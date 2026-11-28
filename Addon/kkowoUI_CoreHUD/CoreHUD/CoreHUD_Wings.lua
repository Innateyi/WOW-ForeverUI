----------------------------------------------------------------------
--  kkowoUI_CoreHUD — CoreHUD/CoreHUD_Wings.lua
--  居中双翼核心 HUD、中央旋转技能球、上方挥砍/副资源条与方案 A 增益减益带
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local CH = F._CoreHUD
if not CH then return end

local ipairs, math_floor, math_max, math_min, pairs, pcall, select, setmetatable, tostring, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, select, setmetatable, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown

local ST = F.StyleTokens
local M = F.Motion
local mod = CH.mod
local AIM_CLASSES, AIM_TIME = CH.AIM_CLASSES, CH.AIM_TIME
local ASPECT_SPELLS, DEBUFF_TYPE_COLORS = CH.ASPECT_SPELLS, CH.DEBUFF_TYPE_COLORS
local IsPermanentOrAspectSpell = CH.IsPermanentOrAspectSpell
local GetSpellNameSafe, GetSpellIconSafe = CH.GetSpellNameSafe, CH.GetSpellIconSafe
local GetClassCrestIcon, GetActiveShapeshiftInfo = CH.GetClassCrestIcon, CH.GetActiveShapeshiftInfo
local swingState, orbState, trState = CH.swingState, CH.orbState, CH.trState
local wingShownInstanceIDs, wingShownIndices, wingShownIcons = CH.wingShownInstanceIDs, CH.wingShownIndices, CH.wingShownIcons
local dedupedAuraBtns, dedupedAuraBtnList, auraAlphaGuarded = CH.dedupedAuraBtns, CH.dedupedAuraBtnList, CH.auraAlphaGuarded

----------------------------------------------------------------------
--  1) 构建居中双翼核心 HUD（CoreHUD）
----------------------------------------------------------------------
local function GetBarRadius(barH)
    local r = ST.GetCornerRadius(6)
    if r <= 0 then return 0 end
    local cap = math_max(2, math_floor(barH * 0.45))
    return math_min(r, cap)
end

local function CreateWingBar(parent, w, h, reverse)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(w, h)
    holder:EnableMouse(false)

    local bg = holder:CreateTexture(nil, "BACKGROUND", nil, -6)
    bg:SetAllPoints()
    bg:SetTexture(ST.TEX.FLAT)
    local tc = ST.COLORS.track
    bg:SetVertexColor(tc[1], tc[2], tc[3], tc[4])
    holder._bg = bg

    local sb = CreateFrame("StatusBar", nil, holder)
    sb:SetAllPoints()
    local fillPath = ST.GetBarFillTexture and ST.GetBarFillTexture(false) or ST.TEX.FLAT
    sb:SetStatusBarTexture(fillPath)
    sb._kkFillPath = fillPath
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(1)
    if reverse and sb.SetReverseFill then
        sb:SetReverseFill(true)
    end
    sb:EnableMouse(false)
    holder._bar = sb

    local sheen = sb:CreateTexture(nil, "OVERLAY", nil, 2)
    ST.Hairline(sheen)
    sheen:SetPoint("TOPLEFT", sb, "TOPLEFT", 2, -1)
    sheen:SetPoint("TOPRIGHT", sb, "TOPRIGHT", -2, -1)
    sheen:SetColorTexture(1, 1, 1, 0.14)
    holder._sheen = sheen

    holder._reverse = reverse == true
    return holder
end

local function ApplyWingStyle(holder, r1, g1, b1, r2, g2, b2, radius, fxOverride)
    if not holder then return end
    local rad = radius or GetBarRadius(F.PlainNumber(holder:GetHeight(), 16) or 16)
    -- 2-T 自制明暗条体贴图联动（关闭 fx_barTexture 时换回 FLAT）
    local wantFill = ST.GetBarFillTexture and ST.GetBarFillTexture(false, fxOverride) or ST.TEX.FLAT
    if holder._bar and holder._bar._kkFillPath ~= wantFill then
        holder._bar:SetStatusBarTexture(wantFill)
        holder._bar._kkFillPath = wantFill
        holder._bar._kkGradCache = nil
    end
    -- 柔和微透色融玻璃底槽：按当前条色相轻染（蓝条带柔蓝玻璃、绿条带柔绿玻璃，彻底告别生硬死黑块）
    if holder._bg then
        local bgA = (r1 + g1 + b1 < 0.25) and 0.34 or 0.42
        holder._bg:SetVertexColor(r1 * 0.16 + 0.06, g1 * 0.16 + 0.06, b1 * 0.16 + 0.08, bgA)
    end
    ST.ClearRoundedMask(holder)
    if rad > 0 then
        if holder._fuiBg then holder._fuiBg:Hide() end
        if holder._fuiBorders then
            for _, ln in ipairs(holder._fuiBorders) do ln:Hide() end
        end
        ST.MaskTexture(holder, holder._bg, rad)
        local fillTex = holder._bar:GetStatusBarTexture()
        if fillTex then ST.MaskTexture(holder, fillTex, rad) end
        if holder._sheen then ST.MaskTexture(holder, holder._sheen, rad) end
        if holder._aimZone then ST.MaskTexture(holder, holder._aimZone, rad) end
        if holder._spark and holder._spark._spark then
            ST.MaskTexture(holder, holder._spark._spark, rad)
        end
        if holder._trail and holder._trail._bar then
            local tTex = holder._trail._bar:GetStatusBarTexture()
            if tTex then ST.MaskTexture(holder, tTex, rad) end
        end
        ST.ApplyRoundedBorder(holder, rad, 0.05, 0.06, 0.09, 0.86, 6)
    else
        F.Theme.StylePanel(holder, 0, 0.80)
        if holder._fuiBorders then
            for _, ln in ipairs(holder._fuiBorders) do ln:Show() end
        end
    end
    -- 重建圆角遮罩后，同步把治疗预估/吸收盾/超量线与受击闪光叠层重挂到外层 holder 遮罩（或圆角归零时卸载）
    if holder._healPred and holder._healPred.SyncLayout then
        holder._healPred:SyncLayout(true)
    end
    if M.SyncBarHitFlashMask and holder._bar then
        M.SyncBarHitFlashMask(holder._bar, holder, rad)
    end
    ST.ApplyBarGradient(holder._bar, r1, g1, b1, r2, g2, b2, 0.98, holder._reverse)
end

local SetCombatBadge -- 战斗徽章显隐（定义在技能球段）
local hasActiveDebuffs = false
CH.lastIdleAlpha = nil

local function IsPlayerInCombatSafe()
    if _G.InCombatLockdown and _G.InCombatLockdown() then return true end
    if _G.UnitAffectingCombat then
        local ok, cbt = pcall(_G.UnitAffectingCombat, "player")
        if ok and not F.IsSecret(cbt) and cbt == true then return true end
    end
    return false
end

local function UnitExistsSafeLocal(unit)
    if not _G.UnitExists then return false end
    local ok, ex = pcall(_G.UnitExists, unit)
    return ok and not F.IsSecret(ex) and ex == true
end

local function UpdateOrbAmbientGlow()
    if not (CH.coreFrame and CH.coreFrame._orb) then return end
    local orb = CH.coreFrame._orb
    local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
    local inCombat = IsPlayerInCombatSafe()
    local energized = inCombat or orbState.castActive or (GetTime() < (orbState.lastSpellUntil or 0))

    if orb._halo then
        orb._halo:SetVertexColor(r2, g2, b2, 1)
        if orb._haloAG and orb._haloAG._al then
            orb._haloAG._al:SetFromAlpha(energized and 0.34 or 0.16)
            orb._haloAG._al:SetToAlpha(energized and 0.66 or 0.32)
            if not orb._haloAG:IsPlaying() then orb._haloAG:Play() end
        end
        orb._halo:Show()
    end
    -- 非战斗待机：两层流光环停转收起，只留柔和呼吸光晕（画面更沉稳，也省 GPU）
    if orb._spinArc then
        orb._spinArc:SetVertexColor(r2, g2, b2, 0.92)
        orb._spinArc:SetShown(energized)
        if orb._spinAG then
            orb._spinAG._rot:SetDuration(2.0)
            if energized then
                if not orb._spinAG:IsPlaying() then orb._spinAG:Play() end
            elseif orb._spinAG:IsPlaying() then
                orb._spinAG:Stop()
            end
        end
    end
    if orb._spinArc2 then
        orb._spinArc2:SetVertexColor(r1 * 0.5 + 0.5, g1 * 0.5 + 0.5, b1 * 0.5 + 0.5, 0.54)
        orb._spinArc2:SetShown(energized)
        if orb._spinAG2 then
            orb._spinAG2._rot:SetDuration(3.6)
            if energized then
                if not orb._spinAG2:IsPlaying() then orb._spinAG2:Play() end
            elseif orb._spinAG2:IsPlaying() then
                orb._spinAG2:Stop()
            end
        end
    end
    if orb._burstRing then
        orb._burstRing:SetVertexColor(r2, g2, b2, 1)
    end
end

SetCombatBadge = function(on, animate)
    local badge = CH.coreFrame and CH.coreFrame._orb and CH.coreFrame._orb._combatIcon
    if not badge then return end
    if on then
        F.Theme.FadeTo(badge, 1, 0) -- 中止可能仍在进行的淡出
        badge:Show()
        if badge._glowAG and not badge._glowAG:IsPlaying() then badge._glowAG:Play() end
        if animate then M.PlayScalePop(badge, 1.28, 0.22) end
    elseif badge:IsShown() then
        if badge._glowAG then badge._glowAG:Stop() end
        if animate then
            F.Theme.FadeTo(badge, 0, 0.28, true)
        else
            badge:Hide()
        end
    end
end

local function SetOrbTexCoords(texObj, iconPath)
    if iconPath == ST.TEX.LOGO_FLAT then
        texObj:SetTexCoord(0, 1, 0, 1)
    else
        texObj:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

local function UpdateOrbAppearance(triggerBurst)
    if not CH.coreFrame or not CH.coreFrame._orb then return end
    local orb = CH.coreFrame._orb
    local db = mod:GetDB()
    orb:SetShown(db.showOrb ~= false)
    if db.showOrb == false then return end

    local now = GetTime()
    local nextIcon
    local isSkillIcon = false
    if orbState.castActive and orbState.castIcon then
        nextIcon = orbState.castIcon
        isSkillIcon = true
    elseif orbState.lastSpellIcon and now < (orbState.lastSpellUntil or 0) then
        nextIcon = orbState.lastSpellIcon
        isSkillIcon = true
    else
        nextIcon = GetClassCrestIcon()
    end

    local prevIcon = orbState.currentIcon
    local changed = (nextIcon ~= prevIcon)
    if changed or triggerBurst then
        orbState.currentIcon = nextIcon
        if changed and prevIcon and orb._iconPrev then
            pcall(orb._iconPrev.SetTexture, orb._iconPrev, prevIcon)
            SetOrbTexCoords(orb._iconPrev, prevIcon)
        end
        pcall(orb._icon.SetTexture, orb._icon, nextIcon)
        SetOrbTexCoords(orb._icon, nextIcon)

        if changed then
            -- 丝滑双层交叉溶解：切入技能 0.20s 柔顺浮现，施法结束回默认图标 0.24s 平滑淡回，零跳切
            M.PlayIconCrossfade(orb._icon, (prevIcon and orb._iconPrev) or nil, isSkillIcon and 0.20 or 0.24, not isSkillIcon)
            if isSkillIcon then
                M.PlayOrbBurst(orb._burstRing, orb._flash, 0.38)
            end
        elseif triggerBurst and isSkillIcon then
            M.PlayOrbBurst(orb._burstRing, orb._flash, 0.34)
        end
    end
    UpdateOrbAmbientGlow()
end

local function SetOrbTimerArc(startTime, duration, activeColorR, activeColorG, activeColorB)
    if not CH.coreFrame or not CH.coreFrame._orb then return end
    local orb = CH.coreFrame._orb
    local cd = orb._cd
    if startTime and duration and duration > 0.05 then
        if cd and cd.SetCooldown then
            pcall(cd.SetCooldown, cd, startTime, duration)
            if activeColorR and cd.SetSwipeColor then
                pcall(cd.SetSwipeColor, cd, activeColorR, activeColorG, activeColorB, 0.92)
            end
            cd:Show()
        end
    else
        if cd then cd:Hide() end
    end
    UpdateOrbAmbientGlow()
end

local function UpdateIdleFade(instant)
    if not CH.coreFrame then return end
    local db = mod:GetDB()
    if not mod._active then return end
    local unlockOn = _G.EllesmereUI and _G.EllesmereUI._unlockActive == true
    local targetA = 1.0
    -- 脱战淡隐已统一到「脱战淡隐（统一开关）」：它接管时这里完全不碰透明度（两套淡隐会互相抢）；
    -- 不接管（总开关或「核心双翼」项关掉）时保持 100%，不再走下面这套独立淡隐
    local UF = F.UnifiedFade
    if UF then
        if UF.Owns("coreHUD") then
            CH.lastIdleAlpha = nil
            return
        end
    elseif db.idleFade ~= false and not unlockOn then
        local inCombat = IsPlayerInCombatSafe()
        local hasTarget = UnitExistsSafeLocal("target")
        local activeCast = orbState.castActive or (GetTime() < (orbState.lastSpellUntil or 0))
        local lowRes = false
        local hp = F.PlainNumber(_G.UnitHealth and _G.UnitHealth("player"), nil)
        local mx = F.PlainNumber(_G.UnitHealthMax and _G.UnitHealthMax("player"), nil)
        if hp and mx and mx > 0 and (hp / mx) < 0.99 then lowRes = true end
        local pType = F.PlainNumber(_G.UnitPowerType and _G.UnitPowerType("player"), 0) or 0
        if pType == 0 then
            local pp = F.PlainNumber(_G.UnitPower and _G.UnitPower("player", 0), nil)
            local pmx = F.PlainNumber(_G.UnitPowerMax and _G.UnitPowerMax("player", 0), nil)
            if pp and pmx and pmx > 0 and (pp / pmx) < 0.99 then lowRes = true end
        end
        if not inCombat and not hasTarget and not activeCast and not hasActiveDebuffs and not lowRes then
            targetA = math_max(0.15, math_min(0.90, F.PlainNumber(db.idleAlpha, 0.50) or 0.50))
        end
    end
    if not instant and CH.lastIdleAlpha == targetA then return end
    CH.lastIdleAlpha = targetA
    local dur = instant and 0.01 or ((targetA >= 0.99) and 0.14 or 0.42)
    if CH.coreFrame:IsShown() then
        F.Theme.FadeTo(CH.coreFrame, targetA, dur, false)
    end
    if CH.petFrame and CH.petFrame:IsShown() then
        F.Theme.FadeTo(CH.petFrame, targetA, dur, false)
    end
end

-- 方案 A：圆球正上方常驻 BUFF（守护/姿态/光环/无时长常驻）+ 正下方两行（增益 Buff / 自身减益 Debuff，均带 +N 溢出折叠）
local MAX_PERM_SLOTS = 6
local MAX_AURA_SLOTS = 8

-- 战斗中 12.x 光环可能受限（GetAuraDataByIndex 直接报错）或字段变成保密值（spellId / name / duration / auraInstanceID 不可读）：
-- 1) 未受限时记住每个 auraInstanceID 的常驻分类，并保存当前常驻 BUFF 快照与图标集；
-- 2) 战斗中扫表受限或字段保密导致顶部常驻排为空时，沿用快照 + 姿态栏（GetShapeshiftFormInfo，战斗始终可读）
--    + 施法事件（UNIT_SPELLCAST_SUCCEEDED，战斗中切守护/光环即时同步图标），避免顶部常驻 BUFF 消失。
CH.permState = {
    byInstance = {},
    byInstanceCount = 0,
    cached = {},
    cachedIcons = {},
    hasCleanScan = false,
}

function CH.permState.AreAurasRestricted()
    local S = _G.C_Secrets
    if S and S.ShouldAurasBeSecret then
        local ok, sec = pcall(S.ShouldAurasBeSecret)
        if not ok or F.IsSecret(sec) or sec == true then
            return true
        end
    end
    return false
end

function CH.permState.GetFamily(sid, nm)
    if sid and ASPECT_SPELLS[sid] then return "aspect" end
    if type(nm) == "string" and nm ~= "" then
        if nm:find("守护", 1, true) or nm:find("Aspect of", 1, true) then
            return "aspect"
        elseif nm:find("姿态", 1, true) or nm:find("形态", 1, true)
            or nm:find("Stance", 1, true) or nm:find("Form", 1, true) then
            return "stance"
        elseif (nm:find("光环", 1, true) or nm:find("Aura", 1, true)) and F.GetPlayerClass() == "PALADIN" then
            return "paladinaura"
        elseif nm:find("追踪", 1, true) or nm:find("寻找", 1, true)
            or nm:find("Track ", 1, true) or nm:find("Find ", 1, true) then
            return "tracking"
        end
    end
    return nil
end

function CH.permState.RebuildIcons()
    for k in pairs(CH.permState.cachedIcons) do CH.permState.cachedIcons[k] = nil end
    for _, e in ipairs(CH.permState.cached) do
        if not F.IsSecret(e.icon) and type(e.icon) ~= "nil" then
            CH.permState.cachedIcons[e.icon] = true
        end
    end
end

function CH.permState.SaveCleanSnapshot(permList)
    CH.permState.hasCleanScan = true
    local snap = {}
    for _, it in ipairs(permList) do
        local ic = (not F.IsSecret(it.icon) and type(it.icon) ~= "nil") and it.icon or nil
        if ic then
            local iid = (not F.IsSecret(it.auraInstanceID) and type(it.auraInstanceID) ~= "nil") and it.auraInstanceID or nil
            snap[#snap + 1] = {
                index = it.index,
                spellID = it.spellID,
                name = it.name,
                auraInstanceID = iid,
                icon = ic,
                applications = F.PlainNumber(it.applications, nil),
                family = CH.permState.GetFamily(it.spellID, it.name),
                isPerm = true,
            }
        end
    end
    CH.permState.cached = snap
    CH.permState.RebuildIcons()
end

function CH.permState.RecordSpellCast(sid, sName)
    if not sid or sid == 8690 then return end
    if type(sName) == "string" and (sName:find("炉石", 1, true) or sName:find("Hearthstone", 1, true)) then
        return
    end
    local ic = GetSpellIconSafe(sid)
    if not ic then return end
    local fam = CH.permState.GetFamily(sid, sName)
    local inCombat = IsPlayerInCombatSafe()
    local entry = {
        spellID = sid,
        name = sName,
        icon = ic,
        family = fam,
        isPerm = true,
        fromCache = true,
        castInCombat = inCombat == true,
    }
    local replaced = false
    if fam == "aspect" or fam == "paladinaura" or fam == "tracking" or fam == "stance" then
        for i, e in ipairs(CH.permState.cached) do
            if e.family == fam or CH.permState.GetFamily(e.spellID, e.name) == fam then
                CH.permState.cached[i] = entry
                replaced = true
                break
            end
        end
    else
        for i, e in ipairs(CH.permState.cached) do
            if (e.spellID and e.spellID == sid) or (e.icon == ic) then
                CH.permState.cached[i] = entry
                replaced = true
                break
            end
        end
    end
    if not replaced then
        CH.permState.cached[#CH.permState.cached + 1] = entry
    end
    CH.permState.RebuildIcons()
    if mod._queueAuraUpdate then mod._queueAuraUpdate() end
end

function CH.permState.BuildFallback()
    local out = {}
    for _, e in ipairs(CH.permState.cached) do
        out[#out + 1] = {
            index = e.index,
            spellID = e.spellID,
            name = e.name,
            auraInstanceID = e.auraInstanceID,
            icon = e.icon,
            applications = e.applications,
            family = e.family,
            isPerm = true,
            fromCache = true,
        }
    end

    -- 姿态/形态栏在战斗中始终实时可读：同步切换后的姿态/德鲁伊形态/圣骑光环/进姿态栏的守护
    local sIcon, sName, sSpellID = GetActiveShapeshiftInfo()
    if sIcon then
        local sFam = CH.permState.GetFamily(sSpellID, sName) or "stance"
        local matchedIdx = nil
        for i, e in ipairs(out) do
            if (sSpellID and e.spellID == sSpellID) or (e.icon == sIcon) or (e.family == sFam) then
                matchedIdx = i
                break
            end
        end
        if matchedIdx then
            local e = out[matchedIdx]
            e.icon = sIcon
            e.name = sName or e.name
            e.spellID = sSpellID or e.spellID
            e.family = sFam
        elseif not CH.permState.hasCleanScan then
            out[#out + 1] = {
                spellID = sSpellID,
                name = sName,
                icon = sIcon,
                family = sFam,
                isPerm = true,
                fromCache = true,
            }
        end
    elseif _G.GetNumShapeshiftForms and (F.PlainNumber(_G.GetNumShapeshiftForms(), 0) or 0) > 0 then
        -- 战斗中从熊/猫形态切回人形时清掉过期的形态缓存
        for i = #out, 1, -1 do
            if out[i].family == "stance" then
                table.remove(out, i)
            end
        end
    end

    -- 战中 /reload 尚未完成脱战扫描时，尝试用非保密白名单法术直查猎人守护
    if #out == 0 and not CH.permState.hasCleanScan and F.GetPlayerClass() == "HUNTER"
        and _G.C_UnitAuras and _G.C_UnitAuras.GetPlayerAuraBySpellID then
        local S = _G.C_Secrets
        for sid in pairs(ASPECT_SPELLS) do
            local isSec = false
            if S and S.ShouldSpellAuraBeSecret then
                local okS, sec = pcall(S.ShouldSpellAuraBeSecret, sid)
                if not okS or F.IsSecret(sec) or sec == true then isSec = true end
            end
            if not isSec then
                local okA, a = pcall(_G.C_UnitAuras.GetPlayerAuraBySpellID, sid)
                if okA and not F.IsSecret(a) and type(a) == "table" then
                    local ic = (not F.IsSecret(a.icon) and type(a.icon) ~= "nil") and a.icon or GetSpellIconSafe(sid)
                    if ic then
                        out[#out + 1] = {
                            spellID = sid,
                            name = F.PlainString(a.name, nil) or GetSpellNameSafe(sid),
                            icon = ic,
                            family = "aspect",
                            isPerm = true,
                            fromCache = true,
                        }
                        break
                    end
                end
            end
        end
    end
    return out
end

local function ClassifyPerm(iidKey, sid, nm, dur, durSecret, iconKey)
    local matched = IsPermanentOrAspectSpell(sid, nm)
    if matched or not durSecret then
        local isPerm = matched or (not dur or dur <= 0)
        if iidKey and CH.permState.byInstance[iidKey] ~= isPerm then
            if CH.permState.byInstance[iidKey] == nil then
                CH.permState.byInstanceCount = CH.permState.byInstanceCount + 1
                if CH.permState.byInstanceCount > 300 then
                    for k in pairs(CH.permState.byInstance) do CH.permState.byInstance[k] = nil end
                    CH.permState.byInstanceCount = 1
                end
            end
            CH.permState.byInstance[iidKey] = isPerm
        end
        return isPerm
    end
    if iidKey and CH.permState.byInstance[iidKey] ~= nil then
        return CH.permState.byInstance[iidKey]
    end
    if iconKey and CH.permState.cachedIcons[iconKey] then
        if iidKey then CH.permState.byInstance[iidKey] = true end
        return true
    end
    return false
end

local function CollectSplitBuffs(buffMode)
    local permOut = {}
    local timedOut = {}
    local scanBlocked = false
    local sawSecretAura = false
    local getByIdx = _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDataByIndex
    if getByIdx then
        for i = 1, 60 do
            local ok, aura = pcall(getByIdx, "player", i, "HELPFUL")
            if not ok then
                scanBlocked = true
                break
            end
            if type(aura) == "nil" then break end
            if F.IsSecret(aura) or type(aura) ~= "table" then
                sawSecretAura = true
            elseif type(aura.icon) ~= "nil" then
                local sid = F.PlainNumber(aura.spellId, nil)
                local nm = F.PlainString(aura.name, nil)
                local dur = F.PlainNumber(aura.duration, nil)
                local durSecret = F.IsSecret(aura.duration)
                local iid = aura.auraInstanceID
                local iidKey = (not F.IsSecret(iid) and type(iid) ~= "nil") and iid or nil
                local iconKey = (not F.IsSecret(aura.icon)) and aura.icon or nil
                if durSecret or F.IsSecret(aura.spellId) or F.IsSecret(aura.name)
                    or F.IsSecret(iid) or F.IsSecret(aura.icon) then
                    sawSecretAura = true
                end
                local isPerm = ClassifyPerm(iidKey, sid, nm, dur, durSecret, iconKey)
                local item = {
                    index = i,
                    spellID = sid,
                    name = nm,
                    auraInstanceID = iid,
                    icon = aura.icon,
                    applications = aura.applications,
                    duration = aura.duration,
                    expirationTime = aura.expirationTime,
                    dispelName = F.PlainString(aura.dispelName, nil),
                    isPerm = isPerm,
                }
                if isPerm then
                    permOut[#permOut + 1] = item
                else
                    local keep = true
                    if not durSecret then
                        if buffMode == "short_2m" and (not dur or dur <= 0 or dur > 120) then
                            keep = false
                        elseif buffMode == "short_5m" and (not dur or dur <= 0 or dur > 300) then
                            keep = false
                        end
                    end
                    if keep then
                        timedOut[#timedOut + 1] = item
                    end
                end
            end
        end
    elseif _G.UnitBuff then
        for i = 1, 60 do
            local ok, nm, ic, count, dispelType, dur, expTime, _, _, _, sid = pcall(_G.UnitBuff, "player", i)
            if not ok then
                scanBlocked = true
                break
            end
            if not F.IsSecret(nm) and not nm then break end
            if type(ic) ~= "nil" then
                local pSid = F.PlainNumber(sid, nil)
                local pNm = F.PlainString(nm, nil)
                local pDur = F.PlainNumber(dur, nil)
                local durSecret = F.IsSecret(dur)
                local iconKey = (not F.IsSecret(ic)) and ic or nil
                if durSecret or F.IsSecret(sid) or F.IsSecret(nm) or F.IsSecret(ic) then
                    sawSecretAura = true
                end
                local isPerm = ClassifyPerm(nil, pSid, pNm, pDur, durSecret, iconKey)
                local item = {
                    index = i,
                    spellID = pSid,
                    name = pNm,
                    icon = ic,
                    applications = count,
                    duration = dur,
                    expirationTime = expTime,
                    dispelName = F.PlainString(dispelType, nil),
                    isPerm = isPerm,
                }
                if isPerm then
                    permOut[#permOut + 1] = item
                else
                    local keep = true
                    if not durSecret then
                        if buffMode == "short_2m" and (not pDur or pDur <= 0 or pDur > 120) then
                            keep = false
                        elseif buffMode == "short_5m" and (not pDur or pDur <= 0 or pDur > 300) then
                            keep = false
                        end
                    end
                    if keep then
                        timedOut[#timedOut + 1] = item
                    end
                end
            end
        end
    end

    local auraRestricted = scanBlocked or CH.permState.AreAurasRestricted()
    if not auraRestricted and not sawSecretAura then
        CH.permState.SaveCleanSnapshot(permOut)
    elseif scanBlocked or (#permOut == 0 and (sawSecretAura or auraRestricted)) then
        permOut = CH.permState.BuildFallback()
    elseif sawSecretAura then
        -- 战斗中已有其他常驻 BUFF 命中缓存，但新切出的守护/光环因新 instanceID + 保密图标漏掉时，补回本场战斗刚施放的常驻项
        for _, ce in ipairs(CH.permState.cached) do
            if ce.castInCombat and ce.icon then
                local found = false
                for _, pe in ipairs(permOut) do
                    local pIc = (not F.IsSecret(pe.icon) and type(pe.icon) ~= "nil") and pe.icon or nil
                    if (ce.spellID and pe.spellID == ce.spellID) or (pIc and pIc == ce.icon) then
                        found = true
                        break
                    end
                end
                if not found then
                    permOut[#permOut + 1] = {
                        spellID = ce.spellID,
                        name = ce.name,
                        icon = ce.icon,
                        family = ce.family,
                        isPerm = true,
                        fromCache = true,
                    }
                end
            end
        end
    end

    return permOut, timedOut
end

local function CollectUnitDebuffs()
    local out = {}
    local getByIdx = _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDataByIndex
    if getByIdx then
        for i = 1, 40 do
            local ok, aura = pcall(getByIdx, "player", i, "HARMFUL")
            if not ok or type(aura) == "nil" then break end
            if not F.IsSecret(aura) and type(aura) == "table" and type(aura.icon) ~= "nil" then
                out[#out + 1] = {
                    index = i,
                    name = F.PlainString(aura.name, nil),
                    auraInstanceID = aura.auraInstanceID,
                    icon = aura.icon,
                    applications = aura.applications,
                    duration = aura.duration,
                    expirationTime = aura.expirationTime,
                    dispelName = F.PlainString(aura.dispelName, nil),
                }
            end
        end
    elseif _G.UnitDebuff then
        for i = 1, 40 do
            local ok, nm, ic, count, dispelType, dur, expTime = pcall(_G.UnitDebuff, "player", i)
            if not ok or (not F.IsSecret(nm) and not nm) then break end
            if type(ic) ~= "nil" then
                out[#out + 1] = {
                    index = i,
                    name = F.PlainString(nm, nil),
                    icon = ic,
                    applications = count,
                    duration = dur,
                    expirationTime = expTime,
                    dispelName = F.PlainString(dispelType, nil),
                }
            end
        end
    end
    return out
end

-- 精致化 Cooldown 原生倒计时字体（彻底解决暴雪默认 16px 巨字糊满图标：9px 清爽描边沉底居中留在框内，12.x 保密值安全）
local function StyleCooldownTimerFont(cd, slot)
    if not (cd and cd.GetRegions) then return end
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

local function ApplyAuraSlotData(slot, data, isDebuff, size, isPerm)
    slot:SetSize(size, size)
    slot._auraIndex = data.index
    slot._auraInstanceID = data.auraInstanceID
    slot._spellID = data.spellID
    slot._auraName = data.name
    slot._fromCache = data.fromCache == true
    slot._isDebuff = isDebuff
    slot._isPerm = isPerm == true
    pcall(slot._icon.SetTexture, slot._icon, data.icon)

    local cd = slot._cd
    local appliedCD = false
    if not isPerm then
        if type(data.auraInstanceID) ~= "nil" and _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDuration and cd.SetCooldownFromDurationObject then
            local okD, durObj = pcall(_G.C_UnitAuras.GetAuraDuration, "player", data.auraInstanceID)
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
    end
    cd:SetShown(appliedCD)
    if slot._timerShade then slot._timerShade:SetShown(appliedCD) end
    if appliedCD then
        StyleCooldownTimerFont(cd, slot)
    end

    local stacks = F.PlainNumber(data.applications, 0) or 0
    if stacks > 1 then
        slot._stacks:SetText(tostring(stacks))
        slot._stacks:Show()
    else
        slot._stacks:Hide()
    end

    local rad = math_min(ST.GetCornerRadius(5), isPerm and 5 or 6)
    if slot._lastRad ~= rad then
        slot._lastRad = rad
        ST.ClearRoundedMask(slot)
        if rad > 0 then
            ST.SetHostIconMode(slot, true)
            ST.MaskTexture(slot, slot._bg, rad)
            ST.MaskIcon(slot, slot._icon, rad)
            if slot._timerShade then ST.MaskTexture(slot, slot._timerShade, rad) end
        end
    end
    local br, bg, bb, ba
    if isDebuff then
        local dc = (data.dispelName and DEBUFF_TYPE_COLORS[data.dispelName]) or { 0.94, 0.28, 0.32 }
        br, bg, bb, ba = dc[1], dc[2], dc[3], 0.96
    elseif isPerm then
        local r1, g1, b1 = ST.GetClassGradient()
        br, bg, bb, ba = r1 * 0.45 + 0.24, g1 * 0.45 + 0.26, b1 * 0.45 + 0.30, 0.86
    else
        local _, _, _, r2, g2, b2 = ST.GetClassGradient()
        br, bg, bb, ba = r2 * 0.72 + 0.10, g2 * 0.72 + 0.10, b2 * 0.72 + 0.10, 0.92
    end
    if rad > 0 then
        if slot._fuiBg then slot._fuiBg:Hide() end
        if slot._fuiBorders then
            for _, ln in ipairs(slot._fuiBorders) do ln:Hide() end
        end
        ST.ApplyRoundedBorder(slot, rad, br, bg, bb, ba, 5)
    else
        ST.ApplyRoundedBorder(slot, 0)
        F.Theme.StylePanel(slot, 0, ba)
        if slot._fuiBorders then
            for _, ln in ipairs(slot._fuiBorders) do
                ln:SetColorTexture(br, bg, bb, ba)
                ln:Show()
            end
        end
    end
    slot:Show()
end

local function IsSafeBlizzFrame(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function SetAuraBtnMuted(btn, mute)
    if not IsSafeBlizzFrame(btn) then return end
    if not auraAlphaGuarded[btn] then
        auraAlphaGuarded[btn] = true
        if btn.SetAlpha then
            _G.hooksecurefunc(btn, "SetAlpha", function(self, a)
                if not trState.alphaBusy and dedupedAuraBtns[self] and F.PlainNumber(a, 1) ~= 0 then
                    trState.alphaBusy = true
                    pcall(self.SetAlpha, self, 0)
                    trState.alphaBusy = false
                end
            end)
        end
    end
    if mute then
        if not dedupedAuraBtns[btn] then
            dedupedAuraBtns[btn] = true
            dedupedAuraBtnList[#dedupedAuraBtnList + 1] = btn
        end
        trState.alphaBusy = true
        pcall(btn.SetAlpha, btn, 0)
        trState.alphaBusy = false
    elseif dedupedAuraBtns[btn] then
        dedupedAuraBtns[btn] = nil
        trState.alphaBusy = true
        pcall(btn.SetAlpha, btn, 1)
        trState.alphaBusy = false
    end
end

local function IsBuffBtnShownOnWing(btn)
    local info = btn.buttonInfo
    if type(info) == "table" then
        local iid = info.auraInstanceID
        if not F.IsSecret(iid) and type(iid) ~= "nil" and wingShownInstanceIDs[iid] then
            return true
        end
        local idx = F.PlainNumber(info.index, nil)
        if idx and wingShownIndices[idx] then
            return true
        end
        local tex = info.texture
        local expT = F.PlainNumber(info.expirationTime, nil)
        if not F.IsSecret(tex) and type(tex) ~= "nil" and wingShownIcons[tex] and expT and expT > 0 then
            return true
        end
    end
    -- 回退：仅对带有倒计时文本的限时增益做图标匹配，绝不误伤常驻守护/光环
    local durFS = btn.Duration or btn.duration
    local hasDurText = false
    if durFS and durFS.IsShown and durFS.GetText then
        local okS, sh = pcall(durFS.IsShown, durFS)
        if okS and not F.IsSecret(sh) and sh then
            local okT, rawT = pcall(durFS.GetText, durFS)
            if okT and type(rawT) ~= "nil" then
                if F.IsSecret(rawT) then
                    hasDurText = true
                else
                    local dt = F.PlainString(rawT, "") or ""
                    if dt ~= "" then hasDurText = true end
                end
            end
        end
    end
    if hasDurText then
        local icObj = btn.Icon or btn.icon
        if icObj and icObj.GetTexture then
            local okT, tex = pcall(icObj.GetTexture, icObj)
            if okT and not F.IsSecret(tex) and type(tex) ~= "nil" and wingShownIcons[tex] then
                return true
            end
        end
    end
    return false
end

local SyncTopRightAuraDedupe -- 前向声明

-- 动态测量小地图左上外侧已占用的指示器列宽度（EUI「追踪 / 日历 / 邮件」等贴在小地图左缘，宽约 25px），
-- 把「B」快捷开关摆在指示器列左侧 8px 之外，绝不遮挡「追踪」按钮
local function PositionTopRightMicroToggle(btn)
    if not btn then return end
    local mm = _G.Minimap
    btn:ClearAllPoints()
    if not mm then
        btn:SetPoint("TOPRIGHT", _G.UIParent, "TOPRIGHT", -240, -8)
        return
    end
    local minOffset = 6
    local edb = _G._EMM_DB
    local mp = edb and edb.profile and edb.profile.minimap
    if type(mp) == "table" then
        local bsz = F.PlainNumber(mp.interactableBtnSize, 25) or 25
        local dist = F.PlainNumber(mp.elementRowDistance, 0) or 0
        -- 仅当 EUI 指示器列可能位于小地图左侧时预留保底宽度（默认 left_top / left_bottom 等）
        local pos = mp.elementRowPos
        if pos == nil or (type(pos) == "string" and pos:find("left", 1, true)) then
            minOffset = math_max(minOffset, bsz + math_max(0, dist) + 8)
        end
    end

    local mmL = mm.GetLeft and F.PlainNumber(mm:GetLeft(), nil)
    local mmT = mm.GetTop and F.PlainNumber(mm:GetTop(), nil)
    local mmS = mm.GetEffectiveScale and F.PlainNumber(mm:GetEffectiveScale(), 1) or 1
    if mmL and mmT and mmS > 0 and mm.GetChildren then
        local leftMost = mmL
        for _, ch in ipairs({ mm:GetChildren() }) do
            if ch and ch ~= btn and not (ch.IsForbidden and ch:IsForbidden())
                and ch.IsShown and ch:IsShown() and ch.GetLeft and ch.GetRight and ch.GetTop then
                local l = F.PlainNumber(ch:GetLeft(), nil)
                local r = F.PlainNumber(ch:GetRight(), nil)
                local t = F.PlainNumber(ch:GetTop(), nil)
                local cs = ch.GetEffectiveScale and F.PlainNumber(ch:GetEffectiveScale(), mmS) or mmS
                if l and r and t and cs > 0 then
                    local k = cs / mmS
                    l, r, t = l * k, r * k, t * k
                    if r <= mmL + 8 and l >= mmL - 96 and l < leftMost and t >= mmT - 48 then
                        leftMost = l
                    end
                end
            end
        end
        local protruded = mmL - leftMost
        if protruded > 1 then
            minOffset = math_max(minOffset, math_floor(protruded + 0.5) + 8)
        end
    end

    btn:SetPoint("TOPRIGHT", mm, "TOPLEFT", -minOffset, -2)
end

local function HookMinimapApplyForMicroToggle()
    if trState.minimapHooked then return end
    if type(_G._EMM_ApplyMinimap) == "function" then
        trState.minimapHooked = true
        _G.hooksecurefunc("_EMM_ApplyMinimap", function()
            if mod._active and trState.microBtn and trState.microBtn:IsShown() then
                C_Timer.After(0, function()
                    if mod._active and trState.microBtn and trState.microBtn:IsShown() then
                        PositionTopRightMicroToggle(trState.microBtn)
                    end
                end)
            end
        end)
    end
end

local function EnsureTopRightMicroToggle()
    if trState.microBtn then return trState.microBtn end
    local btn = CreateFrame("Button", "kkowoUI_TopRightAuraToggle", _G.UIParent)
    btn:SetSize(22, 20)
    btn:SetFrameStrata("LOW")
    btn:SetFrameLevel(16)
    PositionTopRightMicroToggle(btn)
    HookMinimapApplyForMicroToggle()

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(ST.TEX.FLAT)
    bg:SetVertexColor(0.06, 0.08, 0.11, 0.76)
    btn._bg = bg

    local fs = btn:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(fs, 10, 0.88, 0.94, 0.98, 1)
    fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
    fs:SetText("B")
    btn._label = fs

    ST.MaskTexture(btn, bg, 5)
    ST.ApplyRoundedBorder(btn, 5, ST.COLORS.info[1], ST.COLORS.info[2], ST.COLORS.info[3], 0.65, 4)

    btn:SetAlpha(0.24)
    btn:SetScript("OnEnter", function(self)
        self:SetAlpha(0.96)
        if _G.GameTooltip then
            _G.GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT", 0, -4)
            _G.GameTooltip:AddLine("右上角暴雪原生增益栏", ST.COLORS.info[1], ST.COLORS.info[2], ST.COLORS.info[3])
            if trState.tempExpanded then
                _G.GameTooltip:AddLine("当前：已临时展开原生 Buff/Debuff", 0.94, 0.96, 0.99)
                _G.GameTooltip:AddLine("点击再次收起，保持右上角清爽", 0.72, 0.78, 0.85)
            else
                _G.GameTooltip:AddLine("当前：已全部集成到双翼上下，右上角清爽收起", 0.94, 0.96, 0.99)
                _G.GameTooltip:AddLine("点击临时展开原生栏", 0.72, 0.78, 0.85)
            end
            _G.GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetAlpha(trState.tempExpanded and 0.82 or 0.24)
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    btn:SetScript("OnClick", function()
        trState.tempExpanded = not trState.tempExpanded
        SyncTopRightAuraDedupe()
    end)
    btn:Hide()
    trState.microBtn = btn
    return btn
end

-- 透明度为 0 的框体仍会接收鼠标：收起/去重后的暴雪原生光环按钮必须同时关掉鼠标，
-- 否则右上角会残留「看不见却能悬停出提示、右键还能取消增益」的隐形按钮。
-- 光环按钮在 12.x 可能受保护，统一放到脱战窗口里改（战斗中新出现的按钮脱战后补齐）。
local auraMouseOff = setmetatable({}, { __mode = "k" })

local function ForEachBlizzAuraButton(root, fn)
    if not IsSafeBlizzFrame(root) then return end
    if type(root.auraFrames) == "table" then
        for _, btn in ipairs(root.auraFrames) do
            if IsSafeBlizzFrame(btn) then fn(btn) end
        end
    end
    local c = root.AuraContainer
    if IsSafeBlizzFrame(c) and c.GetChildren then
        for _, btn in ipairs({ c:GetChildren() }) do
            if IsSafeBlizzFrame(btn) and (btn.Icon or btn.icon) then fn(btn) end
        end
    end
end

local function SetBlizzAuraBtnMouse(btn, off)
    if not (btn.EnableMouse and btn.IsMouseEnabled) then return end
    if off then
        if not auraMouseOff[btn] then
            local okM, en = pcall(btn.IsMouseEnabled, btn)
            if okM and en == true then
                auraMouseOff[btn] = true
                pcall(btn.EnableMouse, btn, false)
            end
        end
    elseif auraMouseOff[btn] then
        auraMouseOff[btn] = nil
        pcall(btn.EnableMouse, btn, true)
    end
end

local function SyncTopRightAuraMouse()
    ForEachBlizzAuraButton(_G.BuffFrame, function(btn)
        SetBlizzAuraBtnMouse(btn, trState.buffFullMuted or dedupedAuraBtns[btn] == true)
    end)
    ForEachBlizzAuraButton(_G.DebuffFrame, function(btn)
        SetBlizzAuraBtnMouse(btn, trState.debuffMuted)
    end)
end

local function CanToggleBlizzFrameVisibility(f)
    if not (f and f.Hide and f.Show) then return false end
    if InCombatLockdown and InCombatLockdown() and f.IsProtected then
        local okP, prot = pcall(f.IsProtected, f)
        if okP and prot then return false end
    end
    return true
end

local function NotifyMinimapAuraSkinRefresh()
    local skinMod = F.Modules and F.Modules.Get and F.Modules.Get("auraBarSkin") or nil
    if skinMod and skinMod._active and skinMod.OnRefresh then
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if skinMod._active then pcall(skinMod.OnRefresh, skinMod) end
            end)
        else
            pcall(skinMod.OnRefresh, skinMod)
        end
    end
end

local function SyncTopRightFrameVisibility()
    local restoredAny = false
    local bf = _G.BuffFrame
    if IsSafeBlizzFrame(bf) and CanToggleBlizzFrameVisibility(bf) then
        if trState.buffFullMuted then
            if bf:IsShown() then trState.buffHiddenByUs = true end
            trState.showBusy = true
            pcall(bf.Hide, bf)
            trState.showBusy = false
        elseif trState.buffHiddenByUs then
            trState.buffHiddenByUs = false
            trState.showBusy = true
            pcall(bf.Show, bf)
            trState.showBusy = false
            restoredAny = true
        end
    end
    local df = _G.DebuffFrame
    if IsSafeBlizzFrame(df) and CanToggleBlizzFrameVisibility(df) then
        if trState.debuffMuted then
            if df:IsShown() then trState.debuffHiddenByUs = true end
            trState.showBusy = true
            pcall(df.Hide, df)
            trState.showBusy = false
        elseif trState.debuffHiddenByUs then
            trState.debuffHiddenByUs = false
            trState.showBusy = true
            pcall(df.Show, df)
            trState.showBusy = false
            restoredAny = true
        end
    end
    if restoredAny then
        NotifyMinimapAuraSkinRefresh()
    end
end

SyncTopRightAuraDedupe = function(repositionMicro)
    local db = mod:GetDB()
    local hudOn = mod._active == true and db.showCoreHUD ~= false
    local wingOwn = db.wingOwnAuras ~= false
    -- 只有「双翼显示自身增益/减益」总开关打开且对应排启用时，才收起右上角原生栏；
    -- 关闭总开关时自动完整还原小地图左侧 BuffFrame / DebuffFrame 并通知增益栏美化刷新圆角。
    local wingShowsBuffs = wingOwn and (db.showCombatBuffs ~= false or db.showPermanentBuffs ~= false)
    local wingShowsDebuffs = wingOwn and (db.showCombatDebuffs ~= false)
    local hideTopRight = hudOn and wingOwn and (db.hideTopRightBlizzAuras ~= false)
    local wantFullHideOptionA = hideTopRight and (not trState.tempExpanded) and wingShowsBuffs
    local wantDebuffFullHide = hideTopRight and (not trState.tempExpanded) and wingShowsDebuffs
    local dedupeOn = hudOn and wingOwn and (not trState.tempExpanded) and (db.dedupeTopRightAuras ~= false)
    local wantBuffDedupe = dedupeOn and (not wantFullHideOptionA) and wingShowsBuffs
    local wantDebuffDedupe = wantDebuffFullHide or (dedupeOn and wingShowsDebuffs)

    local bf = _G.BuffFrame
    if IsSafeBlizzFrame(bf) then
        if not trState.buffFullGuarded and bf.SetAlpha then
            trState.buffFullGuarded = true
            _G.hooksecurefunc(bf, "SetAlpha", function(self, a)
                if not trState.alphaBusy and trState.buffFullMuted and F.PlainNumber(a, 1) ~= 0 then
                    trState.alphaBusy = true
                    pcall(self.SetAlpha, self, 0)
                    trState.alphaBusy = false
                end
            end)
        end
        if not trState.buffShowGuarded and bf.Show then
            trState.buffShowGuarded = true
            _G.hooksecurefunc(bf, "Show", function(self)
                if not trState.showBusy and trState.buffFullMuted and CanToggleBlizzFrameVisibility(self) then
                    trState.showBusy = true
                    pcall(self.Hide, self)
                    trState.showBusy = false
                end
            end)
        end

        if wantFullHideOptionA then
            -- 方案 A：彻底收起右上角暴雪原生 BuffFrame（Hide + Show 钩子 + SetAlpha(0) 双保险，
            -- 解决 12.1 仅靠 SetAlpha(0) 时 BuffFrame/折叠箭头仍露出的问题，停用或点 B 瞬间复原）
            trState.buffFullMuted = true
            trState.alphaBusy = true
            pcall(bf.SetAlpha, bf, 0)
            if bf.CollapseAndExpandButton and bf.CollapseAndExpandButton.SetAlpha then
                pcall(bf.CollapseAndExpandButton.SetAlpha, bf.CollapseAndExpandButton, 0)
            end
            trState.alphaBusy = false
            for _, btn in ipairs(dedupedAuraBtnList) do
                SetAuraBtnMuted(btn, false)
            end
        else
            if trState.buffFullMuted or trState.buffHiddenByUs then
                trState.buffFullMuted = false
                trState.alphaBusy = true
                pcall(bf.SetAlpha, bf, 1)
                if bf.CollapseAndExpandButton and bf.CollapseAndExpandButton.SetAlpha then
                    pcall(bf.CollapseAndExpandButton.SetAlpha, bf.CollapseAndExpandButton, 1)
                end
                trState.alphaBusy = false
            end
            if wantBuffDedupe and not trState.buffDedupeHooked then
                trState.buffDedupeHooked = true
                local reSync = F.Debounce(0.02, function()
                    if mod._active then SyncTopRightAuraDedupe() end
                end)
                if type(bf.UpdateAuras) == "function" then
                    _G.hooksecurefunc(bf, "UpdateAuras", reSync)
                end
                if type(bf.Update) == "function" then
                    _G.hooksecurefunc(bf, "Update", reSync)
                end
            end
            if wantBuffDedupe then
                if type(bf.auraFrames) == "table" then
                    for _, btn in ipairs(bf.auraFrames) do
                        if IsSafeBlizzFrame(btn) then
                            SetAuraBtnMuted(btn, IsBuffBtnShownOnWing(btn))
                        end
                    end
                elseif IsSafeBlizzFrame(bf.AuraContainer) and bf.AuraContainer.GetChildren then
                    for _, btn in ipairs({ bf.AuraContainer:GetChildren() }) do
                        if IsSafeBlizzFrame(btn) and (btn.Icon or btn.icon) then
                            SetAuraBtnMuted(btn, IsBuffBtnShownOnWing(btn))
                        end
                    end
                end
            else
                for _, btn in ipairs(dedupedAuraBtnList) do
                    SetAuraBtnMuted(btn, false)
                end
            end
        end
    end

    local df = _G.DebuffFrame
    if IsSafeBlizzFrame(df) then
        if not trState.debuffGuarded and df.SetAlpha then
            trState.debuffGuarded = true
            _G.hooksecurefunc(df, "SetAlpha", function(self, a)
                if not trState.alphaBusy and trState.debuffMuted and F.PlainNumber(a, 1) ~= 0 then
                    trState.alphaBusy = true
                    pcall(self.SetAlpha, self, 0)
                    trState.alphaBusy = false
                end
            end)
        end
        if not trState.debuffShowGuarded and df.Show then
            trState.debuffShowGuarded = true
            _G.hooksecurefunc(df, "Show", function(self)
                if not trState.showBusy and trState.debuffMuted and CanToggleBlizzFrameVisibility(self) then
                    trState.showBusy = true
                    pcall(self.Hide, self)
                    trState.showBusy = false
                end
            end)
        end
        if wantDebuffDedupe then
            trState.debuffMuted = true
            trState.alphaBusy = true
            pcall(df.SetAlpha, df, 0)
            trState.alphaBusy = false
        elseif trState.debuffMuted or trState.debuffHiddenByUs then
            trState.debuffMuted = false
            trState.alphaBusy = true
            pcall(df.SetAlpha, df, 1)
            trState.alphaBusy = false
        end
    end

    -- 战斗中延迟执行受保护的 BuffFrame/DebuffFrame Show/Hide，确保停用或点 [B] 脱战后必恢复，绝不卡死隐藏
    F.CombatDefer("kkowoUI_CoreHUD_TopRightVis", SyncTopRightFrameVisibility)
    F.CombatDefer("kkowoUI_CoreHUD_TopRightAuraMouse", SyncTopRightAuraMouse)

    -- 右上角极简悬停微开关（方案 A 激活且未关闭微开关时显示；默认 24% 低调隐匿，悬停清晰）
    local showMicro = hideTopRight and (wingShowsBuffs or wingShowsDebuffs) and (db.showTopRightMicroToggle ~= false)
    if showMicro then
        local mb = EnsureTopRightMicroToggle()
        HookMinimapApplyForMicroToggle()
        local wasShown = mb:IsShown()
        if repositionMicro or not wasShown then
            PositionTopRightMicroToggle(mb)
        end
        local over = mb.IsMouseOver and mb:IsMouseOver()
        if trState.tempExpanded then
            mb._bg:SetVertexColor(0.10, 0.24, 0.14, 0.86)
            ST.ApplyRoundedBorder(mb, 5, ST.COLORS.info[1], ST.COLORS.info[2], ST.COLORS.info[3], 0.92, 4)
            mb._label:SetTextColor(0.62, 1.00, 0.72, 1)
            if not over then mb:SetAlpha(0.82) end
        else
            mb._bg:SetVertexColor(0.06, 0.08, 0.11, 0.72)
            ST.ApplyRoundedBorder(mb, 5, 0.38, 0.44, 0.52, 0.55, 4)
            mb._label:SetTextColor(0.84, 0.90, 0.96, 1)
            if not over then mb:SetAlpha(0.24) end
        end
        mb:Show()
    elseif trState.microBtn then
        trState.microBtn:Hide()
    end
end

local function LayoutAuraRowWithOverflow(slots, overflowBadge, list, maxSlots, sz, gap, anchorTarget, anchorPoint, relPoint, yOff, isDebuff, isPerm, trackShown)
    local total = #list
    local hasOverflow = total > maxSlots
    local showSlots = hasOverflow and (maxSlots - 1) or total
    local itemCount = hasOverflow and maxSlots or showSlots
    local totalW = itemCount > 0 and (itemCount * sz + (itemCount - 1) * gap) or 0
    local startX = -totalW * 0.5 + sz * 0.5

    for i = 1, maxSlots do
        local slot = slots[i]
        local data = (i <= showSlots) and list[i] or nil
        if data then
            if trackShown then
                if not F.IsSecret(data.auraInstanceID) and type(data.auraInstanceID) ~= "nil" then
                    wingShownInstanceIDs[data.auraInstanceID] = true
                end
                if data.index then wingShownIndices[data.index] = true end
                if not F.IsSecret(data.icon) and type(data.icon) ~= "nil" then
                    wingShownIcons[data.icon] = true
                end
            end
            slot:ClearAllPoints()
            slot:SetPoint(anchorPoint, anchorTarget, relPoint, startX + (i - 1) * (sz + gap), yOff)
            ApplyAuraSlotData(slot, data, isDebuff, sz, isPerm)
        else
            slot:Hide()
        end
    end

    if overflowBadge then
        if hasOverflow then
            local hiddenList = {}
            for i = showSlots + 1, total do
                local d = list[i]
                hiddenList[#hiddenList + 1] = d
                if trackShown then
                    if not F.IsSecret(d.auraInstanceID) and type(d.auraInstanceID) ~= "nil" then
                        wingShownInstanceIDs[d.auraInstanceID] = true
                    end
                    if d.index then wingShownIndices[d.index] = true end
                    if not F.IsSecret(d.icon) and type(d.icon) ~= "nil" then
                        wingShownIcons[d.icon] = true
                    end
                end
            end
            overflowBadge._hiddenList = hiddenList
            overflowBadge._isDebuff = isDebuff
            overflowBadge._isPerm = isPerm
            overflowBadge:SetSize(sz, sz)
            overflowBadge:ClearAllPoints()
            overflowBadge:SetPoint(anchorPoint, anchorTarget, relPoint, startX + showSlots * (sz + gap), yOff)
            overflowBadge._text:SetFormattedText("+%d", #hiddenList)
            local rad = math_min(ST.GetCornerRadius(5), isPerm and 5 or 6)
            if overflowBadge._lastRad ~= rad then
                overflowBadge._lastRad = rad
                ST.ClearRoundedMask(overflowBadge)
                if rad > 0 then ST.MaskTexture(overflowBadge, overflowBadge._bg, rad) end
            end
            local obr, obg, obb, oba
            if isDebuff then
                obr, obg, obb, oba = 0.94, 0.30, 0.34, 0.92
            else
                local _, _, _, r2, g2, b2 = ST.GetClassGradient()
                obr, obg, obb, oba = r2 * 0.65 + 0.14, g2 * 0.65 + 0.14, b2 * 0.65 + 0.14, 0.88
            end
            if rad > 0 then
                if overflowBadge._fuiBg then overflowBadge._fuiBg:Hide() end
                if overflowBadge._fuiBorders then
                    for _, ln in ipairs(overflowBadge._fuiBorders) do ln:Hide() end
                end
                ST.ApplyRoundedBorder(overflowBadge, rad, obr, obg, obb, oba, 5)
            else
                ST.ApplyRoundedBorder(overflowBadge, 0)
                F.Theme.StylePanel(overflowBadge, 0, oba)
                if overflowBadge._fuiBorders then
                    for _, ln in ipairs(overflowBadge._fuiBorders) do
                        ln:SetColorTexture(obr, obg, obb, oba)
                        ln:Show()
                    end
                end
            end
            overflowBadge:Show()
        else
            overflowBadge._hiddenList = nil
            overflowBadge:Hide()
        end
    end
    return itemCount
end

local function UpdateCombatAuras()
    if not (CH.coreFrame and CH.coreFrame._buffSlots and CH.coreFrame._debuffSlots) then return end
    local db = mod:GetDB()
    local sz = math_max(20, math_min(34, F.PlainNumber(db.auraIconSize, 26) or 26))
    local permSz = sz
    local gap = 5
    local permGap = gap
    local anchorTarget = CH.coreFrame._orb or CH.coreFrame

    for k in pairs(wingShownInstanceIDs) do wingShownInstanceIDs[k] = nil end
    for k in pairs(wingShownIndices) do wingShownIndices[k] = nil end
    for k in pairs(wingShownIcons) do wingShownIcons[k] = nil end

    local activeHUD = mod._active == true and db.showCoreHUD ~= false
    local wingOwn = activeHUD and db.wingOwnAuras ~= false
    local permBuffs, timedBuffs = {}, {}
    if wingOwn and (db.showPermanentBuffs ~= false or db.showCombatBuffs ~= false) then
        permBuffs, timedBuffs = CollectSplitBuffs(db.buffFilter or "non_permanent")
    end

    -- 顶冠排（中央能量球正上方 +6px，距上方挥砍条留足 15px 空间零遮挡）：常驻 BUFF（守护/姿态/光环/追踪）
    if CH.coreFrame._permSlots then
        local showPerm = wingOwn and db.showPermanentBuffs ~= false
        LayoutAuraRowWithOverflow(
            CH.coreFrame._permSlots, CH.coreFrame._permOverflow,
            showPerm and permBuffs or {}, MAX_PERM_SLOTS,
            permSz, permGap, anchorTarget, "BOTTOM", "TOP", 6,
            false, true, true
        )
    end

    -- 下方第一排（紧贴中央能量球正下方）：限时增益 Buff 动态水平居中平衡（超 8 个自动 +N 折叠）
    local nBuffShown = LayoutAuraRowWithOverflow(
        CH.coreFrame._buffSlots, CH.coreFrame._buffOverflow,
        (wingOwn and db.showCombatBuffs ~= false) and timedBuffs or {}, MAX_AURA_SLOTS,
        sz, gap, anchorTarget, "TOP", "BOTTOM", -8,
        false, false, true
    )

    -- 下方第二排（有增益时在增益排正下方，无增益时自动上提至能量球正下方）：自身 Debuff 动态居中 + +N 折叠
    local debuffs = (wingOwn and db.showCombatDebuffs ~= false) and CollectUnitDebuffs() or {}
    hasActiveDebuffs = (#debuffs > 0)
    local debuffY = (nBuffShown > 0) and -(8 + sz + 9) or -8
    LayoutAuraRowWithOverflow(
        CH.coreFrame._debuffSlots, CH.coreFrame._debuffOverflow,
        debuffs, MAX_AURA_SLOTS,
        sz, gap, anchorTarget, "TOP", "BOTTOM", debuffY,
        true, false, false
    )

    SyncTopRightAuraDedupe()
    UpdateIdleFade(false)
end

-- 挥砍计时独立轻量驱动（仅在平砍/自动射击计时中激活，停止立刻 Hide）
CH.swingTicker = CreateFrame("Frame")
CH.swingTicker:Hide()

local function SyncUpperSwingVisual()
    if not (CH.coreFrame and CH.coreFrame._swingWing) then return end
    local sw = CH.coreFrame._swingWing
    local now = GetTime()
    local kind = swingState.activeKind
    local s, e, d
    if kind == "ranged" and swingState.rEnd > now then
        s, e, d = swingState.rStart, swingState.rEnd, swingState.rDur
    elseif swingState.mhEnd > now then
        s, e, d = swingState.mhStart, swingState.mhEnd, swingState.mhDur
        kind = "mh"
    elseif swingState.rEnd > now then
        s, e, d = swingState.rStart, swingState.rEnd, swingState.rDur
        kind = "ranged"
    else
        s = nil
    end

    local ohActive = swingState.ohEnd > now and swingState.ohDur > 0
    if not s and not ohActive then
        sw._bar:SetValue(0)
        if sw._spark then sw._spark:SetShown(false) end
        if sw._aimZone then sw._aimZone:Hide() end
        if not (_G.InCombatLockdown and _G.InCombatLockdown()) and not swingState.autoRepeat then
            sw:SetAlpha(0.30)
        end
        if CH.coreFrame._ohWing and CH.coreFrame._ohWing._isOHMode then
            CH.coreFrame._ohWing._bar:SetValue(0)
        end
        CH.swingTicker:Hide()
        return
    end

    sw:SetAlpha(1.0)
    if s and d and d > 0.01 then
        local prog = math_max(0, math_min(1, (now - s) / d))
        local rem = e - now
        sw._bar:SetMinMaxValues(0, 1)
        sw._bar:SetValue(prog)

        -- 猎人/法杖远程自动射击防卡平射染色区间（仅在状态切换时刷新渐变，减少每帧调用）
        if kind == "ranged" and AIM_CLASSES[F.GetPlayerClass()] then
            if sw._aimZone then
                local aimFrac = math_min(0.65, AIM_TIME / d)
                local w = F.PlainNumber(sw:GetWidth(), 120) or 120
                sw._aimZone:SetWidth(math_max(4, w * aimFrac))
                sw._aimZone:Show()
            end
            local cKey
            if rem <= AIM_TIME then
                cKey = swingState.moving and "clip" or "still"
            else
                cKey = "go"
            end
            if sw._lastColorKey ~= cKey then
                sw._lastColorKey = cKey
                local c = (cKey == "clip") and ST.COLORS.aimClip
                    or (cKey == "still" and ST.COLORS.aimStill or ST.COLORS.aimGo)
                local mul = (cKey == "go") and 0.72 or 0.80
                ST.ApplyBarGradient(sw._bar, c[1] * mul, c[2] * mul, c[3] * mul, c[1], c[2], c[3], 0.96, false)
            end
        else
            if sw._aimZone then sw._aimZone:Hide() end
            if sw._lastColorKey ~= "class" then
                sw._lastColorKey = "class"
                local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
                ST.ApplyBarGradient(sw._bar, r1 * 0.85, g1 * 0.85, b1 * 0.85, r2, g2, b2, 0.96, false)
            end
        end

        if sw._spark then
            sw._spark:SetShown(prog > 0.02 and prog < 0.99)
            if rem <= 0.25 then
                sw._spark:SetIntensity(1.0, 1.35)
            else
                sw._spark:SetIntensity(0.75, 0.95)
            end
        end
    end

    if ohActive and CH.coreFrame._ohWing and CH.coreFrame._ohWing._isOHMode then
        local ohProg = math_max(0, math_min(1, (now - swingState.ohStart) / swingState.ohDur))
        CH.coreFrame._ohWing._bar:SetMinMaxValues(0, 1)
        CH.coreFrame._ohWing._bar:SetValue(ohProg)
    end
end

CH.swingTicker:SetScript("OnUpdate", function()
    if not mod._active then
        CH.swingTicker:Hide()
        return
    end
    SyncUpperSwingVisual()
end)

local function UpdateUpperRightClassPower()
    if not (CH.coreFrame and CH.coreFrame._classPips) then return end
    local db = mod:GetDB()
    local show = db.showUpperClassPower ~= false
    local cls = F.GetPlayerClass()
    local isCatDruid = (cls == "DRUID") and (_G.GetShapeshiftFormID and F.PlainNumber(_G.GetShapeshiftFormID(), 0) == 1)
    local hasCombo = (cls == "ROGUE" or isCatDruid)
    local maxPips = 0
    local curPips = 0

    if hasCombo then
        local pt = (_G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.ComboPoints) or 4
        maxPips = (_G.UnitPowerMax and F.PlainNumber(_G.UnitPowerMax("player", pt), 5)) or 5
        if maxPips <= 0 then maxPips = 5 end
        if _G.GetComboPoints then
            -- 经典/无限服连击点绑定在当前目标上，优先走 GetComboPoints("player", "target")
            curPips = F.PlainNumber(_G.GetComboPoints("player", "target"), 0) or 0
        elseif _G.UnitPower then
            curPips = F.PlainNumber(_G.UnitPower("player", pt), 0) or 0
        end
    end

    local pipsHolder = CH.coreFrame._classPips
    local ohWing = CH.coreFrame._ohWing
    if show and maxPips > 0 and maxPips <= 7 then
        pipsHolder:Show()
        if ohWing then ohWing:Hide(); ohWing._isOHMode = false end
        if CH.coreFrame._rightTopGroove then CH.coreFrame._rightTopGroove:Hide() end
        local totalW = F.PlainNumber(pipsHolder:GetWidth(), 120) or 120
        local gap = 3
        local pipW = math_max(8, (totalW - gap * (maxPips - 1)) / maxPips)
        local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
        for i = 1, 7 do
            local p = pipsHolder._pips[i]
            if i <= maxPips then
                p:ClearAllPoints()
                p:SetSize(pipW, 5)
                p:SetPoint("LEFT", pipsHolder, "LEFT", (i - 1) * (pipW + gap), 0)
                if i <= curPips then
                    ST.ApplyGradient(p._fill, "HORIZONTAL", r1, g1, b1, 0.98, r2, g2, b2, 0.98)
                    p._fill:Show()
                else
                    p._fill:Hide()
                end
                p:Show()
            else
                p:Hide()
            end
        end
    else
        pipsHolder:Hide()
        -- 非连击点职业：双持副手有挥砍速度时自动切换为副手极细挥砍条，否则展示对称暗色空槽
        -- 注意：`A and f()` 只会保留 f 的第一个返回值，副手速度必须单独多值赋值
        local ohSpeed = nil
        if _G.UnitAttackSpeed then
            local _, oh = _G.UnitAttackSpeed("player")
            ohSpeed = F.PlainNumber(oh, nil)
        end
        if show and ohWing and ohSpeed and ohSpeed > 0.1 then
            ohWing._isOHMode = true
            ohWing:Show()
            if CH.coreFrame._rightTopGroove then CH.coreFrame._rightTopGroove:Hide() end
        else
            if ohWing then
                ohWing._isOHMode = false
                ohWing:Hide()
            end
            if CH.coreFrame._rightTopGroove then
                CH.coreFrame._rightTopGroove:SetShown(db.showUpperSwing ~= false)
            end
        end
    end
end

local function BuildCoreHUD()
    if CH.coreFrame then return end
    local db = mod:GetDB()
    local wingW = F.PlainNumber(db.wingWidth, 136) or 136
    local barH = F.PlainNumber(db.barHeight, 16) or 16
    local orbSz = F.PlainNumber(db.orbSize, 44) or 44
    local orbHalfGap = math_floor(orbSz * 0.34)
    local totalW = wingW * 2 + orbHalfGap * 2
    local totalH = math_max(orbSz + 6, barH + 34)

    local f = CreateFrame("Frame", "kkowoUI_CoreHUD", _G.UIParent)
    f:SetSize(totalW, totalH)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(12)
    f:EnableMouse(false)

    -- 1) 左翼反向血条（严格对称，且上方挥砍条与数字完整落在框体包围盒内）
    local hpWing = CreateWingBar(f, wingW, barH, true)
    hpWing:SetPoint("RIGHT", f, "CENTER", -orbHalfGap, -6)
    hpWing._trail = M.AttachHealthTrail(hpWing._bar, {
        delay = db.trailDelay or 0.16,
        reverse = true,
        color = ST.COLORS.trail,
    })
    hpWing._spark = M.AttachEdgeSpark(hpWing._bar, {
        reverse = true, width = 10, extraHeight = 2, a = 0.55,
    })
    hpWing._spark:SetShown(false)
    f._hpWing = hpWing

    -- 2) 右翼正向主资源条
    local ppWing = CreateWingBar(f, wingW, barH, false)
    ppWing:SetPoint("LEFT", f, "CENTER", orbHalfGap, -6)
    ppWing._trail = M.AttachHealthTrail(ppWing._bar, {
        delay = 0.18,
        reverse = false,
        color = { 0.14, 0.24, 0.42, 0.75 },
    })
    ppWing._spark = M.AttachEdgeSpark(ppWing._bar, {
        reverse = false, width = 10, extraHeight = 2, a = 0.48,
    })
    ppWing._spark:SetShown(false)
    f._ppWing = ppWing

    -- 3) 上方左翼极细挥砍/自动射击条（初始值 0，静默暗槽不抢眼）
    local swingWing = CreateWingBar(f, wingW - 4, 5, false)
    swingWing:SetPoint("BOTTOMRIGHT", hpWing, "TOPRIGHT", 0, 2)
    swingWing._bar:SetValue(0)
    swingWing:SetAlpha(0.35)
    local aimZone = swingWing._bar:CreateTexture(nil, "ARTWORK", nil, 2)
    aimZone:SetPoint("TOPRIGHT", swingWing._bar, "TOPRIGHT", 0, 0)
    aimZone:SetPoint("BOTTOMRIGHT", swingWing._bar, "BOTTOMRIGHT", 0, 0)
    aimZone:SetColorTexture(1, 0.82, 0.25, 0.30)
    aimZone:Hide()
    swingWing._aimZone = aimZone
    swingWing._spark = M.AttachEdgeSpark(swingWing._bar, {
        reverse = false, width = 10, extraHeight = 3, a = 0.85,
    })
    swingWing._spark:SetShown(false)
    f._swingWing = swingWing

    -- 4) 上方右翼副资源分格 / 副手挥砍条 / 对称暗色空槽
    local rightGroove = CreateWingBar(f, wingW - 4, 5, false)
    rightGroove:SetPoint("BOTTOMLEFT", ppWing, "TOPLEFT", 0, 2)
    rightGroove._bar:SetValue(0)
    rightGroove:SetAlpha(0.35)
    f._rightTopGroove = rightGroove

    local pipsHolder = CreateFrame("Frame", nil, f)
    pipsHolder:SetSize(wingW - 4, 5)
    pipsHolder:SetPoint("BOTTOMLEFT", ppWing, "TOPLEFT", 0, 2)
    pipsHolder._pips = {}
    for i = 1, 7 do
        local p = CreateFrame("Frame", nil, pipsHolder)
        p:SetSize(20, 5)
        local bg = p:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.04, 0.045, 0.06, 0.90)
        local fill = p:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", p, "TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -1, 1)
        fill:SetTexture(ST.TEX.FLAT)
        fill:Hide()
        p._fill = fill
        p:Hide()
        pipsHolder._pips[i] = p
    end
    f._classPips = pipsHolder

    local ohWing = CreateWingBar(f, wingW - 4, 5, false)
    ohWing:SetPoint("BOTTOMLEFT", ppWing, "TOPLEFT", 0, 2)
    ohWing._bar:SetValue(0)
    ohWing:Hide()
    f._ohWing = ohWing

    -- 5) 独立高层级文字承载层（高于血蓝条填充与圆角描边、低于中央球体，支持内嵌条内与条外上方无缝切换）
    local textLayer = CreateFrame("Frame", nil, f)
    textLayer:SetAllPoints(f)
    textLayer:SetFrameLevel(f:GetFrameLevel() + 9)
    textLayer:EnableMouse(false)
    f._textLayer = textLayer

    local hpText = textLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(hpText, 11, 0.98, 0.99, 1.00, 1)
    hpText:SetShadowOffset(1, -1)
    hpText:SetPoint("RIGHT", hpWing, "RIGHT", -15, 0)
    hpText:SetJustifyH("RIGHT")
    hpText:SetWordWrap(false)
    f._hpText = hpText

    local ppText = textLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(ppText, 11, 0.96, 0.98, 1.00, 1)
    ppText:SetShadowOffset(1, -1)
    ppText:SetPoint("LEFT", ppWing, "LEFT", 15, 0)
    ppText:SetJustifyH("LEFT")
    ppText:SetWordWrap(false)
    f._ppText = ppText

    -- 6) 中央炫光动态能量球（柔和背光晕 + 双层反向流光环 + 双层图标丝滑交叉溶解 + C端弧形计时）
    local orb = CreateFrame("Frame", nil, f)
    orb:SetSize(orbSz, orbSz)
    orb:SetPoint("CENTER", f, "CENTER", 0, -3)
    orb:SetFrameLevel(f:GetFrameLevel() + 10)
    orb:EnableMouse(false)

    -- 球体背后柔和职业色呼吸光晕
    local orbHalo = orb:CreateTexture(nil, "BACKGROUND", nil, -5)
    orbHalo:SetSize(orbSz * 1.95, orbSz * 1.95)
    orbHalo:SetPoint("CENTER", orb, "CENTER", 0, 0)
    orbHalo:SetTexture(ST.TEX.SOFT_GLOW)
    orbHalo:SetBlendMode("ADD")
    orbHalo:SetAlpha(0.26)
    orb._halo = orbHalo
    orb._haloAG = M.EnsurePulseAlpha(orbHalo, 0.18, 0.36, 2.2)

    local orbBg = orb:CreateTexture(nil, "BACKGROUND", nil, -2)
    orbBg:SetAllPoints()
    orbBg:SetTexture(ST.TEX.CIRCLE_MASK)
    orbBg:SetVertexColor(0.04, 0.045, 0.065, 0.96)

    local orbMask = orb:CreateMaskTexture()
    if orbMask.SetBlockingLoadsRequested then pcall(orbMask.SetBlockingLoadsRequested, orbMask, true) end
    orbMask:SetPoint("TOPLEFT", orb, "TOPLEFT", 4, -4)
    orbMask:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", -4, 4)
    orbMask:SetTexture(ST.TEX.CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")

    -- 底层前序图标缓存（切换技能或施法结束回默认图标时丝滑淡出溶解，绝不生硬跳切）
    local orbIconPrev = orb:CreateTexture(nil, "ARTWORK", nil, 0)
    orbIconPrev:SetPoint("TOPLEFT", orb, "TOPLEFT", 4, -4)
    orbIconPrev:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", -4, 4)
    ST.AttachCustomMask(orb, orbIconPrev, orbMask, { isIcon = true, keepIfLoaded = true })
    orbIconPrev:Hide()
    orb._iconPrev = orbIconPrev

    local orbIcon = orb:CreateTexture(nil, "ARTWORK", nil, 1)
    orbIcon:SetPoint("TOPLEFT", orb, "TOPLEFT", 4, -4)
    orbIcon:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", -4, 4)
    ST.AttachCustomMask(orb, orbIcon, orbMask, { isIcon = true, keepIfLoaded = true })
    orb._icon = orbIcon

    -- 切换技能瞬间内核高光闪耀层
    local orbFlash = orb:CreateTexture(nil, "OVERLAY", nil, 2)
    orbFlash:SetPoint("TOPLEFT", orb, "TOPLEFT", 3, -3)
    orbFlash:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", -3, 3)
    orbFlash:SetTexture(ST.TEX.CIRCLE_MASK)
    orbFlash:SetBlendMode("ADD")
    orbFlash:SetVertexColor(1, 1, 1, 0.72)
    orbFlash:Hide()
    orb._flash = orbFlash

    -- 外围 C 端弧形计时条（原生 Cooldown Frame 零 OnUpdate 驱动）
    local cd = CreateFrame("Cooldown", nil, orb, "CooldownFrameTemplate")
    cd:SetPoint("TOPLEFT", orb, "TOPLEFT", -2, 2)
    cd:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", 2, -2)
    cd:SetFrameLevel(orb:GetFrameLevel() + 2)
    if cd.SetSwipeTexture then pcall(cd.SetSwipeTexture, cd, ST.TEX.CIRCLE_RING) end
    if cd.SetDrawEdge then pcall(cd.SetDrawEdge, cd, false) end
    if cd.SetDrawBling then pcall(cd.SetDrawBling, cd, false) end
    if cd.SetHideCountdownNumbers then pcall(cd.SetHideCountdownNumbers, cd, true) end
    if cd.SetReverse then pcall(cd.SetReverse, cd, true) end
    cd:Hide()
    orb._cd = cd

    -- 主外圈顺时针旋转发光弧
    local spinArc = orb:CreateTexture(nil, "OVERLAY", nil, 4)
    spinArc:SetPoint("TOPLEFT", orb, "TOPLEFT", -5, 5)
    spinArc:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", 5, -5)
    spinArc:SetTexture(ST.TEX.CIRCLE_ARC)
    spinArc:SetBlendMode("ADD")
    orb._spinArc = spinArc
    orb._spinAG = M.EnsureSpinRing(spinArc, 2.4, false)

    -- 副外圈逆时针流光弧（双层反向能量环）
    local spinArc2 = orb:CreateTexture(nil, "OVERLAY", nil, 3)
    spinArc2:SetPoint("TOPLEFT", orb, "TOPLEFT", -7, 7)
    spinArc2:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", 7, -7)
    spinArc2:SetTexture(ST.TEX.CIRCLE_ARC)
    spinArc2:SetBlendMode("ADD")
    orb._spinArc2 = spinArc2
    orb._spinAG2 = M.EnsureSpinRing(spinArc2, 4.6, true)

    -- 切技能外扩光波环（零硬跳淡出）
    local burstRing = orb:CreateTexture(nil, "OVERLAY", nil, 6)
    burstRing:SetPoint("TOPLEFT", orb, "TOPLEFT", -2, 2)
    burstRing:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", 2, -2)
    burstRing:SetTexture(ST.TEX.CIRCLE_ARC)
    burstRing:SetBlendMode("ADD")
    burstRing:Hide()
    orb._burstRing = burstRing

    local orbRing = orb:CreateTexture(nil, "OVERLAY", nil, 5)
    orbRing:SetAllPoints()
    orbRing:SetTexture(ST.TEX.CIRCLE_RING)
    orbRing:SetVertexColor(0.10, 0.12, 0.16, 0.96)
    orb._ring = orbRing

    -- 右上角小交叉双剑战斗标识
    -- 战斗徽章：与技能球同风格的小圆章（暗底 + 战斗红细环 + 柔光呼吸 + 居中小剑），进战弹入、脱战淡出
    local badge = CreateFrame("Frame", nil, orb)
    badge:SetSize(16, 16)
    badge:SetPoint("CENTER", orb, "TOPRIGHT", -3, -3)
    badge:SetFrameLevel(orb:GetFrameLevel() + 12)
    badge:EnableMouse(false)
    local cIn = ST.COLORS.combatIn
    local bGlow = badge:CreateTexture(nil, "BACKGROUND", nil, -4)
    bGlow:SetSize(34, 34)
    bGlow:SetPoint("CENTER", badge, "CENTER", 0, 0)
    bGlow:SetTexture(ST.TEX.SOFT_GLOW)
    bGlow:SetBlendMode("ADD")
    bGlow:SetVertexColor(cIn[1], cIn[2], cIn[3], 1)
    badge._glowAG = M.EnsurePulseAlpha(bGlow, 0.18, 0.55, 1.6)
    local bDisc = badge:CreateTexture(nil, "ARTWORK", nil, 1)
    bDisc:SetAllPoints(badge)
    bDisc:SetTexture(ST.TEX.CIRCLE_MASK)
    bDisc:SetVertexColor(0.07, 0.05, 0.06, 0.96)
    local bRing = badge:CreateTexture(nil, "ARTWORK", nil, 2)
    bRing:SetAllPoints(badge)
    bRing:SetTexture(ST.TEX.CIRCLE_RING)
    bRing:SetVertexColor(cIn[1], cIn[2], cIn[3], 0.95)
    local bIcon = badge:CreateTexture(nil, "OVERLAY", nil, 3)
    bIcon:SetSize(9, 9)
    bIcon:SetPoint("CENTER", badge, "CENTER", 0, 0)
    bIcon:SetTexture(F.MEDIA .. "CombatAlert\\Sword.tga")
    bIcon:SetVertexColor(1.00, 0.90, 0.86, 1)
    badge:Hide()
    orb._combatIcon = badge
    f._orb = orb

    -- 7) 方案 A：圆球正上方常驻 BUFF 池 + 正下方增益 / 减益双行池（均含 +N 溢出折叠与脱战右键取消 Buff）
    local function CreateAuraSlot(isDebuff)
        local slot = CreateFrame("Frame", nil, f)
        slot:SetSize(24, 24)
        slot:SetFrameLevel(f:GetFrameLevel() + 6)
        slot:EnableMouse(true)

        local sBg = slot:CreateTexture(nil, "BACKGROUND", nil, -2)
        sBg:SetAllPoints()
        sBg:SetColorTexture(0.03, 0.035, 0.05, 0.92)
        slot._bg = sBg

        local sIcon = slot:CreateTexture(nil, "ARTWORK", nil, 1)
        sIcon:SetPoint("TOPLEFT", slot, "TOPLEFT", 1, -1)
        sIcon:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -1, 1)
        sIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        slot._icon = sIcon

        -- 底部柔和暗色渐变托底，让 9px 小倒计时数字既清晰又不遮挡图标主体画面
        local tShade = slot:CreateTexture(nil, "ARTWORK", nil, 3)
        tShade:SetPoint("BOTTOMLEFT", slot, "BOTTOMLEFT", 1, 1)
        tShade:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -1, 1)
        tShade:SetHeight(12)
        tShade:SetTexture(ST.TEX.FLAT)
        ST.ApplyGradient(tShade, "VERTICAL", 0, 0, 0, 0.78, 0, 0, 0, 0.0)
        tShade:Hide()
        slot._timerShade = tShade

        local sCD = CreateFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
        sCD:SetPoint("TOPLEFT", slot, "TOPLEFT", 1, -1)
        sCD:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -1, 1)
        if sCD.SetDrawEdge then pcall(sCD.SetDrawEdge, sCD, false) end
        if sCD.SetDrawBling then pcall(sCD.SetDrawBling, sCD, false) end
        if sCD.SetReverse then pcall(sCD.SetReverse, sCD, true) end
        if sCD.SetSwipeColor then pcall(sCD.SetSwipeColor, sCD, 0, 0, 0, 0.45) end
        if sCD.SetHideCountdownNumbers then pcall(sCD.SetHideCountdownNumbers, sCD, false) end
        sCD:HookScript("OnShow", function(self) StyleCooldownTimerFont(self, slot) end)
        sCD:Hide()
        slot._cd = sCD

        -- 堆叠层数放在冷却层之上的独立子框体右上角，确保不被冷却扇形遮住，且与底部计时分离
        local stHost = CreateFrame("Frame", nil, slot)
        stHost:SetAllPoints(slot)
        stHost:SetFrameLevel(slot:GetFrameLevel() + 7)
        stHost:EnableMouse(false)
        local stFS = stHost:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(stFS, 9, "OUTLINE", 1, 0.92, 0.56, 1)
        stFS:SetPoint("TOPRIGHT", slot, "TOPRIGHT", -1, -1)
        stFS:Hide()
        slot._stacks = stFS

        slot:SetScript("OnEnter", function(self)
            if not _G.GameTooltip then return end
            _G.GameTooltip:SetOwner(self, self._isPerm and "ANCHOR_TOP" or "ANCHOR_BOTTOM", 0, self._isPerm and 4 or -4)
            local shownTip = false
            if not self._fromCache then
                if self._auraInstanceID ~= nil then
                    if self._isDebuff and _G.GameTooltip.SetUnitDebuffByAuraInstanceID then
                        shownTip = pcall(_G.GameTooltip.SetUnitDebuffByAuraInstanceID, _G.GameTooltip, "player", self._auraInstanceID)
                    elseif (not self._isDebuff) and _G.GameTooltip.SetUnitBuffByAuraInstanceID then
                        shownTip = pcall(_G.GameTooltip.SetUnitBuffByAuraInstanceID, _G.GameTooltip, "player", self._auraInstanceID)
                    elseif self._auraIndex and _G.GameTooltip.SetUnitAura then
                        shownTip = pcall(_G.GameTooltip.SetUnitAura, _G.GameTooltip, "player", self._auraIndex, self._isDebuff and "HARMFUL" or "HELPFUL")
                    end
                elseif self._auraIndex and _G.GameTooltip.SetUnitAura then
                    shownTip = pcall(_G.GameTooltip.SetUnitAura, _G.GameTooltip, "player", self._auraIndex, self._isDebuff and "HARMFUL" or "HELPFUL")
                end
            end
            local tipLines = _G.GameTooltip.NumLines and F.PlainNumber(_G.GameTooltip:NumLines(), 0) or 0
            if (not shownTip or tipLines == 0) then
                if self._spellID and _G.GameTooltip.SetSpellByID then
                    pcall(_G.GameTooltip.SetSpellByID, _G.GameTooltip, self._spellID)
                elseif self._auraName then
                    _G.GameTooltip:AddLine(self._auraName, 1, 1, 1)
                end
            end
            if not self._isDebuff and not (InCombatLockdown and InCombatLockdown()) then
                _G.GameTooltip:AddLine("右键点击取消该增益（脱战可用）", 0.52, 0.88, 0.62)
            end
            _G.GameTooltip:Show()
        end)
        slot:SetScript("OnLeave", function()
            if _G.GameTooltip then _G.GameTooltip:Hide() end
        end)
        slot:SetScript("OnMouseUp", function(self, btn)
            if btn ~= "RightButton" or self._isDebuff then return end
            if InCombatLockdown and InCombatLockdown() then return end
            if self._auraIndex and _G.CancelUnitBuff then
                pcall(_G.CancelUnitBuff, "player", self._auraIndex)
            end
        end)
        slot:Hide()
        return slot
    end

    local function CreateOverflowBadge()
        local ov = CreateFrame("Frame", nil, f)
        ov:SetSize(24, 24)
        ov:SetFrameLevel(f:GetFrameLevel() + 6)
        ov:EnableMouse(true)

        local oBg = ov:CreateTexture(nil, "BACKGROUND", nil, -2)
        oBg:SetAllPoints()
        oBg:SetTexture(ST.TEX.FLAT)
        oBg:SetVertexColor(0.06, 0.08, 0.12, 0.84)
        ov._bg = oBg

        local oTxt = ov:CreateFontString(nil, "OVERLAY")
        ST.ApplyText(oTxt, 10, 0.94, 0.97, 1.00, 1)
        oTxt:SetPoint("CENTER", ov, "CENTER", 0, 0)
        ov._text = oTxt

        ov:SetScript("OnEnter", function(self)
            if not (_G.GameTooltip and type(self._hiddenList) == "table" and #self._hiddenList > 0) then return end
            _G.GameTooltip:SetOwner(self, self._isPerm and "ANCHOR_TOP" or "ANCHOR_BOTTOM", 0, self._isPerm and 4 or -4)
            local title = self._isDebuff and "折叠的更多减益" or (self._isPerm and "折叠的更多常驻状态" or "折叠的更多增益")
            _G.GameTooltip:AddLine(string_format("%s（+%d）", title, #self._hiddenList), 0.32, 0.84, 0.42)
            local now = GetTime()
            for _, item in ipairs(self._hiddenList) do
                local nm = item.name or "未知效果"
                local expT = F.PlainNumber(item.expirationTime, nil)
                local remStr = ""
                if expT and expT > now then
                    local rem = math_floor(expT - now + 0.5)
                    if rem >= 3600 then
                        remStr = string_format("  %dh", math_floor(rem / 3600))
                    elseif rem >= 60 then
                        remStr = string_format("  %dm", math_floor(rem / 60))
                    else
                        remStr = string_format("  %ds", rem)
                    end
                end
                _G.GameTooltip:AddLine("• " .. nm .. remStr, 0.92, 0.95, 0.98)
            end
            _G.GameTooltip:Show()
        end)
        ov:SetScript("OnLeave", function()
            if _G.GameTooltip then _G.GameTooltip:Hide() end
        end)
        ov:Hide()
        return ov
    end

    f._permSlots = {}
    for i = 1, MAX_PERM_SLOTS do
        f._permSlots[i] = CreateAuraSlot(false)
    end
    f._permOverflow = CreateOverflowBadge()

    f._buffSlots = {}
    f._debuffSlots = {}
    for i = 1, MAX_AURA_SLOTS do
        f._buffSlots[i] = CreateAuraSlot(false)
        f._debuffSlots[i] = CreateAuraSlot(true)
    end
    f._buffOverflow = CreateOverflowBadge()
    f._debuffOverflow = CreateOverflowBadge()

    F.Mover.Register({
        key = "CoreHUD",
        label = "核心双翼血蓝条",
        frame = f,
        order = 12,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 0,
        defaultY = -238,
        allowShiftDrag = false,
        isHidden = function() return not (mod._active and mod:GetDB().showCoreHUD ~= false) end,
    })
    f:EnableMouse(false)

    CH.coreFrame = f
end


CH.GetBarRadius = GetBarRadius
CH.CreateWingBar = CreateWingBar
CH.ApplyWingStyle = ApplyWingStyle
CH.UpdateOrbAmbientGlow = UpdateOrbAmbientGlow
CH.UpdateOrbAppearance = UpdateOrbAppearance
CH.UpdateIdleFade = UpdateIdleFade
CH.SetOrbTimerArc = SetOrbTimerArc
CH.SetCombatBadge = SetCombatBadge
CH.SyncTopRightAuraDedupe = SyncTopRightAuraDedupe
CH.UpdateCombatAuras = UpdateCombatAuras
CH.SyncUpperSwingVisual = SyncUpperSwingVisual
CH.UpdateUpperRightClassPower = UpdateUpperRightClassPower
CH.BuildCoreHUD = BuildCoreHUD
