----------------------------------------------------------------------
--  kkowoUI — Modules/GearList.lua
--  人物面板（C）右侧贴边「装备一览」卡片：
--    • 与人物面板顶部英雄卡同款圆角 Pretty 卡片 + 统一圆角图标与品质色细框
--    • 每格一行：图标 / 品质色名称 / 装等，附魔绿点、低耐久百分比提示
--    • 悬停显示物品提示并点亮人物模型旁对应的装备格；Shift / Ctrl 点击与装备格一致（发链接 / 试穿）
--    • 只挂在「角色」页签（PaperDollFrame）上，切到声望/技能页自动收起；
--      右侧被其它界面窗口占用时自动让位，关闭模块即彻底隐藏（零污染）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_floor, math_max, pcall, string_format, tonumber, tostring, type =
    ipairs, math.floor, math.max, pcall, string.format, tonumber, tostring, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local ST = F.StyleTokens

local mod = F.RegisterModule("gearList", {
    title = "人物面板右侧装备一览",
    desc = "打开人物面板（C）时在右侧贴边显示全部当前装备：圆角图标、品质色名称、装等、附魔标记与低耐久提示，悬停看详情。",
    group = "visual",
    order = 22,
    defaults = {
        enabled = true,
        showCosmetic = false,   -- 是否列出衬衣 / 战袍
        showEnchantDot = true,  -- 已附魔装备在图标右下角显示绿点
        showLowDurability = true, -- 耐久低于 60% 时在装等左侧显示百分比
    },
})

-- 卡片强调色：信息卡片统一用 info 青绿（与人物面板顶部「平均装等 / 装备耐久」英雄卡一致）
local INFO = ST.COLORS.info
local ACCENT_R, ACCENT_G, ACCENT_B = INFO[1], INFO[2], INFO[3]

local PANEL_W = 248
local PAD_X = 10
local HEADER_H = 30
local ROW_H = 23
local ICON_SZ = 19
local GROUP_GAP = 7
local EDGE_GAP = 6   -- 与人物面板（或伸出右缘的页签按钮）之间的间距
local ROW_INSET = 4 -- 行内容相对行框的内缩（悬停高亮是整行圆角底色，比内容宽一圈）

-- 分组：防具 / 首饰 / 武器（组间留细分隔线）；cosmetic = 衬衣、战袍（默认不列）
local SLOT_GROUPS = {
    {
        { id = 1,  slot = "HeadSlot",          label = _G.HEADSLOT or "头部" },
        { id = 2,  slot = "NeckSlot",          label = _G.NECKSLOT or "颈部" },
        { id = 3,  slot = "ShoulderSlot",      label = _G.SHOULDERSLOT or "肩部" },
        { id = 15, slot = "BackSlot",          label = _G.BACKSLOT or "背部" },
        { id = 5,  slot = "ChestSlot",         label = _G.CHESTSLOT or "胸部" },
        { id = 4,  slot = "ShirtSlot",         label = _G.SHIRTSLOT or "衬衣", cosmetic = true },
        { id = 19, slot = "TabardSlot",        label = _G.TABARDSLOT or "战袍", cosmetic = true },
        { id = 9,  slot = "WristSlot",         label = _G.WRISTSLOT or "手腕" },
        { id = 10, slot = "HandsSlot",         label = _G.HANDSSLOT or "手" },
        { id = 6,  slot = "WaistSlot",         label = _G.WAISTSLOT or "腰部" },
        { id = 7,  slot = "LegsSlot",          label = _G.LEGSSLOT or "腿部" },
        { id = 8,  slot = "FeetSlot",          label = _G.FEETSLOT or "脚" },
    },
    {
        { id = 11, slot = "Finger0Slot",       label = _G.FINGER0SLOT or "手指" },
        { id = 12, slot = "Finger1Slot",       label = _G.FINGER1SLOT or "手指" },
        { id = 13, slot = "Trinket0Slot",      label = _G.TRINKET0SLOT or "饰品" },
        { id = 14, slot = "Trinket1Slot",      label = _G.TRINKET1SLOT or "饰品" },
    },
    {
        { id = 16, slot = "MainHandSlot",      label = _G.MAINHANDSLOT or "主手" },
        { id = 17, slot = "SecondaryHandSlot", label = _G.SECONDARYHANDSLOT or "副手" },
        { id = 18, slot = "RangedSlot",        label = _G.RANGEDSLOT or "远程" },
    },
}

local panel = nil
local rows = {}
local separators = {}
local equippedItemIDs = {}
local hookedPanels = false
local refreshQueued = false
local UpdateAnchor -- 前向声明（刷新时先对齐右缘）

----------------------------------------------------------------------
--  物品信息读取（全部 pcall + 保密值安全）
----------------------------------------------------------------------
local function GetQualityColor(q)
    q = F.PlainNumber(q, nil)
    if not q then return 0.92, 0.94, 0.97 end
    if _G.C_Item and _G.C_Item.GetItemQualityColor then
        local ok, r, g, b = pcall(_G.C_Item.GetItemQualityColor, q)
        if ok and F.PlainNumber(r, nil) then return r, g, b end
    end
    if _G.GetItemQualityColor then
        local ok, r, g, b = pcall(_G.GetItemQualityColor, q)
        if ok and F.PlainNumber(r, nil) then return r, g, b end
    end
    local c = _G.ITEM_QUALITY_COLORS and _G.ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
    return 0.92, 0.94, 0.97
end

local function GetEquippedItemLevel(slotId, link)
    if _G.ItemLocation and _G.ItemLocation.CreateFromEquipmentSlot and _G.C_Item and _G.C_Item.GetCurrentItemLevel then
        local okL, loc = pcall(_G.ItemLocation.CreateFromEquipmentSlot, _G.ItemLocation, slotId)
        if okL and loc then
            local ok, lvl = pcall(_G.C_Item.GetCurrentItemLevel, loc)
            lvl = ok and F.PlainNumber(lvl, nil) or nil
            if lvl and lvl > 0 then return lvl end
        end
    end
    if link then
        local fn = (_G.C_Item and _G.C_Item.GetDetailedItemLevelInfo) or _G.GetDetailedItemLevelInfo
        if fn then
            local ok, lvl = pcall(fn, link)
            lvl = ok and F.PlainNumber(lvl, nil) or nil
            if lvl and lvl > 0 then return lvl end
        end
        if _G.GetItemInfo then
            local ok, _, _, _, lvl = pcall(_G.GetItemInfo, link)
            lvl = ok and F.PlainNumber(lvl, nil) or nil
            if lvl and lvl > 0 then return lvl end
        end
    end
    return nil
end

local function HasEnchant(link)
    if type(link) ~= "string" then return false end
    local ench = link:match("item:%-?%d+:(%-?%d*)")
    local n = ench and tonumber(ench) or nil
    return n ~= nil and n > 0
end

local function GetDurabilityPct(slotId)
    if not _G.GetInventoryItemDurability then return nil end
    local ok, cur, mx = pcall(_G.GetInventoryItemDurability, slotId)
    cur = ok and F.PlainNumber(cur, nil) or nil
    mx = ok and F.PlainNumber(mx, nil) or nil
    if cur and mx and mx > 0 then return cur / mx end
    return nil
end

local function GetEmptySlotTexture(slotName)
    if not _G.GetInventorySlotInfo then return nil end
    local ok, _, tex = pcall(_G.GetInventorySlotInfo, slotName)
    if ok then return tex end
    return nil
end

----------------------------------------------------------------------
--  构建
----------------------------------------------------------------------
local function FindPaperDollSlotButton(slotName)
    return _G["Character" .. slotName]
end

local function CreateRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local hl = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    hl:SetAllPoints(row)
    hl:SetColorTexture(1, 1, 1, 0.07)
    ST.MaskTexture(row, hl, 4)
    hl:Hide()
    row._hl = hl

    local iconBox = CreateFrame("Frame", nil, row)
    iconBox:SetSize(ICON_SZ, ICON_SZ)
    iconBox:SetPoint("LEFT", row, "LEFT", ROW_INSET, 0)
    iconBox:EnableMouse(false)
    local icon = iconBox:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(iconBox)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ST.MaskIcon(iconBox, icon, 4)
    row._iconBox = iconBox
    row._icon = icon

    local dotWrap = CreateFrame("Frame", nil, iconBox)
    dotWrap:SetAllPoints(iconBox)
    dotWrap:SetFrameLevel(iconBox:GetFrameLevel() + 4)
    dotWrap:EnableMouse(false)
    local dot = dotWrap:CreateTexture(nil, "OVERLAY", nil, 7)
    dot:SetSize(6, 6)
    dot:SetPoint("CENTER", iconBox, "BOTTOMRIGHT", -1, 1)
    dot:SetTexture(ST.TEX.CIRCLE_MASK)
    local pc = ST.COLORS.positive
    dot:SetVertexColor(pc[1], pc[2], pc[3], 1)
    dot:Hide()
    row._dotWrap = dotWrap
    row._enchDot = dot

    local lvl = row:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(lvl, ST.FONT.body, 0.90, 0.93, 0.97, 1)
    lvl:SetPoint("RIGHT", row, "RIGHT", -ROW_INSET, 0)
    lvl:SetJustifyH("RIGHT")
    lvl:SetWidth(32)
    row._lvl = lvl

    local dur = row:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(dur, ST.FONT.caption, 1, 0.58, 0.22, 1)
    dur:SetPoint("RIGHT", lvl, "LEFT", -4, 0)
    dur:SetJustifyH("RIGHT")
    dur:Hide()
    row._dur = dur

    local name = row:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(name, ST.FONT.body, 0.92, 0.94, 0.97, 1)
    name:SetPoint("LEFT", iconBox, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", lvl, "LEFT", -4, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row._name = name

    local function ClearRowHover(self)
        self._hl:Hide()
        local locked = self._lockedBtn
        self._lockedBtn = nil
        if locked and locked.UnlockHighlight then pcall(locked.UnlockHighlight, locked) end
    end

    row:SetScript("OnEnter", function(self)
        self._hl:Show()
        if self._lockedBtn and self._lockedBtn.UnlockHighlight then
            pcall(self._lockedBtn.UnlockHighlight, self._lockedBtn)
            self._lockedBtn = nil
        end
        local btn = self._spec and FindPaperDollSlotButton(self._spec.slot)
        if btn and btn.LockHighlight then
            pcall(btn.LockHighlight, btn)
            self._lockedBtn = btn
        end
        if _G.GameTooltip and self._spec then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT", 6, 0)
            if self._link then
                pcall(_G.GameTooltip.SetInventoryItem, _G.GameTooltip, "player", self._spec.id)
            else
                _G.GameTooltip:SetText(self._spec.label, 1, 1, 1)
                _G.GameTooltip:AddLine("此部位当前未装备物品", 0.62, 0.66, 0.72)
            end
            _G.GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        ClearRowHover(self)
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    row:SetScript("OnHide", function(self)
        ClearRowHover(self)
    end)
    row:SetScript("OnClick", function(self)
        -- 只响应与人物装备格一致的修饰键点击（Shift 发链接 / Ctrl 试穿），绝不拿起或替换装备
        if self._link and _G.IsModifiedClick and _G.IsModifiedClick() and _G.HandleModifiedItemClick then
            pcall(_G.HandleModifiedItemClick, self._link)
        end
    end)
    return row
end

local RefreshNow -- 前向声明

local function BuildPanel()
    if panel then return panel end
    local cf = _G.CharacterFrame
    if not cf then return nil end
    local host = _G.PaperDollFrame or cf

    local p = CreateFrame("Frame", "kkowoUI_GearList", host)
    p:SetWidth(PANEL_W)
    p:SetPoint("TOPLEFT", cf, "TOPRIGHT", EDGE_GAP, 0)
    p:SetFrameStrata(cf:GetFrameStrata())
    p:SetFrameLevel((F.PlainNumber(host:GetFrameLevel(), 5) or 5) + 6)
    p:EnableMouse(true)

    -- 平均装等已在人物面板顶部英雄卡显示，这里只留标题，不重复
    local title = p:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(title, ST.FONT.title, 0.94, 0.97, 1.00, 1)
    title:SetPoint("TOPLEFT", p, "TOPLEFT", PAD_X + 2, -8)
    title:SetText("装备一览")
    p._title = title

    local headLine = p:CreateTexture(nil, "OVERLAY", nil, 2)
    ST.Hairline(headLine)
    headLine:SetPoint("TOPLEFT", p, "TOPLEFT", PAD_X, -HEADER_H + 4)
    headLine:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD_X, -HEADER_H + 4)
    headLine:SetColorTexture(ACCENT_R, ACCENT_G, ACCENT_B, 0.30)
    p._headLine = headLine

    p:SetScript("OnShow", function()
        if #rows == 0 then
            RefreshNow()
        else
            mod:QueueRefresh()
        end
    end)
    -- 保险：打开人物面板 / 切回「角色」页签时也刷新一次（并重新判断右侧是否被别的窗口占用）
    local function onHostShow()
        if mod._active then
            mod:QueueRefresh()
            if mod._queueVisibility then mod._queueVisibility() end
        end
    end
    if cf.HookScript then cf:HookScript("OnShow", onHostShow) end
    if host ~= cf and host.HookScript then host:HookScript("OnShow", onHostShow) end
    -- 先按大致高度画一次卡片底，避免首帧没有背景；真实高度在首次刷新时按行数重算并重画
    p:SetHeight(HEADER_H + ROW_H * 19 + GROUP_GAP * 2 + 8)
    F.Theme.PaintPrettyCardOverlay(p, ACCENT_R, ACCENT_G, ACCENT_B, HEADER_H, {
        alpha = 0.82, haloAlpha = 0.12, haloSpread = 10, headerTopAlpha = 0.22, headerBottomAlpha = 0.00,
    })
    p:Hide()
    panel = p
    return p
end

local function EnsureRows(count)
    for i = #rows + 1, count do
        rows[i] = CreateRow(panel)
    end
end

local function EnsureSeparator(i)
    local sep = separators[i]
    if sep then return sep end
    sep = panel:CreateTexture(nil, "ARTWORK", nil, 1)
    ST.Hairline(sep)
    sep:SetColorTexture(1, 1, 1, 0.07)
    separators[i] = sep
    return sep
end

----------------------------------------------------------------------
--  刷新
----------------------------------------------------------------------

local function PaintRow(row, spec, db)
    if row._spec ~= spec and row._lockedBtn then
        if row._lockedBtn.UnlockHighlight then pcall(row._lockedBtn.UnlockHighlight, row._lockedBtn) end
        row._lockedBtn = nil
    end
    row._spec = spec
    local link = _G.GetInventoryItemLink and _G.GetInventoryItemLink("player", spec.id) or nil
    link = F.PlainString(link, nil)
    row._link = link

    if link then
        local itemID = tonumber(link:match("item:(%d+)"))
        if itemID then equippedItemIDs[itemID] = true end
        local tex = _G.GetInventoryItemTexture and _G.GetInventoryItemTexture("player", spec.id) or nil
        row._icon:SetTexture(tex or 134400)
        row._icon:SetDesaturated(false)
        row._icon:SetAlpha(1)
        local q = _G.GetInventoryItemQuality and _G.GetInventoryItemQuality("player", spec.id) or nil
        local r, g, b = GetQualityColor(q)
        local nm = link:match("%[(.-)%]")
        if not nm or nm == "" then nm = spec.label end
        row._name:SetText(nm)
        row._name:SetTextColor(r, g, b, 1)
        ST.ApplyRoundedBorder(row._iconBox, 4, r * 0.85, g * 0.85, b * 0.85, 0.92, 3)

        local lvl = GetEquippedItemLevel(spec.id, link)
        row._lvl:SetText(lvl and tostring(math_floor(lvl + 0.5)) or "")

        row._enchDot:SetShown(db.showEnchantDot ~= false and HasEnchant(link))

        local pct = db.showLowDurability ~= false and GetDurabilityPct(spec.id) or nil
        if pct and pct < 0.60 then
            if pct <= 0 then
                row._dur:SetText("已损坏")
                row._dur:SetTextColor(1.00, 0.30, 0.34, 1)
            else
                row._dur:SetText(string_format("%d%%", math_floor(pct * 100 + 0.5)))
                if pct <= 0.30 then
                    row._dur:SetTextColor(1.00, 0.42, 0.36, 1)
                else
                    row._dur:SetTextColor(1.00, 0.70, 0.30, 1)
                end
            end
            row._dur:Show()
            row._name:SetPoint("RIGHT", row._dur, "LEFT", -4, 0)
        else
            row._dur:SetText("")
            row._dur:Hide()
            row._name:SetPoint("RIGHT", row._lvl, "LEFT", -4, 0)
        end
    else
        local tex = GetEmptySlotTexture(spec.slot)
        row._icon:SetTexture(tex or 134400)
        row._icon:SetDesaturated(true)
        row._icon:SetAlpha(0.45)
        row._name:SetText(spec.label .. " · 未装备")
        row._name:SetTextColor(0.50, 0.54, 0.60, 1)
        ST.ApplyRoundedBorder(row._iconBox, 4, 0.20, 0.22, 0.26, 0.80, 3)
        row._lvl:SetText("")
        row._enchDot:Hide()
        row._dur:SetText("")
        row._dur:Hide()
        row._name:SetPoint("RIGHT", row._lvl, "LEFT", -4, 0)
    end
end

RefreshNow = function()
    refreshQueued = false
    if not (panel and panel:IsVisible() and mod._active) then return end
    local db = mod:GetDB()
    UpdateAnchor()
    for k in _G.pairs(equippedItemIDs) do equippedItemIDs[k] = nil end

    -- 先数行数，按需建行
    local total = 0
    for _, group in ipairs(SLOT_GROUPS) do
        for _, spec in ipairs(group) do
            if not spec.cosmetic or db.showCosmetic == true then total = total + 1 end
        end
    end
    EnsureRows(total)

    local y = -HEADER_H - 2
    local idx = 0
    local nGroups = #SLOT_GROUPS
    for gi, group in ipairs(SLOT_GROUPS) do
        for _, spec in ipairs(group) do
            if not spec.cosmetic or db.showCosmetic == true then
                idx = idx + 1
                local row = rows[idx]
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X - ROW_INSET, y)
                row:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -(PAD_X - ROW_INSET), y)
                PaintRow(row, spec, db)
                row:Show()
                y = y - ROW_H
            end
        end
        local sep = EnsureSeparator(gi)
        if gi < nGroups then
            y = y - math_floor(GROUP_GAP * 0.5)
            sep:ClearAllPoints()
            sep:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_X + 2, y)
            sep:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD_X - 2, y)
            sep:Show()
            y = y - (GROUP_GAP - math_floor(GROUP_GAP * 0.5))
        else
            sep:Hide()
        end
    end
    for i = idx + 1, #rows do rows[i]:Hide() end

    panel:SetHeight(math_max(80, -y + 8))

    -- 每次刷新都按当前尺寸重画卡片（高度随衬衣/战袍开关变化；圆角半径跟随悬浮提示统一设置）
    F.Theme.PaintPrettyCardOverlay(panel, ACCENT_R, ACCENT_G, ACCENT_B, HEADER_H, {
        alpha = 0.82,
        haloAlpha = 0.12,
        haloSpread = 10,
        headerTopAlpha = 0.22,
        headerBottomAlpha = 0.00,
    })
end

function mod:QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0.05, RefreshNow)
end

----------------------------------------------------------------------
--  右侧被其它界面窗口占用时让位（例如角色面板开着再打开好友 / 法术书，系统会把它摆在右边）
----------------------------------------------------------------------
local function RectsOverlap(a, b)
    if not (a and b and a.GetLeft and b.GetLeft) then return false end
    local al, ar, at, ab = F.PlainNumber(a:GetLeft(), nil), F.PlainNumber(a:GetRight(), nil),
        F.PlainNumber(a:GetTop(), nil), F.PlainNumber(a:GetBottom(), nil)
    local bl, br, bt, bb = F.PlainNumber(b:GetLeft(), nil), F.PlainNumber(b:GetRight(), nil),
        F.PlainNumber(b:GetTop(), nil), F.PlainNumber(b:GetBottom(), nil)
    if not (al and ar and at and ab and bl and br and bt and bb) then return false end
    local as = F.PlainNumber(a:GetEffectiveScale(), 1) or 1
    local bs = F.PlainNumber(b:GetEffectiveScale(), 1) or 1
    al, ar, at, ab = al * as, ar * as, at * as, ab * as
    bl, br, bt, bb = bl * bs, br * bs, bt * bs, bb * bs
    return al < br and ar > bl and ab < bt and at > bb
end

local function IsRightSideTaken(xOffset)
    if not (panel and _G.GetUIPanel) then return false end
    local cf = _G.CharacterFrame
    local al, ar, at, ab
    if cf and cf.GetRight and cf.GetTop then
        local cfR = F.PlainNumber(cf:GetRight(), nil)
        local cfT = F.PlainNumber(cf:GetTop(), nil)
        local cfS = F.PlainNumber(cf:GetEffectiveScale(), 1) or 1
        local pH = F.PlainNumber(panel:GetHeight(), 400) or 400
        if cfR and cfT then
            al = (cfR + (xOffset or panel._edgeX or EDGE_GAP)) * cfS
            ar = al + PANEL_W * cfS
            at = cfT * cfS
            ab = at - pH * cfS
        end
    end
    for _, pos in ipairs({ "center", "right", "doublewide" }) do
        local ok, other = pcall(_G.GetUIPanel, pos)
        if ok and other and other ~= cf and other.IsShown and other:IsShown() then
            if al then
                local bl, br, bt, bb = F.PlainNumber(other:GetLeft(), nil), F.PlainNumber(other:GetRight(), nil),
                    F.PlainNumber(other:GetTop(), nil), F.PlainNumber(other:GetBottom(), nil)
                local bs = F.PlainNumber(other:GetEffectiveScale(), 1) or 1
                if bl and br and bt and bb then
                    bl, br, bt, bb = bl * bs, br * bs, bt * bs, bb * bs
                    if al < br and ar > bl and ab < bt and at > bb then
                        return true
                    end
                end
            elseif RectsOverlap(panel, other) then
                return true
            end
        end
    end
    return false
end

-- 人物面板右缘可能伸出竖排页签 / 小按钮（模式切换、属性栏开关等）：贴在它们外侧，绝不盖住
local NAMED_EDGE_BUTTONS = { "CharacterFrameModeTab", "CharacterFrameTab", "PaperDollSidebarTab" }

local function MeasureRightProtrusion(cf)
    local cfR = F.PlainNumber(cf:GetRight(), nil)
    if not cfR then return 0 end
    local cfS = F.PlainNumber(cf:GetEffectiveScale(), 1) or 1
    if cfS <= 0 then cfS = 1 end
    local best = cfR
    local seen = {}
    local function consider(f)
        if not f or seen[f] or f == panel then return end
        seen[f] = true
        if f.IsForbidden and f:IsForbidden() then return end
        if not (f.IsShown and f:IsShown() and f.GetRight and f.GetLeft) then return end
        local es = F.PlainNumber(f.GetEffectiveScale and f:GetEffectiveScale(), cfS) or cfS
        local r = F.PlainNumber(f:GetRight(), nil)
        local l = F.PlainNumber(f:GetLeft(), nil)
        local w = F.PlainNumber(f:GetWidth(), nil)
        if not (r and l and w) or w <= 0 or w >= 140 then return end
        r, l = r * es / cfS, l * es / cfS
        -- 只算「从面板内部伸出右缘」的小部件，不算挂在远处的独立窗口
        if l < cfR + 4 and r > best then best = r end
    end
    for _, ch in ipairs({ cf:GetChildren() }) do
        consider(ch)
    end
    for _, prefix in ipairs(NAMED_EDGE_BUTTONS) do
        for i = 1, 8 do consider(_G[prefix .. i]) end
    end
    return math_max(0, best - cfR)
end

UpdateAnchor = function()
    if not panel then return end
    local cf = _G.CharacterFrame
    if not cf then return end
    local host = _G.PaperDollFrame or cf
    local strata = cf.GetFrameStrata and F.PlainString(cf:GetFrameStrata(), nil) or nil
    if strata and panel.SetFrameStrata then pcall(panel.SetFrameStrata, panel, strata) end
    local lvl = (F.PlainNumber(host.GetFrameLevel and host:GetFrameLevel(), 5) or 5) + 6
    if panel.SetFrameLevel then pcall(panel.SetFrameLevel, panel, lvl) end
    local x = MeasureRightProtrusion(cf) + EDGE_GAP
    if panel._edgeX ~= x then
        panel._edgeX = x
        panel:ClearAllPoints()
        panel:SetPoint("TOPLEFT", cf, "TOPRIGHT", x, 0)
    end
    return x
end

local function SyncVisibility()
    if not panel then return end
    local want = mod._active == true
    if want then
        local x = UpdateAnchor()
        if IsRightSideTaken(x) then
            panel:Hide()
        else
            panel:Show()
        end
    else
        panel:Hide()
    end
end

local QueueVisibility = F.Debounce(0.02, SyncVisibility)
mod._queueVisibility = QueueVisibility

local function HookPanelManager()
    if hookedPanels then return end
    hookedPanels = true
    for _, fnName in ipairs({ "ShowUIPanel", "HideUIPanel", "UpdateUIPanelPositions" }) do
        if type(_G[fnName]) == "function" then
            _G.hooksecurefunc(fnName, function()
                if mod._active then QueueVisibility() end
            end)
        end
    end
end

local function TryInstall()
    if not BuildPanel() then return false end
    HookPanelManager()
    SyncVisibility()
    return true
end

----------------------------------------------------------------------
--  生命周期
----------------------------------------------------------------------
function mod:OnEnable()
    local function onItemEvent()
        if panel and panel:IsVisible() then mod:QueueRefresh() end
    end
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", onItemEvent)
    self:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player", onItemEvent)
    self:RegisterEvent("UPDATE_INVENTORY_DURABILITY", onItemEvent)
    self:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_UPDATE", onItemEvent)
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, _, itemID)
        if not (panel and panel:IsVisible()) then return end
        local id = F.PlainNumber(itemID, nil)
        if id and (equippedItemIDs[id] or _G.next(equippedItemIDs) == nil) then
            mod:QueueRefresh()
        end
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if not panel then TryInstall() end
    end)
    self:RegisterEvent("ADDON_LOADED", function(_, _, name)
        if not panel and type(name) == "string" and name:find("CharacterFrame", 1, true) then TryInstall() end
    end)
    TryInstall()
end

function mod:OnDisable()
    if panel then panel:Hide() end
end

function mod:OnRefresh()
    SyncVisibility()
    if panel and panel:IsVisible() then RefreshNow() end
end

function mod:OnThemeChanged()
    if panel then
        if panel._title then ST.ApplyText(panel._title, ST.FONT.title, 0.94, 0.97, 1.00, 1) end
        for _, row in ipairs(rows) do
            if row._lvl then ST.ApplyText(row._lvl, ST.FONT.body, 0.90, 0.93, 0.97, 1) end
            if row._dur then ST.ApplyText(row._dur, ST.FONT.caption, 1, 0.58, 0.22, 1) end
            if row._name then ST.ApplyText(row._name, ST.FONT.body, 0.92, 0.94, 0.97, 1) end
        end
        if panel:IsVisible() then RefreshNow() end
    end
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "列出衬衣与战袍",
        tooltip = "默认只列出影响属性的装备；开启后衬衣与战袍也会出现在装备一览里。",
        getValue = function() return db.showCosmetic == true end,
        setValue = function(v) db.showCosmetic = v == true; mod:OnRefresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "已附魔装备显示绿点",
        tooltip = "图标右下角的小绿点表示该装备已经附魔。",
        getValue = function() return db.showEnchantDot ~= false end,
        setValue = function(v) db.showEnchantDot = v == true; mod:OnRefresh() end,
    }, {
        type = "toggle",
        text = "耐久低于 60% 时提示",
        tooltip = "在装等左侧显示该件装备的剩余耐久百分比（已损坏显示红字）。",
        getValue = function() return db.showLowDurability ~= false end,
        setValue = function(v) db.showLowDurability = v == true; mod:OnRefresh() end,
    })
    y = y - h

    return y
end
