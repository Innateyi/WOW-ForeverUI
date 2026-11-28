----------------------------------------------------------------------
--  kkowoUI — Modules/GroundPin.lua
--  快捷键 + 鼠标点 3D 地面 → 借 C_Navigation 逆投影放置导航点并升起 3D 光柱：
--    • 绝不碰 C_PingSecure / 不 hook 暴雪帧 / 仅只读 C_Navigation.GetFrame()
--    • 自适应稳态采样（至少等 2 帧、连续 1 帧稳定、上限 6 帧）+ Broyden 拟牛顿法逆投影
--    • 严格机密值防御（先判 not F.IsSecret 再读值/比较），受限时立即中止并无损恢复原路点/任务追踪
--    • 零常驻 OnUpdate：仅求解进行中或瞄准态临时挂起，结束/进战/取消立刻卸除并 Hide
--    • 内置 /kk navprobe 一键诊断（测延迟/高度/试解并写入 kkowoUIDB._navprobe）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, math_abs, math_floor, math_max, math_min, math_sqrt, pcall, tostring, type =
    ipairs, math.abs, math.floor, math.max, math.min, math.sqrt, pcall, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown

local mod = F.RegisterModule("groundPin", {
    title = "鼠标点地插旗",
    desc = "按快捷键在鼠标指向的 3D 地面放置导航点并亮 3D 光柱，需先在按键设置中自行绑定快捷键。",
    group = "quest",
    order = 67,
    defaults = {
        enabled = true,
        mode = "instant", -- "instant" | "hold" | "click"
        maxRange = 400,   -- 100~600 码，默认 400
        debug = false,
    },
})

-- Bindings.xml 明确规定的 3 个显示名全局与 2 个转发全局函数（绝不自动绑定任何按键）
BINDING_HEADER_KKOWOUI_NAV = "kkowoUI 导航"
BINDING_NAME_KKOWOUI_GROUNDPIN = "在鼠标指向的地面放置导航点"
BINDING_NAME_KKOWOUI_GROUNDPIN_CLEAR = "清除导航点"

local MAX_ITER = 10
local MAX_SAMPLES = 16
local MAX_SOLVE_TIME = 1.2
local CONVERGE_PX = 2.5
local JACOBIAN_STEP = 6
local MIN_SETTLE_FRAMES = 2
local MAX_SETTLE_FRAMES = 6
local STABLE_EPS_PX = 0.5
local CLICK_TIMEOUT_SEC = 5.0

local solverFrame = nil
local crosshairFrame = nil
local clickCatcher = nil
local solveCtx = nil
local probeCtx = nil
local holdActive = false
local clickActive = false
local clickDeadline = 0

local function ShowUIError(msg)
    if not msg or msg == "" then return end
    if _G.UIErrorsFrame and type(_G.UIErrorsFrame.AddMessage) == "function" then
        pcall(_G.UIErrorsFrame.AddMessage, _G.UIErrorsFrame, msg, 1.0, 0.35, 0.30, 1.0)
    else
        F.Print(msg)
    end
end

local function DebugLog(fmt, ...)
    if mod:GetDB().debug == true then
        F.Print("[GroundPin] " .. string_format(fmt, ...))
    end
end

local function GetWaypointMod()
    return F.Modules and F.Modules.Get and F.Modules.Get("waypointAutoTrack") or nil
end

local function SafeCall1(fn, ...)
    if type(fn) ~= "function" then return false, nil end
    local ok, v = pcall(fn, ...)
    if not ok then return false, nil end
    return true, v
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

local function SnapshotWaypointState()
    local snap = {
        hasWp = false,
        wpMap = nil,
        wpX = nil,
        wpY = nil,
        trackWp = false,
        questID = 0,
    }
    local CM = _G.C_Map
    if CM and type(CM.HasUserWaypoint) == "function" and type(CM.GetUserWaypoint) == "function" then
        local okH, has = pcall(CM.HasUserWaypoint)
        if okH and not F.IsSecret(has) and has == true then
            local okG, wp = pcall(CM.GetUserWaypoint)
            if okG and not F.IsSecret(wp) and type(wp) == "table" and wp.position then
                local m = F.PlainNumber(wp.uiMapID, nil)
                local x, y = wp.position.x, wp.position.y
                if type(wp.position.GetXY) == "function" then
                    local okXY, gx, gy = pcall(wp.position.GetXY, wp.position)
                    if okXY then x, y = gx, gy end
                end
                x = F.PlainNumber(x, nil)
                y = F.PlainNumber(y, nil)
                if m and x and y then
                    snap.hasWp = true
                    snap.wpMap = m
                    snap.wpX = x
                    snap.wpY = y
                end
            end
        end
    end
    local CST = _G.C_SuperTrack
    if CST then
        if type(CST.IsSuperTrackingUserWaypoint) == "function" then
            local okT, isT = pcall(CST.IsSuperTrackingUserWaypoint)
            if okT and not F.IsSecret(isT) and isT == true then
                snap.trackWp = true
            end
        end
        if type(CST.GetSuperTrackedQuestID) == "function" then
            local okQ, qid = pcall(CST.GetSuperTrackedQuestID)
            if okQ then
                snap.questID = F.PlainNumber(qid, 0) or 0
            end
        end
    end
    return snap
end

local function RestoreWaypointState(snap, wa)
    local CM = _G.C_Map
    local CST = _G.C_SuperTrack
    if wa and type(wa.SetGroundSolving) == "function" then
        wa:SetGroundSolving(true)
    end
    if CM then
        if snap and snap.hasWp and snap.wpMap and snap.wpX and snap.wpY and type(CM.SetUserWaypoint) == "function" then
            local pt = MakeUiMapPoint(snap.wpMap, snap.wpX, snap.wpY)
            if pt then pcall(CM.SetUserWaypoint, pt) end
        elseif type(CM.ClearUserWaypoint) == "function" then
            pcall(CM.ClearUserWaypoint)
        end
    end
    local function ApplySuperTrackRestore()
        if CST then
            if snap and snap.trackWp and type(CST.SetSuperTrackedUserWaypoint) == "function" then
                pcall(CST.SetSuperTrackedUserWaypoint, true)
            else
                if type(CST.SetSuperTrackedUserWaypoint) == "function" then
                    pcall(CST.SetSuperTrackedUserWaypoint, false)
                end
                if snap and snap.questID and snap.questID > 0 and type(CST.SetSuperTrackedQuestID) == "function" then
                    pcall(CST.SetSuperTrackedQuestID, snap.questID)
                end
            end
        end
        if wa and type(wa.SetGroundSolving) == "function" then
            wa:SetGroundSolving(false)
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, ApplySuperTrackRestore)
    else
        ApplySuperTrackRestore()
    end
end

local function IsDescendantOf(frame, ancestor)
    if not (frame and ancestor) then return false end
    local cur = frame
    for _ = 1, 12 do
        if cur == ancestor then return true end
        if type(cur.GetParent) ~= "function" then return false end
        local ok, par = pcall(cur.GetParent, cur)
        if not ok or F.IsSecret(par) or not par then return false end
        cur = par
    end
    return false
end

local function CheckCursorOverWorld(ignoreOwnCatcher)
    local top = nil
    if type(_G.GetMouseFoci) == "function" then
        local ok, rawFoci = pcall(_G.GetMouseFoci)
        if ok and not F.IsSecret(rawFoci) and type(rawFoci) == "table" then
            local okLen, len = pcall(function() return #rawFoci end)
            if okLen and type(len) == "number" then
                for i = 1, math_min(len, 16) do
                    local fr = rawFoci[i]
                    if not F.IsSecret(fr) and type(fr) ~= "nil" then
                        if not (ignoreOwnCatcher and (fr == clickCatcher or fr == crosshairFrame)) then
                            top = fr
                            break
                        end
                    end
                end
            end
        end
    elseif type(_G.GetMouseFocus) == "function" then
        local ok, single = pcall(_G.GetMouseFocus)
        if ok and not F.IsSecret(single) and type(single) ~= "nil" then
            if not (ignoreOwnCatcher and (single == clickCatcher or single == crosshairFrame)) then
                top = single
            end
        end
    end

    if top == nil or top == _G.WorldFrame then
        return true, nil
    end
    if _G.Minimap and (top == _G.Minimap or IsDescendantOf(top, _G.Minimap)) then
        return false, "鼠标在小地图上，请用 Ctrl/Shift+左键插旗"
    end
    return false, "请将鼠标指向 3D 游戏地面"
end

local function ReadPlayerMapContext()
    local CM = _G.C_Map
    if not (CM and type(CM.GetBestMapForUnit) == "function"
        and type(CM.GetPlayerMapPosition) == "function"
        and type(CM.GetMapWorldSize) == "function"
        and type(CM.SetUserWaypoint) == "function") then
        return nil, "地图标记接口不可用"
    end
    local okM, rawMap = pcall(CM.GetBestMapForUnit, "player")
    local mapID = okM and F.PlainNumber(rawMap, nil) or nil
    if not mapID then
        return nil, "当前区域无法获取地图坐标"
    end
    if type(CM.CanSetUserWaypointOnMap) == "function" then
        local okCan, can = pcall(CM.CanSetUserWaypointOnMap, mapID)
        if not (okCan and not F.IsSecret(can) and can == true) then
            return nil, "当前地图不支持放置导航点"
        end
    end
    local okP, pos = pcall(CM.GetPlayerMapPosition, mapID, "player")
    if not (okP and not F.IsSecret(pos) and type(pos) == "table") then
        return nil, "无法获取玩家当前坐标"
    end
    local px, py = pos.x, pos.y
    if type(pos.GetXY) == "function" then
        local okXY, gx, gy = pcall(pos.GetXY, pos)
        if okXY then px, py = gx, gy end
    end
    px, py = F.PlainNumber(px, nil), F.PlainNumber(py, nil)
    if not (px and py) then
        return nil, "当前坐标受限，无法定位"
    end
    local okS, rawW, rawH = pcall(CM.GetMapWorldSize, mapID)
    local wYards = okS and F.PlainNumber(rawW, nil) or nil
    local hYards = okS and F.PlainNumber(rawH, nil) or nil
    if not (wYards and hYards and wYards > 1 and hYards > 1) then
        return nil, "无法获取当前地图尺度"
    end
    return { mapID = mapID, px = px, py = py, w = wYards, h = hYards }, nil
end

local function ValidateCanStart(ignoreOwnCatcher)
    if not mod._active then return nil, nil, nil end
    local wa = GetWaypointMod()
    if not (wa and wa._active) then
        return nil, nil, nil
    end
    if type(wa.IsReadyForGroundPin) == "function" and not wa:IsReadyForGroundPin() then
        return nil, nil, "请先在界面设置中开启游戏内导航"
    end
    if InCombatLockdown and InCombatLockdown() then
        return nil, nil, "战斗中无法放置地面导航点"
    end
    if type(_G.IsMouselooking) == "function" then
        local okML, ml = pcall(_G.IsMouselooking)
        if okML and not F.IsSecret(ml) and ml == true then
            return nil, nil, "正在转动视角，松开右键后再放置导航点"
        end
    end
    if type(_G.IsInInstance) == "function" then
        local okI, inInst = pcall(_G.IsInInstance)
        if okI and not F.IsSecret(inInst) and inInst == true then
            return nil, nil, "副本内不支持地面点击导航点"
        end
    end
    if solveCtx or probeCtx then
        return nil, nil, "正在计算落点，请稍候"
    end
    local overWorld, cursorErr = CheckCursorOverWorld(ignoreOwnCatcher)
    if not overWorld then
        return nil, nil, cursorErr
    end
    local mapCtx, mapErr = ReadPlayerMapContext()
    if not mapCtx then
        return nil, nil, mapErr
    end
    return wa, mapCtx, nil
end

-- 读取当前 C_Navigation 投影点：严格先排 secret，返回 status = "ok" | "invalid" | "secret"
local function ReadNavProjection()
    local CN = _G.C_Navigation
    if not (CN and type(CN.GetFrame) == "function") then
        return "invalid", nil, nil, nil, false
    end
    local okF, nav = pcall(CN.GetFrame)
    if not okF or F.IsSecret(nav) or type(nav) == "nil" then
        return "invalid", nil, nil, nil, false
    end
    if type(nav.IsForbidden) == "function" then
        local okFb, forb = pcall(nav.IsForbidden, nav)
        if not okFb or (not F.IsSecret(forb) and forb == true) then
            return "secret", nil, nil, nil, true
        end
    end
    local okV, valid = SafeCall1(CN.HasValidScreenPosition)
    if not okV or F.IsSecret(valid) or valid ~= true then
        return "invalid", nil, nil, nil, false
    end
    local okCl, clamped = SafeCall1(CN.WasClampedToScreen)
    if not okCl or F.IsSecret(clamped) or clamped == true then
        return "invalid", nil, nil, nil, false
    end
    if type(nav.GetCenter) ~= "function" or type(nav.GetEffectiveScale) ~= "function" then
        return "invalid", nil, nil, nil, false
    end
    local okC, cx, cy = pcall(nav.GetCenter, nav)
    local okSc, sc = pcall(nav.GetEffectiveScale, nav)
    if not (okC and okSc) then
        return "invalid", nil, nil, nil, false
    end
    if F.IsSecret(cx) or F.IsSecret(cy) or F.IsSecret(sc) then
        return "secret", nil, nil, nil, true
    end
    local pcx = F.PlainNumber(cx, nil)
    local pcy = F.PlainNumber(cy, nil)
    local psc = F.PlainNumber(sc, nil)
    if not (pcx and pcy and psc and psc > 0) then
        return "invalid", nil, nil, nil, false
    end
    local dist = nil
    if type(CN.GetDistance) == "function" then
        local okD, rawD = pcall(CN.GetDistance)
        if okD and not F.IsSecret(rawD) then
            dist = F.PlainNumber(rawD, nil)
        end
    end
    return "ok", pcx * psc, pcy * psc, dist, false
end

local function WriteProbeWaypoint(mapCtx, e, n, firstTrack)
    local tx = mapCtx.px + e / mapCtx.w
    local ty = mapCtx.py - n / mapCtx.h
    if tx < 0 or tx > 1 or ty < 0 or ty > 1 then
        return false, nil, nil
    end
    local pt = MakeUiMapPoint(mapCtx.mapID, tx, ty)
    if not pt then return false, nil, nil end
    local okW = pcall(_G.C_Map.SetUserWaypoint, pt)
    if not okW then return false, nil, nil end
    local CST = _G.C_SuperTrack
    if CST and type(CST.SetSuperTrackedUserWaypoint) == "function" then
        local needTrack = firstTrack == true
        if not needTrack and type(CST.IsSuperTrackingUserWaypoint) == "function" then
            local okT, isT = pcall(CST.IsSuperTrackingUserWaypoint)
            if not (okT and not F.IsSecret(isT) and isT == true) then
                needTrack = true
            end
        end
        if needTrack then
            pcall(CST.SetSuperTrackedUserWaypoint, true)
        end
    end
    return true, tx, ty
end

local function StopSolverFrameIfIdle()
    if solverFrame and (not solveCtx) and (not probeCtx) then
        solverFrame:SetScript("OnUpdate", nil)
        solverFrame:Hide()
    end
end

local function EnsureSolverFrame()
    if not solverFrame then
        solverFrame = CreateFrame("Frame")
        solverFrame:Hide()
    end
    return solverFrame
end

----------------------------------------------------------------------
--  1) 异步自适应稳态 Broyden 逆投影求解器（0 常驻 OnUpdate）
----------------------------------------------------------------------
local function FinishSolve(success, reason)
    local ctx = solveCtx
    if not ctx then return end
    solveCtx = nil
    StopSolverFrameIfIdle()

    local elapsedMs = math_floor((GetTime() - ctx.startTime) * 1000 + 0.5)
    local distYards = math_sqrt(ctx.uE * ctx.uE + ctx.uN * ctx.uN)

    if success then
        local tx = ctx.mapCtx.px + ctx.uE / ctx.mapCtx.w
        local ty = ctx.mapCtx.py - ctx.uN / ctx.mapCtx.h
        DebugLog("收敛成功: iter=%d samples=%d err=%.2fpx dist=%.1fyd time=%dms (%.1f, %.1f)",
            ctx.iter, ctx.samples, ctx.lastErr or 0, distYards, elapsedMs, tx * 100, ty * 100)
        if ctx.dryRun then
            RestoreWaypointState(ctx.savedSnap, ctx.wa)
        else
            local committed = false
            if ctx.wa and type(ctx.wa.CommitManualPin) == "function" then
                committed = ctx.wa:CommitManualPin(ctx.mapCtx.mapID, tx, ty) == true
            end
            if not committed then
                RestoreWaypointState(ctx.savedSnap, ctx.wa)
                ShowUIError("放置导航点失败，已恢复原标记")
                if type(ctx.onDone) == "function" then
                    ctx.onDone({ ok = false, reason = "commit_failed", samples = ctx.samples, elapsedMs = elapsedMs, distYards = distYards, iterLog = ctx.iterLog })
                end
                return
            end
        end
        if type(ctx.onDone) == "function" then
            ctx.onDone({
                ok = true,
                mapID = ctx.mapCtx.mapID,
                x = tx, y = ty,
                uE = ctx.uE, uN = ctx.uN,
                errPx = ctx.lastErr or 0,
                samples = ctx.samples,
                iter = ctx.iter,
                elapsedMs = elapsedMs,
                distYards = distYards,
                iterLog = ctx.iterLog,
            })
        end
    else
        DebugLog("求解失败(%s): iter=%d samples=%d time=%dms",
            tostring(reason), ctx.iter, ctx.samples, elapsedMs)
        RestoreWaypointState(ctx.savedSnap, ctx.wa)
        if not ctx.dryRun and reason then
            ShowUIError(reason)
        end
        if type(ctx.onDone) == "function" then
            ctx.onDone({
                ok = false,
                reason = reason or "failed",
                samples = ctx.samples,
                iter = ctx.iter,
                elapsedMs = elapsedMs,
                distYards = distYards,
                iterLog = ctx.iterLog,
            })
        end
    end
end

local function BeginMeasure(ctx, e, n, tag)
    if ctx.samples >= MAX_SAMPLES then
        FinishSolve(false, "采样超限，请指向更清晰的地面")
        return false
    end
    if (GetTime() - ctx.startTime) > MAX_SOLVE_TIME then
        FinishSolve(false, "定位超时，请重试")
        return false
    end
    local okW = WriteProbeWaypoint(ctx.mapCtx, e, n, ctx.samples == 0)
    if not okW then
        FinishSolve(false, "目标超出当前地图范围")
        return false
    end
    ctx.samples = ctx.samples + 1
    ctx.mTag = tag
    ctx.mE = e
    ctx.mN = n
    ctx.mFrames = 0
    ctx.mLastX = nil
    ctx.mLastY = nil
    ctx.mChangedFromPrev = (ctx.prevSampleX == nil)
    return true
end

local function AdvanceSolveAfterSample(ctx, okSample, sx, sy, secretHit)
    if secretHit then
        FinishSolve(false, "当前场景导航坐标受限，无法定位地面")
        return
    end
    if okSample then
        ctx.prevSampleX = sx
        ctx.prevSampleY = sy
    end

    local tag = ctx.mTag
    if tag == "S0" then
        if not okSample then
            FinishSolve(false, "无法读取导航投影（请确认已开启游戏内导航）")
            return
        end
        ctx.uE, ctx.uN = 0, 0
        ctx.sX, ctx.sY = sx, sy
        BeginMeasure(ctx, JACOBIAN_STEP, 0, "J_E")
        return
    end

    if tag == "J_E" then
        if not okSample then
            FinishSolve(false, "导航投影采样失败，请调整视角后重试")
            return
        end
        ctx.jeX, ctx.jeY = sx, sy
        BeginMeasure(ctx, ctx.jBaseE or 0, (ctx.jBaseN or 0) + JACOBIAN_STEP, "J_N")
        return
    end

    if tag == "J_N" then
        if not okSample then
            FinishSolve(false, "导航投影采样失败，请调整视角后重试")
            return
        end
        local bX, bY = ctx.sX, ctx.sY
        ctx.j11 = (ctx.jeX - bX) / JACOBIAN_STEP
        ctx.j21 = (ctx.jeY - bY) / JACOBIAN_STEP
        ctx.j12 = (sx - bX) / JACOBIAN_STEP
        ctx.j22 = (sy - bY) / JACOBIAN_STEP
        -- 进入下一轮牛顿步
        ctx.btCount = 0
        ctx.needStep = true
        return
    end

    if tag == "STEP" then
        local rPrev = ctx.curErr or 1e9
        local newErr = okSample and math_sqrt((ctx.tx - sx) * (ctx.tx - sx) + (ctx.ty - sy) * (ctx.ty - sy)) or 1e9
        if (not okSample) or (newErr >= rPrev) then
            -- 减半步长回溯，最多 3 次
            if (ctx.btCount or 0) < 3 then
                ctx.btCount = (ctx.btCount or 0) + 1
                ctx.dE = ctx.dE * 0.5
                ctx.dN = ctx.dN * 0.5
                local ne, nn = ctx.uE + ctx.dE, ctx.uN + ctx.dN
                if math_sqrt(ne * ne + nn * nn) > ctx.maxRange then
                    FinishSolve(false, "太远或指向了天空")
                    return
                end
                BeginMeasure(ctx, ne, nn, "STEP")
                return
            end
            -- 回溯仍失败：允许在当前 u 处重测一次雅可比
            if not ctx.rejacUsed then
                ctx.rejacUsed = true
                ctx.jBaseE, ctx.jBaseN = ctx.uE, ctx.uN
                BeginMeasure(ctx, ctx.uE + JACOBIAN_STEP, ctx.uN, "J_E")
                return
            end
            FinishSolve(false, "无法收敛到目标地面（可能指向天空或遮挡物）")
            return
        end

        -- Broyden 拟牛顿秩 1 更新：J = J + ((S' - S) - J*Δ) * Δ^T / (Δ^T * Δ)
        local dE, dN = ctx.dE, ctx.dN
        local denom = dE * dE + dN * dN
        if denom > 1e-9 then
            local yx = sx - ctx.sX
            local yy = sy - ctx.sY
            local jdx = ctx.j11 * dE + ctx.j12 * dN
            local jdy = ctx.j21 * dE + ctx.j22 * dN
            local dfx = yx - jdx
            local dfy = yy - jdy
            ctx.j11 = ctx.j11 + dfx * dE / denom
            ctx.j12 = ctx.j12 + dfx * dN / denom
            ctx.j21 = ctx.j21 + dfy * dE / denom
            ctx.j22 = ctx.j22 + dfy * dN / denom
        end

        ctx.uE = ctx.uE + dE
        ctx.uN = ctx.uN + dN
        ctx.sX, ctx.sY = sx, sy
        ctx.lastErr = newErr
        ctx.iterLog[#ctx.iterLog + 1] = { iter = ctx.iter, errPx = newErr, distYards = math_sqrt(ctx.uE * ctx.uE + ctx.uN * ctx.uN) }
        DebugLog("iter %d: err=%.2fpx dist=%.1fyd", ctx.iter, newErr, math_sqrt(ctx.uE * ctx.uE + ctx.uN * ctx.uN))
        if newErr <= CONVERGE_PX then
            FinishSolve(true, nil)
            return
        end
        ctx.needStep = true
    end
end

local function IssueNextNewtonStep(ctx)
    ctx.needStep = false
    local rx = ctx.tx - ctx.sX
    local ry = ctx.ty - ctx.sY
    local err = math_sqrt(rx * rx + ry * ry)
    ctx.curErr = err
    ctx.lastErr = err
    if err <= CONVERGE_PX then
        FinishSolve(true, nil)
        return
    end
    ctx.iter = ctx.iter + 1
    if ctx.iter > MAX_ITER then
        FinishSolve(false, "超过最大迭代次数，请指向更近的地面")
        return
    end
    local det = ctx.j11 * ctx.j22 - ctx.j12 * ctx.j21
    if math_abs(det) < 1e-6 then
        if not ctx.rejacUsed then
            ctx.rejacUsed = true
            ctx.jBaseE, ctx.jBaseN = ctx.uE, ctx.uN
            BeginMeasure(ctx, ctx.uE + JACOBIAN_STEP, ctx.uN, "J_E")
            return
        end
        FinishSolve(false, "当前视角过于平直，无法定位地面")
        return
    end
    local dE = (ctx.j22 * rx - ctx.j12 * ry) / det
    local dN = (-ctx.j21 * rx + ctx.j11 * ry) / det
    local stepLen = math_sqrt(dE * dE + dN * dN)
    local uLen = math_sqrt(ctx.uE * ctx.uE + ctx.uN * ctx.uN)
    local maxStep = math_max(15, 0.75 * uLen + 15)
    if stepLen > maxStep and stepLen > 1e-6 then
        local sc = maxStep / stepLen
        dE = dE * sc
        dN = dN * sc
    end
    local nextE = ctx.uE + dE
    local nextN = ctx.uN + dN
    if math_sqrt(nextE * nextE + nextN * nextN) > ctx.maxRange then
        FinishSolve(false, "太远或指向了天空")
        return
    end
    ctx.dE, ctx.dN = dE, dN
    ctx.btCount = 0
    BeginMeasure(ctx, nextE, nextN, "STEP")
end

local function TickSolver()
    local ctx = solveCtx
    if not ctx then return end
    if InCombatLockdown and InCombatLockdown() then
        FinishSolve(false, "进入战斗，已取消地面导航定位")
        return
    end
    if (GetTime() - ctx.startTime) > MAX_SOLVE_TIME then
        FinishSolve(false, "定位超时，请重试")
        return
    end

    ctx.mFrames = ctx.mFrames + 1
    local status, sx, sy, dist, secretHit = ReadNavProjection()
    if secretHit then
        AdvanceSolveAfterSample(ctx, false, nil, nil, true)
        return
    end

    local settled = false
    local validSample = false
    if status == "ok" then
        if ctx.prevSampleX ~= nil then
            local dPrev = math_sqrt((sx - ctx.prevSampleX) * (sx - ctx.prevSampleX) + (sy - ctx.prevSampleY) * (sy - ctx.prevSampleY))
            if dPrev > STABLE_EPS_PX then
                ctx.mChangedFromPrev = true
            end
        end
        local stableFromLast = false
        if ctx.mLastX ~= nil then
            local dLast = math_sqrt((sx - ctx.mLastX) * (sx - ctx.mLastX) + (sy - ctx.mLastY) * (sy - ctx.mLastY))
            stableFromLast = (dLast <= STABLE_EPS_PX)
        end
        ctx.mLastX, ctx.mLastY = sx, sy

        if ctx.mFrames >= MIN_SETTLE_FRAMES then
            if (ctx.mChangedFromPrev and stableFromLast) or ctx.mFrames >= MAX_SETTLE_FRAMES then
                settled = true
                -- 防止导航指向中转点：d3 明显小于水平距离 d2 时采样作废
                local d2 = math_sqrt(ctx.mE * ctx.mE + ctx.mN * ctx.mN)
                if dist ~= nil and d2 > 5 and dist < (0.8 * d2 - 3) then
                    validSample = false
                else
                    validSample = true
                end
            end
        end
    elseif ctx.mFrames >= MAX_SETTLE_FRAMES then
        settled = true
        validSample = false
    end

    if settled then
        AdvanceSolveAfterSample(ctx, validSample, sx, sy, false)
        if solveCtx and solveCtx.needStep then
            IssueNextNewtonStep(solveCtx)
        end
    end
end

local function StartSolveAtCursor(tx, ty, wa, mapCtx, opts)
    opts = opts or {}
    local db = mod:GetDB()
    local maxRange = math_max(100, math_min(600, F.PlainNumber(db.maxRange, 400) or 400))
    local savedSnap = SnapshotWaypointState()
    if wa and type(wa.SetGroundSolving) == "function" then
        wa:SetGroundSolving(true)
    end
    solveCtx = {
        wa = wa,
        mapCtx = mapCtx,
        savedSnap = savedSnap,
        tx = tx, ty = ty,
        maxRange = maxRange,
        startTime = GetTime(),
        samples = 0,
        iter = 0,
        uE = 0, uN = 0,
        sX = 0, sY = 0,
        j11 = 0, j12 = 0, j21 = 0, j22 = 0,
        jBaseE = 0, jBaseN = 0,
        rejacUsed = false,
        dryRun = opts.dryRun == true,
        onDone = opts.onDone,
        iterLog = {},
    }
    if not BeginMeasure(solveCtx, 0, 0, "S0") then
        return false
    end
    local f = EnsureSolverFrame()
    f:SetScript("OnUpdate", TickSolver)
    f:Show()
    return true
end

----------------------------------------------------------------------
--  2) 瞄准准星与点击捕获层（hold / click 模式；空闲时 Hide + 0 OnUpdate）
----------------------------------------------------------------------
local function EnsureCrosshair()
    if crosshairFrame then return crosshairFrame end
    local f = CreateFrame("Frame", "kkowoUI_GroundPinCrosshair", _G.UIParent)
    f:SetSize(28, 28)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(200)
    f:EnableMouse(false)

    local h = f:CreateTexture(nil, "OVERLAY")
    h:SetSize(20, 2)
    h:SetPoint("CENTER", f, "CENTER", 0, 0)
    h:SetColorTexture(0.45, 0.90, 1.00, 0.92)

    local v = f:CreateTexture(nil, "OVERLAY")
    v:SetSize(2, 20)
    v:SetPoint("CENTER", f, "CENTER", 0, 0)
    v:SetColorTexture(0.45, 0.90, 1.00, 0.92)

    local hint = f:CreateFontString(nil, "OVERLAY")
    if F.StyleTokens and F.StyleTokens.ApplyText then
        F.StyleTokens.ApplyText(hint, 12, 0.92, 0.96, 1.00, 1)
    elseif hint.SetFont then
        pcall(hint.SetFont, hint, "Fonts\\ARHei.ttf", 12, "OUTLINE")
    end
    hint:SetPoint("TOP", f, "BOTTOM", 0, -6)
    hint:SetJustifyH("CENTER")
    f._hint = hint

    f:Hide()
    crosshairFrame = f
    return f
end

local function PositionCrosshairAtCursor()
    if not (crosshairFrame and type(_G.GetCursorPosition) == "function") then return end
    local ok, cx, cy = pcall(_G.GetCursorPosition)
    if not ok then return end
    cx, cy = F.PlainNumber(cx, nil), F.PlainNumber(cy, nil)
    local sc = _G.UIParent and _G.UIParent.GetEffectiveScale and F.PlainNumber(_G.UIParent:GetEffectiveScale(), 1) or 1
    if cx and cy and sc and sc > 0 then
        crosshairFrame:ClearAllPoints()
        crosshairFrame:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", cx / sc, cy / sc)
    end
end

local function CancelAiming()
    holdActive = false
    clickActive = false
    if crosshairFrame then
        crosshairFrame:SetScript("OnUpdate", nil)
        crosshairFrame:Hide()
    end
    if clickCatcher then
        clickCatcher:SetScript("OnUpdate", nil)
        if clickCatcher.EnableKeyboard then pcall(clickCatcher.EnableKeyboard, clickCatcher, false) end
        clickCatcher:Hide()
    end
end

local function TriggerSolveFromCurrentCursor(ignoreOwnCatcher)
    local wa, mapCtx, err = ValidateCanStart(ignoreOwnCatcher)
    if not wa then
        if err then ShowUIError(err) end
        return false
    end
    if type(_G.GetCursorPosition) ~= "function" then
        ShowUIError("无法读取鼠标位置")
        return false
    end
    local ok, tx, ty = pcall(_G.GetCursorPosition)
    tx, ty = ok and F.PlainNumber(tx, nil) or nil, ok and F.PlainNumber(ty, nil) or nil
    if not (tx and ty) then
        ShowUIError("无法读取鼠标位置")
        return false
    end
    return StartSolveAtCursor(tx, ty, wa, mapCtx)
end

local function StartHoldAim()
    local wa, _, err = ValidateCanStart(false)
    if not wa then
        if err then ShowUIError(err) end
        return
    end
    CancelAiming()
    holdActive = true
    local ch = EnsureCrosshair()
    ch._hint:SetText("松开放置导航点")
    PositionCrosshairAtCursor()
    ch:SetScript("OnUpdate", function()
        if not holdActive or (InCombatLockdown and InCombatLockdown()) then
            CancelAiming()
            return
        end
        PositionCrosshairAtCursor()
    end)
    ch:Show()
end

local function EnsureClickCatcher()
    if clickCatcher then return clickCatcher end
    local btn = CreateFrame("Button", "kkowoUI_GroundPinCatcher", _G.UIParent)
    btn:SetAllPoints(_G.UIParent)
    btn:SetFrameStrata("FULLSCREEN_DIALOG")
    btn:SetFrameLevel(180)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouseBtn)
        if not clickActive then
            CancelAiming()
            return
        end
        CancelAiming()
        if mouseBtn == "LeftButton" then
            TriggerSolveFromCurrentCursor(true)
        end
    end)
    btn:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            if self.SetPropagateKeyboardInput then pcall(self.SetPropagateKeyboardInput, self, false) end
            CancelAiming()
        else
            -- 非 Esc 键必须放行，绝不吞掉移动或技能键
            if self.SetPropagateKeyboardInput then pcall(self.SetPropagateKeyboardInput, self, true) end
        end
    end)
    btn:Hide()
    clickCatcher = btn
    return btn
end

local function StartClickAim()
    local wa, _, err = ValidateCanStart(false)
    if not wa then
        if err then ShowUIError(err) end
        return
    end
    CancelAiming()
    clickActive = true
    clickDeadline = GetTime() + CLICK_TIMEOUT_SEC
    local ch = EnsureCrosshair()
    ch._hint:SetText("左键点地面放置 / 右键或 Esc 取消")
    PositionCrosshairAtCursor()
    ch:Show()

    local btn = EnsureClickCatcher()
    if btn.EnableKeyboard then pcall(btn.EnableKeyboard, btn, true) end
    btn:SetScript("OnUpdate", function()
        if not clickActive or (InCombatLockdown and InCombatLockdown()) or GetTime() >= clickDeadline then
            CancelAiming()
            return
        end
        PositionCrosshairAtCursor()
    end)
    btn:Show()
end

----------------------------------------------------------------------
--  3) 全局快捷键入口转发
----------------------------------------------------------------------
function mod:HandleKeyBinding(keystate)
    if not mod._active then return end
    local wa = GetWaypointMod()
    if not (wa and wa._active) then return end

    local mode = mod:GetDB().mode or "instant"
    if mode == "instant" then
        if keystate == "down" or keystate == nil then
            TriggerSolveFromCurrentCursor(false)
        end
    elseif mode == "hold" then
        if keystate == "down" then
            StartHoldAim()
        elseif keystate == "up" and holdActive then
            CancelAiming()
            TriggerSolveFromCurrentCursor(false)
        end
    elseif mode == "click" then
        if keystate == "down" then
            if clickActive then
                CancelAiming()
            else
                StartClickAim()
            end
        end
    end
end

function mod:ClearWaypoint()
    if not mod._active then return end
    local wa = GetWaypointMod()
    if not (wa and wa._active) then return end
    CancelAiming()
    if solveCtx then
        FinishSolve(false, nil)
    end
    if _G.C_Map and type(_G.C_Map.ClearUserWaypoint) == "function" then
        pcall(_G.C_Map.ClearUserWaypoint)
    end
end

function kkowoUI_GroundPin_OnKey(keystate)
    mod:HandleKeyBinding(keystate)
end

function kkowoUI_GroundPin_Clear()
    mod:ClearWaypoint()
end

----------------------------------------------------------------------
--  4) /kk navprobe 一键探针（测帧延迟 K / 4 方向高差 dz / 试解，写入 kkowoUIDB._navprobe）
----------------------------------------------------------------------
local PROBE_DIRS = {
    { name = "E", e = 25,  n = 0 },
    { name = "W", e = -25, n = 0 },
    { name = "N", e = 0,   n = 25 },
    { name = "S", e = 0,   n = -25 },
}

local function FinishNavProbe(p)
    probeCtx = nil
    StopSolverFrameIfIdle()
    RestoreWaypointState(p.savedSnap, p.wa)

    local store = p.report
    if type(_G.kkowoUIDB) == "table" then
        _G.kkowoUIDB._navprobe = store
    end

    F.Print("GroundPin 探针 (/kk navprobe) 完成，数据已写入 kkowoUIDB._navprobe：")
    _G.print(string_format("  1) 导航帧：无标记存在=%s | 有标记存在=%s | 坐标机密=%s",
        tostring(store.hasFrameBefore), tostring(store.hasFrameWithWp), tostring(store.coordSecret)))
    _G.print(string_format("  2) 投影延迟：首变帧=%s | 稳定帧=%s | 建议K=%s",
        tostring(store.firstChangeFrame), tostring(store.stableFrame), tostring(store.suggestedK)))
    local hParts = {}
    for _, h in ipairs(store.heights or {}) do
        hParts[#hParts + 1] = string_format("%s:d2=%.0f/d3=%s/dz=%s",
            h.dir, h.d2, h.d3 and string_format("%.1f", h.d3) or "?", h.dz and string_format("%.1f", h.dz) or "?")
    end
    _G.print("  3) 25码四向高差：" .. (#hParts > 0 and table.concat(hParts, " | ") or "无有效读数"))
    if store.trial then
        _G.print(string_format("  4) 试解：ok=%s | err=%.2fpx | samples=%d | %dms | dist=%.1fyd | reason=%s",
            tostring(store.trial.ok), store.trial.errPx or -1, store.trial.samples or 0,
            store.trial.elapsedMs or 0, store.trial.distYards or 0, tostring(store.trial.reason or "ok")))
    end
end

local function TickNavProbe()
    local p = probeCtx
    if not p then return end
    if InCombatLockdown and InCombatLockdown() then
        p.report.aborted = "combat"
        FinishNavProbe(p)
        return
    end
    p.frames = p.frames + 1

    if p.stage == "latency_base" then
        if p.frames >= 2 then
            local st, sx, sy, _, sec = ReadNavProjection()
            p.report.hasFrameWithWp = (_G.C_Navigation and _G.C_Navigation.GetFrame and _G.C_Navigation.GetFrame() ~= nil) or false
            if sec then p.report.coordSecret = true end
            p.baseX, p.baseY = sx, sy
            p.stage = "latency_east"
            p.frames = 0
            p.lastX, p.lastY = sx, sy
            WriteProbeWaypoint(p.mapCtx, 20, 0, false)
            p.report.latencyFrames = {}
        end
        return
    end

    if p.stage == "latency_east" then
        local st, sx, sy, _, sec = ReadNavProjection()
        if sec then p.report.coordSecret = true end
        local dx = (sx and p.baseX) and (sx - p.baseX) or nil
        local dy = (sy and p.baseY) and (sy - p.baseY) or nil
        local movedFromBase = (dx and dy) and math_sqrt(dx * dx + dy * dy) or nil
        p.report.latencyFrames[#p.report.latencyFrames + 1] = {
            frame = p.frames, status = st, x = sx, y = sy, deltaFromBase = movedFromBase,
        }
        if movedFromBase and movedFromBase > 0.5 and not p.report.firstChangeFrame then
            p.report.firstChangeFrame = p.frames
        end
        if p.report.firstChangeFrame and sx and sy and p.lastX and p.lastY then
            local step = math_sqrt((sx - p.lastX) * (sx - p.lastX) + (sy - p.lastY) * (sy - p.lastY))
            if step <= STABLE_EPS_PX and not p.report.stableFrame then
                p.report.stableFrame = p.frames
                p.report.suggestedK = math_max(2, p.frames)
            end
        end
        p.lastX, p.lastY = sx, sy
        if p.report.stableFrame or p.frames >= 8 then
            p.report.suggestedK = p.report.suggestedK or 2
            p.stage = "heights"
            p.dirIdx = 1
            p.frames = 0
            p.report.heights = {}
            local d = PROBE_DIRS[1]
            WriteProbeWaypoint(p.mapCtx, d.e, d.n, false)
        end
        return
    end

    if p.stage == "heights" then
        if p.frames >= (p.report.suggestedK or 2) then
            local d = PROBE_DIRS[p.dirIdx]
            local _, _, _, d3, sec = ReadNavProjection()
            if sec then p.report.coordSecret = true end
            local d2 = math_sqrt(d.e * d.e + d.n * d.n)
            local dz = (d3 and d3 >= 0) and math_sqrt(math_max(0, d3 * d3 - d2 * d2)) or nil
            p.report.heights[#p.report.heights + 1] = { dir = d.name, d2 = d2, d3 = d3, dz = dz }
            p.dirIdx = p.dirIdx + 1
            if p.dirIdx <= #PROBE_DIRS then
                local nd = PROBE_DIRS[p.dirIdx]
                p.frames = 0
                WriteProbeWaypoint(p.mapCtx, nd.e, nd.n, false)
            else
                -- 阶段 4：试解一次（不提交）
                local savedP = p
                probeCtx = nil
                StopSolverFrameIfIdle()
                if savedP.report.coordSecret then
                    savedP.report.trial = { ok = false, reason = "coord_secret" }
                    FinishNavProbe(savedP)
                    return
                end
                StartSolveAtCursor(savedP.cursorX, savedP.cursorY, savedP.wa, savedP.mapCtx, {
                    dryRun = true,
                    onDone = function(res)
                        savedP.report.trial = res
                        FinishNavProbe(savedP)
                    end,
                })
            end
        end
    end
end

function mod:RunNavProbe()
    if InCombatLockdown and InCombatLockdown() then
        ShowUIError("请脱战后再运行 /kk navprobe")
        return false
    end
    if solveCtx or probeCtx then
        ShowUIError("探针或定位正在运行中，请稍候")
        return false
    end
    local wa = GetWaypointMod()
    if wa and type(wa.IsReadyForGroundPin) == "function" then
        wa:IsReadyForGroundPin()
    end
    local mapCtx, mapErr = ReadPlayerMapContext()
    if not mapCtx then
        ShowUIError(mapErr or "无法获取当前地图信息")
        return false
    end
    local cx, cy = 640, 360
    if type(_G.GetCursorPosition) == "function" then
        local ok, gx, gy = pcall(_G.GetCursorPosition)
        if ok then
            cx = F.PlainNumber(gx, cx) or cx
            cy = F.PlainNumber(gy, cy) or cy
        end
    end

    local savedSnap = SnapshotWaypointState()
    local CN = _G.C_Navigation
    local hasBefore = (CN and type(CN.GetFrame) == "function" and CN.GetFrame() ~= nil) or false
    if wa and type(wa.SetGroundSolving) == "function" then
        wa:SetGroundSolving(true)
    end
    WriteProbeWaypoint(mapCtx, 0, 0, true)

    probeCtx = {
        wa = wa,
        mapCtx = mapCtx,
        savedSnap = savedSnap,
        cursorX = cx,
        cursorY = cy,
        stage = "latency_base",
        frames = 0,
        report = {
            timestamp = GetTime(),
            mapID = mapCtx.mapID,
            hasFrameBefore = hasBefore,
            hasFrameWithWp = false,
            coordSecret = false,
        },
    }
    local f = EnsureSolverFrame()
    f:SetScript("OnUpdate", TickNavProbe)
    f:Show()
    return true
end

function mod:HandleSlash(rest)
    local arg = ((rest or ""):gsub("^%s+", ""):gsub("%s+$", "")):lower()
    if arg == "debug on" or arg == "on" then
        self:GetDB().debug = true
        F.Print("已开启 GroundPin 求解调试日志。")
    elseif arg == "debug off" or arg == "off" then
        self:GetDB().debug = false
        F.Print("已关闭 GroundPin 求解调试日志。")
    elseif arg == "probe" then
        self:RunNavProbe()
    elseif arg == "clear" then
        self:ClearWaypoint()
    else
        F.Print("用法：/kk groundpin debug on|off | /kk navprobe")
    end
end

----------------------------------------------------------------------
--  5) 生命周期与设置面板
----------------------------------------------------------------------
function mod:OnEnable()
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        CancelAiming()
        if solveCtx then
            FinishSolve(false, "进入战斗，已取消地面导航定位")
        end
        if probeCtx then
            probeCtx.report.aborted = "combat"
            FinishNavProbe(probeCtx)
        end
    end)
end

function mod:OnDisable()
    CancelAiming()
    if solveCtx then
        FinishSolve(false, nil)
    end
    if probeCtx then
        probeCtx.report.aborted = "disabled"
        FinishNavProbe(probeCtx)
    end
end

local function OpenKeybindingsUI()
    if _G.Settings and type(_G.Settings.OpenToCategory) == "function" and _G.Settings.KEYBINDINGS_CATEGORY_ID then
        pcall(_G.Settings.OpenToCategory, _G.Settings.KEYBINDINGS_CATEGORY_ID)
        return
    end
    if type(_G.KeyBindingFrame_LoadUI) == "function" then
        pcall(_G.KeyBindingFrame_LoadUI)
        if _G.KeyBindingFrame and _G.KeyBindingFrame.Show then
            pcall(_G.KeyBindingFrame.Show, _G.KeyBindingFrame)
            return
        end
    end
    F.Print("请按 Esc → 选项 → 快捷键 → 插件（kkowoUI 导航）自行绑定按键。")
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "交互方式",
        tooltip = "即时：按下时直接按鼠标当前位置放置；按住：松开放置；点击：进入瞄准后左键点地面放置。",
        values = {
            instant = "即时（按下即放，推荐）",
            hold    = "按住瞄准（松开放置）",
            click   = "点击瞄准（左键放置 / 右键取消）",
        },
        order = { "instant", "hold", "click" },
        getValue = function() return db.mode or "instant" end,
        setValue = function(v) db.mode = v or "instant" end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "最大放置距离 (码)",
        tooltip = "超过该距离或指向天空时自动放弃并恢复原导航点，默认 400 码。",
        min = 100, max = 600, step = 20,
        getValue = function() return F.PlainNumber(db.maxRange, 400) or 400 end,
        setValue = function(v) db.maxRange = math_max(100, math_min(600, math_floor((v or 400) + 0.5))) end,
    }, {
        type = "labeledButton",
        text = "快捷键设置",
        buttonText = "打开按键设置",
        width = 120,
        tooltip = "请到 Esc → 选项 → 快捷键 → 插件（kkowoUI 导航）中为『在鼠标指向的地面放置导航点』绑定按键（切勿绑定到『选中焦点』）。",
        onClick = OpenKeybindingsUI,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "输出求解调试日志",
        tooltip = "每次放置时在聊天框打印迭代残差、采样次数与耗时（/kk groundpin debug on|off）。",
        getValue = function() return db.debug == true end,
        setValue = function(v) db.debug = v == true end,
    }, {
        type = "labeledButton",
        text = "定位诊断探针",
        buttonText = "运行 /kk navprobe",
        width = 132,
        tooltip = "脱战站在野外运行：自动测帧延迟、四向高差与试解，并将结果写入存档。",
        onClick = function() mod:RunNavProbe() end,
    })
    y = y - h

    return y
end
