----------------------------------------------------------------------
--  kkowoUI — Modules/QuestAuto.lua
--  零竞态自动接/交任务 + 现代 C_GossipInfo 自动对话 + 装备升级防误选
--  • 修复原版 0.05s 延迟后未重检 QuestFrame:IsShown() / Shift 键问题
--  • 修复单一可选奖励直接点击完成按钮可能未选中问题
--  • 自动接管并关闭 EUI QuestTracker 同名开关，避免抢点
--  • 按住 Shift 打开任务窗口时显示简洁「已暂停自动」徽标
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, select, tostring = ipairs, pairs, pcall, select, tostring
local GetTime = GetTime
local C_Timer = C_Timer

local mod = F.RegisterModule("questAuto", {
    title = "自动接交任务",
    desc = "自动接取/提交任务、单选项自动对话；按住 Shift 临时跳过并在任务框显示暂停提示。",
    group = "quest",
    order = 10,
    defaults = {
        enabled = true,
        autoAccept = false,
        autoTurnIn = true,
        skipTrivial = true,
        pickBestReward = false,
        protectEquipRewards = true,
        autoGossip = false,
        autoConfirmBind = false,
    },
})

local lastPickKey, lastPickTime = nil, 0
local lastNote, lastNoteTime = nil, 0
local pauseBadge = nil

local function Note(msg)
    local now = GetTime()
    if msg == lastNote and now - lastNoteTime < 4 then
        return
    end
    lastNote, lastNoteTime = msg, now
    F.Print(msg)
end

local function FreshPick(key)
    local now = GetTime()
    if key == lastPickKey and now - lastPickTime < 2 then
        return false
    end
    lastPickKey, lastPickTime = key, now
    return true
end

local function UpdatePauseBadge(show)
    local qf = _G.QuestFrame
    if not qf then
        return
    end
    if show and not pauseBadge then
        pauseBadge = qf:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(pauseBadge, 11, "", 0.94, 0.75, 0.34, 1)
        pauseBadge:SetPoint("TOPRIGHT", qf, "TOPRIGHT", -32, -8)
        pauseBadge:SetText("[Shift 已暂停自动]")
    end
    if pauseBadge then
        pauseBadge:SetShown(show == true)
    end
end

local function TakeOverEUIQuestAuto()
    local EQT = _G.EllesmereUIQuestTracker
    if not (EQT and EQT.Cfg and EQT.Set) then
        return
    end
    local db = mod:GetDB()
    local changed = false
    local map = { autoAccept = "autoAccept", autoTurnIn = "autoTurnIn" }
    for eqtKey, ourKey in pairs(map) do
        local ok, on = pcall(EQT.Cfg, eqtKey)
        if ok and on == true then
            db[ourKey] = true
            pcall(EQT.Set, eqtKey, false)
            changed = true
        end
    end
    if changed and EQT.SyncAutoQuests then
        pcall(EQT.SyncAutoQuests)
    end
end

local function GossipQuestComplete(q)
    if q.isComplete then
        return true
    end
    if q.questID and _G.C_QuestLog and _G.C_QuestLog.IsComplete then
        local ok, done = pcall(_G.C_QuestLog.IsComplete, q.questID)
        if ok and done then
            return true
        end
    end
    return false
end

local function GetItemInfoCompat(link)
    if _G.C_Item and _G.C_Item.GetItemInfo then
        return _G.C_Item.GetItemInfo(link)
    end
    if _G.GetItemInfo then
        return _G.GetItemInfo(link)
    end
end

-- 判断多选奖励中是否有本职业可用的装备（武器/护甲/饰品/戒指/项链）
local function HasUsableEquipReward(n)
    local isUsable = _G.IsUsableItem or (_G.C_Item and _G.C_Item.IsUsableItem)
    for i = 1, n do
        local link = _G.GetQuestItemLink and _G.GetQuestItemLink("choice", i)
        if not link then
            return true -- 物品未缓存时保守停手
        end
        local itemName, _, _, _, _, _, _, _, equipLoc = GetItemInfoCompat(link)
        if not itemName then
            return true -- 链接已有但物品数据未缓存：同样保守停手，绝不替玩家选奖励
        end
        if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG" then
            if not isUsable or isUsable(link) then
                return true
            end
        end
    end
    return false
end

local function BestVendorRewardIndex(n)
    local best, bestPrice = nil, -1
    for i = 1, n do
        local link = _G.GetQuestItemLink and _G.GetQuestItemLink("choice", i)
        if not link then
            return nil
        end
        local price = select(11, GetItemInfoCompat(link))
        if type(price) ~= "number" then
            return nil
        end
        if price > bestPrice then
            best, bestPrice = i, price
        end
    end
    return best
end

local function ClickIfReady(btn)
    if btn and btn:IsVisible() and btn:IsEnabled() then
        btn:Click()
        return true
    end
    return false
end

local function TryAutoGossip(db)
    if not db.autoGossip then
        return
    end
    local G = _G.C_GossipInfo
    if not (G and G.GetOptions and G.SelectOption) then
        return
    end
    local avail = G.GetAvailableQuests and G.GetAvailableQuests() or {}
    local active = G.GetActiveQuests and G.GetActiveQuests() or {}
    if #avail > 0 or #active > 0 then
        return
    end
    local opts = G.GetOptions() or {}
    if #opts == 1 and opts[1] and opts[1].gossipOptionID then
        -- 避免自动点开银行/飞行/旅店以外的危险确认，仅自动继续单一对话项
        if FreshPick("gossip_" .. tostring(opts[1].gossipOptionID)) then
            G.SelectOption(opts[1].gossipOptionID)
        end
    end
end

function mod:OnQuestEvent(event)
    local db = self:GetDB()
    -- 这两个事件必须在 Shift 判定之前处理：MODIFIER_STATE_CHANGED 在全世界任意按 Shift 都会触发，
    -- 只在任务窗口打开时才更新暂停角标；按住 Shift 关闭任务窗口也要能收起角标
    if event == "QUEST_FINISHED" then
        UpdatePauseBadge(false)
        return
    elseif event == "MODIFIER_STATE_CHANGED" then
        if _G.QuestFrame and _G.QuestFrame:IsShown() then
            UpdatePauseBadge((_G.IsShiftKeyDown and _G.IsShiftKeyDown()) and (db.autoAccept or db.autoTurnIn))
        end
        return
    end

    local shift = _G.IsShiftKeyDown and _G.IsShiftKeyDown()
    UpdatePauseBadge(shift and (db.autoAccept or db.autoTurnIn))
    if shift then
        return
    end

    if event == "GOSSIP_SHOW" then
        local G = _G.C_GossipInfo
        if not G then
            return
        end
        if db.autoTurnIn and G.GetActiveQuests then
            for _, q in ipairs(G.GetActiveQuests() or {}) do
                if q.questID and GossipQuestComplete(q) then
                    if FreshPick("t" .. q.questID) then
                        G.SelectActiveQuest(q.questID)
                    end
                    return
                end
            end
        end
        if db.autoAccept and G.GetAvailableQuests then
            for _, q in ipairs(G.GetAvailableQuests() or {}) do
                local skip = q.isTrivial and db.skipTrivial ~= false
                if q.questID and not skip then
                    if FreshPick("a" .. q.questID) then
                        G.SelectAvailableQuest(q.questID)
                    end
                    return
                end
            end
        end
        TryAutoGossip(db)

    elseif event == "QUEST_GREETING" then
        if db.autoTurnIn then
            for i = 1, (_G.GetNumActiveQuests and _G.GetNumActiveQuests() or 0) do
                local title, isComplete = _G.GetActiveTitle(i)
                if isComplete then
                    if FreshPick("gt" .. tostring(title)) then
                        _G.SelectActiveQuest(i)
                    end
                    return
                end
            end
        end
        if db.autoAccept then
            for i = 1, (_G.GetNumAvailableQuests and _G.GetNumAvailableQuests() or 0) do
                local isTrivial, _, _, _, questID = _G.GetAvailableQuestInfo(i)
                local skip = isTrivial and db.skipTrivial ~= false
                if not skip then
                    if FreshPick("ga" .. tostring(questID or i)) then
                        _G.SelectAvailableQuest(i)
                    end
                    return
                end
            end
        end

    elseif event == "QUEST_DETAIL" then
        if not db.autoAccept then
            return
        end
        local id = _G.GetQuestID and _G.GetQuestID()
        local trivial = id and _G.C_QuestLog and _G.C_QuestLog.IsQuestTrivial and _G.C_QuestLog.IsQuestTrivial(id)
        if trivial and db.skipTrivial ~= false then
            return
        end
        if _G.AcceptQuest then
            _G.AcceptQuest()
        end

    elseif event == "QUEST_PROGRESS" then
        if not db.autoTurnIn then
            return
        end
        C_Timer.After(0.05, function()
            if not self._active then return end
            if _G.IsShiftKeyDown and _G.IsShiftKeyDown() then return end
            if not (_G.QuestFrame and _G.QuestFrame:IsShown()) then return end
            local money = (_G.GetQuestMoneyToGet and _G.GetQuestMoneyToGet()) or 0
            if money > 0 then
                Note("该任务需要支付金币才能交付，已暂停自动提交。")
                return
            end
            if ClickIfReady(_G.QuestFrameCompleteButton) then
                return
            end
            if _G.IsQuestCompletable and _G.IsQuestCompletable() and _G.CompleteQuest then
                _G.CompleteQuest()
            else
                Note("任务物品尚未集齐，无法交付。")
            end
        end)

    elseif event == "QUEST_COMPLETE" then
        if not db.autoTurnIn then
            return
        end
        C_Timer.After(0.05, function()
            if not self._active then return end
            if _G.IsShiftKeyDown and _G.IsShiftKeyDown() then return end
            if not (_G.QuestFrame and _G.QuestFrame:IsShown()) then return end
            local money = (_G.GetQuestMoneyToGet and _G.GetQuestMoneyToGet()) or 0
            if money > 0 then
                Note("该任务需要支付金币才能交付，已暂停自动提交。")
                return
            end
            local n = (_G.GetNumQuestChoices and _G.GetNumQuestChoices()) or 0
            if n > 1 then
                if not db.pickBestReward then
                    Note(("有 %d 个奖励可选，请手动挑选。"):format(n))
                    return
                end
                if db.protectEquipRewards and HasUsableEquipReward(n) then
                    Note("可选奖励中包含可用装备，已停下请你手动挑选。")
                    return
                end
                local best = BestVendorRewardIndex(n)
                if not best then
                    Note("奖励物品信息加载中，请手动挑选。")
                    return
                end
                _G.GetQuestReward(best)
                return
            elseif n == 1 then
                -- 单一可选奖励直接传 1，避免未选中直接点按钮报红字
                _G.GetQuestReward(1)
                return
            end
            if not ClickIfReady(_G.QuestFrameCompleteQuestButton) and _G.GetQuestReward then
                _G.GetQuestReward(n > 0 and 1 or nil)
            end
        end)

    end
end

function mod:OnConfirmEvent(event, slotOrRoll, roll, ...)
    local db = self:GetDB()
    if not db.autoConfirmBind then
        return
    end
    if event == "CONFIRM_LOOT_ROLL" and _G.ConfirmLootRoll then
        _G.ConfirmLootRoll(slotOrRoll, roll)
        if _G.StaticPopup_Hide then _G.StaticPopup_Hide("CONFIRM_LOOT_ROLL") end
    elseif event == "LOOT_BIND_CONFIRM" and _G.ConfirmLootSlot then
        _G.ConfirmLootSlot(slotOrRoll)
        if _G.StaticPopup_Hide then _G.StaticPopup_Hide("LOOT_BIND", ...) end
    end
end

function mod:GetMode(kind)
    local db = self:GetDB()
    return db[kind] == true
end

function mod:SetMode(kind, val)
    local db = self:GetDB()
    db[kind] = val == true
    local bar = F.Modules.Get("questBar")
    if bar and bar.Refresh then
        bar:Refresh()
    end
end

function mod:OnEnable()
    TakeOverEUIQuestAuto()
    local evs = {
        "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL",
        "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_FINISHED", "MODIFIER_STATE_CHANGED",
    }
    for _, ev in ipairs(evs) do
        self:RegisterEvent(ev, self.OnQuestEvent)
    end
    self:RegisterEvent("CONFIRM_LOOT_ROLL", self.OnConfirmEvent)
    self:RegisterEvent("LOOT_BIND_CONFIRM", self.OnConfirmEvent)
end

function mod:OnDisable()
    UpdatePauseBadge(false)
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "单选项自动对话",
        tooltip = "无任务且 NPC 只有 1 个对话选项时自动继续（使用现代 C_GossipInfo API）。",
        getValue = function() return db.autoGossip == true end,
        setValue = function(v) db.autoGossip = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "自动接任务",
        tooltip = "与 NPC 对话时自动接受可接任务。按住 Shift 临时跳过。",
        getValue = function() return db.autoAccept == true end,
        setValue = function(v) self:SetMode("autoAccept", v) end,
    }, {
        type = "toggle",
        text = "自动交任务",
        tooltip = "自动提交已完成任务；需要付金币的任务会自动停下。",
        getValue = function() return db.autoTurnIn == true end,
        setValue = function(v) self:SetMode("autoTurnIn", v) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "跳过低等级灰色任务",
        tooltip = "自动接任务时跳过灰色过低等级任务。",
        getValue = function() return db.skipTrivial ~= false end,
        setValue = function(v) db.skipTrivial = v == true end,
    }, {
        type = "toggle",
        text = "多奖励自动选卖价最高",
        tooltip = "任务有多个奖励可选时，自动选择商店售价最高的物品。",
        getValue = function() return db.pickBestReward == true end,
        setValue = function(v) db.pickBestReward = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "包含可用装备时停下手动选",
        tooltip = "开启「自动选卖价最高」时，若奖励里包含本职业可用装备则暂停自动，防止误卖升级装。",
        getValue = function() return db.protectEquipRewards ~= false end,
        setValue = function(v) db.protectEquipRewards = v == true end,
    }, {
        type = "toggle",
        text = "自动确认拾取/Roll 绑定",
        tooltip = "拾取或 Roll 拾取绑定物品时自动点击确认。",
        getValue = function() return db.autoConfirmBind == true end,
        setValue = function(v) db.autoConfirmBind = v == true end,
    })
    y = y - h
    return y
end
