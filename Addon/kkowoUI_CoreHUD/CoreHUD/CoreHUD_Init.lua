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
local _G = _G
local F = _G.kkowoUI
if not F then return end
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

local CH = {}
F._CoreHUD = CH

local mod = F.RegisterModule("coreHUD", {
    title = "双翼与目标",
    desc = "启用双翼血蓝条、宠物条与顶部目标条，关闭即恢复 EUI 头像。",
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
        -- 双翼血/蓝文字格式（默认镜像靠内：左「血量百分比 | 血量」，右「蓝量 | 蓝量百分比」，数字贴近中央图标侧）
        wingTextFormat = "mirror",  -- "mirror" | "num_pct" | "pct_num" | "mirror_outer" | "num" | "pct"
        wingTextAnchor = "inner",   -- "inner" | "center" | "outer"
        v5MirrorDefaultMigrated = false,
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

local function AbbreviateSafe(val, valueType)
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.AbbreviateValue) == "function" then
        local ok, s = pcall(EUI.AbbreviateValue, val, valueType or "health")
        if ok and type(s) ~= "nil" then return s end
    end
    if _G.AbbreviateNumbers then
        local ok, s = pcall(_G.AbbreviateNumbers, val)
        if ok and type(s) ~= "nil" then return s end
    end
    local p = F.PlainNumber(val, nil)
    if p then return F.FormatShortNumber(p) end
    return val
end

local function ResolveWingTextModes()
    local fmt = mod:GetDB().wingTextFormat or "mirror"
    if fmt == "mirror" then
        -- 数值靠近中央图标侧：左翼「血量百分比 | 血量」，右翼「蓝量 | 蓝量百分比」；单条目标框沿用「数字 | 百分比」
        return "pct_num", "num_pct", "num_pct"
    elseif fmt == "mirror_outer" then
        -- 百分比靠近中央图标侧：左翼「血量 | 血量百分比」，右翼「蓝量百分比 | 蓝量」
        return "num_pct", "pct_num", "num_pct"
    elseif fmt == "pct_num" or fmt == "num" or fmt == "pct" then
        return fmt, fmt, fmt
    end
    return "num_pct", "num_pct", "num_pct"
end

local function UnitExistsSafe(unit)
    if not _G.UnitExists then return false end
    local ok, ex = pcall(_G.UnitExists, unit)
    return ok and (not F.IsSecret(ex)) and ex == true
end

local function SetHealthText(fs, unit, mode)
    if not fs then return end
    if not UnitExistsSafe(unit) then
        fs:SetText("")
        return
    end
    local m = (mode == true and "pct") or (type(mode) == "string" and mode) or "num_pct"
    if _G.UnitIsDead then
        local okD, dead = pcall(_G.UnitIsDead, unit)
        if okD and not F.IsSecret(dead) and dead == true then
            if m == "pct" then
                fs:SetText("0%")
            elseif m == "num" then
                fs:SetText("死亡")
            elseif m == "pct_num" then
                fs:SetText("0% | 死亡")
            else
                fs:SetText("死亡 | 0%")
            end
            return
        end
    end
    local hp = _G.UnitHealth and _G.UnitHealth(unit)
    local mx = _G.UnitHealthMax and _G.UnitHealthMax(unit)
    local pHp = F.PlainNumber(hp, nil)
    local pMx = F.PlainNumber(mx, nil)
    if pHp and pMx and pMx > 0 then
        local pct = math_floor(pHp / pMx * 100 + 0.5)
        if m == "pct" then
            fs:SetFormattedText("%d%%", pct)
        elseif m == "num" then
            fs:SetFormattedText("%s", AbbreviateSafe(pHp, "health"))
        elseif m == "pct_num" then
            fs:SetFormattedText("%d%% | %s", pct, AbbreviateSafe(pHp, "health"))
        else
            fs:SetFormattedText("%s | %d%%", AbbreviateSafe(pHp, "health"), pct)
        end
        return
    end
    -- 12.x 保密值 C 端安全通路：直接由 C 端格式化，绝不在 Lua 中对保密值做运算或分支
    if m == "num" then
        if type(hp) ~= "nil" then
            pcall(fs.SetFormattedText, fs, "%s", AbbreviateSafe(hp, "health"))
        end
        return
    end
    if _G.UnitHealthPercent then
        local okP, pct
        if SCALE_TO_100 ~= nil then
            okP, pct = pcall(_G.UnitHealthPercent, unit, true, SCALE_TO_100)
        else
            okP, pct = pcall(_G.UnitHealthPercent, unit)
        end
        if okP and type(pct) ~= "nil" then
            if m == "pct" then
                if pcall(fs.SetFormattedText, fs, "%d%%", pct) then return end
            elseif type(hp) ~= "nil" then
                local hpStr = AbbreviateSafe(hp, "health")
                if m == "pct_num" then
                    if pcall(fs.SetFormattedText, fs, "%d%% | %s", pct, hpStr) then return end
                else
                    if pcall(fs.SetFormattedText, fs, "%s | %d%%", hpStr, pct) then return end
                end
            end
            if pcall(fs.SetFormattedText, fs, "%d%%", pct) then return end
        end
    end
    if type(hp) ~= "nil" then
        pcall(fs.SetFormattedText, fs, "%s", AbbreviateSafe(hp, "health"))
    end
end

local function SetPowerText(fs, unit, powerType, mode)
    if not fs then return end
    if not UnitExistsSafe(unit) then
        fs:SetText("")
        return
    end
    local m = (type(mode) == "string" and mode) or "num_pct"
    -- 怒气/能量/集中等上限通常为 100，默认仅显示数值避免冗余 "80 | 80%"；法力（蓝）完整显示数字与百分比
    local effMode = (powerType == 0) and m or ((m == "pct") and "pct" or "num")
    local cur = _G.UnitPower and _G.UnitPower(unit, powerType)
    local mx = _G.UnitPowerMax and _G.UnitPowerMax(unit, powerType)
    local pCur = F.PlainNumber(cur, nil)
    local pMx = F.PlainNumber(mx, nil)
    if pCur and pMx then
        if pMx <= 0 then
            fs:SetText("")
            return
        end
        local pct = math_floor(pCur / pMx * 100 + 0.5)
        if effMode == "pct" then
            fs:SetFormattedText("%d%%", pct)
        elseif effMode == "num" then
            if powerType == 0 then
                fs:SetFormattedText("%s", AbbreviateSafe(pCur, "power"))
            else
                fs:SetFormattedText("%d", math_floor(pCur + 0.5))
            end
        elseif effMode == "pct_num" then
            fs:SetFormattedText("%d%% | %s", pct, AbbreviateSafe(pCur, "power"))
        else
            fs:SetFormattedText("%s | %d%%", AbbreviateSafe(pCur, "power"), pct)
        end
        return
    end
    -- 12.x 保密值 C 端安全通路
    if effMode == "num" then
        if type(cur) ~= "nil" then
            if powerType == 0 then
                pcall(fs.SetFormattedText, fs, "%s", AbbreviateSafe(cur, "power"))
            else
                pcall(fs.SetFormattedText, fs, "%d", cur)
            end
        end
        return
    end
    if _G.UnitPowerPercent then
        local okP, pct
        if SCALE_TO_100 ~= nil then
            okP, pct = pcall(_G.UnitPowerPercent, unit, powerType, true, SCALE_TO_100)
        else
            okP, pct = pcall(_G.UnitPowerPercent, unit, powerType)
        end
        if okP and type(pct) ~= "nil" then
            if effMode == "pct" then
                if pcall(fs.SetFormattedText, fs, "%d%%", pct) then return end
            elseif type(cur) ~= "nil" then
                local ppStr = AbbreviateSafe(cur, "power")
                if effMode == "pct_num" then
                    if pcall(fs.SetFormattedText, fs, "%d%% | %s", pct, ppStr) then return end
                else
                    if pcall(fs.SetFormattedText, fs, "%s | %d%%", ppStr, pct) then return end
                end
            end
            if pcall(fs.SetFormattedText, fs, "%d%%", pct) then return end
        end
    end
    if type(cur) ~= "nil" then
        if powerType == 0 then
            pcall(fs.SetFormattedText, fs, "%s", AbbreviateSafe(cur, "power"))
        else
            pcall(fs.SetFormattedText, fs, "%d", cur)
        end
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
CH.coreFrame = nil
CH.petFrame = nil
CH.topTargetFrame = nil
CH.petEventFrame = nil

CH.UnitNameColor = CH.UnitNameColor

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
CH.alphaGuardBusy = false
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

CH.euiTrailPlayer = nil
CH.euiTrailTarget = nil
CH.euiHooksDone = false


CH.mod = mod
CH.SWING_ENUM = SWING_ENUM
CH.AIM_CLASSES = AIM_CLASSES
CH.AIM_TIME = AIM_TIME
CH.ASPECT_SPELLS = ASPECT_SPELLS
CH.DEBUFF_TYPE_COLORS = DEBUFF_TYPE_COLORS
CH.IsPermanentOrAspectSpell = IsPermanentOrAspectSpell
CH.GetSpellNameSafe = GetSpellNameSafe
CH.GetSpellCastTimeSafe = GetSpellCastTimeSafe
CH.GetSpellCooldownSafe = GetSpellCooldownSafe
CH.GetSpellIconSafe = GetSpellIconSafe
CH.GetClassCrestIcon = GetClassCrestIcon
CH.GetActiveShapeshiftInfo = GetActiveShapeshiftInfo
CH.UnitExistsSafe = UnitExistsSafe
CH.ResolveWingTextModes = ResolveWingTextModes
CH.SetHealthText = SetHealthText
CH.SetPowerText = SetPowerText
CH.swingState = swingState
CH.orbState = orbState
CH.hiddenEUI = hiddenEUI
CH.alphaGuardedEUI = alphaGuardedEUI
CH.euiHiddenByUs = euiHiddenByUs
CH.euiWatchRemoved = euiWatchRemoved
CH.wingShownInstanceIDs = wingShownInstanceIDs
CH.wingShownIndices = wingShownIndices
CH.wingShownIcons = wingShownIcons
CH.dedupedAuraBtns = dedupedAuraBtns
CH.dedupedAuraBtnList = dedupedAuraBtnList
CH.auraAlphaGuarded = auraAlphaGuarded
CH.trState = trState
