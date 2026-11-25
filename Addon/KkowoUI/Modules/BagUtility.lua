----------------------------------------------------------------------
--  KkowoUI — Modules/BagUtility.lua
--  背包低价值清理助手（联动 Auctionator 拍卖价防误删）
--  + 无侵入背包金币文字对齐（无需再改 EllesmereUIBags 源码）
--  + 宏编辑窗口放大
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, select, type = ipairs, pairs, pcall, select, type
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
        showEmptyLoot = true,
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
local sawAnyLootThisOpen = false
local notifiedEmptyThisOpen = false
local lastEmptyToastTime = -10
local fallbackArmedThisOpen = false
local lastFallbackArmTime = -1
local sweptSlots = {}
local retriedCoinOnOpen = {}
local pendingCloseCheck = false
local lootParked = false
local lootPreArmed = false
local manualLootThisOpen = false
local inSilentAlphaSet = false
local inSilentPointSet = false
local savedLootPoint = nil
local savedLootClamped = true
local ResolveWantAuto = nil
local emptyToastFrame = nil
local emptyToastCount = 0
local emptyToastRepositionPending = false
local emptyGradFrom = nil
local emptyGradTo = nil

local function ClearLootSessionTracking()
    lootSweptThisOpen = false
    sawAnyLootThisOpen = false
    notifiedEmptyThisOpen = false
    fallbackArmedThisOpen = false
    for k in pairs(sweptSlots) do sweptSlots[k] = nil end
    for k in pairs(retriedCoinOnOpen) do retriedCoinOnOpen[k] = nil end
end

-- 1) 无侵入对齐所有金币框（EUI 背包、邮箱发件箱/邮资、商人、银行、训练师、拍卖行等）数字与币图标垂直居中
local MONEY_SUFFIXES = { "GoldButton", "SilverButton", "CopperButton" }
local MONEY_TEXT_Y_OFFSET = -0.5
local KNOWN_MONEY_FRAMES = {
    "EUI_BagMoneyFrame",
    "SendMailMoneyFrame",
    "SendMailCostMoneyFrame",
    "MerchantMoneyFrame",
    "BankFrameMoneyFrame",
    "PetStableMoneyFrame",
}

local function AlignMoneyFrame(mf, yOffset)
    if not mf or (mf.IsForbidden and mf:IsForbidden()) then
        return
    end
    local okName, base = pcall(mf.GetName, mf)
    if not (okName and type(base) == "string" and base ~= "") then
        return
    end
    -- 跳过 Tooltip 内嵌金币框，避免 12.x 战斗中触发 GameTooltip 秘密值污染
    if base:find("Tooltip", 1, true) then
        return
    end
    if mf.IsProtected and mf:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown() then
        return
    end
    local dy = yOffset ~= nil and yOffset or MONEY_TEXT_Y_OFFSET
    for _, sfx in ipairs(MONEY_SUFFIXES) do
        local b = _G[base .. sfx]
        if b and not (b.IsForbidden and b:IsForbidden()) then
            local t = b.GetFontString and b:GetFontString()
            if t then
                local nt = b.GetNormalTexture and b:GetNormalTexture()
                local iconW = nt and nt.GetWidth and F.PlainNumber(nt:GetWidth(), nil) or nil
                if not iconW or iconW < 10 or iconW > 28 then
                    iconW = 13
                end
                if t.SetJustifyV then pcall(t.SetJustifyV, t, "MIDDLE") end
                pcall(t.ClearAllPoints, t)
                pcall(t.SetPoint, t, "RIGHT", b, "RIGHT", -iconW, dy)
            end
        end
    end
end

local function AlignKnownMoneyFrames(yOffset)
    for _, fname in ipairs(KNOWN_MONEY_FRAMES) do
        local mf = _G[fname]
        if mf then
            AlignMoneyFrame(mf, yOffset)
        end
    end
end

local function TryAlignAnyMoneyFrame(frame)
    if not (mod._active and mod:GetDB().alignBagMoney) then
        return
    end
    local mf = type(frame) == "string" and _G[frame] or frame
    if mf then
        AlignMoneyFrame(mf)
    end
end

local function SetupMoneyAlign()
    if moneyHooked then
        return
    end
    moneyHooked = true
    if _G.MoneyFrame_Update then
        _G.hooksecurefunc("MoneyFrame_Update", TryAlignAnyMoneyFrame)
    end
    if _G.MoneyFrame_UpdateMoney then
        _G.hooksecurefunc("MoneyFrame_UpdateMoney", TryAlignAnyMoneyFrame)
    end
end

-- 2) 宏编辑界面放大 + 排版修正（弱表记录，不往暴雪 MacroFrame 写字段）
--    EUI 皮肤换上整合包字体后字号偏大：已选宏名、「改变名字/图标」按钮、「输入宏命令」挤在一起，
--    图标选择弹窗的「输入宏的名字」标题也压住输入框。这里收小字号、按图标 / 文本框重新排位，
--    并让文本框铺满放大后的窗口。EUI 每次打开都会在下一帧重新换肤（保留当前字号），所以稍后再排一次。
local MACRO_FONT_NAME, MACRO_FONT_BUTTON, MACRO_FONT_LABEL, MACRO_FONT_BODY, MACRO_FONT_SMALL = 13, 12, 13, 14, 12
local macroUIHooked, macroPopupHooked = false, false

local function SetFontSizeKeepFace(obj, size)
    if not (obj and obj.GetFont and obj.SetFont) then return end
    if obj.IsForbidden and obj:IsForbidden() then return end
    local ok, face, cur, flags = pcall(obj.GetFont, obj)
    if not ok or type(face) ~= "string" or face == "" then return end
    if F.PlainNumber(cur, 0) == size then return end
    pcall(obj.SetFont, obj, face, size, type(flags) == "string" and flags or "")
end

local function LayoutMacroFrameNow()
    local mf = _G.MacroFrame
    if not (mod._active and mod:GetDB().enlargeMacro and mf and mf:IsShown()) then return end
    local selBtn = _G.MacroFrameSelectedMacroButton
    local nameFS = _G.MacroFrameSelectedMacroName
    local editBtn = _G.MacroEditButton
    local label = _G.MacroFrameEnterMacroText
    local tb = _G.MacroFrameTextBackground
    local sf = _G.MacroFrameScrollFrame
    local body = _G.MacroFrameText
    local limit = _G.MacroFrameCharLimitText

    SetFontSizeKeepFace(nameFS, MACRO_FONT_NAME)
    SetFontSizeKeepFace(label, MACRO_FONT_LABEL)
    SetFontSizeKeepFace(body, MACRO_FONT_BODY)
    SetFontSizeKeepFace(limit, MACRO_FONT_SMALL)
    if not selBtn then return end

    -- 已选宏：名字贴图标右上、按钮贴图标右下，都收在图标高度以内。
    -- 暴雪给名字和「输入宏命令」的文字框是固定矮高度，换成整合包字体后下沿（g、y 等）会被裁掉，
    -- 「输入宏命令」溢出的部分还会被下方文本框盖住：两者都按字号给足高度
    if nameFS then
        nameFS:ClearAllPoints()
        nameFS:SetPoint("TOPLEFT", selBtn, "TOPRIGHT", 10, 1)
        nameFS:SetWidth(230)
        nameFS:SetHeight(MACRO_FONT_NAME + 5)
        nameFS:SetJustifyH("LEFT")
        if nameFS.SetWordWrap then nameFS:SetWordWrap(false) end
    end
    if editBtn then
        local fs = editBtn.GetFontString and editBtn:GetFontString()
        SetFontSizeKeepFace(fs, MACRO_FONT_BUTTON)
        local tw = fs and F.PlainNumber(fs:GetStringWidth(), 0) or 0
        editBtn:SetSize(math.max(108, math.floor(tw + 28 + 0.5)), 20)
        editBtn:ClearAllPoints()
        editBtn:SetPoint("BOTTOMLEFT", selBtn, "BOTTOMRIGHT", 10, 0)
    end
    if label then
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", selBtn, "BOTTOMLEFT", 0, -6)
        label:SetHeight(MACRO_FONT_LABEL + 7)
        if label.SetJustifyV then label:SetJustifyV("MIDDLE") end
    end

    -- 文本框：紧接「输入宏命令」下方，左右贴窗体内边距，向下铺满到字数提示上方
    if tb and label then
        local mfL = F.PlainNumber(mf:GetLeft(), nil)
        local selL = F.PlainNumber(selBtn:GetLeft(), nil)
        local dx = (mfL and selL) and math.floor(mfL + 8 - selL + 0.5) or -6
        tb:ClearAllPoints()
        tb:SetPoint("TOPLEFT", label, "BOTTOMLEFT", dx, -5)
        tb:SetPoint("BOTTOMRIGHT", mf, "BOTTOMRIGHT", -10, 58)
        if sf then
            sf:ClearAllPoints()
            sf:SetPoint("TOPLEFT", tb, "TOPLEFT", 8, -6)
            sf:SetPoint("BOTTOMRIGHT", tb, "BOTTOMRIGHT", -26, 6)
        end
        if body then
            local w = F.PlainNumber(tb:GetWidth(), 0) - 38
            if w > 200 then body:SetWidth(w) end
        end
        if limit then
            limit:ClearAllPoints()
            limit:SetPoint("TOP", tb, "BOTTOM", 0, -6)
        end
    end
end

local function LayoutMacroPopupNow()
    local p = _G.MacroPopupFrame
    local bb = p and p.BorderBox
    if not (mod._active and mod:GetDB().enlargeMacro and bb and p:IsShown()) then return end
    local hdr, eb = bb.EditBoxHeaderText, bb.IconSelectorEditBox
    SetFontSizeKeepFace(hdr, MACRO_FONT_LABEL)
    SetFontSizeKeepFace(bb.IconSelectionText, MACRO_FONT_LABEL)
    SetFontSizeKeepFace(eb, MACRO_FONT_LABEL)
    if hdr and eb then
        -- 名字输入框放到标题正下方，不再压住「输入宏的名字（最多16个字符）」
        local w = F.PlainNumber(eb:GetWidth(), 0)
        local h = F.PlainNumber(eb:GetHeight(), 0)
        hdr:SetHeight(MACRO_FONT_LABEL + 7)
        eb:ClearAllPoints()
        eb:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -6)
        if w > 50 then eb:SetWidth(w) end
        eb:SetHeight(math.max(h, 22))
    end
end

local function QueueMacroPopupLayout()
    C_Timer.After(0.05, function()
        F.RunOutOfCombat("FUI_MacroPopupLayout", function() pcall(LayoutMacroPopupNow) end)
    end)
end

local function HookMacroPopupOnce()
    local p = _G.MacroPopupFrame
    if macroPopupHooked or not p then return end
    macroPopupHooked = true
    p:HookScript("OnShow", QueueMacroPopupLayout)
end

local function QueueMacroLayout()
    HookMacroPopupOnce()
    C_Timer.After(0.05, function()
        F.RunOutOfCombat("FUI_MacroLayout", function() pcall(LayoutMacroFrameNow) end)
    end)
end

local function EnlargeMacroFrame()
    if not (mod._active and mod:GetDB().enlargeMacro) then
        return
    end
    local mf = _G.MacroFrame
    if not mf then
        return
    end
    if not macroUIHooked then
        macroUIHooked = true
        mf:HookScript("OnShow", QueueMacroLayout)
    end
    HookMacroPopupOnce()
    if macroEnlarged[mf] then
        if mf:IsShown() then QueueMacroLayout() end
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
        if mf:IsShown() then QueueMacroLayout() end
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
    lvilFrame = CreateFrame("Frame", "KkowoUI_LowValueList", _G.UIParent)
    lvilFrame:SetSize(296, 220)
    lvilFrame:SetFrameStrata("MEDIUM")
    lvilFrame:SetToplevel(true)
    lvilFrame:SetClampedToScreen(true)
    -- 面板空白处吃掉点击，避免点穿到 3D 世界误选目标/误转镜头
    lvilFrame:EnableMouse(true)
    lvilFrame:Hide()
    lvilFrame:SetScript("OnHide", function(self)
        self:SetFrameStrata("MEDIUM")
    end)
    F.Theme.RegisterEscapeClose(lvilFrame, function()
        lvilManualOpen = false
        lvilFrame:Hide()
    end)
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
    -- 从 EUI 设置面板手动点击预览时临时置顶到 FULLSCREEN_DIALOG，避免被设置面板遮挡；关闭后自动回落 MEDIUM
    if forceShow then
        lvilFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        lvilFrame:SetFrameLevel(240)
    else
        lvilFrame:SetFrameStrata("MEDIUM")
    end
    lvilFrame:Show()
    if forceShow then
        lvilFrame:Raise()
    end
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
local function IsAutoLootDefaultOn()
    return (_G.GetCVarBool and _G.GetCVarBool("autoLootDefault")) == true
end

local function ShouldAutoLoot()
    local autoDef = IsAutoLootDefaultOn()
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

local function WantPersistentPreArm()
    local db = mod:GetDB()
    return mod._active and db.silentFastLoot ~= false
        and not IsEditModeActiveSafe()
        and ((db.clickLoot == true) or IsAutoLootDefaultOn())
end

local function PreArmSilentLoot()
    if not WantPersistentPreArm() then
        lootPreArmed = false
        return
    end
    local lf = _G.LootFrame
    if not lf or (lf.IsShown and lf:IsShown()) then return end
    lootPreArmed = true
    SetLootFrameSilent(true)
end

local function RevealLootWindow(markManual)
    isSilentLooting = false
    lootPreArmed = false
    if markManual then
        manualLootThisOpen = true
    else
        manualLootThisOpen = false
    end
    ClearLootSessionTracking()
    pendingCloseCheck = false
    lootRevealToken = lootRevealToken + 1
    SetLootFrameSilent(false)
end

-- 拾取关闭时重置静默状态：只要自动拾取设置开启（不看关窗瞬间是否按着 Shift），
-- 就始终恢复预静默（alpha=0 + 离屏停放），彻底杜绝 Shift 关窗后下一次右键首帧闪窗
local function ResetSilentLootOnClose()
    isSilentLooting = false
    manualLootThisOpen = false
    ClearLootSessionTracking()
    pendingCloseCheck = false
    lootRevealToken = lootRevealToken + 1
    local lf = _G.LootFrame
    if WantPersistentPreArm() then
        lootPreArmed = true
        SetLootFrameSilent(true)
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
            local function ParkLootOnSetPoint(self, pt, rel, rpt, x, y)
                if inSilentPointSet or IsEditModeActiveSafe() then return end
                if not (isSilentLooting or lootPreArmed) then return end
                -- 若玩家正按住 Shift 手动开窗，不要劫持暴雪将窗口放到鼠标处的 SetPoint
                if not isSilentLooting and not ShouldSilenceOnShow() then return end
                local nx = F.PlainNumber(x, nil)
                local ny = F.PlainNumber(y, nil)
                if type(pt) == "string" and nx and ny and math.abs(nx) < 5000 and math.abs(ny) < 5000 then
                    savedLootPoint = { pt, rel or _G.UIParent, rpt or pt, nx, ny }
                end
                local canMove = not (self.IsProtected and self:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown())
                if canMove and self.ClearAllPoints and self.SetPoint then
                    inSilentPointSet = true
                    pcall(self.ClearAllPoints, self)
                    pcall(self.SetPoint, self, "TOPLEFT", _G.UIParent, "BOTTOMRIGHT", 10000, -10000)
                    inSilentPointSet = false
                    lootParked = true
                end
            end
            _G.hooksecurefunc(lf, "SetPoint", ParkLootOnSetPoint)
            if type(lf.SetPointBase) == "function" and lf.SetPointBase ~= lf.SetPoint then
                _G.hooksecurefunc(lf, "SetPointBase", ParkLootOnSetPoint)
            end
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
        em:HookScript("OnHide", function()
            if mod._active and mod:GetDB().silentFastLoot ~= false then
                C_Timer.After(0, PreArmSilentLoot)
            end
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
local function GetLootSlotKind(slot)
    if _G.GetLootSlotType then
        local ok, st = pcall(_G.GetLootSlotType, slot)
        if ok then
            return F.PlainNumber(st, nil)
        end
    end
    return nil
end

local function IsCoinOrCurrencyType(st)
    if not st then return false end
    local moneyType = (_G.Enum and _G.Enum.LootSlotType and _G.Enum.LootSlotType.Money) or _G.LOOT_SLOT_MONEY or 2
    local currType = (_G.Enum and _G.Enum.LootSlotType and _G.Enum.LootSlotType.Currency) or _G.LOOT_SLOT_CURRENCY or 3
    return st == moneyType or st == currType
end

local function GetLootSlotSignature(slot, st)
    if _G.GetLootSlotInfo then
        local ok, _, item, qty, currencyID = pcall(_G.GetLootSlotInfo, slot)
        if ok then
            local cleanItem = F.PlainString(item, "")
            local cleanQty = F.PlainNumber(qty, 0)
            local cleanCurr = F.PlainNumber(currencyID, 0)
            return string_format("%d:%d:%d:%s", st or -1, cleanQty, cleanCurr, cleanItem)
        end
    end
    return st or true
end

local function IsLootSlotActive(slot)
    local st = GetLootSlotKind(slot)
    if st ~= nil then
        local noneType = (_G.Enum and _G.Enum.LootSlotType and _G.Enum.LootSlotType.None) or 0
        return st ~= noneType
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

local function HasActiveCoinSlot()
    local num = _G.GetNumLootItems and F.PlainNumber(_G.GetNumLootItems(), 0) or 0
    for i = 1, num do
        if IsCoinOrCurrencyType(GetLootSlotKind(i)) then
            return true
        end
    end
    return false
end

-- 先扫金币与货币（1..num，确保金币永远最先发出、不再排在所有物品之后），再倒序扫普通物品（num..1）；
-- onlyUnswept=true 时按槽位签名去重：既防止同一具尸体重复刷 LootSlot 卡顿，又能 0ms 拾取群拾/后续包新增的槽位；
-- allowCoinRetry=true（仅 LOOT_OPENED 使用）时，若金币/货币槽在 LOOT_READY 时机过早未被清空，仅对其补发 1 次（绝不重刷物品槽）。
local function SweepLootSlots(onlyUnswept, onlyCoins, allowCoinRetry)
    local num = _G.GetNumLootItems and F.PlainNumber(_G.GetNumLootItems(), 0) or 0
    if num <= 0 or not _G.LootSlot then
        return 0
    end
    local swept = 0
    for i = 1, num do
        local st = GetLootSlotKind(i)
        if IsCoinOrCurrencyType(st) then
            local sig = GetLootSlotSignature(i, st)
            local needSweep = (not onlyUnswept) or (sweptSlots[i] ~= sig)
            local needCoinRetry = (not needSweep) and allowCoinRetry and (not retriedCoinOnOpen[i])
            if needSweep or needCoinRetry then
                pcall(_G.LootSlot, i)
                sweptSlots[i] = sig
                if allowCoinRetry then
                    retriedCoinOnOpen[i] = true
                end
                swept = swept + 1
            end
        end
    end
    if onlyCoins then
        return swept
    end
    for i = num, 1, -1 do
        local st = GetLootSlotKind(i)
        if not IsCoinOrCurrencyType(st) and IsLootSlotActive(i) then
            local sig = GetLootSlotSignature(i, st)
            if not onlyUnswept or sweptSlots[i] ~= sig then
                pcall(_G.LootSlot, i)
                sweptSlots[i] = sig
                swept = swept + 1
            end
        end
    end
    return swept
end

local function SweepLootSlotsOnce()
    return SweepLootSlots(false, false, false)
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
    fallbackArmedThisOpen = true
    lastFallbackArmTime = _G.GetTime()
    lootRevealToken = lootRevealToken + 1
    local myToken = lootRevealToken
    local prevRem = nil
    -- 0.08s 仅检查仍活跃的金币/货币槽位（已清零时不发任何包，未清时比 0.30s 提早 220ms 补拾，不显窗也不重刷物品）
    C_Timer.After(0.08, function()
        if myToken ~= lootRevealToken or not isSilentLooting then return end
        if HasActiveCoinSlot() then
            SweepLootSlots(false, true, false)
        end
    end)
    -- 0.30s / 0.85s 静默补扫两次（处理群拾或网络波动时稍晚到达的槽位，不显窗）
    C_Timer.After(0.30, function()
        if myToken ~= lootRevealToken or not isSilentLooting then return end
        local rem = CountRemainingLootSlots()
        if rem <= 0 then
            CloseLootSafely()
            ResetSilentLootOnClose()
        else
            prevRem = rem
            SweepLootSlotsOnce()
        end
    end)
    C_Timer.After(0.85, function()
        if myToken ~= lootRevealToken or not isSilentLooting then return end
        local rem = CountRemainingLootSlots()
        if rem <= 0 then
            CloseLootSafely()
            ResetSilentLootOnClose()
        else
            prevRem = rem
            SweepLootSlotsOnce()
        end
    end)
    -- 1.80s 兜底（包满/拾绑已由事件瞬时显窗，此处仅兜底异常卡住的槽位；若仍在持续拾取则再宽限 1 秒防群拾闪窗）
    local function CheckFinalReveal(allowGrace)
        if myToken ~= lootRevealToken or not isSilentLooting then return end
        local rem = CountRemainingLootSlots()
        if rem <= 0 then
            CloseLootSafely()
            ResetSilentLootOnClose()
            return
        end
        if allowGrace and prevRem and rem < prevRem then
            prevRem = rem
            SweepLootSlotsOnce()
            C_Timer.After(1.0, function() CheckFinalReveal(false) end)
            return
        end
        local lf = _G.LootFrame
        if lf and lf:IsShown() then
            RevealLootWindow()
        else
            ResetSilentLootOnClose()
        end
    end
    C_Timer.After(1.80, function() CheckFinalReveal(true) end)
end

local function EnsureSilentLootFallback(now)
    if not fallbackArmedThisOpen or (now - lastFallbackArmTime >= 0.25) then
        ArmSilentLootFallback()
    end
end

-- 空包裹微播报：自动对齐 EllesmereUIForeverEssentials 拾取信息（EUI_LootFeed）位置与外观，
-- 若当前已有其他拾取条目则自动顺排在其上方，零重叠、全鼠标穿透；停用 EUI 拾取信息时回退到 KkowoUI 播报锚点
local EMPTY_LOOT_ICON = "Interface\\Icons\\INV_Misc_Bag_08"

local function GetEUILootFeedContext()
    local eui = _G.EllesmereUI
    local lf = eui and eui._LootFeed
    if not (lf and type(lf.Get) == "function") then
        return nil, nil
    end
    local okEn, enabled = pcall(lf.Get, "enabled")
    if not (okEn and enabled == true) then
        return nil, nil
    end
    local elems = eui._unlockRegisteredElements
    local elem = elems and elems["EUI_LootFeed"]
    local anchor = nil
    if elem and type(elem.getFrame) == "function" then
        local okF, frame = pcall(elem.getFrame)
        if okF and frame then
            anchor = frame
        end
    end
    return anchor, lf.Get
end

local function ReadFeedOpt(getOpt, key, fallback)
    if not getOpt then return fallback end
    local ok, v = pcall(getOpt, key)
    if ok and v ~= nil then return v end
    return fallback
end

local function CountVisibleEUIFeedRows(feedAnchor, getOpt)
    if not (feedAnchor and feedAnchor.GetChildren) then return 0 end
    local count = 0
    local children = { feedAnchor:GetChildren() }
    for i = 1, #children do
        local ch = children[i]
        if ch and ch.IsShown and ch:IsShown() and not ch.pinned then
            count = count + 1
        end
    end
    local maxRows = F.PlainNumber(ReadFeedOpt(getOpt, "maxRows", 6), 6)
    if count > maxRows then count = maxRows end
    return count
end

local function PositionEmptyLootToast(f, feedAnchor, getOpt)
    local style = ReadFeedOpt(getOpt, "style", "BAR")
    local rowHeight = F.PlainNumber(ReadFeedOpt(getOpt, "rowHeight", 30), 30)
    local spacing = F.PlainNumber(ReadFeedOpt(getOpt, "spacing", 2), 2)
    local gap = spacing + (style == "TOAST" and 2 or 0)
    local step = rowHeight + (style == "TRAY" and spacing or gap)
    local pin = (ReadFeedOpt(getOpt, "tracker", false) == true) and (rowHeight + (style == "TRAY" and 6 or gap)) or 0
    local growUp = ReadFeedOpt(getOpt, "grow", "UP") ~= "DOWN"

    f:ClearAllPoints()
    if feedAnchor then
        local visCount = CountVisibleEUIFeedRows(feedAnchor, getOpt)
        local yOff = pin + visCount * step
        if growUp then
            f:SetPoint("BOTTOMLEFT", feedAnchor, "BOTTOMLEFT", 0, yOff)
        else
            f:SetPoint("TOPLEFT", feedAnchor, "TOPLEFT", 0, -yOff)
        end
        return
    end
    local kToast = _G.KkowoUI_LootToast
    if kToast then
        f:SetPoint("BOTTOMLEFT", kToast, "BOTTOMLEFT", 0, 0)
        return
    end
    local euiDB = _G.EllesmereUIDB
    local pos = euiDB and euiDB.lootFeed and euiDB.lootFeed.pos
    if pos and type(pos.point) == "string" then
        f:SetPoint(pos.point, _G.UIParent, pos.relPoint or pos.point, F.PlainNumber(pos.x, 0), F.PlainNumber(pos.y, 0))
    else
        f:SetPoint("BOTTOMRIGHT", _G.UIParent, "BOTTOMRIGHT", -320, 260)
    end
end

local function StyleEmptyLootToast(f, getOpt)
    local style = ReadFeedOpt(getOpt, "style", "BAR")
    local width = F.PlainNumber(ReadFeedOpt(getOpt, "width", 180), 180)
    local rowHeight = F.PlainNumber(ReadFeedOpt(getOpt, "rowHeight", 30), 30)
    local textSize = F.PlainNumber(ReadFeedOpt(getOpt, "textSize", 13), 13)
    local barWidth = F.PlainNumber(ReadFeedOpt(getOpt, "barWidth", 3), 3)
    local duration = F.PlainNumber(ReadFeedOpt(getOpt, "duration", 3), 3)
    local bgR = F.PlainNumber(ReadFeedOpt(getOpt, "bgR", 0.05), 0.05)
    local bgG = F.PlainNumber(ReadFeedOpt(getOpt, "bgG", 0.05), 0.05)
    local bgB = F.PlainNumber(ReadFeedOpt(getOpt, "bgB", 0.05), 0.05)
    local bgA = F.PlainNumber(ReadFeedOpt(getOpt, "bgA", 0.30), 0.30)

    if width < 130 then width = 130 end
    if rowHeight < 22 then rowHeight = 22 end
    f:SetSize(width, rowHeight)

    local isBar = (style == "BAR")
    local showBar = isBar and barWidth > 0
    f.bar:SetWidth(showBar and barWidth or 1)
    f.bar:SetShown(showBar)
    f.bar:SetColorTexture(0.68, 0.72, 0.78, 1)

    local iconSize = rowHeight - 8
    if iconSize < 14 then iconSize = 14 end
    f.icon:ClearAllPoints()
    f.icon:SetSize(iconSize, iconSize)
    f.icon:SetPoint("LEFT", f, "LEFT", showBar and (barWidth + 5) or 5, 0)

    local bgTexKey = ReadFeedOpt(getOpt, "bgTexture", "none")
    local eui = _G.EllesmereUI
    if bgTexKey ~= "none" and eui and eui.BuildBarTextureTables and eui.ResolveTexturePath then
        local okT, tbl = pcall(eui.BuildBarTextureTables)
        local okP, path = false, nil
        if okT and tbl then
            okP, path = pcall(eui.ResolveTexturePath, tbl, bgTexKey, "Interface\\Buttons\\WHITE8x8")
        end
        if okP and type(path) == "string" and path ~= "" then
            f.bg:SetTexture(path)
            f.bg:SetVertexColor(1, 1, 1, 1)
        else
            f.bg:SetColorTexture(1, 1, 1, 1)
        end
    else
        f.bg:SetColorTexture(1, 1, 1, 1)
    end
    if _G.CreateColor and f.bg.SetGradient then
        if not emptyGradFrom then
            emptyGradFrom = _G.CreateColor(0, 0, 0, 0)
            emptyGradTo = _G.CreateColor(0, 0, 0, 0)
        end
        emptyGradFrom:SetRGBA(bgR, bgG, bgB, bgA)
        emptyGradTo:SetRGBA(bgR, bgG, bgB, isBar and 0 or bgA)
        f.bg:SetGradient("HORIZONTAL", emptyGradFrom, emptyGradTo)
    else
        f.bg:SetColorTexture(bgR, bgG, bgB, bgA)
    end

    if eui and eui.ApplyModuleFont then
        pcall(eui.ApplyModuleFont, f.name, nil, textSize, "essentials")
    else
        F.Theme.SetFont(f.name, textSize, "")
    end

    local hold = duration > 2.5 and 2.5 or (duration < 0.8 and 0.8 or duration)
    if f.fade and f.fade.alpha then
        f.fade.alpha:SetStartDelay(hold)
    end
end

local function EnsureEmptyLootToast()
    if emptyToastFrame then return emptyToastFrame end
    local f = CreateFrame("Frame", "KkowoUI_EmptyLootToast", _G.UIParent)
    f:SetFrameStrata("MEDIUM")
    f:EnableMouse(false)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()

    f.bar = f:CreateTexture(nil, "ARTWORK")
    f.bar:SetPoint("TOPLEFT")
    f.bar:SetPoint("BOTTOMLEFT")

    f.iconBg = f:CreateTexture(nil, "ARTWORK", nil, 0)
    f.iconBg:SetColorTexture(0, 0, 0, 1)

    f.icon = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.icon:SetTexture(EMPTY_LOOT_ICON)
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if f.icon.SetDesaturated then pcall(f.icon.SetDesaturated, f.icon, true) end
    f.icon:SetVertexColor(0.80, 0.83, 0.88)

    f.iconBg:SetPoint("TOPLEFT", f.icon, "TOPLEFT", -1, 1)
    f.iconBg:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT", 1, -1)

    f.name = f:CreateFontString(nil, "OVERLAY")
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)
    f.name:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
    f.name:SetPoint("RIGHT", f, "RIGHT", -8, 0)

    local showAG = f:CreateAnimationGroup()
    local jump = showAG:CreateAnimation("Translation")
    jump:SetOrder(1)
    jump:SetDuration(0)
    jump:SetOffset(-24, 0)
    local glide = showAG:CreateAnimation("Translation")
    glide:SetOrder(2)
    glide:SetDuration(0.35)
    glide:SetSmoothing("OUT")
    glide:SetOffset(24, 0)
    local appear = showAG:CreateAnimation("Alpha")
    appear:SetOrder(2)
    appear:SetDuration(0.35)
    appear:SetSmoothing("OUT")
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    showAG:SetScript("OnFinished", function()
        f:SetAlpha(1)
        f.fade:Play()
    end)
    f.show = showAG

    local fadeAG = f:CreateAnimationGroup()
    local fadeAlpha = fadeAG:CreateAnimation("Alpha")
    fadeAlpha:SetOrder(1)
    fadeAlpha:SetDuration(0.8)
    fadeAlpha:SetSmoothing("IN_OUT")
    fadeAlpha:SetFromAlpha(1)
    fadeAlpha:SetToAlpha(0)
    fadeAG.alpha = fadeAlpha
    fadeAG:SetScript("OnFinished", function()
        f:Hide()
        emptyToastCount = 0
    end)
    f.fade = fadeAG

    f:Hide()
    emptyToastFrame = f
    return f
end

local function ScheduleEmptyToastReposition()
    if emptyToastRepositionPending or not (emptyToastFrame and emptyToastFrame:IsShown()) then
        return
    end
    emptyToastRepositionPending = true
    C_Timer.After(0, function()
        emptyToastRepositionPending = false
        if emptyToastFrame and emptyToastFrame:IsShown() then
            local feedAnchor, getOpt = GetEUILootFeedContext()
            if feedAnchor then
                PositionEmptyLootToast(emptyToastFrame, feedAnchor, getOpt)
            end
        end
    end)
end

local function ShowEmptyLootToast()
    if not (mod._active and mod:GetDB().showEmptyLoot ~= false) then return end
    local now = _G.GetTime()
    if (now - lastEmptyToastTime) < 0.25 then return end
    lastEmptyToastTime = now

    local f = EnsureEmptyLootToast()
    local feedAnchor, getOpt = GetEUILootFeedContext()
    StyleEmptyLootToast(f, getOpt)
    PositionEmptyLootToast(f, feedAnchor, getOpt)

    local wasShown = f:IsShown()
    emptyToastCount = wasShown and (emptyToastCount + 1) or 1
    if emptyToastCount > 1 then
        f.name:SetText(string_format("%dx |cffd4d8df空包裹|r", emptyToastCount))
    else
        f.name:SetText("|cffd4d8df空包裹|r")
    end

    if not wasShown then
        f.fade:Stop()
        f:SetAlpha(0)
        f:Show()
        f.show:Play()
    else
        f.fade:Stop()
        if not f.show:IsPlaying() then
            f:SetAlpha(1)
            f.fade:Play()
        end
    end
end

local function NotifyEmptyLootOnce()
    if notifiedEmptyThisOpen then return end
    notifiedEmptyThisOpen = true
    ShowEmptyLootToast()
end

local function ScheduleEmptyLootCloseCheck()
    local myToken = lootRevealToken
    C_Timer.After(0.03, function()
        if myToken ~= lootRevealToken or not isSilentLooting then return end
        local rawNum = _G.GetNumLootItems and F.PlainNumber(_G.GetNumLootItems(), 0) or 0
        if rawNum <= 0 or (not sawAnyLootThisOpen and CountRemainingLootSlots() <= 0) then
            NotifyEmptyLootOnce()
            CloseLootSafely()
        end
    end)
end

local function HandleLootTrigger(_, event, autoLoot)
    if not (mod._active and mod:GetDB().silentFastLoot ~= false) then return end
    HookLootFrameOnce()

    local rawNum = _G.GetNumLootItems and F.PlainNumber(_G.GetNumLootItems(), 0) or 0
    local rem = rawNum > 0 and CountRemainingLootSlots() or 0
    if rem > 0 then
        sawAnyLootThisOpen = true
    end
    local isEmptyLoot = (rawNum <= 0) or (rem <= 0 and not sawAnyLootThisOpen)

    if event == "LOOT_OPENED" then
        if not isSilentLooting then
            local wantAuto = ResolveWantAuto(autoLoot)
            -- 空包裹时暴雪常以 autoLoot=false 触发事件：只要玩家未按住 Shift（或右键拾取），绝不显窗闪烁
            if not wantAuto and isEmptyLoot and ResolveWantAuto(nil) then
                wantAuto = true
            end
            if not wantAuto then
                RevealLootWindow(true)
                return
            end
            manualLootThisOpen = false
            isSilentLooting = true
        end
        SetLootFrameSilent(true)
        if rem <= 0 then
            if isEmptyLoot then
                NotifyEmptyLootOnce()
            end
            CloseLootSafely()
            return
        end
        local now = _G.GetTime()
        local hadSweptBefore = lootSweptThisOpen
        local swept = SweepLootSlots(true, false, true)
        if swept > 0 then
            lootSweptThisOpen = true
            if not hadSweptBefore then
                ArmSilentLootFallback()
            else
                EnsureSilentLootFallback(now)
            end
        else
            EnsureSilentLootFallback(now)
        end
        return
    end

    if event ~= "LOOT_READY" then return end

    local wantAuto = ResolveWantAuto(autoLoot)
    if not wantAuto and isEmptyLoot and ResolveWantAuto(nil) then
        wantAuto = true
    end
    if not wantAuto then
        RevealLootWindow(true)
        return
    end

    manualLootThisOpen = false
    isSilentLooting = true
    SetLootFrameSilent(true)

    local now = _G.GetTime()
    local hadSweptBefore = lootSweptThisOpen
    local swept = SweepLootSlots(true, false, false)
    if swept > 0 then
        lootSweptThisOpen = true
        if not hadSweptBefore then
            ArmSilentLootFallback()
        else
            EnsureSilentLootFallback(now)
        end
    else
        if CountRemainingLootSlots() <= 0 then
            if hadSweptBefore then
                ScheduleSilentCloseCheck()
            else
                -- 服务端尚未下发或空包裹：保持离屏静默（防闪窗），若到 LOOT_OPENED 或 30ms 后仍为空则直接关闭并播报「空包裹」
                EnsureSilentLootFallback(now)
                ScheduleEmptyLootCloseCheck()
            end
        else
            EnsureSilentLootFallback(now)
        end
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
    -- 背包/邮箱等框体可能早于本模块创建，启用时先统一对齐一次
    if db.alignBagMoney then
        AlignKnownMoneyFrames()
    end
    HookLootFrameOnce()
    PreArmSilentLoot()
    DisableSlowEUIQuickLoot()
    C_Timer.After(1.5, DisableSlowEUIQuickLoot)

    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if db.alignBagMoney then
            AlignKnownMoneyFrames()
        end
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
    self:RegisterEvent("LOOT_SLOT_CLEARED", function(_, _, slot)
        local cleanSlot = F.PlainNumber(slot, nil)
        if cleanSlot then
            sweptSlots[cleanSlot] = nil
            retriedCoinOnOpen[cleanSlot] = nil
        end
        if isSilentLooting then
            -- 已停到屏外时无需每个槽位都重做 ~20 次窗口 API 调用（AoE 一次拾 15 件时尤为明显）
            if not lootParked then SetLootFrameSilent(true) end
            ScheduleSilentCloseCheck()
        end
    end)
    self:RegisterEvent("LOOT_BIND_CONFIRM", function() RevealLootWindow(true) end)
    self:RegisterEvent("LOOT_CLOSED", ResetSilentLootOnClose)
    self:RegisterEvent("CHAT_MSG_LOOT", ScheduleEmptyToastReposition)
    self:RegisterEvent("CHAT_MSG_MONEY", ScheduleEmptyToastReposition)
    self:RegisterEvent("CURRENCY_DISPLAY_UPDATE", ScheduleEmptyToastReposition)
    self:RegisterEvent("CVAR_UPDATE", function(_, _, cvarName)
        if cvarName == "autoLootDefault" then
            if WantPersistentPreArm() then
                PreArmSilentLoot()
            elseif not isSilentLooting then
                lootPreArmed = false
                SetLootFrameSilent(false)
            end
        end
    end)
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
    if emptyToastFrame then
        emptyToastFrame.show:Stop()
        emptyToastFrame.fade:Stop()
        emptyToastFrame:Hide()
        emptyToastCount = 0
    end
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
    }, {
        type = "toggle",
        text = "空包裹在拾取信息区提示",
        tooltip = "怪物掉落空包裹时静默秒关防闪窗，并在 EUI 拾取信息位置以同风格微条提示「空包裹」。",
        getValue = function() return db.showEmptyLoot ~= false end,
        setValue = function(v)
            db.showEmptyLoot = v == true
            if not v and emptyToastFrame then
                emptyToastFrame.show:Stop()
                emptyToastFrame.fade:Stop()
                emptyToastFrame:Hide()
                emptyToastCount = 0
            end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "对齐背包/邮箱/商人金币数字",
        tooltip = "无侵入式钩子自动将背包、邮箱、商人、银行等界面的金币数字与金/银/铜币图标垂直居中对齐。",
        getValue = function() return db.alignBagMoney ~= false end,
        setValue = function(v)
            db.alignBagMoney = v == true
            AlignKnownMoneyFrames(db.alignBagMoney and MONEY_TEXT_Y_OFFSET or 0)
        end,
    }, {
        type = "toggle",
        text = "放大宏编辑窗口",
        tooltip = "打开 /macro 时自动放大界面，方便查看和编辑长宏；同时收小宏名、按钮与输入框字号，避免文字和按钮重叠（关闭后 /reload 恢复原样）。",
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
