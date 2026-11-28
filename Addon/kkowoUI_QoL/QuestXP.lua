----------------------------------------------------------------------
--  kkowoUI — Modules/QuestXP.lua
--  在 EllesmereUI 自定义任务追踪行显示：
--    1) 标题前 [等级] 难度着色前缀（原 BlizzUIEnhance.showQuestLevel）
--    2) 标题右侧预计经验值 +XP（所有行统一垂直右对齐，自动避让任务道具图标）
--  • 仅使用官方公开 API：EllesmereUI.RegisterQuestTrackerRow
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local math_abs, math_ceil, math_max = math.abs, math.ceil, math.max
local pcall, setmetatable, tonumber, type = pcall, setmetatable, tonumber, type
local string_format = string.format

local mod = F.RegisterModule("questXP", {
    title = "任务等级与经验",
    desc = "在任务追踪栏显示难度着色等级，并在右侧对齐标注预计经验。",
    group = "quest",
    order = 30,
    defaults = {
        enabled = true,
        showQuestLevel = true,
        showQuestXP = true,
        fontSize = 11,
        useAccentColor = false,
    },
})

local registered = false
local slotTexts = setmetatable({}, { __mode = "k" })
local itemRows = {}
local hookedItemBtns = setmetatable({}, { __mode = "k" })
local itemLayerRef = nil
local itemSyncPending = false
local movingItemBtn = false

-- 拆分已有的 [等级] 前缀（兼容 [21] / [21+] / [16D] / 已着色前缀），绝不重复叠加导致换行挤压下方目标
local function SplitLevelPrefix(s)
    local tag, rest = s:match("^|c%x%x%x%x%x%x%x%x(%[%d+[^%]]*%])%s*|r%s*(.*)$")
    if tag then
        return tag, rest
    end
    tag, rest = s:match("^(%[%d+[^%]]*%])%s+(.*)$")
    if tag then
        return tag, rest
    end
    return nil, s
end

local function ColorizeLevelTag(tag, questID)
    local lvl = nil
    local fn = _G.C_QuestLog and _G.C_QuestLog.GetQuestDifficultyLevel
    if fn and questID then
        local ok, v = pcall(fn, questID)
        lvl = ok and F.PlainNumber(v, nil) or nil
    end
    if (not lvl or lvl <= 0) and tag then
        lvl = tonumber(tag:match("%d+"))
    end
    if not lvl or lvl <= 0 then
        return tag or ""
    end
    local label = tag or ("[" .. lvl .. "]")
    local c = _G.GetQuestDifficultyColor and _G.GetQuestDifficultyColor(lvl)
    if c and c.r and c.g and c.b then
        return "|cff" .. F.RGBToHex(c.r, c.g, c.b) .. label .. "|r"
    end
    return label
end

local function ApplyTitleLevel(titleFS, questID, active, wantLevel)
    if not (titleFS and titleFS.GetText and titleFS.SetText) then
        return
    end
    local cur = F.PlainString(titleFS:GetText(), nil)
    if not cur or cur == "" then
        return
    end
    local existingTag, rest = SplitLevelPrefix(cur)
    local want
    if active and wantLevel then
        -- 已有暴雪/EUI 前缀（如 [21+]）时仅原地着色，零额外字符，绝不改变 EUI 已测量的行高
        local colored = ColorizeLevelTag(existingTag, questID)
        want = colored ~= "" and (colored .. " " .. rest) or rest
    elseif not active then
        -- 模块停用时仅去掉我们的染色代码，完整保留暴雪/EUI 原生 [等级] 前缀
        want = (existingTag and existingTag ~= "") and (existingTag .. " " .. rest) or rest
    else
        want = rest
    end
    if want ~= cur then
        pcall(titleFS.SetText, titleFS, want)
    end
end

-- 经验缓存只在本次登录、本角色、当前等级内有效（升级时清空）：
-- 以前存在账号级 SavedVariables 里，换小号或满级后 API 返回 0 时会显示别的角色/旧等级的假经验
local sessionXP = {}

local function FetchQuestXP(questID)
    if not questID then
        return nil
    end
    local xp = nil
    if _G.GetQuestLogRewardXP then
        local ok, val = pcall(_G.GetQuestLogRewardXP, questID)
        val = ok and F.PlainNumber(val, nil) or nil
        if val and val > 0 then
            xp = val
        end
    end
    if xp then
        sessionXP[questID] = xp
        return xp
    end
    return sessionXP[questID]
end

local SyncAllItemButtons

local function ScheduleItemSync()
    if itemSyncPending then return end
    itemSyncPending = true
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, SyncAllItemButtons)
    else
        SyncAllItemButtons()
    end
end

local function IsEUIQuestItemButton(f)
    if type(f) ~= "table" or (f.IsForbidden and f:IsForbidden()) or not f.IsObjectType then return false end
    local ok, isBtn = pcall(f.IsObjectType, f, "Button")
    if not (ok and isBtn) then return false end
    if type(f.questID) ~= "number" or not f.icon or not f.cd or not f.count then
        return false
    end
    if type(f.lastX) ~= "number" or type(f.lastY) ~= "number" then
        return false
    end
    local okAttr, attr = pcall(f.GetAttribute, f, "type")
    return okAttr and F.PlainString(attr, nil) == "item"
end

local function FindEUIItemLayer()
    if itemLayerRef then
        return itemLayerRef
    end
    -- 不做时间节流：登录时追踪器会在 1 秒内连续重绘多次，第一次扫描时道具按钮往往还没建好，
    -- 节流会让后面几次被跳过，道具图标就一直压在经验数字上（直到下次任务日志变化）。
    -- 调用方 ScheduleItemSync 已按帧合并，找到后缓存 itemLayerRef，不会反复扫描。
    local uiParent = _G.UIParent
    if not (uiParent and uiParent.GetChildren) then return nil end
    local children = { uiParent:GetChildren() }
    for i = 1, #children do
        local ch = children[i]
        if type(ch) == "table" and not (ch.IsForbidden and ch:IsForbidden())
            and ch.GetName and not ch:GetName() and ch.GetChildren then
            local okSubs, subs = pcall(function() return { ch:GetChildren() } end)
            subs = okSubs and subs or {}
            for j = 1, #subs do
                if IsEUIQuestItemButton(subs[j]) then
                    itemLayerRef = ch
                    return ch
                end
            end
        end
    end
    return nil
end

-- 将带任务道具行的道具图标安放在经验数字左侧（不污染安全按钮字段，战斗中顺延至脱战）
local function RepositionItemButton(b, expectedY)
    if movingItemBtn or not (b and not (b.IsForbidden and b:IsForbidden()) and b.IsShown and b:IsShown()) then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_QuestXPItems", SyncAllItemButtons)
        return
    end
    local qid = type(b.questID) == "number" and b.questID or nil
    local info = qid and itemRows[qid]
    if not info then return end
    local rowLine = info.line
    local listFrame = info.listFrame
    if not (rowLine and rowLine:IsShown() and listFrame) then return end

    local lr = F.PlainNumber(rowLine:GetRight(), nil)
    local lt = F.PlainNumber(rowLine:GetTop(), nil)
    local listRight = F.PlainNumber(listFrame:GetRight(), nil)
    if not (lr and lt and listRight) then return end

    local ls = F.PlainNumber(rowLine:GetEffectiveScale(), 1)
    local bs = F.PlainNumber(b:GetEffectiveScale(), 1)
    if bs <= 0 then bs = 1 end
    local s = ls / bs
    local targetY = lt * s

    -- EUI SyncItems 在复用安全按钮时先 SetPoint 再写 b.questID；若 Y 坐标与旧 questID 行不匹配，延迟到本帧结束后同步
    if expectedY and math_abs(expectedY - targetY) > 1.5 then
        ScheduleItemSync()
        return
    end

    local btnW = F.PlainNumber(b:GetWidth(), 0)
    local itemSize = (btnW > 1 and s > 0) and (btnW / s) or math_max(16, (info.itemW or 32) - 8)
    local targetLeft
    if mod._active == true and info.xpShown then
        local xpW = info.fs and F.PlainNumber(info.fs:GetStringWidth(), 0) or 0
        local xpCol = math_max(34, math_ceil(xpW))
        targetLeft = listRight - xpCol - 6 - itemSize
        local minLeft = lr + 4
        if targetLeft < minLeft then
            targetLeft = minLeft
        end
    else
        -- 关闭经验显示或该任务无经验时恢复 EUI 默认最右侧位置
        targetLeft = listRight - itemSize - 4
    end

    local targetX = targetLeft * s
    movingItemBtn = true
    pcall(b.ClearAllPoints, b)
    pcall(b.SetPoint, b, "TOPLEFT", _G.UIParent, "BOTTOMLEFT", targetX, targetY)
    movingItemBtn = false
end

local function HookItemButton(b)
    if hookedItemBtns[b] or not _G.hooksecurefunc then return end
    hookedItemBtns[b] = true
    _G.hooksecurefunc(b, "SetPoint", function(self, _, _, _, _, py)
        -- 停用后完全交还给 EUI 自己摆放，不再改写道具按钮位置
        if movingItemBtn or not mod._active then return end
        RepositionItemButton(self, F.PlainNumber(py, nil))
    end)
end

SyncAllItemButtons = function()
    itemSyncPending = false
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_QuestXPItems", SyncAllItemButtons)
        return
    end
    local layer = FindEUIItemLayer()
    if not (layer and layer.GetChildren) then return end
    local btns = { layer:GetChildren() }
    for i = 1, #btns do
        local b = btns[i]
        if IsEUIQuestItemButton(b) then
            HookItemButton(b)
            if b:IsShown() then
                RepositionItemButton(b)
            end
        end
    end
end

-- 无论该行是否包含任务道具图标，经验文字一律贴紧列表最右侧垂直齐平；返回该行被道具图标占用的右侧偏移 itemW
local function AnchorAlignedXP(fs, slot)
    local rowLine = slot and slot:GetParent()
    local listFrame = rowLine and rowLine:GetParent()
    local xOff = 0
    if rowLine and listFrame then
        local listW = F.PlainNumber(listFrame:GetWidth(), 0)
        local rowW = F.PlainNumber(rowLine:GetWidth(), 0)
        local slotW = F.PlainNumber(slot:GetWidth(), 46)
        local _, _, _, rowX = rowLine:GetPoint(1)
        local _, _, _, slotX = slot:GetPoint(1)
        rowX = F.PlainNumber(rowX, 0)
        slotX = F.PlainNumber(slotX, 0)
        if listW > 0 and rowW > 0 then
            local delta = listW - (rowX + rowW + slotX + slotW)
            if delta > 1 and delta < 96 then
                xOff = delta
            end
        end
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPRIGHT", slot, "TOPRIGHT", xOff, -1)
    return xOff, rowLine, listFrame
end

local function RenderRow(slot, questID, titleFS)
    local db = mod:GetDB()
    local active = mod._active == true

    -- 1) 任务等级前缀（原地着色不重复、不触发额外换行）
    ApplyTitleLevel(titleFS, questID, active, db.showQuestLevel ~= false)

    -- 2) 最右侧齐平的经验标注（含道具按钮的行自动将道具图标放到经验左侧）
    local fs = slotTexts[slot]
    if not fs then
        fs = slot:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("RIGHT")
        slotTexts[slot] = fs
    end
    local showXP = active and db.showQuestXP ~= false
    local xp = showXP and FetchQuestXP(questID) or nil
    local xpShown = (xp and xp > 0) and true or false
    if xpShown then
        if db.useAccentColor then
            local r, g, b = F.Theme.GetAccent()
            F.Theme.ApplyFont(fs, db.fontSize or 11, "", r, g, b, 0.92)
        else
            F.Theme.ApplyFont(fs, db.fontSize or 11, "", 0.78, 0.62, 0.98, 0.92)
        end
        fs:SetText(string_format("+%s", F.FormatShortNumber(xp)))
        fs:Show()
    else
        fs:Hide()
    end

    local xOff, rowLine, listFrame = AnchorAlignedXP(fs, slot)
    if questID then
        if xOff > 1 and rowLine and listFrame then
            local info = itemRows[questID]
            if not info then
                info = {}
                itemRows[questID] = info
            end
            info.line = rowLine
            info.listFrame = listFrame
            info.slot = slot
            info.fs = fs
            info.itemW = xOff
            info.xpShown = xpShown
            ScheduleItemSync()
        else
            itemRows[questID] = nil
        end
    end
end

local function RefreshRows()
    local EUI = _G.EllesmereUI
    if EUI and EUI.RefreshQuestTrackerRows then
        pcall(EUI.RefreshQuestTrackerRows)
    end
end

function mod:OnEnable()
    local EUI = _G.EllesmereUI
    if not registered and EUI and EUI.RegisterQuestTrackerRow then
        -- 预留 46px 恰好容纳 "+12.5k" 并释放更多任务标题宽度，避免长标题提前折行
        local ok = pcall(EUI.RegisterQuestTrackerRow, F.NAME, RenderRow, 46)
        if ok then
            registered = true
        end
    end
    -- 旧版账号级经验缓存已停用：清空以免 SavedVariables 无限增长
    local db = self:GetDB()
    if type(db.cache) == "table" then
        db.cache = nil
    end
    self:RegisterEvent("QUEST_LOG_UPDATE", RefreshRows)
    self:RegisterEvent("QUEST_REMOVED", function(_, _, qid)
        if qid then itemRows[qid] = nil end
    end)
    self:RegisterEvent("PLAYER_LEVEL_UP", function()
        -- 任务经验随等级变化：升级后旧值作废
        for k in pairs(sessionXP) do sessionXP[k] = nil end
        RefreshRows()
    end)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", RefreshRows)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        RefreshRows()
        if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0.6, function() if mod._active then RefreshRows() end end)
            _G.C_Timer.After(1.8, function() if mod._active then RefreshRows() end end)
        end
    end)
    RefreshRows()
end

function mod:OnDisable()
    for k in pairs(itemRows) do itemRows[k] = nil end
    RefreshRows()
end

function mod:OnThemeChanged()
    RefreshRows()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "显示任务等级",
        tooltip = "在任务追踪栏标题前显示按难度着色的任务等级（如 [22]）。",
        getValue = function() return db.showQuestLevel ~= false end,
        setValue = function(v) db.showQuestLevel = v == true; RefreshRows() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示预计经验",
        getValue = function() return db.showQuestXP ~= false end,
        setValue = function(v) db.showQuestXP = v == true; RefreshRows() end,
    }, {
        type = "toggle",
        text = "经验用主题色",
        tooltip = "关闭时使用柔和经验紫，开启后跟随当前主题色。",
        getValue = function() return db.useAccentColor == true end,
        setValue = function(v) db.useAccentColor = v == true; RefreshRows() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "经验文字字号",
        min = 9, max = 16, step = 1,
        getValue = function() return db.fontSize or 11 end,
        setValue = function(v) db.fontSize = v; RefreshRows() end,
    }, blank)
    y = y - h
    return y
end
