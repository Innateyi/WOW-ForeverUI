----------------------------------------------------------------------
--  ForeverUI — Modules/MarkBar.lua
--  现代扁平矢量团队标记条（重绘 128px 高清矢量图标 + 烟熏玻璃胶囊 + 目标同步高亮）
--    • 8 枚现代扁平矢量团队标记（骷髅/红叉/方块/月亮/三角/菱形/大饼/星星）
--    • 3 枚同比例矢量功能钮（清除标记 / 就位确认 / 开怪倒数），全行光学居中零偏移
--    • 实时监听目标当前标记（RAID_TARGET_UPDATE / PLAYER_TARGET_CHANGED），
--      自动点亮目标已有标记对应格与 1px 底部高亮线，再次点击即可取消
--    • 视觉语言与 EUI 聊天标签及 PrettyTooltip 保持一致，纯 AnimationGroup 淡隐零污染
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, pcall, tostring = ipairs, math.floor, math.max, pcall, tostring
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("markBar", {
    title = "快捷标记条",
    desc = "现代重绘扁平矢量标记条（8 标记 + 清除/就位/倒数全矢量居中对齐），支持目标同步高亮与烟熏玻璃胶囊托底。",
    group = "combat",
    order = 40,
    defaults = {
        enabled = true,
        iconPack = "modern",      -- "modern" = 现代扁平矢量重绘（推荐）| "blizzard" = 暴雪原版标记
        showBackdrop = true,      -- 烟熏暗色玻璃胶囊托底 + 1px 职业色顶线（与 EUI 统一）
        v3ModernRedesign = false,
        hideWithoutPermission = true,
        hoverReveal = true,
        idleAlpha = 0.78,
        combatFade = false,
        v4NoCombatFadeMigrated = false,
        iconSize = 20,
        pullSeconds = 10,
    },
})

local MARK_DIR = F.MEDIA .. "MarkBar\\"
local RAID_ATLAS = MARK_DIR .. "UI-RaidTargetingIcons.blp"
local globalIconHooked = false
-- 记录被换成现代图集的贴图：GetTexture() 返回值会被引擎规范化（且 12.x 可能是机密值），不能拿路径字符串比较
local replacedRaidTex = setmetatable({}, { __mode = "k" })

local function InstallGlobalRaidIconHook()
    if globalIconHooked or type(_G.hooksecurefunc) ~= "function" then return end
    if type(_G.SetRaidTargetIconTexture) ~= "function" then return end
    globalIconHooked = true
    _G.hooksecurefunc("SetRaidTargetIconTexture", function(tex, idx)
        if not tex or type(tex.SetTexture) ~= "function" then return end
        if tex.IsForbidden and tex:IsForbidden() then return end
        local n = F.PlainNumber(idx, nil)
        if not n or n < 1 or n > 8 then return end
        local wantModern = mod._active and (mod:GetDB().iconPack or "modern") ~= "blizzard"
        local zero = n - 1
        local left = (zero % 4) * 0.25
        local top = math_floor(zero / 4) * 0.25
        if wantModern then
            pcall(tex.SetTexture, tex, RAID_ATLAS, nil, nil, "TRILINEAR")
            replacedRaidTex[tex] = true
        elseif replacedRaidTex[tex] then
            pcall(tex.SetTexture, tex, "Interface\\TargetingFrame\\UI-RaidTargetingIcons")
            replacedRaidTex[tex] = nil
        else
            return
        end
        if tex.SetTexCoord then
            pcall(tex.SetTexCoord, tex, left, left + 0.25, top, top + 0.25)
        end
    end)
end

local MARK_SPECS = {
    { index = 8, name = "骷髅", file = "Mark8.tga", color = { 0.96, 0.97, 1.00 } },
    { index = 7, name = "红叉", file = "Mark7.tga", color = { 0.96, 0.34, 0.38 } },
    { index = 6, name = "方块", file = "Mark6.tga", color = { 0.28, 0.76, 0.98 } },
    { index = 5, name = "月亮", file = "Mark5.tga", color = { 0.80, 0.86, 0.95 } },
    { index = 4, name = "三角", file = "Mark4.tga", color = { 0.24, 0.86, 0.48 } },
    { index = 3, name = "菱形", file = "Mark3.tga", color = { 0.78, 0.48, 0.98 } },
    { index = 2, name = "大饼", file = "Mark2.tga", color = { 0.99, 0.62, 0.24 } },
    { index = 1, name = "星星", file = "Mark1.tga", color = { 0.99, 0.84, 0.30 } },
}

local ACTION_SPECS = {
    {
        id = "clear",
        file = "Clear.tga",
        fallbackText = "清",
        label = "清除目标标记",
        color = { 0.94, 0.50, 0.54 },
        macro = "/tm 0",
    },
    {
        id = "ready",
        file = "Ready.tga",
        fallbackText = "备",
        label = "发起就位确认",
        color = { 0.40, 0.88, 0.62 },
        macro = "/readycheck",
    },
    {
        id = "pull",
        file = "Pull.tga",
        fallbackText = "倒",
        label = "发起开怪倒数",
        color = { 0.98, 0.78, 0.36 },
        macroFn = function()
            return "/countdown " .. tostring(mod:GetDB().pullSeconds or 10)
        end,
    },
}

local barFrame = nil
local topHairline = nil
local sepTex = nil
local markBtns = {}
local actionBtns = {}
local isHovered = false
local isDraggingBar = false
local currentTargetMark = 0

local function RefreshActionMacros()
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_MarkBarMacros", RefreshActionMacros)
        return
    end
    for _, btn in ipairs(actionBtns) do
        local spec = btn._spec
        if spec and spec.macroFn then
            btn:SetAttribute("macrotext", spec.macroFn())
        end
    end
end

local function HasMarkPermission()
    if not (_G.IsInGroup and _G.IsInGroup()) then
        return true
    end
    if not (_G.IsInRaid and _G.IsInRaid()) then
        return true
    end
    return (_G.UnitIsGroupLeader and _G.UnitIsGroupLeader("player"))
        or (_G.UnitIsGroupAssistant and _G.UnitIsGroupAssistant("player"))
end

local function SyncAlpha(instant)
    if not (barFrame and barFrame:IsShown()) then return end
    local db = mod:GetDB()
    local over = isHovered or (barFrame.IsMouseOver and barFrame:IsMouseOver())
    local goal = 1.0
    if not over then
        if db.combatFade and _G.InCombatLockdown and _G.InCombatLockdown() then
            goal = (F.db and F.db.theme and F.db.theme.combatFadeAlpha) or 0.18
        elseif db.hoverReveal ~= false then
            goal = db.idleAlpha or 0.78
        end
    end
    if instant then
        F.Theme.FadeTo(barFrame, goal, 0)
        return
    end
    local cur = F.PlainNumber(barFrame:GetAlpha(), 1)
    if (cur - goal) < 0.015 and (goal - cur) < 0.015 then return end
    F.Theme.FadeTo(barFrame, goal, goal > cur and 0.14 or 0.22)
end

local function ScheduleLeaveCheck()
    local db = mod:GetDB()
    if db.hoverReveal == false and db.combatFade ~= true then
        isHovered = false
        return
    end
    C_Timer.After(0.10, function()
        if not (barFrame and barFrame:IsMouseOver()) then
            isHovered = false
            SyncAlpha(false)
        end
    end)
end

local function PaintCellState(btn, isActive)
    local hovered = btn._isHovered == true
    local col = btn._color or { 0.85, 0.88, 0.92 }
    if hovered then
        btn._cellBg:SetColorTexture(col[1], col[2], col[3], 0.22)
        btn._underline:SetColorTexture(col[1], col[2], col[3], 0.95)
        btn._underline:Show()
        if btn._icon then btn._icon:SetAlpha(1.0) end
        if btn._actionColor and btn._icon then
            btn._icon:SetVertexColor(
                math_max(col[1], col[1] * 0.85 + 0.15),
                math_max(col[2], col[2] * 0.85 + 0.15),
                math_max(col[3], col[3] * 0.85 + 0.15), 1)
        end
    elseif isActive then
        btn._cellBg:SetColorTexture(col[1], col[2], col[3], 0.16)
        btn._underline:SetColorTexture(col[1], col[2], col[3], 0.92)
        btn._underline:Show()
        if btn._icon then btn._icon:SetAlpha(1.0) end
    else
        local showBg = mod:GetDB().showBackdrop ~= false
        if showBg then
            btn._cellBg:SetColorTexture(1, 1, 1, 0.035)
        else
            btn._cellBg:SetColorTexture(0, 0, 0, 0)
        end
        btn._underline:Hide()
        if btn._icon then
            btn._icon:SetAlpha(0.92)
            if btn._actionColor then
                btn._icon:SetVertexColor(col[1], col[2], col[3], 0.92)
            end
        end
    end
end

local function RefreshTargetMarkHighlight()
    local idx = 0
    if _G.UnitExists and _G.UnitExists("target") and _G.GetRaidTargetIndex then
        idx = F.PlainNumber(_G.GetRaidTargetIndex("target"), 0)
    end
    currentTargetMark = idx
    for _, btn in ipairs(markBtns) do
        PaintCellState(btn, idx > 0 and btn._markIndex == idx)
    end
end

local function LayoutAndStyle()
    if not barFrame then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_MarkBarLayout", LayoutAndStyle)
        return
    end
    local db = mod:GetDB()
    local ar, ag, ab = F.Theme.GetAccent()
    local showBg = db.showBackdrop ~= false
    local useModern = (db.iconPack or "modern") ~= "blizzard"
    local barTex = F.Theme.GetBarTexture()

    local iconSz = math_max(14, math_floor(F.PlainNumber(db.iconSize, 20) + 0.5))
    local cellSz = iconSz + 6
    local gap = 2
    local padX = showBg and 6 or 2
    local padY = showBg and 4 or 2
    local sepSpace = 9

    if showBg then
        F.Theme.StylePanel(barFrame, 0.62, 0.30)
        if barFrame._fuiBg then
            barFrame._fuiBg:SetTexture(barTex)
            barFrame._fuiBg:SetVertexColor(0.03, 0.045, 0.05, 0.72)
            barFrame._fuiBg:Show()
        end
        if barFrame._fuiBorders then
            for _, ln in ipairs(barFrame._fuiBorders) do
                ln:SetColorTexture(1, 1, 1, 0.14)
                ln:Show()
            end
        end
        if topHairline then
            topHairline:SetColorTexture(ar, ag, ab, 0.75)
            topHairline:Show()
        end
    else
        if barFrame._fuiBg then barFrame._fuiBg:Hide() end
        if barFrame._fuiBorders then
            for _, ln in ipairs(barFrame._fuiBorders) do ln:Hide() end
        end
        if topHairline then topHairline:Hide() end
    end

    local x = padX
    for _, btn in ipairs(markBtns) do
        btn:ClearAllPoints()
        btn:SetSize(cellSz, cellSz)
        btn:SetPoint("LEFT", barFrame, "LEFT", x, 0)
        btn._icon:SetSize(iconSz, iconSz)
        if useModern then
            btn._icon:SetTexCoord(0, 1, 0, 1)
            btn._icon:SetTexture(MARK_DIR .. btn._spec.file)
            btn._icon:SetVertexColor(1, 1, 1, 1)
        else
            btn._icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
            if _G.SetRaidTargetIconTexture then
                _G.SetRaidTargetIconTexture(btn._icon, btn._markIndex)
            end
            btn._icon:SetVertexColor(1, 1, 1, 1)
        end
        PaintCellState(btn, currentTargetMark > 0 and btn._markIndex == currentTargetMark)
        x = x + cellSz + gap
    end

    -- 1px 垂直细分隔线（严格垂直居中于标记条）
    if sepTex then
        sepTex:ClearAllPoints()
        sepTex:SetSize(1, math_max(10, cellSz - 8))
        sepTex:SetPoint("LEFT", barFrame, "LEFT", x + math_floor((sepSpace - gap) / 2), 0)
        sepTex:SetColorTexture(1, 1, 1, showBg and 0.16 or 0.24)
    end
    x = x + (sepSpace - gap)

    local actIconSz = math_max(14, iconSz - 1)
    for _, btn in ipairs(actionBtns) do
        btn:ClearAllPoints()
        btn:SetSize(cellSz, cellSz)
        btn:SetPoint("LEFT", barFrame, "LEFT", x, 0)
        btn._icon:SetSize(actIconSz, actIconSz)
        btn._icon:SetTexture(MARK_DIR .. btn._spec.file)
        PaintCellState(btn, false)
        x = x + cellSz + gap
    end

    local totalW = x - gap + padX
    local totalH = cellSz + padY * 2
    barFrame:SetSize(totalW, totalH)
    SyncAlpha(true)
end

local function UpdateVisibility()
    if not barFrame then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_MarkBarVis", UpdateVisibility)
        return
    end
    local db = mod:GetDB()
    if not mod._active then
        barFrame:Hide()
        return
    end
    if db.hideWithoutPermission and not HasMarkPermission() then
        barFrame:Hide()
    else
        barFrame:Show()
        RefreshTargetMarkHighlight()
        SyncAlpha(true)
    end
end

local function CreateCellButton(parent, color, macroText)
    -- 使用暴雪安全动作按钮执行 /tm /readycheck /countdown：
    -- 彻底解决 16001/12.x 下 SetRaidTarget 受保护触发 ADDON_ACTION_BLOCKED 报错，战斗内外均可用
    local btn = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    btn._color = color
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetAttribute("useOnKeyDown", false)
    btn:SetAttribute("type1", "macro")
    btn:SetAttribute("shift-type1", "") -- Shift+左键专用于拖拽，不误触标记或倒数
    if macroText then
        btn:SetAttribute("macrotext", macroText)
    end

    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function()
        if _G.IsShiftKeyDown and _G.IsShiftKeyDown() and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            isDraggingBar = true
            barFrame:StartMoving()
        end
    end)
    btn:SetScript("OnDragStop", function()
        if not isDraggingBar then return end
        isDraggingBar = false
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        barFrame:StopMovingOrSizing()
        local pt, _, rpt, x, y = barFrame:GetPoint(1)
        F.DB.SavePosition("MarkBar", pt, rpt, x, y)
    end)

    local cellBg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
    cellBg:SetAllPoints()
    btn._cellBg = cellBg

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn._icon = icon

    local underline = btn:CreateTexture(nil, "OVERLAY", nil, 6)
    underline:SetHeight(1)
    underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 2, 0)
    underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 0)
    underline:Hide()
    btn._underline = underline

    return btn
end

local function CreateBar()
    if barFrame then return end
    barFrame = CreateFrame("Frame", "ForeverUI_MarkBar", _G.UIParent)
    barFrame:SetSize(310, 32)
    barFrame:SetFrameStrata("HIGH")
    barFrame:EnableMouse(true)

    topHairline = barFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    topHairline:SetHeight(1)
    topHairline:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
    topHairline:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, 0)

    sepTex = barFrame:CreateTexture(nil, "ARTWORK")

    barFrame:SetScript("OnEnter", function()
        isHovered = true
        SyncAlpha(false)
    end)
    barFrame:SetScript("OnLeave", ScheduleLeaveCheck)

    for i, spec in ipairs(MARK_SPECS) do
        local btn = CreateCellButton(barFrame, spec.color, "/tm " .. tostring(spec.index))
        btn._spec = spec
        btn._markIndex = spec.index

        btn:SetScript("OnEnter", function(self)
            isHovered = true
            self._isHovered = true
            SyncAlpha(false)
            PaintCellState(self, currentTargetMark == spec.index)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM", 0, -4)
            GameTooltip:AddLine("标记：" .. spec.name, spec.color[1], spec.color[2], spec.color[3])
            GameTooltip:AddLine("左键点击给当前目标上标记（再次点击清除）", 0.82, 0.85, 0.89)
            GameTooltip:AddLine("Shift + 左键拖动可移动标记条", 0.56, 0.60, 0.66)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            self._isHovered = false
            PaintCellState(self, currentTargetMark == spec.index)
            GameTooltip:Hide()
            ScheduleLeaveCheck()
        end)
        markBtns[i] = btn
    end

    for i, spec in ipairs(ACTION_SPECS) do
        local macro = spec.macroFn and spec.macroFn() or spec.macro
        local btn = CreateCellButton(barFrame, spec.color, macro)
        btn._spec = spec
        btn._actionColor = true

        btn:SetScript("OnEnter", function(self)
            isHovered = true
            self._isHovered = true
            SyncAlpha(false)
            PaintCellState(self, false)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM", 0, -4)
            local title = spec.label
            if spec.id == "pull" then
                title = spec.label .. " (" .. tostring(mod:GetDB().pullSeconds or 10) .. "秒)"
            end
            GameTooltip:AddLine(title, spec.color[1], spec.color[2], spec.color[3])
            GameTooltip:AddLine("Shift + 左键拖动可移动标记条", 0.56, 0.60, 0.66)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            self._isHovered = false
            PaintCellState(self, false)
            GameTooltip:Hide()
            ScheduleLeaveCheck()
        end)
        actionBtns[i] = btn
    end

    F.Mover.Register({
        key = "MarkBar",
        label = "快捷标记条",
        frame = barFrame,
        order = 40,
        defaultPoint = "TOP",
        defaultRelPoint = "TOP",
        defaultX = 0,
        defaultY = -44,
    })
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v3ModernRedesign then
        db.v3ModernRedesign = true
        db.iconPack = "modern"
        db.showBackdrop = true
        db.idleAlpha = 0.78
    end
    if not db.v4NoCombatFadeMigrated then
        db.v4NoCombatFadeMigrated = true
        db.combatFade = false
    end
    CreateBar()
    InstallGlobalRaidIconHook()
    LayoutAndStyle()
    UpdateVisibility()
    self:RegisterEvent("GROUP_ROSTER_UPDATE", UpdateVisibility)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", UpdateVisibility)
    self:RegisterEvent("PLAYER_TARGET_CHANGED", RefreshTargetMarkHighlight)
    self:RegisterEvent("RAID_TARGET_UPDATE", RefreshTargetMarkHighlight)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        -- 条上挂着安全按钮：拖动中进战必须在本事件内（受保护调用仍合法）结束移动，否则松手时 StopMovingOrSizing 会被拦截
        if isDraggingBar and barFrame then
            isDraggingBar = false
            barFrame:StopMovingOrSizing()
            local pt, _, rpt, x, y = barFrame:GetPoint(1)
            F.DB.SavePosition("MarkBar", pt, rpt, x, y)
        end
        if mod:GetDB().combatFade == true then SyncAlpha(false) end
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if mod:GetDB().combatFade == true then SyncAlpha(false) end
    end)
end

function mod:OnDisable()
    if barFrame then
        if _G.InCombatLockdown and _G.InCombatLockdown() then
            F.RunOutOfCombat("FUI_MarkBarVis", function()
                if barFrame and not mod._active then barFrame:Hide() end
            end)
        else
            barFrame:Hide()
        end
    end
end

function mod:OnThemeChanged()
    LayoutAndStyle()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "标记图标风格",
        tooltip = "「现代扁平矢量重绘」使用 128px 重绘高清矢量标记与清除/就位/倒数图标；也可随时切回暴雪原版标记。",
        values = {
            modern   = "现代扁平矢量重绘（推荐）",
            blizzard = "经典暴雪原版标记",
        },
        order = { "modern", "blizzard" },
        getValue = function() return db.iconPack or "modern" end,
        setValue = function(v) db.iconPack = v; LayoutAndStyle() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示烟熏玻璃胶囊托底",
        tooltip = "开启后呈现与 EUI 聊天栏一致的半透明烟熏底框与职业色顶线；关闭则完全透明悬浮。",
        getValue = function() return db.showBackdrop ~= false end,
        setValue = function(v) db.showBackdrop = v == true; LayoutAndStyle() end,
    }, {
        type = "slider",
        text = "图标尺寸",
        min = 16, max = 28, step = 1,
        getValue = function() return db.iconSize or 20 end,
        setValue = function(v) db.iconSize = v; LayoutAndStyle() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "静默柔淡（鼠标悬停亮起）",
        tooltip = "平时柔和半透明不抢眼，鼠标移上立刻 100% 清晰。",
        getValue = function() return db.hoverReveal ~= false end,
        setValue = function(v) db.hoverReveal = v == true; SyncAlpha(false) end,
    }, {
        type = "toggle",
        text = "团队无权限时自动隐藏",
        tooltip = "单人和小队始终显示；仅在团队中既非团长也非助理时隐藏。",
        getValue = function() return db.hideWithoutPermission ~= false end,
        setValue = function(v) db.hideWithoutPermission = v == true; UpdateVisibility() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "开怪倒数秒数",
        min = 3, max = 20, step = 1,
        getValue = function() return db.pullSeconds or 10 end,
        setValue = function(v) db.pullSeconds = v; RefreshActionMacros() end,
    }, {
        type = "toggle",
        text = "战斗中自动淡出",
        getValue = function() return db.combatFade == true end,
        setValue = function(v) db.combatFade = v == true; SyncAlpha(false) end,
    })
    y = y - h
    return y
end
