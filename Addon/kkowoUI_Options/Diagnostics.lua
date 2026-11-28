----------------------------------------------------------------------
--  kkowoUI_Options — Diagnostics.lua (LoadOnDemand: 1)
--  内置诊断与验收工具集：
--    • /kk harvest    ：官方译名合规采集 + CVar/插件盘点（写入 kkowoUIDB.harvest）
--    • /kk probe      ：聊天标签逐帧探针 + 姓名板标记矩阵被动记录（写入 kkowoUIDB.probe）
--    • /kk markcal    ：头顶标记视觉校准滑块（写入 kkowoUIDB.markcal）
--    • /kk selftest   ：自动化回归断言套件（写入 kkowoUIDB.selftest，战斗中拒绝执行）
--    • /kk clickcheck ：只读战斗安全隐形挡点击排查（鼠标下框体栈 + 全屏隐形吃点击扫描）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, pairs, pcall, select, tostring, tonumber, type =
    ipairs, pairs, pcall, select, tostring, tonumber, type
local math_floor, math_max, math_min = math.floor, math.max, math.min
local string_format, table_concat = string.format, table.concat
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown

local Diag = {}
F._Diagnostics = Diag

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

local function Round2(v)
    local n = F.PlainNumber(v, nil)
    if not n then return nil end
    return math_floor(n * 100 + 0.5) / 100
end

local function CountTable(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function GetBugCount()
    local bg = _G.BugGrabber
    if type(bg) ~= "table" or type(bg.GetDB) ~= "function" then return 0 end
    local okDB, db = pcall(bg.GetDB, bg)
    if not (okDB and type(db) == "table") then return 0 end
    local sid = nil
    if type(bg.GetSessionId) == "function" then
        local okS, s = pcall(bg.GetSessionId, bg)
        if okS and type(s) == "number" then sid = s end
    end
    if not sid and type(_G.BugGrabberDB) == "table" and type(_G.BugGrabberDB.session) == "number" then
        sid = _G.BugGrabberDB.session
    end
    local n = 0
    for _, err in ipairs(db) do
        if type(err) == "table" and (not sid or err.session == sid) then
            n = n + 1
        end
    end
    return n
end

----------------------------------------------------------------------
--  1) /kk harvest：官方译名合规采集 + CVar & 插件盘点
--     遵守暴雪《UI 插件开发政策》第 3 条：
--       • 先查 QuestieDB 与本地 API（零服务器请求）
--       • 必须问服务器的请求严格限速 <= 8 个/秒，单次上限 2000 个
--       • 战斗中自动暂停、连续失败自动中止、完成后自动关闭
----------------------------------------------------------------------
local harvestState = {
    running = false,
    ticker = nil,
    ui = nil,
}

local function EnsureHarvestUI()
    if harvestState.ui then return harvestState.ui end
    local f = CreateFrame("Frame", "kkowoUI_HarvestProgress", _G.UIParent)
    f:SetSize(250, 44)
    f:SetPoint("BOTTOMRIGHT", _G.UIParent, "BOTTOMRIGHT", -24, 96)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(120)
    f:EnableMouse(false)
    if F.Theme and F.Theme.StylePanel then
        F.Theme.StylePanel(f, 0.90, 0.85)
    end
    local txt = f:CreateFontString(nil, "OVERLAY")
    if F.Theme and F.Theme.ApplyFont then
        F.Theme.ApplyFont(txt, 12, "", 0.94, 0.95, 0.97, 1)
    end
    txt:SetPoint("CENTER", f, "CENTER", 0, 0)
    txt:SetJustifyH("CENTER")
    f._txt = txt
    f:Hide()
    harvestState.ui = f
    return f
end

local function SetHarvestStatus(msg)
    local ui = EnsureHarvestUI()
    ui._txt:SetText(msg)
    ui:Show()
end

local function ExportAddonsAndCVars(store)
    local ca = _G.C_AddOns
    local addons = {}
    if ca and ca.GetNumAddOns and ca.GetAddOnInfo then
        local total = F.PlainNumber(ca.GetNumAddOns(), 0) or 0
        for i = 1, total do
            local ok, name = pcall(ca.GetAddOnInfo, i)
            name = ok and F.PlainString(name, nil) or nil
            if name then
                local loaded = F.IsAddOnLoaded(name)
                local ver = ca.GetAddOnMetadata and F.PlainString(select(2, pcall(ca.GetAddOnMetadata, name, "Version")), "") or ""
                if loaded then
                    addons[name] = ver
                end
            end
        end
    end
    store.addons = addons
    store.addonCount = CountTable(addons)

    -- 导出全部 CVar 名称，并对 raid|target|icon|marker|nameplate|overhead|world 关键字保存完整值与默认值
    local cvarHits = {}
    local cvarAllNames = {}
    local totalCVars = 0
    local getCV = (_G.C_CVar and _G.C_CVar.GetCVarInfo) or nil
    local getVal = (_G.C_CVar and _G.C_CVar.GetCVar) or _G.GetCVar

    local function RecordCVar(cname)
        if type(cname) ~= "string" or cname == "" then return end
        totalCVars = totalCVars + 1
        local low = cname:lower()
        local match = low:find("raid", 1, true)
            or low:find("target", 1, true)
            or low:find("icon", 1, true)
            or low:find("marker", 1, true)
            or low:find("nameplate", 1, true)
            or low:find("overhead", 1, true)
            or low:find("worldtext", 1, true)
        if match then
            if getCV then
                local ok, val, defVal, acc, chr, _, _, ro = pcall(getCV, cname)
                if ok then
                    cvarHits[cname] = {
                        v = F.PlainString(val, tostring(val)),
                        d = F.PlainString(defVal, tostring(defVal)),
                        acc = acc == true,
                        chr = chr == true,
                        ro = ro == true,
                    }
                end
            elseif getVal then
                local ok, val = pcall(getVal, cname)
                if ok then
                    cvarHits[cname] = { v = F.PlainString(val, tostring(val)) }
                end
            end
        end
    end

    if type(_G.ConsoleGetAllCommands) == "function" then
        local ok, cmds = pcall(_G.ConsoleGetAllCommands)
        if ok and type(cmds) == "table" then
            for _, info in ipairs(cmds) do
                if type(info) == "table" and info.commandType == 0 and type(info.command) == "string" then
                    cvarAllNames[#cvarAllNames + 1] = info.command
                    RecordCVar(info.command)
                end
            end
        end
    elseif type(_G.C_Console) == "table" and type(_G.C_Console.GetAllCommands) == "function" then
        local ok, cmds = pcall(_G.C_Console.GetAllCommands)
        if ok and type(cmds) == "table" then
            for _, info in ipairs(cmds) do
                if type(info) == "table" and info.commandType == 0 and type(info.command) == "string" then
                    cvarAllNames[#cvarAllNames + 1] = info.command
                    RecordCVar(info.command)
                end
            end
        end
    end
    store.cvarTotal = totalCVars
    store.cvarFiltered = cvarHits
    store.cvarFilteredCount = CountTable(cvarHits)
    -- 仅保存前 2000 条名称防止 SavedVariables 过度膨胀，实际筛出结果已完整在 cvarFiltered
    store.cvarApiUsed = (#cvarAllNames > 0) and "ConsoleGetAllCommands" or "unavailable"
end

local function TryQuestieLookup(kind, id)
    local ql = _G.QuestieLoader
    if type(ql) == "table" and type(ql.ImportModule) == "function" then
        local okM, qdb = pcall(ql.ImportModule, ql, "QuestieDB")
        if okM and type(qdb) == "table" then
            if kind == "quest" and type(qdb.QueryQuestSingle) == "function" then
                local ok, name = pcall(qdb.QueryQuestSingle, id, "name")
                name = ok and F.PlainString(name, nil) or nil
                if name and name ~= "" then return name end
            elseif kind == "npc" and type(qdb.QueryNPCSingle) == "function" then
                local ok, name = pcall(qdb.QueryNPCSingle, id, "name")
                name = ok and F.PlainString(name, nil) or nil
                if name and name ~= "" then return name end
            elseif kind == "item" and type(qdb.QueryItemSingle) == "function" then
                local ok, name = pcall(qdb.QueryItemSingle, id, "name")
                name = ok and F.PlainString(name, nil) or nil
                if name and name ~= "" then return name end
            end
        end
    end
    return nil
end

local scanTooltip = nil
local function ScanNpcNameByTooltip(id)
    if not scanTooltip then
        scanTooltip = CreateFrame("GameTooltip", "kkowoUI_HarvestScanTip", _G.UIParent, "SharedTooltipTemplate")
        scanTooltip:SetOwner(_G.UIParent, "ANCHOR_NONE")
    end
    scanTooltip:ClearLines()
    local ok = pcall(scanTooltip.SetHyperlink, scanTooltip, "unit:Creature-0-0-0-0-" .. tostring(id))
    if not ok then return nil, false end
    local line1 = _G["kkowoUI_HarvestScanTipTextLeft1"]
    local txt = line1 and line1.GetText and F.PlainString(line1:GetText(), nil) or nil
    if txt and txt ~= "" and txt ~= _G.UNKNOWN and txt ~= "未知目标" then
        return txt, true
    end
    return nil, true
end

function Diag.StopHarvest(silent)
    if harvestState.ticker then
        harvestState.ticker:Cancel()
        harvestState.ticker = nil
    end
    harvestState.running = false
    if harvestState.ui then
        harvestState.ui:Hide()
    end
    if not silent then
        F.Print("数据采集已停止。")
    end
end

function Diag.StartHarvest(arg)
    arg = (arg or ""):lower()
    if arg == "stop" then
        Diag.StopHarvest(false)
        return
    end
    if harvestState.running then
        F.Print("采集正在后台运行中，输入 /kk harvest stop 可停止。")
        return
    end
    if not F.db then F.DB.Init() end
    if arg == "reset" or type(F.db.harvest) ~= "table" then
        F.db.harvest = {
            names = { zone = {}, area = {}, spell = {}, item = {}, quest = {}, npc = {} },
            sources = { zone = {}, area = {}, spell = {}, item = {}, quest = {}, npc = {} },
        }
    end
    local store = F.db.harvest
    store.version = F.VERSION
    store.timestamp = NowStamp()
    store.char = F.GetCharKey()
    store.locale = _G.GetLocale and F.PlainString(_G.GetLocale(), "") or ""
    if _G.GetBuildInfo then
        local v, b, d, toc = _G.GetBuildInfo()
        store.build = { version = v, build = b, date = d, interface = toc }
    end
    store.done = false
    store.names = type(store.names) == "table" and store.names or {}
    store.sources = type(store.sources) == "table" and store.sources or {}
    for _, k in ipairs({ "zone", "area", "spell", "item", "quest", "npc" }) do
        store.names[k] = type(store.names[k]) == "table" and store.names[k] or {}
        store.sources[k] = type(store.sources[k]) == "table" and store.sources[k] or {}
    end

    ExportAddonsAndCVars(store)

    local targets = F._HarvestTargets or {}
    -- 建立两级队列：纯本地队列（每帧 30 条）+ 服务器队列（每秒 <= 8 条，上限 2000）
    local localQueue = {}
    local serverQueue = {}
    local questieHits = 0

    for _, kind in ipairs({ "zone", "area", "spell" }) do
        for _, id in ipairs(targets[kind] or {}) do
            if not store.names[kind][id] then
                localQueue[#localQueue + 1] = { kind = kind, id = id }
            end
        end
    end
    for _, kind in ipairs({ "item", "quest", "npc" }) do
        for _, id in ipairs(targets[kind] or {}) do
            if not store.names[kind][id] then
                local qName = TryQuestieLookup(kind, id)
                if qName then
                    store.names[kind][id] = qName
                    store.sources[kind][id] = "questie"
                    questieHits = questieHits + 1
                else
                    serverQueue[#serverQueue + 1] = { kind = kind, id = id }
                end
            end
        end
    end

    local totalWork = #localQueue + math_min(#serverQueue, 2000)
    local localIdx = 1
    local serverIdx = 1
    local serverSent = 0
    local serverLimit = math_min(#serverQueue, 2000)
    local npcFailStreak = 0
    local npcAborted = false
    local pendingAsync = {}

    harvestState.running = true
    SetHarvestStatus(string_format("数据采集：0 / %d", totalWork))
    F.Print(string_format("开始后台采集：本地 %d 项，Questie 已补齐 %d 项，待查询 %d 项（限速 8/秒）。",
        #localQueue, questieHits, serverLimit))

    local function FinishHarvest()
        Diag.StopHarvest(true)
        store.done = true
        store.finishedAt = NowStamp()
        store.stats = {
            zone = CountTable(store.names.zone),
            area = CountTable(store.names.area),
            spell = CountTable(store.names.spell),
            item = CountTable(store.names.item),
            quest = CountTable(store.names.quest),
            npc = CountTable(store.names.npc),
            questieHits = questieHits,
            serverQueried = serverSent,
            npcAborted = npcAborted,
            cvarTotal = store.cvarTotal,
            cvarFiltered = store.cvarFilteredCount,
        }
        F.Print(string_format("采集完成：CVar %d 项，区域/法术 %d/%d，任务 %d，NPC %d，物品 %d。请 /reload 后退出。",
            store.cvarFilteredCount or 0,
            store.stats.zone + store.stats.area,
            store.stats.spell,
            store.stats.quest,
            store.stats.npc,
            store.stats.item))
    end

    -- 125ms tick = 最多 8 次/秒（纯本地阶段每 tick 30 条，服务器阶段每 tick 1 条）
    harvestState.ticker = C_Timer.NewTicker(0.125, function()
        if not harvestState.running then return end

        -- 先补扫异步缓存回来的任务标题
        if #pendingAsync > 0 then
            local keep = {}
            for _, item in ipairs(pendingAsync) do
                if item.kind == "quest" and _G.C_QuestLog and _G.C_QuestLog.GetTitleForQuestID then
                    local ok, title = pcall(_G.C_QuestLog.GetTitleForQuestID, item.id)
                    title = ok and F.PlainString(title, nil) or nil
                    if title and title ~= "" then
                        store.names.quest[item.id] = title
                        store.sources.quest[item.id] = "official"
                    elseif item.retries < 6 then
                        item.retries = item.retries + 1
                        keep[#keep + 1] = item
                    end
                end
            end
            pendingAsync = keep
        end

        -- 阶段 A：纯本地查询（零服务器通信）
        if localIdx <= #localQueue then
            local stopAt = math_min(#localQueue, localIdx + 29)
            for i = localIdx, stopAt do
                local it = localQueue[i]
                if it.kind == "zone" and _G.C_Map and _G.C_Map.GetMapInfo then
                    local ok, info = pcall(_G.C_Map.GetMapInfo, it.id)
                    local nm = ok and type(info) == "table" and F.PlainString(info.name, nil) or nil
                    if nm and nm ~= "" then
                        store.names.zone[it.id] = nm
                        store.sources.zone[it.id] = "official"
                    end
                elseif it.kind == "area" and _G.C_Map and _G.C_Map.GetAreaInfo then
                    local ok, nm = pcall(_G.C_Map.GetAreaInfo, it.id)
                    nm = ok and F.PlainString(nm, nil) or nil
                    if nm and nm ~= "" then
                        store.names.area[it.id] = nm
                        store.sources.area[it.id] = "official"
                    end
                elseif it.kind == "spell" then
                    local nm = nil
                    if _G.C_Spell and _G.C_Spell.GetSpellName then
                        local ok, s = pcall(_G.C_Spell.GetSpellName, it.id)
                        if ok then nm = F.PlainString(s, nil) end
                    elseif _G.GetSpellInfo then
                        local ok, s = pcall(_G.GetSpellInfo, it.id)
                        if ok then nm = F.PlainString(s, nil) end
                    end
                    if nm and nm ~= "" then
                        store.names.spell[it.id] = nm
                        store.sources.spell[it.id] = "official"
                    end
                end
            end
            localIdx = stopAt + 1
            local doneNow = (localIdx - 1) + serverSent
            SetHarvestStatus(string_format("数据采集：%d / %d（本地）", doneNow, totalWork))
            return
        end

        -- 阶段 B：限速服务器查询（战斗中暂停，每 125ms 仅 1 次 = 8 次/秒）
        if InCombatLockdown and InCombatLockdown() then
            SetHarvestStatus(string_format("数据采集：%d / %d（战斗中暂停）", #localQueue + serverSent, totalWork))
            return
        end

        if serverIdx <= serverLimit then
            local it = serverQueue[serverIdx]
            serverIdx = serverIdx + 1
            serverSent = serverSent + 1
            if it.kind == "item" then
                if _G.Item and _G.Item.CreateFromItemID then
                    local ok, obj = pcall(_G.Item.CreateFromItemID, _G.Item, it.id)
                    if ok and obj and obj.ContinueOnItemLoad then
                        local itemId = it.id
                        pcall(obj.ContinueOnItemLoad, obj, function()
                            local okN, nm = pcall(obj.GetItemName, obj)
                            nm = okN and F.PlainString(nm, nil) or nil
                            if nm and nm ~= "" then
                                store.names.item[itemId] = nm
                                store.sources.item[itemId] = "official"
                            end
                        end)
                    end
                end
            elseif it.kind == "quest" then
                if _G.C_QuestLog and _G.C_QuestLog.GetTitleForQuestID then
                    local ok, title = pcall(_G.C_QuestLog.GetTitleForQuestID, it.id)
                    title = ok and F.PlainString(title, nil) or nil
                    if title and title ~= "" then
                        store.names.quest[it.id] = title
                        store.sources.quest[it.id] = "official"
                    else
                        if _G.C_QuestLog.RequestLoadQuestByID then
                            pcall(_G.C_QuestLog.RequestLoadQuestByID, it.id)
                        end
                        pendingAsync[#pendingAsync + 1] = { kind = "quest", id = it.id, retries = 0 }
                    end
                end
            elseif it.kind == "npc" and not npcAborted then
                local nm, apiOk = ScanNpcNameByTooltip(it.id)
                if nm then
                    store.names.npc[it.id] = nm
                    store.sources.npc[it.id] = "official"
                    npcFailStreak = 0
                else
                    npcFailStreak = npcFailStreak + 1
                    if not apiOk or npcFailStreak >= 25 then
                        npcAborted = true
                    end
                end
            end
            SetHarvestStatus(string_format("数据采集：%d / %d", #localQueue + serverSent, totalWork))
            return
        end

        if #pendingAsync == 0 then
            FinishHarvest()
        end
    end)
end

----------------------------------------------------------------------
--  2) /kk probe：聊天标签逐帧探针 + 姓名板标记矩阵被动记录
--     零污染：只用非受保护只读观察与 EUI 非安全表计数，绝不碰 FCFDock_SelectWindow
----------------------------------------------------------------------
local probeState = {
    active = false,
    frame = nil,
    eventFrame = nil,
    lastSelected = nil,
    activeSwitch = nil,
    euiHooked = false,
    calls = { sync = 0, tabs = 0, clHost = 0, updateWin = 0 },
}

local function GetEUIChatNS()
    local EUI = _G.EllesmereUI
    local ns = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIChat
    return type(ns) == "table" and ns or nil
end

local function GetEUINPNS()
    local EUI = _G.EllesmereUI
    local ns = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUINameplates
    return type(ns) == "table" and ns or nil
end

local function InstallProbeCounters()
    if probeState.euiHooked or not _G.hooksecurefunc then return end
    local chatNS = GetEUIChatNS()
    local echat = chatNS and chatNS.ECHAT
    if type(echat) == "table" then
        probeState.euiHooked = true
        if type(echat.SyncChatFrameState) == "function" then
            _G.hooksecurefunc(echat, "SyncChatFrameState", function()
                if probeState.active then probeState.calls.sync = probeState.calls.sync + 1 end
            end)
        end
        if type(echat.TabsRefreshNow) == "function" then
            _G.hooksecurefunc(echat, "TabsRefreshNow", function()
                if probeState.active then probeState.calls.tabs = probeState.calls.tabs + 1 end
            end)
        end
        if type(echat.EngineUpdateCombatLogHost) == "function" then
            _G.hooksecurefunc(echat, "EngineUpdateCombatLogHost", function()
                if probeState.active then probeState.calls.clHost = probeState.calls.clHost + 1 end
            end)
        end
    end
end

local function SafeBoolMethod(obj, method)
    if not (obj and type(obj[method]) == "function") then return nil end
    local ok, v = pcall(obj[method], obj)
    if not ok or F.IsSecret(v) then return nil end
    return v == true
end

local function SafeBoolFn(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, v = pcall(fn, ...)
    return ok and not F.IsSecret(v) and v == true
end

local function CaptureChatFrameSnapshot(frameIdx, dt)
    local cf1 = _G.ChatFrame1
    local cf2 = _G.ChatFrame2
    local sel = _G.GENERAL_CHAT_DOCK and _G.FCFDock_GetSelectedWindow and _G.FCFDock_GetSelectedWindow(_G.GENERAL_CHAT_DOCK)
    local chatNS = GetEUIChatNS()
    local clBar = _G.CombatLogQuickButtonFrame_Custom
    local clProg = _G.CombatLogQuickButtonFrameProgressBar
    local cbDbg = F._chatBarDebug

    local snap = {
        f = frameIdx,
        dt = Round2((dt or 0) * 1000),
        selId = sel and sel.GetID and sel:GetID() or 0,
        combat = (InCombatLockdown and InCombatLockdown()) == true,
        clHosted = chatNS and chatNS._clHosted or false,
        calls = {
            sync = probeState.calls.sync,
            tabs = probeState.calls.tabs,
            clHost = probeState.calls.clHost,
            updWin = probeState.calls.updateWin,
            cbSync = cbDbg and cbDbg.syncCount or 0,
            cbAnchor = cbDbg and cbDbg.anchorCount or 0,
        },
    }
    if cf2 and IsSafeFrame(cf2) then
        local fsc = cf2.FontStringContainer
        local pt, rel, rpt, x, y = cf2:GetPoint(1)
        snap.cf2 = {
            shown = SafeBoolMethod(cf2, "IsShown") == true,
            alpha = Round2(cf2:GetAlpha()),
            fscAlpha = fsc and IsSafeFrame(fsc) and Round2(fsc:GetAlpha()) or nil,
            w = Round2(cf2:GetWidth()),
            h = Round2(cf2:GetHeight()),
            left = Round2(cf2:GetLeft()),
            bottom = Round2(cf2:GetBottom()),
            pt = F.PlainString(pt, nil),
            rel = rel and IsSafeFrame(rel) and rel.GetName and F.PlainString(rel:GetName(), nil) or nil,
            rpt = F.PlainString(rpt, nil),
            x = Round2(x),
            y = Round2(y),
            msgs = cf2.GetNumMessages and F.PlainNumber(select(2, pcall(cf2.GetNumMessages, cf2)), nil) or nil,
            scroll = cf2.GetScrollOffset and F.PlainNumber(select(2, pcall(cf2.GetScrollOffset, cf2)), nil) or nil,
            atBot = SafeBoolMethod(cf2, "AtBottom"),
            fading = SafeBoolMethod(cf2, "GetFading"),
            locked = cf2.isLocked == true,
        }
        -- 检查 EUI bg 几何
        local EUI = _G.EllesmereUI
        if EUI and type(EUI._chatCFD) == "function" then
            local okD, d = pcall(EUI._chatCFD, cf2)
            local bg = okD and type(d) == "table" and d.bg
            if bg and IsSafeFrame(bg) then
                snap.euiBg2 = {
                    shown = bg:IsShown() == true,
                    w = Round2(bg:GetWidth()),
                    h = Round2(bg:GetHeight()),
                    top = Round2(bg:GetTop()),
                    bottom = Round2(bg:GetBottom()),
                }
            end
        end
    end
    if cf1 and IsSafeFrame(cf1) then
        snap.cf1 = {
            shown = SafeBoolMethod(cf1, "IsShown") == true,
            msgs = cf1.GetNumMessages and F.PlainNumber(select(2, pcall(cf1.GetNumMessages, cf1)), nil) or nil,
            scroll = cf1.GetScrollOffset and F.PlainNumber(select(2, pcall(cf1.GetScrollOffset, cf1)), nil) or nil,
            atBot = SafeBoolMethod(cf1, "AtBottom"),
            locked = cf1.isLocked == true,
        }
    end
    if clBar and IsSafeFrame(clBar) then
        snap.clBar = {
            shown = clBar:IsShown() == true,
            h = Round2(clBar:GetHeight()),
            top = Round2(clBar:GetTop()),
        }
    end
    snap.refilter = clProg and IsSafeFrame(clProg) and (clProg:IsShown() == true) or false
    return snap
end

local function InspectMarkerMatrix(reason)
    local npNS = GetEUINPNS()
    local enp = npNS and (npNS.ENP or (npNS._npInternals and npNS._npInternals.ENP))
    local prof = enp and enp.db and enp.db.profile or nil
    local matrix = {
        t = Round2(GetTime()),
        reason = reason or "manual",
        combat = (InCombatLockdown and InCombatLockdown()) == true,
        cvarFriendlyOnlyName = _G.C_CVar and _G.C_CVar.GetCVar and _G.C_CVar.GetCVar("nameplateShowOnlyNameForFriendlyPlayerUnits") or nil,
        euiProfile = prof and {
            raidMarkerSize = prof.raidMarkerSize,
            raidMarkerCoreSize = prof.raidMarkerCoreSize,
            raidMarkerPos = prof.raidMarkerPos,
            nameRaidMarkerEnabled = prof.nameRaidMarkerEnabled,
            nameRaidMarkerSize = prof.nameRaidMarkerSize,
            showNPCRaidMarker = prof.showNPCRaidMarker,
        } or nil,
        units = {},
    }

    local function InspectUnit(u, np)
        local isForb = not IsSafeFrame(np)
        local rec = {
            unit = u,
            forbidden = isForb,
        }
        if u and SafeBoolFn(_G.UnitExists, u) then
            local okP, isPl = pcall(_G.UnitIsPlayer, u)
            rec.isPlayer = okP and not F.IsSecret(isPl) and isPl == true or false
            local okS, isSelf = pcall(_G.UnitIsUnit, u, "player")
            rec.isSelf = okS and not F.IsSecret(isSelf) and isSelf == true or false
            local okA, canAtk = pcall(_G.UnitCanAttack, "player", u)
            rec.canAttack = okA and not F.IsSecret(canAtk) and canAtk == true or false
            local okF, isFr = pcall(_G.UnitIsFriend, "player", u)
            rec.isFriend = okF and not F.IsSecret(isFr) and isFr == true or false
            local okT, isTgt = pcall(_G.UnitIsUnit, u, "target")
            rec.isTarget = okT and not F.IsSecret(isTgt) and isTgt == true or false
            if _G.GetRaidTargetIndex then
                local okR, ridx = pcall(_G.GetRaidTargetIndex, u)
                rec.raidIdx = okR and F.PlainNumber(ridx, nil) or (okR and type(ridx) ~= "nil" and "secret" or nil)
            end
        end

        if npNS and u then
            local ep = npNS.plates and npNS.plates[u]
            if ep and IsSafeFrame(ep) then
                rec.euiEnemy = {
                    shown = ep:IsShown() == true,
                    raidShown = ep.raidFrame and IsSafeFrame(ep.raidFrame) and ep.raidFrame:IsShown() == true or false,
                    raidW = ep.raidFrame and IsSafeFrame(ep.raidFrame) and Round2(ep.raidFrame:GetWidth()) or nil,
                    raidH = ep.raidFrame and IsSafeFrame(ep.raidFrame) and Round2(ep.raidFrame:GetHeight()) or nil,
                    nameRaidShown = ep.nameRaidFrame and IsSafeFrame(ep.nameRaidFrame) and ep.nameRaidFrame:IsShown() == true or false,
                    nameRaidW = ep.nameRaidFrame and IsSafeFrame(ep.nameRaidFrame) and Round2(ep.nameRaidFrame:GetWidth()) or nil,
                    nameRaidH = ep.nameRaidFrame and IsSafeFrame(ep.nameRaidFrame) and Round2(ep.nameRaidFrame:GetHeight()) or nil,
                }
            end
            local fp = npNS.friendlyPlates and npNS.friendlyPlates[u]
            if fp and IsSafeFrame(fp) then
                rec.euiFriendly = {
                    shown = fp:IsShown() == true,
                    raidShown = fp.raidFrame and IsSafeFrame(fp.raidFrame) and fp.raidFrame:IsShown() == true or false,
                    raidW = fp.raidFrame and IsSafeFrame(fp.raidFrame) and Round2(fp.raidFrame:GetWidth()) or nil,
                    raidH = fp.raidFrame and IsSafeFrame(fp.raidFrame) and Round2(fp.raidFrame:GetHeight()) or nil,
                    nameRaidShown = fp.nameRaidFrame and IsSafeFrame(fp.nameRaidFrame) and fp.nameRaidFrame:IsShown() == true or false,
                    nameRaidW = fp.nameRaidFrame and IsSafeFrame(fp.nameRaidFrame) and Round2(fp.nameRaidFrame:GetWidth()) or nil,
                    nameRaidH = fp.nameRaidFrame and IsSafeFrame(fp.nameRaidFrame) and Round2(fp.nameRaidFrame:GetHeight()) or nil,
                }
            end
        end

        local ep = npNS and u and npNS.plates and npNS.plates[u] or nil
        local fp = npNS and u and npNS.friendlyPlates and npNS.friendlyPlates[u] or nil
        if np and not isForb then
            if np.GetChildren then
                local okC, chs = pcall(function() return { np:GetChildren() } end)
                if okC and type(chs) == "table" then
                    for _, ch in ipairs(chs) do
                        if ch and ch ~= ep and ch ~= fp and IsSafeFrame(ch) and ch.raid then
                            rec.npcOverlay = {
                                shown = ch:IsShown() == true,
                                raidShown = ch.raid.IsShown and ch.raid:IsShown() == true or false,
                                w = ch.raid.GetWidth and Round2(ch.raid:GetWidth()) or nil,
                                h = ch.raid.GetHeight and Round2(ch.raid:GetHeight()) or nil,
                            }
                            break
                        end
                    end
                end
            end
            local uf = np.UnitFrame
            if uf and IsSafeFrame(uf) then
                local rtf = uf.RaidTargetFrame
                local rti = rtf and rtf.RaidTargetIcon
                rec.blizz = {
                    ufShown = uf:IsShown() == true,
                    ufAlpha = Round2(uf:GetAlpha()),
                    rtfShown = rtf and IsSafeFrame(rtf) and rtf:IsShown() == true or false,
                    rtfW = rtf and IsSafeFrame(rtf) and Round2(rtf:GetWidth()) or nil,
                    rtfH = rtf and IsSafeFrame(rtf) and Round2(rtf:GetHeight()) or nil,
                    rtiW = rti and IsSafeFrame(rti) and Round2(rti:GetWidth()) or nil,
                    rtiH = rti and IsSafeFrame(rti) and Round2(rti:GetHeight()) or nil,
                }
            end
        end
        return rec
    end

    -- 玩家自身与当前目标
    matrix.units[#matrix.units + 1] = InspectUnit("player", _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit and select(2, pcall(_G.C_NamePlate.GetNamePlateForUnit, "player")) or nil)
    if SafeBoolFn(_G.UnitExists, "target") then
        local tnp = _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit and select(2, pcall(_G.C_NamePlate.GetNamePlateForUnit, "target")) or nil
        matrix.units[#matrix.units + 1] = InspectUnit("target", tnp)
    end
    -- 所有可见姓名板
    if _G.C_NamePlate and _G.C_NamePlate.GetNamePlates then
        local ok, list = pcall(_G.C_NamePlate.GetNamePlates)
        if ok and type(list) == "table" then
            for _, np in ipairs(list) do
                if np then
                    local isForb = not IsSafeFrame(np)
                    local u = (not isForb) and F.PlainString(np.namePlateUnitToken or (np.UnitFrame and IsSafeFrame(np.UnitFrame) and np.UnitFrame.unit), nil) or nil
                    matrix.units[#matrix.units + 1] = InspectUnit(u or "forbidden_plate", np)
                end
            end
        end
    end
    return matrix
end

function Diag.ToggleProbe()
    if not F.db then F.DB.Init() end
    if probeState.active then
        probeState.active = false
        if probeState.frame then probeState.frame:SetScript("OnUpdate", nil) end
        if probeState.eventFrame then probeState.eventFrame:UnregisterAllEvents() end
        local p = F.db.probe
        local nSw = p and p.chatSwitches and #p.chatSwitches or 0
        local nMk = p and p.markerSnapshots and #p.markerSnapshots or 0
        F.Print(string_format("探针已关闭：已记录 %d 次聊天切页、%d 组标记快照。请 /reload 后退出以保存。", nSw, nMk))
        return
    end

    InstallProbeCounters()
    F.db.probe = {
        version = F.VERSION,
        timestamp = NowStamp(),
        char = F.GetCharKey(),
        chatSwitches = {},
        markerSnapshots = {},
    }
    probeState.active = true
    probeState.lastSelected = _G.GENERAL_CHAT_DOCK and _G.FCFDock_GetSelectedWindow and _G.FCFDock_GetSelectedWindow(_G.GENERAL_CHAT_DOCK) or nil
    probeState.activeSwitch = nil

    if not probeState.frame then
        probeState.frame = CreateFrame("Frame")
    end
    if not probeState.eventFrame then
        probeState.eventFrame = CreateFrame("Frame")
    end

    local function RecordMarker(reason)
        if not probeState.active then return end
        local list = F.db.probe.markerSnapshots
        if #list >= 40 then return end
        list[#list + 1] = InspectMarkerMatrix(reason)
    end

    probeState.eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    probeState.eventFrame:RegisterEvent("RAID_TARGET_UPDATE")
    probeState.eventFrame:RegisterEvent("UPDATE_CHAT_WINDOWS")
    probeState.eventFrame:SetScript("OnEvent", function(_, ev)
        if not probeState.active then return end
        if ev == "UPDATE_CHAT_WINDOWS" then
            probeState.calls.updateWin = probeState.calls.updateWin + 1
        else
            RecordMarker(ev)
        end
    end)

    probeState.frame:SetScript("OnUpdate", function(_, elapsed)
        if not probeState.active then return end
        local sel = _G.GENERAL_CHAT_DOCK and _G.FCFDock_GetSelectedWindow and _G.FCFDock_GetSelectedWindow(_G.GENERAL_CHAT_DOCK)
        if sel and sel ~= probeState.lastSelected then
            local prev = probeState.lastSelected
            probeState.lastSelected = sel
            local switches = F.db.probe.chatSwitches
            if #switches < 40 then
                probeState.activeSwitch = {
                    t = Round2(GetTime()),
                    combat = (InCombatLockdown and InCombatLockdown()) == true,
                    fromId = prev and prev.GetID and prev:GetID() or 0,
                    toId = sel and sel.GetID and sel:GetID() or 0,
                    fromName = prev and prev.name or "",
                    toName = sel and sel.name or "",
                    frames = {},
                }
                switches[#switches + 1] = probeState.activeSwitch
            else
                probeState.activeSwitch = nil
            end
        end
        if probeState.activeSwitch then
            local frs = probeState.activeSwitch.frames
            frs[#frs + 1] = CaptureChatFrameSnapshot(#frs, elapsed)
            if #frs >= 12 then
                probeState.activeSwitch = nil
            end
        end
    end)

    RecordMarker("probe_start")
    F.Print("探针已开启：正在后台记录聊天切页逐帧数据与目标标记矩阵（再次输入 /kk probe 关闭）。")
end

----------------------------------------------------------------------
--  3) /kk markcal：头顶标记视觉校准滑块
----------------------------------------------------------------------
local calFrame = nil

function Diag.OpenMarkCalibrator()
    local mb = F.Modules.Get("markBar")
    if not mb then
        F.Print("未加载快捷标记条模块，无法校准。")
        return
    end
    local initSize = F.PlainNumber(mb:GetDB().overheadSize, 36) or 36
    if not calFrame then
        local f = CreateFrame("Frame", "kkowoUI_MarkCalibrator", _G.UIParent)
        f:SetSize(320, 146)
        f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 120)
        f:SetFrameStrata("DIALOG")
        f:SetFrameLevel(140)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:HookScript("OnHide", f.StopMovingOrSizing)
        if F.Theme and F.Theme.StylePanel then F.Theme.StylePanel(f, 0.94, 0.90) end
        if F.Theme and F.Theme.RegisterEscapeClose then F.Theme.RegisterEscapeClose(f) end

        local title = f:CreateFontString(nil, "OVERLAY")
        if F.Theme and F.Theme.ApplyFont then F.Theme.ApplyFont(title, 13, "", 0.95, 0.85, 0.72, 1) end
        title:SetPoint("TOP", f, "TOP", 0, -12)
        title:SetText("头顶标记大小校准")

        local hint = f:CreateFontString(nil, "OVERLAY")
        if F.Theme and F.Theme.ApplyFont then F.Theme.ApplyFont(hint, 11, "", 0.78, 0.80, 0.84, 1) end
        hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
        hint:SetText("拖动滑块使姓名板标记与自己头顶标记大小一致")

        local valFS = f:CreateFontString(nil, "OVERLAY")
        if F.Theme and F.Theme.ApplyFont then F.Theme.ApplyFont(valFS, 13, "", 1, 1, 1, 1) end
        valFS:SetPoint("TOP", hint, "BOTTOM", 0, -10)
        f._valFS = valFS

        local sl = CreateFrame("Slider", "kkowoUI_MarkCalSlider", f, "OptionsSliderTemplate")
        sl:SetWidth(260)
        sl:SetPoint("TOP", valFS, "BOTTOM", 0, -8)
        sl:SetMinMaxValues(16, 64)
        sl:SetValueStep(1)
        if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
        sl:SetScript("OnValueChanged", function(_, v)
            local sz = math_floor((F.PlainNumber(v, 36) or 36) + 0.5)
            f._curVal = sz
            f._valFS:SetText(tostring(sz) .. " px")
            local m = F.Modules.Get("markBar")
            if m and m.ApplyOverheadSize then m:ApplyOverheadSize(sz) end
        end)
        f._slider = sl

        local okBtn = CreateFrame("Button", nil, f)
        okBtn:SetSize(120, 26)
        okBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 28, 12)
        if F.Theme and F.Theme.StyleButton then F.Theme.StyleButton(okBtn, 12) end
        okBtn:SetText("确认设为默认")
        okBtn:SetScript("OnClick", function()
            local sz = f._curVal or 36
            local m = F.Modules.Get("markBar")
            if m and m.ApplyOverheadSize then m:ApplyOverheadSize(sz) end
            if F.db then
                F.db.markcal = { value = sz, timestamp = NowStamp(), char = F.GetCharKey() }
            end
            F.Print("已保存校准后的默认标记大小：" .. tostring(sz) .. " px。")
            f:Hide()
        end)

        local cancelBtn = CreateFrame("Button", nil, f)
        cancelBtn:SetSize(100, 26)
        cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 12)
        if F.Theme and F.Theme.StyleButton then F.Theme.StyleButton(cancelBtn, 12) end
        cancelBtn:SetText("取消")
        cancelBtn:SetScript("OnClick", function()
            local m = F.Modules.Get("markBar")
            if m and m.ApplyOverheadSize and f._origVal then m:ApplyOverheadSize(f._origVal) end
            f:Hide()
        end)

        calFrame = f
    end

    calFrame._origVal = initSize
    calFrame._curVal = initSize
    calFrame._valFS:SetText(tostring(initSize) .. " px")
    calFrame._slider:SetValue(initSize)
    calFrame:Show()
end

----------------------------------------------------------------------
--  4) /kk selftest：自动化断言测试套件（战斗中拒绝执行）
----------------------------------------------------------------------
local function GetKkowoMemoryKB()
    if type(_G.UpdateAddOnMemoryUsage) == "function" then
        pcall(_G.UpdateAddOnMemoryUsage)
    end
    if type(_G.GetAddOnMemoryUsage) ~= "function" then return 0 end
    local sum = 0
    local pkgs = {
        "kkowoUI", "kkowoUI_Media", "kkowoUI_CoreHUD", "kkowoUI_QoL",
        "kkowoUI_Tooltip", "kkowoUI_Integrations", "kkowoUI_ClassPack",
        "kkowoUI_Options", "kkowoUI_KeybindBoard",
    }
    for _, p in ipairs(pkgs) do
        if F.IsAddOnLoaded(p) then
            local ok, kb = pcall(_G.GetAddOnMemoryUsage, p)
            if ok and type(kb) == "number" then sum = sum + kb end
        end
    end
    return Round2(sum) or 0
end

function Diag.RunSelfTest()
    if InCombatLockdown and InCombatLockdown() then
        F.Print("战斗中不能执行自检，请脱战后再输入 /kk selftest。")
        return
    end
    if not F.db then F.DB.Init() end

    local bugsBefore = GetBugCount()
    local memStart = GetKkowoMemoryKB()
    local results = {}
    local passed, failed = 0, 0

    local function Assert(id, ok, detail)
        if ok then passed = passed + 1 else failed = failed + 1 end
        results[#results + 1] = { id = id, ok = ok == true, detail = tostring(detail or "") }
    end

    -- 1) 9 个套件加载检查
    local requiredPkgs = {
        "kkowoUI", "kkowoUI_Media", "kkowoUI_CoreHUD", "kkowoUI_QoL",
        "kkowoUI_Tooltip", "kkowoUI_Integrations", "kkowoUI_ClassPack", "kkowoUI_Options",
    }
    for _, pkg in ipairs(requiredPkgs) do
        Assert("pkg:" .. pkg, F.IsAddOnLoaded(pkg), F.IsAddOnLoaded(pkg) and "loaded" or "not loaded")
    end

    -- 2) 模块注册与激活状态检查
    local mods = F.Modules.All()
    Assert("modules:count", #mods >= 40, "registered=" .. tostring(#mods))
    for _, m in ipairs(mods) do
        local yielded = m:IsYielded()
        local masterOff = m.masterKey and F.Modules.Get(m.masterKey) and not F.Modules.Get(m.masterKey):IsEnabled()
        local expected = m:IsEnabled() and (not yielded) and (not masterOff)
        -- 职业门控模块（如非术士的 soulstoneAlert）允许自行保持未激活
        local classGated = (m.key == "soulstoneAlert" and F.GetPlayerClass() ~= "WARLOCK")
            or (m.key == "spellSounds" and F.GetPlayerClass() ~= "HUNTER")
        if not classGated then
            Assert("mod:" .. m.key, m._active == expected,
                string_format("active=%s expected=%s", tostring(m._active), tostring(expected)))
        end
    end

    -- 3) 代表性模块生命周期开->关->开检查（不触发破坏性重载或外部配置重置）
    local safeToggleKeys = { "extraFrameMover", "questXP", "combatAlert", "lowHealthAlert", "damageMeterSkin" }
    for _, k in ipairs(safeToggleKeys) do
        local m = F.Modules.Get(k)
        if m then
            local was = m:IsEnabled()
            local ok1 = pcall(m.SetEnabled, m, false)
            local offOk = not m._active
            local ok2 = pcall(m.SetEnabled, m, true)
            local ok3 = pcall(m.SetEnabled, m, was)
            Assert("toggle:" .. k, ok1 and offOk and ok2 and ok3,
                string_format("off=%s restore=%s", tostring(offOk), tostring(ok3)))
        end
    end

    -- 4) 配置组与 pageMap 完整性检查
    local missingPages = {}
    for _, g in ipairs(F.OPTION_GROUPS or {}) do
        if type(g.pageMap) == "table" then
            for pname, keys in pairs(g.pageMap) do
                for _, mk in ipairs(keys) do
                    local baseKey = mk:match("^([^:]+)") or mk
                    local m = F.Modules.Get(baseKey)
                    if not m and baseKey == "keybindBoard" and F.EnsureKeybindBoardLoaded then
                        m = F.EnsureKeybindBoardLoaded()
                    end
                    if not m then
                        missingPages[#missingPages + 1] = g.key .. "/" .. pname .. ":" .. mk
                    end
                end
            end
        end
    end
    Assert("options:pageMap", #missingPages == 0, #missingPages == 0 and "all resolved" or table_concat(missingPages, ", "))

    -- 5) PatchGuard 与 DeadGuard 检查
    local patches = F.CheckPatches and F.CheckPatches() or {}
    for _, p in ipairs(patches) do
        Assert("patch:" .. p.id, p.ok == true, p.ok and "ok" or ("missing: " .. p.name))
    end
    local retired = { "YaMedia", "BlizzMove", "Leatrix_Maps", "WaypointUI", "PrettyTooltip", "163UI_Info", "Polestar_Arcade" }
    local aliveRetired = {}
    for _, rname in ipairs(retired) do
        if F.IsAddOnLoaded(rname) then aliveRetired[#aliveRetired + 1] = rname end
    end
    Assert("deadguard:retired", #aliveRetired == 0, #aliveRetired == 0 and "0 retired loaded" or table_concat(aliveRetired, ", "))

    -- 6) ESC 注册检查（SettingsPanel 等）
    Assert("esc:ThemeAPI", type(F.Theme and F.Theme.RegisterEscapeClose) == "function", "RegisterEscapeClose ready")

    -- 7) 标记矩阵快照与尺寸核验（含 nameRaidMarkerSize + 关闭还原断言）
    local matrix = InspectMarkerMatrix("selftest")
    local mb = F.Modules.Get("markBar")
    local wantSz = mb and F.PlainNumber(mb:GetDB().overheadSize, 36) or 36
    if matrix.euiProfile then
        Assert("mark:euiSize",
            matrix.euiProfile.raidMarkerSize == wantSz
                and matrix.euiProfile.raidMarkerCoreSize == wantSz
                and matrix.euiProfile.nameRaidMarkerSize == wantSz,
            string_format("want=%d eui=%s/%s name=%s(on=%s)",
                wantSz,
                tostring(matrix.euiProfile.raidMarkerSize),
                tostring(matrix.euiProfile.raidMarkerCoreSize),
                tostring(matrix.euiProfile.nameRaidMarkerSize),
                tostring(matrix.euiProfile.nameRaidMarkerEnabled)))
    end
    if mb and mb:IsEnabled() and matrix.euiProfile then
        local savedBefore = F.DeepCopy(mb:GetDB().savedEUIRaidMarker)
        local okOff = pcall(mb.SetEnabled, mb, false)
        local afterOff = InspectMarkerMatrix("selftest_off").euiProfile
        local restoredOk = okOff and afterOff ~= nil
            and (type(savedBefore) ~= "table"
                or (savedBefore.base == "__nil__" or afterOff.raidMarkerSize == savedBefore.base))
        local okOn = pcall(mb.SetEnabled, mb, true)
        local afterOn = InspectMarkerMatrix("selftest_on").euiProfile
        local reappliedOk = okOn and afterOn ~= nil and afterOn.raidMarkerSize == wantSz and afterOn.nameRaidMarkerSize == wantSz
        Assert("mark:disableRestore", restoredOk and reappliedOk,
            string_format("restored=%s reapplied=%s", tostring(restoredOk), tostring(reappliedOk)))
    end

    -- 8) 聊天标签无污染自动切换检查（脱战下用 tab:Click()，对比 dock.selected / isLocked / 几何 / 零冗余锚定）
    local dock = _G.GENERAL_CHAT_DOCK
    local cf1, cf2 = _G.ChatFrame1, _G.ChatFrame2
    local tab1, tab2 = _G.ChatFrame1Tab, _G.ChatFrame2Tab
    local chatTest = { skipped = true }
    if dock and cf1 and cf2 and tab1 and tab2 and tab1.Click and tab2.Click and _G.FCFDock_GetSelectedWindow then
        local origSel = _G.FCFDock_GetSelectedWindow(dock)
        local origLock1, origLock2 = cf1.isLocked, cf2.isLocked
        local w0, h0 = Round2(cf2:GetWidth()), Round2(cf2:GetHeight())
        local cbDbg = F._chatBarDebug
        local anc0 = cbDbg and cbDbg.anchorCount or 0
        pcall(tab2.Click, tab2, "LeftButton")
        local selAfter2 = _G.FCFDock_GetSelectedWindow(dock)
        local w2, h2 = Round2(cf2:GetWidth()), Round2(cf2:GetHeight())
        pcall(tab1.Click, tab1, "LeftButton")
        if origSel == cf2 then pcall(tab2.Click, tab2, "LeftButton") end
        local selRestored = _G.FCFDock_GetSelectedWindow(dock)
        local anc1 = cbDbg and cbDbg.anchorCount or 0
        local noLockTaint = (cf1.isLocked == origLock1) and (cf2.isLocked == origLock2)
        local geomStable = (w0 == w2) and (h0 == h2)
        local noRedundantAnchor = (anc1 == anc0)
        chatTest = {
            skipped = false,
            switchedTo2 = (selAfter2 == cf2),
            restored = (selRestored == origSel),
            noLockTaint = noLockTaint,
            noRedundantAnchor = noRedundantAnchor,
            anchorDelta = anc1 - anc0,
            geomBefore = { w = w0, h = h0 },
            geomAfter = { w = w2, h = h2 },
        }
        Assert("chat:tabClickNoTaint", chatTest.switchedTo2 and chatTest.restored and noLockTaint,
            string_format("to2=%s restored=%s lockOk=%s", tostring(chatTest.switchedTo2), tostring(chatTest.restored), tostring(noLockTaint)))
        Assert("chat:cf2GeomStable", geomStable,
            string_format("before=%sx%s after=%sx%s", tostring(w0), tostring(h0), tostring(w2), tostring(h2)))
        Assert("chat:noRedundantAnchor", noRedundantAnchor,
            string_format("anchorDelta=%d", anc1 - anc0))
    end

    -- 9) 翻译抽查（检查运行时翻译注入表；阶段 3 写入 F._LocaleChecks）
    local locChecks = F._LocaleChecks
    if type(locChecks) == "table" then
        for pluginName, checkFn in pairs(locChecks) do
            local okC, passC, detailC = pcall(checkFn)
            Assert("locale:" .. pluginName, okC and passC == true, okC and tostring(detailC or "") or tostring(passC))
        end
    end

    -- 10) BugGrabber 新增报错检查
    local bugsAfter = GetBugCount()
    local newBugs = math_max(0, bugsAfter - bugsBefore)
    Assert("bugs:noNewErrors", newBugs == 0, string_format("before=%d after=%d new=%d", bugsBefore, bugsAfter, newBugs))

    local memEnd = GetKkowoMemoryKB()
    local report = {
        version = F.VERSION,
        timestamp = NowStamp(),
        char = F.GetCharKey(),
        passed = passed,
        failed = failed,
        newBugs = newBugs,
        memStartKB = memStart,
        memEndKB = memEnd,
        memDeltaKB = Round2(memEnd - memStart),
        chatTest = chatTest,
        markerMatrix = matrix,
        results = results,
    }
    F.db.selftest = report

    -- 60 秒后再采样一次常驻内存差值（不阻塞）
    if C_Timer and C_Timer.After then
        C_Timer.After(60, function()
            if F.db and F.db.selftest == report then
                local m60 = GetKkowoMemoryKB()
                report.memAfter60sKB = m60
                report.memDelta60sKB = Round2(m60 - memStart)
            end
        end)
    end

    F.Print(string_format("自检完成：通过 %d / 失败 %d（新增报错 %d），详见存档。", passed, failed, newBugs))
    if failed > 0 then
        for _, r in ipairs(results) do
            if not r.ok then
                _G.print("  |cffff6b6b[失败]|r " .. tostring(r.id) .. " → " .. tostring(r.detail))
            end
        end
    end
end

----------------------------------------------------------------------
--  5) /kk clickcheck — 实机只读隐形挡点击排查（战斗中 100% 安全，绝不改任何框体）
----------------------------------------------------------------------
local BLIZZ_KNOWN_PREFIXES = {
    "GroupLoot", "BonusRoll", "LootFrame", "BottomManagedFrame", "TopManagedFrame",
    "BuffFrame", "DebuffFrame", "DurabilityFrame", "MainMenu", "MultiBar",
    "ActionButton", "StaticPopup", "HelpTip", "GameMenu", "PlayerFrame",
    "TargetFrame", "FocusFrame", "PartyFrame", "CompactRaid", "ChatFrame",
    "GeneralDockManager", "Minimap", "ObjectiveTracker", "WorldMap",
    "CharacterFrame", "CharacterModel", "PaperDoll", "SpellBook", "PlayerSpells",
    "MacroFrame", "TradeFrame", "TaxiFrame", "GossipFrame", "QuestFrame",
    "GhostFrame", "ZoneAbility", "ExtraAction", "OverrideAction", "AlertFrame",
    "QueueStatus", "UIErrors", "RaidBossEmote", "MirrorTimer",
}

local function SafeFrameBool(obj, method)
    if not (obj and type(obj[method]) == "function") then return nil end
    local ok, val = pcall(obj[method], obj)
    if not ok or F.IsSecret(val) then return nil end
    return val == true
end

local function SafeFrameString(obj, method)
    if not (obj and type(obj[method]) == "function") then return nil end
    local ok, val = pcall(obj[method], obj)
    if not ok then return nil end
    return F.PlainString(val, nil)
end

local function SafeFrameNumber(obj, method, fallback)
    if not (obj and type(obj[method]) == "function") then return fallback end
    local ok, val = pcall(obj[method], obj)
    if not ok then return fallback end
    return F.PlainNumber(val, fallback)
end

local function MatchAnyPrefix(name, list)
    if type(name) ~= "string" or name == "" then return false end
    for i = 1, #list do
        local p = list[i]
        if name:sub(1, #p) == p then return true end
    end
    return false
end

local function ClassifyFrameOwner(frame)
    local cur = frame
    for _ = 1, 5 do
        if not cur or not IsSafeFrame(cur) then break end
        local nm = SafeFrameString(cur, "GetName")
        if nm and nm ~= "" then
            if nm:sub(1, 7) == "kkowoUI" or nm:sub(1, 4) == "FUI_" then
                return "kkowoUI"
            end
            if nm:sub(1, 9) == "Ellesmere" or nm:sub(1, 4) == "EUI_"
                or nm:sub(1, 4) == "ERB_" or nm:sub(1, 5) == "ECME_"
                or nm:sub(1, 4) == "EAB_" then
                return "EUI"
            end
            if MatchAnyPrefix(nm, BLIZZ_KNOWN_PREFIXES) then
                return "Blizzard"
            end
        end
        local okP, par = pcall(cur.GetParent, cur)
        if not okP or par == cur or par == _G.UIParent or par == _G.WorldFrame then
            break
        end
        cur = par
    end
    if SafeFrameBool(frame, "IsProtected") == true then
        return "Blizzard"
    end
    return "Other"
end

local function DescribeFrameName(frame)
    local nm = SafeFrameString(frame, "GetName")
    if nm and nm ~= "" then return nm end
    local ot = SafeFrameString(frame, "GetObjectType") or "Frame"
    local cur = frame
    for depth = 1, 3 do
        local okP, par = pcall(cur.GetParent, cur)
        if not okP or not par or par == cur or not IsSafeFrame(par) then break end
        local pnm = SafeFrameString(par, "GetName")
        if pnm and pnm ~= "" then
            return string_format("%s.<anon %s d%d>", pnm, ot, depth)
        end
        cur = par
    end
    return "<anon " .. ot .. ">"
end

local function ComputeEffectiveAlpha(frame)
    local ea = SafeFrameNumber(frame, "GetEffectiveAlpha", nil)
    if ea ~= nil then return ea end
    local acc = 1
    local cur = frame
    for _ = 1, 12 do
        if not cur or not IsSafeFrame(cur) then break end
        local a = SafeFrameNumber(cur, "GetAlpha", 1) or 1
        acc = acc * a
        local okP, par = pcall(cur.GetParent, cur)
        if not okP or not par or par == cur or par == _G.WorldFrame then break end
        cur = par
    end
    return acc
end

local function RegionLooksVisible(reg)
    if not reg or not IsSafeFrame(reg) then return false end
    if SafeFrameBool(reg, "IsShown") == false then return false end
    local a = SafeFrameNumber(reg, "GetAlpha", 1) or 1
    if a <= 0.02 then return false end
    local ot = SafeFrameString(reg, "GetObjectType")
    if ot == "FontString" then
        if type(reg.GetText) ~= "function" then return true end
        local okT, txt = pcall(reg.GetText, reg)
        if not okT then return false end
        if F.IsSecret(txt) then return true end
        return type(txt) == "string" and txt ~= ""
    elseif ot == "Texture" then
        if type(reg.GetAtlas) == "function" then
            local okA, atl = pcall(reg.GetAtlas, reg)
            if okA and (F.IsSecret(atl) or (type(atl) == "string" and atl ~= "")) then
                return true
            end
        end
        if type(reg.GetTexture) == "function" then
            local okT, tex = pcall(reg.GetTexture, reg)
            if okT and (F.IsSecret(tex) or (type(tex) ~= "nil" and tex ~= "")) then
                return true
            end
        end
        -- 某些纯色贴图在 mock 或旧端仅保留顶点色，保守检查 GetColorTexture / _colorTex
        if reg._colorTexture ~= nil or reg._texture ~= nil then return true end
        return false
    elseif ot == "MaskTexture" then
        return false
    end
    return true
end

local VISUAL_WIDGET_TYPES = {
    StatusBar = true, EditBox = true, ScrollingMessageFrame = true,
    SimpleHTML = true, Cooldown = true, PlayerModel = true,
    DressUpModel = true, Model = true, ModelScene = true, Slider = true,
}

local function FrameHasVisibleVisual(frame, depth)
    depth = depth or 0
    if depth > 3 or not IsSafeFrame(frame) then return false end
    if SafeFrameBool(frame, "IsShown") == false then return false end
    local a = SafeFrameNumber(frame, "GetAlpha", 1) or 1
    if a <= 0.02 then return false end

    local ot = SafeFrameString(frame, "GetObjectType")
    if depth > 0 and ot and VISUAL_WIDGET_TYPES[ot] then
        return true
    end

    if type(frame.GetRegions) == "function" then
        local okR, regs = pcall(function() return { frame:GetRegions() } end)
        if okR and type(regs) == "table" then
            for i = 1, #regs do
                if RegionLooksVisible(regs[i]) then
                    return true
                end
            end
        end
    end

    if depth < 3 and type(frame.GetChildren) == "function" then
        local okC, children = pcall(function() return { frame:GetChildren() } end)
        if okC and type(children) == "table" then
            for i = 1, #children do
                if FrameHasVisibleVisual(children[i], depth + 1) then
                    return true
                end
            end
        end
    end
    return false
end

local function InspectFrameForClickCheck(f)
    if not IsSafeFrame(f) then return nil end
    local shown = SafeFrameBool(f, "IsShown")
    local visible = SafeFrameBool(f, "IsVisible")
    if visible == nil then visible = shown end
    local mouseClick = SafeFrameBool(f, "IsMouseClickEnabled")
    local mouseMotion = SafeFrameBool(f, "IsMouseMotionEnabled")
    local mouseAny = SafeFrameBool(f, "IsMouseEnabled")
    if mouseClick == nil then mouseClick = (mouseAny == true) end
    if mouseMotion == nil then mouseMotion = (mouseAny == true) end

    local effAlpha = ComputeEffectiveAlpha(f)
    local alpha = SafeFrameNumber(f, "GetAlpha", 1) or 1
    local w = SafeFrameNumber(f, "GetWidth", 0) or 0
    local h = SafeFrameNumber(f, "GetHeight", 0) or 0
    local hasVisual = visible == true and effAlpha >= 0.05 and FrameHasVisibleVisual(f, 0) or false
    local invisible = (effAlpha < 0.05) or (not hasVisual)
    local isClickBlocker = (visible == true) and (mouseClick == true) and (w > 0 and h > 0) and invisible

    return {
        frame = f,
        name = DescribeFrameName(f),
        owner = ClassifyFrameOwner(f),
        objectType = SafeFrameString(f, "GetObjectType") or "Frame",
        strata = SafeFrameString(f, "GetFrameStrata") or "?",
        level = SafeFrameNumber(f, "GetFrameLevel", 0) or 0,
        w = Round2(w) or 0,
        h = Round2(h) or 0,
        alpha = Round2(alpha) or 0,
        effAlpha = Round2(effAlpha) or 0,
        shown = shown == true,
        visible = visible == true,
        mouseClick = mouseClick == true,
        mouseMotion = mouseMotion == true,
        hasVisual = hasVisual,
        reason = (effAlpha < 0.05) and "effAlpha<0.05" or ((not hasVisual) and "noVisibleRegion" or "visible"),
        isClickBlocker = isClickBlocker,
    }
end

function Diag.ScanClickBlockers(opts)
    opts = type(opts) == "table" and opts or {}
    local inCombat = (InCombatLockdown and InCombatLockdown()) == true
    local inInst, instType = false, "none"
    if type(_G.IsInInstance) == "function" then
        local okI, flag, typ = pcall(_G.IsInInstance)
        if okI then
            inInst = (not F.IsSecret(flag)) and flag == true
            instType = F.PlainString(typ, "none") or "none"
        end
    end

    -- 1) 鼠标指针下方框体栈（同时兼容 12.x GetMouseFoci 与旧接口 GetMouseFocus）
    local mouseFoci = {}
    local rawFoci = nil
    if type(_G.GetMouseFoci) == "function" then
        local okF, list = pcall(_G.GetMouseFoci)
        if okF and type(list) == "table" then
            rawFoci = list
        end
    elseif type(_G.GetMouseFocus) == "function" then
        local okF, single = pcall(_G.GetMouseFocus)
        if okF and single then
            rawFoci = { single }
        end
    end
    if rawFoci then
        for i = 1, #rawFoci do
            local rec = InspectFrameForClickCheck(rawFoci[i])
            if rec then
                mouseFoci[#mouseFoci + 1] = rec
            end
        end
    end

    -- 2) 全屏枚举：已显示 + 接收鼠标点击 + 实际看不见（effAlpha < 0.05 或无任何可见区域）
    local invisibleBlockers = {}
    local byOwner = { kkowoUI = {}, Blizzard = {}, EUI = {}, Other = {} }
    local enumFn = _G.EnumerateFrames
    if type(enumFn) == "function" then
        local okNext, cur = pcall(enumFn)
        local guard = 0
        while okNext and cur and guard < 60000 do
            guard = guard + 1
            if cur ~= _G.WorldFrame and cur ~= _G.UIParent and IsSafeFrame(cur) then
                local visible = SafeFrameBool(cur, "IsVisible")
                if visible == nil then visible = SafeFrameBool(cur, "IsShown") end
                if visible == true then
                    local mc = SafeFrameBool(cur, "IsMouseClickEnabled")
                    if mc == nil then mc = SafeFrameBool(cur, "IsMouseEnabled") end
                    if mc == true then
                        local rec = InspectFrameForClickCheck(cur)
                        if rec and rec.isClickBlocker then
                            if not opts.ownerFilter or opts.ownerFilter == rec.owner then
                                invisibleBlockers[#invisibleBlockers + 1] = rec
                                local bucket = byOwner[rec.owner] or byOwner.Other
                                bucket[#bucket + 1] = rec
                            end
                        end
                    end
                end
            end
            okNext, cur = pcall(enumFn, cur)
        end
    end

    return {
        timestamp = NowStamp(),
        inCombat = inCombat,
        inInstance = inInst,
        instanceType = instType,
        mouseFoci = mouseFoci,
        invisibleBlockers = invisibleBlockers,
        byOwner = byOwner,
    }
end

local OWNER_COLOR = {
    kkowoUI = "|cffff6b6b[kkowoUI]|r",
    Blizzard = "|cffffd166[Blizzard]|r",
    EUI = "|cff6ec6ff[EUI]|r",
    Other = "|cffb0b8c8[其它]|r",
}

function Diag.ClickCheck(arg)
    local filter = nil
    local cleanArg = F.PlainString(arg, "") or ""
    cleanArg = cleanArg:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if cleanArg == "kk" or cleanArg == "kkowoui" then
        filter = "kkowoUI"
    elseif cleanArg == "blizz" or cleanArg == "blizzard" then
        filter = "Blizzard"
    elseif cleanArg == "eui" then
        filter = "EUI"
    end

    local res = Diag.ScanClickBlockers({ ownerFilter = filter })
    F.Print(string_format(
        "隐形挡点击排查（只读·%s·地点=%s）：鼠标下 %d 个框体，全屏疑似隐形吃点击 %d 个（kkowoUI=%d / Blizzard=%d / EUI=%d / 其它=%d）",
        res.inCombat and "战斗中" or "脱战",
        tostring(res.instanceType),
        #res.mouseFoci,
        #res.invisibleBlockers,
        #res.byOwner.kkowoUI,
        #res.byOwner.Blizzard,
        #res.byOwner.EUI,
        #res.byOwner.Other
    ))

    if #res.mouseFoci > 0 then
        _G.print("  |cffdca77f--- 鼠标指针下方框体栈（自上而下）---|r")
        local limit = math_min(#res.mouseFoci, 12)
        for i = 1, limit do
            local r = res.mouseFoci[i]
            local warn = r.isClickBlocker and " |cffff4444<< 疑似隐形挡点击(" .. r.reason .. ")|r" or ""
            _G.print(string_format(
                "  #%d %s %s [%s:%d] %.0fx%.0f a=%.2f(eff=%.2f) click=%s motion=%s%s",
                i, OWNER_COLOR[r.owner] or "[?]", r.name, r.strata, r.level,
                r.w, r.h, r.alpha, r.effAlpha, tostring(r.mouseClick), tostring(r.mouseMotion), warn
            ))
        end
    else
        _G.print("  鼠标指针下方无框体（或正对 WorldFrame）。")
    end

    if #res.invisibleBlockers > 0 then
        _G.print("  |cffdca77f--- 全屏已显示 + 吃点击 + 不可见框体 ---|r")
        local shownCount = 0
        local order = { "kkowoUI", "Blizzard", "EUI", "Other" }
        for _, grp in ipairs(order) do
            local list = res.byOwner[grp]
            for i = 1, #list do
                if shownCount >= 24 then break end
                shownCount = shownCount + 1
                local r = list[i]
                _G.print(string_format(
                    "  %s %s [%s:%d] %.0fx%.0f effA=%.2f 原因=%s",
                    OWNER_COLOR[r.owner] or "[?]", r.name, r.strata, r.level,
                    r.w, r.h, r.effAlpha, r.reason
                ))
            end
        end
        if #res.invisibleBlockers > shownCount then
            _G.print(string_format("  ...其余 %d 个已省略（可用 /kk clickcheck kk 或 blizz 筛选）。", #res.invisibleBlockers - shownCount))
        end
    else
        _G.print("  |cff52d669未发现全屏隐形吃点击框体。|r")
    end
    return res
end

----------------------------------------------------------------------
--  6) /kk fade why — 只读排查脱战淡隐各条件读数与阻挡原因（战斗中安全）
----------------------------------------------------------------------
function Diag.FadeWhy()
    local im = F.Modules and F.Modules.Get and F.Modules.Get("immersiveHUD")
    if im and im.PrintFadeWhy then
        return im:PrintFadeWhy()
    end
    F.Print("脱战淡隐模块尚未加载。")
    return nil
end
