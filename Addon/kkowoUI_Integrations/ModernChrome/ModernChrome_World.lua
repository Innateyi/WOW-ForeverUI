----------------------------------------------------------------------
--  kkowoUI_Integrations — ModernChrome/ModernChrome_World.lua
--  训练师智能过滤 + 战斗飘字分级 + 无限服「世界刷新」倒计时横幅
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local MC = F._MC
if not MC then return end

local ipairs, pairs, math_abs, math_floor, math_max, math_min, pcall, tonumber, tostring, type =
    ipairs, pairs, math.abs, math.floor, math.max, math.min, pcall, tonumber, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local setmetatable = setmetatable
local mod = MC.mod

----------------------------------------------------------------------
--  8) 训练师 / 猎人野兽训练智能过滤 + 行内文字防重叠排版修复
--     • 使用暴雪官方 SetTrainerServiceTypeFilter，零污染、绝不破坏点击训练索引
--     • 彻底移除登录/打开前抢先预置过滤（避免造成 C++ 过滤标记与野兽训练首开列表脱节）
--     • 同一次打开合并多事件（TRAINER_SHOW / ADDON_LOADED / OnShow）防定时回调互杀，
--       并结合 TRAINER_UPDATE + 多拍复核确认列表中真正清除「已学会/暂不可学」后才结束；
--       严格限制单次打开最多写入 3 次 + 重入锁，玩家手动点「过滤器」立刻放手
--     • 排版修复在 0s + 0.08s 双拍生效，确保在 EUI 首次皮肤防抖后仍保持行内不重叠
----------------------------------------------------------------------
local trainerHooked = false
local trainerScrollHooked = false
local trainerDropdownHooked = false
local trainerOpenGen = 0
local trainerDoneGen = 0
local trainerUserTouchedGen = 0
local trainerAttemptsForGen = 0
local trainerCyclingGen = 0
local trainerSessionActive = false
local applyingTrainerFilter = false
local polishTrainerQueued = false

local function FixTrainerRowLayout(row)
    if not (row and mod._active) then return end
    if row.IsForbidden and row:IsForbidden() then return end

    local nameFS = row.name
    local subFS = row.subText
    local icon = row.icon
    local money = row.money
    local rightBadge = nil
    if money and money.IsShown and money:IsShown() then
        rightBadge = money
    elseif row.cost and row.cost.IsShown and row.cost:IsShown() then
        rightBadge = row.cost
    end

    -- 统一技能名、等级后缀（「（等级 X）」）与训练点数的字体与字号（避免 EUI 仅换 row.name 字体导致大小不齐）
    local fontFace = F.Theme.GetFont()
    local topSize, topFlags = 13, ""
    if nameFS and nameFS.GetFont then
        local okF, fPath, fSize, fFlags = pcall(nameFS.GetFont, nameFS)
        if okF then
            if type(fPath) == "string" and fPath ~= "" and (not fontFace or fontFace == "") then
                fontFace = fPath
            end
            local parsed = F.PlainNumber(fSize, nil)
            if parsed and parsed >= 10 and parsed <= 18 then
                topSize = math_floor(parsed + 0.5)
            end
            if type(fFlags) == "string" then
                topFlags = fFlags
            end
        end
    end
    if fontFace and fontFace ~= "" then
        if nameFS and nameFS.SetFont then
            pcall(nameFS.SetFont, nameFS, fontFace, topSize, topFlags)
        end
        if row.GetRegions then
            for _, reg in ipairs({ row:GetRegions() }) do
                if reg and reg ~= subFS and reg ~= nameFS
                    and reg.GetObjectType and reg:GetObjectType() == "FontString"
                    and reg.SetFont then
                    pcall(reg.SetFont, reg, fontFace, topSize, topFlags)
                end
            end
        end
    end

    -- 价格框 / 训练点数对齐至行右上角，给下方需求文字腾出整行宽度
    if rightBadge and rightBadge.ClearAllPoints then
        pcall(rightBadge.ClearAllPoints, rightBadge)
        pcall(rightBadge.SetPoint, rightBadge, "TOPRIGHT", row, "TOPRIGHT", -6, -5)
    end

    if subFS and subFS.ClearAllPoints then
        local face = (fontFace and fontFace ~= "") and fontFace or (subFS.GetFont and subFS:GetFont())
        if face and face ~= "" then
            pcall(subFS.SetFont, subFS, face, 11, "")
        end
        if subFS.SetJustifyH then pcall(subFS.SetJustifyH, subFS, "LEFT") end
        if subFS.SetJustifyV then pcall(subFS.SetJustifyV, subFS, "TOP") end
        if subFS.SetWordWrap then pcall(subFS.SetWordWrap, subFS, false) end
        if subFS.SetMaxLines then pcall(subFS.SetMaxLines, subFS, 1) end
        pcall(subFS.ClearAllPoints, subFS)
        if icon then
            pcall(subFS.SetPoint, subFS, "TOPLEFT", icon, "TOPRIGHT", 8, -22)
        elseif nameFS then
            pcall(subFS.SetPoint, subFS, "TOPLEFT", nameFS, "BOTTOMLEFT", 0, -4)
        else
            pcall(subFS.SetPoint, subFS, "TOPLEFT", row, "TOPLEFT", 46, -22)
        end
        -- 需求行横跨整行右侧（位于价格下方），彻底告别折行压字与裁切
        pcall(subFS.SetPoint, subFS, "RIGHT", row, "RIGHT", -6, 0)
    end
end

local function PolishTrainerRows()
    local ctf = _G.ClassTrainerFrame
    if not (ctf and ctf:IsShown() and ctf.ScrollBox and ctf.ScrollBox.ForEachFrame) then return end
    pcall(ctf.ScrollBox.ForEachFrame, ctf.ScrollBox, FixTrainerRowLayout)
end

local function QueuePolishTrainerRows()
    if polishTrainerQueued or not mod._active then return end
    polishTrainerQueued = true
    C_Timer.After(0, function()
        polishTrainerQueued = false
        PolishTrainerRows()
        -- 兜底复刷一拍：避免首次加载 Blizzard_TrainerUI 时 EUI WSkin.Debounce 晚一帧覆盖行内字体
        C_Timer.After(0.08, PolishTrainerRows)
    end)
end

local function IsFilterFlagOn(v)
    return v == true or v == 1
end

local function ExtractServiceCategory(i)
    if not _G.GetTrainerServiceInfo then return nil end
    local ok, _, r2, r3, r4 = pcall(_G.GetTrainerServiceInfo, i)
    if not ok then return nil end
    if r2 == "available" or r2 == "unavailable" or r2 == "used" then
        return r2
    end
    if r3 == "available" or r3 == "unavailable" or r3 == "used" then
        return r3
    end
    if r4 == "available" or r4 == "unavailable" or r4 == "used" then
        return r4
    end
    return nil
end

local function ScanTrainerServices(wantHideUsed, wantHideUnavail)
    local numSvc = _G.GetNumTrainerServices and F.PlainNumber(_G.GetNumTrainerServices(), 0) or 0
    local hasUsed, hasUnavail = false, false
    if numSvc > 0 then
        for i = 1, numSvc do
            local cat = ExtractServiceCategory(i)
            if wantHideUsed and cat == "used" then
                hasUsed = true
            elseif wantHideUnavail and cat == "unavailable" then
                hasUnavail = true
            end
            if (not wantHideUsed or hasUsed) and (not wantHideUnavail or hasUnavail) then
                break
            end
        end
    end
    return numSvc, hasUsed, hasUnavail
end

local function ApplyFilterFinal(ctf, wantHideUsed, wantHideUnavail)
    applyingTrainerFilter = true
    pcall(function()
        _G.SetTrainerServiceTypeFilter("available", true)
        if wantHideUsed then _G.SetTrainerServiceTypeFilter("used", false) end
        if wantHideUnavail then _G.SetTrainerServiceTypeFilter("unavailable", false) end
        if _G.ClassTrainerFrame_Update then
            _G.ClassTrainerFrame_Update()
        elseif ctf and ctf.Update then
            ctf:Update()
        end
        if ctf and ctf.FilterDropdown and ctf.FilterDropdown.Update then
            ctf.FilterDropdown:Update()
        end
        if ctf and ctf.ScrollBox and ctf.ScrollBox.ScrollToBegin then
            ctf.ScrollBox:ScrollToBegin()
        end
    end)
    applyingTrainerFilter = false
    QueuePolishTrainerRows()
end

local function ResetTrainerSession()
    -- 递增代次号，让关闭窗口前排下的 0.08~0.55 秒补刷定时器全部作废
    trainerOpenGen = trainerOpenGen + 1
    trainerSessionActive = false
    trainerDoneGen = 0
    trainerAttemptsForGen = 0
    trainerUserTouchedGen = 0
    trainerCyclingGen = 0
end

local function ApplyTrainerFilterForOpen(gen, reason)
    if applyingTrainerFilter or not mod._active then return end
    if gen ~= trainerOpenGen then return end
    if trainerDoneGen == gen or trainerUserTouchedGen == gen or trainerCyclingGen == gen then return end
    if trainerAttemptsForGen >= 3 then
        trainerDoneGen = gen
        return
    end

    local db = mod:GetDB()
    local wantHideUsed = db.trainerHideUsed ~= false
    local wantHideUnavail = db.trainerHideUnavailable ~= false
    if not wantHideUsed and not wantHideUnavail then
        trainerDoneGen = gen
        return
    end
    if not _G.SetTrainerServiceTypeFilter then return end

    local ctf = _G.ClassTrainerFrame
    if not (ctf and ctf:IsShown()) then return end

    local getFilter = _G.GetTrainerServiceTypeFilter
    local curAvail = getFilter and IsFilterFlagOn(getFilter("available"))
    local curUsed = getFilter and IsFilterFlagOn(getFilter("used"))
    local curUnavail = getFilter and IsFilterFlagOn(getFilter("unavailable"))

    local numSvc, hasUsed, hasUnavail = ScanTrainerServices(wantHideUsed, wantHideUnavail)

    local flagNeedsFix = (getFilter == nil)
        or (not curAvail)
        or (wantHideUsed and curUsed)
        or (wantHideUnavail and curUnavail)
    local staleRows = (hasUsed or hasUnavail)

    -- 尚未收到服务列表且过滤标志已就位：等待 TRAINER_UPDATE 或后续拍次，不提前锁死 trainerDoneGen
    if (not flagNeedsFix) and (not staleRows) then
        if reason == "verify" or reason == "late" or (numSvc > 0 and reason == "delay") then
            trainerDoneGen = gen
        end
        QueuePolishTrainerRows()
        return
    end

    -- 关键防卡死保护：严格递增尝试计数并置重入锁
    trainerAttemptsForGen = trainerAttemptsForGen + 1

    if flagNeedsFix then
        ApplyFilterFinal(ctf, wantHideUsed, wantHideUnavail)
        -- 延迟 0.10s 真正复核列表（等待 C++ 引擎/服务器重建列表），而非当帧盲目锁死 done
        C_Timer.After(0.10, function()
            if trainerOpenGen == gen and trainerDoneGen ~= gen and trainerUserTouchedGen ~= gen then
                ApplyTrainerFilterForOpen(gen, "verify")
            end
        end)
        return
    end

    -- C++ 过滤标记已是 false，但列表里仍存在「已学会 / 暂不可学」残留行（野兽训练首次打开常见现象）：
    -- 跨帧先置 true 并刷新，0.08s 后再置 false 并刷新，随后 0.12s 复核确保彻底清空
    trainerCyclingGen = gen
    applyingTrainerFilter = true
    pcall(function()
        if wantHideUsed then _G.SetTrainerServiceTypeFilter("used", true) end
        if wantHideUnavail then _G.SetTrainerServiceTypeFilter("unavailable", true) end
        if _G.ClassTrainerFrame_Update then
            _G.ClassTrainerFrame_Update()
        end
    end)
    applyingTrainerFilter = false

    C_Timer.After(0.08, function()
        if trainerCyclingGen == gen then
            trainerCyclingGen = 0
        end
        if not mod._active or gen ~= trainerOpenGen or trainerUserTouchedGen == gen then return end
        local curCtf = _G.ClassTrainerFrame
        if not (curCtf and curCtf:IsShown()) then return end
        ApplyFilterFinal(curCtf, wantHideUsed, wantHideUnavail)
        C_Timer.After(0.12, function()
            if trainerOpenGen == gen and trainerDoneGen ~= gen and trainerUserTouchedGen ~= gen then
                ApplyTrainerFilterForOpen(gen, "verify")
            end
        end)
    end)
end

local function SafeDebugStr(v)
    if F.IsSecret(v) then return "<secret>" end
    return tostring(v)
end

F.DumpTrainerDebug = function()
    local ctf = _G.ClassTrainerFrame
    local gf = _G.GetTrainerServiceTypeFilter
    local okTT, tt = false, nil
    if _G.C_Trainer and _G.C_Trainer.GetTrainerType then
        okTT, tt = pcall(_G.C_Trainer.GetTrainerType)
    end
    local n, hu, hun = ScanTrainerServices(true, true)
    local okA, fA = pcall(gf or function() return nil end, "available")
    local okU, fU = pcall(gf or function() return nil end, "used")
    local okN, fN = pcall(gf or function() return nil end, "unavailable")
    F.Print(string_format("TrainerDebug: shown=%s active=%s gen=%d/%d att=%d type=%s n=%d usedRow=%s unavailRow=%s | fAvail=%s fUsed=%s fUnavail=%s",
        tostring(ctf and ctf.IsShown and ctf:IsShown() or false), tostring(trainerSessionActive),
        trainerOpenGen, trainerDoneGen, trainerAttemptsForGen,
        okTT and SafeDebugStr(tt) or "nil", n, tostring(hu), tostring(hun),
        okA and SafeDebugStr(fA) or "err", okU and SafeDebugStr(fU) or "err", okN and SafeDebugStr(fN) or "err"))
    if _G.GetTrainerServiceInfo and n > 0 then
        for i = 1, math_min(n, 6) do
            local okI, r1, r2, r3, r4 = pcall(_G.GetTrainerServiceInfo, i)
            if okI then
                F.Print(string_format("  [%d] r1=%s r2=%s r3=%s r4=%s", i,
                    SafeDebugStr(r1), SafeDebugStr(r2), SafeDebugStr(r3), SafeDebugStr(r4)))
            end
        end
    end
end

local function BeginTrainerOpenSession()
    if applyingTrainerFilter or not mod._active then return end
    -- 同一次打开内合并 TRAINER_SHOW / ADDON_LOADED / OnShow 多事件，避免递增 gen 误杀正在执行的跨帧翻转定时器
    if trainerSessionActive then
        QueuePolishTrainerRows()
        return
    end
    trainerSessionActive = true
    trainerOpenGen = trainerOpenGen + 1
    trainerDoneGen = 0
    trainerUserTouchedGen = 0
    trainerAttemptsForGen = 0
    trainerCyclingGen = 0
    local gen = trainerOpenGen
    -- 多拍覆盖首开 LoD 加载与网络包延迟：0s / 0.12s / 0.30s / 0.55s（任一拍确认干净即锁 done 跳过后续）
    C_Timer.After(0, function()
        if trainerOpenGen == gen and trainerDoneGen ~= gen then
            ApplyTrainerFilterForOpen(gen, "open")
        end
    end)
    C_Timer.After(0.12, function()
        if trainerOpenGen == gen and trainerDoneGen ~= gen then
            ApplyTrainerFilterForOpen(gen, "open2")
        end
    end)
    C_Timer.After(0.30, function()
        if trainerOpenGen == gen and trainerDoneGen ~= gen then
            ApplyTrainerFilterForOpen(gen, "delay")
        end
    end)
    C_Timer.After(0.55, function()
        if trainerOpenGen == gen and trainerDoneGen ~= gen then
            ApplyTrainerFilterForOpen(gen, "late")
        end
    end)
end

local function HookTrainerFrameIfReady()
    local ctf = _G.ClassTrainerFrame
    if not ctf then return false end
    local newlyHooked = false
    if not trainerHooked and ctf.HookScript then
        trainerHooked = true
        newlyHooked = true
        ctf:HookScript("OnShow", BeginTrainerOpenSession)
        ctf:HookScript("OnHide", ResetTrainerSession)
        if _G.ClassTrainerFrame_Update then
            _G.hooksecurefunc("ClassTrainerFrame_Update", QueuePolishTrainerRows)
        end
    end
    if ctf.FilterDropdown and not trainerDropdownHooked and ctf.FilterDropdown.HookScript then
        trainerDropdownHooked = true
        ctf.FilterDropdown:HookScript("OnMouseDown", function()
            -- 玩家手动点击「过滤器」时立即停止本次自动干预，绝不抢回选项
            trainerUserTouchedGen = trainerOpenGen
            trainerDoneGen = trainerOpenGen
        end)
    end
    if ctf.ScrollBox and not trainerScrollHooked and type(ctf.ScrollBox.Update) == "function" then
        trainerScrollHooked = true
        _G.hooksecurefunc(ctf.ScrollBox, "Update", QueuePolishTrainerRows)
    end
    return newlyHooked
end

----------------------------------------------------------------------
--  9) 战斗飘字智能分级与自由调节（仅影响战斗数字/飘字，绝不改其他 UI 字体）
--     • 3D 头顶打怪伤害/击杀经验：同步 WorldTextScale_v2 / WorldTextScale（默认 0.85 收敛近景过大）
--     • 2D 滚动战斗文字（Blizzard_CombatText）：纯 hooksecurefunc 零污染分级
--         - 自身受伤数字（物理红 / 法术紫红）：自动放大至 incomingDamageSize（默认 34px）
--         - 2D 经验 / 声望 / 荣誉提示：自动缩至 combatXPSize（默认 15px）
--         - 治疗 / 触发等其余提示：保持清晰适中 22px
----------------------------------------------------------------------
local ApplyWorldTextScale, RestoreWorldTextScale, HookCombatTextSizing
do
    local combatTextHooked = false

    local function GetCVarSafe(name)
        local CV = _G.C_CVar
        if CV and CV.GetCVar then
            local ok, v = pcall(CV.GetCVar, name)
            if ok then return F.PlainString(v, nil) end
        elseif _G.GetCVar then
            local ok, v = pcall(_G.GetCVar, name)
            if ok then return F.PlainString(v, nil) end
        end
        return nil
    end

    local function SetCVarSafe(name, val)
        if GetCVarSafe(name) == nil then return false end
        local want = tostring(val)
        if GetCVarSafe(name) == want then return true end
        local CV = _G.C_CVar
        if CV and CV.SetCVar then
            return (pcall(CV.SetCVar, name, want)) == true
        elseif _G.SetCVar then
            return (pcall(_G.SetCVar, name, want)) == true
        end
        return false
    end

    ApplyWorldTextScale = function()
        local db = mod:GetDB()
        if not (mod._active and db.smartCombatText ~= false) then return end
        local scale = F.PlainNumber(db.worldTextScale, 1.00)
        scale = math_max(0.50, math_min(2.00, math_floor(scale * 100 + 0.5) / 100))
        F.RunOutOfCombat("FUI_WorldTextScale", function()
            if not (mod._active and mod:GetDB().smartCombatText ~= false) then return end
            local curDB = mod:GetDB()
            if type(curDB.savedWorldTextScale) ~= "table" then
                local snap = {}
                for _, cv in ipairs({ "WorldTextScale_v2", "WorldTextScale", "floatingCombatTextCombatDamageDirectionalScale_v2" }) do
                    local orig = GetCVarSafe(cv)
                    if orig ~= nil then snap[cv] = orig end
                end
                curDB.savedWorldTextScale = snap
            elseif curDB.savedWorldTextScale.floatingCombatTextCombatDamageDirectionalScale_v2 == nil then
                local origArc = GetCVarSafe("floatingCombatTextCombatDamageDirectionalScale_v2")
                if origArc ~= nil then
                    curDB.savedWorldTextScale.floatingCombatTextCombatDamageDirectionalScale_v2 = origArc
                end
            end
            SetCVarSafe("WorldTextScale_v2", scale)
            SetCVarSafe("WorldTextScale", scale)
            local arcMode = curDB.damageArcMode or "keep"
            if arcMode == "classic" then
                SetCVarSafe("floatingCombatTextCombatDamageDirectionalScale_v2", 0)
            elseif arcMode == "compact" then
                SetCVarSafe("floatingCombatTextCombatDamageDirectionalScale_v2", 1)
            elseif arcMode == "keep" and curDB.savedWorldTextScale
                and curDB.savedWorldTextScale.floatingCombatTextCombatDamageDirectionalScale_v2 ~= nil then
                SetCVarSafe("floatingCombatTextCombatDamageDirectionalScale_v2", curDB.savedWorldTextScale.floatingCombatTextCombatDamageDirectionalScale_v2)
            end
        end)
    end

    RestoreWorldTextScale = function()
        F.RunOutOfCombat("FUI_WorldTextScale", function()
            local db = mod:GetDB()
            if type(db.savedWorldTextScale) == "table" then
                for cv, orig in pairs(db.savedWorldTextScale) do
                    if orig ~= nil then SetCVarSafe(cv, orig) end
                end
                db.savedWorldTextScale = nil
            end
        end)
    end

    local function FindLatestCombatTextFS(plain)
        local animList = _G.COMBAT_TEXT_TO_ANIMATE
        if type(animList) == "table" and #animList > 0 then
            local last = animList[#animList]
            if last and not (last.IsForbidden and last:IsForbidden()) and last.SetTextHeight then
                return last
            end
        end
        local maxLines = F.PlainNumber(_G.NUM_COMBAT_TEXT_LINES, 20)
        -- 优先精确匹配同帧刚写入的文本，避免同帧多条飘字误改前一条的字号
        if plain and plain ~= "" then
            for i = maxLines, 1, -1 do
                local cand = _G["CombatText" .. i]
                if cand and not (cand.IsForbidden and cand:IsForbidden()) and cand:IsShown() and cand.SetTextHeight then
                    local st = F.PlainNumber(cand.scrollTime, 999)
                    if st <= 0.05 and cand.GetText then
                        local okT, txt = pcall(cand.GetText, cand)
                        if okT and F.PlainString(txt, nil) == plain then
                            return cand
                        end
                    end
                end
            end
        end
        local bestFS, bestTime = nil, 999
        for i = 1, maxLines do
            local cand = _G["CombatText" .. i]
            if cand and not (cand.IsForbidden and cand:IsForbidden()) and cand:IsShown() and cand.SetTextHeight then
                local st = F.PlainNumber(cand.scrollTime, 999)
                if st < bestTime then
                    bestTime = st
                    bestFS = cand
                end
            end
        end
        return bestFS
    end

    local function OnCombatTextAddMessage(message, _, r, g, b, displayType)
        if not (mod._active and mod:GetDB().smartCombatText ~= false) then return end
        local plain = F.PlainString(message, nil)
        local fs = FindLatestCombatTextFS(plain)
        if not fs then return end

        -- 暴雪对 crit 会在 CombatText_OnUpdate 每帧动态插值 SetTextHeight，
        -- 强行写入一次高度会导致首帧尺寸闪跳，此处交由暴雪原生暴击弹跳动画处理
        if F.PlainString(displayType, nil) == "crit" then
            return
        end

        local db = mod:GetDB()
        local rn = F.PlainNumber(r, nil)
        local gn = F.PlainNumber(g, nil)
        local bn = F.PlainNumber(b, nil)

        -- 1) 识别 2D 经验 / 声望 / 荣誉提示（优先识别，避免被紫色法伤误判）
        local isXPOrMisc = false
        if plain then
            local low = plain:lower()
            if plain:find("经验", 1, true) or plain:find("声望", 1, true) or plain:find("荣誉", 1, true)
                or low:find("xp", 1, true) or low:find("reputation", 1, true) or low:find("honor", 1, true) then
                isXPOrMisc = true
            end
        end
        if not isXPOrMisc and rn and gn and bn and rn <= 0.22 and gn <= 0.22 and bn >= 0.88 then
            isXPOrMisc = true
        end

        -- 2) 识别角色自身受到的伤害（物理红 1/0.1/0.1、法术紫红 0.79/0.3/0.85、负伤害数字）
        --    当文本可读（非 12.x 保密值）时必须包含数字，防止把红字「<进入战斗> / 生命值过低」误放大成 34px
        local isIncomingDmg = false
        if not isXPOrMisc then
            local hasDigits = (plain == nil) or (plain:find("%d") ~= nil)
            local isPhysRed = hasDigits and rn and gn and bn and rn >= 0.88 and gn <= 0.28 and bn <= 0.28
            local isSpellMag = hasDigits and rn and gn and bn
                and math_abs(rn - 0.79) <= 0.08 and math_abs(gn - 0.30) <= 0.08 and math_abs(bn - 0.85) <= 0.08
            local isNegNum = plain and plain:find("^%-?%d") and rn and rn >= 0.68 and gn and gn <= 0.45
            if isPhysRed or isSpellMag or isNegNum then
                isIncomingDmg = true
            end
        end

        local targetSize
        if isXPOrMisc then
            targetSize = math_max(10, math_min(26, F.PlainNumber(db.combatXPSize, 15)))
        elseif isIncomingDmg then
            targetSize = math_max(20, math_min(48, F.PlainNumber(db.incomingDamageSize, 34)))
        else
            targetSize = 22
        end
        pcall(fs.SetTextHeight, fs, targetSize)
    end

    local function OnCombatTextAddMessageSafe(message, scrollFunction, r, g, b, displayType)
        pcall(OnCombatTextAddMessage, message, scrollFunction, r, g, b, displayType)
    end

    HookCombatTextSizing = function()
        if combatTextHooked then return end
        if type(_G.CombatText_AddMessage) == "function" then
            combatTextHooked = true
            _G.hooksecurefunc("CombatText_AddMessage", OnCombatTextAddMessageSafe)
        end
    end
end

----------------------------------------------------------------------
--  10) 无限服「世界刷新」倒计时提示框美化、去重、居中与无拖影淡入
--      • 同时探测紧凑版（「世界会在X分钟后刷新」）与完整版（「你周围的世界会在…」）
--      • 若暴雪同时在聊框上方再弹第二个重复原版横幅，自动静音去重只保留主卡片
--      • 停用暴雪原版平移动画 + 合并定位防抖，彻底消除出现时的拖影，改用纯 Alpha 丝滑淡入
--      • 左侧原生红框黄箭头按钮美化为内嵌现代琥珀刷新钮（完整保留原生点击功能）
--      • 正文严格水平/垂直居中，Shift+左键拖动自动记忆位置，全弱表零污染
----------------------------------------------------------------------
local RefreshWorldRefreshBanner, StopWorldRefreshTicker, EnsureWorldRefreshTicker, StopWorldRefreshDrag
do
    local wrSkin = setmetatable({}, { __mode = "k" })
    local wrHooked = setmetatable({}, { __mode = "k" })
    local wrBtnSkin = setmetatable({}, { __mode = "k" })
    local wrBtnHooked = setmetatable({}, { __mode = "k" })
    local wrBtnOrigPt = setmetatable({}, { __mode = "k" })
    local wrOrigFS = setmetatable({}, { __mode = "k" })
    local wrPosQueued = setmetatable({}, { __mode = "k" })
    local wrKnown = setmetatable({}, { __mode = "k" })
    local wrSuppressed = setmetatable({}, { __mode = "k" })
    local wrList = setmetatable({}, { __mode = "v" })
    local wrPrimaryBox = setmetatable({}, { __mode = "v" })
    local wrMoving = false
    local wrDragging = false
    local wrDragBox = setmetatable({}, { __mode = "v" })
    local wrTicker = nil

    local SKIP_PREFIXES = {
        "kkowoUI", "Ellesmere", "Polestar", "Questie", "BigWigs",
        "ChatFrame", "ActionBar", "MultiBar", "GameTooltip", "WorldMap",
        "CharacterFrame", "SpellBook", "FriendsFrame", "BugSack", "WorldFrame",
        "ContainerFrame", "PlayerFrame", "TargetFrame", "Minimap", "BuffFrame", "DebuffFrame",
    }

    local function IsSafeReadableFrame(f)
        if not f then return false end
        if f.IsForbidden then
            local okF, forb = pcall(f.IsForbidden, f)
            if not okF or forb then return false end
        end
        if f.GetWidth then
            local okW, w = pcall(f.GetWidth, f)
            if not okW or F.IsSecret(w) then return false end
        end
        return true
    end

    local function IsFrameShownSafe(f)
        if not IsSafeReadableFrame(f) or not f.IsShown then return false end
        local ok, shown = pcall(f.IsShown, f)
        return ok and shown == true
    end

    -- 系统对话框（StaticPopup 确认框、组队邀请、副本就位、团队确认等）绝不当作刷新横幅：
    -- 游戏的「立即刷新世界」确认框就是 StaticPopup，一旦被当成横幅，它会被改样式、挪位置、
    -- 文字被拉到同一行叠字、按钮底图被抹掉；而 StaticPopup1 之后还会被组队邀请等对话框复用，
    -- 于是这些对话框也跟着坏掉，甚至在与真横幅同时出现时被当作「重复横幅」静音成点不到。
    local DIALOG_PREFIXES = {
        "StaticPopup", "LFGDungeonReady", "LFGInvitePopup", "LFGListInviteDialog", "LFDRoleCheckPopup",
        "ReadyCheckFrame", "PVPReadyDialog", "GroupInvite", "PartyInvite", "RolePollPopup",
        "PetBattleQueueReadyFrame", "ElvUI_StaticPopup",
    }
    local function IsDialogFrame(f)
        if not IsSafeReadableFrame(f) then return false end
        local okD, isDlg = pcall(function() return f.which ~= nil and f.button1 ~= nil end)
        if okD and isDlg then return true end
        if f.GetName then
            local okN, raw = pcall(f.GetName, f)
            local nm = okN and F.PlainString(raw, nil) or nil
            if nm then
                for _, p in ipairs(DIALOG_PREFIXES) do
                    if nm:sub(1, #p) == p then return true end
                end
            end
        end
        return false
    end

    local function ShouldSkipFrame(f)
        if not IsSafeReadableFrame(f) then return true end
        if IsDialogFrame(f) then return true end
        if f.GetFrameStrata then
            local okS, strata = pcall(f.GetFrameStrata, f)
            if okS and F.PlainString(strata, nil) == "TOOLTIP" then
                return true
            end
        end
        if f._brd and f.bg and f.text then
            return true
        end
        if f.GetName then
            local okN, raw = pcall(f.GetName, f)
            local nm = okN and F.PlainString(raw, nil) or nil
            if nm then
                for _, p in ipairs(SKIP_PREFIXES) do
                    if nm:sub(1, #p) == p then return true end
                end
            end
        end
        return false
    end

    local function IsWorldRefreshText(txt)
        if type(txt) ~= "string" or txt == "" then return false end
        if txt:find("默认灰框", 1, true) or txt:find("将无限服", 1, true)
            or txt:find("提示框统一", 1, true) or txt:find("Shift+左键", 1, true) then
            return false
        end
        if txt:find("世界会在", 1, true)
            and (txt:find("刷新", 1, true) or txt:find("分钟", 1, true) or txt:find("秒", 1, true)) then
            return true
        end
        if txt:find("周围的世界", 1, true) and txt:find("刷新", 1, true) then
            return true
        end
        local low = txt:lower()
        return low:find("world around you will refresh", 1, true) ~= nil
            or (low:find("world will refresh", 1, true) ~= nil)
    end

    local function SearchRefreshInFrame(f, depth)
        if not IsSafeReadableFrame(f) or depth > 3 then return nil, nil end
        if f.GetRegions then
            local okR, regions = pcall(function() return { f:GetRegions() } end)
            if okR and type(regions) == "table" then
                for _, reg in ipairs(regions) do
                    if reg and not (reg.IsForbidden and reg:IsForbidden()) and reg.GetObjectType then
                        local okT, ot = pcall(reg.GetObjectType, reg)
                        if okT and ot == "FontString" and reg.GetText then
                            local okS, rawTxt = pcall(reg.GetText, reg)
                            local t = okS and F.PlainString(rawTxt, nil) or nil
                            if IsWorldRefreshText(t) then
                                return f, reg
                            end
                        end
                    end
                end
            end
        end
        if depth < 3 and f.GetChildren then
            local okC, children = pcall(function() return { f:GetChildren() } end)
            if okC and type(children) == "table" then
                for _, ch in ipairs(children) do
                    if IsFrameShownSafe(ch) then
                        local hitF, hitFS = SearchRefreshInFrame(ch, depth + 1)
                        if hitF then return hitF, hitFS end
                    end
                end
            end
        end
        return nil, nil
    end

    local function ResolveOuterBanner(hitF)
        local cur = hitF
        if IsDialogFrame(cur) then return nil end
        for _ = 1, 3 do
            local okP, p = pcall(function() return cur and cur.GetParent and cur:GetParent() end)
            if not okP or not p or p == _G.UIParent or p == _G.WorldFrame or not IsSafeReadableFrame(p) then
                break
            end
            -- 文字落在对话框里：整段都不是横幅
            if IsDialogFrame(p) then return nil end
            local okW, rawW = pcall(p.GetWidth, p)
            local okH, rawH = pcall(p.GetHeight, p)
            local pw = okW and F.PlainNumber(rawW, 9999) or 9999
            local ph = okH and F.PlainNumber(rawH, 9999) or 9999
            if pw > 600 or ph > 220 or pw < 80 or ph < 24 then
                break
            end
            cur = p
        end
        return cur
    end

    -- 停掉暴雪自带的滑入/缩放/闪光 AnimationGroup，彻底消除出现时的残影与拖影
    local function StopBannerNativeAnims(f, depth)
        if not IsSafeReadableFrame(f) or (depth or 0) > 2 then return end
        if f.GetAnimationGroups then
            local okA, groups = pcall(function() return { f:GetAnimationGroups() } end)
            if okA and type(groups) == "table" then
                for _, ag in ipairs(groups) do
                    if ag and not ag._fuiFade and ag.IsPlaying and ag:IsPlaying() and ag.Stop then
                        pcall(ag.Stop, ag)
                    end
                end
            end
        end
        if (depth or 0) < 2 and f.GetChildren then
            local okC, children = pcall(function() return { f:GetChildren() } end)
            if okC and type(children) == "table" then
                for _, ch in ipairs(children) do
                    if ch and ch ~= wrSkin[f] and ch ~= wrBtnSkin[f] then
                        StopBannerNativeAnims(ch, (depth or 0) + 1)
                    end
                end
            end
        end
    end

    local function IsSmallActionButton(ch)
        if not IsSafeReadableFrame(ch) then return false end
        local okT, ot = pcall(ch.GetObjectType, ch)
        if not (okT and ot == "Button") then return false end
        local w = F.PlainNumber(ch.GetWidth and ch:GetWidth(), 0)
        local h = F.PlainNumber(ch.GetHeight and ch:GetHeight(), 0)
        return w >= 16 and w <= 48 and h >= 16 and h <= 48 and math_abs(w - h) <= 10
    end

    -- 横幅里带文字的普通按钮（如「立即刷新」）：不是左侧小图标钮，自身有底图和文字标签
    local function IsTextButton(ch)
        if not IsSafeReadableFrame(ch) or IsSmallActionButton(ch) then return false end
        local okT, ot = pcall(ch.GetObjectType, ch)
        return okT and (ot == "Button" or ot == "CheckButton")
    end

    -- 文字按钮交给 EUI 官方皮肤（扁平暗底 + 细边框 + 白字），保留可点击外观；没有 EUI 皮肤接口时保持原版
    local wrTextBtnSkinned = setmetatable({}, { __mode = "k" })
    local function SkinBannerTextButton(btn)
        if wrTextBtnSkinned[btn] then return end
        local S = F.Theme.GetSkinAPI and F.Theme.GetSkinAPI()
        if not (S and S.Button) then return end
        wrTextBtnSkinned[btn] = true
        pcall(S.Button, btn)
        if S.StateButtonLabel then pcall(S.StateButtonLabel, btn) end
    end

    local function MuteButtonStockTextures(btn, alpha)
        for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
            local fn = btn[getter]
            local t = fn and fn(btn)
            if t and t.SetAlpha then pcall(t.SetAlpha, t, alpha) end
        end
        if btn.GetRegions then
            for _, reg in ipairs({ btn:GetRegions() }) do
                if reg and reg.GetObjectType and reg:GetObjectType() == "Texture" and reg.SetAlpha then
                    pcall(reg.SetAlpha, reg, alpha)
                end
            end
        end
    end

    local function SkinBannerLeftButton(btn, box, want)
        if not IsSafeReadableFrame(btn) then return end
        local canMoveBtn = not (btn.IsProtected and btn:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown())
        if not want then
            local sk = wrBtnSkin[btn]
            if sk then sk:Hide() end
            MuteButtonStockTextures(btn, 1)
            -- 还原被内收到卡片左内侧的原生按钮锚点
            local o = wrBtnOrigPt[btn]
            if o and canMoveBtn then
                pcall(btn.ClearAllPoints, btn)
                pcall(btn.SetPoint, btn, o[1], o[2], o[3], o[4], o[5])
                wrBtnOrigPt[btn] = nil
            end
            return
        end
        MuteButtonStockTextures(btn, 0)
        local sk = wrBtnSkin[btn]
        if not sk then
            sk = CreateFrame("Frame", nil, btn)
            sk:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
            sk:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
            sk:SetFrameLevel((btn:GetFrameLevel() or 2) + 2)
            sk:EnableMouse(false)

            local ic = sk:CreateTexture(nil, "OVERLAY", nil, 4)
            ic:SetSize(14, 14)
            ic:SetPoint("CENTER", sk, "CENTER", 0, 0)
            ic:SetTexture(F.Theme.ICONS .. "Refresh.tga")
            ic:SetTexCoord(0, 1, 0, 1)
            sk._icon = ic
            wrBtnSkin[btn] = sk
        end
        F.Theme.StyleGlassSurface(sk, {
            accent = { 0.96, 0.76, 0.30 },
            bgAlpha = 0.88,
            borderAlpha = 0.85,
            restAura = 0.14,
            hoverAura = 0.34,
            borderTintMix = 0.30,
            hovered = btn.IsMouseOver and btn:IsMouseOver() or false,
        })
        if sk._icon then
            sk._icon:SetVertexColor(0.98, 0.82, 0.38, 0.96)
        end
        -- 将原本突出在左框外的红底按钮齐整内收至卡片左内侧
        if box and canMoveBtn then
            if not wrBtnOrigPt[btn] then
                local okP, p1, rel, p2, ox, oy = pcall(btn.GetPoint, btn, 1)
                p1, p2 = okP and F.PlainString(p1, nil), okP and F.PlainString(p2, nil)
                ox, oy = okP and F.PlainNumber(ox, nil), okP and F.PlainNumber(oy, nil)
                if p1 and ox and oy then
                    wrBtnOrigPt[btn] = { p1, rel, p2 or p1, ox, oy }
                end
            end
            pcall(btn.ClearAllPoints, btn)
            pcall(btn.SetPoint, btn, "LEFT", box, "LEFT", 10, 0)
        end
        sk:Show()
        if not wrBtnHooked[btn] then
            wrBtnHooked[btn] = true
            if btn.HookScript then
                btn:HookScript("OnShow", function(self)
                    if mod._active and mod:GetDB().skinWorldRefresh ~= false then
                        MuteButtonStockTextures(self, 0)
                    end
                end)
                btn:HookScript("OnEnter", function(self)
                    local s = wrBtnSkin[self]
                    if s and mod._active and mod:GetDB().skinWorldRefresh ~= false then
                        F.Theme.SetGlassState(s, true, false)
                        if s._icon then s._icon:SetVertexColor(1, 0.92, 0.65, 1) end
                    end
                end)
                btn:HookScript("OnLeave", function(self)
                    local s = wrBtnSkin[self]
                    if s then
                        F.Theme.SetGlassState(s, false, false)
                        if s._icon then s._icon:SetVertexColor(0.98, 0.82, 0.38, 0.96) end
                    end
                end)
            end
        end
    end

    local function MuteNativeBannerArt(box, alpha, depth)
        if not IsSafeReadableFrame(box) or (depth or 0) > 2 then return end
        if box.NineSlice and box.NineSlice.SetAlpha then
            pcall(box.NineSlice.SetAlpha, box.NineSlice, alpha)
        end
        if box.SetBackdropColor then
            pcall(box.SetBackdropColor, box, 0, 0, 0, alpha == 0 and 0 or 0.85)
        end
        if box.SetBackdropBorderColor then
            pcall(box.SetBackdropBorderColor, box, 0.5, 0.5, 0.5, alpha == 0 and 0 or 1)
        end
        for _, field in ipairs({ "Border", "Bg", "Background", "Center", "TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "Glow", "Shine" }) do
            local part = box[field]
            if type(part) == "table" and part.SetAlpha then pcall(part.SetAlpha, part, alpha) end
        end
        if box.GetRegions then
            for _, reg in ipairs({ box:GetRegions() }) do
                if reg and reg.GetObjectType and reg:GetObjectType() == "Texture" and reg.SetAlpha then
                    pcall(reg.SetAlpha, reg, alpha)
                end
            end
        end
        if (depth or 0) < 2 and box.GetChildren then
            for _, ch in ipairs({ box:GetChildren() }) do
                if ch and ch ~= wrSkin[box] and ch ~= wrBtnSkin[box]
                    and not IsSmallActionButton(ch) and not IsTextButton(ch) then
                    MuteNativeBannerArt(ch, alpha, (depth or 0) + 1)
                end
            end
        end
    end

    local function StyleBannerFontsAndButtons(box, want)
        local hasLeftBtn, hasTextBtn = false, false
        local mainFS = {}

        local function walk(f, depth)
            if not IsSafeReadableFrame(f) or depth > 2 then return end
            if f.GetRegions then
                for _, reg in ipairs({ f:GetRegions() }) do
                    if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                        if want then
                            F.Theme.ApplyFont(reg, 13, "", 0.88, 0.94, 1.0, 1)
                            if reg.SetSpacing then pcall(reg.SetSpacing, reg, 3) end
                            if reg.SetJustifyH then pcall(reg.SetJustifyH, reg, "CENTER") end
                            if reg.SetJustifyV then pcall(reg.SetJustifyV, reg, "MIDDLE") end
                            mainFS[#mainFS + 1] = reg
                        elseif wrOrigFS[reg] then
                            local o = wrOrigFS[reg]
                            pcall(reg.ClearAllPoints, reg)
                            pcall(reg.SetPoint, reg, o[1], o[2], o[3], o[4], o[5])
                            if reg.SetJustifyH and o[6] then pcall(reg.SetJustifyH, reg, o[6]) end
                        end
                    end
                end
            end
            if depth < 2 and f.GetChildren then
                for _, ch in ipairs({ f:GetChildren() }) do
                    if ch and ch ~= wrSkin[box] and ch ~= wrBtnSkin[f] then
                        if IsSmallActionButton(ch) then
                            hasLeftBtn = true
                            SkinBannerLeftButton(ch, box, want)
                        elseif IsTextButton(ch) then
                            -- 不进入按钮内部：它的文字标签属于按钮，绝不能被拉到横幅正中（会与正文叠字）
                            hasTextBtn = true
                            if want then SkinBannerTextButton(ch) end
                        else
                            walk(ch, depth + 1)
                        end
                    end
                end
            end
        end
        walk(box, 0)

        -- 真正居中排版只用于「单行倒计时 + 左侧小刷新钮」的简单横幅；
        -- 带文字按钮或多段文字的状态（如「立即刷新世界。」）保持暴雪原排版，避免几段文字挤到同一行重叠
        local simpleLayout = (not hasTextBtn) and #mainFS == 1
        if want and #mainFS > 0 and not simpleLayout then
            for _, fs in ipairs(mainFS) do
                local o = wrOrigFS[fs]
                if o then
                    pcall(fs.ClearAllPoints, fs)
                    pcall(fs.SetPoint, fs, o[1], o[2], o[3], o[4], o[5])
                    if fs.SetJustifyH and o[6] then pcall(fs.SetJustifyH, fs, o[6]) end
                end
            end
        end
        if want and simpleLayout then
            local sidePad = hasLeftBtn and 42 or 16
            for _, fs in ipairs(mainFS) do
                if not wrOrigFS[fs] and fs.GetPoint then
                    local okP, pt, rel, rpt, x, y = pcall(fs.GetPoint, fs, 1)
                    local jh = fs.GetJustifyH and F.PlainString(fs:GetJustifyH(), "LEFT") or "LEFT"
                    if okP and pt then
                        wrOrigFS[fs] = { pt, rel, rpt, F.PlainNumber(x, 0), F.PlainNumber(y, 0), jh }
                    end
                end
                pcall(fs.ClearAllPoints, fs)
                pcall(fs.SetPoint, fs, "LEFT", box, "LEFT", sidePad, 0)
                pcall(fs.SetPoint, fs, "RIGHT", box, "RIGHT", -sidePad, 0)
                if fs.SetJustifyH then pcall(fs.SetJustifyH, fs, "CENTER") end
                if fs.SetJustifyV then pcall(fs.SetJustifyV, fs, "MIDDLE") end
            end
        end
    end

    local function PositionWorldRefresh(box)
        if not IsSafeReadableFrame(box) then return end
        if not (mod._active and mod:GetDB().skinWorldRefresh ~= false) then return end
        if wrSuppressed[box] then return end
        F.RunOutOfCombat("FUI_MoveWorldRefresh", function()
            if not IsSafeReadableFrame(box) or wrSuppressed[box] then return end
            if not (mod._active and mod:GetDB().skinWorldRefresh ~= false) then return end
            local saved = F.DB and F.DB.GetPosition and F.DB.GetPosition("WorldRefresh")
            local pt = (saved and saved.point) or "TOP"
            local rpt = (saved and saved.relPoint) or pt
            local x = (saved and saved.x) or 0
            local y = (saved and saved.y) or -96
            -- 已在目标坐标 ±1.5px 内则不再重复 ClearAllPoints/SetPoint，杜绝布局抖动与拖影
            if box.GetPoint then
                local okP, cpt, crel, crpt, cx, cy = pcall(box.GetPoint, box, 1)
                cx = okP and F.PlainNumber(cx, nil) or nil
                cy = okP and F.PlainNumber(cy, nil) or nil
                if okP and cpt == pt and crel == _G.UIParent and crpt == rpt
                    and cx and cy and math_abs(cx - x) <= 1.5 and math_abs(cy - y) <= 1.5 then
                    return
                end
            end
            wrMoving = true
            pcall(box.ClearAllPoints, box)
            pcall(box.SetPoint, box, pt, _G.UIParent, rpt, x, y)
            wrMoving = false
        end)
    end

    -- EnableMouse 在受保护框体上战斗中会触发 ADDON_ACTION_BLOCKED（pcall 也挡不住报告），一律延后到脱战
    local function SetBannerMouse(dup, enabled)
        if not dup.EnableMouse then return end
        if _G.InCombatLockdown and _G.InCombatLockdown() then
            F.RunOutOfCombat("FUI_WRMouse_" .. tostring(dup), function()
                if IsSafeReadableFrame(dup) and (wrSuppressed[dup] == true) ~= enabled then
                    pcall(dup.EnableMouse, dup, enabled)
                end
            end)
        else
            pcall(dup.EnableMouse, dup, enabled)
        end
    end

    local function SilenceDuplicateBanner(dup, silent)
        if not IsSafeReadableFrame(dup) then return end
        wrSuppressed[dup] = silent and true or nil
        if silent then
            StopBannerNativeAnims(dup, 0)
            pcall(dup.SetAlpha, dup, 0)
            SetBannerMouse(dup, false)
            local ov = wrSkin[dup]
            if ov then ov:Hide() end
        else
            pcall(dup.SetAlpha, dup, 1)
            SetBannerMouse(dup, true)
        end
    end

    local function ApplySkinToBanner(box, playFadeIn)
        if not IsSafeReadableFrame(box) then return end
        local want = mod._active and (mod:GetDB().skinWorldRefresh ~= false)
        if not want then
            SilenceDuplicateBanner(box, false)
            local ov = wrSkin[box]
            if ov then ov:Hide() end
            MuteNativeBannerArt(box, 1, 0)
            StyleBannerFontsAndButtons(box, false)
            return
        end

        StopBannerNativeAnims(box, 0)
        MuteNativeBannerArt(box, 0, 0)
        StyleBannerFontsAndButtons(box, true)

        local ov = wrSkin[box]
        if not ov then
            ov = CreateFrame("Frame", nil, box)
            ov:SetAllPoints(box)
            local lvl = F.PlainNumber(box:GetFrameLevel(), 2)
            ov:SetFrameLevel(math_max(0, lvl - 1))
            ov:EnableMouse(false)

            local tipTag = ov:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(tipTag, 9, "OUTLINE", 0.76, 0.80, 0.88, 0.88)
            tipTag:SetPoint("TOP", ov, "BOTTOM", 7, -3)
            tipTag:SetText("Shift+左键拖动位置 · 左键点击立即刷新")
            ov._tipTag = tipTag

            local refIcon = ov:CreateTexture(nil, "OVERLAY", nil, 4)
            refIcon:SetSize(11, 11)
            refIcon:SetPoint("RIGHT", tipTag, "LEFT", -3, 0)
            refIcon:SetTexture(F.Theme.ICONS .. "Refresh.tga")
            refIcon:SetTexCoord(0, 1, 0, 1)
            ov._refIcon = refIcon

            wrSkin[box] = ov
        end

        F.Theme.StyleGlassSurface(ov, {
            accent = { 0.95, 0.74, 0.28 },
            bgAlpha = 0.92,
            borderAlpha = 0.90,
            restAura = 0.11,
            hoverAura = 0.26,
            borderTintMix = 0.24,
            hovered = box.IsMouseOver and box:IsMouseOver() or false,
        })
        if ov._refIcon then
            ov._refIcon:SetVertexColor(0.95, 0.76, 0.34, 0.90)
        end
        ov:Show()

        if not wrHooked[box] then
            wrHooked[box] = true
            if box.HookScript then
                box:HookScript("OnShow", function(self)
                    if wrSuppressed[self] then
                        SilenceDuplicateBanner(self, true)
                        return
                    end
                    ApplySkinToBanner(self, true)
                end)
                box:HookScript("OnEnter", function(self)
                    local s = wrSkin[self]
                    if s and mod._active and mod:GetDB().skinWorldRefresh ~= false then
                        F.Theme.SetGlassState(s, true, false)
                        if s._refIcon then s._refIcon:SetVertexColor(1.0, 0.88, 0.56, 1.0) end
                    end
                end)
                box:HookScript("OnLeave", function(self)
                    local s = wrSkin[self]
                    if s then
                        F.Theme.SetGlassState(s, false, false)
                        if s._refIcon then s._refIcon:SetVertexColor(0.95, 0.76, 0.34, 0.90) end
                    end
                end)
            end
            if box.SetPoint then
                _G.hooksecurefunc(box, "SetPoint", function(self)
                    if wrMoving or wrDragging or wrSuppressed[self] or wrPosQueued[self]
                        or not (mod._active and mod:GetDB().skinWorldRefresh ~= false) then
                        return
                    end
                    wrPosQueued[self] = true
                    C_Timer.After(0, function()
                        wrPosQueued[self] = nil
                        if not wrDragging and not wrSuppressed[self] and IsFrameShownSafe(self) then
                            StopBannerNativeAnims(self, 0)
                            PositionWorldRefresh(self)
                        end
                    end)
                end)
            end
            F.RunOutOfCombat("FUI_DragWorldRefresh", function()
                if not IsSafeReadableFrame(box) then return end
                pcall(box.SetMovable, box, true)
                pcall(box.SetClampedToScreen, box, true)
                pcall(box.RegisterForDrag, box, "LeftButton")
                if box.HookScript then
                    box:HookScript("OnDragStart", function(self)
                        if not (mod._active and mod:GetDB().skinWorldRefresh ~= false) then return end
                        if _G.IsShiftKeyDown and _G.IsShiftKeyDown() and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
                            wrDragging = true
                            wrDragBox[1] = self
                            pcall(self.StartMoving, self)
                        end
                    end)
                    box:HookScript("OnDragStop", function(self)
                        -- 未按 Shift 的普通拖动也会触发 OnDragStop：只处理本模块发起的拖动，否则会误存坐标
                        if not wrDragging then return end
                        wrDragging = false
                        wrDragBox[1] = nil
                        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
                        pcall(self.StopMovingOrSizing, self)
                        local pt, _, rpt, x, y = self:GetPoint(1)
                        -- SavePosition 内部过滤 12.x 机密值与非法锚点
                        if F.DB and F.DB.SavePosition then
                            F.DB.SavePosition("WorldRefresh", pt, rpt, x, y)
                        end
                    end)
                    box:HookScript("OnHide", function(self)
                        if not wrDragging or wrDragBox[1] ~= self then return end
                        wrDragging = false
                        wrDragBox[1] = nil
                        if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
                            pcall(self.StopMovingOrSizing, self)
                        end
                    end)
                end
            end)
        end

        PositionWorldRefresh(box)
        if playFadeIn then
            pcall(box.SetAlpha, box, 0)
            F.Theme.FadeTo(box, 1.0, 0.22)
        end
    end

    local function ReconcileBanners()
        local want = mod._active and (mod:GetDB().skinWorldRefresh ~= false)
        if not want then
            for _, b in pairs(wrList) do
                ApplySkinToBanner(b, false)
            end
            wrPrimaryBox[1] = nil
            return
        end
        -- 旧版本登记过的系统对话框：还原成原样并从横幅列表剔除
        for k, b in pairs(wrList) do
            if IsDialogFrame(b) then
                SilenceDuplicateBanner(b, false)
                local ov = wrSkin[b]
                if ov then ov:Hide() end
                MuteNativeBannerArt(b, 1, 0)
                StyleBannerFontsAndButtons(b, false)
                if wrPrimaryBox[1] == b then wrPrimaryBox[1] = nil end
                wrList[k] = nil
            end
        end
        local shownList = {}
        for _, b in pairs(wrList) do
            if IsFrameShownSafe(b) then
                shownList[#shownList + 1] = b
            end
        end
        if #shownList == 0 then
            wrPrimaryBox[1] = nil
            return
        end
        -- 多个刷新框同时出现时（例如顶部主条 + 聊框上方暴雪原版横幅），只保留一个主卡片，静音重复原版框
        local curPrim = wrPrimaryBox[1]
        local chosen = (curPrim and IsFrameShownSafe(curPrim)) and curPrim or shownList[1]
        wrPrimaryBox[1] = chosen
        for _, b in ipairs(shownList) do
            if b == chosen then
                if wrSuppressed[b] then SilenceDuplicateBanner(b, false) end
                ApplySkinToBanner(b, false)
            else
                SilenceDuplicateBanner(b, true)
            end
        end
    end

    local function RefreshWorldRefreshBannerInner()
        local want = mod._active and (mod:GetDB().skinWorldRefresh ~= false)
        if not want then
            ReconcileBanners()
            return
        end
        -- 战斗中或副本/战场内不遍历 UIParent 子框体，零团本 CPU 抖动
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        if _G.IsInInstance then
            local inInst, iType = _G.IsInInstance()
            if inInst and (iType == "raid" or iType == "party" or iType == "pvp" or iType == "arena") then
                return
            end
        end
        local ui = _G.UIParent
        if ui and ui.GetChildren then
            local okC, children = pcall(function() return { ui:GetChildren() } end)
            if okC and type(children) == "table" then
                for _, ch in ipairs(children) do
                    if not wrKnown[ch] and not ShouldSkipFrame(ch) and IsFrameShownSafe(ch) then
                        local okW, rw = pcall(ch.GetWidth, ch)
                        local okH, rh = pcall(ch.GetHeight, ch)
                        local cw = okW and F.PlainNumber(rw, 0) or 0
                        local chH = okH and F.PlainNumber(rh, 0) or 0
                        -- 仅对尺寸接近横幅/容器的框体向下扫描，跳过大面积全屏/微距装饰框以杜绝每几秒的 Lua 表垃圾分配
                        if cw >= 120 and cw <= 720 and chH >= 24 and chH <= 260 then
                            local hitF = SearchRefreshInFrame(ch, 0)
                            if hitF then
                                local outer = ResolveOuterBanner(hitF)
                                if outer and not wrKnown[outer] then
                                    wrKnown[outer] = true
                                    wrList[#wrList + 1] = outer
                                end
                            end
                        end
                    end
                end
            end
        end
        ReconcileBanners()
    end

    RefreshWorldRefreshBanner = function()
        pcall(RefreshWorldRefreshBannerInner)
    end

    EnsureWorldRefreshTicker = function()
        if wrTicker then return end
        if C_Timer and C_Timer.NewTicker then
            -- 平时已靠 CHAT_MSG_SYSTEM / UI_INFO_MESSAGE 毫秒级触发，后台兜底改为 15 秒极轻量巡检（零卡顿）
            wrTicker = C_Timer.NewTicker(15.0, RefreshWorldRefreshBanner)
        end
    end

    StopWorldRefreshTicker = function()
        if wrTicker then
            wrTicker:Cancel()
            wrTicker = nil
        end
    end

    StopWorldRefreshDrag = function()
        if not wrDragging then return end
        local b = wrDragBox[1]
        wrDragging = false
        wrDragBox[1] = nil
        if b and IsSafeReadableFrame(b) and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            pcall(b.StopMovingOrSizing, b)
            local pt, _, rpt, x, y = b:GetPoint(1)
            if F.DB and F.DB.SavePosition then
                F.DB.SavePosition("WorldRefresh", pt, rpt, x, y)
            end
        end
    end
end


MC.HookTrainerFrameIfReady = HookTrainerFrameIfReady
MC.BeginTrainerOpenSession = BeginTrainerOpenSession
MC.ApplyTrainerFilterForOpen = ApplyTrainerFilterForOpen
MC.QueuePolishTrainerRows = QueuePolishTrainerRows
MC.ResetTrainerSession = ResetTrainerSession
MC.HandleTrainerUpdate = function()
    if applyingTrainerFilter then return end
    HookTrainerFrameIfReady()
    local ctf = _G.ClassTrainerFrame
    if ctf and ctf:IsShown() and not trainerSessionActive then
        BeginTrainerOpenSession()
    elseif trainerOpenGen > 0 and trainerDoneGen ~= trainerOpenGen and trainerUserTouchedGen ~= trainerOpenGen then
        local gen = trainerOpenGen
        C_Timer.After(0, function()
            if trainerOpenGen == gen and trainerDoneGen ~= gen then
                ApplyTrainerFilterForOpen(gen, "update")
            end
        end)
    end
    QueuePolishTrainerRows()
end
MC.ApplyWorldTextScale = ApplyWorldTextScale
MC.RestoreWorldTextScale = RestoreWorldTextScale
MC.HookCombatTextSizing = HookCombatTextSizing
MC.RefreshWorldRefreshBanner = RefreshWorldRefreshBanner
MC.StopWorldRefreshTicker = StopWorldRefreshTicker
MC.EnsureWorldRefreshTicker = EnsureWorldRefreshTicker
MC.StopWorldRefreshDrag = StopWorldRefreshDrag
