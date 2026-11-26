----------------------------------------------------------------------
--  kkowoUI — Modules/ActionBarMotion.lua
--  动作条、冷却管理器与伤害统计全局圆角 + 技能按键反馈与冷却就绪脉冲：
--    • 100% 保留原有 EUI 动作条布局、键位与翻页逻辑，零写入原框体字段（全弱表）
--    • 统一 GPU 抗锯齿圆角图标/底槽/高亮/冷却裁边 + 1px 圆角细边框（自动隐藏 EUI 方形边框）
--    • 按下技能缩放回弹 + 职业色柔光边闪（C端 AnimationGroup，空技能格静默，播完归零隐藏）
--    • 冷却结束（>2s 技能，排除 GCD）触发温和脉冲提醒
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_min, pairs, pcall, setmetatable, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, setmetatable, type
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("actionBarMotion", {
    title = "动作条与冷却条圆角动效",
    desc = "为 EUI 动作条、冷却管理器图标及伤害统计条施加统一抗锯齿圆角裁边、按键缩放回弹、职业色点击边闪与冷却完成脉冲。",
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
local maskedCDMap = setmetatable({}, { __mode = "k" })
local tbbBars = {}
local tbbSeen = setmetatable({}, { __mode = "k" })
local tbbHooked = setmetatable({}, { __mode = "k" })
local lootFeedRows = {}
local lootFeedSeen = setmetatable({}, { __mode = "k" })
local lootFeedIconWraps = setmetatable({}, { __mode = "k" })
local hookedUseAction = false
local hookedEAB = false
local hookedCDM = false
local slotToBtn = {}
local trackedCDs = {}

local EAB_BAR_NAMES = {
    "EABBar_MainBar", "EABBar_Bar1", "EABBar_Bar2", "EABBar_Bar3", "EABBar_Bar4",
    "EABBar_Bar5", "EABBar_Bar6", "EABBar_Bar7", "EABBar_Bar8",
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

local function GetEABNS()
    local EUI = _G.EllesmereUI
    return EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIActionBars or nil
end

local function FindButtonIcon(btn)
    if btn.icon and btn.icon.GetObjectType and btn.icon:GetObjectType() == "Texture" then
        return btn.icon
    end
    if btn.Icon and btn.Icon.GetObjectType and btn.Icon:GetObjectType() == "Texture" then
        return btn.Icon
    end
    local nm = btn.GetName and F.PlainString(btn:GetName(), nil)
    if nm and _G[nm .. "Icon"] then return _G[nm .. "Icon"] end
    return nil
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
        if ok then return has == true end
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

    fl = { host = host, tex = tex, ag = ag }
    flashOverlays[btn] = fl
    return fl
end

local function TriggerButtonFX(btn, isCDFinish)
    if not (mod._active and IsSafe(btn) and btn:IsVisible()) then return end
    if (not isCDFinish) and (skinnedBtns[btn] == "ab") and (not ButtonHasVisibleAction(btn)) then
        return
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
        local rad = math_min(ST.GetCornerRadius(db.iconRadius or 6), 10)
        if rad > 0 then ST.MaskTexture(fl.host, fl.tex, rad) end
        fl.ag:Stop()
        fl.tex:SetAlpha(0)
        fl.tex:Show()
        fl.ag:Play()
    end
end

local function MaskCooldownObj(btn, cd, mask, enable)
    if not (cd and IsSafe(cd)) then return end
    local rec = maskedCDMap[btn]
    if enable and mask then
        if not rec then
            rec = {}
            maskedCDMap[btn] = rec
        end
        if rec[cd] ~= mask then
            if rec[cd] and cd.RemoveMaskTexture then
                pcall(cd.RemoveMaskTexture, cd, rec[cd])
            end
            if cd.AddMaskTexture then
                pcall(cd.AddMaskTexture, cd, mask)
                rec[cd] = mask
            end
        end
    elseif rec and rec[cd] then
        if cd.RemoveMaskTexture then
            pcall(cd.RemoveMaskTexture, cd, rec[cd])
        end
        rec[cd] = nil
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

local function ApplyButtonRound(btn, enable)
    if not IsSafe(btn) then return end
    local icon = FindButtonIcon(btn)
    if not icon then return end
    local db = mod:GetDB()
    local rad = math_max(0, math_min(10, F.PlainNumber(db.iconRadius, ST.GetCornerRadius(6)) or 6))
    local EUI = _G.EllesmereUI
    local PP = EUI and EUI.PP
    local eabNS = GetEABNS()
    local eabFD = eabNS and eabNS._eabFD and eabNS._eabFD[btn] or nil

    if enable and rad > 0 then
        -- 如果用户在 EUI 里已选定了特殊自定义形状（如六边形/圆形），则尊重用户自定义形状不强覆盖
        if eabFD and eabFD.shapeApplied then
            return
        end

        local mask = ST.EnsureRoundedMask(btn, rad)
        ST.MaskTexture(btn, icon, rad)

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

        -- 冷却扇形同样裁切为圆角
        if mask then
            MaskCooldownObj(btn, btn.cooldown or btn.Cooldown, mask, true)
            MaskCooldownObj(btn, btn.chargeCooldown, mask, true)
        end

        -- 隐藏 EUI 原生直角框，沿用用户自己在 EUI 里设置的边框颜色与透明度重绘圆角细框
        if skinnedBtns[btn] == "ab" then
            if PP and PP.HideBorder then
                pcall(PP.HideBorder, btn)
                hiddenEUIBorders[btn] = true
            end
            if EUI and EUI._bdBorderData and EUI._bdBorderData[btn] then
                pcall(EUI._bdBorderData[btn].Hide, EUI._bdBorderData[btn])
                hiddenEUIBorders[btn] = true
            end
            local showBrd, br, bg, bb, ba = ResolveEABButtonBorder(eabNS, eabFD)
            if showBrd and ba > 0.02 then
                ST.ApplyRoundedBorder(btn, rad, br, bg, bb, ba, 6)
            else
                ST.ApplyRoundedBorder(btn, 0)
            end
        else
            ST.ApplyRoundedBorder(btn, rad, 0.06, 0.07, 0.09, 0.78, 6)
        end
    else
        MaskCooldownObj(btn, btn.cooldown or btn.Cooldown, nil, false)
        MaskCooldownObj(btn, btn.chargeCooldown, nil, false)
        ST.ClearRoundedMask(btn)
        if hiddenEUIBorders[btn] then
            hiddenEUIBorders[btn] = nil
            if PP and PP.ShowBorder then pcall(PP.ShowBorder, btn) end
        end
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
                    local d = F.PlainNumber(dur, nil)
                    if d then cdLastDur[self] = d end
                end)
            end
            if cd.HookScript and cd.HasScript and cd:HasScript("OnCooldownDone") then
                cd:HookScript("OnCooldownDone", function(self)
                    if not (mod._active and mod:GetDB().cdFinishPulse ~= false) then return end
                    local d = cdLastDur[self]
                    if d == nil or d > 2.0 then
                        cdLastDur[self] = nil
                        TriggerButtonFX(ownerBtn, true)
                    end
                end)
            end
        end
    end
    if isActionSlot then
        local slot = GetButtonActionSlot(btn)
        if slot and slot > 0 then slotToBtn[slot] = btn end
    end
    local db = mod:GetDB()
    local want = mod._active and ((isActionSlot and db.roundActionBars ~= false) or ((not isActionSlot) and db.roundCooldownManager ~= false))
    ApplyButtonRound(btn, want)
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
    local wantCDM = mod._active and db.roundCooldownManager ~= false
    local EUI = _G.EllesmereUI
    local PP = EUI and EUI.PP

    for _, cdmName in ipairs(CDM_ROOT_NAMES) do
        local root = _G[cdmName]
        if IsSafe(root) and root.GetChildren then
            for _, ch in ipairs({ root:GetChildren() }) do
                if IsSafe(ch) and FindButtonIcon(ch) then
                    RegisterActionBtn(ch, false)
                end
            end
        end
    end

    local function RoundTrackedBar(wrap)
        if not (IsSafe(wrap) and IsSafe(wrap._bar)) then return end
        if not tbbSeen[wrap] then
            tbbSeen[wrap] = true
            tbbBars[#tbbBars + 1] = wrap
        end
        if not tbbHooked[wrap] and wrap.HookScript then
            tbbHooked[wrap] = true
            wrap:HookScript("OnShow", function(self)
                if mod._active and mod:GetDB().roundCooldownManager ~= false then
                    RoundTrackedBar(self)
                end
            end)
        end
        local sb = wrap._bar
        local h = F.PlainNumber(sb.GetHeight and sb:GetHeight(), 20) or 20
        local rad = math_min(globalRad, math_max(3, math_floor(h * 0.44)))
        if wantCDM and rad > 0 then
            local ft = sb.GetStatusBarTexture and sb:GetStatusBarTexture() or nil
            if ft then ST.MaskTexture(sb, ft, rad) end
            if wrap._bg then ST.MaskTexture(sb, wrap._bg, rad) end
            if wrap._gradTex then ST.MaskTexture(sb, wrap._gradTex, rad) end
            if wrap._spark then ST.MaskTexture(sb, wrap._spark, rad) end
            if PP and PP.HideBorder then pcall(PP.HideBorder, sb) end
            if EUI and EUI._bdBorderData and EUI._bdBorderData[sb] then
                pcall(EUI._bdBorderData[sb].Hide, EUI._bdBorderData[sb])
            end
            ST.ApplyRoundedBorder(sb, rad, 0.08, 0.10, 0.14, 0.72, 6)

            local icFrame = wrap._icon or wrap.icon
            if IsSafe(icFrame) and icFrame.GetRegions then
                local iRad = math_min(rad, 5)
                for _, reg in ipairs({ icFrame:GetRegions() }) do
                    if reg and reg.GetObjectType and reg:GetObjectType() == "Texture" then
                        ST.MaskTexture(icFrame, reg, iRad)
                    end
                end
                if PP and PP.HideBorder then pcall(PP.HideBorder, icFrame) end
                ST.ApplyRoundedBorder(icFrame, iRad, 0.08, 0.10, 0.14, 0.78, 5)
            end
        else
            ST.ClearRoundedMask(sb)
            if PP and PP.ShowBorder then pcall(PP.ShowBorder, sb) end
            local icFrame = wrap._icon or wrap.icon
            if IsSafe(icFrame) then
                ST.ClearRoundedMask(icFrame)
                if PP and PP.ShowBorder then pcall(PP.ShowBorder, icFrame) end
            end
        end
    end

    local cdmNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUICooldownManager
    local tbbList = cdmNS and cdmNS._buffBarInternals and cdmNS._buffBarInternals.tbbFrames
    if type(tbbList) == "table" then
        for _, wrap in ipairs(tbbList) do RoundTrackedBar(wrap) end
    end
    for i = 1, 30 do
        local w = _G["ECME_TBBWrap" .. i]
        if w then RoundTrackedBar(w) end
    end

    -- 4b) EUI Forever Essentials 拾取播报行（EUI_LootFeed）统一圆角化（解决图 6 拾取信息直角）
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
        local rad = math_min(globalRad, math_max(4, math_floor(h * 0.25)))
        if mod._active and rad > 0 then
            if r.bg then ST.MaskTexture(r, r.bg, rad) end
            if r.bar then ST.MaskTexture(r, r.bar, rad) end
            if PP and PP.HideBorder then pcall(PP.HideBorder, r) end
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
                ST.MaskTexture(iw, r.icon, 4)
                if r.iconBg then ST.MaskTexture(iw, r.iconBg, 4) end
                ST.ApplyRoundedBorder(iw, 4, 0.12, 0.14, 0.18, 0.80, 3)
            end
        else
            ST.ClearRoundedMask(r)
            local iw = lootFeedIconWraps[r]
            if iw then ST.ClearRoundedMask(iw); iw:Hide() end
        end
    end

    local unlockReg = EUI and EUI._unlockRegisteredElements
    if type(unlockReg) == "table" then
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
                    if reg and reg.GetObjectType and reg:GetObjectType() == "Texture" and reg ~= ft then
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
                    if mod._active then C_Timer.After(0.05, ScanButtons) end
                end)
            end
            WalkDMTree(dm, 1)
        end
    end
end

local function RefreshCooldownWatches()
    if not (mod._active and mod:GetDB().cdFinishPulse ~= false) then return end
    if not _G.GetActionCooldown then return end
    local now = GetTime()
    for slot, btn in pairs(slotToBtn) do
        if IsSafe(btn) and btn:IsVisible() then
            local ok, start, dur, enable = pcall(_G.GetActionCooldown, slot)
            start = ok and F.PlainNumber(start, 0) or 0
            dur = ok and F.PlainNumber(dur, 0) or 0
            if enable == 1 and start > 0 and dur > 2.0 then
                local endAt = start + dur
                local prevEnd = trackedCDs[slot]
                if not prevEnd or (endAt - prevEnd) > 0.35 then
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
            end
        end
    end
end

local QueueScan = F.Debounce(0.20, ScanButtons)
local QueueCDCheck = F.Debounce(0.18, RefreshCooldownWatches)

local function InstallEABHooks()
    if not hookedEAB then
        local eabNS = GetEABNS()
        local eab = eabNS and eabNS.EAB
        if eab then
            hookedEAB = true
            for _, fnName in ipairs({ "ApplyAll", "ApplyBar", "ApplyBarStyle", "RefreshAll" }) do
                if type(eab[fnName]) == "function" then
                    _G.hooksecurefunc(eab, fnName, function()
                        if mod._active then QueueScan() end
                    end)
                end
            end
        end
    end
    if not hookedCDM then
        local EUI = _G.EllesmereUI
        local cdmNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUICooldownManager
        if cdmNS then
            hookedCDM = true
            if type(cdmNS.BuildTrackedBuffBars) == "function" then
                _G.hooksecurefunc(cdmNS, "BuildTrackedBuffBars", function()
                    if mod._active then QueueScan() end
                end)
            end
            local bi = cdmNS._buffBarInternals
            if bi and type(bi.ApplyTrackedBuffBarSettings) == "function" then
                _G.hooksecurefunc(bi, "ApplyTrackedBuffBarSettings", function()
                    if mod._active then QueueScan() end
                end)
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
    self:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN", function()
        QueueCDCheck()
        QueueScan()
    end)
    self:RegisterEvent("SPELL_UPDATE_COOLDOWN", QueueScan)
    self:RegisterEvent("CHAT_MSG_LOOT", QueueScan)
    self:RegisterEvent("CHAT_MSG_MONEY", QueueScan)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", QueueScan)
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
            end
            ApplyButtonRound(btn, false)
        end
    end
    for _, sb in ipairs(dmBars) do
        if IsSafe(sb) then ST.ClearRoundedMask(sb) end
    end
    for _, wrap in ipairs(tbbBars) do
        if IsSafe(wrap) and IsSafe(wrap._bar) then
            ST.ClearRoundedMask(wrap._bar)
            if wrap._icon then ST.ClearRoundedMask(wrap._icon) end
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
        text = "动作条图标统一圆角 + 1px 描边",
        tooltip = "将 EUI 全部动作条（含主动作条、宠物条、姿态条与空技能格）统一改为抗锯齿圆角与 1px 细描边。",
        getValue = function() return db.roundActionBars ~= false end,
        setValue = function(v) db.roundActionBars = v == true; ScanButtons() end,
    }, {
        type = "toggle",
        text = "冷却管理器与伤害统计统一圆角",
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
        text = "按下技能缩放回弹 + 职业色边闪",
        tooltip = "仅对有技能的动作格生效，空技能格不会触发闪烁。",
        getValue = function() return db.pressBounce ~= false end,
        setValue = function(v) db.pressBounce = v == true; db.pressFlash = v == true end,
    }, {
        type = "toggle",
        text = "冷却转完脉冲高亮提醒（>2秒技能）",
        getValue = function() return db.cdFinishPulse ~= false end,
        setValue = function(v) db.cdFinishPulse = v == true end,
    })
    y = y - h

    return y
end
