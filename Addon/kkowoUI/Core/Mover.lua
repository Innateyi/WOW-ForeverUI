----------------------------------------------------------------------
--  kkowoUI — Core/Mover.lua
--  统一框体定位：原生接入 EllesmereUI 解锁模式 + 兜底 Shift 拖拽
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pcall, type = ipairs, pcall, type
local UIParent = _G.UIParent
local InCombatLockdown = _G.InCombatLockdown

local Mover = {}
F.Mover = Mover

local VALID_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function IsValidPos(pos)
    if type(pos) ~= "table" then return false end
    local pt = F.PlainString(pos.point, nil)
    local rpt = pos.relPoint ~= nil and F.PlainString(pos.relPoint, nil) or nil
    local nx = F.PlainNumber(pos.x, nil)
    local ny = F.PlainNumber(pos.y, nil)
    return pt ~= nil and VALID_POINTS[pt] == true
        and (pos.relPoint == nil or (rpt ~= nil and VALID_POINTS[rpt] == true))
        and nx ~= nil and ny ~= nil
        and nx == nx and ny == ny
end

local registeredElements = {}
local registeredApply = {}
local pendingUnlock = {}
local flushed = false

function Mover.ApplyPosition(frame, key, defaultPoint, defaultRelPoint, defaultX, defaultY)
    if not frame then
        return
    end
    local function doApply()
        local saved = F.DB.GetPosition(key)
        if saved and not IsValidPos(saved) then
            F.DB.ClearPosition(key)
            saved = nil
        end
        local pt = (saved and F.PlainString(saved.point, nil)) or defaultPoint or "CENTER"
        local rpt = (saved and F.PlainString(saved.relPoint, nil)) or defaultRelPoint or pt
        local x = (saved and F.PlainNumber(saved.x, nil)) or defaultX or 0
        local y = (saved and F.PlainNumber(saved.y, nil)) or defaultY or 0
        if not VALID_POINTS[pt] then pt = "CENTER" end
        if not VALID_POINTS[rpt] then rpt = pt end
        if type(x) ~= "number" or x ~= x then x = 0 end
        if type(y) ~= "number" or y ~= y then y = 0 end
        frame:ClearAllPoints()
        frame:SetPoint(pt, UIParent, rpt, x, y)
    end
    if frame.IsProtected and frame:IsProtected() and InCombatLockdown and InCombatLockdown() then
        F.RunOutOfCombat("FUI_Move_" .. tostring(key), doApply)
        return
    end
    doApply()
end

function Mover.Register(opts)
    local key = opts.key
    local frame = opts.frame
    if not (key and frame) then
        return
    end
    if registeredApply[key] then
        registeredApply[key]()
        return registeredApply[key]
    end

    local defPt = opts.defaultPoint or "CENTER"
    local defRel = opts.defaultRelPoint or defPt
    local defX = opts.defaultX or 0
    local defY = opts.defaultY or 0

    local function applyPos()
        if opts.isAnchored and opts.isAnchored() then
            if opts.onReanchor then opts.onReanchor() end
            return
        end
        Mover.ApplyPosition(frame, key, defPt, defRel, defX, defY)
    end
    registeredApply[key] = applyPos

    applyPos()

    -- 兜底 Shift + 左键拖动（未开 EUI 解锁模式时也能微调；仅在真正开始拖动时才执行 StopMoving，避免误吞点击）
    if opts.allowShiftDrag ~= false then
        local dragging = false
        frame:SetMovable(true)
        frame:SetClampedToScreen(true)
        frame:RegisterForDrag("LeftButton")
        frame:HookScript("OnDragStart", function(self)
            if _G.IsShiftKeyDown() and not (InCombatLockdown and InCombatLockdown()) then
                dragging = true
                self:StartMoving()
            end
        end)
        frame:HookScript("OnDragStop", function(self)
            if not dragging then return end
            dragging = false
            if not (self.IsProtected and self:IsProtected() and InCombatLockdown and InCombatLockdown()) then
                self:StopMovingOrSizing()
            else
                F.RunOutOfCombat("FUI_StopDrag_" .. tostring(key), function()
                    if self.StopMovingOrSizing then pcall(self.StopMovingOrSizing, self) end
                end)
            end
            local pt, _, rpt, x, y = self:GetPoint(1)
            pt = F.PlainString(pt, nil)
            rpt = F.PlainString(rpt, nil)
            x = F.PlainNumber(x, nil)
            y = F.PlainNumber(y, nil)
            if pt and VALID_POINTS[pt] and x and y then
                F.DB.SavePosition(key, pt, (rpt and VALID_POINTS[rpt]) and rpt or pt, x, y)
            end
        end)
        frame:HookScript("OnHide", function(self)
            if not dragging then return end
            dragging = false
            if not (self.IsProtected and self:IsProtected() and InCombatLockdown and InCombatLockdown()) then
                self:StopMovingOrSizing()
            end
        end)
    end

    local EUI = _G.EllesmereUI
    if EUI and EUI.MakeUnlockElement then
        local el = EUI.MakeUnlockElement({
            key = "FUI_" .. key,
            label = opts.label or key,
            group = "kkowoUI",
            order = opts.order or 50,
            getFrame = function() return frame end,
            getSize = function() return frame:GetWidth(), frame:GetHeight() end,
            -- EUI UnlockMode 协议：savePosition(barKey, point, relPoint, x, y)
            -- 兼容直接 4 参调用或带首参 key 的 5 参调用，彻底杜绝坐标错位损坏
            savePos = function(a1, a2, a3, a4, a5)
                local p1 = F.PlainString(a1, nil)
                local n3 = F.PlainNumber(a3, nil)
                local pt, rpt, x, y
                if p1 and VALID_POINTS[p1] and n3 then
                    pt, rpt, x, y = p1, F.PlainString(a2, nil), n3, F.PlainNumber(a4, nil)
                else
                    pt, rpt, x, y = F.PlainString(a2, nil), F.PlainString(a3, nil), F.PlainNumber(a4, nil), F.PlainNumber(a5, nil)
                end
                if pt and VALID_POINTS[pt] and x and y then
                    F.DB.SavePosition(key, pt, (rpt and VALID_POINTS[rpt]) and rpt or pt, x, y)
                end
            end,
            -- EUI UnlockMode 协议：loadPosition(key) 必须返回 { point, relPoint, x, y } 表
            loadPos = function()
                local s = F.DB.GetPosition(key)
                if IsValidPos(s) then
                    return { point = s.point, relPoint = s.relPoint or s.point, x = s.x, y = s.y }
                end
                return { point = defPt, relPoint = defRel, x = defX, y = defY }
            end,
            clearPos = function()
                F.DB.ClearPosition(key)
                applyPos()
            end,
            applyPos = applyPos,
            noResize = true,
            isHidden = opts.isHidden,
            isAnchored = opts.isAnchored,
            ownsPosition = opts.ownsPosition,
            noInitHook = opts.noInitHook,
            getInsets = opts.getInsets,
            getBottomExtra = opts.getBottomExtra,
        })
        registeredElements[key] = el
        pendingUnlock[#pendingUnlock + 1] = el
        if flushed and EUI.RegisterUnlockElements then
            pcall(EUI.RegisterUnlockElements, EUI, { el }, F.NAME)
        end
    end

    return applyPos
end

function Mover.FlushRegistration()
    if flushed then
        return
    end
    flushed = true
    local EUI = _G.EllesmereUI
    if EUI and EUI.RegisterUnlockElements and #pendingUnlock > 0 then
        pcall(EUI.RegisterUnlockElements, EUI, pendingUnlock, F.NAME)
    end
end
