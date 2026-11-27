----------------------------------------------------------------------
--  kkowoUI — Core/OptionsProxy.lua
--  极轻量配置入口代理（常驻）：
--    • 启动时向 EllesmereUI 注册 6 个顶层侧边栏菜单（24 页，44 模块全覆盖）
--    • 真正点击菜单页或输入 /kk 时按需加载 kkowoUI_Options (LoadOnDemand: 1)
--    • 输入 /kkkeys 时按需加载 kkowoUI_KeybindBoard (LoadOnDemand: 1)
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pcall, tostring, type = ipairs, pcall, tostring, type

local function LoadLoD(addonName)
    if F.IsAddOnLoaded(addonName) then
        return true
    end
    local loader = (_G.C_AddOns and _G.C_AddOns.LoadAddOn) or _G.LoadAddOn
    if type(loader) ~= "function" then
        return false
    end
    local ok, loaded, reason = pcall(loader, addonName)
    if ok and loaded then
        return true
    end
    F.Print("|cffff5555无法加载 " .. addonName .. "：|r" .. tostring(reason or loaded or "未知原因") .. "，请在插件列表确认已启用。")
    return false
end

function F.EnsureOptionsLoaded()
    if type(F._OptionsUI) == "table" then
        return F._OptionsUI
    end
    if LoadLoD("kkowoUI_Options") and type(F._OptionsUI) == "table" then
        return F._OptionsUI
    end
    return nil
end

function F.EnsureKeybindBoardLoaded()
    local kb = F.Modules.Get("keybindBoard")
    if kb then return kb end
    if LoadLoD("kkowoUI_KeybindBoard") then
        return F.Modules.Get("keybindBoard")
    end
    return nil
end

F.OPTION_GROUPS = {
    {
        key   = "ControlHub",
        title = "总控",
        desc  = "快捷入口、综合体检、一键瘦身与诊断工具。",
        pages = { "快捷入口", "体检与守卫", "瘦身与高级" },
        isHub = true,
    },
    {
        key   = "Appearance",
        title = "界面外观",
        desc  = "主题圆角、提示框、系统栏、伤害统计、人物拍卖与窗口沉浸。",
        pages = { "主题与圆角", "提示框", "系统栏与统计", "人物与拍卖", "窗口与沉浸" },
        pageMap = {
            ["主题与圆角"]   = { "modernChrome:theme", "motionFX", "auraBarSkin" },
            ["提示框"]       = { "tooltipStyle" },
            ["系统栏与统计"] = { "systemBar", "damageMeterSkin" },
            ["人物与拍卖"]   = { "modernChrome:character", "gearList", "auctionSkin" },
            ["窗口与沉浸"]   = { "immersiveHUD", "perfAutoTier", "extraFrameMover", "keybindBoard" },
        },
    },
    {
        key   = "CombatHUD",
        title = "战斗 HUD",
        desc  = "双翼与目标、施法与挥砍、动作条、姓名板、标记与冷却预设。",
        pages = { "双翼与目标", "施法与挥砍", "动作条与提醒", "姓名板", "标记与标记条" },
        pageMap = {
            ["双翼与目标"]   = { "coreHUD", "lowHealthAlert" },
            ["施法与挥砍"]   = { "castbarMotion", "swingTimerMotion" },
            ["动作条与提醒"] = { "actionBarMotion", "combatAlert", "cdPresets" },
            ["姓名板"]       = { "nameplateMotion", "nameplateSmart", "euiRuntimeFixes" },
            ["标记与标记条"] = { "markBar" },
        },
    },
    {
        key   = "QuestMap",
        title = "任务与地图",
        desc  = "自动任务、任务条、经验与声望、大地图、导航与采集提醒。",
        pages = { "自动任务与任务条", "经验与声望", "大地图与导航", "采集提醒" },
        pageMap = {
            ["自动任务与任务条"] = { "questAuto", "questBar", "questXP" },
            ["经验与声望"]       = { "xpBar" },
            ["大地图与导航"]     = { "zoneLabels", "waypointAutoTrack", "polestarNav", "modernChrome:map", "worldNames" },
            ["采集提醒"]         = { "nodeReminder" },
        },
    },
    {
        key   = "ChatSocial",
        title = "聊天与社交",
        desc  = "聊天条、气泡、社交与邮件、拾取播报、掷点条与耐久。",
        pages = { "聊天条", "气泡与社交", "拾取与耐久" },
        pageMap = {
            ["聊天条"]     = { "chatBar" },
            ["气泡与社交"] = { "chatBubbles", "socialTools" },
            ["拾取与耐久"] = { "bagUtility", "lootToast", "rollBars", "durability" },
        },
    },
    {
        key   = "ClassPack",
        title = "职业专属",
        desc  = "术士灵魂石、猎人音效、武器特效与职业表情喊话。",
        pages = { "灵魂石", "猎人音效", "武器特效", "职业表情" },
        pageMap = {
            ["灵魂石"]   = { "soulstoneAlert" },
            ["猎人音效"] = { "spellSounds", "modernChrome:audio" },
            ["武器特效"] = { "weaponProcs" },
            ["职业表情"] = { "classEmote" },
        },
    },
}

local function RegisterWithEUI()
    local EUI = _G.EllesmereUI
    if not (EUI and EUI.RegisterPlugin) then
        return
    end
    local pluginModules = {}
    for _, g in ipairs(F.OPTION_GROUPS) do
        local groupSpec = g
        pluginModules[#pluginModules + 1] = {
            key = groupSpec.key,
            title = groupSpec.title,
            description = groupSpec.desc,
            pages = groupSpec.pages,
            buildPage = function(pageName, parent, yOffset)
                local ui = F.EnsureOptionsLoaded()
                if ui and type(ui.BuildGroupPage) == "function" then
                    return ui.BuildGroupPage(groupSpec, pageName, parent, yOffset)
                end
                return 0
            end,
        }
    end
    EUI.RegisterPlugin(F.NAME, {
        label = "kkowoUI",
        position = "top",
        modules = pluginModules,
    })
end

RegisterWithEUI()

-- /kk, /kkowoui, /fui, /foreverui 统一入口（按需加载 kkowoUI_Options）
_G.SLASH_KKOWOUI1 = "/kk"
_G.SLASH_KKOWOUI2 = "/kkowoui"
_G.SLASH_KKOWOUI3 = "/fui"
_G.SLASH_KKOWOUI4 = "/foreverui"
_G.SlashCmdList.KKOWOUI = function(msg)
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd = (raw:match("^(%S+)") or ""):lower()
    if cmd == "keys" or cmd == "keybind" then
        local kb = F.EnsureKeybindBoardLoaded()
        if kb and kb.ToggleBoard then kb:ToggleBoard() end
        return
    end
    if cmd == "" then
        local EUI = _G.EllesmereUI
        if EUI and EUI.OpenPlugin then
            EUI.OpenPlugin(F.NAME)
            return
        end
    end
    local ui = F.EnsureOptionsLoaded()
    if ui and type(ui.HandleSlash) == "function" then
        ui.HandleSlash(msg)
    end
end

-- /kkkeys 快捷入口（按需加载 kkowoUI_KeybindBoard）
_G.SLASH_KKOWOKEYS1 = "/kkkeys"
_G.SlashCmdList.KKOWOKEYS = function()
    local kb = F.EnsureKeybindBoardLoaded()
    if kb and kb.ToggleBoard then
        kb:ToggleBoard()
    end
end
