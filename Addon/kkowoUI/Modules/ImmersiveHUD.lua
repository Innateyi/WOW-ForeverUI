----------------------------------------------------------------------
--  kkowoUI — Modules/ImmersiveHUD.lua
--  包含两个紧耦合的现代 MMO 体验模块：
--    1) immersiveHUD — 沉浸探索模式（智能动态 HUD 淡隐，FFXIV / GW2 风格）
--       • 非战斗、无目标、非施法、血蓝健康且不在副本时，柔和淡化次要 HUD
--       • 进战 / 选目标 / 施法 / 血蓝下降 / 进副本 / 鼠标划过 瞬间 100% 恢复
--       • 零 taint（独立极简 alpha 过渡帧，不碰暴雪 FADEFRAMES，不写外部框体字段）
--       • 仅在淡隐态启用 0.15s 轻量悬停检测，战斗与副本内零轮询开销
--    2) perfAutoTier — 场景性能自动档位（主城 / 团本智能稳帧 + 副本公屏静音）
--       • 仅调节即时生效、零卡顿的轻量 CVar（完整备份原值，离开场景自动还原）
--       • 副本战斗中自动过滤 /1 综合与 /2 交易频道刷屏（绝不屏蔽队/团/密语/公会）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, next, pairs, pcall, tostring, type = ipairs, next, pairs, pcall, tostring, type
local math_abs, math_floor, math_max, math_min = math.abs, math.floor, math.max, math.min
local setmetatable = setmetatable
local CreateFrame = CreateFrame
local C_Timer = C_Timer

----------------------------------------------------------------------
--  模块 1：immersiveHUD — 沉浸探索模式
----------------------------------------------------------------------
do
    local mod = F.RegisterModule("immersiveHUD", {
        title = "脱战淡隐（统一开关）",
        desc = "一个开关统一管理脱战淡隐：非战斗、无目标且血蓝健康时，动作条、冷却条、核心双翼、属性卡片、伤害统计、计时条、任务栏、系统栏一起柔和淡化；"
            .. "进战、选目标、施法或鼠标移上瞬间清晰。聊天框鼠标移开后也会很快淡隐。",
        group = "visual",
        order = 20,
        defaults = {
            enabled = true,
            idleAlpha = 0.28,
            disableInInstance = true,
            fadeActionBars = true,    -- 全部 EUI 动作条（含主动作条、姿态条、宠物条）
            fadeCooldowns = true,     -- EUI 冷却管理器的冷却 / 增益 / 追踪条
            fadeCoreHUD = true,       -- kkowoUI 核心双翼与宠物条（原核心 HUD 自带的空闲淡隐并入这里）
            fadeStats = true,         -- 人物属性 / 耐久卡片
            fadeTimers = true,        -- 武器附魔 / 攻击特效计时条
            fadeQuestTracker = true,
            fadeDamageMeter = true,
            fadeSystemBar = true,
            fadeXPBar = false,
            fadeMinimap = false,
            chatQuickFade = true,     -- 聊天框：鼠标移开后很快淡隐（新消息仍按 EUI 的闲置延迟）
            chatLeaveDelay = 1.5,
            hpThreshold = 95,
            powerThreshold = 85,
        },
    })

    -- 全部 EUI 动作条（EABBar_<key>）；是否显示、是否「悬停才显示」、平时透明度都以 EUI 自己的设置为准
    local EUI_BAR_KEYS = {
        "MainBar", "Bar2", "Bar3", "Bar4", "Bar5", "Bar6", "Bar7", "Bar8", "Bar9", "Bar10",
        "StanceBar", "PetBar",
    }

    local managed = setmetatable({}, { __mode = "k" })   -- frame -> true（本模块已接管过透明度）
    local restAlpha = setmetatable({}, { __mode = "k" }) -- frame -> 恢复时的透明度（EUI 动作条按其自身设置，其余 1.0）
    local animTargets = {}                                -- frame -> targetAlpha
    local hoverTicker = nil
    local isImmersiveNow = false
    local unlockHooked = false

    -- 独立零污染 Alpha 过渡帧：仅在有过渡任务时 Show，完成后立刻 Hide（平时 0 CPU）
    local animFrame = CreateFrame("Frame")
    animFrame:Hide()
    animFrame:SetScript("OnUpdate", function(self, elapsed)
        local anyActive = false
        local step = math_min(1, (elapsed or 0.016) * 6.5)
        for frame, goal in pairs(animTargets) do
            if frame and frame.GetAlpha and frame.SetAlpha then
                local cur = F.PlainNumber(frame:GetAlpha(), goal)
                local diff = goal - cur
                if math_abs(diff) <= 0.015 then
                    frame:SetAlpha(goal)
                    animTargets[frame] = nil
                else
                    frame:SetAlpha(cur + diff * step)
                    anyActive = true
                end
            else
                animTargets[frame] = nil
            end
        end
        if not anyActive then
            self:Hide()
        end
    end)

    local function FadeFrameTo(frame, goal, instant)
        if not (frame and frame.SetAlpha) then return end
        local cur = F.PlainNumber(frame.GetAlpha and frame:GetAlpha(), goal)
        if instant then
            animTargets[frame] = nil
            if math_abs(cur - goal) > 0.005 then
                frame:SetAlpha(goal)
            end
        else
            if math_abs(cur - goal) <= 0.015 then
                animTargets[frame] = nil
                if math_abs(cur - goal) > 0.002 then
                    frame:SetAlpha(goal)
                end
                return
            end
            animTargets[frame] = goal
            animFrame:Show()
        end
    end

    local targetBuf = {}
    local activeSetBuf = {}
    local worldMapHooked = false

    local function ModuleNS(name)
        local EUI = _G.EllesmereUI
        local reg = EUI and EUI._ModuleNS
        return type(reg) == "table" and reg[name] or nil
    end

    -- EUI 动作条的「平时透明度」：悬停才显示的条交给 EUI 自己（返回 gated=true，不接管），
    -- 其余按 EUI 设置的不透明度恢复，避免把你在 EUI 里调暗的条恢复成 100%
    local function EUIBarRest(key)
        local ns = ModuleNS("EllesmereUIActionBars")
        local H = ns and ns.EAB_VTABLE and ns.EAB_VTABLE.Hover
        if not (H and type(H.RestingAlpha) == "function") then return 1, false end
        local ok, a, gated = pcall(H.RestingAlpha, key)
        if not ok then return 1, false end
        return F.PlainNumber(a, 1) or 1, gated == true
    end

    local seenBuf = {}
    local function CollectTargets()
        local db = mod:GetDB()
        for i = #targetBuf, 1, -1 do targetBuf[i] = nil end
        for k in pairs(seenBuf) do seenBuf[k] = nil end
        local function addFrame(f, rest)
            if not f or seenBuf[f] then return end
            if (f.IsForbidden and f:IsForbidden()) or not (f.IsShown and f:IsShown()) then return end
            -- 不抢占被 EUI 自身 visibility="never" 隐藏（alpha==0 且未由本模块接管）的框体
            local a = F.PlainNumber(f:GetAlpha(), 1)
            if managed[f] or animTargets[f] ~= nil or a > 0.02 then
                seenBuf[f] = true
                restAlpha[f] = rest or 1
                targetBuf[#targetBuf + 1] = f
            end
        end
        local function addByName(name, rest)
            addFrame(_G[name], rest)
        end

        if db.fadeActionBars ~= false then
            for _, key in ipairs(EUI_BAR_KEYS) do
                local f = _G["EABBar_" .. key]
                if f then
                    local rest, gated = EUIBarRest(key)
                    if not gated and rest > 0.02 then addFrame(f, rest) end
                end
            end
        end
        if db.fadeCooldowns ~= false then
            local cdm = ModuleNS("EllesmereUICooldownManager")
            if cdm and type(cdm.cdmBarFrames) == "table" then
                for _, f in pairs(cdm.cdmBarFrames) do
                    if type(f) == "table" then addFrame(f) end
                end
            end
            for i = 1, 30 do addByName("ECME_TBBWrap" .. i) end
        end
        if db.fadeCoreHUD ~= false then
            addByName("kkowoUI_CoreHUD")
            addByName("kkowoUI_PetHUD")
        end
        if db.fadeStats ~= false then
            addByName("EUI_SecondaryStats")
            addByName("kkowoUI_StatsCard")
        end
        if db.fadeTimers ~= false then
            addByName("kkowoUI_WeaponProcBars")
            addByName("kkowoUI_WeaponEnchantBars")
        end
        if db.fadeQuestTracker ~= false then
            addByName("EUI_CustomQuestTracker")
        end
        if db.fadeDamageMeter ~= false then
            for i = 1, 4 do addByName("EllesmereUIDMFrame" .. i) end
            addByName("EDM_Win1")
        end
        if db.fadeSystemBar ~= false then
            addByName("kkowoUI_SystemBar")
        end
        if db.fadeXPBar == true then
            addByName("kkowoUI_XPBar")
        end
        if db.fadeMinimap == true then
            addByName("MinimapCluster")
        end

        -- 父子都在名单里时只淡父框体（否则透明度相乘，子框体会淡得过头，例如属性卡片挂在 EUI 属性面板上）
        for i = #targetBuf, 1, -1 do
            local f = targetBuf[i]
            local p = f.GetParent and f:GetParent() or nil
            local depth = 0
            while p and depth < 10 do
                if seenBuf[p] then
                    table.remove(targetBuf, i)
                    break
                end
                p = p.GetParent and p:GetParent() or nil
                depth = depth + 1
            end
        end
        return targetBuf
    end

    local function IsInCombatInstance()
        if not _G.GetInstanceInfo then return false end
        local _, iType = _G.GetInstanceInfo()
        return iType == "party" or iType == "raid" or iType == "scenario" or iType == "arena" or iType == "pvp"
    end

    local function IsPlayerVitalHealthy(db)
        local hp = F.PlainNumber(_G.UnitHealth and _G.UnitHealth("player"), nil)
        local hpMax = F.PlainNumber(_G.UnitHealthMax and _G.UnitHealthMax("player"), nil)
        if hp and hpMax and hpMax > 0 and (hp / hpMax * 100) < (db.hpThreshold or 95) then
            return false
        end
        local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("player"), 0) or 0
        -- 仅对蓝条（MANA = 0）检查回蓝不满；怒气/能量/集中值平时为 0 或自回，不触发常亮
        if pType == 0 then
            local mp = F.PlainNumber(_G.UnitPower and _G.UnitPower("player", 0), nil)
            local mpMax = F.PlainNumber(_G.UnitPowerMax and _G.UnitPowerMax("player", 0), nil)
            if mp and mpMax and mpMax > 0 and (mp / mpMax * 100) < (db.powerThreshold or 85) then
                return false
            end
        end
        return true
    end

    local function SafeBoolCall(fn, ...)
        if type(fn) ~= "function" then return false end
        local ok, val = pcall(fn, ...)
        if not ok or F.IsSecret(val) then return false end
        return val == true
    end

    local function SafeHasCast(fn, unit)
        if type(fn) ~= "function" then return false end
        local ok, name = pcall(fn, unit)
        return ok and type(name) ~= "nil"
    end

    local function ShouldImmerse()
        if not mod._active then return false end
        local db = mod:GetDB()
        if _G.EllesmereUI and _G.EllesmereUI._unlockActive then return false end
        if _G.InCombatLockdown and _G.InCombatLockdown() then return false end
        if SafeBoolCall(_G.UnitAffectingCombat, "player") then return false end
        if SafeBoolCall(_G.UnitExists, "target") then return false end
        if SafeHasCast(_G.UnitCastingInfo, "player") then return false end
        if SafeHasCast(_G.UnitChannelInfo, "player") then return false end
        if db.disableInInstance ~= false and IsInCombatInstance() then return false end
        if _G.WorldMapFrame and _G.WorldMapFrame:IsShown() then return false end
        if not IsPlayerVitalHealthy(db) then return false end
        return true
    end

    local COMBAT_FADE_OWNERS = {
        kkowoUI_SystemBar    = "systemBar",
        kkowoUI_XPBar        = "xpBar",
    }

    local function IsYieldedToCombatFade(frame)
        if not frame then return false end
        local inCombat = (_G.InCombatLockdown and _G.InCombatLockdown())
            or SafeBoolCall(_G.UnitAffectingCombat, "player")
        if not inCombat then return false end
        local fname = frame.GetName and F.PlainString(frame:GetName(), nil) or nil
        local modKey = fname and COMBAT_FADE_OWNERS[fname]
        if not modKey then return false end
        local mdb = F.db and F.db.modules and F.db.modules[modKey]
        return mdb and mdb.combatFade == true
    end

    local function RestoreAllManaged(instant)
        local toRestore = {}
        for frame in pairs(managed) do
            toRestore[frame] = true
            managed[frame] = nil
        end
        for frame in pairs(animTargets) do
            toRestore[frame] = true
        end
        for frame in pairs(toRestore) do
            if IsYieldedToCombatFade(frame) then
                animTargets[frame] = nil
            else
                FadeFrameTo(frame, restAlpha[frame] or 1.0, instant)
            end
        end
        if instant then
            for k in pairs(animTargets) do animTargets[k] = nil end
            animFrame:Hide()
        end
        if hoverTicker then
            hoverTicker:Cancel()
            hoverTicker = nil
        end
        isImmersiveNow = false
    end

    local function RefreshAlphas(instant)
        if not mod._active then
            RestoreAllManaged(true)
            return
        end
        local wantImmerse = ShouldImmerse()
        isImmersiveNow = wantImmerse

        -- 非沉浸态且没有任何已接管框体或残留淡入动画时零开销直接返回（彻底消除战斗中高频事件唤醒）
        if not wantImmerse then
            if next(managed) ~= nil or next(animTargets) ~= nil then
                RestoreAllManaged(instant)
            elseif hoverTicker then
                hoverTicker:Cancel()
                hoverTicker = nil
            end
            return
        end

        local db = mod:GetDB()
        local idleA = db.idleAlpha or 0.28
        for k in pairs(activeSetBuf) do activeSetBuf[k] = nil end
        local targets = CollectTargets()
        for _, f in ipairs(targets) do
            activeSetBuf[f] = true
            managed[f] = true
            local rest = restAlpha[f] or 1.0
            local over = f.IsMouseOver and f:IsMouseOver()
            FadeFrameTo(f, over and rest or math_min(rest, idleA), instant)
        end
        -- 被用户在选项中取消勾选（或已隐藏 / 被父框体代淡）的框体立即恢复
        for f in pairs(managed) do
            if not activeSetBuf[f] then
                if IsYieldedToCombatFade(f) then
                    animTargets[f] = nil
                else
                    FadeFrameTo(f, restAlpha[f] or 1.0, instant)
                end
                managed[f] = nil
            end
        end

        if not hoverTicker then
            hoverTicker = C_Timer.NewTicker(0.15, function()
                if not (mod._active and isImmersiveNow) then
                    if hoverTicker then hoverTicker:Cancel(); hoverTicker = nil end
                    return
                end
                local a = mod:GetDB().idleAlpha or 0.28
                local curTargets = CollectTargets()
                for k in pairs(activeSetBuf) do activeSetBuf[k] = nil end
                for _, f in ipairs(curTargets) do
                    activeSetBuf[f] = true
                    if not managed[f] then managed[f] = true end
                end
                -- 期间被隐藏 / 被父框体代淡 / 变成 EUI「悬停才显示」的框体交还原透明度
                for f in pairs(managed) do
                    if not activeSetBuf[f] then
                        managed[f] = nil
                        FadeFrameTo(f, restAlpha[f] or 1.0, false)
                    end
                end
                for f in pairs(managed) do
                    if f and not (f.IsForbidden and f:IsForbidden()) and f.IsShown and f:IsShown() then
                        local rest = restAlpha[f] or 1.0
                        local over = f.IsMouseOver and f:IsMouseOver()
                        local want = over and rest or math_min(rest, a)
                        local curGoal = animTargets[f]
                        local curA = F.PlainNumber(f:GetAlpha(), 1)
                        if (curGoal and math_abs(curGoal - want) > 0.02)
                            or (not curGoal and math_abs(curA - want) > 0.02) then
                            FadeFrameTo(f, want, false)
                        end
                    end
                end
            end)
        end
    end

    local QueueRefresh = F.Debounce(0.12, function() RefreshAlphas(false) end)

    local function OnVitalEvent()
        if not mod._active then return end
        -- 战斗中或选中目标时一定处于非沉浸态，且无已接管框体时直接短路，避免高频回血/回蓝触发防抖计时器
        if next(managed) == nil and next(animTargets) == nil and (
            (_G.InCombatLockdown and _G.InCombatLockdown())
            or SafeBoolCall(_G.UnitAffectingCombat, "player")
            or SafeBoolCall(_G.UnitExists, "target")
        ) then
            return
        end
        QueueRefresh()
    end

    -- 统一开关：其它模块（核心双翼）问这里自己是否已被接管，被接管就不再自行淡化
    F.UnifiedFade = {
        Owns = function(what)
            if not mod._active then return false end
            local db = mod:GetDB()
            if what == "coreHUD" then return db.fadeCoreHUD ~= false end
            return false
        end,
    }

    ----------------------------------------------------------------------
    -- 聊天框快速淡隐：EUI 聊天的「闲置淡隐」在鼠标划过后会重新计满整个闲置延迟（默认 15 秒）才淡出，
    -- 鼠标早就移开了它还亮着。这里在 EUI 每次重置闲置计时后判断：若不是新消息唤醒，
    -- 就盯着鼠标，离开聊天区域（且输入框没在输入）满 chatLeaveDelay 秒立即让 EUI 淡出。
    -- 新消息唤醒仍保持 EUI 原本的延迟，方便看完消息。
    ----------------------------------------------------------------------
    local CHAT_WAKE_EVENTS = {
        "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
        "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM",
        "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
        "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
        "CHAT_MSG_CHANNEL", "CHAT_MSG_COMMUNITIES_CHANNEL",
    }
    local chatHooked = false
    local chatMsgAt = -10
    local chatWatchToken = 0

    local function ChatEditFocused()
        local eb = _G.ChatFrame1EditBox
        if not (eb and eb.HasFocus) then return false end
        local ok, f = pcall(eb.HasFocus, eb)
        return ok and not F.IsSecret(f) and f == true
    end

    local function ChatMouseOver(chatNS)
        local overlay = chatNS and chatNS._chatHoverOverlay
        local areas = { overlay, _G.GeneralDockManager, _G.ChatFrame1 }
        for _, f in ipairs(areas) do
            if f and f.IsMouseOver then
                local ok, over = pcall(f.IsMouseOver, f)
                if ok and not F.IsSecret(over) and over == true then return true end
            end
        end
        return false
    end

    local function OnEUIChatIdleReset()
        chatWatchToken = chatWatchToken + 1
        if not mod._active then return end
        local db = mod:GetDB()
        if db.chatQuickFade == false then return end
        -- 新消息唤醒（EUI 在收到消息的下一帧重置计时）：保持 EUI 的闲置延迟
        if _G.GetTime() - chatMsgAt < 0.5 then return end
        local chatNS = ModuleNS("EllesmereUIChat")
        local E = chatNS and chatNS.ECHAT
        if not (E and type(E.StartIdleFadeNow) == "function") then return end
        local my = chatWatchToken
        local cfg = type(E.DB) == "function" and E.DB() or nil
        local maxWatch = (cfg and F.PlainNumber(cfg.idleFadeDelay, nil) or 15) + 1
        local started = _G.GetTime()
        local awaySince = nil
        local function Tick()
            if my ~= chatWatchToken or not mod._active then return end
            local now = _G.GetTime()
            if ChatMouseOver(chatNS) or ChatEditFocused() then
                awaySince = nil
            else
                awaySince = awaySince or now
                local delay = F.PlainNumber(mod:GetDB().chatLeaveDelay, 1.5) or 1.5
                if now - awaySince >= delay then
                    pcall(E.StartIdleFadeNow)
                    return
                end
            end
            if now - started < maxWatch then C_Timer.After(0.2, Tick) end
        end
        C_Timer.After(0.2, Tick)
    end

    local function HookEUIChat()
        if chatHooked then return true end
        local chatNS = ModuleNS("EllesmereUIChat")
        local E = chatNS and chatNS.ECHAT
        if not (E and type(E.ResetIdleTimer) == "function") then return false end
        chatHooked = true
        _G.hooksecurefunc(E, "ResetIdleTimer", OnEUIChatIdleReset)
        return true
    end

    function mod:ToggleImmersive()
        local db = self:GetDB()
        self:SetEnabled(not (db.enabled ~= false))
        F.Print("脱战淡隐（统一开关）已" .. (self:IsEnabled() and "|cff5fd3a6开启|r" or "|cff888888关闭|r") .. "。")
    end

    function mod:OnEnable()
        local EUI = _G.EllesmereUI
        if not unlockHooked and EUI and EUI.RegisterUnlockModeListener then
            unlockHooked = true
            pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_ImmersiveHUD", function(active)
                if not mod._active then return end
                if active then
                    RestoreAllManaged(true)
                else
                    C_Timer.After(0.2, function()
                        if mod._active then RefreshAlphas(false) end
                    end)
                end
            end)
        end

        if not worldMapHooked and _G.WorldMapFrame and _G.WorldMapFrame.HookScript then
            worldMapHooked = true
            _G.WorldMapFrame:HookScript("OnShow", function()
                if mod._active then RefreshAlphas(false) end
            end)
            _G.WorldMapFrame:HookScript("OnHide", function()
                if mod._active then QueueRefresh() end
            end)
        end

        self:RegisterEvent("PLAYER_REGEN_DISABLED", function() RefreshAlphas(true) end)
        self:RegisterEvent("PLAYER_REGEN_ENABLED", QueueRefresh)
        self:RegisterEvent("PLAYER_TARGET_CHANGED", function() RefreshAlphas(false) end)
        self:RegisterUnitEvent("UNIT_HEALTH", "player", OnVitalEvent)
        -- 用 UNIT_POWER_UPDATE（每次回蓝跳一次）代替 FREQUENT（每帧级），并在战斗/选目标时直接短路
        self:RegisterUnitEvent("UNIT_POWER_UPDATE", "player", OnVitalEvent)
        self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player", function() RefreshAlphas(true) end)
        self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player", QueueRefresh)
        self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", function() RefreshAlphas(true) end)
        self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", QueueRefresh)
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA", QueueRefresh)
        self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
            RefreshAlphas(true)
            HookEUIChat()
            C_Timer.After(1.2, function()
                if mod._active then RefreshAlphas(false) end
            end)
        end)
        local function OnChatMsg() chatMsgAt = _G.GetTime() end
        for _, ev in ipairs(CHAT_WAKE_EVENTS) do self:RegisterEvent(ev, OnChatMsg) end
        if not HookEUIChat() then
            C_Timer.After(2, HookEUIChat)
        end

        C_Timer.After(1.0, function()
            if mod._active then RefreshAlphas(false) end
        end)
    end

    function mod:OnDisable()
        local EUI = _G.EllesmereUI
        if unlockHooked and EUI and EUI.UnregisterUnlockModeListener then
            pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_ImmersiveHUD")
            unlockHooked = false
        end
        RestoreAllManaged(true)
    end

    function mod:OnRefresh()
        RefreshAlphas(false)
    end

    function mod:BuildOptions(W, parent, y, enableSlot, blank)
        local db = self:GetDB()
        local _, h
        local function Toggle(key, text, tooltip, defaultOff)
            return {
                type = "toggle",
                text = text,
                tooltip = tooltip,
                disabled = function() return not mod:IsEnabled() end,
                getValue = function()
                    if defaultOff then return db[key] == true end
                    return db[key] ~= false
                end,
                setValue = function(v) db[key] = v == true; RefreshAlphas(false) end,
            }
        end
        enableSlot.text = "启用脱战淡隐（总开关）"
        enableSlot.tooltip = "一个开关管理下面所有框体的脱战淡隐。关闭后全部恢复 100% 清晰（也可输入 /kk hud 切换）。"
        _, h = W:DualRow(parent, y, enableSlot, {
            type = "slider",
            text = "淡隐后的透明度",
            tooltip = "非战斗、无目标、血蓝健康时的可见度；鼠标移到对应框体上瞬间恢复。",
            min = 0.0, max = 0.75, step = 0.05,
            disabled = function() return not mod:IsEnabled() end,
            getValue = function() return db.idleAlpha or 0.28 end,
            setValue = function(v) db.idleAlpha = v; RefreshAlphas(false) end,
        })
        y = y - h

        _, h = W:DualRow(parent, y,
            Toggle("fadeActionBars", "动作条（全部 EUI 动作条）",
                "含主动作条、姿态条、宠物条。EUI 里设为「鼠标悬停才显示」的条仍由 EUI 管理；调过不透明度的条恢复到你在 EUI 里设的值。"),
            Toggle("fadeCooldowns", "冷却管理器（冷却 / 增益 / 追踪条）"))
        y = y - h

        _, h = W:DualRow(parent, y,
            Toggle("fadeCoreHUD", "核心双翼血蓝条与宠物条",
                "原先核心 HUD 自带的「脱战满状态淡隐」已并入这里，统一用上面的透明度。"),
            Toggle("fadeStats", "人物属性 / 耐久卡片"))
        y = y - h

        _, h = W:DualRow(parent, y,
            Toggle("fadeDamageMeter", "伤害统计窗口"),
            Toggle("fadeTimers", "武器附魔 / 攻击特效计时条"))
        y = y - h

        _, h = W:DualRow(parent, y,
            Toggle("fadeQuestTracker", "任务追踪栏"),
            Toggle("fadeSystemBar", "底部系统栏"))
        y = y - h

        _, h = W:DualRow(parent, y,
            Toggle("chatQuickFade", "聊天框：鼠标移开后快速淡隐",
                "EUI 聊天框的「闲置淡隐」在鼠标划过后要重新等满闲置时间（默认 15 秒）才淡出。开启后鼠标移开（且没在输入）"
                .. "一小会儿就淡出；收到新消息时仍按 EUI 的闲置时间显示。需要 EUI 聊天设置里的「闲置淡隐」开着。"), {
            type = "slider",
            text = "移开后多久淡隐（秒）",
            min = 0.5, max = 5, step = 0.5,
            disabled = function() return not mod:IsEnabled() or db.chatQuickFade == false end,
            getValue = function() return F.PlainNumber(db.chatLeaveDelay, 1.5) or 1.5 end,
            setValue = function(v) db.chatLeaveDelay = v end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "副本 / 战场内禁用淡隐",
            tooltip = "进入地下城、团本或战场时保持全部 HUD 100% 清晰。",
            getValue = function() return db.disableInInstance ~= false end,
            setValue = function(v) db.disableInInstance = v == true; RefreshAlphas(false) end,
        }, {
            type = "toggle",
            text = "同时淡化经验条 / 小地图",
            getValue = function() return db.fadeXPBar == true end,
            setValue = function(v) db.fadeXPBar = v == true; db.fadeMinimap = v == true; RefreshAlphas(false) end,
        })
        y = y - h
        return y
    end
end

----------------------------------------------------------------------
--  模块 2：perfAutoTier — 场景性能自动档位 + 副本战斗安静模式
----------------------------------------------------------------------
do
    local pMod = F.RegisterModule("perfAutoTier", {
        title = "场景性能自动档位",
        desc = "主城人群密集或大型团本自动应用零卡顿稳帧预设（仅调即时 CVar，离开自动还原），并支持副本战斗屏蔽公屏刷屏。",
        group = "visual",
        order = 25,
        defaults = {
            enabled = true,
            autoCityTier = true,
            autoRaidTier = true,
            quietInstanceChat = true,
            fpsGuard = true,
            fpsThreshold = 24,
            forceBoost = false,
            savedCVars = nil,
        },
    })

    local MANAGED_CVARS = {
        "weatherDensity",
        "spellClutter",
        "ffxDeath",
    }

    local chatFilterRegistered = false
    local currentTier = "normal"
    local fpsTicker = nil
    local lowFpsStreak = 0

    local function SafeGetCVar(name)
        local CV = _G.C_CVar
        if CV and CV.GetCVar then
            local ok, v = pcall(CV.GetCVar, name)
            if ok then return F.PlainString(v, nil) end
        elseif _G.GetCVar then
            local ok, v = pcall(_G.GetCVar, name)
            if ok then return F.PlainString(v, nil) end
        end
        return nil
    end

    local function SafeSetCVar(name, value)
        local cur = SafeGetCVar(name)
        if cur == nil then return false end
        local want = tostring(value)
        if cur == want then return true end
        local CV = _G.C_CVar
        if CV and CV.SetCVar then
            return pcall(CV.SetCVar, name, want)
        elseif _G.SetCVar then
            return pcall(_G.SetCVar, name, want)
        end
        return false
    end

    local function IsInCombatInstance()
        if not _G.GetInstanceInfo then return false end
        local _, iType = _G.GetInstanceInfo()
        return iType == "party" or iType == "raid" or iType == "scenario" or iType == "arena" or iType == "pvp"
    end

    local function DetectTier(db)
        if db.forceBoost then return "raid" end
        local iType = "none"
        if _G.GetInstanceInfo then
            local _, t = _G.GetInstanceInfo()
            if type(t) == "string" then iType = t end
        end
        local members = (_G.GetNumGroupMembers and _G.GetNumGroupMembers()) or 0
        if db.autoRaidTier ~= false and (iType == "raid" or members >= 15) then
            return "raid"
        end
        if db.autoCityTier ~= false and not IsInCombatInstance() and (_G.IsResting and _G.IsResting()) then
            return "city"
        end
        return "normal"
    end

    local function SnapshotCVars(db)
        if type(db.savedCVars) == "table" then return end
        local snap = {}
        for _, name in ipairs(MANAGED_CVARS) do
            local v = SafeGetCVar(name)
            if v ~= nil then snap[name] = v end
        end
        db.savedCVars = snap
    end

    local function RestoreCVars(db)
        if type(db.savedCVars) ~= "table" then return end
        for name, orig in pairs(db.savedCVars) do
            SafeSetCVar(name, orig)
        end
        db.savedCVars = nil
    end

    local fpsGuarded = false

    local function ApplyTier()
        if not pMod._active then return end
        F.RunOutOfCombat("FUI_PerfAutoTier", function()
            if not pMod._active then return end
            local db = pMod:GetDB()
            local tier = DetectTier(db)
            if tier == "normal" then
                if fpsGuarded and db.fpsGuard ~= false then
                    return
                end
                fpsGuarded = false
                if db.savedCVars then RestoreCVars(db) end
                currentTier = "normal"
                return
            end
            fpsGuarded = false
            SnapshotCVars(db)
            if tier == "raid" then
                SafeSetCVar("weatherDensity", "0")
                SafeSetCVar("spellClutter", "100")
                SafeSetCVar("ffxDeath", "0")
            elseif tier == "city" then
                SafeSetCVar("weatherDensity", "1")
                SafeSetCVar("spellClutter", "80")
                if db.savedCVars and db.savedCVars.ffxDeath ~= nil then
                    SafeSetCVar("ffxDeath", db.savedCVars.ffxDeath)
                end
            end
            currentTier = tier
        end)
    end

    local function InstanceChatFilter(_, _, _, _, _, _, _, _, zoneChanID, _, chanBaseName)
        if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            return false
        end
        if not (pMod._active and pMod:GetDB().quietInstanceChat ~= false) then
            return false
        end
        if not IsInCombatInstance() then
            return false
        end
        local zid = F.PlainNumber(zoneChanID, 0)
        if zid == 1 or zid == 2 then
            return true
        end
        local base = F.PlainString(chanBaseName, nil)
        if base and (base:find("综合", 1, true) or base:find("交易", 1, true)
            or base:find("General", 1, true) or base:find("Trade", 1, true)) then
            return true
        end
        return false
    end

    function pMod:ToggleForceBoost()
        local db = self:GetDB()
        db.forceBoost = not (db.forceBoost == true)
        fpsGuarded = false
        ApplyTier()
        F.Print("强力稳帧预设已" .. (db.forceBoost and "|cff5fd3a6开启|r（团本级精简特效）" or "|cff888888恢复自动|r") .. "。")
    end

    function pMod:OnEnable()
        local addFilter = (_G.ChatFrameUtil and _G.ChatFrameUtil.AddMessageEventFilter)
            or _G.ChatFrame_AddMessageEventFilter
        if not chatFilterRegistered and addFilter then
            chatFilterRegistered = true
            pcall(addFilter, "CHAT_MSG_CHANNEL", InstanceChatFilter)
        end

        self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
            lowFpsStreak = 0
            fpsGuarded = false
            ApplyTier()
            C_Timer.After(1.5, function()
                if pMod._active then ApplyTier() end
            end)
        end)
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
            lowFpsStreak = 0
            fpsGuarded = false
            ApplyTier()
        end)
        self:RegisterEvent("PLAYER_UPDATE_RESTING", ApplyTier)
        self:RegisterEvent("GROUP_ROSTER_UPDATE", F.Debounce(0.5, ApplyTier))
        self:RegisterEvent("PLAYER_REGEN_ENABLED", ApplyTier)

        if fpsTicker then fpsTicker:Cancel() end
        fpsTicker = C_Timer.NewTicker(5, function()
            if not (pMod._active and pMod:GetDB().fpsGuard ~= false) then return end
            if _G.InCombatLockdown and _G.InCombatLockdown() then return end
            if currentTier == "raid" then return end
            local fps = math_floor((_G.GetFramerate and _G.GetFramerate() or 60) + 0.5)
            local thr = pMod:GetDB().fpsThreshold or 24
            if fps > 5 and fps < thr then
                lowFpsStreak = lowFpsStreak + 1
                if lowFpsStreak >= 2 and not fpsGuarded then
                    lowFpsStreak = 0
                    fpsGuarded = true
                    local db = pMod:GetDB()
                    SnapshotCVars(db)
                    SafeSetCVar("weatherDensity", "0")
                    SafeSetCVar("spellClutter", "100")
                    F.PrintOnce("perf_fps_guard", "|cff5fd3a6帧率保护已触发|r：已自动轻度收紧天气与法术冗余特效以稳帧（离开拥挤区自动恢复）。")
                end
            else
                lowFpsStreak = 0
                if fpsGuarded and fps >= thr + 12 then
                    fpsGuarded = false
                    ApplyTier()
                end
            end
        end)

        ApplyTier()
    end

    function pMod:OnDisable()
        if fpsTicker then fpsTicker:Cancel(); fpsTicker = nil end
        local remFilter = (_G.ChatFrameUtil and _G.ChatFrameUtil.RemoveMessageEventFilter)
            or _G.ChatFrame_RemoveMessageEventFilter
        if chatFilterRegistered and remFilter then
            pcall(remFilter, "CHAT_MSG_CHANNEL", InstanceChatFilter)
            chatFilterRegistered = false
        end
        fpsGuarded = false
        F.RunOutOfCombat("FUI_PerfAutoTier", function()
            RestoreCVars(pMod:GetDB())
        end)
        currentTier = "normal"
    end

    function pMod:BuildOptions(W, parent, y, enableSlot, blank)
        local db = self:GetDB()
        local _, h
        _, h = W:DualRow(parent, y, enableSlot, {
            type = "toggle",
            text = "副本战斗自动过滤综合/交易刷屏",
            tooltip = "地下城/团本进入战斗期间临时过滤 /1 综合与 /2 交易频道，不影响小队、团队、公会与密语，脱战即恢复。",
            getValue = function() return db.quietInstanceChat ~= false end,
            setValue = function(v) db.quietInstanceChat = v == true end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "主城自动轻度稳帧",
            tooltip = "进入主城/休整区自动收紧天气与冗余法术粒子，离开自动还原原设置。",
            getValue = function() return db.autoCityTier ~= false end,
            setValue = function(v) db.autoCityTier = v == true; ApplyTier() end,
        }, {
            type = "toggle",
            text = "团本 / 15人以上自动稳帧",
            tooltip = "进入团队副本或大型团队自动启用团本级零卡顿预设（绝不触发重载黑屏）。",
            getValue = function() return db.autoRaidTier ~= false end,
            setValue = function(v) db.autoRaidTier = v == true; ApplyTier() end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "持续低帧自动介入保护",
            tooltip = "脱战检测到帧率连续低于阈值时自动收紧天气与杂项粒子。",
            getValue = function() return db.fpsGuard ~= false end,
            setValue = function(v)
                db.fpsGuard = v == true
                if not db.fpsGuard and fpsGuarded then
                    fpsGuarded = false
                    ApplyTier()
                end
            end,
        }, {
            type = "toggle",
            text = "手动锁定强力稳帧（/kk boost）",
            getValue = function() return db.forceBoost == true end,
            setValue = function(v) db.forceBoost = v == true; ApplyTier() end,
        })
        y = y - h
        return y
    end
end
