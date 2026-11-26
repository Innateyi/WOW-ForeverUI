----------------------------------------------------------------------
--  kkowoUI — Core/Options.lua
--  通过 EllesmereUI.RegisterPlugin 官方接口挂载统一设置面板 + /kk 命令
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, math_abs, pcall, type = ipairs, pairs, math.abs, pcall, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local GROUPS = {
    {
        key   = "QuestLeveling",
        title = "任务与练级",
        desc  = "自动接交任务、任务快捷条、任务经验、经验/声望条、采集与拾取闪光、地图区域等级。",
        pages = { "任务增强", "经验与地图" },
        pageMap = {
            ["任务增强"]   = { "questAuto", "questBar", "questXP" },
            ["经验与地图"] = { "xpBar", "nodeReminder", "zoneLabels", "worldNames" },
        },
    },
    {
        key   = "CombatAudio",
        title = "战斗与音效",
        desc  = "职业预设冷却条、进/脱战剑盾提醒、术士灵魂石到期提醒、猎人技能音效、Roll 点条、快捷标记条。",
        pages = { "战斗增强", "灵魂石提醒", "猎人音效" },
        pageMap = {
            ["战斗增强"]   = { "cdPresets", "combatAlert", "rollBars", "markBar" },
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
        desc  = "全局视觉统一、人物面板装备一览、姓名板主城减卡、场景性能自动档位、沉浸探索淡隐、一体化系统栏与极简鼠标提示。",
        pages = { "视觉与性能", "沉浸与系统栏" },
        pageMap = {
            ["视觉与性能"]   = { "modernChrome", "gearList", "auctionSkin", "nameplateSmart", "perfAutoTier" },
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
        label = "kkowoUI",
        position = "top",
        modules = pluginModules,
    })
end

RegisterWithEUI()

-- /kk 命令：打开设置、查看模块状态、快速触发解锁模式
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
    -- 已整合进 kkowoUI 的 6 个插件（保留 PrettyTooltip 以完整呈现哈兰德卡片提示材质）
    "QFXSystemBar", "QFXSystemBar_Config", "QFXSystemBar_InfoBar",
    "QFXSystemBar_Locale", "QFXSystemBar_MeetingStone",
    "EllesmereUIDataBars",
    -- 确认闲置 / 练级无用 / 调试 / 重叠重型插件
    "TalentsForever", "ForeverFishing", "ArcAuras", "ArcAuras_Finds", "ArcAuras_LFG", "ArcUI",
    "EllesmereUIAuraBuffReminders", "EllesmereUIQuickdraw", "EllesmereUIMythicTimer",
    "GlowingBars", "MiniMarkers", "163UI_Info", "QuestieTrace", "BlizzMove_Debug",
    "DungeonsForeverPvP", "DungeonsForeverExplore", "DungeonsForeverClass",
    "DungeonsForeverProf", "DungeonsForeverGear", "DungeonsForeverSpell",
    "DungeonsForeverFaction", "DungeonsForeverQuest",
}

local function SetAddOnEnabledSafely(name, enabled)
    local ca = _G.C_AddOns
    local fn = enabled and ((ca and ca.EnableAddOn) or _G.EnableAddOn)
        or ((ca and ca.DisableAddOn) or _G.DisableAddOn)
    if not fn then return end
    local getState = ca and ca.GetAddOnEnableState
    local guid = _G.UnitGUID and _G.UnitGUID("player") or nil
    if guid then
        pcall(fn, name, guid)
    end
    local matched = false
    if getState then
        local ok, st = pcall(getState, name)
        if ok and type(st) == "number" then
            if enabled then
                matched = st > 0
            else
                matched = st == 0
            end
        end
    end
    if not matched then
        pcall(fn, name)
    end
end

local function ApplyInGameSlim()
    local disable = (_G.C_AddOns and _G.C_AddOns.DisableAddOn) or _G.DisableAddOn
    local getState = _G.C_AddOns and _G.C_AddOns.GetAddOnEnableState
    local existsFn = _G.C_AddOns and _G.C_AddOns.DoesAddOnExist
    local saveFn = _G.C_AddOns and _G.C_AddOns.SaveAddOns
    if not disable then
        F.Print("|cffe05263当前客户端不支持插件开关接口，请退出游戏后运行 Tools\\slim_addons.py。|r")
        return
    end
    local list = {}
    for _, name in ipairs(SLIM_LIST) do
        list[#list + 1] = name
    end
    local backup = {}
    local count = 0
    for _, name in ipairs(list) do
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
            SetAddOnEnabledSafely(name, false)
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
    -- 玩家主动还原：不再在登录时自动停用无效插件，否则下次登录又会被关掉
    if F.db then F.db.autoDisableDeadAddons = false end
    for _, name in ipairs(list) do
        SetAddOnEnabledSafely(name, true)
    end
    if saveFn then pcall(saveFn) end
    F.Print("已重新启用 " .. tostring(#list) .. " 个插件，即将重载界面。")
    if _G.ReloadUI then _G.ReloadUI() end
end

-- 无效 / 已替换插件守卫：下面这些插件在本整合里不该加载，但网易 DD 每次更新所属整包时会把文件夹放回来
-- （ArcUI 随 ArcAuras、QuestieTrace 随 Questie、163UI_Info 是 DD 自己的同步插件），删了也会再出现。
-- 所以登录时检查：只要它们处于启用状态就替本角色停用（下次登录 / 重载生效），不用再手动 /kk slim。
--   ArcUI           Arc UI Forever 迁移存根，自身什么都不画
--   163UI_Info      DD 数据同步插件，没有适配无限服（16001）的 TOC，根本加载不了
--   QuestieTrace    Questie 开发者收集数据用的调试插件
--   BlizzMove_Debug BlizzMove 调试版
--   VamoosesSlipstream 已由改名的 VamoosesSlipstream_kkowo（极速导航 kkowo优化版）替代；DD 若把原版装回来，两份会抢同一份存档
-- 「ArcAuras 换成 EUI 冷却管理器」只在选择后才做（/kk deadguard arc on，作者本机的旧存档自动沿用）：
--   这时 ArcAuras(+子插件) 也会停用，并且每个角色一次性启用 EUI 冷却管理器（之后你自己关掉它也不会再被打开）。
--   默认不碰 ArcAuras：装了整合包的朋友如果本来就在用 ArcAuras，以对方为准。
-- /kk restore 会关闭此守卫；/kk deadguard on 重新打开。
local DEAD_ADDONS = { "ArcUI", "163UI_Info", "QuestieTrace", "BlizzMove_Debug" }
local ARC_ADDONS = { "ArcAuras", "ArcAuras_Finds", "ArcAuras_LFG" }
-- 原版 -> 替代它的改名版：替代版存在且启用时才停用原版
local REPLACED_BY = { VamoosesSlipstream = "VamoosesSlipstream_kkowo" }
local CDM_ADDON = "EllesmereUICooldownManager"

local function PreferCDMOverArc()
    if not F.db then return false end
    if F.db.cdmReplacesArc == nil then
        -- 旧存档：守卫已经替这个角色启用过 EUI 冷却管理器，说明当初选的就是「ArcAuras 换成 EUI 冷却管理器」
        F.db.cdmReplacesArc = (F.charDB and F.charDB.cdmEnabledOnce == true) or false
    end
    return F.db.cdmReplacesArc == true
end

local function ShowReloadOffer(msg)
    if not (_G.StaticPopupDialogs and _G.StaticPopup_Show) then return end
    if not _G.StaticPopupDialogs["KKOWOUI_ADDON_RELOAD"] then
        _G.StaticPopupDialogs["KKOWOUI_ADDON_RELOAD"] = {
            text = "%s",
            button1 = "立即重载",
            button2 = "稍后",
            OnAccept = function() if _G.ReloadUI then _G.ReloadUI() end end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    F.RunOutOfCombat("KKOWOUI_ADDON_RELOAD", function()
        _G.StaticPopup_Show("KKOWOUI_ADDON_RELOAD", msg)
    end)
end

local function DisableDeadAddons(verbose)
    local ca = _G.C_AddOns
    local getState = ca and ca.GetAddOnEnableState
    local existsFn = ca and ca.DoesAddOnExist
    if not getState then return 0 end
    local guid = _G.UnitGUID and _G.UnitGUID("player") or nil
    local function Exists(name)
        if not existsFn then return true end
        local okEx, ex = pcall(existsFn, name)
        return okEx and ex == true
    end
    local function State(name)
        local ok, st = pcall(getState, name, guid)
        if not ok then ok, st = pcall(getState, name) end
        return (ok and type(st) == "number") and st or nil
    end
    local preferCDM = PreferCDMOverArc()
    local list = {}
    for _, name in ipairs(DEAD_ADDONS) do list[#list + 1] = name end
    if preferCDM then
        for _, name in ipairs(ARC_ADDONS) do list[#list + 1] = name end
    end
    for orig, repl in pairs(REPLACED_BY) do
        local rs = Exists(repl) and State(repl)
        if rs and rs > 0 then list[#list + 1] = orig end
    end
    local off = {}
    for _, name in ipairs(list) do
        if Exists(name) then
            local st = State(name)
            if st and st > 0 then
                SetAddOnEnabledSafely(name, false)
                off[#off + 1] = name
            end
        end
    end
    -- 选择了用 EUI 冷却管理器替代 ArcAuras 时，每个角色一次：启用 EUI 冷却管理器
    local cdmOn = false
    if preferCDM and F.charDB and not F.charDB.cdmEnabledOnce then
        F.charDB.cdmEnabledOnce = true
        if Exists(CDM_ADDON) and State(CDM_ADDON) == 0 then
            SetAddOnEnabledSafely(CDM_ADDON, true)
            cdmOn = true
        end
    end
    if #off > 0 or cdmOn then
        if ca.SaveAddOns then pcall(ca.SaveAddOns) end
        local parts = {}
        if #off > 0 then parts[#parts + 1] = "已停用：" .. table.concat(off, "、") end
        if cdmOn then parts[#parts + 1] = "已启用：EUI 冷却管理器" end
        F.Print(table.concat(parts, "；") .. "（下次登录 / 重载生效；/kk deadguard off 可关闭自动停用）")
        -- 其中有正在运行的插件（如 ArcAuras）或刚启用了冷却管理器：问一句要不要马上重载
        local liveChange = cdmOn
        for _, name in ipairs(off) do
            if F.IsAddOnLoaded(name) then liveChange = true end
        end
        if liveChange then
            ShowReloadOffer("|cffdca77fkkowoUI|r\n\n" .. table.concat(parts, "\n") .. "\n\n重载界面后生效，现在重载吗？")
        end
    elseif verbose then
        F.Print("没有需要停用的无效插件。")
    end
    return #off
end

do
    local guard = CreateFrame("Frame")
    guard:RegisterEvent("PLAYER_LOGIN")
    guard:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        C_Timer.After(3, function()
            if F.db and F.db.autoDisableDeadAddons ~= false then
                DisableDeadAddons(false)
            end
        end)
    end)
end

if _G.StaticPopupDialogs then
    _G.StaticPopupDialogs["KKOWOUI_SLIM_CONFIRM"] = {
        text = "|cffdca77fkkowoUI 一键瘦身与精简切换|r\n\n将停用已合并或闲置/冲突的重型插件（约省 35+ MB 常驻内存，其他角色若也启用了它们会一并停用），随后自动重载界面：\n\n• 合并/冲突：QFXSystemBar×5、EUI DataBars、ArcAuras（与 EUI 冷却管理器冲突，已改用后者）\n• 闲置/调试：TalentsForever、ForeverFishing、ArcAuras_Finds/LFG、ArcUI、163UI_Info、QuestieTrace、EUI Quickdraw/MythicTimer/BuffReminders、GlowingBars、MiniMarkers、DungeonsForever×8 百科子库\n\n你的布局与核心插件全部保留，随时可输入 /kk restore 一键还原。",
        button1 = "确认瘦身并重载",
        button2 = "取消",
        OnAccept = ApplyInGameSlim,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

_G.SLASH_KKOWOUI1 = "/kk"
_G.SLASH_KKOWOUI2 = "/kkowoui"
-- 兼容改名前的旧命令，已有的 /fui 宏（如 /fui boost、/fui hud）继续可用
_G.SLASH_KKOWOUI3 = "/fui"
_G.SLASH_KKOWOUI4 = "/foreverui"
_G.SlashCmdList.KKOWOUI = function(msg)
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
                if F.db and F.db.autoDisableDeadAddons ~= false then DisableDeadAddons(true) end
            else
                F.Print("不再自动停用 ArcAuras（与 EUI 冷却管理器同时开启时会提示二选一）。")
            end
        else
            if F.db then F.db.autoDisableDeadAddons = true end
            local extra = PreferCDMOverArc() and "、ArcAuras 及其子插件" or ""
            F.Print("已开启无效插件自动停用（ArcUI、163UI_Info、QuestieTrace、BlizzMove_Debug、被改名版替代的原版插件" .. extra .. "）。/kk deadguard arc on|off 切换是否用 EUI 冷却管理器替代 ArcAuras。")
            DisableDeadAddons(true)
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
    elseif cmd == "keys" or cmd == "keybind" then
        local kb = F.Modules.Get("keybindBoard")
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
