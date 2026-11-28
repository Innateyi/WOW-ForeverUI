----------------------------------------------------------------------
--  kkowoUI — Modules/RollBars.lua
--  零全局泄漏的现代扁平 Roll 点条（MerfinMain 材质 + 品质边框）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, pairs, pcall, type = ipairs, pairs, pcall, type
local math_floor, math_min = math.floor, math.min
local table_sort = table.sort
local CreateFrame = CreateFrame
local GameTooltip = _G.GameTooltip
local GetTime = GetTime

local mod = F.RegisterModule("rollBars", {
    title = "Roll 点增强",
    desc = "扁平装备掷点条，带倒计时与快捷按钮；开启 EUI 掷点框时让位。",
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
local nativeShowHooked = setmetatable({}, { __mode = "k" })
local hiddenNativeFrames = {}

local ApplyBarBorder -- 前向声明
local HideNativeRollFrames -- 前向声明
local ScheduleHideNativeRollFrames -- 前向声明
local RestoreNativeRollFrames -- 前向声明
local DisableContainerMouse -- 前向声明

local function SafeBool(v, fallback)
    if F.IsSecret(v) then return fallback end
    return v == true
end

local function IsObjForbidden(obj)
    if not obj then return true end
    if obj.IsForbidden then
        local ok, forb = pcall(obj.IsForbidden, obj)
        if not ok or forb then return true end
    end
    return false
end

DisableContainerMouse = function(frame)
    if not frame then return end
    if frame.EnableMouse then pcall(frame.EnableMouse, frame, false) end
    if frame.SetMouseClickEnabled then pcall(frame.SetMouseClickEnabled, frame, false) end
    if frame.SetMouseMotionEnabled then pcall(frame.SetMouseMotionEnabled, frame, false) end
end

local function SetBarMouseHoverOnly(bar, hoverOn)
    if not bar then return end
    if hoverOn then
        if bar.EnableMouse then pcall(bar.EnableMouse, bar, true) end
        -- 条体仅用于悬停查看装备提示，绝不吞掉左右键点击/视角拖动（按钮与图标按钮独立响应点击）
        if bar.SetMouseClickEnabled then pcall(bar.SetMouseClickEnabled, bar, false) end
        if bar.SetMouseMotionEnabled then pcall(bar.SetMouseMotionEnabled, bar, true) end
    else
        DisableContainerMouse(bar)
    end
end

local function LayoutRollButtons(bar, showDis)
    if not bar then return end
    if bar.btnPass then
        bar.btnPass:ClearAllPoints()
        bar.btnPass:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    end
    if showDis then
        if bar.btnDis then
            bar.btnDis:ClearAllPoints()
            bar.btnDis:SetPoint("RIGHT", bar, "RIGHT", -28, 0)
            bar.btnDis:Show()
        end
        if bar.btnGreed then
            bar.btnGreed:ClearAllPoints()
            bar.btnGreed:SetPoint("RIGHT", bar, "RIGHT", -52, 0)
        end
        if bar.btnNeed then
            bar.btnNeed:ClearAllPoints()
            bar.btnNeed:SetPoint("RIGHT", bar, "RIGHT", -76, 0)
        end
        if bar.timeFS then
            bar.timeFS:ClearAllPoints()
            bar.timeFS:SetPoint("RIGHT", bar, "RIGHT", -102, 0)
        end
    else
        if bar.btnDis then bar.btnDis:Hide() end
        if bar.btnGreed then
            bar.btnGreed:ClearAllPoints()
            bar.btnGreed:SetPoint("RIGHT", bar, "RIGHT", -28, 0)
        end
        if bar.btnNeed then
            bar.btnNeed:ClearAllPoints()
            bar.btnNeed:SetPoint("RIGHT", bar, "RIGHT", -52, 0)
        end
        if bar.timeFS then
            bar.timeFS:ClearAllPoints()
            bar.timeFS:SetPoint("RIGHT", bar, "RIGHT", -78, 0)
        end
    end
end

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

local SLIDE_X = 24

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

    -- 容器固定单条尺寸、无条时立刻隐藏且绝不拦截鼠标：
    -- 1) 解锁模式锚框与第 1 条严格对齐，增减装备时剩余条不再整体跳动；
    -- 2) 无可见掷点条时隐藏容器本身，彻底杜绝残留空框体拦截副本内左/右键点击；
    -- 3) 实战置 HIGH 层（高于 MEDIUM 层核心 HUD / 常驻 BUFF / 动作条，低于 DIALOG 拾取绑定弹窗与 TOOLTIP）。
    container:SetSize(w, h)
    DisableContainerMouse(container)
    if #visible == 0 then
        container:Hide()
        return
    end
    container:Show()
    local strata = hasPreview and "FULLSCREEN_DIALOG" or "HIGH"
    local baseLvl = hasPreview and 200 or 50
    container:SetFrameStrata(strata)
    container:SetFrameLevel(baseLvl)

    local step = h + gap
    local anchorPt = growDown and "TOP" or "BOTTOM"
    for idx, bar in ipairs(visible) do
        local offset = (idx - 1) * step
        local newY = growDown and -offset or offset
        local geomChanged = (bar._slotPt ~= anchorPt) or (bar._slotY ~= newY) or (bar._slotW ~= w) or (bar._slotH ~= h)
        bar._slotPt = anchorPt
        bar._slotY = newY
        bar._slotW = w
        bar._slotH = h
        if geomChanged then
            bar:ClearAllPoints()
            bar:SetSize(w, h)
            bar:SetPoint(anchorPt, container, anchorPt, 0, newY)
        end
        SyncBarLayers(bar, strata, baseLvl + 1)
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

local function HideOneNativeFrame(f)
    if IsObjForbidden(f) then return end
    if f.IsShown then
        local okS, shown = pcall(f.IsShown, f)
        if okS and shown then
            if pcall(f.Hide, f) then
                hiddenNativeFrames[f] = true
            end
        end
    end
end

RestoreNativeRollFrames = function()
    local pendingCombat = false
    for f in pairs(hiddenNativeFrames) do
        if not IsObjForbidden(f) then
            if _G.InCombatLockdown and _G.InCombatLockdown() and f.IsProtected then
                local okP, prot = pcall(f.IsProtected, f)
                if okP and prot then
                    pendingCombat = true
                else
                    hiddenNativeFrames[f] = nil
                    pcall(f.Show, f)
                end
            else
                hiddenNativeFrames[f] = nil
                pcall(f.Show, f)
            end
        else
            hiddenNativeFrames[f] = nil
        end
    end
    if pendingCombat and F.RunOutOfCombat then
        F.RunOutOfCombat("kkowoUI_RollBars_RestoreNative", RestoreNativeRollFrames)
    end
end

HideNativeRollFrames = function()
    if not (mod._active and not EUILootRollsInUse()) then
        return
    end
    local c = _G.GroupLootContainer
    if c and IsObjForbidden(c) then c = nil end
    local maxN = (c and F.PlainNumber(c.maxIndex, 4)) or 4
    if maxN < 4 then maxN = 4 end
    local bonus = _G.BonusRollFrame
    if bonus and IsObjForbidden(bonus) then bonus = nil end
    for i = 1, maxN do
        local f = _G["GroupLootFrame" .. i]
        if f and not IsObjForbidden(f) then
            if f.HookScript and not nativeShowHooked[f] then
                nativeShowHooked[f] = true
                f:HookScript("OnShow", function(self)
                    if mod._active and not EUILootRollsInUse() then
                        HideOneNativeFrame(self)
                    end
                end)
            end
            HideOneNativeFrame(f)
        end
    end
    local hasOtherVisible = false
    if bonus and bonus.IsShown then
        local okB, bShown = pcall(bonus.IsShown, bonus)
        hasOtherVisible = okB and bShown == true
    end
    if c and type(c.rollFrames) == "table" then
        for _, rf in pairs(c.rollFrames) do
            if rf and rf ~= bonus and not IsObjForbidden(rf) then
                local nm = rf.GetName and F.PlainString(rf:GetName(), "") or ""
                if nm:find("GroupLootFrame", 1, true) or rf.rollID ~= nil then
                    if rf.HookScript and not nativeShowHooked[rf] then
                        nativeShowHooked[rf] = true
                        rf:HookScript("OnShow", function(self)
                            if mod._active and not EUILootRollsInUse() then
                                HideOneNativeFrame(self)
                            end
                        end)
                    end
                    HideOneNativeFrame(rf)
                elseif rf.IsShown then
                    local okR, rShown = pcall(rf.IsShown, rf)
                    if okR and rShown then hasOtherVisible = true end
                end
            end
        end
    end
    if c then
        if c.HookScript and not nativeShowHooked[c] then
            nativeShowHooked[c] = true
            c:HookScript("OnShow", function()
                if mod._active and not EUILootRollsInUse() then
                    ScheduleHideNativeRollFrames()
                end
            end)
        end
        if not hasOtherVisible then
            HideOneNativeFrame(c)
        end
    end
end

ScheduleHideNativeRollFrames = function()
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
    if bar._animIn then bar._animIn:Stop() end
    bar:SetAlpha(1)
    SetBarMouseHoverOnly(bar, false)
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
    bar._checkAccum = nil
    bar._slotPt = nil
    bar._slotY = nil
    bar._slotW = nil
    bar._slotH = nil
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

local function PruneStaleRolls()
    local getLeft = _G.GetLootRollTimeLeft
    local now = GetTime()
    local changed = false
    for _, bar in ipairs(bars) do
        if bar:IsShown() and bar.rollID ~= nil then
            -- 绝不因 GetLootRollTimeLeft 返回 nil/机密值/0 而误关真实掷点条（K5）：
            -- 仅在读到有效正剩余时间时校准 endTime，否则依靠本地计时器与 CANCEL_LOOT_ROLL 结束。
            if getLeft then
                local ok, ms = pcall(getLeft, bar.rollID)
                local rem = ok and F.PlainNumber(ms, nil) or nil
                if rem and rem > 0 then
                    bar.endTime = now + rem / 1000
                end
            end
            if not bar.endTime or bar.endTime <= now then
                CloseBar(bar)
                changed = true
            end
        end
    end
    if changed then
        LayoutBars()
    end
end

local function RecoverActiveRolls()
    if not mod._active or EUILootRollsInUse() then return end
    local getIds = _G.GetActiveLootRollIDs
    if type(getIds) ~= "function" then return end
    local ok, ids = pcall(getIds)
    if not ok or F.IsSecret(ids) or type(ids) ~= "table" then return end
    for _, rid in ipairs(ids) do
        if not F.IsSecret(rid) and rid ~= nil then
            local already = false
            for _, b in ipairs(bars) do
                if b:IsShown() and b.rollID == rid then
                    already = true
                    break
                end
            end
            if not already then
                local leftMs = 60000
                if _G.GetLootRollTimeLeft then
                    local okL, ms = pcall(_G.GetLootRollTimeLeft, rid)
                    local n = okL and F.PlainNumber(ms, nil) or nil
                    if n and n > 0 then leftMs = n end
                end
                mod:OnStartRoll("RECOVER_LOOT_ROLL", rid, leftMs)
            end
        end
    end
end

local function EnsureNativeHooks()
    if nativeHooksInstalled then return end
    nativeHooksInstalled = true
    -- 仅延后到下一帧隐藏原生容器，避免在 GroupLootContainer_Update/AddFrame 同步布局栈内改写受管布局导致 taint
    if type(_G.GroupLootFrame_OpenNewFrame) == "function" then
        _G.hooksecurefunc("GroupLootFrame_OpenNewFrame", function()
            ScheduleHideNativeRollFrames()
        end)
    end
    if type(_G.GroupLootContainer_OpenNewFrame) == "function" then
        _G.hooksecurefunc("GroupLootContainer_OpenNewFrame", function()
            ScheduleHideNativeRollFrames()
        end)
    end
    if type(_G.GroupLootContainer_AddFrame) == "function" then
        _G.hooksecurefunc("GroupLootContainer_AddFrame", function()
            ScheduleHideNativeRollFrames()
        end)
    end
    if type(_G.GroupLootContainer_Update) == "function" then
        _G.hooksecurefunc("GroupLootContainer_Update", function()
            ScheduleHideNativeRollFrames()
        end)
    end
    if type(_G.ConfirmLootRoll) == "function" then
        _G.hooksecurefunc("ConfirmLootRoll", function(rollID)
            if mod._active and not EUILootRollsInUse() and not F.IsSecret(rollID) and rollID ~= nil then
                CloseRollID(rollID)
            end
        end)
    end
    HideNativeRollFrames()
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
    F.Theme.PaintLuminousCard(bar, {
        r = r, g = g, b = b,
        radius = rad,
        bgAlpha = 0.84,
        tintMix = 0.14,
        glowAlpha = 0.20,
        glowWidth = 104,
        borderAlpha = 0.58,
        borderLevel = 2,
        leftBar = false,
    })
    if bar._iconBg then
        bar._iconBg:SetColorTexture(
            math_min(1, r * 0.58 + 0.08),
            math_min(1, g * 0.58 + 0.08),
            math_min(1, b * 0.58 + 0.08), 0.86)
    end
    if ST and rad > 0 then
        local ft = bar.status and bar.status:GetStatusBarTexture()
        if ft then ST.MaskTexture(bar, ft, rad) end
        if bar._spark and bar._spark._spark then ST.MaskTexture(bar, bar._spark._spark, rad) end
    elseif ST then
        ST.ClearRoundedMask(bar)
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
    SetBarMouseHoverOnly(bar, false)
    bar:SetClampedToScreen(true)
    F.Theme.StyleLuminousCard(bar, {
        radius = 6,
        bgAlpha = 0.80,
        tintMix = 0.18,
        glowAlpha = 0.24,
        glowWidth = 112,
        borderAlpha = 0.86,
        borderLevel = 2,
        leftBar = false,
    })
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
    if F.Motion and F.Motion.AttachEdgeSpark then
        bar._spark = F.Motion.AttachEdgeSpark(sb, { width = 18, extraHeight = 2, levelOffset = 2 })
    end

    -- 与 EUI LootFeed 同款零闪烁入场：播放前 SetAlpha(0)，Order 2 位移与淡入等长并启用 SetToFinalAlpha(true)
    local animIn = bar:CreateAnimationGroup()
    animIn:SetToFinalAlpha(true)
    local aJump = animIn:CreateAnimation("Translation")
    aJump:SetOrder(1); aJump:SetOffset(SLIDE_X, 0); aJump:SetDuration(0)
    local aSlide = animIn:CreateAnimation("Translation")
    aSlide:SetOrder(2); aSlide:SetOffset(-SLIDE_X, 0); aSlide:SetDuration(0.34); aSlide:SetSmoothing("OUT")
    local aFade = animIn:CreateAnimation("Alpha")
    aFade:SetOrder(2); aFade:SetFromAlpha(0); aFade:SetToAlpha(1); aFade:SetDuration(0.34); aFade:SetSmoothing("OUT")
    animIn:SetScript("OnFinished", function() bar:SetAlpha(1) end)
    animIn:SetScript("OnStop", function() if bar:IsShown() then bar:SetAlpha(1) end end)
    bar._animIn = animIn

    local iconBtn = CreateFrame("Button", nil, bar)
    iconBtn:SetSize(26, 26)
    iconBtn:SetPoint("LEFT", bar, "LEFT", 3, 0)
    local iconBg = iconBtn:CreateTexture(nil, "BACKGROUND", nil, -1)
    iconBg:SetAllPoints(iconBtn)
    iconBg:SetColorTexture(0.18, 0.20, 0.26, 0.86)
    local icon = iconBtn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", iconBtn, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", iconBtn, "BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar._iconBtn = iconBtn
    bar._iconBg = iconBg
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

    bar:SetScript("OnUpdate", function(self, elapsed)
        if not self.endTime then return end
        local rem = self.endTime - GetTime()
        if rem <= 0 then
            CloseBar(self)
            LayoutBars()
            return
        end
        if self.rollID ~= nil and _G.GetLootRollTimeLeft then
            local acc = (self._checkAccum or 0) + (elapsed or 0)
            if acc >= 0.5 then
                self._checkAccum = 0
                local ok, ms = pcall(_G.GetLootRollTimeLeft, self.rollID)
                local leftMs = ok and F.PlainNumber(ms, nil) or nil
                -- 仅在读到有效正剩余时间时校准本地倒计时；读不到/机密/返回 0 时绝不误关条（K5）
                if leftMs and leftMs > 0 then
                    local syncedEnd = GetTime() + leftMs / 1000
                    if (syncedEnd - self.endTime) > 1.5 or (self.endTime - syncedEnd) > 1.5 then
                        self.endTime = syncedEnd
                    end
                end
            else
                self._checkAccum = acc
            end
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
    DisableContainerMouse(container)
    F.Mover.Register({
        key = "RollBars",
        label = "Roll 点增强条",
        frame = container,
        order = 35,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 0,
        defaultY = -140,
        allowShiftDrag = false,
        isHidden = function() return not mod._active end,
    })
    -- 无可见掷点条时隐藏容器并彻底禁鼠，防止副本外/副本内空锚点拦截左右键点击
    DisableContainerMouse(container)
    container:Hide()
end

function mod:OnStartRoll(_, rollID, rollTime)
    if not _G.GetLootRollItemInfo or F.IsSecret(rollID) or rollID == nil then
        return
    end
    if EUILootRollsInUse() then
        F.PrintOnce("rollbars_yield_eui", "EUI 拾取掷点框已开启，掷点条自动让位。")
        return
    end
    EnsureContainer()
    HideNativeRollFrames()
    ScheduleHideNativeRollFrames()

    local okInfo, texture, name, _, quality, bindOnPickUp, canNeed, canGreed, canDisenchant = pcall(_G.GetLootRollItemInfo, rollID)
    if not okInfo or (not F.IsSecret(name) and type(name) == "nil") then
        return
    end
    local dispName = F.PlainString(name, nil) or ("战利品 #" .. tostring(F.PlainNumber(rollID, 0) or ""))
    local safeTex = (not F.IsSecret(texture) and (type(texture) == "number" or type(texture) == "string")) and texture or 134400
    local safeBop = SafeBool(bindOnPickUp, false)
    local safeNeed = SafeBool(canNeed, true)
    local safeGreed = SafeBool(canGreed, true)
    local safeDis = SafeBool(canDisenchant, false)

    local bar, existed = AcquireBar(rollID)
    bar.rollID = rollID
    bar.bop = safeBop
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
    local ST = F.StyleTokens
    if ST and ST.ApplyBarGradient then
        bar.status:SetStatusBarColor(1, 1, 1, 1)
        ST.ApplyBarGradient(bar.status,
            qr * 0.40, qg * 0.40, qb * 0.40,
            math_min(1, qr * 0.85 + 0.15), math_min(1, qg * 0.85 + 0.15), math_min(1, qb * 0.85 + 0.15),
            0.54)
    else
        bar.status:SetStatusBarColor(qr, qg, qb, 0.42)
    end
    if bar._spark then
        bar._spark:SetColor(math_min(1, qr * 0.5 + 0.5), math_min(1, qg * 0.5 + 0.5), math_min(1, qb * 0.5 + 0.5), 0.82)
        bar._spark:SyncAnchor()
    end
    bar._borderColor = { qr, qg, qb }
    bar._lastSec = nil
    bar.icon:SetTexture(safeTex)
    bar.nameText:SetText(dispName)
    bar.nameText:SetTextColor(qr, qg, qb, 1)

    bar.btnPass:SetEnabled(true); bar.btnPass:SetAlpha(1)
    bar.btnNeed:SetEnabled(safeNeed); bar.btnNeed:SetAlpha(safeNeed and 1 or 0.25)
    bar.btnGreed:SetEnabled(safeGreed); bar.btnGreed:SetAlpha(safeGreed and 1 or 0.25)
    local showDis = safeDis
    bar.btnDis:SetEnabled(showDis); bar.btnDis:SetAlpha(showDis and 1 or 0.25)
    LayoutRollButtons(bar, showDis)
    bar._checkAccum = 0
    SetBarMouseHoverOnly(bar, true)
    if not existed and bar._animIn then
        bar._animIn:Stop()
        bar:SetAlpha(0)
        bar:Show()
        LayoutBars()
        ApplyBarBorder(bar, qr, qg, qb)
        bar._animIn:Play()
        if F.Theme and F.Theme.PlayLuminousShimmer then F.Theme.PlayLuminousShimmer(bar) end
    else
        bar:SetAlpha(1)
        bar:Show()
        LayoutBars()
        ApplyBarBorder(bar, qr, qg, qb)
    end
end

function mod:OnCancelRoll(_, rollID)
    CloseRollID(rollID)
end

function mod:ShowPreview()
    if not self._active then return end
    EnsureContainer()
    local bar = AcquireBar(nil)
    bar.rollID = nil
    bar.bop = false
    bar._checkAccum = 0
    nextSeq = nextSeq + 1
    bar._seq = nextSeq
    bar.endTime = GetTime() + 12
    bar.status:SetStatusBarTexture(F.Theme.GetBarTexture())
    bar.status:SetMinMaxValues(0, 12)
    bar.status:SetValue(12)
    local qr, qg, qb = 0.64, 0.21, 0.93
    local ST = F.StyleTokens
    if ST and ST.ApplyBarGradient then
        bar.status:SetStatusBarColor(1, 1, 1, 1)
        ST.ApplyBarGradient(bar.status,
            qr * 0.40, qg * 0.40, qb * 0.40,
            math_min(1, qr * 0.85 + 0.15), math_min(1, qg * 0.85 + 0.15), math_min(1, qb * 0.85 + 0.15),
            0.56)
    else
        bar.status:SetStatusBarColor(qr, qg, qb, 0.45)
    end
    if bar._spark then
        bar._spark:SetColor(math_min(1, qr * 0.5 + 0.5), math_min(1, qg * 0.5 + 0.5), math_min(1, qb * 0.5 + 0.5), 0.85)
        bar._spark:SyncAnchor()
    end
    bar.icon:SetTexture(135489)
    bar.nameText:SetText("[预览] 史诗猎人长弓")
    bar.nameText:SetTextColor(qr, qg, qb, 1)
    -- 复用的条可能残留上一次真实掷骰的禁用状态 / 倒计时 / 品质边框色
    bar._lastSec = nil
    bar._borderColor = { qr, qg, qb }
    bar.btnPass:SetEnabled(true); bar.btnPass:SetAlpha(1)
    bar.btnNeed:SetEnabled(true); bar.btnGreed:SetEnabled(true); bar.btnDis:SetEnabled(false)
    bar.btnNeed:SetAlpha(1); bar.btnGreed:SetAlpha(1); bar.btnDis:SetAlpha(0.25)
    LayoutRollButtons(bar, false)
    SetBarMouseHoverOnly(bar, true)
    if bar._animIn then
        bar._animIn:Stop()
        bar:SetAlpha(0)
        bar:Show()
        LayoutBars()
        ApplyBarBorder(bar, qr, qg, qb)
        bar._animIn:Play()
        if F.Theme and F.Theme.PlayLuminousShimmer then F.Theme.PlayLuminousShimmer(bar) end
    else
        bar:SetAlpha(1)
        bar:Show()
        LayoutBars()
        ApplyBarBorder(bar, qr, qg, qb)
    end
end

function mod:OnEnable()
    EnsureContainer()
    EnsureNativeHooks()
    self:RegisterEvent("START_LOOT_ROLL", self.OnStartRoll)
    self:RegisterEvent("CANCEL_LOOT_ROLL", self.OnCancelRoll)
    self:RegisterEvent("CANCEL_ALL_LOOT_ROLLS", function() self:OnCancelRoll(nil, nil) end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        PruneStaleRolls()
        HideNativeRollFrames()
        RecoverActiveRolls()
    end)
    RecoverActiveRolls()
    LayoutBars()
end

function mod:OnDisable()
    self:OnCancelRoll(nil, nil)
    RestoreNativeRollFrames()
end

function mod:OnThemeChanged()
    for _, bar in ipairs(bars) do
        if bar._borderColor then
            ApplyBarBorder(bar, bar._borderColor[1], bar._borderColor[2], bar._borderColor[3])
        end
    end
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
        tooltip = "多件装备同时掷点时的展开方向，默认向上避免压到双翼。",
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
