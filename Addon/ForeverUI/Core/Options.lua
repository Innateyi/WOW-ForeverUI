----------------------------------------------------------------------
--  ForeverUI — Core/Options.lua
--  通过 EllesmereUI.RegisterPlugin 官方接口挂载统一设置面板 + /fui 命令
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_abs, pcall = ipairs, math.abs, pcall

local GROUPS = {
    {
        key   = "QuestLeveling",
        title = "任务与练级",
        desc  = "自动接交任务、任务快捷条、任务经验、经验/声望条、采集与拾取闪光、地图区域等级。",
        pages = { "任务增强", "经验与地图" },
        pageMap = {
            ["任务增强"]   = { "questAuto", "questBar", "questXP" },
            ["经验与地图"] = { "xpBar", "nodeReminder", "zoneLabels" },
        },
    },
    {
        key   = "CombatAudio",
        title = "战斗与音效",
        desc  = "进/脱战剑盾提醒、猎人技能音效、Roll 点条、快捷标记条。",
        pages = { "战斗增强", "猎人音效" },
        pageMap = {
            ["战斗增强"] = { "combatAlert", "rollBars", "markBar" },
            ["猎人音效"] = { "spellSounds" },
        },
    },
    {
        key   = "SocialUtility",
        title = "社交与工具",
        desc  = "融合聊天条、右键菜单与邮件联系人、极速静默拾取、现代拾取微播报、装备耐久度。",
        pages = { "聊天与社交", "拾取与工具" },
        pageMap = {
            ["聊天与社交"] = { "chatBar", "socialTools" },
            ["拾取与工具"] = { "bagUtility", "lootToast", "durability" },
        },
    },
    {
        key   = "ModernUI",
        title = "现代视觉与性能",
        desc  = "全局视觉统一、姓名板主城减卡、场景性能自动档位、沉浸探索淡隐、一体化系统栏与极简鼠标提示。",
        pages = { "视觉与性能", "沉浸与系统栏" },
        pageMap = {
            ["视觉与性能"]   = { "modernChrome", "nameplateSmart", "perfAutoTier" },
            ["沉浸与系统栏"] = { "immersiveHUD", "systemBar", "tooltipStyle" },
        },
    },
}

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

local function RegisterWithEUI()
    local EUI = _G.EllesmereUI
    if not (EUI and EUI.RegisterPlugin) then
        return
    end

    local pluginModules = {}
    for _, g in ipairs(GROUPS) do
        local groupSpec = g
        pluginModules[#pluginModules + 1] = {
            key = groupSpec.key,
            title = groupSpec.title,
            description = groupSpec.desc,
            pages = groupSpec.pages,
            buildPage = function(pageName, parent, yOffset)
                local W = EUI.Widgets
                if not W then
                    return 0
                end
                local y = yOffset or 0
                local keys = groupSpec.pageMap[pageName] or {}
                for _, modKey in ipairs(keys) do
                    local mod = F.Modules.Get(modKey)
                    if mod then
                        y = BuildModuleSection(mod, W, parent, y)
                    end
                end
                return math_abs(y) + 20
            end,
        }
    end

    EUI.RegisterPlugin(F.NAME, {
        label = "ForeverUI",
        position = "top",
        modules = pluginModules,
    })
end

RegisterWithEUI()

-- /fui 命令：打开设置、查看模块状态、快速触发解锁模式
local function PrintStatus()
    F.Print("版本 " .. F.VERSION .. " — 模块运行状态：")
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
    -- 已整合进 ForeverUI 的 6 个插件（保留 PrettyTooltip 以完整呈现哈兰德卡片提示材质）
    "QFXSystemBar", "QFXSystemBar_Config", "QFXSystemBar_InfoBar",
    "QFXSystemBar_Locale", "QFXSystemBar_MeetingStone",
    "EllesmereUIDataBars",
    -- 确认闲置 / 练级无用 / 重叠重型插件（17 个）
    "TalentsForever", "ForeverFishing", "ArcAuras_Finds", "ArcAuras_LFG",
    "EllesmereUIAuraBuffReminders", "EllesmereUIQuickdraw", "EllesmereUIMythicTimer",
    "GlowingBars", "MiniMarkers",
    "DungeonsForeverPvP", "DungeonsForeverExplore", "DungeonsForeverClass",
    "DungeonsForeverProf", "DungeonsForeverGear", "DungeonsForeverSpell",
    "DungeonsForeverFaction", "DungeonsForeverQuest",
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
    local player = _G.UnitName and _G.UnitName("player") or nil
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
                local ok, st = pcall(getState, name, player)
                if ok and type(st) == "number" and st > 0 then wasEnabled = true end
            else
                wasEnabled = true
            end
        end
        if wasEnabled then
            backup[#backup + 1] = name
            pcall(disable, name, player)
            count = count + 1
        end
    end
    if #backup > 0 then
        if F.charDB then F.charDB.slimBackup = backup
        elseif F.db then F.db.slimBackup = backup end
    end
    if saveFn then pcall(saveFn) end
    F.Print("已为当前角色停用 " .. tostring(count) .. " 个重叠/闲置插件，即将重载界面（随时可用 /fui restore 一键还原）。")
    if _G.ReloadUI then _G.ReloadUI() end
end

local function RestoreInGameSlim()
    local enable = (_G.C_AddOns and _G.C_AddOns.EnableAddOn) or _G.EnableAddOn
    local saveFn = _G.C_AddOns and _G.C_AddOns.SaveAddOns
    local charBak = F.charDB and type(F.charDB.slimBackup) == "table" and #F.charDB.slimBackup > 0 and F.charDB.slimBackup or nil
    local accBak = F.db and type(F.db.slimBackup) == "table" and #F.db.slimBackup > 0 and F.db.slimBackup or nil
    local list = charBak or accBak or SLIM_LIST
    if not enable then return end
    local player = _G.UnitName and _G.UnitName("player") or nil
    for _, name in ipairs(list) do
        pcall(enable, name, player)
    end
    if saveFn then pcall(saveFn) end
    F.Print("已重新启用 " .. tostring(#list) .. " 个插件，即将重载界面。")
    if _G.ReloadUI then _G.ReloadUI() end
end

if _G.StaticPopupDialogs then
    _G.StaticPopupDialogs["FOREVERUI_SLIM_CONFIRM"] = {
        text = "|cffdca77fForeverUI 一键瘦身与精简切换|r\n\n将为当前角色停用以下 23 个已合并或闲置的重型插件（约省 35 MB 常驻内存），随后自动重载界面：\n\n• 合并替代：QFXSystemBar×5、EUI DataBars（PrettyTooltip 将完整保留）\n• 闲置/重叠：TalentsForever、ForeverFishing、ArcAuras_Finds/LFG、EUI Quickdraw/MythicTimer/BuffReminders、GlowingBars、MiniMarkers、DungeonsForever×8 百科子库\n\n你的布局与核心插件全部保留，随时可输入 /fui restore 一键还原。",
        button1 = "确认瘦身并重载",
        button2 = "取消",
        OnAccept = ApplyInGameSlim,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

_G.SLASH_FOREVERUI1 = "/fui"
_G.SLASH_FOREVERUI2 = "/foreverui"
_G.SlashCmdList.FOREVERUI = function(msg)
    local raw = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = raw:match("^(%S+)%s*(.*)$")
    cmd = (cmd or ""):lower()
    if cmd == "status" or cmd == "check" then
        PrintStatus()
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
                F.Print("当前关键词：" .. (kw ~= "" and kw or "（空）") .. "；用法：/fui kw 黑龙,通灵 或 /fui kw clear")
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
                    .. "；用法：/fui world 频道名 或 /fui world reset")
            end
        end
    elseif cmd == "slim" then
        if _G.StaticPopup_Show then
            _G.StaticPopup_Show("FOREVERUI_SLIM_CONFIRM")
        else
            ApplyInGameSlim()
        end
    elseif cmd == "restore" then
        RestoreInGameSlim()
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
    elseif cmd == "trainerdebug" then
        if F.DumpTrainerDebug then F.DumpTrainerDebug() end
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
