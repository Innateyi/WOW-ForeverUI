----------------------------------------------------------------------
--  kkowoUI_Options — Options.lua (LoadOnDemand: 1)
--  EUI 统一设置面板渲染 + /kk 全部子命令 + 一键瘦身向导
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, math_abs, pcall, tostring, type = ipairs, math.abs, pcall, tostring, type

local UI = {}
F._OptionsUI = UI

local function BuildModuleSection(mod, W, parent, y)
    local EUI = _G.EllesmereUI
    local blank = (EUI and EUI.BlankRowCfg and EUI.BlankRowCfg()) or nil
    local yielded, byAddon = mod:IsYielded()
    local headerTitle = mod.title
    if yielded then
        headerTitle = headerTitle .. "（已自动让位给 " .. tostring(byAddon) .. "）"
    end

    local _, h = W:SectionHeader(parent, headerTitle, y)
    y = y - h

    local enableSlot = {
        type = "toggle",
        text = "启用 " .. mod.title,
        tooltip = mod.desc or ("启用或关闭 " .. mod.title .. " 模块。"),
        disabled = function() return yielded end,
        disabledTooltip = yielded and ("检测到已启用 " .. tostring(byAddon) .. "，本模块自动让位避免冲突。停用该插件后生效。") or nil,
        getValue = function() return mod:IsEnabled() end,
        setValue = function(v)
            mod:SetEnabled(v)
            if EUI and EUI.RefreshPage then
                pcall(EUI.RefreshPage, EUI)
            end
        end,
    }

    if mod.BuildOptions then
        y = mod:BuildOptions(W, parent, y, enableSlot, blank)
    else
        _, h = W:DualRow(parent, y, enableSlot, blank)
        y = y - h
    end

    _, h = W:Spacer(parent, y, 10)
    y = y - h
    return y
end

function UI.BuildGroupPage(groupSpec, pageName, parent, yOffset)
    local EUI = _G.EllesmereUI
    local W = EUI and EUI.Widgets
    if not W then return 0 end
    local y = yOffset or 0
    local blank = (EUI and EUI.BlankRowCfg and EUI.BlankRowCfg()) or nil

    if groupSpec.isHub then
        local hub = F.Modules.Get("controlHub")
        if hub then
            if pageName == "重叠体检与补丁守卫" and hub.BuildHealthPage then
                y = hub:BuildHealthPage(W, parent, y, blank)
            elseif hub.BuildLauncherPage then
                y = hub:BuildLauncherPage(W, parent, y, blank)
            end
        end
        return math_abs(y) + 20
    end

    local keys = groupSpec.pageMap and groupSpec.pageMap[pageName] or {}
    for _, modKey in ipairs(keys) do
        local mod = F.Modules.Get(modKey)
        if not mod and modKey == "keybindBoard" and F.EnsureKeybindBoardLoaded then
            mod = F.EnsureKeybindBoardLoaded()
        end
        if mod then
            y = BuildModuleSection(mod, W, parent, y)
        end
    end
    return math_abs(y) + 20
end

local function PrintStatus()
    F.Print("版本 " .. tostring(F.VERSION) .. "（9 目录模块化套件）— 模块运行状态：")
    for _, mod in ipairs(F.Modules.All()) do
        local yielded, byAddon = mod:IsYielded()
        local state
        if yielded then
            state = "|cffaaaaaa让位给 " .. tostring(byAddon) .. "|r"
        elseif mod._active then
            state = "|cff5fd3a6已启用|r"
        else
            state = "|cff888888已关闭|r"
        end
        _G.print("  • " .. mod.title .. " (" .. mod.key .. "): " .. state)
    end
end

local SLIM_LIST = {
    "QFXSystemBar", "QFXSystemBar_Config", "QFXSystemBar_InfoBar",
    "QFXSystemBar_Locale", "QFXSystemBar_MeetingStone",
    "EllesmereUIDataBars", "YaMedia",
    "BlizzMove", "Leatrix_Maps", "WaypointUI",
    "VamoosesSlipstream", "VamoosesSlipstream_kkowo", "PrettyTooltip",
    "TalentsForever", "ForeverFishing", "ArcAuras", "ArcAuras_Finds", "ArcAuras_LFG", "ArcUI",
    "EllesmereUIAuraBuffReminders", "EllesmereUIQuickdraw", "EllesmereUIMythicTimer",
    "EllesmereUIFriends", "EllesmereUIGroupFinder", "Polestar_Arcade",
    "GlowingBars", "MiniMarkers", "163UI_Info", "QuestieTrace", "BlizzMove_Debug",
}

local function ApplyInGameSlim()
    local disable = (_G.C_AddOns and _G.C_AddOns.DisableAddOn) or _G.DisableAddOn
    local getState = _G.C_AddOns and _G.C_AddOns.GetAddOnEnableState
    local existsFn = _G.C_AddOns and _G.C_AddOns.DoesAddOnExist
    local saveFn = _G.C_AddOns and _G.C_AddOns.SaveAddOns
    if not disable then
        F.Print("|cffe05263当前客户端不支持插件开关接口，请退出游戏后运行 Tools\\slim_addons.py。|r")
        return
    end
    local backup = {}
    local count = 0
    for _, name in ipairs(SLIM_LIST) do
        local exists = true
        if existsFn then
            local okEx, ex = pcall(existsFn, name)
            if not (okEx and ex) then exists = false end
        end
        local wasEnabled = false
        if exists then
            if getState then
                local ok, st = pcall(getState, name)
                if ok and type(st) == "number" and st > 0 then wasEnabled = true end
            else
                wasEnabled = true
            end
        end
        if wasEnabled then
            backup[#backup + 1] = name
            F.SetAddOnEnabledSafely(name, false)
            count = count + 1
        end
    end
    if #backup > 0 then
        if F.charDB then F.charDB.slimBackup = backup
        elseif F.db then F.db.slimBackup = backup end
    end
    if saveFn then pcall(saveFn) end
    F.Print("已停用 " .. tostring(count) .. " 个重叠/闲置插件，即将重载界面（随时可用 /kk restore 一键还原）。")
    if _G.ReloadUI then _G.ReloadUI() end
end

local function RestoreInGameSlim()
    local enable = (_G.C_AddOns and _G.C_AddOns.EnableAddOn) or _G.EnableAddOn
    local saveFn = _G.C_AddOns and _G.C_AddOns.SaveAddOns
    local charBak = F.charDB and type(F.charDB.slimBackup) == "table" and #F.charDB.slimBackup > 0 and F.charDB.slimBackup or nil
    local accBak = F.db and type(F.db.slimBackup) == "table" and #F.db.slimBackup > 0 and F.db.slimBackup or nil
    local list = charBak or accBak or SLIM_LIST
    if not enable then return end
    if F.db then F.db.autoDisableDeadAddons = false end
    for _, name in ipairs(list) do
        F.SetAddOnEnabledSafely(name, true)
    end
    if saveFn then pcall(saveFn) end
    F.Print("已重新启用 " .. tostring(#list) .. " 个插件，即将重载界面。")
    if _G.ReloadUI then _G.ReloadUI() end
end

if _G.StaticPopupDialogs then
    _G.StaticPopupDialogs["KKOWOUI_SLIM_CONFIRM"] = {
        text = "|cffdca77fkkowoUI 一键瘦身与精简切换|r\n\n将停用已整合或被 EUI/Polestar/kkowoUI 原生接管的重叠/闲置插件，随后自动重载界面：\n\n• 已接管重叠：QFXSystemBar×5、EUI DataBars、YaMedia、BlizzMove、Leatrix_Maps、WaypointUI、VamoosesSlipstream、PrettyTooltip、ArcAuras\n• 闲置/正式服无用/调试：TalentsForever、ForeverFishing、ArcUI、163UI_Info、QuestieTrace、BlizzMove_Debug、Polestar_Arcade、EUI Quickdraw/MythicTimer/BuffReminders/Friends/GroupFinder\n\n《无限副本手册》LoD 子库与 Scales/核心插件全部保留，随时可输入 /kk restore 一键还原。",
        button1 = "确认瘦身并重载",
        button2 = "取消",
        OnAccept = ApplyInGameSlim,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

function UI.HandleSlash(msg)
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = raw:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "status" or cmd == "check" then
        PrintStatus()
    elseif cmd == "loginlog" or cmd == "quiet" then
        if F.DumpSuppressedLoginMsgs then F.DumpSuppressedLoginMsgs() end
    elseif cmd == "nav" or cmd == "beam" then
        local wa = F.Modules.Get("waypointAutoTrack")
        if wa and wa.DumpDiagnostics then wa:DumpDiagnostics() end
    elseif cmd == "doctor" or cmd == "health" or cmd == "hub" then
        local hub = F.Modules.Get("controlHub")
        if hub and hub.PrintHealthReport then hub:PrintHealthReport() end
    elseif cmd == "kw" then
        local cb = F.Modules.Get("chatBar")
        if cb then
            local db = cb:GetDB()
            if rest and rest ~= "" then
                if rest == "clear" or rest == "off" then
                    db.keywords = ""
                    db.keywordAlert = false
                    F.Print("已清空并关闭聊天关键词提醒。")
                else
                    db.keywords = rest
                    db.keywordAlert = true
                    F.Print("已开启聊天关键词提醒：" .. rest)
                end
                if cb.RefreshKeywordWatch then cb:RefreshKeywordWatch() end
            else
                local kw = type(db.keywords) == "string" and db.keywords or ""
                F.Print("当前关键词：" .. (kw ~= "" and kw or "（空）") .. "；用法：/kk kw 黑龙,通灵 或 /kk kw clear")
            end
        end
    elseif cmd == "world" then
        local cb = F.Modules.Get("chatBar")
        if cb and cb.SetWorldChannelName then
            if rest and rest ~= "" then
                cb:SetWorldChannelName(rest == "reset" and "" or rest)
            else
                local cur = cb:GetDB().worldChannelName
                F.Print("当前世界频道：" .. ((type(cur) == "string" and cur ~= "") and cur or "大脚世界频道")
                    .. "；用法：/kk world 频道名 或 /kk world reset")
            end
        end
    elseif cmd == "slim" then
        if _G.StaticPopup_Show then
            _G.StaticPopup_Show("KKOWOUI_SLIM_CONFIRM")
        else
            ApplyInGameSlim()
        end
    elseif cmd == "restore" then
        RestoreInGameSlim()
    elseif cmd == "deadguard" then
        local arg = (rest or ""):lower()
        if arg == "off" then
            if F.db then F.db.autoDisableDeadAddons = false end
            F.Print("已关闭无效插件自动停用。")
        elseif arg == "arc on" or arg == "arc off" then
            if F.db then F.db.cdmReplacesArc = (arg == "arc on") end
            if arg == "arc on" then
                F.Print("已选择用 EUI 冷却管理器替代 ArcAuras：守卫开着时会停用 ArcAuras 及其子插件。")
                if F.db and F.db.autoDisableDeadAddons ~= false and F.DisableDeadAddons then F.DisableDeadAddons(true) end
            else
                F.Print("不再自动停用 ArcAuras（与 EUI 冷却管理器同时开启时会提示二选一）。")
            end
        else
            if F.db then F.db.autoDisableDeadAddons = true end
            local extra = (F.PreferCDMOverArc and F.PreferCDMOverArc()) and "、ArcAuras 及其子插件" or ""
            F.Print("已开启无效插件自动停用（ArcUI、163UI_Info、QuestieTrace、BlizzMove_Debug、被改名版替代的原版插件" .. extra .. "）。")
            if F.DisableDeadAddons then F.DisableDeadAddons(true) end
        end
    elseif cmd == "unifybars" then
        local mc = F.Modules.Get("modernChrome")
        if mc and mc.UnifyResourceBarsNow then mc:UnifyResourceBarsNow() end
    elseif cmd == "restorebars" then
        local mc = F.Modules.Get("modernChrome")
        if mc and mc.RestoreResourceBarsNow then mc:RestoreResourceBarsNow() end
    elseif cmd == "friendly" or cmd == "city" then
        local np = F.Modules.Get("nameplateSmart")
        if np and np.CycleFriendlyMode then
            np:CycleFriendlyMode(rest ~= "" and rest:lower() or nil)
        end
    elseif cmd == "hud" or cmd == "immerse" then
        local im = F.Modules.Get("immersiveHUD")
        if im and im.ToggleImmersive then im:ToggleImmersive() end
    elseif cmd == "perf" or cmd == "boost" then
        local pf = F.Modules.Get("perfAutoTier")
        if pf and pf.ToggleForceBoost then pf:ToggleForceBoost() end
    elseif cmd == "toast" then
        local lt = F.Modules.Get("lootToast")
        if lt and lt.ShowPreview then lt:ShowPreview() end
    elseif cmd == "ss" or cmd == "soulstone" then
        local ss = F.Modules.Get("soulstoneAlert")
        if ss then
            local sub = (rest or ""):lower()
            if sub == "voice" or sub == "tts" then
                if ss.TestVoice then ss:TestVoice() end
            elseif sub == "normal" or sub == "expired" or sub == "expiring" then
                if ss.ShowPreview then ss:ShowPreview(sub) end
            elseif sub == "clear" or sub == "stop" or sub == "off" then
                if ss.DismissPreview then ss:DismissPreview() end
            else
                if ss.ShowPreview then ss:ShowPreview("expiring") end
            end
        end
    elseif cmd == "emote" or cmd == "rp" then
        local ce = F.Modules.Get("classEmote")
        if ce and ce.TriggerCommand then
            ce:TriggerCommand(rest)
        end
    elseif cmd == "trainerdebug" then
        if F.DumpTrainerDebug then F.DumpTrainerDebug() end
    elseif cmd == "wp" or cmd == "proc" then
        local wp = F.Modules.Get("weaponProcs")
        if wp and wp.TogglePreview then wp:TogglePreview() end
    elseif cmd == "keys" or cmd == "keybind" then
        local kb = F.EnsureKeybindBoardLoaded and F.EnsureKeybindBoardLoaded() or F.Modules.Get("keybindBoard")
        if kb and kb.ToggleBoard then kb:ToggleBoard() end
    elseif cmd == "unlock" then
        local EUI = _G.EllesmereUI
        if EUI and EUI.ToggleUnlockMode then
            pcall(EUI.ToggleUnlockMode, EUI)
        else
            F.Print("请按住 Shift + 左键拖动框体调整位置，或在 EllesmereUI 里开启解锁模式。")
        end
    else
        local EUI = _G.EllesmereUI
        if EUI and EUI.OpenPlugin then
            EUI.OpenPlugin(F.NAME)
        else
            PrintStatus()
        end
    end
end
