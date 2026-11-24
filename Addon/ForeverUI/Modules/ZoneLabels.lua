----------------------------------------------------------------------
--  ForeverUI — Modules/ZoneLabels.lua
--  世界地图零污染区域等级标签：
--    1) 大陆地图各子区域常驻名称 + 等级区间（内置 21 个已精调偏移）
--    2) 世界地图底部鼠标悬停区域等级条（现代暗底浮胶囊）
--    3) /zlmap 微调命令：/zlmap <mapID> <x> <y> 或 /zlmap reset
--  • 绝不向 WorldMapFrame 写字段，绝不挂钩地图 Pin 方法，延迟一帧重绘零污染
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pcall, tonumber, tostring, type = ipairs, pcall, tonumber, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local mod = F.RegisterModule("zoneLabels", {
    title = "地图区域等级",
    desc = "在大陆地图上为每个区域标注名称与等级区间，并在地图底部显示鼠标悬停区域的等级（零污染，与 Leatrix_Maps 兼容）。",
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
    },
})

local overlayLayer = nil
local bottomBar = nil
local labelPool = {}
local hookedMap = false

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
    local lvl = _G.UnitLevel("player") or 1
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

local function AcquireLabel(idx)
    local fs = labelPool[idx]
    if not fs then
        fs = overlayLayer:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("CENTER")
        labelPool[idx] = fs
    end
    return fs
end

-- 鼠标静止时（地图编号与归一化坐标都没变）跳过整套查询/排版：轮询频率 12.5Hz，地图开着时大部分时间鼠标并不动
local lastHoverMap, lastHoverX, lastHoverY, lastHoverText = nil, nil, nil, nil

local function ResetHoverCache()
    lastHoverMap, lastHoverX, lastHoverY, lastHoverText = nil, nil, nil, nil
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
    if mapID == lastHoverMap and lastHoverX and math.abs(cx - lastHoverX) < 0.001 and math.abs(cy - lastHoverY) < 0.001 then
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
        local tw = F.PlainNumber(bottomBar.text:GetStringWidth(), 100)
        bottomBar:SetSize(tw + 20, 22)
        bottomBar:Show()
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
        bottomBar:SetSize(140, 22)
        bottomBar:SetPoint("BOTTOM", sc, "BOTTOM", 0, 14)
        bottomBar:SetFrameLevel(sc:GetFrameLevel() + 50)
        bottomBar:EnableMouse(false)
        F.Theme.StylePanel(bottomBar, 0.84, 0.72)
        bottomBar.text = bottomBar:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(bottomBar.text, 12, "", 0.94, 0.95, 0.97, 1)
        bottomBar.text:SetPoint("CENTER", 0, 0)
        bottomBar:Hide()
    end
    return true
end

local function RedrawMapLabels()
    if not mod._active then
        HideAllLabels()
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

    local db = mod:GetDB()
    if not db.showLabels then
        UpdateBottomHoverBar()
        return
    end

    local mapID = wmf.GetMapID and wmf:GetMapID()
    if not (mapID and _G.C_Map and _G.C_Map.GetMapChildrenInfo and _G.C_Map.GetMapRectOnMap) then
        return
    end

    local mapInfo = _G.C_Map.GetMapInfo and _G.C_Map.GetMapInfo(mapID)
    if not (mapInfo and mapInfo.mapType == 2) then
        UpdateBottomHoverBar()
        return
    end

    local children = _G.C_Map.GetMapChildrenInfo(mapID, 3, true)
    if type(children) ~= "table" then
        return
    end

    local cw = F.PlainNumber(overlayLayer:GetWidth(), 0)
    local ch = F.PlainNumber(overlayLayer:GetHeight(), 0)
    if cw <= 10 or ch <= 10 then
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
            if bottomBar then bottomBar:Hide() end
        end)
        if type(wmf.OnMapChanged) == "function" then
            _G.hooksecurefunc(wmf, "OnMapChanged", ScheduleRedraw)
        end
    end
    self:RegisterEvent("PLAYER_LEVEL_UP", ScheduleRedraw)
    if wmf and wmf:IsShown() then
        hoverPoller:Show()
        ScheduleRedraw()
    end
end

function mod:OnDisable()
    hoverPoller:Hide()
    HideAllLabels()
    if bottomBar then bottomBar:Hide() end
end

function mod:OnThemeChanged()
    if bottomBar then F.Theme.StylePanel(bottomBar, 0.84, 0.72) end
    ScheduleRedraw()
end

-- /zlmap 微调命令：兼容原用法
_G.SLASH_FOREVERUIZLMAP1 = "/zlmap"
_G.SlashCmdList.FOREVERUIZLMAP = function(msg)
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

function mod:BuildOptions(W, parent, y, enableSlot, blank)
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
        text = "标签包含区域名称",
        getValue = function() return db.showName ~= false end,
        setValue = function(v) db.showName = v == true; ScheduleRedraw() end,
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
        text = "按难度着色",
        getValue = function() return db.colorByDifficulty ~= false end,
        setValue = function(v) db.colorByDifficulty = v == true; ScheduleRedraw() end,
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
