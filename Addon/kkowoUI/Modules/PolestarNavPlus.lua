----------------------------------------------------------------------
--  kkowoUI — Modules/PolestarNavPlus.lua
--  Polestar 导航与任务怪零侵入增强 + 原生副本到达提醒配置联动：
--    1) 自动切换 Polestar 为「道路优先」寻路模式（山路/盘山路优先大路，停用无损还原）
--    2) 实时扫描周围视野/姓名板/目标：发现当前引导任务的存活任务怪时：
--       • 通过回调阻止 Polestar 的 Own.dwelt 把玩家从怪堆赶走
--       • 若 Polestar 箭头指向 65 码外的其它刷怪区，自动尝试切回更近的刷怪点并弹出轻提示胶囊
--    3) 统一在 /kk 面板控制 Polestar 原生「进入地下城所在地图」卡片提醒（适级过滤 / 团本 / 一键预览）
--    4) 提供「立即重算 Polestar 路线」快捷按钮，解决走上新道路后等待重算的问题
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_sqrt, pairs, pcall, setmetatable, tonumber, tostring, type =
    ipairs, math.floor, math.max, math.sqrt, pairs, pcall, setmetatable, tonumber, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime

local ST = F.StyleTokens

local mod = F.RegisterModule("polestarNav", {
    title = "Polestar 导航与任务怪优化",
    desc = "自动启用 Polestar 道路优先寻路、视野检测到当前任务怪时就近锁定防赶人并轻提示，并在 /kk 统一配置 Polestar 原生进入副本所在地图提醒。",
    group = "quest",
    order = 65,
    defaults = {
        enabled = true,
        preferRoads = true,
        savedRouteStyle = nil,
        nearbyQuestMob = true,
        nearbyMobBanner = true,
        autoSnapSpot = true,
        zoneDungeonAlert = true,
        zoneDungeonLevelOnly = true,
        zoneDungeonIncludeRaids = false,
    },
})

local COL_EMERALD = { 0.37, 0.83, 0.65 }
local SCAN_INTERVAL = 0.8
local MOB_HOLD_SEC = 5.0
local FAR_WAYPOINT_YD = 65
local SNAP_NEAR_YD = 55
local SNAP_COOLDOWN = 12

local questieTT = nil
local goalInfoCache = setmetatable({}, { __mode = "k" })
local lastSnapAt = setmetatable({}, { __mode = "k" })

local nearbyBanner = nil
local lastBannerKey = nil
local lastMobGoal = nil
local lastMobName = nil
local lastMobAt = 0

local scanTicker = nil
local bootSyncDone = false

local function GetPolestar()
    local P = _G.Polestar
    return type(P) == "table" and P or nil
end

local function SafeBool(v)
    return type(v) == "boolean" and not F.IsSecret(v) and v
end

local function GetQuestieTooltips()
    if questieTT == nil then
        questieTT = false
        local loader = _G.QuestieLoader
        if type(loader) == "table" and type(loader.ImportModule) == "function" then
            local ok, m = pcall(loader.ImportModule, loader, "QuestieTooltips")
            if ok and type(m) == "table" then
                questieTT = m
            end
        end
    end
    return questieTT or nil
end

----------------------------------------------------------------------
--  1) 道路优先寻路模式同步（无损记录与还原）
----------------------------------------------------------------------
local function SyncRouteStyle(wantOn)
    local P = GetPolestar()
    if not (P and type(P.Get) == "function" and type(P.Set) == "function") then return end
    local db = mod:GetDB()
    local want = (wantOn ~= nil) and wantOn or (mod._active and db.preferRoads ~= false)
    if want then
        local okG, cur = pcall(P.Get, "nav.routeStyle")
        cur = okG and F.PlainString(cur, nil) or nil
        if db.savedRouteStyle == nil then
            db.savedRouteStyle = cur or "balanced"
        end
        if cur ~= "roads" then
            pcall(P.Set, "nav.routeStyle", "roads")
        end
    else
        if type(db.savedRouteStyle) == "string" and db.savedRouteStyle ~= "" then
            pcall(P.Set, "nav.routeStyle", db.savedRouteStyle)
            db.savedRouteStyle = nil
        end
    end
end

local function ForceReplanNow()
    local P = GetPolestar()
    if not (P and type(P.Nav) == "table") then
        F.Print("未检测到 Polestar 插件。")
        return false
    end
    local walk = P.Nav.walk
    if type(walk) == "table" and type(walk.Clear) == "function" then
        pcall(walk.Clear)
    end
    if type(P.Nav.Refresh) == "function" then
        pcall(P.Nav.Refresh)
    end
    F.Print("已强制重算当前 Polestar 导航路线。")
    return true
end

----------------------------------------------------------------------
--  2) 任务怪目标解析与视野/姓名板实时检测（12.x 保密值安全）
----------------------------------------------------------------------
local function IsMobHuntGoal(goal)
    if type(goal) ~= "table" then return false end
    local t = goal.t
    return t == "kill" or t == "collect" or goal.grind == true
end

local function GetActiveGoal()
    local P = GetPolestar()
    local E = P and P.Engine
    if not (E and type(E.GetWaypoint) == "function" and type(E.GetGuide) == "function") then
        return nil, nil
    end
    local okW, wp = pcall(E.GetWaypoint)
    if not (okW and type(wp) == "table") then return nil, nil end
    local okG, guide = pcall(E.GetGuide)
    if not (okG and type(guide) == "table" and type(guide.steps) == "table") then
        return wp, nil
    end
    local step = wp.stepIndex and guide.steps[wp.stepIndex]
    local goal = step and type(step.goals) == "table" and wp.goalIndex and step.goals[wp.goalIndex]
    return wp, goal
end

local function ResolveGoalMobs(goal)
    local cached = goalInfoCache[goal]
    if cached ~= nil then return cached end

    local ids, names = {}, {}
    local label = nil
    local P = GetPolestar()
    local N = P and P.Names

    if type(goal.npc) == "number" and goal.npc > 0 then
        ids[goal.npc] = true
        if N and type(N.Npc) == "function" then
            local okN, locName = pcall(N.Npc, goal.npc)
            locName = okN and F.PlainString(locName, nil) or nil
            if locName and locName ~= "" then
                names[locName] = true
                label = label or locName
            end
        end
    end
    if type(goal.target) == "string" and goal.target ~= "" then
        names[goal.target] = true
        label = label or goal.target
    end

    -- 若 Codex 已在内存中，补充掉落该任务物品的怪物 ID（绝不在战斗中触发 Codex 加载）
    local X = P and P.Codex
    if type(goal.item) == "number" and X and X.IsLoaded and X.IsLoaded() and type(X.Item) == "function" then
        local okI, rec = pcall(X.Item, goal.item)
        if okI and type(rec) == "table" and type(rec.sources) == "table" then
            for _, src in ipairs(rec.sources) do
                if type(src) == "table" and (src.kind == "drop" or src.kind == "d") and type(src.id) == "number" then
                    ids[src.id] = true
                end
            end
        end
    end

    local info = {
        ids = ids,
        names = names,
        quest = type(goal.quest) == "number" and goal.quest or nil,
        label = label,
    }
    goalInfoCache[goal] = info
    return info
end

local function UnitMatchesGoal(unit, info)
    if not unit then return false, nil end
    local okE, exists = pcall(_G.UnitExists, unit)
    if not (okE and SafeBool(exists)) then return false, nil end
    local okP, isPlayer = pcall(_G.UnitIsPlayer, unit)
    if okP and SafeBool(isPlayer) then return false, nil end
    local okD, isDead = pcall(_G.UnitIsDeadOrGhost or _G.UnitIsDead, unit)
    if okD and SafeBool(isDead) then return false, nil end

    local okN, rawName = pcall(_G.UnitName, unit)
    local uname = okN and F.PlainString(rawName, nil) or nil

    local npcId = nil
    if _G.UnitGUID then
        local okG, rawGuid = pcall(_G.UnitGUID, unit)
        local guid = okG and F.PlainString(rawGuid, nil) or nil
        if guid then
            local idStr = guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
            if idStr then npcId = tonumber(idStr) end
        end
    end

    if npcId and info.ids[npcId] then
        return true, uname or info.label or ("NPC #" .. npcId)
    end
    if uname and uname ~= "" and info.names[uname] then
        return true, uname
    end

    -- 联动 QuestieTooltips：O(1) 反查该怪物是否属于当前任务的击杀/掉落目标（覆盖多怪共掉物品任务）
    if npcId and info.quest then
        local qtt = GetQuestieTooltips()
        local lookup = qtt and qtt.lookupByKey
        local entries = type(lookup) == "table" and lookup["m_" .. npcId]
        if type(entries) == "table" then
            for _, entry in pairs(entries) do
                if type(entry) == "table" and entry.questId == info.quest then
                    local obj = entry.objective
                    if type(obj) ~= "table" or obj.Completed ~= true then
                        return true, uname or info.label or ("NPC #" .. npcId)
                    end
                end
            end
        end
    end

    return false, nil
end

local function DetectNearbyQuestMob(goal)
    if not IsMobHuntGoal(goal) then return false, nil end
    local info = ResolveGoalMobs(goal)

    local hit, name = UnitMatchesGoal("target", info)
    if hit then return true, name end
    hit, name = UnitMatchesGoal("mouseover", info)
    if hit then return true, name end

    local NP = _G.C_NamePlate
    if NP and type(NP.GetNamePlates) == "function" then
        local okL, plates = pcall(NP.GetNamePlates)
        if okL and type(plates) == "table" then
            for i = 1, #plates do
                local plate = plates[i]
                if type(plate) == "table" then
                    local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
                    if u then
                        hit, name = UnitMatchesGoal(u, info)
                        if hit then return true, name end
                    end
                end
            end
        end
    end

    return false, nil
end

----------------------------------------------------------------------
--  3) 顶部轻提示胶囊（PrettyTooltip / ZoneLabels 同源黑曜石柔光风格）
----------------------------------------------------------------------
local function EnsureNearbyBanner()
    if nearbyBanner then return nearbyBanner end
    local f = CreateFrame("Frame", "kkowoUI_NearbyQuestMobBanner", _G.UIParent)
    f:SetSize(286, 50)
    f:SetPoint("TOP", _G.UIParent, "TOP", 0, -172)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(78)
    f:EnableMouse(false)

    local title = f:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(title, 13, 0.96, 0.97, 0.99, 1)
    title:SetPoint("TOP", f, "TOP", 0, -8)
    title:SetJustifyH("CENTER")
    title:SetWordWrap(false)

    local divider = f:CreateTexture(nil, "OVERLAY", nil, 2)
    ST.Hairline(divider)
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -27)
    divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -27)
    divider:SetColorTexture(1, 1, 1, 0.08)

    local sub = f:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(sub, 11, 0.72, 0.76, 0.83, 0.95)
    sub:SetPoint("BOTTOM", f, "BOTTOM", 0, 7)
    sub:SetJustifyH("CENTER")
    sub:SetWordWrap(false)

    f._title = title
    f._divider = divider
    f._sub = sub
    f:Hide()
    nearbyBanner = f
    return f
end

local function HideNearbyBanner(instant)
    lastBannerKey = nil
    if not nearbyBanner then return end
    if instant then
        F.Theme.FadeTo(nearbyBanner, 0, 0, true)
    elseif nearbyBanner:IsShown() then
        F.Theme.FadeTo(nearbyBanner, 0, 0.22, true)
    end
end

local function ShowNearbyBanner(mobName, distYards)
    local f = EnsureNearbyBanner()
    local distRounded = math_floor((distYards or 0) / 10 + 0.5) * 10
    local key = tostring(mobName) .. ":" .. tostring(distRounded)
    if key ~= lastBannerKey or not f:IsShown() then
        local wasShown = f:IsShown() and (F.PlainNumber(f:GetAlpha(), 0) or 0) > 0.05
        lastBannerKey = key
        local cr, cg, cb = COL_EMERALD[1], COL_EMERALD[2], COL_EMERALD[3]
        local hex = F.RGBToHex(cr, cg, cb)
        ST.ApplyText(f._title, 13, 0.96, 0.97, 0.99, 1)
        ST.ApplyText(f._sub, 11, 0.72, 0.76, 0.83, 0.95)
        f._title:SetText(string_format("|cff%s附近已有任务怪|r  |cff556070·|r  %s", hex, tostring(mobName)))
        f._sub:SetText(string_format("Polestar 导航指向 %d 码外，可直接在附近击杀", math_floor(distYards + 0.5)))
        if not wasShown then
            f:SetAlpha(0)
            f:Show()
        end
        local w = math_max(
            F.PlainNumber(f._title:GetStringWidth(), 200) or 200,
            F.PlainNumber(f._sub:GetStringWidth(), 200) or 200
        )
        f:SetSize(math_max(250, math_floor(w + 36)), 50)
        F.Theme.PaintPrettyCardOverlay(f, cr, cg, cb, 24, {
            alpha = 0.88,
            haloAlpha = 0.16,
            haloSpread = 12,
            headerTopAlpha = 0.28,
            headerBottomAlpha = 0.00,
        })
        F.Theme.FadeTo(f, 1, 0.18, false)
    elseif f:IsShown() then
        F.Theme.FadeTo(f, 1, 0.18, false)
    end
end

----------------------------------------------------------------------
--  4) 若当前目标在附近有更近的刷怪点，自动切回就近点
----------------------------------------------------------------------
local function TrySnapCloserSpot(P, wp, goal, pc, px, py)
    local db = mod:GetDB()
    if db.autoSnapSpot == false then return false end
    if type(goal.spots) ~= "table" or #goal.spots < 2 then return false end
    local E = P and P.Engine
    local C = P and P.Compat
    if not (E and C and type(E.CycleSpot) == "function" and type(C.MapToWorld) == "function") then
        return false
    end
    local now = GetTime()
    if (now - (lastSnapAt[goal] or 0)) < SNAP_COOLDOWN then return false end

    local curIdx = type(E.SpotIndexOf) == "function" and E.SpotIndexOf(goal) or nil
    local bestIdx, bestDist = nil, SNAP_NEAR_YD
    for i, s in ipairs(goal.spots) do
        if type(s) == "table" and s.x and s.y then
            local okM, sc, wx, wy = pcall(C.MapToWorld, goal.map, s.x, s.y, goal.f)
            if okM and sc == pc and wx and wy then
                local d = math_sqrt((wx - px) * (wx - px) + (wy - py) * (wy - py)) - (s.r or 0)
                if d < 0 then d = 0 end
                if d < bestDist then
                    bestDist = d
                    bestIdx = i
                end
            end
        end
    end
    if bestIdx and bestIdx ~= curIdx and wp.stepIndex and wp.goalIndex then
        lastSnapAt[goal] = now
        local ok = pcall(E.CycleSpot, wp.stepIndex, wp.goalIndex, bestIdx)
        return ok
    end
    return false
end

local function ScanNearbyQuestMobs()
    local db = mod:GetDB()
    if not (mod._active and db.nearbyQuestMob ~= false) then
        HideNearbyBanner(true)
        return
    end
    if _G.IsInInstance then
        local okI, inInst = pcall(_G.IsInInstance)
        if okI and SafeBool(inInst) then
            HideNearbyBanner(true)
            return
        end
    end
    local P = GetPolestar()
    if not P then
        HideNearbyBanner(true)
        return
    end
    local wp, goal = GetActiveGoal()
    if not (wp and goal and IsMobHuntGoal(goal)) then
        HideNearbyBanner(false)
        return
    end

    local now = GetTime()
    local hit, mobName = DetectNearbyQuestMob(goal)
    if hit then
        lastMobGoal = goal
        lastMobName = mobName
        lastMobAt = now
    elseif lastMobGoal == goal and (now - lastMobAt) <= MOB_HOLD_SEC then
        hit = true
        mobName = lastMobName
    else
        HideNearbyBanner(false)
        return
    end

    local C = P.Compat
    if not (C and type(C.GetPlayerWorldPosition) == "function" and type(C.MapToWorld) == "function") then
        HideNearbyBanner(false)
        return
    end
    local okP, pc, px, py = pcall(C.GetPlayerWorldPosition)
    local okT, tc, tx, ty = pcall(C.MapToWorld, wp.map, wp.x, wp.y, wp.f)
    if not (okP and okT and pc and tc and pc == tc and px and py and tx and ty) then
        HideNearbyBanner(false)
        return
    end
    local dist = math_sqrt((tx - px) * (tx - px) + (ty - py) * (ty - py))
    local wpArea = tonumber(wp.area) or 0
    local effDist = dist - wpArea
    if effDist < 0 then effDist = 0 end

    if effDist > FAR_WAYPOINT_YD then
        if TrySnapCloserSpot(P, wp, goal, pc, px, py) then
            HideNearbyBanner(false)
            return
        end
        if db.nearbyMobBanner ~= false then
            ShowNearbyBanner(mobName or "任务目标", effDist)
        else
            HideNearbyBanner(false)
        end
    else
        HideNearbyBanner(false)
    end
end

----------------------------------------------------------------------
--  5) 与 Polestar 补丁的轻量全局回调桥接（停用时彻底摘除）
----------------------------------------------------------------------
local function InstallBridges()
    _G.kkowoUI_PolestarHasNearbyQuestMob = function(goal)
        local db = mod:GetDB()
        if not (mod._active and db.nearbyQuestMob ~= false) then return false end
        if goal == lastMobGoal and (GetTime() - lastMobAt) <= MOB_HOLD_SEC then
            return true
        end
        local hit, name = DetectNearbyQuestMob(goal)
        if hit then
            lastMobGoal = goal
            lastMobName = name
            lastMobAt = GetTime()
            return true
        end
        return false
    end

    _G.kkowoUI_PolestarZoneDungeonCfg = function()
        local db = mod:GetDB()
        return {
            enabled = mod._active and db.zoneDungeonAlert ~= false,
            levelFilter = db.zoneDungeonLevelOnly ~= false,
            includeRaids = db.zoneDungeonIncludeRaids == true,
        }
    end
end

local function RemoveBridges()
    _G.kkowoUI_PolestarHasNearbyQuestMob = nil
    _G.kkowoUI_PolestarZoneDungeonCfg = nil
end

local function StartTicker()
    if scanTicker or not (C_Timer and C_Timer.NewTicker) then return end
    scanTicker = C_Timer.NewTicker(SCAN_INTERVAL, ScanNearbyQuestMobs)
end

local function StopTicker()
    if scanTicker then
        scanTicker:Cancel()
        scanTicker = nil
    end
end

----------------------------------------------------------------------
--  生命周期与 /kk 面板选项
----------------------------------------------------------------------
function mod:OnEnable()
    InstallBridges()
    StartTicker()
    if not bootSyncDone then
        bootSyncDone = true
        C_Timer.After(1.5, function()
            if mod._active then SyncRouteStyle() end
        end)
    else
        SyncRouteStyle()
    end
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        C_Timer.After(1.0, function()
            if mod._active then SyncRouteStyle() end
        end)
    end)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        HideNearbyBanner(true)
        lastMobGoal = nil
    end)
end

function mod:OnDisable()
    StopTicker()
    HideNearbyBanner(true)
    lastMobGoal = nil
    lastMobName = nil
    lastMobAt = 0
    RemoveBridges()
    SyncRouteStyle(false)
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "优先沿大路与山路寻路（Roads 模式）",
        tooltip = "自动将 Polestar 路线风格设为「道路优先」（大幅提高陡坡惩罚、优先走盘山公路），关闭或停用模块时无损恢复原设置。",
        getValue = function() return db.preferRoads ~= false end,
        setValue = function(v)
            db.preferRoads = v == true
            SyncRouteStyle()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "视野任务怪就近防赶人",
        tooltip = "扫描目标/悬停/周围姓名板：发现附近仍有当前任务的存活任务怪时，阻止 Polestar 误把你赶去其它区域；若目标在附近存在备选怪区则自动切回就近点。",
        getValue = function() return db.nearbyQuestMob ~= false end,
        setValue = function(v)
            db.nearbyQuestMob = v == true
            if not db.nearbyQuestMob then HideNearbyBanner(true) end
        end,
    }, {
        type = "toggle",
        text = "附近已有任务怪时弹出顶部轻提示",
        tooltip = "当 Polestar 导航指向 65 码外其它区域但你身边已经出现存活任务怪时，在顶部显示轻提示胶囊提醒可直接就近击杀。",
        getValue = function() return db.nearbyMobBanner ~= false end,
        setValue = function(v)
            db.nearbyMobBanner = v == true
            if not db.nearbyMobBanner then HideNearbyBanner(true) end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "进入副本所在地图时用 Polestar 原生卡片提醒",
        tooltip = "跨入包含地下城的地图时，复用 Polestar 原生卡片提醒本图副本、可接任务数，并提供「接取任务 / 导航至入口」一键按钮（飞行路线路过不误报，需已应用 Polestar 导航补丁）。",
        getValue = function() return db.zoneDungeonAlert ~= false end,
        setValue = function(v) db.zoneDungeonAlert = v == true end,
    }, {
        type = "toggle",
        text = "仅提醒适合当前等级的副本",
        tooltip = "开启时仅提醒适合当前等级区间的地下城（避免满级路过新手城/低级图反复弹窗）；关闭则提醒当前地图全部地下城。",
        getValue = function() return db.zoneDungeonLevelOnly ~= false end,
        setValue = function(v) db.zoneDungeonLevelOnly = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "地图副本提醒包含团队副本",
        tooltip = "开启后进入熔火之心、黑翼之巢、祖尔格拉布、安其拉、纳克萨玛斯等团本所在地图时也会一并提醒。",
        getValue = function() return db.zoneDungeonIncludeRaids == true end,
        setValue = function(v) db.zoneDungeonIncludeRaids = v == true end,
    }, {
        type = "toggle",
        text = "自动切回附近备选刷怪点",
        tooltip = "附近出现任务怪且 Polestar 列表里有 55 码内的备选怪区时，自动切换箭头到脚下这个怪区。",
        getValue = function() return db.autoSnapSpot ~= false end,
        setValue = function(v) db.autoSnapSpot = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "button",
        text = "立即重算 Polestar 路线",
        buttonText = "立即重算",
        tooltip = "清空当前寻路缓存并立刻按当前位置重新规划 Polestar 路线与箭头。",
        onClick = ForceReplanNow,
    }, {
        type = "button",
        text = "测试当前地图副本提醒",
        buttonText = "立即预览",
        tooltip = "立刻用 Polestar 原生卡片预览当前所在地图的地下城提醒（需在含副本的地图中，或聊天输入 /polestar dungeontoast zone）。",
        onClick = function()
            local P = GetPolestar()
            local DT = P and P.UI and P.UI.DungeonToast
            if DT and type(DT.CheckZone) == "function" then
                if not DT.CheckZone(true) then
                    F.Print("当前所在地图未检测到地下城/副本。")
                end
            else
                F.Print("请先退出游戏并运行「DD更新后重打补丁.bat」应用 Polestar 导航补丁。")
            end
        end,
    })
    y = y - h
    return y
end
