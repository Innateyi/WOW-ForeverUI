----------------------------------------------------------------------
--  kkowoUI — Modules/WaypointAutoTrack.lua
--  零污染、零快捷键冲突、单标记去重的 3D 光柱 + Polestar 统一导航联动：
--    • 绝不拦截大地图 Ctrl+左键 / Shift+左键：100% 保留暴雪原生交互
--      （Ctrl+左键放点/移除标记、Shift+左键在聊天中分享标记）
--    • 大地图 Ctrl+左键放点或点击聊天框坐标链接 → 自动开启 EUI 3D 光柱，
--      并同步驱动 Polestar 跨图最短路线（绿虚线 + 3D 箭头）；Ctrl+左键移除时同步取消
--    • Polestar 指南步骤 / Shift+Alt 地图规划 / /way → 自动同步 EUI 3D 光柱
--    • 单标去重：当暴雪黄菱形标记与 Polestar 绿圆目标点重合时，通过 Polestar 官方
--      Pins.SetLayerVisible("nav.target", false) 隐藏重复绿圆，只保留一个标记 + 绿色路线
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local GetTime = GetTime
local ipairs, math_abs, math_atan2, math_ceil, math_cos, math_floor, math_max, math_min, math_pi, math_sin, math_sqrt, pcall, tonumber, tostring, type =
    ipairs, math.abs, math.atan2, math.ceil, math.cos, math.floor, math.max, math.min, math.pi, math.sin, math.sqrt, pcall, tonumber, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown

local mod = F.RegisterModule("waypointAutoTrack", {
    title = "地图光柱联动",
    desc = "大地图插旗同步显示渐变光柱与北极星路线，自动隐藏重合绿标。",
    group = "quest",
    order = 66,
    yieldIfLoaded = "WaypointUI",
    defaults = {
        enabled = true,
        autoTrackPlacedPin = true,
        syncPinToPolestar = true,
        syncPolestarBeam = true,
        onlyManualOrQuestBeam = true, -- 默认仅手动插旗或点击任务标题左侧追踪钮时亮光柱（屏蔽北极星常规指南/附近NPC）
        shiftClickPlacePin = true,    -- 大地图空地 Shift+左键直接插旗，点黄标仍分享到聊天
        beamSound = true,             -- 手动大地图插旗时播放清脆落点提示音
        dedupPolestarPin = true,
        autoTrackChatLink = true,
        beamStyle = "kkowo",          -- "kkowo"（渐变光柱）| "eui"（EUI 原生光柱）
        beamColorMode = "glacier",    -- "glacier" | "class" | "brand" | "gold" | "violet"
        beamHeight = 140,
        medallionSize = 42,
        beamAnim = true,
        savedEUIInGameNav = nil,
    },
})

local FOLLOW_OWNER = "kkowoUI"
local PIN_EPS = 0.0008
local DEDUP_EPS = 0.015
local SHIFT_SHARE_DIST = 0.025

local setItemRefHooked = false
local insertLinkHooked = false
local worldMapShareHooked = false
local worldMapShareWaiter = nil
local minimapPinHooked = false
local polestarFollowed = false
local userWpQueued = false
local polestarSyncQueued = false
local suppressOwnPinEvent = false
local polestarPinHidden = false
local manualNavActive = false
local ignoreNextPolestarUntil = 0
local lastOpenedLinkAt = 0
local openingChatLink = false
local polestarPin = nil       -- { map, x, y } 当前由本模块代 Polestar 同步写入的暴雪地图钉
local manualPin = nil         -- { map, x, y } 玩家手动在大地图/聊天链接放置的地图钉
local lastManualPinIntentAt = 0
local lastPinSoundAt = -10
local wpPendingRevealAnim = false
local worldMapHideHooked = false
local RefreshBeam -- 前向声明

local function PlayPinPlaceSound()
    if mod:GetDB().beamSound == false then return end
    local now = GetTime()
    if (now - lastPinSoundAt) < 0.25 then return end
    lastPinSoundAt = now
    if type(_G.PlaySound) ~= "function" then return end
    local kit = (_G.SOUNDKIT and (_G.SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON or _G.SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)) or 170270
    pcall(_G.PlaySound, kit, "Master")
end

local function GetPolestarAPI()
    local ps = _G.Polestar
    local api = type(ps) == "table" and type(ps.Nav) == "table" and ps.Nav.API
    return type(api) == "table" and api or nil
end

local function SetPolestarTargetPinHidden(hide)
    hide = hide == true
    if hide == polestarPinHidden then
        return
    end
    local ps = _G.Polestar
    local pins = type(ps) == "table" and ps.Pins
    if type(pins) == "table" and type(pins.SetLayerVisible) == "function" then
        pcall(pins.SetLayerVisible, "nav.target", not hide)
        polestarPinHidden = hide
    elseif not hide then
        polestarPinHidden = false
    end
end

local function MakeUiMapPoint(mapID, x, y)
    local UMP = _G.UiMapPoint
    if UMP and type(UMP.CreateFromCoordinates) == "function" then
        local ok, pt = pcall(UMP.CreateFromCoordinates, mapID, x, y)
        if ok and pt then return pt end
    end
    local CreateVec = _G.CreateVector2D
    if CreateVec and UMP and type(UMP.CreateFromVector2D) == "function" then
        local okV, vec = pcall(CreateVec, x, y)
        if okV and vec then
            local okP, pt = pcall(UMP.CreateFromVector2D, mapID, vec)
            if okP and pt then return pt end
        end
    end
    return nil
end

local function GetCurrentUserWaypointCoords()
    local CM = _G.C_Map
    if not (CM and type(CM.HasUserWaypoint) == "function" and type(CM.GetUserWaypoint) == "function") then
        return nil
    end
    local okH, has = pcall(CM.HasUserWaypoint)
    if not (okH and has == true) then
        return nil
    end
    local okG, wp = pcall(CM.GetUserWaypoint)
    if not (okG and type(wp) == "table" and wp.uiMapID and wp.position) then
        return nil
    end
    local x, y = wp.position.x, wp.position.y
    if wp.position.GetXY then
        local okXY, gx, gy = pcall(wp.position.GetXY, wp.position)
        if okXY then x, y = gx, gy end
    end
    x = F.PlainNumber(x, nil)
    y = F.PlainNumber(y, nil)
    local m = F.PlainNumber(wp.uiMapID, nil)
    if not (m and x and y) then return nil end
    return m, x, y
end

local function IsCurrentPinPolestarOwned()
    if not polestarPin then return false end
    local m, x, y = GetCurrentUserWaypointCoords()
    if not m then return false end
    return m == polestarPin.map
        and math_abs(x - polestarPin.x) < PIN_EPS
        and math_abs(y - polestarPin.y) < PIN_EPS
end

local function EnsureNavigationCVar()
    if InCombatLockdown and InCombatLockdown() then return end
    local CCV = _G.C_CVar
    if CCV and type(CCV.GetCVar) == "function" and type(CCV.SetCVar) == "function" then
        local ok, cur = pcall(CCV.GetCVar, "showInGameNavigation")
        if ok and F.PlainString(cur, nil) == "0" then
            pcall(CCV.SetCVar, "showInGameNavigation", "1")
        end
    end
end

local function GetMapDisplayName(mapID)
    local CM = _G.C_Map
    if CM and type(CM.GetMapInfo) == "function" then
        local ok, info = pcall(CM.GetMapInfo, mapID)
        local name = ok and type(info) == "table" and F.PlainString(info.name, nil)
        if name and name ~= "" then
            return name
        end
    end
    return "地图标记"
end

-- 当暴雪黄菱形标记与 Polestar 最终目标点位于同一位置时，隐藏 Polestar 重复的绿色圆标（保留绿色虚线与 3D 箭头）
local function UpdatePolestarPinDedup(target, wpMap, wpX, wpY)
    if not (mod._active and mod:GetDB().dedupPolestarPin ~= false) then
        SetPolestarTargetPinHidden(false)
        return
    end
    if not wpMap then
        wpMap, wpX, wpY = GetCurrentUserWaypointCoords()
    end
    if not wpMap then
        SetPolestarTargetPinHidden(false)
        return
    end
    if not target then
        local api = GetPolestarAPI()
        if api and type(api.Target) == "function" then
            local okT, t = pcall(api.Target)
            if okT and type(t) == "table" then target = t end
        end
    end
    if type(target) ~= "table" then
        SetPolestarTargetPinHidden(false)
        return
    end
    local tm = F.PlainNumber(target.map, nil)
    local tx = F.PlainNumber(target.x, nil)
    local ty = F.PlainNumber(target.y, nil)
    if not (tm and tx and ty) then
        SetPolestarTargetPinHidden(false)
        return
    end
    if tx > 1 or ty > 1 then
        tx = tx / 100
        ty = ty / 100
    end
    local sameSpot = (tm == wpMap) and (math_abs(tx - wpX) < DEDUP_EPS) and (math_abs(ty - wpY) < DEDUP_EPS)
    SetPolestarTargetPinHidden(sameSpot)
end

local function ClearPolestarPinIfOwned()
    if not polestarPin then return end
    local owned = IsCurrentPinPolestarOwned()
    polestarPin = nil
    if not owned then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local CM = _G.C_Map
    local ST = _G.C_SuperTrack
    if ST and type(ST.IsSuperTrackingUserWaypoint) == "function" and type(ST.SetSuperTrackedUserWaypoint) == "function" then
        local ok, isUT = pcall(ST.IsSuperTrackingUserWaypoint)
        if ok and isUT == true then
            pcall(ST.SetSuperTrackedUserWaypoint, false)
        end
    end
    if CM and type(CM.ClearUserWaypoint) == "function" then
        suppressOwnPinEvent = true
        local ok = pcall(CM.ClearUserWaypoint)
        if not ok then suppressOwnPinEvent = false end
    end
end

-- ---------------------------------------------------------------------------
-- 1) 玩家通过暴雪原生 Ctrl+左键 / 聊天坐标链接 放置或移除地图标记
-- ---------------------------------------------------------------------------
local function HandleUserWaypointChanged()
    userWpQueued = false
    if not mod._active then return end
    if InCombatLockdown and InCombatLockdown() then return end

    local db = mod:GetDB()
    local wpMap, wpX, wpY = GetCurrentUserWaypointCoords()
    local ST = _G.C_SuperTrack
    local api = GetPolestarAPI()

    if wpMap then
        -- 区分玩家手动插旗（大地图 Ctrl/Shift+左键、聊天坐标链接）与北极星后台自动同步写入的标记
        local now = GetTime()
        local isManual = ((now - lastManualPinIntentAt) <= 0.85)
            or (_G.WorldMapFrame and _G.WorldMapFrame.IsShown and _G.WorldMapFrame:IsShown())
            or (manualPin ~= nil and manualPin.map == wpMap and math_abs(manualPin.x - wpX) < PIN_EPS and math_abs(manualPin.y - wpY) < PIN_EPS)
        if not isManual and api and type(api.Target) == "function" then
            local okT, pt = pcall(api.Target)
            if okT and type(pt) == "table" then
                local tm = F.PlainNumber(pt.map, nil)
                local tx = F.PlainNumber(pt.x, nil)
                local ty = F.PlainNumber(pt.y, nil)
                if tx and ty and (tx > 1 or ty > 1) then tx, ty = tx / 100, ty / 100 end
                if not (tm == wpMap and tx and ty and math_abs(tx - wpX) < DEDUP_EPS and math_abs(ty - wpY) < DEDUP_EPS) then
                    isManual = true
                end
            else
                isManual = true
            end
        end

        if isManual then
            manualPin = { map = wpMap, x = wpX, y = wpY }
            polestarPin = nil
            wpPendingRevealAnim = true
            PlayPinPlaceSound()
            if db.autoTrackPlacedPin ~= false and ST and type(ST.SetSuperTrackedUserWaypoint) == "function" then
                if type(ST.SetSuperTrackedQuestID) == "function" then
                    pcall(ST.SetSuperTrackedQuestID, 0)
                end
                pcall(ST.SetSuperTrackedUserWaypoint, true)
            end
            if db.syncPinToPolestar ~= false and api and type(api.Navigate) == "function" then
                local label = string_format("%s %.1f, %.1f", GetMapDisplayName(wpMap), wpX * 100, wpY * 100)
                local okNav, started = pcall(api.Navigate, FOLLOW_OWNER, wpMap, wpX, wpY, label)
                if okNav and started then
                    manualNavActive = true
                    SetPolestarTargetPinHidden(db.dedupPolestarPin ~= false)
                else
                    UpdatePolestarPinDedup(nil, wpMap, wpX, wpY)
                end
            else
                UpdatePolestarPinDedup(nil, wpMap, wpX, wpY)
            end
        else
            manualPin = nil
            UpdatePolestarPinDedup(nil, wpMap, wpX, wpY)
        end
        if RefreshBeam then RefreshBeam(isManual) end
    else
        -- 玩家用暴雪原生 Ctrl+左键 移除了地图标记：同步清除 3D 光柱与对应的 Polestar 路线
        manualPin = nil
        if ST and type(ST.IsSuperTrackingUserWaypoint) == "function" and type(ST.SetSuperTrackedUserWaypoint) == "function" then
            local okS, isUT = pcall(ST.IsSuperTrackingUserWaypoint)
            if okS and isUT == true then
                pcall(ST.SetSuperTrackedUserWaypoint, false)
            end
        end
        if manualNavActive then
            manualNavActive = false
            ignoreNextPolestarUntil = GetTime() + 0.6
            if api and type(api.Cancel) == "function" then
                pcall(api.Cancel, FOLLOW_OWNER)
            end
        elseif polestarPin ~= nil then
            polestarPin = nil
            ignoreNextPolestarUntil = GetTime() + 0.6
            if api and type(api.Dismiss) == "function" then
                pcall(api.Dismiss, FOLLOW_OWNER)
            end
        end
        SetPolestarTargetPinHidden(false)
        if RefreshBeam then RefreshBeam(false) end
    end
end

local function QueueUserWaypointChanged()
    if userWpQueued or not mod._active then return end
    userWpQueued = true
    -- 延迟 1 帧调用，绝不在暴雪同步事件栈里写 C_SuperTrack 状态（避免污染）
    C_Timer.After(0, HandleUserWaypointChanged)
end

-- ---------------------------------------------------------------------------
-- 2) Polestar 指南 / Shift+Alt 地图规划 / /way 实时联动 EUI 3D 光柱
-- ---------------------------------------------------------------------------
local function HandlePolestarTargetChanged()
    polestarSyncQueued = false
    if not mod._active then return end
    if InCombatLockdown and InCombatLockdown() then return end

    local api = GetPolestarAPI()
    if not (api and type(api.Target) == "function") then
        SetPolestarTargetPinHidden(false)
        return
    end

    -- 若当前 Polestar 目标正是由我们代玩家手动 Ctrl+左键 发起的导航，只维护去重即可，绝不反向改写暴雪标记
    if type(api.Active) == "function" then
        local okA, isActive, owner = pcall(api.Active)
        if okA and isActive and owner == FOLLOW_OWNER then
            local okT, target = pcall(api.Target)
            UpdatePolestarPinDedup(okT and target or nil)
            return
        end
    end
    manualNavActive = false

    local okT, target = pcall(api.Target)
    if not okT or type(target) ~= "table" then
        ClearPolestarPinIfOwned()
        SetPolestarTargetPinHidden(false)
        return
    end

    -- 玩家刚按 Ctrl+左键手动移除标记后的短暂冷却期，不立刻弹回新黄菱形
    if GetTime() < ignoreNextPolestarUntil then
        UpdatePolestarPinDedup(target)
        return
    end

    local db = mod:GetDB()
    if db.onlyManualOrQuestBeam ~= false or db.syncPolestarBeam == false then
        ClearPolestarPinIfOwned()
        UpdatePolestarPinDedup(target)
        if RefreshBeam then RefreshBeam(false) end
        return
    end

    -- 多段跨图路线把 3D 光柱放到当前航段终点（鸟点/港口/传送门），直达段放在目标点
    local leg = (type(target.next) == "table" and target.next.map and target.next.x and target.next.y)
        and target.next or target
    local mapID = F.PlainNumber(leg.map, nil)
    local x = F.PlainNumber(leg.x, nil)
    local y = F.PlainNumber(leg.y, nil)
    if not (mapID and x and y) then
        ClearPolestarPinIfOwned()
        SetPolestarTargetPinHidden(false)
        return
    end
    if x > 1 or y > 1 then
        x = x / 100
        y = y / 100
    end
    if x < 0 or x > 1 or y < 0 or y > 1 then
        return
    end

    local CM = _G.C_Map
    local ST = _G.C_SuperTrack
    if not (CM and type(CM.SetUserWaypoint) == "function" and ST and type(ST.SetSuperTrackedUserWaypoint) == "function") then
        return
    end
    if type(CM.CanSetUserWaypointOnMap) == "function" then
        local okCan, can = pcall(CM.CanSetUserWaypointOnMap, mapID)
        if not (okCan and can == true) then
            ClearPolestarPinIfOwned()
            SetPolestarTargetPinHidden(false)
            return
        end
    end

    local curM, curX, curY = GetCurrentUserWaypointCoords()
    if curM == mapID and math_abs(curX - x) < PIN_EPS and math_abs(curY - y) < PIN_EPS then
        polestarPin = { map = mapID, x = x, y = y }
        local okS, isUT = pcall(ST.IsSuperTrackingUserWaypoint)
        if not (okS and isUT == true) then
            pcall(ST.SetSuperTrackedUserWaypoint, true)
        end
        UpdatePolestarPinDedup(target, mapID, x, y)
        return
    end

    local pt = MakeUiMapPoint(mapID, x, y)
    if not pt then return end
    suppressOwnPinEvent = true
    local okSet = pcall(CM.SetUserWaypoint, pt)
    if okSet then
        polestarPin = { map = mapID, x = x, y = y }
        pcall(ST.SetSuperTrackedUserWaypoint, true)
        UpdatePolestarPinDedup(target, mapID, x, y)
    else
        suppressOwnPinEvent = false
    end
end

local function QueuePolestarSync()
    if polestarSyncQueued or not mod._active then return end
    polestarSyncQueued = true
    C_Timer.After(0, HandlePolestarTargetChanged)
end

local function EnsurePolestarFollower()
    if polestarFollowed or not mod._active then return end
    local api = GetPolestarAPI()
    if api and type(api.Follow) == "function" then
        local ok = pcall(api.Follow, FOLLOW_OWNER, QueuePolestarSync, { pin = true })
        if ok then
            polestarFollowed = true
            QueuePolestarSync()
        end
    end
end

local function DetachPolestarFollower()
    local api = GetPolestarAPI()
    if manualNavActive and api and type(api.Cancel) == "function" then
        pcall(api.Cancel, FOLLOW_OWNER)
    end
    manualNavActive = false
    if polestarFollowed then
        polestarFollowed = false
        if api and type(api.Unfollow) == "function" then
            pcall(api.Unfollow, FOLLOW_OWNER)
        end
    end
    ClearPolestarPinIfOwned()
    SetPolestarTargetPinHidden(false)
end

-- ---------------------------------------------------------------------------
-- 3) Shift + 左键点黄菱形：未开聊天框时自动打开聊天框并直接插入 [地图标记] 链接，
--    同时防止靠近黄菱形的 Shift+左键被 Polestar 当成空地点击而复制出新坐标点
-- ---------------------------------------------------------------------------
local function GetActiveChatEditBox()
    local fn = (_G.ChatFrameUtil and _G.ChatFrameUtil.GetActiveWindow) or _G.ChatEdit_GetActiveWindow
    if type(fn) ~= "function" then return nil end
    local ok, box = pcall(fn)
    return ok and box or nil
end

local function OpenChatWithWaypointLink(link)
    if openingChatLink then return end
    local plain = F.PlainString(link, nil)
    if not plain or plain == "" then return end
    local now = GetTime()
    if (now - lastOpenedLinkAt) < 0.15 then return end
    lastOpenedLinkAt = now
    openingChatLink = true
    local box = GetActiveChatEditBox()
    if box and type(box.Insert) == "function" then
        pcall(box.Insert, box, plain)
    else
        local openChat = (_G.ChatFrameUtil and _G.ChatFrameUtil.OpenChat) or _G.ChatFrame_OpenChat
        if type(openChat) == "function" then
            pcall(openChat, plain, _G.DEFAULT_CHAT_FRAME)
        end
    end
    openingChatLink = false
end

local function OnInsertLinkHook(text)
    if openingChatLink or not mod._active then return end
    local plain = F.PlainString(text, nil)
    if not plain or not plain:find("|Hworldmap:", 1, true) then return end
    -- 若聊天输入框本就开着，暴雪原生 InsertLink 已经写入成功，无需干预；
    -- 若聊天框未打开，则自动打开聊天输入框并直接把 [地图标记] 贴进去
    if GetActiveChatEditBox() then return end
    C_Timer.After(0, function()
        if mod._active and not GetActiveChatEditBox() then
            OpenChatWithWaypointLink(plain)
        end
    end)
end

local function EnsureInsertLinkHook()
    if insertLinkHooked or type(_G.hooksecurefunc) ~= "function" then return end
    insertLinkHooked = true
    if _G.ChatFrameUtil and type(_G.ChatFrameUtil.InsertLink) == "function" then
        _G.hooksecurefunc(_G.ChatFrameUtil, "InsertLink", OnInsertLinkHook)
    elseif type(_G.ChatEdit_InsertLink) == "function" then
        _G.hooksecurefunc("ChatEdit_InsertLink", OnInsertLinkHook)
    end
end

local function OnWorldMapCanvasClick(canvas, button)
    if not mod._active or button ~= "LeftButton" then return false end
    local shift = _G.IsShiftKeyDown and _G.IsShiftKeyDown() or false
    local ctrl = _G.IsControlKeyDown and _G.IsControlKeyDown() or false
    local alt = _G.IsAltKeyDown and _G.IsAltKeyDown() or false

    -- 暴雪原生 Ctrl+左键放点/移除：仅记录玩家手动意图，绝不拦截暴雪原生处理
    if ctrl and not shift and not alt then
        lastManualPinIntentAt = GetTime()
        return false
    end

    if not shift or ctrl or alt then
        return false
    end
    local mapID = canvas and canvas.GetMapID and F.PlainNumber(canvas:GetMapID(), nil)
    if not mapID then return false end
    local nx, ny = nil, nil
    if canvas and canvas.GetNormalizedCursorPosition then
        local okC, cx, cy = pcall(canvas.GetNormalizedCursorPosition, canvas)
        if okC then
            nx = F.PlainNumber(cx, nil)
            ny = F.PlainNumber(cy, nil)
        end
    end
    if not (nx and ny) or nx < 0 or nx > 1 or ny < 0 or ny > 1 then return false end

    -- 1) 点在现有黄菱形附近：维持原 Shift+左键分享 [地图标记] 到聊天框
    local wpMap, wpX, wpY = GetCurrentUserWaypointCoords()
    if wpMap == mapID and math_abs(nx - wpX) <= SHIFT_SHARE_DIST and math_abs(ny - wpY) <= SHIFT_SHARE_DIST then
        local CM = _G.C_Map
        local okL, link = CM and type(CM.GetUserWaypointHyperlink) == "function" and pcall(CM.GetUserWaypointHyperlink)
        if okL and F.PlainString(link, nil) then
            C_Timer.After(0, function()
                if mod._active then
                    OpenChatWithWaypointLink(link)
                end
            end)
            return true
        end
    end

    -- 2) 点在大地图空地：直接放置/移动暴雪地图标记并播放落点音效（同步点亮 3D 光柱）
    if mod:GetDB().shiftClickPlacePin == false then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    local CM = _G.C_Map
    if not (CM and type(CM.SetUserWaypoint) == "function") then return false end
    if type(CM.CanSetUserWaypointOnMap) == "function" then
        local okCan, can = pcall(CM.CanSetUserWaypointOnMap, mapID)
        if not (okCan and can == true) then return false end
    end
    local pt = MakeUiMapPoint(mapID, nx, ny)
    if not pt then return false end
    lastManualPinIntentAt = GetTime()
    manualPin = { map = mapID, x = nx, y = ny }
    local okSet = pcall(CM.SetUserWaypoint, pt)
    if okSet then
        wpPendingRevealAnim = true
        PlayPinPlaceSound()
        QueueUserWaypointChanged()
        return true
    end
    return false
end

local function EnsureWorldMapShareHook()
    if worldMapShareHooked then return end
    local wm = _G.WorldMapFrame
    if wm and type(wm.AddCanvasClickHandler) == "function" then
        worldMapShareHooked = true
        -- 优先级 10000（暴雪 MapCanvasMixin 按高优先级优先执行，稳压 Polestar 默认优先级）：
        -- 点黄菱形附近 Shift+左键分享到聊天；点空地 Shift+左键直接插旗并同步北极星路线；Ctrl+左键仅打标不拦截
        pcall(wm.AddCanvasClickHandler, wm, OnWorldMapCanvasClick, 10000)
        if not worldMapHideHooked and wm.HookScript then
            worldMapHideHooked = true
            wm:HookScript("OnHide", function()
                if not (mod._active and wpPendingRevealAnim) then return end
                C_Timer.After(0.05, function()
                    if mod._active and wpPendingRevealAnim and RefreshBeam then
                        RefreshBeam(true)
                    end
                end)
            end)
        end
        return
    end
    if not worldMapShareWaiter then
        worldMapShareWaiter = _G.CreateFrame("Frame")
        worldMapShareWaiter:SetScript("OnEvent", function(self, _, name)
            if name == "Blizzard_WorldMap" then
                self:UnregisterEvent("ADDON_LOADED")
                EnsureWorldMapShareHook()
            end
        end)
    end
    worldMapShareWaiter:RegisterEvent("ADDON_LOADED")
end

-- 小地图零污染 Ctrl+左键 / Shift+左键直接插旗放 3D 光柱（兼容方形 EUI 小地图与旋转小地图，无需打开大地图）
local MINIMAP_RADIUS_OUTDOOR = { [0] = 700 / 3, 200, 500 / 3, 400 / 3, 100, 200 / 3 }
local MINIMAP_RADIUS_INDOOR  = { [0] = 150, 120, 90, 60, 40, 25 }

local function PlacePinFromMinimapClick(minimap, button)
    if not mod._active or button ~= "LeftButton" then return end
    if mod:GetDB().shiftClickPlacePin == false then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local ctrl = _G.IsControlKeyDown and _G.IsControlKeyDown() or false
    local shift = _G.IsShiftKeyDown and _G.IsShiftKeyDown() or false
    local alt = _G.IsAltKeyDown and _G.IsAltKeyDown() or false
    if alt or not (ctrl or shift) then return end
    if ctrl and shift then return end

    local CM = _G.C_Map
    if not (CM and CM.GetBestMapForUnit and CM.GetPlayerMapPosition and CM.GetMapWorldSize and CM.SetUserWaypoint) then return end
    local mapID = F.PlainNumber(CM.GetBestMapForUnit("player"), nil)
    if not mapID then return end
    if CM.CanSetUserWaypointOnMap then
        local okCan, can = pcall(CM.CanSetUserWaypointOnMap, mapID)
        if not (okCan and can == true) then return end
    end
    local pos = CM.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local px, py = pos.x, pos.y
    if pos.GetXY then
        local okXY, gx, gy = pcall(pos.GetXY, pos)
        if okXY then px, py = gx, gy end
    end
    px, py = F.PlainNumber(px, nil), F.PlainNumber(py, nil)
    if not (px and py) then return end

    local wYards, hYards = CM.GetMapWorldSize(mapID)
    wYards, hYards = F.PlainNumber(wYards, nil), F.PlainNumber(hYards, nil)
    if not (wYards and hYards and wYards > 0 and hYards > 0) then return end

    if not (minimap and minimap.GetCenter and _G.GetCursorPosition) then return end
    local cx, cy = minimap:GetCenter()
    local scale = minimap.GetEffectiveScale and F.PlainNumber(minimap:GetEffectiveScale(), 1) or 1
    local mw = minimap.GetWidth and F.PlainNumber(minimap:GetWidth(), 0) or 0
    local mh = minimap.GetHeight and F.PlainNumber(minimap:GetHeight(), 0) or 0
    cx, cy = F.PlainNumber(cx, nil), F.PlainNumber(cy, nil)
    if not (cx and cy and scale > 0 and mw > 10 and mh > 10) then return end

    local mx, my = _G.GetCursorPosition()
    mx, my = F.PlainNumber(mx, nil), F.PlainNumber(my, nil)
    if not (mx and my) then return end

    local nx = (mx / scale - cx) / (mw * 0.5)
    local ny = (my / scale - cy) / (mh * 0.5)
    if math_abs(nx) > 1 or math_abs(ny) > 1 then return end
    local shape = _G.GetMinimapShape and _G.GetMinimapShape() or "ROUND"
    if shape == "ROUND" and (nx * nx + ny * ny) > 1 then return end

    local radius = _G.C_Minimap and _G.C_Minimap.GetViewRadius and F.PlainNumber(_G.C_Minimap.GetViewRadius(), nil)
    if not (radius and radius > 0) then
        local zoom = minimap.GetZoom and F.PlainNumber(minimap:GetZoom(), 0) or 0
        local cvZoom = _G.GetCVar and tonumber(F.PlainString(_G.GetCVar("minimapZoom"), "")) or nil
        radius = (cvZoom == zoom and MINIMAP_RADIUS_OUTDOOR or MINIMAP_RADIUS_INDOOR)[zoom]
    end
    if not (radius and radius > 0) then return end

    local eastYards = nx * radius
    local northYards = ny * radius
    local rotOn = _G.GetCVar and F.PlainString(_G.GetCVar("rotateMinimap"), "0") == "1"
    if rotOn and not (_G.C_Minimap and _G.C_Minimap.IsRotateMinimapIgnored and _G.C_Minimap.IsRotateMinimapIgnored()) then
        local facing = _G.GetPlayerFacing and F.PlainNumber(_G.GetPlayerFacing(), nil)
        if not facing then return end
        local c, s = math_cos(facing), math_sin(facing)
        eastYards, northYards = eastYards * c - northYards * s, eastYards * s + northYards * c
    end

    local tx = px + eastYards / wYards
    local ty = py - northYards / hYards
    if tx < 0 or tx > 1 or ty < 0 or ty > 1 then return end

    local pt = MakeUiMapPoint(mapID, tx, ty)
    if not pt then return end
    lastManualPinIntentAt = GetTime()
    manualPin = { map = mapID, x = tx, y = ty }
    local okSet = pcall(CM.SetUserWaypoint, pt)
    if okSet then
        wpPendingRevealAnim = true
        PlayPinPlaceSound()
        QueueUserWaypointChanged()
    end
end

local function EnsureMinimapPinHook()
    if minimapPinHooked then return end
    local mm = _G.Minimap
    if mm and type(mm.HookScript) == "function" then
        minimapPinHooked = true
        mm:HookScript("OnMouseUp", PlacePinFromMinimapClick)
    end
end

-- ---------------------------------------------------------------------------
-- 4) 聊天框 worldmap: 坐标链接点击后兜底激活超级追踪
-- ---------------------------------------------------------------------------
local function OnSetItemRef(link)
    if not (mod._active and mod:GetDB().autoTrackChatLink ~= false) then
        return
    end
    local plain = F.PlainString(link, nil)
    if not plain or plain:sub(1, 9) ~= "worldmap:" then
        return
    end
    lastManualPinIntentAt = GetTime()
    QueueUserWaypointChanged()
end

-- ---------------------------------------------------------------------------
-- 5) kkowoUI 3D 远景光柱与悬浮渐变圆章渲染器（零 OnUpdate、全 C 端动效）
--    • 读取 C_Navigation.GetFrame() 3D 投影锚点（零污染、绝不修改暴雪帧）
--    • 视觉分层：落点扩散光环 + 地面柔光点 + 双层渐细光柱 + 烟熏黑曜石圆章
--      + 底部月牙流光边 + 彗尾弧光扫环 + 双色渐变几何图标 + 距离/耗时读数
--    • 支持 5 套双色渐变配色（冰川蓝紫 / 实时职业渐变 / 青草翡翠 / 星辉暖金 / 琉璃幻紫）
--    • 离开视野时自动吸附屏幕椭圆边缘并切换双折线方向箭头
-- ---------------------------------------------------------------------------
local BEAM_PRESETS = {
    glacier = { 0.64, 0.96, 1.00,  0.34, 0.48, 1.00 }, -- 视频同款：冰青 → 星辉蓝紫
    brand   = { 0.66, 1.00, 0.82,  0.20, 0.78, 0.44 }, -- 青草翡翠
    gold    = { 1.00, 0.95, 0.70,  0.90, 0.56, 0.18 }, -- 星辉暖金
    violet  = { 0.90, 0.81, 1.00,  0.48, 0.32, 0.94 }, -- 琉璃幻紫
}

local WP_EDGE = 0.38
local WP_ARRIVE_MARGIN = 5
local WP_TRACKED_EVENTS = {
    "NAVIGATION_DESTINATION_REACHED",
    "PLAYER_STARTED_MOVING",
    "PLAYER_STOPPED_MOVING",
}

local wpEventFrame = nil
local wpMarker = nil
local wpWatch = nil
local wpNavFrame = nil
local wpShown = nil
local wpAtEdge = nil
local wpArrivedAt = nil
local wpLastYards = nil
local wpLastEta = nil
local wpLastDX = nil
local wpLastDY = nil
local wpDistHooked = false
local wpPreviewActive = false
local wpPreviewToken = 0
local wpLastTargetKey = nil
local wpSoundReadyAt = 0
local wpLastQuestSoundKey = nil

local function DisablePixelSnap(obj)
    if not obj then return end
    if obj.SetSnapToPixelGrid then pcall(obj.SetSnapToPixelGrid, obj, false) end
    if obj.SetTexelSnappingBias then pcall(obj.SetTexelSnappingBias, obj, 0) end
end

local function ResolveBeamGradient()
    local db = mod:GetDB()
    local mode = db.beamColorMode or "glacier"
    if mode == "class" and F.StyleTokens and F.StyleTokens.GetClassGradient then
        local r1, g1, b1, r2, g2, b2 = F.StyleTokens.GetClassGradient(nil, "bright")
        return r2, g2, b2, r1, g1, b1
    end
    local p = BEAM_PRESETS[mode] or BEAM_PRESETS.glacier
    return p[1], p[2], p[3], p[4], p[5], p[6]
end

local function GetBeamMetrics()
    local db = mod:GetDB()
    local bh = math_max(80, math_min(220, math_floor((F.PlainNumber(db.beamHeight, 140) or 140) + 0.5)))
    local ms = math_max(32, math_min(56, math_floor((F.PlainNumber(db.medallionSize, 42) or 42) + 0.5)))
    return bh, ms
end

local function IsKkowoBeamDesired()
    return mod._active == true and (mod:GetDB().beamStyle or "kkowo") ~= "eui"
end

function mod:IsUsingKkowoBeam()
    return IsKkowoBeamDesired()
end

local function SyncEUIInGameNavPolicy(forceEnableEUI)
    local db = mod:GetDB()
    local EUI = _G.EllesmereUI
    local navAPI = EUI and EUI._InGameNavigation
    local euiDB = _G.EllesmereUIDB
    if not (type(euiDB) == "table" and type(navAPI) == "table") then return end

    if IsKkowoBeamDesired() then
        local curOn = (type(euiDB.inGameNavigation) == "table" and euiDB.inGameNavigation.enabled == true)
        if curOn then
            if db.savedEUIInGameNav == nil then
                db.savedEUIInGameNav = true
            end
            if type(navAPI.Set) == "function" then
                pcall(navAPI.Set, false)
            else
                euiDB.inGameNavigation.enabled = false
                if type(navAPI.Apply) == "function" then pcall(navAPI.Apply) end
            end
        end
    elseif forceEnableEUI then
        db.savedEUIInGameNav = nil
        if type(navAPI.Set) == "function" then
            pcall(navAPI.Set, true)
        else
            if type(euiDB.inGameNavigation) ~= "table" then euiDB.inGameNavigation = {} end
            euiDB.inGameNavigation.enabled = true
            if type(navAPI.Apply) == "function" then pcall(navAPI.Apply) end
        end
    elseif db.savedEUIInGameNav ~= nil then
        local restoreOn = db.savedEUIInGameNav == true
        db.savedEUIInGameNav = nil
        if type(navAPI.Set) == "function" then
            pcall(navAPI.Set, restoreOn)
        else
            if type(euiDB.inGameNavigation) ~= "table" then euiDB.inGameNavigation = {} end
            euiDB.inGameNavigation.enabled = restoreOn
            if type(navAPI.Apply) == "function" then pcall(navAPI.Apply) end
        end
    end
end

local function ApplyBeamGeometry()
    if not wpMarker then return end
    local bh, ms = GetBeamMetrics()
    local edge = (wpAtEdge == true) and (not wpPreviewActive)

    wpMarker.groundFlare:SetSize(ms * 0.62, ms * 0.28)
    wpMarker.ripple:SetSize(ms * 1.18, ms * 0.52)

    wpMarker.beamWrap:SetSize(math_max(24, math_floor(ms * 0.68)), bh)
    wpMarker.beamHalo:SetSize(math_max(22, math_floor(ms * 0.64)), bh + 8)
    wpMarker.beamCore:SetSize(math_max(8, math_floor(ms * 0.24)), bh + 6)

    wpMarker.medallion:SetSize(ms, ms)
    wpMarker.medallion:ClearAllPoints()
    wpMarker.medallion:SetPoint("CENTER", wpMarker, "CENTER", 0, edge and 0 or bh)

    wpMarker.innerGlow:SetSize(ms * 1.10, ms * 1.10)
    wpMarker.rim:SetSize(ms * 1.22, ms * 1.22)
    wpMarker.cometArc:SetSize(ms * 1.22, ms * 1.22)
    local icSz = math_floor(ms * 0.58 + 0.5)
    wpMarker.icon:SetSize(icSz, icSz)
    wpMarker.arrow:SetSize(math_max(16, math_floor(ms * 0.44)), math_max(16, math_floor(ms * 0.44)))

    wpMarker.distFS:ClearAllPoints()
    if edge then
        wpMarker.distFS:SetPoint("TOP", wpMarker.medallion, "BOTTOM", 0, -4)
    else
        wpMarker.distFS:SetPoint("BOTTOM", wpMarker.medallion, "TOP", 0, 5)
    end
    wpMarker.titleFS:ClearAllPoints()
    wpMarker.titleFS:SetPoint("BOTTOM", wpMarker.distFS, "TOP", 0, 2)
end

local function PaintBeam()
    if not wpMarker then return end
    local ST = F.StyleTokens
    local tr, tg, tb, br, bg, bb = ResolveBeamGradient()

    if ST and ST.ApplyGradient then
        -- VERTICAL: minColor = bottom, maxColor = top
        ST.ApplyGradient(wpMarker.beamHalo, "VERTICAL", br, bg, bb, 0.72, tr, tg, tb, 0.96)
        ST.ApplyGradient(wpMarker.beamCore, "VERTICAL", tr, tg, tb, 0.84, 1.0, 1.0, 1.0, 0.98)
        ST.ApplyGradient(wpMarker.rim, "VERTICAL", tr, tg, tb, 1.00, br, bg, bb, 0.76)
        ST.ApplyGradient(wpMarker.icon, "VERTICAL",
            math_min(1, br * 0.78 + 0.22), math_min(1, bg * 0.78 + 0.22), math_min(1, bb * 0.78 + 0.22), 1.0,
            math_min(1, tr * 0.45 + 0.55), math_min(1, tg * 0.45 + 0.55), math_min(1, tb * 0.45 + 0.55), 1.0)
        ST.ApplyGradient(wpMarker.arrow, "VERTICAL", br, bg, bb, 0.95, tr, tg, tb, 1.0)
    else
        wpMarker.beamHalo:SetVertexColor(br, bg, bb, 0.80)
        wpMarker.beamCore:SetVertexColor(tr, tg, tb, 0.95)
        wpMarker.rim:SetVertexColor(tr, tg, tb, 0.95)
        wpMarker.icon:SetVertexColor(tr, tg, tb, 1.0)
        wpMarker.arrow:SetVertexColor(tr, tg, tb, 0.96)
    end

    wpMarker.groundFlare:SetVertexColor(tr, tg, tb, 0.52)
    wpMarker.ripple:SetVertexColor(tr, tg, tb, 0.92)
    wpMarker.cometArc:SetVertexColor(tr, tg, tb, 0.95)
    wpMarker.innerGlow:SetVertexColor(br * 0.5 + tr * 0.5, bg * 0.5 + tg * 0.5, bb * 0.5 + tb * 0.5, 0.24)
    wpMarker.titleFS:SetTextColor(
        math_min(1, tr * 0.55 + 0.45),
        math_min(1, tg * 0.55 + 0.45),
        math_min(1, tb * 0.55 + 0.45), 1)
    wpMarker.distFS:SetTextColor(0.92, 0.96, 1.0, 0.96)
end

local function StopBeamSpawnAnims()
    if not wpMarker then return end
    wpMarker.rippleAnim:Stop()
    wpMarker.ripple:Hide()
    wpMarker.beamRiseAnim:Stop()
    wpMarker.beamWrap:SetAlpha(1)
    wpMarker.medRiseAnim:Stop()
    wpMarker.medallion:SetAlpha(1)
    wpMarker.cometAnim:Stop()
    wpMarker.cometArc:Hide()
    wpMarker.iconPopAnim:Stop()
    wpMarker.bloomAnim:Stop()
    wpMarker.innerGlow:SetAlpha(0.24)
end

local function SyncRimBreathe()
    if not wpMarker then return end
    local wantAnim = mod:GetDB().beamAnim ~= false
    if wantAnim and wpMarker:IsShown() then
        if not wpMarker.rimBreatheAnim:IsPlaying() then
            wpMarker.rimBreatheAnim:Play()
        end
    else
        wpMarker.rimBreatheAnim:Stop()
        wpMarker.rim:SetAlpha(0.94)
    end
end

local function PlayBeamSpawnAnim()
    if not wpMarker then return end
    StopBeamSpawnAnims()
    local bh = GetBeamMetrics()
    local edge = (wpAtEdge == true) and (not wpPreviewActive)
    if mod:GetDB().beamAnim == false or edge then
        ApplyBeamGeometry()
        SyncRimBreathe()
        return
    end

    -- 1) 落点地面扩散光环
    wpMarker.ripple:SetAlpha(1)
    wpMarker.ripple:Show()
    wpMarker.rippleAnim:Play()

    -- 2) 双层渐变光柱从地面向上升腾（宿主 Alpha 须为 1，避免与 Alpha 动画相乘变暗）
    wpMarker.beamWrap:SetAlpha(1)
    wpMarker.beamRiseAnim:Play()

    -- 3) 悬浮圆章柔和淡入到位（零 Translation 位移，彻底杜绝 3D 投影框体上图标错位飞天）
    wpMarker.medallion:ClearAllPoints()
    wpMarker.medallion:SetPoint("CENTER", wpMarker, "CENTER", 0, bh)
    wpMarker.medallion:SetAlpha(1)
    wpMarker.medRiseAnim:Play()

    -- 4) 外圈饱满流光扫环（0.74s 全圆周 -360° 柔和淡入淡出，消除左上角瞬闪）
    wpMarker.cometArc:SetAlpha(1)
    wpMarker.cometArc:Show()
    wpMarker.cometAnim:Play()

    -- 5) 中央双菱形/任务图标原地淡入 + 内部柔光闪耀（绝不对 3D 锚定子纹理做 Scale，保证 100% 居中不飞出圆环）
    wpMarker.icon:ClearAllPoints()
    wpMarker.icon:SetPoint("CENTER", wpMarker.medallion, "CENTER", 0, 0)
    wpMarker.icon:SetAlpha(1)
    wpMarker.iconPopAnim:Play()
    wpMarker.innerGlow:SetAlpha(1)
    wpMarker.bloomAnim:Play()

    -- 6) 常驻柔和月牙呼吸
    SyncRimBreathe()
end

local function IsBeamAllowedForCurrentTarget()
    if wpPreviewActive then return true end
    if mod:GetDB().onlyManualOrQuestBeam == false then return true end
    local CST = _G.C_SuperTrack
    local E = _G.Enum and _G.Enum.SuperTrackingType
    local kind = CST and CST.GetHighestPrioritySuperTrackingType and CST.GetHighestPrioritySuperTrackingType() or nil
    if E and (kind == E.Quest or kind == E.Corpse) then
        return true
    end
    if (not E) or kind == E.UserWaypoint then
        if not manualPin then return false end
        local wpM, wpX, wpY = GetCurrentUserWaypointCoords()
        if wpM and wpM == manualPin.map
            and math_abs(wpX - manualPin.x) < PIN_EPS
            and math_abs(wpY - manualPin.y) < PIN_EPS then
            return true
        end
        return false
    end
    return false
end

local function UpdateBeamTargetMeta()
    if not wpMarker then return end
    local ST = F.StyleTokens
    local texPin = (ST and ST.TEX and ST.TEX.WP_PIN) or (F.MEDIA .. "Waypoint\\WaypointPin.tga")
    local texQuest = (ST and ST.TEX and ST.TEX.WP_QUEST) or (F.MEDIA .. "Waypoint\\WaypointQuest.tga")
    local texCorpse = (ST and ST.TEX and ST.TEX.WP_CORPSE) or (F.MEDIA .. "Waypoint\\WaypointCorpse.tga")

    if wpPreviewActive then
        wpMarker.icon:SetTexture(texPin)
        wpMarker.titleFS:SetText("地图标记预览")
        wpMarker.titleFS:Show()
        wpMarker.distFS:SetText("185 米 · 24秒")
        wpMarker.distFS:Show()
        return false
    end

    local CST = _G.C_SuperTrack
    local E = _G.Enum and _G.Enum.SuperTrackingType
    local kind = CST and CST.GetHighestPrioritySuperTrackingType and CST.GetHighestPrioritySuperTrackingType() or nil
    local tex = texPin
    local title = ""
    local targetKey = tostring(kind or "none")

    if E and kind == E.Quest then
        tex = texQuest
        local qid = CST and CST.GetSuperTrackedQuestID and CST.GetSuperTrackedQuestID()
        if qid then
            targetKey = "q:" .. tostring(qid)
            local qTitle = _G.C_QuestLog and _G.C_QuestLog.GetTitleForQuestID and _G.C_QuestLog.GetTitleForQuestID(qid)
            title = F.PlainString(qTitle, "") or ""
        end
    elseif E and kind == E.Corpse then
        tex = texCorpse
        title = "尸体位置"
    else
        local wpM, wpX, wpY = GetCurrentUserWaypointCoords()
        if wpM then
            targetKey = string_format("u:%d:%.3f:%.3f", wpM, wpX, wpY)
        end
    end

    wpMarker.icon:SetTexture(tex)
    if title ~= "" then
        wpMarker.titleFS:SetText(title)
        wpMarker.titleFS:Show()
    else
        wpMarker.titleFS:SetText("")
        wpMarker.titleFS:Hide()
    end

    wpLastYards, wpLastEta, wpArrivedAt = nil, nil, nil
    local changed = (targetKey ~= wpLastTargetKey)
    wpLastTargetKey = targetKey
    return changed
end

local function FormatEtaCN(sec)
    if not sec or sec <= 0 then return nil end
    if sec <= 89 then
        return tostring(math_ceil(sec)) .. "秒"
    end
    local mins = math_max(2, math_floor(sec / 60 + 0.5))
    return tostring(mins) .. "分"
end

local function UpdateBeamDistance()
    if not wpMarker or wpPreviewActive then return end
    local CN = _G.C_Navigation
    if not (CN and CN.GetDistance) then return end
    local rawDist = CN.GetDistance()
    local dist = F.PlainNumber(rawDist, nil)
    if not dist then return end
    local yards = math_floor(dist + 0.5)

    local eta = nil
    if _G.GetUnitSpeed then
        local okS, spd = pcall(_G.GetUnitSpeed, "player")
        spd = okS and F.PlainNumber(spd, nil) or nil
        if spd and spd > 0 then
            local rawEta = yards / spd
            eta = rawEta <= 89 and math_ceil(rawEta) or math_max(2, math_floor(rawEta / 60 + 0.5)) * 60
        end
    end
    if yards == wpLastYards and eta == wpLastEta then return end
    wpLastYards, wpLastEta = yards, eta

    local distStr
    if yards >= 1000 then
        distStr = string_format("%.1f千米", yards / 1000)
    else
        distStr = tostring(yards) .. " 米"
    end
    if not wpAtEdge and eta and eta > 0 then
        local etaStr = FormatEtaCN(eta)
        if etaStr then
            distStr = distStr .. " · " .. etaStr
        end
    end
    wpMarker.distFS:SetText(distStr)
    wpMarker.distFS:Show()
end

local function PlaceBeamAtEdge(dx, dy)
    if not wpMarker then return end
    if wpLastDX and math_abs(dx - wpLastDX) < 0.5 and math_abs(dy - wpLastDY) < 0.5 then return end
    local len = math_sqrt(dx * dx + dy * dy)
    if len <= 0.001 then return end
    wpLastDX, wpLastDY = dx, dy
    local up = _G.UIParent
    local uw = F.PlainNumber(up and up:GetWidth(), 1920) or 1920
    local uh = F.PlainNumber(up and up:GetHeight(), 1080) or 1080
    local a, b = uw * WP_EDGE, uh * WP_EDGE
    if a <= 1 or b <= 1 then return end
    local k = 1 / math_sqrt((dx * dx) / (a * a) + (dy * dy) / (b * b))
    wpMarker:ClearAllPoints()
    wpMarker:SetPoint("CENTER", up, "CENTER", dx * k, dy * k)

    local _, ms = GetBeamMetrics()
    local gap = ms * 0.64 + 7
    wpMarker.arrow:SetRotation(math_atan2(dy, dx) - math_pi * 0.5)
    wpMarker.arrow:ClearAllPoints()
    wpMarker.arrow:SetPoint("CENTER", wpMarker.medallion, "CENTER", (dx / len) * gap, (dy / len) * gap)
end

local function BuildBeamFrame()
    if wpMarker then return end
    local ST = F.StyleTokens
    local texDisc = (ST and ST.TEX and ST.TEX.WP_DISC) or (F.MEDIA .. "Waypoint\\WaypointDisc.tga")
    local texRim = (ST and ST.TEX and ST.TEX.WP_RIM) or (F.MEDIA .. "Waypoint\\WaypointCrescentRim.tga")
    local texSweep = (ST and ST.TEX and ST.TEX.WP_SWEEP) or (F.MEDIA .. "Waypoint\\WaypointSweep.tga")
    local texCore = (ST and ST.TEX and ST.TEX.WP_BEAM_CORE) or (F.MEDIA .. "Waypoint\\WaypointBeamCore.tga")
    local texHalo = (ST and ST.TEX and ST.TEX.WP_BEAM_HALO) or (F.MEDIA .. "Waypoint\\WaypointBeamHalo.tga")
    local texRip = (ST and ST.TEX and ST.TEX.WP_RIPPLE) or (F.MEDIA .. "Waypoint\\WaypointRipple.tga")
    local texPin = (ST and ST.TEX and ST.TEX.WP_PIN) or (F.MEDIA .. "Waypoint\\WaypointPin.tga")
    local texArrow = (ST and ST.TEX and ST.TEX.WP_ARROW) or (F.MEDIA .. "Waypoint\\WaypointArrow.tga")
    local texGlow = (ST and ST.TEX and ST.TEX.SOFT_GLOW) or (F.MEDIA .. "Textures\\SoftGlow.tga")

    local f = CreateFrame("Frame", "kkowoUI_WaypointBeam", _G.UIParent)
    f:SetFrameStrata("BACKGROUND")
    f:SetSize(1, 1)
    f:EnableMouse(false)
    f:Hide()

    -- 地面锚点柔和微光 + 落点扩散光环
    local groundFlare = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    groundFlare:SetTexture(texGlow)
    groundFlare:SetBlendMode("ADD")
    groundFlare:SetPoint("CENTER", f, "CENTER", 0, 0)
    DisablePixelSnap(groundFlare)
    f.groundFlare = groundFlare

    local ripple = f:CreateTexture(nil, "BORDER", nil, 1)
    ripple:SetTexture(texRip)
    ripple:SetBlendMode("ADD")
    ripple:SetPoint("CENTER", f, "CENTER", 0, 0)
    ripple:Hide()
    DisablePixelSnap(ripple)
    f.ripple = ripple

    local rippleAnim = ripple:CreateAnimationGroup()
    local rSc = rippleAnim:CreateAnimation("Scale")
    rSc:SetOrder(1); rSc:SetOrigin("CENTER", 0, 0)
    rSc:SetScaleFrom(0.28, 0.28); rSc:SetScaleTo(1.88, 1.88)
    rSc:SetDuration(0.62); rSc:SetSmoothing("OUT")
    local rAl = rippleAnim:CreateAnimation("Alpha")
    rAl:SetOrder(1); rAl:SetFromAlpha(0.92); rAl:SetToAlpha(0)
    rAl:SetDuration(0.62); rAl:SetSmoothing("OUT")
    rippleAnim:SetScript("OnFinished", function() ripple:Hide() end)
    f.rippleAnim = rippleAnim

    -- 双层垂直渐细光柱容器（自底向上升腾）
    local beamWrap = CreateFrame("Frame", nil, f)
    beamWrap:SetPoint("BOTTOM", f, "CENTER", 0, 0)
    beamWrap:EnableMouse(false)
    f.beamWrap = beamWrap

    local beamHalo = beamWrap:CreateTexture(nil, "BACKGROUND", nil, 1)
    beamHalo:SetTexture(texHalo)
    beamHalo:SetBlendMode("ADD")
    beamHalo:SetPoint("BOTTOM", beamWrap, "BOTTOM", 0, 0)
    DisablePixelSnap(beamHalo)
    f.beamHalo = beamHalo

    local beamCore = beamWrap:CreateTexture(nil, "BORDER", nil, 2)
    beamCore:SetTexture(texCore)
    beamCore:SetBlendMode("ADD")
    beamCore:SetPoint("BOTTOM", beamWrap, "BOTTOM", 0, 0)
    DisablePixelSnap(beamCore)
    f.beamCore = beamCore

    local beamRiseAnim = beamWrap:CreateAnimationGroup()
    local bSc = beamRiseAnim:CreateAnimation("Scale")
    bSc:SetOrder(1); bSc:SetOrigin("BOTTOM", 0, 0)
    bSc:SetScaleFrom(1.0, 0.04); bSc:SetScaleTo(1.0, 1.0)
    bSc:SetDuration(0.48); bSc:SetSmoothing("OUT")
    local bAl = beamRiseAnim:CreateAnimation("Alpha")
    bAl:SetOrder(1); bAl:SetFromAlpha(0.15); bAl:SetToAlpha(1.0)
    bAl:SetDuration(0.34); bAl:SetSmoothing("OUT")
    beamRiseAnim:SetScript("OnFinished", function() beamWrap:SetAlpha(1) end)
    f.beamRiseAnim = beamRiseAnim

    -- 顶部悬浮黑曜石圆章
    local med = CreateFrame("Frame", nil, f)
    med:EnableMouse(false)
    f.medallion = med

    local disc = med:CreateTexture(nil, "BACKGROUND", nil, 0)
    disc:SetTexture(texDisc)
    disc:SetAllPoints(med)
    DisablePixelSnap(disc)
    f.disc = disc

    local innerGlow = med:CreateTexture(nil, "BORDER", nil, 1)
    innerGlow:SetTexture(texGlow)
    innerGlow:SetBlendMode("ADD")
    innerGlow:SetPoint("CENTER", med, "CENTER", 0, 0)
    DisablePixelSnap(innerGlow)
    f.innerGlow = innerGlow

    local rim = med:CreateTexture(nil, "ARTWORK", nil, 2)
    rim:SetTexture(texRim)
    rim:SetBlendMode("ADD")
    rim:SetPoint("CENTER", med, "CENTER", 0, 0)
    DisablePixelSnap(rim)
    f.rim = rim

    local cometArc = med:CreateTexture(nil, "OVERLAY", nil, 3)
    cometArc:SetTexture(texSweep)
    cometArc:SetBlendMode("ADD")
    cometArc:SetPoint("CENTER", med, "CENTER", 0, 0)
    cometArc:Hide()
    DisablePixelSnap(cometArc)
    f.cometArc = cometArc

    local icon = med:CreateTexture(nil, "OVERLAY", nil, 5)
    icon:SetTexture(texPin)
    icon:SetPoint("CENTER", med, "CENTER", 0, 0)
    DisablePixelSnap(icon)
    f.icon = icon

    local arrow = f:CreateTexture(nil, "OVERLAY", nil, 6)
    arrow:SetTexture(texArrow)
    arrow:Hide()
    DisablePixelSnap(arrow)
    f.arrow = arrow

    local distFS = med:CreateFontString(nil, "OVERLAY")
    if ST and ST.ApplyText then
        ST.ApplyText(distFS, 11, 0.92, 0.96, 1.0, 0.96)
    else
        F.Theme.ApplyFont(distFS, 11, "", 0.92, 0.96, 1.0, 0.96)
    end
    f.distFS = distFS

    local titleFS = med:CreateFontString(nil, "OVERLAY")
    if ST and ST.ApplyText then
        ST.ApplyText(titleFS, 12, 0.96, 0.98, 1.0, 1.0)
    else
        F.Theme.ApplyFont(titleFS, 12, "", 0.96, 0.98, 1.0, 1.0)
    end
    titleFS:Hide()
    f.titleFS = titleFS

    -- 圆章柔和淡入（纯 Alpha，绝不对 C_Navigation 3D 锚定子框体叠加 Translation 避免偏移飞天）
    local medRiseAnim = med:CreateAnimationGroup()
    local mAl = medRiseAnim:CreateAnimation("Alpha")
    mAl:SetOrder(1); mAl:SetFromAlpha(0); mAl:SetToAlpha(1); mAl:SetDuration(0.36); mAl:SetSmoothing("OUT")
    local function settleMed()
        local bh = GetBeamMetrics()
        local edge = (wpAtEdge == true) and (not wpPreviewActive)
        med:ClearAllPoints()
        med:SetPoint("CENTER", f, "CENTER", 0, edge and 0 or bh)
        med:SetAlpha(1)
    end
    medRiseAnim:SetScript("OnFinished", settleMed)
    medRiseAnim:SetScript("OnStop", settleMed)
    f.medRiseAnim = medRiseAnim

    -- 外圈饱满流光扫环（0.74s 全圆周 -360° 柔和点亮再淡出）
    local cometAnim = cometArc:CreateAnimationGroup()
    local cRot = cometAnim:CreateAnimation("Rotation")
    cRot:SetOrder(1); cRot:SetOrigin("CENTER", 0, 0); cRot:SetDegrees(-360); cRot:SetDuration(0.74); cRot:SetSmoothing("IN_OUT")
    local cAlIn = cometAnim:CreateAnimation("Alpha")
    cAlIn:SetOrder(1); cAlIn:SetFromAlpha(0); cAlIn:SetToAlpha(0.96); cAlIn:SetDuration(0.18); cAlIn:SetSmoothing("OUT")
    local cAlOut = cometAnim:CreateAnimation("Alpha")
    cAlOut:SetOrder(1); cAlOut:SetStartDelay(0.18); cAlOut:SetFromAlpha(0.96); cAlOut:SetToAlpha(0); cAlOut:SetDuration(0.56); cAlOut:SetSmoothing("OUT")
    cometAnim:SetScript("OnFinished", function() cometArc:Hide() end)
    f.cometAnim = cometAnim

    -- 中央几何图标原地纯 Alpha 点亮（零 Scale，彻底避免 3D 投影帧缩放原点错位导致图标飞离圆环）
    local iconPopAnim = icon:CreateAnimationGroup()
    local ip1 = iconPopAnim:CreateAnimation("Alpha")
    ip1:SetOrder(1); ip1:SetFromAlpha(0); ip1:SetToAlpha(1)
    ip1:SetDuration(0.30); ip1:SetSmoothing("OUT")
    iconPopAnim:SetScript("OnFinished", function() icon:SetAlpha(1) end)
    iconPopAnim:SetScript("OnStop", function() icon:SetAlpha(1) end)
    f.iconPopAnim = iconPopAnim

    -- 内部柔光闪耀回落
    local bloomAnim = innerGlow:CreateAnimationGroup()
    local bl1 = bloomAnim:CreateAnimation("Alpha")
    bl1:SetOrder(1); bl1:SetFromAlpha(0.18); bl1:SetToAlpha(0.88); bl1:SetDuration(0.22); bl1:SetSmoothing("OUT")
    local bl2 = bloomAnim:CreateAnimation("Alpha")
    bl2:SetOrder(2); bl2:SetFromAlpha(0.88); bl2:SetToAlpha(0.24); bl2:SetDuration(0.46); bl2:SetSmoothing("OUT")
    bloomAnim:SetScript("OnFinished", function() innerGlow:SetAlpha(0.24) end)
    f.bloomAnim = bloomAnim

    -- 常驻微弱月牙呼吸（C 端 BOUNCE，0 Lua CPU）
    local rimBreatheAnim = rim:CreateAnimationGroup()
    rimBreatheAnim:SetLooping("BOUNCE")
    local rbAl = rimBreatheAnim:CreateAnimation("Alpha")
    rbAl:SetFromAlpha(0.74); rbAl:SetToAlpha(1.00); rbAl:SetDuration(1.30); rbAl:SetSmoothing("IN_OUT")
    f.rimBreatheAnim = rimBreatheAnim

    -- 零 OnUpdate 位移监听器：锚定在 navFrame CENTER 到 WorldFrame 右下外延，每次投影变化自动触发 OnSizeChanged
    wpWatch = CreateFrame("Frame", nil, _G.UIParent)
    wpWatch:Hide()
    wpWatch:SetScript("OnSizeChanged", function()
        if RefreshBeam then RefreshBeam(false) end
    end)

    if not wpDistHooked and type(_G.hooksecurefunc) == "function" then
        local stf = _G.SuperTrackedFrame
        local gameDist = stf and stf.DistanceText
        if gameDist and type(gameDist.SetText) == "function" then
            wpDistHooked = true
            _G.hooksecurefunc(gameDist, "SetText", function()
                if RefreshBeam then RefreshBeam(false) end
            end)
        end
    end

    wpMarker = f
    ApplyBeamGeometry()
    PaintBeam()
end

RefreshBeam = function(forceAnim)
    if wpPreviewActive then return end
    if not (IsKkowoBeamDesired() and wpNavFrame) then return end
    local CN = _G.C_Navigation
    if not CN then return end

    local dist = CN.GetDistance and F.PlainNumber(CN.GetDistance(), nil) or nil
    if wpArrivedAt and dist and dist > wpArrivedAt + WP_ARRIVE_MARGIN then
        wpArrivedAt = nil
    end

    local NS = _G.Enum and _G.Enum.NavigationState
    local validPos = CN.HasValidScreenPosition and CN.HasValidScreenPosition()
    if F.IsSecret(validPos) then validPos = false end
    local tState = CN.GetTargetState and CN.GetTargetState()
    if F.IsSecret(tState) then tState = nil end
    local stateOK = (not NS) or (not NS.Invalid) or (tState == nil) or (tState == NS.Invalid)
    local show = (not wpArrivedAt) and (validPos == true) and stateOK and IsBeamAllowedForCurrentTarget()

    local edge, nx, ny, nScale = false, nil, nil, nil
    if show then
        local clamped = CN.WasClampedToScreen and CN.WasClampedToScreen()
        edge = (not F.IsSecret(clamped)) and clamped == true
        if edge then
            local okC, cx, cy = pcall(wpNavFrame.GetCenter, wpNavFrame)
            local okS, sc = pcall(wpNavFrame.GetEffectiveScale, wpNavFrame)
            nx = okC and F.PlainNumber(cx, nil) or nil
            ny = okC and F.PlainNumber(cy, nil) or nil
            nScale = okS and F.PlainNumber(sc, nil) or nil
            if not (nx and ny and nScale) then
                show = false
            end
        end
    end

    local becameVisible = show and (wpShown ~= true)
    if show ~= wpShown then
        wpShown = show
        wpMarker:SetShown(show)
        if not show then
            StopBeamSpawnAnims()
            wpMarker.rimBreatheAnim:Stop()
        end
    end
    if not show then return end

    local leftEdge = (wpAtEdge == true) and (not edge)
    if edge ~= wpAtEdge then
        wpAtEdge = edge
        wpMarker.groundFlare:SetShown(not edge)
        wpMarker.beamWrap:SetShown(not edge)
        wpMarker.arrow:SetShown(edge)
        if edge then
            StopBeamSpawnAnims()
            wpMarker.titleFS:Hide()
        else
            local title = wpMarker.titleFS:GetText()
            if title and title ~= "" then wpMarker.titleFS:Show() end
        end
        wpLastDX, wpLastDY = nil, nil
        ApplyBeamGeometry()
        if not edge then
            wpMarker:ClearAllPoints()
            wpMarker:SetPoint("CENTER", wpNavFrame, "CENTER", 0, 0)
        end
    end

    if edge then
        local up = _G.UIParent
        local okU, ucx, ucy = pcall(up.GetCenter, up)
        local okUS, usc = pcall(up.GetEffectiveScale, up)
        ucx = okU and F.PlainNumber(ucx, nil) or nil
        ucy = okU and F.PlainNumber(ucy, nil) or nil
        usc = okUS and F.PlainNumber(usc, 1) or 1
        if nx and ny and ucx and ucy and usc > 0 then
            local s = nScale / usc
            PlaceBeamAtEdge(nx * s - ucx, ny * s - ucy)
        end
        UpdateBeamDistance()
    else
        UpdateBeamDistance()
        local mapOpen = _G.WorldMapFrame and _G.WorldMapFrame.IsShown and _G.WorldMapFrame:IsShown()
        local wantReveal = wpPendingRevealAnim and (not mapOpen)
        if becameVisible or forceAnim or wantReveal or (leftEdge and wpPendingRevealAnim) then
            if not mapOpen then wpPendingRevealAnim = false end
            PlayBeamSpawnAnim()
        else
            SyncRimBreathe()
        end
    end
end

local function AttachBeamNav(nav)
    wpNavFrame = nav
    wpShown, wpAtEdge, wpLastYards, wpLastEta, wpLastDX, wpLastDY, wpArrivedAt = nil, nil, nil, nil, nil, nil, nil
    if not nav then
        if wpEventFrame then
            for _, ev in ipairs(WP_TRACKED_EVENTS) do
                wpEventFrame:UnregisterEvent(ev)
            end
        end
        if wpWatch then
            wpWatch:Hide()
            wpWatch:ClearAllPoints()
        end
        if wpMarker and not wpPreviewActive then
            StopBeamSpawnAnims()
            wpMarker.rimBreatheAnim:Stop()
            wpMarker:Hide()
            wpMarker:ClearAllPoints()
        end
        return
    end
    BuildBeamFrame()
    if wpPreviewActive then
        mod:StopBeamPreview()
    end
    wpMarker:SetFrameStrata("BACKGROUND")
    wpMarker:SetFrameLevel(1)
    PaintBeam()
    UpdateBeamTargetMeta()
    ApplyBeamGeometry()
    wpMarker:ClearAllPoints()
    wpMarker:SetPoint("CENTER", nav, "CENTER", 0, 0)
    wpWatch:ClearAllPoints()
    wpWatch:SetPoint("TOPLEFT", nav, "CENTER", 0, 0)
    if _G.WorldFrame then
        wpWatch:SetPoint("BOTTOMRIGHT", _G.WorldFrame, "BOTTOMRIGHT", 2000, -2000)
    end
    wpWatch:Show()
    if wpEventFrame then
        for _, ev in ipairs(WP_TRACKED_EVENTS) do
            wpEventFrame:RegisterEvent(ev)
        end
    end
    RefreshBeam(true)
end

local function PlayQuestTrackSoundIfNeeded()
    if wpPreviewActive then return end
    if GetTime() < wpSoundReadyAt then return end
    local CST = _G.C_SuperTrack
    local E = _G.Enum and _G.Enum.SuperTrackingType
    local kind = CST and CST.GetHighestPrioritySuperTrackingType and CST.GetHighestPrioritySuperTrackingType() or nil
    if not (E and kind == E.Quest) then
        wpLastQuestSoundKey = nil
        return
    end
    local qid = CST and CST.GetSuperTrackedQuestID and CST.GetSuperTrackedQuestID() or nil
    if not qid then return end
    local key = "q:" .. tostring(qid)
    if key ~= wpLastQuestSoundKey and IsBeamAllowedForCurrentTarget() then
        wpLastQuestSoundKey = key
        PlayPinPlaceSound()
    end
end

local function EnsureBeamEventDriver()
    if wpEventFrame then return end
    wpEventFrame = CreateFrame("Frame")
    wpEventFrame:SetScript("OnEvent", function(_, event, region)
        if not IsKkowoBeamDesired() then return end
        if event == "NAVIGATION_FRAME_CREATED" then
            AttachBeamNav(region)
        elseif event == "NAVIGATION_FRAME_DESTROYED" then
            AttachBeamNav(nil)
        elseif wpNavFrame then
            if event == "SUPER_TRACKING_CHANGED" then
                local changed = UpdateBeamTargetMeta()
                PaintBeam()
                RefreshBeam(changed)
                if changed then PlayQuestTrackSoundIfNeeded() end
            elseif event == "NAVIGATION_DESTINATION_REACHED" then
                local CN = _G.C_Navigation
                wpArrivedAt = CN and CN.GetDistance and F.PlainNumber(CN.GetDistance(), 0) or 0
                RefreshBeam(false)
            else
                RefreshBeam(false)
            end
        elseif event == "SUPER_TRACKING_CHANGED" then
            PlayQuestTrackSoundIfNeeded()
            local CN = _G.C_Navigation
            if CN and CN.GetFrame then
                AttachBeamNav(CN.GetFrame())
            end
        end
    end)
end

local function SyncKkowoBeamState(forceEnableEUI)
    SyncEUIInGameNavPolicy(forceEnableEUI)
    if IsKkowoBeamDesired() then
        EnsureBeamEventDriver()
        wpEventFrame:RegisterEvent("NAVIGATION_FRAME_CREATED")
        wpEventFrame:RegisterEvent("NAVIGATION_FRAME_DESTROYED")
        wpEventFrame:RegisterEvent("SUPER_TRACKING_CHANGED")
        local CN = _G.C_Navigation
        AttachBeamNav(CN and CN.GetFrame and CN.GetFrame() or nil)
    else
        if wpEventFrame then
            wpEventFrame:UnregisterAllEvents()
        end
        AttachBeamNav(nil)
    end
end

function mod:StopBeamPreview()
    wpPreviewToken = wpPreviewToken + 1
    if not wpPreviewActive then return end
    wpPreviewActive = false
    if wpMarker then
        StopBeamSpawnAnims()
        wpMarker.rimBreatheAnim:Stop()
        wpMarker:SetFrameStrata("BACKGROUND")
        wpMarker:SetFrameLevel(1)
        wpMarker:Hide()
    end
    wpShown = nil
    wpAtEdge = nil
    if IsKkowoBeamDesired() and wpNavFrame then
        AttachBeamNav(wpNavFrame)
    end
end

function mod:ShowBeamPreview()
    BuildBeamFrame()
    wpPreviewActive = true
    wpPreviewToken = wpPreviewToken + 1
    local myToken = wpPreviewToken

    wpMarker:SetFrameStrata("FULLSCREEN_DIALOG")
    wpMarker:SetFrameLevel(240)
    wpMarker.groundFlare:Show()
    wpMarker.beamWrap:Show()
    wpMarker.arrow:Hide()
    wpAtEdge = false
    UpdateBeamTargetMeta()
    ApplyBeamGeometry()
    PaintBeam()
    wpMarker:ClearAllPoints()
    wpMarker:SetPoint("CENTER", _G.UIParent, "CENTER", 260, -70)
    wpMarker:Show()
    PlayBeamSpawnAnim()

    C_Timer.After(6.0, function()
        if wpPreviewToken == myToken and wpPreviewActive then
            mod:StopBeamPreview()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- 诊断信息输出：/kk nav
-- ---------------------------------------------------------------------------
function mod:DumpDiagnostics()
    local EUI = _G.EllesmereUI
    local euiNavOn = EUI and EUI._InGameNavigation and EUI._InGameNavigation.Get
        and EUI._InGameNavigation.Get("enabled")
    local cvar = _G.C_CVar and _G.C_CVar.GetCVar and F.PlainString(_G.C_CVar.GetCVar("showInGameNavigation"), "?") or "?"
    local ST = _G.C_SuperTrack
    local CN = _G.C_Navigation
    local isAny = ST and ST.IsSuperTrackingAnything and ST.IsSuperTrackingAnything()
    local stType = ST and ST.GetHighestPrioritySuperTrackingType and ST.GetHighestPrioritySuperTrackingType()
    local wpM, wpX, wpY = GetCurrentUserWaypointCoords()
    local navF = CN and CN.GetFrame and CN.GetFrame()
    local validPos = CN and CN.HasValidScreenPosition and CN.HasValidScreenPosition()
    local tState = CN and CN.GetTargetState and CN.GetTargetState()
    local dist = CN and CN.GetDistance and F.PlainNumber(CN.GetDistance(), nil)
    local api = GetPolestarAPI()
    local psT = api and api.Target and api.Target()
    local db = self:GetDB()

    F.Print("3D 光柱导航诊断 (/kk nav)：")
    _G.print("  • 光柱引擎=" .. (IsKkowoBeamDesired() and ("kkowoUI/" .. tostring(db.beamColorMode or "glacier")) or "EUI")
        .. " | EUI光柱=" .. tostring(euiNavOn)
        .. " | CVar showInGameNavigation=" .. tostring(cvar)
        .. " | Polestar联动=" .. tostring(polestarFollowed)
        .. " | 重复绿标隐藏=" .. tostring(polestarPinHidden))
    _G.print("  • SuperTrack active=" .. tostring(isAny)
        .. " | type=" .. tostring(stType)
        .. " | UserWaypoint=" .. (wpM and string_format("#%d (%.1f, %.1f)", wpM, wpX * 100, wpY * 100) or "无"))
    _G.print("  • C_Navigation frame=" .. tostring(navF ~= nil)
        .. " | validPos=" .. tostring(validPos)
        .. " | targetState=" .. tostring(tState)
        .. " | dist=" .. (dist and string_format("%.1f米", dist) or "无"))
    if type(psT) == "table" then
        local leg = (type(psT.next) == "table" and psT.next.map) and psT.next or psT
        _G.print("  • Polestar 当前目标：" .. tostring(leg.title or psT.title or "?")
            .. string_format(" (#%s %.1f, %.1f)", tostring(leg.map), (F.PlainNumber(leg.x, 0) or 0) * 100, (F.PlainNumber(leg.y, 0) or 0) * 100))
    else
        _G.print("  • Polestar 当前目标：无")
    end
end

function mod:OnThemeChanged()
    if wpMarker then
        PaintBeam()
    end
end

function mod:OnEnable()
    wpSoundReadyAt = GetTime() + 2.5
    EnsureNavigationCVar()
    EnsurePolestarFollower()
    EnsureInsertLinkHook()
    EnsureWorldMapShareHook()
    EnsureMinimapPinHook()
    SyncKkowoBeamState(false)

    self:RegisterEvent("USER_WAYPOINT_UPDATED", function()
        if suppressOwnPinEvent then
            suppressOwnPinEvent = false
            return
        end
        QueueUserWaypointChanged()
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        wpSoundReadyAt = GetTime() + 2.0
        EnsureNavigationCVar()
        EnsurePolestarFollower()
        EnsureWorldMapShareHook()
        SyncKkowoBeamState(false)
        C_Timer.After(0.6, QueuePolestarSync)
    end)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        C_Timer.After(0.3, QueuePolestarSync)
    end)

    if not setItemRefHooked and _G.hooksecurefunc then
        setItemRefHooked = true
        _G.hooksecurefunc("SetItemRef", OnSetItemRef)
    end
    C_Timer.After(1.0, function()
        if mod._active then
            SyncKkowoBeamState(false)
            EnsurePolestarFollower()
            QueuePolestarSync()
        end
    end)
end

function mod:OnDisable()
    userWpQueued = false
    polestarSyncQueued = false
    self:StopBeamPreview()
    SyncKkowoBeamState(false)
    DetachPolestarFollower()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "光柱样式",
        tooltip = "切换渐变动效光柱与 EUI 原生光柱，开启时自动避免重复。",
        values = {
            kkowo = "kkowoUI 渐变光柱（推荐）",
            eui   = "EUI 原生光柱",
        },
        order = { "kkowo", "eui" },
        getValue = function() return db.beamStyle or "kkowo" end,
        setValue = function(v)
            db.beamStyle = (v == "eui") and "eui" or "kkowo"
            SyncKkowoBeamState(db.beamStyle == "eui")
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "光柱配色",
        tooltip = "选择光柱与图标的双色渐变方案，支持实时跟随职业色。",
        values = {
            glacier = "冰川蓝紫（默认）",
            class   = "职业渐变色",
            brand   = "青草翡翠",
            gold    = "星辉暖金",
            violet  = "琉璃幻紫",
        },
        order = { "glacier", "class", "brand", "gold", "violet" },
        disabled = function() return (db.beamStyle or "kkowo") == "eui" end,
        getValue = function() return db.beamColorMode or "glacier" end,
        setValue = function(v)
            db.beamColorMode = v or "glacier"
            PaintBeam()
            if wpPreviewActive then PlayBeamSpawnAnim() end
        end,
    }, {
        type = "labeledButton",
        text = "光柱效果预览",
        buttonText = "预览光柱",
        width = 110,
        tooltip = "在屏幕演示光柱升腾、扩散环与渐变图标效果（/kk beam）。",
        onClick = function() mod:ShowBeamPreview() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "仅手动与任务光柱",
        tooltip = "仅手动插旗或点任务追踪时亮光柱，屏蔽北极星常规与附近导航。",
        getValue = function() return db.onlyManualOrQuestBeam ~= false end,
        setValue = function(v)
            db.onlyManualOrQuestBeam = v == true
            if v then
                ClearPolestarPinIfOwned()
            else
                QueuePolestarSync()
            end
            if RefreshBeam then RefreshBeam(false) end
        end,
    }, {
        type = "toggle",
        text = "快捷插旗",
        tooltip = "大地图空地及小地图支持 Ctrl/Shift+左键直接插旗并升起光柱。",
        getValue = function() return db.shiftClickPlacePin ~= false end,
        setValue = function(v) db.shiftClickPlacePin = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "插旗联动路线",
        tooltip = "大地图插旗后同步亮起光柱与跨图路线，移除同步取消。",
        getValue = function() return db.syncPinToPolestar ~= false end,
        setValue = function(v)
            db.syncPinToPolestar = v == true
            if not v and manualNavActive then
                manualNavActive = false
                local api = GetPolestarAPI()
                if api and type(api.Cancel) == "function" then pcall(api.Cancel, FOLLOW_OWNER) end
                SetPolestarTargetPinHidden(false)
            end
        end,
    }, {
        type = "toggle",
        text = "隐藏重合绿标",
        tooltip = "暴雪标记与北极星目标点重合时隐藏多余绿标，保留路线与箭头。",
        getValue = function() return db.dedupPolestarPin ~= false end,
        setValue = function(v)
            db.dedupPolestarPin = v == true
            UpdatePolestarPinDedup()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "光柱升腾动效",
        tooltip = "放点时播放落点光环、光柱升腾与全环流光动效。",
        disabled = function() return (db.beamStyle or "kkowo") == "eui" end,
        getValue = function() return db.beamAnim ~= false end,
        setValue = function(v)
            db.beamAnim = v == true
            SyncRimBreathe()
            if wpPreviewActive and v then PlayBeamSpawnAnim() end
        end,
    }, {
        type = "toggle",
        text = "插旗音效提示",
        tooltip = "大地图手动放置标记时播放清脆的落点提示音。",
        getValue = function() return db.beamSound ~= false end,
        setValue = function(v) db.beamSound = v == true end,
    })
    y = y - h

    local function buildAdv(w, p, curY)
        local _, rh
        _, rh = w:DualRow(p, curY, {
            type = "slider",
            text = "光柱高度",
            min = 80, max = 220, step = 10,
            disabled = function() return (db.beamStyle or "kkowo") == "eui" end,
            getValue = function() return db.beamHeight or 140 end,
            setValue = function(v)
                db.beamHeight = v
                ApplyBeamGeometry()
                if wpPreviewActive then PlayBeamSpawnAnim() end
            end,
        }, {
            type = "slider",
            text = "圆章大小",
            min = 32, max = 56, step = 2,
            disabled = function() return (db.beamStyle or "kkowo") == "eui" end,
            getValue = function() return db.medallionSize or 42 end,
            setValue = function(v)
                db.medallionSize = v
                ApplyBeamGeometry()
            end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "北极星同步光柱",
            tooltip = "关闭仅手动限制时，允许北极星常规步骤同步到世界光柱。",
            disabled = function() return db.onlyManualOrQuestBeam ~= false end,
            getValue = function() return db.syncPolestarBeam ~= false end,
            setValue = function(v)
                db.syncPolestarBeam = v == true
                if v then
                    QueuePolestarSync()
                else
                    ClearPolestarPinIfOwned()
                    SetPolestarTargetPinHidden(false)
                end
            end,
        }, blank)
        curY = curY - rh
        return curY
    end

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("waypointAutoTrack", W, parent, y, buildAdv, blank)
    else
        y = buildAdv(W, parent, y)
    end
    return y
end
