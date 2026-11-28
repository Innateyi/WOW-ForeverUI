----------------------------------------------------------------------
--  kkowoUI — Modules/ActionBarMotion.lua
--  动作条、冷却管理器与伤害统计全局圆角 + 技能按键反馈与冷却就绪脉冲：
--    • 100% 保留原有 EUI 动作条布局、键位与翻页逻辑，零写入原框体字段（全弱表）
--    • 统一 GPU 抗锯齿圆角图标/底槽/高亮/冷却裁边 + 1px 圆角细边框（自动隐藏 EUI 方形边框）
--    • 按下技能缩放回弹 + 职业色柔光边闪（C端 AnimationGroup，空技能格静默，播完归零隐藏）
--    • 冷却结束（>2s 技能，排除 GCD）触发温和脉冲提醒
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_abs, math_floor, math_max, math_min, pairs, pcall, setmetatable, type =
    ipairs, math.abs, math.floor, math.max, math.min, pairs, pcall, setmetatable, type
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("actionBarMotion", {
    title = "动作条动效",
    desc = "为动作条、冷却图标与伤害统计添加圆角、按键回弹与冷却脉冲。",
    group = "motion",
    order = 30,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        roundActionBars = true,
        roundCooldownManager = true,
        roundDamageMeters = true,
        v2DMRoundMigrated = false,
        iconRadius = 6,
        pressBounce = true,
        pressFlash = true,
        cdFinishPulse = true,
    },
})

local skinnedBtns = setmetatable({}, { __mode = "k" })
local btnList = {}
local dmBars = {}
local dmBarSeen = setmetatable({}, { __mode = "k" })
local dmFrameHooked = setmetatable({}, { __mode = "k" })
local flashOverlays = setmetatable({}, { __mode = "k" })
local hookedCDs = setmetatable({}, { __mode = "k" })
local cdLastDur = setmetatable({}, { __mode = "k" })
local hiddenEUIBorders = setmetatable({}, { __mode = "k" })
local cdmWraps = setmetatable({}, { __mode = "k" })
local cdmHiddenBorderTarget = setmetatable({}, { __mode = "k" })
local cdmBorderTargetToBtn = setmetatable({}, { __mode = "kv" })
local tbbHiddenBorderTarget = setmetatable({}, { __mode = "k" })
local tbbBorderTargetToWrap = setmetatable({}, { __mode = "kv" })
local hookedApplyBorderStyle = false
local hookedIconMask = setmetatable({}, { __mode = "k" })
local lastPressFX = setmetatable({}, { __mode = "k" })
local tbbBars = {}
local tbbSeen = setmetatable({}, { __mode = "k" })
local tbbHooked = setmetatable({}, { __mode = "k" })
local lootFeedRows = {}
local lootFeedSeen = setmetatable({}, { __mode = "k" })
local lootFeedIconWraps = setmetatable({}, { __mode = "k" })
local hookedUseAction = false
local hookedEAB = false
local hookedCDM = false
local hookedTBB = false
local slotToBtn = {}
local trackedCDs = {}

local EAB_BAR_NAMES = {
    "EABBar_MainBar", "EABBar_Bar1", "EABBar_Bar2", "EABBar_Bar3", "EABBar_Bar4",
    "EABBar_Bar5", "EABBar_Bar6", "EABBar_Bar7", "EABBar_Bar8", "EABBar_Bar9", "EABBar_Bar10",
    "EABBar_StanceBar", "EABBar_PetBar",
}

local BLIZZ_BTN_PREFIXES = {
    { prefix = "ActionButton", count = 12 },
    { prefix = "MultiBarBottomLeftButton", count = 12 },
    { prefix = "MultiBarBottomRightButton", count = 12 },
    { prefix = "MultiBarRightButton", count = 12 },
    { prefix = "MultiBarLeftButton", count = 12 },
    { prefix = "MultiBar5Button", count = 12 },
    { prefix = "MultiBar6Button", count = 12 },
    { prefix = "MultiBar7Button", count = 12 },
    { prefix = "StanceButton", count = 10 },
    { prefix = "PetActionButton", count = 10 },
}

local CDM_ROOT_NAMES = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "EllesmereUIDMIconHistoryFrame",
}

local function IsSafe(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

-- 记录我们隐藏过的 EUI 方形边框（PP 像素边框 / _bdBorderData 背板边框），停用时逐个还原，
-- 只还原自己动过、且隐藏前本来就显示着的边框。
local ppHiddenBorders = setmetatable({}, { __mode = "k" })
local bdHiddenBorders = setmetatable({}, { __mode = "k" })

local function HideEUIBorder(frame)
    if not IsSafe(frame) then return end
    local EUI = _G.EllesmereUI
    local PP = EUI and EUI.PP
    if PP and PP.HideBorder then
        if not ppHiddenBorders[frame] then
            local b = PP.GetBorders and PP.GetBorders(frame) or nil
            local wasShown = true
            if b and b.IsShown then
                local okS, s = pcall(b.IsShown, b)
                wasShown = not okS or s == true
            end
            if wasShown then ppHiddenBorders[frame] = true end
        end
        pcall(PP.HideBorder, frame)
    end
    local bd = EUI and EUI._bdBorderData and EUI._bdBorderData[frame]
    if bd and bd.Hide then
        if not bdHiddenBorders[frame] then
            local wasShown = true
            if bd.IsShown then
                local okS, s = pcall(bd.IsShown, bd)
                wasShown = not okS or s == true
            end
            if wasShown then bdHiddenBorders[frame] = true end
        end
        pcall(bd.Hide, bd)
    end
end

local function RestoreEUIBorder(frame)
    if not frame then return end
    local EUI = _G.EllesmereUI
    if ppHiddenBorders[frame] then
        ppHiddenBorders[frame] = nil
        local PP = EUI and EUI.PP
        if PP and PP.ShowBorder and IsSafe(frame) then pcall(PP.ShowBorder, frame) end
    end
    if bdHiddenBorders[frame] then
        bdHiddenBorders[frame] = nil
        local bd = EUI and EUI._bdBorderData and EUI._bdBorderData[frame]
        if bd and bd.Show then pcall(bd.Show, bd) end
    end
end

local function GetEABNS()
    local EUI = _G.EllesmereUI
    return EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIActionBars or nil
end

local function GetCDMNS()
    local EUI = _G.EllesmereUI
    return EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUICooldownManager or nil
end

local function GetCDMFrameContext(btn)
    local cdmNS = GetCDMNS()
    if not cdmNS then return nil, nil, nil, nil end
    local hi = cdmNS._hookInternals
    local fd = hi and hi.hookFrameData and hi.hookFrameData[btn] or nil
    local fc = cdmNS._ecmeFC and cdmNS._ecmeFC[btn] or nil
    local barKey = fc and fc.barKey or nil
    local barData = barKey and cdmNS.barDataByKey and cdmNS.barDataByKey[barKey] or nil
    return cdmNS, fd, fc, barData
end

local function IsTextureObj(obj)
    return IsSafe(obj) and obj.GetObjectType ~= nil and obj:GetObjectType() == "Texture"
end

local function FindButtonIcon(btn)
    if not btn then return nil end
    if IsTextureObj(btn._tex) then return btn._tex end
    if IsTextureObj(btn.icon) then return btn.icon end
    if IsTextureObj(btn.Icon) then return btn.Icon end
    -- EUI CDM 兼容：部分暴雪查看器按钮的 .Icon 是容器框体，真正的贴图在 .Icon.Icon
    if btn.Icon and type(btn.Icon) == "table" and IsTextureObj(btn.Icon.Icon) then
        return btn.Icon.Icon
    end
    local nm = btn.GetName and F.PlainString(btn:GetName(), nil)
    if nm and IsTextureObj(_G[nm .. "Icon"]) then return _G[nm .. "Icon"] end
    return nil
end

local function IsCDMBuffIcon(btn, fd, barData)
    if not btn then return false end
    local vf = btn.viewerFrame
    if vf and (vf == _G.BuffIconCooldownViewer or vf == _G.BuffBarCooldownViewer) then
        return true
    end
    if fd and fd._isBuffViewerFrame then return true end
    if barData and (barData.barType == "buffs" or barData.barType == "custom_buff" or barData.key == "buffs") then
        return true
    end
    return false
end

local function ShouldYieldCDMButton(cdmNS, btn, fd, fc, barData)
    if btn._isEmptySlotFrame then return true end
    if fd and (fd._blizzArt or fd._osnOn) then return true end
    if cdmNS and type(cdmNS.CdmBlizzIcons) == "function" then
        local okB, isBlizz = pcall(cdmNS.CdmBlizzIcons)
        if okB and isBlizz then return true end
    end
    if fc and (fc.shapeApplied or (fc.auraRound and fc.auraRound.on)) then return true end
    if barData then
        if barData.onlyShowNumbers or barData.chargesOnly then return true end
        local shape = barData.iconShape
        if shape and shape ~= "none" and shape ~= "cropped" then return true end
        local texKey = barData.borderTexture
        if texKey and texKey ~= "solid" and texKey ~= "" then return true end
    end
    return false
end

local function ResolveCDMButtonBorder(cdmNS, btn, fd, barData)
    if type(barData) ~= "table" then
        return true, 0.06, 0.07, 0.09, 0.78, 13
    end
    local borderSz = F.PlainNumber(barData.borderSize, 1) or 1
    local r = F.PlainNumber(barData.borderR, 0) or 0
    local g = F.PlainNumber(barData.borderG, 0) or 0
    local b = F.PlainNumber(barData.borderB, 0) or 0
    local a = F.PlainNumber(barData.borderA, 1) or 1
    if barData.borderClassColor then
        r, g, b = F.Theme.GetClassColor()
    end
    local ss = nil
    if cdmNS and type(cdmNS._ResolveCdmSS) == "function" then
        local okS, res = pcall(cdmNS._ResolveCdmSS, btn)
        if okS and type(res) == "table" then ss = res end
    end
    if ss then
        if ss.borderSize ~= nil then borderSz = F.PlainNumber(ss.borderSize, borderSz) or borderSz end
        if ss.borderR ~= nil then r = F.PlainNumber(ss.borderR, r) or r end
        if ss.borderG ~= nil then g = F.PlainNumber(ss.borderG, g) or g end
        if ss.borderB ~= nil then b = F.PlainNumber(ss.borderB, b) or b end
    end
    if fd and fd._activeBorderOn then
        r = (ss and F.PlainNumber(ss.activeBorderR, nil)) or 1
        g = (ss and F.PlainNumber(ss.activeBorderG, nil)) or 0.776
        b = (ss and F.PlainNumber(ss.activeBorderB, nil)) or 0.376
        a = (ss and F.PlainNumber(ss.activeBorderA, nil)) or 1
    end
    local levelOff = barData.borderBehind and -1 or 13
    return (borderSz > 0 and a > 0.02), r, g, b, a, levelOff
end

local function GetCDMSwipeFallback(cdmNS)
    if cdmNS and type(cdmNS.CdmSwipeFile) == "function" then
        local ok, path = pcall(cdmNS.CdmSwipeFile)
        if ok and type(path) == "string" then return path end
    end
    return ""
end

local function CleanupCDMButton(cdmNS, btn, cdMain)
    ST.ClearRoundedMask(btn)
    local wrap = cdmWraps[btn]
    if wrap then
        ST.ClearRoundedMask(wrap)
        wrap:Hide()
    end
    if IsSafe(cdMain) then
        ST.ClearRoundedCooldownSwipe(cdMain, GetCDMSwipeFallback(cdmNS))
    end
    local oldTarget = cdmHiddenBorderTarget[btn]
    if oldTarget then
        cdmHiddenBorderTarget[btn] = nil
        if cdmBorderTargetToBtn[oldTarget] == btn then
            cdmBorderTargetToBtn[oldTarget] = nil
        end
        RestoreEUIBorder(oldTarget)
    end
    if hiddenEUIBorders[btn] then
        hiddenEUIBorders[btn] = nil
    end
    RestoreEUIBorder(btn)
end

local function GetButtonActionSlot(btn)
    if not btn then return nil end
    local s = F.PlainNumber(btn.action, nil)
    if s and s > 0 then return s end
    if btn.GetAttribute then
        local ok, attr = pcall(btn.GetAttribute, btn, "action")
        if ok then
            s = F.PlainNumber(attr, nil)
            if s and s > 0 then return s end
        end
    end
    return nil
end

local function ButtonHasVisibleAction(btn)
    local slot = GetButtonActionSlot(btn)
    if slot and _G.HasAction then
        local ok, has = pcall(_G.HasAction, slot)
        if ok and not F.IsSecret(has) then return has == true end
    end
    local icon = FindButtonIcon(btn)
    if not (icon and icon:IsShown()) then return false end
    local okT, tex = pcall(icon.GetTexture, icon)
    return okT and tex ~= nil
end

local function EnsureFlashOverlay(btn)
    local fl = flashOverlays[btn]
    if fl then return fl end
    local host = CreateFrame("Frame", nil, btn)
    host:SetAllPoints(btn)
    host:EnableMouse(false)
    local lvl = F.PlainNumber(btn.GetFrameLevel and btn:GetFrameLevel(), 5) or 5
    host:SetFrameLevel(lvl + 8)

    local tex = host:CreateTexture(nil, "OVERLAY", nil, 6)
    tex:SetAllPoints(host)
    tex:SetTexture(ST.TEX.FLAT)
    tex:SetBlendMode("ADD")
    tex:SetAlpha(0)
    tex:Hide()

    local ag = tex:CreateAnimationGroup()
    local a1 = ag:CreateAnimation("Alpha")
    a1:SetOrder(1); a1:SetFromAlpha(0); a1:SetToAlpha(0.36); a1:SetDuration(0.04)
    local a2 = ag:CreateAnimation("Alpha")
    a2:SetOrder(2); a2:SetFromAlpha(0.36); a2:SetToAlpha(0); a2:SetDuration(0.18); a2:SetSmoothing("OUT")

    -- 严格保护基础透明度：动画开始前清零显形，结束或中止立刻归零并隐藏，杜绝残影色块滞留
    ag:SetScript("OnPlay", function()
        tex:SetAlpha(0)
        tex:Show()
    end)
    ag:SetScript("OnFinished", function()
        tex:SetAlpha(0)
        tex:Hide()
    end)
    ag:SetScript("OnStop", function()
        tex:SetAlpha(0)
        tex:Hide()
    end)

    local bloom = host:CreateTexture(nil, "OVERLAY", nil, 7)
    bloom:SetPoint("CENTER", host, "CENTER", 0, 0)
    bloom:SetTexture(ST.TEX.SOFT_GLOW)
    bloom:SetBlendMode("ADD")
    bloom:SetAlpha(0)
    bloom:Hide()

    local bag = bloom:CreateAnimationGroup()
    local b1 = bag:CreateAnimation("Alpha")
    b1:SetOrder(1); b1:SetFromAlpha(0); b1:SetToAlpha(0.68); b1:SetDuration(0.06); b1:SetSmoothing("OUT")
    local bSc = bag:CreateAnimation("Scale")
    bSc:SetOrder(1); bSc:SetOrigin("CENTER", 0, 0)
    bSc:SetScaleFrom(0.84, 0.84); bSc:SetScaleTo(1.22, 1.22); bSc:SetDuration(0.34); bSc:SetSmoothing("OUT")
    local b2 = bag:CreateAnimation("Alpha")
    b2:SetOrder(2); b2:SetFromAlpha(0.68); b2:SetToAlpha(0); b2:SetDuration(0.28); b2:SetSmoothing("OUT")
    bag:SetScript("OnPlay", function() bloom:SetAlpha(0); bloom:Show() end)
    bag:SetScript("OnFinished", function() bloom:SetAlpha(0); bloom:Hide() end)
    bag:SetScript("OnStop", function() bloom:SetAlpha(0); bloom:Hide() end)

    fl = { host = host, tex = tex, ag = ag, bloom = bloom, bag = bag }
    flashOverlays[btn] = fl
    return fl
end

local function TriggerButtonFX(btn, isCDFinish)
    if not (mod._active and IsSafe(btn) and btn:IsVisible()) then return end
    if (not isCDFinish) and (skinnedBtns[btn] == "ab") and (not ButtonHasVisibleAction(btn)) then
        return
    end
    if not isCDFinish then
        local now = GetTime()
        if lastPressFX[btn] and (now - lastPressFX[btn]) < 0.04 then return end
        lastPressFX[btn] = now
    end
    local db = mod:GetDB()
    local icon = FindButtonIcon(btn)
    if (isCDFinish and db.cdFinishPulse ~= false) or ((not isCDFinish) and db.pressBounce ~= false) then
        M.PlayScalePop(icon or btn, isCDFinish and 1.16 or 1.10, isCDFinish and 0.22 or 0.13)
    end
    if (isCDFinish and db.cdFinishPulse ~= false) or ((not isCDFinish) and db.pressFlash ~= false) then
        local fl = EnsureFlashOverlay(btn)
        local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
        -- 切忌传入第 4 参数 alpha=1！否则动画播放完毕后会回弹到基础 alpha=1 留下实心色块
        if isCDFinish then
            fl.tex:SetVertexColor(r2, g2, b2)
        else
            fl.tex:SetVertexColor(r1 * 0.45 + 0.55, g1 * 0.45 + 0.55, b1 * 0.45 + 0.55)
        end
        local rad = math_max(0, math_min(10, F.PlainNumber(db.iconRadius, ST.GetCornerRadius(6)) or 6))
        if rad > 0 then
            ST.MaskTexture(fl.host, fl.tex, rad)
        else
            ST.ClearRoundedMask(fl.host)
        end
        fl.ag:Stop()
        fl.tex:SetAlpha(0)
        fl.tex:Show()
        fl.ag:Play()
        if isCDFinish and fl.bloom and fl.bag then
            local bw = F.PlainNumber(btn.GetWidth and btn:GetWidth(), 36) or 36
            local bh = F.PlainNumber(btn.GetHeight and btn:GetHeight(), 36) or 36
            fl.bloom:SetSize(bw * 1.38, bh * 1.38)
            fl.bloom:SetVertexColor(r2, g2, b2)
            fl.bag:Stop()
            fl.bloom:SetAlpha(0)
            fl.bloom:Show()
            fl.bag:Play()
        end
    end
end

local function ResolveEABButtonBorder(eabNS, eabFD)
    local r, g, b, a = 0.06, 0.07, 0.09, 0.72
    local show = true
    local prof = eabNS and eabNS.EAB and eabNS.EAB.db and eabNS.EAB.db.profile
    local barKey = eabFD and eabFD.barKey
    local s = prof and barKey and prof.bars and prof.bars[barKey]
    if type(s) == "table" then
        if s.showBorder == false or s.borderEnabled == false then
            show = false
        end
        local mode = s.borderColorMode
        if mode == "class" then
            r, g, b = F.Theme.GetClassColor()
            a = (type(s.borderColor) == "table" and F.PlainNumber(s.borderColor.a, 0.85)) or 0.85
        elseif mode == "accent" and _G.EllesmereUI and _G.EllesmereUI.GetAccentColor then
            local okA, ar, ag, ab = pcall(_G.EllesmereUI.GetAccentColor)
            if okA and ar and ag and ab then r, g, b = ar, ag, ab end
            a = (type(s.borderColor) == "table" and F.PlainNumber(s.borderColor.a, 0.85)) or 0.85
        elseif type(s.borderColor) == "table" then
            r = F.PlainNumber(s.borderColor.r, r) or r
            g = F.PlainNumber(s.borderColor.g, g) or g
            b = F.PlainNumber(s.borderColor.b, b) or b
            a = F.PlainNumber(s.borderColor.a, a) or a
        end
    elseif type(prof) == "table" and type(prof.borderColor) == "table" then
        r = F.PlainNumber(prof.borderColor.r, r) or r
        g = F.PlainNumber(prof.borderColor.g, g) or g
        b = F.PlainNumber(prof.borderColor.b, b) or b
        a = F.PlainNumber(prof.borderColor.a, a) or a
    end
    return show, r, g, b, a
end

-- 暴雪原生 ActionBarButtonTemplate 自带 IconMask，被 EUI 置空/缩至 0.001x0.001 后一旦被 UpdateButtonArt 重新挂回就会把图标裁成纯空白。
-- 每次圆角化时确保将其与 icon 分离，并对未置空的 UpdateButtonArt 挂延迟清理钩子。
local function NeutralizeBlizzIconMask(btn, icon)
    if not (btn and icon) then return end
    local im = btn.IconMask
    if im and icon.RemoveMaskTexture then
        pcall(icon.RemoveMaskTexture, icon, im)
    end
    if im and not hookedIconMask[btn] and type(btn.UpdateButtonArt) == "function" then
        hookedIconMask[btn] = true
        _G.hooksecurefunc(btn, "UpdateButtonArt", function(self)
            if not mod._active then return end
            C_Timer.After(0, function()
                if not (mod._active and IsSafe(self)) then return end
                local ic = FindButtonIcon(self)
                if ic and self.IconMask and ic.RemoveMaskTexture then
                    pcall(ic.RemoveMaskTexture, ic, self.IconMask)
                end
            end)
        end)
    end
end

local function ApplyButtonRound(btn, enable)
    if not IsSafe(btn) then return end
    local db = mod:GetDB()
    local rad = math_max(0, math_min(10, F.PlainNumber(db.iconRadius, ST.GetCornerRadius(6)) or 6))

    -- 冷却管理器（CDM）图标走独立子框体包装：
    -- 1) 遮罩建在子框体 cdmWrap 上，不污染暴雪查看器 btn:GetRegions()，避免被 EUI HideBlizzardDecorations 刷回 WHITE8X8；
    -- 2) 正确隐藏 EUI 的 fd.borderFrame 方形框，并沿用 EUI CDM 自身的边框颜色/职业色/层级（+13，位于文字与冷却下层）；
    -- 3) 同步裁切 fd.bg 与 OutOfRange，并用 aura-swipe.tga 替代直接 AddMaskTexture 挂到 Cooldown，避免裁剪畸变与显示不完整；
    -- 4) 自动跟随 LayoutCDMBar 的动态缩放、尺寸变化（含 cropped 40x32 矩形增益图标）与特殊形状让位。
    if skinnedBtns[btn] == "cdm" then
        local cdmNS, fd, fc, barData = GetCDMFrameContext(btn)
        local icon = (fd and IsTextureObj(fd.tex) and fd.tex) or FindButtonIcon(btn)
        local cdMain = (fd and fd.cooldown) or btn._cooldown or btn.Cooldown or btn.cooldown
        if not (enable and rad > 0 and icon) or ShouldYieldCDMButton(cdmNS, btn, fd, fc, barData) then
            CleanupCDMButton(cdmNS, btn, cdMain)
            return
        end

        ST.ClearRoundedMask(btn)
        local wrap = cdmWraps[btn]
        if not wrap then
            wrap = CreateFrame("Frame", nil, btn)
            wrap:SetAllPoints(btn)
            wrap:EnableMouse(false)
            cdmWraps[btn] = wrap
        end
        local baseLvl = F.PlainNumber(btn.GetFrameLevel and btn:GetFrameLevel(), 5) or 5
        wrap:SetFrameLevel(baseLvl)
        wrap:Show()

        local bdrTarget = (fd and fd.borderFrame) or btn
        local prevTarget = cdmHiddenBorderTarget[btn]
        if prevTarget and prevTarget ~= bdrTarget then
            if cdmBorderTargetToBtn[prevTarget] == btn then
                cdmBorderTargetToBtn[prevTarget] = nil
            end
            RestoreEUIBorder(prevTarget)
        end
        cdmHiddenBorderTarget[btn] = bdrTarget
        cdmBorderTargetToBtn[bdrTarget] = btn
        HideEUIBorder(bdrTarget)
        hiddenEUIBorders[btn] = true

        ST.SetHostIconMode(wrap, true)
        local showBrd, br, bg, bb, ba, levelOff = ResolveCDMButtonBorder(cdmNS, btn, fd, barData)
        if showBrd then
            ST.ApplyRoundedBorder(wrap, rad, br, bg, bb, ba, levelOff)
        else
            ST.ApplyRoundedBorder(wrap, 0)
        end

        NeutralizeBlizzIconMask(btn, icon)
        ST.MaskIcon(wrap, icon, rad, { keepIfLoaded = true })

        local bgTex = (fd and fd.bg) or btn._bg
        if bgTex then ST.MaskTexture(wrap, bgTex, rad) end
        if btn.OutOfRange then ST.MaskTexture(wrap, btn.OutOfRange, rad) end
        if IsSafe(cdMain) then ST.ApplyRoundedCooldownSwipe(wrap, cdMain, rad) end
        return
    end

    local icon = FindButtonIcon(btn)
    if not icon then return end
    local eabNS = GetEABNS()
    local eabFD = eabNS and eabNS._eabFD and eabNS._eabFD[btn] or nil

    if enable and rad > 0 then
        -- 如果用户在 EUI 里已选定了特殊自定义形状（如六边形/圆形），则先清理旧圆角再让位，尊重用户自定义形状
        if eabFD and eabFD.shapeApplied then
            ST.ClearRoundedMask(btn)
            if hiddenEUIBorders[btn] then hiddenEUIBorders[btn] = nil end
            RestoreEUIBorder(btn)
            return
        end

        -- 图标按钮宿主使用 64x64 整图圆角遮罩（aura-masks/round-N.tga，无 9 宫格切片），
        -- 且先建立圆角描边再挂遮罩，避免先 0 缩进建遮罩、紧接着被描边重塑内缩导致二次卸挂。
        ST.SetHostIconMode(btn, true)
        HideEUIBorder(btn)
        hiddenEUIBorders[btn] = true
        local showBrd, br, bg, bb, ba = ResolveEABButtonBorder(eabNS, eabFD)
        if showBrd and ba > 0.02 then
            ST.ApplyRoundedBorder(btn, rad, br, bg, bb, ba, 6)
        else
            ST.ApplyRoundedBorder(btn, 0)
        end

        NeutralizeBlizzIconMask(btn, icon)
        ST.MaskIcon(btn, icon, rad, { keepIfLoaded = true })

        -- 严格保留用户在 EUI 动作条里设置的空技能格底色与半透明度（绝不覆写颜色，仅做圆角裁切）
        if eabFD then
            if eabFD.slotBG then ST.MaskTexture(btn, eabFD.slotBG, rad) end
            if eabFD.iconBg then ST.MaskTexture(btn, eabFD.iconBg, rad) end
        end
        if btn.SlotBackground then ST.MaskTexture(btn, btn.SlotBackground, rad) end
        if btn.HighlightTexture then ST.MaskTexture(btn, btn.HighlightTexture, rad) end
        if btn.PushedTexture then ST.MaskTexture(btn, btn.PushedTexture, rad) end
        if btn.CheckedTexture then ST.MaskTexture(btn, btn.CheckedTexture, rad) end
        if btn.NewActionTexture then ST.MaskTexture(btn, btn.NewActionTexture, rad) end
        if btn.Flash then ST.MaskTexture(btn, btn.Flash, rad) end
        if btn.Border then ST.MaskTexture(btn, btn.Border, rad) end

        -- 冷却扇形交由 StyleTokens 统一管理圆角扇形贴图（Cooldown 框体无 AddMaskTexture，须用 SetSwipeTexture + UV）
        local cdMain = btn.cooldown or btn.Cooldown
        if IsSafe(cdMain) then ST.ApplyRoundedCooldownSwipe(btn, cdMain, rad) end
        if IsSafe(btn.chargeCooldown) then ST.ApplyRoundedCooldownSwipe(btn, btn.chargeCooldown, rad) end
    else
        ST.ClearRoundedMask(btn)
        if hiddenEUIBorders[btn] then
            hiddenEUIBorders[btn] = nil
        end
        RestoreEUIBorder(btn)
    end
end

local function RegisterActionBtn(btn, isActionSlot)
    if not IsSafe(btn) then return end
    local icon = FindButtonIcon(btn)
    if not icon then return end
    if not skinnedBtns[btn] then
        skinnedBtns[btn] = isActionSlot and "ab" or "cdm"
        btnList[#btnList + 1] = btn
        if isActionSlot and btn.HookScript and btn.HasScript and btn:HasScript("OnClick") then
            btn:HookScript("OnClick", function(self)
                TriggerButtonFX(self, false)
            end)
        end
        -- 冷却管理器（CDM）图标挂载原生 Cooldown 结束爆光脉冲（仅 >2s 真实技能 CD，排除 GCD）
        local cd = (not isActionSlot) and (btn.Cooldown or btn.cooldown) or nil
        if cd and not hookedCDs[cd] and IsSafe(cd) then
            hookedCDs[cd] = true
            local ownerBtn = btn
            if cd.SetCooldown then
                _G.hooksecurefunc(cd, "SetCooldown", function(self, _, dur)
                    if F.IsSecret(dur) then
                        cdLastDur[self] = "secret"
                        return
                    end
                    local d = F.PlainNumber(dur, nil)
                    if d then cdLastDur[self] = d end
                end)
            end
            if cd.HookScript and cd.HasScript and cd:HasScript("OnCooldownDone") then
                cd:HookScript("OnCooldownDone", function(self)
                    if not (mod._active and mod:GetDB().cdFinishPulse ~= false) then return end
                    -- 增益图标倒计时结束是 BUFF 消失，不是技能冷却就绪，绝不能对其做缩放回弹
                    local _, fd, _, barData = GetCDMFrameContext(ownerBtn)
                    if IsCDMBuffIcon(ownerBtn, fd, barData) then return end
                    local d = cdLastDur[self]
                    cdLastDur[self] = nil
                    -- 仅明确 >2s 的真实技能冷却结束才闪光；dur 为机密值时无法区分 GCD，绝不误触发（P3-08a）
                    if type(d) == "number" and d > 2.0 then
                        TriggerButtonFX(ownerBtn, true)
                    end
                end)
            end
        end
    end
    if isActionSlot then
        local slot = GetButtonActionSlot(btn)
        if slot and slot > 0 then
            -- 优先保留当前可见按钮（防止被隐藏的暴雪原生 ActionButton 覆盖可见的 EAB 按钮）
            local cur = slotToBtn[slot]
            if not cur or (not IsSafe(cur)) or ((not cur:IsVisible()) and btn:IsVisible()) then
                slotToBtn[slot] = btn
            end
        end
    end
    local db = mod:GetDB()
    local want = mod._active and ((isActionSlot and db.roundActionBars ~= false) or ((not isActionSlot) and db.roundCooldownManager ~= false))
    ApplyButtonRound(btn, want)
end

-- EUI Forever Essentials 拾取播报行（EUI_LootFeed）统一圆角化：独立轻量扫描，
-- 拾取 / 金币消息只扫这一处，不再连带整套动作条与冷却管理器全量重扫。
local function RoundLootFeedRow(r)
    if not IsSafe(r) then return end
    if not lootFeedSeen[r] then
        lootFeedSeen[r] = true
        lootFeedRows[#lootFeedRows + 1] = r
        if r.HookScript then
            r:HookScript("OnShow", function(self)
                if mod._active then RoundLootFeedRow(self) end
            end)
        end
    end
    local h = F.PlainNumber(r.GetHeight and r:GetHeight(), 32) or 32
    local rad = math_min(ST.GetCornerRadius(6), math_max(4, math_floor(h * 0.25)))
    if mod._active and rad > 0 then
        if r.bg then ST.MaskTexture(r, r.bg, rad) end
        if r.bar then ST.MaskTexture(r, r.bar, rad) end
        HideEUIBorder(r)
        if r.icon then
            local iw = lootFeedIconWraps[r]
            if not iw then
                iw = CreateFrame("Frame", nil, r)
                iw:EnableMouse(false)
                iw:SetFrameLevel((F.PlainNumber(r:GetFrameLevel(), 4) or 4) + 2)
                lootFeedIconWraps[r] = iw
            end
            iw:ClearAllPoints()
            iw:SetPoint("TOPLEFT", r.icon, "TOPLEFT", 0, 0)
            iw:SetPoint("BOTTOMRIGHT", r.icon, "BOTTOMRIGHT", 0, 0)
            iw:Show()
            ST.SetHostIconMode(iw, true)
            ST.ApplyRoundedBorder(iw, 4, 0.12, 0.14, 0.18, 0.80, 3)
            ST.MaskIcon(iw, r.icon, 4)
            if r.iconBg then ST.MaskTexture(iw, r.iconBg, 4) end
        end
    else
        ST.ClearRoundedMask(r)
        RestoreEUIBorder(r)
        local iw = lootFeedIconWraps[r]
        if iw then ST.ClearRoundedMask(iw); iw:Hide() end
    end
end

local function ScanLootFeed()
    local EUI = _G.EllesmereUI
    local unlockReg = EUI and EUI._unlockRegisteredElements
    if type(unlockReg) ~= "table" then return end
    for _, el in ipairs(unlockReg) do
        if type(el) == "table" and el.key == "EUI_LootFeed" and type(el.getFrame) == "function" then
            local okF, lf = pcall(el.getFrame)
            if okF and IsSafe(lf) and lf.GetChildren then
                for _, ch in ipairs({ lf:GetChildren() }) do
                    if IsSafe(ch) and (ch.bg or ch.icon) then
                        RoundLootFeedRow(ch)
                    end
                end
            end
            break
        end
    end
end

-- 冷却管理器（CDM）图标：同时扫描暴雪查看器子框体与 EUI cdmBarIcons（含自定义/饰品/占位图标）
local function ScanCDMIcons(onlyNew)
    local seen = {}
    local function VisitCDM(ch)
        if not IsSafe(ch) or seen[ch] then return end
        seen[ch] = true
        if onlyNew and skinnedBtns[ch] then return end
        if ch._isEmptySlotFrame then
            if skinnedBtns[ch] == "cdm" then ApplyButtonRound(ch, false) end
            return
        end
        local _, fd = GetCDMFrameContext(ch)
        if (fd and IsTextureObj(fd.tex)) or FindButtonIcon(ch) then
            RegisterActionBtn(ch, false)
        end
    end

    for _, cdmName in ipairs(CDM_ROOT_NAMES) do
        local root = _G[cdmName]
        if IsSafe(root) and root.GetChildren then
            for _, ch in ipairs({ root:GetChildren() }) do
                VisitCDM(ch)
            end
        end
    end

    local cdmNS = GetCDMNS()
    local barIcons = cdmNS and (cdmNS.cdmBarIcons or (cdmNS._internals and cdmNS._internals.cdmBarIcons))
    if type(barIcons) == "table" then
        for _, list in pairs(barIcons) do
            if type(list) == "table" then
                for _, ch in ipairs(list) do
                    VisitCDM(ch)
                end
            end
        end
    end
end

local function FindTBBConfig(cdmNS, wrap)
    if not (cdmNS and wrap) then return nil end
    local bi = cdmNS._buffBarInternals
    local frames = bi and bi.tbbFrames
    if type(frames) ~= "table" or type(cdmNS.GetTrackedBuffBars) ~= "function" then return nil end
    local okT, tbb = pcall(cdmNS.GetTrackedBuffBars)
    local bars = okT and type(tbb) == "table" and tbb.bars or nil
    if type(bars) ~= "table" then return nil end
    for idx, fr in ipairs(frames) do
        if fr == wrap then return bars[idx] end
    end
    return nil
end

local function ShouldYieldTrackedBar(cdmNS, wrap, cfg)
    if wrap._blizzIconOverlay or wrap._classicArt or wrap._roundRadius then return true end
    if cdmNS and type(cdmNS.CdmBlizzBars) == "function" then
        local okB, isBlizz = pcall(cdmNS.CdmBlizzBars)
        if okB and isBlizz then return true end
    end
    if type(cfg) == "table" then
        local bSz = F.PlainNumber(cfg.borderSize, 0) or 0
        local texKey = cfg.borderTexture
        if bSz > 0 and texKey and texKey ~= "solid" and texKey ~= "" then return true end
    end
    return false
end

local function DisablePixelSnap(obj)
    if not obj then return end
    if obj.SetSnapToPixelGrid then pcall(obj.SetSnapToPixelGrid, obj, false) end
    if obj.SetTexelSnappingBias then pcall(obj.SetTexelSnappingBias, obj, 0) end
end

-- 追踪冷却条（ECME_TBBWrap*）模块级圆角化（实时读取当前半径与开关状态，避免闭包捕获过期设置）
local function RoundTrackedBar(wrap, forceDisable)
    if not (IsSafe(wrap) and IsSafe(wrap._bar)) then return end
    if not tbbSeen[wrap] then
        tbbSeen[wrap] = true
        tbbBars[#tbbBars + 1] = wrap
    end
    if not tbbHooked[wrap] and wrap.HookScript then
        tbbHooked[wrap] = true
        wrap:HookScript("OnShow", function(self)
            if mod._active then
                RoundTrackedBar(self)
            end
        end)
    end
    local sb = wrap._bar
    local cdmNS = GetCDMNS()
    local cfg = FindTBBConfig(cdmNS, wrap)
    local h = F.PlainNumber(sb.GetHeight and sb:GetHeight(), 20) or 20
    local globalRad = ST.GetCornerRadius(6)
    local wantCDM = (not forceDisable) and mod._active and mod:GetDB().roundCooldownManager ~= false and not ShouldYieldTrackedBar(cdmNS, wrap, cfg)
    -- 无论是否圆角，只要启用模块就关闭追踪条主填充/渐变/光刃的像素网格吸附，
    -- 消除 15~30s 低速冷却条按整像素逐格跳动的顿挫感（EUI 仅关闭了 spark 而漏掉了 fillTex）
    if (not forceDisable) and mod._active then
        local ft0 = sb.GetStatusBarTexture and sb:GetStatusBarTexture() or nil
        DisablePixelSnap(sb)
        DisablePixelSnap(ft0)
        DisablePixelSnap(wrap._gradClip)
        DisablePixelSnap(wrap._gradTex)
        DisablePixelSnap(wrap._spark)
        if type(wrap._threshOverlays) == "table" then
            for _, ov in ipairs(wrap._threshOverlays) do
                if IsSafe(ov) then
                    DisablePixelSnap(ov)
                    if ov.GetStatusBarTexture then DisablePixelSnap(ov:GetStatusBarTexture()) end
                end
            end
        end
    end
    local rad = math_min(globalRad, math_max(3, math_floor(h * 0.44)))
    if wantCDM and rad > 0 then
        local ft = sb.GetStatusBarTexture and sb:GetStatusBarTexture() or nil
        if ft then ST.MaskTexture(sb, ft, rad) end
        if wrap._bg then ST.MaskTexture(sb, wrap._bg, rad) end
        if wrap._gradTex then ST.MaskTexture(sb, wrap._gradTex, rad) end
        if wrap._spark then ST.MaskTexture(sb, wrap._spark, rad) end
        if type(wrap._threshOverlays) == "table" then
            for _, ov in ipairs(wrap._threshOverlays) do
                if IsSafe(ov) and ov.GetStatusBarTexture then
                    local ovTex = ov:GetStatusBarTexture()
                    if ovTex then ST.MaskTexture(sb, ovTex, rad) end
                end
            end
        end
        HideEUIBorder(sb)
        if IsSafe(wrap._barBorder) then
            tbbHiddenBorderTarget[wrap] = wrap._barBorder
            tbbBorderTargetToWrap[wrap._barBorder] = wrap
            HideEUIBorder(wrap._barBorder)
        end
        local br, bg, bb, ba = 0.08, 0.10, 0.14, 0.72
        if type(cfg) == "table" and (F.PlainNumber(cfg.borderSize, 0) or 0) > 0 then
            br = F.PlainNumber(cfg.borderR, 0) or 0
            bg = F.PlainNumber(cfg.borderG, 0) or 0
            bb = F.PlainNumber(cfg.borderB, 0) or 0
            ba = 0.90
        end
        ST.ApplyRoundedBorder(sb, rad, br, bg, bb, ba, 6)

        local icFrame = wrap._icon or wrap.icon
        if IsSafe(icFrame) and not icFrame._endMask and not icFrame._roundSide then
            local iRad = math_min(rad, 5)
            ST.SetHostIconMode(icFrame, true)
            HideEUIBorder(icFrame)
            ST.ApplyRoundedBorder(icFrame, iRad, br, bg, bb, math_max(ba, 0.78), 5)
            if IsTextureObj(icFrame._tex) then
                ST.MaskIcon(icFrame, icFrame._tex, iRad)
            elseif icFrame.GetRegions then
                for _, reg in ipairs({ icFrame:GetRegions() }) do
                    if IsSafe(reg) and IsTextureObj(reg) and not (reg.IsObjectType and reg:IsObjectType("MaskTexture")) then
                        local layer = reg.GetDrawLayer and reg:GetDrawLayer() or nil
                        if layer == "ARTWORK" or layer == "BACKGROUND" then
                            ST.MaskIcon(icFrame, reg, iRad)
                        end
                    end
                end
            end
        end
    else
        ST.ClearRoundedMask(sb)
        RestoreEUIBorder(sb)
        local bdr = tbbHiddenBorderTarget[wrap] or wrap._barBorder
        tbbHiddenBorderTarget[wrap] = nil
        if bdr and tbbBorderTargetToWrap[bdr] == wrap then
            tbbBorderTargetToWrap[bdr] = nil
        end
        if IsSafe(bdr) then RestoreEUIBorder(bdr) end
        local icFrame = wrap._icon or wrap.icon
        if IsSafe(icFrame) then
            ST.ClearRoundedMask(icFrame)
            RestoreEUIBorder(icFrame)
        end
    end
end

local function ScanTrackedBuffBars()
    local cdmNS = GetCDMNS()
    local tbbList = cdmNS and cdmNS._buffBarInternals and cdmNS._buffBarInternals.tbbFrames
    local seen = {}
    if type(tbbList) == "table" then
        for _, wrap in ipairs(tbbList) do
            if wrap and not seen[wrap] then
                seen[wrap] = true
                RoundTrackedBar(wrap)
            end
        end
    end
    for i = 1, 30 do
        local w = _G["ECME_TBBWrap" .. i]
        if w and not seen[w] then
            seen[w] = true
            RoundTrackedBar(w)
        end
    end
end

local function ScanButtons()
    for k in pairs(slotToBtn) do slotToBtn[k] = nil end
    local seenAB = setmetatable({}, { __mode = "k" })

    local function VisitAB(btn)
        if IsSafe(btn) and not seenAB[btn] and FindButtonIcon(btn) then
            seenAB[btn] = true
            RegisterActionBtn(btn, true)
        end
    end

    -- 1) 优先直接遍历 EllesmereUIActionBars 维护的全部动作条按钮表（含主条 MainBar / Bar2-8 / 宠物条 / 姿态条）
    local eabNS = GetEABNS()
    if eabNS and type(eabNS.barButtons) == "table" then
        for _, list in pairs(eabNS.barButtons) do
            if type(list) == "table" then
                for _, btn in ipairs(list) do
                    VisitAB(btn)
                end
            end
        end
    end

    -- 2) 兜底遍历 EABBar_* 容器子框体
    for _, barName in ipairs(EAB_BAR_NAMES) do
        local bar = _G[barName]
        if IsSafe(bar) and bar.GetChildren then
            for _, ch in ipairs({ bar:GetChildren() }) do
                if IsSafe(ch) and ch.GetObjectType and (ch:GetObjectType() == "CheckButton" or ch:GetObjectType() == "Button") then
                    VisitAB(ch)
                end
            end
        end
    end

    -- 3) 兜底遍历暴雪原生动作条/宠物条/姿态条按钮名（兼容主条 nativeMainBar 与 EAB 接管按钮）
    for _, spec in ipairs(BLIZZ_BTN_PREFIXES) do
        for i = 1, spec.count do
            local btn = _G[spec.prefix .. i]
            if btn then VisitAB(btn) end
        end
    end

    -- 4) 冷却管理器图标 + 追踪冷却条（ECME_TBBWrap*）统一圆角（解决图 5 冷却条为直角）
    local db = mod:GetDB()
    local globalRad = ST.GetCornerRadius(6)

    ScanCDMIcons(false)
    ScanTrackedBuffBars()

    -- 4b) EUI Forever Essentials 拾取播报行（EUI_LootFeed）统一圆角化（解决图 6 拾取信息直角）
    ScanLootFeed()

    -- 5) 伤害统计进度条行圆角美化（遍历 EllesmereUIDMFrame1..4 内每一条伤害条 StatusBar）
    local wantDM = mod._active and db.roundDamageMeters ~= false

    local function RoundDMStatusBar(sb)
        if not IsSafe(sb) then return end
        if not dmBarSeen[sb] then
            dmBarSeen[sb] = true
            dmBars[#dmBars + 1] = sb
        end
        local h = F.PlainNumber(sb.GetHeight and sb:GetHeight(), 18) or 18
        local rad = math_min(globalRad, math_max(3, math_floor(h * 0.42)))
        if wantDM and rad > 0 then
            local ft = sb.GetStatusBarTexture and sb:GetStatusBarTexture() or nil
            if ft then ST.MaskTexture(sb, ft, rad) end
            if sb.GetRegions then
                for _, reg in ipairs({ sb:GetRegions() }) do
                    if IsSafe(reg) and reg.GetObjectType and reg:GetObjectType() == "Texture" and reg ~= ft then
                        local layer = reg.GetDrawLayer and reg:GetDrawLayer()
                        if layer == "BACKGROUND" then
                            ST.MaskTexture(sb, reg, rad)
                        end
                    end
                end
            end
            ST.ApplyRoundedBorder(sb, rad, 0.02, 0.024, 0.036, 0.68, 4)
        else
            ST.ClearRoundedMask(sb)
        end
    end

    local function WalkDMTree(frame, depth)
        if not (IsSafe(frame) and depth <= 4 and frame.GetChildren) then return end
        for _, ch in ipairs({ frame:GetChildren() }) do
            if IsSafe(ch) then
                if ch.GetObjectType and ch:GetObjectType() == "StatusBar" then
                    RoundDMStatusBar(ch)
                elseif ch.GetChildren then
                    WalkDMTree(ch, depth + 1)
                end
            end
        end
    end

    for i = 1, 4 do
        local dm = _G["EllesmereUIDMFrame" .. i]
        if IsSafe(dm) then
            ST.ClearRoundedMask(dm)
            if not dmFrameHooked[dm] and dm.HookScript then
                dmFrameHooked[dm] = true
                dm:HookScript("OnShow", function()
                    if mod._active then
                        C_Timer.After(0.05, function() if mod._active then ScanButtons() end end)
                    end
                end)
            end
            WalkDMTree(dm, 1)
        end
    end
end

-- 12.x：优先 C_ActionBar.GetActionCooldown（isEnabled 为布尔值，战斗中可能是保密值）；
-- 旧版 GetActionCooldown 的 enable 在新客户端同样是布尔值，绝不能写成 `enable == 1`。
local function ReadActionCooldown(slot)
    local CAB = _G.C_ActionBar
    if CAB and CAB.GetActionCooldown then
        local ok, info = pcall(CAB.GetActionCooldown, slot)
        if ok then
            if F.IsSecret(info) then return nil, nil, true end
            if type(info) == "table" then
                local en = info.isEnabled
                if F.IsSecret(en) or F.IsSecret(info.startTime) or F.IsSecret(info.duration) then
                    return nil, nil, true
                end
                if en == false then return nil, nil, false end
                return F.PlainNumber(info.startTime, nil), F.PlainNumber(info.duration, nil), false
            end
        end
    end
    if _G.GetActionCooldown then
        local ok, s, d, en = pcall(_G.GetActionCooldown, slot)
        if ok then
            if F.IsSecret(en) or F.IsSecret(s) or F.IsSecret(d) then
                return nil, nil, true
            end
            if en == 1 or en == true then
                return F.PlainNumber(s, nil), F.PlainNumber(d, nil), false
            end
        end
    end
    return nil, nil, false
end

local function RefreshCooldownWatches()
    if not (mod._active and mod:GetDB().cdFinishPulse ~= false) then return end
    local now = GetTime()
    for slot, btn in pairs(slotToBtn) do
        if IsSafe(btn) and btn:IsVisible() then
            local start, dur, isSecret = ReadActionCooldown(slot)
            if not isSecret then
                start = start or 0
                dur = dur or 0
                if start > 0 and dur > 2.0 then
                    local endAt = start + dur
                    local prevEnd = trackedCDs[slot]
                    if not prevEnd or math_abs(endAt - prevEnd) > 0.35 then
                        trackedCDs[slot] = endAt
                        local delay = endAt - now
                        if delay > 0.1 and delay < 180 then
                            local sKey = slot
                            local expectEnd = endAt
                            C_Timer.After(delay, function()
                                if not (mod._active and mod:GetDB().cdFinishPulse ~= false) then return end
                                if trackedCDs[sKey] ~= expectEnd then return end
                                trackedCDs[sKey] = nil
                                local b = slotToBtn[sKey]
                                if b then TriggerButtonFX(b, true) end
                            end)
                        end
                    end
                else
                    trackedCDs[slot] = nil
                end
            end
        end
    end
end

local QueueScan = F.Debounce(0.20, function() if mod._active then ScanButtons() end end)
local QueueCDCheck = F.Debounce(0.18, RefreshCooldownWatches)
local QueueLootScan = F.Debounce(0.15, function() if mod._active then ScanLootFeed() end end)
local QueueCDMScan = F.Debounce(0.12, function() if mod._active then ScanCDMIcons(true) end end)
local QueueCDMResync = F.Debounce(0.08, function() if mod._active then ScanCDMIcons(false) end end)
local QueueTBBScan = F.Debounce(0.10, function() if mod._active then ScanTrackedBuffBars() end end)
local cdmLayoutHooked = setmetatable({}, { __mode = "k" })

local function InstallEABHooks()
    if not hookedEAB then
        local eabNS = GetEABNS()
        local eab = eabNS and eabNS.EAB
        if eab or (eabNS and type(eabNS._eabApplyAll) == "function") then
            hookedEAB = true
            if eab then
                for _, fnName in ipairs({
                    "ApplyBorders", "ApplyBordersForBar", "ApplyShapes", "ApplyShapesForBar",
                    "ApplyBackgroundForBar", "ApplyIconBackgroundForBar", "ApplyButtonSizeForBar",
                    "ApplyAll", "ApplyBar", "ApplyBarStyle", "RefreshAll",
                }) do
                    if type(eab[fnName]) == "function" then
                        _G.hooksecurefunc(eab, fnName, function()
                            if mod._active then QueueScan() end
                        end)
                    end
                end
            end
            if eabNS and type(eabNS._eabApplyAll) == "function" then
                _G.hooksecurefunc(eabNS, "_eabApplyAll", function()
                    if mod._active then QueueScan() end
                end)
            end
        end
    end
    local EUI = _G.EllesmereUI
    if EUI and not hookedApplyBorderStyle and type(EUI.ApplyBorderStyle) == "function" then
        hookedApplyBorderStyle = true
        -- 兜底捕获 EUI 通过文件内局部上值调用 DecorateFrame / ApplyShapeToCDMIcon / ApplyTrackedBuffBarSettings
        -- 重新刷回方形边框的所有路径（零污染，O(1) 弱表查表，已接管目标即时隐藏避免 1 帧方框闪烁）
        _G.hooksecurefunc(EUI, "ApplyBorderStyle", function(target, _, _, _, _, _, _, _, _, _, _, scope)
            if not (mod._active and target) then return end
            if cdmBorderTargetToBtn[target] then
                HideEUIBorder(target)
                QueueCDMResync()
                return
            end
            if tbbBorderTargetToWrap[target] then
                HideEUIBorder(target)
                QueueTBBScan()
                return
            end
            if scope == "cdm" then
                QueueCDMResync()
            end
        end)
        if type(EUI.SetBorderStyleColor) == "function" then
            _G.hooksecurefunc(EUI, "SetBorderStyleColor", function(target)
                if mod._active and target and cdmBorderTargetToBtn[target] then
                    QueueCDMResync()
                end
            end)
        end
    end
    local cdmNS = GetCDMNS()
    if cdmNS then
        if not hookedTBB then
            hookedTBB = true
            if type(cdmNS.BuildTrackedBuffBars) == "function" then
                _G.hooksecurefunc(cdmNS, "BuildTrackedBuffBars", function()
                    if mod._active then QueueTBBScan() end
                end)
            end
            local bi = cdmNS._buffBarInternals
            if bi and type(bi.ApplyTrackedBuffBarSettings) == "function" then
                _G.hooksecurefunc(bi, "ApplyTrackedBuffBarSettings", function()
                    if mod._active then QueueTBBScan() end
                end)
            end
        end
        if not hookedCDM and (type(cdmNS.LayoutCDMBar) == "function" or type(cdmNS.RefreshCDMIconAppearance) == "function") then
            hookedCDM = true
            for _, fnName in ipairs({
                "RefreshCDMIconAppearance",
                "LayoutCDMBar",
                "BuildAllCDMBars",
                "CollectAndReanchor",
            }) do
                if type(cdmNS[fnName]) == "function" then
                    _G.hooksecurefunc(cdmNS, fnName, function()
                        if mod._active then QueueCDMResync() end
                    end)
                end
            end
        end
    end
    -- 冷却管理器图标在重排时才会新建：只挂 RefreshLayout（绝不挂 BuffIconCooldownViewer.Layout，避免暴雪内部调用污染）
    for _, cdmName in ipairs(CDM_ROOT_NAMES) do
        local root = _G[cdmName]
        if IsSafe(root) and not cdmLayoutHooked[root] then
            local hooks = (cdmName == "BuffIconCooldownViewer") and { "RefreshLayout" } or { "RefreshLayout", "Layout" }
            for _, fnName in ipairs(hooks) do
                if type(root[fnName]) == "function" then
                    cdmLayoutHooked[root] = true
                    _G.hooksecurefunc(root, fnName, function()
                        if mod._active then QueueCDMScan() end
                    end)
                end
            end
        end
    end
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2DMRoundMigrated then
        db.v2DMRoundMigrated = true
        db.roundDamageMeters = true
    end

    if not hookedUseAction and type(_G.UseAction) == "function" then
        hookedUseAction = true
        _G.hooksecurefunc("UseAction", function(slot)
            if not mod._active then return end
            local s = F.PlainNumber(slot, nil)
            local btn = s and slotToBtn[s] or nil
            if btn then TriggerButtonFX(btn, false) end
        end)
    end
    InstallEABHooks()

    self:RegisterEvent("ACTIONBAR_SLOT_CHANGED", QueueScan)
    self:RegisterEvent("ACTIONBAR_PAGE_CHANGED", QueueScan)
    self:RegisterEvent("UPDATE_BONUS_ACTIONBAR", QueueScan)
    self:RegisterEvent("PET_BAR_UPDATE", QueueScan)
    self:RegisterEvent("UPDATE_SHAPESHIFT_FORMS", QueueScan)
    -- 冷却事件只更新冷却就绪提醒；整套按钮扫描只在布局类事件（换槽 / 翻页 / 进出战 / 队伍变化）时做，
    -- 不再随每次公共冷却在战斗中每秒全量重扫数次
    self:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN", QueueCDCheck)
    self:RegisterEvent("SPELLS_CHANGED", QueueScan)
    self:RegisterEvent("CHAT_MSG_LOOT", QueueLootScan)
    self:RegisterEvent("CHAT_MSG_MONEY", QueueLootScan)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", QueueScan)
    self:RegisterEvent("GROUP_ROSTER_UPDATE", QueueScan)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        InstallEABHooks()
        QueueScan()
        C_Timer.After(1.2, function() if mod._active then ScanButtons() end end)
    end)

    ScanButtons()
    C_Timer.After(1.0, function() if mod._active then InstallEABHooks(); ScanButtons() end end)
end

function mod:OnDisable()
    for k in pairs(trackedCDs) do trackedCDs[k] = nil end
    for _, btn in ipairs(btnList) do
        if IsSafe(btn) then
            local fl = flashOverlays[btn]
            if fl then
                if fl.ag then fl.ag:Stop() end
                if fl.tex then fl.tex:SetAlpha(0); fl.tex:Hide() end
                if fl.bag then fl.bag:Stop() end
                if fl.bloom then fl.bloom:SetAlpha(0); fl.bloom:Hide() end
            end
            ApplyButtonRound(btn, false)
        end
    end
    for _, sb in ipairs(dmBars) do
        if IsSafe(sb) then ST.ClearRoundedMask(sb) end
    end
    for _, wrap in ipairs(tbbBars) do
        if IsSafe(wrap) then
            RoundTrackedBar(wrap, true)
        end
    end
    for _, r in ipairs(lootFeedRows) do
        if IsSafe(r) then
            ST.ClearRoundedMask(r)
            local iw = lootFeedIconWraps[r]
            if iw then ST.ClearRoundedMask(iw); iw:Hide() end
        end
    end
    for i = 1, 4 do
        local dm = _G["EllesmereUIDMFrame" .. i]
        if IsSafe(dm) then ST.ClearRoundedMask(dm) end
    end
    -- 还原所有被我们隐藏过的 EUI 方形边框（冷却追踪条及其图标、拾取播报行、动作条按钮）
    local toRestore = {}
    for fr in pairs(ppHiddenBorders) do toRestore[#toRestore + 1] = fr end
    for fr in pairs(bdHiddenBorders) do
        if not ppHiddenBorders[fr] then toRestore[#toRestore + 1] = fr end
    end
    for _, fr in ipairs(toRestore) do RestoreEUIBorder(fr) end
end

function mod:OnRefresh()
    ScanButtons()
end

function mod:OnThemeChanged()
    ScanButtons()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "slider",
        text = "图标圆角半径（px）",
        min = 0, max = 10, step = 1,
        getValue = function() return F.PlainNumber(db.iconRadius, 6) or 6 end,
        setValue = function(v) db.iconRadius = math_floor(v + 0.5); ScanButtons() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "动作条圆角描边",
        tooltip = "为主动作条、宠物条、姿态条与空格应用圆角与细描边。",
        getValue = function() return db.roundActionBars ~= false end,
        setValue = function(v) db.roundActionBars = v == true; ScanButtons() end,
    }, {
        type = "toggle",
        text = "冷却与统计圆角",
        getValue = function() return db.roundCooldownManager ~= false end,
        setValue = function(v)
            db.roundCooldownManager = v == true
            db.roundDamageMeters = v == true
            ScanButtons()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "按键回弹边闪",
        tooltip = "仅对有技能的动作格生效，空技能格不会触发闪烁。",
        getValue = function() return db.pressBounce ~= false end,
        setValue = function(v) db.pressBounce = v == true; db.pressFlash = v == true end,
    }, {
        type = "toggle",
        text = "冷却完成脉冲",
        getValue = function() return db.cdFinishPulse ~= false end,
        setValue = function(v) db.cdFinishPulse = v == true end,
    })
    y = y - h

    return y
end
