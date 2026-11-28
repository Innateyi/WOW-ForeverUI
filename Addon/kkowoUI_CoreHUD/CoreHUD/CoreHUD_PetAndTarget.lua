----------------------------------------------------------------------
--  kkowoUI_CoreHUD — CoreHUD/CoreHUD_PetAndTarget.lua
--  独立宠物圆角框体（含猎人快乐度悬停提示与安全喂食菜单）+ 顶部极简目标条
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local CH = F._CoreHUD
if not CH then return end

local ipairs, math_abs, math_floor, math_max, math_min, pairs, pcall, tostring, type =
    ipairs, math.abs, math.floor, math.max, math.min, pairs, pcall, tostring, type
local string_format = string.format
local table_concat, table_sort = table.concat, table.sort
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown

local ST = F.StyleTokens
local M = F.Motion
local mod = CH.mod
local CreateWingBar = CH.CreateWingBar
local DEBUFF_TYPE_COLORS = CH.DEBUFF_TYPE_COLORS
local UnitExistsSafe = CH.UnitExistsSafe

----------------------------------------------------------------------
--  2) 独立宠物圆角框体（PetHUD）+ 猎人快乐度悬停提示与安全喂食网格菜单
----------------------------------------------------------------------
local FEED_PET_SPELL_ID = 6991
local petFeedMenu = nil
local petFeedButtons = {}
local petFeedCloseFrame = nil
CH.SyncClickLayers = CH.SyncClickLayers

local function GetPetHappinessInfoSafe()
    local fn = (_G.C_PetInfo and _G.C_PetInfo.GetPetHappiness) or _G.GetPetHappiness
    if not fn then return nil end
    local ok, h, dmg, rate = pcall(fn)
    if not ok then return nil end
    return F.PlainNumber(h, nil), F.PlainNumber(dmg, nil), F.PlainNumber(rate, nil)
end

local function PetHappinessAccent(happy)
    if happy == 3 then
        return 0.36, 0.90, 0.56
    elseif happy == 2 then
        return 0.98, 0.80, 0.32
    elseif happy == 1 then
        return 0.96, 0.34, 0.38
    end
    return F.Theme.GetAccent()
end

local function BuildPetHappinessTooltipText()
    local happy, dmgPct, loyaltyRate = GetPetHappinessInfoSafe()
    if not happy then return nil end
    local lines = {}
    local stateText = (happy == 3 and (_G.PET_HAPPINESS3 or "开心"))
        or (happy == 2 and (_G.PET_HAPPINESS2 or "满足"))
        or (_G.PET_HAPPINESS1 or "不开心")
    lines[#lines + 1] = stateText
    if dmgPct then
        lines[#lines + 1] = string_format("宠物造成 %d%% 伤害", dmgPct)
    end
    local loyaltyFn = (_G.C_PetInfo and _G.C_PetInfo.GetPetLoyalty) or _G.GetPetLoyalty
    local loyalty = loyaltyFn and F.PlainString(loyaltyFn(), nil) or nil
    if loyalty and loyalty ~= "" then
        lines[#lines + 1] = loyalty
    end
    if loyaltyRate and loyaltyRate ~= 0 then
        lines[#lines + 1] = loyaltyRate > 0 and (_G.GAINING_LOYALTY or "忠诚度正在上升") or (_G.LOSING_LOYALTY or "忠诚度正在下降")
    end
    local dietFn = (_G.C_PetInfo and _G.C_PetInfo.GetPetFoodTypes) or _G.GetPetFoodTypes
    if dietFn then
        local ok, r1, r2, r3, r4, r5, r6 = pcall(dietFn)
        if ok then
            local foods = {}
            if type(r1) == "table" then
                for _, v in ipairs(r1) do
                    local s = F.PlainString(v, nil)
                    if s and s ~= "" then foods[#foods + 1] = s end
                end
            else
                for _, v in ipairs({ r1, r2, r3, r4, r5, r6 }) do
                    local s = F.PlainString(v, nil)
                    if s and s ~= "" then foods[#foods + 1] = s end
                end
            end
            if #foods > 0 then
                local delim = F.PlainString(_G.PET_FOOD_DELIMIT, "、") or "、"
                lines[#lines + 1] = "食物：" .. table_concat(foods, delim)
            end
        end
    end
    lines[#lines + 1] = "左键点击喂养宠物"
    return table_concat(lines, "\n"), happy
end

local function HidePetIconTooltip()
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.HideWidgetTooltip) == "function" then
        pcall(EUI.HideWidgetTooltip)
    end
    if _G.GameTooltip then
        _G.GameTooltip:Hide()
    end
end

local function ShowPetIconTooltip(anchor)
    local txt, happy = BuildPetHappinessTooltipText()
    if not txt then return end
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.ShowWidgetTooltip) == "function" then
        pcall(EUI.ShowWidgetTooltip, anchor, txt)
        return
    end
    if _G.GameTooltip then
        local r, g, b = PetHappinessAccent(happy)
        _G.GameTooltip:SetOwner(anchor, "ANCHOR_TOP", 0, 6)
        local first = true
        for line in txt:gmatch("[^\n]+") do
            if first then
                _G.GameTooltip:AddLine(line, r, g, b)
                first = false
            elseif line == "左键点击喂养宠物" then
                _G.GameTooltip:AddLine(line, 0.37, 0.88, 0.62)
            else
                _G.GameTooltip:AddLine(line, 0.86, 0.88, 0.92)
            end
        end
        _G.GameTooltip:Show()
    end
end

local function HidePetFeedMenu()
    if not (petFeedMenu and petFeedMenu:IsShown()) then
        if petFeedCloseFrame then
            petFeedCloseFrame:UnregisterAllEvents()
        end
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        -- 战斗中延迟关闭：保留事件监听，待脱战真正隐藏后由 OnHide 注销（P3-03）
        F.CombatDefer("kkowoUI_PetFeedHide", function()
            if petFeedMenu then petFeedMenu:Hide() end
            if petFeedCloseFrame then petFeedCloseFrame:UnregisterAllEvents() end
        end)
        return
    end
    if petFeedCloseFrame then
        petFeedCloseFrame:UnregisterAllEvents()
    end
    petFeedMenu:Hide()
end

local function ScanPetEdibleFoods()
    local foods = {}
    local byID = {}
    local CCont = _G.C_Container
    local canEat = _G.C_PetInfo and _G.C_PetInfo.CanPetEatItem
    if not (CCont and CCont.GetContainerNumSlots and CCont.GetContainerItemInfo and canEat) then
        return foods
    end
    local maxBag = _G.NUM_BAG_SLOTS or 4
    for bag = 0, maxBag do
        local slots = F.PlainNumber(CCont.GetContainerNumSlots(bag), 0) or 0
        for slot = 1, slots do
            local ok, info = pcall(CCont.GetContainerItemInfo, bag, slot)
            if ok and type(info) == "table" then
                local itemID = F.PlainNumber(info.itemID, nil)
                if itemID then
                    local okEat, edible = pcall(canEat, itemID)
                    if okEat and edible == true then
                        local cnt = F.PlainNumber(info.stackCount, 1) or 1
                        local existing = byID[itemID]
                        if existing then
                            existing.count = existing.count + cnt
                        else
                            local entry = {
                                bag = bag,
                                slot = slot,
                                itemID = itemID,
                                icon = info.iconFileID or 134400,
                                quality = F.PlainNumber(info.quality, 1) or 1,
                                count = cnt,
                            }
                            byID[itemID] = entry
                            foods[#foods + 1] = entry
                        end
                    end
                end
            end
        end
    end
    table_sort(foods, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.itemID < b.itemID
    end)
    return foods
end

local function EnsurePetFeedMenu()
    if petFeedMenu then return petFeedMenu end
    local m = CreateFrame("Frame", "kkowoUI_PetFeedMenu", _G.UIParent)
    m:SetFrameStrata("DIALOG")
    m:SetFrameLevel(80)
    m:SetClampedToScreen(true)
    m:EnableMouse(true)

    local title = m:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(title, ST.FONT.body, 0.95, 0.97, 1.00, 1)
    title:SetPoint("TOPLEFT", m, "TOPLEFT", 10, -7)
    title:SetText("喂养宠物")
    m._title = title

    local emptyFS = m:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(emptyFS, ST.FONT.caption, 0.72, 0.76, 0.82, 1)
    emptyFS:SetPoint("CENTER", m, "CENTER", 0, -9)
    emptyFS:SetText("背包中没有宠物可吃的食物")
    emptyFS:Hide()
    m._emptyFS = emptyFS

    m:SetScript("OnHide", function()
        if petFeedCloseFrame then
            petFeedCloseFrame:UnregisterAllEvents()
        end
    end)

    if not petFeedCloseFrame then
        petFeedCloseFrame = CreateFrame("Frame")
        petFeedCloseFrame:SetScript("OnEvent", function(_, ev)
            if ev == "GLOBAL_MOUSE_DOWN" then
                if petFeedMenu and petFeedMenu:IsShown() then
                    local overMenu = petFeedMenu:IsMouseOver()
                    local overBtn = CH.petFrame and CH.petFrame._iconBox and CH.petFrame._iconBox:IsMouseOver()
                    if not overMenu and not overBtn then
                        HidePetFeedMenu()
                    end
                end
            elseif ev == "PLAYER_REGEN_DISABLED" or ev == "UNIT_PET" then
                HidePetFeedMenu()
            elseif ev == "BAG_UPDATE_DELAYED" then
                if petFeedMenu and petFeedMenu:IsShown() and not (InCombatLockdown and InCombatLockdown()) then
                    if petFeedMenu._rebuildFn then petFeedMenu._rebuildFn() end
                end
            end
        end)
    end

    m:Hide()
    if type(_G.RegisterStateDriver) == "function" then
        pcall(_G.RegisterStateDriver, m, "visibility", "[combat] hide")
    end
    petFeedMenu = m
    return m
end

local function AcquirePetFeedButton(index)
    local btn = petFeedButtons[index]
    if btn then return btn end
    local ok, b = pcall(CreateFrame, "Button", "kkowoUI_PetFeedBtn" .. index, petFeedMenu, "SecureActionButtonTemplate")
    if not (ok and b) then return nil end
    btn = b
    btn:SetSize(32, 32)
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetAttribute("useOnKeyDown", false)
    btn:SetAttribute("type", "spell")
    btn:SetAttribute("spell", FEED_PET_SPELL_ID)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.055, 0.075, 0.94)
    ST.SetHostIconMode(btn, true)
    ST.MaskTexture(btn, bg, 5)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ST.MaskIcon(btn, icon, 5)
    btn._icon = icon

    local cnt = btn:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(cnt, 10, 0.98, 0.98, 1.00, 1)
    cnt:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    cnt:SetJustifyH("RIGHT")
    btn._count = cnt

    btn:HookScript("PostClick", function()
        HidePetFeedMenu()
    end)
    btn:SetScript("OnEnter", function(self)
        local ar, ag, ab = F.Theme.GetAccent()
        ST.ApplyRoundedBorder(self, 5, ar, ag, ab, 0.96, 4)
        if _G.GameTooltip and self._bag ~= nil and self._slot ~= nil then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT", 6, 0)
            pcall(_G.GameTooltip.SetBagItem, _G.GameTooltip, self._bag, self._slot)
            _G.GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        local r, g, bCol = self._qr or 0.28, self._qg or 0.30, self._qb or 0.36
        ST.ApplyRoundedBorder(self, 5, r, g, bCol, 0.86, 4)
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    petFeedButtons[index] = btn
    return btn
end

local function TogglePetFeedMenu(anchor)
    if not (_G.UnitExists and _G.UnitExists("pet")) then return end
    if petFeedMenu and petFeedMenu:IsShown() then
        HidePetFeedMenu()
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        if _G.UIErrorsFrame and _G.UIErrorsFrame.AddMessage then
            _G.UIErrorsFrame:AddMessage("战斗中无法打开喂食菜单。", 1, 0.30, 0.34)
        else
            F.Print("战斗中无法打开喂食菜单，请脱战后重试。")
        end
        return
    end

    HidePetIconTooltip()
    local menu = EnsurePetFeedMenu()
    local function populateMenu()
        if InCombatLockdown and InCombatLockdown() then return end
        local foods = ScanPetEdibleFoods()
        local pad = 8
        local headerH = 26
        local btnSz = 32
        local gap = 5
        local cols = 5
        local happy = GetPetHappinessInfoSafe()
        local ar, ag, ab = PetHappinessAccent(happy)
        local getQualColor = (_G.C_Item and _G.C_Item.GetItemQualityColor) or _G.GetItemQualityColor

        if #foods == 0 then
            for _, b in ipairs(petFeedButtons) do b:Hide() end
            menu._emptyFS:Show()
            menu:SetSize(188, 56)
        else
            menu._emptyFS:Hide()
            local usedCols = math_min(cols, #foods)
            local rows = math_floor((#foods - 1) / cols) + 1
            local totalW = math_max(118, pad * 2 + usedCols * btnSz + (usedCols - 1) * gap)
            local totalH = headerH + pad + rows * btnSz + (rows - 1) * gap
            menu:SetSize(totalW, totalH)
            for i, food in ipairs(foods) do
                local btn = AcquirePetFeedButton(i)
                if btn then
                    local col = (i - 1) % cols
                    local row = math_floor((i - 1) / cols)
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", menu, "TOPLEFT", pad + col * (btnSz + gap), -(headerH + row * (btnSz + gap)))
                    btn._bag = food.bag
                    btn._slot = food.slot
                    btn:SetAttribute("target-bag", food.bag)
                    btn:SetAttribute("target-slot", food.slot)
                    btn._icon:SetTexture(food.icon)
                    if food.count and food.count > 1 then
                        btn._count:SetText(tostring(food.count))
                        btn._count:Show()
                    else
                        btn._count:Hide()
                    end
                    local qr, qg, qb = 0.32, 0.36, 0.42
                    if getQualColor and food.quality >= 1 then
                        local okQ, r, g, bCol = pcall(getQualColor, food.quality)
                        if okQ and F.PlainNumber(r, nil) then
                            qr, qg, qb = r * 0.78 + 0.12, g * 0.78 + 0.12, bCol * 0.78 + 0.12
                        end
                    end
                    btn._qr, btn._qg, btn._qb = qr, qg, qb
                    ST.ApplyRoundedBorder(btn, 5, qr, qg, qb, 0.86, 4)
                    btn:Show()
                end
            end
            for i = #foods + 1, #petFeedButtons do
                petFeedButtons[i]:Hide()
            end
        end
        F.Theme.PaintPrettyCardOverlay(menu, ar, ag, ab, headerH - 2, {
            alpha = 0.90,
            haloAlpha = 0.14,
            haloSpread = 10,
            headerTopAlpha = 0.24,
            headerBottomAlpha = 0.00,
        })
    end

    menu._rebuildFn = populateMenu
    populateMenu()

    -- 通过 UIParent 屏幕坐标定位（绝不直接锚定到宠物普通框体，避免内部安全喂食按钮在战斗期牵连定位保护）
    menu:ClearAllPoints()
    local l = anchor.GetLeft and F.PlainNumber(anchor:GetLeft(), nil)
    local t = anchor.GetTop and F.PlainNumber(anchor:GetTop(), nil)
    local es = anchor.GetEffectiveScale and F.PlainNumber(anchor:GetEffectiveScale(), 1) or 1
    local uiS = _G.UIParent and F.PlainNumber(_G.UIParent:GetEffectiveScale(), 1) or 1
    if l and t and es > 0 and uiS > 0 then
        local k = es / uiS
        menu:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", l * k, t * k + 8)
    else
        menu:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 8)
    end
    menu:Show()
    if petFeedCloseFrame then
        pcall(petFeedCloseFrame.RegisterEvent, petFeedCloseFrame, "GLOBAL_MOUSE_DOWN")
        pcall(petFeedCloseFrame.RegisterEvent, petFeedCloseFrame, "BAG_UPDATE_DELAYED")
        pcall(petFeedCloseFrame.RegisterEvent, petFeedCloseFrame, "PLAYER_REGEN_DISABLED")
        pcall(petFeedCloseFrame.RegisterUnitEvent, petFeedCloseFrame, "UNIT_PET", "player")
    end
end

local function BuildPetHUD()
    if CH.petFrame then return end
    local f = CreateFrame("Frame", "kkowoUI_PetHUD", _G.UIParent)
    f:SetSize(156, 36)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(12)
    f:EnableMouse(false)

    -- 左侧宠物快乐度/头像圆角徽章（猎人可点击打开喂食网格，层高于点击选中层）
    local iconBox = CreateFrame("Frame", nil, f)
    iconBox:SetSize(22, 22)
    iconBox:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    iconBox:SetFrameLevel(f:GetFrameLevel() + 12)
    local isHunter = (F.GetPlayerClass() == "HUNTER")
    iconBox:EnableMouse(isHunter)
    local ibBg = iconBox:CreateTexture(nil, "BACKGROUND")
    ibBg:SetAllPoints()
    ibBg:SetColorTexture(0.04, 0.045, 0.06, 0.92)
    local ibTex = iconBox:CreateTexture(nil, "ARTWORK")
    ibTex:SetPoint("TOPLEFT", iconBox, "TOPLEFT", 2, -2)
    ibTex:SetPoint("BOTTOMRIGHT", iconBox, "BOTTOMRIGHT", -2, 2)
    ST.SetHostIconMode(iconBox, true)
    ST.ApplyRoundedBorder(iconBox, 5, 0.02, 0.022, 0.03, 0.95, 4)
    ST.MaskTexture(iconBox, ibBg, 5)
    ST.MaskIcon(iconBox, ibTex, 5, { keepIfLoaded = true })
    iconBox._tex = ibTex
    if isHunter then
        iconBox:SetScript("OnEnter", function(self)
            local happy = GetPetHappinessInfoSafe()
            local r, g, b = PetHappinessAccent(happy)
            ST.ApplyRoundedBorder(self, 5, r, g, b, 0.96, 4)
            ShowPetIconTooltip(self)
        end)
        iconBox:SetScript("OnLeave", function(self)
            ST.ApplyRoundedBorder(self, 5, 0.02, 0.022, 0.03, 0.95, 4)
            HidePetIconTooltip()
        end)
        iconBox:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and (not self.IsMouseOver or self:IsMouseOver()) then
                TogglePetFeedMenu(self)
            end
        end)
    end
    f._iconBox = iconBox

    local hpBar = CreateWingBar(f, 130, 16, false)
    hpBar:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 4, 0)
    hpBar._trail = M.AttachHealthTrail(hpBar._bar, {
        delay = 0.16, reverse = false, color = ST.COLORS.trail,
    })
    f._hpBar = hpBar

    local ppBar = CreateWingBar(f, 130, 4, false)
    ppBar:SetPoint("TOPLEFT", hpBar, "BOTTOMLEFT", 0, -2)
    f._ppBar = ppBar

    local petTextLayer = CreateFrame("Frame", nil, f)
    petTextLayer:SetAllPoints(f)
    petTextLayer:SetFrameLevel(hpBar:GetFrameLevel() + 8)
    petTextLayer:EnableMouse(false)
    f._textLayer = petTextLayer

    local nameFS = petTextLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(nameFS, 10, 0.96, 0.98, 1.00, 1)
    nameFS:SetShadowOffset(1, -1)
    nameFS:SetPoint("LEFT", hpBar, "LEFT", 6, 0)
    nameFS:SetWidth(76)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    f._nameText = nameFS

    local hpFS = petTextLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(hpFS, 10, 0.96, 0.98, 1.00, 1)
    hpFS:SetShadowOffset(1, -1)
    hpFS:SetPoint("RIGHT", hpBar, "RIGHT", -6, 0)
    hpFS:SetJustifyH("RIGHT")
    hpFS:SetWordWrap(false)
    f._hpText = hpFS

    F.Mover.Register({
        key = "PetHUD",
        label = "宠物独立圆角框体",
        frame = f,
        order = 13,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = -270,
        defaultY = -241,
        allowShiftDrag = false,
        isHidden = function() return not (mod._active and mod:GetDB().showPetFrame ~= false and _G.UnitExists and _G.UnitExists("pet")) end,
    })
    f:EnableMouse(false)

    f:Hide()
    CH.petFrame = f
end

----------------------------------------------------------------------
--  3) 可选顶部极简目标框体（TopTargetHUD：目标长条 + 圆形头像 + 目标的目标）
----------------------------------------------------------------------
local function BuildTopTargetHUD()
    if CH.topTargetFrame then return end
    -- 精确匹配「256px 血蓝条 + 34px 右侧圆形头像(重叠4px) = 286px」，确保解锁居中与实际可见主体 1:1 严格对齐
    local f = CreateFrame("Frame", "kkowoUI_TopTargetHUD", _G.UIParent)
    f:SetSize(286, 38)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(12)
    f:EnableMouse(false)

    local ppBar = CreateWingBar(f, 256, 4, false)
    ppBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 2)
    f._ppBar = ppBar

    local hpBar = CreateWingBar(f, 256, 18, false)
    hpBar:SetPoint("BOTTOMLEFT", ppBar, "TOPLEFT", 0, 2)
    hpBar._trail = M.AttachHealthTrail(hpBar._bar, {
        delay = 0.16, reverse = false, color = ST.COLORS.trail,
    })
    hpBar._spark = M.AttachEdgeSpark(hpBar._bar, {
        reverse = false, width = 10, extraHeight = 2, a = 0.50,
    })
    hpBar._spark:SetShown(false)
    f._hpBar = hpBar

    local targetTextLayer = CreateFrame("Frame", nil, f)
    targetTextLayer:SetAllPoints(f)
    targetTextLayer:SetFrameLevel(hpBar:GetFrameLevel() + 7)
    targetTextLayer:EnableMouse(false)
    f._textLayer = targetTextLayer

    local hpText = targetTextLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(hpText, 11, 0.98, 0.99, 1.00, 1)
    hpText:SetShadowOffset(1, -1)
    hpText:SetPoint("LEFT", hpBar, "LEFT", 8, 0)
    hpText:SetJustifyH("LEFT")
    hpText:SetWordWrap(false)
    f._hpText = hpText

    local nameText = targetTextLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(nameText, 11, 0.98, 0.99, 1.00, 1)
    nameText:SetShadowOffset(1, -1)
    nameText:SetPoint("RIGHT", hpBar, "RIGHT", -10, 0)
    nameText:SetWidth(148)
    nameText:SetJustifyH("RIGHT")
    nameText:SetWordWrap(false)
    f._nameText = nameText

    -- 右侧圆形目标头像（右边缘正好落在 256 - 4 + 34 = 286px，零外溢、零空隙）
    local port = CreateFrame("Frame", nil, f)
    port:SetSize(34, 34)
    port:SetPoint("LEFT", hpBar, "RIGHT", -4, -2)
    port:SetFrameLevel(hpBar:GetFrameLevel() + 8)
    local pBg = port:CreateTexture(nil, "BACKGROUND")
    pBg:SetAllPoints()
    pBg:SetTexture(ST.TEX.CIRCLE_MASK)
    pBg:SetVertexColor(0.04, 0.045, 0.06, 0.96)
    local pMask = port:CreateMaskTexture()
    if pMask.SetBlockingLoadsRequested then pcall(pMask.SetBlockingLoadsRequested, pMask, true) end
    pMask:SetPoint("TOPLEFT", port, "TOPLEFT", 2, -2)
    pMask:SetPoint("BOTTOMRIGHT", port, "BOTTOMRIGHT", -2, 2)
    pMask:SetTexture(ST.TEX.CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    local pTex = port:CreateTexture(nil, "ARTWORK")
    pTex:SetPoint("TOPLEFT", port, "TOPLEFT", 2, -2)
    pTex:SetPoint("BOTTOMRIGHT", port, "BOTTOMRIGHT", -2, 2)
    ST.AttachCustomMask(port, pTex, pMask, { isIcon = true, keepIfLoaded = true })
    local pRing = port:CreateTexture(nil, "OVERLAY", nil, 4)
    pRing:SetAllPoints()
    pRing:SetTexture(ST.TEX.CIRCLE_RING)
    pRing:SetVertexColor(0.10, 0.12, 0.16, 0.96)
    port._tex = pTex
    f._portrait = port

    -- 目标的目标微条（作为附属浮标挂在圆形头像右侧外，不撑偏目标条主居中盒）
    local totBar = CreateWingBar(f, 84, 10, false)
    totBar:SetPoint("LEFT", port, "RIGHT", 8, -4)
    -- 名字必须挂在小血条上：挂在目标条本体上时，小血条隐藏后名字仍残留上一次的内容（总显示「风蛇」）
    local totName = totBar:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(totName, 10, 0.90, 0.92, 0.96, 1)
    totName:SetPoint("BOTTOMLEFT", totBar, "TOPLEFT", 1, 2)
    totName:SetWidth(90)
    totName:SetJustifyH("LEFT")
    totName:SetWordWrap(false)
    totBar._nameText = totName
    totBar:Hide()
    f._totBar = totBar

    -- 目标增益/减益容器（挂在蓝条正下方，宽度与血蓝条 256px 对齐，绝不与右侧头像或目标的目标重叠）
    local auraHost = CreateFrame("Frame", nil, f)
    auraHost:SetPoint("TOPLEFT", ppBar, "BOTTOMLEFT", 0, -6)
    auraHost:SetSize(256, 52)
    auraHost:SetFrameLevel(hpBar:GetFrameLevel() + 2)
    auraHost:EnableMouse(false)
    f._auraHost = auraHost

    F.Mover.Register({
        key = "TopTargetHUD",
        label = "顶部极简目标条",
        frame = f,
        order = 14,
        defaultPoint = "TOP",
        defaultRelPoint = "TOP",
        defaultX = 0,
        defaultY = -88,
        allowShiftDrag = false,
        isHidden = function() return not (mod._active and mod:GetDB().enableTopTarget ~= false) end,
    })
    f:EnableMouse(false)

    f:Hide()
    CH.topTargetFrame = f
end

----------------------------------------------------------------------
--  3b) 目标增益与减益图标系统（支持怪物、友方/敌对玩家、队友）
--      • 优先接入 EllesmereUI AuraKit 引擎光环容器（无限服副本/战斗保密值完全可读，
--        自动呈现冷却扇形、倒计时文字、层数、驱散类型彩色描边与悬停提示，且点击穿透）；
--      • 无 AuraKit 环境自动退回安全扫描池，保持一致圆角风格与完整提示。
----------------------------------------------------------------------
local TARGET_AURA_ROW_W = 256
local TARGET_AURA_GAP = 4
local TARGET_AURA_ROW_GAP = 5
local TARGET_AURA_DIV_GAP = 7 -- 减益与增益之间：7px + 1px「|」分隔线 + 7px = 15px 留白
local TARGET_MAX_MY_DEBUFFS = 10
local TARGET_MAX_OTHER_DEBUFFS = 10
local TARGET_MAX_BUFFS = 12

local tgtAuraState = {
    container = nil,
    gen = 0,
    debuffStyleKey = nil,
    buffStyleKey = nil,
    layoutFP = nil,
    capDebuff = nil,
    capBuff = nil,
    engineFailed = false,
    fallbackSlots = {},
    divider = nil,
    engineDebuffBtns = {},
    engineBuffBtns = {},
    dividerPending = false,
    eventFrame = nil,
    scanPending = false,
}

local function EnsureTargetAuraDivider(host)
    if tgtAuraState.divider then return tgtAuraState.divider end
    if not host then return nil end
    local div = host:CreateTexture(nil, "OVERLAY", nil, 6)
    div:SetColorTexture(0.78, 0.85, 0.94, 0.62)
    ST.Hairline(div, true)
    div:Hide()
    tgtAuraState.divider = div
    return div
end

local function HideTargetAuraDivider()
    if tgtAuraState.divider then
        tgtAuraState.divider:Hide()
    end
end

local function IsEngineBtnShownPlain(btn)
    if not (btn and btn.IsShown) then return false end
    local ok, s = pcall(btn.IsShown, btn)
    return ok and (not F.IsSecret(s)) and s == true
end

local function TargetAuraMetrics()
    local db = mod:GetDB()
    local sz = math_floor(math_max(18, math_min(28, F.PlainNumber(db.targetAuraSize, 22) or 22)) + 0.5)
    local rad = math_min(ST.GetCornerRadius(5), 5)
    if rad < 0 then rad = 0 end
    local wantBuffs = db.showTargetBuffs ~= false
    local wantDebuffs = db.showTargetDebuffs ~= false
    return sz, rad, wantBuffs, wantDebuffs
end

local function RefreshEngineTargetDivider()
    tgtAuraState.dividerPending = false
    local host = CH.topTargetFrame and CH.topTargetFrame._auraHost
    local c = tgtAuraState.container
    if not (host and c and mod._active and mod:GetDB().enableTopTarget ~= false and UnitExistsSafe("target")) then
        HideTargetAuraDivider()
        return
    end
    local sz = TargetAuraMetrics()
    local div = EnsureTargetAuraDivider(host)
    if not div then return end
    local hostL = host.GetLeft and F.PlainNumber(host:GetLeft(), nil) or nil
    local hostT = host.GetTop and F.PlainNumber(host:GetTop(), nil) or nil
    if not (hostL and hostT) then
        div:Hide()
        return
    end

    -- 找出最末行最右侧的可见减益，以及同行首个可见增益；12.x 保密值一律静默跳过不报错
    local lastDTop, lastDBot, lastDRight = nil, nil, nil
    for _, btn in ipairs(tgtAuraState.engineDebuffBtns) do
        if IsEngineBtnShownPlain(btn) then
            local r = btn.GetRight and F.PlainNumber(btn:GetRight(), nil) or nil
            local t = btn.GetTop and F.PlainNumber(btn:GetTop(), nil) or nil
            local b = btn.GetBottom and F.PlainNumber(btn:GetBottom(), nil) or nil
            if r and t and b then
                if (not lastDTop) or (t < lastDTop - 4) or (math_abs(t - lastDTop) <= 4 and r > lastDRight) then
                    lastDTop, lastDBot, lastDRight = t, b, r
                end
            end
        end
    end
    if not lastDRight then
        div:Hide()
        return
    end

    local firstBLeft = nil
    for _, btn in ipairs(tgtAuraState.engineBuffBtns) do
        if IsEngineBtnShownPlain(btn) then
            local l = btn.GetLeft and F.PlainNumber(btn:GetLeft(), nil) or nil
            local t = btn.GetTop and F.PlainNumber(btn:GetTop(), nil) or nil
            if l and t and math_abs(t - lastDTop) <= 4 and l >= lastDRight + 6 then
                if (not firstBLeft) or l < firstBLeft then
                    firstBLeft = l
                end
            end
        end
    end
    if firstBLeft then
        local midX = (lastDRight + firstBLeft) * 0.5 - hostL
        local midY = ((lastDTop + lastDBot) * 0.5) - hostT
        div:SetHeight(math_max(10, sz - 6))
        ST.Hairline(div, true)
        div:ClearAllPoints()
        div:SetPoint("CENTER", host, "TOPLEFT", midX, midY)
        div:Show()
    else
        div:Hide()
    end
end

local function QueueEngineTargetDivider()
    if tgtAuraState.dividerPending or not tgtAuraState.container then return end
    tgtAuraState.dividerPending = true
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0.04, RefreshEngineTargetDivider)
    else
        RefreshEngineTargetDivider()
    end
end

local function GetTargetAK()
    local EUI = _G.EllesmereUI
    local AK = EUI and EUI.AuraKit or nil
    if AK and type(AK.CreateContainerShell) == "function"
        and type(AK.AddGroupToContainer) == "function"
        and type(AK.FinishContainer) == "function"
        and type(AK.styles) == "table" then
        return AK
    end
    return nil
end

local function ApplyTargetAuraText(button, d)
    if d.duration then
        if not d._kkTgtDurStyled then
            d._kkTgtDurStyled = true
            ST.ApplyText(d.duration, 9, 0.96, 0.98, 1.00, 1)
            d.duration:SetShadowOffset(1, -1)
            d.duration:SetJustifyH("CENTER")
        end
        if d._kkTgtDurAnchor ~= "BOTTOM" then
            d.duration:ClearAllPoints()
            d.duration:SetPoint("BOTTOM", button, "BOTTOM", 0, 2)
            d._kkTgtDurAnchor = "BOTTOM"
        end
    end
    if d.stack then
        if not d._kkTgtStkStyled then
            d._kkTgtStkStyled = true
            ST.ApplyText(d.stack, 9, 1.00, 0.96, 0.82, 1)
            d.stack:SetShadowOffset(1, -1)
            d.stack:SetJustifyH("RIGHT")
        end
        if d._kkTgtStkAnchor ~= "TOPRIGHT" then
            d.stack:ClearAllPoints()
            d.stack:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
            d._kkTgtStkAnchor = "TOPRIGHT"
        end
    end
end

local function BuildTargetAuraStyleTable(sz, rad, isDebuff)
    local br, bg, bb, ba
    if isDebuff then
        br, bg, bb, ba = 0.88, 0.26, 0.30, 0.94
    else
        br, bg, bb, ba = 0.14, 0.16, 0.22, 0.90
    end
    return {
        width = sz,
        height = sz,
        texCoord = { 0.08, 0.92, 0.08, 0.92 },
        border = { br, bg, bb, ba, size = 1, cornerRadius = (rad > 0) and rad or nil },
        dispelBorder = true,
        dispelHelpful = (not isDebuff) or nil,
        dispelBorderPx = 1,
        cooldownReverse = true,
        cooldownDrawEdge = false,
        noDefaultFonts = true,
        hideDurationText = false,
        noTooltips = false,
        applyExtra = ApplyTargetAuraText,
    }
end

local function HideFallbackTargetSlots()
    for _, slot in ipairs(tgtAuraState.fallbackSlots) do
        slot:Hide()
    end
    HideTargetAuraDivider()
end

local function ReleaseTargetAuraEngine()
    local c = tgtAuraState.container
    tgtAuraState.container = nil
    tgtAuraState.layoutFP = nil
    tgtAuraState.capDebuff = nil
    tgtAuraState.capBuff = nil
    tgtAuraState.engineDebuffBtns = {}
    tgtAuraState.engineBuffBtns = {}
    tgtAuraState.dividerPending = false
    HideTargetAuraDivider()
    local AK = GetTargetAK()
    if AK then
        if tgtAuraState.debuffStyleKey then AK.styles[tgtAuraState.debuffStyleKey] = nil end
        if tgtAuraState.buffStyleKey then AK.styles[tgtAuraState.buffStyleKey] = nil end
    end
    tgtAuraState.debuffStyleKey = nil
    tgtAuraState.buffStyleKey = nil
    if c then
        local function DoRelease()
            if AK and AK.ReleaseContainer then
                pcall(AK.ReleaseContainer, c)
            else
                pcall(c.Hide, c)
            end
        end
        if InCombatLockdown and InCombatLockdown() and F.RunOutOfCombat then
            F.RunOutOfCombat("kkowoUI_CoreHUD_ReleaseTargetAuras", DoRelease)
        else
            DoRelease()
        end
    end
end

local function EnsureTargetAuraEngine()
    local AK = GetTargetAK()
    local f = CH.topTargetFrame
    local host = f and f._auraHost
    if not (AK and host) or tgtAuraState.engineFailed then return false end
    local sz, rad, wantBuffs, wantDebuffs = TargetAuraMetrics()
    local fp = sz .. "|" .. rad

    if tgtAuraState.container then
        local c = tgtAuraState.container
        local needLayout = (tgtAuraState.layoutFP ~= fp)
        local needCapD = (tgtAuraState.capDebuff ~= wantDebuffs)
        local needCapB = (tgtAuraState.capBuff ~= wantBuffs)
        if (needLayout or needCapD or needCapB) and InCombatLockdown and InCombatLockdown() then
            F.RunOutOfCombat("kkowoUI_CoreHUD_TargetAuras", function()
                if mod._active and CH.SyncTargetAuras then CH.SyncTargetAuras() end
            end)
            return true
        end
        if needLayout then
            tgtAuraState.layoutFP = fp
            AK.styles[tgtAuraState.debuffStyleKey] = BuildTargetAuraStyleTable(sz, rad, true)
            AK.styles[tgtAuraState.buffStyleKey] = BuildTargetAuraStyleTable(sz, rad, false)
            local divSpan = TARGET_AURA_DIV_GAP * 2 + 1
            -- 已核实 EUI（EUI_PlayerAuraBars_Groups.lua:413 + EUI_RaidFrames_AuraContainers.lua:2255）：
            -- 12.x AuraContainer 的 flow layout 在每组末尾元素后自带一次 elementSpacing，而 groupSpacing 施加在
            -- 目标组之前并与前组末尾 elementSpacing 叠加。因此减益两组之间设 groupSpacing=0（保持 4px 连续流），
            -- 增益组设 groupSpacing = divSpan - TARGET_AURA_GAP（4 + 11 = 15px，精确容纳 7px + 1px「|」+ 7px）。
            local buffGroupExtra = math_max(0, divSpan - TARGET_AURA_GAP)
            local gLayout = {
                elementWidth = sz, elementHeight = sz,
                elementSpacing = TARGET_AURA_GAP, lineSpacing = TARGET_AURA_ROW_GAP,
                groupSpacing = 0, groupLineSpacing = TARGET_AURA_ROW_GAP + 4,
            }
            if c.SetAuraGroupLayout then
                gLayout.layoutIndex = 1; gLayout.forceNewLine = nil; gLayout.groupSpacing = 0
                pcall(c.SetAuraGroupLayout, c, "kk_tgt_my_debuffs", gLayout)
                gLayout.layoutIndex = 2; gLayout.forceNewLine = nil; gLayout.groupSpacing = 0
                pcall(c.SetAuraGroupLayout, c, "kk_tgt_other_debuffs", gLayout)
                gLayout.layoutIndex = 3; gLayout.forceNewLine = nil; gLayout.groupSpacing = buffGroupExtra
                pcall(c.SetAuraGroupLayout, c, "kk_tgt_buffs", gLayout)
            end
            if AK.RestyleSoon then
                pcall(AK.RestyleSoon, tgtAuraState.debuffStyleKey)
                pcall(AK.RestyleSoon, tgtAuraState.buffStyleKey)
            elseif AK.Restyle then
                pcall(AK.Restyle, tgtAuraState.debuffStyleKey)
                pcall(AK.Restyle, tgtAuraState.buffStyleKey)
            end
        end
        if tgtAuraState.capDebuff ~= wantDebuffs then
            tgtAuraState.capDebuff = wantDebuffs
            if AK.SetGroupCap then
                pcall(AK.SetGroupCap, c, "kk_tgt_my_debuffs", wantDebuffs and TARGET_MAX_MY_DEBUFFS or 0)
                pcall(AK.SetGroupCap, c, "kk_tgt_other_debuffs", wantDebuffs and TARGET_MAX_OTHER_DEBUFFS or 0)
            end
        end
        if tgtAuraState.capBuff ~= wantBuffs then
            tgtAuraState.capBuff = wantBuffs
            if AK.SetGroupCap then
                pcall(AK.SetGroupCap, c, "kk_tgt_buffs", wantBuffs and TARGET_MAX_BUFFS or 0)
            end
        end
        return true
    end

    if InCombatLockdown and InCombatLockdown() then
        F.RunOutOfCombat("kkowoUI_CoreHUD_TargetAuras", function()
            if mod._active and CH.SyncTargetAuras then CH.SyncTargetAuras() end
        end)
        return false
    end

    tgtAuraState.gen = tgtAuraState.gen + 1
    local dKey = "kkowoUI_tgt_debuffs_" .. tgtAuraState.gen
    local bKey = "kkowoUI_tgt_buffs_" .. tgtAuraState.gen
    AK.styles[dKey] = BuildTargetAuraStyleTable(sz, rad, true)
    AK.styles[bKey] = BuildTargetAuraStyleTable(sz, rad, false)

    local ok = pcall(function()
        local c = AK.CreateContainerShell(host, {
            point = { "TOPLEFT", host, "TOPLEFT", 0, 0 },
        })
        tgtAuraState.container = c
        tgtAuraState.debuffStyleKey = dKey
        tgtAuraState.buffStyleKey = bKey
        tgtAuraState.layoutFP = fp
        tgtAuraState.capDebuff = wantDebuffs
        tgtAuraState.capBuff = wantBuffs

        local FlowDir = _G.AnchorUtil and _G.AnchorUtil.FlowDirection
        if AK.SetContainerAxis then pcall(AK.SetContainerAxis, c, false) end
        AK.ApplyContainerLayout(c, {
            anchorPoint = "TOPLEFT",
            padding = { 0, 0, 0, 0 },
            rowWidth = TARGET_AURA_ROW_W + 0.4,
            growthH = FlowDir and FlowDir.Right or nil,
            growthV = FlowDir and FlowDir.Down or nil,
        })
        local SM = _G.AuraContainerSortMethod
        local sortDefault = SM and SM.Default or nil
        local divSpan = TARGET_AURA_DIV_GAP * 2 + 1
        local buffGroupExtra = math_max(0, divSpan - TARGET_AURA_GAP)
        tgtAuraState.engineDebuffBtns = {}
        tgtAuraState.engineBuffBtns = {}
        local function TrackDebuffBtn(btn)
            tgtAuraState.engineDebuffBtns[#tgtAuraState.engineDebuffBtns + 1] = btn
        end
        local function TrackBuffBtn(btn)
            tgtAuraState.engineBuffBtns[#tgtAuraState.engineBuffBtns + 1] = btn
        end
        local myDebuffLayout = {
            elementWidth = sz, elementHeight = sz,
            elementSpacing = TARGET_AURA_GAP, lineSpacing = TARGET_AURA_ROW_GAP,
            groupSpacing = 0, groupLineSpacing = TARGET_AURA_ROW_GAP + 4,
            layoutIndex = 1,
        }
        local otherDebuffLayout = {
            elementWidth = sz, elementHeight = sz,
            elementSpacing = TARGET_AURA_GAP, lineSpacing = TARGET_AURA_ROW_GAP,
            groupSpacing = 0, groupLineSpacing = TARGET_AURA_ROW_GAP + 4,
            layoutIndex = 2,
        }
        local buffLayout = {
            elementWidth = sz, elementHeight = sz,
            elementSpacing = TARGET_AURA_GAP, lineSpacing = TARGET_AURA_ROW_GAP,
            groupSpacing = buffGroupExtra, groupLineSpacing = TARGET_AURA_ROW_GAP + 4,
            layoutIndex = 3,
        }
        -- 同行流式排布：减益（自身优先 + 其他）与增益之间留出 15px 间距并居中绘制「|」分隔线
        AK.AddGroupToContainer(c, {
            key = "kk_tgt_my_debuffs",
            filter = { "HARMFUL", "PLAYER" },
            maxFrameCount = wantDebuffs and TARGET_MAX_MY_DEBUFFS or 0,
            sortMethod = sortDefault,
            style = dKey,
            extraInit = TrackDebuffBtn,
            layout = myDebuffLayout,
        })
        AK.AddGroupToContainer(c, {
            key = "kk_tgt_other_debuffs",
            filter = { "HARMFUL", "!PLAYER" },
            maxFrameCount = wantDebuffs and TARGET_MAX_OTHER_DEBUFFS or 0,
            sortMethod = sortDefault,
            style = dKey,
            extraInit = TrackDebuffBtn,
            layout = otherDebuffLayout,
        })
        AK.AddGroupToContainer(c, {
            key = "kk_tgt_buffs",
            filter = { "HELPFUL" },
            maxFrameCount = wantBuffs and TARGET_MAX_BUFFS or 0,
            sortMethod = sortDefault,
            style = bKey,
            extraInit = TrackBuffBtn,
            layout = buffLayout,
        })
        if c.SetAuraGroupLayout then
            pcall(c.SetAuraGroupLayout, c, "kk_tgt_my_debuffs", myDebuffLayout)
            pcall(c.SetAuraGroupLayout, c, "kk_tgt_other_debuffs", otherDebuffLayout)
            pcall(c.SetAuraGroupLayout, c, "kk_tgt_buffs", buffLayout)
        end
        if c.HookScript then
            pcall(c.HookScript, c, "OnSizeChanged", QueueEngineTargetDivider)
        end
        if c.SetEnabled then pcall(c.SetEnabled, c, true) end
        AK.FinishContainer(c, "target")
    end)

    if not ok then
        tgtAuraState.engineFailed = true
        ReleaseTargetAuraEngine()
        return false
    end
    HideFallbackTargetSlots()
    if tgtAuraState.eventFrame then tgtAuraState.eventFrame:UnregisterAllEvents() end
    return true
end

local function AcquireTargetFallbackSlot(index)
    local slot = tgtAuraState.fallbackSlots[index]
    if slot then return slot end
    local host = CH.topTargetFrame and CH.topTargetFrame._auraHost
    if not host then return nil end
    slot = CreateFrame("Button", nil, host)
    slot:SetSize(22, 22)
    slot:EnableMouse(true)
    if slot.SetMouseClickEnabled then pcall(slot.SetMouseClickEnabled, slot, false) end
    if slot.SetMouseMotionEnabled then pcall(slot.SetMouseMotionEnabled, slot, true) end

    local bg = slot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.045, 0.06, 0.90)
    slot._bg = bg

    local icon = slot:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    slot._icon = icon

    local cd = CreateFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
    cd:SetAllPoints()
    if cd.SetDrawEdge then pcall(cd.SetDrawEdge, cd, false) end
    if cd.SetReverse then pcall(cd.SetReverse, cd, true) end
    if cd.SetDrawBling then pcall(cd.SetDrawBling, cd, false) end
    if cd.SetHideCountdownNumbers then pcall(cd.SetHideCountdownNumbers, cd, false) end
    if cd.EnableMouse then pcall(cd.EnableMouse, cd, false) end
    slot._cd = cd

    local textHost = CreateFrame("Frame", nil, slot)
    textHost:SetAllPoints()
    textHost:SetFrameLevel(slot:GetFrameLevel() + 5)
    textHost:EnableMouse(false)
    local stacks = textHost:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(stacks, 9, 1.00, 0.96, 0.82, 1)
    stacks:SetPoint("TOPRIGHT", slot, "TOPRIGHT", -1, -1)
    stacks:SetShadowOffset(1, -1)
    stacks:SetJustifyH("RIGHT")
    slot._stacks = stacks

    slot:SetScript("OnEnter", function(self)
        if not (_G.GameTooltip and UnitExistsSafe("target")) then return end
        _G.GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT", 0, -4)
        local okTip = false
        if type(self._auraInstanceID) ~= "nil" then
            if self._isDebuff and _G.GameTooltip.SetUnitDebuffByAuraInstanceID then
                okTip = pcall(_G.GameTooltip.SetUnitDebuffByAuraInstanceID, _G.GameTooltip, "target", self._auraInstanceID) == true
            elseif (not self._isDebuff) and _G.GameTooltip.SetUnitBuffByAuraInstanceID then
                okTip = pcall(_G.GameTooltip.SetUnitBuffByAuraInstanceID, _G.GameTooltip, "target", self._auraInstanceID) == true
            end
        end
        if not okTip and self._auraIndex then
            if self._isDebuff and _G.GameTooltip.SetUnitDebuff then
                pcall(_G.GameTooltip.SetUnitDebuff, _G.GameTooltip, "target", self._auraIndex)
            elseif (not self._isDebuff) and _G.GameTooltip.SetUnitBuff then
                pcall(_G.GameTooltip.SetUnitBuff, _G.GameTooltip, "target", self._auraIndex)
            elseif _G.GameTooltip.SetUnitAura then
                pcall(_G.GameTooltip.SetUnitAura, _G.GameTooltip, "target", self._auraIndex, self._isDebuff and "HARMFUL" or "HELPFUL")
            end
        end
        _G.GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    slot:Hide()
    tgtAuraState.fallbackSlots[index] = slot
    return slot
end

local function CollectTargetAurasFallback(filter, maxCount)
    local mine, others = {}, {}
    local getByIdx = _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDataByIndex
    if getByIdx then
        for i = 1, 40 do
            local ok, aura = pcall(getByIdx, "target", i, filter)
            if not ok or type(aura) == "nil" then break end
            if not F.IsSecret(aura) and type(aura) == "table" and type(aura.icon) ~= "nil" then
                local fromMe = (not F.IsSecret(aura.isFromPlayerOrPlayerPet)) and aura.isFromPlayerOrPlayerPet == true
                local item = {
                    index = i,
                    auraInstanceID = aura.auraInstanceID,
                    icon = aura.icon,
                    applications = aura.applications,
                    duration = aura.duration,
                    expirationTime = aura.expirationTime,
                    dispelName = F.PlainString(aura.dispelName, nil),
                }
                if filter == "HARMFUL" and fromMe then
                    mine[#mine + 1] = item
                else
                    others[#others + 1] = item
                end
            end
        end
    else
        local fn = (filter == "HARMFUL") and _G.UnitDebuff or _G.UnitBuff
        if fn then
            for i = 1, 40 do
                local ok, nm, ic, count, dispelType, dur, expTime, source = pcall(fn, "target", i)
                if not ok or (not F.IsSecret(nm) and not nm) then break end
                if type(ic) ~= "nil" then
                    local src = F.PlainString(source, nil)
                    local item = {
                        index = i,
                        icon = ic,
                        applications = count,
                        duration = dur,
                        expirationTime = expTime,
                        dispelName = F.PlainString(dispelType, nil),
                    }
                    if filter == "HARMFUL" and (src == "player" or src == "pet") then
                        mine[#mine + 1] = item
                    else
                        others[#others + 1] = item
                    end
                end
            end
        end
    end
    local out = {}
    for _, it in ipairs(mine) do
        if #out >= maxCount then break end
        out[#out + 1] = it
    end
    for _, it in ipairs(others) do
        if #out >= maxCount then break end
        out[#out + 1] = it
    end
    return out
end

local function PaintTargetFallbackSlot(slot, data, isDebuff, sz, rad)
    slot:SetSize(sz, sz)
    slot._auraIndex = data.index
    slot._auraInstanceID = data.auraInstanceID
    slot._isDebuff = isDebuff
    pcall(slot._icon.SetTexture, slot._icon, data.icon)

    local cd = slot._cd
    local appliedCD = false
    if type(data.auraInstanceID) ~= "nil" and _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDuration and cd.SetCooldownFromDurationObject then
        local okD, durObj = pcall(_G.C_UnitAuras.GetAuraDuration, "target", data.auraInstanceID)
        if okD and type(durObj) ~= "nil" then
            appliedCD = pcall(cd.SetCooldownFromDurationObject, cd, durObj) == true
        end
    end
    if not appliedCD then
        local d = F.PlainNumber(data.duration, nil)
        local e = F.PlainNumber(data.expirationTime, nil)
        if d and e and d > 0 then
            pcall(cd.SetCooldown, cd, e - d, d)
            appliedCD = true
        end
    end
    cd:SetShown(appliedCD)
    if appliedCD and cd.GetRegions then
        for _, reg in ipairs({ cd:GetRegions() }) do
            if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                ST.ApplyText(reg, 9, 0.96, 0.98, 1.00, 1)
                reg:ClearAllPoints()
                reg:SetPoint("BOTTOM", slot, "BOTTOM", 0, 2)
                reg:SetJustifyH("CENTER")
                reg:SetShadowOffset(1, -1)
            end
        end
    end

    local stacks = F.PlainNumber(data.applications, 0) or 0
    if stacks > 1 then
        slot._stacks:SetText(tostring(stacks))
        slot._stacks:Show()
    else
        slot._stacks:Hide()
    end

    if slot._lastRad ~= rad then
        slot._lastRad = rad
        ST.ClearRoundedMask(slot)
        if rad > 0 then
            ST.SetHostIconMode(slot, true)
            ST.MaskTexture(slot, slot._bg, rad)
            ST.MaskIcon(slot, slot._icon, rad)
        end
    end
    local br, bg, bb, ba
    if isDebuff then
        local dc = (data.dispelName and DEBUFF_TYPE_COLORS and DEBUFF_TYPE_COLORS[data.dispelName]) or { 0.88, 0.26, 0.30 }
        br, bg, bb, ba = dc[1], dc[2], dc[3], 0.94
    else
        local dc = (data.dispelName and DEBUFF_TYPE_COLORS and DEBUFF_TYPE_COLORS[data.dispelName]) or nil
        if dc then
            br, bg, bb, ba = dc[1], dc[2], dc[3], 0.94
        else
            br, bg, bb, ba = 0.14, 0.16, 0.22, 0.90
        end
    end
    ST.ApplyRoundedBorder(slot, rad, br, bg, bb, ba, 4)
    slot:Show()
end

local function UpdateTargetAurasFallback()
    local f = CH.topTargetFrame
    local host = f and f._auraHost
    if not (host and mod._active and mod:GetDB().enableTopTarget ~= false and UnitExistsSafe("target")) then
        HideFallbackTargetSlots()
        return
    end
    local sz, rad, wantBuffs, wantDebuffs = TargetAuraMetrics()
    local debuffs = wantDebuffs and CollectTargetAurasFallback("HARMFUL", 16) or {}
    local buffs = wantBuffs and CollectTargetAurasFallback("HELPFUL", TARGET_MAX_BUFFS) or {}
    local stepX = sz + TARGET_AURA_GAP
    local stepY = sz + TARGET_AURA_ROW_GAP
    local divSpan = TARGET_AURA_DIV_GAP * 2 + 1
    local used = 0
    local xCursor = 0
    local yCursor = 0
    local div = EnsureTargetAuraDivider(host)

    if #debuffs > 0 then
        for _, data in ipairs(debuffs) do
            if xCursor > 0 and (xCursor + sz) > TARGET_AURA_ROW_W then
                xCursor = 0
                yCursor = yCursor + stepY
            end
            used = used + 1
            local slot = AcquireTargetFallbackSlot(used)
            if slot then
                slot:ClearAllPoints()
                slot:SetPoint("TOPLEFT", host, "TOPLEFT", xCursor, -yCursor)
                PaintTargetFallbackSlot(slot, data, true, sz, rad)
            end
            xCursor = xCursor + stepX
        end
    end

    if #debuffs > 0 and #buffs > 0 then
        -- 减益末尾与增益之间：同排有空间时画竖向「|」分隔线并留 15px 距离；若已占满行则换新排并增加排距
        local lastRight = xCursor - TARGET_AURA_GAP
        if (lastRight + divSpan + sz) <= TARGET_AURA_ROW_W then
            if div then
                div:SetHeight(math_max(10, sz - 6))
                ST.Hairline(div, true)
                div:ClearAllPoints()
                div:SetPoint("CENTER", host, "TOPLEFT", lastRight + TARGET_AURA_DIV_GAP + 0.5, -(yCursor + sz * 0.5))
                div:Show()
            end
            xCursor = lastRight + divSpan
        else
            if div then div:Hide() end
            xCursor = 0
            yCursor = yCursor + stepY + 4
        end
    elseif div then
        div:Hide()
    end

    if #buffs > 0 then
        for _, data in ipairs(buffs) do
            if xCursor > 0 and (xCursor + sz) > TARGET_AURA_ROW_W then
                xCursor = 0
                yCursor = yCursor + stepY
            end
            used = used + 1
            local slot = AcquireTargetFallbackSlot(used)
            if slot then
                slot:ClearAllPoints()
                slot:SetPoint("TOPLEFT", host, "TOPLEFT", xCursor, -yCursor)
                PaintTargetFallbackSlot(slot, data, false, sz, rad)
            end
            xCursor = xCursor + stepX
        end
    end

    for i = used + 1, #tgtAuraState.fallbackSlots do
        tgtAuraState.fallbackSlots[i]:Hide()
    end
end

local function EnsureTargetAuraEventFrame()
    if tgtAuraState.eventFrame then return tgtAuraState.eventFrame end
    local ef = CreateFrame("Frame")
    ef:SetScript("OnEvent", function()
        if not mod._active then return end
        if tgtAuraState.container then
            QueueEngineTargetDivider()
            return
        end
        if tgtAuraState.scanPending then return end
        tgtAuraState.scanPending = true
        _G.C_Timer.After(0.06, function()
            tgtAuraState.scanPending = false
            if mod._active and not tgtAuraState.container then
                UpdateTargetAurasFallback()
            end
        end)
    end)
    tgtAuraState.eventFrame = ef
    return ef
end

local function SyncTargetAuras()
    local f = CH.topTargetFrame
    local host = f and f._auraHost
    if not host then return end
    local db = mod:GetDB()
    local featureOn = mod._active == true and db.enableTopTarget ~= false
        and (db.showTargetBuffs ~= false or db.showTargetDebuffs ~= false)
    if not featureOn then
        host:Hide()
        HideFallbackTargetSlots()
        if tgtAuraState.eventFrame then tgtAuraState.eventFrame:UnregisterAllEvents() end
        return
    end
    -- 在脱战登录期就预先创建引擎容器（即使当前尚未选中目标），保证首次进战点选怪物时立刻显示光环；
    -- auraHost 挂在 topTargetFrame 下，无目标时随父框体自动隐藏
    host:Show()
    local hasTarget = UnitExistsSafe("target")
    if EnsureTargetAuraEngine() then
        local ef = EnsureTargetAuraEventFrame()
        pcall(ef.RegisterUnitEvent, ef, "UNIT_AURA", "target")
        if hasTarget and tgtAuraState.container and tgtAuraState.container.UpdateAllAuras then
            pcall(tgtAuraState.container.UpdateAllAuras, tgtAuraState.container)
        end
        if hasTarget then
            QueueEngineTargetDivider()
        else
            HideTargetAuraDivider()
        end
        return
    end
    if not hasTarget then
        HideFallbackTargetSlots()
        return
    end
    -- 兜底扫描模式：为 target 单独挂 UNIT_AURA 监听（不占用模块主事件帧上 player 的 UNIT_AURA）
    local ef = EnsureTargetAuraEventFrame()
    pcall(ef.RegisterUnitEvent, ef, "UNIT_AURA", "target")
    UpdateTargetAurasFallback()
end

local function ReleaseTargetAuras()
    tgtAuraState.engineFailed = false
    tgtAuraState.scanPending = false
    if tgtAuraState.eventFrame then tgtAuraState.eventFrame:UnregisterAllEvents() end
    ReleaseTargetAuraEngine()
    HideFallbackTargetSlots()
    if CH.topTargetFrame and CH.topTargetFrame._auraHost then
        CH.topTargetFrame._auraHost:Hide()
    end
end


CH.HidePetFeedMenu = HidePetFeedMenu
CH.BuildPetHUD = BuildPetHUD
CH.BuildTopTargetHUD = BuildTopTargetHUD
CH.SyncTargetAuras = SyncTargetAuras
CH.ReleaseTargetAuras = ReleaseTargetAuras
