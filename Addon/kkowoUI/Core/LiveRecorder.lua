----------------------------------------------------------------------
--  kkowoUI — Core/LiveRecorder.lua
--  常驻只读实机事件/API 录制器（为离线回放校准 mock 提供真实游戏数据）
--  设计原则：
--    • 登录即常驻加载（绝不放在 LoD 的 kkowoUI_Options 里），不修改任何框体
--    • 绝不注册 COMBAT_LOG_EVENT_UNFILTERED（无限服禁止）
--    • 绝不在 OnUpdate 逐帧记录；战斗中仅 O(1) 环形缓冲追加，零字符串拼接
--    • 严格区分「零返回值 (n=0)」与「返回 nil (n=1, t="nil")」（坑 K2）
--    • 所有 API 包 pcall，机密值只记 { t, s=true }，绝不比较/运算/当表键（坑 K3/K4）
--    • 不存其他玩家名与 Player/BNet GUID；仅保留物品名、法术名、副本名与类型
--    • 「只录一次、按需再开」：首次部署自动待录一次，进本开录，离本即停并退出待录
----------------------------------------------------------------------
local _, F = ...
if not F then return end

local _G = _G
local ipairs, pairs, pcall, select, tonumber, tostring, type =
    ipairs, pairs, pcall, select, tonumber, tostring, type
local math_floor, math_min = math.floor, math.min
local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown

local REC = {}
F.Recorder = REC

local SCHEMA_VERSION = 2
local AUTO_ARM_KEY = "v1_initial"
local AUTO_ARM_KEY_V2 = "v2_motion_fx"
local MAX_SESSION_ENTRIES = 1200
local MAX_TOTAL_ENTRIES = 2000
local MAX_SESSIONS = 4

local COMBAT_INSTANCE_TYPES = {
    party = true,
    raid = true,
    scenario = true,
    pvp = true,
    arena = true,
}

-- 供后续任务扩展录制事件与自动重武装标记（不破坏 v1 结构）
local EXTRA_EVENTS = {}
local EXTRA_UNIT_EVENTS = {}
local EXTRA_HOOKS = {}

local function NowStamp()
    if _G.date then
        local ok, s = pcall(_G.date, "%Y-%m-%d %H:%M:%S")
        if ok and type(s) == "string" then return s end
    end
    return tostring(math_floor(GetTime()))
end

local function IsSafeFrame(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function SafeFrameBool(obj, method)
    if not (obj and type(obj[method]) == "function") then return nil, false end
    local ok, val = pcall(obj[method], obj)
    if not ok then return nil, false end
    if F.IsSecret(val) then return nil, true end
    return val == true, false
end

local function SafeFrameNum(obj, method)
    if not (obj and type(obj[method]) == "function") then return nil, false end
    local ok, val = pcall(obj[method], obj)
    if not ok then return nil, false end
    if F.IsSecret(val) then return nil, true end
    return type(val) == "number" and val or nil, false
end

local function SafeFrameStr(obj, method)
    if not (obj and type(obj[method]) == "function") then return nil, false end
    local ok, val = pcall(obj[method], obj)
    if not ok then return nil, false end
    if F.IsSecret(val) then return nil, true end
    return type(val) == "string" and val or nil, false
end

-- 安全序列化单个返回值（绝不对机密值做任何比较/拼接/运算/表键）
-- kind: "redact" = 明确丢弃原文（如玩家名/GUID）；nil = 允许安全标量
local function PackValue(val, redact)
    local vt = type(val)
    local sec = F.IsSecret(val)
    if sec then
        return { t = vt, s = true }
    end
    if vt == "nil" then
        return { t = "nil", s = false }
    elseif vt == "number" or vt == "boolean" then
        return { t = vt, s = false, v = val }
    elseif vt == "string" then
        if redact then
            return { t = "string", s = false, v = "<redacted>" }
        end
        return { t = "string", s = false, v = val }
    elseif vt == "table" then
        return { t = "table", s = false }
    end
    return { t = vt, s = false }
end

-- 严格记录参数个数 n（区分 0 返回值与 1 个 nil 返回值）
local function PackTuple(redactIdxMap, ...)
    local n = select("#", ...)
    local items = {}
    for i = 1, n do
        local redact = redactIdxMap and redactIdxMap[i] == true
        items[i] = PackValue(select(i, ...), redact)
    end
    return { n = n, v = items }
end

local function PackPcallResult(redactIdxMap, ok, ...)
    if not ok then
        return { ok = false, n = 0, v = {} }
    end
    local packed = PackTuple(redactIdxMap, ...)
    packed.ok = true
    return packed
end

local function CaptureAPI(fn, redactIdxMap, ...)
    if type(fn) ~= "function" then
        return { ok = false, missing = true, n = 0, v = {} }
    end
    return PackPcallResult(redactIdxMap, pcall(fn, ...))
end

local function ReadInstanceInfoSafe()
    local inInst, instType, instSec = false, "none", false
    if type(_G.IsInInstance) == "function" then
        local ok, f, t = pcall(_G.IsInInstance)
        if ok then
            if F.IsSecret(f) or F.IsSecret(t) then
                instSec = true
            else
                inInst = (f == true)
                if type(t) == "string" then instType = t end
            end
        end
    end
    local instName, instID = nil, nil
    if type(_G.GetInstanceInfo) == "function" then
        local ok, nm, typ, _, _, _, _, _, id = pcall(_G.GetInstanceInfo)
        if ok then
            if not F.IsSecret(nm) and type(nm) == "string" then instName = nm end
            if instType == "none" and not F.IsSecret(typ) and type(typ) == "string" then
                instType = typ
                if COMBAT_INSTANCE_TYPES[instType] then inInst = true end
            end
            if not F.IsSecret(id) and type(id) == "number" then instID = id end
        end
    end
    local isCombatInst = inInst and COMBAT_INSTANCE_TYPES[instType] == true
    return isCombatInst, inInst, instType, instName, instID, instSec
end

local function CaptureContext()
    local _, inInst, instType, instName, instID, instSec = ReadInstanceInfoSafe()
    local inCombat = (InCombatLockdown and InCombatLockdown()) == true
    local grpType = "solo"
    local isRaid = false
    if type(_G.IsInRaid) == "function" then
        local ok, r = pcall(_G.IsInRaid)
        if ok and not F.IsSecret(r) and r == true then
            isRaid = true
            grpType = "raid"
        end
    end
    if not isRaid and type(_G.IsInGroup) == "function" then
        local ok, g = pcall(_G.IsInGroup)
        if ok and not F.IsSecret(g) and g == true then
            grpType = "party"
        end
    end
    local grpN = 0
    if type(_G.GetNumGroupMembers) == "function" then
        local ok, n = pcall(_G.GetNumGroupMembers)
        if ok and not F.IsSecret(n) and type(n) == "number" then
            grpN = n
        end
    end
    return {
        t = GetTime(),
        inst = inInst,
        instType = instType,
        instName = instName,
        instID = instID,
        instSec = instSec,
        combat = inCombat,
        grp = grpType,
        grpN = grpN,
    }
end

----------------------------------------------------------------------
--  SavedVariables 初始化与环形缓冲
----------------------------------------------------------------------
local function EnsureDB()
    if type(_G.kkowoUIRecordDB) ~= "table" then
        _G.kkowoUIRecordDB = {}
    end
    local db = _G.kkowoUIRecordDB
    db.schemaVersion = SCHEMA_VERSION
    if type(db.autoArmFlags) ~= "table" then db.autoArmFlags = {} end
    if type(db.sessions) ~= "table" then db.sessions = {} end
    if db.armed == nil then db.armed = false end
    if db.recording == nil then db.recording = false end
    return db
end

-- O(1) 环形缓冲追加（战斗中零 table.remove 搬移、零字符串拼接）
local function PushEntry(entry)
    local db = EnsureDB()
    local sess = db.currentSession
    if type(sess) ~= "table" then return end
    if type(sess.ring) ~= "table" then
        sess.ring = {}
        sess.head = 1
        sess.count = 0
        sess.dropped = 0
        sess.seq = 0
    end
    local cap = MAX_SESSION_ENTRIES
    sess.seq = (sess.seq or 0) + 1
    entry.seq = sess.seq
    if sess.count < cap then
        local idx = ((sess.head - 1 + sess.count) % cap) + 1
        sess.ring[idx] = entry
        sess.count = sess.count + 1
    else
        sess.ring[sess.head] = entry
        sess.head = (sess.head % cap) + 1
        sess.dropped = (sess.dropped or 0) + 1
    end
end

-- 将环形缓冲整理为有序 1..N 列表，并按总条数与总会话数裁剪最旧会话
local function MaterializeRing(sess)
    if type(sess) ~= "table" then return {} end
    if type(sess.entries) == "table" and (type(sess.ring) ~= "table" or (sess.count or 0) == 0) then
        return sess.entries
    end
    local out = {}
    local cap = MAX_SESSION_ENTRIES
    local head = sess.head or 1
    local cnt = sess.count or 0
    local ring = sess.ring or {}
    for i = 0, cnt - 1 do
        local idx = ((head - 1 + i) % cap) + 1
        local item = ring[idx]
        if item ~= nil then
            out[#out + 1] = item
        end
    end
    sess.entries = out
    sess.ring = nil
    sess.head = nil
    return out
end

local function EnforceTotalCaps(db)
    while #db.sessions > MAX_SESSIONS do
        table.remove(db.sessions, 1)
    end
    local total = 0
    for i = 1, #db.sessions do
        local e = db.sessions[i].entries
        total = total + (type(e) == "table" and #e or 0)
    end
    while total > MAX_TOTAL_ENTRIES and #db.sessions > 1 do
        local oldest = table.remove(db.sessions, 1)
        local n = type(oldest.entries) == "table" and #oldest.entries or 0
        total = total - n
    end
    if total > MAX_TOTAL_ENTRIES and #db.sessions == 1 then
        local entries = db.sessions[1].entries
        local dropN = total - MAX_TOTAL_ENTRIES
        local kept = {}
        for i = dropN + 1, #entries do
            kept[#kept + 1] = entries[i]
        end
        db.sessions[1].entries = kept
        db.sessions[1].dropped = (db.sessions[1].dropped or 0) + dropN
        db.sessions[1].count = #kept
    end
end

----------------------------------------------------------------------
--  专项只读快照采集器（全部 pcall + 机密防护）
----------------------------------------------------------------------
local function CaptureNativeRollFrames()
    local out = {}
    local function inspectOne(key, f)
        if not f then return end
        if not IsSafeFrame(f) then
            out[key] = { forbidden = true }
            return
        end
        local shown, shownSec = SafeFrameBool(f, "IsShown")
        local vis, visSec = SafeFrameBool(f, "IsVisible")
        local mc, mcSec = SafeFrameBool(f, "IsMouseClickEnabled")
        local me, meSec = SafeFrameBool(f, "IsMouseEnabled")
        local prot, protSec = SafeFrameBool(f, "IsProtected")
        local alpha, alphaSec = SafeFrameNum(f, "GetAlpha")
        out[key] = {
            shown = shown, shownSec = shownSec,
            visible = vis, visSec = visSec,
            mouseClick = mc, mouseClickSec = mcSec,
            mouseEnabled = me, mouseEnabledSec = meSec,
            protected = prot, protectedSec = protSec,
            alpha = alpha, alphaSec = alphaSec,
        }
    end
    inspectOne("GroupLootContainer", _G.GroupLootContainer)
    for i = 1, 4 do
        inspectOne("GroupLootFrame" .. i, _G["GroupLootFrame" .. i])
    end
    inspectOne("BonusRollFrame", _G.BonusRollFrame)
    return out
end

local function CaptureActiveRollIDs()
    local fn = _G.GetActiveLootRollIDs
    if type(fn) ~= "function" then return { ok = false, missing = true } end
    local ok, ids = pcall(fn)
    if not ok then return { ok = false } end
    if F.IsSecret(ids) then return { ok = true, secret = true } end
    if type(ids) ~= "table" then return { ok = true, t = type(ids) } end
    local list = {}
    for i = 1, math_min(#ids, 16) do
        list[i] = PackValue(ids[i], false)
    end
    return { ok = true, count = #ids, list = list }
end

local function CaptureWeaponEnchants()
    local snap = {}
    if _G.C_Item and type(_G.C_Item.GetWeaponEnchantInfo) == "function" then
        snap.cItem = CaptureAPI(_G.C_Item.GetWeaponEnchantInfo, nil)
    end
    if type(_G.GetWeaponEnchantInfo) == "function" then
        snap.legacy = CaptureAPI(_G.GetWeaponEnchantInfo, nil)
    end
    if _G.C_PaperDollInfo and type(_G.C_PaperDollInfo.GetTemporaryEnchantmentInfo) == "function" then
        snap.tempMH = CaptureAPI(_G.C_PaperDollInfo.GetTemporaryEnchantmentInfo, nil, 16)
        snap.tempOH = CaptureAPI(_G.C_PaperDollInfo.GetTemporaryEnchantmentInfo, nil, 17)
    end
    if _G.C_Secrets and type(_G.C_Secrets.ShouldAurasBeSecret) == "function" then
        snap.aurasSecret = CaptureAPI(_G.C_Secrets.ShouldAurasBeSecret, nil)
    end
    return snap
end

local function CapturePlayerAuraSample()
    local snap = {}
    if _G.C_Secrets and type(_G.C_Secrets.ShouldAurasBeSecret) == "function" then
        snap.aurasSecret = CaptureAPI(_G.C_Secrets.ShouldAurasBeSecret, nil)
    end
    local UA = _G.C_UnitAuras
    if UA and type(UA.GetAuraDataByIndex) == "function" then
        local ok, aura = pcall(UA.GetAuraDataByIndex, "player", 1, "HELPFUL")
        if not ok then
            snap.firstBuff = { ok = false }
        elseif F.IsSecret(aura) then
            snap.firstBuff = { ok = true, secret = true }
        elseif type(aura) == "table" then
            snap.firstBuff = {
                ok = true,
                spellId = PackValue(aura.spellId, false),
                name = PackValue(aura.name, false),
                duration = PackValue(aura.duration, false),
                expirationTime = PackValue(aura.expirationTime, false),
                auraInstanceID = PackValue(aura.auraInstanceID, false),
            }
        else
            snap.firstBuff = { ok = true, t = type(aura) }
        end
    end
    return snap
end

local function CaptureEnvironmentVitals()
    local snap = {}
    snap.UnitHealth = CaptureAPI(_G.UnitHealth, nil, "player")
    snap.UnitHealthMax = CaptureAPI(_G.UnitHealthMax, nil, "player")
    snap.UnitPowerType = CaptureAPI(_G.UnitPowerType, nil, "player")
    snap.UnitPower = CaptureAPI(_G.UnitPower, nil, "player", 0)
    snap.UnitPowerMax = CaptureAPI(_G.UnitPowerMax, nil, "player", 0)
    snap.UnitAffectingCombat = CaptureAPI(_G.UnitAffectingCombat, nil, "player")
    snap.UnitExistsTarget = CaptureAPI(_G.UnitExists, nil, "target")
    if _G.C_InstanceEncounter and type(_G.C_InstanceEncounter.IsEncounterInProgress) == "function" then
        snap.IsEncounterInProgress = CaptureAPI(_G.C_InstanceEncounter.IsEncounterInProgress, nil)
    end
    return snap
end

-- 只读鼠标框体栈与隐形挡点击快照（兼容 _Options 未加载、战斗中 100% 安全）
local function CaptureClickCheckForMark()
    if F._Diagnostics and type(F._Diagnostics.ScanClickBlockers) == "function" then
        local ok, res = pcall(F._Diagnostics.ScanClickBlockers, {})
        if ok and type(res) == "table" then
            local foci = {}
            for i = 1, math_min(#(res.mouseFoci or {}), 12) do
                local r = res.mouseFoci[i]
                foci[i] = {
                    name = r.name, owner = r.owner, strata = r.strata, level = r.level,
                    w = r.w, h = r.h, alpha = r.alpha, effAlpha = r.effAlpha,
                    mouseClick = r.mouseClick, isClickBlocker = r.isClickBlocker, reason = r.reason,
                }
            end
            local blockers = {}
            for i = 1, math_min(#(res.invisibleBlockers or {}), 24) do
                local r = res.invisibleBlockers[i]
                blockers[i] = {
                    name = r.name, owner = r.owner, strata = r.strata, level = r.level,
                    w = r.w, h = r.h, effAlpha = r.effAlpha, reason = r.reason,
                }
            end
            return {
                source = "diagnostics",
                mouseFoci = foci,
                invisibleBlockers = blockers,
                kkowoCount = #(res.byOwner and res.byOwner.kkowoUI or {}),
                blizzCount = #(res.byOwner and res.byOwner.Blizzard or {}),
            }
        end
    end

    -- 轻量内置兜底（无需加载 kkowoUI_Options）
    local foci = {}
    local rawFoci = nil
    if type(_G.GetMouseFoci) == "function" then
        local ok, list = pcall(_G.GetMouseFoci)
        if ok and type(list) == "table" then rawFoci = list end
    elseif type(_G.GetMouseFocus) == "function" then
        local ok, single = pcall(_G.GetMouseFocus)
        if ok and single then rawFoci = { single } end
    end
    if rawFoci then
        for i = 1, math_min(#rawFoci, 12) do
            local fr = rawFoci[i]
            if IsSafeFrame(fr) then
                local nm = SafeFrameStr(fr, "GetName") or "<anon>"
                local st = SafeFrameStr(fr, "GetFrameStrata") or "?"
                local lv = SafeFrameNum(fr, "GetFrameLevel") or 0
                local a = SafeFrameNum(fr, "GetAlpha") or 1
                local mc = SafeFrameBool(fr, "IsMouseClickEnabled")
                if mc == nil then mc = SafeFrameBool(fr, "IsMouseEnabled") end
                foci[#foci + 1] = {
                    name = nm, strata = st, level = lv, alpha = a, mouseClick = mc == true,
                }
            end
        end
    end
    return { source = "lite", mouseFoci = foci, invisibleBlockers = {} }
end

----------------------------------------------------------------------
--  录制事件框体与生命周期
----------------------------------------------------------------------
local recFrame = CreateFrame("Frame")
local recUnitFrame2 = CreateFrame("Frame")
local watchFrame = CreateFrame("Frame")
local lastPlayerAuraAt = -10
local lastPowerFreqAt = {}
local lastHealthAt = {}
local probeHealCalc = nil

local function CaptureDurationObject(fn, unit)
    if type(fn) ~= "function" then
        return { ok = false, missing = true }
    end
    local ok, obj = pcall(fn, unit)
    if not ok then return { ok = false } end
    if type(obj) == "nil" then return { ok = true, t = "nil", s = false } end
    if F.IsSecret(obj) then return { ok = true, t = type(obj), s = true } end
    local res = { ok = true, t = type(obj), s = false }
    if (type(obj) == "table" or type(obj) == "userdata") and obj.GetRemainingDuration then
        local okR, rem = pcall(obj.GetRemainingDuration, obj)
        if okR then res.rem = PackValue(rem, false) end
        if obj.GetTotalDuration then
            local okT, tot = pcall(obj.GetTotalDuration, obj)
            if okT then res.tot = PackValue(tot, false) end
        end
    end
    return res
end

local function CaptureHealPredictAndAbsorb(unit)
    local snap = {}
    snap.incomingHeals = CaptureAPI(_G.UnitGetIncomingHeals, nil, unit)
    snap.totalAbsorbs = CaptureAPI(_G.UnitGetTotalAbsorbs, nil, unit)
    snap.healAbsorbs = CaptureAPI(_G.UnitGetTotalHealAbsorbs, nil, unit)
    if type(_G.CreateUnitHealPredictionCalculator) == "function" and type(_G.UnitGetDetailedHealPrediction) == "function" then
        if not probeHealCalc then
            local okC, calc = pcall(_G.CreateUnitHealPredictionCalculator)
            if okC and calc then probeHealCalc = calc end
        end
        if probeHealCalc then
            local okU = pcall(_G.UnitGetDetailedHealPrediction, unit, nil, probeHealCalc)
            if okU then
                local cSnap = { ok = true }
                if probeHealCalc.GetIncomingHeals then
                    cSnap.heals = PackPcallResult(nil, pcall(probeHealCalc.GetIncomingHeals, probeHealCalc))
                end
                if probeHealCalc.GetDamageAbsorbs then
                    cSnap.absorbs = PackPcallResult(nil, pcall(probeHealCalc.GetDamageAbsorbs, probeHealCalc))
                end
                snap.calculator = cSnap
            else
                snap.calculator = { ok = false }
            end
        end
    else
        snap.calculator = { ok = false, missing = true }
    end
    return snap
end

local CORE_RECORD_EVENTS = {
    "START_LOOT_ROLL",
    "CANCEL_LOOT_ROLL",
    "CANCEL_ALL_LOOT_ROLLS",
    "LOOT_ROLLS_COMPLETE",
    "CONFIRM_LOOT_ROLL",
    "LOOT_READY",
    "LOOT_OPENED",
    "LOOT_CLOSED",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "ENCOUNTER_START",
    "ENCOUNTER_END",
    "GROUP_ROSTER_UPDATE",
    "PLAYER_EQUIPMENT_CHANGED",
    "NAME_PLATE_UNIT_ADDED",
    "NAME_PLATE_UNIT_REMOVED",
    "PLAYER_TARGET_CHANGED",
    "UNIT_PET",
    "PLAYER_XP_UPDATE",
    "UPDATE_FACTION",
}

local CORE_PLAYER_ONLY_UNIT_EVENTS = {
    "UNIT_AURA",
    "UNIT_INVENTORY_CHANGED",
}

local CORE_CAST_UNIT_EVENTS = {
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_DELAYED",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_EMPOWER_UPDATE",
    "UNIT_SPELLCAST_EMPOWER_STOP",
}

local CORE_VITAL_UNIT_EVENTS = {
    "UNIT_HEALTH",
    "UNIT_MAXHEALTH",
    "UNIT_POWER_FREQUENT",
    "UNIT_MAXPOWER",
    "UNIT_DISPLAYPOWER",
    "UNIT_ABSORB_AMOUNT_CHANGED",
    "UNIT_HEAL_ABSORB_AMOUNT_CHANGED",
    "UNIT_HEAL_PREDICTION",
    "UNIT_COMBAT",
}

local CAST_EVENT_SET = {}
for i = 1, #CORE_CAST_UNIT_EVENTS do CAST_EVENT_SET[CORE_CAST_UNIT_EVENTS[i]] = true end

local VITAL_EVENT_SET = {}
for i = 1, #CORE_VITAL_UNIT_EVENTS do VITAL_EVENT_SET[CORE_VITAL_UNIT_EVENTS[i]] = true end

local function SyncRecordEventRegistration(active)
    recFrame:UnregisterAllEvents()
    recUnitFrame2:UnregisterAllEvents()
    if not active then return end
    for i = 1, #CORE_RECORD_EVENTS do
        pcall(recFrame.RegisterEvent, recFrame, CORE_RECORD_EVENTS[i])
    end
    for i = 1, #CORE_PLAYER_ONLY_UNIT_EVENTS do
        pcall(recFrame.RegisterUnitEvent, recFrame, CORE_PLAYER_ONLY_UNIT_EVENTS[i], "player")
    end
    for i = 1, #CORE_CAST_UNIT_EVENTS do
        pcall(recFrame.RegisterUnitEvent, recFrame, CORE_CAST_UNIT_EVENTS[i], "player", "target")
    end
    for i = 1, #CORE_VITAL_UNIT_EVENTS do
        pcall(recFrame.RegisterUnitEvent, recFrame, CORE_VITAL_UNIT_EVENTS[i], "player", "target")
        pcall(recUnitFrame2.RegisterUnitEvent, recUnitFrame2, CORE_VITAL_UNIT_EVENTS[i], "pet", "targettarget")
    end
    for i = 1, #EXTRA_EVENTS do
        pcall(recFrame.RegisterEvent, recFrame, EXTRA_EVENTS[i])
    end
    for i = 1, #EXTRA_UNIT_EVENTS do
        local spec = EXTRA_UNIT_EVENTS[i]
        pcall(recFrame.RegisterUnitEvent, recFrame, spec.event, spec.u1, spec.u2)
    end
end

local function OnRecordEvent(_, event, ...)
    local db = EnsureDB()
    if not db.recording then return end

    local ctx = CaptureContext()

    -- 玩家光环高频事件节流（0.20s），且不落盘其他玩家信息
    if event == "UNIT_AURA" then
        local unit = select(1, ...)
        local plainU = F.PlainString(unit, nil)
        if plainU == "player" then
            if ctx.t - lastPlayerAuraAt < 0.20 then return end
            lastPlayerAuraAt = ctx.t
            local updateInfo = select(2, ...)
            local uSummary = nil
            if type(updateInfo) == "table" and not F.IsSecret(updateInfo) then
                uSummary = {
                    isFullUpdate = PackValue(updateInfo.isFullUpdate, false),
                    added = type(updateInfo.addedAuras) == "table" and #updateInfo.addedAuras or 0,
                    updated = type(updateInfo.updatedAuraInstanceIDs) == "table" and #updateInfo.updatedAuraInstanceIDs or 0,
                    removed = type(updateInfo.removedAuraInstanceIDs) == "table" and #updateInfo.removedAuraInstanceIDs or 0,
                }
            else
                uSummary = PackValue(updateInfo, true)
            end
            PushEntry({
                ev = event,
                ctx = ctx,
                args = { n = 1, v = { PackValue(unit, false) } },
                auraUpdate = uSummary,
                apis = {
                    weaponEnchants = CaptureWeaponEnchants(),
                    playerAura = CapturePlayerAuraSample(),
                },
            })
        end
        return
    end

    -- 掷点相关事件
    if event == "START_LOOT_ROLL" or event == "CANCEL_LOOT_ROLL" or event == "CONFIRM_LOOT_ROLL" then
        local rollID = select(1, ...)
        local apis = {
            nativeRoll = CaptureNativeRollFrames(),
            activeRollIDs = CaptureActiveRollIDs(),
        }
        if type(rollID) ~= "nil" then
            apis.GetLootRollItemInfo = CaptureAPI(_G.GetLootRollItemInfo, nil, rollID)
            apis.GetLootRollTimeLeft = CaptureAPI(_G.GetLootRollTimeLeft, nil, rollID)
        end
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = apis,
        })
        return
    end

    if event == "CANCEL_ALL_LOOT_ROLLS" or event == "LOOT_ROLLS_COMPLETE" then
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = {
                nativeRoll = CaptureNativeRollFrames(),
                activeRollIDs = CaptureActiveRollIDs(),
            },
        })
        return
    end

    -- 拾取窗口事件（验证 P2-28 / P2-29）
    if event == "LOOT_READY" or event == "LOOT_OPENED" or event == "LOOT_CLOSED" then
        local lf = _G.LootFrame
        local lfSnap = nil
        if lf then
            if IsSafeFrame(lf) then
                local prot, protSec = SafeFrameBool(lf, "IsProtected")
                local shown, shownSec = SafeFrameBool(lf, "IsShown")
                local a, aSec = SafeFrameNum(lf, "GetAlpha")
                lfSnap = { protected = prot, protSec = protSec, shown = shown, shownSec = shownSec, alpha = a, alphaSec = aSec }
            else
                lfSnap = { forbidden = true }
            end
        end
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = {
                lootFrame = lfSnap,
                GetNumLootItems = CaptureAPI(_G.GetNumLootItems, nil),
                LootSlotHasItem1 = CaptureAPI(_G.LootSlotHasItem, nil, 1),
            },
        })
        return
    end

    -- 武器附魔与装备变动
    if event == "UNIT_INVENTORY_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = {
                weaponEnchants = CaptureWeaponEnchants(),
            },
        })
        return
    end

    -- 姓名板事件：记录 IsForbidden / IsProtected
    if event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
        local unit = select(1, ...)
        local npSnap = { exists = false }
        if _G.C_NamePlate and type(_G.C_NamePlate.GetNamePlateForUnit) == "function" then
            local ok, plate = pcall(_G.C_NamePlate.GetNamePlateForUnit, unit)
            if ok and plate then
                local forb, forbSec = SafeFrameBool(plate, "IsForbidden")
                local prot, protSec = false, false
                if not forb then
                    prot, protSec = SafeFrameBool(plate, "IsProtected")
                end
                npSnap = { exists = true, forbidden = forb == true, forbSec = forbSec, protected = prot == true, protSec = protSec }
            end
        end
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = { nameplate = npSnap },
        })
        return
    end

    -- 施法事件（arg #2 是 castGUID，UNIT_SPELLCAST_INTERRUPTED arg #4 可能是打断者 GUID，明确脱敏不存原文）
    if CAST_EVENT_SET[event] then
        local unit = select(1, ...)
        local safeUnit = F.PlainString(unit, "player") or "player"
        local apis = {}
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_DELAYED" then
            apis.UnitCastingInfo = CaptureAPI(_G.UnitCastingInfo, { [7] = true }, safeUnit)
            apis.UnitCastingDuration = CaptureDurationObject(_G.UnitCastingDuration, safeUnit)
        elseif event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
            or event == "UNIT_SPELLCAST_EMPOWER_START" or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
            apis.UnitChannelInfo = CaptureAPI(_G.UnitChannelInfo, nil, safeUnit)
            apis.UnitChannelDuration = CaptureDurationObject(_G.UnitChannelDuration, safeUnit)
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" and safeUnit == "player" then
            apis.weaponEnchants = CaptureWeaponEnchants()
        end
        for i = 1, #EXTRA_HOOKS do
            pcall(EXTRA_HOOKS[i], event, ctx, apis, ...)
        end
        local redactMap = (event == "UNIT_SPELLCAST_INTERRUPTED") and { [2] = true, [4] = true } or { [2] = true }
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(redactMap, ...),
            apis = apis,
        })
        return
    end

    -- 血量/能量/治疗预估/吸收/受击事件（player/target/pet/targettarget，限流防挤掉 roll 记录）
    if VITAL_EVENT_SET[event] then
        local unit = select(1, ...)
        local uKey = F.PlainString(unit, "unknown") or "unknown"
        if event == "UNIT_POWER_FREQUENT" then
            local prevAt = lastPowerFreqAt[uKey] or -10
            if ctx.t - prevAt < 0.25 then return end
            lastPowerFreqAt[uKey] = ctx.t
        elseif event == "UNIT_HEALTH" then
            local prevAt = lastHealthAt[uKey] or -10
            if ctx.t - prevAt < 0.10 then return end
            lastHealthAt[uKey] = ctx.t
        end
        local apis = {}
        if event == "UNIT_COMBAT" then
            -- 动作类型(arg2)、标志(arg3)与伤害数字是否机密(arg4)
            local _, action, flags, amount, school = ...
            PushEntry({
                ev = event,
                ctx = ctx,
                args = {
                    n = 5,
                    v = {
                        PackValue(unit, false),
                        PackValue(action, false),
                        PackValue(flags, false),
                        PackValue(amount, false),
                        PackValue(school, false),
                    },
                },
                apis = {
                    UnitHealth = CaptureAPI(_G.UnitHealth, nil, uKey),
                    UnitHealthMax = CaptureAPI(_G.UnitHealthMax, nil, uKey),
                },
            })
            return
        elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" or event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" or event == "UNIT_HEAL_PREDICTION" then
            apis.healPredict = CaptureHealPredictAndAbsorb(uKey)
            apis.UnitHealthMax = CaptureAPI(_G.UnitHealthMax, nil, uKey)
        elseif event == "UNIT_POWER_FREQUENT" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
            apis.UnitPower = CaptureAPI(_G.UnitPower, nil, uKey)
            apis.UnitPowerMax = CaptureAPI(_G.UnitPowerMax, nil, uKey)
            apis.UnitPowerType = CaptureAPI(_G.UnitPowerType, nil, uKey)
        else
            apis.UnitHealth = CaptureAPI(_G.UnitHealth, nil, uKey)
            apis.UnitHealthMax = CaptureAPI(_G.UnitHealthMax, nil, uKey)
        end
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = apis,
        })
        return
    end

    -- 目标切换、宠物变更、经验与声望更新
    if event == "PLAYER_TARGET_CHANGED" or event == "UNIT_PET" or event == "PLAYER_XP_UPDATE" or event == "UPDATE_FACTION" then
        local apis = {}
        if event == "PLAYER_TARGET_CHANGED" then
            apis.UnitExists = CaptureAPI(_G.UnitExists, nil, "target")
            apis.UnitHealth = CaptureAPI(_G.UnitHealth, nil, "target")
            apis.UnitHealthMax = CaptureAPI(_G.UnitHealthMax, nil, "target")
            apis.UnitPower = CaptureAPI(_G.UnitPower, nil, "target")
            apis.UnitPowerMax = CaptureAPI(_G.UnitPowerMax, nil, "target")
            apis.healPredict = CaptureHealPredictAndAbsorb("target")
            apis.UnitCastingInfo = CaptureAPI(_G.UnitCastingInfo, { [7] = true }, "target")
            apis.UnitCastingDuration = CaptureDurationObject(_G.UnitCastingDuration, "target")
        elseif event == "UNIT_PET" then
            apis.UnitExistsPet = CaptureAPI(_G.UnitExists, nil, "pet")
            apis.UnitHealthPet = CaptureAPI(_G.UnitHealth, nil, "pet")
            apis.UnitHealthMaxPet = CaptureAPI(_G.UnitHealthMax, nil, "pet")
        elseif event == "PLAYER_XP_UPDATE" then
            apis.UnitXP = CaptureAPI(_G.UnitXP, nil, "player")
            apis.UnitXPMax = CaptureAPI(_G.UnitXPMax, nil, "player")
        end
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = apis,
        })
        return
    end

    -- 战斗与首领战状态切换
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED"
        or event == "ENCOUNTER_START" or event == "ENCOUNTER_END"
        or event == "GROUP_ROSTER_UPDATE" then
        local apis = CaptureEnvironmentVitals()
        for i = 1, #EXTRA_HOOKS do
            pcall(EXTRA_HOOKS[i], event, ctx, apis, ...)
        end
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = apis,
        })
        return
    end

    -- 其它扩展注册事件（由扩展钩子决定是否丢弃/限流并填充 apis）
    local apis = {}
    local accept = true
    for i = 1, #EXTRA_HOOKS do
        local okH, keep = pcall(EXTRA_HOOKS[i], event, ctx, apis, ...)
        if okH and keep == false then
            accept = false
            break
        end
    end
    if accept then
        PushEntry({
            ev = event,
            ctx = ctx,
            args = PackTuple(nil, ...),
            apis = apis,
        })
    end
end

recFrame:SetScript("OnEvent", OnRecordEvent)
recUnitFrame2:SetScript("OnEvent", function(self, event, ...)
    local u = F.PlainString(select(1, ...), nil)
    if u ~= "pet" and u ~= "targettarget" then return end
    OnRecordEvent(self, event, ...)
end)

----------------------------------------------------------------------
--  状态机：只录一次、副本内重载续录、离本即停并提示一次
----------------------------------------------------------------------
local function IsSameInstance(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    if a.instID and b.instID then
        return a.instID == b.instID and a.instType == b.instType
    end
    return a.instName == b.instName and a.instType == b.instType
end

local function StartSession(instType, instName, instID, reason)
    local db = EnsureDB()
    local buildVer, buildNum, buildDate, buildToc = nil, nil, nil, nil
    if type(_G.GetBuildInfo) == "function" then
        local ok, v, b, d, toc = pcall(_G.GetBuildInfo)
        if ok then
            buildVer = F.PlainString(v, nil)
            buildNum = F.PlainString(b, nil)
            buildDate = F.PlainString(d, nil)
            buildToc = F.PlainNumber(toc, nil)
        end
    end
    db.currentSession = {
        id = NowStamp(),
        startedAt = NowStamp(),
        addonVersion = F.VERSION,
        locale = _G.GetLocale and F.PlainString(_G.GetLocale(), "") or "",
        build = { version = buildVer, build = buildNum, date = buildDate, interface = buildToc },
        instanceType = instType or "none",
        instanceName = instName or "Unknown",
        instanceID = instID,
        reason = reason or "auto",
        ring = {},
        head = 1,
        count = 0,
        dropped = 0,
        seq = 0,
    }
    db.recording = true
    db.activeInstance = { instType = instType, instName = instName, instID = instID }
    SyncRecordEventRegistration(true)

    local ctx = CaptureContext()
    local apis = CaptureEnvironmentVitals()
    apis.weaponEnchants = CaptureWeaponEnchants()
    apis.nativeRoll = CaptureNativeRollFrames()
    apis.activeRollIDs = CaptureActiveRollIDs()
    PushEntry({
        ev = "SESSION_START",
        ctx = ctx,
        args = { n = 1, v = { PackValue(reason or "auto", false) } },
        apis = apis,
    })
end

local function StopSession(reason, silent)
    local db = EnsureDB()
    local wasRecording = db.recording == true
    local savedCount = 0
    local instName = nil
    if wasRecording and type(db.currentSession) == "table" then
        local sess = db.currentSession
        PushEntry({
            ev = "SESSION_END",
            ctx = CaptureContext(),
            args = { n = 1, v = { PackValue(reason or "leave", false) } },
            apis = CaptureEnvironmentVitals(),
        })
        local entries = MaterializeRing(sess)
        sess.endedAt = NowStamp()
        sess.endReason = reason or "leave"
        sess.count = #entries
        savedCount = sess.count
        instName = sess.instanceName
        db.sessions[#db.sessions + 1] = sess
        db.lastSession = {
            startedAt = sess.startedAt,
            endedAt = sess.endedAt,
            instanceName = sess.instanceName,
            instanceType = sess.instanceType,
            count = sess.count,
            dropped = sess.dropped or 0,
        }
        db.currentSession = nil
        EnforceTotalCaps(db)
    end
    db.recording = false
    db.armed = false
    db.activeInstance = nil
    SyncRecordEventRegistration(false)

    if wasRecording and not silent then
        F.Print("本次副本录像已保存（" .. tostring(instName or "副本") .. "，共 " .. tostring(savedCount)
            .. " 条），/reload 或下线后告诉 Gemini「录像好了」即可。需要再次录制时输入 /kk rec on。")
    end
end

local function EvaluateInstanceTransition(evName, isInitialLogin, isReloadingUi)
    local db = EnsureDB()
    local isCombatInst, _, instType, instName, instID = ReadInstanceInfoSafe()
    local curInfo = { instType = instType, instName = instName, instID = instID }

    if db.recording then
        if isCombatInst then
            if db.activeInstance and not IsSameInstance(db.activeInstance, curInfo) then
                -- 切到了另一个副本：结束前一次单次录像
                StopSession("instance_changed", false)
            else
                -- 仍在同一个副本内（包括副本内 /reload 或掉线重连）：继续同一次录像
                SyncRecordEventRegistration(true)
                PushEntry({
                    ev = evName or "PLAYER_ENTERING_WORLD",
                    ctx = CaptureContext(),
                    args = PackTuple(nil, isInitialLogin, isReloadingUi),
                    apis = CaptureEnvironmentVitals(),
                })
            end
        else
            -- 离开副本回到野外/主城：自动停止并退出待录状态
            StopSession("left_instance", false)
        end
        return
    end

    if db.armed then
        if isCombatInst then
            StartSession(instType, instName, instID, "armed_enter")
            if evName == "PLAYER_ENTERING_WORLD" then
                PushEntry({
                    ev = "PLAYER_ENTERING_WORLD",
                    ctx = CaptureContext(),
                    args = PackTuple(nil, isInitialLogin, isReloadingUi),
                    apis = CaptureEnvironmentVitals(),
                })
            end
        end
        -- 野外/主城不消耗待录状态
    end
end

----------------------------------------------------------------------
--  公开接口与扩展钩子（供命令、测试与视觉升级扩展使用）
----------------------------------------------------------------------
function REC.GetDB()
    return EnsureDB()
end

function REC.GetState()
    local db = EnsureDB()
    local curCount = 0
    if type(db.currentSession) == "table" then
        curCount = db.currentSession.count or (type(db.currentSession.entries) == "table" and #db.currentSession.entries or 0)
    end
    local totalSaved = 0
    for i = 1, #db.sessions do
        local e = db.sessions[i].entries
        totalSaved = totalSaved + (type(e) == "table" and #e or 0)
    end
    return {
        armed = db.armed == true,
        recording = db.recording == true,
        currentCount = curCount,
        savedSessions = #db.sessions,
        totalSavedEntries = totalSaved,
        activeInstance = db.activeInstance,
        lastSession = db.lastSession,
    }
end

-- 供后续功能（如视觉升级任务）注册新增自动待录批次标记
function REC.EnsureAutoArm(flagKey)
    if type(flagKey) ~= "string" or flagKey == "" then return false end
    local db = EnsureDB()
    if not db.autoArmFlags[flagKey] then
        db.autoArmFlags[flagKey] = true
        if not db.recording then
            db.armed = true
        end
        return true
    end
    return false
end

-- 供后续功能扩展额外录制事件与钩子（保持单框架、无重复注册）
function REC.RegisterExtension(opts)
    if type(opts) ~= "table" then return end
    if type(opts.events) == "table" then
        for i = 1, #opts.events do
            EXTRA_EVENTS[#EXTRA_EVENTS + 1] = opts.events[i]
        end
    end
    if type(opts.unitEvents) == "table" then
        for i = 1, #opts.unitEvents do
            EXTRA_UNIT_EVENTS[#EXTRA_UNIT_EVENTS + 1] = opts.unitEvents[i]
        end
    end
    if type(opts.onEvent) == "function" then
        EXTRA_HOOKS[#EXTRA_HOOKS + 1] = opts.onEvent
    end
    if type(opts.autoArmKey) == "string" then
        REC._pendingAutoArmKeys = REC._pendingAutoArmKeys or {}
        REC._pendingAutoArmKeys[#REC._pendingAutoArmKeys + 1] = opts.autoArmKey
    end
    if EnsureDB().recording then
        SyncRecordEventRegistration(true)
    end
end

-- 暴露安全打包助手给扩展使用
REC.PackValue = PackValue
REC.PackTuple = PackTuple
REC.CaptureAPI = CaptureAPI

function REC.Arm()
    local db = EnsureDB()
    db.armed = true
    local isCombatInst, _, instType, instName, instID = ReadInstanceInfoSafe()
    if isCombatInst then
        if not db.recording then
            StartSession(instType, instName, instID, "manual_in_instance")
            F.Print("当前已在副本内（" .. tostring(instName or instType) .. "），已立即开始录制，离开副本后自动停止。")
        else
            F.Print("已在录制当前副本，离开副本后自动停止。")
        end
    else
        F.Print("已开启单次待录：下一次进入副本自动开始录制，离开副本自动停止并退出待录。")
    end
end

function REC.Stop()
    local db = EnsureDB()
    local wasRec = db.recording == true
    local wasArmed = db.armed == true
    if wasRec then
        StopSession("manual_off", false)
    else
        db.armed = false
        db.activeInstance = nil
        SyncRecordEventRegistration(false)
        if wasArmed then
            F.Print("已退出待录状态（已有录像数据已保留）。")
        else
            F.Print("当前未在录制也未待录（已有录像数据已保留）。")
        end
    end
end

function REC.Clear()
    local db = EnsureDB()
    if db.recording then
        db.recording = false
        db.activeInstance = nil
        SyncRecordEventRegistration(false)
    end
    db.currentSession = nil
    db.sessions = {}
    db.lastSession = nil
    F.Print("已清空全部实机录像数据（不会重新触发首次自动待录）。")
end

function REC.PrintStatus()
    local st = REC.GetState()
    F.Print("实机录制状态：待录=" .. (st.armed and "|cff52d669是|r" or "|cff888888否|r")
        .. " | 正在录=" .. (st.recording and "|cffffd166是|r" or "|cff888888否|r")
        .. " | 当前条数=" .. tostring(st.currentCount)
        .. " | 已存会话=" .. tostring(st.savedSessions)
        .. "（共 " .. tostring(st.totalSavedEntries) .. " 条）")
    if st.lastSession then
        _G.print("  上次录像：" .. tostring(st.lastSession.instanceName or "?")
            .. "（" .. tostring(st.lastSession.instanceType or "?") .. "）"
            .. " | 时间=" .. tostring(st.lastSession.endedAt or st.lastSession.startedAt or "?")
            .. " | 条数=" .. tostring(st.lastSession.count or 0))
    end
    return st
end

function REC.Mark(note)
    local cleanNote = F.PlainString(note, "") or ""
    cleanNote = cleanNote:gsub("^%s+", ""):gsub("%s+$", "")
    local db = EnsureDB()
    local snap = CaptureClickCheckForMark()
    if db.recording then
        PushEntry({
            ev = "USER_MARK",
            ctx = CaptureContext(),
            note = cleanNote,
            clickcheck = snap,
            apis = {
                nativeRoll = CaptureNativeRollFrames(),
                vitals = CaptureEnvironmentVitals(),
            },
        })
        F.Print("已在录像中打标：" .. (cleanNote ~= "" and cleanNote or "（无备注）")
            .. "（鼠标下框体=" .. tostring(#(snap.mouseFoci or {}))
            .. "，疑似隐形挡点击=" .. tostring(#(snap.invisibleBlockers or {})) .. "）")
    else
        if F._Diagnostics and type(F._Diagnostics.ClickCheck) == "function" then
            F._Diagnostics.ClickCheck("")
        else
            F.Print("鼠标下方框体数=" .. tostring(#(snap.mouseFoci or {})))
            for i = 1, #(snap.mouseFoci or {}) do
                local r = snap.mouseFoci[i]
                _G.print("  #" .. tostring(i) .. " " .. tostring(r.name) .. " [" .. tostring(r.strata) .. ":" .. tostring(r.level) .. "] a=" .. tostring(r.alpha) .. " click=" .. tostring(r.mouseClick))
            end
        end
        F.Print("当前没有在录制（输入 /kk rec on 可开启下一次副本录制）。")
    end
    return snap
end

function REC.HandleSlash(rest)
    local raw = F.PlainString(rest, "") or ""
    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
    local sub, arg = raw:match("^(%S+)%s*(.*)$")
    sub = (sub or ""):lower()
    if sub == "on" or sub == "arm" or sub == "start" then
        REC.Arm()
    elseif sub == "off" or sub == "stop" then
        REC.Stop()
    elseif sub == "clear" or sub == "reset" then
        REC.Clear()
    elseif sub == "mark" or sub == "m" then
        REC.Mark(arg)
    elseif sub == "status" or sub == "" then
        REC.PrintStatus()
    else
        F.Print("用法：/kk rec [on|off|status|clear|mark <备注>]")
    end
end

----------------------------------------------------------------------
--  常驻守望事件：仅 3 个低频生命周期事件，未录制时 0 额外负载
----------------------------------------------------------------------
watchFrame:RegisterEvent("PLAYER_LOGIN")
watchFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
watchFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
watchFrame:SetScript("OnEvent", function(_, event, a1, a2)
    if event == "PLAYER_LOGIN" then
        REC.EnsureAutoArm(AUTO_ARM_KEY)
        REC.EnsureAutoArm(AUTO_ARM_KEY_V2)
        if type(REC._pendingAutoArmKeys) == "table" then
            for i = 1, #REC._pendingAutoArmKeys do
                REC.EnsureAutoArm(REC._pendingAutoArmKeys[i])
            end
        end
        -- 若上次在副本内 /reload 后重登，尽快恢复事件监听
        local db = EnsureDB()
        if db.recording then
            SyncRecordEventRegistration(true)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        EvaluateInstanceTransition("PLAYER_ENTERING_WORLD", a1, a2)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        EvaluateInstanceTransition("ZONE_CHANGED_NEW_AREA", nil, nil)
    end
end)
