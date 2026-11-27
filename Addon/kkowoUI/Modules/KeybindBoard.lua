----------------------------------------------------------------------
--  kkowoUI — Modules/KeybindBoard.lua
--  kkowoUI 可视化实体键盘拖拽绑键器（/kkkeys 或 EUI 设置入口打开）：
--    • 暗黑极简圆角界面，支持 60% / 75% / TKL / 全尺寸 键盘布局切换
--    • 顶部 常规 / SHIFT / CTRL / ALT / 组合 修饰键页签 + 常用鼠标滚轮与侧键
--    • 底部同步展示关联动作条槽位，支持直接从法术书、宏、背包或动作条拖拽至虚拟按键完成绑键
--    • 悬停显示原生技能/宏/绑定提示，右键一键解绑，战斗中自动锁定防 Taint
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, pairs, pcall, select, tostring, type =
    ipairs, math.floor, pairs, pcall, select, tostring, type
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GameTooltip = _G.GameTooltip

local ST = F.StyleTokens

local mod = F.RegisterModule("keybindBoard", {
    title = "可视化键盘拖拽绑键器（/kkkeys）",
    desc = "直观暗黑实体键盘布局，支持切换修饰键页签、直接从法术书/宏/动作条拖拽技能图标到虚拟按键绑键、右键一键解绑，战斗中自动锁定。",
    group = "motion",
    order = 45,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        layout = "75",  -- "60" | "75" | "tkl" | "full"
        actionBar = 1,  -- 底部参考动作条编号（1~6）
    },
})

local boardFrame = nil
local currentModPrefix = "" -- "" | "SHIFT-" | "CTRL-" | "ALT-" | "SHIFT-CTRL-" | "SHIFT-ALT-"
local keyButtons = {}
local slotButtons = {}
local modTabButtons = {}
local layoutTabButtons = {}
local barTabButtons = {}
local combatBanner = nil
local inCombat = false

local function IsCombatLocked()
    return inCombat or ((InCombatLockdown and InCombatLockdown()) == true)
end

local MOD_TABS = {
    { prefix = "",            label = "常规" },
    { prefix = "SHIFT-",      label = "SHIFT" },
    { prefix = "CTRL-",       label = "CTRL" },
    { prefix = "ALT-",        label = "ALT" },
    { prefix = "SHIFT-CTRL-", label = "S+C" },
    { prefix = "SHIFT-ALT-",  label = "S+A" },
}

local LAYOUT_TABS = {
    { id = "60",   label = "60%" },
    { id = "75",   label = "75%" },
    { id = "tkl",  label = "TKL" },
    { id = "full", label = "全尺寸" },
}

-- 动作条命令与槽位区间映射（标准 WoW 动作条映射，兼容 EUI ActionBars）
local BAR_SPECS = {
    { id = 1, label = "主动作条",   startSlot = 1,  cmdPrefix = "ACTIONBUTTON" },
    { id = 2, label = "左下动作条", startSlot = 61, cmdPrefix = "MULTIACTIONBAR1BUTTON" },
    { id = 3, label = "右下动作条", startSlot = 49, cmdPrefix = "MULTIACTIONBAR2BUTTON" },
    { id = 4, label = "右侧动作条1", startSlot = 25, cmdPrefix = "MULTIACTIONBAR3BUTTON" },
    { id = 5, label = "右侧动作条2", startSlot = 37, cmdPrefix = "MULTIACTIONBAR4BUTTON" },
    { id = 6, label = "动作条6",    startSlot = 145, cmdPrefix = "MULTIACTIONBAR5BUTTON" },
}

-- 实体键盘行定义：{ key = WoW按键名, label = 显示字, w = 相对键宽 }
local ROW_FUNC = {
    { key = "F1",  label = "F1",  w = 1 }, { key = "F2",  label = "F2",  w = 1 },
    { key = "F3",  label = "F3",  w = 1 }, { key = "F4",  label = "F4",  w = 1 },
    { key = "F5",  label = "F5",  w = 1 }, { key = "F6",  label = "F6",  w = 1 },
    { key = "F7",  label = "F7",  w = 1 }, { key = "F8",  label = "F8",  w = 1 },
    { key = "F9",  label = "F9",  w = 1 }, { key = "F10", label = "F10", w = 1 },
    { key = "F11", label = "F11", w = 1 }, { key = "F12", label = "F12", w = 1 },
}

local KEY_ROWS = {
    {
        { key = "`", label = "~", w = 1 }, { key = "1", label = "1", w = 1 },
        { key = "2", label = "2", w = 1 }, { key = "3", label = "3", w = 1 },
        { key = "4", label = "4", w = 1 }, { key = "5", label = "5", w = 1 },
        { key = "6", label = "6", w = 1 }, { key = "7", label = "7", w = 1 },
        { key = "8", label = "8", w = 1 }, { key = "9", label = "9", w = 1 },
        { key = "0", label = "0", w = 1 }, { key = "-", label = "-", w = 1 },
        { key = "=", label = "=", w = 1 }, { key = "BACKSPACE", label = "BS", w = 1.6 },
    },
    {
        { key = "TAB", label = "TAB", w = 1.4 }, { key = "Q", label = "Q", w = 1 },
        { key = "W", label = "W", w = 1 }, { key = "E", label = "E", w = 1 },
        { key = "R", label = "R", w = 1 }, { key = "T", label = "T", w = 1 },
        { key = "Y", label = "Y", w = 1 }, { key = "U", label = "U", w = 1 },
        { key = "I", label = "I", w = 1 }, { key = "O", label = "O", w = 1 },
        { key = "P", label = "P", w = 1 }, { key = "[", label = "[", w = 1 },
        { key = "]", label = "]", w = 1 }, { key = "\\", label = "\\", w = 1.2 },
    },
    {
        { key = "CAPSLOCK", label = "CAPS", w = 1.7 }, { key = "A", label = "A", w = 1 },
        { key = "S", label = "S", w = 1 }, { key = "D", label = "D", w = 1 },
        { key = "F", label = "F", w = 1 }, { key = "G", label = "G", w = 1 },
        { key = "H", label = "H", w = 1 }, { key = "J", label = "J", w = 1 },
        { key = "K", label = "K", w = 1 }, { key = "L", label = "L", w = 1 },
        { key = ";", label = ";", w = 1 }, { key = "'", label = "'", w = 1 },
        { key = "ENTER", label = "ENT", w = 1.9 },
    },
    {
        { key = "Z", label = "Z", w = 1, offsetX = 1.2 },
        { key = "X", label = "X", w = 1 }, { key = "C", label = "C", w = 1 },
        { key = "V", label = "V", w = 1 }, { key = "B", label = "B", w = 1 },
        { key = "N", label = "N", w = 1 }, { key = "M", label = "M", w = 1 },
        { key = ",", label = ",", w = 1 }, { key = ".", label = ".", w = 1 },
        { key = "/", label = "/", w = 1 },
    },
}

local MOUSE_KEYS = {
    { key = "MOUSEWHEELUP",   label = "滚轮上", w = 1.6 },
    { key = "MOUSEWHEELDOWN", label = "滚轮下", w = 1.6 },
    { key = "BUTTON3",        label = "中键",   w = 1.4 },
    { key = "BUTTON4",        label = "侧键4",  w = 1.5 },
    { key = "BUTTON5",        label = "侧键5",  w = 1.5 },
    { key = "SPACE",          label = "SPACE",  w = 2.6 },
}

local NUMPAD_KEYS = {
    { key = "NUMPAD7", label = "N7" }, { key = "NUMPAD8", label = "N8" }, { key = "NUMPAD9", label = "N9" },
    { key = "NUMPAD4", label = "N4" }, { key = "NUMPAD5", label = "N5" }, { key = "NUMPAD6", label = "N6" },
    { key = "NUMPAD1", label = "N1" }, { key = "NUMPAD2", label = "N2" }, { key = "NUMPAD3", label = "N3" },
    { key = "NUMPAD0", label = "N0" }, { key = "NUMPADDECIMAL", label = "N." }, { key = "NUMPADPLUS", label = "N+" },
}

----------------------------------------------------------------------
--  动作命令 <-> 槽位/图标解析
----------------------------------------------------------------------
local CMD_TO_SLOT = {}
for _, b in ipairs(BAR_SPECS) do
    for i = 1, 12 do
        CMD_TO_SLOT[b.cmdPrefix .. i] = b.startSlot + i - 1
    end
end

local function SaveCurrentBindings()
    if IsCombatLocked() then return end
    if _G.SaveBindings and _G.GetCurrentBindingSet then
        pcall(_G.SaveBindings, _G.GetCurrentBindingSet())
    end
end

local function ResolveBindingInfo(cmd)
    if not cmd or cmd == "" then return nil, nil, nil end
    local slot = CMD_TO_SLOT[cmd]
    if slot and _G.GetActionTexture then
        local tex = _G.GetActionTexture(slot)
        local kind, id
        if _G.GetActionInfo then kind, id = _G.GetActionInfo(slot) end
        return tex, "action", slot, kind, id
    end
    local spellName = cmd:match("^SPELL (.+)$")
    if spellName then
        local tex
        if _G.C_Spell and _G.C_Spell.GetSpellTexture then
            local ok, t = pcall(_G.C_Spell.GetSpellTexture, spellName)
            if ok then tex = t end
        elseif _G.GetSpellTexture then
            local ok, t = pcall(_G.GetSpellTexture, spellName)
            if ok then tex = t end
        end
        return tex, "spell", spellName
    end
    local macroName = cmd:match("^MACRO (.+)$")
    if macroName and _G.GetMacroInfo then
        local ok, _, tex = pcall(_G.GetMacroInfo, macroName)
        return ok and tex or 134400, "macro", macroName
    end
    local itemName = cmd:match("^ITEM (.+)$")
    if itemName then
        local tex
        if _G.C_Item and _G.C_Item.GetItemIconByID then
            local ok, t = pcall(_G.C_Item.GetItemIconByID, itemName)
            if ok then tex = t end
        end
        return tex or 134400, "item", itemName
    end
    return nil, "command", cmd
end

local function GetKeyFriendlyLabel(cmd)
    if not cmd or cmd == "" then return "未绑定" end
    local gName = _G["BINDING_NAME_" .. cmd]
    if type(gName) == "string" and gName ~= "" then return gName end
    return cmd
end

local RefreshAllKeys -- 前向声明

local function HandleDropOnKey(btn)
    if IsCombatLocked() then
        F.Print("|cffff5555战斗中已锁定键位修改，脱战后再拖放绑定。|r")
        return
    end
    local cursorType, a1, a2, a3
    if _G.GetCursorInfo then cursorType, a1, a2, a3 = _G.GetCursorInfo() end
    if not cursorType then return end

    local fullKey = currentModPrefix .. btn._baseKey
    local bound = false

    if cursorType == "spell" then
        local spellID = a3
        if (not spellID) and _G.C_SpellBook and _G.C_SpellBook.GetSpellBookItemInfo then
            local bank = (a2 == "pet" and _G.Enum and _G.Enum.SpellBookSpellBank and _G.Enum.SpellBookSpellBank.Pet)
                or (_G.Enum and _G.Enum.SpellBookSpellBank and _G.Enum.SpellBookSpellBank.Player)
            local ok, info = pcall(_G.C_SpellBook.GetSpellBookItemInfo, a1, bank)
            if ok and type(info) == "table" then spellID = info.actionID or info.spellID end
        elseif (not spellID) and _G.GetSpellBookItemInfo then
            local ok, _, id = pcall(_G.GetSpellBookItemInfo, a1, a2 or "spell")
            if ok then spellID = id end
        end
        local spellName
        if spellID and _G.C_Spell and _G.C_Spell.GetSpellName then
            local ok, nm = pcall(_G.C_Spell.GetSpellName, spellID)
            if ok then spellName = F.PlainString(nm, nil) end
        elseif spellID and _G.GetSpellInfo then
            local ok, nm = pcall(_G.GetSpellInfo, spellID)
            if ok then spellName = F.PlainString(nm, nil) end
        end
        if spellName and _G.SetBindingSpell then
            local ok, res = pcall(_G.SetBindingSpell, fullKey, spellName)
            bound = (ok and res ~= false)
        end
    elseif cursorType == "macro" then
        local mName = _G.GetMacroInfo and select(1, _G.GetMacroInfo(a1)) or nil
        if mName and _G.SetBindingMacro then
            local ok, res = pcall(_G.SetBindingMacro, fullKey, mName)
            bound = (ok and res ~= false)
        end
    elseif cursorType == "item" then
        local itemName
        if a1 and _G.C_Item and _G.C_Item.GetItemNameByID then
            local ok, nm = pcall(_G.C_Item.GetItemNameByID, a1)
            if ok then itemName = F.PlainString(nm, nil) end
        end
        if not itemName and a1 and _G.C_Item and _G.C_Item.GetItemInfo then
            local ok, nm = pcall(_G.C_Item.GetItemInfo, a1)
            if ok then itemName = F.PlainString(nm, nil) end
        end
        if not itemName and type(a2) == "string" then
            itemName = a2:match("%[(.-)%]") or a2
        end
        if itemName and itemName ~= "" and _G.SetBindingItem then
            local ok, res = pcall(_G.SetBindingItem, fullKey, itemName)
            bound = (ok and res ~= false)
        end
    elseif cursorType == "petaction" then
        if _G.SetBinding and a1 then
            local ok, res = pcall(_G.SetBinding, fullKey, "BONUSACTIONBUTTON" .. tostring(a1))
            bound = (ok and res ~= false)
        end
    end

    if bound then
        if _G.ClearCursor then pcall(_G.ClearCursor) end
        SaveCurrentBindings()
        RefreshAllKeys()
        F.Print("已绑定按键 |cff52d669" .. fullKey .. "|r。")
    end
end

local function BindSlotToKey(slotCmd, btn)
    if IsCombatLocked() then return end
    local fullKey = currentModPrefix .. btn._baseKey
    if _G.SetBinding then
        local ok, res = pcall(_G.SetBinding, fullKey, slotCmd)
        if ok and res ~= false then
            SaveCurrentBindings()
            RefreshAllKeys()
            F.Print("已将 |cff52d669" .. fullKey .. "|r 绑定至动作槽 " .. tostring(slotCmd) .. "。")
        end
    end
end

local pendingSlotCmd = nil

local function StylePillBtn(b, active)
    local r, g, bCol = F.Theme.GetAccent()
    if active then
        b._bg:SetColorTexture(r * 0.28 + 0.06, g * 0.28 + 0.06, bCol * 0.28 + 0.08, 0.96)
        ST.ApplyRoundedBorder(b, 5, r, g, bCol, 0.95, 4)
        b._label:SetTextColor(1, 1, 1, 1)
    else
        b._bg:SetColorTexture(0.08, 0.09, 0.11, 0.88)
        ST.ApplyRoundedBorder(b, 5, 0.22, 0.24, 0.28, 0.85, 4)
        b._label:SetTextColor(0.76, 0.80, 0.86, 1)
    end
end

local function CreateKeyButton(parent, baseKey, label, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b._baseKey = baseKey
    b._shortLabel = label
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local bg = b:CreateTexture(nil, "BACKGROUND", nil, -4)
    bg:SetAllPoints()
    bg:SetColorTexture(0.075, 0.082, 0.105, 0.92)
    ST.MaskTexture(b, bg, 5)
    b._bg = bg

    local icon = b:CreateTexture(nil, "ARTWORK", nil, 1)
    icon:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ST.MaskIcon(b, icon, 5)
    icon:Hide()
    b._icon = icon

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    ST.MaskTexture(b, hl, 5)

    local lbl = b:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(lbl, 10, "OUTLINE", 0.92, 0.95, 0.98, 1)
    lbl:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -2)
    lbl:SetText(label)
    b._label = lbl

    local sub = b:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(sub, 9, "OUTLINE", 0.72, 0.78, 0.86, 0.90)
    sub:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    sub:SetJustifyH("RIGHT")
    sub:SetWidth(w - 4)
    sub:SetWordWrap(false)
    if sub.SetMaxLines then sub:SetMaxLines(1) end
    b._sub = sub

    b:SetScript("OnReceiveDrag", function(self)
        HandleDropOnKey(self)
    end)

    b:SetScript("OnClick", function(self, mouseBtn)
        if IsCombatLocked() then
            F.Print("|cffff5555战斗中已锁定键位编辑，脱战后可继续调整。|r")
            return
        end
        if mouseBtn == "RightButton" then
            local fullKey = currentModPrefix .. self._baseKey
            if _G.SetBinding then
                local ok, res = pcall(_G.SetBinding, fullKey)
                if ok and res ~= false then
                    SaveCurrentBindings()
                    RefreshAllKeys()
                    F.Print("已解绑按键 |cffe05263" .. fullKey .. "|r。")
                end
            end
            return
        end
        if _G.GetCursorInfo and _G.GetCursorInfo() then
            HandleDropOnKey(self)
        elseif pendingSlotCmd then
            local cmd = pendingSlotCmd
            pendingSlotCmd = nil
            BindSlotToKey(cmd, self)
        end
    end)

    b:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        local fullKey = currentModPrefix .. self._baseKey
        local cmd = _G.GetBindingAction and _G.GetBindingAction(fullKey, true) or nil
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT", 6, 0)
        if cmd and cmd ~= "" then
            local _, kind, target = ResolveBindingInfo(cmd)
            if kind == "action" and GameTooltip.SetAction then
                pcall(GameTooltip.SetAction, GameTooltip, target)
                GameTooltip:AddLine(" ")
            elseif kind == "spell" and GameTooltip.SetSpellByID and _G.C_Spell and _G.C_Spell.GetSpellIDForSpellIdentifier then
                local ok, sid = pcall(_G.C_Spell.GetSpellIDForSpellIdentifier, target)
                if ok and sid then pcall(GameTooltip.SetSpellByID, GameTooltip, sid); GameTooltip:AddLine(" ") end
            else
                GameTooltip:SetText(GetKeyFriendlyLabel(cmd), 1, 1, 1)
            end
            GameTooltip:AddDoubleLine("按键", fullKey, 0.65, 0.70, 0.78, 0.32, 0.84, 0.41)
            GameTooltip:AddDoubleLine("当前命令", cmd, 0.65, 0.70, 0.78, 0.88, 0.90, 0.95)
            GameTooltip:AddLine("拖入法术/宏/物品覆盖 · 右键一键解绑", 0.56, 0.62, 0.70)
        else
            GameTooltip:SetText("按键：" .. fullKey, 1, 1, 1)
            GameTooltip:AddLine("当前未绑定", 0.62, 0.66, 0.72)
            GameTooltip:AddLine("直接从法术书、宏或下方动作条拖放至此完成绑键", 0.32, 0.84, 0.41)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    return b
end

local function RebuildKeyboardGrid()
    if not boardFrame then return end
    for _, b in ipairs(keyButtons) do b:Hide() end
    local poolIdx = 0
    local function Acquire(baseKey, label, w, h)
        poolIdx = poolIdx + 1
        local b = keyButtons[poolIdx]
        if not b then
            b = CreateKeyButton(boardFrame._keyArea, baseKey, label, w, h)
            keyButtons[poolIdx] = b
        else
            b._baseKey = baseKey
            b._shortLabel = label
            b:SetSize(w, h)
            b._label:SetText(label)
            b._sub:SetWidth(w - 4)
        end
        b:Show()
        return b
    end

    local db = mod:GetDB()
    local layout = db.layout or "75"
    local unit = 42
    local gap = 4
    local y = 0

    if layout ~= "60" then
        for i, spec in ipairs(ROW_FUNC) do
            local b = Acquire(spec.key, spec.label, unit, 32)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", boardFrame._keyArea, "TOPLEFT", (i - 1) * (unit + gap), -y)
        end
        y = y + 38
    end

    for _, row in ipairs(KEY_ROWS) do
        local x = 0
        for _, spec in ipairs(row) do
            if spec.offsetX then x = x + spec.offsetX * (unit + gap) end
            local bw = math_floor(spec.w * unit + (spec.w - 1) * gap)
            local b = Acquire(spec.key, spec.label, bw, unit)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", boardFrame._keyArea, "TOPLEFT", x, -y)
            x = x + bw + gap
        end
        y = y + unit + gap
    end

    -- 鼠标侧键 / 滚轮 / 空格行
    y = y + 4
    local mx = 0
    for _, spec in ipairs(MOUSE_KEYS) do
        local bw = math_floor(spec.w * unit + (spec.w - 1) * gap)
        local b = Acquire(spec.key, spec.label, bw, 34)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", boardFrame._keyArea, "TOPLEFT", mx, -y)
        mx = mx + bw + gap
    end

    -- 全尺寸显示右侧小键盘
    if layout == "full" then
        local npX = 14.8 * (unit + gap) + 10
        local npY = 38
        for idx, spec in ipairs(NUMPAD_KEYS) do
            local col = (idx - 1) % 3
            local row = math_floor((idx - 1) / 3)
            local b = Acquire(spec.key, spec.label, unit, unit)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", boardFrame._keyArea, "TOPLEFT", npX + col * (unit + gap), -(npY + row * (unit + gap)))
        end
        boardFrame:SetSize(862, 424)
    elseif layout == "60" then
        boardFrame:SetSize(692, 386)
    else
        boardFrame:SetSize(692, 424)
    end
end

RefreshAllKeys = function()
    if not (boardFrame and boardFrame:IsShown()) then return end
    local ar, ag, ab = F.Theme.GetAccent()
    local locked = IsCombatLocked()
    if combatBanner then combatBanner:SetShown(locked) end

    for _, t in ipairs(modTabButtons) do StylePillBtn(t, t._prefix == currentModPrefix) end
    local curLayout = mod:GetDB().layout or "75"
    for _, t in ipairs(layoutTabButtons) do StylePillBtn(t, t._layout == curLayout) end
    local curBar = mod:GetDB().actionBar or 1
    for _, t in ipairs(barTabButtons) do StylePillBtn(t, t._barId == curBar) end

    for _, b in ipairs(keyButtons) do
        if b:IsShown() then
            local fullKey = currentModPrefix .. b._baseKey
            local cmd = _G.GetBindingAction and _G.GetBindingAction(fullKey, true) or nil
            if cmd and cmd ~= "" then
                local tex = ResolveBindingInfo(cmd)
                if tex then
                    b._icon:SetTexture(tex)
                    b._icon:Show()
                    b._sub:SetText("")
                    ST.ApplyRoundedBorder(b, 5, ar * 0.85, ag * 0.85, ab * 0.85, 0.94, 4)
                else
                    b._icon:Hide()
                    b._sub:SetText(GetKeyFriendlyLabel(cmd))
                    ST.ApplyRoundedBorder(b, 5, 0.34, 0.38, 0.46, 0.88, 4)
                end
            else
                b._icon:Hide()
                b._sub:SetText("")
                ST.ApplyRoundedBorder(b, 5, 0.16, 0.18, 0.22, 0.78, 4)
            end
        end
    end

    -- 刷新底部动作条槽位参考条
    local spec = BAR_SPECS[curBar] or BAR_SPECS[1]
    for i = 1, 12 do
        local sb = slotButtons[i]
        if sb then
            local slot = spec.startSlot + i - 1
            local cmd = spec.cmdPrefix .. i
            sb._slot = slot
            sb._cmd = cmd
            local tex = _G.GetActionTexture and _G.GetActionTexture(slot) or nil
            if tex then
                sb._icon:SetTexture(tex)
                sb._icon:Show()
            else
                sb._icon:Hide()
            end
            local keyStr = _G.GetBindingKey and _G.GetBindingKey(cmd) or nil
            sb._keyFS:SetText(keyStr and keyStr:gsub("SHIFT%-", "S"):gsub("CTRL%-", "C"):gsub("ALT%-", "A") or "")
            local isSel = (pendingSlotCmd == cmd)
            ST.ApplyRoundedBorder(sb, 5, isSel and ar or 0.20, isSel and ag or 0.22, isSel and ab or 0.28, isSel and 1 or 0.85, 4)
        end
    end
end

local function BuildBoard()
    if boardFrame then return end
    local f = CreateFrame("Frame", "kkowoUI_KeybindBoard", _G.UIParent)
    f:SetSize(692, 424)
    f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 20)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(40)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:HookScript("OnHide", function(self) self:StopMovingOrSizing() end)
    F.Theme.RegisterEscapeClose(f)

    F.Theme.PaintPrettyCardOverlay(f, 0.322, 0.839, 0.412, 36, {
        alpha = 0.95, haloAlpha = 0.22,
    })

    -- 标题栏
    local logo = f:CreateTexture(nil, "OVERLAY")
    logo:SetSize(18, 18)
    logo:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -11)
    logo:SetTexture(ST.TEX.LOGO_FLAT)

    local title = f:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(title, 14, "OUTLINE", 0.96, 0.98, 0.99, 1)
    title:SetPoint("LEFT", logo, "RIGHT", 7, 0)
    title:SetText("kkowoUI 可视化键位图  |cff9aa3b2（拖放技能/宏至按键 · 右键解绑）|r")

    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -9)
    local closeIcon = closeBtn:CreateTexture(nil, "ARTWORK")
    closeIcon:SetSize(12, 12)
    closeIcon:SetPoint("CENTER")
    closeIcon:SetTexture(F.MEDIA .. "Icons\\Close.tga")
    closeIcon:SetVertexColor(0.82, 0.86, 0.90, 0.9)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- 修饰键页签（左上）
    local function MakeTab(x, y, w, h, text)
        local b = CreateFrame("Button", nil, f)
        b:SetSize(w, h)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        ST.MaskTexture(b, bg, 5)
        b._bg = bg
        local lbl = b:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(lbl, 11, "", 0.9, 0.92, 0.95, 1)
        lbl:SetPoint("CENTER")
        lbl:SetText(text)
        b._label = lbl
        return b
    end

    for i, mt in ipairs(MOD_TABS) do
        local tb = MakeTab(14 + (i - 1) * 62, -40, 58, 22, mt.label)
        tb._prefix = mt.prefix
        tb:SetScript("OnClick", function()
            currentModPrefix = mt.prefix
            RefreshAllKeys()
        end)
        modTabButtons[i] = tb
    end

    -- 键盘尺寸页签（右上）
    for i, lt in ipairs(LAYOUT_TABS) do
        local tb = MakeTab(432 + (i - 1) * 60, -40, 56, 22, lt.label)
        tb._layout = lt.id
        tb:SetScript("OnClick", function()
            mod:GetDB().layout = lt.id
            RebuildKeyboardGrid()
            RefreshAllKeys()
        end)
        layoutTabButtons[i] = tb
    end

    -- 战斗锁定提示条（置于键位按钮之上）
    combatBanner = CreateFrame("Frame", nil, f)
    combatBanner:SetFrameLevel(f:GetFrameLevel() + 20)
    combatBanner:SetHeight(20)
    combatBanner:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -66)
    combatBanner:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -66)
    local cbBg = combatBanner:CreateTexture(nil, "BACKGROUND")
    cbBg:SetAllPoints()
    cbBg:SetColorTexture(0.75, 0.14, 0.18, 0.88)
    local cbFS = combatBanner:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(cbFS, 11, "OUTLINE", 1, 0.95, 0.95, 1)
    cbFS:SetPoint("CENTER")
    cbFS:SetText("战斗中已锁定键位编辑（防止界面污染），脱战后自动恢复")
    combatBanner:Hide()

    -- 主键盘网格容器
    local keyArea = CreateFrame("Frame", nil, f)
    keyArea:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -72)
    keyArea:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 86)
    f._keyArea = keyArea

    -- 底部动作条映射条（点击动作槽再点上方按键，也可一键关联动作条槽位）
    local barStrip = CreateFrame("Frame", nil, f)
    barStrip:SetHeight(68)
    barStrip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
    barStrip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 12)

    for i, spec in ipairs(BAR_SPECS) do
        local bt = CreateFrame("Button", nil, barStrip)
        bt:SetSize(74, 18)
        bt:SetPoint("TOPLEFT", barStrip, "TOPLEFT", (i - 1) * 78, 0)
        local bbg = bt:CreateTexture(nil, "BACKGROUND")
        bbg:SetAllPoints()
        ST.MaskTexture(bt, bbg, 4)
        bt._bg = bbg
        local bl = bt:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(bl, 10, "", 0.85, 0.88, 0.94, 1)
        bl:SetPoint("CENTER")
        bl:SetText(spec.label)
        bt._label = bl
        bt._barId = spec.id
        bt:SetScript("OnClick", function()
            mod:GetDB().actionBar = spec.id
            RefreshAllKeys()
        end)
        barTabButtons[i] = bt
    end

    for i = 1, 12 do
        local sb = CreateFrame("Button", nil, barStrip)
        sb:SetSize(38, 38)
        sb:SetPoint("BOTTOMLEFT", barStrip, "BOTTOMLEFT", (i - 1) * 42, 2)
        local bg = sb:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.065, 0.085, 0.90)
        ST.SetHostIconMode(sb, true)
        ST.MaskTexture(sb, bg, 5)
        local ic = sb:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", sb, "TOPLEFT", 2, -2)
        ic:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", -2, 2)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ST.MaskIcon(sb, ic, 5)
        sb._icon = ic

        local kfs = sb:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(kfs, 10, "OUTLINE", 0.96, 0.98, 1, 1)
        kfs:SetPoint("TOPRIGHT", sb, "TOPRIGHT", -2, -2)
        sb._keyFS = kfs

        local idxFS = sb:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(idxFS, 9, "OUTLINE", 0.62, 0.68, 0.76, 0.9)
        idxFS:SetPoint("BOTTOMLEFT", sb, "BOTTOMLEFT", 3, 2)
        idxFS:SetText(tostring(i))

        sb:SetScript("OnClick", function(self)
            if IsCombatLocked() then return end
            if _G.GetCursorInfo and _G.GetCursorInfo() and _G.PlaceAction and self._slot then
                pcall(_G.PlaceAction, self._slot)
                RefreshAllKeys()
                return
            end
            pendingSlotCmd = (pendingSlotCmd == self._cmd) and nil or self._cmd
            if pendingSlotCmd then
                F.Print("已选中槽位 " .. tostring(pendingSlotCmd) .. "：请点击上方键盘任意键完成绑定。")
            end
            RefreshAllKeys()
        end)
        sb:SetScript("OnReceiveDrag", function(self)
            if IsCombatLocked() then return end
            if _G.PlaceAction and self._slot then
                pcall(_G.PlaceAction, self._slot)
                RefreshAllKeys()
            end
        end)
        sb:SetScript("OnEnter", function(self)
            if not (GameTooltip and self._slot) then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP", 0, 4)
            if _G.HasAction and _G.HasAction(self._slot) and GameTooltip.SetAction then
                pcall(GameTooltip.SetAction, GameTooltip, self._slot)
                GameTooltip:AddLine(" ")
            else
                GameTooltip:SetText("动作条槽位 #" .. tostring(self._slot), 1, 1, 1)
            end
            GameTooltip:AddLine("左键选中后点上方键盘绑键 · 也可直接拖入技能", 0.32, 0.84, 0.41)
            GameTooltip:Show()
        end)
        sb:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        slotButtons[i] = sb
    end

    f:Hide()
    boardFrame = f
    RebuildKeyboardGrid()
end

function mod:ToggleBoard()
    if not self._active then
        F.Print("可视化键位图模块当前已关闭，请在 /kk「动效与视觉增强」中启用。")
        return
    end
    BuildBoard()
    if boardFrame:IsShown() then
        boardFrame:Hide()
    else
        pendingSlotCmd = nil
        RebuildKeyboardGrid()
        boardFrame:Show()
        RefreshAllKeys()
    end
end

function mod:OnEnable()
    inCombat = (InCombatLockdown and InCombatLockdown()) == true
    self:RegisterEvent("UPDATE_BINDINGS", RefreshAllKeys)
    self:RegisterEvent("ACTIONBAR_SLOT_CHANGED", RefreshAllKeys)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        inCombat = true
        RefreshAllKeys()
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        inCombat = false
        RefreshAllKeys()
    end)
end

function mod:OnDisable()
    inCombat = false
    pendingSlotCmd = nil
    if boardFrame then boardFrame:Hide() end
end

function mod:OnThemeChanged()
    if boardFrame then
        F.Theme.PaintPrettyCardOverlay(boardFrame, 0.322, 0.839, 0.412, 36, {
            alpha = 0.95, haloAlpha = 0.22,
        })
        RefreshAllKeys()
    end
end

-- 注册独立快捷命令 /kkkeys
_G.SLASH_KKOWOKEYS1 = "/kkkeys"
_G.SlashCmdList.KKOWOKEYS = function()
    mod:ToggleBoard()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "labeledButton",
        text = "可视化实体键盘绑键器",
        buttonText = "打开 /kkkeys",
        width = 130,
        tooltip = "弹出实体键盘绑键面板，支持拖放技能/宏/动作槽与右键一键解绑。",
        onClick = function() mod:ToggleBoard() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "默认实体键盘尺寸",
        values = {
            ["60"]   = "60% 紧凑布局",
            ["75"]   = "75% 含功能区（推荐）",
            ["tkl"]  = "TKL 标准无小键盘",
            ["full"] = "全尺寸含数字小键盘",
        },
        order = { "60", "75", "tkl", "full" },
        getValue = function() return db.layout or "75" end,
        setValue = function(v)
            db.layout = v
            if boardFrame then RebuildKeyboardGrid(); RefreshAllKeys() end
        end,
    }, {
        type = "dropdown",
        text = "底部默认动作条映射",
        values = { [1] = "主动作条", [2] = "左下动作条", [3] = "右下动作条", [4] = "右侧1", [5] = "右侧2", [6] = "动作条6" },
        order = { 1, 2, 3, 4, 5, 6 },
        getValue = function() return db.actionBar or 1 end,
        setValue = function(v) db.actionBar = v; RefreshAllKeys() end,
    })
    y = y - h

    return y
end
