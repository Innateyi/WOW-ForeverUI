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
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_abs, math_floor, math_max, math_sqrt, pairs, pcall, select, setmetatable, tonumber, tostring, type =
    ipairs, math.abs, math.floor, math.max, math.sqrt, pairs, pcall, select, setmetatable, tonumber, tostring, type
local string_format = string.format
local table_concat, table_sort = table.concat, table.sort
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime

local ST = F.StyleTokens

local mod = F.RegisterModule("polestarNav", {
    title = "北极星导航优化",
    desc = "优先沿道路寻路，附近有任务怪时就近锁定并提醒本图副本。",
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
    if F.IsSecret(v) then return false end
    return type(v) == "boolean" and v
end

local function IsObjForbidden(obj)
    if not obj then return true end
    if obj.IsForbidden then
        local ok, forb = pcall(obj.IsForbidden, obj)
        if not ok or forb then return true end
    end
    return false
end

local function SafeCall1(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, res = pcall(fn, ...)
    if not ok then return nil end
    return res
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
        F.Print("未检测到北极星指南插件。")
        return false
    end
    local walk = P.Nav.walk
    if type(walk) == "table" and type(walk.Clear) == "function" then
        pcall(walk.Clear)
    end
    if type(P.Nav.Refresh) == "function" then
        pcall(P.Nav.Refresh)
    end
    F.Print("已重算北极星指南路线。")
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
                if type(plate) == "table" and not IsObjForbidden(plate) then
                    local uf = plate.UnitFrame
                    local u = plate.namePlateUnitToken or (uf and not IsObjForbidden(uf) and uf.unit)
                    if u and not F.IsSecret(u) then
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

    local curIdx = SafeCall1(E.SpotIndexOf, goal)
    local bestIdx, bestDist = nil, SNAP_NEAR_YD
    for i, s in ipairs(goal.spots) do
        if type(s) == "table" and s.x and s.y then
            local okM, sc, wx, wy = pcall(C.MapToWorld, goal.map, s.x, s.y, goal.f)
            sc = okM and F.PlainNumber(sc, nil) or nil
            wx = okM and F.PlainNumber(wx, nil) or nil
            wy = okM and F.PlainNumber(wy, nil) or nil
            if sc and sc == pc and wx and wy then
                local d = math_sqrt((wx - px) * (wx - px) + (wy - py) * (wy - py)) - (F.PlainNumber(s.r, 0) or 0)
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
    pc = okP and F.PlainNumber(pc, nil) or nil
    px = okP and F.PlainNumber(px, nil) or nil
    py = okP and F.PlainNumber(py, nil) or nil
    tc = okT and F.PlainNumber(tc, nil) or nil
    tx = okT and F.PlainNumber(tx, nil) or nil
    ty = okT and F.PlainNumber(ty, nil) or nil
    if not (pc and tc and pc == tc and px and py and tx and ty) then
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
--  5) 原生进入副本所在地图提醒（零文件补丁：直接复用 Polestar.UI.ClassToast）
--     使用 kkowoZoneDungeon 字段而非 m.dungeon，避免污染原版 DungeonToast 的 seen()
----------------------------------------------------------------------
local ZONE_DUNGEON_MAPS = {
    [1413] = true, [1416] = true, [1418] = true, [1420] = true, [1421] = true,
    [1422] = true, [1423] = true, [1426] = true, [1427] = true, [1428] = true,
    [1434] = true, [1435] = true, [1436] = true, [1437] = true, [1440] = true,
    [1443] = true, [1444] = true, [1445] = true, [1446] = true, [1447] = true,
    [1449] = true, [1451] = true, [1453] = true, [1454] = true, [1455] = true,
    [1458] = true, [2548] = true,
}
local SIDE_MAP = { Alliance = "A", Horde = "H" }
local ZONE_ALERT_COOLDOWN = 1800
local zoneShownAt = {}
local zoneDismissed = {}
local lastZoneMap = nil
local pendingZoneMap = nil
local zoneTimerGen = 0
local psHeadsUpHooked = false

local function GetCurrentOutdoorMapID()
    if _G.IsInInstance then
        local okI, inInst = pcall(_G.IsInInstance)
        if okI and SafeBool(inInst) then return nil end
    end
    local P = GetPolestar()
    local C = P and P.Compat
    if C and type(C.GetPlayerMapPosition) == "function" then
        local okM, m = pcall(C.GetPlayerMapPosition)
        m = okM and F.PlainNumber(m, nil) or nil
        if m and m > 0 then return m end
    end
    local CM = _G.C_Map
    if CM and type(CM.GetBestMapForUnit) == "function" then
        local okM, m = pcall(CM.GetBestMapForUnit, "player")
        m = okM and F.PlainNumber(m, nil) or nil
        if m and m > 0 then return m end
    end
    return nil
end

local function DungeonMatchesZone(d, mapID)
    if d.zone == mapID then return true end
    if type(d.entrance) == "table" and d.entrance.map == mapID then return true end
    if (mapID == 1427 or mapID == 1428) and (d.zone == 1427 or d.zone == 1428) then return true end
    return false
end

local function BuildZoneDungeonCardModel(P, c, isPreview)
    local Dg = P.Dungeons
    local DT = P.UI and P.UI.DungeonToast
    local CT = P.UI and P.UI.ClassToast
    local Theme = P.Theme
    local L = type(P.L) == "table" and P.L or {}
    local pInfo = SafeCall1(P.Compat and P.Compat.GetPlayerInfo)
    if type(pInfo) ~= "table" then pInfo = {} end
    local side = SIDE_MAP[pInfo.faction or ""]

    local isRaid = c.kind == "raid"
    local m = {
        kkowoZoneDungeon = c.key,
        kkowoPreview = isPreview == true,
        art = SafeCall1(Dg and Dg.Art, c.key),
        icon = SafeCall1(Theme and Theme.Media, "icon-dungeon"),
        iconColor = "dungeon",
        titleColor = "text",
        head = isRaid and "当前地图 · 团队副本" or "当前地图 · 地下城",
        title = string_format("本图副本：%s", tostring(c.name)),
    }
    m.facts = m.head

    local where = {}
    if (c.take or 0) > 0 then
        if c.take == 1 then
            where[#where + 1] = L["1 quest to pick up"] or "1 个可接任务"
        else
            where[#where + 1] = string_format(L["%d quests to pick up"] or "%d 个可接任务", c.take)
        end
    else
        where[#where + 1] = "已到达副本所在地图"
    end
    local range = SafeCall1(P.UI and P.UI.LevelRange, c.minLevel, c.maxLevel)
    if range then
        where[#where + 1] = string_format(L["Levels %s"] or "等级 %s", range)
    end
    if c.zoneName then
        where[#where + 1] = c.zoneName
    end
    m.giver = table_concat(where, "  \194\183  ")
    if c.extraNames and c.extraNames ~= "" then
        m.giver = m.giver .. "\n同图另有：" .. c.extraNames
    end
    local enemy = side and SafeCall1(Dg and Dg.EnemyEntrance, c.key, side) or nil
    local warnHex = enemy and SafeCall1(Theme and Theme.Hex, "warning") or nil
    if enemy and warnHex then
        m.giver = m.giver .. "\n|c" .. warnHex .. enemy .. "|r"
    end
    local LT = P.UI and P.UI.LevelTip
    local xs = (c.take or 0) > 0 and SafeCall1(Dg and Dg.QuestXP, c.key) or nil
    if type(xs) == "table" and not xs.maxed and (xs.levels or 0) > 0 and LT and LT.Text then
        local txt = SafeCall1(LT.Text, xs.levels)
        if txt then m.badge = SafeCall1(P.Upper, txt) or txt end
    end

    local pickBtn = {
        label = c.pickLabel or L["Pick up the quests"] or "接取任务",
        run = function() return DT and DT.PickUp and DT.PickUp(c.key) end,
    }
    local pageBtn = {
        label = L["Open in Dungeons"] or "打开副本页",
        run = function() return DT and DT.SeePage and DT.SeePage(c.key) end,
    }
    local guideBtn = {
        label = "导航至入口",
        run = function()
            local ok = Dg and Dg.GuideTo and Dg.GuideTo(c.key)
            if ok and CT and CT.Hide then CT.Hide() end
            return ok
        end,
    }
    if enemy then
        m.act = pageBtn
        m.more = (c.take or 0) > 0 and pickBtn or (c.hasEntrance and guideBtn or nil)
    elseif (c.take or 0) > 0 then
        m.act = pickBtn
        m.more = c.hasEntrance and guideBtn or pageBtn
    elseif c.hasEntrance then
        m.act = guideBtn
        m.more = pageBtn
    else
        m.act = pageBtn
        m.more = nil
    end
    m.off = {
        label = "关闭本图副本提醒",
        run = function()
            mod:GetDB().zoneDungeonAlert = false
            if CT and CT.Hide then CT.Hide() end
            F.Print("已关闭「进入副本所在地图提醒」，可在 /kk 中随时重新开启。")
        end,
    }
    m.later = {
        label = L["Later"] or "稍后",
        run = function() zoneDismissed[c.key] = GetTime() end,
    }
    return m
end

local function CheckZoneDungeonAlert(force)
    local db = mod:GetDB()
    if not force and not (mod._active and db.zoneDungeonAlert ~= false) then
        return false
    end
    if not force and _G.UnitOnTaxi then
        local okT, onTaxi = pcall(_G.UnitOnTaxi, "player")
        if okT and SafeBool(onTaxi) then return false end
    end
    local mapID = GetCurrentOutdoorMapID()
    if not mapID then return false end

    local P = GetPolestar()
    local Dg = P and P.Dungeons
    local CT = P and P.UI and P.UI.ClassToast
    local C = P and P.Compat
    if not (P and Dg and type(Dg.List) == "function" and CT and type(CT.ShowCard) == "function") then
        return false
    end
    local codexLoaded = SafeBool(SafeCall1(P.Codex and P.Codex.IsLoaded))
    if not force and not codexLoaded and not ZONE_DUNGEON_MAPS[mapID] then
        return false
    end
    local inCombat = SafeBool(SafeCall1(C and C.InCombat))
    if inCombat or (not force and CT.current) then
        pendingZoneMap = mapID
        return false
    end
    if not codexLoaded and type(Dg.Load) == "function" then
        local okL, loaded = pcall(Dg.Load)
        if not (okL and loaded) then return false end
    end

    local pInfo = SafeCall1(C and C.GetPlayerInfo)
    if type(pInfo) ~= "table" then pInfo = nil end
    local level = pInfo and F.PlainNumber(pInfo.level, nil) or nil
    local side = pInfo and SIDE_MAP[pInfo.faction or ""] or nil
    if not (level and side) then return false end

    local now = GetTime()
    local found = {}
    local okList, list = pcall(Dg.List)
    if not (okList and type(list) == "table") then return false end

    for _, d in ipairs(list) do
        if type(d) == "table" and DungeonMatchesZone(d, mapID) then
            local isRaid = d.kind == "raid"
            local kindOk = (not isRaid) or (db.zoneDungeonIncludeRaids == true) or force
            local enemyCap = SafeCall1(Dg.EnemyCapital, d.key, side)
            local lo = d.minLevel or 1
            local hi = d.maxLevel or lo or 60
            local levelOk = force
                or (db.zoneDungeonLevelOnly == false)
                or (isRaid and level >= 58)
                or (not isRaid and level >= lo - 2 and level <= hi + 5)
            local cooled = force
                or ((now - (zoneShownAt[d.key] or -1e9)) >= ZONE_ALERT_COOLDOWN and not zoneDismissed[d.key])
            if kindOk and not enemyCap and levelOk and cooled then
                local plan = SafeCall1(Dg.PickupPlan, d.key)
                local take = type(plan) == "table" and type(plan.take) == "table" and #plan.take or 0
                local best = F.PlainNumber(SafeCall1(Dg.BestAt, d.key), nil) or lo
                found[#found + 1] = {
                    key = d.key,
                    name = d.name,
                    kind = d.kind,
                    zoneName = d.zoneName,
                    minLevel = d.minLevel,
                    maxLevel = d.maxLevel,
                    best = best,
                    take = take,
                    hasEntrance = d.entrance ~= nil,
                    pickLabel = plan and SafeCall1(Dg.PickupLabel, plan) or nil,
                    gap = math_abs((best or lo) - level),
                }
            end
        end
    end
    if #found == 0 then return false end

    table_sort(found, function(a, b)
        if (a.kind == "raid") ~= (b.kind == "raid") then return a.kind ~= "raid" end
        if (a.take > 0) ~= (b.take > 0) then return a.take > 0 end
        if a.gap ~= b.gap then return a.gap < b.gap end
        return tostring(a.key) < tostring(b.key)
    end)

    local pick = found[1]
    if #found > 1 then
        local extras = {}
        for i = 2, #found do extras[#extras + 1] = found[i].name end
        pick.extraNames = table_concat(extras, "、")
    end
    local model = BuildZoneDungeonCardModel(P, pick, force == true)
    local okShow, shown = pcall(CT.ShowCard, model)
    if okShow and shown then
        -- 预览模式（force=true）绝不写入 30 分钟冷却，避免阻断后续真实进图提醒（P2-27）
        if not force then
            zoneShownAt[pick.key] = now
            for i = 2, #found do
                zoneShownAt[found[i].key] = now
            end
        end
        return true
    end
    return false
end

local function ScheduleZoneDungeonCheck(delay)
    zoneTimerGen = zoneTimerGen + 1
    local gen = zoneTimerGen
    C_Timer.After(delay or 1.2, function()
        if gen ~= zoneTimerGen or not mod._active then return end
        if _G.UnitOnTaxi then
            local okT, onTaxi = pcall(_G.UnitOnTaxi, "player")
            if okT and SafeBool(onTaxi) then return end
        end
        local mapID = GetCurrentOutdoorMapID()
        if not mapID or mapID == lastZoneMap then return end
        lastZoneMap = mapID
        pendingZoneMap = nil
        CheckZoneDungeonAlert(false)
    end)
end

local function RetryPendingZoneAlert()
    if not (mod._active and pendingZoneMap) then return end
    local m = pendingZoneMap
    pendingZoneMap = nil
    C_Timer.After(0.6, function()
        if mod._active and GetCurrentOutdoorMapID() == m then
            CheckZoneDungeonAlert(false)
        end
    end)
end

----------------------------------------------------------------------
--  6) 与 Polestar 极简导航参数补丁的轻量全局回调桥接（停用时彻底摘除）
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

    if not psHeadsUpHooked then
        local P = GetPolestar()
        if P and type(P.On) == "function" then
            psHeadsUpHooked = true
            P.On("HEADS_UP_HIDDEN", function(m)
                if not mod._active then return end
                if type(m) == "table" and m.kkowoZoneDungeon and not m.kkowoPreview then
                    zoneDismissed[m.kkowoZoneDungeon] = GetTime()
                end
                RetryPendingZoneAlert()
            end)
        end
    end
end

local function RemoveBridges()
    _G.kkowoUI_PolestarHasNearbyQuestMob = nil
end

function mod:PreviewZoneDungeon()
    if not self._active then return end
    if not CheckZoneDungeonAlert(true) then
        F.Print("当前所在地图未检测到地下城/副本。")
    end
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
        lastZoneMap = GetCurrentOutdoorMapID()
        C_Timer.After(1.0, function()
            if mod._active then SyncRouteStyle() end
        end)
    end)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        HideNearbyBanner(true)
        lastMobGoal = nil
        ScheduleZoneDungeonCheck(1.2)
    end)
    self:RegisterEvent("PLAYER_CONTROL_GAINED", function()
        ScheduleZoneDungeonCheck(0.8)
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", RetryPendingZoneAlert)
end

function mod:OnDisable()
    StopTicker()
    HideNearbyBanner(true)
    lastMobGoal = nil
    lastMobName = nil
    lastMobAt = 0
    pendingZoneMap = nil
    RemoveBridges()
    SyncRouteStyle(false)
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "优先沿大路寻路",
        tooltip = "让北极星指南优先走大路与山路，停用后自动恢复原设置。",
        getValue = function() return db.preferRoads ~= false end,
        setValue = function(v)
            db.preferRoads = v == true
            SyncRouteStyle()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "附近任务怪锁定",
        tooltip = "视野内仍有当前任务怪时阻止切去远处，附近有备选点自动切回。",
        getValue = function() return db.nearbyQuestMob ~= false end,
        setValue = function(v)
            db.nearbyQuestMob = v == true
            if not db.nearbyQuestMob then HideNearbyBanner(true) end
        end,
    }, {
        type = "toggle",
        text = "附近任务怪横幅",
        tooltip = "导航指向远处而身边已有存活任务怪时，顶部弹出简短提示。",
        getValue = function() return db.nearbyMobBanner ~= false end,
        setValue = function(v)
            db.nearbyMobBanner = v == true
            if not db.nearbyMobBanner then HideNearbyBanner(true) end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "入图副本提醒",
        tooltip = "进入含地下城的地图时弹出卡片，显示可接任务与导航入口。",
        getValue = function() return db.zoneDungeonAlert ~= false end,
        setValue = function(v) db.zoneDungeonAlert = v == true end,
    }, {
        type = "toggle",
        text = "仅提示适级副本",
        tooltip = "只提醒适合当前等级的地下城，避免路过低级地图反复弹窗。",
        getValue = function() return db.zoneDungeonLevelOnly ~= false end,
        setValue = function(v) db.zoneDungeonLevelOnly = v == true end,
    })
    y = y - h

    local function buildAdv(w, p, curY)
        local _, rh
        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "包含团队副本",
            tooltip = "进入熔火之心、黑翼之巢等团队副本所在地图时一并提醒。",
            getValue = function() return db.zoneDungeonIncludeRaids == true end,
            setValue = function(v) db.zoneDungeonIncludeRaids = v == true end,
        }, {
            type = "toggle",
            text = "自动切近刷怪点",
            tooltip = "附近发现任务怪且 55 码内有备选怪区时自动切换导航点。",
            getValue = function() return db.autoSnapSpot ~= false end,
            setValue = function(v) db.autoSnapSpot = v == true end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "button",
            text = "重算导航路线",
            buttonText = "立即重算",
            tooltip = "清空寻路缓存并按当前位置重新规划北极星路线与箭头。",
            onClick = ForceReplanNow,
        }, {
            type = "button",
            text = "预览副本提醒",
            buttonText = "立即预览",
            tooltip = "立即预览当前所在地图的地下城提醒卡片。",
            onClick = function()
                mod:PreviewZoneDungeon()
            end,
        })
        curY = curY - rh
        return curY
    end

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("polestarNav", W, parent, y, buildAdv, blank)
    else
        y = buildAdv(W, parent, y)
    end
    return y
end
