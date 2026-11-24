----------------------------------------------------------------------
--  ForeverUI — Modules/BagUtility.lua
--  背包低价值清理助手（联动 Auctionator 拍卖价防误删）
--  + 无侵入背包金币文字对齐（无需再改 EllesmereUIBags 源码）
--  + 宏编辑窗口放大
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pcall, select, type = ipairs, pcall, select, type
local table_sort = table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("bagUtility", {
    title = "背包清理与拾取增强",
    desc = "无闪烁极速静默拾取（替代 EUI 延迟拾取，消除闪窗卡顿）、包满低价值清单、EUI 背包金币对齐与宏界面放大。",
    group = "utility",
    order = 10,
    defaults = {
        enabled = true,
        silentFastLoot = true,
        clickLoot = false,         -- 默认使用暴雪原生 C++ 自动拾取（1 次往返零卡顿，按住 Shift+右键开窗）；开启则改为右键全拾 / 左键开窗
        v2NativeAutoLoot = false,
        autoSellJunk = true,
        autoRepair = true,
        lowValueHelper = true,
        useAuctionPrice = true,
        onlyWhenFull = true,
        hideQuestItems = true,
        alignBagMoney = true,
        enlargeMacro = true,
        maxRows = 8,
    },
})

local lvilFrame = nil
local lvilRows = {}
local moneyHooked = false
local macroEnlarged = setmetatable({}, { __mode = "k" })
local isSilentLooting = false
local lootRevealToken = 0
local lootFrameHooked = false
local editModeHooked = false
local lootSweptThisOpen = false
local pendingCloseCheck = false
local lootParked = false
local lootPreArmed = false
local manualLootThisOpen = false
local inSilentAlphaSet = false
local inSilentPointSet = false
local savedLootPoint = nil
local savedLootClamped = true
local ResolveWantAuto = nil

-- 1) 无侵入对齐 EllesmereUIBags 底部金币数字（替代手打补丁）
local MONEY_SUFFIXES = { "GoldButton", "SilverButton", "CopperButton" }

local function AlignMoneyFrame(mf)
    if not (mf and mf.GetName and mf:GetName()) then
        return
    end
    local base = mf:GetName()
    for _, sfx in ipairs(MONEY_SUFFIXES) do
        local b = _G[base .. sfx]
        local t = b and b.GetFontString and b:GetFontString()
        if t then
            t:ClearAllPoints()
            t:SetPoint("RIGHT", b, "RIGHT", -13, -1)
        end
    end
end

local function SetupMoneyAlign()
    if moneyHooked then
        return
    end
    moneyHooked = true
    if _G.MoneyFrame_Update then
        _G.hooksecurefunc("MoneyFrame_Update", function(frame)
            if not (mod._active and mod:GetDB().alignBagMoney) then
                return
            end
            local mf = type(frame) == "string" and _G[frame] or frame
            local name = mf and mf.GetName and mf:GetName()
            if name and (name:find("^EUI_Bag") or name:find("^EUI_OfflineMoneyFrame") or name:find("EllesmereUIBags")) then
                AlignMoneyFrame(mf)
            end
        end)
    end
end

-- 2) 宏编辑界面放大（弱表记录，不往暴雪 MacroFrame 写字段）
local function EnlargeMacroFrame()
    if not (mod._active and mod:GetDB().enlargeMacro) then
        return
    end
    local mf = _G.MacroFrame
    if not mf or macroEnlarged[mf] then
        return
    end
    F.RunOutOfCombat("FUI_EnlargeMacro", function()
        if not mf or macroEnlarged[mf] then return end
        macroEnlarged[mf] = true
        mf:SetSize(480, 560)
        if _G.MacroFrameText then
            _G.MacroFrameText:SetWidth(420)
        end
        if _G.MacroFrameScrollFrame then
            _G.MacroFrameScrollFrame:SetWidth(430)
            _G.MacroFrameScrollFrame:SetHeight(165)
        end
    end)
end

-- 3) 背包低价值物品清单（融合 Auctionator 估价）
local function GetContainerFreeSlots()
    local C = _G.C_Container
    if not (C and C.GetContainerNumFreeSlots) then
        return 99
    end
    local free = 0
    for bag = 0, 4 do
        local n, bagType = C.GetContainerNumFreeSlots(bag)
        if bagType == 0 then
            free = free + (n or 0)
        end
    end
    return free
end

local function ScanLowValueItems()
    local C = _G.C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) then
        return {}
    end
    local db = mod:GetDB()
    local items = {}
    local getInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    local getInstant = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    local itemClassEnum = _G.Enum and _G.Enum.ItemClass
    local CLASS_PROJECTILE = (itemClassEnum and itemClassEnum.Projectile) or 6
    local CLASS_QUEST = (itemClassEnum and itemClassEnum.Questitem) or 12

    for bag = 0, 4 do
        -- 跳过箭袋/弹药袋/灵魂袋，且下面按物品类型再次过滤普通背包中的溢出弹药
        local _, bagType = C.GetContainerNumFreeSlots and C.GetContainerNumFreeSlots(bag)
        if bagType == nil or bagType == 0 then
            local slots = C.GetContainerNumSlots(bag) or 0
            for slot = 1, slots do
                local info = C.GetContainerItemInfo(bag, slot)
                if info and info.hyperlink and info.itemID and not info.isLocked then
                    -- 炉石(6948) / 灵魂碎片(6265) 永不列入清理清单
                    if info.itemID ~= 6948 and info.itemID ~= 6265 then
                        local name, _, quality, _, _, itemType, _, _, equipLoc, _, sellPrice, classID = getInfo(info.hyperlink)
                        if (not classID or not equipLoc) and getInstant then
                            local _, _, _, instEquipLoc, _, instClassID = getInstant(info.itemID)
                            classID = classID or instClassID
                            equipLoc = equipLoc or instEquipLoc
                        end
                        local isAmmo = (classID == CLASS_PROJECTILE)
                            or (equipLoc == "INVTYPE_AMMO")
                            or (itemType == "弹药" or itemType == "Projectile")
                        local isQuest = (classID == CLASS_QUEST)
                            or (itemType == "任务" or itemType == "Quest")
                        -- 未缓存物品 GetItemInfo 返回 nil：改用容器自带品质，绝不把未缓存的蓝/紫装误判为白装列入摧毁清单
                        quality = F.PlainNumber(quality, nil) or F.PlainNumber(info.quality, nil)
                        if not isAmmo and not (db.hideQuestItems and isQuest) and quality and quality <= 2 then
                            local count = F.PlainNumber(info.stackCount, 1)
                            local vendorTotal = F.PlainNumber(sellPrice, 0) * count
                            local ahUnit = db.useAuctionPrice and F.GetAuctionPrice(info.hyperlink) or nil
                            local ahTotal = ahUnit and (ahUnit * count) or 0
                            local effectiveVal = math.max(vendorTotal, ahTotal)
                            if effectiveVal > 0 then
                                items[#items + 1] = {
                                    bag = bag,
                                    slot = slot,
                                    itemID = info.itemID,
                                    name = name or info.hyperlink,
                                    link = info.hyperlink,
                                    icon = info.iconFileID,
                                    count = count,
                                    quality = quality or 1,
                                    vendorTotal = vendorTotal,
                                    ahTotal = ahTotal,
                                    effectiveVal = effectiveVal,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    table_sort(items, function(a, b) return a.effectiveVal < b.effectiveVal end)
    return items
end

local lvilManualOpen = false
local RefreshLVIL

local function DestroyLowValueItem(it)
    if not it then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.Print("|cffe05263战斗中无法销毁物品，请脱战后再试。|r")
        return
    end
    if _G.GetCursorInfo and _G.GetCursorInfo() then
        F.Print("|cfff0bf57请先放下鼠标上拿取的物品后再点击销毁。|r")
        return
    end
    local C = _G.C_Container
    if not (C and C.GetContainerItemInfo and C.PickupContainerItem and _G.DeleteCursorItem) then
        return
    end
    -- 销毁前二次核对同格 itemID，防止背包变动导致误删
    local cur = C.GetContainerItemInfo(it.bag, it.slot)
    if not cur or cur.itemID ~= it.itemID or cur.isLocked then
        if RefreshLVIL then RefreshLVIL(lvilManualOpen) end
        return
    end
    pcall(C.PickupContainerItem, it.bag, it.slot)
    local cursorType = _G.GetCursorInfo and _G.GetCursorInfo()
    if cursorType == "item" then
        pcall(_G.DeleteCursorItem)
        if (it.quality or 1) <= 1 then
            local suffix = (it.count and it.count > 1) and (" x" .. it.count) or ""
            F.Print("已销毁：" .. (it.link or it.name or "") .. suffix)
        end
        C_Timer.After(0.18, function()
            if RefreshLVIL and lvilFrame and lvilFrame:IsShown() then
                RefreshLVIL(lvilManualOpen)
            end
        end)
    end
end

local function EnsureLVILFrame()
    if lvilFrame then
        return
    end
    lvilFrame = CreateFrame("Frame", "ForeverUI_LowValueList", _G.UIParent)
    lvilFrame:SetSize(296, 220)
    lvilFrame:SetFrameStrata("MEDIUM")
    -- 面板空白处吃掉点击，避免点穿到 3D 世界误选目标/误转镜头
    lvilFrame:EnableMouse(true)
    F.Theme.StyleGlassSurface(lvilFrame, {
        bgAlpha = 0.93,
        borderAlpha = 0.90,
        restAura = 0.08,
        hoverAura = 0.08,
        borderTintMix = 0.32,
    })

    local title = lvilFrame:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(title, 12, "", 0.95, 0.96, 0.98, 1)
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("低价值物品清理（含拍卖价）")

    local hdrLine = lvilFrame:CreateTexture(nil, "BORDER")
    hdrLine:SetHeight(1)
    hdrLine:SetPoint("TOPLEFT", lvilFrame, "TOPLEFT", 8, -26)
    hdrLine:SetPoint("TOPRIGHT", lvilFrame, "TOPRIGHT", -8, -26)
    hdrLine:SetColorTexture(1, 1, 1, 0.08)

    local close = CreateFrame("Button", nil, lvilFrame)
    close:SetSize(18, 18)
    close:SetPoint("TOPRIGHT", -6, -5)
    F.Theme.StyleGlassSurface(close, {
        accent = { 0.93, 0.36, 0.43 },
        bgAlpha = 0.72,
        borderAlpha = 0.58,
        restAura = 0.04,
        hoverAura = 0.32,
        borderTintMix = 0.10,
    })
    local cxIcon = close:CreateTexture(nil, "OVERLAY", nil, 4)
    cxIcon:SetSize(10, 10)
    cxIcon:SetPoint("CENTER", close, "CENTER", 0, 0)
    cxIcon:SetTexture(F.Theme.ICONS .. "Close.tga")
    cxIcon:SetTexCoord(0, 1, 0, 1)
    cxIcon:SetVertexColor(0.76, 0.80, 0.86, 0.90)
    close:SetScript("OnEnter", function(self)
        F.Theme.SetGlassState(self, true, false)
        cxIcon:SetVertexColor(1.0, 0.86, 0.88, 1.0)
    end)
    close:SetScript("OnLeave", function(self)
        F.Theme.SetGlassState(self, false, false)
        cxIcon:ClearAllPoints()
        cxIcon:SetPoint("CENTER", self, "CENTER", 0, 0)
        cxIcon:SetVertexColor(0.76, 0.80, 0.86, 0.90)
    end)
    close:SetScript("OnMouseDown", function(self)
        cxIcon:ClearAllPoints()
        cxIcon:SetPoint("CENTER", self, "CENTER", 0, -1)
    end)
    close:SetScript("OnMouseUp", function(self)
        cxIcon:ClearAllPoints()
        cxIcon:SetPoint("CENTER", self, "CENTER", 0, 0)
    end)
    close:SetScript("OnClick", function()
        lvilManualOpen = false
        lvilFrame:Hide()
    end)

    F.Mover.Register({
        key = "LowValueList",
        label = "低价值物品清单",
        frame = lvilFrame,
        order = 60,
        defaultPoint = "TOPRIGHT",
        defaultRelPoint = "TOPRIGHT",
        defaultX = -320,
        defaultY = -180,
    })
    lvilFrame:Hide()
end

RefreshLVIL = function(forceShow)
    local db = mod:GetDB()
    if not (mod._active and db.lowValueHelper) then
        lvilManualOpen = false
        if lvilFrame then lvilFrame:Hide() end
        return
    end
    if forceShow then
        lvilManualOpen = true
    end
    if not forceShow and db.onlyWhenFull and GetContainerFreeSlots() > 0 then
        lvilManualOpen = false
        if lvilFrame then lvilFrame:Hide() end
        return
    end
    EnsureLVILFrame()
    local items = ScanLowValueItems()
    local maxRows = db.maxRows or 8
    for _, r in ipairs(lvilRows) do r:Hide() end
    local y = -28
    local shown = 0
    for i = 1, math.min(#items, maxRows) do
        local it = items[i]
        local row = lvilRows[i]
        if not row then
            row = CreateFrame("Button", nil, lvilFrame)
            row:SetSize(280, 22)
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", 2, 0)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.icon = icon

            local nameFS = row:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(nameFS, 11, "", 0.92, 0.92, 0.94, 1)
            nameFS:SetPoint("LEFT", icon, "RIGHT", 5, 0)
            nameFS:SetPoint("RIGHT", row, "RIGHT", -110, 0)
            nameFS:SetJustifyH("LEFT")
            nameFS:SetWordWrap(false)
            row.nameFS = nameFS

            local valFS = row:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(valFS, 11, "", 0.85, 0.85, 0.88, 1)
            valFS:SetPoint("RIGHT", row, "RIGHT", -34, 0)
            valFS:SetJustifyH("RIGHT")
            row.valFS = valFS

            local delBtn = CreateFrame("Button", nil, row)
            delBtn:SetSize(22, 18)
            delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            F.Theme.StyleGlassSurface(delBtn, {
                accent = { 0.93, 0.36, 0.43 },
                bgAlpha = 0.88,
                borderAlpha = 0.82,
                restAura = 0.16,
                hoverAura = 0.36,
                borderTintMix = 0.30,
            })
            local delIcon = delBtn:CreateTexture(nil, "OVERLAY", nil, 4)
            delIcon:SetSize(12, 12)
            delIcon:SetPoint("CENTER", delBtn, "CENTER", 0, 0)
            delIcon:SetTexture(F.Theme.ICONS .. "Trash.tga")
            delIcon:SetTexCoord(0, 1, 0, 1)
            delIcon:SetVertexColor(0.96, 0.56, 0.60, 0.94)
            delBtn._icon = delIcon
            delBtn:SetScript("OnClick", function(self)
                DestroyLowValueItem(self._item)
            end)
            delBtn:SetScript("OnEnter", function(self)
                F.Theme.SetGlassState(self, true, false)
                if self._icon then self._icon:SetVertexColor(1.0, 0.84, 0.86, 1.0) end
                local curItem = self._item
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("销毁此格物品", 0.95, 0.38, 0.42)
                if curItem then
                    local suffix = (curItem.count and curItem.count > 1) and (" x" .. curItem.count) or ""
                    GameTooltip:AddLine((curItem.name or "") .. suffix, 0.95, 0.95, 0.96)
                    if (curItem.quality or 1) >= 2 then
                        GameTooltip:AddLine("绿装及以上将弹出系统确认框", 0.94, 0.78, 0.34)
                    else
                        GameTooltip:AddLine("左键直接销毁（不可恢复，脱战可用）", 0.72, 0.75, 0.80)
                    end
                end
                GameTooltip:Show()
            end)
            delBtn:SetScript("OnLeave", function(self)
                F.Theme.SetGlassState(self, false, false)
                if self._icon then
                    self._icon:ClearAllPoints()
                    self._icon:SetPoint("CENTER", self, "CENTER", 0, 0)
                    self._icon:SetVertexColor(0.96, 0.56, 0.60, 0.94)
                end
                GameTooltip:Hide()
            end)
            delBtn:SetScript("OnMouseDown", function(self)
                if self._icon then
                    self._icon:ClearAllPoints()
                    self._icon:SetPoint("CENTER", self, "CENTER", 0, -1)
                end
            end)
            delBtn:SetScript("OnMouseUp", function(self)
                if self._icon then
                    self._icon:ClearAllPoints()
                    self._icon:SetPoint("CENTER", self, "CENTER", 0, 0)
                end
            end)
            row.delBtn = delBtn

            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.06)
            lvilRows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", lvilFrame, "TOPLEFT", 8, y)
        row.icon:SetTexture(it.icon or 134400)
        local qr, qg, qb = 0.85, 0.85, 0.85
        local getQualityColor = (_G.C_Item and _G.C_Item.GetItemQualityColor) or _G.GetItemQualityColor
        if getQualityColor then
            local okQ, r, g, b = pcall(getQualityColor, it.quality)
            if okQ and r then qr, qg, qb = r, g, b end
        end
        row.nameFS:SetTextColor(qr, qg, qb, 1)
        row.nameFS:SetText(it.count > 1 and string_format("%s x%d", it.name, it.count) or it.name)
        local tag = it.ahTotal > it.vendorTotal and "|cff73bdf2拍|r" or ""
        row.valFS:SetText(tag .. F.FormatMoney(it.effectiveVal))
        row.delBtn._item = it
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetBagItem(it.bag, it.slot)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("商店总价", F.FormatMoney(it.vendorTotal), 0.75, 0.75, 0.78, 1, 1, 1)
            if it.ahTotal > 0 then
                GameTooltip:AddDoubleLine("拍卖估价", F.FormatMoney(it.ahTotal), 0.45, 0.74, 0.95, 1, 1, 1)
            end
            GameTooltip:AddLine("点击行尾红色清理图标可销毁此格物品", 0.94, 0.56, 0.58)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:Show()
        y = y - 24
        shown = shown + 1
    end
    if shown == 0 and not forceShow then
        lvilManualOpen = false
        lvilFrame:Hide()
        return
    end
    lvilFrame:SetHeight(math.max(60, shown * 24 + 34))
    lvilFrame:Show()
end

-- 4) 智能商人助手（仅当 EllesmereUIQoL 未接管自动卖灰/修装时生效，绝不重复触发；按住 Shift 临时跳过）
local function HandleMerchantShow()
    if not mod._active then return end
    if _G.IsShiftKeyDown and _G.IsShiftKeyDown() then return end
    local db = mod:GetDB()
    local euiQoL = F.IsAddOnLoaded("EllesmereUIQoL")
    local euiDB = _G.EllesmereUIDB

    local euiHandlesJunk = euiQoL and (not euiDB or euiDB.autoSellJunk ~= false)
    if db.autoSellJunk ~= false and not euiHandlesJunk then
        local C = _G.C_Container
        if C and C.GetContainerNumSlots and C.GetContainerItemInfo and C.UseContainerItem then
            local getInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
            local soldCount, totalGain = 0, 0
            for bag = 0, 4 do
                local slots = C.GetContainerNumSlots(bag) or 0
                for slot = 1, slots do
                    local info = C.GetContainerItemInfo(bag, slot)
                    if info and info.hyperlink and not info.hasNoValue and not info.isLocked and info.quality == 0 then
                        local sellPrice = 0
                        if getInfo then
                            local _, _, _, _, _, _, _, _, _, _, price = getInfo(info.hyperlink)
                            sellPrice = F.PlainNumber(price, 0)
                        end
                        if sellPrice > 0 then
                            local ok = pcall(C.UseContainerItem, bag, slot)
                            if ok then
                                soldCount = soldCount + (info.stackCount or 1)
                                totalGain = totalGain + sellPrice * (info.stackCount or 1)
                            end
                        end
                    end
                end
            end
            if soldCount > 0 then
                F.Print(string_format("已自动清理 %d 件灰色垃圾，收入 %s。", soldCount, F.FormatMoney(totalGain)))
            end
        end
    end

    local euiHandlesRepair = euiQoL and (not euiDB or euiDB.autoRepair ~= false)
    if db.autoRepair ~= false and not euiHandlesRepair and _G.CanMerchantRepair and _G.CanMerchantRepair() then
        local cost, canRepair = _G.GetRepairAllCost and _G.GetRepairAllCost()
        cost = F.PlainNumber(cost, 0)
        if canRepair and cost > 0 then
            local money = _G.GetMoney and F.PlainNumber(_G.GetMoney(), 0) or 0
            if money >= cost and _G.RepairAllItems then
                local ok = pcall(_G.RepairAllItems, false)
                if ok then
                    F.Print("已自动修理全身装备，花费 " .. F.FormatMoney(cost) .. "。")
                end
            else
                F.Print("|cffe05263金币不足，未能自动修理|r（需 " .. F.FormatMoney(cost) .. "）。")
            end
        end
    end
end

-- 5) 无闪烁极速静默拾取（单帧倒序秒拾 + LootFrame 视觉静默，彻底消除闪窗与卡顿）
local function ShouldAutoLoot()
    local autoDef = _G.GetCVarBool and _G.GetCVarBool("autoLootDefault")
    local modClick = _G.IsModifiedClick and _G.IsModifiedClick("AUTOLOOTTOGGLE")
    if autoDef then
        return not modClick
    end
    return modClick == true
end

local function SetFrameMousePass(frame, enabled)
    if not frame then return end
    if frame.EnableMouse then pcall(frame.EnableMouse, frame, enabled) end
    if frame.SetMouseClickEnabled then pcall(frame.SetMouseClickEnabled, frame, enabled) end
    if frame.SetMouseMotionEnabled then pcall(frame.SetMouseMotionEnabled, frame, enabled) end
end

local function SetLootFrameSilent(silent)
    local lf = _G.LootFrame
    if not lf then return end
    local canMove = not (lf.IsProtected and lf:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown())
    -- 绝不修改 LootFrame 缩放（SetScale(0.0001) 会让 EllesmereUI 像素对齐边框按 1/0.0001 算出巨型黑块遮住图标），
    -- 改为保持 1:1 原缩放并无缩放移至屏外 + 禁用鼠标穿透，包满显窗时 100% 像素无损还原
    if canMove and lf.GetScale and lf.SetScale then
        local curScale = F.PlainNumber(lf:GetScale(), 1)
        if curScale and curScale < 0.5 then
            pcall(lf.SetScale, lf, 1)
        end
    end
    if silent then
        if canMove and lf.GetPoint then
            local okP, pt, rel, rpt, x, y = pcall(lf.GetPoint, lf, 1)
            local nx = okP and F.PlainNumber(x, nil) or nil
            local ny = okP and F.PlainNumber(y, nil) or nil
            if okP and type(pt) == "string" and nx and ny and math.abs(nx) < 5000 and math.abs(ny) < 5000 then
                savedLootPoint = { pt, rel or _G.UIParent, rpt or pt, nx, ny }
            end
        end
        if canMove and not lootParked and lf.IsClampedToScreen then
            local okC, clamped = pcall(lf.IsClampedToScreen, lf)
            if okC then savedLootClamped = clamped ~= false end
        end
        inSilentAlphaSet = true
        pcall(lf.SetAlpha, lf, 0)
        inSilentAlphaSet = false
        SetFrameMousePass(lf, false)
        SetFrameMousePass(lf.ScrollBox, false)
        SetFrameMousePass(lf.ClosePanelButton, false)
        SetFrameMousePass(lf.TitleContainer, false)
        if canMove and lf.ClearAllPoints and lf.SetPoint then
            if lf.SetClampedToScreen then pcall(lf.SetClampedToScreen, lf, false) end
            inSilentPointSet = true
            pcall(lf.ClearAllPoints, lf)
            pcall(lf.SetPoint, lf, "TOPLEFT", _G.UIParent, "BOTTOMRIGHT", 10000, -10000)
            inSilentPointSet = false
            lootParked = true
        end
    else
        if canMove and lootParked then
            if lf.SetClampedToScreen then pcall(lf.SetClampedToScreen, lf, savedLootClamped ~= false) end
            local stillOffscreen = true
            if lf.GetPoint then
                local okP, _, _, _, cx, cy = pcall(lf.GetPoint, lf, 1)
                local nx = okP and F.PlainNumber(cx, nil) or nil
                local ny = okP and F.PlainNumber(cy, nil) or nil
                if nx and ny and math.abs(nx) < 5000 and math.abs(ny) < 5000 then
                    stillOffscreen = false
                end
            end
            if stillOffscreen and lf.ClearAllPoints and lf.SetPoint then
                inSilentPointSet = true
                pcall(lf.ClearAllPoints, lf)
                if savedLootPoint then
                    pcall(lf.SetPoint, lf, savedLootPoint[1], savedLootPoint[2], savedLootPoint[3], savedLootPoint[4], savedLootPoint[5])
                else
                    pcall(lf.SetPoint, lf, "CENTER", _G.UIParent, "CENTER", 0, 80)
                end
                inSilentPointSet = false
            end
            lootParked = false
        end
        inSilentAlphaSet = true
        pcall(lf.SetAlpha, lf, 1)
        inSilentAlphaSet = false
        SetFrameMousePass(lf, true)
        SetFrameMousePass(lf.ScrollBox, true)
        SetFrameMousePass(lf.ClosePanelButton, true)
        SetFrameMousePass(lf.TitleContainer, true)
    end
end

local function IsEditModeActiveSafe()
    local em = _G.EditModeManagerFrame
    return (em and em.IsEditModeActive and em:IsEditModeActive()) == true
end

local function PreArmSilentLoot()
    if not (mod._active and mod:GetDB().silentFastLoot ~= false) or IsEditModeActiveSafe() then
        lootPreArmed = false
        return
    end
    local lf = _G.LootFrame
    if not lf or (lf.IsShown and lf:IsShown()) then return end
    local wantPreArm = (mod:GetDB().clickLoot == true) or ShouldAutoLoot()
    if wantPreArm then
        lootPreArmed = true
        inSilentAlphaSet = true
        pcall(lf.SetAlpha, lf, 0)
        inSilentAlphaSet = false
        SetFrameMousePass(lf, false)
    else
        lootPreArmed = false
    end
end

local function RevealLootWindow(markManual)
    isSilentLooting = false
    lootPreArmed = false
    if markManual then
        manualLootThisOpen = true
    else
        manualLootThisOpen = false
    end
    lootSweptThisOpen = false
    pendingCloseCheck = false
    lootRevealToken = lootRevealToken + 1
    SetLootFrameSilent(false)
end

-- 拾取关闭时重置静默状态：自动拾取开启时直接预静默（alpha=0），彻底杜绝下一次右键首帧闪窗
local function ResetSilentLootOnClose()
    isSilentLooting = false
    manualLootThisOpen = false
    lootSweptThisOpen = false
    pendingCloseCheck = false
    lootRevealToken = lootRevealToken + 1
    local lf = _G.LootFrame
    local keepPreArmed = mod._active and mod:GetDB().silentFastLoot ~= false
        and not IsEditModeActiveSafe()
        and ((mod:GetDB().clickLoot == true) or ShouldAutoLoot())
    if keepPreArmed then
        lootPreArmed = true
        if lf then
            inSilentAlphaSet = true
            pcall(lf.SetAlpha, lf, 0)
            inSilentAlphaSet = false
            SetFrameMousePass(lf, false)
        end
        return
    end
    lootPreArmed = false
    if lf and lf:IsShown() then
        C_Timer.After(0.06, function()
            if not isSilentLooting and not lootPreArmed and not (lf and lf:IsShown()) then
                SetLootFrameSilent(false)
            end
        end)
    else
        SetLootFrameSilent(false)
    end
end

local function ShouldSilenceOnShow()
    if not (mod._active and mod:GetDB().silentFastLoot ~= false) then
        return false
    end
    if IsEditModeActiveSafe() or manualLootThisOpen then
        return false
    end
    if isSilentLooting then
        return true
    end
    if ResolveWantAuto then
        return ResolveWantAuto(nil) == true
    end
    return ShouldAutoLoot()
end

-- 模块停用（或关闭静默拾取）且 LootFrame 已完全还原时，所有永久钩子直接空转，不再碰暴雪拾取窗
local function LootHooksIdle()
    if isSilentLooting or lootPreArmed or lootParked then return false end
    return not (mod._active and mod:GetDB().silentFastLoot ~= false)
end

local function HookLootFrameOnce()
    local lf = _G.LootFrame
    if lf and not lootFrameHooked then
        lootFrameHooked = true
        lf:HookScript("OnShow", function()
            if LootHooksIdle() then return end
            if ShouldSilenceOnShow() then
                isSilentLooting = true
                SetLootFrameSilent(true)
            else
                RevealLootWindow()
            end
        end)
        if type(lf.Open) == "function" and _G.hooksecurefunc then
            _G.hooksecurefunc(lf, "Open", function()
                if LootHooksIdle() then return end
                if ShouldSilenceOnShow() then
                    isSilentLooting = true
                    SetLootFrameSilent(true)
                else
                    RevealLootWindow()
                end
            end)
        end
        if type(lf.SetAlpha) == "function" and _G.hooksecurefunc then
            _G.hooksecurefunc(lf, "SetAlpha", function(self, alpha)
                if inSilentAlphaSet then return end
                if (isSilentLooting or lootPreArmed) and not IsEditModeActiveSafe() then
                    local a = F.PlainNumber(alpha, 0)
                    if a and a > 0.01 then
                        inSilentAlphaSet = true
                        pcall(self.SetAlpha, self, 0)
                        inSilentAlphaSet = false
                    end
                end
            end)
        end
        if type(lf.SetPoint) == "function" and _G.hooksecurefunc then
            _G.hooksecurefunc(lf, "SetPoint", function(self)
                if inSilentPointSet or not isSilentLooting or IsEditModeActiveSafe() then return end
                local canMove = not (self.IsProtected and self:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown())
                if canMove and self.ClearAllPoints and self.SetPoint then
                    inSilentPointSet = true
                    pcall(self.ClearAllPoints, self)
                    pcall(self.SetPoint, self, "TOPLEFT", _G.UIParent, "BOTTOMRIGHT", 10000, -10000)
                    inSilentPointSet = false
                    lootParked = true
                end
            end)
        end
        lf:HookScript("OnHide", function()
            if LootHooksIdle() then return end
            if not isSilentLooting and not lootPreArmed then
                SetLootFrameSilent(false)
            end
        end)
    end
    local em = _G.EditModeManagerFrame
    if em and not editModeHooked and em.HookScript then
        editModeHooked = true
        em:HookScript("OnShow", function()
            if LootHooksIdle() then return end
            RevealLootWindow(true)
        end)
    end
end

-- 自动关掉 EllesmereUIQoL 原本的 0.05s*i 分帧延迟拾取，避免拖长窗口停留时间
-- 关闭前记下用户原值，停用本模块或关闭静默拾取时原样还给 EUI
local function DisableSlowEUIQuickLoot()
    local db = mod:GetDB()
    if not (mod._active and db.silentFastLoot ~= false) then return end
    local euiDB = _G.EllesmereUIDB
    if euiDB and euiDB.quickLoot then
        if db.savedEUIQuickLoot == nil then
            db.savedEUIQuickLoot = true
        end
        euiDB.quickLoot = false
        if _G.EllesmereUI and _G.EllesmereUI._applyQuickLoot then
            pcall(_G.EllesmereUI._applyQuickLoot)
        end
    end
end

local function RestoreEUIQuickLoot()
    local db = mod:GetDB()
    if db.savedEUIQuickLoot == nil then return end
    local euiDB = _G.EllesmereUIDB
    if euiDB then
        euiDB.quickLoot = db.savedEUIQuickLoot == true
        if _G.EllesmereUI and _G.EllesmereUI._applyQuickLoot then
            pcall(_G.EllesmereUI._applyQuickLoot)
        end
    end
    db.savedEUIQuickLoot = nil
end

-- 注意：GetNumLootItems() 在槽位拾空后仍返回原始槽位数（直到 LOOT_CLOSED），
-- 必须用 GetLootSlotType / LootSlotHasItem 判断真正尚未拾取的剩余物品与金币
local function IsLootSlotActive(slot)
    if _G.GetLootSlotType then
        local ok, st = pcall(_G.GetLootSlotType, slot)
        if ok and st ~= nil then
            local noneType = (_G.Enum and _G.Enum.LootSlotType and _G.Enum.LootSlotType.None) or 0
            return st ~= noneType
        end
    end
    if _G.LootSlotHasItem then
        local ok, has = pcall(_G.LootSlotHasItem, slot)
        if ok then return has == true end
    end
    return true
end

local function CountRemainingLootSlots()
    local num = _G.GetNumLootItems and F.PlainNumber(_G.GetNumLootItems(), 0) or 0
    if num <= 0 then
        return 0
    end
    local rem = 0
    for i = 1, num do
        if IsLootSlotActive(i) then
            rem = rem + 1
        end
    end
    return rem
end

local function SweepLootSlotsOnce()
    local num = _G.GetNumLootItems and F.PlainNumber(_G.GetNumLootItems(), 0) or 0
    if num <= 0 then
        return 0
    end
    local swept = 0
    if _G.LootSlot then
        for i = num, 1, -1 do
            if IsLootSlotActive(i) then
                pcall(_G.LootSlot, i)
                swept = swept + 1
            end
        end
    end
    return swept
end

local function CloseLootSafely()
    if _G.CloseLoot then
        pcall(_G.CloseLoot)
    end
end

-- 静默拾取期间，当所有槽位均被服务端确认清空后立刻关闭拾取会话（避免 autoLootDefault=0 时残留空「物品」窗）
local function ScheduleSilentCloseCheck()
    if pendingCloseCheck or not isSilentLooting then return end
    pendingCloseCheck = true
    local myToken = lootRevealToken
    C_Timer.After(0, function()
        pendingCloseCheck = false
        if myToken ~= lootRevealToken or not isSilentLooting then return end
        if CountRemainingLootSlots() <= 0 then
            CloseLootSafely()
        end
    end)
end

-- 每具尸体只拾取一次（避免重复刷 LootSlot 造成延迟），但若首次事件尚无有效槽位则不占节流窗口
local lastLootTime = -1

-- 左右键拾取：分别记录最近左右键时间，仅在启用 clickLoot 时监听 GLOBAL_MOUSE_DOWN
local lastLeftTime, lastRightTime = -10, -10
local function OnGlobalMouseDown(_, _, button)
    local now = _G.GetTime()
    if button == "LeftButton" then
        lastLeftTime = now
    elseif button == "RightButton" then
        lastRightTime = now
    end
end

local function SyncClickLootMouseWatch()
    local db = mod:GetDB()
    if mod._active and db.silentFastLoot ~= false and db.clickLoot == true then
        mod:RegisterEvent("GLOBAL_MOUSE_DOWN", OnGlobalMouseDown)
    else
        mod:UnregisterEvent("GLOBAL_MOUSE_DOWN")
    end
end

local function GetCVarValue(name)
    local get = (_G.C_CVar and _G.C_CVar.GetCVar) or _G.GetCVar
    if not get then return nil end
    local ok, v = pcall(get, name)
    return ok and v or nil
end

local function SetCVarValue(name, value)
    local set = (_G.C_CVar and _G.C_CVar.SetCVar) or _G.SetCVar
    if set then pcall(set, name, value) end
end

-- 开启「左右键拾取」：游戏自带自动拾取改为默认关闭（右键由本模块代为全部拾取），
-- 并打开「左键与对象互动」，否则左键点尸体不会打开拾取窗口。原值存档，关闭本项即还原。
local function ApplyClickLootCVars(on)
    F.RunOutOfCombat("FUI_ClickLootCVars", function()
        local db = mod:GetDB()
        if on then
            if db.savedAutoLoot == nil then db.savedAutoLoot = GetCVarValue("autoLootDefault") or "1" end
            SetCVarValue("autoLootDefault", "0")
            local left = GetCVarValue("interactOnLeftClick")
            if left ~= nil then
                if db.savedLeftClick == nil then db.savedLeftClick = left end
                SetCVarValue("interactOnLeftClick", "1")
            end
        else
            if db.savedAutoLoot ~= nil then
                SetCVarValue("autoLootDefault", db.savedAutoLoot)
                db.savedAutoLoot = nil
            end
            if db.savedLeftClick ~= nil then
                SetCVarValue("interactOnLeftClick", db.savedLeftClick)
                db.savedLeftClick = nil
            end
        end
    end)
end

ResolveWantAuto = function(autoLoot)
    if mod:GetDB().clickLoot == true then
        -- 仅当 0.55 秒内确实是纯左键触发（且晚于右键）才开窗自选，防止走位转视角左键误弹拾取框；
        -- 按住自动拾取切换键（默认 Shift）时由游戏反转（autoLoot 为真）。
        local now = _G.GetTime()
        local recentLeft = (now - lastLeftTime) < 0.55 and (lastLeftTime > lastRightTime)
        return (autoLoot == true) or not recentLeft
    end
    return (autoLoot == true) or (autoLoot == nil and ShouldAutoLoot())
end

local function ArmSilentLootFallback()
    lootRevealToken = lootRevealToken + 1
    local myToken = lootRevealToken
    -- 0.35s 补扫一次（处理群拾或网络波动时稍晚到达的槽位，不显窗）
    C_Timer.After(0.35, function()
        if myToken ~= lootRevealToken or not isSilentLooting then return end
        local rem = CountRemainingLootSlots()
        if rem <= 0 then
            CloseLootSafely()
            ResetSilentLootOnClose()
        else
            SweepLootSlotsOnce()
        end
    end)
    -- 1.15s 兜底：若仍有物品无法自动拾取（拾绑确认/唯一/背包满），再自然显示窗口
    C_Timer.After(1.15, function()
        if myToken ~= lootRevealToken or not isSilentLooting then return end
        local rem = CountRemainingLootSlots()
        if rem <= 0 then
            CloseLootSafely()
            ResetSilentLootOnClose()
        else
            local lf = _G.LootFrame
            if lf and lf:IsShown() then
                RevealLootWindow()
            else
                ResetSilentLootOnClose()
            end
        end
    end)
end

local function HandleLootTrigger(_, event, autoLoot)
    if not (mod._active and mod:GetDB().silentFastLoot ~= false) then return end
    HookLootFrameOnce()

    if event == "LOOT_OPENED" then
        if not isSilentLooting then
            if not ResolveWantAuto(autoLoot) then
                RevealLootWindow(true)
                return
            end
            isSilentLooting = true
        end
        SetLootFrameSilent(true)
        local rem = CountRemainingLootSlots()
        if rem <= 0 then
            CloseLootSafely()
            return
        end
        if not lootSweptThisOpen then
            local swept = SweepLootSlotsOnce()
            if swept > 0 then
                lootSweptThisOpen = true
                lastLootTime = _G.GetTime()
            end
            ArmSilentLootFallback()
        end
        return
    end

    if event ~= "LOOT_READY" then return end

    if not ResolveWantAuto(autoLoot) then
        RevealLootWindow(true)
        return
    end

    manualLootThisOpen = false
    isSilentLooting = true
    SetLootFrameSilent(true)

    local now = _G.GetTime()
    if lootSweptThisOpen and (now - lastLootTime < 0.3) then
        if CountRemainingLootSlots() <= 0 then
            ScheduleSilentCloseCheck()
        end
        return
    end

    local swept = SweepLootSlotsOnce()
    if swept > 0 then
        lootSweptThisOpen = true
        lastLootTime = now
        ArmSilentLootFallback()
    else
        -- 服务端尚未下发或空掉落：延后兜底（若到达 LOOT_OPENED 仍为空则立刻关闭）
        ArmSilentLootFallback()
    end
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2NativeAutoLoot then
        db.v2NativeAutoLoot = true
        -- 一次性切回暴雪原生 C++ 自动拾取（1 次往返、首拾不触发 LootFrame 皮肤初始化卡顿、不强制左键互动）
        if db.clickLoot == true then
            db.clickLoot = false
            ApplyClickLootCVars(false)
        end
    end

    SetupMoneyAlign()
    -- 背包框体可能早于本模块创建，此时 MoneyFrame_Update 尚未再次触发：启用时先对齐一次
    if db.alignBagMoney and _G.EUI_BagMoneyFrame then
        AlignMoneyFrame(_G.EUI_BagMoneyFrame)
    end
    HookLootFrameOnce()
    PreArmSilentLoot()
    DisableSlowEUIQuickLoot()
    C_Timer.After(1.5, DisableSlowEUIQuickLoot)

    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        HookLootFrameOnce()
        PreArmSilentLoot()
        DisableSlowEUIQuickLoot()
        C_Timer.After(1.0, DisableSlowEUIQuickLoot)
    end)
    self:RegisterEvent("LOOT_READY", HandleLootTrigger)
    self:RegisterEvent("LOOT_OPENED", HandleLootTrigger)
    SyncClickLootMouseWatch()
    if db.clickLoot == true and db.silentFastLoot ~= false then
        ApplyClickLootCVars(true)
    end
    self:RegisterEvent("LOOT_SLOT_CLEARED", function()
        if isSilentLooting then
            -- 已停到屏外时无需每个槽位都重做 ~20 次窗口 API 调用（AoE 一次拾 15 件时尤为明显）
            if not lootParked then SetLootFrameSilent(true) end
            ScheduleSilentCloseCheck()
        end
    end)
    self:RegisterEvent("LOOT_BIND_CONFIRM", function() RevealLootWindow(true) end)
    self:RegisterEvent("LOOT_CLOSED", ResetSilentLootOnClose)
    self:RegisterEvent("MERCHANT_SHOW", HandleMerchantShow)
    self:RegisterEvent("BAG_UPDATE_DELAYED", F.Debounce(0.4, function() RefreshLVIL(lvilManualOpen) end))
    self:RegisterEvent("UI_ERROR_MESSAGE", function(_, _, _, msg)
        local cleanMsg = F.PlainString(msg, nil)
        if not cleanMsg then return end
        if cleanMsg == _G.ERR_INV_FULL then
            if isSilentLooting then RevealLootWindow(true) end
            lvilManualOpen = false
            RefreshLVIL(true)
            lvilManualOpen = false
        elseif isSilentLooting and (cleanMsg == _G.ERR_LOOT_CANT_LOOT_THAT or cleanMsg == _G.ERR_ITEM_MAX_COUNT) then
            RevealLootWindow(true)
        end
    end)
    self:RegisterEvent("ADDON_LOADED", function(_, _, name)
        if name == "Blizzard_MacroUI" then
            EnlargeMacroFrame()
        end
    end)
    if _G.MacroFrame then
        EnlargeMacroFrame()
    end
end

function mod:OnDisable()
    RevealLootWindow()
    ApplyClickLootCVars(false)
    RestoreEUIQuickLoot()
    lvilManualOpen = false
    if lvilFrame then lvilFrame:Hide() end
end

function mod:OnThemeChanged()
    if lvilFrame then
        F.Theme.SetGlassState(lvilFrame, false, false)
    end
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "无闪烁极速静默拾取",
        tooltip = "自动拾取时单帧倒序秒拾并隐藏掉落窗，彻底消除闪现与卡顿；按住 Shift 拾取、背包满或拾取绑定物品时自动正常显窗。",
        getValue = function() return db.silentFastLoot ~= false end,
        setValue = function(v)
            db.silentFastLoot = v == true
            if v then DisableSlowEUIQuickLoot(); PreArmSilentLoot() else RevealLootWindow(); RestoreEUIQuickLoot() end
            ApplyClickLootCVars(v == true and db.clickLoot == true)
            SyncClickLootMouseWatch()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "右键全部拾取 / 左键打开拾取窗口（可选）",
        tooltip = "默认关闭以保留暴雪原生 C++ 自动拾取（最快、首拾零卡顿，按住 Shift+右键 即可开窗挑物品）。若习惯左键开窗、右键全拾可勾选此项。",
        getValue = function() return db.clickLoot == true end,
        setValue = function(v)
            db.clickLoot = v == true
            ApplyClickLootCVars(v == true and db.silentFastLoot ~= false)
            SyncClickLootMouseWatch()
        end,
    }, blank)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "对齐 EUI 背包金币数字",
        tooltip = "无侵入式钩子自动将 EUI 背包底栏金币数字与币图标垂直居中对齐。",
        getValue = function() return db.alignBagMoney ~= false end,
        setValue = function(v) db.alignBagMoney = v == true end,
    }, {
        type = "toggle",
        text = "放大宏编辑窗口",
        tooltip = "打开 /macro 时自动放大界面，方便查看和编辑长宏。",
        getValue = function() return db.enlargeMacro ~= false end,
        setValue = function(v) db.enlargeMacro = v == true; if v then EnlargeMacroFrame() end end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "访问商人自动卖灰色垃圾",
        tooltip = "打开商人窗口时自动出售所有粗糙（灰色）可售垃圾并汇总收益；按住 Shift 对话可临时跳过（EUI QoL 开启时自动让位）。",
        getValue = function() return db.autoSellJunk ~= false end,
        setValue = function(v) db.autoSellJunk = v == true end,
    }, {
        type = "toggle",
        text = "访问商人自动修理装备",
        tooltip = "打开可修理商人时自动使用个人金币修满装备；按住 Shift 对话可临时跳过（EUI QoL 开启时自动让位）。",
        getValue = function() return db.autoRepair ~= false end,
        setValue = function(v) db.autoRepair = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "包满时弹出低价值清单",
        tooltip = "背包已满时按价值从低到高列出可清理物品。",
        getValue = function() return db.lowValueHelper ~= false end,
        setValue = function(v) db.lowValueHelper = v == true end,
    }, {
        type = "toggle",
        text = "参考 Auctionator 拍卖行价格",
        tooltip = "低价值排序同时参考拍卖行市价，避免误删高价材料/白装。",
        getValue = function() return db.useAuctionPrice ~= false end,
        setValue = function(v) db.useAuctionPrice = v == true end,
    })
    y = y - h

    _, h = W:WideButton(parent, "立即查看当前背包低价值清单", y, function() RefreshLVIL(true) end)
    y = y - h
    return y
end
