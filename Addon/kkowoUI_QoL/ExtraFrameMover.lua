----------------------------------------------------------------------
--  kkowoUI — Modules/ExtraFrameMover.lua
--  补齐 EllesmereUI Shifter 未收录的 3 个无限服常用非战斗窗体拖动与缩放
--  （替代独立 BlizzMove 插件，零污染，绝不向暴雪框体写自定义字段）：
--    • GameMenuFrame（ESC 系统菜单，默认记忆 0.80 缩放与位置）
--    • TaxiFrame（经典鸟点飞行地图）
--    • TradeFrame（玩家交易窗口）
--  操作手感与 EUI Shifter 完全一致：
--    • Shift + 左键拖动：永久保存位置
--    • Ctrl + 滚轮：调整缩放（0.60 ~ 1.40）并永久保存
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_floor, math_max, math_min, pairs, pcall, setmetatable, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, setmetatable, type
local InCombatLockdown = InCombatLockdown
local IsShiftKeyDown = IsShiftKeyDown
local IsControlKeyDown = IsControlKeyDown
local C_Timer = C_Timer

local TARGET_FRAMES = {
    { name = "GameMenuFrame", label = "ESC 菜单", defaultScale = 0.80 },
    { name = "TaxiFrame",     label = "飞行路线图", defaultScale = 1.00 },
    { name = "TradeFrame",    label = "交易窗口",   defaultScale = 1.00 },
}

local mod = F.RegisterModule("extraFrameMover", {
    title = "补充窗口拖动",
    desc = "为系统菜单、飞行路线图与交易窗口补充 Shift 拖动与滚轮缩放。",
    group = "theme",
    order = 44,
    defaults = {
        enabled = true,
        positions = {},
        scales = {
            GameMenuFrame = 0.80,
        },
    },
})

local hookedFrames = setmetatable({}, { __mode = "k" })
local draggingFrame = setmetatable({}, { __mode = "k" })

local function IsSafeFrame(f)
    return type(f) == "table" and not (f.IsForbidden and f:IsForbidden())
end

local SaveFramePosition -- forward

local function StopAllDrags(savePos)
    local inCombat = InCombatLockdown and InCombatLockdown()
    for _, spec in ipairs(TARGET_FRAMES) do
        local fr = _G[spec.name]
        if fr and draggingFrame[fr] then
            draggingFrame[fr] = nil
            if IsSafeFrame(fr) and not inCombat then
                if fr.StopMovingOrSizing then pcall(fr.StopMovingOrSizing, fr) end
                if savePos and SaveFramePosition then SaveFramePosition(fr, spec.name) end
            end
        end
    end
end

local function ClampScale(s)
    s = F.PlainNumber(s, 1.0) or 1.0
    s = math_floor(s * 20 + 0.5) / 20
    return math_max(0.60, math_min(1.40, s))
end

local function ApplySavedState(frame, key)
    if not (mod._active and IsSafeFrame(frame)) then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        return
    end
    local db = mod:GetDB()
    local scales = type(db.scales) == "table" and db.scales or nil
    local sc = scales and F.PlainNumber(scales[key], nil) or nil
    if sc and sc > 0 and frame.SetScale then
        pcall(frame.SetScale, frame, ClampScale(sc))
    end
    local positions = type(db.positions) == "table" and db.positions or nil
    local pos = positions and positions[key]
    if type(pos) == "table" and pos.point and frame.ClearAllPoints and frame.SetPoint then
        pcall(frame.ClearAllPoints, frame)
        pcall(frame.SetPoint, frame, pos.point, _G.UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    end
end

SaveFramePosition = function(frame, key)
    if not (frame and frame.GetPoint) then
        return
    end
    local ok, pt, _, rpt, x, y = pcall(frame.GetPoint, frame, 1)
    if not (ok and type(pt) == "string") then
        return
    end
    local db = mod:GetDB()
    if type(db.positions) ~= "table" then
        db.positions = {}
    end
    db.positions[key] = {
        point = pt,
        relPoint = type(rpt) == "string" and rpt or pt,
        x = F.PlainNumber(x, 0) or 0,
        y = F.PlainNumber(y, 0) or 0,
    }
end

local function HookOneFrame(spec)
    local key = spec.name
    local frame = _G[key]
    if not (IsSafeFrame(frame) and not hookedFrames[frame]) then
        return
    end
    hookedFrames[frame] = true

    F.RunOutOfCombat("kkowoUI_EFM_" .. key, function()
        if not IsSafeFrame(frame) then return end
        pcall(frame.SetMovable, frame, true)
        pcall(frame.SetClampedToScreen, frame, true)
        pcall(frame.EnableMouse, frame, true)
        pcall(frame.EnableMouseWheel, frame, true)
        pcall(frame.RegisterForDrag, frame, "LeftButton")
    end)

    frame:HookScript("OnDragStart", function(self)
        if not (mod._active and IsSafeFrame(self)) then return end
        if InCombatLockdown and InCombatLockdown() then return end
        local euiDB = _G.EllesmereUIDB
        local noShift = type(euiDB) == "table" and euiDB.shifterNoShift == true
        if not noShift and not (IsShiftKeyDown and IsShiftKeyDown()) then return end
        draggingFrame[self] = true
        pcall(self.StartMoving, self)
    end)

    frame:HookScript("OnDragStop", function(self)
        if not draggingFrame[self] then return end
        draggingFrame[self] = nil
        if not IsSafeFrame(self) or (InCombatLockdown and InCombatLockdown()) then return end
        pcall(self.StopMovingOrSizing, self)
        SaveFramePosition(self, key)
    end)

    frame:HookScript("OnHide", function(self)
        if not draggingFrame[self] then return end
        draggingFrame[self] = nil
        if IsSafeFrame(self) and not (InCombatLockdown and InCombatLockdown()) then
            pcall(self.StopMovingOrSizing, self)
        end
    end)

    frame:HookScript("OnMouseWheel", function(self, delta)
        if not (mod._active and IsSafeFrame(self)) then return end
        if InCombatLockdown and InCombatLockdown() then return end
        if not (IsControlKeyDown and IsControlKeyDown()) then return end
        local db = mod:GetDB()
        if type(db.scales) ~= "table" then db.scales = {} end
        local cur = F.PlainNumber(db.scales[key], nil)
        if not cur and self.GetScale then
            local ok, sc = pcall(self.GetScale, self)
            cur = ok and F.PlainNumber(sc, 1.0) or 1.0
        end
        local nextScale = ClampScale((cur or 1.0) + (delta > 0 and 0.05 or -0.05))
        db.scales[key] = nextScale
        pcall(self.SetScale, self, nextScale)
    end)

    frame:HookScript("OnShow", function(self)
        ApplySavedState(self, key)
        C_Timer.After(0, function()
            if IsSafeFrame(self) and self.IsShown and self:IsShown() then
                ApplySavedState(self, key)
            end
        end)
    end)

    if frame.IsShown and frame:IsShown() then
        ApplySavedState(frame, key)
    end
end

local function HookAll()
    for _, spec in ipairs(TARGET_FRAMES) do
        HookOneFrame(spec)
    end
end

local function ResetAll()
    local db = mod:GetDB()
    db.positions = {}
    db.scales = { GameMenuFrame = 0.80 }
    F.RunOutOfCombat("kkowoUI_EFM_Reset", function()
        for _, spec in ipairs(TARGET_FRAMES) do
            local frame = _G[spec.name]
            if IsSafeFrame(frame) and frame.SetScale then
                pcall(frame.SetScale, frame, spec.defaultScale or 1.0)
            end
        end
    end)
    F.Print("已重置补充窗口位置与缩放，重载后生效。")
end

function mod:OnEnable()
    HookAll()
    self:RegisterEvent("TAXIMAP_OPENED", function()
        HookOneFrame(TARGET_FRAMES[2])
        ApplySavedState(_G.TaxiFrame, "TaxiFrame")
    end)
    self:RegisterEvent("TRADE_SHOW", function()
        HookOneFrame(TARGET_FRAMES[3])
        ApplySavedState(_G.TradeFrame, "TradeFrame")
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        C_Timer.After(0.5, HookAll)
    end)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        StopAllDrags(true)
    end)
end

function mod:OnDisable()
    StopAllDrags(false)
    F.RunOutOfCombat("kkowoUI_EFM_Disable", function()
        if mod._active then return end
        for _, spec in ipairs(TARGET_FRAMES) do
            local frame = _G[spec.name]
            if IsSafeFrame(frame) and frame.SetScale then
                pcall(frame.SetScale, frame, 1.0)
            end
        end
    end)
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "slider",
        text = "系统菜单缩放",
        tooltip = "调节 ESC 菜单大小（默认 0.80），也可按住 Ctrl+滚轮缩放。",
        min = 0.60, max = 1.25, step = 0.05,
        getValue = function()
            local sc = type(db.scales) == "table" and db.scales.GameMenuFrame
            return F.PlainNumber(sc, 0.80) or 0.80
        end,
        setValue = function(v)
            if type(db.scales) ~= "table" then db.scales = {} end
            db.scales.GameMenuFrame = ClampScale(v)
            if _G.GameMenuFrame and not (InCombatLockdown and InCombatLockdown()) then
                pcall(_G.GameMenuFrame.SetScale, _G.GameMenuFrame, db.scales.GameMenuFrame)
            end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "button",
        text = "重置窗口位置",
        buttonText = "恢复默认",
        noCapture = true,
        tooltip = "重置 ESC 菜单、经典飞行路线图与交易窗口的拖动位置与缩放。",
        onClick = ResetAll,
    }, nil)
    y = y - h
    return y
end
