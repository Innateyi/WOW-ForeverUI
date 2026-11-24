----------------------------------------------------------------------
--  ForeverUI — Modules/SystemBar.lua
--  6 合 1 现代极简底部一体化系统栏（整合替代 QFXSystemBar×5 + EllesmereUIDataBars）
--    • 左侧：10 枚职业色极简矢量图标（全 SecureActionButtonTemplate 零污染转发，
--      含好友/公会实时在线角标 + 一键炉石冷却指示 + 右键系统钮直达 /fui）
--    • 右侧：大字时钟 + FPS（悬停看内存排行/点击 GC）+ 延迟 ms（悬停看带宽/背包/金币）
--    • 零 OnUpdate、仅 1 个 2 秒轻量计时器；支持 GameIcons / Lucide 双矢量图标集
--    • 检测到 QFXSystemBar 仍启用时自动让位，停用 QFX 后无缝接管
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_min, pairs, pcall, tostring, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, tostring, type
local table_sort = table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("systemBar", {
    title = "一体化系统微菜单栏",
    desc = "将微菜单图标、好友/公会在线角标、一键炉石与时钟/FPS/延迟融为一条零污染极简栏（替代 QFXSystemBar×5 + EUI DataBars）。",
    group = "theme",
    order = 20,
    yieldIfLoaded = "QFXSystemBar",
    defaults = {
        enabled = true,
        iconStyle = "gameicons",   -- "gameicons" | "lucide"
        iconSize = 20,
        iconSpacing = 8,
        showBackdrop = false,      -- 默认无框透明悬浮（与现代透明 HUD 一致），可开暗色玻璃托底
        showTelemetry = true,      -- 显示右侧 时钟 / FPS / 延迟
        showSocialGuild = false,   -- 默认隐藏好友/公会（与小地图顶部社交入口去重，可按需开启）
        showBadges = true,         -- 未分配天赋/传承点数角标与炉石冷却
        replaceMicroAlerts = true, -- 隐藏暴雪黄色微菜单气泡，改由屏幕中上方现代轻提示单次提醒
        showHearthstone = true,    -- 一键炉石
        combatFade = false,        -- 战斗淡出（底部居中常不遮挡，默认关，可自由开）
        v2HideRedundantSocial = false,
        v3NoCombatFadeMigrated = false,
    },
})

local ICON_DIRS = {
    gameicons = F.MEDIA .. "SystemBar\\GameIcons\\",
    lucide    = F.MEDIA .. "SystemBar\\Lucide\\",
}

local BUTTON_DEFS = {
    { id = "Character",   file = "Character.blp",    label = "角色面板",     native = "CharacterMicroButton",    bindings = { "TOGGLECHARACTER0" } },
    { id = "Social",      file = "Social.blp",       label = "好友与社交",   native = "QuickJoinToastButton",    badge = "friends", socialGroup = true, bindings = { "TOGGLESOCIAL" } },
    { id = "Profession",  file = "Profession.blp",   label = "专业技能",     native = "ProfessionMicroButton",   bindings = { "TOGGLEPROFESSIONBOOK" } },
    { id = "PlayerSpells",file = "PlayerSpells.blp", label = "天赋与法术",   native = "TalentMicroButton",       fallback = "PlayerSpellsMicroButton", badge = "talents", bindings = { "TOGGLETALENTS", "TOGGLESPELLBOOK" } },
    { id = "Legacy",      file = "Achievement.blp",  label = "传承与成就",   native = "LegacyMicroButton",       fallback = "AchievementMicroButton",  badge = "legacy",  bindings = { "TOGGLEACHIEVEMENT" } },
    { id = "Guild",       file = "Guild.blp",        label = "公会与社区",   native = "GuildMicroButton",        badge = "guild", socialGroup = true, bindings = { "TOGGLEGUILDTAB" } },
    { id = "LFD",         file = "LFD.blp",          label = "队伍查找器",   native = "LFDMicroButton",          bindings = { "TOGGLEGROUPFINDER", "TOGGLELFGPARENT" } },
    { id = "Collections", file = "Collections.blp",  label = "收藏与坐骑",   native = "CollectionsMicroButton",  bindings = { "TOGGLECOLLECTIONS", "TOGGLECOLLECTIONSMOUNTJOURNAL" } },
    { id = "Hearthstone", file = "Hearthstone.blp",  label = "炉石",         hearthstone = true },
    { id = "MainMenu",    file = "MainMenu.blp",     label = "系统菜单",     mainMenu = true, rightFUI = true,   bindings = { "TOGGLEGAMEMENU" } },
}

local MICRO_ALERT_OWNER_MAP = {
    TalentMicroButton       = "PlayerSpells",
    PlayerSpellsMicroButton = "PlayerSpells",
    CharacterMicroButton    = "Character",
    ProfessionMicroButton   = "Profession",
    LegacyMicroButton       = "Legacy",
    AchievementMicroButton  = "Legacy",
    CollectionsMicroButton  = "Collections",
    LFDMicroButton          = "LFD",
    GuildMicroButton        = "Guild",
    EJMicroButton           = "Legacy",
    QuestLogMicroButton     = "Character",
    MainMenuMicroButton     = "MainMenu",
    MicroMenu               = "PlayerSpells",
    MicroMenuContainer      = "PlayerSpells",
    MicroButtonAndBagsBar   = "PlayerSpells",
}

local barFrame = nil
local iconButtons = {}
local dividerTex = nil
local clockBtn, clockFS
local perfBtn, fpsFS, msFS
local ticker = nil
-- 角标（天赋/传承/好友/公会）均由事件驱动刷新；2 秒遥测心跳里只在炉石冷却倒计时期间逐拍刷新，其余 30 秒兜底一次
local hsCooling = false
local badgeTick = 0
local barDragging = false
local updateFade = nil
local alertBanner = nil
local alertBannerAG = nil
local alertHooksInstalled = false
local shownAlertKeys = {}
local lastNotifiedTalents = 0
local lastNotifiedLegacy = 0

local function ResolveNativeButton(def)
    if def.native and _G[def.native] then
        return _G[def.native]
    end
    if def.fallback and _G[def.fallback] then
        return _G[def.fallback]
    end
    return nil
end

local function FormatBindingKey(rawKey)
    if type(rawKey) ~= "string" or rawKey == "" then return nil end
    local s = rawKey
    s = s:gsub("SHIFT%-", "Shift+")
    s = s:gsub("CTRL%-", "Ctrl+")
    s = s:gsub("ALT%-", "Alt+")
    s = s:gsub("ESCAPE", "ESC")
    s = s:gsub("SPACE", "Space")
    s = s:gsub("NUMPAD", "Num")
    s = s:gsub("BUTTON3", "中键")
    s = s:gsub("BUTTON(%d+)", "M%1")
    return s
end

local function ResolveButtonKeybind(def)
    if not (_G.GetBindingKey and def) then return nil end
    local target = ResolveNativeButton(def)
    if target and type(target.commandName) == "string" and target.commandName ~= "" then
        local ok, key = pcall(_G.GetBindingKey, target.commandName)
        if ok and type(key) == "string" and key ~= "" then
            return FormatBindingKey(key)
        end
    end
    if type(def.bindings) == "table" then
        for _, cmd in ipairs(def.bindings) do
            local ok, key = pcall(_G.GetBindingKey, cmd)
            if ok and type(key) == "string" and key ~= "" then
                return FormatBindingKey(key)
            end
        end
    end
    return nil
end

local function GetOnlineFriendsCount()
    local total = 0
    if _G.C_FriendList and _G.C_FriendList.GetNumOnlineFriends then
        local ok, n = pcall(_G.C_FriendList.GetNumOnlineFriends)
        if ok and type(n) == "number" then total = total + n end
    end
    if _G.BNGetNumFriends then
        local ok, _, online = pcall(_G.BNGetNumFriends)
        if ok and type(online) == "number" then total = total + online end
    end
    return total
end

local function GetOnlineGuildCount()
    if not (_G.IsInGuild and _G.IsInGuild()) then return 0 end
    if _G.GetNumGuildMembers then
        local ok, _, online, mobile = pcall(_G.GetNumGuildMembers)
        if ok then
            local n = (type(online) == "number" and online or 0) + (type(mobile) == "number" and mobile or 0)
            return math_max(0, n)
        end
    end
    return 0
end

local function GetUnspentTalentPoints()
    local total = 0
    local CT = _G.C_Traits
    local CCT = _G.C_ClassTalents
    if CT and CT.GetConfigInfo and CT.GetTreeCurrencyInfo then
        local configID = nil
        if CCT and CCT.GetActiveConfigID then
            local okA, cid = pcall(CCT.GetActiveConfigID)
            if okA then configID = F.PlainNumber(cid, nil) end
        end
        if not configID and CT.GetConfigsByType and _G.Enum and _G.Enum.TraitConfigType then
            local okL, cfgs = pcall(CT.GetConfigsByType, _G.Enum.TraitConfigType.Combat)
            if okL and type(cfgs) == "table" and cfgs[1] then
                configID = F.PlainNumber(cfgs[1], nil)
            end
        end
        if configID then
            local okCfg, cfg = pcall(CT.GetConfigInfo, configID)
            if okCfg and type(cfg) == "table" and type(cfg.treeIDs) == "table" then
                for _, treeID in ipairs(cfg.treeIDs) do
                    local okCur, list = pcall(CT.GetTreeCurrencyInfo, configID, treeID, false)
                    if okCur and type(list) == "table" then
                        for _, c in ipairs(list) do
                            local q = type(c) == "table" and F.PlainNumber(c.quantity, 0) or 0
                            if q > 0 then total = total + q end
                        end
                    end
                end
            end
        end
    end
    if total <= 0 and CCT then
        local hasT, hasH = false, false
        if CCT.HasUnspentTalentPoints then
            local okT, valT = pcall(CCT.HasUnspentTalentPoints)
            hasT = (okT and valT == true)
        end
        if CCT.HasUnspentHeroTalentPoints then
            local okH, valH = pcall(CCT.HasUnspentHeroTalentPoints)
            hasH = (okH and valH == true)
        end
        if hasT or hasH then
            total = 1
        end
    end
    if total <= 0 and _G.UnitCharacterPoints then
        local okP, pts = pcall(_G.UnitCharacterPoints, "player")
        local n = okP and F.PlainNumber(pts, 0) or 0
        if n > 0 then total = n end
    end
    return total
end

local function GetUnspentLegacyPoints()
    local LC = _G.Constants and _G.Constants.LegacyConsts
    local CMF = _G.C_MajorFactions
    local CT = _G.C_Traits
    if not (LC and CMF and CT and CMF.GetCurrentRenownLevel and CT.GetConfigIDByTreeID and CT.GetTreeCurrencyInfo) then
        return 0
    end
    local okR, renown = pcall(CMF.GetCurrentRenownLevel, LC.LEGACY_REWARD_TRACK_FACTION_ID)
    if not (okR and F.PlainNumber(renown, 0) > 0) then return 0 end
    local treeID = LC.LEGACY_TREE_PROFESSIONS_ID
    local okC, configID = pcall(CT.GetConfigIDByTreeID, treeID)
    if not (okC and configID) then return 0 end
    local okI, infos = pcall(CT.GetTreeCurrencyInfo, configID, treeID, false)
    local info = okI and type(infos) == "table" and infos[1]
    return info and F.PlainNumber(info.quantity, 0) or 0
end

local function FindButtonDefById(btnId)
    for _, def in ipairs(BUTTON_DEFS) do
        if def.id == btnId then return def end
    end
    return nil
end

local function EnsureMicroAlertBanner()
    if alertBanner then return alertBanner end
    local f = CreateFrame("Button", "ForeverUI_MicroAlertBanner", _G.UIParent)
    f:SetSize(280, 34)
    f:SetPoint("TOP", _G.UIParent, "TOP", 0, -135)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(90)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetAlpha(0)
    f:Hide()

    -- 与 ForeverUI 统一的烟熏半透明玻璃底板 + 1px 柔和边框 + 顶部 2px 主题光带
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    bg:SetAllPoints()
    bg:SetColorTexture(0.048, 0.055, 0.078, 0.84)
    f._bg = bg

    local borders = {}
    local specs = {
        { "TOPLEFT",     "TOPRIGHT",    0,  0, nil, 1 },
        { "BOTTOMLEFT",  "BOTTOMRIGHT", 0,  0, nil, 1 },
        { "TOPLEFT",     "BOTTOMLEFT",  0,  0, 1, nil },
        { "TOPRIGHT",    "BOTTOMRIGHT", 0,  0, 1, nil },
    }
    for i, sp in ipairs(specs) do
        local ln = f:CreateTexture(nil, "BORDER")
        ln:SetPoint(sp[1], f, sp[1], sp[3], sp[4])
        ln:SetPoint(sp[2], f, sp[2], sp[3], sp[4])
        if sp[5] then ln:SetWidth(sp[5]) end
        if sp[6] then ln:SetHeight(sp[6]) end
        ln:SetColorTexture(1, 1, 1, 0.12)
        borders[i] = ln
    end
    f._borders = borders

    local topBar = f:CreateTexture(nil, "OVERLAY", nil, 2)
    topBar:SetHeight(2)
    topBar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    topBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    f._topBar = topBar

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", f, "LEFT", 12, 0)
    f._icon = icon

    local msgFS = f:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(msgFS, 13, "", 0.98, 0.98, 1.00, 1)
    msgFS:SetPoint("LEFT", icon, "RIGHT", 9, 0)
    msgFS:SetJustifyH("LEFT")
    msgFS:SetWordWrap(false)
    f._msgFS = msgFS

    local hintFS = f:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(hintFS, 11, "", 0.68, 0.74, 0.84, 0.92)
    hintFS:SetPoint("LEFT", msgFS, "RIGHT", 12, 0)
    hintFS:SetJustifyH("RIGHT")
    hintFS:SetWordWrap(false)
    f._hintFS = hintFS

    -- C++ AnimationGroup 丝滑淡入 → 停留 3.4 秒 → 淡出消失（零 OnUpdate）
    local ag = f:CreateAnimationGroup()
    local fadeIn = ag:CreateAnimation("Alpha")
    fadeIn:SetOrder(1)
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.22)
    fadeIn:SetSmoothing("OUT")

    local hold = ag:CreateAnimation("Alpha")
    hold:SetOrder(2)
    hold:SetFromAlpha(1)
    hold:SetToAlpha(1)
    hold:SetDuration(3.40)

    local fadeOut = ag:CreateAnimation("Alpha")
    fadeOut:SetOrder(3)
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.45)
    fadeOut:SetSmoothing("IN")

    ag:SetScript("OnFinished", function()
        f:SetAlpha(0)
        f:Hide()
    end)

    f:SetScript("OnClick", function(self, mouseBtn)
        if alertBannerAG and alertBannerAG:IsPlaying() then
            alertBannerAG:Stop()
        end
        self:SetAlpha(0)
        self:Hide()
        if mouseBtn == "RightButton" then return end
        if _G.InCombatLockdown and _G.InCombatLockdown() then
            F.Print("战斗中无法直接打开面板，请脱战后按快捷键或点击底部导航栏。")
            return
        end
        local def = self._targetDef
        if def then
            local native = ResolveNativeButton(def)
            if native and native.Click then
                pcall(native.Click, native)
            elseif def.id == "PlayerSpells" then
                if _G.PlayerSpellsUtil and _G.PlayerSpellsUtil.ToggleClassTalentOrSpecFrame then
                    pcall(_G.PlayerSpellsUtil.ToggleClassTalentOrSpecFrame)
                elseif _G.ToggleTalentFrame then
                    pcall(_G.ToggleTalentFrame)
                end
            end
        end
    end)

    alertBanner = f
    alertBannerAG = ag
    return f
end

local function ShowMicroAlertOnce(dedupKey, message, btnId)
    if not (mod._active and mod:GetDB().replaceMicroAlerts ~= false) then return end
    if type(message) ~= "string" or message == "" then return end
    if dedupKey and shownAlertKeys[dedupKey] then return end
    if dedupKey then shownAlertKeys[dedupKey] = true end

    local f = EnsureMicroAlertBanner()
    local db = mod:GetDB()
    local def = FindButtonDefById(btnId or "PlayerSpells") or FindButtonDefById("PlayerSpells")
    local dir = ICON_DIRS[db.iconStyle or "gameicons"] or ICON_DIRS.gameicons
    local ar, ag, ab = F.Theme.GetAccent()
    local isPointAlert = (btnId == "PlayerSpells" or btnId == "Legacy")
    local barR, barG, barB = isPointAlert and 0.96 or ar, isPointAlert and 0.78 or ag, isPointAlert and 0.34 or ab

    f._targetDef = def
    f._topBar:SetColorTexture(barR, barG, barB, 0.95)
    f._icon:SetTexture(dir .. (def and def.file or "PlayerSpells.blp"))
    f._icon:SetVertexColor(barR, barG, barB, 1)

    F.Theme.ApplyFont(f._msgFS, 13, "", 0.98, 0.98, 1.00, 1)
    f._msgFS:SetText(message)

    local keyStr = def and ResolveButtonKeybind(def) or nil
    local hintStr = keyStr and ("点击打开 · " .. keyStr) or "点击打开"
    F.Theme.ApplyFont(f._hintFS, 11, "", barR, barG, barB, 0.92)
    f._hintFS:SetText(hintStr)

    local msgW = F.PlainNumber(f._msgFS:GetStringWidth(), 140)
    local hintW = F.PlainNumber(f._hintFS:GetStringWidth(), 50)
    f:SetWidth(math_max(210, math_floor(12 + 18 + 9 + msgW + 12 + hintW + 14)))

    if alertBannerAG:IsPlaying() then
        alertBannerAG:Stop()
    end
    f:SetAlpha(1)
    f:Show()
    alertBannerAG:Play()
end

local function ResolveMicroAlertButtonId(frame, text)
    local cur = frame
    for _ = 1, 3 do
        if not cur then break end
        if cur.GetName then
            local okN, nm = pcall(cur.GetName, cur)
            if okN and type(nm) == "string" and MICRO_ALERT_OWNER_MAP[nm] then
                return MICRO_ALERT_OWNER_MAP[nm]
            end
        end
        cur = cur.GetParent and cur:GetParent() or nil
    end
    if type(text) == "string" then
        if text:find("天赋", 1, true) or text:lower():find("talent", 1, true) then
            return "PlayerSpells"
        elseif text:find("传承", 1, true) or text:lower():find("legacy", 1, true) then
            return "Legacy"
        elseif text:find("收藏", 1, true) or text:lower():find("collection", 1, true) then
            return "Collections"
        end
    end
    return nil
end

local function SuppressBlizzardMicroHelpTips(triggerBanner)
    if not (mod._active and mod:GetDB().replaceMicroAlerts ~= false) then return end

    -- 1) 隐藏挂在微菜单按钮上的暴雪黄色 HelpTip 气泡（零污染：仅 Hide，绝不调用暴雪 Alert 状态函数）
    local HT = _G.HelpTip
    if HT and HT.framePool and HT.framePool.EnumerateActive then
        pcall(function()
            for tip in HT.framePool:EnumerateActive() do
                if tip and tip:IsShown() then
                    local info = tip.info
                    local rawTxt = info and F.PlainString(info.text, nil) or nil
                    local btnId = ResolveMicroAlertButtonId(tip.relativeRegion or tip:GetParent(), rawTxt)
                    if btnId then
                        tip:Hide()
                        if triggerBanner and rawTxt and rawTxt ~= "" then
                            if btnId == "PlayerSpells" then
                                local pts = GetUnspentTalentPoints()
                                local msg = pts > 0 and string_format("你有 %d 点未分配的天赋", pts) or rawTxt
                                ShowMicroAlertOnce("talent:" .. pts, msg, "PlayerSpells")
                            elseif btnId == "Legacy" then
                                local pts = GetUnspentLegacyPoints()
                                local msg = pts > 0 and string_format("你有 %d 点未分配的传承点数", pts) or rawTxt
                                ShowMicroAlertOnce("legacy:" .. pts, msg, "Legacy")
                            else
                                ShowMicroAlertOnce("msg:" .. rawTxt, rawTxt, btnId)
                            end
                        end
                    end
                end
            end
        end)
    end

    -- 2) 兜底隐藏经典版独立微菜单提醒框
    for _, globalName in ipairs({ "TalentMicroButtonAlert", "CollectionsMicroButtonAlert", "LFDMicroButtonAlert" }) do
        local af = _G[globalName]
        if af and af.IsShown and af:IsShown() then
            pcall(af.Hide, af)
        end
    end
end

local function InstallMicroAlertHooks()
    if alertHooksInstalled then return end
    alertHooksInstalled = true

    if _G.HelpTip and _G.HelpTip.Show then
        _G.hooksecurefunc(_G.HelpTip, "Show", function(_, parent, info, relativeRegion)
            if not (mod._active and mod:GetDB().replaceMicroAlerts ~= false) then return end
            local rawTxt = info and F.PlainString(info.text, nil) or nil
            local btnId = ResolveMicroAlertButtonId(relativeRegion or parent, rawTxt)
            if btnId then
                SuppressBlizzardMicroHelpTips(true)
            end
        end)
    end

    if type(_G.MainMenuMicroButton_ShowAlert) == "function" then
        _G.hooksecurefunc("MainMenuMicroButton_ShowAlert", function(microButton, text)
            if not (mod._active and mod:GetDB().replaceMicroAlerts ~= false) then return end
            local cleanTxt = F.PlainString(text, nil)
            local btnId = ResolveMicroAlertButtonId(microButton, cleanTxt)
            C_Timer.After(0, function()
                SuppressBlizzardMicroHelpTips(false)
            end)
            if btnId and cleanTxt and cleanTxt ~= "" then
                if btnId == "PlayerSpells" then
                    local pts = GetUnspentTalentPoints()
                    local msg = pts > 0 and string_format("你有 %d 点未分配的天赋", pts) or cleanTxt
                    ShowMicroAlertOnce("talent:" .. pts, msg, "PlayerSpells")
                elseif btnId == "Legacy" then
                    local pts = GetUnspentLegacyPoints()
                    local msg = pts > 0 and string_format("你有 %d 点未分配的传承点数", pts) or cleanTxt
                    ShowMicroAlertOnce("legacy:" .. pts, msg, "Legacy")
                else
                    ShowMicroAlertOnce("msg:" .. cleanTxt, cleanTxt, btnId)
                end
            end
        end)
    end
end

local function GetHearthstoneCooldown()
    local start, dur
    if _G.C_Container and _G.C_Container.GetItemCooldown then
        start, dur = _G.C_Container.GetItemCooldown(6948)
    elseif _G.GetItemCooldown then
        start, dur = _G.GetItemCooldown(6948)
    end
    start = F.PlainNumber(start, 0)
    dur = F.PlainNumber(dur, 0)
    if start > 0 and dur > 1.5 then
        local rem = (start + dur) - GetTime()
        if rem > 0 then return rem end
    end
    return 0
end

local function GetFreeBagSlots()
    local C = _G.C_Container
    if not (C and C.GetContainerNumFreeSlots) then return 0, 0 end
    local free, total = 0, 0
    for bag = 0, 4 do
        local n, bagType = C.GetContainerNumFreeSlots(bag)
        if bagType == 0 then
            free = free + (n or 0)
            total = total + (C.GetContainerNumSlots and C.GetContainerNumSlots(bag) or 0)
        end
    end
    return free, total
end

local function ShowTopAddonsMemory()
    -- 12.x / 16001 已移除全局 GetNumAddOns / GetAddOnInfo，只剩 C_AddOns.*：先解析函数再判断，旧写法会直接 return 导致内存榜永远不显示
    local CA = _G.C_AddOns
    local getNum = (CA and CA.GetNumAddOns) or _G.GetNumAddOns
    local isLoadedFn = (CA and CA.IsAddOnLoaded) or _G.IsAddOnLoaded
    local infoFn = (CA and CA.GetAddOnInfo) or _G.GetAddOnInfo
    if not (getNum and isLoadedFn and infoFn and _G.GetAddOnMemoryUsage) then return end
    if _G.UpdateAddOnMemoryUsage then pcall(_G.UpdateAddOnMemoryUsage) end
    local list = {}
    local totalKB = 0
    local num = F.PlainNumber(getNum(), 0)
    for i = 1, num do
        if isLoadedFn(i) then
            local kb = _G.GetAddOnMemoryUsage(i) or 0
            totalKB = totalKB + kb
            if kb > 10 then
                local name = infoFn(i)
                list[#list + 1] = { name = name or ("#" .. i), kb = kb }
            end
        end
    end
    table_sort(list, function(a, b) return a.kb > b.kb end)
    GameTooltip:AddDoubleLine("插件总内存", string_format("%.1f MB", totalKB / 1024), 0.72, 0.75, 0.80, 1, 1, 1)
    GameTooltip:AddLine(" ")
    for i = 1, math_min(8, #list) do
        local it = list[i]
        local valStr = it.kb >= 1024 and string_format("%.1f MB", it.kb / 1024) or string_format("%d KB", math_floor(it.kb))
        GameTooltip:AddDoubleLine(it.name, valStr, 0.84, 0.86, 0.90, 0.92, 0.85, 0.60)
    end
end

local function UpdateBadges(allowNotify)
    if not barFrame then return end
    local db = mod:GetDB()
    local showBadges = db.showBadges ~= false
    local friends = (showBadges and db.showSocialGuild == true) and GetOnlineFriendsCount() or 0
    local guild = (showBadges and db.showSocialGuild == true) and GetOnlineGuildCount() or 0
    local unspentTalents = GetUnspentTalentPoints()
    local unspentLegacy = GetUnspentLegacyPoints()
    local hsCD = GetHearthstoneCooldown()

    -- 点数归零后清除单次去重标记，下次升级获得新点数时会再次于屏幕中上方提醒一次
    if unspentTalents <= 0 then
        lastNotifiedTalents = 0
        for k in pairs(shownAlertKeys) do
            if type(k) == "string" and k:sub(1, 7) == "talent:" then
                shownAlertKeys[k] = nil
            end
        end
    elseif allowNotify == true and unspentTalents > lastNotifiedTalents then
        lastNotifiedTalents = unspentTalents
        ShowMicroAlertOnce("talent:" .. unspentTalents, string_format("你有 %d 点未分配的天赋", unspentTalents), "PlayerSpells")
    end

    if unspentLegacy <= 0 then
        lastNotifiedLegacy = 0
        for k in pairs(shownAlertKeys) do
            if type(k) == "string" and k:sub(1, 7) == "legacy:" then
                shownAlertKeys[k] = nil
            end
        end
    elseif allowNotify == true and unspentLegacy > lastNotifiedLegacy then
        lastNotifiedLegacy = unspentLegacy
        ShowMicroAlertOnce("legacy:" .. unspentLegacy, string_format("你有 %d 点未分配的传承点数", unspentLegacy), "Legacy")
    end

    for _, btn in ipairs(iconButtons) do
        if btn._def.badge == "friends" then
            if friends > 0 then
                btn._badge:SetTextColor(1, 1, 1, 1)
                btn._badge:SetText(tostring(friends))
                btn._badge:Show()
            else
                btn._badge:Hide()
            end
        elseif btn._def.badge == "guild" then
            if guild > 0 then
                btn._badge:SetTextColor(1, 1, 1, 1)
                btn._badge:SetText(tostring(guild))
                btn._badge:Show()
            else
                btn._badge:Hide()
            end
        elseif btn._def.badge == "talents" then
            if showBadges and unspentTalents > 0 then
                btn._badge:SetTextColor(0.98, 0.80, 0.32, 1)
                btn._badge:SetText(tostring(unspentTalents))
                btn._badge:Show()
            else
                btn._badge:Hide()
            end
        elseif btn._def.badge == "legacy" then
            if showBadges and unspentLegacy > 0 then
                btn._badge:SetTextColor(0.98, 0.80, 0.32, 1)
                btn._badge:SetText(tostring(unspentLegacy))
                btn._badge:Show()
            else
                btn._badge:Hide()
            end
        elseif btn._def.hearthstone then
            if hsCD > 0 then
                btn._icon:SetAlpha(0.45)
                if showBadges then
                    btn._badge:SetTextColor(1, 1, 1, 1)
                    btn._badge:SetText(hsCD >= 60 and (math_floor(hsCD / 60 + 0.5) .. "m") or (math_floor(hsCD) .. "s"))
                    btn._badge:Show()
                else
                    btn._badge:Hide()
                end
            else
                btn._icon:SetAlpha(0.92)
                btn._badge:Hide()
            end
        end
    end
    hsCooling = hsCD > 0
end

local LayoutBar

local function UpdateTelemetry()
    if not (barFrame and clockFS and fpsFS and msFS) then return end
    local db = mod:GetDB()
    if db.showTelemetry == false then
        if dividerTex then dividerTex:Hide() end
        clockBtn:Hide()
        perfBtn:Hide()
        return
    end

    local ar, ag, ab = F.Theme.GetAccent()
    local clockStr = _G.date and _G.date("%H:%M") or "--:--"
    clockFS:SetText(clockStr)
    clockFS:SetTextColor(ar, ag, ab, 0.98)

    local fps = math_floor((_G.GetFramerate and _G.GetFramerate() or 0) + 0.5)
    local fr, fg, fb = ar, ag, ab
    if fps > 0 and fps < 25 then
        fr, fg, fb = 0.92, 0.36, 0.42
    elseif fps > 0 and fps < 45 then
        fr, fg, fb = 0.94, 0.78, 0.34
    end
    fpsFS:SetText(string_format("%dfps", fps))
    fpsFS:SetTextColor(fr, fg, fb, 0.96)

    local homeMS, worldMS = 0, 0
    if _G.GetNetStats then
        local _, _, h, w = _G.GetNetStats()
        homeMS, worldMS = h or 0, w or 0
    end
    local ms = math_max(homeMS, worldMS)
    local mr, mg, mb = 0.92, 0.94, 0.96
    if ms >= 180 then
        mr, mg, mb = 0.92, 0.36, 0.42
    elseif ms >= 100 then
        mr, mg, mb = 0.94, 0.78, 0.34
    end
    msFS:SetText(string_format("%dms", ms))
    msFS:SetTextColor(mr, mg, mb, 0.96)

    -- 动态自适应 FPS/延迟宽度，防止帧数从 2 位数跳到 3 位数时文字挤压（战斗中顺延至脱战，避免触碰安全按钮保护）
    if perfBtn and perfBtn:IsShown() and LayoutBar then
        local fw = math_max(38, F.PlainNumber(fpsFS:GetStringWidth(), 38))
        local mw = math_max(36, F.PlainNumber(msFS:GetStringWidth(), 36))
        local needW = fw + 8 + mw + 2
        local curW = F.PlainNumber(perfBtn:GetWidth(), 0)
        if curW == 0 or needW > curW or (curW - needW) > 10 then
            if _G.InCombatLockdown and _G.InCombatLockdown() then
                F.RunOutOfCombat("FUI_SystemBarLayout", LayoutBar)
            else
                LayoutBar()
            end
        end
    end

    badgeTick = badgeTick + 1
    if hsCooling or badgeTick >= 15 then
        badgeTick = 0
        UpdateBadges()
    end
end

LayoutBar = function()
    -- 脱战队列可能在停用模块之后才冲刷：此时不再重排（也就不会把栏重新显示出来）
    if not (barFrame and mod._active) then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_SystemBarLayout", LayoutBar)
        return
    end
    local db = mod:GetDB()
    local sz = db.iconSize or 20
    local gap = db.iconSpacing or 8
    local padX = db.showBackdrop and 10 or 4
    local x = padX

    for _, btn in ipairs(iconButtons) do
        local visible = true
        if btn._def.socialGroup and db.showSocialGuild ~= true then
            visible = false
        elseif btn._def.hearthstone and db.showHearthstone == false then
            visible = false
        elseif btn._def.native and not ResolveNativeButton(btn._def) then
            visible = false
        end
        if visible then
            btn:SetSize(sz, sz)
            btn:ClearAllPoints()
            btn:SetPoint("LEFT", barFrame, "LEFT", x, 0)
            btn:Show()
            x = x + sz + gap
        else
            btn:Hide()
        end
    end

    if x > padX then
        x = x - gap -- 去掉最后一个图标的多余间距
    end

    if db.showTelemetry ~= false then
        x = x + 10
        dividerTex:ClearAllPoints()
        dividerTex:SetPoint("LEFT", barFrame, "LEFT", x, 0)
        dividerTex:Show()
        x = x + 11

        clockBtn:ClearAllPoints()
        clockBtn:SetPoint("LEFT", barFrame, "LEFT", x, 0)
        local cw = math_max(46, F.PlainNumber(clockFS:GetStringWidth(), 46) + 4)
        clockBtn:SetSize(cw, sz + 4)
        clockBtn:Show()
        x = x + cw + 8

        perfBtn:ClearAllPoints()
        perfBtn:SetPoint("LEFT", barFrame, "LEFT", x, 0)
        fpsFS:ClearAllPoints()
        -- HarmonyOS Sans 13px 字框含下部降部余量，视觉光学下移 1px 与图标及分隔线严格垂直居中
        fpsFS:SetPoint("LEFT", perfBtn, "LEFT", 0, -1)
        local fw = math_max(38, F.PlainNumber(fpsFS:GetStringWidth(), 38))
        msFS:ClearAllPoints()
        msFS:SetPoint("LEFT", fpsFS, "RIGHT", 8, 0)
        local mw = math_max(36, F.PlainNumber(msFS:GetStringWidth(), 36))
        perfBtn:SetSize(fw + 8 + mw + 2, sz + 4)
        perfBtn:Show()
        x = x + fw + 8 + mw
    else
        dividerTex:Hide()
        clockBtn:Hide()
        perfBtn:Hide()
    end

    barFrame:SetSize(math_max(120, x + padX), sz + (db.showBackdrop and 10 or 6))
end

local function ApplyVisuals()
    if not barFrame then return end
    local db = mod:GetDB()
    local ar, ag, ab = F.Theme.GetAccent()
    local dir = ICON_DIRS[db.iconStyle or "gameicons"] or ICON_DIRS.gameicons

    if db.showBackdrop then
        F.Theme.StylePanel(barFrame, 0.72, 0.55)
        if barFrame._fuiBg then barFrame._fuiBg:Show() end
        if barFrame._fuiBorders then
            for _, b in ipairs(barFrame._fuiBorders) do b:Show() end
        end
    else
        if barFrame._fuiBg then barFrame._fuiBg:Hide() end
        if barFrame._fuiBorders then
            for _, b in ipairs(barFrame._fuiBorders) do b:Hide() end
        end
    end

    if dividerTex then
        dividerTex:SetColorTexture(ar, ag, ab, 0.30)
    end

    for _, btn in ipairs(iconButtons) do
        btn._icon:SetTexture(dir .. btn._def.file, nil, nil, "TRILINEAR")
        btn._icon:SetVertexColor(ar, ag, ab, 1)
        btn._hoverBar:SetColorTexture(ar, ag, ab, 0.95)
        F.Theme.ApplyFont(btn._badge, 10, "OUTLINE", 1, 1, 1, 1)
    end

    F.Theme.ApplyFont(clockFS, 16, "", ar, ag, ab, 0.98)
    F.Theme.ApplyFont(fpsFS, 13, "", ar, ag, ab, 0.96)
    F.Theme.ApplyFont(msFS, 13, "", 0.92, 0.94, 0.96, 0.96)

    UpdateTelemetry()
    LayoutBar()
    if updateFade then
        updateFade(F.db and F.db.theme and F.db.theme.combatFadeAlpha or 0.18, 1.0)
    end
end

local function BindSecureButtons()
    F.RunOutOfCombat("FUI_SystemBarSecure", function()
        for _, btn in ipairs(iconButtons) do
            local def = btn._def
            if not def.mainMenu then
                -- 12.x / Forever 默认 ActionButtonUseKeyDown=1，必须显式关闭 useOnKeyDown
                -- 否则仅注册 LeftButtonUp/RightButtonUp 时 SecureActionButton_OnClick 会吞掉所有点击
                btn:SetAttribute("useOnKeyDown", false)
                if def.hearthstone then
                    btn:SetAttribute("type1", "macro")
                    btn:SetAttribute("macrotext1", "/use item:6948")
                    btn:EnableMouse(true)
                elseif def.native then
                    local target = ResolveNativeButton(def)
                    if target then
                        btn:SetAttribute("type1", "click")
                        btn:SetAttribute("clickbutton1", target)
                        btn:EnableMouse(true)
                    else
                        btn:SetAttribute("type1", nil)
                        btn:SetAttribute("clickbutton1", nil)
                    end
                end
            end
        end
    end)
end

local function CreateBar()
    if barFrame then return end

    barFrame = CreateFrame("Frame", "ForeverUI_SystemBar", _G.UIParent)
    barFrame:SetSize(420, 26)
    barFrame:SetFrameStrata("MEDIUM")
    barFrame:EnableMouse(true)

    for i, def in ipairs(BUTTON_DEFS) do
        local tpl = nil
        if not def.mainMenu then
            tpl = "SecureActionButtonTemplate"
        end
        local btn = CreateFrame("Button", "ForeverUI_SysBtn_" .. def.id, barFrame, tpl)
        if def.mainMenu then
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
        else
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn:SetAttribute("useOnKeyDown", false)
        end
        btn._def = def

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetAlpha(0.92)
        btn._icon = icon

        local hoverBar = btn:CreateTexture(nil, "OVERLAY")
        hoverBar:SetHeight(2)
        hoverBar:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 1, -2)
        hoverBar:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", -1, -2)
        hoverBar:Hide()
        btn._hoverBar = hoverBar

        local badge = btn:CreateFontString(nil, "OVERLAY")
        badge:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 3, -2)
        badge:Hide()
        btn._badge = badge

        if def.mainMenu then
            btn:SetScript("OnClick", function(_, mouseBtn)
                if mouseBtn == "RightButton" then
                    if _G.InCombatLockdown and _G.InCombatLockdown() then
                        F.Print("战斗中无法打开设置面板，请脱战后重试。")
                        return
                    end
                    local EUI = _G.EllesmereUI
                    if EUI and EUI.OpenPlugin then
                        pcall(EUI.OpenPlugin, F.NAME)
                    end
                elseif mouseBtn == "MiddleButton" then
                    if _G.InCombatLockdown and _G.InCombatLockdown() then
                        F.Print("战斗中无法打开插件列表，请脱战后重试。")
                        return
                    end
                    if _G.ToggleFrame and _G.AddonList then
                        pcall(_G.ToggleFrame, _G.AddonList)
                    end
                else
                    if _G.InCombatLockdown and _G.InCombatLockdown() then
                        F.Print("战斗中无法打开系统菜单，请脱战后重试。")
                        return
                    end
                    if _G.ToggleFrame and _G.GameMenuFrame then
                        pcall(_G.ToggleFrame, _G.GameMenuFrame)
                    elseif _G.ToggleGameMenu then
                        pcall(_G.ToggleGameMenu)
                    end
                end
            end)
        elseif def.rightFUI then
            btn:SetScript("PostClick", function(_, mouseBtn)
                if mouseBtn == "RightButton" then
                    local EUI = _G.EllesmereUI
                    if EUI and EUI.OpenPlugin then
                        pcall(EUI.OpenPlugin, F.NAME)
                    end
                end
            end)
        end

        btn:SetScript("OnEnter", function(self)
            local ar, ag, ab = F.Theme.GetAccent()
            self._icon:SetVertexColor(
                math_min(1, ar + 0.20),
                math_min(1, ag + 0.20),
                math_min(1, ab + 0.20),
                1
            )
            self._hoverBar:Show()
            GameTooltip:SetOwner(self, "ANCHOR_TOP", 0, 6)
            local keyStr = ResolveButtonKeybind(def)
            if keyStr then
                local hex = string_format("%02x%02x%02x",
                    math_floor(math_min(1, ar * 0.8 + 0.2) * 255 + 0.5),
                    math_floor(math_min(1, ag * 0.8 + 0.2) * 255 + 0.5),
                    math_floor(math_min(1, ab * 0.8 + 0.2) * 255 + 0.5))
                GameTooltip:AddLine(def.label .. " |cff" .. hex .. keyStr .. "|r", 1, 1, 1)
            else
                GameTooltip:AddLine(def.label, 1, 1, 1)
            end
            if def.badge == "friends" then
                GameTooltip:AddDoubleLine("在线好友", tostring(GetOnlineFriendsCount()), 0.72, 0.75, 0.80, ar, ag, ab)
            elseif def.badge == "guild" then
                local gName = _G.GetGuildInfo and _G.GetGuildInfo("player")
                if gName then
                    GameTooltip:AddDoubleLine(gName, "在线 " .. tostring(GetOnlineGuildCount()) .. " 人", 0.72, 0.75, 0.80, 0.42, 0.86, 0.50)
                else
                    GameTooltip:AddLine("尚未加入公会", 0.62, 0.65, 0.70)
                end
            elseif def.badge == "talents" then
                local pts = GetUnspentTalentPoints()
                if pts > 0 then
                    GameTooltip:AddDoubleLine("未分配天赋点数", tostring(pts), 0.72, 0.75, 0.80, 0.98, 0.80, 0.32)
                end
            elseif def.badge == "legacy" then
                local pts = GetUnspentLegacyPoints()
                if pts > 0 then
                    GameTooltip:AddDoubleLine("未分配传承点数", tostring(pts), 0.72, 0.75, 0.80, 0.98, 0.80, 0.32)
                end
            elseif def.hearthstone then
                local loc = _G.GetBindLocation and _G.GetBindLocation()
                if loc and loc ~= "" then
                    GameTooltip:AddDoubleLine("绑定旅店", loc, 0.72, 0.75, 0.80, 0.94, 0.82, 0.48)
                end
                local cd = GetHearthstoneCooldown()
                if cd > 0 then
                    GameTooltip:AddDoubleLine("剩余冷却", string_format("%d分 %d秒", math_floor(cd / 60), math_floor(cd % 60)), 0.72, 0.75, 0.80, 0.92, 0.45, 0.45)
                else
                    GameTooltip:AddLine("左键点击直接使用炉石", 0.37, 0.83, 0.65)
                end
            elseif def.rightFUI then
                GameTooltip:AddLine("左键：打开游戏系统菜单", 0.78, 0.80, 0.84)
                GameTooltip:AddLine("右键：打开 ForeverUI 设置 (/fui)", ar, ag, ab)
                GameTooltip:AddLine("中键：打开插件列表", 0.62, 0.66, 0.72)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            local ar, ag, ab = F.Theme.GetAccent()
            self._icon:SetVertexColor(ar, ag, ab, 1)
            self._hoverBar:Hide()
            GameTooltip:Hide()
        end)

        iconButtons[i] = btn
    end

    dividerTex = barFrame:CreateTexture(nil, "ARTWORK")
    dividerTex:SetSize(1, 14)

    -- 时钟区（支持 Shift+左键联动拖动整个系统栏）
    local function AttachBarDrag(sub)
        sub:RegisterForDrag("LeftButton")
        sub:SetScript("OnDragStart", function()
            if _G.IsShiftKeyDown and _G.IsShiftKeyDown() and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
                barDragging = true
                barFrame:StartMoving()
            end
        end)
        sub:SetScript("OnDragStop", function()
            if not barDragging then return end
            barDragging = false
            -- 栏内含安全按钮：战斗中 StopMovingOrSizing 会被拦截；进战时已在 PLAYER_REGEN_DISABLED 中结束拖动
            if _G.InCombatLockdown and _G.InCombatLockdown() then return end
            barFrame:StopMovingOrSizing()
            local pt, _, rpt, x, y = barFrame:GetPoint(1)
            F.DB.SavePosition("SystemBar", pt, rpt, x, y)
        end)
    end

    clockBtn = CreateFrame("Button", nil, barFrame)
    AttachBarDrag(clockBtn)
    clockFS = clockBtn:CreateFontString(nil, "OVERLAY")
    clockFS:SetJustifyV("MIDDLE")
    clockFS:SetPoint("CENTER", 0, 0)
    clockBtn:SetScript("OnClick", function()
        if _G.ToggleCalendar then
            pcall(_G.ToggleCalendar)
        elseif _G.TimeManager_Toggle then
            pcall(_G.TimeManager_Toggle)
        end
    end)
    clockBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP", 0, 6)
        GameTooltip:AddLine("时间与日程", 1, 1, 1)
        GameTooltip:AddDoubleLine("本地时间", _G.date and _G.date("%Y-%m-%d %H:%M") or "--", 0.72, 0.75, 0.80, 1, 1, 1)
        if _G.GetGameTime then
            local sh, sm = _G.GetGameTime()
            if sh and sm then
                GameTooltip:AddDoubleLine("服务器时间", string_format("%02d:%02d", sh, sm), 0.72, 0.75, 0.80, 0.94, 0.82, 0.48)
            end
        end
        GameTooltip:AddLine("左键点击打开日历 / 闹钟", 0.58, 0.62, 0.68)
        GameTooltip:AddLine("Shift + 左键拖动整个系统栏", 0.58, 0.62, 0.68)
        GameTooltip:Show()
    end)
    clockBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- FPS & 延迟区
    perfBtn = CreateFrame("Button", nil, barFrame)
    AttachBarDrag(perfBtn)
    fpsFS = perfBtn:CreateFontString(nil, "OVERLAY")
    fpsFS:SetJustifyV("MIDDLE")
    msFS  = perfBtn:CreateFontString(nil, "OVERLAY")
    msFS:SetJustifyV("MIDDLE")
    perfBtn:SetScript("OnClick", function()
        local before = _G.collectgarbage and _G.collectgarbage("count") or 0
        if _G.collectgarbage then _G.collectgarbage("collect") end
        local after = _G.collectgarbage and _G.collectgarbage("count") or 0
        local freed = math_max(0, before - after)
        F.Print(string_format("已完成内存清理，释放 %.1f MB。", freed / 1024))
        UpdateTelemetry()
    end)
    perfBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP", 0, 6)
        GameTooltip:AddLine("性能与背包概览", 1, 1, 1)
        if _G.GetNetStats then
            local bwIn, bwOut, homeMS, worldMS = _G.GetNetStats()
            GameTooltip:AddDoubleLine("本地 / 世界延迟", string_format("%d ms / %d ms", homeMS or 0, worldMS or 0), 0.72, 0.75, 0.80, 1, 1, 1)
            GameTooltip:AddDoubleLine("下载 / 上传速率", string_format("%.1f / %.1f KB/s", bwIn or 0, bwOut or 0), 0.72, 0.75, 0.80, 0.82, 0.85, 0.90)
        end
        local free, total = GetFreeBagSlots()
        GameTooltip:AddDoubleLine("背包空位", string_format("%d / %d", free, total), 0.72, 0.75, 0.80, 0.92, 0.94, 0.96)
        if _G.GetMoney then
            GameTooltip:AddDoubleLine("当前金币", F.FormatMoney(_G.GetMoney() or 0), 0.72, 0.75, 0.80, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        ShowTopAddonsMemory()
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("左键点击：立即清理 Lua 内存", 0.37, 0.83, 0.65)
        GameTooltip:Show()
    end)
    perfBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- 默认锚定在屏幕正下方（对齐原 QFXSystemBar + EUI DataBars 所在位置）
    F.Mover.Register({
        key = "SystemBar",
        label = "一体化系统微菜单栏",
        frame = barFrame,
        order = 5,
        defaultPoint = "BOTTOM",
        defaultRelPoint = "BOTTOM",
        defaultX = 0,
        defaultY = 4,
    })

    updateFade = F.Theme.AttachCombatFade(barFrame, function()
        return mod:GetDB().combatFade == true
    end)
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2HideRedundantSocial then
        db.v2HideRedundantSocial = true
        -- 与小地图顶部的「公会/好友」合并入口去重，默认隐藏底部栏重复的好友与公会图标
        db.showSocialGuild = false
    end
    if not db.v3NoCombatFadeMigrated then
        db.v3NoCombatFadeMigrated = true
        db.combatFade = false
    end
    CreateBar()
    BindSecureButtons()
    ApplyVisuals()
    InstallMicroAlertHooks()
    SuppressBlizzardMicroHelpTips(false)
    -- 栏内含安全按钮，战斗中显示/隐藏会被拦截：顺延到脱战（同一 key 与 OnDisable 互相覆盖，以最后一次操作为准）
    F.RunOutOfCombat("FUI_SystemBarVis", function()
        if barFrame and mod._active then barFrame:Show() end
    end)

    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if barDragging and barFrame then
            barDragging = false
            barFrame:StopMovingOrSizing()
            local pt, _, rpt, x, y = barFrame:GetPoint(1)
            F.DB.SavePosition("SystemBar", pt, rpt, x, y)
        end
    end)

    local function OnTalentOrLegacyChanged()
        SuppressBlizzardMicroHelpTips(false)
        UpdateBadges(true)
    end
    local onPointsChanged = F.Debounce(0.15, OnTalentOrLegacyChanged)

    self:RegisterEvent("FRIENDLIST_UPDATE", UpdateBadges)
    self:RegisterEvent("BN_FRIEND_INFO_CHANGED", UpdateBadges)
    self:RegisterEvent("GUILD_ROSTER_UPDATE", UpdateBadges)
    self:RegisterEvent("BAG_UPDATE_COOLDOWN", UpdateBadges)
    self:RegisterEvent("PLAYER_TALENT_UPDATE", onPointsChanged)
    self:RegisterEvent("TRAIT_CONFIG_UPDATED", onPointsChanged)
    self:RegisterEvent("TRAIT_TREE_CURRENCY_INFO_UPDATED", onPointsChanged)
    self:RegisterEvent("PLAYER_LEVEL_UP", onPointsChanged)
    self:RegisterEvent("PLAYER_LEVEL_CHANGED", onPointsChanged)
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", onPointsChanged)
    self:RegisterEvent("MAJOR_FACTION_RENOWN_LEVEL_CHANGED", onPointsChanged)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        BindSecureButtons()
        ApplyVisuals()
        SuppressBlizzardMicroHelpTips(false)
        C_Timer.After(0.8, function()
            if not mod._active then return end
            SuppressBlizzardMicroHelpTips(false)
            UpdateBadges(true)
        end)
    end)

    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(2, UpdateTelemetry)
end

function mod:OnDisable()
    if ticker then ticker:Cancel(); ticker = nil end
    F.RunOutOfCombat("FUI_SystemBarVis", function()
        if barFrame and not mod._active then barFrame:Hide() end
    end)
    if alertBanner then alertBanner:Hide() end
end

function mod:OnThemeChanged()
    ApplyVisuals()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "图标风格",
        tooltip = "GameIcons 为你原截图同款清晰实心图标；Lucide 为更轻盈的现代细线矢量风。",
        values = { gameicons = "GameIcons（经典实心）", lucide = "Lucide（极简细线）" },
        order = { "gameicons", "lucide" },
        getValue = function() return db.iconStyle or "gameicons" end,
        setValue = function(v) db.iconStyle = v; ApplyVisuals() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示右侧 时钟 / FPS / 延迟",
        getValue = function() return db.showTelemetry ~= false end,
        setValue = function(v) db.showTelemetry = v == true; ApplyVisuals() end,
    }, {
        type = "toggle",
        text = "显示暗色玻璃托底",
        tooltip = "关闭时完全透明悬浮（与原截图一致）；开启后增加一层极淡暗色托底与 1px 边框。",
        getValue = function() return db.showBackdrop == true end,
        setValue = function(v) db.showBackdrop = v == true; ApplyVisuals() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示好友 / 公会按钮（与小地图去重默认隐藏）",
        tooltip = "小地图上方已有合并的公会/好友在线卡片，默认隐藏底部重复按钮以保持导航栏精简。",
        getValue = function() return db.showSocialGuild == true end,
        setValue = function(v) db.showSocialGuild = v == true; ApplyVisuals() end,
    }, {
        type = "toggle",
        text = "显示未分配点数角标与炉石冷却",
        tooltip = "在底部「天赋与法术 / 传承与成就」图标右下角直接显示未分配点数，并在炉石图标显示冷却时间。",
        getValue = function() return db.showBadges ~= false end,
        setValue = function(v) db.showBadges = v == true; UpdateBadges(false) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "替换暴雪黄色提醒气泡（中上方单次轻提示）",
        tooltip = "隐藏挡在动作条上的暴雪黄色「你有未分配的天赋」气泡，改为屏幕中上方现代半透明轻提示提醒一次后自动消失。",
        getValue = function() return db.replaceMicroAlerts ~= false end,
        setValue = function(v)
            db.replaceMicroAlerts = v == true
            if v then SuppressBlizzardMicroHelpTips(false) end
        end,
    }, {
        type = "toggle",
        text = "显示一键炉石按钮",
        getValue = function() return db.showHearthstone ~= false end,
        setValue = function(v) db.showHearthstone = v == true; ApplyVisuals() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "战斗中自动淡出",
        getValue = function() return db.combatFade == true end,
        setValue = function(v) db.combatFade = v == true; ApplyVisuals() end,
    }, blank)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "图标尺寸",
        min = 14, max = 28, step = 1,
        getValue = function() return db.iconSize or 20 end,
        setValue = function(v) db.iconSize = v; ApplyVisuals() end,
    }, {
        type = "slider",
        text = "图标间距",
        min = 2, max = 16, step = 1,
        getValue = function() return db.iconSpacing or 8 end,
        setValue = function(v) db.iconSpacing = v; ApplyVisuals() end,
    })
    y = y - h
    return y
end
