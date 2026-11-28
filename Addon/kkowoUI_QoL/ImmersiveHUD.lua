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
local _G = _G
local F = _G.kkowoUI
if not F then return end
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
        title = "脱战淡隐",
        desc = "脱战、无目标且血蓝健康时统一淡化各框体，进战或悬停即恢复。",
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
    local desiredAlpha = setmetatable({}, { __mode = "k" }) -- frame -> 本模块期望维持的淡隐透明度（用于拦住外部瞬闪）
    local alphaHooked = setmetatable({}, { __mode = "k" })
    local alphaGuardBusy = false
    local animTargets = {}                                -- frame -> targetAlpha
    local hoverTicker = nil
    local isImmersiveNow = false
    local unlockHooked = false

    local function SafeSetManagedAlpha(frame, val)
        alphaGuardBusy = true
        pcall(frame.SetAlpha, frame, val)
        alphaGuardBusy = false
    end

    local function SafeIsMouseOver(frame)
        if not (frame and frame.IsMouseOver) then return false end
        local ok, over = pcall(frame.IsMouseOver, frame)
        return ok and not F.IsSecret(over) and over == true
    end

    -- 零污染防瞬闪护栏：过图/切换子区域时 EUI 任务追踪器等框体会在 ZONE_CHANGED 里调用 SetAlpha(1)，
    -- 钩住全部已接管框体的 SetAlpha，脱战淡隐态且未悬停时当帧立即压回目标淡隐值（0 闪屏、覆盖全框体）
    local function EnsureAlphaGuard(frame)
        if not (frame and _G.hooksecurefunc and not alphaHooked[frame]) then return end
        if frame.IsForbidden and frame:IsForbidden() then return end
        alphaHooked[frame] = true
        _G.hooksecurefunc(frame, "SetAlpha", function(self, a)
            if alphaGuardBusy or not (mod._active and isImmersiveNow and managed[self]) then return end
            local want = desiredAlpha[self]
            if not want then return end
            local numA = F.PlainNumber(a, nil)
            if numA and numA > want + 0.03 and not SafeIsMouseOver(self) then
                SafeSetManagedAlpha(self, want)
            end
        end)
    end

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
                    SafeSetManagedAlpha(frame, goal)
                    animTargets[frame] = nil
                else
                    SafeSetManagedAlpha(frame, cur + diff * step)
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
        if managed[frame] then
            desiredAlpha[frame] = goal
            EnsureAlphaGuard(frame)
        end
        local cur = F.PlainNumber(frame.GetAlpha and frame:GetAlpha(), goal)
        if instant then
            animTargets[frame] = nil
            if math_abs(cur - goal) > 0.005 then
                SafeSetManagedAlpha(frame, goal)
            end
        else
            if math_abs(cur - goal) <= 0.015 then
                animTargets[frame] = nil
                if math_abs(cur - goal) > 0.002 then
                    SafeSetManagedAlpha(frame, goal)
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
    local euiBarKeyOf = setmetatable({}, { __mode = "k" })
    local function IsExternalHiddenOrGated(f)
        if not f then return false end
        if f._visHidden == true then return true end
        local barKey = euiBarKeyOf[f]
        if barKey then
            local _, gated = EUIBarRest(barKey)
            if gated then return true end
        end
        return false
    end

    local function CollectTargets()
        local db = mod:GetDB()
        for i = #targetBuf, 1, -1 do targetBuf[i] = nil end
        for k in pairs(seenBuf) do seenBuf[k] = nil end
        local function addFrame(f, rest)
            if not f or seenBuf[f] then return end
            if (f.IsForbidden and f:IsForbidden()) or not (f.IsShown and f:IsShown()) then return end
            if f._visHidden == true then return end
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
                    euiBarKeyOf[f] = key
                    local rest, gated = EUIBarRest(key)
                    if not gated and rest > 0.02 then addFrame(f, rest) end
                end
            end
        end
        if db.fadeCooldowns ~= false then
            local cdm = ModuleNS("EllesmereUICooldownManager")
            if cdm and type(cdm.cdmBarFrames) == "table" then
                for _, f in pairs(cdm.cdmBarFrames) do
                    if type(f) == "table" and f._visHidden ~= true then addFrame(f) end
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
            local p = (not (f.IsForbidden and f:IsForbidden())) and f.GetParent and f:GetParent() or nil
            local depth = 0
            while p and depth < 10 do
                if p.IsForbidden and p:IsForbidden() then break end
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
        if not _G.GetInstanceInfo then return false, "none", false end
        local ok, _, rawType = pcall(_G.GetInstanceInfo)
        local isSec = ok and F.IsSecret(rawType) or false
        local iType = ok and F.PlainString(rawType, nil) or nil
        local inInst = iType == "party" or iType == "raid" or iType == "scenario" or iType == "arena" or iType == "pvp"
        return inInst, iType or (isSec and "<secret>" or "none"), isSec
    end

    local function SafeBoolCall(fn, ...)
        if type(fn) ~= "function" then return false end
        local ok, val = pcall(fn, ...)
        if not ok or F.IsSecret(val) then return false end
        return val == true
    end

    local function SafeHasCast(fn, unit)
        if type(fn) ~= "function" then return false, false end
        local ok, name = pcall(fn, unit)
        if not ok then return false, false end
        return type(name) ~= "nil", F.IsSecret(name)
    end

    -- 脱战后的血量/蓝量健康检查：
    -- 12.x / 无限服在脱战状态下 UnitHealth/UnitPower 也可能返回机密值；
    -- 战斗锁定已前置拦截，这里读到机密值或读取失败时跳过该项（绝不把"读不到"当作"永远不健康"挡死淡隐）。
    local function IsPlayerVitalHealthy(db)
        if _G.UnitHealth and _G.UnitHealthMax then
            local okH, rawHp = pcall(_G.UnitHealth, "player")
            local okM, rawMax = pcall(_G.UnitHealthMax, "player")
            if okH and okM and not F.IsSecret(rawHp) and not F.IsSecret(rawMax) then
                local hp = F.PlainNumber(rawHp, nil)
                local hpMax = F.PlainNumber(rawMax, nil)
                if hp and hpMax and hpMax > 0 and (hp / hpMax * 100) < (db.hpThreshold or 95) then
                    return false
                end
            end
        end
        local pType = nil
        if _G.UnitPowerType then
            local okPT, rawPT = pcall(_G.UnitPowerType, "player")
            if okPT and not F.IsSecret(rawPT) then
                pType = F.PlainNumber(rawPT, nil)
            end
        end
        -- 仅对蓝条（MANA = 0）检查回蓝不满；怒气/能量/集中值平时为 0 或自回，不触发常亮
        if pType == 0 and _G.UnitPower and _G.UnitPowerMax then
            local okP, rawMp = pcall(_G.UnitPower, "player", 0)
            local okPM, rawMpMax = pcall(_G.UnitPowerMax, "player", 0)
            if okP and okPM and not F.IsSecret(rawMp) and not F.IsSecret(rawMpMax) then
                local mp = F.PlainNumber(rawMp, nil)
                local mpMax = F.PlainNumber(rawMpMax, nil)
                if mp and mpMax and mpMax > 0 and (mp / mpMax * 100) < (db.powerThreshold or 85) then
                    return false
                end
            end
        end
        return true
    end

    local function IsPlayerCombatBusy(inCombatInstance)
        -- 1) InCombatLockdown 永不为机密值，是战斗判定的首要依据
        if _G.InCombatLockdown and _G.InCombatLockdown() then
            return true
        end
        -- 2) UnitAffectingCombat("player")：明文 true 必为战斗；副本内若读到机密/失败保守按战斗防误淡（P3-25）
        if type(_G.UnitAffectingCombat) == "function" then
            local ok, val = pcall(_G.UnitAffectingCombat, "player")
            if ok and not F.IsSecret(val) then
                if val == true then return true end
            elseif inCombatInstance then
                return true
            end
        end
        -- 3) 副本首领战期间（即使短暂脱锁）保持清晰
        if _G.C_InstanceEncounter and type(_G.C_InstanceEncounter.IsEncounterInProgress) == "function" then
            if SafeBoolCall(_G.C_InstanceEncounter.IsEncounterInProgress) then
                return true
            end
        end
        return false
    end

    local function ShouldImmerse()
        if not mod._active then return false end
        local db = mod:GetDB()
        if _G.EllesmereUI and _G.EllesmereUI._unlockActive then return false end
        local inInst = IsInCombatInstance()
        if IsPlayerCombatBusy(inInst) then return false end
        if SafeBoolCall(_G.UnitExists, "target") then return false end
        if SafeHasCast(_G.UnitCastingInfo, "player") then return false end
        if SafeHasCast(_G.UnitChannelInfo, "player") then return false end
        if db.disableInInstance ~= false and inInst then return false end
        if _G.WorldMapFrame and SafeBoolCall(_G.WorldMapFrame.IsShown, _G.WorldMapFrame) then return false end
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

    local function ReleaseManagedFrame(f, instant)
        if not f then return end
        desiredAlpha[f] = nil
        if IsYieldedToCombatFade(f) or IsExternalHiddenOrGated(f) then
            animTargets[f] = nil
            return
        end
        local shown = f.IsShown and f:IsShown()
        FadeFrameTo(f, restAlpha[f] or 1.0, instant or not shown)
    end

    local function RestoreAllManaged(instant)
        local toRestore = {}
        for frame in pairs(managed) do
            toRestore[frame] = true
            managed[frame] = nil
            desiredAlpha[frame] = nil
        end
        for frame in pairs(animTargets) do
            toRestore[frame] = true
        end
        for frame in pairs(toRestore) do
            ReleaseManagedFrame(frame, instant)
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
            local over = SafeIsMouseOver(f)
            FadeFrameTo(f, over and rest or math_min(rest, idleA), instant)
        end
        -- 被用户在选项中取消勾选（或已隐藏 / 被父框体代淡 / 交还 EUI 隐藏或悬停控制）的框体立即交还
        for f in pairs(managed) do
            if not activeSetBuf[f] then
                managed[f] = nil
                ReleaseManagedFrame(f, instant)
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
                -- 期间被隐藏 / 被父框体代淡 / 变成 EUI「悬停才显示」或隐藏的框体安全交还
                for f in pairs(managed) do
                    if not activeSetBuf[f] then
                        managed[f] = nil
                        ReleaseManagedFrame(f, false)
                    end
                end
                for f in pairs(managed) do
                    if f and not (f.IsForbidden and f:IsForbidden()) and f.IsShown and f:IsShown() then
                        local rest = restAlpha[f] or 1.0
                        local over = SafeIsMouseOver(f)
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

    -- 统一开关：其它模块（核心双翼 / 任务快捷条）问这里自己是否已被接管
    F.UnifiedFade = {
        Owns = function(what)
            if not mod._active then return false end
            local db = mod:GetDB()
            if what == "coreHUD" then return db.fadeCoreHUD ~= false end
            return false
        end,
        IsFading = function(frame)
            return mod._active == true and isImmersiveNow == true and frame ~= nil and managed[frame] == true
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
        if _G.ChatEdit_GetActiveWindow then
            local okA, win = pcall(_G.ChatEdit_GetActiveWindow)
            if okA and win ~= nil then return true end
        end
        local eb = _G.ChatFrame1EditBox
        if not (eb and eb.HasFocus) then return false end
        local ok, f = pcall(eb.HasFocus, eb)
        return ok and not F.IsSecret(f) and f == true
    end

    local function IsFrameMouseOver(f)
        if not (f and f.IsMouseOver) then return false end
        if f.IsShown then
            local okS, shown = pcall(f.IsShown, f)
            if not okS or F.IsSecret(shown) or shown ~= true then return false end
        end
        local ok, over = pcall(f.IsMouseOver, f)
        return ok and not F.IsSecret(over) and over == true
    end

    local function ChatMouseOver(chatNS)
        return IsFrameMouseOver(chatNS and chatNS._chatHoverOverlay)
            or IsFrameMouseOver(chatNS and chatNS._chatBgExt)
            or IsFrameMouseOver(chatNS and chatNS._chatTabStrip)
            or IsFrameMouseOver(chatNS and chatNS._sidebarFrame)
            or IsFrameMouseOver(_G.kkowoUI_ChatUnifiedPanel)
            or IsFrameMouseOver(_G.kkowoUI_ChatBar)
            or IsFrameMouseOver(_G.GeneralDockManager)
            or IsFrameMouseOver(_G.ChatFrame1)
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
        local cfg = nil
        if type(E.DB) == "function" then
            local okDB, c = pcall(E.DB)
            if okDB and type(c) == "table" then cfg = c end
        end
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
        F.Print("脱战淡隐已" .. (self:IsEnabled() and "|cff5fd3a6开启|r" or "|cff888888关闭|r") .. "。")
    end

    -- 只读诊断（战斗中 100% 安全，不修改任何框体与状态）：供 /kk fade why 与离线回归使用
    function mod:InspectFadeState()
        local db = self:GetDB()
        local conds = {}
        local blockers = {}

        local function addCond(key, label, raw, isSecret, blocked, note)
            conds[#conds + 1] = {
                key = key,
                label = label,
                raw = raw,
                secret = isSecret == true,
                blocked = blocked == true,
                note = note or "",
            }
            if blocked then
                blockers[#blockers + 1] = key
            end
        end

        -- 1) 模块总开关
        local modOn = self:IsEnabled() and mod._active == true
        addCond("moduleActive", "模块总开关",
            "enabled=" .. tostring(self:IsEnabled()) .. ", active=" .. tostring(mod._active == true),
            false, not modOn, modOn and "已启用" or "未启用")

        -- 2) EUI 解锁模式
        local unlockOn = (_G.EllesmereUI and _G.EllesmereUI._unlockActive == true) == true
        addCond("unlockMode", "EUI 解锁模式", tostring(unlockOn), false, unlockOn, unlockOn and "解锁拖动中" or "关闭")

        -- 3) 战斗锁定（永不机密）
        local lockdown = (_G.InCombatLockdown and _G.InCombatLockdown() == true) == true
        addCond("combatLockdown", "战斗锁定 InCombatLockdown", tostring(lockdown), false, lockdown, lockdown and "战斗中" or "脱战")

        -- 4) 副本判定
        local inInst, instType, instSec = IsInCombatInstance()
        local instDisabled = db.disableInInstance ~= false
        local instBlocked = instDisabled and inInst
        addCond("instanceInfo", "副本判定 GetInstanceInfo",
            "type=" .. tostring(instType) .. ", disableInInstance=" .. tostring(instDisabled),
            instSec, instBlocked,
            instBlocked and "副本内已禁用淡隐" or (inInst and "副本内(允许淡隐)" or "野外/主城"))

        -- 5) UnitAffectingCombat("player")
        local uacRaw, uacSec, uacBlocked, uacNote = "unavailable", false, false, "API不可用"
        if type(_G.UnitAffectingCombat) == "function" then
            local ok, val = pcall(_G.UnitAffectingCombat, "player")
            if not ok then
                uacRaw = "<pcall_err>"
                uacBlocked = inInst
                uacNote = inInst and "副本内调用失败→保守拦截" or "调用失败→信任InCombatLockdown"
            elseif F.IsSecret(val) then
                uacRaw = "<secret>"
                uacSec = true
                uacBlocked = inInst
                uacNote = inInst and "副本内机密→保守拦截(P3-25)" or "野外机密→跳过(以InCombatLockdown为准)"
            else
                uacRaw = tostring(val == true)
                uacBlocked = (val == true)
                uacNote = uacBlocked and "单位处于战斗状态" or "非战斗"
            end
        end
        addCond("unitCombat", "单位战斗 UnitAffectingCombat", uacRaw, uacSec, uacBlocked, uacNote)

        -- 6) 首领战
        local encRaw, encSec, encBlocked, encNote = "false", false, false, "非首领战"
        if _G.C_InstanceEncounter and type(_G.C_InstanceEncounter.IsEncounterInProgress) == "function" then
            local ok, val = pcall(_G.C_InstanceEncounter.IsEncounterInProgress)
            if not ok then
                encRaw = "<pcall_err>"
                encNote = "调用失败→跳过"
            elseif F.IsSecret(val) then
                encRaw = "<secret>"
                encSec = true
                encNote = "机密→跳过"
            else
                encRaw = tostring(val == true)
                encBlocked = (val == true)
                encNote = encBlocked and "首领战进行中" or "非首领战"
            end
        end
        addCond("encounter", "首领战 IsEncounterInProgress", encRaw, encSec, encBlocked, encNote)

        -- 7) 当前目标 UnitExists("target")
        local tgtRaw, tgtSec, tgtBlocked, tgtNote = "unavailable", false, false, "API不可用"
        if type(_G.UnitExists) == "function" then
            local ok, val = pcall(_G.UnitExists, "target")
            if not ok then
                tgtRaw = "<pcall_err>"
                tgtNote = "调用失败→跳过"
            elseif F.IsSecret(val) then
                tgtRaw = "<secret>"
                tgtSec = true
                tgtNote = "机密→跳过"
            else
                tgtRaw = tostring(val == true)
                tgtBlocked = (val == true)
                tgtNote = tgtBlocked and "存在目标" or "无目标"
            end
        end
        addCond("hasTarget", "当前目标 UnitExists(target)", tgtRaw, tgtSec, tgtBlocked, tgtNote)

        -- 8) 玩家施法 / 引导
        local isCast, castSec = SafeHasCast(_G.UnitCastingInfo, "player")
        addCond("casting", "玩家施法 UnitCastingInfo", tostring(isCast), castSec, isCast, isCast and "正在施法" or "空闲")
        local isChan, chanSec = SafeHasCast(_G.UnitChannelInfo, "player")
        addCond("channeling", "玩家引导 UnitChannelInfo", tostring(isChan), chanSec, isChan, isChan and "正在引导" or "空闲")

        -- 9) 大地图
        local mapOpen = (_G.WorldMapFrame and SafeBoolCall(_G.WorldMapFrame.IsShown, _G.WorldMapFrame)) == true
        addCond("worldMap", "世界地图 WorldMapFrame", tostring(mapOpen), false, mapOpen, mapOpen and "大地图已打开" or "未打开")

        -- 10) 玩家血量
        local hpThr = db.hpThreshold or 95
        local hpRaw, hpSec, hpBlocked, hpNote = "unavailable", false, false, "API不可用"
        if _G.UnitHealth and _G.UnitHealthMax then
            local okH, rawHp = pcall(_G.UnitHealth, "player")
            local okM, rawMax = pcall(_G.UnitHealthMax, "player")
            if not okH or not okM then
                hpRaw = "<pcall_err>"
                hpNote = "调用失败→跳过"
            elseif F.IsSecret(rawHp) or F.IsSecret(rawMax) then
                hpRaw = (F.IsSecret(rawHp) and "<secret>" or tostring(rawHp))
                    .. "/" .. (F.IsSecret(rawMax) and "<secret>" or tostring(rawMax))
                hpSec = true
                hpNote = "机密→跳过"
            else
                local hp = F.PlainNumber(rawHp, nil)
                local hpMax = F.PlainNumber(rawMax, nil)
                if hp and hpMax and hpMax > 0 then
                    local pct = hp / hpMax * 100
                    hpRaw = tostring(math_floor(hp)) .. "/" .. tostring(math_floor(hpMax))
                        .. " (" .. tostring(math_floor(pct + 0.5)) .. "%)"
                    hpBlocked = pct < hpThr
                    hpNote = hpBlocked and ("低于阈值 " .. tostring(hpThr) .. "%") or ("达标 >=" .. tostring(hpThr) .. "%")
                else
                    hpRaw = tostring(rawHp) .. "/" .. tostring(rawMax)
                    hpNote = "无有效上限→跳过"
                end
            end
        end
        addCond("vitalHealth", "玩家血量 UnitHealth", hpRaw, hpSec, hpBlocked, hpNote)

        -- 11) 玩家能量
        local mpThr = db.powerThreshold or 85
        local mpRaw, mpSec, mpBlocked, mpNote = "unavailable", false, false, "API不可用"
        if _G.UnitPowerType then
            local okPT, rawPT = pcall(_G.UnitPowerType, "player")
            if not okPT then
                mpRaw = "pType=<pcall_err>"
                mpNote = "能量类型读取失败→跳过"
            elseif F.IsSecret(rawPT) then
                mpRaw = "pType=<secret>"
                mpSec = true
                mpNote = "能量类型机密→跳过"
            else
                local pType = F.PlainNumber(rawPT, nil)
                if pType ~= 0 then
                    mpRaw = "pType=" .. tostring(pType) .. " (非蓝条)"
                    mpNote = "非蓝条职业免检"
                elseif _G.UnitPower and _G.UnitPowerMax then
                    local okP, rawMp = pcall(_G.UnitPower, "player", 0)
                    local okPM, rawMpMax = pcall(_G.UnitPowerMax, "player", 0)
                    if not okP or not okPM then
                        mpRaw = "MANA <pcall_err>"
                        mpNote = "蓝量读取失败→跳过"
                    elseif F.IsSecret(rawMp) or F.IsSecret(rawMpMax) then
                        mpRaw = "MANA " .. (F.IsSecret(rawMp) and "<secret>" or tostring(rawMp))
                            .. "/" .. (F.IsSecret(rawMpMax) and "<secret>" or tostring(rawMpMax))
                        mpSec = true
                        mpNote = "蓝量机密→跳过"
                    else
                        local mp = F.PlainNumber(rawMp, nil)
                        local mpMax = F.PlainNumber(rawMpMax, nil)
                        if mp and mpMax and mpMax > 0 then
                            local pct = mp / mpMax * 100
                            mpRaw = "MANA " .. tostring(math_floor(mp)) .. "/" .. tostring(math_floor(mpMax))
                                .. " (" .. tostring(math_floor(pct + 0.5)) .. "%)"
                            mpBlocked = pct < mpThr
                            mpNote = mpBlocked and ("低于阈值 " .. tostring(mpThr) .. "%") or ("达标 >=" .. tostring(mpThr) .. "%")
                        else
                            mpRaw = "MANA " .. tostring(rawMp) .. "/" .. tostring(rawMpMax)
                            mpNote = "无有效蓝上限→跳过"
                        end
                    end
                end
            end
        end
        addCond("vitalPower", "玩家能量 UnitPower", mpRaw, mpSec, mpBlocked, mpNote)

        local managedList = {}
        for f in pairs(managed) do
            if f and not (f.IsForbidden and f:IsForbidden()) then
                local nm = (f.GetName and F.PlainString(f:GetName(), nil)) or "<anon>"
                local curA = f.GetAlpha and F.PlainNumber(f:GetAlpha(), nil) or nil
                managedList[#managedList + 1] = {
                    name = nm,
                    alpha = curA,
                    desired = desiredAlpha[f],
                    rest = restAlpha[f] or 1.0,
                    over = SafeIsMouseOver(f),
                }
            end
        end

        return {
            enabled = self:IsEnabled(),
            active = mod._active == true,
            isImmersiveNow = isImmersiveNow == true,
            idleAlpha = db.idleAlpha or 0.28,
            disableInInstance = instDisabled,
            shouldImmerse = #blockers == 0,
            blockedBy = blockers[1],
            blockers = blockers,
            conditions = conds,
            managedCount = #managedList,
            managedFrames = managedList,
        }
    end

    function mod:PrintFadeWhy()
        local info = self:InspectFadeState()
        local verdict = info.shouldImmerse
            and "|cff52d669允许淡隐|r"
            or ("|cffff5555被挡住(" .. table.concat(info.blockers, ", ") .. ")|r")
        F.Print("脱战淡隐诊断（只读）：总开关=" .. (info.enabled and "|cff52d669开|r" or "|cff888888关|r")
            .. " | 激活=" .. tostring(info.active)
            .. " | 当前淡隐态=" .. tostring(info.isImmersiveNow)
            .. " | 目标透明度=" .. tostring(info.idleAlpha)
            .. " | 已接管框体=" .. tostring(info.managedCount)
            .. " | 判定=" .. verdict)
        for _, c in ipairs(info.conditions) do
            local tag
            if c.blocked then
                tag = "|cffff5555[挡住]|r"
            elseif c.secret then
                tag = "|cffffd166[机密·跳过]|r"
            else
                tag = "|cff52d669[通过]|r"
            end
            _G.print("  " .. tag .. " " .. c.label .. " = " .. tostring(c.raw)
                .. (c.secret and " (secret=true)" or " (secret=false)")
                .. (c.note ~= "" and (" — " .. c.note) or ""))
        end
        if info.managedCount > 0 then
            local parts = {}
            local lim = math_min(info.managedCount, 8)
            for i = 1, lim do
                local m = info.managedFrames[i]
                local aStr = m.alpha and string.format("%.2f", m.alpha) or "?"
                local dStr = m.desired and string.format("%.2f", m.desired) or "-"
                parts[#parts + 1] = m.name .. "(" .. aStr .. "→" .. dStr .. (m.over and ",悬停" or "") .. ")"
            end
            _G.print("  |cffdca77f已接管框体|r：" .. table.concat(parts, ", ")
                .. (info.managedCount > lim and (" ...共" .. tostring(info.managedCount) .. "个") or ""))
        end
        return info
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
        chatWatchToken = chatWatchToken + 1
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
        enableSlot.text = "启用"
        enableSlot.tooltip = "统一控制动作条、双翼、伤害统计与系统栏的脱战淡隐（/kk hud）。"
        _, h = W:DualRow(parent, y, enableSlot, {
            type = "slider",
            text = "淡隐透明度",
            tooltip = "脱战无目标时的可见度，鼠标移到框体上立即恢复清晰。",
            min = 0.0, max = 0.75, step = 0.05,
            disabled = function() return not mod:IsEnabled() end,
            getValue = function() return db.idleAlpha or 0.28 end,
            setValue = function(v) db.idleAlpha = v; RefreshAlphas(false) end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "副本内禁用淡隐",
            tooltip = "进入地下城、团队副本或战场时保持全部界面清晰显示。",
            getValue = function() return db.disableInInstance ~= false end,
            setValue = function(v) db.disableInInstance = v == true; RefreshAlphas(false) end,
        }, Toggle("fadeCoreHUD", "淡隐双翼与宠物",
            "按统一透明度与条件淡化核心双翼与宠物条。"))
        y = y - h

        _, h = W:DualRow(parent, y,
            Toggle("chatQuickFade", "聊天框快速淡隐",
                "鼠标移开聊天框且未输入时快速淡出，需开启 EUI 聊天闲置淡隐。"), {
            type = "slider",
            text = "移开延迟 (秒)",
            min = 0.5, max = 5, step = 0.5,
            disabled = function() return not mod:IsEnabled() or db.chatQuickFade == false end,
            getValue = function() return F.PlainNumber(db.chatLeaveDelay, 1.5) or 1.5 end,
            setValue = function(v) db.chatLeaveDelay = v end,
        })
        y = y - h

        local function buildAdv(w, p, curY, blk)
            local _, rh
            _, rh = w:DualRow(p, curY,
                Toggle("fadeActionBars", "淡隐动作条",
                    "包含主动作条、姿态条与宠物条，尊重 EUI 自身的悬停设置。"),
                Toggle("fadeCooldowns", "淡隐冷却管理器"))
            curY = curY - rh

            _, rh = w:DualRow(p, curY,
                Toggle("fadeStats", "淡隐属性耐久"),
                Toggle("fadeDamageMeter", "淡隐伤害统计"))
            curY = curY - rh

            _, rh = w:DualRow(p, curY,
                Toggle("fadeTimers", "淡隐武器计时条"),
                Toggle("fadeQuestTracker", "淡隐任务追踪栏"))
            curY = curY - rh

            _, rh = w:DualRow(p, curY,
                Toggle("fadeSystemBar", "淡隐系统栏"),
                {
                    type = "toggle",
                    text = "淡化经验与小图",
                    getValue = function() return db.fadeXPBar == true end,
                    setValue = function(v) db.fadeXPBar = v == true; db.fadeMinimap = v == true; RefreshAlphas(false) end,
                })
            curY = curY - rh
            return curY
        end
        if type(F.BuildAdvancedSection) == "function" then
            y = F.BuildAdvancedSection("immersiveHUD", W, parent, y, buildAdv, blank)
        else
            y = buildAdv(W, parent, y, blank)
        end
        return y
    end
end

----------------------------------------------------------------------
--  模块 2：perfAutoTier — 场景稳帧 + 副本战斗安静模式
----------------------------------------------------------------------
do
    local pMod = F.RegisterModule("perfAutoTier", {
        title = "场景稳帧",
        desc = "主城或大型团本自动调低非必要特效稳帧，离开后自动还原。",
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
                    F.PrintOnce("perf_fps_guard", "|cff5fd3a6已触发低帧保护|r：临时调低部分特效，离开拥挤区自动恢复。")
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
            text = "副本战屏蔽公屏",
            tooltip = "副本战斗中临时隐藏综合与交易频道，不影响小队与团队聊天。",
            getValue = function() return db.quietInstanceChat ~= false end,
            setValue = function(v) db.quietInstanceChat = v == true end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "主城自动稳帧",
            tooltip = "进入主城或休整区自动调低天气与冗余法术粒子，离开自动恢复。",
            getValue = function() return db.autoCityTier ~= false end,
            setValue = function(v) db.autoCityTier = v == true; ApplyTier() end,
        }, {
            type = "toggle",
            text = "大型团本稳帧",
            tooltip = "进入团本或大型团队时自动调低非必要特效，不触发黑屏重载。",
            getValue = function() return db.autoRaidTier ~= false end,
            setValue = function(v) db.autoRaidTier = v == true; ApplyTier() end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "持续低帧保护",
            tooltip = "脱战检测到帧率持续偏低时自动调低天气与杂项粒子。",
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
            text = "锁定强力稳帧",
            tooltip = "手动保持团本级特效精简（/kk boost 切换）。",
            getValue = function() return db.forceBoost == true end,
            setValue = function(v) db.forceBoost = v == true; ApplyTier() end,
        })
        y = y - h
        return y
    end
end
