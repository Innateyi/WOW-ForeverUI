----------------------------------------------------------------------
--  kkowoUI_Options — ControlHubUI.lua (LoadOnDemand: 1)
--  /kk 顶层「整合包总控台」双页面 UI + 重叠体检 + 一键对齐 + /kk doctor
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, pcall, tostring, type = ipairs, pcall, tostring, type
local table_concat = table.concat
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown

local mod = F.Modules.Get("controlHub")
if not mod then return end

local function OpenOrWarn(addonName, slash, arg, displayName, customFn, keepEUIOpen, expectedFrameFn)
    if InCombatLockdown and InCombatLockdown() then
        F.Print("|cffe0a24b战斗中暂不打开「" .. displayName .. "」，脱战后再点即可。|r")
        return
    end
    if addonName and not F.IsAddOnLoaded(addonName) then
        F.Print("未检测到已启用的 " .. displayName .. "（" .. addonName .. "）。")
        return
    end
    local function dispatch()
        if type(customFn) == "function" then
            local ok, opened = pcall(customFn)
            if ok and opened ~= false then
                return
            end
        end
        if slash and F.RunSlashCommand(slash, arg) then
            return
        end
        local hint = slash or ""
        if arg and arg ~= "" then hint = hint .. " " .. arg end
        F.Print("请在聊天框输入 |cff5fd3a6" .. hint .. "|r 打开 " .. displayName .. "。")
    end
    if keepEUIOpen or type(F.LaunchFromEUI) ~= "function" then
        dispatch()
    else
        F.LaunchFromEUI(dispatch, expectedFrameFn)
    end
end

local function GetBugCount()
    local bg = _G.BugGrabber
    if type(bg) ~= "table" or type(bg.GetDB) ~= "function" then
        return nil
    end
    local okDB, db = pcall(bg.GetDB, bg)
    if not (okDB and type(db) == "table") then return nil end
    local curSid = nil
    if type(bg.GetSessionId) == "function" then
        local okS, sid = pcall(bg.GetSessionId, bg)
        if okS and type(sid) == "number" then
            curSid = sid
        end
    end
    if not curSid and type(_G.BugGrabberDB) == "table" and type(_G.BugGrabberDB.session) == "number" then
        curSid = _G.BugGrabberDB.session
    end
    local count = 0
    for _, err in ipairs(db) do
        if type(err) == "table" and (not curSid or err.session == curSid) then
            count = count + 1
        end
    end
    return count
end

local RETIRED_OVERLAPS = {
    "YaMedia",
    "BlizzMove",
    "Leatrix_Maps",
    "WaypointUI",
    "VamoosesSlipstream",
    "VamoosesSlipstream_kkowo",
    "PrettyTooltip",
    "EllesmereUIDataBars",
    "EllesmereUIMythicTimer",
    "EllesmereUIQuickdraw",
    "EllesmereUIAuraBuffReminders",
    "EllesmereUIFriends",
    "EllesmereUIGroupFinder",
    "Polestar_Arcade",
}

local function CollectHealthReport()
    local patches = F.CheckPatches and F.CheckPatches() or {}
    local missingPatches = {}
    for _, p in ipairs(patches) do
        if not p.ok then
            missingPatches[#missingPatches + 1] = p
        end
    end

    local loadedOverlaps = {}
    for _, name in ipairs(RETIRED_OVERLAPS) do
        if F.IsAddOnLoaded(name) then
            if name ~= "PrettyTooltip" or F.IsAddOnLoaded("kkowoUI_Tooltip") then
                loadedOverlaps[#loadedOverlaps + 1] = name
            end
        end
    end

    local configWarnings = {}
    local edb = _G.EllesmereUIDB
    if type(edb) == "table" then
        if edb.shifterEnabled == false then
            configWarnings[#configWarnings + 1] = "EUI Shifter 面板拖动未开启"
        end
        if type(edb.inGameNavigation) ~= "table" or edb.inGameNavigation.enabled ~= true then
            configWarnings[#configWarnings + 1] = "EUI 3D 光柱导航 (inGameNavigation) 未开启"
        end
        if type(edb.worldMapReveal) ~= "table" or edb.worldMapReveal.enabled ~= true then
            configWarnings[#configWarnings + 1] = "EUI 大地图全亮 (worldMapReveal) 未开启"
        end
        if type(edb.mapTravel) ~= "table" or edb.mapTravel.enabled ~= true then
            configWarnings[#configWarnings + 1] = "EUI 大地图交通/飞点标记 (mapTravel) 未开启"
        end
        if type(edb.worldMapFade) ~= "table" or edb.worldMapFade.dim ~= true then
            configWarnings[#configWarnings + 1] = "EUI 大地图去黑幕点击穿透 (worldMapFade.dim) 未开启"
        end
    end
    local pdb = _G.PolestarDB
    local pSet = type(pdb) == "table" and pdb.settings
    if F.IsAddOnLoaded("Polestar") and type(pSet) == "table" then
        local hasScales = F.IsAddOnLoaded("Scales")
        if hasScales then
            if type(pSet.gear) == "table" and pSet.gear.enabled == true then
                configWarnings[#configWarnings + 1] = "已启用 Scales，建议关闭 Polestar 装备评分 (gear.enabled) 防重复提示"
            end
        elseif type(pSet.gear) == "table" and pSet.gear.enabled == false then
            configWarnings[#configWarnings + 1] = "Polestar 装备评分与背包箭头 (gear.enabled) 未开启"
        end
    end

    return {
        patches = patches,
        missingPatches = missingPatches,
        loadedOverlaps = loadedOverlaps,
        configWarnings = configWarnings,
        tooltipEngine = F.IsAddOnLoaded("kkowoUI_Tooltip") and "kkowoUI_Tooltip (MIT 内嵌)"
            or (F.IsAddOnLoaded("PrettyTooltip") and "PrettyTooltip (独立版)" or "未启用（回退皮肤）"),
    }
end

function mod:PrintHealthReport()
    local r = CollectHealthReport()
    F.Print("整合包综合体检 (/kk doctor) — kkowoUI v" .. tostring(F.VERSION) .. "：")
    _G.print("  • 悬浮提示引擎：|cff5fd3a6" .. r.tooltipEngine .. "|r")

    if #r.patches == 0 then
        _G.print("  • 补丁守卫：无待巡检目标插件。")
    elseif #r.missingPatches == 0 then
        _G.print("  • 补丁守卫：|cff5fd3a6全部 " .. tostring(#r.patches) .. "/" .. tostring(#r.patches) .. " 个极简补丁完整生效|r")
    else
        local names = {}
        for _, m in ipairs(r.missingPatches) do names[#names + 1] = m.name end
        _G.print("  • 补丁守卫：|cffffb84d发现 " .. tostring(#r.missingPatches) .. " 个补丁失效|r → " .. table_concat(names, "、"))
        _G.print("    提示：退出游戏后双击 |cffdca77fTools\\DD更新后重打补丁.bat|r 即可一键恢复。")
    end

    if #r.loadedOverlaps == 0 then
        _G.print("  • 重叠残留检查：|cff5fd3a60 个已退场/冲突插件残留，非常干净|r")
    else
        _G.print("  • 重叠残留检查：|cffff6b6b检测到残留插件|r → " .. table_concat(r.loadedOverlaps, "、"))
    end

    if #r.configWarnings == 0 then
        _G.print("  • EUI / Polestar / Scales 协同开关：|cff5fd3a6全部对齐推荐配置|r")
    else
        _G.print("  • EUI / Polestar / Scales 协同开关：|cffffb84d有 " .. tostring(#r.configWarnings) .. " 项未对齐|r → " .. table_concat(r.configWarnings, "；"))
    end

    local bugs = GetBugCount()
    if bugs ~= nil then
        local color = bugs == 0 and "|cff5fd3a6" or "|cffff6b6b"
        _G.print("  • BugSack 本次报错：" .. color .. tostring(bugs) .. " 条|r")
    end
end

local function AlignRecommendedSettings()
    if InCombatLockdown and InCombatLockdown() then
        F.Print("|cffe0a24b战斗中暂不调整配置，脱战后再点即可。|r")
        return
    end
    local changed = 0
    local edb = _G.EllesmereUIDB
    if type(edb) == "table" then
        if edb.shifterEnabled ~= true then edb.shifterEnabled = true; changed = changed + 1 end
        if edb.shifterNoShift ~= true then edb.shifterNoShift = true; changed = changed + 1 end

        if type(edb.worldMapReveal) ~= "table" then edb.worldMapReveal = {} end
        if edb.worldMapReveal.enabled ~= true then edb.worldMapReveal.enabled = true; changed = changed + 1 end

        if type(edb.mapTravel) ~= "table" then edb.mapTravel = {} end
        if edb.mapTravel.enabled ~= true then edb.mapTravel.enabled = true; changed = changed + 1 end
        if edb.mapTravel.transports ~= true then edb.mapTravel.transports = true; changed = changed + 1 end
        if edb.mapTravel.exits ~= true then edb.mapTravel.exits = true; changed = changed + 1 end
        if edb.mapTravel.flights ~= true then edb.mapTravel.flights = true; changed = changed + 1 end
        if edb.mapTravel.instances ~= false then edb.mapTravel.instances = false; changed = changed + 1 end

        if type(edb.worldMapFade) ~= "table" then edb.worldMapFade = {} end
        if edb.worldMapFade.dim ~= true then edb.worldMapFade.dim = true; changed = changed + 1 end
        if edb.worldMapFade.dimOpacity ~= 0 then edb.worldMapFade.dimOpacity = 0; changed = changed + 1 end
        if edb.worldMapFade.dimClickThrough ~= true then edb.worldMapFade.dimClickThrough = true; changed = changed + 1 end

        if type(edb.zoneLevels) ~= "table" then edb.zoneLevels = {} end
        if edb.zoneLevels.enabled ~= false then edb.zoneLevels.enabled = false; changed = changed + 1 end
        if edb.zoneLevels.fishing ~= true then edb.zoneLevels.fishing = true; changed = changed + 1 end

        if type(edb.inGameNavigation) ~= "table" then edb.inGameNavigation = {} end
        if edb.inGameNavigation.enabled ~= true then
            edb.inGameNavigation.enabled = true
            changed = changed + 1
            local EUI = _G.EllesmereUI
            if EUI and EUI._InGameNavigation and type(EUI._InGameNavigation.Apply) == "function" then
                pcall(EUI._InGameNavigation.Apply)
            end
        end
    end

    local pdb = _G.PolestarDB
    if F.IsAddOnLoaded("Polestar") and type(pdb) == "table" then
        if type(pdb.settings) ~= "table" then pdb.settings = {} end
        if type(pdb.settings.gear) ~= "table" then pdb.settings.gear = {} end
        local wantPolestarGear = not F.IsAddOnLoaded("Scales")
        if pdb.settings.gear.enabled ~= wantPolestarGear then
            pdb.settings.gear.enabled = wantPolestarGear
            changed = changed + 1
        end
        if type(pdb.settings.nav) ~= "table" then pdb.settings.nav = {} end
        if pdb.settings.nav.mapPlan ~= true then pdb.settings.nav.mapPlan = true; changed = changed + 1 end
    end

    if changed > 0 then
        F.Print("已一键对齐 " .. tostring(changed) .. " 项 EUI / Polestar 推荐协同开关（部分地图选项重载界面 /rl 后全部生效）。")
    else
        F.Print("全部 EUI / Polestar 协同开关均已处于推荐状态，无需修改。")
    end
end

local function GetSettingsPanel() return _G.SettingsPanel end
local function GetPolestarOptions()
    local ps = _G.Polestar
    return (ps and ps.UI and ps.UI.Options and ps.UI.Options.frame) or _G.PolestarOptions
end
local function GetPrettyEditor() return _G.PrettyTooltipEditor end
local function GetDFMain() return _G.DungeonsForever_MainFrame end
local function GetBugSackFrame() return _G.BugSackFrame end
local function GetKeybindFrame() return _G.kkowoUI_KeybindBoard end

function mod:BuildLauncherPage(W, parent, y, blank)
    local _, h
    _, h = W:SectionHeader(parent, "核心界面与 kkowoUI 快捷入口（点按直达 · 按 ESC 关闭后自动返回本界面）", y)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "悬浮提示编辑器 (kkowoUI_Tooltip)",
        buttonText = "打开 /ptip",
        width = 136,
        tooltip = "打开内置 PrettyTooltip 样式编辑器，微调物品/技能/单位悬浮卡片细节。聊天命令：/ptip",
        onClick = function()
            local loaded = F.IsAddOnLoaded("kkowoUI_Tooltip") or F.IsAddOnLoaded("PrettyTooltip")
            if not loaded then
                F.Print("未启用 kkowoUI_Tooltip 悬浮提示引擎。")
                return
            end
            OpenOrWarn(nil, "/ptip", "", "悬浮提示编辑器", nil, false, GetPrettyEditor)
        end,
    }, {
        type = "labeledButton",
        text = "可视化全键位总览面板",
        buttonText = "打开 /kkkeys",
        width = 136,
        tooltip = "打开 kkowoUI 实体键盘快捷键可视化拖拽绑键面板（按需加载）。聊天命令：/kkkeys",
        onClick = function()
            F.LaunchFromEUI(function()
                local kb = F.EnsureKeybindBoardLoaded and F.EnsureKeybindBoardLoaded() or F.Modules.Get("keybindBoard")
                if kb and kb.ToggleBoard then kb:ToggleBoard() end
            end, GetKeybindFrame)
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "自由拖拽布局（解锁模式）",
        buttonText = "切换 /kk unlock",
        width = 136,
        tooltip = "一键开启/关闭 EllesmereUI 与 kkowoUI 统一布局解锁模式。聊天命令：/kk unlock",
        onClick = function()
            local EUI = _G.EllesmereUI
            if EUI and type(EUI.ToggleUnlockMode) == "function" then
                pcall(EUI.ToggleUnlockMode, EUI)
            end
        end,
    }, {
        type = "labeledButton",
        text = "输出整合包综合体检报告",
        buttonText = "运行 /kk doctor",
        width = 136,
        tooltip = "在聊天框核验 3 个补丁、退场插件残留、EUI/Polestar/Scales 协同开关与本次会话报错数。",
        onClick = function() mod:PrintHealthReport() end,
    })
    y = y - h

    _, h = W:Spacer(parent, y, 8)
    y = y - h
    _, h = W:SectionHeader(parent, "上游核心数据与战斗引擎（点按直达 · 按 ESC 关闭后自动返回本界面）", y)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "Scales 装备评分与对比",
        buttonText = "打开 /scales",
        width = 136,
        tooltip = "打开 Scales 装备属性模拟与权重界面（提示卡绿/红/金箭直观看提升）。聊天命令：/scales",
        onClick = function() OpenOrWarn("Scales", "/scales", "", "Scales 装备评分") end,
    }, {
        type = "labeledButton",
        text = "Polestar 极星练级导航",
        buttonText = "打开 /polestar",
        width = 136,
        tooltip = "打开 Polestar 配置界面（升级路线、跨图最短路径与 NPC 服务图钉）。聊天命令：/polestar options",
        onClick = function()
            OpenOrWarn("Polestar", "/polestar", "options", "Polestar", function()
                local ps = _G.Polestar
                if ps and ps.UI and type(ps.UI.ShowOptions) == "function" then
                    ps.UI.ShowOptions()
                    return true
                end
                return false
            end, false, GetPolestarOptions)
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "Questie 任务百科与地图追踪",
        buttonText = "打开 /questie",
        width = 136,
        tooltip = "打开 Questie 任务配置面板。聊天命令：/questie",
        onClick = function() OpenOrWarn("Questie", "/questie", "", "Questie") end,
    }, {
        type = "labeledButton",
        text = "《无限副本手册》DungeonsForever",
        buttonText = "打开 /df",
        width = 136,
        tooltip = "打开《无限副本手册》（副本掉落、Boss 攻略、37 张副本地图与任务查询）。聊天命令：/df",
        onClick = function() OpenOrWarn("DungeonsForever", "/df", "", "无限副本手册", nil, false, GetDFMain) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "BigWigs / LittleWigs 首领警报",
        buttonText = "打开 /bw",
        width = 136,
        tooltip = "打开 BigWigs 团队与五人本首领技能计时条设置（已接管 ESC 关闭并返回）。聊天命令：/bw",
        onClick = function()
            OpenOrWarn("BigWigs", "/bw", "", "BigWigs", function()
                local ok = F.RunSlashCommand("/bw", "")
                if ok and F._BindVisibleBigWigsFrame then
                    C_Timer.After(0.05, F._BindVisibleBigWigsFrame)
                end
                return ok
            end)
        end,
    }, {
        type = "labeledButton",
        text = "Auctionator 拍卖行助手",
        buttonText = "打开设置",
        width = 136,
        tooltip = "在暴雪插件设置页直接打开 Auctionator 图形化配置（按 ESC 返回总控台）。",
        onClick = function()
            OpenOrWarn("Auctionator", "/atr", "", "Auctionator 拍卖行助手", function()
                local atr = _G.Auctionator
                local cat = atr and atr.State and atr.State.OptionsCategory
                if cat and type(cat.GetID) == "function" and _G.Settings and _G.Settings.OpenToCategory then
                    _G.Settings.OpenToCategory(cat:GetID())
                    return true
                end
                return false
            end, false, GetSettingsPanel)
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "SpellActivationOverlay 技能触发提醒",
        buttonText = "打开 /sao",
        width = 136,
        tooltip = "打开屏幕中央职业触发光效配置界面（按 ESC 返回总控台）。聊天命令：/sao",
        onClick = function()
            OpenOrWarn("SpellActivationOverlay", "/sao", "", "SpellActivationOverlay", nil, false, GetSettingsPanel)
        end,
    }, {
        type = "labeledButton",
        text = "GTFO 站位伤害警报",
        buttonText = "打开 /gtfo options",
        width = 136,
        tooltip = "打开 GTFO 地面伤害音效警报配置（按 ESC 返回总控台）。聊天命令：/gtfo options",
        onClick = function()
            OpenOrWarn("GTFO", "/gtfo", "options", "GTFO", function()
                if type(_G.GTFO_Command_Options) == "function" then
                    _G.GTFO_Command_Options()
                    return true
                end
                return false
            end, false, GetSettingsPanel)
        end,
    })
    y = y - h

    local bugs = GetBugCount()
    local bugBtnText = (bugs and bugs > 0) and ("查看 (" .. tostring(bugs) .. "报错)") or "打开 /bugsack"
    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "BugSack 报错口袋（本次会话）",
        buttonText = bugBtnText,
        width = 136,
        tooltip = "查看或清空本次会话捕获的 Lua 报错记录（按 ESC 关闭并返回）。聊天命令：/bugsack",
        onClick = function()
            OpenOrWarn("BugSack", "/bugsack", "", "BugSack", function()
                local bs = _G.BugSack
                if type(bs) == "table" and type(bs.OpenSack) == "function" then
                    bs:OpenSack()
                    return true
                end
                return false
            end, false, GetBugSackFrame)
        end,
    }, blank)
    y = y - h

    _, h = W:Spacer(parent, y, 8)
    y = y - h
    _, h = W:SectionHeader(parent, "常用日志与诊断", y)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "查看本次登录静默收纳的刷屏提示",
        buttonText = "查看 /kk loginlog",
        width = 136,
        tooltip = "在聊天框列出本次登录自动隐藏的第三方插件横幅提示。",
        onClick = function()
            if F.DumpSuppressedLoginMsgs then F.DumpSuppressedLoginMsgs() end
        end,
    }, {
        type = "labeledButton",
        text = "3D 光柱与大地图导航诊断",
        buttonText = "诊断 /kk nav",
        width = 136,
        tooltip = "在聊天框打印 EUI InGameNavigation、SuperTrack 与 Polestar 联动状态。",
        onClick = function()
            local wa = F.Modules.Get("waypointAutoTrack")
            if wa and wa.DumpDiagnostics then wa:DumpDiagnostics() end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "在聊天框输出全部模块运行状态",
        buttonText = "运行 /kk status",
        width = 136,
        tooltip = "打印 kkowoUI 版本与所有功能模块的启用/让位状态。",
        onClick = function() F.RunSlashCommand("/kk", "status") end,
    }, blank)
    y = y - h
    return y
end

function mod:BuildHealthPage(W, parent, y)
    local db = self:GetDB()
    local r = CollectHealthReport()
    local _, h

    local patchSummary = (#r.missingPatches == 0)
        and ("3 个极简补丁完整（" .. tostring(#r.patches) .. "/" .. tostring(#r.patches) .. "）")
        or ("发现 " .. tostring(#r.missingPatches) .. " 个补丁缺失")
    local overlapSummary = (#r.loadedOverlaps == 0)
        and "0 个重叠残留"
        or (tostring(#r.loadedOverlaps) .. " 个重叠残留")

    _, h = W:SectionHeader(parent, "整合包体检：" .. patchSummary .. " · " .. overlapSummary, y)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "登录自动巡检 3 个极简补丁（PatchGuard）",
        tooltip = "登录 4.5 秒后静默核验 EUI 聊天瞬切、Polestar 寻路与中文补齐补丁；全部生效时不刷屏，仅在被更新覆盖时发一条金色提醒。",
        getValue = function() return db.patchGuardAlert ~= false end,
        setValue = function(v) db.patchGuardAlert = v == true end,
    }, {
        type = "toggle",
        text = "登录自动停用无效/已替换插件（DeadGuard）",
        tooltip = "若网易 DD 更新时把已退场或正式服死目录放回 AddOns，下次登录自动停用并提示重载，防止冲突。",
        getValue = function() return not F.db or F.db.autoDisableDeadAddons ~= false end,
        setValue = function(v)
            if F.db then F.db.autoDisableDeadAddons = v == true end
            if v and F.DisableDeadAddons then F.DisableDeadAddons(true) end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "输出完整整合包体检报告到聊天框",
        buttonText = "立即体检",
        width = 136,
        tooltip = "检查悬浮提示引擎、3 个补丁、退场插件残留、EUI/Polestar/Scales 开关对齐与 BugSack 报错数（等价 /kk doctor）。",
        onClick = function() mod:PrintHealthReport() end,
    }, {
        type = "labeledButton",
        text = "一键对齐 EUI + Polestar 推荐交接开关",
        buttonText = "一键对齐",
        width = 136,
        tooltip = "自动启用 EUI Shifter/MapReveal/MapTravel/MapFade/InGameNavigation，并按是否启用 Scales 对齐 Polestar 装备评分。",
        onClick = function()
            AlignRecommendedSettings()
            local EUI = _G.EllesmereUI
            if EUI and EUI.RefreshPage then pcall(EUI.RefreshPage, EUI) end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "立即扫描并停用残留无效/替换插件",
        buttonText = "执行守卫",
        width = 136,
        tooltip = "手动运行一次 DeadGuard，立即停用被 DD 放回的独立 PrettyTooltip 或正式服无用子目录。",
        onClick = function()
            if F.DisableDeadAddons then F.DisableDeadAddons(true) end
        end,
    }, {
        type = "labeledButton",
        text = "一键瘦身向导（停用旧重叠插件）",
        buttonText = "打开 /kk slim",
        width = 136,
        tooltip = "弹出确认框一键停用所有已整合/退场的旧插件（随时可用 /kk restore 还原）。",
        onClick = function() F.RunSlashCommand("/kk", "slim") end,
    })
    y = y - h
    return y
end
