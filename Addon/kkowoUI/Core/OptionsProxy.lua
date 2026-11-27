----------------------------------------------------------------------
--  kkowoUI — Core/OptionsProxy.lua
--  极轻量配置入口代理（常驻仅 ~100 行）：
--    • 启动时向 EllesmereUI 注册 6 个顶层侧边栏菜单，保证打开 /eui 即见
--    • 真正点击菜单页或输入 /kk 时按需加载 kkowoUI_Options (LoadOnDemand: 1)
--    • 输入 /kkkeys 时按需加载 kkowoUI_KeybindBoard (LoadOnDemand: 1)
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pcall, type = ipairs, pcall, type

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
    F.Print("|cffff5555无法按需加载 " .. addonName .. "：|r" .. tostring(reason or loaded or "未知原因") .. "（请在插件列表确认已启用）。")
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
        title = "整合包总控",
        desc  = "一键打开 kkowoUI_Tooltip 与保留上游核心引擎（按 ESC 自动返回），并提供补丁守卫与重叠开关体检。",
        pages = { "插件总控台", "重叠体检与补丁守卫" },
        isHub = true,
    },
    {
        key   = "QuestLeveling",
        title = "任务与练级",
        desc  = "自动接交任务、任务快捷条、任务经验、经验/声望条、采集与拾取闪光、地图区域等级。",
        pages = { "任务增强", "经验与地图" },
        pageMap = {
            ["任务增强"]   = { "questAuto", "questBar", "questXP" },
            ["经验与地图"] = { "xpBar", "nodeReminder", "zoneLabels", "waypointAutoTrack", "polestarNav", "worldNames" },
        },
    },
    {
        key   = "CombatAudio",
        title = "战斗与音效",
        desc  = "职业预设冷却条、武器附魔与攻击特效计时条、进/脱战剑盾提醒、术士灵魂石到期提醒、猎人技能音效、Roll 点条、快捷标记条。",
        pages = { "战斗增强", "武器特效", "灵魂石提醒", "猎人音效" },
        pageMap = {
            ["战斗增强"]   = { "cdPresets", "combatAlert", "rollBars", "markBar" },
            ["武器特效"]   = { "weaponProcs" },
            ["灵魂石提醒"] = { "soulstoneAlert" },
            ["猎人音效"]   = { "spellSounds" },
        },
    },
    {
        key   = "SocialUtility",
        title = "社交与工具",
        desc  = "融合聊天条、右键菜单与邮件联系人、趣味职业表情喊话、极速静默拾取、现代拾取微播报、装备耐久度。",
        pages = { "聊天与社交", "趣味表情喊话", "拾取与工具" },
        pageMap = {
            ["聊天与社交"]   = { "chatBar", "chatBubbles", "socialTools" },
            ["趣味表情喊话"] = { "classEmote" },
            ["拾取与工具"]   = { "bagUtility", "lootToast", "durability" },
        },
    },
    {
        key   = "ModernUI",
        title = "现代视觉与性能",
        desc  = "全局视觉统一、伤害统计圆角与黑曜石明细卡、人物面板装备一览、姓名板主城减卡、场景性能自动档位、脱战淡隐、一体化系统栏与极简鼠标提示。",
        pages = { "视觉与性能", "沉浸与系统栏" },
        pageMap = {
            ["视觉与性能"]   = { "modernChrome", "damageMeterSkin", "euiRuntimeFixes", "extraFrameMover", "gearList", "auctionSkin", "nameplateSmart", "perfAutoTier" },
            ["沉浸与系统栏"] = { "immersiveHUD", "systemBar", "tooltipStyle" },
        },
    },
    {
        key   = "MotionFX",
        title = "动效与视觉增强",
        desc  = "全局圆角渐变、核心双翼血蓝条与动态旋转技能球、独立宠物与顶部目标条、低血量红暗角、施法/挥砍/动作条/姓名板动效及可视化键位图。",
        pages = { "总控与圆角", "核心双翼与预警", "施法挥砍与技能条", "姓名板与键位图" },
        pageMap = {
            ["总控与圆角"]       = { "motionFX", "auraBarSkin" },
            ["核心双翼与预警"]   = { "coreHUD", "lowHealthAlert" },
            ["施法挥砍与技能条"] = { "castbarMotion", "swingTimerMotion", "actionBarMotion" },
            ["姓名板与键位图"]   = { "nameplateMotion", "keybindBoard" },
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
