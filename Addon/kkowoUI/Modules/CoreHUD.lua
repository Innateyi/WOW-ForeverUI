----------------------------------------------------------------------
--  kkowoUI — Modules/CoreHUD.lua
--  现代圆角渐变核心战斗 HUD 系统（全部独立可选，关闭一键无损还原）：
--    1) 核心双翼状态条（居中镜像布局）：
--       • 左翼反向填充玩家血条（职业色渐变 + 受击延迟残影 + 前沿高光）
--       • 右翼正向填充主资源条（蓝/能量/怒气/集中渐变 + 消耗残影）
--       • 上方左翼极细挥砍/自动射击计时条（无限服原生 PLAYER_SWING + 猎人防卡平射区间）
--       • 上方右翼极细副资源分格条（连击点/圣能/碎片，或双持副手挥砍自适应）
--       • 中央圆形动态技能球（施法/瞬发自动切技能图标 + 0.2s 旋入弹动 + 外围发光旋转环 + C端圆弧计时）
--       • 圆球正下方「守护/姿态/形态」圆角徽章（猎人守护/战士姿态/德鲁伊形态/圣骑光环等）
--    2) 独立宠物圆角框体（血条 + 能量/集中条 + 掉血残影 + 猎人宠物快乐度徽章）
--    3) 可选顶部极简目标框体（圆角渐变目标条 + 掉血残影 + 右侧圆形头像 + 目标的目标小条）
--    4) 原地为 EllesmereUI 玩家/目标单位框体注入受击掉血残影与切换微淡入
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_min, pairs, pcall, select, setmetatable, tostring, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, select, setmetatable, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("coreHUD", {
    title = "核心双翼、宠物与圆角目标整套 HUD",
    desc = "开启即自动接管 EUI 玩家/宠物/目标框并自动去重右上角增益减益；关闭或一键切换即刻 100% 无损恢复 EUI 原版框体与右上角状态栏。",
    group = "motion",
    order = 10,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        showCoreHUD = true,
        showOrb = true,
        showUpperSwing = true,
        showUpperClassPower = true,
        showTrail = true,
        trailDelay = 0.16,
        wingWidth = 136,
        barHeight = 18,
        orbSize = 44,
        scale = 1.0,
        textInsideBars = true,
        -- 默认启用新版即自动隐藏对应 EUI 原生框体（仅在需要同屏对比时可开启保留）
        keepOriginalEUI = false,
        -- 方案 A：圆球正上方常驻 BUFF（守护/姿态/光环）+ 下方两行增益与减益（含 +N 溢出折叠）+ 右上角彻底收起
        showPermanentBuffs = true,
        showCombatBuffs = true,
        showCombatDebuffs = true,
        hideTopRightBlizzAuras = true,
        showTopRightMicroToggle = true,
        dedupeTopRightAuras = true,
        buffFilter = "non_permanent", -- "non_permanent" | "short_2m" | "short_5m" | "all"
        auraIconSize = 26,
        -- 脱战空闲柔和淡隐（默认开启）
        idleFade = true,
        idleAlpha = 0.50,
        v2AuraStripMigrated = false,
        v3UnifiedTargetMigrated = false,
        v4CenteredBoundsMigrated = false,
        v5AutoReplaceMigrated = false,
        v6AuraRefined = false,
        v7OptionAAndInsideText = false,
        -- 独立宠物框体
        showPetFrame = true,
        -- 统一圆角渐变目标条（默认开启）
        enableTopTarget = true,
        -- 原地增强 EUI 单位框体（保留原框体或回退时提供掉血残影与微淡入）
        enhanceEUIFrames = true,
    },
})

local SWING_ENUM = _G.Enum and _G.Enum.PlayerSwingType or nil
local AIM_CLASSES = { HUNTER = true, PRIEST = true, MAGE = true, WARLOCK = true }
local AIM_TIME = 0.50

-- 猎人守护 / 姿态 / 光环等常驻法术 ID（保留在右上角，不进核心圆球与双翼下方增益带）
local ASPECT_SPELLS = {
    [13165] = true, [14318] = true, [14319] = true, [14320] = true, [14321] = true, [14322] = true, [25296] = true, -- 雄鹰
    [13163] = true, -- 灵猴
    [5118]  = true, -- 猎豹
    [13159] = true, -- 豹群
    [13161] = true, -- 野兽
    [20043] = true, [20190] = true, -- 自然
    [34074] = true, -- 蝰蛇
    [61846] = true, -- 龙鹰
}

local DEBUFF_TYPE_COLORS = {
    Magic   = { 0.30, 0.64, 1.00 },
    Curse   = { 0.72, 0.40, 1.00 },
    Poison  = { 0.24, 0.88, 0.44 },
    Disease = { 0.80, 0.56, 0.26 },
}

local function IsPermanentOrAspectSpell(spellID, spellName)
    if spellID and ASPECT_SPELLS[spellID] then return true end
    if type(spellName) == "string" and spellName ~= "" then
        if spellName:find("守护", 1, true)
            or spellName:find("姿态", 1, true)
            or spellName:find("光环", 1, true)
            or spellName:find("形态", 1, true)
            or spellName:find("追踪", 1, true)
            or spellName:find("炉石", 1, true)
            or spellName:find("Aspect of", 1, true)
            or spellName:find("Stance", 1, true)
            or spellName:find("Track ", 1, true) then
            return true
        end
    end
    return false
end

local function GetSpellNameSafe(spellID)
    if not spellID or F.IsSecret(spellID) then return nil end
    if _G.C_Spell and _G.C_Spell.GetSpellName then
        local ok, nm = pcall(_G.C_Spell.GetSpellName, spellID)
        if ok then return F.PlainString(nm, nil) end
    elseif _G.GetSpellInfo then
        local ok, nm = pcall(_G.GetSpellInfo, spellID)
        if ok then return F.PlainString(nm, nil) end
    end
    return nil
end

----------------------------------------------------------------------
--  辅助函数（12.x 保密值安全）
----------------------------------------------------------------------
local function GetSpellCastTimeSafe(spellID)
    if not spellID or F.IsSecret(spellID) then return 0 end
    if _G.C_Spell and _G.C_Spell.GetSpellInfo then
        local ok, info = pcall(_G.C_Spell.GetSpellInfo, spellID)
        if ok and type(info) == "table" then
            return F.PlainNumber(info.castTime, 0) or 0
        end
    elseif _G.GetSpellInfo then
        local ok, _, _, _, castTime = pcall(_G.GetSpellInfo, spellID)
        if ok then
            return F.PlainNumber(castTime, 0) or 0
        end
    end
    return 0
end

local function GetSpellIconSafe(spellID)
    if not spellID or F.IsSecret(spellID) then return nil end
    if _G.C_Spell and _G.C_Spell.GetSpellTexture then
        local ok, tex = pcall(_G.C_Spell.GetSpellTexture, spellID)
        if ok and tex and not F.IsSecret(tex) then return tex end
    end
    if _G.GetSpellTexture then
        local ok, tex = pcall(_G.GetSpellTexture, spellID)
        if ok and tex and not F.IsSecret(tex) then return tex end
    end
    return nil
end

local function GetSpellCooldownSafe(spellID)
    if _G.C_Spell and _G.C_Spell.GetSpellCooldown then
        local ok, info = pcall(_G.C_Spell.GetSpellCooldown, spellID)
        if ok and type(info) == "table" then
            local s = F.PlainNumber(info.startTime, nil)
            local d = F.PlainNumber(info.duration, nil)
            if s and d then return s, d end
        end
    end
    if _G.GetSpellCooldown then
        local ok, s, d = pcall(_G.GetSpellCooldown, spellID)
        if ok then
            s = F.PlainNumber(s, nil)
            d = F.PlainNumber(d, nil)
            if s and d then return s, d end
        end
    end
    return 0, 0
end

local SCALE_TO_100 = _G.CurveConstants and _G.CurveConstants.ScaleTo100 or nil

local function AbbreviateSafe(val)
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.AbbreviateValue) == "function" then
        local ok, s = pcall(EUI.AbbreviateValue, val, "health")
        if ok and s ~= nil then return s end
    end
    if _G.AbbreviateNumbers then
        local ok, s = pcall(_G.AbbreviateNumbers, val)
        if ok and s ~= nil then return s end
    end
    return val
end

local function SetHealthText(fs, unit, compact)
    if not fs then return end
    if not (_G.UnitExists and _G.UnitExists(unit)) then
        fs:SetText("")
        return
    end
    if _G.UnitIsDead and _G.UnitIsDead(unit) then
        fs:SetText(compact and "0%" or "0% - 死亡")
        return
    end
    local hp = _G.UnitHealth and _G.UnitHealth(unit)
    local mx = _G.UnitHealthMax and _G.UnitHealthMax(unit)
    local pHp = F.PlainNumber(hp, nil)
    local pMx = F.PlainNumber(mx, nil)
    if pHp and pMx and pMx > 0 then
        local pct = math_floor(pHp / pMx * 100 + 0.5)
        if compact then
            fs:SetFormattedText("%d%%", pct)
        else
            fs:SetFormattedText("%d%% - %s", pct, F.FormatShortNumber(pHp))
        end
        return
    end
    -- 12.x 保密值 C 端安全通路：直接由 C 端格式化，绝不在 Lua 中对保密值做运算或分支
    if _G.UnitHealthPercent then
        local okP, pct
        if SCALE_TO_100 ~= nil then
            okP, pct = pcall(_G.UnitHealthPercent, unit, true, SCALE_TO_100)
        else
            okP, pct = pcall(_G.UnitHealthPercent, unit)
        end
        if okP and pct ~= nil then
            if compact then
                if pcall(fs.SetFormattedText, fs, "%d%%", pct) then return end
            elseif hp ~= nil then
                local hpStr = AbbreviateSafe(hp)
                if pcall(fs.SetFormattedText, fs, "%d%% - %s", pct, hpStr) then return end
            end
            if pcall(fs.SetFormattedText, fs, "%d%%", pct) then return end
        end
    end
    if hp ~= nil then
        pcall(fs.SetFormattedText, fs, "%s", AbbreviateSafe(hp))
    end
end

local function SetPowerText(fs, unit, powerType)
    if not fs then return end
    if not (_G.UnitExists and _G.UnitExists(unit)) then
        fs:SetText("")
        return
    end
    local cur = _G.UnitPower and _G.UnitPower(unit, powerType)
    local mx = _G.UnitPowerMax and _G.UnitPowerMax(unit, powerType)
    local pCur = F.PlainNumber(cur, nil)
    local pMx = F.PlainNumber(mx, nil)
    if pCur and pMx and pMx > 0 then
        if powerType == 0 then
            fs:SetFormattedText("%d%%", math_floor(pCur / pMx * 100 + 0.5))
        else
            fs:SetFormattedText("%d", math_floor(pCur + 0.5))
        end
        return
    end
    -- 12.x 保密值 C 端安全通路
    if powerType == 0 and _G.UnitPowerPercent then
        local okP, pct
        if SCALE_TO_100 ~= nil then
            okP, pct = pcall(_G.UnitPowerPercent, unit, powerType, true, SCALE_TO_100)
        else
            okP, pct = pcall(_G.UnitPowerPercent, unit, powerType)
        end
        if okP and pct ~= nil and pcall(fs.SetFormattedText, fs, "%d%%", pct) then
            return
        end
    end
    if cur ~= nil then
        pcall(fs.SetFormattedText, fs, "%d", cur)
    end
end

-- 查询当前激活的「守护 / 姿态 / 形态」图标与名字
local function ResolveActiveStance()
    -- 1) 优先查暴雪姿态/形态栏（战士姿态、德鲁伊形态、圣骑光环、盗贼潜行、牧师暗影、部分无限服守护）
    if _G.GetNumShapeshiftForms and _G.GetShapeshiftFormInfo then
        local n = F.PlainNumber(_G.GetNumShapeshiftForms(), 0) or 0
        for i = 1, n do
            local ok, icon, active, _, spellID = pcall(_G.GetShapeshiftFormInfo, i)
            if ok and active and not F.IsSecret(icon) and icon then
                local name = nil
                if spellID and not F.IsSecret(spellID) then
                    if _G.C_Spell and _G.C_Spell.GetSpellName then
                        local okN, nm = pcall(_G.C_Spell.GetSpellName, spellID)
                        if okN then name = F.PlainString(nm, nil) end
                    elseif _G.GetSpellInfo then
                        local okN, nm = pcall(_G.GetSpellInfo, spellID)
                        if okN then name = F.PlainString(nm, nil) end
                    end
                end
                return icon, name, spellID, i
            end
        end
    end

    -- 2) 扫描玩家 Buff 中的猎人守护（兼容不进姿态栏的守护法术）
    if _G.C_UnitAuras and _G.C_UnitAuras.GetBuffDataByIndex then
        for i = 1, 40 do
            local ok, aura = pcall(_G.C_UnitAuras.GetBuffDataByIndex, "player", i)
            if not ok or not aura then break end
            local sid = F.PlainNumber(aura.spellId, nil)
            local nm = F.PlainString(aura.name, nil)
            local ic = (not F.IsSecret(aura.icon)) and aura.icon or nil
            if ic and ((sid and ASPECT_SPELLS[sid]) or (nm and (nm:find("守护", 1, true) or nm:find("Aspect of", 1, true)))) then
                return ic, nm, sid, nil
            end
        end
    elseif _G.UnitBuff then
        for i = 1, 40 do
            local ok, nm, ic, _, _, _, _, _, _, _, sid = pcall(_G.UnitBuff, "player", i)
            if not ok or not nm then break end
            nm = F.PlainString(nm, nil)
            sid = F.PlainNumber(sid, nil)
            if ic and not F.IsSecret(ic) and ((sid and ASPECT_SPELLS[sid]) or (nm and (nm:find("守护", 1, true) or nm:find("Aspect of", 1, true)))) then
                return ic, nm, sid, nil
            end
        end
    end

    return nil, nil, nil, nil
end

local function GetClassCrestIcon()
    local cls = F.GetPlayerClass()
    local classSpellIcons = {
        HUNTER      = 132164, -- 雄鹰/猎人标志
        MAGE        = 135812, -- 冰火法术
        ROGUE       = 132290, -- 匕首
        WARRIOR     = 132355, -- 剑盾
        PRIEST      = 135940, -- 圣光
        WARLOCK     = 136163, -- 暗影
        PALADIN     = 135920, -- 圣盾
        SHAMAN      = 136048, -- 闪电
        DRUID       = 132115, -- 自然
        DEATHKNIGHT = 135771, -- 符文
    }
    return classSpellIcons[cls] or ST.TEX.LOGO_FLAT
end

----------------------------------------------------------------------
--  状态对象与框体引用
----------------------------------------------------------------------
local coreFrame = nil
local petFrame = nil
local topTargetFrame = nil
local petEventFrame = nil

local playerCache = {}
local petCache = {}
local targetCache = {}

-- 挥砍计时运行时（仅挥砍进行中启动 OnUpdate，归零即 Hide，平时 0 CPU）
local swingState = {
    mhStart = 0, mhEnd = 0, mhDur = 0,
    ohStart = 0, ohEnd = 0, ohDur = 0,
    rStart  = 0, rEnd  = 0, rDur  = 0,
    activeKind = nil, -- "ranged" | "mh"
    moving = false,
    autoRepeat = false,
}

-- 中央技能球状态
local orbState = {
    currentIcon = nil,
    castActive = false,
    castIcon = nil,
    castSpellID = nil,
    castGUID = nil,
    lastCastEndTime = 0,
    gcdUntil = 0,
    lastSpellIcon = nil,
    lastSpellUntil = 0,
    stanceIcon = nil,
    stanceName = nil,
    stanceSpellID = nil,
}

-- EUI 原生框体显隐状态与弱表防复原锁（关闭开关 100% 瞬间无损还原）
local hiddenEUI = {
    player = false,
    pet = false,
    target = false,
    targettarget = false,
}
local alphaGuardedEUI = setmetatable({}, { __mode = "k" })
local alphaGuardBusy = false

-- 右上角 BuffFrame / DebuffFrame 方案 A 收起与单图标去重状态（全程弱表零污染，停用即还原）
local wingShownInstanceIDs = {}
local wingShownIndices = {}
local wingShownIcons = {}
local dedupedAuraBtns = setmetatable({}, { __mode = "k" })
local dedupedAuraBtnList = {}
local auraAlphaGuarded = setmetatable({}, { __mode = "k" })
local auraAlphaBusy = false
local buffFrameDedupeHooked = false
local buffFrameFullMuted = false
local buffFrameFullGuarded = false
local debuffFrameMuted = false
local debuffFrameGuarded = false
local topRightTempExpanded = false
local topRightMicroBtn = nil

local euiTrailPlayer = nil
local euiTrailTarget = nil
local euiHooksDone = false

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
    sb:SetStatusBarTexture(ST.TEX.FLAT)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(1)
    if reverse and sb.SetReverseFill then
        sb:SetReverseFill(true)
    end
    sb:EnableMouse(false)
    holder._bar = sb

    local sheen = sb:CreateTexture(nil, "OVERLAY", nil, 2)
    sheen:SetHeight(1)
    sheen:SetPoint("TOPLEFT", sb, "TOPLEFT", 2, -1)
    sheen:SetPoint("TOPRIGHT", sb, "TOPRIGHT", -2, -1)
    sheen:SetColorTexture(1, 1, 1, 0.14)
    holder._sheen = sheen

    holder._reverse = reverse == true
    return holder
end

local function ApplyWingStyle(holder, r1, g1, b1, r2, g2, b2, radius)
    if not holder then return end
    local rad = radius or GetBarRadius(F.PlainNumber(holder:GetHeight(), 16) or 16)
    -- 柔和微透色融玻璃底槽：按当前条色相轻染（蓝条带柔蓝玻璃、绿条带柔绿玻璃，彻底告别生硬死黑块）
    if holder._bg then
        local bgA = (r1 + g1 + b1 < 0.25) and 0.34 or 0.42
        holder._bg:SetVertexColor(r1 * 0.16 + 0.06, g1 * 0.16 + 0.06, b1 * 0.16 + 0.08, bgA)
    end
    ST.ClearRoundedMask(holder)
    if rad > 0 then
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
    end
    ST.ApplyBarGradient(holder._bar, r1, g1, b1, r2, g2, b2, 0.98, holder._reverse)
end

local hasActiveDebuffs = false
local lastIdleAlpha = nil

local function UpdateOrbAmbientGlow()
    if not (coreFrame and coreFrame._orb) then return end
    local orb = coreFrame._orb
    local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
    local inCombat = (_G.InCombatLockdown and _G.InCombatLockdown())
        or (_G.UnitAffectingCombat and _G.UnitAffectingCombat("player"))
    local energized = (inCombat == true) or orbState.castActive or (GetTime() < (orbState.lastSpellUntil or 0))

    if orb._halo then
        orb._halo:SetVertexColor(r2, g2, b2, 1)
        if orb._haloAG and orb._haloAG._al then
            orb._haloAG._al:SetFromAlpha(energized and 0.34 or 0.16)
            orb._haloAG._al:SetToAlpha(energized and 0.66 or 0.32)
            if not orb._haloAG:IsPlaying() then orb._haloAG:Play() end
        end
        orb._halo:Show()
    end
    if orb._spinArc then
        orb._spinArc:SetVertexColor(r2, g2, b2, energized and 0.92 or 0.42)
        orb._spinArc:Show()
        if orb._spinAG then
            orb._spinAG._rot:SetDuration(energized and 2.0 or 3.8)
            if not orb._spinAG:IsPlaying() then orb._spinAG:Play() end
        end
    end
    if orb._spinArc2 then
        orb._spinArc2:SetVertexColor(r1 * 0.5 + 0.5, g1 * 0.5 + 0.5, b1 * 0.5 + 0.5, energized and 0.54 or 0.22)
        orb._spinArc2:Show()
        if orb._spinAG2 then
            orb._spinAG2._rot:SetDuration(energized and 3.6 or 6.2)
            if not orb._spinAG2:IsPlaying() then orb._spinAG2:Play() end
        end
    end
    if orb._burstRing then
        orb._burstRing:SetVertexColor(r2, g2, b2, 1)
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
    if not coreFrame or not coreFrame._orb then return end
    local orb = coreFrame._orb
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
    if not coreFrame or not coreFrame._orb then return end
    local orb = coreFrame._orb
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
    if not coreFrame then return end
    local db = mod:GetDB()
    if not mod._active then return end
    local unlockOn = _G.EllesmereUI and _G.EllesmereUI._unlockActive == true
    local targetA = 1.0
    if db.idleFade ~= false and not unlockOn then
        local inCombat = (_G.InCombatLockdown and _G.InCombatLockdown())
            or (_G.UnitAffectingCombat and _G.UnitAffectingCombat("player"))
        local hasTarget = (_G.UnitExists and _G.UnitExists("target")) == true
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
    if not instant and lastIdleAlpha == targetA then return end
    lastIdleAlpha = targetA
    local dur = instant and 0.01 or ((targetA >= 0.99) and 0.14 or 0.42)
    if coreFrame:IsShown() then
        F.Theme.FadeTo(coreFrame, targetA, dur, false)
    end
    if petFrame and petFrame:IsShown() then
        F.Theme.FadeTo(petFrame, targetA, dur, false)
    end
end

-- 方案 A：圆球正上方常驻 BUFF（守护/姿态/光环/无时长常驻）+ 正下方两行（增益 Buff / 自身减益 Debuff，均带 +N 溢出折叠）
local MAX_PERM_SLOTS = 6
local MAX_AURA_SLOTS = 8

local function CollectSplitBuffs(buffMode)
    local permOut = {}
    local timedOut = {}
    local getByIdx = _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDataByIndex
    if getByIdx then
        for i = 1, 40 do
            local ok, aura = pcall(getByIdx, "player", i, "HELPFUL")
            if not ok or not aura then break end
            if aura.icon ~= nil then
                local sid = F.PlainNumber(aura.spellId, nil)
                local nm = F.PlainString(aura.name, nil)
                local dur = F.PlainNumber(aura.duration, nil)
                local durSecret = F.IsSecret(aura.duration)
                local isPerm = IsPermanentOrAspectSpell(sid, nm) or ((not durSecret) and (not dur or dur <= 0))
                local item = {
                    index = i,
                    name = nm,
                    auraInstanceID = aura.auraInstanceID,
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
        for i = 1, 40 do
            local ok, nm, ic, count, dispelType, dur, expTime, _, _, _, sid = pcall(_G.UnitBuff, "player", i)
            if not ok or not nm then break end
            if ic ~= nil then
                local pSid = F.PlainNumber(sid, nil)
                local pNm = F.PlainString(nm, nil)
                local pDur = F.PlainNumber(dur, nil)
                local durSecret = F.IsSecret(dur)
                local isPerm = IsPermanentOrAspectSpell(pSid, pNm) or ((not durSecret) and (not pDur or pDur <= 0))
                local item = {
                    index = i,
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
    return permOut, timedOut
end

local function CollectUnitDebuffs()
    local out = {}
    local getByIdx = _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDataByIndex
    if getByIdx then
        for i = 1, 40 do
            local ok, aura = pcall(getByIdx, "player", i, "HARMFUL")
            if not ok or not aura then break end
            if aura.icon ~= nil then
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
            if not ok or not nm then break end
            if ic ~= nil then
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

-- 精致化 Cooldown 原生倒计时字体（彻底解决暴雪默认 16px 巨字糊满图标：9px 清爽描边沉底贴边，图标画面 100% 清晰，12.x 保密值安全）
local function StyleCooldownTimerFont(cd, slot)
    if not (cd and cd.GetRegions) then return end
    for _, reg in ipairs({ cd:GetRegions() }) do
        if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" then
            F.Theme.ApplyFont(reg, 9, "OUTLINE", 0.96, 0.98, 1.00, 1)
            reg:ClearAllPoints()
            reg:SetPoint("BOTTOM", slot, "BOTTOM", 0, -2)
            reg:SetJustifyH("CENTER")
            reg:SetShadowOffset(1, -1)
        end
    end
end

local function ApplyAuraSlotData(slot, data, isDebuff, size, isPerm)
    slot:SetSize(size, size)
    slot._auraIndex = data.index
    slot._auraInstanceID = data.auraInstanceID
    slot._isDebuff = isDebuff
    slot._isPerm = isPerm == true
    pcall(slot._icon.SetTexture, slot._icon, data.icon)

    local cd = slot._cd
    local appliedCD = false
    if not isPerm then
        if data.auraInstanceID and _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDuration and cd.SetCooldownFromDurationObject then
            local okD, durObj = pcall(_G.C_UnitAuras.GetAuraDuration, "player", data.auraInstanceID)
            if okD and durObj then
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
    ST.ClearRoundedMask(slot)
    if rad > 0 then
        ST.MaskTexture(slot, slot._bg, rad)
        ST.MaskTexture(slot, slot._icon, rad)
        if slot._timerShade then ST.MaskTexture(slot, slot._timerShade, rad) end
    end
    if isDebuff then
        local dc = (data.dispelName and DEBUFF_TYPE_COLORS[data.dispelName]) or { 0.94, 0.28, 0.32 }
        ST.ApplyRoundedBorder(slot, math_max(rad, 4), dc[1], dc[2], dc[3], 0.96, 5)
    elseif isPerm then
        local r1, g1, b1 = ST.GetClassGradient()
        ST.ApplyRoundedBorder(slot, math_max(rad, 4), r1 * 0.45 + 0.24, g1 * 0.45 + 0.26, b1 * 0.45 + 0.30, 0.86, 5)
    else
        local _, _, _, r2, g2, b2 = ST.GetClassGradient()
        ST.ApplyRoundedBorder(slot, math_max(rad, 4), r2 * 0.72 + 0.10, g2 * 0.72 + 0.10, b2 * 0.72 + 0.10, 0.92, 5)
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
                if not auraAlphaBusy and dedupedAuraBtns[self] and a ~= 0 then
                    auraAlphaBusy = true
                    pcall(self.SetAlpha, self, 0)
                    auraAlphaBusy = false
                end
            end)
        end
    end
    if mute then
        if not dedupedAuraBtns[btn] then
            dedupedAuraBtns[btn] = true
            dedupedAuraBtnList[#dedupedAuraBtnList + 1] = btn
        end
        auraAlphaBusy = true
        pcall(btn.SetAlpha, btn, 0)
        auraAlphaBusy = false
    elseif dedupedAuraBtns[btn] then
        dedupedAuraBtns[btn] = nil
        auraAlphaBusy = true
        pcall(btn.SetAlpha, btn, 1)
        auraAlphaBusy = false
    end
end

local function IsBuffBtnShownOnWing(btn)
    local info = btn.buttonInfo
    if type(info) == "table" then
        local iid = info.auraInstanceID
        if iid ~= nil and not F.IsSecret(iid) and wingShownInstanceIDs[iid] then
            return true
        end
        local idx = F.PlainNumber(info.index, nil)
        if idx and wingShownIndices[idx] then
            return true
        end
        local tex = info.texture
        local expT = F.PlainNumber(info.expirationTime, nil)
        if tex ~= nil and not F.IsSecret(tex) and wingShownIcons[tex] and expT and expT > 0 then
            return true
        end
    end
    -- 回退：仅对带有倒计时文本的限时增益做图标匹配，绝不误伤常驻守护/光环
    local durFS = btn.Duration or btn.duration
    local hasDurText = false
    if durFS and durFS.IsShown and durFS:IsShown() and durFS.GetText then
        local dt = F.PlainString(durFS:GetText(), "") or ""
        if dt ~= "" then hasDurText = true end
    end
    if hasDurText then
        local icObj = btn.Icon or btn.icon
        if icObj and icObj.GetTexture then
            local okT, tex = pcall(icObj.GetTexture, icObj)
            if okT and tex ~= nil and not F.IsSecret(tex) and wingShownIcons[tex] then
                return true
            end
        end
    end
    return false
end

local SyncTopRightAuraDedupe -- 前向声明

local function EnsureTopRightMicroToggle()
    if topRightMicroBtn then return topRightMicroBtn end
    local btn = CreateFrame("Button", "kkowoUI_TopRightAuraToggle", _G.UIParent)
    btn:SetSize(22, 20)
    btn:SetFrameStrata("LOW")
    btn:SetFrameLevel(16)
    if _G.Minimap then
        btn:SetPoint("TOPRIGHT", _G.Minimap, "TOPLEFT", -6, -2)
    else
        btn:SetPoint("TOPRIGHT", _G.UIParent, "TOPRIGHT", -210, -8)
    end

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(ST.TEX.FLAT)
    bg:SetVertexColor(0.06, 0.08, 0.11, 0.76)
    btn._bg = bg

    local fs = btn:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(fs, 10, "OUTLINE", 0.88, 0.94, 0.98, 1)
    fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
    fs:SetText("B")
    btn._label = fs

    ST.MaskTexture(btn, bg, 5)
    ST.ApplyRoundedBorder(btn, 5, 0.32, 0.84, 0.42, 0.65, 4)

    btn:SetAlpha(0.24)
    btn:SetScript("OnEnter", function(self)
        self:SetAlpha(0.96)
        if _G.GameTooltip then
            _G.GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT", 0, -4)
            _G.GameTooltip:AddLine("右上角暴雪原生增益栏（方案 A 快捷开关）", 0.32, 0.84, 0.42)
            if topRightTempExpanded then
                _G.GameTooltip:AddLine("当前：已临时展开原生 Buff/Debuff（可战中右键取消）", 0.94, 0.96, 0.99)
                _G.GameTooltip:AddLine("点击再次收起，保持右上角清爽", 0.72, 0.78, 0.85)
            else
                _G.GameTooltip:AddLine("当前：已全部集成到双翼上下，右上角清爽收起", 0.94, 0.96, 0.99)
                _G.GameTooltip:AddLine("点击临时展开原生栏（团本战中右键点掉 Buff 用）", 0.72, 0.78, 0.85)
            end
            _G.GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetAlpha(topRightTempExpanded and 0.82 or 0.24)
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    btn:SetScript("OnClick", function()
        topRightTempExpanded = not topRightTempExpanded
        SyncTopRightAuraDedupe()
    end)
    btn:Hide()
    topRightMicroBtn = btn
    return btn
end

SyncTopRightAuraDedupe = function()
    local db = mod:GetDB()
    local hudOn = mod._active == true and db.showCoreHUD ~= false
    local wantFullHideOptionA = hudOn and (db.hideTopRightBlizzAuras ~= false) and (not topRightTempExpanded)
    local dedupeOn = hudOn and (not wantFullHideOptionA) and (not topRightTempExpanded) and (db.dedupeTopRightAuras ~= false)
    local wantBuffDedupe = dedupeOn and db.showCombatBuffs ~= false
    local wantDebuffDedupe = wantFullHideOptionA or (dedupeOn and db.showCombatDebuffs ~= false)

    local bf = _G.BuffFrame
    if IsSafeBlizzFrame(bf) then
        if not buffFrameFullGuarded and bf.SetAlpha then
            buffFrameFullGuarded = true
            _G.hooksecurefunc(bf, "SetAlpha", function(self, a)
                if not auraAlphaBusy and buffFrameFullMuted and a ~= 0 then
                    auraAlphaBusy = true
                    pcall(self.SetAlpha, self, 0)
                    auraAlphaBusy = false
                end
            end)
        end

        if wantFullHideOptionA then
            -- 方案 A：彻底收起右上角暴雪原生 BuffFrame（战斗安全 0 污染，停用或点小按钮瞬间复原）
            buffFrameFullMuted = true
            auraAlphaBusy = true
            pcall(bf.SetAlpha, bf, 0)
            auraAlphaBusy = false
            for _, btn in ipairs(dedupedAuraBtnList) do
                SetAuraBtnMuted(btn, false)
            end
        else
            if buffFrameFullMuted then
                buffFrameFullMuted = false
                auraAlphaBusy = true
                pcall(bf.SetAlpha, bf, 1)
                auraAlphaBusy = false
            end
            if wantBuffDedupe and not buffFrameDedupeHooked then
                buffFrameDedupeHooked = true
                local reSync = F.Debounce(0.02, SyncTopRightAuraDedupe)
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
                elseif bf.AuraContainer and bf.AuraContainer.GetChildren then
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
        if not debuffFrameGuarded and df.SetAlpha then
            debuffFrameGuarded = true
            _G.hooksecurefunc(df, "SetAlpha", function(self, a)
                if not auraAlphaBusy and debuffFrameMuted and a ~= 0 then
                    auraAlphaBusy = true
                    pcall(self.SetAlpha, self, 0)
                    auraAlphaBusy = false
                end
            end)
        end
        if wantDebuffDedupe then
            debuffFrameMuted = true
            auraAlphaBusy = true
            pcall(df.SetAlpha, df, 0)
            auraAlphaBusy = false
        elseif debuffFrameMuted then
            debuffFrameMuted = false
            auraAlphaBusy = true
            pcall(df.SetAlpha, df, 1)
            auraAlphaBusy = false
        end
    end

    -- 右上角极简悬停微开关（方案 A 激活且未关闭微开关时显示；默认 24% 低调隐匿，悬停清晰）
    local showMicro = hudOn and (db.hideTopRightBlizzAuras ~= false) and (db.showTopRightMicroToggle ~= false)
    if showMicro then
        local mb = EnsureTopRightMicroToggle()
        if topRightTempExpanded then
            mb._bg:SetVertexColor(0.10, 0.24, 0.14, 0.86)
            ST.ApplyRoundedBorder(mb, 5, 0.32, 0.84, 0.42, 0.92, 4)
            mb._label:SetTextColor(0.62, 1.00, 0.72, 1)
            mb:SetAlpha(0.82)
        else
            mb._bg:SetVertexColor(0.06, 0.08, 0.11, 0.72)
            ST.ApplyRoundedBorder(mb, 5, 0.38, 0.44, 0.52, 0.55, 4)
            mb._label:SetTextColor(0.84, 0.90, 0.96, 1)
            mb:SetAlpha(0.24)
        end
        mb:Show()
    elseif topRightMicroBtn then
        topRightMicroBtn:Hide()
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
                if data.auraInstanceID ~= nil and not F.IsSecret(data.auraInstanceID) then
                    wingShownInstanceIDs[data.auraInstanceID] = true
                end
                if data.index then wingShownIndices[data.index] = true end
                if data.icon ~= nil and not F.IsSecret(data.icon) then
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
                    if d.auraInstanceID ~= nil and not F.IsSecret(d.auraInstanceID) then
                        wingShownInstanceIDs[d.auraInstanceID] = true
                    end
                    if d.index then wingShownIndices[d.index] = true end
                    if d.icon ~= nil and not F.IsSecret(d.icon) then
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
            ST.ClearRoundedMask(overflowBadge)
            if rad > 0 then ST.MaskTexture(overflowBadge, overflowBadge._bg, rad) end
            if isDebuff then
                ST.ApplyRoundedBorder(overflowBadge, math_max(rad, 4), 0.94, 0.30, 0.34, 0.92, 5)
            else
                local _, _, _, r2, g2, b2 = ST.GetClassGradient()
                ST.ApplyRoundedBorder(overflowBadge, math_max(rad, 4), r2 * 0.65 + 0.14, g2 * 0.65 + 0.14, b2 * 0.65 + 0.14, 0.88, 5)
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
    if not (coreFrame and coreFrame._buffSlots and coreFrame._debuffSlots) then return end
    local db = mod:GetDB()
    local sz = math_max(20, math_min(34, F.PlainNumber(db.auraIconSize, 26) or 26))
    local permSz = math_max(18, math_min(26, sz - 4))
    local gap = 5
    local permGap = 4
    local anchorTarget = coreFrame._orb or coreFrame

    for k in pairs(wingShownInstanceIDs) do wingShownInstanceIDs[k] = nil end
    for k in pairs(wingShownIndices) do wingShownIndices[k] = nil end
    for k in pairs(wingShownIcons) do wingShownIcons[k] = nil end

    local activeHUD = mod._active == true and db.showCoreHUD ~= false
    local permBuffs, timedBuffs = {}, {}
    if activeHUD and (db.showPermanentBuffs ~= false or db.showCombatBuffs ~= false) then
        permBuffs, timedBuffs = CollectSplitBuffs(db.buffFilter or "non_permanent")
    end

    -- 顶冠排（中央能量球正上方 +6px，距上方挥砍条留足 15px 空间零遮挡）：常驻 BUFF（守护/姿态/光环/追踪）
    if coreFrame._permSlots then
        local showPerm = activeHUD and db.showPermanentBuffs ~= false
        LayoutAuraRowWithOverflow(
            coreFrame._permSlots, coreFrame._permOverflow,
            showPerm and permBuffs or {}, MAX_PERM_SLOTS,
            permSz, permGap, anchorTarget, "BOTTOM", "TOP", 6,
            false, true, true
        )
    end

    -- 下方第一排（紧贴中央能量球正下方）：限时增益 Buff 动态水平居中平衡（超 8 个自动 +N 折叠）
    local nBuffShown = LayoutAuraRowWithOverflow(
        coreFrame._buffSlots, coreFrame._buffOverflow,
        (activeHUD and db.showCombatBuffs ~= false) and timedBuffs or {}, MAX_AURA_SLOTS,
        sz, gap, anchorTarget, "TOP", "BOTTOM", -8,
        false, false, true
    )

    -- 下方第二排（有增益时在增益排正下方，无增益时自动上提至能量球正下方）：自身 Debuff 动态居中 + +N 折叠
    local debuffs = (activeHUD and db.showCombatDebuffs ~= false) and CollectUnitDebuffs() or {}
    hasActiveDebuffs = (#debuffs > 0)
    local debuffY = (nBuffShown > 0) and -(8 + sz + 9) or -8
    LayoutAuraRowWithOverflow(
        coreFrame._debuffSlots, coreFrame._debuffOverflow,
        debuffs, MAX_AURA_SLOTS,
        sz, gap, anchorTarget, "TOP", "BOTTOM", debuffY,
        true, false, false
    )

    SyncTopRightAuraDedupe()
    UpdateIdleFade(false)
end

-- 挥砍计时独立轻量驱动（仅在平砍/自动射击计时中激活，停止立刻 Hide）
local swingTicker = CreateFrame("Frame")
swingTicker:Hide()

local function SyncUpperSwingVisual()
    if not (coreFrame and coreFrame._swingWing) then return end
    local sw = coreFrame._swingWing
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
        if coreFrame._ohWing and coreFrame._ohWing._isOHMode then
            coreFrame._ohWing._bar:SetValue(0)
        end
        swingTicker:Hide()
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

    if ohActive and coreFrame._ohWing and coreFrame._ohWing._isOHMode then
        local ohProg = math_max(0, math_min(1, (now - swingState.ohStart) / swingState.ohDur))
        coreFrame._ohWing._bar:SetMinMaxValues(0, 1)
        coreFrame._ohWing._bar:SetValue(ohProg)
    end
end

swingTicker:SetScript("OnUpdate", function()
    if not mod._active then
        swingTicker:Hide()
        return
    end
    SyncUpperSwingVisual()
end)

local function UpdateUpperRightClassPower()
    if not (coreFrame and coreFrame._classPips) then return end
    local db = mod:GetDB()
    local show = db.showUpperClassPower ~= false
    local cls = F.GetPlayerClass()
    local hasCombo = (cls == "ROGUE" or cls == "DRUID")
    local maxPips = 0
    local curPips = 0

    if hasCombo and _G.UnitPowerMax then
        local pt = (_G.Enum and _G.Enum.PowerType and _G.Enum.PowerType.ComboPoints) or 4
        maxPips = F.PlainNumber(_G.UnitPowerMax("player", pt), 5) or 5
        if maxPips > 0 then
            curPips = F.PlainNumber(_G.UnitPower("player", pt), 0) or 0
        elseif _G.GetComboPoints then
            maxPips = 5
            curPips = F.PlainNumber(_G.GetComboPoints("player", "target"), 0) or 0
        end
    end

    local pipsHolder = coreFrame._classPips
    local ohWing = coreFrame._ohWing
    if show and maxPips > 0 and maxPips <= 7 then
        pipsHolder:Show()
        if ohWing then ohWing:Hide(); ohWing._isOHMode = false end
        if coreFrame._rightTopGroove then coreFrame._rightTopGroove:Hide() end
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
        local _, ohSpeed = _G.UnitAttackSpeed and _G.UnitAttackSpeed("player")
        ohSpeed = F.PlainNumber(ohSpeed, nil)
        if show and ohWing and ohSpeed and ohSpeed > 0.1 then
            ohWing._isOHMode = true
            ohWing:Show()
            if coreFrame._rightTopGroove then coreFrame._rightTopGroove:Hide() end
        else
            if ohWing then
                ohWing._isOHMode = false
                ohWing:Hide()
            end
            if coreFrame._rightTopGroove then
                coreFrame._rightTopGroove:SetShown(db.showUpperSwing ~= false)
            end
        end
    end
end

local function BuildCoreHUD()
    if coreFrame then return end
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
        radius = GetBarRadius(barH),
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
        radius = GetBarRadius(barH),
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
    F.Theme.ApplyFont(hpText, 11, "OUTLINE", 0.98, 0.99, 1.00, 1)
    hpText:SetShadowOffset(1, -1)
    hpText:SetPoint("LEFT", hpWing, "LEFT", 8, 0)
    hpText:SetJustifyH("LEFT")
    hpText:SetWordWrap(false)
    f._hpText = hpText

    local ppText = textLayer:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(ppText, 11, "OUTLINE", 0.96, 0.98, 1.00, 1)
    ppText:SetShadowOffset(1, -1)
    ppText:SetPoint("RIGHT", ppWing, "RIGHT", -8, 0)
    ppText:SetJustifyH("RIGHT")
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
    orbMask:SetPoint("TOPLEFT", orb, "TOPLEFT", 4, -4)
    orbMask:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", -4, 4)
    orbMask:SetTexture(ST.TEX.CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")

    -- 底层前序图标缓存（切换技能或施法结束回默认图标时丝滑淡出溶解，绝不生硬跳切）
    local orbIconPrev = orb:CreateTexture(nil, "ARTWORK", nil, 0)
    orbIconPrev:SetPoint("TOPLEFT", orb, "TOPLEFT", 4, -4)
    orbIconPrev:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", -4, 4)
    orbIconPrev:AddMaskTexture(orbMask)
    orbIconPrev:Hide()
    orb._iconPrev = orbIconPrev

    local orbIcon = orb:CreateTexture(nil, "ARTWORK", nil, 1)
    orbIcon:SetPoint("TOPLEFT", orb, "TOPLEFT", 4, -4)
    orbIcon:SetPoint("BOTTOMRIGHT", orb, "BOTTOMRIGHT", -4, 4)
    orbIcon:AddMaskTexture(orbMask)
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
    local combatIcon = orb:CreateTexture(nil, "OVERLAY", nil, 7)
    combatIcon:SetSize(13, 13)
    combatIcon:SetPoint("TOPRIGHT", orb, "TOPRIGHT", 5, 5)
    combatIcon:SetTexture(F.MEDIA .. "CombatAlert\\Sword.tga")
    combatIcon:SetVertexColor(0.96, 0.88, 0.72, 0.95)
    combatIcon:Hide()
    orb._combatIcon = combatIcon
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
        tShade:SetHeight(10)
        tShade:SetTexture(ST.TEX.FLAT)
        ST.ApplyGradient(tShade, "VERTICAL", 0, 0, 0, 0.72, 0, 0, 0, 0.0)
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

        -- 堆叠层数放在右上角，与底部计时完全分离不重叠
        local stFS = slot:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(stFS, 9, "OUTLINE", 1, 0.92, 0.56, 1)
        stFS:SetPoint("TOPRIGHT", slot, "TOPRIGHT", -1, -1)
        stFS:Hide()
        slot._stacks = stFS

        slot:SetScript("OnEnter", function(self)
            if not _G.GameTooltip then return end
            _G.GameTooltip:SetOwner(self, self._isPerm and "ANCHOR_TOP" or "ANCHOR_BOTTOM", 0, self._isPerm and 4 or -4)
            if self._auraInstanceID then
                if self._isDebuff and _G.GameTooltip.SetUnitDebuffByAuraInstanceID then
                    pcall(_G.GameTooltip.SetUnitDebuffByAuraInstanceID, _G.GameTooltip, "player", self._auraInstanceID)
                elseif (not self._isDebuff) and _G.GameTooltip.SetUnitBuffByAuraInstanceID then
                    pcall(_G.GameTooltip.SetUnitBuffByAuraInstanceID, _G.GameTooltip, "player", self._auraInstanceID)
                elseif self._auraIndex and _G.GameTooltip.SetUnitAura then
                    pcall(_G.GameTooltip.SetUnitAura, _G.GameTooltip, "player", self._auraIndex, self._isDebuff and "HARMFUL" or "HELPFUL")
                end
            elseif self._auraIndex and _G.GameTooltip.SetUnitAura then
                pcall(_G.GameTooltip.SetUnitAura, _G.GameTooltip, "player", self._auraIndex, self._isDebuff and "HARMFUL" or "HELPFUL")
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
        F.Theme.ApplyFont(oTxt, 10, "OUTLINE", 0.94, 0.97, 1.00, 1)
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
        isHidden = function() return not (mod._active and mod:GetDB().showCoreHUD ~= false) end,
    })

    coreFrame = f
end

----------------------------------------------------------------------
--  2) 独立宠物圆角框体（PetHUD）
----------------------------------------------------------------------
local function BuildPetHUD()
    if petFrame then return end
    local f = CreateFrame("Frame", "kkowoUI_PetHUD", _G.UIParent)
    f:SetSize(156, 36)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(12)
    f:EnableMouse(false)

    -- 左侧宠物快乐度/头像圆角徽章
    local iconBox = CreateFrame("Frame", nil, f)
    iconBox:SetSize(22, 22)
    iconBox:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    local ibBg = iconBox:CreateTexture(nil, "BACKGROUND")
    ibBg:SetAllPoints()
    ibBg:SetColorTexture(0.04, 0.045, 0.06, 0.92)
    local ibTex = iconBox:CreateTexture(nil, "ARTWORK")
    ibTex:SetPoint("TOPLEFT", iconBox, "TOPLEFT", 2, -2)
    ibTex:SetPoint("BOTTOMRIGHT", iconBox, "BOTTOMRIGHT", -2, 2)
    ST.MaskTexture(iconBox, ibBg, 5)
    ST.MaskTexture(iconBox, ibTex, 5)
    ST.ApplyRoundedBorder(iconBox, 5, 0.02, 0.022, 0.03, 0.95, 4)
    iconBox._tex = ibTex
    f._iconBox = iconBox

    local hpBar = CreateWingBar(f, 130, 16, false)
    hpBar:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 4, 0)
    hpBar._trail = M.AttachHealthTrail(hpBar._bar, {
        delay = 0.16, reverse = false, radius = 5, color = ST.COLORS.trail,
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
    F.Theme.ApplyFont(nameFS, 10, "OUTLINE", 0.96, 0.98, 1.00, 1)
    nameFS:SetShadowOffset(1, -1)
    nameFS:SetPoint("LEFT", hpBar, "LEFT", 6, 0)
    nameFS:SetWidth(76)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    f._nameText = nameFS

    local hpFS = petTextLayer:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(hpFS, 10, "OUTLINE", 0.96, 0.98, 1.00, 1)
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
    petFrame = f
end

----------------------------------------------------------------------
--  3) 可选顶部极简目标框体（TopTargetHUD：目标长条 + 圆形头像 + 目标的目标）
----------------------------------------------------------------------
local function BuildTopTargetHUD()
    if topTargetFrame then return end
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
        delay = 0.16, reverse = false, radius = 6, color = ST.COLORS.trail,
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
    F.Theme.ApplyFont(hpText, 11, "OUTLINE", 0.98, 0.99, 1.00, 1)
    hpText:SetShadowOffset(1, -1)
    hpText:SetPoint("LEFT", hpBar, "LEFT", 8, 0)
    hpText:SetJustifyH("LEFT")
    hpText:SetWordWrap(false)
    f._hpText = hpText

    local nameText = targetTextLayer:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(nameText, 11, "OUTLINE", 0.98, 0.99, 1.00, 1)
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
    pMask:SetPoint("TOPLEFT", port, "TOPLEFT", 2, -2)
    pMask:SetPoint("BOTTOMRIGHT", port, "BOTTOMRIGHT", -2, 2)
    pMask:SetTexture(ST.TEX.CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    local pTex = port:CreateTexture(nil, "ARTWORK")
    pTex:SetPoint("TOPLEFT", port, "TOPLEFT", 2, -2)
    pTex:SetPoint("BOTTOMRIGHT", port, "BOTTOMRIGHT", -2, 2)
    pTex:AddMaskTexture(pMask)
    local pRing = port:CreateTexture(nil, "OVERLAY", nil, 4)
    pRing:SetAllPoints()
    pRing:SetTexture(ST.TEX.CIRCLE_RING)
    pRing:SetVertexColor(0.10, 0.12, 0.16, 0.96)
    port._tex = pTex
    f._portrait = port

    -- 目标的目标微条（作为附属浮标挂在圆形头像右侧外，不撑偏目标条主居中盒）
    local totBar = CreateWingBar(f, 84, 10, false)
    totBar:SetPoint("LEFT", port, "RIGHT", 8, -4)
    local totName = f:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(totName, 10, "OUTLINE", 0.90, 0.92, 0.96, 1)
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
    topTargetFrame = f
end

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

local function UpdatePlayerHealth(instant)
    if coreFrame and coreFrame:IsShown() then
        local hp = _G.UnitHealth and _G.UnitHealth("player") or 0
        local mx = _G.UnitHealthMax and _G.UnitHealthMax("player") or 1
        pcall(coreFrame._hpWing._bar.SetMinMaxValues, coreFrame._hpWing._bar, 0, mx)
        pcall(coreFrame._hpWing._bar.SetValue, coreFrame._hpWing._bar, hp)
        UpdateBarSparkVis(coreFrame._hpWing, hp, mx)
        if coreFrame._hpWing._trail then
            coreFrame._hpWing._trail:SetEnabled(mod:GetDB().showTrail ~= false)
            coreFrame._hpWing._trail:SetValue(hp, mx, instant)
        end
        SetHealthText(coreFrame._hpText, "player", false)
    end
    if euiTrailPlayer then
        euiTrailPlayer:SetEnabled(mod._active and mod:GetDB().enhanceEUIFrames ~= false and mod:GetDB().showTrail ~= false)
        euiTrailPlayer:UpdateFromUnit("player", instant)
    end
end

local function UpdatePlayerPower(instant)
    if not (coreFrame and coreFrame:IsShown()) then return end
    local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("player"), 0) or 0
    local cur = _G.UnitPower and _G.UnitPower("player", pType) or 0
    local mx = _G.UnitPowerMax and _G.UnitPowerMax("player", pType) or 1
    pcall(coreFrame._ppWing._bar.SetMinMaxValues, coreFrame._ppWing._bar, 0, mx)
    pcall(coreFrame._ppWing._bar.SetValue, coreFrame._ppWing._bar, cur)
    UpdateBarSparkVis(coreFrame._ppWing, cur, mx)
    if coreFrame._ppWing._trail then
        coreFrame._ppWing._trail:SetEnabled(mod:GetDB().showTrail ~= false)
        coreFrame._ppWing._trail:SetValue(cur, mx, instant)
    end
    local r1, g1, b1, r2, g2, b2 = ST.GetPowerGradient(pType)
    ST.ApplyBarGradient(coreFrame._ppWing._bar, r1, g1, b1, r2, g2, b2, 0.98, false)
    SetPowerText(coreFrame._ppText, "player", pType)
end

local function UpdatePetHUD(instant)
    if not petFrame then return end
    local db = mod:GetDB()
    local exists = _G.UnitExists and _G.UnitExists("pet")
    if not (mod._active and db.showPetFrame ~= false and exists) then
        petFrame:Hide()
        return
    end
    petFrame:Show()
    local hp = _G.UnitHealth and _G.UnitHealth("pet") or 0
    local mx = _G.UnitHealthMax and _G.UnitHealthMax("pet") or 1
    pcall(petFrame._hpBar._bar.SetMinMaxValues, petFrame._hpBar._bar, 0, mx)
    pcall(petFrame._hpBar._bar.SetValue, petFrame._hpBar._bar, hp)
    if petFrame._hpBar._trail then
        petFrame._hpBar._trail:SetEnabled(db.showTrail ~= false)
        petFrame._hpBar._trail:SetValue(hp, mx, instant)
    end
    local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
    ST.ApplyBarGradient(petFrame._hpBar._bar, r1, g1, b1, r2, g2, b2, 0.98, false)

    local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("pet"), 2) or 2
    local pCur = _G.UnitPower and _G.UnitPower("pet", pType) or 0
    local pMx = _G.UnitPowerMax and _G.UnitPowerMax("pet", pType) or 1
    pcall(petFrame._ppBar._bar.SetMinMaxValues, petFrame._ppBar._bar, 0, pMx)
    pcall(petFrame._ppBar._bar.SetValue, petFrame._ppBar._bar, pCur)
    local pr1, pg1, pb1, pr2, pg2, pb2 = ST.GetPowerGradient(pType)
    ST.ApplyBarGradient(petFrame._ppBar._bar, pr1, pg1, pb1, pr2, pg2, pb2, 0.98, false)

    local petName = _G.UnitName and _G.UnitName("pet")
    if petName ~= nil then
        pcall(petFrame._nameText.SetText, petFrame._nameText, petName)
    else
        petFrame._nameText:SetText("宠物")
    end
    SetHealthText(petFrame._hpText, "pet", true)

    -- 宠物快乐度图标（猎人优先，其它宠物自动显示头像）
    local happy = _G.C_PetInfo and _G.C_PetInfo.GetPetHappiness and F.PlainNumber(_G.C_PetInfo.GetPetHappiness(), nil)
        or (_G.GetPetHappiness and F.PlainNumber(_G.GetPetHappiness(), nil))
    if happy == 3 then
        petFrame._iconBox._tex:SetTexture(F.MEDIA .. "Icons\\PetHappy.tga")
        petFrame._iconBox._tex:SetTexCoord(0, 1, 0, 1)
    elseif happy == 2 then
        petFrame._iconBox._tex:SetTexture(F.MEDIA .. "Icons\\PetNeutral.tga")
        petFrame._iconBox._tex:SetTexCoord(0, 1, 0, 1)
    elseif happy == 1 then
        petFrame._iconBox._tex:SetTexture(F.MEDIA .. "Icons\\PetMad.tga")
        petFrame._iconBox._tex:SetTexCoord(0, 1, 0, 1)
    elseif _G.SetPortraitTexture then
        pcall(_G.SetPortraitTexture, petFrame._iconBox._tex, "pet")
        petFrame._iconBox._tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

local function UpdateTargetOfTarget()
    if not (topTargetFrame and topTargetFrame._totBar) then return end
    local tot = topTargetFrame._totBar
    if not (_G.UnitExists and _G.UnitExists("targettarget")) then
        tot:Hide()
        return
    end
    tot:Show()
    local hp = _G.UnitHealth and _G.UnitHealth("targettarget") or 0
    local mx = _G.UnitHealthMax and _G.UnitHealthMax("targettarget") or 1
    pcall(tot._bar.SetMinMaxValues, tot._bar, 0, mx)
    pcall(tot._bar.SetValue, tot._bar, hp)
    local r1, g1, b1, r2, g2, b2 = ST.GetUnitGradient("targettarget")
    ST.ApplyBarGradient(tot._bar, r1, g1, b1, r2, g2, b2, 0.98, false)
    local nm = F.PlainString(_G.UnitName and _G.UnitName("targettarget"), "") or ""
    tot._nameText:SetText(nm)
end

local function UpdateTopTargetHUD(instant)
    if topTargetFrame then
        local db = mod:GetDB()
        local exists = _G.UnitExists and _G.UnitExists("target")
        if not (mod._active and db.enableTopTarget ~= false and exists) then
            topTargetFrame:Hide()
        else
            if instant and not topTargetFrame:IsShown() then
                topTargetFrame:SetAlpha(0)
                topTargetFrame:Show()
                F.Theme.FadeTo(topTargetFrame, 1.0, 0.10, false)
            else
                topTargetFrame:Show()
            end
            local hp = _G.UnitHealth and _G.UnitHealth("target") or 0
            local mx = _G.UnitHealthMax and _G.UnitHealthMax("target") or 1
            pcall(topTargetFrame._hpBar._bar.SetMinMaxValues, topTargetFrame._hpBar._bar, 0, mx)
            pcall(topTargetFrame._hpBar._bar.SetValue, topTargetFrame._hpBar._bar, hp)
            if topTargetFrame._hpBar._trail then
                topTargetFrame._hpBar._trail:SetEnabled(db.showTrail ~= false)
                topTargetFrame._hpBar._trail:SetValue(hp, mx, instant)
            end
            local r1, g1, b1, r2, g2, b2 = ST.GetUnitGradient("target")
            ST.ApplyBarGradient(topTargetFrame._hpBar._bar, r1, g1, b1, r2, g2, b2, 0.98, false)

            local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("target"), 0) or 0
            local pCur = _G.UnitPower and _G.UnitPower("target", pType) or 0
            local pMx = _G.UnitPowerMax and _G.UnitPowerMax("target", pType) or 1
            pcall(topTargetFrame._ppBar._bar.SetMinMaxValues, topTargetFrame._ppBar._bar, 0, pMx)
            pcall(topTargetFrame._ppBar._bar.SetValue, topTargetFrame._ppBar._bar, pCur)
            local pr1, pg1, pb1, pr2, pg2, pb2 = ST.GetPowerGradient(pType)
            ST.ApplyBarGradient(topTargetFrame._ppBar._bar, pr1, pg1, pb1, pr2, pg2, pb2, 0.98, false)

            SetHealthText(topTargetFrame._hpText, "target", false)
            local rawName = _G.UnitName and _G.UnitName("target")
            local tName = F.PlainString(rawName, nil)
            local tLvl = _G.UnitLevel and F.PlainNumber(_G.UnitLevel("target"), nil)
            local lvlStr = (tLvl and tLvl > 0) and tostring(tLvl) or (tLvl == -1 and "??" or "")
            if tName then
                topTargetFrame._nameText:SetText(lvlStr ~= "" and (tName .. " | " .. lvlStr) or tName)
            elseif rawName ~= nil then
                pcall(topTargetFrame._nameText.SetText, topTargetFrame._nameText, rawName)
            end

            if _G.SetPortraitTexture and topTargetFrame._portrait then
                pcall(_G.SetPortraitTexture, topTargetFrame._portrait._tex, "target")
            end
            UpdateTargetOfTarget()
        end
    end

    if euiTrailTarget then
        euiTrailTarget:SetEnabled(mod._active and mod:GetDB().enhanceEUIFrames ~= false and mod:GetDB().showTrail ~= false)
        euiTrailTarget:UpdateFromUnit("target", instant)
        if instant and mod._active and mod:GetDB().enhanceEUIFrames ~= false then
            local tf = _G.EllesmereUIUnitFrames_Target
            if tf and tf:IsShown() and not hiddenEUI.target then
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

local function AttachEUITrails()
    local pf = _G.EllesmereUIUnitFrames_Player
    if pf and pf.Health and not euiTrailPlayer then
        euiTrailPlayer = M.AttachHealthTrail(pf.Health, {
            delay = mod:GetDB().trailDelay or 0.16,
            color = ST.COLORS.trail,
        })
    end
    local tf = _G.EllesmereUIUnitFrames_Target
    if tf and tf.Health and not euiTrailTarget then
        euiTrailTarget = M.AttachHealthTrail(tf.Health, {
            delay = mod:GetDB().trailDelay or 0.16,
            color = ST.COLORS.trail,
        })
    end
    if not euiHooksDone and type(_G._EUF_ReloadFrames) == "function" then
        euiHooksDone = true
        _G.hooksecurefunc("_EUF_ReloadFrames", function()
            if mod._active then
                C_Timer.After(0.1, function()
                    if mod._active then
                        if euiTrailPlayer then euiTrailPlayer:SyncAnchor() end
                        if euiTrailTarget then euiTrailTarget:SyncAnchor() end
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
        if not alphaGuardBusy and hiddenEUI[key] then
            alphaGuardBusy = true
            pcall(self.SetAlpha, self, 0)
            alphaGuardBusy = false
        end
    end
    if fr.SetAlpha then
        _G.hooksecurefunc(fr, "SetAlpha", function(self, a)
            if not alphaGuardBusy and hiddenEUI[key] and a ~= 0 then
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

    -- SetAlpha 战斗内也 100% 安全，立刻同步生效并挂防复原锁（同步拦截 SetAlpha / SetAlphaFromBoolean / Show）
    for key, hide in pairs(wantHide) do
        local fr = GetEUIUnitFrame(key)
        hiddenEUI[key] = hide == true
        if fr then
            local targetObj = fr._visWrap or fr
            EnsureEUIAlphaGuard(fr, key)
            if targetObj ~= fr then EnsureEUIAlphaGuard(targetObj, key) end
            alphaGuardBusy = true
            pcall(fr.SetAlpha, fr, hide and 0 or 1)
            if targetObj ~= fr then pcall(targetObj.SetAlpha, targetObj, hide and 0 or 1) end
            alphaGuardBusy = false
        end
    end

    -- 脱战安全窗口：同步注销/恢复 RegisterUnitWatch 与 Hide/Show + 鼠标穿透，彻底杜绝「召唤宠物」或切目标把 EUI 原版框体重新唤出
    F.CombatDefer("kkowoUI_CoreHUD_SyncEUIMouse", function()
        for key, hide in pairs(hiddenEUI) do
            local fr = GetEUIUnitFrame(key)
            if fr then
                if hide then
                    if _G.UnregisterUnitWatch then pcall(_G.UnregisterUnitWatch, fr) end
                    if fr.Hide then pcall(fr.Hide, fr) end
                    if fr.EnableMouse then pcall(fr.EnableMouse, fr, false) end
                    alphaGuardBusy = true
                    pcall(fr.SetAlpha, fr, 0)
                    alphaGuardBusy = false
                else
                    if fr.EnableMouse then pcall(fr.EnableMouse, fr, true) end
                    alphaGuardBusy = true
                    pcall(fr.SetAlpha, fr, 1)
                    if fr._visWrap and fr._visWrap ~= fr then pcall(fr._visWrap.SetAlpha, fr._visWrap, 1) end
                    alphaGuardBusy = false
                    if key == "player" then
                        if fr.Show then pcall(fr.Show, fr) end
                    else
                        if _G.RegisterUnitWatch then pcall(_G.RegisterUnitWatch, fr) end
                    end
                end
            end
        end
    end)
end

local function ApplyLayoutAndTheme()
    local db = mod:GetDB()
    local insideBars = (db.textInsideBars ~= false)
    if coreFrame then
        local show = mod._active and db.showCoreHUD ~= false
        coreFrame:SetShown(show)
        if show then
            local wingW = math_max(90, math_min(200, F.PlainNumber(db.wingWidth, 136) or 136))
            local barH = math_max(12, math_min(26, F.PlainNumber(db.barHeight, 18) or 18))
            local orbSz = math_max(34, math_min(58, F.PlainNumber(db.orbSize, 44) or 44))
            local sc = math_max(0.7, math_min(1.4, F.PlainNumber(db.scale, 1.0) or 1.0))

            local orbHalfGap = math_floor(orbSz * 0.34)
            coreFrame:SetScale(sc)
            coreFrame:SetSize(wingW * 2 + orbHalfGap * 2, math_max(orbSz + 6, barH + (insideBars and 22 or 34)))
            coreFrame._hpWing:SetSize(wingW, barH)
            coreFrame._ppWing:SetSize(wingW, barH)
            coreFrame._hpWing:ClearAllPoints()
            coreFrame._hpWing:SetPoint("RIGHT", coreFrame, "CENTER", -orbHalfGap, -6)
            coreFrame._ppWing:ClearAllPoints()
            coreFrame._ppWing:SetPoint("LEFT", coreFrame, "CENTER", orbHalfGap, -6)

            -- 数值文字位置：默认精致内嵌到血条与资源条内部（让双翼上方极度清爽，不与上方常驻 BUFF 争空间）
            local inFontSz = math_max(9, math_min(12, math_floor(barH - 7)))
            coreFrame._hpText:ClearAllPoints()
            coreFrame._ppText:ClearAllPoints()
            if insideBars then
                F.Theme.ApplyFont(coreFrame._hpText, inFontSz, "OUTLINE", 0.98, 0.99, 1.00, 1)
                F.Theme.ApplyFont(coreFrame._ppText, inFontSz, "OUTLINE", 0.96, 0.98, 1.00, 1)
                coreFrame._hpText:SetPoint("LEFT", coreFrame._hpWing, "LEFT", 8, 0)
                coreFrame._ppText:SetPoint("RIGHT", coreFrame._ppWing, "RIGHT", -8, 0)
                coreFrame._hpText:SetWidth(math_max(48, wingW - orbHalfGap - 8))
                coreFrame._ppText:SetWidth(math_max(40, wingW - orbHalfGap - 8))
            else
                F.Theme.ApplyFont(coreFrame._hpText, 12, "OUTLINE", 0.96, 0.97, 0.99, 1)
                F.Theme.ApplyFont(coreFrame._ppText, 12, "OUTLINE", 0.94, 0.96, 0.99, 1)
                coreFrame._hpText:SetPoint("BOTTOMLEFT", coreFrame._hpWing, "TOPLEFT", 2, 9)
                coreFrame._ppText:SetPoint("BOTTOMRIGHT", coreFrame._ppWing, "TOPRIGHT", -2, 9)
                coreFrame._hpText:SetWidth(0)
                coreFrame._ppText:SetWidth(0)
            end

            coreFrame._swingWing:SetSize(wingW - 4, 5)
            coreFrame._swingWing:SetShown(db.showUpperSwing ~= false)
            if coreFrame._rightTopGroove then
                coreFrame._rightTopGroove:SetSize(wingW - 4, 5)
                ApplyWingStyle(coreFrame._rightTopGroove, 0.04, 0.045, 0.06, 0.04, 0.045, 0.06, GetBarRadius(5))
            end
            coreFrame._classPips:SetSize(wingW - 4, 5)
            coreFrame._ohWing:SetSize(wingW - 4, 5)
            coreFrame._orb:SetSize(orbSz, orbSz)
            if coreFrame._orb._halo then
                coreFrame._orb._halo:SetSize(orbSz * 1.95, orbSz * 1.95)
            end

            local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
            local rad = GetBarRadius(barH)
            ApplyWingStyle(coreFrame._hpWing, r1, g1, b1, r2, g2, b2, rad)
            if coreFrame._hpWing._trail then
                coreFrame._hpWing._trail:SetDelay(db.trailDelay or 0.16)
                coreFrame._hpWing._trail:SyncAnchor()
            end
            if coreFrame._hpWing._spark then coreFrame._hpWing._spark:SyncAnchor() end

            local pType = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("player"), 0) or 0
            local pr1, pg1, pb1, pr2, pg2, pb2 = ST.GetPowerGradient(pType)
            ApplyWingStyle(coreFrame._ppWing, pr1, pg1, pb1, pr2, pg2, pb2, rad)
            if coreFrame._ppWing._trail then coreFrame._ppWing._trail:SyncAnchor() end
            if coreFrame._ppWing._spark then coreFrame._ppWing._spark:SyncAnchor() end

            ApplyWingStyle(coreFrame._swingWing, r1 * 0.85, g1 * 0.85, b1 * 0.85, r2, g2, b2, GetBarRadius(5))
            coreFrame._swingWing._lastColorKey = "class"
            ApplyWingStyle(coreFrame._ohWing, r1 * 0.72, g1 * 0.72, b1 * 0.72, r2 * 0.9, g2 * 0.9, b2 * 0.9, GetBarRadius(5))
            if coreFrame._orb._ring then
                coreFrame._orb._ring:SetVertexColor(r1 * 0.45 + 0.08, g1 * 0.45 + 0.08, b1 * 0.45 + 0.08, 0.96)
            end

            if coreFrame._orb._cd and coreFrame._orb._cd.SetSwipeColor then
                pcall(coreFrame._orb._cd.SetSwipeColor, coreFrame._orb._cd, r2, g2, b2, 0.92)
            end
            local inCombat = (_G.InCombatLockdown and _G.InCombatLockdown())
                or (_G.UnitAffectingCombat and _G.UnitAffectingCombat("player"))
            coreFrame._orb._combatIcon:SetShown(inCombat == true)

            UpdatePlayerHealth(true)
            UpdatePlayerPower(true)
            UpdateUpperRightClassPower()
            UpdateOrbAppearance(false)
            UpdateCombatAuras()
        end
    end

    if petFrame then
        petFrame:SetScale(math_max(0.7, math_min(1.4, F.PlainNumber(db.scale, 1.0) or 1.0)))
        local pHpH = insideBars and 16 or 14
        local pPpH = insideBars and 4 or 5
        petFrame:SetSize(156, insideBars and 24 or 36)
        petFrame._hpBar:SetSize(130, pHpH)
        petFrame._ppBar:SetSize(130, pPpH)
        petFrame._nameText:ClearAllPoints()
        petFrame._hpText:ClearAllPoints()
        if insideBars then
            F.Theme.ApplyFont(petFrame._nameText, 10, "OUTLINE", 0.96, 0.98, 1.00, 1)
            F.Theme.ApplyFont(petFrame._hpText, 10, "OUTLINE", 0.96, 0.98, 1.00, 1)
            petFrame._nameText:SetPoint("LEFT", petFrame._hpBar, "LEFT", 6, 0)
            petFrame._nameText:SetWidth(76)
            petFrame._hpText:SetPoint("RIGHT", petFrame._hpBar, "RIGHT", -6, 0)
        else
            F.Theme.ApplyFont(petFrame._nameText, 11, "OUTLINE", 0.92, 0.95, 0.98, 1)
            F.Theme.ApplyFont(petFrame._hpText, 11, "OUTLINE", 0.94, 0.96, 0.99, 1)
            petFrame._nameText:SetPoint("BOTTOMLEFT", petFrame._hpBar, "TOPLEFT", 2, 2)
            petFrame._nameText:SetWidth(90)
            petFrame._hpText:SetPoint("BOTTOMRIGHT", petFrame._hpBar, "TOPRIGHT", -2, 2)
        end
        local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
        ApplyWingStyle(petFrame._hpBar, r1, g1, b1, r2, g2, b2, GetBarRadius(pHpH))
        local pt = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("pet"), 2) or 2
        local pr1, pg1, pb1, pr2, pg2, pb2 = ST.GetPowerGradient(pt)
        ApplyWingStyle(petFrame._ppBar, pr1, pg1, pb1, pr2, pg2, pb2, GetBarRadius(pPpH))
        if petFrame._hpBar._trail then petFrame._hpBar._trail:SetDelay(db.trailDelay or 0.16) end
        UpdatePetHUD(true)
    end
    if topTargetFrame then
        topTargetFrame:SetScale(math_max(0.7, math_min(1.4, F.PlainNumber(db.scale, 1.0) or 1.0)))
        local tHpH = insideBars and 18 or 16
        topTargetFrame:SetSize(286, insideBars and 30 or 38)
        topTargetFrame._hpBar:SetSize(256, tHpH)
        topTargetFrame._hpText:ClearAllPoints()
        topTargetFrame._nameText:ClearAllPoints()
        if insideBars then
            F.Theme.ApplyFont(topTargetFrame._hpText, 11, "OUTLINE", 0.98, 0.99, 1.00, 1)
            F.Theme.ApplyFont(topTargetFrame._nameText, 11, "OUTLINE", 0.98, 0.99, 1.00, 1)
            topTargetFrame._hpText:SetPoint("LEFT", topTargetFrame._hpBar, "LEFT", 8, 0)
            topTargetFrame._nameText:SetPoint("RIGHT", topTargetFrame._hpBar, "RIGHT", -10, 0)
            topTargetFrame._nameText:SetWidth(148)
        else
            F.Theme.ApplyFont(topTargetFrame._hpText, 12, "OUTLINE", 0.97, 0.97, 0.99, 1)
            F.Theme.ApplyFont(topTargetFrame._nameText, 12, "OUTLINE", 0.97, 0.97, 0.99, 1)
            topTargetFrame._hpText:SetPoint("BOTTOMLEFT", topTargetFrame._hpBar, "TOPLEFT", 2, 2)
            topTargetFrame._nameText:SetPoint("BOTTOMRIGHT", topTargetFrame._hpBar, "TOPRIGHT", -2, 2)
            topTargetFrame._nameText:SetWidth(168)
        end
        local tr1, tg1, tb1, tr2, tg2, tb2 = ST.GetUnitGradient("target")
        ApplyWingStyle(topTargetFrame._hpBar, tr1, tg1, tb1, tr2, tg2, tb2, GetBarRadius(tHpH))
        local tpt = _G.UnitPowerType and F.PlainNumber(_G.UnitPowerType("target"), 0) or 0
        local tpr1, tpg1, tpb1, tpr2, tpg2, tpb2 = ST.GetPowerGradient(tpt)
        ApplyWingStyle(topTargetFrame._ppBar, tpr1, tpg1, tpb1, tpr2, tpg2, tpb2, GetBarRadius(4))
        local totr1, totg1, totb1, totr2, totg2, totb2 = ST.GetUnitGradient("targettarget")
        ApplyWingStyle(topTargetFrame._totBar, totr1, totg1, totb1, totr2, totg2, totb2, GetBarRadius(10))
        if topTargetFrame._hpBar._trail then topTargetFrame._hpBar._trail:SetDelay(db.trailDelay or 0.16) end
        if topTargetFrame._hpBar._spark then topTargetFrame._hpBar._spark:SyncAnchor() end
        UpdateTopTargetHUD(true)
    end
    if euiTrailPlayer then euiTrailPlayer:SetDelay(db.trailDelay or 0.16) end
    if euiTrailTarget then euiTrailTarget:SetDelay(db.trailDelay or 0.16) end
    SyncHiddenEUIFrames()
    UpdateIdleFade(true)
end

----------------------------------------------------------------------
--  6) 生命周期与事件注册（关闭时 0 事件 / 0 Ticker）
----------------------------------------------------------------------
local function OnCastBegin(isChannel, castGUID, spellID)
    local fn = isChannel and _G.UnitChannelInfo or _G.UnitCastingInfo
    if not fn then return end
    local ok, name, _, tex, startMS, endMS = pcall(fn, "player")
    if not ok or not tex then return end
    local pName = F.PlainString(name, nil)
    local pSid = F.PlainNumber(spellID, nil)
    if IsPermanentOrAspectSpell(pSid, pName) then return end
    local sMS = F.PlainNumber(startMS, nil)
    local eMS = F.PlainNumber(endMS, nil)
    orbState.castActive = true
    orbState.castSpellID = pSid
    orbState.castGUID = (castGUID ~= nil and not F.IsSecret(castGUID)) and castGUID or nil
    orbState.lastSpellIcon = nil
    orbState.lastSpellUntil = 0
    if not F.IsSecret(tex) then orbState.castIcon = tex end
    UpdateOrbAppearance(true)
    UpdateIdleFade(false)
    if sMS and eMS and eMS > sMS then
        SetOrbTimerArc(sMS / 1000, (eMS - sMS) / 1000)
    end
end

local function OnCastEnd()
    if (_G.UnitCastingInfo and _G.UnitCastingInfo("player"))
        or (_G.UnitChannelInfo and _G.UnitChannelInfo("player")) then
        return
    end
    -- 读条/引导技能（如剥皮、采矿、瞄准射击等）结束瞬间立刻归位，绝不滞留 5 秒！
    orbState.castActive = false
    orbState.castIcon = nil
    orbState.castSpellID = nil
    orbState.lastSpellIcon = nil
    orbState.lastSpellUntil = 0
    orbState.lastCastEndTime = GetTime()
    local inCombat = (_G.InCombatLockdown and _G.InCombatLockdown())
        or (_G.UnitAffectingCombat and _G.UnitAffectingCombat("player"))
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
    AttachEUITrails()

    local EUI = _G.EllesmereUI
    if EUI and EUI.RegisterUnlockModeListener then
        pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_CoreHUD_Idle", function()
            if mod._active then UpdateIdleFade(false) end
        end)
    end

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
    self:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player", function()
        UpdatePlayerPower(true)
        UpdateUpperRightClassPower()
        UpdateIdleFade(false)
    end)

    -- 宠物事件走独立事件帧，避免与 player/target 的 UNIT_HEALTH 在同一模块事件帧上互相覆盖
    if not petEventFrame then
        petEventFrame = CreateFrame("Frame")
        petEventFrame:SetScript("OnEvent", function(_, ev)
            if not mod._active then return end
            UpdatePetHUD(ev == "UNIT_MAXHEALTH")
        end)
    end
    pcall(petEventFrame.RegisterUnitEvent, petEventFrame, "UNIT_HEALTH", "pet")
    pcall(petEventFrame.RegisterUnitEvent, petEventFrame, "UNIT_MAXHEALTH", "pet")
    pcall(petEventFrame.RegisterUnitEvent, petEventFrame, "UNIT_POWER_UPDATE", "pet")
    pcall(petEventFrame.RegisterUnitEvent, petEventFrame, "UNIT_HAPPINESS", "pet")
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
        UpdateTopTargetHUD(true)
        UpdateUpperRightClassPower()
        SyncHiddenEUIFrames()
        UpdateIdleFade(false)
    end)
    self:RegisterUnitEvent("UNIT_TARGET", "target", UpdateTargetOfTarget)

    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if coreFrame and coreFrame._orb then coreFrame._orb._combatIcon:Show() end
        UpdateOrbAmbientGlow()
        UpdateIdleFade(false)
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if coreFrame and coreFrame._orb then coreFrame._orb._combatIcon:Hide() end
        UpdateOrbAmbientGlow()
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
        -- 读条/引导技能（如剥皮、采矿、炉石、瞄准射击）施法完成时同步触发 SUCCEEDED：绝不滞留，交由 OnCastEnd 瞬间丝滑回默认图标
        local now = GetTime()
        if orbState.castActive
            or (castGUID ~= nil and not F.IsSecret(castGUID) and castGUID == orbState.castGUID)
            or ((now - (orbState.lastCastEndTime or 0)) < 0.30)
            or (GetSpellCastTimeSafe(sid) > 0) then
            return
        end
        local sName = GetSpellNameSafe(sid)
        if IsPermanentOrAspectSpell(sid, sName) then return end
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
    self:RegisterUnitEvent("UNIT_AURA", "player", F.Debounce(0.10, UpdateCombatAuras))

    -- 无限服原生挥砍事件（驱动左上极细挥砍翼与空闲外环计时）
    self:RegisterEvent("PLAYER_SWING", function(_, _, duration, swingType)
        local dur = F.PlainNumber(duration, nil)
        local stype = F.PlainNumber(swingType, nil)
        if not dur or dur <= 0.05 then return end
        local now = GetTime()
        if SWING_ENUM and stype == SWING_ENUM.Ranged then
            swingState.rStart, swingState.rEnd, swingState.rDur = now, now + dur, dur
            swingState.activeKind = "ranged"
        elseif SWING_ENUM and stype == SWING_ENUM.OffHand then
            swingState.ohStart, swingState.ohEnd, swingState.ohDur = now, now + dur, dur
        else
            swingState.mhStart, swingState.mhEnd, swingState.mhDur = now, now + dur, dur
            swingState.activeKind = "mh"
        end
        if mod:GetDB().showUpperSwing ~= false then
            swingTicker:Show()
            SyncUpperSwingVisual()
        end
        if not orbState.castActive and now >= (orbState.lastSpellUntil or 0) then
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
        C_Timer.After(0.65, function() if mod._active then SyncHiddenEUIFrames() end end)
        C_Timer.After(1.50, function() if mod._active then SyncHiddenEUIFrames() end end)
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
    if petEventFrame then petEventFrame:UnregisterAllEvents() end
    swingTicker:Hide()
    SetOrbTimerArc(nil, nil)
    lastIdleAlpha = nil
    if coreFrame then
        if coreFrame._orb then
            if coreFrame._orb._haloAG then coreFrame._orb._haloAG:Stop() end
            if coreFrame._orb._spinAG then coreFrame._orb._spinAG:Stop() end
            if coreFrame._orb._spinAG2 then coreFrame._orb._spinAG2:Stop() end
        end
        coreFrame:Hide()
    end
    if petFrame then petFrame:Hide() end
    if topTargetFrame then topTargetFrame:Hide() end
    if euiTrailPlayer then euiTrailPlayer:SetEnabled(false) end
    if euiTrailTarget then euiTrailTarget:SetEnabled(false) end
    SyncHiddenEUIFrames()
    SyncTopRightAuraDedupe()
end

function mod:OnRefresh()
    ApplyLayoutAndTheme()
end

function mod:OnThemeChanged()
    ApplyLayoutAndTheme()
end

-- 供低血量预警模块触发血条微频警报脉冲
function mod:SetLowHealthPulse(active)
    if not (coreFrame and coreFrame._hpWing) then return end
    local ag = M.EnsurePulseAlpha(coreFrame._hpWing._bar, 0.55, 1.0, 0.72)
    if not ag then return end
    if active then
        if not ag:IsPlaying() then ag:Play() end
    else
        if ag:IsPlaying() then ag:Stop() end
        coreFrame._hpWing._bar:SetAlpha(1)
    end
end

function mod:IsOrbActive()
    return self._active == true and self:GetDB().showCoreHUD ~= false and self:GetDB().showOrb ~= false
end

function mod:GetAnchorFrame()
    return (coreFrame and coreFrame:IsShown()) and coreFrame or nil
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h

    -- 第一行：一键总开关 + 快捷一键切换新版/原版 EUI 框体按钮
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "labeledButton",
        text = "整套新版 / EUI 原版框体一键切换",
        buttonText = mod:IsEnabled() and "一键切回原版 EUI" or "一键启用新版 HUD",
        width = 148,
        tooltip = "启用新版整套 HUD 时会自动隐藏 EUI 原玩家/宠物/目标框并去重右上角增益；切回原版时即刻 100% 无损恢复全部 EUI 原生框体与右上角状态栏。",
        onClick = function()
            local nextOn = not mod:IsEnabled()
            mod:SetEnabled(nextOn)
            local EUI = _G.EllesmereUI
            if EUI and EUI.RefreshPage then pcall(EUI.RefreshPage, EUI) end
            F.Print(nextOn and "已一键启用新版核心双翼、宠物与圆角目标整套 HUD（已自动收起原 EUI 框体）。"
                or "已一键关闭新版 HUD，并无损恢复 EUI 原生玩家/宠物/目标框体与右上角状态栏。")
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "居中双翼血蓝条（自动替代 EUI 原玩家框）",
        tooltip = "开启后显示镜像圆角双翼血蓝条并自动隐藏 EUI 原玩家框；关闭即刻还原 EUI 原玩家框。",
        getValue = function() return db.showCoreHUD ~= false end,
        setValue = function(v) db.showCoreHUD = v == true; ApplyLayoutAndTheme() end,
    }, {
        type = "toggle",
        text = "独立宠物圆角框体（自动替代 EUI 原宠物框）",
        tooltip = "开启后显示独立宠物圆角框并自动隐藏 EUI 原宠物框；关闭即刻还原 EUI 原宠物框。",
        getValue = function() return db.showPetFrame ~= false end,
        setValue = function(v) db.showPetFrame = v == true; ApplyLayoutAndTheme() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "统一圆角渐变目标条（自动替代 EUI 原目标框）",
        tooltip = "开启后显示顶部统一圆角目标条 + 圆形头像 + 目标的目标，并自动隐藏 EUI 原目标与目标的目标框；关闭即刻还原。",
        getValue = function() return db.enableTopTarget ~= false end,
        setValue = function(v) db.enableTopTarget = v == true; ApplyLayoutAndTheme() end,
    }, {
        type = "toggle",
        text = "中央炫光动态技能球（双环流光+爆发光波）",
        tooltip = "施法/释放主动技能时丝滑弹性切入并绽放职业色光波（自动排除守护/姿态/炉石），外围双环反向流光+弧形计时。",
        getValue = function() return db.showOrb ~= false end,
        setValue = function(v) db.showOrb = v == true; ApplyLayoutAndTheme() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "血量 / 蓝量 / 宠物名内嵌至条内（推荐）",
        tooltip = "将双翼血蓝数值、宠物名与百分比、目标名与血量直接精致内嵌至圆角条内部，让条上方极度清爽且与上方常驻 BUFF 零遮挡。",
        getValue = function() return db.textInsideBars ~= false end,
        setValue = function(v) db.textInsideBars = v == true; ApplyLayoutAndTheme() end,
    }, {
        type = "toggle",
        text = "圆球正上方显示常驻 BUFF（方案 A·守护/姿态）",
        tooltip = "在中央能量球正上方居中显示猎人守护、姿态、光环、追踪等常驻状态（超 6 个自动 +N 折叠，脱战右键可取消）。",
        getValue = function() return db.showPermanentBuffs ~= false end,
        setValue = function(v) db.showPermanentBuffs = v == true; UpdateCombatAuras() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "圆球下方第一排：限时增益（含 +N 折叠）",
        tooltip = "紧贴中央能量球正下方居中显示战斗增益图标（超 8 个自动折叠为 +N 悬停全览，脱战右键可取消）。",
        getValue = function() return db.showCombatBuffs ~= false end,
        setValue = function(v) db.showCombatBuffs = v == true; UpdateCombatAuras() end,
    }, {
        type = "toggle",
        text = "圆球下方第二排：自身减益（含 +N 折叠）",
        tooltip = "在增益排正下方居中显示自身 Debuff（按魔法/诅咒/中毒/疾病语义色描边，无减益零占位）。",
        getValue = function() return db.showCombatDebuffs ~= false end,
        setValue = function(v) db.showCombatDebuffs = v == true; UpdateCombatAuras() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "彻底收起右上角暴雪原生增益/减益栏（方案 A）",
        tooltip = "默认开启：右上角小地图左侧彻底清空清爽，全部状态统一在双翼上下居中管理；关闭本模块即刻 100% 还原。",
        getValue = function() return db.hideTopRightBlizzAuras ~= false end,
        setValue = function(v)
            db.hideTopRightBlizzAuras = v == true
            topRightTempExpanded = false
            UpdateCombatAuras()
        end,
    }, {
        type = "toggle",
        text = "右上角保留极简 [B] 悬停展开微开关",
        tooltip = "平时低调透明（24%），打团本需要在战斗中右键取消暴雪原生 Buff 时可点一下临时展开原生栏。",
        disabled = function() return db.hideTopRightBlizzAuras == false end,
        getValue = function() return db.showTopRightMicroToggle ~= false end,
        setValue = function(v) db.showTopRightMicroToggle = v == true; SyncTopRightAuraDedupe() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "双翼下方增益（Buff）过滤类别",
        tooltip = "控制下方第一排显示的增益范围；守护/姿态/光环等常驻状态会自动归类到圆球正上方。",
        values = {
            non_permanent = "除常驻/守护外全部增益（推荐）",
            short_2m      = "仅战斗短期触发/爆发（≤2分钟）",
            short_5m      = "中短期战斗增益（≤5分钟）",
            all           = "全部限时增益",
        },
        order = { "non_permanent", "short_2m", "short_5m", "all" },
        disabled = function() return db.showCombatBuffs == false end,
        getValue = function() return db.buffFilter or "non_permanent" end,
        setValue = function(v) db.buffFilter = v; UpdateCombatAuras() end,
    }, {
        type = "toggle",
        text = "未全收起时自动去重右上角已显示增益",
        tooltip = "当关闭「彻底收起右上角」时生效：已显示在双翼下方的限时增益不会在右上角重复出现。",
        disabled = function() return db.hideTopRightBlizzAuras ~= false end,
        getValue = function() return db.dedupeTopRightAuras ~= false end,
        setValue = function(v) db.dedupeTopRightAuras = v == true; UpdateCombatAuras() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "脱战满状态柔和淡隐（默认开启）",
        tooltip = "脱战、无目标、满血满蓝且无自身减益时自动淡化核心双翼与宠物条，进战/选目标/掉血/施法瞬间恢复 100%。",
        getValue = function() return db.idleFade ~= false end,
        setValue = function(v) db.idleFade = v == true; UpdateIdleFade(false) end,
    }, {
        type = "slider",
        text = "空闲淡隐透明度",
        min = 0.20, max = 0.85, step = 0.05,
        disabled = function() return db.idleFade == false end,
        getValue = function() return F.PlainNumber(db.idleAlpha, 0.50) or 0.50 end,
        setValue = function(v) db.idleAlpha = v; UpdateIdleFade(false) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "上方左翼：武器挥砍 / 猎人自动射击条",
        tooltip = "采用无限服原生挥砍接口，猎人自动射击自动区分绿色可移动段与金色读瞄段（防卡平射）。",
        getValue = function() return db.showUpperSwing ~= false end,
        setValue = function(v) db.showUpperSwing = v == true; ApplyLayoutAndTheme() end,
    }, {
        type = "toggle",
        text = "上方右翼：连击点 / 双持副手自适应条",
        getValue = function() return db.showUpperClassPower ~= false end,
        setValue = function(v) db.showUpperClassPower = v == true; ApplyLayoutAndTheme() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "启用受击掉血延迟残影条",
        tooltip = "受击时血量瞬间下降，底层半透明残影滞留后平滑追赶（兼容 12.x 保密值战斗，不遮挡护盾与治疗预测）。",
        getValue = function() return db.showTrail ~= false end,
        setValue = function(v) db.showTrail = v == true; ApplyLayoutAndTheme() end,
    }, {
        type = "slider",
        text = "残影滞留延迟（秒）",
        min = 0.08, max = 0.35, step = 0.02,
        disabled = function() return db.showTrail == false end,
        getValue = function() return F.PlainNumber(db.trailDelay, 0.16) or 0.16 end,
        setValue = function(v) db.trailDelay = v; ApplyLayoutAndTheme() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "单翼宽度（px）",
        min = 100, max = 180, step = 4,
        getValue = function() return F.PlainNumber(db.wingWidth, 136) or 136 end,
        setValue = function(v) db.wingWidth = math_floor(v + 0.5); ApplyLayoutAndTheme() end,
    }, {
        type = "slider",
        text = "核心 HUD 整体缩放",
        min = 0.75, max = 1.35, step = 0.05,
        getValue = function() return F.PlainNumber(db.scale, 1.0) or 1.0 end,
        setValue = function(v) db.scale = v; ApplyLayoutAndTheme() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "高级：同时保留 EUI 原生框体（仅对比布局用）",
        tooltip = "默认关闭（开启新版即自动收起 EUI 原玩家/宠物/目标框体）；若想同时显示两套框体做对比或右键原框体菜单，可临时开启。",
        getValue = function() return db.keepOriginalEUI == true end,
        setValue = function(v) db.keepOriginalEUI = v == true; SyncHiddenEUIFrames() end,
    }, blank)
    y = y - h

    return y
end
