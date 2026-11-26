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
local table_concat, table_sort = table.concat, table.sort
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
        -- 双翼 / 宠物 / 目标条可点击：左键选中、右键单位菜单（安全按钮，战斗中同样可用）
        clickableHUD = true,
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

-- 猎人守护 / 姿态 / 光环等常驻法术 ID（保留在圆球正上方常驻排，不进核心圆球与双翼下方限时增益带）
local ASPECT_SPELLS = {
    [13165] = true, [14318] = true, [14319] = true, [14320] = true, [14321] = true, [14322] = true, [25296] = true, -- 雄鹰
    [13163] = true, -- 灵猴
    [5118]  = true, -- 猎豹
    [13159] = true, -- 豹群
    [13161] = true, [1299445] = true, [1299446] = true, [1299447] = true, -- 野兽（含无限服高阶）
    [20043] = true, [20190] = true, -- 自然
    [34074] = true, [415423] = true, -- 蝰蛇
    [469145] = true, -- 无限服守护
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

-- 查询暴雪姿态/形态栏当前激活项（战斗中始终非保密可读：战士姿态、德鲁伊形态、圣骑光环、盗贼潜行、牧师暗影、进姿态栏的守护）
local function GetActiveShapeshiftInfo()
    if _G.GetNumShapeshiftForms and _G.GetShapeshiftFormInfo then
        local n = F.PlainNumber(_G.GetNumShapeshiftForms(), 0) or 0
        for i = 1, n do
            local ok, icon, active, _, spellID = pcall(_G.GetShapeshiftFormInfo, i)
            if ok and active == true and icon ~= nil and not F.IsSecret(icon) then
                local sid = F.PlainNumber(spellID, nil)
                local name = sid and GetSpellNameSafe(sid) or nil
                return icon, name, sid, i
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

local UnitNameColor -- 敌对玩家红名（定义在数据刷新段）
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
local euiHiddenByUs = {}    -- key -> true：本模块确实隐藏过该 EUI 框体（停用时只还原这些）
local euiWatchRemoved = {}  -- key -> true：本模块注销过该框体的 RegisterUnitWatch

-- 右上角 BuffFrame / DebuffFrame 方案 A 收起与单图标去重状态（全程弱表零污染，停用即还原）
local wingShownInstanceIDs = {}
local wingShownIndices = {}
local wingShownIcons = {}
local dedupedAuraBtns = setmetatable({}, { __mode = "k" })
local dedupedAuraBtnList = {}
local auraAlphaGuarded = setmetatable({}, { __mode = "k" })
local trState = {
    alphaBusy = false,
    showBusy = false,
    buffDedupeHooked = false,
    buffFullMuted = false,
    buffFullGuarded = false,
    buffShowGuarded = false,
    buffHiddenByUs = false,
    debuffMuted = false,
    debuffGuarded = false,
    debuffShowGuarded = false,
    debuffHiddenByUs = false,
    tempExpanded = false,
    microBtn = nil,
    minimapHooked = false,
}

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
    ST.Hairline(sheen)
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
    ST.ApplyBarGradient(holder._bar, r1, g1, b1, r2, g2, b2, 0.98, holder._reverse)
end

local SetCombatBadge -- 战斗徽章显隐（定义在技能球段）
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
    local badge = coreFrame and coreFrame._orb and coreFrame._orb._combatIcon
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
    -- 脱战淡隐已统一到「脱战淡隐（统一开关）」：它接管时这里完全不碰透明度（两套淡隐会互相抢）；
    -- 不接管（总开关或「核心双翼」项关掉）时保持 100%，不再走下面这套独立淡隐
    local UF = F.UnifiedFade
    if UF then
        if UF.Owns("coreHUD") then
            lastIdleAlpha = nil
            return
        end
    elseif db.idleFade ~= false and not unlockOn then
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

-- 战斗中 12.x 光环可能受限（GetAuraDataByIndex 直接报错）或字段变成保密值（spellId / name / duration / auraInstanceID 不可读）：
-- 1) 未受限时记住每个 auraInstanceID 的常驻分类，并保存当前常驻 BUFF 快照与图标集；
-- 2) 战斗中扫表受限或字段保密导致顶部常驻排为空时，沿用快照 + 姿态栏（GetShapeshiftFormInfo，战斗始终可读）
--    + 施法事件（UNIT_SPELLCAST_SUCCEEDED，战斗中切守护/光环即时同步图标），避免顶部常驻 BUFF 消失。
local permState = {
    byInstance = {},
    byInstanceCount = 0,
    cached = {},
    cachedIcons = {},
    hasCleanScan = false,
}

function permState.AreAurasRestricted()
    local S = _G.C_Secrets
    if S and S.ShouldAurasBeSecret then
        local ok, sec = pcall(S.ShouldAurasBeSecret)
        if not ok or F.IsSecret(sec) or sec == true then
            return true
        end
    end
    return false
end

function permState.GetFamily(sid, nm)
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

function permState.RebuildIcons()
    for k in pairs(permState.cachedIcons) do permState.cachedIcons[k] = nil end
    for _, e in ipairs(permState.cached) do
        if e.icon ~= nil and not F.IsSecret(e.icon) then
            permState.cachedIcons[e.icon] = true
        end
    end
end

function permState.SaveCleanSnapshot(permList)
    permState.hasCleanScan = true
    local snap = {}
    for _, it in ipairs(permList) do
        local ic = (it.icon ~= nil and not F.IsSecret(it.icon)) and it.icon or nil
        if ic then
            local iid = (it.auraInstanceID ~= nil and not F.IsSecret(it.auraInstanceID)) and it.auraInstanceID or nil
            snap[#snap + 1] = {
                index = it.index,
                spellID = it.spellID,
                name = it.name,
                auraInstanceID = iid,
                icon = ic,
                applications = F.PlainNumber(it.applications, nil),
                family = permState.GetFamily(it.spellID, it.name),
                isPerm = true,
            }
        end
    end
    permState.cached = snap
    permState.RebuildIcons()
end

function permState.RecordSpellCast(sid, sName)
    if not sid or sid == 8690 then return end
    if type(sName) == "string" and (sName:find("炉石", 1, true) or sName:find("Hearthstone", 1, true)) then
        return
    end
    local ic = GetSpellIconSafe(sid)
    if not ic then return end
    local fam = permState.GetFamily(sid, sName)
    local inCombat = (_G.InCombatLockdown and _G.InCombatLockdown())
        or (_G.UnitAffectingCombat and _G.UnitAffectingCombat("player"))
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
        for i, e in ipairs(permState.cached) do
            if e.family == fam or permState.GetFamily(e.spellID, e.name) == fam then
                permState.cached[i] = entry
                replaced = true
                break
            end
        end
    else
        for i, e in ipairs(permState.cached) do
            if (e.spellID and e.spellID == sid) or (e.icon == ic) then
                permState.cached[i] = entry
                replaced = true
                break
            end
        end
    end
    if not replaced then
        permState.cached[#permState.cached + 1] = entry
    end
    permState.RebuildIcons()
    if mod._queueAuraUpdate then mod._queueAuraUpdate() end
end

function permState.BuildFallback()
    local out = {}
    for _, e in ipairs(permState.cached) do
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
        local sFam = permState.GetFamily(sSpellID, sName) or "stance"
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
        elseif not permState.hasCleanScan then
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
    if #out == 0 and not permState.hasCleanScan and F.GetPlayerClass() == "HUNTER"
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
                if okA and type(a) == "table" and not F.IsSecret(a) then
                    local ic = (a.icon ~= nil and not F.IsSecret(a.icon)) and a.icon or GetSpellIconSafe(sid)
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
        if iidKey and permState.byInstance[iidKey] ~= isPerm then
            if permState.byInstance[iidKey] == nil then
                permState.byInstanceCount = permState.byInstanceCount + 1
                if permState.byInstanceCount > 300 then
                    for k in pairs(permState.byInstance) do permState.byInstance[k] = nil end
                    permState.byInstanceCount = 1
                end
            end
            permState.byInstance[iidKey] = isPerm
        end
        return isPerm
    end
    if iidKey and permState.byInstance[iidKey] ~= nil then
        return permState.byInstance[iidKey]
    end
    if iconKey and permState.cachedIcons[iconKey] then
        if iidKey then permState.byInstance[iidKey] = true end
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
            if not aura then break end
            if F.IsSecret(aura) or type(aura) ~= "table" then
                sawSecretAura = true
            elseif aura.icon ~= nil then
                local sid = F.PlainNumber(aura.spellId, nil)
                local nm = F.PlainString(aura.name, nil)
                local dur = F.PlainNumber(aura.duration, nil)
                local durSecret = F.IsSecret(aura.duration)
                local iid = aura.auraInstanceID
                local iidKey = (iid ~= nil and not F.IsSecret(iid)) and iid or nil
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
            if not nm then break end
            if ic ~= nil then
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

    local auraRestricted = scanBlocked or permState.AreAurasRestricted()
    if not auraRestricted and not sawSecretAura then
        permState.SaveCleanSnapshot(permOut)
    elseif scanBlocked or (#permOut == 0 and (sawSecretAura or auraRestricted)) then
        permOut = permState.BuildFallback()
    elseif sawSecretAura then
        -- 战斗中已有其他常驻 BUFF 命中缓存，但新切出的守护/光环因新 instanceID + 保密图标漏掉时，补回本场战斗刚施放的常驻项
        for _, ce in ipairs(permState.cached) do
            if ce.castInCombat and ce.icon then
                local found = false
                for _, pe in ipairs(permOut) do
                    local pIc = (pe.icon ~= nil and not F.IsSecret(pe.icon)) and pe.icon or nil
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
            if not ok or not aura then break end
            if type(aura) == "table" and not F.IsSecret(aura) and aura.icon ~= nil then
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
            ST.ApplyText(reg, 9, 0.96, 0.98, 1.00, 1)
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
    slot._spellID = data.spellID
    slot._auraName = data.name
    slot._fromCache = data.fromCache == true
    slot._isDebuff = isDebuff
    slot._isPerm = isPerm == true
    pcall(slot._icon.SetTexture, slot._icon, data.icon)

    local cd = slot._cd
    local appliedCD = false
    if not isPerm then
        if data.auraInstanceID ~= nil and _G.C_UnitAuras and _G.C_UnitAuras.GetAuraDuration and cd.SetCooldownFromDurationObject then
            local okD, durObj = pcall(_G.C_UnitAuras.GetAuraDuration, "player", data.auraInstanceID)
            if okD and durObj ~= nil then
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
            ST.MaskTexture(slot, slot._bg, rad)
            ST.MaskTexture(slot, slot._icon, rad)
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
            if okT and tex ~= nil and not F.IsSecret(tex) and wingShownIcons[tex] then
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
    if c and c.GetChildren then
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

local function SyncTopRightFrameVisibility()
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
        end
    end
end

SyncTopRightAuraDedupe = function(repositionMicro)
    local db = mod:GetDB()
    local hudOn = mod._active == true and db.showCoreHUD ~= false
    -- 只有双翼确实在显示对应的增益 / 减益时，才收起或去重右上角原生栏；
    -- 否则关掉双翼的减益排后，玩家会在屏幕上任何地方都看不到减益。
    local wingShowsBuffs = db.showCombatBuffs ~= false or db.showPermanentBuffs ~= false
    local wingShowsDebuffs = db.showCombatDebuffs ~= false
    local hideTopRight = hudOn and (db.hideTopRightBlizzAuras ~= false)
    local wantFullHideOptionA = hideTopRight and (not trState.tempExpanded) and wingShowsBuffs
    local wantDebuffFullHide = hideTopRight and (not trState.tempExpanded) and wingShowsDebuffs
    local dedupeOn = hudOn and (not trState.tempExpanded) and (db.dedupeTopRightAuras ~= false)
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
        -- 注意：`A and f()` 只会保留 f 的第一个返回值，副手速度必须单独多值赋值
        local ohSpeed = nil
        if _G.UnitAttackSpeed then
            local _, oh = _G.UnitAttackSpeed("player")
            ohSpeed = F.PlainNumber(oh, nil)
        end
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
    hpText:SetPoint("LEFT", hpWing, "LEFT", 8, 0)
    hpText:SetJustifyH("LEFT")
    hpText:SetWordWrap(false)
    f._hpText = hpText

    local ppText = textLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(ppText, 11, 0.96, 0.98, 1.00, 1)
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
        isHidden = function() return not (mod._active and mod:GetDB().showCoreHUD ~= false) end,
    })

    coreFrame = f
end

----------------------------------------------------------------------
--  2) 独立宠物圆角框体（PetHUD）+ 猎人快乐度悬停提示与安全喂食网格菜单
----------------------------------------------------------------------
local FEED_PET_SPELL_ID = 6991
local petFeedMenu = nil
local petFeedButtons = {}
local petFeedCloseFrame = nil
local SyncClickLayers -- 前向声明

local function GetPetHappinessInfoSafe()
    local fn = (_G.C_PetInfo and _G.C_PetInfo.GetPetHappiness) or _G.GetPetHappiness
    if not fn then return nil end
    local ok, h, dmg, rate = pcall(fn)
    if not ok then return nil end
    return F.PlainNumber(h, nil), F.PlainNumber(dmg, nil), F.PlainNumber(rate, nil)
end

local function PetHappinessAccent(happy)
    if happy == 3 then
        return 0.36, 0.90, 0.56
    elseif happy == 2 then
        return 0.98, 0.80, 0.32
    elseif happy == 1 then
        return 0.96, 0.34, 0.38
    end
    return F.Theme.GetAccent()
end

local function BuildPetHappinessTooltipText()
    local happy, dmgPct, loyaltyRate = GetPetHappinessInfoSafe()
    if not happy then return nil end
    local lines = {}
    local stateText = (happy == 3 and (_G.PET_HAPPINESS3 or "开心"))
        or (happy == 2 and (_G.PET_HAPPINESS2 or "满足"))
        or (_G.PET_HAPPINESS1 or "不开心")
    lines[#lines + 1] = stateText
    if dmgPct then
        lines[#lines + 1] = string_format("宠物造成 %d%% 伤害", dmgPct)
    end
    local loyaltyFn = (_G.C_PetInfo and _G.C_PetInfo.GetPetLoyalty) or _G.GetPetLoyalty
    local loyalty = loyaltyFn and F.PlainString(loyaltyFn(), nil) or nil
    if loyalty and loyalty ~= "" then
        lines[#lines + 1] = loyalty
    end
    if loyaltyRate and loyaltyRate ~= 0 then
        lines[#lines + 1] = loyaltyRate > 0 and (_G.GAINING_LOYALTY or "忠诚度正在上升") or (_G.LOSING_LOYALTY or "忠诚度正在下降")
    end
    local dietFn = (_G.C_PetInfo and _G.C_PetInfo.GetPetFoodTypes) or _G.GetPetFoodTypes
    if dietFn then
        local ok, r1, r2, r3, r4, r5, r6 = pcall(dietFn)
        if ok then
            local foods = {}
            if type(r1) == "table" then
                for _, v in ipairs(r1) do
                    local s = F.PlainString(v, nil)
                    if s and s ~= "" then foods[#foods + 1] = s end
                end
            else
                for _, v in ipairs({ r1, r2, r3, r4, r5, r6 }) do
                    local s = F.PlainString(v, nil)
                    if s and s ~= "" then foods[#foods + 1] = s end
                end
            end
            if #foods > 0 then
                local delim = F.PlainString(_G.PET_FOOD_DELIMIT, "、") or "、"
                lines[#lines + 1] = "食物：" .. table_concat(foods, delim)
            end
        end
    end
    lines[#lines + 1] = "左键点击喂养宠物"
    return table_concat(lines, "\n"), happy
end

local function HidePetIconTooltip()
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.HideWidgetTooltip) == "function" then
        pcall(EUI.HideWidgetTooltip)
    end
    if _G.GameTooltip then
        _G.GameTooltip:Hide()
    end
end

local function ShowPetIconTooltip(anchor)
    local txt, happy = BuildPetHappinessTooltipText()
    if not txt then return end
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.ShowWidgetTooltip) == "function" then
        pcall(EUI.ShowWidgetTooltip, anchor, txt)
        return
    end
    if _G.GameTooltip then
        local r, g, b = PetHappinessAccent(happy)
        _G.GameTooltip:SetOwner(anchor, "ANCHOR_TOP", 0, 6)
        local first = true
        for line in txt:gmatch("[^\n]+") do
            if first then
                _G.GameTooltip:AddLine(line, r, g, b)
                first = false
            elseif line == "左键点击喂养宠物" then
                _G.GameTooltip:AddLine(line, 0.37, 0.88, 0.62)
            else
                _G.GameTooltip:AddLine(line, 0.86, 0.88, 0.92)
            end
        end
        _G.GameTooltip:Show()
    end
end

local function HidePetFeedMenu()
    if petFeedCloseFrame then
        petFeedCloseFrame:UnregisterAllEvents()
    end
    if not (petFeedMenu and petFeedMenu:IsShown()) then return end
    if InCombatLockdown and InCombatLockdown() then
        F.CombatDefer("kkowoUI_PetFeedHide", function()
            if petFeedMenu then petFeedMenu:Hide() end
        end)
        return
    end
    petFeedMenu:Hide()
end

local function ScanPetEdibleFoods()
    local foods = {}
    local byID = {}
    local CCont = _G.C_Container
    local canEat = _G.C_PetInfo and _G.C_PetInfo.CanPetEatItem
    if not (CCont and CCont.GetContainerNumSlots and CCont.GetContainerItemInfo and canEat) then
        return foods
    end
    local maxBag = _G.NUM_BAG_SLOTS or 4
    for bag = 0, maxBag do
        local slots = F.PlainNumber(CCont.GetContainerNumSlots(bag), 0) or 0
        for slot = 1, slots do
            local ok, info = pcall(CCont.GetContainerItemInfo, bag, slot)
            if ok and type(info) == "table" then
                local itemID = F.PlainNumber(info.itemID, nil)
                if itemID then
                    local okEat, edible = pcall(canEat, itemID)
                    if okEat and edible == true then
                        local cnt = F.PlainNumber(info.stackCount, 1) or 1
                        local existing = byID[itemID]
                        if existing then
                            existing.count = existing.count + cnt
                        else
                            local entry = {
                                bag = bag,
                                slot = slot,
                                itemID = itemID,
                                icon = info.iconFileID or 134400,
                                quality = F.PlainNumber(info.quality, 1) or 1,
                                count = cnt,
                            }
                            byID[itemID] = entry
                            foods[#foods + 1] = entry
                        end
                    end
                end
            end
        end
    end
    table_sort(foods, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.itemID < b.itemID
    end)
    return foods
end

local function EnsurePetFeedMenu()
    if petFeedMenu then return petFeedMenu end
    local m = CreateFrame("Frame", "kkowoUI_PetFeedMenu", _G.UIParent)
    m:SetFrameStrata("DIALOG")
    m:SetFrameLevel(80)
    m:SetClampedToScreen(true)
    m:EnableMouse(true)

    local title = m:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(title, ST.FONT.body, 0.95, 0.97, 1.00, 1)
    title:SetPoint("TOPLEFT", m, "TOPLEFT", 10, -7)
    title:SetText("喂养宠物")
    m._title = title

    local emptyFS = m:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(emptyFS, ST.FONT.caption, 0.72, 0.76, 0.82, 1)
    emptyFS:SetPoint("CENTER", m, "CENTER", 0, -9)
    emptyFS:SetText("背包中没有宠物可吃的食物")
    emptyFS:Hide()
    m._emptyFS = emptyFS

    m:SetScript("OnHide", function()
        if petFeedCloseFrame then
            petFeedCloseFrame:UnregisterAllEvents()
        end
    end)

    if not petFeedCloseFrame then
        petFeedCloseFrame = CreateFrame("Frame")
        petFeedCloseFrame:SetScript("OnEvent", function(_, ev)
            if ev == "GLOBAL_MOUSE_DOWN" then
                if petFeedMenu and petFeedMenu:IsShown() then
                    local overMenu = petFeedMenu:IsMouseOver()
                    local overBtn = petFrame and petFrame._iconBox and petFrame._iconBox:IsMouseOver()
                    if not overMenu and not overBtn then
                        HidePetFeedMenu()
                    end
                end
            elseif ev == "PLAYER_REGEN_DISABLED" or ev == "UNIT_PET" then
                HidePetFeedMenu()
            elseif ev == "BAG_UPDATE_DELAYED" then
                if petFeedMenu and petFeedMenu:IsShown() and not (InCombatLockdown and InCombatLockdown()) then
                    if petFeedMenu._rebuildFn then petFeedMenu._rebuildFn() end
                end
            end
        end)
    end

    m:Hide()
    petFeedMenu = m
    return m
end

local function AcquirePetFeedButton(index)
    local btn = petFeedButtons[index]
    if btn then return btn end
    local ok, b = pcall(CreateFrame, "Button", "kkowoUI_PetFeedBtn" .. index, petFeedMenu, "SecureActionButtonTemplate")
    if not (ok and b) then return nil end
    btn = b
    btn:SetSize(32, 32)
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetAttribute("useOnKeyDown", false)
    btn:SetAttribute("type", "spell")
    btn:SetAttribute("spell", FEED_PET_SPELL_ID)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.055, 0.075, 0.94)
    ST.MaskTexture(btn, bg, 5)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    ST.MaskTexture(btn, icon, 5)
    btn._icon = icon

    local cnt = btn:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(cnt, 10, 0.98, 0.98, 1.00, 1)
    cnt:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
    cnt:SetJustifyH("RIGHT")
    btn._count = cnt

    btn:HookScript("PostClick", function()
        HidePetFeedMenu()
    end)
    btn:SetScript("OnEnter", function(self)
        local ar, ag, ab = F.Theme.GetAccent()
        ST.ApplyRoundedBorder(self, 5, ar, ag, ab, 0.96, 4)
        if _G.GameTooltip and self._bag ~= nil and self._slot ~= nil then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT", 6, 0)
            pcall(_G.GameTooltip.SetBagItem, _G.GameTooltip, self._bag, self._slot)
            _G.GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        local r, g, bCol = self._qr or 0.28, self._qg or 0.30, self._qb or 0.36
        ST.ApplyRoundedBorder(self, 5, r, g, bCol, 0.86, 4)
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    petFeedButtons[index] = btn
    return btn
end

local function TogglePetFeedMenu(anchor)
    if not (_G.UnitExists and _G.UnitExists("pet")) then return end
    if petFeedMenu and petFeedMenu:IsShown() then
        HidePetFeedMenu()
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        if _G.UIErrorsFrame and _G.UIErrorsFrame.AddMessage then
            _G.UIErrorsFrame:AddMessage("战斗中无法打开喂食菜单。", 1, 0.30, 0.34)
        else
            F.Print("战斗中无法打开喂食菜单，请脱战后重试。")
        end
        return
    end

    HidePetIconTooltip()
    local menu = EnsurePetFeedMenu()
    local function populateMenu()
        if InCombatLockdown and InCombatLockdown() then return end
        local foods = ScanPetEdibleFoods()
        local pad = 8
        local headerH = 26
        local btnSz = 32
        local gap = 5
        local cols = 5
        local happy = GetPetHappinessInfoSafe()
        local ar, ag, ab = PetHappinessAccent(happy)
        local getQualColor = (_G.C_Item and _G.C_Item.GetItemQualityColor) or _G.GetItemQualityColor

        if #foods == 0 then
            for _, b in ipairs(petFeedButtons) do b:Hide() end
            menu._emptyFS:Show()
            menu:SetSize(188, 56)
        else
            menu._emptyFS:Hide()
            local usedCols = math_min(cols, #foods)
            local rows = math_floor((#foods - 1) / cols) + 1
            local totalW = math_max(118, pad * 2 + usedCols * btnSz + (usedCols - 1) * gap)
            local totalH = headerH + pad + rows * btnSz + (rows - 1) * gap
            menu:SetSize(totalW, totalH)
            for i, food in ipairs(foods) do
                local btn = AcquirePetFeedButton(i)
                if btn then
                    local col = (i - 1) % cols
                    local row = math_floor((i - 1) / cols)
                    btn:ClearAllPoints()
                    btn:SetPoint("TOPLEFT", menu, "TOPLEFT", pad + col * (btnSz + gap), -(headerH + row * (btnSz + gap)))
                    btn._bag = food.bag
                    btn._slot = food.slot
                    btn:SetAttribute("target-bag", food.bag)
                    btn:SetAttribute("target-slot", food.slot)
                    btn._icon:SetTexture(food.icon)
                    if food.count and food.count > 1 then
                        btn._count:SetText(tostring(food.count))
                        btn._count:Show()
                    else
                        btn._count:Hide()
                    end
                    local qr, qg, qb = 0.32, 0.36, 0.42
                    if getQualColor and food.quality >= 1 then
                        local okQ, r, g, bCol = pcall(getQualColor, food.quality)
                        if okQ and F.PlainNumber(r, nil) then
                            qr, qg, qb = r * 0.78 + 0.12, g * 0.78 + 0.12, bCol * 0.78 + 0.12
                        end
                    end
                    btn._qr, btn._qg, btn._qb = qr, qg, qb
                    ST.ApplyRoundedBorder(btn, 5, qr, qg, qb, 0.86, 4)
                    btn:Show()
                end
            end
            for i = #foods + 1, #petFeedButtons do
                petFeedButtons[i]:Hide()
            end
        end
        F.Theme.PaintPrettyCardOverlay(menu, ar, ag, ab, headerH - 2, {
            alpha = 0.90,
            haloAlpha = 0.14,
            haloSpread = 10,
            headerTopAlpha = 0.24,
            headerBottomAlpha = 0.00,
        })
    end

    menu._rebuildFn = populateMenu
    populateMenu()

    -- 通过 UIParent 屏幕坐标定位（绝不直接锚定到宠物普通框体，避免内部安全喂食按钮在战斗期牵连定位保护）
    menu:ClearAllPoints()
    local l = anchor.GetLeft and F.PlainNumber(anchor:GetLeft(), nil)
    local t = anchor.GetTop and F.PlainNumber(anchor:GetTop(), nil)
    local es = anchor.GetEffectiveScale and F.PlainNumber(anchor:GetEffectiveScale(), 1) or 1
    local uiS = _G.UIParent and F.PlainNumber(_G.UIParent:GetEffectiveScale(), 1) or 1
    if l and t and es > 0 and uiS > 0 then
        local k = es / uiS
        menu:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", l * k, t * k + 8)
    else
        menu:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 8)
    end
    menu:Show()
    if petFeedCloseFrame then
        pcall(petFeedCloseFrame.RegisterEvent, petFeedCloseFrame, "GLOBAL_MOUSE_DOWN")
        pcall(petFeedCloseFrame.RegisterEvent, petFeedCloseFrame, "BAG_UPDATE_DELAYED")
        pcall(petFeedCloseFrame.RegisterEvent, petFeedCloseFrame, "PLAYER_REGEN_DISABLED")
        pcall(petFeedCloseFrame.RegisterUnitEvent, petFeedCloseFrame, "UNIT_PET", "player")
    end
end

local function BuildPetHUD()
    if petFrame then return end
    local f = CreateFrame("Frame", "kkowoUI_PetHUD", _G.UIParent)
    f:SetSize(156, 36)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(12)
    f:EnableMouse(false)

    -- 左侧宠物快乐度/头像圆角徽章（猎人可点击打开喂食网格，层高于点击选中层）
    local iconBox = CreateFrame("Frame", nil, f)
    iconBox:SetSize(22, 22)
    iconBox:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    iconBox:SetFrameLevel(f:GetFrameLevel() + 12)
    local isHunter = (F.GetPlayerClass() == "HUNTER")
    iconBox:EnableMouse(isHunter)
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
    if isHunter then
        iconBox:SetScript("OnEnter", function(self)
            local happy = GetPetHappinessInfoSafe()
            local r, g, b = PetHappinessAccent(happy)
            ST.ApplyRoundedBorder(self, 5, r, g, b, 0.96, 4)
            ShowPetIconTooltip(self)
        end)
        iconBox:SetScript("OnLeave", function(self)
            ST.ApplyRoundedBorder(self, 5, 0.02, 0.022, 0.03, 0.95, 4)
            HidePetIconTooltip()
        end)
        iconBox:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and (not self.IsMouseOver or self:IsMouseOver()) then
                TogglePetFeedMenu(self)
            end
        end)
    end
    f._iconBox = iconBox

    local hpBar = CreateWingBar(f, 130, 16, false)
    hpBar:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 4, 0)
    hpBar._trail = M.AttachHealthTrail(hpBar._bar, {
        delay = 0.16, reverse = false, color = ST.COLORS.trail,
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
    ST.ApplyText(nameFS, 10, 0.96, 0.98, 1.00, 1)
    nameFS:SetShadowOffset(1, -1)
    nameFS:SetPoint("LEFT", hpBar, "LEFT", 6, 0)
    nameFS:SetWidth(76)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    f._nameText = nameFS

    local hpFS = petTextLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(hpFS, 10, 0.96, 0.98, 1.00, 1)
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
        delay = 0.16, reverse = false, color = ST.COLORS.trail,
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
    ST.ApplyText(hpText, 11, 0.98, 0.99, 1.00, 1)
    hpText:SetShadowOffset(1, -1)
    hpText:SetPoint("LEFT", hpBar, "LEFT", 8, 0)
    hpText:SetJustifyH("LEFT")
    hpText:SetWordWrap(false)
    f._hpText = hpText

    local nameText = targetTextLayer:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(nameText, 11, 0.98, 0.99, 1.00, 1)
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
    -- 名字必须挂在小血条上：挂在目标条本体上时，小血条隐藏后名字仍残留上一次的内容（总显示「风蛇」）
    local totName = totBar:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(totName, 10, 0.90, 0.92, 0.96, 1)
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
        HidePetFeedMenu()
        petFrame:Hide()
        return
    end
    local wasShown = petFrame:IsShown()
    petFrame:Show()
    if not wasShown then
        if lastIdleAlpha then petFrame:SetAlpha(lastIdleAlpha) end
        if SyncClickLayers then SyncClickLayers() end
    end
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

-- 敌对阵营玩家显示红名（与怪物区分）；其余单位保持传入的默认文字色
UnitNameColor = function(unit, r, g, b)
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

local function UpdateTargetOfTarget()
    if not (topTargetFrame and topTargetFrame._totBar) then return end
    local tot = topTargetFrame._totBar
    if not (_G.UnitExists and _G.UnitExists("targettarget")) then
        tot._nameText:SetText("")
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
    local rawName = _G.UnitName and _G.UnitName("targettarget")
    local nm = F.PlainString(rawName, nil)
    if nm then
        tot._nameText:SetText(nm)
    elseif type(rawName) ~= "nil" then
        pcall(tot._nameText.SetText, tot._nameText, rawName)
    else
        tot._nameText:SetText("")
    end
    tot._nameText:SetTextColor(UnitNameColor("targettarget", 0.90, 0.92, 0.96))
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
            UpdateBarSparkVis(topTargetFrame._hpBar, hp, mx)
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
                topTargetFrame._nameText:SetText(lvlStr ~= "" and (tName .. " · " .. lvlStr) or tName)
            elseif type(rawName) ~= "nil" then
                pcall(topTargetFrame._nameText.SetText, topTargetFrame._nameText, rawName)
            end
            topTargetFrame._nameText:SetTextColor(UnitNameColor("target", 0.98, 0.99, 1.00))

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
            if not alphaGuardBusy and hiddenEUI[key] and F.PlainNumber(a, 1) ~= 0 then
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
    -- 还原只发生在「由隐藏转为显示」的那一刻：平时绝不把 EUI 自己的淡隐 / 距离透明度反复拉回 1
    for key, hide in pairs(wantHide) do
        local fr = GetEUIUnitFrame(key)
        local wasHidden = hiddenEUI[key] == true
        hiddenEUI[key] = hide == true
        if fr then
            local targetObj = fr._visWrap or fr
            if hide then
                EnsureEUIAlphaGuard(fr, key)
                if targetObj ~= fr then EnsureEUIAlphaGuard(targetObj, key) end
                alphaGuardBusy = true
                pcall(fr.SetAlpha, fr, 0)
                if targetObj ~= fr then pcall(targetObj.SetAlpha, targetObj, 0) end
                alphaGuardBusy = false
            elseif wasHidden or euiHiddenByUs[key] then
                alphaGuardBusy = true
                pcall(fr.SetAlpha, fr, 1)
                if targetObj ~= fr then pcall(targetObj.SetAlpha, targetObj, 1) end
                alphaGuardBusy = false
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
                    alphaGuardBusy = true
                    pcall(fr.SetAlpha, fr, 0)
                    alphaGuardBusy = false
                elseif euiHiddenByUs[key] then
                    euiHiddenByUs[key] = nil
                    if fr.EnableMouse then pcall(fr.EnableMouse, fr, true) end
                    alphaGuardBusy = true
                    pcall(fr.SetAlpha, fr, 1)
                    if fr._visWrap and fr._visWrap ~= fr then pcall(fr._visWrap.SetAlpha, fr._visWrap, 1) end
                    alphaGuardBusy = false
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
        if coreFrame and coreFrame:IsShown() then return coreFrame._hpWing, coreFrame._ppWing end
    elseif key == "pet" then
        -- 猎人左侧宠物快乐度按钮独立承担点击喂食，点击选中层只覆盖右侧血蓝条
        if petFrame and F.GetPlayerClass() == "HUNTER" and petFrame._hpBar and petFrame._ppBar then
            return petFrame._hpBar, petFrame._ppBar
        end
        return petFrame
    elseif key == "target" then
        return topTargetFrame
    elseif key == "targettarget" then
        if topTargetFrame and topTargetFrame._totBar then
            return topTargetFrame._totBar, topTargetFrame._totBar._nameText
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

SyncClickLayers = function()
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
                ST.ApplyText(coreFrame._hpText, inFontSz, 0.98, 0.99, 1.00, 1)
                ST.ApplyText(coreFrame._ppText, inFontSz, 0.96, 0.98, 1.00, 1)
                coreFrame._hpText:SetPoint("LEFT", coreFrame._hpWing, "LEFT", 8, 0)
                coreFrame._ppText:SetPoint("RIGHT", coreFrame._ppWing, "RIGHT", -8, 0)
                coreFrame._hpText:SetWidth(math_max(48, wingW - orbHalfGap - 8))
                coreFrame._ppText:SetWidth(math_max(40, wingW - orbHalfGap - 8))
            else
                ST.ApplyText(coreFrame._hpText, 12, 0.96, 0.97, 0.99, 1)
                ST.ApplyText(coreFrame._ppText, 12, 0.94, 0.96, 0.99, 1)
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
            SetCombatBadge(inCombat == true, false)

            UpdatePlayerHealth(true)
            UpdatePlayerPower(true)
            UpdateUpperRightClassPower()
            UpdateOrbAppearance(false)
            UpdateCombatAuras()
        else
            swingTicker:Hide()
            SyncTopRightAuraDedupe(true)
        end
    end
    if euiTrailPlayer then
        euiTrailPlayer:SetDelay(db.trailDelay or 0.16)
        euiTrailPlayer:SetEnabled(mod._active and db.enhanceEUIFrames ~= false and db.showTrail ~= false)
        if mod._active and db.enhanceEUIFrames ~= false and db.showTrail ~= false then
            euiTrailPlayer:UpdateFromUnit("player", true)
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
            ST.ApplyText(petFrame._nameText, 10, 0.96, 0.98, 1.00, 1)
            ST.ApplyText(petFrame._hpText, 10, 0.96, 0.98, 1.00, 1)
            petFrame._nameText:SetPoint("LEFT", petFrame._hpBar, "LEFT", 6, 0)
            petFrame._nameText:SetWidth(76)
            petFrame._hpText:SetPoint("RIGHT", petFrame._hpBar, "RIGHT", -6, 0)
        else
            ST.ApplyText(petFrame._nameText, 11, 0.92, 0.95, 0.98, 1)
            ST.ApplyText(petFrame._hpText, 11, 0.94, 0.96, 0.99, 1)
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
            ST.ApplyText(topTargetFrame._hpText, 11, 0.98, 0.99, 1.00, 1)
            ST.ApplyText(topTargetFrame._nameText, 11, 0.98, 0.99, 1.00, 1)
            topTargetFrame._hpText:SetPoint("LEFT", topTargetFrame._hpBar, "LEFT", 8, 0)
            topTargetFrame._nameText:SetPoint("RIGHT", topTargetFrame._hpBar, "RIGHT", -10, 0)
            topTargetFrame._nameText:SetWidth(148)
        else
            ST.ApplyText(topTargetFrame._hpText, 12, 0.97, 0.97, 0.99, 1)
            ST.ApplyText(topTargetFrame._nameText, 12, 0.97, 0.97, 0.99, 1)
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
    if euiTrailTarget then euiTrailTarget:SetDelay(db.trailDelay or 0.16) end
    SyncHiddenEUIFrames()
    SyncTopRightAuraDedupe(true)
    SyncClickLayers()
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
            if mod._active then
                UpdateIdleFade(false)
                SyncClickLayers() -- 解锁模式拖动 HUD 后，点击层跟随新位置
            end
        end)
    end
    self:RegisterEvent("UI_SCALE_CHANGED", function() SyncClickLayers() end)
    self:RegisterEvent("DISPLAY_SIZE_CHANGED", function() SyncClickLayers() end)

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
            permState.RecordSpellCast(sid, sName)
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
        if mod:GetDB().showUpperSwing ~= false and coreFrame and coreFrame:IsShown() then
            swingTicker:Show()
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
    if petEventFrame then petEventFrame:UnregisterAllEvents() end
    swingTicker:Hide()
    self:SetLowHealthPulse(false)
    SetOrbTimerArc(nil, nil)
    lastIdleAlpha = nil
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
    permState.cached = {}
    permState.hasCleanScan = false
    permState.RebuildIcons()
    if coreFrame then
        if coreFrame._orb then
            if coreFrame._orb._haloAG then coreFrame._orb._haloAG:Stop() end
            if coreFrame._orb._spinAG then coreFrame._orb._spinAG:Stop() end
            if coreFrame._orb._spinAG2 then coreFrame._orb._spinAG2:Stop() end
        end
        coreFrame:Hide()
    end
    HidePetFeedMenu()
    if petFrame then petFrame:Hide() end
    if topTargetFrame then topTargetFrame:Hide() end
    if euiTrailPlayer then euiTrailPlayer:SetEnabled(false) end
    if euiTrailTarget then euiTrailTarget:SetEnabled(false) end
    SyncHiddenEUIFrames()
    SyncTopRightAuraDedupe()
    SyncClickLayers()
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
            if EUI and EUI.RefreshPage then pcall(EUI.RefreshPage, EUI, true) end
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
        text = "彻底收起右上角暴雪原生增益/减益栏",
        tooltip = "默认开启：右上角小地图左侧彻底清空清爽，全部状态统一在双翼上下居中管理；关闭本模块即刻 100% 还原。",
        getValue = function() return db.hideTopRightBlizzAuras ~= false end,
        setValue = function(v)
            db.hideTopRightBlizzAuras = v == true
            trState.tempExpanded = false
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
        text = "脱战时淡隐核心双翼与宠物条",
        tooltip = "已并入「现代视觉与性能 → 沉浸与系统栏 → 脱战淡隐（统一开关）」：透明度、触发条件与其它框体一致，总开关关掉时这里也不淡隐。",
        disabled = function()
            local um = F.Modules.Get("immersiveHUD")
            return not (um and um:IsEnabled())
        end,
        getValue = function()
            local um = F.Modules.Get("immersiveHUD")
            return um ~= nil and um:GetDB().fadeCoreHUD ~= false
        end,
        setValue = function(v)
            local um = F.Modules.Get("immersiveHUD")
            if not um then return end
            um:GetDB().fadeCoreHUD = v == true
            um:Refresh()
            UpdateIdleFade(false)
        end,
    }, blank)
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
    }, {
        type = "toggle",
        text = "双翼 / 宠物 / 目标条可点击（左键选中、右键菜单）",
        tooltip = "原 EUI 框体收起后，用安全按钮让新版血条、宠物条、目标条与目标的目标都能左键选中、右键打开单位菜单（战斗中同样可用）。关闭后这些条完全鼠标穿透。",
        getValue = function() return db.clickableHUD ~= false end,
        setValue = function(v) db.clickableHUD = v == true; SyncClickLayers() end,
    })
    y = y - h

    return y
end
