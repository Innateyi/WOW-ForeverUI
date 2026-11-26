----------------------------------------------------------------------
--  kkowoUI — Modules/NodeReminder.lua
--  可采集 / 任务物件 / 钓鱼鱼漂 3D 头顶图标提醒 + 拾取闪光保活
--  • 严格限定：仅对 UnitIsGameObject(unit) 且为 softinteract 的游戏物件姓名板生效，
--    绝不对怪物、NPC、尸体或非互动目标显示提醒图标
--  • 支持四类：草药 / 矿脉 / 任务物件 / 钓鱼鱼漂（复用 12 张专用图标）
--  • 联动 Questie 任务物件库（o_<id>）+ cmangos 任务物件表 + item/object 任务目标匹配 + 拾取自动学习
--  • 内置 ForeverLootSparkles 闪光保活（outlineModeShowLootEffectWhenDisabled = 1）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, tonumber, tostring, type = ipairs, pairs, pcall, tonumber, tostring, type
local table_remove = table.remove
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local setmetatable = setmetatable

local mod = F.RegisterModule("nodeReminder", {
    title = "采集与拾取闪光提醒",
    desc = "仅在草药、矿脉、可互动物件任务目标与钓鱼浮漂上方显示图标提醒，联动 Questie 并自动保活拾取闪光。",
    group = "quest",
    order = 50,
    defaults = {
        enabled = true,
        lootSparkles = true,
        professionOnly = true,
        herbs = true,
        ore = true,
        quests = true,
        bobber = true,
        soundAlert = true,
        soundVolume = 0.8,
        gatherDim = true,
        iconSize = 50,
        savedCVars = {},
        learnedQuestObjects = {},
    },
})

local MEDIA_FMT = F.MEDIA .. "NodeReminder\\NodeReminder_%02d.tga"
local KIND_CFG = {
    herbs  = { pic = 37, height = 20, scale = 1.00 },
    ore    = { pic = 11, height = 25, scale = 1.00 },
    quests = { pic = 38, height = 25, scale = 1.00 },
    bobber = { pic = 27, height = 50, scale = 0.62 },
}
local SKILL_LINE = { herbs = 182, ore = 186 }
local BOBBER_OBJ_ID = 35591
local FISHING_ICON = 136245

local SOFT_TARGET_CVARS = {
    softTargetInteract = "3",
    SoftTargetInteractArc = "2",
    SoftTargetIconGameObject = "1",
    SoftTargetInteractRange = "30",
}

local marks = setmetatable({}, { __mode = "k" }) -- plate -> mark frame
local spare = {}
local questNames = {}
local questWords = {}
local openQuests = {}
local questsRead = false
local questieMod = nil
local enByCn = nil
local soundLastAt = 0
local soundNodeAt = {}
local plateDriverHooked = false
local suppressedNodes = {}
local activeGatherKey = nil
local activeGatherKind = nil
local isCastingGather = false
local isLootingGather = false
local gatherSucceededAt = 0
local gatherStopToken = 0

local function BuildNameLookup()
    if enByCn then return enByCn end
    enByCn = {}
    local data = F.NodeReminderData or {}
    for _, key in ipairs({ "HERBS_CN", "ITEM_HERBS_CN", "ORE_CN", "TREASURE_CN" }) do
        for cn, en in pairs(data[key] or {}) do
            enByCn[cn] = en
        end
    end
    return enByCn
end

local function EndsWith(str, suffix)
    return #str >= #suffix and str:sub(-#suffix) == suffix
end

local function ExtractWords(text)
    local words = {}
    for word in text:lower():gmatch("[%a\128-\255]+") do
        if #word >= 3 then
            words[#words + 1] = word
            if #word > 4 and word:sub(-3) == "ies" then
                words[#words + 1] = word:sub(1, -4) .. "y"
            elseif #word > 3 and word:sub(-1) == "s" and word:sub(-2) ~= "ss" then
                words[#words + 1] = word:sub(1, -2)
            end
        end
    end
    return words
end

local function ApplyLootSparkleCVar()
    -- 延时回调可能在停用模块之后才触发：停用后绝不再改 CVar
    if not (mod._active and mod:GetDB().lootSparkles) then return end
    F.RunOutOfCombat("FUI_LootSparkles", function()
        if not mod._active then return end
        local CV = _G.C_CVar
        if CV and CV.GetCVar and CV.SetCVar then
            local cur = CV.GetCVar("outlineModeShowLootEffectWhenDisabled")
            if cur ~= nil and cur ~= "1" then
                pcall(CV.SetCVar, "outlineModeShowLootEffectWhenDisabled", "1")
            end
        end
    end)
end

local function ApplySoftTargetCVars(enable)
    if enable and not mod._active then return end
    F.RunOutOfCombat("FUI_SoftTargetCVars", function()
        local CV = _G.C_CVar
        if not (CV and CV.GetCVar and CV.SetCVar) then return end
        local db = mod:GetDB()
        db.savedCVars = type(db.savedCVars) == "table" and db.savedCVars or {}
        -- 停用后才触发的延时「启用」回调直接作废，否则会重写 CVar 并把已改值存成「原值」
        if enable and not mod._active then return end
        if enable then
            for k, want in pairs(SOFT_TARGET_CVARS) do
                if db.savedCVars[k] == nil then
                    local cur = CV.GetCVar(k)
                    if cur ~= nil then db.savedCVars[k] = cur end
                end
                if CV.GetCVar(k) ~= want then
                    pcall(CV.SetCVar, k, want)
                end
            end
        else
            for k, orig in pairs(db.savedCVars) do
                if orig ~= nil then
                    pcall(CV.SetCVar, k, tostring(orig))
                end
            end
            db.savedCVars = {}
        end
    end)
end

local function HasProfession(kind)
    local id = SKILL_LINE[kind]
    if not id then return true end
    local db = mod:GetDB()
    if not db.professionOnly then return true end
    local fn = _G.C_SkillInfo and _G.C_SkillInfo.GetSkillLineInfoByID
    if type(fn) ~= "function" then return true end
    local ok, info = pcall(fn, id)
    if not ok or F.IsSecret(info) then return true end
    return info ~= nil
end

-- 仅采集 item / object 类型任务目标，绝不把杀怪（monster）目标纳入物件名称表
local function RefreshQuestObjectives()
    questsRead = true
    for k in pairs(questNames) do questNames[k] = nil end
    for k in pairs(questWords) do questWords[k] = nil end
    for k in pairs(openQuests) do openQuests[k] = nil end
    local QL = _G.C_QuestLog
    if not (QL and QL.GetNumQuestLogEntries and QL.GetInfo and QL.GetQuestObjectives) then
        return
    end
    for i = 1, QL.GetNumQuestLogEntries() do
        local info = QL.GetInfo(i)
        if info and info.questID and not info.isHeader then
            local objs = QL.GetQuestObjectives(info.questID)
            local anyLeft = (objs == nil)
            if type(objs) == "table" then
                for _, o in ipairs(objs) do
                    if o and not o.finished then
                        anyLeft = true
                        if (o.type == "item" or o.type == "object") and type(o.text) == "string" then
                            local item = o.text:match("^(.-):%s*%d+%s*/%s*%d+%s*$")
                                or o.text:match("^(.-)：%s*%d+%s*/%s*%d+%s*$")
                                or o.text:match("^%s*%d+%s*/%s*%d+%s+(.-)%s*$")
                                or o.text
                            if item and #item >= 4 then
                                questNames[item] = true
                                for _, w in ipairs(ExtractWords(item)) do
                                    questWords[w] = true
                                end
                            end
                        end
                    end
                end
            end
            if anyLeft then
                openQuests[info.questID] = true
            end
        end
    end
end

local function QuestieKnowsObject(objID)
    if not objID then return false end
    if questieMod == nil then
        questieMod = false
        local loader = _G.QuestieLoader
        if type(loader) == "table" and type(loader.ImportModule) == "function" then
            local ok, m = pcall(loader.ImportModule, loader, "QuestieTooltips")
            if ok and type(m) == "table" then questieMod = m end
        end
    end
    local lookup = questieMod and questieMod.lookupByKey
    local entries = type(lookup) == "table" and lookup["o_" .. objID]
    if type(entries) ~= "table" then return false end
    for _, e in pairs(entries) do
        local obj = type(e) == "table" and e.objective
        -- Questie 只在打开鼠标提示时才清理已放弃/已完成任务的条目：再用本模块自己的任务日志集合核对一次
        if type(obj) == "table" and not obj.Completed
            and (e.questId == nil or openQuests[e.questId]) then
            return true
        end
    end
    return false
end

local function DataKnowsQuestObject(objID)
    if not objID then return false end
    local qobjs = F.NodeReminderData and F.NodeReminderData.QUEST_OBJECTS
    local q = qobjs and qobjs[objID]
    if not q then return false end
    if type(q) == "number" then
        return openQuests[q] == true
    elseif type(q) == "table" then
        for _, qid in ipairs(q) do
            if openQuests[qid] then return true end
        end
    end
    return false
end

local function NameMatchesQuest(name)
    if type(name) ~= "string" or #name < 4 then return false end
    if questNames[name] then return true end
    for _, w in ipairs(ExtractWords(name)) do
        if questWords[w] then return true end
    end
    if name:find("[\128-\255]") and #name >= 6 then
        for qn in pairs(questNames) do
            if #qn >= 6 and (qn:find(name, 1, true) or name:find(qn, 1, true)) then
                return true
            end
        end
    end
    return false
end

local function IsFishingChannel()
    if not _G.UnitChannelInfo then return false end
    local ok, a, _, c = pcall(_G.UnitChannelInfo, "player")
    if not ok then return false end
    -- 兼容 12.x 结构体返回与传统多返回值
    if type(a) == "table" then
        return F.PlainNumber(a.icon, nil) == FISHING_ICON
    end
    return F.PlainNumber(c, nil) == FISHING_ICON
end

local function ExtractObjectID(guid)
    guid = F.PlainString(guid, nil)
    if not guid then return nil end
    local id = guid:match("^GameObject%-%d+%-%d+%-%d+%-%d+%-(%d+)")
    return id and tonumber(id) or nil
end

local function IsBobber(objID)
    if objID and objID ~= BOBBER_OBJ_ID then return false end
    if objID == BOBBER_OBJ_ID then return true end
    return IsFishingChannel()
end

local function ClassifyIcon(unitFrame)
    local soft = unitFrame and unitFrame.SoftTargetFrame
    local icon = soft and soft.Icon
    if not icon then return nil end
    local okShow, shown = pcall(icon.IsShown, icon)
    if okShow and not F.IsSecret(shown) and not shown then return nil end
    local okTex, tex = pcall(icon.GetTexture, icon)
    local okAtl, atl = pcall(icon.GetAtlas, icon)
    local candidates = {
        okTex and F.PlainString(tex, nil) and tex:lower() or nil,
        okAtl and F.PlainString(atl, nil) and atl:lower() or nil,
    }
    local plain = false
    for i = 1, 2 do
        local s = candidates[i]
        if s then
            if s:find("herb", 1, true) then return "herbs" end
            if s:find("mine", 1, true) or s:find("mining", 1, true) then return "ore" end
            if s:find("questinteract", 1, true) then return "quests" end
            if s:find("interact", 1, true) or s:find("buy", 1, true) or s:find("mail", 1, true) then
                plain = true
            end
        end
    end
    return plain and "plain" or nil
end

local function ClassifyName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local data = F.NodeReminderData or {}
    local lookup = BuildNameLookup()
    local plain = name:lower():gsub("\226\128\153", "'")
    local en = lookup[name] or lookup[plain] or plain
    if en:find("[%d:/]") then return nil end
    local words = 0
    for _ in en:gmatch("%S+") do words = words + 1 end
    if words > 5 then return nil end
    if EndsWith(en, " vein") or EndsWith(en, " deposit") then
        return "ore"
    end
    for _, other in ipairs(data.ORE_OTHER or {}) do
        if EndsWith(en, other) then return "ore" end
    end
    for _, herb in ipairs(data.HERBS or {}) do
        if EndsWith(en, herb) then return "herbs" end
    end
    return nil
end

local function ClassifyGameObject(unit, plate)
    local okG, rawGuid = pcall(_G.UnitGUID, unit)
    local guid = okG and F.PlainString(rawGuid, nil) or nil
    -- 若能读出 GUID 且不是 GameObject（例如 Creature / Player / Pet / Corpse），绝不标记
    if guid and not guid:find("^GameObject%-") then
        return nil, nil
    end
    local objID = ExtractObjectID(guid)
    local okN, rawName = pcall(_G.UnitName, unit)
    local name = okN and F.PlainString(rawName, nil) or nil
    local nodeKey = guid or (name and ("name:" .. name)) or nil

    -- 1) 暴雪互动图标直接指明类型
    local kind = ClassifyIcon(plate and plate.UnitFrame)
    if kind == "herbs" or kind == "ore" or kind == "quests" then
        return kind, nodeKey
    end

    -- 2) 普通互动图标或图标未就绪时：鱼漂 → 草药/矿脉名 → 任务物件
    if kind == nil or kind == "plain" then
        if IsBobber(objID) then
            return "bobber", nodeKey or "bobber"
        end
        if name then
            local byName = ClassifyName(name)
            if byName == "herbs" or byName == "ore" then
                return byName, nodeKey
            end
        end
        if not questsRead then
            RefreshQuestObjectives()
        end
        local learned = mod:GetDB().learnedQuestObjects
        if (objID and (QuestieKnowsObject(objID) or DataKnowsQuestObject(objID) or (learned and learned[objID] and questNames[learned[objID]])))
            or NameMatchesQuest(name) then
            return "quests", nodeKey
        end
    end
    return nil, nil
end

local function PlayAlertSound(nodeKey)
    local db = mod:GetDB()
    if not db.soundAlert then return end
    local now = GetTime()
    if now - soundLastAt < 3 then return end
    if nodeKey and soundNodeAt[nodeKey] and (now - soundNodeAt[nodeKey]) < 5 then return end

    local kit = _G.SOUNDKIT
    local sid = (kit and (kit.UI_MAP_WAYPOINT_SUPER_TRACK_ON or kit.IG_CHARACTER_INFO_TAB)) or 170270
    local played = false
    if _G.C_Sound and _G.C_Sound.PlaySound then
        local ok, r = pcall(_G.C_Sound.PlaySound, sid, nil, false, false, nil, db.soundVolume or 0.8)
        played = ok and r ~= false
    end
    if not played and _G.PlaySound then
        played = pcall(_G.PlaySound, sid, "SFX")
    end
    if played then
        soundLastAt = now
        if nodeKey then soundNodeAt[nodeKey] = now end
    end
end

local function AcquireMark()
    local f = table_remove(spare)
    if not f then
        f = CreateFrame("Frame", nil, _G.UIParent)
        f:SetFrameStrata("HIGH")
        f:EnableMouse(false)
        f.tex = f:CreateTexture(nil, "OVERLAY")
        f.tex:SetAllPoints()
        f.tex:SetBlendMode("BLEND")
    end
    return f
end

local function ReleaseMark(plate)
    local m = plate and marks[plate]
    if not m then return end
    marks[plate] = nil
    m.soundKey = nil
    m.gathering = nil
    m:Hide()
    m:ClearAllPoints()
    spare[#spare + 1] = m
end

local function ClearAllMarks()
    for plate in pairs(marks) do
        ReleaseMark(plate)
    end
end

local function EvaluatePlate(unit)
    if not mod._active then return end
    if type(unit) ~= "string" or not unit:find("^nameplate%d+$") then return end
    local getPlate = _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit
    if type(getPlate) ~= "function" then return end
    local okP, plate = pcall(getPlate, unit)
    if not okP or not plate then return end
    if not plate.UnitFrame then
        ReleaseMark(plate)
        return
    end

    -- 关键过滤 1：必须是游戏物件（草药/矿脉/地上可互动物件/鱼漂），怪物与尸体一律排除
    local okObj, isObj = pcall(_G.UnitIsGameObject, unit)
    if not okObj or F.IsSecret(isObj) or not isObj then
        ReleaseMark(plate)
        return
    end

    -- 关键过滤 2：必须是当前互动按键的软目标（softinteract）
    local okPick, picked = pcall(_G.UnitIsUnit, unit, "softinteract")
    if not okPick or F.IsSecret(picked) or not picked then
        ReleaseMark(plate)
        return
    end

    local db = mod:GetDB()
    local kind, nodeKey = ClassifyGameObject(unit, plate)
    if not kind or not KIND_CFG[kind] or not db[kind] or not HasProfession(kind) then
        ReleaseMark(plate)
        return
    end

    local keyId = nodeKey or kind
    local now = GetTime()
    if keyId and suppressedNodes[keyId] then
        if now < suppressedNodes[keyId] then
            ReleaseMark(plate)
            return
        else
            suppressedNodes[keyId] = nil
        end
    end
    if isLootingGather and activeGatherKey and keyId == activeGatherKey then
        ReleaseMark(plate)
        return
    end

    local cfg = KIND_CFG[kind]
    local baseSize = (db.iconSize or 50) * (cfg.scale or 1)
    local m = marks[plate]
    local isNew = false
    if not m then
        m = AcquireMark()
        marks[plate] = m
        isNew = true
    elseif (not m:IsShown()) or (m.soundKey ~= keyId) then
        isNew = true
    end
    m.soundKey = keyId
    m.nodeKey = keyId
    m.kind = kind
    m:SetSize(baseSize, baseSize)
    m:ClearAllPoints()
    m:SetPoint("CENTER", plate, "BOTTOM", 0, cfg.height or 25)
    m.tex:SetTexture(MEDIA_FMT:format(cfg.pic))
    local dimmed = db.gatherDim and (isCastingGather or (activeGatherKey ~= nil and keyId == activeGatherKey))
    m.gathering = dimmed or nil
    m:SetAlpha(dimmed and 0.25 or 1)
    m:Show()

    if isNew and kind ~= "bobber" then
        PlayAlertSound(nodeKey)
    end
end

local livePlates = {}

local function UpdateAll()
    if not mod._active then
        ClearAllMarks()
        return
    end
    -- 一次 GetNamePlates 同时完成「清理已消失姓名板的标记」与「重新评估」（原先连调两次并每次新建表）
    local getPlates = _G.C_NamePlate and _G.C_NamePlate.GetNamePlates
    if type(getPlates) ~= "function" then return end
    local ok, list = pcall(getPlates)
    if not ok or type(list) ~= "table" then return end
    for k in pairs(livePlates) do livePlates[k] = nil end
    for _, p in ipairs(list) do livePlates[p] = true end
    for plate in pairs(marks) do
        if not livePlates[plate] then ReleaseMark(plate) end
    end
    for _, plate in ipairs(list) do
        local unit = plate.UnitFrame and plate.UnitFrame.unit
        if unit then
            EvaluatePlate(unit)
        else
            ReleaseMark(plate)
        end
    end
end

local function LearnQuestLoot()
    if not questsRead then RefreshQuestObjectives() end
    if not (_G.GetNumLootItems and _G.GetLootSlotInfo and _G.GetLootSourceInfo) then return end
    local count = F.PlainNumber(_G.GetNumLootItems(), 0)
    if count <= 0 then return end
    local db = mod:GetDB()
    db.learnedQuestObjects = type(db.learnedQuestObjects) == "table" and db.learnedQuestObjects or {}
    for slot = 1, count do
        local okN, _, itemName = pcall(_G.GetLootSlotInfo, slot)
        itemName = okN and F.PlainString(itemName, nil) or nil
        if itemName and questNames[itemName] then
            local okS, guid = pcall(_G.GetLootSourceInfo, slot)
            local objID = okS and ExtractObjectID(guid) or nil
            if objID then
                db.learnedQuestObjects[objID] = itemName
            end
        end
    end
end

local updateQueued = false
local function QueueUpdateAll()
    if updateQueued then return end
    updateQueued = true
    C_Timer.After(0, function()
        updateQueued = false
        if mod._active then
            UpdateAll()
        end
    end)
end

local function HookPlateDriverOnce()
    if plateDriverHooked then return end
    local driver = _G.NamePlateDriverFrame
    if not driver or type(_G.hooksecurefunc) ~= "function" then return end
    plateDriverHooked = true
    pcall(_G.hooksecurefunc, driver, "OnNamePlateAdded", function(_, unit)
        EvaluatePlate(unit)
    end)
    pcall(_G.hooksecurefunc, driver, "OnSoftTargetUpdate", QueueUpdateAll)
end

function mod:OnEnable()
    ApplyLootSparkleCVar()
    ApplySoftTargetCVars(true)
    C_Timer.After(4, ApplyLootSparkleCVar)
    RefreshQuestObjectives()
    HookPlateDriverOnce()
    UpdateAll()

    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        HookPlateDriverOnce()
        ClearAllMarks()
        suppressedNodes = {}
        activeGatherKey, activeGatherKind = nil, nil
        isCastingGather, isLootingGather = false, false
        for k in pairs(soundNodeAt) do soundNodeAt[k] = nil end
        ApplyLootSparkleCVar()
        ApplySoftTargetCVars(true)
        RefreshQuestObjectives()
        UpdateAll()
        C_Timer.After(0.8, function()
            if not mod._active then return end
            ApplyLootSparkleCVar()
            ApplySoftTargetCVars(true)
            RefreshQuestObjectives()
            UpdateAll()
        end)
        C_Timer.After(2.5, UpdateAll)
    end)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        suppressedNodes = {}
        activeGatherKey, activeGatherKind = nil, nil
        isCastingGather, isLootingGather = false, false
        for k in pairs(soundNodeAt) do soundNodeAt[k] = nil end
        RefreshQuestObjectives()
        UpdateAll()
    end)
    self:RegisterEvent("CVAR_UPDATE", function(_, _, cvar)
        if type(cvar) == "string" then
            local lc = cvar:lower()
            if lc == "graphicsquality" or lc == "raidgraphicsquality" or lc == "outlinemodeshowlooteffectwhendisabled" then
                C_Timer.After(1, ApplyLootSparkleCVar)
            end
        end
    end)
    self:RegisterEvent("QUEST_LOG_UPDATE", F.Debounce(0.25, function()
        RefreshQuestObjectives()
        UpdateAll()
    end))
    self:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED", QueueUpdateAll)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", QueueUpdateAll)
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, _, unit)
        EvaluatePlate(unit)
    end)
    self:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, _, unit)
        local getPlate = _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit
        if type(getPlate) == "function" and unit then
            local ok, p = pcall(getPlate, unit)
            if ok and p then ReleaseMark(p) end
        end
    end)
    -- 采集 / 拾取无闪烁状态机（施法完毕→拾取→物体消失全程无缝衔接，消除多次明暗闪烁）
    local function CaptureActiveNode()
        for _, m in pairs(marks) do
            if m:IsShown() and m.kind and m.kind ~= "bobber" and m.nodeKey then
                return m.nodeKey, m.kind
            end
        end
        return nil, nil
    end
    local function HideMarksForKey(targetKey)
        if not targetKey then return end
        local toRelease = {}
        for plate, m in pairs(marks) do
            if m.nodeKey == targetKey then
                toRelease[#toRelease + 1] = plate
            end
        end
        for _, plate in ipairs(toRelease) do
            ReleaseMark(plate)
        end
    end

    self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player", function()
        local k, kind = CaptureActiveNode()
        if k then
            activeGatherKey = k
            activeGatherKind = kind
            isCastingGather = true
            gatherStopToken = gatherStopToken + 1
            if self:GetDB().gatherDim then
                for _, m in pairs(marks) do
                    m.gathering = true
                    m:SetAlpha(0.25)
                end
            end
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function()
        if activeGatherKey then
            gatherSucceededAt = GetTime()
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player", function()
        isCastingGather = false
        if activeGatherKey and (GetTime() - gatherSucceededAt) < 0.40 then
            -- 采集读条刚成功：保持淡化/等待拾取窗口，绝不瞬间回弹 1.0 造成闪烁
            gatherStopToken = gatherStopToken + 1
            local myToken = gatherStopToken
            C_Timer.After(0.55, function()
                if myToken ~= gatherStopToken or isLootingGather then return end
                activeGatherKey = nil
                activeGatherKind = nil
                for _, m in pairs(marks) do
                    m.gathering = nil
                    m:SetAlpha(1)
                end
                QueueUpdateAll()
            end)
            return
        end
        activeGatherKey = nil
        activeGatherKind = nil
        if not isLootingGather then
            for _, m in pairs(marks) do
                m.gathering = nil
                m:SetAlpha(1)
            end
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", UpdateAll)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", UpdateAll)
    local function IsLootingCreatureCorpse()
        if not (_G.GetNumLootItems and _G.GetLootSourceInfo) then return false end
        local n = F.PlainNumber(_G.GetNumLootItems(), 0)
        if n <= 0 then return false end
        local sawCreature = false
        for slot = 1, n do
            local okS, guid = pcall(_G.GetLootSourceInfo, slot)
            local g = okS and F.PlainString(guid, nil) or nil
            if g then
                if g:find("^GameObject%-") then
                    return false
                elseif g:find("^Creature%-") then
                    sawCreature = true
                end
            end
        end
        return sawCreature
    end

    self:RegisterEvent("LOOT_READY", function()
        pcall(LearnQuestLoot)
        if IsLootingCreatureCorpse() then
            -- 站在草药/矿点旁拾取怪物尸体时，绝不误把旁边未采集的节点当成已采集隐藏
            return
        end
        gatherStopToken = gatherStopToken + 1
        if not activeGatherKey then
            local k, kind = CaptureActiveNode()
            if k then
                activeGatherKey = k
                activeGatherKind = kind
            end
        end
        if activeGatherKey then
            isLootingGather = true
            HideMarksForKey(activeGatherKey)
        elseif self:GetDB().gatherDim then
            for _, m in pairs(marks) do
                m.gathering = true
                m:SetAlpha(0.25)
            end
        end
    end)
    self:RegisterEvent("LOOT_CLOSED", function()
        isLootingGather = false
        gatherStopToken = gatherStopToken + 1
        if activeGatherKey then
            -- 草药/地上任务物件采完即消失，抑制 3.2s 避开淡出动画残留；矿脉可多敲，抑制 0.95s 消除抖动后干净复现
            local dur = (activeGatherKind == "ore") and 0.95 or 3.20
            local wasOre = (activeGatherKind == "ore")
            suppressedNodes[activeGatherKey] = GetTime() + dur
            HideMarksForKey(activeGatherKey)
            activeGatherKey = nil
            activeGatherKind = nil
            if wasOre then
                C_Timer.After(1.0, QueueUpdateAll)
            end
        end
        for _, m in pairs(marks) do
            m.gathering = nil
            m:SetAlpha(1)
        end
        QueueUpdateAll()
    end)
end

local function ResetGatherState()
    suppressedNodes = {}
    activeGatherKey, activeGatherKind = nil, nil
    isCastingGather, isLootingGather = false, false
    for k in pairs(soundNodeAt) do soundNodeAt[k] = nil end
end

function mod:OnDisable()
    ClearAllMarks()
    ResetGatherState()
    ApplySoftTargetCVars(false)
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "任务物品拾取闪光保活",
        tooltip = "自动维持 outlineModeShowLootEffectWhenDisabled = 1（替代 ForeverLootSparkles）。",
        getValue = function() return db.lootSparkles ~= false end,
        setValue = function(v) db.lootSparkles = v == true; if v then ApplyLootSparkleCVar() end end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "草药头顶标记",
        getValue = function() return db.herbs ~= false end,
        setValue = function(v) db.herbs = v == true; UpdateAll() end,
    }, {
        type = "toggle",
        text = "矿脉头顶标记",
        getValue = function(v) return db.ore ~= false end,
        setValue = function(v) db.ore = v == true; UpdateAll() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "地上任务物件标记（不含怪物）",
        tooltip = "仅对地上的可互动物件任务目标显示，绝不标记怪物或尸体。",
        getValue = function() return db.quests ~= false end,
        setValue = function(v) db.quests = v == true; UpdateAll() end,
    }, {
        type = "toggle",
        text = "钓鱼鱼漂标记",
        getValue = function() return db.bobber ~= false end,
        setValue = function(v) db.bobber = v == true; UpdateAll() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "仅提醒已学采集专业",
        tooltip = "未学采药/采矿时不提示草药和矿脉（不影响地上任务物件和鱼漂）。",
        getValue = function() return db.professionOnly ~= false end,
        setValue = function(v) db.professionOnly = v == true; UpdateAll() end,
    }, {
        type = "toggle",
        text = "发现时播放轻提示音",
        tooltip = "带 5 秒同节点去重与 3 秒全局冷却。",
        getValue = function() return db.soundAlert ~= false end,
        setValue = function(v) db.soundAlert = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "标记图标尺寸",
        min = 24, max = 72, step = 2,
        getValue = function() return db.iconSize or 50 end,
        setValue = function(v) db.iconSize = v; UpdateAll() end,
    }, {
        type = "toggle",
        text = "采集/拾取时自动淡化标记",
        getValue = function() return db.gatherDim ~= false end,
        setValue = function(v) db.gatherDim = v == true end,
    })
    y = y - h
    return y
end
