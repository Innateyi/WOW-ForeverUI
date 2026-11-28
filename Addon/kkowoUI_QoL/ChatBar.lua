----------------------------------------------------------------------
--  kkowoUI — Modules/ChatBar.lua
--  与 EllesmereUIChat 无缝融合的左侧竖向聊天中控栏（频道切换 + 复制/设置/回底一体化）：
--    • 默认「左侧融合竖栏」：将原顶部频道条与右侧聊天功能栏合二为一，贴合聊框左缘通高对齐
--      - 顶部工具区：复制聊天 / 聊天设置（右键直达 /kk），自动隐藏与小地图重复的好友按钮
--      - 中部频道区（由上到下贴合底部输入框高频习惯）：世 / 综(右键交) / 会 / 团 / 队 / 密 / 喊 / 说 / 骰
--      - 底部回底钮：翻看历史聊天时自动高亮提醒，一键直达最新消息
--      - 兼容切换「标签栏上方横栏 / 底栏横栏 / 自由拖动」多种停靠模式
--    • 100% 脱离暴雪 ChatFrame1 锚点链（仅锚定 EUI 独立底板 d1.bg），零污染
--    • 实时同步 EUI 材质、半透明底色、字形描边与职业/主题色激活指示线
--    • 同步美化暴雪「N个聊天窗口」溢出菜单，内置密语提示音与关键词提醒
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_abs, math_floor, math_max, math_min, pairs, pcall, tostring, type =
    ipairs, math.abs, math.floor, math.max, math.min, pairs, pcall, tostring, type
local setmetatable = setmetatable
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local GameTooltip = _G.GameTooltip

local EUI_CHAT_MEDIA = "Interface\\AddOns\\EllesmereUIChat\\media\\"
local RAIL_WIDTH = 26

local mod = F.RegisterModule("chatBar", {
    title = "聊天条",
    desc = "将频道切换与复制、设置、回底按钮融为一体，默认贴合左侧。",
    group = "social",
    order = 10,
    defaults = {
        enabled = true,
        dockMode = "left",        -- "left" = 左侧融合竖栏（推荐）| "top" = 标签栏上方横栏 | "bottom" = 底栏横栏 | "free" = 自由拖动
        hoverReveal = false,
        idleAlpha = 1.0,
        combatFade = false,       -- 默认关闭战斗淡出，避免进脱战频繁淡入淡出开销
        tintChannelText = true,
        showActiveChannel = true,
        hideRedundantFriends = true, -- 自动隐藏 EUI 聊天侧边栏里与小地图重复的好友按钮
        unifiedRoundedPanel = true,  -- 统一圆角一体化聊天底板（融合左侧栏、标签栏与聊天正文）
        panelAlpha = 0.24,           -- 统一清透玻璃透明度（比纯透明略深即可看清文字，不挡场景）
        panelRadius = 8,
        v6LightChatGlassMigrated = false,
        v7OneGlassMigrated = false,
        channelOrder = nil,       -- 自定义频道按钮顺序（key 数组，nil 使用默认顺序）
        v2Migrated = false,
        v3ChatFitMigrated = false,
        v4LeftDockMigrated = false,
        v5NoCombatFadeMigrated = false,
        savedEUISidebarVis = nil,
        skinOverflow = true,
        loginQuiet = true,        -- 精简登录聊天刷屏（只保留 kkowoUI 与 Bug/报错提醒）
        whisperSound = true,
        keywordAlert = false,
        keywords = "",
        worldChannelName = "大脚世界频道", -- 「世」按钮右键加入/离开的自定义频道名（无限服玩家通用的世界频道）
    },
})

local barFrame = nil
local unifiedPanel = nil
local SyncUnifiedChatPanel -- 前向声明
local mutedBgFrames = setmetatable({}, { __mode = "k" })
local combatLogGlass = setmetatable({}, { __mode = "k" })
local chanButtons = {}
local chanButtonByKey = {}
local selectedOrderKey = "WORLD"
local utilButtons = {}
local utilDivTop = nil
local utilDivBot = nil
local euiHooksInstalled = false
local registryRegistered = false
local syncingEUI = false
local resyncQueued = false
local isHovered = false
local editBoxActive = false
local activeChannelKey = nil
local lastKeywordAlert = 0
local leftRoomAdjusted = false
local wheelQueued = false
local keywordList = {}
local keywordSource = nil
local keywordWatching = false

-- 弱表管理暴雪溢出按钮/下拉菜单及 EUI 底板挂钩（严禁写暴雪框体字段，零污染）
local overflowHooked = setmetatable({}, { __mode = "k" })
local overflowVisual = setmetatable({}, { __mode = "k" })
local bgSizeHooked = setmetatable({}, { __mode = "k" })
local wheelHooked = setmetatable({}, { __mode = "k" })
local euiAlphaHooked = setmetatable({}, { __mode = "k" })
local euiChatLiveAlpha = 1.0

----------------------------------------------------------------------
--  读取 EllesmereUIChat 实时配置、材质、字体与独立背景框
----------------------------------------------------------------------
local function GetEUIChatContext()
    local EUI = _G.EllesmereUI
    local cf1 = _G.ChatFrame1
    local d1 = EUI and EUI._chatCFD and cf1 and EUI._chatCFD(cf1)
    local bg1 = d1 and d1.bg
    local chatNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIChat
    local echat = chatNS and chatNS.ECHAT
    local ecfg = nil
    if echat and type(echat.DB) == "function" then
        local okDB, cfg = pcall(echat.DB)
        if okDB and type(cfg) == "table" then ecfg = cfg end
    end
    local pp = EUI and EUI.PP
    local onePx = (pp and pp.mult) or 1
    return EUI, cf1, bg1, chatNS, echat, ecfg, onePx, d1
end

local function IsVerticalMode()
    return (mod:GetDB().dockMode or "left") == "left"
end

local function ResolveEUITabTexture(EUI, chatNS, echat, ecfg)
    if ecfg then
        local texKey = ecfg.tabBackgroundTexture or "none"
        if texKey ~= "none" then
            if chatNS and chatNS.chatBgTextures and not chatNS.chatBgTextures[texKey]
                and echat and echat.RefreshBgTextureCatalogue then
                pcall(echat.RefreshBgTextureCatalogue)
            end
            if EUI and EUI.ResolveTexturePath and chatNS and chatNS.chatBgTextures then
                local ok, path = pcall(EUI.ResolveTexturePath, chatNS.chatBgTextures, texKey, nil)
                if ok and type(path) == "string" and path ~= "" then
                    return path
                end
            elseif chatNS and chatNS.chatBgTextures and chatNS.chatBgTextures[texKey] then
                return chatNS.chatBgTextures[texKey]
            end
        end
    end
    return F.Theme.GetBarTexture()
end

local function ResolveEUITabFont(EUI, echat, ecfg)
    local path = nil
    local flag = ""
    local size = 12
    if ecfg and EUI then
        local fontKey = ecfg.tabFont or "__global"
        if fontKey == "__global" and EUI.GetFontPath then
            local ok, p = pcall(EUI.GetFontPath, "chat")
            if ok and type(p) == "string" and p ~= "" then path = p end
        elseif EUI.ResolveFontName then
            local ok, p = pcall(EUI.ResolveFontName, fontKey)
            if ok and type(p) == "string" and p ~= "" then path = p end
        end
        if echat and echat.GetOutlineFlag then
            local ok, fl = pcall(echat.GetOutlineFlag)
            if ok and type(fl) == "string" then flag = fl end
        elseif EUI.GetFontOutlineFlag then
            local ok, fl = pcall(EUI.GetFontOutlineFlag, "chat")
            if ok and type(fl) == "string" then flag = fl end
        end
        local tabSz = F.PlainNumber(ecfg.tabFontSize, 11)
        size = math_max(11, math_min(14, tabSz + 1))
    end
    return path or F.Theme.GetFont(), size, flag
end

local function ResolveEUITabColors(EUI, ecfg)
    local bgR, bgG, bgB, bgA = 0.03, 0.045, 0.05, 0.44
    local actR, actG, actB, actA = F.Theme.GetAccent()
    actA = 0.52
    local ulR, ulG, ulB, ulA = actR, actG, actB, 0.95

    if ecfg then
        local c = ecfg.tabBackgroundColor
        if type(c) == "table" then
            bgR = F.PlainNumber(c.r, bgR)
            bgG = F.PlainNumber(c.g, bgG)
            bgB = F.PlainNumber(c.b, bgB)
            bgA = (c.a ~= nil) and F.PlainNumber(c.a, bgA) or bgA
        end
        local extBg = ecfg.extendBgBehindTabs == true
        if extBg then
            local eA = F.PlainNumber(ecfg.bgAlpha, 0.65)
            if eA > 0.05 then
                bgR = F.PlainNumber(ecfg.bgR, bgR)
                bgG = F.PlainNumber(ecfg.bgG, bgG)
                bgB = F.PlainNumber(ecfg.bgB, bgB)
                bgA = eA
            end
        end

        local actMode = ecfg.tabBackgroundColorActiveMode or "class"
        local ac = ecfg.tabBackgroundColorActive
        if actMode == "class" then
            actR, actG, actB = F.Theme.GetClassColor()
            actA = (type(ac) == "table" and ac.a ~= nil) and F.PlainNumber(ac.a, 0.56) or 0.56
        elseif actMode == "accent" and EUI and EUI.GetAccentColor then
            local ok, r, g, b = pcall(EUI.GetAccentColor)
            if ok and r and g and b then actR, actG, actB = r, g, b end
            actA = (type(ac) == "table" and ac.a ~= nil) and F.PlainNumber(ac.a, 0.56) or 0.56
        elseif type(ac) == "table" then
            actR = F.PlainNumber(ac.r, actR)
            actG = F.PlainNumber(ac.g, actG)
            actB = F.PlainNumber(ac.b, actB)
            actA = (ac.a ~= nil) and F.PlainNumber(ac.a, 0.56) or 0.56
        end

        local ulMode = ecfg.activeUnderlineColorMode or "accent"
        local uc = ecfg.activeUnderlineColor
        if ulMode == "class" then
            ulR, ulG, ulB = F.Theme.GetClassColor()
            ulA = (type(uc) == "table" and uc.a ~= nil) and F.PlainNumber(uc.a, 0.95) or 0.95
        elseif ulMode == "accent" and EUI and EUI.GetAccentColor then
            local ok, r, g, b = pcall(EUI.GetAccentColor)
            if ok and r and g and b then ulR, ulG, ulB = r, g, b end
            ulA = (type(uc) == "table" and uc.a ~= nil) and F.PlainNumber(uc.a, 0.95) or 0.95
        elseif type(uc) == "table" then
            ulR = F.PlainNumber(uc.r, ulR)
            ulG = F.PlainNumber(uc.g, ulG)
            ulB = F.PlainNumber(uc.b, ulB)
            ulA = (uc.a ~= nil) and F.PlainNumber(uc.a, 0.95) or 0.95
        end
    end

    return bgR, bgG, bgB, bgA, actR, actG, actB, actA, ulR, ulG, ulB, ulA
end

----------------------------------------------------------------------
--  同步隐藏 EUI 重复的好友按钮 & 在左侧融合模式下接管右侧功能栏
----------------------------------------------------------------------
local function EnsureLeftDockRoom()
    if leftRoomAdjusted or not (mod._active and IsVerticalMode()) then return end
    local _, _, bg1, _, echat, ecfg = GetEUIChatContext()
    if not (bg1 and echat and type(ecfg) == "table") then return end
    local bgLeft = bg1.GetLeft and F.PlainNumber(bg1:GetLeft(), nil)
    if not bgLeft then return end
    local minLeft = RAIL_WIDTH + 4
    if bgLeft >= minLeft then
        leftRoomAdjusted = true
        return
    end
    local pos = ecfg.chatPosition
    if type(pos) == "table" and type(pos.x) == "number" then
        leftRoomAdjusted = true
        F.RunOutOfCombat("FUI_ChatLeftRoom", function()
            if not (mod._active and IsVerticalMode()) then return end
            local delta = math_floor((minLeft - bgLeft) + 0.5)
            if delta > 0 then
                local db = mod:GetDB()
                if db.leftRoomDelta == nil then
                    db.leftRoomDelta = 0
                end
                db.leftRoomDelta = db.leftRoomDelta + delta
                pos.x = pos.x + delta
                db.leftRoomSetX = pos.x
                if echat.ApplyChatPosition then
                    pcall(echat.ApplyChatPosition)
                end
            end
        end)
    end
end

-- 退出左侧竖栏/停用模块时，把为竖栏让位而右移的聊天框挪回原处（仅当用户之后没再手动移动过聊天框）
local function RestoreLeftDockRoom(ecfg, echat)
    local db = mod:GetDB()
    local delta = db.leftRoomDelta
    if not delta then return end
    local pos = type(ecfg) == "table" and ecfg.chatPosition
    if type(pos) == "table" and type(pos.x) == "number" and db.leftRoomSetX == pos.x then
        F.RunOutOfCombat("FUI_ChatLeftRoom", function()
            if type(pos.x) == "number" and db.leftRoomSetX == pos.x then
                pos.x = pos.x - delta
                if echat and echat.ApplyChatPosition then
                    pcall(echat.ApplyChatPosition)
                end
            end
            db.leftRoomDelta = nil
            db.leftRoomSetX = nil
        end)
    else
        db.leftRoomDelta = nil
        db.leftRoomSetX = nil
    end
    leftRoomAdjusted = false
end

local function SyncEUIChatSidebar()
    if syncingEUI then return end
    local _, _, _, _, echat, ecfg, _, d1 = GetEUIChatContext()
    if not (echat and type(ecfg) == "table") then return end

    local db = mod:GetDB()
    local wantFusedLeft = mod._active and IsVerticalMode()
    local changed = false

    syncingEUI = true

    -- 1) 按选项隐藏聊天侧边栏里的「好友」按钮（与小地图顶部合并社交入口去重）；改写前记下 EUI 原值，停用/关闭选项时原样还原
    if mod._active and db.hideRedundantFriends ~= false then
        if ecfg.showFriends ~= false then
            if db.savedEUIShowFriends == nil then
                db.savedEUIShowFriends = (ecfg.showFriends == nil) and "nil" or ecfg.showFriends
            end
            ecfg.showFriends = false
            changed = true
        end
        if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            if d1 and d1.friendsBtn and not (d1.friendsBtn.IsForbidden and d1.friendsBtn:IsForbidden()) and d1.friendsBtn:IsShown() then
                pcall(d1.friendsBtn.Hide, d1.friendsBtn)
            end
            if d1 and d1.friendsCount and not (d1.friendsCount.IsForbidden and d1.friendsCount:IsForbidden()) and d1.friendsCount:IsShown() then
                pcall(d1.friendsCount.Hide, d1.friendsCount)
            end
        end
    elseif db.savedEUIShowFriends ~= nil then
        if db.savedEUIShowFriends == "nil" then
            ecfg.showFriends = nil
        else
            ecfg.showFriends = db.savedEUIShowFriends
        end
        db.savedEUIShowFriends = nil
        changed = true
    end

    -- 2) 左侧融合竖栏模式：无缝收起 EUI 原生右侧边栏，所有实用功能由左侧融合栏统一承接
    if wantFusedLeft then
        if ecfg.sidebarVisibility ~= "never" then
            if db.savedEUISidebarVis == nil then
                db.savedEUISidebarVis = ecfg.sidebarVisibility or "always"
            end
            ecfg.sidebarVisibility = "never"
            changed = true
        end
        if ecfg.scrollButtonOnChat == true then
            db.savedEUIScrollOnChat = true
            ecfg.scrollButtonOnChat = false
            changed = true
        end
    else
        if db.savedEUISidebarVis ~= nil then
            ecfg.sidebarVisibility = db.savedEUISidebarVis
            db.savedEUISidebarVis = nil
            changed = true
        end
        if db.savedEUIScrollOnChat ~= nil then
            ecfg.scrollButtonOnChat = db.savedEUIScrollOnChat == true
            db.savedEUIScrollOnChat = nil
            changed = true
        end
        if db.leftRoomDelta then
            RestoreLeftDockRoom(ecfg, echat)
        end
    end

    -- 3) 统一圆角一体化聊天底板：将 EUI 标签底色设为透明并启用延展模式（去除零散方框），全部统一落在一整块圆角玻璃底板上
    local wantUnified = mod._active and db.unifiedRoundedPanel ~= false
    if wantUnified then
        if ecfg.extendBgBehindTabs ~= true then
            if db.savedEUIExtendBg == nil then
                db.savedEUIExtendBg = (ecfg.extendBgBehindTabs == nil) and "nil" or ecfg.extendBgBehindTabs
            end
            ecfg.extendBgBehindTabs = true
            changed = true
        end
        local curTabBg = ecfg.tabBackgroundColor
        if not (type(curTabBg) == "table" and curTabBg.a == 0) then
            if db.savedEUITabBg == nil then
                if type(curTabBg) == "table" then
                    db.savedEUITabBg = { r = curTabBg.r, g = curTabBg.g, b = curTabBg.b, a = curTabBg.a }
                else
                    db.savedEUITabBg = "nil"
                end
            end
            ecfg.tabBackgroundColor = { r = 0, g = 0, b = 0, a = 0 }
            changed = true
        end
        local curAct = ecfg.tabBackgroundColorActive
        if type(curAct) == "table" and type(curAct.a) == "number" and curAct.a > 0.30 then
            if db.savedEUITabActA == nil then
                db.savedEUITabActA = curAct.a
            end
            curAct.a = 0.26
            changed = true
        end
    else
        if db.savedEUIExtendBg ~= nil then
            if db.savedEUIExtendBg == "nil" then
                ecfg.extendBgBehindTabs = nil
            else
                ecfg.extendBgBehindTabs = db.savedEUIExtendBg
            end
            db.savedEUIExtendBg = nil
            changed = true
        end
        if db.savedEUITabBg ~= nil then
            if db.savedEUITabBg == "nil" then
                ecfg.tabBackgroundColor = nil
            elseif type(db.savedEUITabBg) == "table" then
                ecfg.tabBackgroundColor = {
                    r = db.savedEUITabBg.r, g = db.savedEUITabBg.g,
                    b = db.savedEUITabBg.b, a = db.savedEUITabBg.a,
                }
            end
            db.savedEUITabBg = nil
            changed = true
        end
        if db.savedEUITabActA ~= nil then
            if type(ecfg.tabBackgroundColorActive) == "table" then
                ecfg.tabBackgroundColorActive.a = db.savedEUITabActA
            end
            db.savedEUITabActA = nil
            changed = true
        end
    end

    if changed then
        -- 不调用 EUI 的 ApplySidebarIcons：其完整 ClearAllPoints/SetPoint 布局链会污染聊天框（EUI 自身初始化也刻意跳过）。
        -- 与 EUI 初始化相同，只按配置对单个图标做 SetShown；整批放到脱战后执行，杜绝战斗中改动聊天布局。
        F.RunOutOfCombat("FUI_ChatSidebarApply", function()
            if echat.ApplySidebarVisibility then pcall(echat.ApplySidebarVisibility) end
            local sbd = d1
            if sbd then
                if sbd.scrollBtn then sbd.scrollBtn:SetShown(ecfg.showScroll ~= false) end
                if sbd.friendsBtn then sbd.friendsBtn:SetShown(ecfg.showFriends ~= false) end
                if sbd.friendsCount then sbd.friendsCount:SetShown(ecfg.showFriends ~= false) end
            end
            -- 「回到底部」按钮随 scrollButtonOnChat 切换座位：EUI 提供的单按钮重挂函数（只动它自己的按钮，不走整条布局链）
            if echat.ApplyScrollButtonPosition then pcall(echat.ApplyScrollButtonPosition) end
            if echat.ApplyBackground then pcall(echat.ApplyBackground) end
            if echat.ApplyBorders then pcall(echat.ApplyBorders) end
            if echat.ApplyExtendedBackground then pcall(echat.ApplyExtendedBackground) end
            if echat.ApplyTabAppearance then pcall(echat.ApplyTabAppearance) end
            C_Timer.After(0, function()
                if SyncUnifiedChatPanel then SyncUnifiedChatPanel() end
            end)
        end)
    end

    syncingEUI = false
end

----------------------------------------------------------------------
--  右侧工具按钮功能转发（复制聊天 / 聊天设置 / 回到底部）
----------------------------------------------------------------------
local function GetSelectedChatWindow()
    if _G.GENERAL_CHAT_DOCK and _G.FCFDock_GetSelectedWindow then
        local ok, sel = pcall(_G.FCFDock_GetSelectedWindow, _G.GENERAL_CHAT_DOCK)
        if ok and sel then return sel end
    end
    return _G.SELECTED_DOCK_FRAME or _G.ChatFrame1
end

local function TriggerCopyChat()
    local _, _, _, _, _, _, _, d1 = GetEUIChatContext()
    local btn = d1 and d1.copyBtn
    if btn and btn.GetScript then
        local fn = btn:GetScript("OnClick")
        if fn then
            pcall(fn, btn, "LeftButton")
            return
        end
    end
    F.Print("未检测到 EUI 聊天复制功能。")
end

local function TriggerChatSettings(mouseBtn)
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.Print("战斗中无法打开设置面板，请脱战后再试。")
        return
    end
    local EUI = _G.EllesmereUI
    if mouseBtn == "RightButton" then
        if EUI and EUI.OpenPlugin then
            pcall(EUI.OpenPlugin, F.NAME)
        end
        return
    end
    local _, _, _, _, _, _, _, d1 = GetEUIChatContext()
    local btn = d1 and d1.settingsBtn
    if btn and btn.GetScript then
        local fn = btn:GetScript("OnClick")
        if fn then
            pcall(fn, btn, "LeftButton")
            return
        end
    end
    if EUI and EUI.ShowModule then
        pcall(EUI.ShowModule, EUI, "EllesmereUIChat")
    end
end

local function IsChatScrolledUp()
    local sel = GetSelectedChatWindow()
    local EUI = _G.EllesmereUI
    local ds = EUI and EUI._chatCFD and sel and EUI._chatCFD(sel)
    local mf = ds and ds.msgFrame
    if mf and mf.AtBottom then
        local ok, atBot = pcall(mf.AtBottom, mf)
        if ok and atBot == false then return true end
    end
    if sel and sel.AtBottom then
        local ok, atBot = pcall(sel.AtBottom, sel)
        if ok and atBot == false then return true end
    end
    return false
end

local UpdateScrollIndicator

local function TriggerScrollToBottom()
    local _, _, _, _, echat = GetEUIChatContext()
    local sel = GetSelectedChatWindow()
    if echat and echat.EngineScrollToBottom then
        pcall(echat.EngineScrollToBottom, sel)
    end
    if sel and sel.ScrollToBottom then
        pcall(sel.ScrollToBottom, sel)
    end
    if UpdateScrollIndicator then
        C_Timer.After(0.05, UpdateScrollIndicator)
    end
end

----------------------------------------------------------------------
--  频道编号动态解析与持久化切换频道（回车保留当前频道 + 12.x 零污染）
----------------------------------------------------------------------
local function GetPrimaryEditBox()
    local choose = (_G.ChatFrameUtil and _G.ChatFrameUtil.ChooseBoxForSend) or _G.ChatEdit_ChooseBoxForSend
    local eb = choose and choose() or nil
    if not eb then
        local cf = _G.SELECTED_DOCK_FRAME or _G.ChatFrame1
        eb = (cf and cf.editBox) or _G.ChatFrame1EditBox
    end
    local targetFrame = (eb and eb.chatFrame) or _G.SELECTED_DOCK_FRAME or _G.ChatFrame1
    return eb, targetFrame
end

local function OpenChatPrefix(prefix)
    if not prefix then return end
    local _, targetFrame = GetPrimaryEditBox()
    if _G.ChatFrameUtil and _G.ChatFrameUtil.OpenChat then
        pcall(_G.ChatFrameUtil.OpenChat, prefix, targetFrame)
    elseif _G.ChatFrame_OpenChat then
        pcall(_G.ChatFrame_OpenChat, prefix, targetFrame)
    end
end

local function IsChatMessagingLocked()
    local ci = _G.C_ChatInfo
    if not (ci and ci.InChatMessagingLockdown) then return false end
    local ok, locked = pcall(ci.InChatMessagingLockdown)
    return ok and (not F.IsSecret(locked)) and locked == true
end

local function SwitchChatChannel(chatType, opts)
    opts = opts or {}
    if not chatType then
        if opts.prefix then OpenChatPrefix(opts.prefix) end
        return
    end
    if IsChatMessagingLocked() then
        if opts.prefix then OpenChatPrefix(opts.prefix) end
        return
    end
    local eb = GetPrimaryEditBox()
    if not eb then
        if opts.prefix then OpenChatPrefix(opts.prefix) end
        return
    end

    local prevText = ""
    if eb.HasFocus and eb:HasFocus() and eb.GetText then
        local okT, txt = pcall(eb.GetText, eb)
        txt = okT and F.PlainString(txt, "") or ""
        if not txt:find("^/") then
            prevText = txt
        end
    end

    local activate = (_G.ChatFrameUtil and _G.ChatFrameUtil.ActivateChat) or _G.ChatEdit_ActivateChat
    if activate then
        pcall(activate, eb)
    else
        pcall(eb.Show, eb)
        pcall(eb.SetFocus, eb)
    end

    if opts.channelID then
        if eb.SetChannelTarget then
            pcall(eb.SetChannelTarget, eb, opts.channelID)
        elseif eb.SetAttribute then
            pcall(eb.SetAttribute, eb, "channelTarget", opts.channelID)
        end
    end
    if opts.tellTarget then
        if eb.SetTellTarget then
            pcall(eb.SetTellTarget, eb, opts.tellTarget)
        elseif eb.SetAttribute then
            pcall(eb.SetAttribute, eb, "tellTarget", opts.tellTarget)
        end
    end
    if eb.SetChatType then
        pcall(eb.SetChatType, eb, chatType)
    elseif eb.SetAttribute then
        pcall(eb.SetAttribute, eb, "chatType", chatType)
    end
    if opts.sticky ~= false then
        if eb.SetStickyType then
            pcall(eb.SetStickyType, eb, chatType)
        elseif eb.SetAttribute then
            pcall(eb.SetAttribute, eb, "stickyType", chatType)
        end
    end

    if eb.UpdateHeader then
        pcall(eb.UpdateHeader, eb)
    elseif _G.ChatEdit_UpdateHeader then
        pcall(_G.ChatEdit_UpdateHeader, eb)
    end

    if eb.SetText then
        pcall(eb.SetText, eb, prevText)
    end
end

local function OpenReplyWhisper()
    local _, targetFrame = GetPrimaryEditBox()
    if _G.ChatFrameUtil and _G.ChatFrameUtil.ReplyTell then
        local ok = pcall(_G.ChatFrameUtil.ReplyTell, targetFrame)
        if ok then return end
    elseif _G.ChatEdit_ReplyTell then
        local ok = pcall(_G.ChatEdit_ReplyTell, targetFrame)
        if ok then return end
    end
    OpenChatPrefix("/r ")
end

local function FindChannelID(exactName, keywords)
    if exactName and _G.GetChannelName then
        local id = F.PlainNumber(_G.GetChannelName(exactName), 0)
        if id > 0 then return id, exactName end
    end
    if _G.GetChannelList then
        local list = { _G.GetChannelList() }
        for i = 1, #list, 3 do
            local id = F.PlainNumber(list[i], 0)
            local name = F.PlainString(list[i + 1], nil)
            if id > 0 and name then
                local low = name:lower()
                if exactName and low == exactName:lower() then
                    return id, name
                end
                if keywords then
                    for _, kw in ipairs(keywords) do
                        if low:find(kw, 1, true) then
                            return id, name
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

local DEFAULT_WORLD_CHANNEL = "大脚世界频道"

-- 世界频道名：自建频道按名字区分，名字相同即同一个频道（不需要装大脚插件）
local function GetWorldChannelName()
    local n = mod:GetDB().worldChannelName
    if type(n) == "string" then
        n = n:gsub("^%s+", ""):gsub("%s+$", "")
        if n ~= "" then return n end
    end
    return DEFAULT_WORLD_CHANNEL
end

-- 校验玩家输入的频道名：/join 以空格分隔密码，纯数字会被当成频道编号
local function ValidateWorldChannelName(raw)
    if type(raw) ~= "string" then return nil, "频道名无效" end
    local n = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if n == "" then return DEFAULT_WORLD_CHANNEL end
    if n:find("%s") then return nil, "频道名不能包含空格" end
    if n:match("^%d+$") then return nil, "频道名不能是纯数字（数字代表频道编号）" end
    if #n > 31 then return nil, "频道名过长" end
    return n
end

function mod:SetWorldChannelName(raw)
    local n, err = ValidateWorldChannelName(raw)
    if not n then
        F.Print("|cffe05263" .. err .. "，未修改。|r当前世界频道：" .. GetWorldChannelName())
        return false
    end
    self:GetDB().worldChannelName = n
    F.Print("世界频道已设为 |cff5fd3a6" .. n .. "|r；右键「世」即可加入或离开。")
    return true
end

-- 左键「世」：优先精确匹配设定的频道名，其次匹配名字里带「世界/world/大脚/组队」的已加入频道
local function FindWorldChannel()
    return FindChannelID(GetWorldChannelName(), { "世界", "world", "大脚", "组队", "lookingforgroup" })
end

-- 右键只认精确频道名：模糊匹配会把「寻求组队」等系统频道当成世界频道直接退掉
local function FindExactWorldChannel()
    local name = GetWorldChannelName()
    if not _G.GetChannelName then return nil, name end
    local id = F.PlainNumber(_G.GetChannelName(name), 0)
    if id > 0 then return id, name end
    return nil, name
end

local function ToggleWorldChannel()
    local id, name = FindExactWorldChannel()
    if id and id > 0 then
        local targetName = name
        local ok = false
        if _G.LeaveChannelByName then
            ok = pcall(_G.LeaveChannelByName, targetName)
        elseif _G.C_ChatInfo and _G.C_ChatInfo.LeaveChannelByName then
            ok = pcall(_G.C_ChatInfo.LeaveChannelByName, targetName)
        end
        if ok then
            F.Print("已离开频道：|cffe6b450" .. targetName .. "|r")
        else
            OpenChatPrefix("/leave " .. id .. " ")
        end
    else
        local ok = false
        if _G.JoinChannelByName then
            ok = pcall(_G.JoinChannelByName, name)
        elseif _G.C_ChatInfo and _G.C_ChatInfo.JoinChannelByName then
            ok = pcall(_G.C_ChatInfo.JoinChannelByName, name)
        end
        if ok then
            F.Print("已尝试加入 |cff5fd3a6" .. name .. "|r，稍等 1 秒后左键「世」即可发言。")
        else
            OpenChatPrefix("/join " .. name)
        end
    end
end

-- 频道按钮顺序（竖栏由上至下：公共大频道在上，高频说/喊/队紧邻底部输入框；横栏自动适配）
local CHANNELS = {
    {
        key = "WORLD",
        label = "世", tip = "左键：世界频道发言（切换并记住）\n右键：一键加入或离开世界频道（频道名可在设置中修改）",
        color = { 0.97, 0.85, 0.44 },
        left = function()
            local id = FindWorldChannel()
            if id and id > 0 then
                SwitchChatChannel("CHANNEL", { channelID = id, sticky = true, prefix = "/" .. id .. " " })
            else
                F.Print("当前未加入世界频道，|cff5fd3a6右键「世」|r 可一键加入「" .. GetWorldChannelName() .. "」。")
            end
        end,
        right = ToggleWorldChannel,
    },
    {
        key = "GENERAL",
        label = "综", tip = "左键：综合频道 (/1，切换并记住)\n右键：交易频道 (/2，切换并记住)",
        color = { 0.92, 0.80, 0.60 },
        left = function()
            local id = FindChannelID("综合", { "综合", "general" }) or 1
            SwitchChatChannel("CHANNEL", { channelID = id, sticky = true, prefix = "/" .. id .. " " })
        end,
        right = function()
            local id = FindChannelID("交易", { "交易", "trade" }) or 2
            SwitchChatChannel("CHANNEL", { channelID = id, sticky = true, prefix = "/" .. id .. " " })
        end,
    },
    {
        key = "TRADE",
        label = "交", tip = "交易频道 (/2，自动匹配编号并记住)",
        color = { 0.95, 0.72, 0.50 },
        hideInVertical = true, -- 左侧竖栏已合并至「综」右键，给其余按钮更宽敞防误触高度
        left = function()
            local id = FindChannelID("交易", { "交易", "trade" }) or 2
            SwitchChatChannel("CHANNEL", { channelID = id, sticky = true, prefix = "/" .. id .. " " })
        end,
    },
    {
        key = "GUILD",
        label = "会", tip = "左键：公会 (/g) — 切换并记住\n右键：官员 (/o) — 切换并记住",
        color = { 0.42, 0.89, 0.54 },
        left = function() SwitchChatChannel("GUILD", { sticky = true, prefix = "/g " }) end,
        right = function() SwitchChatChannel("OFFICER", { sticky = true, prefix = "/o " }) end,
    },
    {
        key = "RAID",
        label = "团", tip = "左键：团队 / 副本频道（切换并记住）\n右键：团队警报 (/rw)",
        color = { 0.99, 0.65, 0.34 },
        left = function()
            if _G.IsInGroup and _G.LE_PARTY_CATEGORY_INSTANCE and _G.IsInGroup(_G.LE_PARTY_CATEGORY_INSTANCE) then
                SwitchChatChannel("INSTANCE_CHAT", { sticky = true, prefix = "/i " })
            else
                SwitchChatChannel("RAID", { sticky = true, prefix = "/ra " })
            end
        end,
        right = function() SwitchChatChannel("RAID_WARNING", { sticky = false, prefix = "/rw " }) end,
    },
    {
        key = "PARTY",
        label = "队", tip = "小队 (/p) — 点击切换并记住频道",
        color = { 0.64, 0.78, 1.00 },
        left = function() SwitchChatChannel("PARTY", { sticky = true, prefix = "/p " }) end,
    },
    {
        key = "WHISPER",
        label = "密", tip = "左键：回复最后密语 (/r)\n右键：密语当前友方玩家目标",
        color = { 0.96, 0.58, 0.90 },
        left = OpenReplyWhisper,
        right = function()
            -- pcall 的多返回值不能放进 and/or 表达式（会被截成 1 个值，第二个变量恒为 nil）
            local function SafeCall2(fn, ...)
                if type(fn) ~= "function" then return false, nil end
                return pcall(fn, ...)
            end
            local okE, exists = SafeCall2(_G.UnitExists, "target")
            local okP, isPlayer = false, nil
            if okE and not F.IsSecret(exists) and exists then
                okP, isPlayer = SafeCall2(_G.UnitIsPlayer, "target")
            end
            if okP and not F.IsSecret(isPlayer) and isPlayer then
                local okF, isFriend = SafeCall2(_G.UnitIsFriend, "player", "target")
                local okS, isSelf = SafeCall2(_G.UnitIsUnit, "player", "target")
                if okF and not F.IsSecret(isFriend) and isFriend and not (okS and not F.IsSecret(isSelf) and isSelf) then
                    local okN, name, realm = pcall(_G.UnitName, "target")
                    name = okN and F.PlainString(name, nil) or nil
                    realm = okN and F.PlainString(realm, nil) or nil
                    if name and name ~= "" then
                        local EUI = _G.EllesmereUI
                        local full
                        if EUI and EUI.IS_FOREVER then
                            if realm and realm ~= "" then
                                full = (type(EUI.WithSurname) == "function" and F.PlainString(EUI.WithSurname(name, realm, true), nil))
                                    or (name .. " " .. realm)
                            else
                                full = name
                            end
                        else
                            full = (realm and realm ~= "") and (name .. "-" .. realm) or name
                        end
                        SwitchChatChannel("WHISPER", { tellTarget = full, sticky = false, prefix = "/w " .. full .. " " })
                        return
                    end
                end
            end
            OpenReplyWhisper()
        end,
    },
    {
        key = "YELL",
        label = "喊", tip = "大喊 (/y)",
        color = { 0.96, 0.46, 0.46 },
        left = function() SwitchChatChannel("YELL", { sticky = false, prefix = "/y " }) end,
    },
    {
        key = "SAY",
        label = "说", tip = "说 (/s) — 点击切换并记住频道",
        color = { 0.94, 0.94, 0.97 },
        left = function() SwitchChatChannel("SAY", { sticky = true, prefix = "/s " }) end,
    },
    {
        key = "ROLL",
        label = "骰", tip = "掷骰子 (/roll 1-100)",
        color = { 0.74, 0.88, 0.97 },
        left = function()
            if _G.RandomRoll then pcall(_G.RandomRoll, 1, 100) end
        end,
    },
}

local function GetNormalizedChannelOrder()
    local db = mod:GetDB()
    local valid, order, seen = {}, {}, {}
    for _, ch in ipairs(CHANNELS) do
        valid[ch.key] = true
    end
    if type(db.channelOrder) == "table" then
        for _, k in ipairs(db.channelOrder) do
            if valid[k] and not seen[k] then
                seen[k] = true
                order[#order + 1] = k
            end
        end
    end
    for _, ch in ipairs(CHANNELS) do
        if not seen[ch.key] then
            seen[ch.key] = true
            order[#order + 1] = ch.key
        end
    end
    return order
end

local function GetOrderedChannelButtons(vert)
    local out = {}
    local order = GetNormalizedChannelOrder()
    for _, key in ipairs(order) do
        local btn = chanButtonByKey[key]
        if btn then
            if vert and btn._ch.hideInVertical then
                btn:Hide()
            else
                btn:Show()
                out[#out + 1] = btn
            end
        end
    end
    return out
end

local LayoutButtons

local function MoveChannelOrder(key, delta)
    if not key or delta == 0 then return end
    local order = GetNormalizedChannelOrder()
    local vert = IsVerticalMode()
    local idx = nil
    for i, k in ipairs(order) do
        if k == key then idx = i; break end
    end
    if not idx then return end

    local step = delta > 0 and 1 or -1
    local target = idx + step
    while target >= 1 and target <= #order do
        local btn = chanButtonByKey[order[target]]
        if not (vert and btn and btn._ch and btn._ch.hideInVertical) then
            break
        end
        target = target + step
    end
    if target < 1 or target > #order then return end

    order[idx], order[target] = order[target], order[idx]
    mod:GetDB().channelOrder = order
    if LayoutButtons then LayoutButtons() end

    local labels = {}
    for _, k in ipairs(order) do
        local btn = chanButtonByKey[k]
        if btn and btn._ch and not (vert and btn._ch.hideInVertical) then
            labels[#labels + 1] = btn._ch.label
        end
    end
    F.Print("聊天频道顺序已更新：" .. _G.table.concat(labels, " · "))
end

local function ResetChannelOrder()
    mod:GetDB().channelOrder = nil
    if LayoutButtons then LayoutButtons() end
    F.Print("聊天频道按钮顺序已恢复默认。")
end

local UTIL_DEFS = {
    {
        id = "copy",
        zone = "top",
        tex = EUI_CHAT_MEDIA .. "chat_copy.png",
        fallbackTex = F.Theme.ICONS .. "Copy.tga",
        fallbackGlyph = "复",
        tip = "复制当前聊天记录",
        onClick = function() TriggerCopyChat() end,
    },
    {
        id = "settings",
        zone = "top",
        tex = EUI_CHAT_MEDIA .. "chat_settings.png",
        fallbackTex = F.Theme.ICONS .. "Settings.tga",
        fallbackGlyph = "设",
        tip = "左键：打开聊天窗口设置\n右键：打开 kkowoUI 设置 (/kk)",
        onClick = function(mouseBtn) TriggerChatSettings(mouseBtn) end,
    },
    {
        id = "scroll",
        zone = "bottom",
        tex = EUI_CHAT_MEDIA .. "chat_scroll2.png",
        fallbackTex = F.Theme.ICONS .. "ScrollDown.tga",
        fallbackGlyph = "↓",
        tip = "一键回到底部最新消息",
        onClick = function() TriggerScrollToBottom() end,
    },
}

-- 只认常驻聊天窗口 1~10 的输入框（11+ 的临时密语窗口带保密 tellTarget，EUI 也明确不碰）
local function IsPermanentEditBox(eb)
    if not (eb and type(eb.GetName) == "function") then return false end
    local n = F.PlainString(eb:GetName(), nil)
    local i = n and tonumber(n:match("^ChatFrame(%d+)EditBox$"))
    return i ~= nil and i <= 10
end

-- 最近一次真正被聊天使用的输入框（焦点回调 / 频道按钮切换时记录）
local lastEditBox = nil

-- 当前频道判断必须读「正在用的那个输入框」：IM 聊天风格下每个标签页各有自己的输入框，
-- 选中「世界」等其它标签时回车打开的是该标签自己的框；写死读 ChatFrame1EditBox 会读到
-- 一个没在用、仍是默认「说」的框，导致竖栏高亮跳回「说」
local function GetActiveEditBox()
    for i = 1, 10 do
        local eb = _G["ChatFrame" .. i .. "EditBox"]
        if eb and eb.HasFocus and eb:HasFocus() then
            return eb, true
        end
    end
    if lastEditBox then return lastEditBox, false end
    local eb = GetPrimaryEditBox()
    return eb or _G.ChatFrame1EditBox, false
end

local function DetectActiveChannelKey()
    local eb, focused = GetActiveEditBox()
    if not eb then return nil end

    local chatType = nil
    if focused then
        if eb.GetChatType then
            local ok, v = pcall(eb.GetChatType, eb)
            chatType = ok and F.PlainString(v, nil) or nil
        elseif eb.GetAttribute then
            local ok, v = pcall(eb.GetAttribute, eb, "chatType")
            chatType = ok and F.PlainString(v, nil) or nil
        end
    end
    if not chatType then
        if eb.GetStickyType then
            local ok, v = pcall(eb.GetStickyType, eb)
            chatType = ok and F.PlainString(v, nil) or nil
        elseif eb.GetAttribute then
            local ok, v = pcall(eb.GetAttribute, eb, "stickyType")
            chatType = ok and F.PlainString(v, nil) or nil
        end
    end
    if not chatType and eb.GetAttribute then
        local ok, v = pcall(eb.GetAttribute, eb, "chatType")
        chatType = ok and F.PlainString(v, nil) or nil
    end
    if not chatType then return nil end

    if chatType == "SAY" then return "SAY"
    elseif chatType == "YELL" then return "YELL"
    elseif chatType == "PARTY" or chatType == "PARTY_LEADER" then return "PARTY"
    elseif chatType == "RAID" or chatType == "RAID_LEADER" or chatType == "RAID_WARNING"
        or chatType == "INSTANCE_CHAT" or chatType == "INSTANCE_CHAT_LEADER" then
        return "RAID"
    elseif chatType == "GUILD" or chatType == "OFFICER" then return "GUILD"
    elseif chatType == "WHISPER" or chatType == "BN_WHISPER" then return "WHISPER"
    elseif chatType == "CHANNEL" then
        local cid = 0
        local okC, target
        if eb.GetChannelTarget then
            okC, target = pcall(eb.GetChannelTarget, eb)
        elseif eb.GetAttribute then
            okC, target = pcall(eb.GetAttribute, eb, "channelTarget")
        end
        if okC then
            -- 频道目标可能是数字，也可能是字符串形式的编号
            cid = F.PlainNumber(target, nil) or tonumber(F.PlainString(target, "")) or 0
        end
        if cid > 0 then
            local genId = FindChannelID("综合", { "综合", "general" })
            if genId and cid == genId then return "GENERAL" end
            local trdId = FindChannelID("交易", { "交易", "trade" })
            if trdId and cid == trdId then return IsVerticalMode() and "GENERAL" or "TRADE" end
            local wrdId = FindWorldChannel()
            if wrdId and cid == wrdId then return "WORLD" end
        end
    end
    return nil
end

----------------------------------------------------------------------
--  显隐与焦点让位（纯 EventRegistry + AnimationGroup，零污染）
----------------------------------------------------------------------
local function IsAnyEditBoxFocused()
    for i = 1, 10 do
        local eb = _G["ChatFrame" .. i .. "EditBox"]
        if eb and eb.HasFocus and eb:HasFocus() then
            return true
        end
    end
    return false
end

local activeDockMode = "left"

local function TargetAlpha()
    local db = mod:GetDB()
    if editBoxActive and activeDockMode == "bottom" then
        return 0
    end
    if db.combatFade == true and not isHovered then
        local inCombat = (_G.InCombatLockdown and _G.InCombatLockdown()) == true
        if not inCombat and _G.UnitAffectingCombat then
            local okC, c = pcall(_G.UnitAffectingCombat, "player")
            inCombat = okC and not F.IsSecret(c) and c == true
        end
        if inCombat then
            return (F.db and F.db.theme and F.db.theme.combatFadeAlpha) or 0.22
        end
    end
    if isHovered then
        return 1.0
    end
    if db.hoverReveal == true then
        return math_min(0.65, db.idleAlpha or 1.0)
    end
    return db.idleAlpha or 1.0
end

local euiIdleFadeHooked = false

local function IsEUIFadeLockstep()
    local db = mod:GetDB()
    if activeDockMode == "free" or db.hoverReveal == true or db.combatFade == true then
        return false
    end
    local _, _, bg1, chatNS = GetEUIChatContext()
    return (chatNS and chatNS._chatTabStrip ~= nil) or (bg1 ~= nil)
end

local function SetBarClickThrough(clickEnabled)
    if not barFrame then return end
    if barFrame.SetMouseClickEnabled then
        pcall(barFrame.SetMouseClickEnabled, barFrame, clickEnabled)
    end
    if barFrame.SetMouseMotionEnabled then
        pcall(barFrame.SetMouseMotionEnabled, barFrame, true)
    end
    if barFrame.GetChildren then
        for _, ch in ipairs({ barFrame:GetChildren() }) do
            if ch and not (ch.IsForbidden and ch:IsForbidden()) then
                if ch.SetMouseClickEnabled then
                    pcall(ch.SetMouseClickEnabled, ch, clickEnabled)
                end
                if ch.SetMouseMotionEnabled then
                    pcall(ch.SetMouseMotionEnabled, ch, true)
                end
            end
        end
    end
end

local function SyncAlpha(instant)
    if not barFrame then return end
    if not mod._active or (editBoxActive and activeDockMode == "bottom") then
        barFrame:Hide()
        if unifiedPanel and not mod._active then unifiedPanel:Hide() end
        return
    end
    barFrame:Show()
    local euiA = math_max(0, math_min(1, F.PlainNumber(euiChatLiveAlpha, 1) or 1))
    local goal
    if IsEUIFadeLockstep() then
        -- 停靠且未启用独立悬停/战斗淡出时，与 EUI 聊天框保持 1:1 逐帧锁步透明度（杜绝独立渐变抢跑或亮度错层）
        goal = euiA
        F.Theme.FadeTo(barFrame, euiA, 0)
    else
        goal = TargetAlpha() * euiA
        local cur = F.PlainNumber(barFrame:GetAlpha(), 1)
        F.Theme.FadeTo(barFrame, goal, instant and 0 or (goal > cur and 0.14 or 0.22))
    end
    -- 淡隐至不可见（< 0.05）时关闭点击接收（保留悬停唤醒），防止透明聊天条拦截下方点击（P3-15）
    SetBarClickThrough(goal >= 0.05)
    if unifiedPanel and unifiedPanel:IsShown() then
        unifiedPanel:SetAlpha(math_max(0, math_min(1.0, euiA)))
    end
end

local function WakeEUIChatFade()
    local _, _, _, _, echat = GetEUIChatContext()
    if echat and type(echat.ResetIdleTimer) == "function" then
        pcall(echat.ResetIdleTimer)
    end
end

local function HookEUIChatFadeSync()
    if type(_G.hooksecurefunc) ~= "function" then return end
    local _, cf1, bg1, chatNS, echat = GetEUIChatContext()
    local drivers = {}
    if chatNS and chatNS._chatTabStrip then drivers[#drivers + 1] = chatNS._chatTabStrip end
    if bg1 then drivers[#drivers + 1] = bg1 end
    if cf1 then drivers[#drivers + 1] = cf1 end
    for i, driver in ipairs(drivers) do
        if i <= 2 and driver.GetAlpha then
            local cur = F.PlainNumber(driver:GetAlpha(), nil)
            if cur ~= nil then
                euiChatLiveAlpha = math_max(0, math_min(1, cur))
            end
        end
        if not euiAlphaHooked[driver] then
            euiAlphaHooked[driver] = true
            _G.hooksecurefunc(driver, "SetAlpha", function(_, a)
                if not mod._active then return end
                local na = F.PlainNumber(a, nil)
                if na == nil then return end
                na = math_max(0, math_min(1, na))
                if math_abs(na - euiChatLiveAlpha) < 0.002 then return end
                euiChatLiveAlpha = na
                SyncAlpha(true)
            end)
        end
    end
    -- 鼠标停留在左侧快捷条上时，阻断 EUI 聊天闲置淡出计时器把聊天框单独淡暗
    if not euiIdleFadeHooked and echat and type(echat.SetIdleFadeAlpha) == "function" then
        euiIdleFadeHooked = true
        _G.hooksecurefunc(echat, "SetIdleFadeAlpha", function(a)
            if not mod._active then return end
            local na = F.PlainNumber(a, 1) or 1
            if na < 0.99 and barFrame and barFrame.IsMouseOver and barFrame:IsMouseOver() then
                C_Timer.After(0, function()
                    if mod._active and barFrame and barFrame:IsMouseOver() then
                        WakeEUIChatFade()
                    end
                end)
            end
        end)
    end
end

local function UpdateUtilButtonState(btn)
    if not btn then return end
    local ar, ag, ab = F.Theme.GetAccent()
    local hovered = btn._isHovered == true
    local isScrollHot = (btn._def.id == "scroll") and IsChatScrolledUp()

    if hovered then
        btn._activeBg:Show()
        btn._activeBg:SetAlpha(0.75)
        if btn._icon then btn._icon:SetVertexColor(ar, ag, ab, 1.0) end
        if btn._glyph then btn._glyph:SetTextColor(ar, ag, ab, 1.0) end
    elseif isScrollHot then
        btn._activeBg:Show()
        btn._activeBg:SetAlpha(0.32)
        if btn._icon then btn._icon:SetVertexColor(ar, ag, ab, 0.96) end
        if btn._glyph then btn._glyph:SetTextColor(ar, ag, ab, 0.96) end
    else
        btn._activeBg:Hide()
        local baseA = (btn._def.id == "scroll") and 0.42 or 0.58
        if btn._icon then btn._icon:SetVertexColor(0.88, 0.90, 0.94, baseA) end
        if btn._glyph then btn._glyph:SetTextColor(0.82, 0.85, 0.90, baseA) end
    end
end

UpdateScrollIndicator = function()
    for _, ubtn in ipairs(utilButtons) do
        if ubtn._def.id == "scroll" then
            UpdateUtilButtonState(ubtn)
            break
        end
    end
end

local function UpdateButtonState(btn)
    if not btn then return end
    local db = mod:GetDB()
    local ch = btn._ch
    local hovered = btn._isHovered == true
    local active = (db.showActiveChannel ~= false) and (activeChannelKey == ch.key) and (ch.key ~= "ROLL")
    local vert = IsVerticalMode()

    if hovered then
        if not vert then btn._tileBg:Hide() end
        btn._activeBg:Show()
        btn._activeBg:SetAlpha(vert and 0.65 or 1.0)
        btn._underline:Show()
        btn._underline:SetAlpha(1.0)
        btn._lbl:SetTextColor(1, 1, 1, 1)
    elseif active then
        if not vert then btn._tileBg:Hide() end
        btn._activeBg:Show()
        btn._activeBg:SetAlpha(vert and 0.42 or 0.86)
        btn._underline:Show()
        btn._underline:SetAlpha(0.95)
        if db.tintChannelText ~= false then
            btn._lbl:SetTextColor(
                math_min(1, ch.color[1] + 0.08),
                math_min(1, ch.color[2] + 0.08),
                math_min(1, ch.color[3] + 0.08), 1)
        else
            btn._lbl:SetTextColor(1, 1, 1, 1)
        end
    else
        if vert then
            btn._tileBg:Hide()
        else
            btn._tileBg:Show()
        end
        btn._activeBg:Hide()
        btn._underline:Hide()
        if db.tintChannelText ~= false then
            btn._lbl:SetTextColor(ch.color[1], ch.color[2], ch.color[3], 0.92)
        else
            btn._lbl:SetTextColor(0.82, 0.85, 0.89, 0.90)
        end
    end
end

local function RefreshActiveChannel(overrideKey)
    if overrideKey ~= nil then
        activeChannelKey = overrideKey
    else
        activeChannelKey = DetectActiveChannelKey()
    end
    for _, btn in ipairs(chanButtons) do
        UpdateButtonState(btn)
    end
end

----------------------------------------------------------------------
--  竖向左侧融合布局 & 横向等宽布局
----------------------------------------------------------------------
LayoutButtons = function()
    if not barFrame then return end
    local EUI, _, _, _, _, ecfg, onePx = GetEUIChatContext()
    local pp = EUI and EUI.PP
    local vert = IsVerticalMode()

    if vert then
        local w = F.PlainNumber(barFrame:GetWidth(), RAIL_WIDTH)
        local h = F.PlainNumber(barFrame:GetHeight(), 240)
        if w < 20 then w = RAIL_WIDTH end
        if h < 140 then h = 240 end

        local topUtils, botUtils = {}, {}
        for _, ubtn in ipairs(utilButtons) do
            ubtn:Show()
            if ubtn._def.zone == "top" then
                topUtils[#topUtils + 1] = ubtn
            else
                botUtils[#botUtils + 1] = ubtn
            end
        end

        local utilH = math_max(18, math_min(22, math_floor(h * 0.082)))
        local topY = 3
        for _, ubtn in ipairs(topUtils) do
            ubtn:ClearAllPoints()
            ubtn:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 1, -topY)
            ubtn:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", -1, -topY)
            ubtn:SetHeight(utilH)
            topY = topY + utilH + 1
        end

        if utilDivTop then
            utilDivTop:ClearAllPoints()
            utilDivTop:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 5, -(topY + 2))
            utilDivTop:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", -5, -(topY + 2))
            utilDivTop:SetHeight(onePx)
            utilDivTop:Show()
            topY = topY + 6
        end

        local botY = 3
        for _, ubtn in ipairs(botUtils) do
            ubtn:ClearAllPoints()
            ubtn:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 1, botY)
            ubtn:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -1, botY)
            ubtn:SetHeight(utilH)
            botY = botY + utilH + 1
        end

        if utilDivBot then
            utilDivBot:ClearAllPoints()
            utilDivBot:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 5, botY + 2)
            utilDivBot:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -5, botY + 2)
            utilDivBot:SetHeight(onePx)
            utilDivBot:Show()
            botY = botY + 6
        end

        local visibleChans = GetOrderedChannelButtons(true)

        local n = #visibleChans
        if n > 0 then
            local usableH = math_max(n * 14, h - topY - botY)
            for i, btn in ipairs(visibleChans) do
                local y0 = topY + math_floor(((i - 1) * usableH / n) + 0.5)
                local y1 = topY + math_floor((i * usableH / n) + 0.5)
                local bh = math_max(14, y1 - y0)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, -y0)
                btn:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, -y0)
                btn:SetHeight(bh)
                if btn._sep then btn._sep:Hide() end
                if btn._underline then
                    btn._underline:ClearAllPoints()
                    btn._underline:SetWidth(2)
                    btn._underline:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -2)
                    btn._underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 2)
                end
            end
        end
        return
    end

    -- 横向模式（top / bottom / free）：隐藏竖栏专用工具钮，按 EUI 标签间距像素等宽排列
    for _, ubtn in ipairs(utilButtons) do ubtn:Hide() end
    if utilDivTop then utilDivTop:Hide() end
    if utilDivBot then utilDivBot:Hide() end

    local w = F.PlainNumber(barFrame:GetWidth(), 418)
    local h = F.PlainNumber(barFrame:GetHeight(), 22)
    if w < 180 then w = 418 end
    if h < 16 then h = 22 end

    local visibleChans = GetOrderedChannelButtons(false)
    local n = #visibleChans
    if n == 0 then return end

    local extendBg = ecfg and ecfg.extendBgBehindTabs == true
    local gapPx = extendBg and 0 or ((ecfg and ecfg.tabSpacing or 1) * onePx)
    if gapPx < 0 then gapPx = 0 end
    if gapPx > 4 then gapPx = 4 end

    local totalGaps = gapPx * (n - 1)
    local usableW = math_max(n * 16, w - totalGaps)

    for i, btn in ipairs(visibleChans) do
        local x0 = math_floor(((i - 1) * usableW / n) + 0.5) + (i - 1) * gapPx
        local x1 = (i == n) and w or (math_floor((i * usableW / n) + 0.5) + (i - 1) * gapPx)
        local bw = math_max(12, x1 - x0)

        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", barFrame, "TOPLEFT", x0, 0)
        btn:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", x0, 0)
        btn:SetWidth(bw)

        if btn._sep then
            if extendBg and i < n and not (ecfg and ecfg.hideBorders) then
                btn._sep:SetWidth(onePx)
                if pp and pp.DisablePixelSnap then pp.DisablePixelSnap(btn._sep) end
                btn._sep:Show()
            else
                btn._sep:Hide()
            end
        end
        if btn._underline then
            btn._underline:ClearAllPoints()
            btn._underline:SetHeight(onePx)
            btn._underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
            btn._underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
            if pp and pp.DisablePixelSnap then pp.DisablePixelSnap(btn._underline) end
        end
    end
end

local MeasureTabTopExtension -- 前向声明
local MeasureTabRightExtension -- 前向声明
local euiTabSyncHooked = false
local CHAT_LINE_SPACING = 3
local CHAT_SPACING_ALPHABETS = { "roman", "russian", "simplifiedchinese", "traditionalchinese" }

-- 修正 EUI 聊天引擎仅给韩语加 3px 行距、简体中文行距为 0 导致鸿蒙字体上下轻微贴字/压字的问题：
-- 同步给 EUIChatFontFamily1..10 的中英文成员补足 3px 行距（EUI 可见框与暴雪底层链接热区共享同一字体族，1:1 对齐且零污染）
local function ApplyChatFontSpacingToFamily(fam, spacing)
    if not (fam and fam.GetFontObjectForAlphabet) then return end
    for _, alpha in ipairs(CHAT_SPACING_ALPHABETS) do
        local ok, member = pcall(fam.GetFontObjectForAlphabet, fam, alpha)
        if ok and member and member.SetSpacing then
            pcall(member.SetSpacing, member, spacing)
        end
    end
end

local function SyncChatLineSpacing(reapplyEngine)
    local spacing = mod._active and CHAT_LINE_SPACING or 0
    for i = 1, 10 do
        local fam = _G["EUIChatFontFamily" .. i]
        if fam then
            ApplyChatFontSpacingToFamily(fam, spacing)
        end
    end
    if reapplyEngine then
        local _, _, _, _, echat = GetEUIChatContext()
        if echat and type(echat.EngineApplyFonts) == "function" then
            pcall(echat.EngineApplyFonts)
        end
    end
end

----------------------------------------------------------------------
--  统一圆角一体化聊天玻璃底板（左侧栏 + 顶部标签栏 + 聊天正文同底同圆角，零污染）
----------------------------------------------------------------------
local function EnsureUnifiedPanel()
    if unifiedPanel then return unifiedPanel end
    local p = CreateFrame("Frame", "kkowoUI_ChatUnifiedPanel", _G.UIParent)
    p:SetFrameStrata("BACKGROUND")
    p:SetFrameLevel(1)
    p:EnableMouse(false)

    local fill = p:CreateTexture(nil, "BACKGROUND", nil, -6)
    fill:SetAllPoints(p)
    fill:SetColorTexture(0.042, 0.048, 0.064, 0.64)

    local sheen = p:CreateTexture(nil, "BACKGROUND", nil, -5)
    sheen:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    sheen:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    sheen:SetHeight(32)
    sheen:SetTexture(F.StyleTokens and F.StyleTokens.TEX.FLAT or "Interface\\Buttons\\WHITE8X8")
    if F.StyleTokens then
        F.StyleTokens.ApplyGradient(sheen, "VERTICAL", 1, 1, 1, 0.00, 1, 1, 1, 0.05)
    else
        sheen:SetVertexColor(1, 1, 1, 0.03)
    end

    local vSep = p:CreateTexture(nil, "ARTWORK", nil, 2)
    vSep:SetWidth(1)
    vSep:SetColorTexture(1, 1, 1, 0.08)
    vSep:Hide()

    local hSep = p:CreateTexture(nil, "ARTWORK", nil, 2)
    hSep:SetHeight(1)
    hSep:SetColorTexture(1, 1, 1, 0.08)
    hSep:Hide()

    p._fill = fill
    p._sheen = sheen
    p._vSep = vSep
    p._hSep = hSep
    p:Hide()
    unifiedPanel = p
    return p
end

local function IsAnyDockedChatShown()
    for i = 1, 10 do
        local cf = _G["ChatFrame" .. i]
        if cf and cf.IsShown and cf:IsShown() then
            return true
        end
    end
    return false
end

local function SetEUIBgMuted(bg1, chatNS, muted)
    local EUI = _G.EllesmereUI
    local cfd = EUI and EUI._chatCFD
    -- 同步静音全部停靠标签页（综合/战斗记录/私聊/队伍/公会/世界）各自独立的方形底板，避免切标签变色
    local targets = {}
    if bg1 then targets[bg1] = true end
    if cfd then
        for i = 1, 10 do
            local cf = _G["ChatFrame" .. i]
            local d = cf and cfd(cf)
            if d and d.bg then targets[d.bg] = true end
        end
    end
    for bg in pairs(targets) do
        if bg and bg.GetRegions then
            for _, reg in ipairs({ bg:GetRegions() }) do
                if reg and reg.GetObjectType and reg:GetObjectType() == "Texture" then
                    if muted then
                        mutedBgFrames[reg] = true
                        pcall(reg.SetAlpha, reg, 0)
                    elseif mutedBgFrames[reg] then
                        mutedBgFrames[reg] = nil
                        pcall(reg.SetAlpha, reg, 1)
                    end
                end
            end
        end
    end
    if chatNS then
        for _, key in ipairs({ "_chatBgExt", "_chatPanelBorder" }) do
            local obj = chatNS[key]
            if obj and obj.SetAlpha then
                if muted then
                    mutedBgFrames[obj] = true
                    pcall(obj.SetAlpha, obj, 0)
                elseif mutedBgFrames[obj] then
                    mutedBgFrames[obj] = nil
                    pcall(obj.SetAlpha, obj, 1)
                end
            end
        end
    end
    -- 战斗记录顶部过滤条（我的动作 / 我发生了什么？）同步改为清透圆角玻璃，不再出现刺眼纯黑长条
    local qb = _G.CombatLogQuickButtonFrame_Custom
    if qb and not (qb.IsForbidden and qb:IsForbidden()) then
        local ST = F.StyleTokens
        local qbTex = _G.CombatLogQuickButtonFrame_CustomTexture
        local glass = combatLogGlass[qb]
        if muted then
            if qbTex and qbTex.SetAlpha then pcall(qbTex.SetAlpha, qbTex, 0) end
            if qb.GetRegions then
                for _, reg in ipairs({ qb:GetRegions() }) do
                    if reg and reg ~= glass and reg.GetObjectType and reg:GetObjectType() == "Texture" then
                        mutedBgFrames[reg] = true
                        pcall(reg.SetAlpha, reg, 0)
                    end
                end
            end
            if ST and not glass then
                local g = qb:CreateTexture(nil, "BACKGROUND", nil, -4)
                g:SetPoint("TOPLEFT", qb, "TOPLEFT", 2, -1)
                g:SetPoint("BOTTOMRIGHT", qb, "BOTTOMRIGHT", -2, 1)
                g:SetColorTexture(0.05, 0.06, 0.08, 0.28)
                ST.MaskTexture(qb, g, 5)
                combatLogGlass[qb] = g
            elseif glass then
                glass:SetAlpha(1)
                glass:Show()
            end
        else
            if glass then glass:Hide() end
            if ST then ST.ClearRoundedMask(qb) end
            if qbTex and qbTex.SetAlpha then pcall(qbTex.SetAlpha, qbTex, 1) end
            if qb.GetRegions then
                for _, reg in ipairs({ qb:GetRegions() }) do
                    if reg ~= glass and mutedBgFrames[reg] then
                        mutedBgFrames[reg] = nil
                        pcall(reg.SetAlpha, reg, 1)
                    end
                end
            end
        end
    end
end

local chatBarDebug = { syncCount = 0, syncChecks = 0, anchorCount = 0 }
F._chatBarDebug = chatBarDebug
local lastUnifiedSig = nil
local lastAnchorSig = nil
local lastObservedSel = nil
local bgHideQueued = false

SyncUnifiedChatPanel = function(force)
    chatBarDebug.syncChecks = chatBarDebug.syncChecks + 1
    local ST = F.StyleTokens
    local db = mod:GetDB()
    local EUI, _, bg1, chatNS, _, ecfg, onePx = GetEUIChatContext()
    local want = mod._active == true and db.unifiedRoundedPanel ~= false and ST ~= nil
    local pp = EUI and EUI.PP

    if not want then
        lastUnifiedSig = nil
        chatBarDebug.syncCount = chatBarDebug.syncCount + 1
        SetEUIBgMuted(bg1, chatNS, false)
        if unifiedPanel then unifiedPanel:Hide() end
        if barFrame and ST then ST.ClearRoundedMask(barFrame) end
        return
    end

    local rad = math_max(4, math_min(14, F.PlainNumber(db.panelRadius, ST.GetCornerRadius(8)) or 8))
    local alpha = math_max(0.12, math_min(0.85, F.PlainNumber(db.panelAlpha, 0.24) or 0.24))
    local gc = ST.COLORS.glass
    local mode = activeDockMode or db.dockMode or "left"

    if not bg1 then
        lastUnifiedSig = nil
        chatBarDebug.syncCount = chatBarDebug.syncCount + 1
        if unifiedPanel then unifiedPanel:Hide() end
        if barFrame and barFrame._unifiedBg then
            barFrame._unifiedBg:SetColorTexture(gc[1], gc[2], gc[3], alpha)
            barFrame._unifiedBg:Show()
            ST.MaskTexture(barFrame, barFrame._unifiedBg, rad)
            ST.ApplyRoundedBorder(barFrame, rad, 0.18, 0.22, 0.30, 0.46, 5)
        end
        return
    end

    local topExt = MeasureTabTopExtension and MeasureTabTopExtension(bg1, chatNS, ecfg) or 24
    local rightExt = MeasureTabRightExtension and MeasureTabRightExtension(bg1, chatNS) or 0
    local wantShown = IsAnyDockedChatShown() or (barFrame and barFrame:IsShown()) or false
    local qb = _G.CombatLogQuickButtonFrame_Custom
    local qbShown = (qb and not (qb.IsForbidden and qb:IsForbidden()) and qb.IsShown and qb:IsShown()) and true or false
    local sig = mode .. "|" .. tostring(rad) .. "|" .. tostring(alpha) .. "|" .. tostring(topExt)
        .. "|" .. tostring(rightExt) .. "|" .. tostring(wantShown) .. "|" .. tostring(qbShown)
    if (not force) and unifiedPanel and lastUnifiedSig == sig then
        if unifiedPanel:IsShown() ~= wantShown then
            unifiedPanel:SetShown(wantShown)
        end
        return
    end
    lastUnifiedSig = sig
    chatBarDebug.syncCount = chatBarDebug.syncCount + 1

    SetEUIBgMuted(bg1, chatNS, true)

    local p = EnsureUnifiedPanel()
    p._fill:SetColorTexture(gc[1], gc[2], gc[3], alpha)
    ST.MaskTexture(p, p._fill, rad)
    -- 整块底板只保留一层均匀玻璃 + 极淡圆角描边：去掉顶部高光带与内部分隔线，左侧栏 / 标签 / 正文浑然一体
    p._sheen:Hide()
    ST.ApplyRoundedBorder(p, rad, 0.30, 0.34, 0.40, 0.26, 5)

    p:ClearAllPoints()
    p._vSep:Hide()
    p._hSep:Hide()

    if mode == "left" and barFrame then
        ST.ClearRoundedMask(barFrame)
        if barFrame._unifiedBg then barFrame._unifiedBg:Hide() end
        if barFrame._rightSep then barFrame._rightSep:Hide() end
        p:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
        p:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 0, 0)
        p:SetPoint("BOTTOMRIGHT", bg1, "BOTTOMRIGHT", rightExt, 0)

        p._vSep:ClearAllPoints()
        p._vSep:SetWidth(onePx)
        if pp and pp.DisablePixelSnap then pp.DisablePixelSnap(p._vSep) end
        p._vSep:SetPoint("TOPLEFT", barFrame, "TOPRIGHT", 0, -6)
        p._vSep:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMRIGHT", 0, 6)
        p._vSep:Hide()

        p._hSep:ClearAllPoints()
        p._hSep:SetHeight(onePx)
        if pp and pp.DisablePixelSnap then pp.DisablePixelSnap(p._hSep) end
        p._hSep:SetPoint("TOPLEFT", bg1, "TOPLEFT", 2, 0)
        p._hSep:SetPoint("TOPRIGHT", bg1, "TOPRIGHT", rightExt - 6, 0)
        p._hSep:Hide()
    elseif mode == "top" and barFrame then
        ST.ClearRoundedMask(barFrame)
        if barFrame._unifiedBg then barFrame._unifiedBg:Hide() end
        p:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
        p:SetPoint("BOTTOMRIGHT", bg1, "BOTTOMRIGHT", rightExt, 0)

        p._hSep:ClearAllPoints()
        p._hSep:SetHeight(onePx)
        p._hSep:SetPoint("TOPLEFT", bg1, "TOPLEFT", 6, 0)
        p._hSep:SetPoint("TOPRIGHT", bg1, "TOPRIGHT", rightExt - 6, 0)
        p._hSep:Hide()
    elseif mode == "bottom" and barFrame then
        ST.ClearRoundedMask(barFrame)
        if barFrame._unifiedBg then barFrame._unifiedBg:Hide() end
        p:SetPoint("TOPLEFT", bg1, "TOPLEFT", 0, topExt)
        p:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)

        p._hSep:ClearAllPoints()
        p._hSep:SetHeight(onePx)
        p._hSep:SetPoint("TOPLEFT", bg1, "TOPLEFT", 6, 0)
        p._hSep:SetPoint("TOPRIGHT", bg1, "TOPRIGHT", rightExt - 6, 0)
        p._hSep:Hide()
    else
        -- 自由模式：聊天本体与自由聊天条各自拥有一致的圆角玻璃底板
        p:SetPoint("TOPLEFT", bg1, "TOPLEFT", 0, topExt)
        p:SetPoint("BOTTOMRIGHT", bg1, "BOTTOMRIGHT", rightExt, 0)
        p._hSep:ClearAllPoints()
        p._hSep:SetHeight(onePx)
        p._hSep:SetPoint("TOPLEFT", bg1, "TOPLEFT", 6, 0)
        p._hSep:SetPoint("TOPRIGHT", bg1, "TOPRIGHT", -6, 0)
        p._hSep:Hide()
        if barFrame and barFrame._unifiedBg then
            barFrame._unifiedBg:SetColorTexture(gc[1], gc[2], gc[3], alpha)
            barFrame._unifiedBg:Show()
            ST.MaskTexture(barFrame, barFrame._unifiedBg, 6)
            ST.ApplyRoundedBorder(barFrame, 6, 0.16, 0.19, 0.26, 0.84, 5)
        end
    end

    p:SetShown(IsAnyDockedChatShown() or (barFrame and barFrame:IsShown()))
end

local function ApplyVisuals()
    if not barFrame then return end
    local ST = F.StyleTokens
    local db = mod:GetDB()
    local EUI, _, _, chatNS, echat, ecfg, onePx = GetEUIChatContext()
    local tabTex = ResolveEUITabTexture(EUI, chatNS, echat, ecfg)
    local fontPath, fontSize, fontFlag = ResolveEUITabFont(EUI, echat, ecfg)
    local bgR, bgG, bgB, bgA, actR, actG, actB, actA, ulR, ulG, ulB, ulA =
        ResolveEUITabColors(EUI, ecfg)
    local extendBg = ecfg and ecfg.extendBgBehindTabs == true
    local hideBorders = ecfg and ecfg.hideBorders == true
    local unifiedOn = db.unifiedRoundedPanel ~= false and ST ~= nil
    local pp = EUI and EUI.PP
    local vert = IsVerticalMode()

    if barFrame._unifiedBg then
        if unifiedOn and (db.dockMode or "left") ~= "free" then
            barFrame._unifiedBg:Hide()
        elseif vert then
            local railA = math_max(0.46, math_min(0.78, bgA))
            barFrame._unifiedBg:SetColorTexture(bgR, bgG, bgB, railA)
            barFrame._unifiedBg:Show()
        elseif extendBg then
            barFrame._unifiedBg:SetColorTexture(bgR, bgG, bgB, bgA)
            barFrame._unifiedBg:Show()
        else
            barFrame._unifiedBg:Hide()
        end
    end

    if barFrame._rightSep then
        if vert and not hideBorders and not unifiedOn then
            barFrame._rightSep:SetWidth(onePx)
            if pp and pp.DisablePixelSnap then pp.DisablePixelSnap(barFrame._rightSep) end
            barFrame._rightSep:SetColorTexture(1, 1, 1, 0.08)
            barFrame._rightSep:Show()
        else
            barFrame._rightSep:Hide()
        end
    end

    if barFrame._bottomSep then
        if (not vert) and extendBg and not hideBorders and not unifiedOn then
            barFrame._bottomSep:SetHeight(onePx)
            if pp and pp.DisablePixelSnap then pp.DisablePixelSnap(barFrame._bottomSep) end
            barFrame._bottomSep:SetColorTexture(1, 1, 1, 0.08)
            barFrame._bottomSep:Show()
        else
            barFrame._bottomSep:Hide()
        end
    end

    if utilDivTop then utilDivTop:SetColorTexture(1, 1, 1, 0.11) end
    if utilDivBot then utilDivBot:SetColorTexture(1, 1, 1, 0.11) end

    for _, ubtn in ipairs(utilButtons) do
        if ubtn._activeBg then
            ubtn._activeBg:SetColorTexture(actR, actG, actB, 0.35)
            ubtn._activeBg:ClearAllPoints()
            if unifiedOn then
                ubtn._activeBg:SetPoint("TOPLEFT", ubtn, "TOPLEFT", 2, -1)
                ubtn._activeBg:SetPoint("BOTTOMRIGHT", ubtn, "BOTTOMRIGHT", -2, 1)
                ST.MaskTexture(ubtn, ubtn._activeBg, 4)
            else
                ubtn._activeBg:SetAllPoints(ubtn)
                if ST then ST.ClearRoundedMask(ubtn) end
            end
        end
        if ubtn._glyph and ubtn._glyph.SetFont then
            pcall(ubtn._glyph.SetFont, ubtn._glyph, fontPath, 11, fontFlag)
        end
        UpdateUtilButtonState(ubtn)
    end

    local chanFontSz = vert and math_max(11, math_min(13, fontSize)) or fontSize
    for _, btn in ipairs(chanButtons) do
        if btn._lbl and btn._lbl.SetFont then
            pcall(btn._lbl.SetFont, btn._lbl, fontPath, chanFontSz, fontFlag)
            if fontFlag == "" then
                btn._lbl:SetShadowColor(0, 0, 0, 0.88)
                btn._lbl:SetShadowOffset(1, -1)
            else
                btn._lbl:SetShadowColor(0, 0, 0, 0.45)
                btn._lbl:SetShadowOffset(0, 0)
            end
        end

        if vert or extendBg or unifiedOn then
            btn._tileBg:SetColorTexture(0, 0, 0, 0)
        elseif tabTex then
            btn._tileBg:SetTexture(tabTex)
            btn._tileBg:SetVertexColor(bgR, bgG, bgB, bgA)
        else
            btn._tileBg:SetVertexColor(1, 1, 1, 1)
            btn._tileBg:SetColorTexture(bgR, bgG, bgB, bgA)
        end

        btn._activeBg:ClearAllPoints()
        if unifiedOn then
            btn._activeBg:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -1)
            btn._activeBg:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 1)
            ST.MaskTexture(btn, btn._activeBg, 4)
        else
            btn._activeBg:SetAllPoints(btn)
            if ST then ST.ClearRoundedMask(btn) end
        end

        if vert then
            btn._activeBg:SetVertexColor(1, 1, 1, 1)
            btn._activeBg:SetColorTexture(actR, actG, actB, 0.42)
        elseif tabTex and not unifiedOn then
            btn._activeBg:SetTexture(tabTex)
            if btn._activeBg.SetGradient and _G.CreateColor then
                btn._activeBg:SetGradient("VERTICAL",
                    _G.CreateColor(actR, actG, actB, actA),
                    _G.CreateColor(actR * 0.65, actG * 0.65, actB * 0.65, math_max(0.18, actA * 0.42)))
            else
                btn._activeBg:SetVertexColor(actR, actG, actB, actA)
            end
        else
            btn._activeBg:SetVertexColor(1, 1, 1, 1)
            btn._activeBg:SetColorTexture(actR, actG, actB, unifiedOn and 0.36 or actA)
        end

        btn._underline:SetColorTexture(ulR, ulG, ulB, ulA)
        if btn._sep then
            btn._sep:SetColorTexture(1, 1, 1, 0.06)
        end

        UpdateButtonState(btn)
    end

    LayoutButtons()
    SyncUnifiedChatPanel(true)
    SyncAlpha(true)
end

----------------------------------------------------------------------
--  精准锚定至 EllesmereUIChat（100% 脱离暴雪 ChatFrame1 锚点链）
----------------------------------------------------------------------
local function ComputeBarHeight(ecfg)
    local tabH = ecfg and F.PlainNumber(ecfg.tabHeight, 24) or 24
    return math_max(20, math_min(24, tabH - 2))
end

MeasureTabTopExtension = function(bg1, chatNS, ecfg)
    local tabH = ecfg and F.PlainNumber(ecfg.tabHeight, 24) or 24
    local tabPad = ecfg and F.PlainNumber(ecfg.tabPadding, 0) or 0
    local ext = chatNS and chatNS._chatBgExt
    local bgTop = bg1 and bg1.GetTop and F.PlainNumber(bg1:GetTop(), nil)
    if ext and ext:IsShown() and ext.GetTop and bgTop then
        local extTop = F.PlainNumber(ext:GetTop(), nil)
        if extTop and (extTop - bgTop) >= 12 and (extTop - bgTop) <= 60 then
            return extTop - bgTop
        end
    end
    local tab1 = _G.ChatFrame1Tab
    local tabBot = tab1 and tab1.GetBottom and F.PlainNumber(tab1:GetBottom(), nil)
    if bgTop and tabBot then
        local measured = (tabBot + tabH) - bgTop
        if measured >= 14 and measured <= 56 then
            return measured
        end
    end
    return tabH + tabPad
end

-- 测量停靠聊天标签栏右侧超出 bg1 的像素宽度（隐藏 EUI 原右侧边栏后，最右侧如「公会」标签会超出 bg1 右缘；
-- 纯只读测量，不改暴雪标签位置与 GeneralDockManager，零污染，确保所有标签严丝合缝留在圆角玻璃框内）
MeasureTabRightExtension = function(bg1, chatNS)
    local bgR = bg1 and bg1.GetRight and F.PlainNumber(bg1:GetRight(), nil)
    if not bgR then return 0 end
    local bgS = bg1.GetEffectiveScale and F.PlainNumber(bg1:GetEffectiveScale(), 1) or 1
    if bgS <= 0 then bgS = 1 end
    local maxR = bgR
    local function consider(f)
        if not f or (f.IsForbidden and f:IsForbidden()) then return end
        if f.IsShown and not f:IsShown() then return end
        if not f.GetRight then return end
        local r = F.PlainNumber(f:GetRight(), nil)
        if not r then return end
        local es = f.GetEffectiveScale and F.PlainNumber(f:GetEffectiveScale(), bgS) or bgS
        if es <= 0 then es = bgS end
        r = r * es / bgS
        if r > maxR then maxR = r end
    end
    local dock = _G.GENERAL_CHAT_DOCK
    if dock and type(dock.DOCKED_CHAT_FRAMES) == "table" then
        for _, cf in ipairs(dock.DOCKED_CHAT_FRAMES) do
            if cf and cf.GetName then
                local nm = F.PlainString(cf:GetName(), nil)
                if nm then consider(_G[nm .. "Tab"]) end
            end
        end
    else
        for i = 1, 10 do
            local cf = _G["ChatFrame" .. i]
            if cf and cf.isDocked then
                consider(_G["ChatFrame" .. i .. "Tab"])
            end
        end
    end
    if chatNS and chatNS._chatTabStrip then
        consider(chatNS._chatTabStrip)
    end
    local gdm = _G.GeneralDockManager
    if gdm and gdm.overflowButton then
        consider(gdm.overflowButton)
    end
    local over = maxR - bgR
    if over <= 0.5 then return 0 end
    return math_min(64, math_floor(over + 0.5) + 4)
end

-- EUI 聊天底板尺寸变化：单一钩子、按当前停靠模式动态分派，并合并到下一帧只跑一次
-- （此前左侧/横栏两套分支共用 bgSizeHooked 标记，先装哪套就永远是哪套，切模式后失效且拖拽时每像素重排 3~4 次）
local ApplyAnchor
local bgResizeQueued = false

local function DockFollowsChat()
    return mod._active and mod:GetDB().dockMode ~= "free"
end

local function OnBgResize()
    if bgResizeQueued or not DockFollowsChat() then return end
    bgResizeQueued = true
    C_Timer.After(0, function()
        bgResizeQueued = false
        if not DockFollowsChat() then return end
        if IsVerticalMode() then
            ApplyAnchor() -- 左侧模式下 ApplyAnchor 会自行排程 LayoutButtons
        else
            LayoutButtons()
            SyncUnifiedChatPanel()
        end
    end)
end

local function OnBgShow()
    -- 切回「综合」标签时 bg1 重新显示，不盲目重设锚点；仅做当帧差分同步（几何未变则零写入）
    if DockFollowsChat() then
        SyncUnifiedChatPanel(false)
    end
end

local function HookBgResize(bg1)
    if not bg1 or bgSizeHooked[bg1] then return end
    bgSizeHooked[bg1] = true
    bg1:HookScript("OnSizeChanged", OnBgResize)
    bg1:HookScript("OnShow", OnBgShow)
    bg1:HookScript("OnHide", function()
        -- 切换到「战斗记录 / 私聊 / 队伍 / 公会 / 世界」时 ChatFrame1 的 bg1 会暂时隐藏，
        -- 绝不能因此藏掉统一底板；合并去重到下一帧仅当所有停靠聊天框均隐藏时才收起。
        if bgHideQueued then return end
        bgHideQueued = true
        C_Timer.After(0, function()
            bgHideQueued = false
            if not mod._active then return end
            if unifiedPanel and not IsAnyDockedChatShown() then
                unifiedPanel:Hide()
            else
                SyncUnifiedChatPanel(false)
            end
        end)
    end)
end

ApplyAnchor = function(force)
    if not barFrame then return end
    HookEUIChatFadeSync()
    local db = mod:GetDB()
    local mode = db.dockMode or "left"
    local _, cf1, bg1, chatNS, _, ecfg, onePx = GetEUIChatContext()
    local barH = ComputeBarHeight(ecfg)
    local gapPx = (ecfg and ecfg.extendBgBehindTabs == true) and 0 or ((ecfg and ecfg.tabSpacing or 1) * onePx)

    local effectiveMode = mode
    if mode == "bottom" then
        local bot = (bg1 and bg1.GetBottom and F.PlainNumber(bg1:GetBottom(), nil))
            or (cf1 and cf1.GetBottom and F.PlainNumber(cf1:GetBottom(), 30)) or 30
        if bot < (barH + 4) then
            effectiveMode = "top"
        end
    end
    activeDockMode = effectiveMode

    if (not force) and bg1 and effectiveMode ~= "free" then
        local topExtChk = MeasureTabTopExtension(bg1, chatNS, ecfg)
        local rightExtChk = MeasureTabRightExtension and MeasureTabRightExtension(bg1, chatNS) or 0
        local bgWChk = math_floor((bg1.GetWidth and F.PlainNumber(bg1:GetWidth(), 0) or 0) + 0.5)
        local bgHChk = math_floor((bg1.GetHeight and F.PlainNumber(bg1:GetHeight(), 0) or 0) + 0.5)
        local aSig = effectiveMode .. "|" .. tostring(topExtChk) .. "|" .. tostring(rightExtChk)
            .. "|" .. tostring(gapPx) .. "|" .. tostring(barH) .. "|" .. tostring(bgWChk) .. "|" .. tostring(bgHChk)
        if lastAnchorSig == aSig then
            SyncUnifiedChatPanel(false)
            return
        end
        lastAnchorSig = aSig
    else
        lastAnchorSig = nil
    end

    chatBarDebug.anchorCount = chatBarDebug.anchorCount + 1
    barFrame:ClearAllPoints()

    if effectiveMode == "left" then
        EnsureLeftDockRoom()
        barFrame:SetWidth(RAIL_WIDTH)
        if bg1 then
            HookBgResize(bg1)
            local topExt = MeasureTabTopExtension(bg1, chatNS, ecfg)
            local xGap = (ecfg and ecfg.extendBgBehindTabs == true) and 0 or onePx
            barFrame:SetPoint("TOPRIGHT", bg1, "TOPLEFT", -xGap, topExt)
            barFrame:SetPoint("BOTTOMRIGHT", bg1, "BOTTOMLEFT", -xGap, 0)
        elseif cf1 then
            local l = cf1.GetLeft and F.PlainNumber(cf1:GetLeft(), nil)
            local t = cf1.GetTop and F.PlainNumber(cf1:GetTop(), nil)
            local b = cf1.GetBottom and F.PlainNumber(cf1:GetBottom(), nil)
            if l and t and b and (t - b) >= 100 then
                local rx = math_max(RAIL_WIDTH + 2, l - 4)
                barFrame:SetPoint("TOPRIGHT", _G.UIParent, "BOTTOMLEFT", rx, t + 26)
                barFrame:SetPoint("BOTTOMRIGHT", _G.UIParent, "BOTTOMLEFT", rx, b - 4)
            else
                barFrame:SetSize(RAIL_WIDTH, 240)
                barFrame:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", 4, 24)
            end
        else
            barFrame:SetSize(RAIL_WIDTH, 240)
            barFrame:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", 4, 24)
        end
        C_Timer.After(0, function()
            LayoutButtons()
            SyncUnifiedChatPanel()
        end)
        SyncUnifiedChatPanel()
        SyncAlpha(true)
        return
    end

    barFrame:SetHeight(barH)

    if effectiveMode == "free" then
        local w = (bg1 and bg1.GetWidth and F.PlainNumber(bg1:GetWidth(), 0)) or 418
        if w < 220 then w = 418 end
        barFrame:SetSize(w, barH)
        F.Mover.ApplyPosition(barFrame, "ChatBar", "BOTTOMLEFT", "BOTTOMLEFT", 10, 290)
    elseif bg1 then
        local bgW = bg1.GetWidth and F.PlainNumber(bg1:GetWidth(), 0) or 0
        if bgW >= 180 then
            barFrame:SetWidth(bgW)
        end
        HookBgResize(bg1)

        local rightExt = MeasureTabRightExtension and MeasureTabRightExtension(bg1, chatNS) or 0
        if effectiveMode == "bottom" then
            barFrame:SetPoint("TOPLEFT", bg1, "BOTTOMLEFT", 0, -gapPx)
            barFrame:SetPoint("TOPRIGHT", bg1, "BOTTOMRIGHT", rightExt, -gapPx)
        else
            local ext = chatNS and chatNS._chatBgExt
            if ext and ext:IsShown() then
                barFrame:SetPoint("BOTTOMLEFT", ext, "TOPLEFT", 0, gapPx)
                barFrame:SetPoint("BOTTOMRIGHT", ext, "TOPRIGHT", rightExt, gapPx)
            else
                local yOff = MeasureTabTopExtension(bg1, chatNS, ecfg)
                barFrame:SetPoint("BOTTOMLEFT", bg1, "TOPLEFT", 0, yOff + gapPx)
                barFrame:SetPoint("BOTTOMRIGHT", bg1, "TOPRIGHT", rightExt, yOff + gapPx)
            end
        end
    elseif cf1 then
        local l = cf1.GetLeft and F.PlainNumber(cf1:GetLeft(), nil)
        local r = cf1.GetRight and F.PlainNumber(cf1:GetRight(), nil)
        local t = cf1.GetTop and F.PlainNumber(cf1:GetTop(), nil)
        local b = cf1.GetBottom and F.PlainNumber(cf1:GetBottom(), nil)
        if l and r and t and b and (r - l) >= 160 then
            local left = l - 4
            local right = r + 4
            local yBase = (effectiveMode == "bottom") and (b - barH - 4) or (t + 28)
            barFrame:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", left, yBase)
            barFrame:SetPoint("BOTTOMRIGHT", _G.UIParent, "BOTTOMLEFT", right, yBase)
        else
            barFrame:SetSize(403, barH)
            barFrame:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", 10, 290)
        end
    end

    C_Timer.After(0, function()
        LayoutButtons()
        SyncUnifiedChatPanel()
    end)
    SyncUnifiedChatPanel()
    SyncAlpha(true)
end

local function ScheduleHoverLeaveCheck()
    local db = mod:GetDB()
    if db.hoverReveal ~= true and db.combatFade ~= true then
        isHovered = false
        return
    end
    C_Timer.After(0.14, function()
        local _, cf1, bg1 = GetEUIChatContext()
        local overBar = barFrame and barFrame:IsMouseOver()
        local overBg = bg1 and bg1:IsMouseOver()
        local overChat = (not bg1) and cf1 and cf1:IsMouseOver()
        if not (overBar or overBg or overChat) then
            isHovered = false
            SyncAlpha(false)
        end
    end)
end

----------------------------------------------------------------------
--  美化暴雪「N个聊天窗口」溢出按钮与下拉列表
----------------------------------------------------------------------
local function StyleOverflowList(list, ob)
    if not (list and mod._active and mod:GetDB().skinOverflow ~= false) then return end
    if list.IsForbidden and list:IsForbidden() then return end
    local ar, ag, ab = F.Theme.GetAccent()

    if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
        pcall(list.SetFrameStrata, list, "DIALOG")
        pcall(list.SetFrameLevel, list, 120)

        if ob and list.ClearAllPoints then
            local yOff = (mod:GetDB().dockMode == "top") and 26 or 6
            pcall(list.ClearAllPoints, list)
            pcall(list.SetPoint, list, "BOTTOMRIGHT", ob, "TOPRIGHT", 0, yOff)
        end
    end

    if list.NineSlice and list.NineSlice.SetAlpha then
        list.NineSlice:SetAlpha(0)
    end
    for _, reg in ipairs({ list:GetRegions() }) do
        local ot = reg.GetObjectType and reg:GetObjectType()
        if ot == "Texture" then
            reg:SetAlpha(0)
        elseif ot == "FontString" then
            F.Theme.ApplyFont(reg, 11, "", 0.66, 0.70, 0.76, 0.95)
        end
    end

    F.Theme.PaintPrettyCardOverlay(list, ar, ag, ab, 24)

    for _, ch in ipairs({ list:GetChildren() }) do
        if ch.GetObjectType and ch:GetObjectType() == "Button" then
            local fs = ch.GetFontString and ch:GetFontString()
            if fs then
                F.Theme.ApplyFont(fs, 12, "", 0.92, 0.94, 0.97, 1)
            end
        end
    end
end

local function OverflowSkinWanted()
    return mod._active and mod:GetDB().skinOverflow ~= false
end

-- 关闭「美化溢出按钮」或停用模块时，把暴雪溢出按钮与下拉列表的原生贴图原样还回去
local function UnskinChatOverflow()
    local gdm = _G.GeneralDockManager
    local ob = gdm and gdm.overflowButton
    if not (ob and overflowVisual[ob]) or (ob.IsForbidden and ob:IsForbidden()) then return end
    for _, reg in ipairs({ ob:GetRegions() }) do
        if reg.GetObjectType and reg:GetObjectType() == "Texture" then
            reg:SetAlpha(1)
        end
    end
    overflowVisual[ob]:Hide()
    local list = ob.list or _G.GeneralDockManagerOverflowButtonList
    if list and not (list.IsForbidden and list:IsForbidden()) and overflowHooked[list] then
        if list.NineSlice and list.NineSlice.SetAlpha then
            list.NineSlice:SetAlpha(1)
        end
        for _, reg in ipairs({ list:GetRegions() }) do
            if reg.GetObjectType and reg:GetObjectType() == "Texture" then
                reg:SetAlpha(1)
            end
        end
        F.Theme.HidePrettyCardOverlay(list)
    end
end

local function SkinChatOverflow()
    if not OverflowSkinWanted() then
        UnskinChatOverflow()
        return
    end
    local gdm = _G.GeneralDockManager
    local ob = gdm and gdm.overflowButton
    if not ob or (ob.IsForbidden and ob:IsForbidden()) then return end

    for _, reg in ipairs({ ob:GetRegions() }) do
        if reg.GetObjectType and reg:GetObjectType() == "Texture" then
            reg:SetAlpha(0)
        end
    end
    local glyph = overflowVisual[ob]
    if glyph then glyph:Show() end
    if not glyph then
        glyph = CreateFrame("Frame", nil, ob)
        glyph:SetAllPoints(ob)
        glyph:EnableMouse(false)

        local hoverBg = glyph:CreateTexture(nil, "BACKGROUND")
        hoverBg:SetAllPoints()
        hoverBg:Hide()
        glyph._hoverBg = hoverBg

        local dots = glyph:CreateTexture(nil, "OVERLAY")
        dots:SetSize(14, 14)
        dots:SetPoint("CENTER", glyph, "CENTER", 0, 0)
        dots:SetTexture(F.Theme.ICONS .. "MoreDots.tga")
        dots:SetTexCoord(0, 1, 0, 1)
        glyph._dots = dots
        overflowVisual[ob] = glyph
    end
    if glyph._dots then
        glyph._dots:SetVertexColor(0.76, 0.80, 0.86, 0.92)
    end
    if not overflowHooked[ob] then
        overflowHooked[ob] = true
        ob:HookScript("OnEnter", function()
            if not OverflowSkinWanted() then return end
            local r, g, b = F.Theme.GetAccent()
            if glyph._hoverBg then
                glyph._hoverBg:SetColorTexture(r, g, b, 0.22)
                glyph._hoverBg:Show()
            end
            if glyph._dots then glyph._dots:SetVertexColor(r, g, b, 1) end
        end)
        ob:HookScript("OnLeave", function()
            if glyph._hoverBg then glyph._hoverBg:Hide() end
            if glyph._dots then glyph._dots:SetVertexColor(0.76, 0.80, 0.86, 0.92) end
        end)
    end

    local list = ob.list or _G.GeneralDockManagerOverflowButtonList
    if list then
        if not overflowHooked[list] then
            overflowHooked[list] = true
            list:HookScript("OnShow", function(self)
                if not OverflowSkinWanted() then return end
                StyleOverflowList(self, ob)
                C_Timer.After(0, function()
                    if self:IsShown() then StyleOverflowList(self, ob) end
                end)
            end)
        end
        if list:IsShown() then
            StyleOverflowList(list, ob)
        end
    end
end

----------------------------------------------------------------------
--  注册零污染 EventRegistry 焦点回调 + EUI 聊天样式联动挂钩
----------------------------------------------------------------------
local function HookChatFrameInteractions()
    editBoxActive = IsAnyEditBoxFocused()

    if not registryRegistered and _G.EventRegistry and _G.EventRegistry.RegisterCallback then
        registryRegistered = true
        _G.EventRegistry:RegisterCallback("ChatFrame.OnEditBoxFocusGained", function(_, eb)
            editBoxActive = true
            if IsPermanentEditBox(eb) then lastEditBox = eb end
            if not mod._active then return end
            RefreshActiveChannel()
            -- 暴雪在 SetFocus 之后才 UpdateHeader（可能把粘滞的团队/小队切成副本频道）：下一帧再对一次
            C_Timer.After(0, function()
                if mod._active and editBoxActive then RefreshActiveChannel() end
            end)
            SyncAlpha(true)
        end, "kkowoUI_ChatBar_FocusIn")
        _G.EventRegistry:RegisterCallback("ChatFrame.OnEditBoxFocusLost", function(_, eb)
            editBoxActive = false
            if IsPermanentEditBox(eb) then lastEditBox = eb end
            if not mod._active then return end
            local _, cf1, bg1 = GetEUIChatContext()
            isHovered = (barFrame and barFrame:IsMouseOver())
                or (bg1 and bg1:IsMouseOver())
                or ((not bg1) and cf1 and cf1:IsMouseOver())
                or false
            RefreshActiveChannel()
            SyncAlpha(false)
        end, "kkowoUI_ChatBar_FocusOut")
    end

    local _, cf1, bg1, _, echat, _, _, d1 = GetEUIChatContext()
    -- 监听聊天滚轮，仅在翻看历史时点亮底部「回到底部」箭头（零后台轮询）
    local wheelHost = (d1 and d1.msgFrame) or bg1 or cf1
    if wheelHost and not wheelHooked[wheelHost] and wheelHost.HookScript then
        wheelHooked[wheelHost] = true
        wheelHost:HookScript("OnMouseWheel", function()
            if not mod._active or wheelQueued then return end
            wheelQueued = true
            C_Timer.After(0.05, function()
                wheelQueued = false
                if mod._active then UpdateScrollIndicator() end
            end)
        end)
    end

    HookEUIChatFadeSync()
    if echat and not euiHooksInstalled then
        euiHooksInstalled = true
        local function ResyncFromEUI()
            if syncingEUI or not mod._active or resyncQueued then return end
            resyncQueued = true
            C_Timer.After(0, function()
                resyncQueued = false
                if syncingEUI or not mod._active then return end
                SyncEUIChatSidebar()
                ApplyAnchor()
                ApplyVisuals()
                SkinChatOverflow()
            end)
        end
        for _, fnName in ipairs({
            "ApplyBackground",
            "ApplyExtendedBackground",
            "ApplyTabAppearance",
            "ApplyTabPadding",
            "ApplyBorders",
            "ApplySidebarPosition",
        }) do
            if type(echat[fnName]) == "function" then
                _G.hooksecurefunc(echat, fnName, ResyncFromEUI)
            end
        end
    end
end

local function CreateBar()
    if barFrame then
        return
    end
    barFrame = CreateFrame("Frame", "kkowoUI_ChatBar", _G.UIParent)
    barFrame:SetSize(RAIL_WIDTH, 240)
    barFrame:SetFrameStrata("MEDIUM")
    barFrame:SetFrameLevel(102)
    barFrame:EnableMouse(true)
    barFrame:SetClampedToScreen(true)

    local unifiedBg = barFrame:CreateTexture(nil, "BACKGROUND", nil, -4)
    unifiedBg:SetAllPoints()
    unifiedBg:Hide()
    barFrame._unifiedBg = unifiedBg

    local rightSep = barFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    rightSep:SetWidth(1)
    rightSep:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, 0)
    rightSep:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
    rightSep:Hide()
    barFrame._rightSep = rightSep

    local bottomSep = barFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    bottomSep:SetHeight(1)
    bottomSep:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 0, 0)
    bottomSep:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
    bottomSep:Hide()
    barFrame._bottomSep = bottomSep

    utilDivTop = barFrame:CreateTexture(nil, "OVERLAY", nil, 5)
    utilDivTop:SetHeight(1)
    utilDivTop:Hide()

    utilDivBot = barFrame:CreateTexture(nil, "OVERLAY", nil, 5)
    utilDivBot:SetHeight(1)
    utilDivBot:Hide()

    barFrame:SetScript("OnEnter", function()
        isHovered = true
        WakeEUIChatFade()
        if not IsEUIFadeLockstep() then SyncAlpha(false) end
        UpdateScrollIndicator()
    end)
    barFrame:SetScript("OnLeave", ScheduleHoverLeaveCheck)
    barFrame:SetScript("OnSizeChanged", LayoutButtons)

    -- 创建左侧融合实用按钮（复制 / 设置 / 回到底部）
    local hasEUIChat = F.IsAddOnLoaded("EllesmereUIChat")
    for idx, udef in ipairs(UTIL_DEFS) do
        local ubtn = CreateFrame("Button", nil, barFrame)
        ubtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        ubtn._def = udef

        local activeBg = ubtn:CreateTexture(nil, "BACKGROUND", nil, -1)
        activeBg:SetAllPoints()
        activeBg:Hide()
        ubtn._activeBg = activeBg

        local iconPath = (hasEUIChat and udef.tex) or udef.fallbackTex
        if iconPath then
            local ic = ubtn:CreateTexture(nil, "ARTWORK")
            ic:SetSize(14, 14)
            ic:SetPoint("CENTER", 0, 0)
            ic:SetTexture(iconPath)
            if hasEUIChat and udef.tex then
                ic:SetDesaturated(true)
            end
            ubtn._icon = ic
        else
            local gl = ubtn:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(gl, 11, "")
            gl:SetPoint("CENTER", 0, 0)
            gl:SetText(udef.fallbackGlyph or "·")
            ubtn._glyph = gl
        end

        ubtn:SetScript("OnClick", function(_, mouseBtn)
            if udef.onClick then udef.onClick(mouseBtn) end
        end)
        ubtn:SetScript("OnEnter", function(self)
            isHovered = true
            self._isHovered = true
            WakeEUIChatFade()
            if not IsEUIFadeLockstep() then SyncAlpha(false) end
            UpdateUtilButtonState(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT", 6, 0)
            GameTooltip:AddLine(udef.tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        ubtn:SetScript("OnLeave", function(self)
            self._isHovered = false
            UpdateUtilButtonState(self)
            GameTooltip:Hide()
            ScheduleHoverLeaveCheck()
        end)

        utilButtons[idx] = ubtn
    end

    local draggingChatBar = false
    local function StartFreeBarDrag()
        if mod:GetDB().dockMode == "free" and _G.IsShiftKeyDown() and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            draggingChatBar = true
            barFrame:StartMoving()
        end
    end
    local function StopFreeBarDrag(skipSave)
        if not draggingChatBar then return end
        draggingChatBar = false
        -- 无论拖动途中是否切换了停靠模式，都必须先结束移动，否则框体会一直跟随鼠标
        barFrame:StopMovingOrSizing()
        if skipSave then return end
        if mod:GetDB().dockMode ~= "free" then
            ApplyAnchor()
            return
        end
        local pt, _, rpt, x, y = barFrame:GetPoint(1)
        -- SavePosition 内部会过滤 12.x 机密值与非法锚点
        F.DB.SavePosition("ChatBar", pt, rpt, x, y)
    end

    -- 创建频道切换按钮
    for i, ch in ipairs(CHANNELS) do
        local btn = CreateFrame("Button", nil, barFrame)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:RegisterForDrag("LeftButton")
        btn:SetScript("OnDragStart", StartFreeBarDrag)
        btn:SetScript("OnDragStop", function() StopFreeBarDrag(false) end)
        btn._ch = ch

        local tileBg = btn:CreateTexture(nil, "BACKGROUND", nil, -2)
        tileBg:SetAllPoints()
        btn._tileBg = tileBg

        local activeBg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
        activeBg:SetAllPoints()
        activeBg:Hide()
        btn._activeBg = activeBg

        local underline = btn:CreateTexture(nil, "OVERLAY", nil, 7)
        underline:SetHeight(1)
        underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
        underline:Hide()
        btn._underline = underline

        local sep = btn:CreateTexture(nil, "OVERLAY", nil, 6)
        sep:SetWidth(1)
        sep:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 0, -3)
        sep:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 3)
        sep:Hide()
        btn._sep = sep

        local lbl = btn:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(lbl, 12, "")
        lbl:SetPoint("CENTER", 0, 0)
        lbl:SetText(ch.label)
        btn._lbl = lbl

        btn:SetScript("OnClick", function(_, mouseBtn)
            if _G.IsAltKeyDown and _G.IsAltKeyDown() then
                MoveChannelOrder(ch.key, mouseBtn == "RightButton" and 1 or -1)
                return
            end
            if mouseBtn == "RightButton" and ch.right then
                ch.right()
            elseif ch.left then
                ch.left()
            end
            if ch.key ~= "ROLL" then
                RefreshActiveChannel(ch.key)
            end
        end)
        btn:SetScript("OnEnter", function(self)
            isHovered = true
            self._isHovered = true
            WakeEUIChatFade()
            if not IsEUIFadeLockstep() then SyncAlpha(false) end
            UpdateButtonState(self)
            local vert = IsVerticalMode()
            if vert then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT", 6, 0)
            else
                GameTooltip:SetOwner(self, "ANCHOR_TOP", 0, 4)
            end
            GameTooltip:AddLine(ch.tip, 1, 1, 1, true)
            if ch.label == "世" then
                local id, name = FindWorldChannel()
                if id and id > 0 then
                    GameTooltip:AddDoubleLine("当前已加入", "/" .. id .. " " .. tostring(name), 0.68, 0.72, 0.78, 0.37, 0.83, 0.65)
                else
                    GameTooltip:AddLine("尚未加入世界频道（右键一键加入）", 0.96, 0.76, 0.32)
                end
                GameTooltip:AddDoubleLine("右键加入/离开", GetWorldChannelName(), 0.68, 0.72, 0.78, 0.97, 0.85, 0.44)
            end
            GameTooltip:AddLine(
                vert and "Alt + 左键上移 · Alt + 右键下移（自定义排序）"
                    or "Alt + 左键左移 · Alt + 右键右移（自定义排序）",
                0.58, 0.62, 0.68
            )
            if mod:GetDB().dockMode == "free" then
                GameTooltip:AddLine("Shift + 左键拖动可移动位置", 0.58, 0.62, 0.68)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            self._isHovered = false
            UpdateButtonState(self)
            GameTooltip:Hide()
            ScheduleHoverLeaveCheck()
        end)

        chanButtons[i] = btn
        chanButtonByKey[ch.key] = btn
    end

    F.Mover.Register({
        key = "ChatBar",
        label = "融合聊天条（自由模式）",
        frame = barFrame,
        order = 50,
        defaultPoint = "BOTTOMLEFT",
        defaultRelPoint = "BOTTOMLEFT",
        defaultX = 10,
        defaultY = 290,
        allowShiftDrag = false,
        isHidden = function() return not mod._active or mod:GetDB().dockMode ~= "free" end,
        isAnchored = function() return mod:GetDB().dockMode ~= "free" end,
        ownsPosition = true,
        onReanchor = ApplyAnchor,
    })

    barFrame:SetMovable(true)
    barFrame:RegisterForDrag("LeftButton")
    barFrame:HookScript("OnDragStart", StartFreeBarDrag)
    barFrame:HookScript("OnDragStop", function() StopFreeBarDrag(false) end)
    barFrame:HookScript("OnHide", function() StopFreeBarDrag(true) end)

    HookChatFrameInteractions()
end

local unlockListenerRegistered = false

local function RegisterChatBarUnlockListener()
    if unlockListenerRegistered then return end
    local EUI = _G.EllesmereUI
    if EUI and EUI.RegisterUnlockModeListener then
        unlockListenerRegistered = true
        pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_ChatBar", function(active)
            if not active and mod._active then
                C_Timer.After(0, function()
                    if mod._active then
                        SyncEUIChatSidebar()
                        ApplyAnchor()
                        ApplyVisuals()
                    end
                end)
            end
        end)
    end
end

local function UnregisterChatBarUnlockListener()
    if not unlockListenerRegistered then return end
    unlockListenerRegistered = false
    local EUI = _G.EllesmereUI
    if EUI and EUI.UnregisterUnlockModeListener then
        pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_ChatBar")
    end
end

function mod:OnWhisper()
    if self:GetDB().whisperSound and _G.PlaySound then
        pcall(_G.PlaySound, 3081, "Master")
    end
end

-- 关键词切分：Lua 5.1 的 [...] 是「字节」字符类，把全角「，；」直接放进去会按字节把
-- 团/猎/盗/国/图 等汉字从中间切断。先把全角分隔符整体替换成 ASCII，再按 ASCII 切分。
local function RebuildKeywordList(src)
    for i = #keywordList, 1, -1 do keywordList[i] = nil end
    keywordSource = src
    if type(src) ~= "string" or src == "" then return end
    local norm = src:gsub("，", ","):gsub("；", ";"):gsub("　", " ")
    for kw in norm:gmatch("[^,;%s]+") do
        if #kw >= 2 then
            keywordList[#keywordList + 1] = { raw = kw, lower = kw:lower() }
        end
    end
end

local KEYWORD_EVENTS = { "CHAT_MSG_CHANNEL", "CHAT_MSG_YELL", "CHAT_MSG_SAY", "CHAT_MSG_GUILD", "CHAT_MSG_PARTY" }

function mod:OnChatMessage(_, text)
    local db = self:GetDB()
    if not db.keywordAlert then return end
    if keywordSource ~= db.keywords then RebuildKeywordList(db.keywords) end
    if #keywordList == 0 then return end
    local now = GetTime()
    if now - lastKeywordAlert < 5 then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" then return end
    local lowerMsg = msg:lower()
    for _, kw in ipairs(keywordList) do
        if lowerMsg:find(kw.lower, 1, true) then
            lastKeywordAlert = now
            if _G.PlaySound then pcall(_G.PlaySound, 8960, "Master") end
            F.Print("|cff73bdf2关键词命中|r [" .. kw.raw .. "]：" .. msg)
            return
        end
    end
end

-- 只在开启关键词提醒且有关键词时才监听 5 个高频公共聊天事件（默认关闭时零开销）
function mod:RefreshKeywordWatch()
    local db = self:GetDB()
    RebuildKeywordList(db.keywords)
    local want = self._active and db.keywordAlert == true and #keywordList > 0
    if want == keywordWatching then return end
    keywordWatching = want
    for _, ev in ipairs(KEYWORD_EVENTS) do
        if want then
            self:RegisterEvent(ev, self.OnChatMessage)
        else
            self:UnregisterEvent(ev)
        end
    end
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2Migrated then
        db.v2Migrated = true
        db.hoverReveal = false
        db.tintChannelText = true
    end
    if not db.v3ChatFitMigrated then
        db.v3ChatFitMigrated = true
        db.idleAlpha = 1.0
    end
    if not db.v4LeftDockMigrated then
        db.v4LeftDockMigrated = true
        -- 自动迁移至「左侧融合竖栏」并隐藏聊天侧边栏重复的好友按钮
        db.dockMode = "left"
        db.hideRedundantFriends = true
        db.idleAlpha = 1.0
    end
    if not db.v5NoCombatFadeMigrated then
        db.v5NoCombatFadeMigrated = true
        db.combatFade = false
    end
    if not db.v6LightChatGlassMigrated then
        db.v6LightChatGlassMigrated = true
        if not db.panelAlpha or db.panelAlpha >= 0.55 then
            db.panelAlpha = 0.24
        end
    end
    -- 一整块清透玻璃：旧的 0.34 偏深、且有分隔线与顶部高光带，看起来一块块的
    if not db.v7OneGlassMigrated then
        db.v7OneGlassMigrated = true
        if not db.panelAlpha or db.panelAlpha >= 0.30 then
            db.panelAlpha = 0.24
        end
    end
    -- 停靠模式下旧存档可能残留 idleAlpha=0.25，导致聊天框亮起时左侧快捷条仍暗一层且淡隐不同步
    if not db.v8SyncChatFadeMigrated then
        db.v8SyncChatFadeMigrated = true
        if (db.dockMode or "left") ~= "free" and db.hoverReveal ~= true then
            db.idleAlpha = 1.0
        end
    end
    -- 禁止 hooksecurefunc("FCFDock_SelectWindow")（实测会污染 dock.selected 与 chatFrame.isLocked）；
    -- 改挂 EUI 自身非暴雪标签刷新函数 + UPDATE_CHAT_WINDOWS 事件，零污染同步底板尺寸与显隐
    local function HookEUIChatTabSyncOnce()
        if euiTabSyncHooked then return end
        local _, _, _, _, echat = GetEUIChatContext()
        if not echat then return end
        euiTabSyncHooked = true
        -- 当帧直接差分同步（EUI 的 TabsRefreshNow / SyncChatFrameState 均在 EUI 自身延迟上下文执行，
        -- 零污染且消除下一帧 C_Timer.After(0) 重排抖动；未切换标签且状态未变时直接跳过）
        local function syncPanelNow()
            if not mod._active then return end
            local sel = GetSelectedChatWindow()
            if sel ~= lastObservedSel then
                lastObservedSel = sel
                SyncUnifiedChatPanel(false)
            elseif unifiedPanel and unifiedPanel:IsShown() ~= (IsAnyDockedChatShown() or (barFrame and barFrame:IsShown()) or false) then
                SyncUnifiedChatPanel(false)
            end
        end
        if type(echat.TabsRefreshNow) == "function" then
            _G.hooksecurefunc(echat, "TabsRefreshNow", syncPanelNow)
        end
        if type(echat.SyncChatFrameState) == "function" then
            _G.hooksecurefunc(echat, "SyncChatFrameState", syncPanelNow)
        end
        if type(echat.EngineFontFamily) == "function" then
            _G.hooksecurefunc(echat, "EngineFontFamily", function(id)
                if mod._active and (type(id) == "number" or type(id) == "string") then
                    local fam = _G["EUIChatFontFamily" .. id]
                    if fam then ApplyChatFontSpacingToFamily(fam, CHAT_LINE_SPACING) end
                end
            end)
        end
    end
    HookEUIChatTabSyncOnce()
    SyncChatLineSpacing(true)
    self:RegisterEvent("UPDATE_CHAT_WINDOWS", function()
        if mod._active then
            ApplyAnchor(false)
            SyncUnifiedChatPanel(false)
        end
    end)
    leftRoomAdjusted = false
    CreateBar()
    HookEUIChatFadeSync()
    C_Timer.After(1.0, function()
        if mod._active then HookEUIChatFadeSync() end
    end)
    SyncEUIChatSidebar()
    ApplyAnchor()
    ApplyVisuals()
    RefreshActiveChannel()
    SkinChatOverflow()
    C_Timer.After(0.8, function()
        if not mod._active then return end
        HookEUIChatTabSyncOnce()
        SyncChatLineSpacing(true)
        HookChatFrameInteractions()
        SyncEUIChatSidebar()
        ApplyAnchor()
        ApplyVisuals()
        RefreshActiveChannel()
        SkinChatOverflow()
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        editBoxActive = IsAnyEditBoxFocused()
        isHovered = false
        HookEUIChatTabSyncOnce()
        SyncChatLineSpacing(true)
        HookChatFrameInteractions()
        SyncEUIChatSidebar()
        ApplyAnchor()
        ApplyVisuals()
        RefreshActiveChannel()
        SkinChatOverflow()
        C_Timer.After(1.2, function()
            if not mod._active then return end
            editBoxActive = IsAnyEditBoxFocused()
            SyncChatLineSpacing(true)
            SyncEUIChatSidebar()
            ApplyAnchor()
            ApplyVisuals()
            RefreshActiveChannel()
            SkinChatOverflow()
        end)
        C_Timer.After(2.6, function()
            if not mod._active then return end
            SyncEUIChatSidebar()
            ApplyAnchor()
            ApplyVisuals()
            RefreshActiveChannel()
        end)
    end)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if mod:GetDB().combatFade == true then SyncAlpha(false) end
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if mod:GetDB().combatFade == true then SyncAlpha(false) end
    end)
    self:RegisterEvent("CHAT_MSG_WHISPER", self.OnWhisper)
    self:RegisterEvent("CHAT_MSG_BN_WHISPER", self.OnWhisper)
    RegisterChatBarUnlockListener()
    keywordWatching = false
    self:RefreshKeywordWatch()
end

function mod:OnDisable()
    -- 基类已 UnregisterAllEvents，这里只需同步本地标志
    UnregisterChatBarUnlockListener()
    keywordWatching = false
    lastUnifiedSig = nil
    lastAnchorSig = nil
    lastObservedSel = nil
    SyncChatLineSpacing(true)
    SyncEUIChatSidebar()
    SyncUnifiedChatPanel(true)
    UnskinChatOverflow()
    if barFrame then barFrame:Hide() end
end

function mod:OnThemeChanged()
    ApplyVisuals()
    RefreshActiveChannel()
    SkinChatOverflow()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "与聊天框融合方式",
        tooltip = "左侧融合竖栏自动收起重复边栏，也可切换上下横条或自由拖动。",
        values = {
            left   = "左侧融合竖栏（推荐）",
            top    = "标签栏上方横栏",
            bottom = "底栏横栏",
            free   = "自由拖动",
        },
        order = { "left", "top", "bottom", "free" },
        getValue = function() return db.dockMode or "left" end,
        setValue = function(v)
            db.dockMode = v
            leftRoomAdjusted = false
            SyncEUIChatSidebar()
            ApplyAnchor()
            ApplyVisuals()
            RefreshActiveChannel()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "一体化圆角底板",
        tooltip = "将聊天条、顶部标签栏与正文融为统一圆角底板，消除色差。",
        getValue = function() return db.unifiedRoundedPanel ~= false end,
        setValue = function(v)
            db.unifiedRoundedPanel = v == true
            SyncEUIChatSidebar()
            ApplyAnchor()
            ApplyVisuals()
        end,
    }, {
        type = "slider",
        text = "底板透明度",
        tooltip = "调节整块聊天底板的不透明度，推荐 0.20 至 0.28。",
        min = 0.12, max = 0.85, step = 0.04,
        disabled = function() return db.unifiedRoundedPanel == false end,
        getValue = function() return F.PlainNumber(db.panelAlpha, 0.24) or 0.24 end,
        setValue = function(v) db.panelAlpha = v; SyncUnifiedChatPanel(true) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "高亮当前频道",
        tooltip = "竖栏以左侧色线、横栏以底线标出当前激活的发言频道。",
        getValue = function() return db.showActiveChannel ~= false end,
        setValue = function(v) db.showActiveChannel = v == true; RefreshActiveChannel() end,
    }, {
        type = "toggle",
        text = "频道专属淡色",
        tooltip = "开启后文字按频道着色，关闭后使用统一浅灰文字。",
        getValue = function() return db.tintChannelText ~= false end,
        setValue = function(v) db.tintChannelText = v == true; ApplyVisuals() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "密语提示音",
        tooltip = "收到新密语时播放简短提示音。",
        getValue = function() return db.whisperSound ~= false end,
        setValue = function(v) db.whisperSound = v == true end,
    }, {
        type = "toggle",
        text = "战斗中自动淡出",
        tooltip = "默认关闭以减少频繁淡入淡出，需要时可手动开启。",
        getValue = function() return db.combatFade == true end,
        setValue = function(v) db.combatFade = v == true; SyncAlpha(false) end,
    })
    y = y - h

    local function buildAdv(w, p, curY)
        local _, rh
        _, rh = w:DualRow(p, curY, {
            type = "slider",
            text = "常规整体透明度",
            tooltip = "保持 1.00 时底板透明度与聊天框协调一致。",
            min = 0.25, max = 1.0, step = 0.05,
            getValue = function() return db.idleAlpha or 1.0 end,
            setValue = function(v) db.idleAlpha = v; SyncAlpha(true) end,
        }, {
            type = "toggle",
            text = "美化溢出菜单",
            tooltip = "将标签过多时的窗口列表改为暗色圆角卡片并向上弹出。",
            getValue = function() return db.skinOverflow ~= false end,
            setValue = function(v) db.skinOverflow = v == true; SkinChatOverflow() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "dropdown",
            text = "选择排序频道",
            tooltip = "选好频道后点按钮移动，也可在聊天条上按住 Alt 点击微调。",
            values = {
                WORLD   = "世（世界频道）",
                GENERAL = "综（综合/交易）",
                TRADE   = "交（仅横栏）",
                GUILD   = "会（公会/官员）",
                RAID    = "团（团队/副本）",
                PARTY   = "队（小队）",
                WHISPER = "密（密语）",
                YELL    = "喊（大喊）",
                SAY     = "说（当前）",
                ROLL    = "骰（掷骰子）",
            },
            order = { "WORLD", "GENERAL", "TRADE", "GUILD", "RAID", "PARTY", "WHISPER", "YELL", "SAY", "ROLL" },
            getValue = function() return selectedOrderKey or "WORLD" end,
            setValue = function(v) selectedOrderKey = v end,
        }, {
            type = "button",
            text = "上移或左移",
            noCapture = true,
            tooltip = "将当前选中频道按钮向上或向左移动一格。",
            onClick = function() MoveChannelOrder(selectedOrderKey or "WORLD", -1) end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "button",
            text = "下移或右移",
            noCapture = true,
            tooltip = "将当前选中频道按钮向下或向右移动一格。",
            onClick = function() MoveChannelOrder(selectedOrderKey or "WORLD", 1) end,
        }, {
            type = "button",
            text = "恢复默认排序",
            noCapture = true,
            tooltip = "恢复默认频道排序：世、综、会、团、队、密、喊、说、骰。",
            onClick = ResetChannelOrder,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "隐藏登录刷屏",
            tooltip = "登录 12 秒内隐藏第三方欢迎提示，保留报错（/kk loginlog）。",
            getValue = function() return db.loginQuiet ~= false end,
            setValue = function(v)
                db.loginQuiet = v == true
                if db.loginQuiet and F.SweepLoginChatBanners then
                    F.SweepLoginChatBanners()
                end
            end,
        }, {
            type = "button",
            text = "查看隐藏提示",
            buttonText = "查看",
            noCapture = true,
            tooltip = "在聊天框输出本次登录被隐藏的第三方提示（/kk loginlog）。",
            onClick = function()
                if F.DumpSuppressedLoginMsgs then F.DumpSuppressedLoginMsgs() end
            end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "关键词提醒",
            tooltip = "在聊天框输入 /kk kw 关键词1,关键词2 设置监控词（5 秒冷却）。",
            getValue = function() return db.keywordAlert == true end,
            setValue = function(v) db.keywordAlert = v == true; mod:RefreshKeywordWatch() end,
        }, {
            type = "input",
            text = "世界频道名称",
            tooltip = "右键「世」一键加入的频道名，留空默认大脚世界频道（/kk world）。",
            inputWidth = 140,
            inputStyle = "popup",
            placeholder = DEFAULT_WORLD_CHANNEL,
            getValue = function() return GetWorldChannelName() end,
            setValue = function(v) mod:SetWorldChannelName(v) end,
        })
        curY = curY - rh
        return curY
    end

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("chatBar", W, parent, y, buildAdv, blank)
    else
        y = buildAdv(W, parent, y)
    end
    return y
end
