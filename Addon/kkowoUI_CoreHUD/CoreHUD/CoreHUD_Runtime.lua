----------------------------------------------------------------------
--  kkowoUI_CoreHUD — CoreHUD/CoreHUD_Runtime.lua
--  数据实时刷新、EUI 原框体无损隐藏与安全点击层、生命周期与 /kk 选项面板
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local CH = F._CoreHUD
if not CH then return end

local ipairs, math_floor, math_max, math_min, pairs, pcall, select, tostring, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, select, tostring, type
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown

local ST = F.StyleTokens
local M = F.Motion
local mod = CH.mod
local SWING_ENUM = CH.SWING_ENUM
local IsPermanentOrAspectSpell = CH.IsPermanentOrAspectSpell
local GetSpellCastTimeSafe, GetSpellCooldownSafe = CH.GetSpellCastTimeSafe, CH.GetSpellCooldownSafe
local GetSpellIconSafe, GetSpellNameSafe = CH.GetSpellIconSafe, CH.GetSpellNameSafe
local ResolveWingTextModes, SetHealthText, SetPowerText = CH.ResolveWingTextModes, CH.SetHealthText, CH.SetPowerText
local UnitExistsSafe = CH.UnitExistsSafe
local swingState, orbState, trState = CH.swingState, CH.orbState, CH.trState
local hiddenEUI, alphaGuardedEUI, euiHiddenByUs, euiWatchRemoved = CH.hiddenEUI, CH.alphaGuardedEUI, CH.euiHiddenByUs, CH.euiWatchRemoved
local GetBarRadius, ApplyWingStyle = CH.GetBarRadius, CH.ApplyWingStyle
local UpdateOrbAmbientGlow, UpdateOrbAppearance, UpdateIdleFade = CH.UpdateOrbAmbientGlow, CH.UpdateOrbAppearance, CH.UpdateIdleFade
local SetOrbTimerArc, SetCombatBadge = CH.SetOrbTimerArc, CH.SetCombatBadge
local SyncTopRightAuraDedupe, UpdateCombatAuras = CH.SyncTopRightAuraDedupe, CH.UpdateCombatAuras
local SyncUpperSwingVisual, UpdateUpperRightClassPower = CH.SyncUpperSwingVisual, CH.UpdateUpperRightClassPower
local BuildCoreHUD, BuildPetHUD, BuildTopTargetHUD, HidePetFeedMenu = CH.BuildCoreHUD, CH.BuildPetHUD, CH.BuildTopTargetHUD, CH.HidePetFeedMenu

----------------------------------------------------------------------
--  4) 数据刷新（核心血蓝、宠物、顶部目标、EUI 原框体残影）
----------------------------------------------------------------------
local function UpdateBarSparkVis(wing, cur, mx)
    if not (wing and wing._spark) then return end
    local pCur = F.PlainNumber(cur, nil)
    local pMx = F.PlainNumber(mx, nil)
    if pCur and pMx and pMx > 0 then
        local frac = pCur / pMx
        wing._spark:SetShown(frac > 0.02 and frac < 0.985)
    else
        wing._spark:SetShown(false)
    end
end

-- 零 GC 颜色缓存：仅在颜色/方向变化时重刷渐变，避免每次血蓝事件重复 SetGradient
local function ApplyCachedBarGradient(bar, r1, g1, b1, r2, g2, b2, alpha, reverse)
    if not bar then return end
    local a = alpha or 0.98
    local rev = reverse == true
    local c = bar._kkGradCache
    if c and c[1] == r1 and c[2] == g1 and c[3] == b1
        and c[4] == r2 and c[5] == g2 and c[6] == b2
        and c[7] == a and c[8] == rev then
        return
    end
    if not c then c = {}; bar._kkGradCache = c end
    c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8] = r1, g1, b1, r2, g2, b2, a, rev
    ST.ApplyBarGradient(bar, r1, g1, b1, r2, g2, b2, a, rev)
end

-- 统一主条赋值（fx_smoothMain 关闭时严格退回旧路径 SetMinMaxValues + 1 参 SetValue）
local function SetHUDMainBar(bar, val, mx, unit, instant, extraChanged)
    if not bar then return end
    if not ST.IsFXEnabled("fx_smoothMain") then
        pcall(bar.SetMinMaxValues, bar, 0, mx)
        M.SetBarValue(bar, val, { fxKey = "fx_smoothMain" })
        return
    end
    local maxChanged = M.SetBarMinMax(bar, 0, mx)
    M.SetBarValue(bar, val, {
        fxKey = "fx_smoothMain",
        unit = unit,
        instant = instant == true,
        maxChanged = maxChanged or extraChanged == true,
    })
end

-- 大额受击与治疗柔光闪光（UNIT_COMBAT：绝不对机密数值做算术或比较）
local hitFlashCooldowns = setmetatable({}, { __mode = "k" })

local function HandleUnitCombatFlash(unit, action, flags, amount)
    if not (mod._active and ST.IsFXEnabled("fx_hitFlash")) then return end
    local act = F.PlainString(action, nil)
    if act ~= "WOUND" and act ~= "HEAL" then return end

    local bar = nil
    if unit == "player" then
        bar = CH.coreFrame and CH.coreFrame:IsShown() and CH.coreFrame._hpWing and CH.coreFrame._hpWing._bar or nil
    elseif unit == "target" then
        bar = CH.topTargetFrame and CH.topTargetFrame:IsShown() and CH.topTargetFrame._hpBar and CH.topTargetFrame._hpBar._bar or nil
    elseif unit == "pet" then
        bar = CH.petFrame and CH.petFrame:IsShown() and CH.petFrame._hpBar and CH.petFrame._hpBar._bar or nil
    end
    if not bar then return end

    local alphaMul = 1.0
    local plainAmt = (not F.IsSecret(amount)) and F.PlainNumber(amount, nil) or nil
    local rawMx = _G.UnitHealthMax and _G.UnitHealthMax(unit) or nil
    local plainMx = (not F.IsSecret(rawMx)) and F.PlainNumber(rawMx, nil) or nil

    if plainAmt and plainMx and plainMx > 0 then
        local thresh = (act == "HEAL") and 0.10 or 0.08
        if (plainAmt / plainMx) < thresh then
            return
        end
    else
        -- 数值或血量上限为机密值：若标志字段明文可用则仅暴击触发；标志也不可读时退化为 0.35s 限流半透轻闪
        if (not F.IsSecret(flags)) and type(flags) == "string" then
            if not flags:find("CRITICAL", 1, true) then
                return
            end
        else
            local now = GetTime()
            local last = hitFlashCooldowns[bar] or -10
            if (now - last) < 0.35 then
                return
            end
            hitFlashCooldowns[bar] = now
            alphaMul = 0.5
        end
    end

    local h = F.PlainNumber(bar.GetHeight and bar:GetHeight(), 16) or 16
    M.TriggerBarHitFlash(bar, act, {
        alphaMul = alphaMul,
        radius = GetBarRadius(h),
    })
end

local function UpdatePlayerHealth(instant)
    if CH.coreFrame and CH.coreFrame:IsShown() then
        local hp = _G.UnitHealth and _G.UnitHealth("player")
        if type(hp) == "nil" then hp = 0 end
        local mx = _G.UnitHealthMax and _G.UnitHealthMax("player")
        if type(mx) == "nil" then mx = 1 end
        SetHUDMainBar(CH.coreFrame._hpWing._bar, hp, mx, "player", instant)
        UpdateBarSparkVis(CH.coreFrame._hpWing, hp, mx)
        if CH.coreFrame._hpWing._trail then
            CH.coreFrame._hpWing._trail:SetEnabled(mod:GetDB().showTrail ~= false)
            CH.coreFrame._hpWing._trail:SetValue(hp, mx, instant)
        end
        if CH.coreFrame._hpWing._healPred then
            CH.coreFrame._hpWing._healPred:QueueUpdate("player", instant)
        end
        local hpMode = ResolveWingTextModes()
        SetHealthText(CH.coreFrame._hpText, "player", hpMode)
    end
    if CH.euiTrailPlayer then
        CH.euiTrailPlayer:SetEnabled(mod._active and mod:GetDB().enhanceEUIFrames ~= false and mod:GetDB().showTrail ~= false)
        CH.euiTrailPlayer:UpdateFromUnit("player", instant)
    end
end

local function UpdatePlayerPower(instant)
    if not (CH.coreFrame and CH.coreFrame:IsShown()) then return end
    local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("player"), 0) or 0
    local cur = _G.UnitPower and _G.UnitPower("player", pType)
    if type(cur) == "nil" then cur = 0 end
    local mx = _G.UnitPowerMax and _G.UnitPowerMax("player", pType)
    if type(mx) == "nil" then mx = 1 end
    local bar = CH.coreFrame._ppWing._bar
    local ptChanged = (bar._kkLastPowerType ~= nil and bar._kkLastPowerType ~= pType)
    bar._kkLastPowerType = pType
    SetHUDMainBar(bar, cur, mx, "player", instant, ptChanged)
    UpdateBarSparkVis(CH.coreFrame._ppWing, cur, mx)
    if CH.coreFrame._ppWing._trail then
        CH.coreFrame._ppWing._trail:SetEnabled(mod:GetDB().showTrail ~= false)
        CH.coreFrame._ppWing._trail:SetValue(cur, mx, instant or ptChanged)
    end
    local r1, g1, b1, r2, g2, b2 = ST.GetPowerGradient(pType)
    ApplyCachedBarGradient(bar, r1, g1, b1, r2, g2, b2, 0.98, false)
    local _, ppMode = ResolveWingTextModes()
    SetPowerText(CH.coreFrame._ppText, "player", pType, ppMode)
end

local function UpdatePetHUD(instant)
    if not CH.petFrame then return end
    local db = mod:GetDB()
    local exists = UnitExistsSafe("pet")
    if not (mod._active and db.showPetFrame ~= false and exists) then
        HidePetFeedMenu()
        CH.petFrame:Hide()
        return
    end
    local wasShown = CH.petFrame:IsShown()
    CH.petFrame:Show()
    if not wasShown then
        if CH.lastIdleAlpha then CH.petFrame:SetAlpha(CH.lastIdleAlpha) end
        if CH.SyncClickLayers then CH.SyncClickLayers() end
    end
    local snap = instant == true or (not wasShown)
    local hp = _G.UnitHealth and _G.UnitHealth("pet")
    if type(hp) == "nil" then hp = 0 end
    local mx = _G.UnitHealthMax and _G.UnitHealthMax("pet")
    if type(mx) == "nil" then mx = 1 end
    local hpBar = CH.petFrame._hpBar._bar
    SetHUDMainBar(hpBar, hp, mx, "pet", snap)
    if CH.petFrame._hpBar._trail then
        CH.petFrame._hpBar._trail:SetEnabled(db.showTrail ~= false)
        CH.petFrame._hpBar._trail:SetValue(hp, mx, snap)
    end
    local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
    ApplyCachedBarGradient(hpBar, r1, g1, b1, r2, g2, b2, 0.98, false)

    local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("pet"), 2) or 2
    local pCur = _G.UnitPower and _G.UnitPower("pet", pType)
    if type(pCur) == "nil" then pCur = 0 end
    local pMx = _G.UnitPowerMax and _G.UnitPowerMax("pet", pType)
    if type(pMx) == "nil" then pMx = 1 end
    local ppBar = CH.petFrame._ppBar._bar
    local ptChanged = (ppBar._kkLastPowerType ~= nil and ppBar._kkLastPowerType ~= pType)
    ppBar._kkLastPowerType = pType
    SetHUDMainBar(ppBar, pCur, pMx, "pet", snap, ptChanged)
    local pr1, pg1, pb1, pr2, pg2, pb2 = ST.GetPowerGradient(pType)
    ApplyCachedBarGradient(ppBar, pr1, pg1, pb1, pr2, pg2, pb2, 0.98, false)

    local petName = _G.UnitName and _G.UnitName("pet")
    if type(petName) ~= "nil" then
        pcall(CH.petFrame._nameText.SetText, CH.petFrame._nameText, petName)
    else
        CH.petFrame._nameText:SetText("宠物")
    end
    SetHealthText(CH.petFrame._hpText, "pet", true)

    -- 宠物快乐度图标（猎人优先，其它宠物自动显示头像）
    local happy = _G.C_PetInfo and _G.C_PetInfo.GetPetHappiness and F.PlainNumber(_G.C_PetInfo.GetPetHappiness(), nil)
        or (_G.GetPetHappiness and F.PlainNumber(_G.GetPetHappiness(), nil))
    if happy == 3 then
        CH.petFrame._iconBox._tex:SetTexture(F.MEDIA .. "Icons\\PetHappy.tga")
        CH.petFrame._iconBox._tex:SetTexCoord(0, 1, 0, 1)
    elseif happy == 2 then
        CH.petFrame._iconBox._tex:SetTexture(F.MEDIA .. "Icons\\PetNeutral.tga")
        CH.petFrame._iconBox._tex:SetTexCoord(0, 1, 0, 1)
    elseif happy == 1 then
        CH.petFrame._iconBox._tex:SetTexture(F.MEDIA .. "Icons\\PetMad.tga")
        CH.petFrame._iconBox._tex:SetTexCoord(0, 1, 0, 1)
    elseif _G.SetPortraitTexture then
        pcall(_G.SetPortraitTexture, CH.petFrame._iconBox._tex, "pet")
        ST.NotifyTextureChanged(CH.petFrame._iconBox._tex)
        CH.petFrame._iconBox._tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

-- 敌对阵营玩家显示红名（与怪物区分）；其余单位保持传入的默认文字色
CH.UnitNameColor = function(unit, r, g, b)
    local npMod = F.Modules.Get("nameplateMotion")
    if npMod and npMod:GetDB().redHostilePlayers == false then return r, g, b, 1 end
    local okP, isP = pcall(_G.UnitIsPlayer, unit)
    if okP and not F.IsSecret(isP) and isP == true and _G.UnitIsFriend then
        local okF, isFriend = pcall(_G.UnitIsFriend, "player", unit)
        if okF and not F.IsSecret(isFriend) and isFriend == false then
            local h = ST.COLORS.hostile
            return h[1], h[2], h[3], 1
        end
    end
    return r, g, b, 1
end

local function UpdateTargetOfTarget(instant)
    if not (CH.topTargetFrame and CH.topTargetFrame._totBar) then return end
    local tot = CH.topTargetFrame._totBar
    if not UnitExistsSafe("targettarget") then
        tot._nameText:SetText("")
        tot:Hide()
        return
    end
    local wasShown = tot:IsShown()
    tot:Show()
    local hp = _G.UnitHealth and _G.UnitHealth("targettarget")
    if type(hp) == "nil" then hp = 0 end
    local mx = _G.UnitHealthMax and _G.UnitHealthMax("targettarget")
    if type(mx) == "nil" then mx = 1 end
    SetHUDMainBar(tot._bar, hp, mx, "targettarget", instant == true or (not wasShown))
    local r1, g1, b1, r2, g2, b2 = ST.GetUnitGradient("targettarget")
    ApplyCachedBarGradient(tot._bar, r1, g1, b1, r2, g2, b2, 0.98, false)
    local rawName = _G.UnitName and _G.UnitName("targettarget")
    local nm = F.PlainString(rawName, nil)
    if nm then
        tot._nameText:SetText(nm)
    elseif type(rawName) ~= "nil" then
        pcall(tot._nameText.SetText, tot._nameText, rawName)
    else
        tot._nameText:SetText("")
    end
    tot._nameText:SetTextColor(CH.UnitNameColor("targettarget", 0.90, 0.92, 0.96))
end

local function UpdateTopTargetHUD(instant, isTargetSwitch)
    if CH.topTargetFrame then
        local db = mod:GetDB()
        local exists = UnitExistsSafe("target")
        if not (mod._active and db.enableTopTarget ~= false and exists) then
            CH.topTargetFrame:Hide()
        else
            if instant and not CH.topTargetFrame:IsShown() then
                CH.topTargetFrame:SetAlpha(0)
                CH.topTargetFrame:Show()
                F.Theme.FadeTo(CH.topTargetFrame, 1.0, 0.10, false)
            else
                CH.topTargetFrame:Show()
            end
            local hp = _G.UnitHealth and _G.UnitHealth("target")
            if type(hp) == "nil" then hp = 0 end
            local mx = _G.UnitHealthMax and _G.UnitHealthMax("target")
            if type(mx) == "nil" then mx = 1 end
            local hpBar = CH.topTargetFrame._hpBar._bar
            local trail = CH.topTargetFrame._hpBar._trail
            if trail then
                trail:SetEnabled(db.showTrail ~= false)
            end
            local didArrive = isTargetSwitch == true
                and M.PlayBarArriveGlide(hpBar, hp, mx, trail, { unit = "target" })
            if not didArrive then
                SetHUDMainBar(hpBar, hp, mx, "target", instant)
                if trail then
                    trail:SetValue(hp, mx, instant)
                end
            end
            UpdateBarSparkVis(CH.topTargetFrame._hpBar, hp, mx)
            if CH.topTargetFrame._hpBar._healPred then
                CH.topTargetFrame._hpBar._healPred:QueueUpdate("target", instant)
            end
            local r1, g1, b1, r2, g2, b2 = ST.GetUnitGradient("target")
            ApplyCachedBarGradient(hpBar, r1, g1, b1, r2, g2, b2, 0.98, false)

            local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("target"), 0) or 0
            local pCur = _G.UnitPower and _G.UnitPower("target", pType)
            if type(pCur) == "nil" then pCur = 0 end
            local pMx = _G.UnitPowerMax and _G.UnitPowerMax("target", pType)
            if type(pMx) == "nil" then pMx = 1 end
            local ppBar = CH.topTargetFrame._ppBar._bar
            local ptChanged = (ppBar._kkLastPowerType ~= nil and ppBar._kkLastPowerType ~= pType)
            ppBar._kkLastPowerType = pType
            SetHUDMainBar(ppBar, pCur, pMx, "target", instant, ptChanged)
            local pr1, pg1, pb1, pr2, pg2, pb2 = ST.GetPowerGradient(pType)
            ApplyCachedBarGradient(ppBar, pr1, pg1, pb1, pr2, pg2, pb2, 0.98, false)

            local _, _, tgtMode = ResolveWingTextModes()
            SetHealthText(CH.topTargetFrame._hpText, "target", tgtMode)
            local rawName = _G.UnitName and _G.UnitName("target")
            local tName = F.PlainString(rawName, nil)
            local tLvl = _G.UnitLevel and F.PlainNumber(_G.UnitLevel("target"), nil)
            local lvlStr = (tLvl and tLvl > 0) and tostring(tLvl) or (tLvl == -1 and "??" or "")
            if tName then
                CH.topTargetFrame._nameText:SetText(lvlStr ~= "" and (tName .. " · " .. lvlStr) or tName)
            elseif type(rawName) ~= "nil" then
                pcall(CH.topTargetFrame._nameText.SetText, CH.topTargetFrame._nameText, rawName)
            end
            CH.topTargetFrame._nameText:SetTextColor(CH.UnitNameColor("target", 0.98, 0.99, 1.00))

            if _G.SetPortraitTexture and CH.topTargetFrame._portrait then
                pcall(_G.SetPortraitTexture, CH.topTargetFrame._portrait._tex, "target")
                ST.NotifyTextureChanged(CH.topTargetFrame._portrait._tex)
            end
            UpdateTargetOfTarget(instant)
        end
        if instant and CH.SyncTargetAuras then
            CH.SyncTargetAuras()
        end
    end

    if CH.euiTrailTarget then
        CH.euiTrailTarget:SetEnabled(mod._active and mod:GetDB().enhanceEUIFrames ~= false and mod:GetDB().showTrail ~= false)
        CH.euiTrailTarget:UpdateFromUnit("target", instant)
        if instant and mod._active and mod:GetDB().enhanceEUIFrames ~= false then
            local tf = _G.EllesmereUIUnitFrames_Target
            -- 只在 EUI 当前让目标框完全可见时补一个微淡入：EUI 的「仅悬停 / 仅战斗显示」与距离淡隐
            -- 都是用透明度实现的，透明度不是 1（或是保密值）时绝不把它强行拉满
            local curA = tf and tf.GetAlpha and F.PlainNumber(tf:GetAlpha(), nil) or nil
            if tf and tf:IsShown() and not hiddenEUI.target and not tf._euiVisDriver
                and curA and curA >= 0.99 then
                tf:SetAlpha(0.15)
                F.Theme.FadeTo(tf, 1.0, 0.10, false)
            end
        end
    end
end

----------------------------------------------------------------------
--  5) EUI 原生单位框体残影挂钩与可选联动隐藏（战斗安全、可无损还原）
----------------------------------------------------------------------
local SyncHiddenEUIFrames -- 前向声明

-- EUI 玩家/目标框体平滑联动：仅在 fx_smoothMain 开启时写入 smoothing，关闭或停用时完整还原用户 EUI 原值
local euiOrigSmoothing = setmetatable({}, { __mode = "k" })
local NIL_SMOOTH_SENTINEL = {}

local function SyncEUISmoothing()
    local want = mod._active == true and ST.IsFXEnabled("fx_smoothMain")
    local interp = _G.Enum and _G.Enum.StatusBarInterpolation and _G.Enum.StatusBarInterpolation.ExponentialEaseOut or nil
    local frames = { _G.EllesmereUIUnitFrames_Player, _G.EllesmereUIUnitFrames_Target }
    for fi = 1, 2 do
        local uf = frames[fi]
        if uf then
            local elems = { uf.Health, uf.Power }
            for ei = 1, 2 do
                local elem = elems[ei]
                if elem then
                    if want and interp ~= nil then
                        if euiOrigSmoothing[elem] == nil then
                            euiOrigSmoothing[elem] = (elem.smoothing == nil) and NIL_SMOOTH_SENTINEL or elem.smoothing
                        end
                        elem.smoothing = interp
                    elseif euiOrigSmoothing[elem] ~= nil then
                        local orig = euiOrigSmoothing[elem]
                        if orig == NIL_SMOOTH_SENTINEL then
                            elem.smoothing = nil
                        else
                            elem.smoothing = orig
                        end
                        euiOrigSmoothing[elem] = nil
                    end
                end
            end
        end
    end
end

local function AttachEUITrails()
    local pf = _G.EllesmereUIUnitFrames_Player
    if pf and pf.Health and not CH.euiTrailPlayer then
        CH.euiTrailPlayer = M.AttachHealthTrail(pf.Health, {
            delay = mod:GetDB().trailDelay or 0.16,
            color = ST.COLORS.trail,
        })
    end
    local tf = _G.EllesmereUIUnitFrames_Target
    if tf and tf.Health and not CH.euiTrailTarget then
        CH.euiTrailTarget = M.AttachHealthTrail(tf.Health, {
            delay = mod:GetDB().trailDelay or 0.16,
            color = ST.COLORS.trail,
        })
    end
    SyncEUISmoothing()
    if not CH.euiHooksDone and type(_G._EUF_ReloadFrames) == "function" then
        CH.euiHooksDone = true
        _G.hooksecurefunc("_EUF_ReloadFrames", function()
            if mod._active then
                C_Timer.After(0.1, function()
                    if mod._active then
                        if CH.euiTrailPlayer then CH.euiTrailPlayer:SyncAnchor() end
                        if CH.euiTrailTarget then CH.euiTrailTarget:SyncAnchor() end
                        SyncEUISmoothing()
                        SyncHiddenEUIFrames()
                    end
                end)
            end
        end)
    end
end

local EUI_UF_GLOBALS = {
    player       = "EllesmereUIUnitFrames_Player",
    pet          = "EllesmereUIUnitFrames_Pet",
    target       = "EllesmereUIUnitFrames_Target",
    targettarget = "EllesmereUIUnitFrames_TargetTarget",
}

local function GetEUIUnitFrame(key)
    local gName = EUI_UF_GLOBALS[key]
    local fr = gName and _G[gName] or nil
    if not fr then
        local EUI = _G.EllesmereUI
        local ns = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIUnitFrames
        fr = ns and ns.frames and ns.frames[key] or nil
    end
    return fr
end

local function EnsureEUIAlphaGuard(fr, key)
    if not (fr and not alphaGuardedEUI[fr]) then return end
    alphaGuardedEUI[fr] = key
    local function ClampZero(self)
        if not CH.alphaGuardBusy and hiddenEUI[key] then
            CH.alphaGuardBusy = true
            pcall(self.SetAlpha, self, 0)
            CH.alphaGuardBusy = false
        end
    end
    if fr.SetAlpha then
        _G.hooksecurefunc(fr, "SetAlpha", function(self, a)
            if not CH.alphaGuardBusy and hiddenEUI[key] and F.PlainNumber(a, 1) ~= 0 then
                ClampZero(self)
            end
        end)
    end
    -- 12.x 距离淡隐会走 SetAlphaFromBoolean 绕过 SetAlpha 钩子（召唤宠物/距离刷新后直接把框体拉回 1）
    if fr.SetAlphaFromBoolean then
        _G.hooksecurefunc(fr, "SetAlphaFromBoolean", ClampZero)
    end
    if fr.HookScript then
        fr:HookScript("OnShow", ClampZero)
    end
    if fr.Show then
        _G.hooksecurefunc(fr, "Show", ClampZero)
    end
end

local function IsPlayerInCombatSafe()
    if _G.InCombatLockdown and _G.InCombatLockdown() then return true end
    if _G.UnitAffectingCombat then
        local ok, cbt = pcall(_G.UnitAffectingCombat, "player")
        if ok and not F.IsSecret(cbt) and cbt == true then return true end
    end
    return false
end

SyncHiddenEUIFrames = function()
    local db = mod:GetDB()
    local active = mod._active == true
    local autoHide = active and (db.keepOriginalEUI ~= true)

    local wantHide = {
        player       = autoHide and (db.showCoreHUD ~= false),
        pet          = autoHide and (db.showPetFrame ~= false),
        target       = autoHide and (db.enableTopTarget ~= false),
        targettarget = autoHide and (db.enableTopTarget ~= false),
    }

    local combatNow = (_G.InCombatLockdown and _G.InCombatLockdown()) == true
    -- SetAlpha 战斗内也 100% 安全，但若战斗中首次隐藏尚未关鼠的 EUI 框体，跳过 Alpha=0 等脱战原子 Hide+关鼠，防隐形吃点击
    for key, hide in pairs(wantHide) do
        local fr = GetEUIUnitFrame(key)
        local wasHidden = hiddenEUI[key] == true
        hiddenEUI[key] = hide == true
        if fr then
            local targetObj = fr._visWrap or fr
            if hide then
                local mouseStillOn = false
                if combatNow and not euiHiddenByUs[key] and fr.IsMouseEnabled then
                    local okM, en = pcall(fr.IsMouseEnabled, fr)
                    if okM and en == true then mouseStillOn = true end
                end
                if not mouseStillOn then
                    EnsureEUIAlphaGuard(fr, key)
                    if targetObj ~= fr then EnsureEUIAlphaGuard(targetObj, key) end
                    CH.alphaGuardBusy = true
                    pcall(fr.SetAlpha, fr, 0)
                    if targetObj ~= fr then pcall(targetObj.SetAlpha, targetObj, 0) end
                    CH.alphaGuardBusy = false
                end
            elseif wasHidden or euiHiddenByUs[key] then
                CH.alphaGuardBusy = true
                pcall(fr.SetAlpha, fr, 1)
                if targetObj ~= fr then pcall(targetObj.SetAlpha, targetObj, 1) end
                CH.alphaGuardBusy = false
            end
        end
    end

    -- 脱战安全窗口：注销单位监视 + Hide + 鼠标穿透，杜绝「召唤宠物」或切目标把 EUI 原版框体重新唤出。
    -- 只还原本模块确实动过的框体；EUI 用属性驱动（state-visibility，如「仅战斗中显示」）管显隐的框体
    -- 只靠透明度与鼠标穿透隐藏，绝不叠加 RegisterUnitWatch 抢 EUI 的显隐控制。
    F.CombatDefer("kkowoUI_CoreHUD_SyncEUIMouse", function()
        for key, hide in pairs(hiddenEUI) do
            local fr = GetEUIUnitFrame(key)
            if fr then
                if hide then
                    euiHiddenByUs[key] = true
                    if not fr._euiVisDriver then
                        if key ~= "player" and _G.UnregisterUnitWatch then
                            local wasWatched = true
                            if _G.UnitWatchRegistered then
                                local okW, reg = pcall(_G.UnitWatchRegistered, fr)
                                if okW then wasWatched = (reg == true) end
                            end
                            if wasWatched then
                                pcall(_G.UnregisterUnitWatch, fr)
                                euiWatchRemoved[key] = true
                            end
                        end
                        if fr.Hide then pcall(fr.Hide, fr) end
                    end
                    if fr.EnableMouse then pcall(fr.EnableMouse, fr, false) end
                    CH.alphaGuardBusy = true
                    pcall(fr.SetAlpha, fr, 0)
                    CH.alphaGuardBusy = false
                elseif euiHiddenByUs[key] then
                    euiHiddenByUs[key] = nil
                    if fr.EnableMouse then pcall(fr.EnableMouse, fr, true) end
                    CH.alphaGuardBusy = true
                    pcall(fr.SetAlpha, fr, 1)
                    if fr._visWrap and fr._visWrap ~= fr then pcall(fr._visWrap.SetAlpha, fr._visWrap, 1) end
                    CH.alphaGuardBusy = false
                    if euiWatchRemoved[key] then
                        euiWatchRemoved[key] = nil
                        if _G.RegisterUnitWatch and not fr._euiVisDriver then pcall(_G.RegisterUnitWatch, fr) end
                    elseif key == "player" and not fr._euiVisDriver and fr.GetAttribute then
                        -- EUI 里停用玩家框时它没有 unit：这种情况绝不把空框体重新显示出来
                        local okU, u = pcall(fr.GetAttribute, fr, "unit")
                        if okU and u ~= nil and fr.Show then pcall(fr.Show, fr) end
                    end
                end
            end
        end
    end)
end

----------------------------------------------------------------------
--  5b) 安全点击层：新版 HUD 本身是普通框体（战斗中可自由淡入淡出、显隐），EUI 原框体被收起并穿透鼠标后，
--      用 SecureUnitButton 补回「左键选中 / 右键单位菜单 / 点击施法」。
--      点击层挂在 UIParent 上、只按屏幕坐标对齐 HUD，绝不锚定到 HUD 内部框体——
--      否则 HUD 在战斗中改布局会被判定为移动受保护框体而被拦截。显隐交给 RegisterUnitWatch。
----------------------------------------------------------------------
local CLICK_SPECS = {
    { key = "player",       unit = "player",       watch = false },
    { key = "pet",          unit = "pet",          watch = true },
    { key = "target",       unit = "target",       watch = true },
    { key = "targettarget", unit = "targettarget", watch = true },
}
local clickLayers = {}

local function ClickRegionsFor(key)
    if key == "player" then
        if CH.coreFrame and CH.coreFrame:IsShown() then return CH.coreFrame._hpWing, CH.coreFrame._ppWing end
    elseif key == "pet" then
        -- 猎人左侧宠物快乐度按钮独立承担点击喂食，点击选中层只覆盖右侧血蓝条
        if CH.petFrame and F.GetPlayerClass() == "HUNTER" and CH.petFrame._hpBar and CH.petFrame._ppBar then
            return CH.petFrame._hpBar, CH.petFrame._ppBar
        end
        return CH.petFrame
    elseif key == "target" then
        return CH.topTargetFrame
    elseif key == "targettarget" then
        if CH.topTargetFrame and CH.topTargetFrame._totBar then
            return CH.topTargetFrame._totBar, CH.topTargetFrame._totBar._nameText
        end
    end
    return nil
end

local function WantClickLayer(key)
    if not mod._active then return false end
    local db = mod:GetDB()
    if db.clickableHUD == false then return false end
    if key == "player" then return db.showCoreHUD ~= false end
    if key == "pet" then return db.showPetFrame ~= false end
    return db.enableTopTarget ~= false
end

-- 把若干区域的并集换算成 UIParent 坐标（任一边为保密值 / 未布局时返回 nil，保持上次位置）
local function UnionRectInUIParent(...)
    local ui = _G.UIParent
    local uiS = ui and F.PlainNumber(ui:GetEffectiveScale(), nil)
    if not uiS or uiS <= 0 then return nil end
    local L, B, R, T
    for i = 1, select("#", ...) do
        local rg = select(i, ...)
        if rg and rg.GetLeft and rg.GetEffectiveScale then
            local es = F.PlainNumber(rg:GetEffectiveScale(), nil)
            local l = F.PlainNumber(rg:GetLeft(), nil)
            local r = F.PlainNumber(rg:GetRight(), nil)
            local t = F.PlainNumber(rg:GetTop(), nil)
            local b = F.PlainNumber(rg:GetBottom(), nil)
            if es and l and r and t and b and r > l and t > b then
                local k = es / uiS
                l, r, t, b = l * k, r * k, t * k, b * k
                L = L and math_min(L, l) or l
                R = R and math_max(R, r) or r
                T = T and math_max(T, t) or t
                B = B and math_min(B, b) or b
            end
        end
    end
    if not (L and R and T and B) then return nil end
    return L, B, R - L, T - B
end

local function EnsureClickLayer(spec)
    local btn = clickLayers[spec.key]
    if btn then return btn end
    local ok, b = pcall(CreateFrame, "Button", "kkowoUI_HUDClick_" .. spec.key, _G.UIParent, "SecureUnitButtonTemplate")
    if not (ok and b) then return nil end
    btn = b
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(11) -- 低于 HUD 光环图标（可悬停取消），高于场景
    btn:RegisterForClicks("AnyUp")
    btn:SetAttribute("unit", spec.unit)
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.SetLeftClickTarget) == "function" then
        if not pcall(EUI.SetLeftClickTarget, btn) then
            btn:SetAttribute("*type1", "target")
        end
    else
        btn:SetAttribute("*type1", "target")
    end
    if EUI and type(EUI.AttachSecureUnitMenu) == "function" then
        -- 12.0.7+ 的 togglemenu 有门控：沿用 EUI 已验证的安全菜单代理
        if not pcall(EUI.AttachSecureUnitMenu, btn) then
            btn:SetAttribute("*type2", "togglemenu")
        end
    else
        btn:SetAttribute("*type2", "togglemenu")
    end
    btn.unit = spec.unit
    btn:SetScript("OnEnter", function(self)
        if _G.UnitFrame_OnEnter then
            pcall(_G.UnitFrame_OnEnter, self)
        elseif _G.GameTooltip then
            _G.GameTooltip_SetDefaultAnchor(_G.GameTooltip, self)
            _G.GameTooltip:SetUnit(self.unit)
            _G.GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if _G.UnitFrame_OnLeave then
            pcall(_G.UnitFrame_OnLeave, self)
        elseif _G.GameTooltip then
            _G.GameTooltip:Hide()
        end
    end)
    if type(_G.ClickCastFrames) ~= "table" then _G.ClickCastFrames = {} end
    _G.ClickCastFrames[btn] = true
    btn:Hide()
    clickLayers[spec.key] = btn
    return btn
end

local function SyncClickLayersNow()
    for _, spec in ipairs(CLICK_SPECS) do
        local want = WantClickLayer(spec.key)
        local btn = clickLayers[spec.key] or (want and EnsureClickLayer(spec)) or nil
        if btn then
            local l, b, w, h = nil, nil, nil, nil
            if want then l, b, w, h = UnionRectInUIParent(ClickRegionsFor(spec.key)) end
            if want and l then
                btn:ClearAllPoints()
                btn:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", l, b)
                btn:SetSize(math_max(4, w), math_max(4, h))
                if spec.watch then
                    if not btn._kkWatched and _G.RegisterUnitWatch then
                        _G.RegisterUnitWatch(btn)
                        btn._kkWatched = true
                    end
                else
                    btn:Show()
                end
            elseif not want then
                if btn._kkWatched and _G.UnregisterUnitWatch then
                    _G.UnregisterUnitWatch(btn)
                    btn._kkWatched = false
                end
                btn:Hide()
            end
        end
    end
end

CH.SyncClickLayers = function()
    F.CombatDefer("kkowoUI_CoreHUD_ClickLayers", function()
        SyncClickLayersNow()
        -- 刚改过锚点 / 尺寸的 HUD 下一帧才完成布局，再对齐一次
        C_Timer.After(0, function()
            F.CombatDefer("kkowoUI_CoreHUD_ClickLayers", SyncClickLayersNow)
        end)
    end)
end

local function ApplyLayoutAndTheme()
    local db = mod:GetDB()
    local insideBars = (db.textInsideBars ~= false)
    if CH.coreFrame then
        local show = mod._active and db.showCoreHUD ~= false
        CH.coreFrame:SetShown(show)
        if show then
            local wingW = math_max(90, math_min(200, F.PlainNumber(db.wingWidth, 136) or 136))
            local barH = math_max(12, math_min(26, F.PlainNumber(db.barHeight, 18) or 18))
            local orbSz = math_max(34, math_min(58, F.PlainNumber(db.orbSize, 44) or 44))
            local sc = math_max(0.7, math_min(1.4, F.PlainNumber(db.scale, 1.0) or 1.0))

            local orbHalfGap = math_floor(orbSz * 0.34)
            CH.coreFrame:SetScale(sc)
            CH.coreFrame:SetSize(wingW * 2 + orbHalfGap * 2, math_max(orbSz + 6, barH + (insideBars and 22 or 34)))
            CH.coreFrame._hpWing:SetSize(wingW, barH)
            CH.coreFrame._ppWing:SetSize(wingW, barH)
            CH.coreFrame._hpWing:ClearAllPoints()
            CH.coreFrame._hpWing:SetPoint("RIGHT", CH.coreFrame, "CENTER", -orbHalfGap, -6)
            CH.coreFrame._ppWing:ClearAllPoints()
            CH.coreFrame._ppWing:SetPoint("LEFT", CH.coreFrame, "CENTER", orbHalfGap, -6)

            -- 数值文字位置：默认紧贴中央图标两侧内嵌到血/蓝条内部（支持条内居中与外侧两端，以及条外上方）
            local showOrb = (db.showOrb ~= false)
            local orbOverlap = showOrb and math_max(0, math_floor(orbSz * 0.5 + 0.5) - orbHalfGap) or 0
            local innerPad = orbOverlap + (showOrb and 7 or 8)
            local outerPad = 8
            local textAnchor = db.wingTextAnchor or "inner"
            local availW = math_max(48, wingW - innerPad - outerPad)
            local centerShift = math_floor(orbOverlap * 0.5)

            local inFontSz = math_max(9, math_min(12, math_floor(barH - 7)))
            CH.coreFrame._hpText:ClearAllPoints()
            CH.coreFrame._ppText:ClearAllPoints()
            if insideBars then
                ST.ApplyText(CH.coreFrame._hpText, inFontSz, 0.98, 0.99, 1.00, 1)
                ST.ApplyText(CH.coreFrame._ppText, inFontSz, 0.96, 0.98, 1.00, 1)
                CH.coreFrame._hpText:SetWidth(availW)
                CH.coreFrame._ppText:SetWidth(availW)
                if textAnchor == "outer" then
                    CH.coreFrame._hpText:SetJustifyH("LEFT")
                    CH.coreFrame._ppText:SetJustifyH("RIGHT")
                    CH.coreFrame._hpText:SetPoint("LEFT", CH.coreFrame._hpWing, "LEFT", outerPad, 0)
                    CH.coreFrame._ppText:SetPoint("RIGHT", CH.coreFrame._ppWing, "RIGHT", -outerPad, 0)
                elseif textAnchor == "center" then
                    CH.coreFrame._hpText:SetJustifyH("CENTER")
                    CH.coreFrame._ppText:SetJustifyH("CENTER")
                    CH.coreFrame._hpText:SetPoint("CENTER", CH.coreFrame._hpWing, "CENTER", -centerShift, 0)
                    CH.coreFrame._ppText:SetPoint("CENTER", CH.coreFrame._ppWing, "CENTER", centerShift, 0)
                else
                    CH.coreFrame._hpText:SetJustifyH("RIGHT")
                    CH.coreFrame._ppText:SetJustifyH("LEFT")
                    CH.coreFrame._hpText:SetPoint("RIGHT", CH.coreFrame._hpWing, "RIGHT", -innerPad, 0)
                    CH.coreFrame._ppText:SetPoint("LEFT", CH.coreFrame._ppWing, "LEFT", innerPad, 0)
                end
            else
                ST.ApplyText(CH.coreFrame._hpText, 12, 0.96, 0.97, 0.99, 1)
                ST.ApplyText(CH.coreFrame._ppText, 12, 0.94, 0.96, 0.99, 1)
                CH.coreFrame._hpText:SetWidth(0)
                CH.coreFrame._ppText:SetWidth(0)
                if textAnchor == "outer" then
                    CH.coreFrame._hpText:SetJustifyH("LEFT")
                    CH.coreFrame._ppText:SetJustifyH("RIGHT")
                    CH.coreFrame._hpText:SetPoint("BOTTOMLEFT", CH.coreFrame._hpWing, "TOPLEFT", 2, 9)
                    CH.coreFrame._ppText:SetPoint("BOTTOMRIGHT", CH.coreFrame._ppWing, "TOPRIGHT", -2, 9)
                elseif textAnchor == "center" then
                    CH.coreFrame._hpText:SetJustifyH("CENTER")
                    CH.coreFrame._ppText:SetJustifyH("CENTER")
                    CH.coreFrame._hpText:SetPoint("BOTTOM", CH.coreFrame._hpWing, "TOP", -centerShift, 9)
                    CH.coreFrame._ppText:SetPoint("BOTTOM", CH.coreFrame._ppWing, "TOP", centerShift, 9)
                else
                    CH.coreFrame._hpText:SetJustifyH("RIGHT")
                    CH.coreFrame._ppText:SetJustifyH("LEFT")
                    CH.coreFrame._hpText:SetPoint("BOTTOMRIGHT", CH.coreFrame._hpWing, "TOPRIGHT", -innerPad, 9)
                    CH.coreFrame._ppText:SetPoint("BOTTOMLEFT", CH.coreFrame._ppWing, "TOPLEFT", innerPad, 9)
                end
            end

            CH.coreFrame._swingWing:SetSize(wingW - 4, 5)
            CH.coreFrame._swingWing:SetShown(db.showUpperSwing ~= false)
            if CH.coreFrame._rightTopGroove then
                CH.coreFrame._rightTopGroove:SetSize(wingW - 4, 5)
                ApplyWingStyle(CH.coreFrame._rightTopGroove, 0.04, 0.045, 0.06, 0.04, 0.045, 0.06, GetBarRadius(5))
            end
            CH.coreFrame._classPips:SetSize(wingW - 4, 5)
            CH.coreFrame._ohWing:SetSize(wingW - 4, 5)
            CH.coreFrame._orb:SetSize(orbSz, orbSz)
            if CH.coreFrame._orb._halo then
                CH.coreFrame._orb._halo:SetSize(orbSz * 1.95, orbSz * 1.95)
            end

            local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
            local rad = GetBarRadius(barH)
            CH.coreFrame._hpWing._bar._kkGradCache = nil
            CH.coreFrame._ppWing._bar._kkGradCache = nil
            ApplyWingStyle(CH.coreFrame._hpWing, r1, g1, b1, r2, g2, b2, rad)
            if CH.coreFrame._hpWing._trail then
                CH.coreFrame._hpWing._trail:SetDelay(db.trailDelay or 0.16)
                CH.coreFrame._hpWing._trail:SyncAnchor()
            end
            if CH.coreFrame._hpWing._spark then CH.coreFrame._hpWing._spark:SyncAnchor() end

            local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("player"), 0) or 0
            local pr1, pg1, pb1, pr2, pg2, pb2 = ST.GetPowerGradient(pType)
            ApplyWingStyle(CH.coreFrame._ppWing, pr1, pg1, pb1, pr2, pg2, pb2, rad)
            if CH.coreFrame._ppWing._trail then CH.coreFrame._ppWing._trail:SyncAnchor() end
            if CH.coreFrame._ppWing._spark then CH.coreFrame._ppWing._spark:SyncAnchor() end

            ApplyWingStyle(CH.coreFrame._swingWing, r1 * 0.85, g1 * 0.85, b1 * 0.85, r2, g2, b2, GetBarRadius(5))
            CH.coreFrame._swingWing._lastColorKey = "class"
            ApplyWingStyle(CH.coreFrame._ohWing, r1 * 0.72, g1 * 0.72, b1 * 0.72, r2 * 0.9, g2 * 0.9, b2 * 0.9, GetBarRadius(5))
            if CH.coreFrame._orb._ring then
                CH.coreFrame._orb._ring:SetVertexColor(r1 * 0.45 + 0.08, g1 * 0.45 + 0.08, b1 * 0.45 + 0.08, 0.96)
            end

            if CH.coreFrame._orb._cd and CH.coreFrame._orb._cd.SetSwipeColor then
                pcall(CH.coreFrame._orb._cd.SetSwipeColor, CH.coreFrame._orb._cd, r2, g2, b2, 0.92)
            end
            local inCombat = IsPlayerInCombatSafe()
            SetCombatBadge(inCombat, false)

            UpdatePlayerHealth(true)
            UpdatePlayerPower(true)
            UpdateUpperRightClassPower()
            UpdateOrbAppearance(false)
            UpdateCombatAuras()
        else
            CH.swingTicker:Hide()
            SyncTopRightAuraDedupe(true)
        end
    end
    if CH.euiTrailPlayer then
        CH.euiTrailPlayer:SetDelay(db.trailDelay or 0.16)
        CH.euiTrailPlayer:SetEnabled(mod._active and db.enhanceEUIFrames ~= false and db.showTrail ~= false)
        if mod._active and db.enhanceEUIFrames ~= false and db.showTrail ~= false then
            CH.euiTrailPlayer:UpdateFromUnit("player", true)
        end
    end

    if CH.petFrame then
        CH.petFrame:SetScale(math_max(0.7, math_min(1.4, F.PlainNumber(db.scale, 1.0) or 1.0)))
        local pHpH = insideBars and 16 or 14
        local pPpH = insideBars and 4 or 5
        CH.petFrame:SetSize(156, insideBars and 24 or 36)
        CH.petFrame._hpBar:SetSize(130, pHpH)
        CH.petFrame._ppBar:SetSize(130, pPpH)
        CH.petFrame._nameText:ClearAllPoints()
        CH.petFrame._hpText:ClearAllPoints()
        if insideBars then
            ST.ApplyText(CH.petFrame._nameText, 10, 0.96, 0.98, 1.00, 1)
            ST.ApplyText(CH.petFrame._hpText, 10, 0.96, 0.98, 1.00, 1)
            CH.petFrame._nameText:SetPoint("LEFT", CH.petFrame._hpBar, "LEFT", 6, 0)
            CH.petFrame._nameText:SetWidth(76)
            CH.petFrame._hpText:SetPoint("RIGHT", CH.petFrame._hpBar, "RIGHT", -6, 0)
        else
            ST.ApplyText(CH.petFrame._nameText, 11, 0.92, 0.95, 0.98, 1)
            ST.ApplyText(CH.petFrame._hpText, 11, 0.94, 0.96, 0.99, 1)
            CH.petFrame._nameText:SetPoint("BOTTOMLEFT", CH.petFrame._hpBar, "TOPLEFT", 2, 2)
            CH.petFrame._nameText:SetWidth(90)
            CH.petFrame._hpText:SetPoint("BOTTOMRIGHT", CH.petFrame._hpBar, "TOPRIGHT", -2, 2)
        end
        local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
        ApplyWingStyle(CH.petFrame._hpBar, r1, g1, b1, r2, g2, b2, GetBarRadius(pHpH))
        local pt = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("pet"), 2) or 2
        local pr1, pg1, pb1, pr2, pg2, pb2 = ST.GetPowerGradient(pt)
        ApplyWingStyle(CH.petFrame._ppBar, pr1, pg1, pb1, pr2, pg2, pb2, GetBarRadius(pPpH))
        if CH.petFrame._hpBar._trail then CH.petFrame._hpBar._trail:SetDelay(db.trailDelay or 0.16) end
        CH.petFrame._hpBar._bar._kkGradCache = nil
        CH.petFrame._ppBar._bar._kkGradCache = nil
        UpdatePetHUD(true)
    end
    if CH.topTargetFrame then
        CH.topTargetFrame:SetScale(math_max(0.7, math_min(1.4, F.PlainNumber(db.scale, 1.0) or 1.0)))
        local tHpH = insideBars and 18 or 16
        CH.topTargetFrame:SetSize(286, insideBars and 30 or 38)
        CH.topTargetFrame._hpBar:SetSize(256, tHpH)
        CH.topTargetFrame._hpText:ClearAllPoints()
        CH.topTargetFrame._nameText:ClearAllPoints()
        if insideBars then
            ST.ApplyText(CH.topTargetFrame._hpText, 11, 0.98, 0.99, 1.00, 1)
            ST.ApplyText(CH.topTargetFrame._nameText, 11, 0.98, 0.99, 1.00, 1)
            CH.topTargetFrame._hpText:SetPoint("LEFT", CH.topTargetFrame._hpBar, "LEFT", 8, 0)
            CH.topTargetFrame._nameText:SetPoint("RIGHT", CH.topTargetFrame._hpBar, "RIGHT", -10, 0)
            CH.topTargetFrame._nameText:SetWidth(148)
        else
            ST.ApplyText(CH.topTargetFrame._hpText, 12, 0.97, 0.97, 0.99, 1)
            ST.ApplyText(CH.topTargetFrame._nameText, 12, 0.97, 0.97, 0.99, 1)
            CH.topTargetFrame._hpText:SetPoint("BOTTOMLEFT", CH.topTargetFrame._hpBar, "TOPLEFT", 2, 2)
            CH.topTargetFrame._nameText:SetPoint("BOTTOMRIGHT", CH.topTargetFrame._hpBar, "TOPRIGHT", -2, 2)
            CH.topTargetFrame._nameText:SetWidth(168)
        end
        local tr1, tg1, tb1, tr2, tg2, tb2 = ST.GetUnitGradient("target")
        ApplyWingStyle(CH.topTargetFrame._hpBar, tr1, tg1, tb1, tr2, tg2, tb2, GetBarRadius(tHpH))
        local tpt = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("target"), 0) or 0
        local tpr1, tpg1, tpb1, tpr2, tpg2, tpb2 = ST.GetPowerGradient(tpt)
        ApplyWingStyle(CH.topTargetFrame._ppBar, tpr1, tpg1, tpb1, tpr2, tpg2, tpb2, GetBarRadius(4))
        local totr1, totg1, totb1, totr2, totg2, totb2 = ST.GetUnitGradient("targettarget")
        ApplyWingStyle(CH.topTargetFrame._totBar, totr1, totg1, totb1, totr2, totg2, totb2, GetBarRadius(10))
        if CH.topTargetFrame._hpBar._trail then CH.topTargetFrame._hpBar._trail:SetDelay(db.trailDelay or 0.16) end
        if CH.topTargetFrame._hpBar._spark then CH.topTargetFrame._hpBar._spark:SyncAnchor() end
        CH.topTargetFrame._hpBar._bar._kkGradCache = nil
        CH.topTargetFrame._ppBar._bar._kkGradCache = nil
        CH.topTargetFrame._totBar._bar._kkGradCache = nil
        UpdateTopTargetHUD(true)
    end
    if CH.euiTrailTarget then CH.euiTrailTarget:SetDelay(db.trailDelay or 0.16) end
    if CH.coreFrame and CH.coreFrame._hpWing and CH.coreFrame._hpWing._healPred then
        CH.coreFrame._hpWing._healPred:SyncLayout()
        CH.coreFrame._hpWing._healPred:UpdateFromUnit("player", true)
    end
    if CH.topTargetFrame and CH.topTargetFrame._hpBar and CH.topTargetFrame._hpBar._healPred then
        CH.topTargetFrame._hpBar._healPred:SyncLayout()
        CH.topTargetFrame._hpBar._healPred:UpdateFromUnit("target", true)
    end
    SyncEUISmoothing()
    SyncHiddenEUIFrames()
    SyncTopRightAuraDedupe(true)
    CH.SyncClickLayers()
    UpdateIdleFade(true)
end

----------------------------------------------------------------------
--  6) 生命周期与事件注册（关闭时 0 事件 / 0 Ticker）
----------------------------------------------------------------------
local function OnCastBegin(isChannel, castGUID, spellID)
    local fn = isChannel and _G.UnitChannelInfo or _G.UnitCastingInfo
    if not fn then return end
    local ok, name, _, tex, startMS, endMS = pcall(fn, "player")
    if not ok or type(tex) == "nil" then return end
    local pName = F.PlainString(name, nil)
    local pSid = F.PlainNumber(spellID, nil)
    if IsPermanentOrAspectSpell(pSid, pName) then return end
    local sMS = F.PlainNumber(startMS, nil)
    local eMS = F.PlainNumber(endMS, nil)
    orbState.castActive = true
    orbState.castSpellID = pSid
    orbState.castGUID = (type(castGUID) ~= "nil" and not F.IsSecret(castGUID)) and castGUID or nil
    orbState.lastSpellIcon = nil
    orbState.lastSpellUntil = 0
    if not F.IsSecret(tex) then orbState.castIcon = tex end
    UpdateOrbAppearance(true)
    UpdateIdleFade(false)
    if sMS and eMS and eMS > sMS then
        SetOrbTimerArc(sMS / 1000, (eMS - sMS) / 1000)
    end
end

local function OnCastEnd(_, event, _, castGUID, spellID)
    if event ~= "UNIT_SPELLCAST_CHANNEL_STOP" then
        if type(castGUID) ~= "nil" and not F.IsSecret(castGUID) and orbState.castGUID and castGUID ~= orbState.castGUID then
            return
        end
        local sid = F.PlainNumber(spellID, nil)
        if sid and orbState.castSpellID and sid ~= orbState.castSpellID then
            return
        end
        if F.UnitIsCasting("player") or F.UnitIsCasting("player", true) then
            return
        end
    else
        if F.UnitIsCasting("player") then
            return
        end
    end
    -- 读条/引导技能（如剥皮、采矿、瞄准射击等）结束瞬间立刻归位，绝不滞留 5 秒！
    orbState.castActive = false
    orbState.castIcon = nil
    orbState.castSpellID = nil
    orbState.castGUID = nil
    orbState.lastSpellIcon = nil
    orbState.lastSpellUntil = 0
    orbState.lastCastEndTime = GetTime()
    local inCombat = IsPlayerInCombatSafe()
    if inCombat then
        local s, d = GetSpellCooldownSafe(61304)
        if s > 0 and d > 0.1 then
            SetOrbTimerArc(s, d)
        else
            SetOrbTimerArc(nil, nil)
        end
    else
        SetOrbTimerArc(nil, nil)
    end
    UpdateOrbAppearance(false)
    UpdateIdleFade(false)
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2AuraStripMigrated then
        db.v2AuraStripMigrated = true
        db.showCombatBuffs = true
        db.showCombatDebuffs = true
        db.buffFilter = "non_permanent"
        db.idleFade = true
        db.idleAlpha = 0.50
    end
    if not db.v5MirrorDefaultMigrated then
        db.v5MirrorDefaultMigrated = true
        if db.wingTextFormat == nil or db.wingTextFormat == "num_pct" then
            db.wingTextFormat = "mirror"
        end
    end
    if not db.v3UnifiedTargetMigrated then
        db.v3UnifiedTargetMigrated = true
        db.enableTopTarget = true
    end
    if not db.v4CenteredBoundsMigrated then
        db.v4CenteredBoundsMigrated = true
        if F.DB and F.DB.ClearPosition then
            F.DB.ClearPosition("TopTargetHUD")
        end
    end
    if not db.v5AutoReplaceMigrated then
        db.v5AutoReplaceMigrated = true
        db.keepOriginalEUI = false
        db.dedupeTopRightAuras = true
    end
    if not db.v6AuraRefined then
        db.v6AuraRefined = true
        db.auraIconSize = 26
    end
    if not db.v7OptionAAndInsideText then
        db.v7OptionAAndInsideText = true
        db.textInsideBars = true
        if (F.PlainNumber(db.barHeight, 16) or 16) < 18 then
            db.barHeight = 18
        end
        db.showPermanentBuffs = true
        db.hideTopRightBlizzAuras = true
        db.showTopRightMicroToggle = true
    end

    BuildCoreHUD()
    BuildPetHUD()
    BuildTopTargetHUD()
    if CH.coreFrame and CH.coreFrame._hpWing and not CH.coreFrame._hpWing._healPred then
        CH.coreFrame._hpWing._healPred = M.AttachHealPrediction(CH.coreFrame._hpWing._bar, { reverse = true })
    end
    if CH.topTargetFrame and CH.topTargetFrame._hpBar and not CH.topTargetFrame._hpBar._healPred then
        CH.topTargetFrame._hpBar._healPred = M.AttachHealPrediction(CH.topTargetFrame._hpBar._bar, { reverse = false })
    end
    AttachEUITrails()

    local EUI = _G.EllesmereUI
    if EUI and EUI.RegisterUnlockModeListener then
        pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_CoreHUD_Idle", function()
            if mod._active then
                UpdateIdleFade(false)
                CH.SyncClickLayers() -- 解锁模式拖动 HUD 后，点击层跟随新位置
            end
        end)
    end
    self:RegisterEvent("UI_SCALE_CHANGED", function() CH.SyncClickLayers() end)
    self:RegisterEvent("DISPLAY_SIZE_CHANGED", function() CH.SyncClickLayers() end)

    self:RegisterUnitEvent("UNIT_HEALTH", "player", "target", function(_, _, unit)
        if unit == "player" then
            UpdatePlayerHealth(false)
            UpdateIdleFade(false)
        elseif unit == "target" then
            UpdateTopTargetHUD(false)
        end
    end)
    self:RegisterUnitEvent("UNIT_MAXHEALTH", "player", "target", function(_, _, unit)
        if unit == "player" then
            UpdatePlayerHealth(true)
            UpdateIdleFade(false)
        elseif unit == "target" then
            UpdateTopTargetHUD(true)
        end
    end)
    local function OnPowerEvent(_, _, unit)
        if unit == "player" then
            UpdatePlayerPower(false)
            UpdateUpperRightClassPower()
            UpdateIdleFade(false)
        elseif unit == "target" then
            UpdateTopTargetHUD(false)
        end
    end
    self:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player", "target", OnPowerEvent)
    self:RegisterUnitEvent("UNIT_POWER_UPDATE", "player", "target", OnPowerEvent)
    self:RegisterUnitEvent("UNIT_MAXPOWER", "player", "target", function(_, _, unit)
        if unit == "player" then
            UpdatePlayerPower(true)
            UpdateUpperRightClassPower()
            UpdateIdleFade(false)
        elseif unit == "target" then
            UpdateTopTargetHUD(true)
        end
    end)
    self:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player", function()
        UpdatePlayerPower(true)
        UpdateUpperRightClassPower()
        UpdateIdleFade(false)
    end)
    self:RegisterUnitEvent("UNIT_COMBAT", "player", "target", function(_, _, unit, action, flags, amount)
        if unit == "player" or unit == "target" then
            HandleUnitCombatFlash(unit, action, flags, amount)
        end
    end)
    local function OnHealPredEvent(_, _, unit)
        if not mod._active then return end
        if unit == "player" and CH.coreFrame and CH.coreFrame._hpWing and CH.coreFrame._hpWing._healPred then
            CH.coreFrame._hpWing._healPred:QueueUpdate("player", false)
        elseif unit == "target" and CH.topTargetFrame and CH.topTargetFrame._hpBar and CH.topTargetFrame._hpBar._healPred then
            CH.topTargetFrame._hpBar._healPred:QueueUpdate("target", false)
        end
    end
    self:RegisterUnitEvent("UNIT_HEAL_PREDICTION", "player", "target", OnHealPredEvent)
    self:RegisterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED", "player", "target", OnHealPredEvent)
    self:RegisterUnitEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED", "player", "target", OnHealPredEvent)
    if not mod._numFmtHooked and EUI and type(EUI.RegisterNumberFormatCallback) == "function" then
        mod._numFmtHooked = true
        pcall(EUI.RegisterNumberFormatCallback, function()
            if mod._active then
                UpdatePlayerHealth(true)
                UpdatePlayerPower(true)
                UpdateTopTargetHUD(true)
            end
        end)
    end

    -- 宠物事件走独立事件帧，避免与 player/target 的 UNIT_HEALTH 在同一模块事件帧上互相覆盖
    if not CH.petEventFrame then
        CH.petEventFrame = CreateFrame("Frame")
        CH.petEventFrame:SetScript("OnEvent", function(_, ev, unit, action, flags, amount)
            if not mod._active then return end
            if ev == "UNIT_COMBAT" then
                if unit == "pet" then
                    HandleUnitCombatFlash(unit, action, flags, amount)
                end
                return
            end
            UpdatePetHUD(ev == "UNIT_MAXHEALTH")
        end)
    end
    pcall(CH.petEventFrame.RegisterUnitEvent, CH.petEventFrame, "UNIT_HEALTH", "pet")
    pcall(CH.petEventFrame.RegisterUnitEvent, CH.petEventFrame, "UNIT_MAXHEALTH", "pet")
    pcall(CH.petEventFrame.RegisterUnitEvent, CH.petEventFrame, "UNIT_POWER_UPDATE", "pet")
    pcall(CH.petEventFrame.RegisterUnitEvent, CH.petEventFrame, "UNIT_HAPPINESS", "pet")
    pcall(CH.petEventFrame.RegisterUnitEvent, CH.petEventFrame, "UNIT_COMBAT", "pet")
    local QueuePetHideSync = F.Debounce(0.08, function()
        if mod._active then SyncHiddenEUIFrames() end
    end)
    self:RegisterUnitEvent("UNIT_PET", "player", function()
        if not mod._active then return end
        UpdatePetHUD(true)
        SyncHiddenEUIFrames()
        QueuePetHideSync()
    end)
    self:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        UpdateTopTargetHUD(true, true)
        UpdateUpperRightClassPower()
        SyncHiddenEUIFrames()
        UpdateIdleFade(false)
    end)
    self:RegisterUnitEvent("UNIT_TARGET", "target", UpdateTargetOfTarget)

    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        SetCombatBadge(true, true)
        UpdateOrbAmbientGlow()
        if mod._queueAuraUpdate then mod._queueAuraUpdate() end
        UpdateIdleFade(false)
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        SetCombatBadge(false, true)
        UpdateOrbAmbientGlow()
        if mod._queueAuraUpdate then mod._queueAuraUpdate() end
        C_Timer.After(0.35, function()
            if mod._active then UpdateCombatAuras() end
        end)
        UpdateIdleFade(false)
    end)

    -- 动态技能球：读条/引导结束即刻丝滑回默认图标；瞬发主动技能仅随公共冷却短暂停留（排除平砍/自动射击/守护/姿态/炉石）
    self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player", function(_, _, _, castGUID, spellID)
        OnCastBegin(false, castGUID, spellID)
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", function(_, _, _, castGUID, spellID)
        OnCastBegin(true, castGUID, spellID)
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player", OnCastEnd)
    self:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", OnCastEnd)
    self:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", OnCastEnd)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", OnCastEnd)
    self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, castGUID, spellID)
        local sid = F.PlainNumber(spellID, nil)
        if not sid or sid == 6603 or sid == 75 then return end
        local sName = GetSpellNameSafe(sid)
        if IsPermanentOrAspectSpell(sid, sName) then
            CH.permState.RecordSpellCast(sid, sName)
            return
        end
        -- 读条/引导技能（如剥皮、采矿、炉石、瞄准射击）施法完成时同步触发 SUCCEEDED：绝不滞留，交由 OnCastEnd 瞬间丝滑回默认图标
        local now = GetTime()
        if orbState.castActive
            or (type(castGUID) ~= "nil" and not F.IsSecret(castGUID) and castGUID == orbState.castGUID)
            or ((now - (orbState.lastCastEndTime or 0)) < 0.30)
            or (GetSpellCastTimeSafe(sid) > 0) then
            return
        end
        local ic = GetSpellIconSafe(sid)
        if ic then
            local s, d = GetSpellCooldownSafe(61304)
            local holdDur = (s > 0 and d > 0.2 and d <= 2.0) and math_max(0.75, (s + d) - now) or 1.25
            orbState.lastSpellIcon = ic
            orbState.lastSpellUntil = now + holdDur
            UpdateOrbAppearance(true)
            UpdateIdleFade(false)
            if s > 0 and d > 0.1 then
                SetOrbTimerArc(s, d)
            end
            C_Timer.After(holdDur + 0.04, function()
                if mod._active and GetTime() >= (orbState.lastSpellUntil or 0) - 0.04 then
                    orbState.lastSpellIcon = nil
                    orbState.lastSpellUntil = 0
                    UpdateOrbAppearance(false)
                    UpdateIdleFade(false)
                end
            end)
        end
    end)
    local QueueAuraUpdate = F.Debounce(0.10, UpdateCombatAuras)
    self:RegisterUnitEvent("UNIT_AURA", "player", QueueAuraUpdate)
    self:RegisterEvent("UPDATE_SHAPESHIFT_FORM", function()
        QueueAuraUpdate()
        UpdateUpperRightClassPower()
    end)
    self:RegisterEvent("UPDATE_SHAPESHIFT_FORMS", function()
        QueueAuraUpdate()
        UpdateUpperRightClassPower()
    end)
    self._queueAuraUpdate = QueueAuraUpdate

    -- 无限服原生挥砍事件（驱动左上极细挥砍翼与空闲外环计时）
    self:RegisterEvent("PLAYER_SWING", function(_, _, duration, swingType)
        local dur = F.PlainNumber(duration, nil)
        local stype = F.PlainNumber(swingType, nil)
        if not dur or dur <= 0.05 then return end
        local now = GetTime()
        local isOffHand = SWING_ENUM and stype == SWING_ENUM.OffHand
        if SWING_ENUM and stype == SWING_ENUM.Ranged then
            swingState.rStart, swingState.rEnd, swingState.rDur = now, now + dur, dur
            swingState.activeKind = "ranged"
        elseif isOffHand then
            swingState.ohStart, swingState.ohEnd, swingState.ohDur = now, now + dur, dur
        else
            swingState.mhStart, swingState.mhEnd, swingState.mhDur = now, now + dur, dur
            swingState.activeKind = "mh"
        end
        if mod:GetDB().showUpperSwing ~= false and CH.coreFrame and CH.coreFrame:IsShown() then
            CH.swingTicker:Show()
            SyncUpperSwingVisual()
        end
        if (not isOffHand) and not orbState.castActive and now >= (orbState.lastSpellUntil or 0) then
            SetOrbTimerArc(now, dur)
        end
    end)
    self:RegisterEvent("START_AUTOREPEAT_SPELL", function() swingState.autoRepeat = true end)
    self:RegisterEvent("STOP_AUTOREPEAT_SPELL", function() swingState.autoRepeat = false end)
    self:RegisterEvent("PLAYER_STARTED_MOVING", function() swingState.moving = true end)
    self:RegisterEvent("PLAYER_STOPPED_MOVING", function() swingState.moving = false end)

    local function OnZoneOrPetSync()
        AttachEUITrails()
        ApplyLayoutAndTheme()
        SyncHiddenEUIFrames()
        C_Timer.After(0.15, function() if mod._active then SyncHiddenEUIFrames() end end)
        C_Timer.After(0.65, function() if mod._active then SyncHiddenEUIFrames(); UpdateCombatAuras() end end)
        C_Timer.After(1.50, function() if mod._active then SyncHiddenEUIFrames(); UpdateCombatAuras() end end)
    end
    self:RegisterEvent("PLAYER_ENTERING_WORLD", OnZoneOrPetSync)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", OnZoneOrPetSync)
    self:RegisterEvent("PET_BAR_UPDATE", QueuePetHideSync)

    ApplyLayoutAndTheme()
    C_Timer.After(0.8, function()
        if mod._active then
            AttachEUITrails()
            ApplyLayoutAndTheme()
        end
    end)
end

function mod:OnDisable()
    local EUI = _G.EllesmereUI
    if EUI and EUI.UnregisterUnlockModeListener then
        pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_CoreHUD_Idle")
    end
    if CH.petEventFrame then CH.petEventFrame:UnregisterAllEvents() end
    CH.swingTicker:Hide()
    self:SetLowHealthPulse(false)
    SetOrbTimerArc(nil, nil)
    CH.lastIdleAlpha = nil
    orbState.castActive = false
    orbState.castIcon = nil
    orbState.castSpellID = nil
    orbState.castGUID = nil
    orbState.lastSpellIcon = nil
    orbState.lastSpellUntil = 0
    orbState.currentIcon = nil
    swingState.mhEnd = 0
    swingState.ohEnd = 0
    swingState.rEnd = 0
    swingState.autoRepeat = false
    trState.tempExpanded = false
    CH.permState.cached = {}
    CH.permState.hasCleanScan = false
    CH.permState.RebuildIcons()
    if CH.coreFrame then
        if CH.coreFrame._orb then
            if CH.coreFrame._orb._haloAG then CH.coreFrame._orb._haloAG:Stop() end
            if CH.coreFrame._orb._spinAG then CH.coreFrame._orb._spinAG:Stop() end
            if CH.coreFrame._orb._spinAG2 then CH.coreFrame._orb._spinAG2:Stop() end
        end
        CH.coreFrame:Hide()
    end
    HidePetFeedMenu()
    if CH.ReleaseTargetAuras then CH.ReleaseTargetAuras() end
    if CH.petFrame then CH.petFrame:Hide() end
    if CH.topTargetFrame then CH.topTargetFrame:Hide() end
    if CH.euiTrailPlayer then CH.euiTrailPlayer:SetEnabled(false) end
    if CH.euiTrailTarget then CH.euiTrailTarget:SetEnabled(false) end
    SyncEUISmoothing()
    SyncHiddenEUIFrames()
    SyncTopRightAuraDedupe()
    CH.SyncClickLayers()
end

function mod:OnRefresh()
    ApplyLayoutAndTheme()
end

function mod:OnThemeChanged()
    ApplyLayoutAndTheme()
end

-- 供低血量预警模块触发血条微频警报脉冲
function mod:SetLowHealthPulse(active)
    if not (CH.coreFrame and CH.coreFrame._hpWing) then return end
    local ag = M.EnsurePulseAlpha(CH.coreFrame._hpWing._bar, 0.55, 1.0, 0.72)
    if not ag then return end
    if active then
        if not ag:IsPlaying() then ag:Play() end
    else
        if ag:IsPlaying() then ag:Stop() end
        CH.coreFrame._hpWing._bar:SetAlpha(1)
    end
end

function mod:IsOrbActive()
    return self._active == true and self:GetDB().showCoreHUD ~= false and self:GetDB().showOrb ~= false
end

function mod:GetAnchorFrame()
    return (CH.coreFrame and CH.coreFrame:IsShown()) and CH.coreFrame or nil
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h

    local function GetTopRightMode()
        if db.hideTopRightBlizzAuras ~= false then
            return (db.showTopRightMicroToggle ~= false) and "hide_with_toggle" or "hide_all"
        end
        return (db.dedupeTopRightAuras ~= false) and "dedupe" or "keep"
    end

    local function SetTopRightMode(v)
        if v == "hide_with_toggle" then
            db.hideTopRightBlizzAuras = true
            db.showTopRightMicroToggle = true
        elseif v == "hide_all" then
            db.hideTopRightBlizzAuras = true
            db.showTopRightMicroToggle = false
        elseif v == "dedupe" then
            db.hideTopRightBlizzAuras = false
            db.dedupeTopRightAuras = true
        else
            db.hideTopRightBlizzAuras = false
            db.dedupeTopRightAuras = false
        end
        trState.tempExpanded = false
        UpdateCombatAuras()
        SyncTopRightAuraDedupe()
    end

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "显示双翼血蓝条",
        tooltip = "显示双翼血蓝条并隐藏 EUI 玩家头像，关闭即还原。",
        getValue = function() return db.showCoreHUD ~= false end,
        setValue = function(v) db.showCoreHUD = v == true; ApplyLayoutAndTheme() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示独立宠物条",
        tooltip = "显示圆角宠物条并隐藏 EUI 宠物头像，关闭即还原。",
        getValue = function() return db.showPetFrame ~= false end,
        setValue = function(v) db.showPetFrame = v == true; ApplyLayoutAndTheme() end,
    }, {
        type = "toggle",
        text = "显示顶部目标条",
        tooltip = "显示顶部目标与目标的目标条，并隐藏 EUI 原目标头像。",
        getValue = function() return db.enableTopTarget ~= false end,
        setValue = function(v) db.enableTopTarget = v == true; ApplyLayoutAndTheme() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "中央技能球",
        tooltip = "施放主动技能时在中央显示图标、计时环与职业色光波。",
        getValue = function() return db.showOrb ~= false end,
        setValue = function(v) db.showOrb = v == true; ApplyLayoutAndTheme() end,
    }, {
        type = "toggle",
        text = "数值内嵌至条内",
        tooltip = "将血蓝、宠物名与目标信息放入条内，减少上方遮挡。",
        getValue = function() return db.textInsideBars ~= false end,
        setValue = function(v) db.textInsideBars = v == true; ApplyLayoutAndTheme() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "上方显示常驻增益",
        tooltip = "在圆球上方显示守护、姿态、光环与追踪，超 6 个折叠。",
        getValue = function() return db.showPermanentBuffs ~= false end,
        setValue = function(v) db.showPermanentBuffs = v == true; UpdateCombatAuras() end,
    }, {
        type = "toggle",
        text = "下方显示限时增益",
        tooltip = "在圆球下方显示限时增益，超 8 个自动折叠，脱战右键可取消。",
        getValue = function() return db.showCombatBuffs ~= false end,
        setValue = function(v) db.showCombatBuffs = v == true; UpdateCombatAuras() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "下方显示自身减益",
        tooltip = "在增益排下方按类型着色显示自身减益，无减益时不占位。",
        getValue = function() return db.showCombatDebuffs ~= false end,
        setValue = function(v) db.showCombatDebuffs = v == true; UpdateCombatAuras() end,
    }, {
        type = "dropdown",
        text = "右上角增益栏",
        tooltip = "控制小地图左侧原版增益栏收起、保留 [B] 按钮或仅去重。",
        values = {
            hide_with_toggle = "收起并保留 [B] 开关",
            hide_all         = "完全收起",
            dedupe           = "保留并隐藏已显示项",
            keep             = "保持原样",
        },
        order = { "hide_with_toggle", "hide_all", "dedupe", "keep" },
        getValue = GetTopRightMode,
        setValue = SetTopRightMode,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "目标显示减益",
        tooltip = "在顶部目标条下方优先显示自身与队友的减益图标。",
        disabled = function() return db.enableTopTarget == false end,
        getValue = function() return db.showTargetDebuffs ~= false end,
        setValue = function(v)
            db.showTargetDebuffs = v == true
            if CH.SyncTargetAuras then CH.SyncTargetAuras() end
        end,
    }, {
        type = "toggle",
        text = "目标显示增益",
        tooltip = "在顶部目标条下方显示目标增益，怪物与队友均支持。",
        disabled = function() return db.enableTopTarget == false end,
        getValue = function() return db.showTargetBuffs ~= false end,
        setValue = function(v)
            db.showTargetBuffs = v == true
            if CH.SyncTargetAuras then CH.SyncTargetAuras() end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "左翼挥砍射击条",
        tooltip = "在左翼上方显示挥砍条，猎人自动射击区分可移动与读瞄段。",
        getValue = function() return db.showUpperSwing ~= false end,
        setValue = function(v) db.showUpperSwing = v == true; ApplyLayoutAndTheme() end,
    }, {
        type = "toggle",
        text = "右翼资源副手条",
        tooltip = "在右翼上方显示连击点或双持副手挥砍条。",
        getValue = function() return db.showUpperClassPower ~= false end,
        setValue = function(v) db.showUpperClassPower = v == true; ApplyLayoutAndTheme() end,
    })
    y = y - h

    local function buildAdv(w, p, curY)
        local _, rh
        _, rh = w:DualRow(p, curY, {
            type = "dropdown",
            text = "双翼数值格式",
            tooltip = "设置双翼血蓝的数值与百分比排布，怒气和能量仅显示数值。",
            values = {
                mirror       = "镜像靠内（左 % | 血，右 蓝 | %）",
                num_pct      = "数字 | 百分比",
                pct_num      = "百分比 | 数字",
                mirror_outer = "镜像靠外（左 血 | %，右 % | 蓝）",
                num          = "仅显示数字",
                pct          = "仅显示百分比",
            },
            order = { "mirror", "num_pct", "pct_num", "mirror_outer", "num", "pct" },
            getValue = function() return db.wingTextFormat or "mirror" end,
            setValue = function(v) db.wingTextFormat = v; ApplyLayoutAndTheme() end,
        }, {
            type = "dropdown",
            text = "双翼数值位置",
            tooltip = "选择双翼数值靠中央图标、条内居中或外侧两端显示。",
            values = {
                inner  = "紧贴中央图标两侧",
                center = "双翼条内居中",
                outer  = "双翼外侧两端",
            },
            order = { "inner", "center", "outer" },
            getValue = function() return db.wingTextAnchor or "inner" end,
            setValue = function(v) db.wingTextAnchor = v; ApplyLayoutAndTheme() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "dropdown",
            text = "下方增益过滤",
            tooltip = "按持续时间过滤下方增益，守护与姿态仍归类到圆球上方。",
            values = {
                non_permanent = "除常驻外全部增益",
                short_2m      = "短期触发（≤2分钟）",
                short_5m      = "中短期增益（≤5分钟）",
                all           = "全部限时增益",
            },
            order = { "non_permanent", "short_2m", "short_5m", "all" },
            disabled = function() return db.showCombatBuffs == false end,
            getValue = function() return db.buffFilter or "non_permanent" end,
            setValue = function(v) db.buffFilter = v; UpdateCombatAuras() end,
        }, {
            type = "toggle",
            text = "掉血延迟残影",
            tooltip = "受击掉血时在底层留出半透明残影并平滑追赶，不遮挡护盾。",
            getValue = function() return db.showTrail ~= false end,
            setValue = function(v) db.showTrail = v == true; ApplyLayoutAndTheme() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "slider",
            text = "残影延迟 (秒)",
            min = 0.08, max = 0.35, step = 0.02,
            disabled = function() return db.showTrail == false end,
            getValue = function() return F.PlainNumber(db.trailDelay, 0.16) or 0.16 end,
            setValue = function(v) db.trailDelay = v; ApplyLayoutAndTheme() end,
        }, {
            type = "slider",
            text = "单翼宽度 (px)",
            min = 100, max = 180, step = 4,
            getValue = function() return F.PlainNumber(db.wingWidth, 136) or 136 end,
            setValue = function(v) db.wingWidth = math_floor(v + 0.5); ApplyLayoutAndTheme() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "slider",
            text = "整体缩放 (倍)",
            min = 0.75, max = 1.35, step = 0.05,
            getValue = function() return F.PlainNumber(db.scale, 1.0) or 1.0 end,
            setValue = function(v) db.scale = v; ApplyLayoutAndTheme() end,
        }, {
            type = "toggle",
            text = "双翼与目标可点击",
            tooltip = "开启后支持左键选中与右键单位菜单，关闭后完全鼠标穿透。",
            getValue = function() return db.clickableHUD ~= false end,
            setValue = function(v) db.clickableHUD = v == true; CH.SyncClickLayers() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "保留原版头像对比",
            tooltip = "开启新版双翼时同时保留 EUI 原头像，仅用于布局对比。",
            getValue = function() return db.keepOriginalEUI == true end,
            setValue = function(v) db.keepOriginalEUI = v == true; SyncHiddenEUIFrames() end,
        }, blank)
        curY = curY - rh
        return curY
    end

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("coreHUD", W, parent, y, buildAdv, blank)
    else
        y = buildAdv(W, parent, y)
    end
    return y
end
