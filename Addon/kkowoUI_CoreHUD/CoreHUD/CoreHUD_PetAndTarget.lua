----------------------------------------------------------------------
--  kkowoUI_CoreHUD — CoreHUD/CoreHUD_PetAndTarget.lua
--  独立宠物圆角框体（含猎人快乐度悬停提示与安全喂食菜单）+ 顶部极简目标条
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local CH = F._CoreHUD
if not CH then return end

local ipairs, math_floor, math_max, math_min, pairs, pcall, tostring, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, tostring, type
local string_format = string.format
local table_concat, table_sort = table.concat, table.sort
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown

local ST = F.StyleTokens
local M = F.Motion
local mod = CH.mod
local CreateWingBar = CH.CreateWingBar

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
    if petFeedCloseFrame then
        petFeedCloseFrame:UnregisterAllEvents()
    end
    if not (petFeedMenu and petFeedMenu:IsShown()) then return end
    if InCombatLockdown and InCombatLockdown() then
        F.CombatDefer("kkowoUI_PetFeedHide", function()
            if petFeedMenu then petFeedMenu:Hide() end
        end)
        return
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
        isHidden = function() return not (mod._active and mod:GetDB().showPetFrame ~= false and _G.UnitExists and _G.UnitExists("pet")) end,
    })

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

    F.Mover.Register({
        key = "TopTargetHUD",
        label = "顶部极简目标条",
        frame = f,
        order = 14,
        defaultPoint = "TOP",
        defaultRelPoint = "TOP",
        defaultX = 0,
        defaultY = -88,
        isHidden = function() return not (mod._active and mod:GetDB().enableTopTarget ~= false) end,
    })

    f:Hide()
    CH.topTargetFrame = f
end


CH.HidePetFeedMenu = HidePetFeedMenu
CH.BuildPetHUD = BuildPetHUD
CH.BuildTopTargetHUD = BuildTopTargetHUD
