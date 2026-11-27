----------------------------------------------------------------------
--  kkowoUI — Modules/RollBars.lua
--  零全局泄漏的现代扁平 Roll 点条（MerfinMain 材质 + 品质边框）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, type = ipairs, pairs, pcall, type
local math_floor, math_min = math.floor, math.min
local table_sort = table.sort
local CreateFrame = CreateFrame
local GameTooltip = _G.GameTooltip
local GetTime = GetTime

local mod = F.RegisterModule("rollBars", {
    title = "Roll 点增强",
    desc = "现代扁平装备 Roll 点条（带倒计时条、需求/贪婪/分解/放弃快捷钮，零全局函数污染）。开启 EUI「拾取掷点框」时自动让位。",
    group = "combat",
    order = 30,
    defaults = {
        enabled = true,
        width = 300,
        height = 30,
        spacing = 6,
        growDir = "UP", -- "UP"（默认向上堆叠，避开下方核心 HUD / 常驻 BUFF）| "DOWN"
    },
})

local container = nil
local bars = {}
local MAX_BARS = 12
local nextSeq = 0
local nativeHooksInstalled = false
local hideNativePending = false

local ApplyBarBorder -- 前向声明

local function SyncBarLayers(bar, strata, barLvl)
    if not bar then return end
    bar:SetFrameStrata(strata)
    bar:SetFrameLevel(barLvl)
    if bar.status then bar.status:SetFrameLevel(barLvl + 1) end
    if bar._ov then bar._ov:SetFrameLevel(barLvl + 3) end
    if bar._iconBtn then bar._iconBtn:SetFrameLevel(barLvl + 4) end
    local btnLvl = barLvl + 5
    if bar.btnPass then bar.btnPass:SetFrameLevel(btnLvl) end
    if bar.btnDis then bar.btnDis:SetFrameLevel(btnLvl) end
    if bar.btnGreed then bar.btnGreed:SetFrameLevel(btnLvl) end
    if bar.btnNeed then bar.btnNeed:SetFrameLevel(btnLvl) end
end

local function LayoutBars()
    if not container then
        return
    end
    local db = mod:GetDB()
    local w, h, gap = db.width or 300, db.height or 30, db.spacing or 6
    local growDown = (db.growDir == "DOWN")
    local hasPreview = false
    local visible = {}
    for _, bar in ipairs(bars) do
        if bar:IsShown() then
            if not bar.rollID then hasPreview = true end
            visible[#visible + 1] = bar
        end
    end
    table_sort(visible, function(a, b)
        return (a._seq or 0) < (b._seq or 0)
    end)

    -- 容器固定单条尺寸：
    -- 1) 解锁模式锚框与第 1 条严格对齐，增减装备时剩余条不再整体跳动；
    -- 2) 实战置 HIGH 层（高于 MEDIUM 层核心 HUD / 常驻 BUFF / 动作条，低于 DIALOG 拾取绑定弹窗与 TOOLTIP），杜绝多件装备重叠时点击被下层框体吞掉。
    container:SetSize(w, h)
    local strata = hasPreview and "FULLSCREEN_DIALOG" or "HIGH"
    local baseLvl = hasPreview and 200 or 50
    container:SetFrameStrata(strata)
    container:SetFrameLevel(baseLvl)

    local step = h + gap
    local anchorPt = growDown and "TOP" or "BOTTOM"
    for idx, bar in ipairs(visible) do
        local offset = (idx - 1) * step
        bar:ClearAllPoints()
        bar:SetSize(w, h)
        bar:SetPoint(anchorPt, container, anchorPt, 0, growDown and -offset or offset)
        SyncBarLayers(bar, strata, baseLvl + 1)
        if bar._borderColor then
            ApplyBarBorder(bar, bar._borderColor[1], bar._borderColor[2], bar._borderColor[3])
        end
    end
end

-- EUI 9.9.4+ 的「拾取掷点框」（生活质量 → 拾取 → LOOT ROLLS，默认关闭）开启并接管掷点时返回 true：
-- 此时由它显示掷点列表（暴雪原生弹窗也已由它关闭），本模块让位，避免同时出现两套掷点框；关掉后自动恢复
local function EUILootRollsInUse()
    local eui = _G.EllesmereUI
    local lr = eui and eui._LootRolls
    if not (lr and type(lr.InUse) == "function") then
        return false
    end
    local ok, inUse = pcall(lr.InUse)
    return ok and inUse == true
end

local function HideNativeRollFrames()
    if not (mod._active and not EUILootRollsInUse()) then
        return
    end
    local c = _G.GroupLootContainer
    local maxN = (c and F.PlainNumber(c.maxIndex, 4)) or 4
    if maxN < 4 then maxN = 4 end
    for i = 1, maxN do
        local f = _G["GroupLootFrame" .. i]
        if f and f.IsShown and f:IsShown() then
            pcall(f.Hide, f)
        end
    end
    if c and type(c.rollFrames) == "table" then
        local bonus = _G.BonusRollFrame
        for _, rf in pairs(c.rollFrames) do
            if rf and rf ~= bonus and rf.IsShown and rf:IsShown() then
                local nm = rf.GetName and F.PlainString(rf:GetName(), "") or ""
                if nm:find("GroupLootFrame", 1, true) or rf.rollID ~= nil then
                    pcall(rf.Hide, rf)
                end
            end
        end
    end
end

local function ScheduleHideNativeRollFrames()
    if hideNativePending or not (mod._active and not EUILootRollsInUse()) then
        return
    end
    if _G.C_Timer and _G.C_Timer.After then
        hideNativePending = true
        _G.C_Timer.After(0, function()
            hideNativePending = false
            HideNativeRollFrames()
        end)
    else
        HideNativeRollFrames()
    end
end

local function CloseBar(bar)
    if not bar then return end
    if GameTooltip and GameTooltip.IsOwned then
        local owner = GameTooltip.GetOwner and GameTooltip:GetOwner()
        if owner and (owner == bar or owner == bar._iconBtn
            or owner == bar.btnPass or owner == bar.btnDis
            or owner == bar.btnGreed or owner == bar.btnNeed) then
            GameTooltip:Hide()
        end
    end
    bar.rollID = nil
    bar.endTime = nil
    bar.bop = nil
    bar:Hide()
end

local function CloseRollID(rollID)
    local changed = false
    for _, bar in ipairs(bars) do
        if not rollID or bar.rollID == rollID then
            if bar:IsShown() or bar.rollID ~= nil then
                CloseBar(bar)
                changed = true
            end
        end
    end
    if changed then
        LayoutBars()
    end
end

local function EnsureNativeHooks()
    if nativeHooksInstalled then return end
    nativeHooksInstalled = true
    if type(_G.GroupLootContainer_AddFrame) == "function" then
        _G.hooksecurefunc("GroupLootContainer_AddFrame", ScheduleHideNativeRollFrames)
    end
    if type(_G.GroupLootContainer_Update) == "function" then
        _G.hooksecurefunc("GroupLootContainer_Update", ScheduleHideNativeRollFrames)
    end
    if type(_G.ConfirmLootRoll) == "function" then
        _G.hooksecurefunc("ConfirmLootRoll", function(rollID)
            if mod._active and not EUILootRollsInUse() and rollID then
                CloseRollID(rollID)
            end
        end)
    end
end

local function CreateRollButton(bar, host, iconFile, color, tip, rollAction, offsetX)
    local btn = CreateFrame("Button", nil, host)
    btn:SetSize(22, 22)
    btn:SetPoint("RIGHT", bar, "RIGHT", offsetX, 0)
    btn:SetFrameLevel(host:GetFrameLevel() + 2)

    local cr, cg, cb = color[1], color[2], color[3]
    F.Theme.StyleGlassSurface(btn, {
        accent = color,
        bgAlpha = 0.80,
        borderAlpha = 0.68,
        restAura = 0.12,
        hoverAura = 0.34,
        borderTintMix = 0.28,
    })

    local tex = btn:CreateTexture(nil, "OVERLAY", nil, 4)
    tex:SetSize(14, 14)
    tex:SetPoint("CENTER", btn, "CENTER", 0, 0)
    tex:SetTexture(F.Theme.ICONS .. iconFile)
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetVertexColor(cr, cg, cb, 0.94)
    btn._icon = tex

    btn:SetScript("OnClick", function()
        if bar.rollID and _G.RollOnLoot then
            local rid = bar.rollID
            local isBoP = bar.bop == true
            local ok = pcall(_G.RollOnLoot, rid, rollAction)
            -- 放弃或非拾取绑定物品：立刻收起该条，无需干等服务端延迟；拾取绑定由确认弹窗 ConfirmLootRoll 或 CANCEL_LOOT_ROLL 收起
            if ok and (rollAction == 0 or not isBoP) then
                CloseBar(bar)
                LayoutBars()
            end
        elseif not bar.rollID then
            -- 预览条没有 rollID：点任意按钮直接关闭预览
            CloseBar(bar)
            LayoutBars()
        end
    end)
    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            F.Theme.SetGlassState(self, true, false)
            tex:SetVertexColor(
                math_min(1, cr * 0.45 + 0.55),
                math_min(1, cg * 0.45 + 0.55),
                math_min(1, cb * 0.45 + 0.55), 1.0)
        end
        GameTooltip:SetOwner(self, "ANCHOR_TOP", 0, 4)
        GameTooltip:SetText(tip, cr, cg, cb)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        F.Theme.SetGlassState(self, false, false)
        tex:ClearAllPoints()
        tex:SetPoint("CENTER", self, "CENTER", 0, 0)
        tex:SetVertexColor(cr, cg, cb, 0.94)
        GameTooltip:Hide()
    end)
    btn:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", self, "CENTER", 0, -1)
        end
    end)
    btn:SetScript("OnMouseUp", function(self)
        tex:ClearAllPoints()
        tex:SetPoint("CENTER", self, "CENTER", 0, 0)
    end)
    return btn
end

ApplyBarBorder = function(bar, r, g, b)
    if not bar then return end
    local ST = F.StyleTokens
    local rad = ST and ST.GetCornerRadius(6) or 0
    if ST and rad > 0 then
        if bar._fuiBg then ST.MaskTexture(bar, bar._fuiBg, rad) end
        if bar._fuiBorders then
            for _, ln in ipairs(bar._fuiBorders) do ln:Hide() end
        end
        local ft = bar.status and bar.status:GetStatusBarTexture()
        if ft then ST.MaskTexture(bar, ft, rad) end
        ST.ApplyRoundedBorder(bar, rad, r * 0.68 + 0.10, g * 0.68 + 0.10, b * 0.68 + 0.10, 0.86, 6)
        if bar._iconBtn and bar.icon then ST.MaskIcon(bar._iconBtn, bar.icon, 4) end
    else
        if ST then
            ST.ClearRoundedMask(bar)
            if bar._iconBtn then ST.ClearRoundedMask(bar._iconBtn) end
        end
        if bar._fuiBorders then
            for _, ln in ipairs(bar._fuiBorders) do
                ln:SetColorTexture(r, g, b, 0.72)
                ln:Show()
            end
        end
    end
end

local function ShowRollTooltip(bar, owner)
    if not (bar and bar.rollID and GameTooltip) then return end
    GameTooltip:SetOwner(owner or bar, "ANCHOR_LEFT")
    pcall(GameTooltip.SetLootRollItem, GameTooltip, bar.rollID)
    GameTooltip:Show()
end

local function AcquireBar(rollID)
    if rollID ~= nil then
        for _, b in ipairs(bars) do
            if b:IsShown() and b.rollID == rollID then
                return b, true
            end
        end
    end
    for _, b in ipairs(bars) do
        if not b:IsShown() then
            return b, false
        end
    end
    if #bars >= MAX_BARS then
        local oldest = bars[1]
        for i = 2, #bars do
            local b = bars[i]
            if (b.endTime or 0) < (oldest.endTime or 0) then
                oldest = b
            end
        end
        return oldest, false
    end
    local bar = CreateFrame("Frame", nil, container)
    bar:EnableMouse(true)
    bar:SetClampedToScreen(true)
    F.Theme.StylePanel(bar, 0.88, 0.85)
    bar:SetScript("OnEnter", function(self) ShowRollTooltip(self, self) end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local sb = CreateFrame("StatusBar", nil, bar)
    sb:SetPoint("TOPLEFT", 32, -1)
    sb:SetPoint("BOTTOMRIGHT", -1, 1)
    sb:SetStatusBarTexture(F.Theme.GetBarTexture())
    sb:EnableMouse(false)
    if sb.SetSnapToPixelGrid then pcall(sb.SetSnapToPixelGrid, sb, false) end
    if sb.SetTexelSnappingBias then pcall(sb.SetTexelSnappingBias, sb, 0) end
    local sbFill = sb:GetStatusBarTexture()
    if sbFill then
        if sbFill.SetSnapToPixelGrid then pcall(sbFill.SetSnapToPixelGrid, sbFill, false) end
        if sbFill.SetTexelSnappingBias then pcall(sbFill.SetTexelSnappingBias, sbFill, 0) end
    end
    bar.status = sb

    local iconBtn = CreateFrame("Button", nil, bar)
    iconBtn:SetSize(28, 28)
    iconBtn:SetPoint("LEFT", bar, "LEFT", 2, 0)
    local icon = iconBtn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar._iconBtn = iconBtn
    bar.icon = icon

    ApplyBarBorder(bar, 0.04, 0.045, 0.06)
    iconBtn:SetScript("OnEnter", function(self) ShowRollTooltip(bar, self) end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    iconBtn:SetScript("OnClick", function()
        if bar.rollID and _G.IsModifiedClick and _G.IsModifiedClick() and _G.GetLootRollItemLink and _G.HandleModifiedItemClick then
            local ok, link = pcall(_G.GetLootRollItemLink, bar.rollID)
            if ok and link then pcall(_G.HandleModifiedItemClick, link) end
        end
    end)

    local ov = CreateFrame("Frame", nil, bar)
    ov:SetAllPoints()
    ov:EnableMouse(false)
    ov:SetFrameLevel(sb:GetFrameLevel() + 2)
    bar._ov = ov
    local timeFS = ov:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(timeFS, 11, "", 0.78, 0.80, 0.85, 0.92)
    timeFS:SetPoint("RIGHT", bar, "RIGHT", -102, 0)
    timeFS:SetJustifyH("RIGHT")
    bar.timeFS = timeFS

    local nameText = ov:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(nameText, 12, "", 0.96, 0.96, 0.98, 1)
    nameText:SetPoint("LEFT", iconBtn, "RIGHT", 6, 0)
    nameText:SetPoint("RIGHT", timeFS, "LEFT", -6, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    bar.nameText = nameText

    local sheen = sb:CreateTexture(nil, "OVERLAY")
    sheen:SetHeight(1)
    sheen:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, 0)
    sheen:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)
    sheen:SetColorTexture(1, 1, 1, 0.14)

    bar.btnPass   = CreateRollButton(bar, ov, "Close.tga",          { 0.93, 0.38, 0.44 }, "放弃", 0, -4)
    bar.btnDis    = CreateRollButton(bar, ov, "RollDisenchant.tga", { 0.76, 0.53, 0.98 }, "分解", 3, -28)
    bar.btnGreed  = CreateRollButton(bar, ov, "RollGreed.tga",      { 0.96, 0.78, 0.34 }, "贪婪", 2, -52)
    bar.btnNeed   = CreateRollButton(bar, ov, "RollNeed.tga",       { 0.37, 0.85, 0.64 }, "需求", 1, -76)

    bar:SetScript("OnUpdate", function(self)
        if not self.endTime then return end
        local rem = self.endTime - GetTime()
        if rem <= 0 then
            CloseBar(self)
            LayoutBars()
            return
        end
        self.status:SetValue(rem)
        if self.timeFS then
            local sec = math_floor(rem + 0.5)
            if self._lastSec ~= sec then
                self._lastSec = sec
                self.timeFS:SetText(sec .. "s")
            end
        end
    end)

    SyncBarLayers(bar, (container and container:GetFrameStrata()) or "HIGH", ((container and container:GetFrameLevel()) or 50) + 1)
    bar:Hide()
    bars[#bars + 1] = bar
    return bar, false
end

local function EnsureContainer()
    if container then
        return
    end
    local db = mod:GetDB()
    container = CreateFrame("Frame", "kkowoUI_RollBars", _G.UIParent)
    container:SetSize(db.width or 300, db.height or 30)
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(50)
    F.Mover.Register({
        key = "RollBars",
        label = "Roll 点增强条",
        frame = container,
        order = 35,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 0,
        defaultY = -140,
        isHidden = function() return not mod._active end,
    })
end

function mod:OnStartRoll(_, rollID, rollTime)
    if not (_G.GetLootRollItemInfo and rollID) then
        return
    end
    if EUILootRollsInUse() then
        F.PrintOnce("rollbars_yield_eui", "检测到 EUI「拾取掷点框」已开启，kkowoUI 的 Roll 点条自动让位（关闭 EUI 的掷点框后自动恢复）。")
        return
    end
    EnsureContainer()
    HideNativeRollFrames()
    ScheduleHideNativeRollFrames()

    local okInfo, texture, name, _, quality, bindOnPickUp, canNeed, canGreed, canDisenchant = pcall(_G.GetLootRollItemInfo, rollID)
    if not (okInfo and name) then
        return
    end
    local bar, existed = AcquireBar(rollID)
    bar.rollID = rollID
    bar.bop = (bindOnPickUp == true)
    if not existed then
        nextSeq = nextSeq + 1
        bar._seq = nextSeq
    end
    local rt = F.PlainNumber(rollTime, 60000)
    if rt <= 0 then rt = 60000 end
    local dur = rt / 1000
    bar.endTime = GetTime() + dur
    bar.status:SetStatusBarTexture(F.Theme.GetBarTexture())
    bar.status:SetMinMaxValues(0, dur)
    bar.status:SetValue(dur)

    local qr, qg, qb = 0.7, 0.7, 0.7
    local getQualColor = (_G.C_Item and _G.C_Item.GetItemQualityColor) or _G.GetItemQualityColor
    if getQualColor then
        local okQ, r, g, b = pcall(getQualColor, F.PlainNumber(quality, 1))
        if okQ and r and g and b then qr, qg, qb = r, g, b end
    end
    bar.status:SetStatusBarColor(qr, qg, qb, 0.42)
    bar._borderColor = { qr, qg, qb }
    bar._lastSec = nil
    bar.icon:SetTexture(texture or 134400)
    bar.nameText:SetText(name)
    bar.nameText:SetTextColor(qr, qg, qb, 1)

    bar.btnPass:SetEnabled(true); bar.btnPass:SetAlpha(1)
    bar.btnNeed:SetEnabled(canNeed == true); bar.btnNeed:SetAlpha(canNeed == true and 1 or 0.25)
    bar.btnGreed:SetEnabled(canGreed == true); bar.btnGreed:SetAlpha(canGreed == true and 1 or 0.25)
    bar.btnDis:SetEnabled(canDisenchant == true); bar.btnDis:SetAlpha(canDisenchant == true and 1 or 0.25)
    bar:Show()
    LayoutBars()
end

function mod:OnCancelRoll(_, rollID)
    CloseRollID(rollID)
end

function mod:ShowPreview()
    EnsureContainer()
    local bar = AcquireBar(nil)
    bar.rollID = nil
    bar.bop = false
    nextSeq = nextSeq + 1
    bar._seq = nextSeq
    bar.endTime = GetTime() + 12
    bar.status:SetStatusBarTexture(F.Theme.GetBarTexture())
    bar.status:SetMinMaxValues(0, 12)
    bar.status:SetValue(12)
    local ar, ag, ab = F.Theme.GetAccent()
    bar.status:SetStatusBarColor(ar, ag, ab, 0.45)
    bar.icon:SetTexture(135489)
    bar.nameText:SetText("[预览] 史诗猎人长弓")
    bar.nameText:SetTextColor(0.64, 0.21, 0.93, 1)
    -- 复用的条可能残留上一次真实掷骰的禁用状态 / 倒计时 / 品质边框色
    bar._lastSec = nil
    bar._borderColor = { 0.64, 0.21, 0.93 }
    bar.btnPass:SetEnabled(true); bar.btnPass:SetAlpha(1)
    bar.btnNeed:SetEnabled(true); bar.btnGreed:SetEnabled(true); bar.btnDis:SetEnabled(true)
    bar.btnNeed:SetAlpha(1); bar.btnGreed:SetAlpha(1); bar.btnDis:SetAlpha(1)
    bar:Show()
    LayoutBars()
end

function mod:OnEnable()
    EnsureContainer()
    EnsureNativeHooks()
    self:RegisterEvent("START_LOOT_ROLL", self.OnStartRoll)
    self:RegisterEvent("CANCEL_LOOT_ROLL", self.OnCancelRoll)
    self:RegisterEvent("CANCEL_ALL_LOOT_ROLLS", function() self:OnCancelRoll(nil, nil) end)
    self:RegisterEvent("LOOT_ROLLS_COMPLETE", function() self:OnCancelRoll(nil, nil) end)
end

function mod:OnDisable()
    self:OnCancelRoll(nil, nil)
end

function mod:OnThemeChanged()
    LayoutBars()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "slider",
        text = "Roll 条宽度",
        min = 240, max = 420, step = 10,
        getValue = function() return db.width or 300 end,
        setValue = function(v) db.width = v; LayoutBars() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "多件装备堆叠方向",
        tooltip = "同时掉落多件装备时新条目的展开方向。默认向上堆叠，避免向下压到常驻 BUFF 图标与核心双翼 HUD。",
        values = {
            UP   = "向上堆叠（推荐）",
            DOWN = "向下堆叠",
        },
        order = { "UP", "DOWN" },
        getValue = function() return db.growDir == "DOWN" and "DOWN" or "UP" end,
        setValue = function(v) db.growDir = (v == "DOWN") and "DOWN" or "UP"; LayoutBars() end,
    }, blank)
    y = y - h

    _, h = W:WideButton(parent, "预览 Roll 点条（12 秒，可连点测多条）", y, function() self:ShowPreview() end)
    y = y - h
    return y
end
