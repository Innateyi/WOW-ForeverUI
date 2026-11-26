----------------------------------------------------------------------
--  kkowoUI — Modules/RollBars.lua
--  零全局泄漏的现代扁平 Roll 点条（MerfinMain 材质 + 品质边框）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pcall = ipairs, pcall
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
    },
})

local container = nil
local bars = {}
local MAX_BARS = 8

local function LayoutBars()
    if not container then
        return
    end
    local db = mod:GetDB()
    local w, h, gap = db.width or 300, db.height or 30, db.spacing or 6
    local shown = 0
    local hasPreview = false
    for _, bar in ipairs(bars) do
        if bar:IsShown() then
            if not bar.rollID then hasPreview = true end
            bar:ClearAllPoints()
            bar:SetSize(w, h)
            bar:SetPoint("TOP", container, "TOP", 0, -shown * (h + gap))
            shown = shown + 1
        end
    end
    container:SetSize(w, math.max(h, shown * (h + gap)))
    if hasPreview then
        container:SetFrameStrata("FULLSCREEN_DIALOG")
    else
        container:SetFrameStrata("MEDIUM")
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
    for i = 1, 4 do
        local f = _G["GroupLootFrame" .. i]
        if f and f:IsShown() then
            f:Hide()
        end
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
            pcall(_G.RollOnLoot, bar.rollID, rollAction)
        elseif not bar.rollID then
            -- 预览条没有 rollID：点任意按钮直接关闭预览
            bar.endTime = nil
            bar:Hide()
            LayoutBars()
        end
    end)
    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            F.Theme.SetGlassState(self, true, false)
            tex:SetVertexColor(
                math.min(1, cr * 0.45 + 0.55),
                math.min(1, cg * 0.45 + 0.55),
                math.min(1, cb * 0.45 + 0.55), 1.0)
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

local function ApplyBarBorder(bar, r, g, b)
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
        if bar._iconBtn and bar.icon then ST.MaskTexture(bar._iconBtn, bar.icon, 4) end
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

local function AcquireBar()
    for _, b in ipairs(bars) do
        if not b:IsShown() then
            return b
        end
    end
    if #bars >= MAX_BARS then
        return bars[1]
    end
    local bar = CreateFrame("Frame", nil, container)
    F.Theme.StylePanel(bar, 0.88, 0.85)

    local sb = CreateFrame("StatusBar", nil, bar)
    sb:SetPoint("TOPLEFT", 32, -1)
    sb:SetPoint("BOTTOMRIGHT", -1, 1)
    sb:SetStatusBarTexture(F.Theme.GetBarTexture())
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
    iconBtn:SetScript("OnEnter", function(self)
        if bar.rollID then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            pcall(GameTooltip.SetLootRollItem, GameTooltip, bar.rollID)
            GameTooltip:Show()
        end
    end)
    iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local ov = CreateFrame("Frame", nil, bar)
    ov:SetAllPoints()
    ov:SetFrameLevel(sb:GetFrameLevel() + 2)
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
            self.rollID = nil
            self.endTime = nil
            self:Hide()
            LayoutBars()
            return
        end
        self.status:SetValue(rem)
        if self.timeFS then
            local sec = math.floor(rem + 0.5)
            if self._lastSec ~= sec then
                self._lastSec = sec
                self.timeFS:SetText(sec .. "s")
            end
        end
    end)

    bar:Hide()
    bars[#bars + 1] = bar
    return bar
end

local function EnsureContainer()
    if container then
        return
    end
    container = CreateFrame("Frame", "kkowoUI_RollBars", _G.UIParent)
    container:SetSize(300, 30)
    container:SetFrameStrata("MEDIUM")
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
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, function()
            if mod._active then HideNativeRollFrames() end
        end)
    end
    local texture, name, _, quality, _, canNeed, canGreed, canDisenchant = _G.GetLootRollItemInfo(rollID)
    if not name then
        return
    end
    local bar = AcquireBar()
    bar.rollID = rollID
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
        local r, g, b = getQualColor(F.PlainNumber(quality, 1))
        if r and g and b then qr, qg, qb = r, g, b end
    end
    bar.status:SetStatusBarColor(qr, qg, qb, 0.42)
    ApplyBarBorder(bar, qr, qg, qb)
    bar._lastSec = nil
    bar.icon:SetTexture(texture or 134400)
    bar.nameText:SetText(name)
    bar.nameText:SetTextColor(qr, qg, qb, 1)

    bar.btnNeed:SetEnabled(canNeed == true); bar.btnNeed:SetAlpha(canNeed and 1 or 0.25)
    bar.btnGreed:SetEnabled(canGreed == true); bar.btnGreed:SetAlpha(canGreed and 1 or 0.25)
    bar.btnDis:SetEnabled(canDisenchant == true); bar.btnDis:SetAlpha(canDisenchant and 1 or 0.25)
    bar:Show()
    LayoutBars()
end

function mod:OnCancelRoll(_, rollID)
    for _, bar in ipairs(bars) do
        if not rollID or bar.rollID == rollID then
            bar.rollID = nil
            bar.endTime = nil
            bar:Hide()
        end
    end
    LayoutBars()
end

function mod:ShowPreview()
    EnsureContainer()
    local bar = AcquireBar()
    bar.rollID = nil
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
    ApplyBarBorder(bar, 0.64, 0.21, 0.93)
    bar.btnNeed:SetEnabled(true); bar.btnGreed:SetEnabled(true); bar.btnDis:SetEnabled(true)
    bar.btnNeed:SetAlpha(1); bar.btnGreed:SetAlpha(1); bar.btnDis:SetAlpha(1)
    bar:Show()
    LayoutBars()
end

function mod:OnEnable()
    EnsureContainer()
    self:RegisterEvent("START_LOOT_ROLL", self.OnStartRoll)
    self:RegisterEvent("CANCEL_LOOT_ROLL", self.OnCancelRoll)
    self:RegisterEvent("CANCEL_ALL_LOOT_ROLLS", function() self:OnCancelRoll(nil, nil) end)
    self:RegisterEvent("LOOT_ROLLS_COMPLETE", function() self:OnCancelRoll(nil, nil) end)
end

function mod:OnDisable()
    self:OnCancelRoll(nil, nil)
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

    _, h = W:WideButton(parent, "预览 Roll 点条（12 秒）", y, function() self:ShowPreview() end)
    y = y - h
    return y
end
