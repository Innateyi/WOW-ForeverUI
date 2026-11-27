----------------------------------------------------------------------
--  kkowoUI_Options — ControlHubUI.lua (LoadOnDemand: 1)
--  /kk 顶层「总控」三页 UI：快捷入口 / 体检与守卫 / 瘦身与高级
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

local function OpenOrWarn(addonName, slash, arg, displayName, customFn, keepEUIOpen, expectedFrameFn, launchOpts)
    if InCombatLockdown and InCombatLockdown() then
        F.Print("|cffe0a24b战斗中无法打开「" .. displayName .. "」，脱战后再试。|r")
        return
    end
    if addonName and not F.IsAddOnLoaded(addonName) then
        F.Print("未启用 " .. displayName .. "，请在插件列表勾选 " .. addonName .. "。")
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
        F.LaunchFromEUI(dispatch, expectedFrameFn, launchOpts)
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

local function IsKkowoBeamActive()
    local wa = F.Modules and F.Modules.Get and F.Modules.Get("waypointAutoTrack")
    return wa ~= nil and type(wa.IsUsingKkowoBeam) == "function" and wa:IsUsingKkowoBeam() == true
end

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
            configWarnings[#configWarnings + 1] = "EUI 窗口拖动未开启"
        end
        if not IsKkowoBeamActive() and (type(edb.inGameNavigation) ~= "table" or edb.inGameNavigation.enabled ~= true) then
            configWarnings[#configWarnings + 1] = "EUI 地图光柱导航未开启"
        end
        if type(edb.worldMapReveal) ~= "table" or edb.worldMapReveal.enabled ~= true then
            configWarnings[#configWarnings + 1] = "EUI 大地图全亮未开启"
        end
        if type(edb.mapTravel) ~= "table" or edb.mapTravel.enabled ~= true then
            configWarnings[#configWarnings + 1] = "EUI 大地图航线飞点未开启"
        end
        if type(edb.worldMapFade) ~= "table" or edb.worldMapFade.dim ~= true then
            configWarnings[#configWarnings + 1] = "EUI 大地图去黑幕未开启"
        end
        if edb.merchantBulkBuy ~= true then
            configWarnings[#configWarnings + 1] = "EUI 商人批量购买未开启"
        end
    end
    local pdb = _G.PolestarDB
    local pSet = type(pdb) == "table" and pdb.settings
    if F.IsAddOnLoaded("Polestar") and type(pSet) == "table" then
        local hasScales = F.IsAddOnLoaded("Scales")
        if hasScales then
            if type(pSet.gear) == "table" and pSet.gear.enabled == true then
                configWarnings[#configWarnings + 1] = "已启用装备评分，建议关闭北极星自带评分防重复"
            end
        elseif type(pSet.gear) == "table" and pSet.gear.enabled == false then
            configWarnings[#configWarnings + 1] = "北极星装备评分未开启"
        end
    end

    return {
        patches = patches,
        missingPatches = missingPatches,
        loadedOverlaps = loadedOverlaps,
        configWarnings = configWarnings,
        tooltipEngine = F.IsAddOnLoaded("kkowoUI_Tooltip") and "kkowoUI_Tooltip（内嵌版）"
            or (F.IsAddOnLoaded("PrettyTooltip") and "PrettyTooltip（独立版）" or "未启用（回退样式）"),
    }
end

function mod:PrintHealthReport()
    local r = CollectHealthReport()
    F.Print("综合体检 (/kk doctor) v" .. tostring(F.VERSION) .. "：")
    _G.print("  • 提示框引擎：|cff5fd3a6" .. r.tooltipEngine .. "|r")

    if #r.patches == 0 then
        _G.print("  • 启动巡检：无待核验项。")
    elseif #r.missingPatches == 0 then
        _G.print("  • 启动巡检：|cff5fd3a6全部 " .. tostring(#r.patches) .. "/" .. tostring(#r.patches) .. " 项正常运行|r")
    else
        local names = {}
        for _, m in ipairs(r.missingPatches) do names[#names + 1] = m.name end
        _G.print("  • 启动巡检：|cffffb84d发现 " .. tostring(#r.missingPatches) .. " 项失效|r → " .. table_concat(names, "、"))
        _G.print("    提示：退出游戏后运行 |cffdca77fTools\\DD更新后重打补丁.bat|r 恢复。")
    end

    if #r.loadedOverlaps == 0 then
        _G.print("  • 残留旧插件：|cff5fd3a60 个|r")
    else
        _G.print("  • 残留旧插件：|cffff6b6b" .. table_concat(r.loadedOverlaps, "、") .. "|r")
    end

    if #r.configWarnings == 0 then
        _G.print("  • 推荐联动开关：|cff5fd3a6全部已对齐|r")
    else
        _G.print("  • 推荐联动开关：|cffffb84d" .. tostring(#r.configWarnings) .. " 项未对齐|r → " .. table_concat(r.configWarnings, "；"))
    end

    local bugs = GetBugCount()
    if bugs ~= nil then
        local color = bugs == 0 and "|cff5fd3a6" or "|cffff6b6b"
        _G.print("  • 报错口袋本次会话：" .. color .. tostring(bugs) .. " 条|r")
    end
end

local function AlignRecommendedSettings()
    if InCombatLockdown and InCombatLockdown() then
        F.Print("|cffe0a24b战斗中无法调整配置，脱战后再试。|r")
        return
    end
    local changed = 0
    local edb = _G.EllesmereUIDB
    if type(edb) == "table" then
        if edb.shifterEnabled ~= true then edb.shifterEnabled = true; changed = changed + 1 end
        if edb.shifterNoShift ~= true then edb.shifterNoShift = true; changed = changed + 1 end
        if edb.merchantBulkBuy ~= true then
            edb.merchantBulkBuy = true
            changed = changed + 1
            local EUI = _G.EllesmereUI
            if EUI and type(EUI._Merchant_RefreshBulkBuy) == "function" then
                pcall(EUI._Merchant_RefreshBulkBuy)
            end
        end

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

        if not IsKkowoBeamActive() then
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
        F.Print("已对齐 " .. tostring(changed) .. " 项推荐联动开关，部分地图项重载后生效。")
    else
        F.Print("全部推荐联动开关均已对齐，无需修改。")
    end
end

local function PrintSafeSettingsGuide(addonName, displayName, categoryName, slashHint)
    if addonName and not F.IsAddOnLoaded(addonName) then
        F.Print("未启用 " .. displayName .. "，请在插件列表勾选 " .. addonName .. "。")
        return
    end
    F.Print("|cff5fd3a6" .. displayName .. "|r 位于暴雪受保护插件设置页，请按 |cffffd24dESC → 选项 → 插件 → "
        .. categoryName .. "|r，或在聊天框输入 |cff5fd3a6" .. slashHint .. "|r 打开（零界面污染）。")
end

local function GetPolestarOptions()
    local ps = _G.Polestar
    return (ps and ps.UI and ps.UI.Options and ps.UI.Options.frame) or _G.PolestarOptions
end
local function GetPrettyEditor() return _G.PrettyTooltipEditor end
local function GetDFMain() return _G.DungeonsForever_MainFrame end
local function GetBugSackFrame() return _G.BugSackFrame end
local function GetKeybindFrame() return _G.kkowoUI_KeybindBoard end

-- ---------------------------------------------------------------------------
-- 页 1：快捷入口
-- ---------------------------------------------------------------------------
function mod:BuildLauncherPage(W, parent, y, blank)
    local _, h
    _, h = W:SectionHeader(parent, "常用工具", y)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "提示框编辑器",
        buttonText = "打开",
        width = 110,
        tooltip = "打开内置提示框样式编辑器，微调物品与单位卡片（/ptip）。",
        onClick = function()
            local loaded = F.IsAddOnLoaded("kkowoUI_Tooltip") or F.IsAddOnLoaded("PrettyTooltip")
            if not loaded then
                F.Print("未启用提示框模块，请在插件列表启用 kkowoUI_Tooltip。")
                return
            end
            OpenOrWarn(nil, "/ptip", "", "提示框编辑器", nil, false, GetPrettyEditor)
        end,
    }, {
        type = "labeledButton",
        text = "可视化键位图",
        buttonText = "打开",
        width = 110,
        tooltip = "打开实体键盘拖拽绑键面板，支持按需加载（/kkkeys）。",
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
        text = "界面自由拖动",
        buttonText = "切换",
        width = 110,
        tooltip = "开启或关闭 EUI 与 kkowoUI 布局解锁（/kk unlock）。",
        onClick = function()
            local EUI = _G.EllesmereUI
            if EUI and type(EUI.ToggleUnlockMode) == "function" then
                pcall(EUI.ToggleUnlockMode, EUI)
            end
        end,
    }, {
        type = "labeledButton",
        text = "综合体检报告",
        buttonText = "运行",
        width = 110,
        tooltip = "在聊天框核验加速模块、残留插件、联动开关与本次报错数。",
        onClick = function() mod:PrintHealthReport() end,
    })
    y = y - h

    _, h = W:Spacer(parent, y, 8)
    y = y - h
    _, h = W:SectionHeader(parent, "配套插件（按 ESC 返回）", y)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "装备评分",
        buttonText = "打开",
        width = 110,
        tooltip = "打开装备属性模拟与提升权重界面（/scales）。",
        onClick = function() OpenOrWarn("Scales", "/scales", "", "装备评分") end,
    }, {
        type = "labeledButton",
        text = "北极星指南",
        buttonText = "打开",
        width = 110,
        tooltip = "打开练级路线、跨图寻路与城镇服务图钉设置（/polestar）。",
        onClick = function()
            OpenOrWarn("Polestar", "/polestar", "options", "北极星指南", function()
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
        text = "任务助手",
        buttonText = "打开",
        width = 110,
        tooltip = "打开任务助手地图追踪与数据库配置（/questie）。",
        onClick = function() OpenOrWarn("Questie", "/questie", "", "任务助手") end,
    }, {
        type = "labeledButton",
        text = "无限副本手册",
        buttonText = "打开",
        width = 110,
        tooltip = "打开副本掉落、首领攻略、副本地图与任务查询（/df）。",
        onClick = function() OpenOrWarn("DungeonsForever", "/df", "", "无限副本手册", nil, false, GetDFMain) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "首领警报",
        buttonText = "打开",
        width = 110,
        tooltip = "打开团队与五人本首领技能计时条设置，按 ESC 返回（/bw）。",
        onClick = function()
            OpenOrWarn("BigWigs", "/bw", "", "首领警报", function()
                local ok = F.RunSlashCommand("/bw", "")
                if ok and F._BindVisibleBigWigsFrame then
                    C_Timer.After(0.05, F._BindVisibleBigWigsFrame)
                end
                return ok
            end, false, nil, {
                onEscape = function(fr)
                    if fr.obj and type(fr.obj.Hide) == "function" then
                        pcall(fr.obj.Hide, fr.obj)
                    elseif fr.Hide then
                        pcall(fr.Hide, fr)
                    end
                end,
            })
        end,
    }, {
        type = "labeledButton",
        text = "拍卖助手",
        buttonText = "路径指引",
        width = 110,
        tooltip = "受暴雪 12.1 保护，点击在聊天框输出打开路径与命令（/atr）。",
        onClick = function()
            PrintSafeSettingsGuide("Auctionator", "拍卖助手", "Auctionator", "/atr")
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "技能触发光效",
        buttonText = "路径指引",
        width = 110,
        tooltip = "受暴雪 12.1 保护，点击在聊天框输出打开路径与命令（/sao）。",
        onClick = function()
            PrintSafeSettingsGuide("SpellActivationOverlay", "技能触发光效", "SpellActivationOverlay", "/sao")
        end,
    }, {
        type = "labeledButton",
        text = "站位警报",
        buttonText = "路径指引",
        width = 110,
        tooltip = "受暴雪 12.1 保护，点击在聊天框输出打开路径与命令（/gtfo）。",
        onClick = function()
            PrintSafeSettingsGuide("GTFO", "站位警报", "GTFO", "/gtfo options")
        end,
    })
    y = y - h

    local bugs = GetBugCount()
    local bugBtnText = (bugs and bugs > 0) and ("查看(" .. tostring(bugs) .. ")") or "打开"
    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "报错口袋",
        buttonText = bugBtnText,
        width = 110,
        tooltip = "查看或清空本次会话捕获的报错记录，按 ESC 返回（/bugsack）。",
        onClick = function()
            OpenOrWarn("BugSack", "/bugsack", "", "报错口袋", function()
                local bs = _G.BugSack
                if type(bs) == "table" and type(bs.OpenSack) == "function" then
                    bs:OpenSack()
                    return true
                end
                return false
            end, false, GetBugSackFrame, {
                onEscape = function()
                    local bs = _G.BugSack
                    if type(bs) == "table" and type(bs.CloseSack) == "function" then
                        pcall(bs.CloseSack, bs)
                    elseif _G.BugSackFrame and _G.BugSackFrame.Hide then
                        pcall(_G.BugSackFrame.Hide, _G.BugSackFrame)
                    end
                end,
            })
        end,
    }, blank)
    y = y - h
    return y
end

-- ---------------------------------------------------------------------------
-- 页 2：体检与守卫
-- ---------------------------------------------------------------------------
function mod:BuildHealthPage(W, parent, y, blank)
    local db = self:GetDB()
    local r = CollectHealthReport()
    local _, h

    local patchSummary = (#r.missingPatches == 0)
        and ("加速项正常（" .. tostring(#r.patches) .. "/" .. tostring(#r.patches) .. "）")
        or ("发现 " .. tostring(#r.missingPatches) .. " 项失效")
    local overlapSummary = (#r.loadedOverlaps == 0)
        and "0 个残留旧插件"
        or (tostring(#r.loadedOverlaps) .. " 个残留旧插件")

    _, h = W:SectionHeader(parent, "运行状态：" .. patchSummary .. " · " .. overlapSummary, y)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "启动功能巡检",
        tooltip = "登录后静默检查聊天与导航加速状态，失效时发一条提醒。",
        getValue = function() return db.patchGuardAlert ~= false end,
        setValue = function(v) db.patchGuardAlert = v == true end,
    }, {
        type = "toggle",
        text = "停用无效插件",
        tooltip = "检测到已替换或失效的旧插件被重新放回时自动停用并提醒。",
        getValue = function() return not F.db or F.db.autoDisableDeadAddons ~= false end,
        setValue = function(v)
            if F.db then F.db.autoDisableDeadAddons = v == true end
            if v and F.DisableDeadAddons then F.DisableDeadAddons(true) end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "综合体检报告",
        buttonText = "立即体检",
        width = 110,
        tooltip = "核验提示框、巡检状态、残留插件、联动开关与本次报错数。",
        onClick = function() mod:PrintHealthReport() end,
    }, {
        type = "labeledButton",
        text = "一键对齐推荐开关",
        buttonText = "立即对齐",
        width = 110,
        tooltip = "自动对齐 EUI 窗口拖动、地图光柱与北极星装备评分开关。",
        onClick = function()
            AlignRecommendedSettings()
            local EUI = _G.EllesmereUI
            if EUI and EUI.RefreshPage then pcall(EUI.RefreshPage, EUI) end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "扫描残留插件",
        buttonText = "立即扫描",
        width = 110,
        tooltip = "立即扫描并停用被更新放回的重叠或无效旧插件目录。",
        onClick = function()
            if F.DisableDeadAddons then F.DisableDeadAddons(true) end
        end,
    }, blank)
    y = y - h
    return y
end

-- ---------------------------------------------------------------------------
-- 页 3：瘦身与高级
-- ---------------------------------------------------------------------------
function mod:BuildSlimAndAdvancedPage(W, parent, y, blank)
    local _, h
    _, h = W:SectionHeader(parent, "一键瘦身", y)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "一键瘦身向导",
        buttonText = "开始瘦身",
        width = 110,
        tooltip = "停用已整合的旧重叠插件并重载，随时可用 /kk restore 还原。",
        onClick = function() F.RunSlashCommand("/kk", "slim") end,
    }, {
        type = "labeledButton",
        text = "还原已停用插件",
        buttonText = "一键还原",
        width = 110,
        tooltip = "恢复一键瘦身停用的旧插件并重载界面（/kk restore）。",
        onClick = function() F.RunSlashCommand("/kk", "restore") end,
    })
    y = y - h

    if type(F.BuildCollapsibleSection) == "function" then
        y = F.BuildCollapsibleSection("hub:slimlist", "瘦身插件明细", W, parent, y, function(w, p, curY, blk)
            local groups = F._OptionsUI and F._OptionsUI.SLIM_GROUPS or {}
            local _, rh
            for _, grp in ipairs(groups) do
                _, rh = w:DualRow(p, curY, {
                    type = "label",
                    text = "|cffdca77f" .. grp.title .. "|r：" .. grp.items,
                }, blk)
                curY = curY - rh
            end
            return curY
        end, blank)
    end

    _, h = W:Spacer(parent, y, 8)
    y = y - h
    _, h = W:SectionHeader(parent, "日志与诊断", y)
    y = y - h

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("hub:diag", W, parent, y, function(w, p, curY, blk)
            local _, rh
            _, rh = w:DualRow(p, curY, {
                type = "labeledButton",
                text = "查看登录静默日志",
                buttonText = "查看",
                width = 110,
                tooltip = "在聊天框列出本次登录自动隐藏的第三方插件提示。",
                onClick = function()
                    if F.DumpSuppressedLoginMsgs then F.DumpSuppressedLoginMsgs() end
                end,
            }, {
                type = "labeledButton",
                text = "光柱导航诊断",
                buttonText = "诊断",
                width = 110,
                tooltip = "在聊天框输出大地图光柱与北极星指南的联动状态。",
                onClick = function()
                    local wa = F.Modules.Get("waypointAutoTrack")
                    if wa and wa.DumpDiagnostics then wa:DumpDiagnostics() end
                end,
            })
            curY = curY - rh

            _, rh = w:DualRow(p, curY, {
                type = "labeledButton",
                text = "全部模块状态",
                buttonText = "查看",
                width = 110,
                tooltip = "在聊天框打印版本与所有功能模块的启用或让位状态。",
                onClick = function() F.RunSlashCommand("/kk", "status") end,
            }, {
                type = "labeledButton",
                text = "运行回归自检",
                buttonText = "自检",
                width = 110,
                tooltip = "脱战状态下运行内置自检并将结果写入存档（/kk selftest）。",
                onClick = function() F.RunSlashCommand("/kk", "selftest") end,
            })
            curY = curY - rh
            return curY
        end, blank)
    end

    return y
end
