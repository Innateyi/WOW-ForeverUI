----------------------------------------------------------------------
--  kkowoUI — Modules/QuestBar.lua
--  极简现代任务快捷条：[接] [交] [通告]
--  • 职业主题色激活高亮，支持战斗自动淡出与 EUI 解锁模式
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, setmetatable, tostring, type = ipairs, pairs, pcall, setmetatable, tostring, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("questBar", {
    title = "任务快捷条",
    desc = "紧凑的「接 / 交 / 通告」任务快捷按钮，默认无缝嵌入任务追踪标题栏，一键切换自动接交与小队进度通告。",
    group = "quest",
    order = 20,
    defaults = {
        enabled = true,
        dockMode = "header",   -- "header"（嵌入任务追踪标题栏）| "free"（自由悬浮）
        showZoneBtn = true,    -- 附加「本图」一键收纳按钮（左键仅看当前地图 / 右键折叠已完成）
        announce = false,
        combatFade = false,
        v2NoCombatFadeMigrated = false,
        btnWidth = 34,
        btnHeight = 20,
        scale = 1.0,
    },
})

local barFrame = nil
local buttons = {}
local announcedQuests = {}
local hookedFilters = setmetatable({}, { __mode = "k" })
local hookedHeaders = setmetatable({}, { __mode = "k" })
local hookedTrackers = setmetatable({}, { __mode = "k" })
local updateFade = nil
local applyFreePos = nil
local isDockedNow = false
local dockPollTicker = nil
local eqtInitHooked = false

local BUTTON_DEFS = {
    { kind = "accept",   label = "接",   dockW = 22, tip = "自动接任务" },
    { kind = "turnIn",   label = "交",   dockW = 22, tip = "自动交任务" },
    { kind = "announce", label = "通告", dockW = 32, tip = "小队/团队任务进度通告" },
    { kind = "zone",     label = "本图", dockW = 30, tip = "任务追踪栏智能收纳" },
}

local function GetZoneFilterState()
    local EQT = _G.EllesmereUIQuestTracker
    if EQT and type(EQT.Cfg) == "function" then
        local okF, fOn = pcall(EQT.Cfg, "filterEnabled")
        local okZ, zOn = pcall(EQT.Cfg, "filterZone")
        local okC, cOn = pcall(EQT.Cfg, "customCollapseCompleted")
        return (okF and fOn == true and (not okZ or zOn ~= false)), (okC and cOn == true)
    end
    return false, false
end

local function ToggleZoneFilter()
    local EQT = _G.EllesmereUIQuestTracker
    if not (EQT and type(EQT.Set) == "function") then return end
    local curZone = GetZoneFilterState()
    local nextVal = not curZone
    pcall(EQT.Set, "filterZone", true)
    pcall(EQT.Set, "filterEnabled", nextVal)
    if EQT.ApplyQuestWatches then pcall(EQT.ApplyQuestWatches) end
    local EUI = _G.EllesmereUI
    if EUI and EUI.RefreshQuestTrackerRows then pcall(EUI.RefreshQuestTrackerRows) end
    F.Print("任务追踪筛选：" .. (nextVal and "|cff5fd3a6仅显示当前地图任务|r" or "|cff888888显示全部已追踪任务|r"))
end

local function ToggleCollapseCompleted()
    local EQT = _G.EllesmereUIQuestTracker
    if not (EQT and type(EQT.Set) == "function") then return end
    local _, curCol = GetZoneFilterState()
    local nextVal = not curCol
    pcall(EQT.Set, "customCollapseCompleted", nextVal)
    if EQT.ApplyQuestWatches then pcall(EQT.ApplyQuestWatches) end
    local EUI = _G.EllesmereUI
    if EUI and EUI.RefreshQuestTrackerRows then pcall(EUI.RefreshQuestTrackerRows) end
    F.Print("已完成任务自动折叠：" .. (nextVal and "|cff5fd3a6已开启|r" or "|cff888888已关闭|r"))
end

local function SendPartyNotice(msg)
    if _G.IsInGroup and _G.IsInGroup() then
        local chan
        local instCat = _G.LE_PARTY_CATEGORY_INSTANCE
        if instCat and _G.IsInGroup(instCat) then
            chan = "INSTANCE_CHAT"
        elseif _G.IsInRaid and _G.IsInRaid() then
            chan = "RAID"
        else
            chan = "PARTY"
        end
        pcall(_G.SendChatMessage, msg, chan)
    end
end

-- 登录瞬间任务日志可能还是空的：在第一次读到非空日志之前不算「已预填」
local questLogSeeded = false

-- 将当前已完成任务预填进已通告表，避免开启「通告」或重载后把旧的已完成任务刷屏发进小队
local function SeedCompletedQuests()
    local QL = _G.C_QuestLog
    if not (QL and QL.GetNumQuestLogEntries and QL.GetInfo and QL.IsComplete) then
        return
    end
    local num = F.PlainNumber(QL.GetNumQuestLogEntries(), 0)
    if num > 0 then questLogSeeded = true end
    for i = 1, num do
        local info = QL.GetInfo(i)
        if info and info.questID and not info.isHeader and QL.IsComplete(info.questID) then
            announcedQuests[info.questID] = true
        end
    end
end

local function FindTrackerHeader()
    local tracker = _G.EUI_CustomQuestTracker
    if not (tracker and tracker.GetChildren) then
        return nil, nil
    end
    for _, child in ipairs({ tracker:GetChildren() }) do
        if child and child.count and child.toggle then
            return tracker, child
        end
    end
    return tracker, nil
end

-- EUI 任务追踪：折叠的地区标题被写成「+ 地区名」。开头的英文「+」让整行按英文字体的行高排版，
-- 中文字形顶部超出行框，被追踪栏的滚动裁切区切掉一截；地区名还会被「+ 」往右挤。
-- 这里把它改成「地区名 ＋」（全角加号放在名字后面、调暗），名字不再移动，行高按中文排版。
-- 只改显示文字，点击折叠 / 展开仍由 EUI 处理（它按行记的是地区 ID，不看文字）。
local zoneLineHooked = setmetatable({}, { __mode = "k" })
local zoneTrackerHooked = false
local zoneFixing = false

local function GetLineKind(fs)
    local p = fs.GetParent and fs:GetParent()
    return p and p.kind
end

local function OnZoneLineSetText(fs, text)
    if zoneFixing or not mod._active or type(text) ~= "string" or F.IsSecret(text) then return end
    if text:sub(1, 2) ~= "+ " or GetLineKind(fs) ~= "zone" then return end
    zoneFixing = true
    pcall(fs.SetText, fs, text:sub(3) .. "  |cff8a8f9a＋|r")   -- 与下方 ZONE_SUFFIX 一致
    zoneFixing = false
end

-- 中文字形会比文字框顶端高出一两个像素（当前安装的字体字身偏大）。追踪列表的滚动区是贴着第一行裁切的，
-- 地区收起后整个列表只剩一行，字顶就被齐刷刷切掉。内容装得下、根本不用滚动时就不裁切，
-- 只有真的需要滚动时才恢复裁切。
local function SyncTrackerClip(sf, child)
    if not (sf.SetClipsChildren and sf.GetHeight and child.GetHeight) then return end
    local viewH = F.PlainNumber(sf:GetHeight(), 0)
    local contentH = F.PlainNumber(child:GetHeight(), 0)
    local needScroll = mod._active and contentH > viewH + 2
    pcall(sf.SetClipsChildren, sf, needScroll or not mod._active)
end

local function HookZoneLines()
    local tracker = _G.EUI_CustomQuestTracker
    if not (tracker and tracker.GetChildren) then return end
    for _, sf in ipairs({ tracker:GetChildren() }) do
        local child = sf and sf.GetScrollChild and sf:GetScrollChild()
        if child then SyncTrackerClip(sf, child) end
        if child and child.GetChildren then
            for _, line in ipairs({ child:GetChildren() }) do
                local fs = line and line.text
                if fs and fs.GetText and not zoneLineHooked[fs] then
                    zoneLineHooked[fs] = true
                    _G.hooksecurefunc(fs, "SetText", OnZoneLineSetText)
                    OnZoneLineSetText(fs, fs:GetText())
                end
            end
        end
    end
end

-- 停用模块时把已改过的地区标题还原成 EUI 原本的「+ 地区名」
local ZONE_SUFFIX = "  |cff8a8f9a＋|r"
local function RestoreZoneLines()
    local tracker = _G.EUI_CustomQuestTracker
    if tracker and tracker.GetChildren then
        for _, sf in ipairs({ tracker:GetChildren() }) do
            if sf and sf.GetScrollChild and sf.SetClipsChildren then pcall(sf.SetClipsChildren, sf, true) end
        end
    end
    for fs in pairs(zoneLineHooked) do
        local t = fs.GetText and fs:GetText()
        if type(t) == "string" and not F.IsSecret(t) and t:sub(-#ZONE_SUFFIX) == ZONE_SUFFIX then
            zoneFixing = true
            pcall(fs.SetText, fs, "+ " .. t:sub(1, -#ZONE_SUFFIX - 1))
            zoneFixing = false
        end
    end
end

local function HookZoneTracker()
    if zoneTrackerHooked then
        HookZoneLines()
        return
    end
    local tracker = _G.EUI_CustomQuestTracker
    if not (tracker and tracker.SetHeight) then return end
    zoneTrackerHooked = true
    -- EUI 每次重绘末尾都会 SetHeight：借它发现新建的行（已挂过的行直接跳过，开销只是遍历几十个子框）
    _G.hooksecurefunc(tracker, "SetHeight", function()
        if mod._active then HookZoneLines() end
    end)
    HookZoneLines()
end

local function SetPanelChromeShown(frame, shown)
    if frame._fuiBg then frame._fuiBg:SetShown(shown) end
    if frame._fuiBorders then
        for _, ln in ipairs(frame._fuiBorders) do
            ln:SetShown(shown)
        end
    end
end

local RefreshButtons
local refreshQueued = false

local function HookFilterAnchor(filterBtn)
    if not filterBtn or hookedFilters[filterBtn] or not filterBtn.HookScript then
        return
    end
    hookedFilters[filterBtn] = true
    filterBtn:HookScript("OnShow", function() RefreshButtons() end)
    filterBtn:HookScript("OnHide", function() RefreshButtons() end)
end

local function StabilizeTrackerHeader(header)
    if not header then return end
    -- 固定 EUI 折叠符号（+ / -）宽度为恒定 14px 居中，防止折叠切换时因 + 比 - 更宽而挤动 17/40 与快捷按钮
    if header.toggle and header.toggle.SetWidth then
        header.toggle:SetWidth(14)
        if header.toggle.SetJustifyH then
            header.toggle:SetJustifyH("CENTER")
        end
    end
    if header.count and header.count.SetJustifyH then
        header.count:SetJustifyH("RIGHT")
    end
    if not hookedHeaders[header] and header.HookScript then
        hookedHeaders[header] = true
        header:HookScript("OnClick", function()
            C_Timer.After(0, function()
                if header.toggle and header.toggle.SetWidth then
                    header.toggle:SetWidth(14)
                end
                RefreshButtons()
            end)
        end)
    end
end

local function StopDockPoll()
    if dockPollTicker then
        dockPollTicker:Cancel()
        dockPollTicker = nil
    end
end

local function EnsureDockPoll()
    if dockPollTicker or not (C_Timer and C_Timer.NewTicker) then return end
    local tries = 0
    dockPollTicker = C_Timer.NewTicker(0.4, function()
        tries = tries + 1
        RefreshButtons()
        if isDockedNow or tries >= 35 or not mod._active then
            StopDockPoll()
        end
    end)
end

local function HookEQTInitOnce()
    if eqtInitHooked then return end
    local EQT = _G.EllesmereUIQuestTracker
    if EQT and type(EQT.InitCustom) == "function" then
        eqtInitHooked = true
        _G.hooksecurefunc(EQT, "InitCustom", function()
            C_Timer.After(0, RefreshButtons)
            C_Timer.After(0.2, RefreshButtons)
        end)
    end
end

local function ApplyDockAndLayout()
    if not barFrame then return end
    local db = mod:GetDB()
    local wantDock = (db.dockMode or "header") == "header"
    local tracker, header = nil, nil
    if wantDock then
        tracker, header = FindTrackerHeader()
    end
    local docked = wantDock and header ~= nil
    isDockedNow = docked

    if docked then
        StopDockPoll()
        StabilizeTrackerHeader(header)
        if tracker and not hookedTrackers[tracker] and tracker.HookScript then
            hookedTrackers[tracker] = true
            -- 追踪器每次增删任务行都会改变尺寸：合并到下一帧只重排一次
            local function queue()
                if refreshQueued or not mod._active then return end
                refreshQueued = true
                C_Timer.After(0, function()
                    refreshQueued = false
                    RefreshButtons()
                end)
            end
            tracker:HookScript("OnShow", queue)
            tracker:HookScript("OnSizeChanged", queue)
        end
        if barFrame:GetParent() ~= header then
            barFrame:SetParent(header)
        end
        barFrame:SetFrameStrata(header:GetFrameStrata() or "LOW")
        barFrame:SetFrameLevel((header:GetFrameLevel() or 2) + 8)
        barFrame:SetScale(1.0)

        local bh, gap = 18, 3
        local x = 0
        local showZone = db.showZoneBtn ~= false and _G.EllesmereUIQuestTracker ~= nil
        for i, btn in ipairs(buttons) do
            if btn.kind == "zone" and not showZone then
                btn:Hide()
            else
                local w = BUTTON_DEFS[i].dockW or 24
                btn:SetSize(w, bh)
                btn:ClearAllPoints()
                btn:SetPoint("LEFT", barFrame, "LEFT", x, 0)
                btn:Show()
                x = x + w + gap
            end
        end
        barFrame:SetSize(x > 0 and (x - gap) or 60, bh)

        barFrame:ClearAllPoints()
        if header.filter then
            HookFilterAnchor(header.filter)
        end
        if header.filter and header.filter:IsShown() then
            barFrame:SetPoint("RIGHT", header.filter, "LEFT", -8, 0)
        elseif header.count and header.count:IsShown() then
            barFrame:SetPoint("RIGHT", header.count, "LEFT", -10, 0)
        elseif header.toggle then
            barFrame:SetPoint("RIGHT", header.toggle, "LEFT", -10, 0)
        else
            barFrame:SetPoint("RIGHT", header, "RIGHT", -28, 0)
        end
        barFrame:Show()
    elseif wantDock then
        -- 嵌入模式等待 EUI_CustomQuestTracker 完成初始化：绝不回退漂浮到任务列表上方
        barFrame:Hide()
        HookEQTInitOnce()
        EnsureDockPoll()
    else
        StopDockPoll()
        if barFrame:GetParent() ~= _G.UIParent then
            barFrame:SetParent(_G.UIParent)
        end
        barFrame:SetFrameStrata("MEDIUM")
        barFrame:SetScale(db.scale or 1.0)

        local bw, bh, gap = db.btnWidth or 34, db.btnHeight or 20, 4
        local showZone = db.showZoneBtn ~= false and _G.EllesmereUIQuestTracker ~= nil
        local idx = 0
        for _, btn in ipairs(buttons) do
            if btn.kind == "zone" and not showZone then
                btn:Hide()
            else
                btn:SetSize(bw, bh)
                btn:ClearAllPoints()
                btn:SetPoint("LEFT", barFrame, "LEFT", idx * (bw + gap), 0)
                btn:Show()
                idx = idx + 1
            end
        end
        barFrame:SetSize(idx > 0 and (bw * idx + gap * (idx - 1)) or bw, bh)
        if applyFreePos then
            applyFreePos()
        end
        barFrame:Show()
    end
end

RefreshButtons = function()
    if not barFrame then
        return
    end
    -- 追踪器 OnShow/OnSizeChanged、标题栏点击、EQT.InitCustom 等永久钩子与延时回调都会走到这里：
    -- 停用后必须保持隐藏，否则会把已关闭的快捷条「复活」
    if not mod._active then
        StopDockPoll()
        barFrame:Hide()
        return
    end
    ApplyDockAndLayout()
    HookZoneTracker()

    local db = mod:GetDB()
    local qa = F.Modules.Get("questAuto")
    local ar, ag, ab = F.Theme.GetAccent()
    local zoneOnly, collapseDone = GetZoneFilterState()
    local states = {
        accept = qa and qa:GetMode("autoAccept") or false,
        turnIn = qa and qa:GetMode("autoTurnIn") or false,
        announce = db.announce == true,
        zone = zoneOnly,
    }
    for _, b in ipairs(buttons) do
        local on = states[b.kind]
        b._isOn = on
        b._collapseDone = collapseDone
        if isDockedNow then
            SetPanelChromeShown(b, false)
            F.Theme.SetGlassShown(b, false)
            if on then
                b._pillBg:SetColorTexture(ar, ag, ab, 0.14)
                b._pillBg:Show()
                b._accentLine:SetHeight(1.5)
                b._accentLine:ClearAllPoints()
                b._accentLine:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 2, 0)
                b._accentLine:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 0)
                b._accentLine:SetColorTexture(ar, ag, ab, 0.95)
                b._accentLine:Show()
                b._label:SetTextColor(ar, ag, ab, 1)
            else
                b._pillBg:Hide()
                b._accentLine:Hide()
                b._label:SetTextColor(0.62, 0.65, 0.70, 0.85)
            end
        else
            b._pillBg:Hide()
            SetPanelChromeShown(b, false)
            b._accentLine:Hide()
            F.Theme.StyleGlassSurface(b, {
                bgAlpha = on and 0.92 or 0.78,
                borderAlpha = on and 0.90 or 0.65,
                restAura = 0.05,
                activeAura = 0.22,
                hoverAura = 0.30,
                borderTintMix = on and 0.30 or 0.12,
                active = on,
                hovered = b.IsMouseOver and b:IsMouseOver() or false,
            })
            if on then
                b._label:SetTextColor(ar, ag, ab, 1)
            else
                b._label:SetTextColor(0.62, 0.65, 0.71, 0.92)
            end
        end
    end
    if updateFade then
        updateFade(F.db and F.db.theme and F.db.theme.combatFadeAlpha or 0.18, 1.0)
    end
end

local function CreateBar()
    if barFrame then
        return
    end
    local db = mod:GetDB()
    local bw, bh, gap = db.btnWidth or 34, db.btnHeight or 20, 4
    barFrame = CreateFrame("Frame", "kkowoUI_QuestBar", _G.UIParent)
    barFrame:SetSize(bw * #BUTTON_DEFS + gap * (#BUTTON_DEFS - 1), bh)
    barFrame:SetFrameStrata("MEDIUM")
    barFrame:SetMovable(true)
    barFrame:SetClampedToScreen(true)

    local function AttachFreeDrag(f)
        local dragging = false
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function()
            if not isDockedNow and _G.IsShiftKeyDown and _G.IsShiftKeyDown() and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
                dragging = true
                barFrame:StartMoving()
            end
        end)
        f:SetScript("OnDragStop", function()
            if not dragging then return end
            dragging = false
            if not isDockedNow then
                barFrame:StopMovingOrSizing()
                local pt, _, rpt, x, y = barFrame:GetPoint(1)
                if pt then F.DB.SavePosition("QuestBar", pt, rpt, x, y) end
            end
        end)
    end
    AttachFreeDrag(barFrame)

    for i, d in ipairs(BUTTON_DEFS) do
        local btn = CreateFrame("Button", nil, barFrame)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetSize(bw, bh)
        btn:SetPoint("LEFT", barFrame, "LEFT", (i - 1) * (bw + gap), 0)
        btn.kind = d.kind
        AttachFreeDrag(btn)

        local pillBg = btn:CreateTexture(nil, "BACKGROUND")
        pillBg:SetAllPoints()
        pillBg:Hide()
        btn._pillBg = pillBg

        local lbl = btn:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(lbl, 11, "", 0.9, 0.9, 0.92, 1)
        lbl:SetPoint("CENTER", btn, "CENTER", 0, 0)
        lbl:SetText(d.label)
        btn._label = lbl

        local line = btn:CreateTexture(nil, "OVERLAY")
        line:SetHeight(2)
        line:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 1, 0)
        line:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 0)
        btn._accentLine = line

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)

        btn:SetScript("OnClick", function(_, mouseBtn)
            local qa = F.Modules.Get("questAuto")
            if d.kind == "accept" and qa then
                qa:SetMode("autoAccept", not qa:GetMode("autoAccept"))
            elseif d.kind == "turnIn" and qa then
                qa:SetMode("autoTurnIn", not qa:GetMode("autoTurnIn"))
            elseif d.kind == "announce" then
                local nextVal = not db.announce
                if nextVal then
                    SeedCompletedQuests()
                end
                db.announce = nextVal
            elseif d.kind == "zone" then
                if mouseBtn == "RightButton" then
                    ToggleCollapseCompleted()
                else
                    ToggleZoneFilter()
                end
            end
            RefreshButtons()
        end)
        btn:SetScript("OnEnter", function(self)
            if not isDockedNow then
                F.Theme.SetGlassState(self, true, self._isOn == true)
            end
            if not self._isOn then
                self._label:SetTextColor(0.92, 0.94, 0.97, 1)
            end
            GameTooltip:SetOwner(self, "ANCHOR_TOP", 0, 4)
            GameTooltip:AddLine(d.tip, 1, 1, 1)
            if d.kind == "zone" then
                local zOn, cOn = GetZoneFilterState()
                GameTooltip:AddDoubleLine("仅看当前地图", zOn and "已开启" or "已关闭", 0.68, 0.72, 0.78, zOn and 0.37 or 0.65, zOn and 0.85 or 0.68, zOn and 0.56 or 0.72)
                GameTooltip:AddDoubleLine("折叠已完成任务", cOn and "已开启" or "已关闭", 0.68, 0.72, 0.78, cOn and 0.37 or 0.65, cOn and 0.85 or 0.68, cOn and 0.56 or 0.72)
                GameTooltip:AddLine("左键：切换仅看当前地图任务", 0.75, 0.78, 0.82)
                GameTooltip:AddLine("右键：切换自动折叠已完成任务", 0.75, 0.78, 0.82)
            else
                if self._isOn then
                    GameTooltip:AddDoubleLine("当前状态", "已开启", 0.68, 0.72, 0.78, 0.37, 0.85, 0.56)
                else
                    GameTooltip:AddDoubleLine("当前状态", "已关闭", 0.68, 0.72, 0.78, 0.65, 0.68, 0.72)
                end
                GameTooltip:AddLine("左键点击切换", 0.75, 0.78, 0.82)
            end
            if isDockedNow then
                GameTooltip:AddLine("可在 /kk「任务快捷条」中切换为自由悬浮", 0.55, 0.58, 0.64)
            else
                GameTooltip:AddLine("Shift + 左键拖动可移动位置", 0.65, 0.68, 0.72)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            if not isDockedNow then
                F.Theme.SetGlassState(self, false, self._isOn == true)
            end
            if not self._isOn then
                if isDockedNow then
                    self._label:SetTextColor(0.62, 0.65, 0.70, 0.85)
                else
                    self._label:SetTextColor(0.62, 0.65, 0.71, 0.92)
                end
            end
            GameTooltip:Hide()
        end)

        buttons[i] = btn
    end

    applyFreePos = F.Mover.Register({
        key = "QuestBar",
        label = "任务快捷条（接/交/通告）",
        frame = barFrame,
        order = 10,
        defaultPoint = "TOPRIGHT",
        defaultRelPoint = "TOPRIGHT",
        defaultX = -260,
        defaultY = -220,
        allowShiftDrag = false,
        isHidden = function()
            return (mod:GetDB().dockMode or "header") ~= "free"
        end,
        isAnchored = function()
            return (mod:GetDB().dockMode or "header") ~= "free"
        end,
        onReanchor = ApplyDockAndLayout,
    })

    updateFade = F.Theme.AttachCombatFade(barFrame, function()
        return mod:GetDB().combatFade == true
    end)
end

function mod:OnQuestAccepted(_, questID)
    if not self:GetDB().announce or not questID then
        return
    end
    local title = _G.C_QuestLog and _G.C_QuestLog.GetTitleForQuestID and _G.C_QuestLog.GetTitleForQuestID(questID)
    if title then
        SendPartyNotice("[任务] 已接取：" .. title)
    end
end

function mod:OnQuestLogUpdate()
    if not questLogSeeded then
        -- 第一次拿到完整任务日志：只预填、不通告，杜绝登录后把所有旧的已完成任务刷进队伍频道
        SeedCompletedQuests()
        return
    end
    if not self:GetDB().announce then
        return
    end
    local QL = _G.C_QuestLog
    if not (QL and QL.GetNumQuestLogEntries and QL.GetInfo and QL.IsComplete) then
        return
    end
    for i = 1, F.PlainNumber(QL.GetNumQuestLogEntries(), 0) do
        local info = QL.GetInfo(i)
        if info and info.questID and not info.isHeader and not announcedQuests[info.questID] then
            if QL.IsComplete(info.questID) then
                announcedQuests[info.questID] = true
                SendPartyNotice("[任务] 已完成：" .. (info.title or tostring(info.questID)))
            end
        end
    end
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2NoCombatFadeMigrated then
        db.v2NoCombatFadeMigrated = true
        db.combatFade = false
    end
    CreateBar()
    SeedCompletedQuests()
    HookEQTInitOnce()
    RefreshButtons()
    -- 兜底重挂：若 EUI_CustomQuestTracker 稍晚完成建框，自动吸附进标题栏
    C_Timer.After(0.5, RefreshButtons)
    C_Timer.After(1.5, RefreshButtons)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        SeedCompletedQuests()
        HookEQTInitOnce()
        RefreshButtons()
        C_Timer.After(0.5, RefreshButtons)
        C_Timer.After(1.5, RefreshButtons)
    end)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", RefreshButtons)
    self:RegisterEvent("QUEST_WATCH_LIST_CHANGED", function()
        if not isDockedNow then RefreshButtons() end
    end)
    self:RegisterEvent("QUEST_ACCEPTED", self.OnQuestAccepted)
    -- 任务被交掉/放弃后清除通告记录，可重复任务或重新接取后完成时才能再次通告
    self:RegisterEvent("QUEST_REMOVED", function(_, _, questID)
        questID = F.PlainNumber(questID, nil)
        if questID then announcedQuests[questID] = nil end
    end)
    -- 任务日志更新常成串到达：合并为 0.15 秒一次
    self:RegisterEvent("QUEST_LOG_UPDATE", F.Debounce(0.15, function()
        if not mod._active then return end
        if not isDockedNow then RefreshButtons() end
        mod:OnQuestLogUpdate()
    end))
end

function mod:OnDisable()
    StopDockPoll()
    if barFrame then
        barFrame:Hide()
    end
    RestoreZoneLines()
end

function mod:OnRefresh()
    RefreshButtons()
end

function mod:OnThemeChanged()
    RefreshButtons()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "显示方式",
        tooltip = "默认无缝嵌入任务追踪器「任务 ... 16/40」标题栏内部，不占额外屏幕空间；也可切换为自由悬浮条。",
        values = { header = "嵌入任务追踪标题栏（默认）", free = "自由悬浮（可拖动）" },
        order = { "header", "free" },
        getValue = function() return db.dockMode or "header" end,
        setValue = function(v) db.dockMode = v; RefreshButtons() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示「本图」智能收纳按钮",
        tooltip = "在标题栏新增「本图」按钮：左键一键只看当前地图任务，右键切换自动折叠已完成任务。",
        getValue = function() return db.showZoneBtn ~= false end,
        setValue = function(v) db.showZoneBtn = v == true; RefreshButtons() end,
    }, {
        type = "toggle",
        text = "战斗中自动淡出",
        tooltip = "进入战斗后自动淡出任务快捷按钮，鼠标移上去立刻清晰。",
        getValue = function() return db.combatFade == true end,
        setValue = function(v) db.combatFade = v == true; RefreshButtons() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "自由悬浮缩放",
        tooltip = "仅在「自由悬浮」模式下生效；嵌入标题栏时自动跟随追踪栏缩放。",
        min = 0.7, max = 1.5, step = 0.05,
        getValue = function() return db.scale or 1.0 end,
        setValue = function(v) db.scale = v; RefreshButtons() end,
    }, blank)
    y = y - h
    return y
end
