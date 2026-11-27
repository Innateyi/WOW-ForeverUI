----------------------------------------------------------------------
--  kkowoUI — Modules/ZoneLabels.lua
--  世界地图区域等级标签 + 飞艇/航船航线三维清晰指引（零污染）：
--    1) 大陆地图各子区域常驻名称 + 等级区间（内置 21 个已精调偏移）
--    2) 世界地图底部鼠标悬停区域等级条（现代暗底圆角浮胶囊）
--    3) 世界地图区域页分离式「飞艇 / 航船航线」圆角标牌（彻底解决双飞艇图标重叠看不清去哪的问题）
--    4) 飞艇塔 / 码头「当前泊位」顶部悬浮胶囊（站上平台即显示本侧与对侧分别前往何地，离开零开销）
--    5) 飞艇管理员头顶姓名板航线胶囊 + 鼠标悬停提示补充（走上塔楼一眼分清弗雷萨/斯努尔克去哪）
--    6) /zlmap 微调命令：/zlmap <mapID> <x> <y> 或 /zlmap reset
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_abs, math_floor, math_max, math_sqrt, pairs, pcall, setmetatable, tonumber, tostring, type =
    ipairs, math.abs, math.floor, math.max, math.sqrt, pairs, pcall, setmetatable, tonumber, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local ST = F.StyleTokens

local mod = F.RegisterModule("zoneLabels", {
    title = "地图区域等级与飞艇航线指引",
    desc = "在大陆地图标注区域名称与等级；并在区域地图、飞艇塔/码头站台及飞艇管理员头顶清晰标出每班飞艇与航船的目的地（零污染）。",
    group = "quest",
    order = 60,
    defaults = {
        enabled = true,
        showLabels = true,
        showName = true,
        showBottomBar = true,
        colorByDifficulty = true,
        fontSize = 11,
        customOffsets = {},
        showTransportMap = true,
        showTransportBanner = true,
        showTransportNameplates = true,
    },
})

----------------------------------------------------------------------
--  WoW Forever 全量飞艇与航船航线数据（坐标源自客户端地图基准，双向对齐）
--  配色与 Core/Theme.lua / Core/StyleTokens.lua 语义色严格对齐
----------------------------------------------------------------------
local COL_EMERALD = { 0.37, 0.83, 0.65 } -- 柔玉绿（幽暗城 / 塞拉摩 / 鲁瑟兰 / 泽弗拉斯）
local COL_AMBER   = { 0.94, 0.72, 0.34 } -- 暖琥珀（格罗姆高 / 雷霆崖）
local COL_CORAL   = { 0.90, 0.42, 0.46 } -- 珊瑚红（奥格瑞玛）
local COL_SKY     = { 0.44, 0.86, 0.94 } -- 清透青蓝（航船 / 码头）
local COL_AZURE   = { 0.48, 0.74, 0.98 } -- 雾蓝（暴风城）

local TRANSPORT_MAP_ROUTES = {
    -- 杜隆塔尔（奥格瑞玛城外飞艇塔）
    [1411] = {
        { x = 50.5, y = 12.7, kind = "飞艇", dest = "格罗姆高（荆棘谷）", shortDest = "格罗姆高", side = "西侧泊位", dx = -68, dy = 20, color = COL_AMBER },
        { x = 51.0, y = 13.9, kind = "飞艇", dest = "幽暗城（提瑞斯法）", shortDest = "幽暗城", side = "东侧泊位", dx = 68, dy = -18, color = COL_EMERALD },
    },
    -- 提瑞斯法林地（幽暗城外飞艇塔）
    [1420] = {
        { x = 60.6, y = 58.9, kind = "飞艇", dest = "奥格瑞玛（杜隆塔尔）", shortDest = "奥格瑞玛", side = "西侧泊位", dx = -66, dy = 18, color = COL_CORAL },
        { x = 61.9, y = 58.9, kind = "飞艇", dest = "格罗姆高（荆棘谷）", shortDest = "格罗姆高", side = "东侧泊位", dx = 66, dy = -18, color = COL_AMBER },
    },
    -- 荆棘谷（格罗姆高飞艇塔 + 藏宝海湾码头）
    [1434] = {
        { x = 31.5, y = 29.1, kind = "飞艇", dest = "幽暗城（提瑞斯法）", shortDest = "幽暗城", side = "北侧泊位", dx = 66, dy = 18, color = COL_EMERALD },
        { x = 31.2, y = 30.4, kind = "飞艇", dest = "奥格瑞玛（杜隆塔尔）", shortDest = "奥格瑞玛", side = "南侧泊位", dx = -66, dy = -18, color = COL_CORAL },
        { x = 25.7, y = 73.1, kind = "航船", dest = "棘齿城（贫瘠之地）", shortDest = "棘齿城", side = "藏宝海湾码头", dx = -60, dy = -16, color = COL_SKY },
    },
    -- 莫高雷（雷霆崖飞艇）
    [1412] = {
        { x = 34.3, y = 26.1, kind = "飞艇", dest = "泽弗拉斯岛", shortDest = "泽弗拉斯岛", side = "雷霆崖泊位", dx = -62, dy = 16, color = COL_EMERALD },
    },
    -- 泽弗拉斯岛（Forever 新增双航线）
    [2521] = {
        { x = 57.7, y = 81.0, kind = "飞艇", dest = "雷霆崖（莫高雷）", shortDest = "雷霆崖", side = "飞艇泊位", dx = -64, dy = 16, color = COL_AMBER },
        { x = 65.8, y = 83.8, kind = "航船", dest = "奥特兰克山脉", shortDest = "奥特兰克", side = "码头泊位", dx = 64, dy = -16, color = COL_SKY },
    },
    -- 贫瘠之地（棘齿城码头）
    [1413] = {
        { x = 63.8, y = 38.8, kind = "航船", dest = "藏宝海湾（荆棘谷）", shortDest = "藏宝海湾", side = "棘齿城码头", dx = 62, dy = -14, color = COL_SKY },
    },
    -- 湿地（米奈希尔港双码头）
    [1437] = {
        { x = 4.5, y = 56.7, kind = "航船", dest = "南海镇 / 奥伯丁", shortDest = "南海/奥伯丁", side = "北侧码头", dx = 72, dy = 18, color = COL_SKY },
        { x = 4.7, y = 63.8, kind = "航船", dest = "塞拉摩（尘泥沼泽）", shortDest = "塞拉摩", side = "南侧码头", dx = 66, dy = -18, color = COL_EMERALD },
    },
    -- 黑海岸（奥伯丁三码头）
    [1439] = {
        { x = 33.3, y = 39.8, kind = "航船", dest = "鲁瑟兰村（泰达希尔）", shortDest = "鲁瑟兰村", side = "北侧码头", dx = 66, dy = 20, color = COL_EMERALD },
        { x = 30.5, y = 40.9, kind = "航船", dest = "暴风城", shortDest = "暴风城", side = "西侧码头", dx = -64, dy = 6, color = COL_AZURE },
        { x = 32.3, y = 44.1, kind = "航船", dest = "米奈希尔港 / 南海镇", shortDest = "米奈希尔", side = "南侧码头", dx = 66, dy = -18, color = COL_AMBER },
    },
    -- 泰达希尔（鲁瑟兰村码头）
    [1438] = {
        { x = 54.8, y = 97.2, kind = "航船", dest = "奥伯丁（黑海岸）", shortDest = "奥伯丁", side = "鲁瑟兰码头", dx = -60, dy = 16, color = COL_SKY },
    },
    -- 尘泥沼泽（塞拉摩码头）
    [1445] = {
        { x = 71.7, y = 56.7, kind = "航船", dest = "米奈希尔港（湿地）", shortDest = "米奈希尔", side = "塞拉摩码头", dx = 62, dy = -14, color = COL_SKY },
    },
    -- 暴风城港口
    [1453] = {
        { x = 21.8, y = 56.9, kind = "航船", dest = "奥伯丁（黑海岸）", shortDest = "奥伯丁", side = "暴风城港口", dx = 60, dy = 14, color = COL_SKY },
    },
    -- 希尔斯布莱德丘陵（南海镇码头）
    [1424] = {
        { x = 50.7, y = 70.4, kind = "航船", dest = "奥伯丁 / 米奈希尔港", shortDest = "奥伯丁/米奈", side = "南海镇码头", dx = 68, dy = -14, color = COL_SKY },
    },
    -- 塔纳利斯 / 河谷地（Forever 航船）
    [1446] = {
        { x = 68.6, y = 23.0, kind = "航船", dest = "河谷地", shortDest = "河谷地", side = "热砂港码头", dx = 56, dy = 14, color = COL_SKY },
    },
    [2548] = {
        { x = 80.6, y = 54.6, kind = "航船", dest = "塔纳利斯", shortDest = "塔纳利斯", side = "河谷地码头", dx = -56, dy = -14, color = COL_SKY },
    },
}

-- 飞艇管理员 NPC 精准匹配（优先按中文/英文名字匹配，次选确定 ID，杜绝不同服务端译名误差）
local TRANSPORT_NPC_ENTRIES = {
    { names = { "弗雷萨", "Frezza" },                                           ids = { [9564] = true }, kind = "飞艇", dest = "幽暗城（提瑞斯法）", shortDest = "幽暗城", color = COL_EMERALD },
    { names = { "斯努尔克", "斯纳尔克", "思娜克", "Snurk Bucksquick", "Snurk" }, ids = { [12136] = true }, kind = "飞艇", dest = "格罗姆高（荆棘谷）", shortDest = "格罗姆高", color = COL_AMBER },
    { names = { "萨匹塔", "扎佩塔", "Zapetta" },                                 ids = { [9566] = true }, kind = "飞艇", dest = "奥格瑞玛（杜隆塔尔）", shortDest = "奥格瑞玛", color = COL_CORAL },
    { names = { "兴登堡", "欣登堡", "辛登堡", "Hin Denburg" },                   ids = {},                 kind = "飞艇", dest = "格罗姆高（荆棘谷）", shortDest = "格罗姆高", color = COL_AMBER },
    { names = { "内兹拉斯", "奈兹拉兹", "Nez'raz" },                             ids = {},                 kind = "飞艇", dest = "奥格瑞玛（杜隆塔尔）", shortDest = "奥格瑞玛", color = COL_CORAL },
    { names = { "斯奎比", "思奎比", "Squibby Overspeck", "Squibby" },            ids = {},                 kind = "飞艇", dest = "幽暗城（提瑞斯法）", shortDest = "幽暗城", color = COL_EMERALD },
}

local function GetUnitCreatureID(unit)
    if not (unit and _G.UnitGUID) then return nil end
    local ok, guid = pcall(_G.UnitGUID, unit)
    if not ok then return nil end
    guid = F.PlainString(guid, nil)
    if not guid then return nil end
    local idStr = guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return idStr and tonumber(idStr) or nil
end

local function ResolveTransportNPC(unit)
    unit = F.PlainString(unit, nil)
    if not (unit and _G.UnitExists) then return nil end
    local okE, exists = pcall(_G.UnitExists, unit)
    if not okE or F.IsSecret(exists) or not exists then return nil end
    if _G.UnitIsPlayer then
        local okP, isPlayer = pcall(_G.UnitIsPlayer, unit)
        if not okP or F.IsSecret(isPlayer) or isPlayer then return nil end
    end
    local okN, rawName = pcall(_G.UnitName, unit)
    local name = okN and F.PlainString(rawName, nil) or nil
    local cid = GetUnitCreatureID(unit)

    if name then
        for _, entry in ipairs(TRANSPORT_NPC_ENTRIES) do
            for _, kw in ipairs(entry.names) do
                if name == kw or name:find(kw, 1, true) then
                    return entry
                end
            end
        end
    end
    if cid then
        for _, entry in ipairs(TRANSPORT_NPC_ENTRIES) do
            if entry.ids[cid] then
                return entry
            end
        end
    end
    return nil
end

local overlayLayer = nil
local bottomBar = nil
local labelPool = {}
local routePinPool = {}
local hookedMap = false
local hookedTooltip = false

local platformBanner = nil
local npBadgeMap = setmetatable({}, { __mode = "k" })
local hookedNP = setmetatable({}, { __mode = "k" })
local npBadgeList = {}

local function GetZoneLevels(mapID, name)
    local data = F.ZoneLevelData
    if not data then return nil end
    if mapID and data.overrides[mapID] then
        return data.overrides[mapID][1], data.overrides[mapID][2]
    end
    if mapID and _G.C_Map and _G.C_Map.GetMapLevels then
        local ok, lo, hi = pcall(_G.C_Map.GetMapLevels, mapID)
        if ok and type(lo) == "number" and lo > 0 and type(hi) == "number" and hi > 0 then
            return lo, hi
        end
    end
    if name and data.byName[name] then
        return data.byName[name][1], data.byName[name][2]
    end
    return nil
end

local function DifficultyHex(lo, hi)
    local lvl = (_G.UnitLevel and F.PlainNumber(_G.UnitLevel("player"), 1)) or 1
    if lvl + 5 <= lo then
        return "e05263" -- 红
    elseif lvl + 3 <= lo then
        return "f09348" -- 橙
    elseif lvl < lo then
        return "f0bf57" -- 黄
    elseif lvl <= hi + 4 then
        return "5fd3a6" -- 绿
    end
    return "9a9ea8" -- 灰
end

local function HideAllLabels()
    for _, fs in ipairs(labelPool) do
        fs:Hide()
    end
end

local function HideAllRoutePins()
    for _, pin in ipairs(routePinPool) do
        pin:Hide()
        if pin._line then pin._line:Hide() end
        if pin._anchorDot then pin._anchorDot:Hide() end
    end
end

local function AcquireLabel(idx)
    local fs = labelPool[idx]
    if not fs then
        fs = overlayLayer:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("CENTER")
        labelPool[idx] = fs
    end
    return fs
end

local function AcquireRoutePin(idx)
    local pin = routePinPool[idx]
    if pin then return pin end

    pin = CreateFrame("Frame", nil, overlayLayer)
    pin:SetSize(110, 22)
    pin:EnableMouse(false)
    pin:SetFrameLevel(overlayLayer:GetFrameLevel() + 12)

    local txt = pin:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(txt, 11, 0.95, 0.96, 0.98, 1)
    txt:SetPoint("CENTER", pin, "CENTER", 0, -1)
    txt:SetJustifyH("CENTER")
    txt:SetWordWrap(false)

    local anchorDot = overlayLayer:CreateTexture(nil, "ARTWORK", nil, 5)
    anchorDot:SetSize(5, 5)
    anchorDot:SetTexture(ST.TEX.CIRCLE_MASK)

    local line = overlayLayer:CreateLine(nil, "ARTWORK", nil, 4)
    line:SetThickness(1.2)

    pin._txt = txt
    pin._anchorDot = anchorDot
    pin._line = line
    routePinPool[idx] = pin
    return pin
end

-- 鼠标静止时（地图编号与归一化坐标都没变）跳过整套查询/排版：轮询频率 12.5Hz，地图开着时大部分时间鼠标并不动
local lastHoverMap, lastHoverX, lastHoverY, lastHoverText = nil, nil, nil, nil

local function ResetHoverCache()
    lastHoverMap, lastHoverX, lastHoverY, lastHoverText = nil, nil, nil, nil
end

local function PaintBottomBarOverlay()
    if not bottomBar then return end
    local ic = ST.COLORS.info
    F.Theme.PaintPrettyCardOverlay(bottomBar, ic[1], ic[2], ic[3], 14, {
        radius = 6,
        alpha = 0.86,
        haloAlpha = 0.12,
        haloSpread = 8,
        headerTopAlpha = 0.24,
        headerBottomAlpha = 0.00,
    })
end

local function UpdateBottomHoverBar()
    if not bottomBar then return end
    local db = mod:GetDB()
    local wmf = _G.WorldMapFrame
    if not (mod._active and db.showBottomBar and wmf and wmf:IsShown()) then
        ResetHoverCache()
        bottomBar:Hide()
        return
    end
    local sc = wmf.ScrollContainer
    if not (sc and sc.GetNormalizedCursorPosition and _G.C_Map and _G.C_Map.GetMapInfoAtPosition) then
        bottomBar:Hide()
        return
    end
    local mapID = wmf.GetMapID and wmf:GetMapID()
    if not mapID then
        bottomBar:Hide()
        return
    end
    local cx, cy = sc:GetNormalizedCursorPosition()
    cx, cy = F.PlainNumber(cx, nil), F.PlainNumber(cy, nil)
    if not (cx and cy and cx >= 0 and cx <= 1 and cy >= 0 and cy <= 1) then
        ResetHoverCache()
        bottomBar:Hide()
        return
    end
    if mapID == lastHoverMap and lastHoverX and math_abs(cx - lastHoverX) < 0.001 and math_abs(cy - lastHoverY) < 0.001 then
        return
    end
    lastHoverMap, lastHoverX, lastHoverY = mapID, cx, cy
    local okInfo, info = pcall(_G.C_Map.GetMapInfoAtPosition, mapID, cx, cy)
    if not okInfo then info = nil end
    if not (info and info.name) then
        info = _G.C_Map.GetMapInfo and _G.C_Map.GetMapInfo(mapID)
    end
    if not (info and info.name) then
        bottomBar:Hide()
        return
    end
    local lo, hi = GetZoneLevels(info.mapID, info.name)
    if not (lo and hi) then
        bottomBar:Hide()
        return
    end
    local hex = db.colorByDifficulty and DifficultyHex(lo, hi) or F.RGBToHex(F.Theme.GetAccent())
    local lvlText = (lo == hi) and tostring(lo) or string_format("%d - %d", lo, hi)
    local txt = string_format("%s  |cff%s(%s)|r", info.name, hex, lvlText)
    if txt ~= lastHoverText or not bottomBar:IsShown() then
        lastHoverText = txt
        bottomBar.text:SetText(txt)
        bottomBar:Show()
        local tw = F.PlainNumber(bottomBar.text:GetStringWidth(), 100) or 100
        bottomBar:SetSize(math_max(100, math_floor(tw + 26)), 24)
        PaintBottomBarOverlay()
    end
end

local ScheduleRedraw

local function EnsureMapLayers()
    local wmf = _G.WorldMapFrame
    if not (wmf and wmf.ScrollContainer) then
        return false
    end
    local sc = wmf.ScrollContainer
    local canvas = (wmf.GetCanvas and wmf:GetCanvas()) or sc.Child
    if not canvas then
        return false
    end
    if not overlayLayer then
        overlayLayer = CreateFrame("Frame", nil, canvas)
        overlayLayer:SetAllPoints(canvas)
        overlayLayer:EnableMouse(false)
        overlayLayer:SetFrameLevel(canvas:GetFrameLevel() + 30)
        -- 地图最大化/还原等改变画布尺寸时按新宽高重新摆放区域标签
        overlayLayer:SetScript("OnSizeChanged", function()
            if mod._active and ScheduleRedraw then ScheduleRedraw() end
        end)
    end
    if not bottomBar then
        bottomBar = CreateFrame("Frame", nil, sc)
        bottomBar:SetSize(140, 24)
        bottomBar:SetPoint("BOTTOM", sc, "BOTTOM", 0, 14)
        bottomBar:SetFrameLevel(sc:GetFrameLevel() + 50)
        bottomBar:EnableMouse(false)
        bottomBar.text = bottomBar:CreateFontString(nil, "OVERLAY")
        ST.ApplyText(bottomBar.text, 12, 0.95, 0.96, 0.98, 1)
        bottomBar.text:SetPoint("CENTER", 0, -1)
        PaintBottomBarOverlay()
        bottomBar:Hide()
    end
    return true
end

local function RedrawTransportMapPins(mapID, cw, ch)
    HideAllRoutePins()
    local db = mod:GetDB()
    if not (mod._active and db.showTransportMap ~= false) then return end
    local routes = TRANSPORT_MAP_ROUTES[mapID]
    if not routes then return end

    for i, r in ipairs(routes) do
        local pin = AcquireRoutePin(i)
        local px = (r.x / 100) * cw
        local py = -(r.y / 100) * ch
        local bx = px + (r.dx or 56)
        local by = py + (r.dy or 14)
        local cr, cg, cb = r.color[1], r.color[2], r.color[3]
        local hex = F.RGBToHex(cr, cg, cb)

        ST.ApplyText(pin._txt, 11, 0.95, 0.96, 0.98, 1)
        pin._txt:SetText(string_format("|cff9aa4b2%s|r |cff556070·|r |cff%s%s|r", r.kind, hex, r.shortDest or r.dest))
        pin:Show()
        local tw = F.PlainNumber(pin._txt:GetStringWidth(), 82) or 82
        pin:SetSize(math_max(84, math_floor(tw + 20)), 22)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", overlayLayer, "TOPLEFT", bx, by)
        F.Theme.PaintPrettyCardOverlay(pin, cr, cg, cb, 14, {
            radius = 6,
            alpha = 0.88,
            haloAlpha = 0.14,
            haloSpread = 8,
            headerTopAlpha = 0.26,
            headerBottomAlpha = 0.00,
        })

        pin._anchorDot:SetVertexColor(cr, cg, cb, 0.92)
        pin._anchorDot:ClearAllPoints()
        pin._anchorDot:SetPoint("CENTER", overlayLayer, "TOPLEFT", px, py)
        pin._anchorDot:Show()

        pin._line:SetColorTexture(cr, cg, cb, 0.55)
        pin._line:SetStartPoint("TOPLEFT", overlayLayer, px, py)
        pin._line:SetEndPoint("CENTER", pin, 0, 0)
        pin._line:Show()
    end
end

local function RedrawMapLabels()
    ResetHoverCache()
    if not mod._active then
        HideAllLabels()
        HideAllRoutePins()
        if bottomBar then bottomBar:Hide() end
        return
    end
    local wmf = _G.WorldMapFrame
    if not (wmf and wmf:IsShown()) then
        return
    end
    if not EnsureMapLayers() then
        return
    end
    HideAllLabels()
    HideAllRoutePins()

    local db = mod:GetDB()
    local mapID = wmf.GetMapID and wmf:GetMapID()
    if not (mapID and _G.C_Map and _G.C_Map.GetMapInfo) then
        UpdateBottomHoverBar()
        return
    end

    local cw = F.PlainNumber(overlayLayer:GetWidth(), 0)
    local ch = F.PlainNumber(overlayLayer:GetHeight(), 0)
    if cw <= 10 or ch <= 10 then
        return
    end

    local mapInfo = _G.C_Map.GetMapInfo(mapID)
    -- 区域地图（mapType == 3）：渲染分离式飞艇 / 航船航线圆角标签
    if mapInfo and mapInfo.mapType == 3 then
        RedrawTransportMapPins(mapID, cw, ch)
        UpdateBottomHoverBar()
        return
    end

    if not db.showLabels then
        UpdateBottomHoverBar()
        return
    end
    if not (mapInfo and mapInfo.mapType == 2 and _G.C_Map.GetMapChildrenInfo and _G.C_Map.GetMapRectOnMap) then
        UpdateBottomHoverBar()
        return
    end

    local children = _G.C_Map.GetMapChildrenInfo(mapID, 3, true)
    if type(children) ~= "table" then
        return
    end

    local defaultOffsets = (F.ZoneLevelData and F.ZoneLevelData.defaultOffsets) or {}
    local customOffsets = db.customOffsets or {}
    local idx = 0

    for _, child in ipairs(children) do
        local lo, hi = GetZoneLevels(child.mapID, child.name)
        if lo and hi then
            local ok, minX, maxX, minY, maxY = pcall(_G.C_Map.GetMapRectOnMap, child.mapID, mapID)
            if ok and minX and maxX and minY and maxY and maxX > minX then
                idx = idx + 1
                local fs = AcquireLabel(idx)
                local off = customOffsets[child.mapID] or defaultOffsets[child.mapID]
                local cx = (minX + maxX) * 0.5 + (off and off.x or 0)
                local cy = (minY + maxY) * 0.5 - (off and off.y or 0)
                local hex = db.colorByDifficulty and DifficultyHex(lo, hi) or F.RGBToHex(F.Theme.GetAccent())
                local lvlText = (lo == hi) and tostring(lo) or string_format("%d-%d", lo, hi)
                F.Theme.ApplyFont(fs, db.fontSize or 11, "OUTLINE", 0.94, 0.94, 0.96, 1)
                if db.showName and child.name then
                    fs:SetText(string_format("|cffe8eaef%s|r\n|cff%s(%s)|r", child.name, hex, lvlText))
                else
                    fs:SetText(string_format("|cff%s%s|r", hex, lvlText))
                end
                fs:ClearAllPoints()
                fs:SetPoint("CENTER", overlayLayer, "TOPLEFT", cx * cw, -cy * ch)
                fs:Show()
            end
        end
    end
    UpdateBottomHoverBar()
end

local redrawQueued = false
ScheduleRedraw = function()
    if redrawQueued then return end
    redrawQueued = true
    C_Timer.After(0, function()
        redrawQueued = false
        RedrawMapLabels()
    end)
end

----------------------------------------------------------------------
--  飞艇塔 / 码头「当前泊位」悬浮卡片（PrettyTooltip 同源黑曜石柔光风格，
--  仅在含航线区域内按 0.45s 低频检测，其它区域零开销）
----------------------------------------------------------------------
local function EnsurePlatformBanner()
    if platformBanner then return platformBanner end
    local f = CreateFrame("Frame", "kkowoUI_TransportBanner", _G.UIParent)
    f:SetSize(280, 50)
    f:SetPoint("TOP", _G.UIParent, "TOP", 0, -112)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(80)
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
    platformBanner = f
    return f
end

local platformPoller = CreateFrame("Frame")
platformPoller:Hide()
local platformElapsed = 0
local lastBannerKey = nil

local function HidePlatformBanner(instant)
    lastBannerKey = nil
    if not platformBanner then return end
    if instant then
        F.Theme.FadeTo(platformBanner, 0, 0, true)
    elseif platformBanner:IsShown() then
        F.Theme.FadeTo(platformBanner, 0, 0.20, true)
    end
end

local function UpdatePlatformProximity()
    local db = mod:GetDB()
    if not (mod._active and db.showTransportBanner ~= false and _G.C_Map and _G.C_Map.GetBestMapForUnit and _G.C_Map.GetPlayerMapPosition) then
        HidePlatformBanner(true)
        return
    end
    local okM, mapID = pcall(_G.C_Map.GetBestMapForUnit, "player")
    mapID = okM and F.PlainNumber(mapID, nil) or nil
    local routes = mapID and TRANSPORT_MAP_ROUTES[mapID] or nil
    if not routes then
        HidePlatformBanner(false)
        platformPoller:Hide()
        return
    end
    local okPos, pos = pcall(_G.C_Map.GetPlayerMapPosition, mapID, "player")
    if not (okPos and pos and pos.GetXY) then
        HidePlatformBanner(false)
        return
    end
    local okXY, px, py = pcall(pos.GetXY, pos)
    px = okXY and F.PlainNumber(px, nil) or nil
    py = okXY and F.PlainNumber(py, nil) or nil
    if not (px and py) then
        HidePlatformBanner(false)
        return
    end
    px, py = px * 100, py * 100

    local best, bestDist = nil, 999
    for _, r in ipairs(routes) do
        local dx = px - r.x
        local dy = py - r.y
        local d = math_sqrt(dx * dx + dy * dy)
        if d < bestDist then
            bestDist = d
            best = r
        end
    end

    -- 2.6 地图坐标内（完整覆盖飞艇塔与码头区域）自动弹出当前泊位提示
    if not best or bestDist > 2.6 then
        HidePlatformBanner(false)
        return
    end

    local other = nil
    local otherDist = 999
    for _, r in ipairs(routes) do
        if r ~= best then
            local dx = best.x - r.x
            local dy = best.y - r.y
            local d = math_sqrt(dx * dx + dy * dy)
            if d < 10 and d < otherDist then
                otherDist = d
                other = r
            end
        end
    end

    local key = tostring(mapID) .. ":" .. best.dest .. ":" .. (other and other.dest or "")
    local f = EnsurePlatformBanner()
    if key ~= lastBannerKey or not f:IsShown() then
        local wasShown = f:IsShown() and (F.PlainNumber(f:GetAlpha(), 0) or 0) > 0.05
        lastBannerKey = key
        local cr, cg, cb = best.color[1], best.color[2], best.color[3]
        local hex = F.RGBToHex(cr, cg, cb)
        ST.ApplyText(f._title, 13, 0.96, 0.97, 0.99, 1)
        ST.ApplyText(f._sub, 11, 0.72, 0.76, 0.83, 0.95)
        f._title:SetText(string_format("|cff9aa4b2%s|r  |cff556070·|r  %s前往 |cff%s%s|r", best.side or "当前泊位", best.kind, hex, best.dest))
        if not wasShown then
            f:SetAlpha(0)
            f:Show()
        end
        local hdrH
        if other then
            local oHex = F.RGBToHex(other.color[1], other.color[2], other.color[3])
            f._sub:SetText(string_format("另一侧（%s）：前往 |cff%s%s|r", other.side or "对侧", oHex, other.dest))
            f._sub:Show()
            f._divider:Show()
            f._title:ClearAllPoints()
            f._title:SetPoint("TOP", f, "TOP", 0, -8)
            local w = math_max(F.PlainNumber(f._title:GetStringWidth(), 180) or 180, F.PlainNumber(f._sub:GetStringWidth(), 180) or 180)
            f:SetSize(math_max(236, math_floor(w + 36)), 50)
            hdrH = 24
        else
            f._sub:Hide()
            f._divider:Hide()
            f._title:ClearAllPoints()
            f._title:SetPoint("CENTER", f, "CENTER", 0, -1)
            local w = F.PlainNumber(f._title:GetStringWidth(), 180) or 180
            f:SetSize(math_max(210, math_floor(w + 36)), 32)
            hdrH = 18
        end
        F.Theme.PaintPrettyCardOverlay(f, cr, cg, cb, hdrH, {
            alpha = 0.88,
            haloAlpha = 0.16,
            haloSpread = 12,
            headerTopAlpha = 0.28,
            headerBottomAlpha = 0.00,
        })
        F.Theme.FadeTo(f, 1, 0.18, false)
    elseif f:IsShown() then
        -- 若正处于淡出中途又重新走回泊位范围内，平滑反转淡回可见
        F.Theme.FadeTo(f, 1, 0.18, false)
    end
end

platformPoller:SetScript("OnUpdate", function(_, elapsed)
    platformElapsed = platformElapsed + elapsed
    if platformElapsed < 0.45 then return end
    platformElapsed = 0
    UpdatePlatformProximity()
end)

local function SyncPlatformZoneWatch()
    local db = mod:GetDB()
    if not (mod._active and db.showTransportBanner ~= false and _G.C_Map and _G.C_Map.GetBestMapForUnit) then
        platformPoller:Hide()
        HidePlatformBanner(true)
        return
    end
    local okM, mapID = pcall(_G.C_Map.GetBestMapForUnit, "player")
    mapID = okM and F.PlainNumber(mapID, nil) or nil
    if mapID and TRANSPORT_MAP_ROUTES[mapID] then
        platformElapsed = 0.45
        platformPoller:Show()
        UpdatePlatformProximity()
    else
        platformPoller:Hide()
        HidePlatformBanner(false)
    end
end

----------------------------------------------------------------------
--  飞艇管理员头顶姓名板航线标牌 + 鼠标提示航线说明（零污染弱表托管）
----------------------------------------------------------------------
local function HideNameplateBadge(np)
    local b = np and npBadgeMap[np]
    if b then b:Hide() end
end

local function HideAllNameplateBadges()
    for _, b in ipairs(npBadgeList) do
        b:Hide()
    end
end

local function UpdateTransportNameplate(unit)
    if not (unit and _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit) then return end
    local okNP, np = pcall(_G.C_NamePlate.GetNamePlateForUnit, unit)
    if not (okNP and np) or (np.IsForbidden and np:IsForbidden()) then return end
    local db = mod:GetDB()
    if not (mod._active and db.showTransportNameplates ~= false) then
        HideNameplateBadge(np)
        return
    end
    local info = ResolveTransportNPC(unit)
    if not info then
        HideNameplateBadge(np)
        return
    end

    if not hookedNP[np] and np.HookScript then
        hookedNP[np] = true
        pcall(np.HookScript, np, "OnHide", HideNameplateBadge)
    end

    local b = npBadgeMap[np]
    if not b then
        b = CreateFrame("Frame", nil, _G.UIParent)
        b:SetFrameStrata("LOW")
        b:SetFrameLevel(20)
        b:EnableMouse(false)

        local txt = b:CreateFontString(nil, "OVERLAY")
        ST.ApplyText(txt, 12, 0.96, 0.97, 0.99, 1)
        txt:SetPoint("CENTER", b, "CENTER", 0, -1)
        txt:SetJustifyH("CENTER")
        txt:SetWordWrap(false)

        b._txt = txt
        npBadgeMap[np] = b
        npBadgeList[#npBadgeList + 1] = b
    end

    local cr, cg, cb = info.color[1], info.color[2], info.color[3]
    local hex = F.RGBToHex(cr, cg, cb)
    ST.ApplyText(b._txt, 12, 0.96, 0.97, 0.99, 1)
    b._txt:SetText(string_format("|cff9aa4b2%s|r |cff556070·|r 前往 |cff%s%s|r", info.kind, hex, info.shortDest or info.dest))
    b:Show()
    local tw = F.PlainNumber(b._txt:GetStringWidth(), 96) or 96
    b:SetSize(math_max(106, math_floor(tw + 26)), 24)
    b:ClearAllPoints()
    b:SetPoint("BOTTOM", np, "TOP", 0, 22)
    F.Theme.PaintPrettyCardOverlay(b, cr, cg, cb, 14, {
        radius = 6,
        alpha = 0.86,
        haloAlpha = 0.15,
        haloSpread = 10,
        headerTopAlpha = 0.28,
        headerBottomAlpha = 0.00,
    })
end

local function SweepTransportNameplates()
    HideAllNameplateBadges()
    if not (mod._active and mod:GetDB().showTransportNameplates ~= false and _G.C_NamePlate and _G.C_NamePlate.GetNamePlates) then
        return
    end
    local ok, plates = pcall(_G.C_NamePlate.GetNamePlates)
    if not ok or type(plates) ~= "table" then return end
    for _, np in ipairs(plates) do
        if np and not (np.IsForbidden and np:IsForbidden()) then
            local u = F.PlainString(np.namePlateUnitToken or (np.UnitFrame and np.UnitFrame.unit), nil)
            if u then UpdateTransportNameplate(u) end
        end
    end
end

local function AppendTransportTooltip(tip)
    if not (mod._active and tip and tip.GetUnit) then return end
    local ok, _, unit = pcall(tip.GetUnit, tip)
    unit = ok and F.PlainString(unit, nil) or nil
    if not unit then return end
    local info = ResolveTransportNPC(unit)
    if not info then return end
    local cr, cg, cb = info.color[1], info.color[2], info.color[3]
    local hex = F.RGBToHex(cr, cg, cb)
    tip:AddLine(string_format("|cff70e6ebkkowoUI 航线：|r本泊位%s前往 |cff%s%s|r", info.kind, hex, info.dest), 0.92, 0.95, 0.98)
end

local function InstallTransportTooltipHook()
    if hookedTooltip then return end
    hookedTooltip = true
    if _G.TooltipDataProcessor and _G.TooltipDataProcessor.AddTooltipPostCall
        and _G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Unit then
        _G.TooltipDataProcessor.AddTooltipPostCall(_G.Enum.TooltipDataType.Unit, function(tip)
            if tip == _G.GameTooltip then AppendTransportTooltip(tip) end
        end)
    elseif _G.GameTooltip and _G.GameTooltip.HookScript then
        _G.GameTooltip:HookScript("OnTooltipSetUnit", AppendTransportTooltip)
    end
end

-- 独立轻量轮询帧：仅在 WorldMapFrame 显示时以 0.08s 间隔刷新底部悬停区域等级
local hoverPoller = CreateFrame("Frame")
hoverPoller:Hide()
local hoverElapsed = 0
hoverPoller:SetScript("OnUpdate", function(_, elapsed)
    hoverElapsed = hoverElapsed + elapsed
    if hoverElapsed < 0.08 then return end
    hoverElapsed = 0
    if not (_G.WorldMapFrame and _G.WorldMapFrame:IsShown()) then
        hoverPoller:Hide()
        return
    end
    UpdateBottomHoverBar()
end)

function mod:OnEnable()
    local wmf = _G.WorldMapFrame
    if wmf and not hookedMap then
        hookedMap = true
        wmf:HookScript("OnShow", function()
            if not mod._active then return end
            hoverPoller:Show()
            ScheduleRedraw()
        end)
        wmf:HookScript("OnHide", function()
            hoverPoller:Hide()
            ResetHoverCache()
            if bottomBar then bottomBar:Hide() end
        end)
        if type(wmf.OnMapChanged) == "function" then
            _G.hooksecurefunc(wmf, "OnMapChanged", ScheduleRedraw)
        end
    end
    InstallTransportTooltipHook()

    self:RegisterEvent("PLAYER_LEVEL_UP", ScheduleRedraw)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        SyncPlatformZoneWatch()
        C_Timer.After(0.3, function()
            if mod._active then
                SyncPlatformZoneWatch()
                SweepTransportNameplates()
            end
        end)
    end)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", SyncPlatformZoneWatch)
    self:RegisterEvent("ZONE_CHANGED", SyncPlatformZoneWatch)
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, _, unit)
        if mod._active and unit then UpdateTransportNameplate(unit) end
    end)
    self:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, _, unit)
        unit = F.PlainString(unit, nil)
        if unit and _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit then
            local ok, np = pcall(_G.C_NamePlate.GetNamePlateForUnit, unit)
            if ok and np and not (np.IsForbidden and np:IsForbidden()) then
                HideNameplateBadge(np)
            end
        end
    end)

    if wmf and wmf:IsShown() then
        hoverPoller:Show()
        ScheduleRedraw()
    end
    SyncPlatformZoneWatch()
    SweepTransportNameplates()
end

function mod:OnDisable()
    hoverPoller:Hide()
    platformPoller:Hide()
    HideAllLabels()
    HideAllRoutePins()
    HideAllNameplateBadges()
    if bottomBar then bottomBar:Hide() end
    HidePlatformBanner(true)
end

function mod:OnThemeChanged()
    if bottomBar then
        ST.ApplyText(bottomBar.text, 12, 0.95, 0.96, 0.98, 1)
        PaintBottomBarOverlay()
    end
    lastBannerKey = nil
    UpdatePlatformProximity()
    SweepTransportNameplates()
    ScheduleRedraw()
end

-- /zlmap 微调命令：兼容原用法
_G.SLASH_KKOWOUIZLMAP1 = "/zlmap"
_G.SlashCmdList.KKOWOUIZLMAP = function(msg)
    local db = mod:GetDB()
    db.customOffsets = db.customOffsets or {}
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "reset" then
        db.customOffsets = {}
        F.Print("已重置全部自定义地图区域标签偏移（恢复 21 个内置精调坐标）。")
        ScheduleRedraw()
        return
    end
    local idStr, xStr, yStr = msg:match("^(%d+)%s+([%-%.%d]+)%s+([%-%.%d]+)$")
    local id, x, y = tonumber(idStr), tonumber(xStr), tonumber(yStr)
    if id and x and y then
        db.customOffsets[id] = { x = x, y = y }
        F.Print(string_format("已更新区域 %d 偏移：x=%.3f, y=%.3f", id, x, y))
        ScheduleRedraw()
    else
        F.Print("用法：/zlmap <mapID> <x偏移> <y偏移>（例如 /zlmap 1442 0.02 -0.025），或 /zlmap reset 重置。")
    end
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "显示大陆常驻区域标签",
        tooltip = "在卡利姆多/东部王国大陆地图上直接标注各区域名称与等级（已内置 21 个精调偏移）。",
        getValue = function() return db.showLabels ~= false end,
        setValue = function(v) db.showLabels = v == true; ScheduleRedraw() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "区域地图分离式飞艇 / 航船航线标签",
        tooltip = "打开杜隆塔尔、提瑞斯法、荆棘谷、黑海岸、湿地等区域地图时，用不重叠的圆角胶囊与引线清晰标出每班飞艇与航船的目的地。",
        getValue = function() return db.showTransportMap ~= false end,
        setValue = function(v) db.showTransportMap = v == true; ScheduleRedraw() end,
    }, {
        type = "toggle",
        text = "站上飞艇塔/码头弹出当前泊位指引",
        tooltip = "靠近飞艇塔或码头时在顶部弹出圆角胶囊，即时标出当前泊位与对侧泊位分别前往何地（离开自动隐藏，其它区域零开销）。",
        getValue = function() return db.showTransportBanner ~= false end,
        setValue = function(v) db.showTransportBanner = v == true; SyncPlatformZoneWatch() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "飞艇管理员头顶姓名板显示目的地标牌",
        tooltip = "靠近弗雷萨、斯努尔克、萨匹塔等飞艇管理员时，直接在其姓名板上方显示前往目的地的圆角胶囊（同时补充鼠标提示）。",
        getValue = function() return db.showTransportNameplates ~= false end,
        setValue = function(v) db.showTransportNameplates = v == true; SweepTransportNameplates() end,
    }, {
        type = "toggle",
        text = "地图底部悬停区域等级条",
        tooltip = "鼠标滑过世界地图任意区域时，在地图底部显示该区域名称与等级区间。",
        getValue = function() return db.showBottomBar ~= false end,
        setValue = function(v) db.showBottomBar = v == true; ScheduleRedraw() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "标签包含区域名称与难度着色",
        getValue = function() return db.showName ~= false end,
        setValue = function(v) db.showName = v == true; db.colorByDifficulty = v == true; ScheduleRedraw() end,
    }, {
        type = "slider",
        text = "标签字号",
        min = 9, max = 16, step = 1,
        getValue = function() return db.fontSize or 11 end,
        setValue = function(v) db.fontSize = v; ScheduleRedraw() end,
    })
    y = y - h
    return y
end
