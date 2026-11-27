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
local math_abs, pcall, tostring, type = math.abs, pcall, tostring, type
local string_format = string.format
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown

local mod = F.RegisterModule("waypointAutoTrack", {
    title = "大地图标记与 3D 光柱 / Polestar 统一联动",
    desc = "保持暴雪原生大地图 Ctrl+左键放点/移除与 Shift+左键分享，自动激活 EUI 3D 光柱并与 Polestar 跨图最短路线双向联动，同时自动去重避免双标记重叠。",
    group = "quest",
    order = 66,
    yieldIfLoaded = "WaypointUI",
    defaults = {
        enabled = true,
        autoTrackPlacedPin = true,
        syncPinToPolestar = true,
        syncPolestarBeam = true,
        dedupPolestarPin = true,
        autoTrackChatLink = true,
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
        -- 玩家放下了新的暴雪地图标记：立即激活 EUI 3D 光柱，并通知 Polestar 规划跨图路线
        polestarPin = nil
        if db.autoTrackPlacedPin ~= false and ST and type(ST.SetSuperTrackedUserWaypoint) == "function" then
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
        -- 玩家用暴雪原生 Ctrl+左键 移除了地图标记：同步清除 3D 光柱与对应的 Polestar 路线
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

    if mod:GetDB().syncPolestarBeam == false then
        UpdatePolestarPinDedup(target)
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

local function OnShiftClickNearPin(canvas, button)
    if not mod._active or button ~= "LeftButton" then return false end
    if not (_G.IsShiftKeyDown and _G.IsShiftKeyDown()) then return false end
    if (_G.IsControlKeyDown and _G.IsControlKeyDown()) or (_G.IsAltKeyDown and _G.IsAltKeyDown()) then
        return false
    end
    local wpMap, wpX, wpY = GetCurrentUserWaypointCoords()
    if not wpMap then return false end
    local mapID = canvas and canvas.GetMapID and F.PlainNumber(canvas:GetMapID(), nil)
    if mapID ~= wpMap then return false end
    local nx, ny = nil, nil
    if canvas and canvas.GetNormalizedCursorPosition then
        local okC, cx, cy = pcall(canvas.GetNormalizedCursorPosition, canvas)
        if okC then
            nx = F.PlainNumber(cx, nil)
            ny = F.PlainNumber(cy, nil)
        end
    end
    if not (nx and ny) then return false end
    if math_abs(nx - wpX) > SHIFT_SHARE_DIST or math_abs(ny - wpY) > SHIFT_SHARE_DIST then
        return false
    end
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
    return false
end

local function EnsureWorldMapShareHook()
    if worldMapShareHooked then return end
    local wm = _G.WorldMapFrame
    if wm and type(wm.AddCanvasClickHandler) == "function" then
        worldMapShareHooked = true
        -- 优先级 1：仅在黄菱形周围 Shift+左键时优先分享到聊天，避免 Polestar 误把擦边点击当成新建坐标
        pcall(wm.AddCanvasClickHandler, wm, OnShiftClickNearPin, 1)
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
    QueueUserWaypointChanged()
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

    F.Print("3D 光柱导航诊断 (/kk nav)：")
    _G.print("  • EUI InGameNavigation=" .. tostring(euiNavOn)
        .. " | CVar showInGameNavigation=" .. tostring(cvar)
        .. " | Polestar联动=" .. tostring(polestarFollowed)
        .. " | 重复绿标隐藏=" .. tostring(polestarPinHidden))
    _G.print("  • SuperTrack active=" .. tostring(isAny)
        .. " | type=" .. tostring(stType)
        .. " | UserWaypoint=" .. (wpM and string_format("#%d (%.1f, %.1f)", wpM, wpX * 100, wpY * 100) or "无"))
    _G.print("  • C_Navigation frame=" .. tostring(navF ~= nil)
        .. " | validPos=" .. tostring(validPos)
        .. " | targetState=" .. tostring(tState)
        .. " | dist=" .. (dist and string_format("%.1f码", dist) or "无"))
    if type(psT) == "table" then
        local leg = (type(psT.next) == "table" and psT.next.map) and psT.next or psT
        _G.print("  • Polestar 当前目标：" .. tostring(leg.title or psT.title or "?")
            .. string_format(" (#%s %.1f, %.1f)", tostring(leg.map), (F.PlainNumber(leg.x, 0) or 0) * 100, (F.PlainNumber(leg.y, 0) or 0) * 100))
    else
        _G.print("  • Polestar 当前目标：无")
    end
end

function mod:OnEnable()
    EnsureNavigationCVar()
    EnsurePolestarFollower()
    EnsureInsertLinkHook()
    EnsureWorldMapShareHook()

    self:RegisterEvent("USER_WAYPOINT_UPDATED", function()
        if suppressOwnPinEvent then
            suppressOwnPinEvent = false
            return
        end
        QueueUserWaypointChanged()
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        EnsureNavigationCVar()
        EnsurePolestarFollower()
        EnsureWorldMapShareHook()
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
            EnsurePolestarFollower()
            QueuePolestarSync()
        end
    end)
end

function mod:OnDisable()
    userWpQueued = false
    polestarSyncQueued = false
    DetachPolestarFollower()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "大地图 Ctrl+左键插旗联动 Polestar 路线与光柱",
        tooltip = "保留暴雪原生 Ctrl+左键放置/移除与 Shift+左键聊天分享，插旗后自动亮起 EUI 3D 光柱并用 Polestar 画出跨图最短路线；移除标记时同步取消。",
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
    })
    y = y - h
    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "Polestar 指南与地图规划同步 3D 光柱",
        tooltip = "Polestar 指南步骤、Alt/Shift 规划或 /way 目标自动同步到 EUI 3D 光柱（多段跨图路线指向当前航段终点）。",
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
    }, {
        type = "toggle",
        text = "自动隐藏与暴雪标记重合的 Polestar 绿标",
        tooltip = "当暴雪黄菱形标记与 Polestar 目标点重合时，自动隐藏多余的绿色圆标（保留绿色虚线与 3D 箭头），避免大地图同时出现两个重叠标记。",
        getValue = function() return db.dedupPolestarPin ~= false end,
        setValue = function(v)
            db.dedupPolestarPin = v == true
            UpdatePolestarPinDedup()
        end,
    })
    y = y - h
    return y
end
