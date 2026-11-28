----------------------------------------------------------------------
--  kkowoUI — Modules/SwingTimerMotion.lua
--  武器挥砍计时器（100% 适配无限服原生 PLAYER_SWING / C_SwingTimer API）：
--    • 模式 A（默认 enhance_eui）：原地为 EUI 挥砍条叠加圆角遮罩 + <0.25s 出手临界光刃提亮 + 出手瞬闪
--    • 模式 B（standalone）：3~5px 极简圆角细条（自动适配双持上下双条 & 猎人自动射击防卡平射色段），
--      可吸附核心血条下方或接入 EUI 解锁模式自由移动，脱战静止 0 OnUpdate 开销
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local math_floor, math_max, math_min, pcall = math.floor, math.max, math.min, pcall
local CreateFrame = CreateFrame
local GetTime = GetTime

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("swingTimerMotion", {
    title = "挥砍条动效",
    desc = "原地增强 EUI 挥砍条或启用独立细条，支持双持与猎人平射。",
    group = "motion",
    order = 25,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        mode = "enhance_eui", -- "enhance_eui" | "standalone"
        width = 249,
        height = 4,
        hideOOC = true,
        criticalBoost = true, -- < 0.25s 出手临界光点提亮
        flashOnSwing = true,
    },
})

local SWING_ENUM = _G.Enum and _G.Enum.PlayerSwingType or nil
local AIM_CLASSES = { HUNTER = true, PRIEST = true, MAGE = true, WARLOCK = true }
local AIM_TIME = 0.50

local container = nil
local mhBar, ohBar = nil, nil
local flashTex = nil
local flashAG = nil
local isAimClass = AIM_CLASSES[F.GetPlayerClass()] == true
local inCombat = false

local state = {
    mhS = 0, mhE = 0, mhD = 0,
    ohS = 0, ohE = 0, ohD = 0,
    rS  = 0, rE  = 0, rD  = 0,
    lastKind = "mh",
    moving = false,
    autoRepeat = false,
}

local function MakeThinBar(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f:EnableMouse(false)

    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    bg:SetAllPoints()
    bg:SetTexture(ST.TEX.FLAT)
    local tc = ST.COLORS.track
    bg:SetVertexColor(tc[1], tc[2], tc[3], tc[4])
    f._bg = bg

    local sb = CreateFrame("StatusBar", nil, f)
    sb:SetAllPoints()
    sb:SetStatusBarTexture(ST.TEX.FLAT)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    if sb.SetSnapToPixelGrid then pcall(sb.SetSnapToPixelGrid, sb, false) end
    if sb.SetTexelSnappingBias then pcall(sb.SetTexelSnappingBias, sb, 0) end
    local sbFill = sb:GetStatusBarTexture()
    if sbFill then
        if sbFill.SetSnapToPixelGrid then pcall(sbFill.SetSnapToPixelGrid, sbFill, false) end
        if sbFill.SetTexelSnappingBias then pcall(sbFill.SetTexelSnappingBias, sbFill, 0) end
    end
    f._bar = sb

    local aim = sb:CreateTexture(nil, "ARTWORK", nil, 2)
    aim:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)
    aim:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
    aim:SetColorTexture(1, 0.80, 0.24, 0.34)
    aim:Hide()
    f._aim = aim

    f._spark = M.AttachEdgeSpark(sb, { width = 14, extraHeight = 4, a = 0.90 })
    f._spark:SetShown(false)
    return f
end

local function StyleThinBar(f, h)
    if not f then return end
    local rad = math_min(ST.GetCornerRadius(3), math_max(2, math_floor(h * 0.5)))
    ST.ClearRoundedMask(f)
    if rad > 0 then
        ST.MaskTexture(f, f._bg, rad)
        local t = f._bar:GetStatusBarTexture()
        if t then ST.MaskTexture(f, t, rad) end
        if f._aim then ST.MaskTexture(f, f._aim, rad) end
        if f._spark and f._spark._spark then
            ST.MaskTexture(f, f._spark._spark, rad)
        end
        if f == mhBar and flashTex then
            ST.MaskTexture(f, flashTex, rad)
        end
        ST.ApplyRoundedBorder(f, rad, 0.02, 0.02, 0.03, 0.94, 5)
    end
    if f._spark then f._spark:SyncAnchor() end
end

local function BuildStandalone()
    if container then return end
    local db = mod:GetDB()
    local w = F.PlainNumber(db.width, 249) or 249
    local h = F.PlainNumber(db.height, 4) or 4

    local f = CreateFrame("Frame", "kkowoUI_SwingTimer", _G.UIParent)
    f:SetSize(w, h * 2 + 2)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(18)
    f:EnableMouse(false)

    mhBar = MakeThinBar(f, w, h)
    mhBar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    mhBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)

    ohBar = MakeThinBar(f, w, h)
    ohBar:SetPoint("TOPLEFT", mhBar, "BOTTOMLEFT", 0, -2)
    ohBar:SetPoint("TOPRIGHT", mhBar, "BOTTOMRIGHT", 0, -2)
    ohBar:Hide()

    flashTex = mhBar._bar:CreateTexture(nil, "OVERLAY", nil, 7)
    flashTex:SetAllPoints(mhBar._bar)
    flashTex:SetColorTexture(1, 1, 1, 0.85)
    flashTex:SetBlendMode("ADD")
    flashTex:SetAlpha(0)
    flashAG = flashTex:CreateAnimationGroup()
    local fa = flashAG:CreateAnimation("Alpha")
    fa:SetFromAlpha(0.85); fa:SetToAlpha(0); fa:SetDuration(0.16); fa:SetSmoothing("OUT")

    F.Mover.Register({
        key = "SwingTimerHUD",
        label = "独立极细挥砍计时条",
        frame = f,
        order = 16,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 0,
        defaultY = -262,
        allowShiftDrag = false,
        isHidden = function() return not (mod._active and mod:GetDB().mode == "standalone") end,
    })
    f:EnableMouse(false)

    f:Hide()
    container = f
end

local function TriggerSwingFlash()
    if mod:GetDB().flashOnSwing == false then return end
    if mod:GetDB().mode == "standalone" and flashAG then
        flashAG:Stop()
        flashAG:Play()
    else
        local erb = _G.ERB_SwingTimerFrame
        if erb and erb:IsShown() then
            M.PlayScalePop(erb, 1.03, 0.14)
        end
    end
end

local mutedSwingBorders = _G.setmetatable({}, { __mode = "k" })
local hookedSwingBorder = _G.setmetatable({}, { __mode = "k" })
local hookedSwingShell = _G.setmetatable({}, { __mode = "k" })
local seenSwingRows = _G.setmetatable({}, { __mode = "k" })
local swingBorderBusy = false

local function IsSafeObj(obj)
    if not obj then return false end
    if obj.IsForbidden then
        local ok, forb = pcall(obj.IsForbidden, obj)
        if not ok or forb then return false end
    end
    return true
end

local function EnhanceEUISwingFrame()
    local erb = _G.ERB_SwingTimerFrame
    if not IsSafeObj(erb) then return end
    -- 外壳 ERB_SwingTimerFrame 仅是多行排布容器，绝不能在外壳上套圆角框（会包住多行空隙并与行内直角框打架）
    ST.ClearRoundedMask(erb)
    if not hookedSwingShell[erb] and erb.HookScript then
        hookedSwingShell[erb] = true
        erb:HookScript("OnShow", function()
            if mod._active and mod:GetDB().mode == "enhance_eui" then
                EnhanceEUISwingFrame()
            end
        end)
    end
    local want = mod._active and mod:GetDB().mode == "enhance_eui"
    local rad = math_min(ST.GetCornerRadius(4), 4)
    if not erb.GetChildren then return end
    for _, row in _G.ipairs({ erb:GetChildren() }) do
        if IsSafeObj(row) and row._bar and row._bg then
            seenSwingRows[row] = true
            if row._merged == true then
                ST.ClearRoundedMask(row)
                if row._border then mutedSwingBorders[row._border] = nil end
            elseif want and rad > 0 then
                ST.MaskTexture(row, row._bg, rad)
                local ft = row._bar.GetStatusBarTexture and row._bar:GetStatusBarTexture() or nil
                if ft then ST.MaskTexture(row, ft, rad) end
                if row._border and row._border.SetAlpha then
                    local bd = row._border
                    mutedSwingBorders[bd] = true
                    if not hookedSwingBorder[bd] then
                        hookedSwingBorder[bd] = true
                        _G.hooksecurefunc(bd, "SetAlpha", function(self, a)
                            if not swingBorderBusy and mutedSwingBorders[self] and F.PlainNumber(a, 1) ~= 0 then
                                swingBorderBusy = true
                                pcall(self.SetAlpha, self, 0)
                                swingBorderBusy = false
                            end
                        end)
                    end
                    swingBorderBusy = true
                    pcall(bd.SetAlpha, bd, 0)
                    swingBorderBusy = false
                end
                ST.ApplyRoundedBorder(row, rad, 0.02, 0.02, 0.03, 0.92, 6)
            else
                ST.ClearRoundedMask(row)
                if row._border and mutedSwingBorders[row._border] and row._border.SetAlpha then
                    mutedSwingBorders[row._border] = nil
                    if not row._merged then
                        swingBorderBusy = true
                        pcall(row._border.SetAlpha, row._border, 1)
                        swingBorderBusy = false
                    end
                end
            end
        end
    end
end

local function CheckUnseenEUISwingRows()
    local erb = _G.ERB_SwingTimerFrame
    if not (IsSafeObj(erb) and erb.GetChildren) then return end
    for _, row in _G.ipairs({ erb:GetChildren() }) do
        if IsSafeObj(row) and row._bar and row._bg and not seenSwingRows[row] then
            EnhanceEUISwingFrame()
            return
        end
    end
end

local function MaybeHideIdleStandalone()
    if not (mod._active and mod:GetDB().mode == "standalone" and container and container:IsShown()) then return end
    local db = mod:GetDB()
    if db.hideOOC == false or inCombat or state.autoRepeat then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end
    local now = GetTime()
    if state.mhE > now or state.ohE > now or state.rE > now then return end
    F.Theme.FadeTo(container, 0, 0.25, true)
end

local function UpdateStandaloneTick(self)
    if not (mod._active and mod:GetDB().mode == "standalone") then
        self:SetScript("OnUpdate", nil)
        self:Hide()
        return
    end
    local now = GetTime()
    local db = mod:GetDB()
    local s, e, d, kind
    if state.lastKind == "ranged" and state.rE > now then
        s, e, d, kind = state.rS, state.rE, state.rD, "ranged"
    elseif state.mhE > now then
        s, e, d, kind = state.mhS, state.mhE, state.mhD, "mh"
    elseif state.rE > now then
        s, e, d, kind = state.rS, state.rE, state.rD, "ranged"
    end

    local ohLive = state.ohE > now and state.ohD > 0.01
    if not s and not ohLive then
        mhBar._bar:SetValue(0)
        mhBar._spark:SetShown(false)
        ohBar:Hide()
        self:SetScript("OnUpdate", nil)
        if db.hideOOC ~= false and not inCombat and not (_G.InCombatLockdown and _G.InCombatLockdown()) and not state.autoRepeat then
            F.Theme.FadeTo(self, 0, 0.25, true)
        end
        return
    end

    if s and d and d > 0.01 then
        local prog = math_max(0, math_min(1, (now - s) / d))
        local rem = e - now
        mhBar._bar:SetValue(prog)
        if kind == "ranged" and isAimClass then
            local w = F.PlainNumber(mhBar:GetWidth(), 249) or 249
            mhBar._aim:SetWidth(math_max(4, w * math_min(0.65, AIM_TIME / d)))
            mhBar._aim:Show()
            local cKey = (rem <= AIM_TIME) and (state.moving and "clip" or "still") or "go"
            if mhBar._lastColorKey ~= cKey then
                mhBar._lastColorKey = cKey
                local c = (cKey == "clip") and ST.COLORS.aimClip
                    or (cKey == "still" and ST.COLORS.aimStill or ST.COLORS.aimGo)
                ST.ApplyBarGradient(mhBar._bar, c[1] * 0.78, c[2] * 0.78, c[3] * 0.78, c[1], c[2], c[3], 0.98, false)
            end
        else
            mhBar._aim:Hide()
            if mhBar._lastColorKey ~= "class" then
                mhBar._lastColorKey = "class"
                local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
                ST.ApplyBarGradient(mhBar._bar, r1, g1, b1, r2, g2, b2, 0.98, false)
            end
        end
        mhBar._spark:SetShown(prog > 0.02 and prog < 0.99)
        if db.criticalBoost ~= false and rem <= 0.25 then
            mhBar._spark:SetIntensity(1.0, 1.45)
        else
            mhBar._spark:SetIntensity(0.80, 0.95)
        end
    end

    if ohLive then
        ohBar:Show()
        local ohProg = math_max(0, math_min(1, (now - state.ohS) / state.ohD))
        ohBar._bar:SetValue(ohProg)
        if ohBar._lastColorKey ~= "class" then
            ohBar._lastColorKey = "class"
            local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
            ST.ApplyBarGradient(ohBar._bar, r1 * 0.75, g1 * 0.75, b1 * 0.75, r2 * 0.9, g2 * 0.9, b2 * 0.9, 0.92, false)
        end
        ohBar._spark:SetShown(ohProg > 0.02 and ohProg < 0.99)
    else
        ohBar:Hide()
    end
end

local function ApplyModeLayout()
    local db = mod:GetDB()
    EnhanceEUISwingFrame()
    if db.mode == "standalone" then
        BuildStandalone()
        local w = math_max(120, math_min(360, F.PlainNumber(db.width, 249) or 249))
        local h = math_max(3, math_min(10, F.PlainNumber(db.height, 4) or 4))
        container:SetSize(w, h * 2 + 2)
        mhBar:SetHeight(h)
        ohBar:SetHeight(h)
        mhBar._lastColorKey = nil
        ohBar._lastColorKey = nil
        StyleThinBar(mhBar, h)
        StyleThinBar(ohBar, h)
    elseif container then
        container:SetScript("OnUpdate", nil)
        container:Hide()
    end
end

function mod:OnEnable()
    isAimClass = AIM_CLASSES[F.GetPlayerClass()] == true
    inCombat = (_G.InCombatLockdown and _G.InCombatLockdown()) == true
    ApplyModeLayout()
    self:RegisterEvent("PLAYER_SWING", function(_, _, duration, swingType)
        local dur = F.PlainNumber(duration, nil)
        local stype = F.PlainNumber(swingType, nil)
        if not dur or dur <= 0.05 then return end
        local now = GetTime()
        if SWING_ENUM and stype == SWING_ENUM.Ranged then
            state.rS, state.rE, state.rD = now, now + dur, dur
            state.lastKind = "ranged"
        elseif SWING_ENUM and stype == SWING_ENUM.OffHand then
            state.ohS, state.ohE, state.ohD = now, now + dur, dur
        else
            state.mhS, state.mhE, state.mhD = now, now + dur, dur
            state.lastKind = "mh"
        end
        if mod:GetDB().mode == "enhance_eui" then
            CheckUnseenEUISwingRows()
        end
        TriggerSwingFlash()
        if mod:GetDB().mode == "standalone" then
            BuildStandalone()
            -- 中止脱战淡出（其结束回调会 Hide 容器），否则淡出期间来的新一刀会被藏掉
            F.Theme.FadeTo(container, 1, 0)
            container:Show()
            container:SetScript("OnUpdate", UpdateStandaloneTick)
            UpdateStandaloneTick(container)
        end
    end)
    self:RegisterEvent("START_AUTOREPEAT_SPELL", function() state.autoRepeat = true end)
    self:RegisterEvent("STOP_AUTOREPEAT_SPELL", function()
        state.autoRepeat = false
        MaybeHideIdleStandalone()
    end)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function() inCombat = true end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        inCombat = false
        MaybeHideIdleStandalone()
    end)
    self:RegisterEvent("PLAYER_STARTED_MOVING", function() state.moving = true end)
    self:RegisterEvent("PLAYER_STOPPED_MOVING", function() state.moving = false end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", ApplyModeLayout)
end

function mod:OnDisable()
    inCombat = false
    if container then
        container:SetScript("OnUpdate", nil)
        container:Hide()
    end
    EnhanceEUISwingFrame()
end

function mod:OnRefresh()
    ApplyModeLayout()
end

function mod:OnThemeChanged()
    ApplyModeLayout()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "挥砍条运行模式",
        tooltip = "原地增强避免双条重叠，也可切为 4px 独立条支持双持与平射。",
        values = {
            enhance_eui = "原地增强 EUI 挥砍条（推荐·防重复）",
            standalone  = "独立 4px 极细圆角挥砍条（支持双持）",
        },
        order = { "enhance_eui", "standalone" },
        getValue = function() return db.mode or "enhance_eui" end,
        setValue = function(v) db.mode = v; ApplyModeLayout() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "独立细条高度（px）",
        min = 3, max = 8, step = 1,
        disabled = function() return db.mode ~= "standalone" end,
        getValue = function() return F.PlainNumber(db.height, 4) or 4 end,
        setValue = function(v) db.height = math_floor(v + 0.5); ApplyModeLayout() end,
    }, {
        type = "slider",
        text = "独立细条宽度（px）",
        min = 140, max = 340, step = 5,
        disabled = function() return db.mode ~= "standalone" end,
        getValue = function() return F.PlainNumber(db.width, 249) or 249 end,
        setValue = function(v) db.width = math_floor(v + 0.5); ApplyModeLayout() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "临界前沿提亮",
        getValue = function() return db.criticalBoost ~= false end,
        setValue = function(v) db.criticalBoost = v == true end,
    }, {
        type = "toggle",
        text = "出手瞬间轻闪重置",
        getValue = function() return db.flashOnSwing ~= false end,
        setValue = function(v) db.flashOnSwing = v == true end,
    })
    y = y - h

    return y
end
