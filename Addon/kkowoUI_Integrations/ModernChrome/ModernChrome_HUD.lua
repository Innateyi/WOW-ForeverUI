----------------------------------------------------------------------
--  kkowoUI_Integrations — ModernChrome/ModernChrome_HUD.lua
--  EUI 资源/挥砍/施法条统一 + 暴雪 HUD 现代化 + 高清宠物快乐度图标
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

--  5) 统一 EllesmereUI 资源条 / 挥砍计时器 / 施法条 现代极简职业色风格
--     • 绝不改动任何 unlockPos 位置坐标与可见性（visibility）
--     • 首次修改前自动完整快照备份到 db.erbStyleBackup，随时可一键还原
----------------------------------------------------------------------
local function CopyStyleFields(src, keys)
    local out = {}
    if type(src) ~= "table" then return out end
    for _, k in ipairs(keys) do
        out[k] = src[k]
    end
    return out
end

local ERB_UNIFY_VERSION = 3

local function GetERBProfileAndApply()
    -- EUI ResourceBars 直接导出 _G._ERB_AceDB 与 _G._ERB_Apply（EUI_ResourceBars_Events.lua）
    local aceDB = _G._ERB_AceDB
    local applyFn = _G._ERB_Apply
    if aceDB and type(aceDB.profile) == "table" then
        return aceDB.profile, applyFn
    end
    local EUI = _G.EllesmereUI
    local nsMap = EUI and EUI._ModuleNS
    local rbNS = nsMap and nsMap.EllesmereUIResourceBars
    local ERB = rbNS and rbNS.ERB
    if ERB and ERB.db and type(ERB.db.profile) == "table" then
        return ERB.db.profile, function() if ERB.ApplyAll then ERB:ApplyAll() end end
    end
    return nil, nil
end

local ERB_UNIFY_PLAN = {
    general = {
        barTexture = "sm:MerfinMain",
    },
    health = {
        width = 249, height = 14, textSize = 12,
        customColored = false, gradientEnabled = false,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.84,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    primary = {
        width = 249, height = 14, textSize = 12,
        customColored = false, gradientEnabled = false,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.84,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    secondary = {
        pipWidth = 249, pipHeight = 14, textSize = 12,
        classColored = true, darkTheme = false,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.72,
        barBgR = 0.055, barBgG = 0.060, barBgB = 0.072, barBgA = 0.84,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    swingTimer = {
        width = 249, height = 12, rowSpacing = 2,
        texture = "sm:MerfinMain",
        classColored = true,
        textSize = 11,
        hideWhenIdle = true,
        idleHidePerType = true,
        showSpark = true,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.86,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    castBar = {
        width = 229, height = 20, -- 229 + 20 图标 = 249px 与上方资源条像素级等宽
        texture = "sm:MerfinMain",
        classColored = true,
        gradientEnabled = false,
        useBlizzardStyle = false,
        useClassicStyle = false,
        showIconDivider = true,
        showSpark = true,
        spellTextSize = 12, timerSize = 12,
        showTotalDuration = false,
        latencyShowText = false,
        latencyR = 0.90, latencyG = 0.34, latencyB = 0.40, latencyA = 0.55,
        channelOverride = true, channelR = 0.37, channelG = 0.83, channelB = 0.65,
        uninterruptibleOverride = true, uninterruptibleR = 0.52, uninterruptibleG = 0.55, uninterruptibleB = 0.60,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.86,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    gcdBar = {
        width = 249, height = 4,
        texture = "sm:MerfinMain",
        classColored = true,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.84,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
}

local function ApplyUnifiedResourceBars(forceApply)
    local db = mod:GetDB()
    if not (mod._active and db.unifyResourceBars ~= false) then return false end
    -- 版本号门控：首次升级至 v2 自动统一一次（修复此前 GetERB 取值为 nil 导致施法条未生效的问题）
    if not forceApply and db.erbUnifiedVersion == ERB_UNIFY_VERSION then return false end
    local prof, applyFn = GetERBProfileAndApply()
    if type(prof) ~= "table" then return false end

    F.RunOutOfCombat("FUI_ResourceBarsStyle", function()
        if not (mod._active and db.unifyResourceBars ~= false) then return end
        if type(db.erbStyleBackup) ~= "table" then
            local snap = {}
            for sec, spec in pairs(ERB_UNIFY_PLAN) do
                if type(prof[sec]) == "table" then
                    local keys = {}
                    for k in pairs(spec) do keys[#keys + 1] = k end
                    snap[sec] = CopyStyleFields(prof[sec], keys)
                end
            end
            db.erbStyleBackup = snap
        end

        for sec, spec in pairs(ERB_UNIFY_PLAN) do
            prof[sec] = type(prof[sec]) == "table" and prof[sec] or {}
            for k, v in pairs(spec) do
                prof[sec][k] = v
            end
        end
        db.erbUnifiedApplied = true
        db.erbUnifiedVersion = ERB_UNIFY_VERSION

        if applyFn then
            pcall(applyFn)
        end
        if forceApply then
            F.Print("已统一资源条、挥砍条与施法条外观，原有位置不变。")
        end
    end)
    return true
end

local function RestoreResourceBarsStyle(notify)
    local db = mod:GetDB()
    local snap = db.erbStyleBackup
    local prof, applyFn = GetERBProfileAndApply()
    if type(snap) ~= "table" or type(prof) ~= "table" then
        if notify then F.Print("当前没有可还原的资源条样式备份。") end
        return
    end
    F.RunOutOfCombat("FUI_ResourceBarsStyle", function()
        -- 按统一方案逐键还原：备份里原本为 nil 的键（pairs 遍历不到）也要写回 nil，
        -- 否则 249px 宽度 / solid 边框等会永久留在 EUI 配置里；备份时不存在的整段同理清回默认
        for sec, spec in pairs(ERB_UNIFY_PLAN) do
            local dst = prof[sec]
            if type(dst) == "table" then
                local fields = type(snap[sec]) == "table" and snap[sec] or {}
                for k in pairs(spec) do
                    dst[k] = fields[k]
                end
            end
        end
        db.erbStyleBackup = nil
        db.erbUnifiedApplied = false
        db.erbUnifiedVersion = 0
        if applyFn then
            pcall(applyFn)
        end
        if notify then
            F.Print("已还原你之前的资源条 / 挥砍计时器 / 施法条外观设置。")
        end
    end)
end

function mod:UnifyResourceBarsNow()
    self:GetDB().unifyResourceBars = true
    ApplyUnifiedResourceBars(true)
end

function mod:RestoreResourceBarsNow()
    self:GetDB().unifyResourceBars = false
    RestoreResourceBarsStyle(true)
end

-- EUI 解锁模式取消/放弃改动时，若挥砍计时器开启了「闲置时按类型隐藏」，
-- EUI 会把进解锁前的单行快照高度（12）按解锁预览展开后的 2~3 行均分，触发 setHeight 下限 4（约 5px 细线）。
-- 这里零侵入监听解锁模式退出并自愈，并在登录时修复已受损的 <=4.5 高度。
local swingGuard = {}
do
    local preUnlockSwingH = nil
    local swingGuardRegistered = false

    function swingGuard.Heal(expectedH)
        local prof, applyFn = GetERBProfileAndApply()
        local st = type(prof) == "table" and prof.swingTimer
        if type(st) ~= "table" or not st.enabled then return end
        local curH = F.PlainNumber(st.height, nil)
        if not curH then return end
        local textSz = F.PlainNumber(st.textSize, 11) or 11
        local targetH
        if expectedH and expectedH >= 8 and curH <= 5.5 and curH <= expectedH * 0.55 then
            targetH = expectedH
        elseif not expectedH and curH <= 4.5 and textSz >= 9
            -- 登录时的启发式修复只在用户仍使用统一资源条样式时进行；
            -- /kk restorebars 还原为自己的样式后，细线挥砍条可能就是用户本意
            and mod:GetDB().unifyResourceBars ~= false then
            targetH = (ERB_UNIFY_PLAN.swingTimer and ERB_UNIFY_PLAN.swingTimer.height) or 12
        end
        if not targetH then return end
        F.RunOutOfCombat("FUI_HealSwingHeight", function()
            local p2, fn2 = GetERBProfileAndApply()
            local st2 = type(p2) == "table" and p2.swingTimer
            if type(st2) == "table" then
                st2.height = targetH
                if fn2 then pcall(fn2) end
            end
        end)
    end

    function swingGuard.Install()
        if swingGuardRegistered then return end
        local EUI = _G.EllesmereUI
        if not (EUI and EUI.RegisterUnlockModeListener) then return end
        swingGuardRegistered = true
        pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_SwingHeightGuard", function(active, closeAction)
            if not mod._active then return end
            if active then
                local prof = GetERBProfileAndApply()
                local st = type(prof) == "table" and prof.swingTimer
                local h = type(st) == "table" and F.PlainNumber(st.height, 12) or nil
                preUnlockSwingH = (h and h >= 8) and h or nil
            else
                local savedH = preUnlockSwingH
                preUnlockSwingH = nil
                -- 「保存」退出时的高度是用户在解锁模式里亲手调的，不能回滚；
                -- EUI 的均分 bug 只出现在取消 / 放弃改动时
                if savedH and closeAction ~= "save" then
                    C_Timer.After(0, function()
                        if mod._active then swingGuard.Heal(savedH) end
                    end)
                end
            end
        end)
    end

    function swingGuard.Remove()
        if not swingGuardRegistered then return end
        swingGuardRegistered = false
        preUnlockSwingH = nil
        local EUI = _G.EllesmereUI
        if EUI and EUI.UnregisterUnlockModeListener then
            pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_SwingHeightGuard")
        end
    end
end

-- EUI 冷却管理器（CDM 增益条 / 冷却条 / 追踪冷却条）位置漂移零侵入自愈守护：
-- 1) 未吸附到其它框体的非 CENTER 增长 CDM 条（如 buffs / cooldowns 向右增长，存档为 LEFT 锚点），
--    在空条/刚登录宽高为 0 时 EUI ApplyCenterPosition 会退化写死为 CENTER 锚点（并且覆盖 rowGrowDirection 角锚点），
--    随后 LayoutCDMBar 扩展宽高时因 _layoutBarResizing 抑制重锚且未重套 ApplyBarPositionCentered，导致整条横向偏移/回弹；
-- 2) 解锁模式保存退出时，CommitPositions 只重建 CDM_* 而跳过 TBB_* / TBBG_* 追踪条，
--    留下拖拽期的 TOPLEFT 临时锚点，直到后续重绘才突然跳回 CENTER 存档坐标。
local cdmPosGuard = {}
do
    local math_abs = math.abs
    local unlockRegistered = false
    local settleScheduled = false
    local hookedNotifyResized = false
    local hookedLayoutCDMBar = false
    local hookedCollectAndReanchor = false
    local hookedBarFrames = setmetatable({}, { __mode = "k" })
    local verifying = false
    local verifyQueued = false
    local queuedBarKeys = {}

    local function GetCDMNS()
        local EUI = _G.EllesmereUI
        return EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUICooldownManager or nil
    end

    local function IsModuleAnchoredCDM(bd)
        local a = bd and bd.anchorTo
        if type(a) ~= "string" then return false end
        return a == "mouse" or a == "partyframe" or a == "playerframe" or a:sub(1, 4) == "erb_"
    end

    local function ComputeExpectedBarAnchor(EUI, cdmNS, frame, pos, bd)
        local fw = F.PlainNumber(frame.GetWidth and frame:GetWidth(), 0) or 0
        local fh = F.PlainNumber(frame.GetHeight and frame:GetHeight(), 0) or 0
        local px = F.PlainNumber(pos.x, 0) or 0
        local py = F.PlainNumber(pos.y, 0) or 0
        local anchor = pos.point
        local storedIsCorner = (anchor:find("TOP", 1, true) or anchor:find("BOTTOM", 1, true))
            and (anchor:find("LEFT", 1, true) or anchor:find("RIGHT", 1, true))
        if ((bd and bd.rowGrowDirection) or storedIsCorner)
            and type(cdmNS.AnchorCoordToCenter) == "function"
            and type(cdmNS.ResolveGrowAnchorPoint) == "function"
            and type(cdmNS.CenterToAnchorCoord) == "function" then
            local cx, cy = cdmNS.AnchorCoordToCenter(anchor, px, py, fw, fh)
            anchor = cdmNS.ResolveGrowAnchorPoint(bd) or anchor
            px, py = cdmNS.CenterToAnchorCoord(anchor, cx, cy, fw, fh)
        elseif anchor == "CENTER" and bd then
            local grow = bd.growDirection or "CENTER"
            if grow == "RIGHT" and fw > 0 then
                anchor = "LEFT"; px = px - fw / 2
            elseif grow == "LEFT" and fw > 0 then
                anchor = "RIGHT"; px = px + fw / 2
            elseif grow == "DOWN" and fh > 0 then
                anchor = "TOP"; py = py + fh / 2
            elseif grow == "UP" and fh > 0 then
                anchor = "BOTTOM"; py = py - fh / 2
            end
        end
        if type(cdmNS.CDMAddOffset) == "function" then
            local okO, ox, oy = pcall(cdmNS.CDMAddOffset, bd)
            if okO then
                px = px + (F.PlainNumber(ox, 0) or 0)
                py = py + (F.PlainNumber(oy, 0) or 0)
            end
        end
        local PPa = EUI and EUI.PP
        if PPa and frame.GetEffectiveScale then
            local okS, es = pcall(frame.GetEffectiveScale, frame)
            es = okS and F.PlainNumber(es, nil) or nil
            if es and es > 0 then
                if anchor == "CENTER" and PPa.SnapCenterForDim then
                    px = PPa.SnapCenterForDim(px, fw, es)
                    py = PPa.SnapCenterForDim(py, fh, es)
                elseif PPa.SnapForES then
                    if PPa.SnapCenterForDim and (anchor == "LEFT" or anchor == "RIGHT") then
                        px = PPa.SnapForES(px, es)
                        py = PPa.SnapCenterForDim(py, fh, es)
                    elseif PPa.SnapCenterForDim and (anchor == "TOP" or anchor == "BOTTOM") then
                        px = PPa.SnapCenterForDim(px, fw, es)
                        py = PPa.SnapForES(py, es)
                    else
                        px = PPa.SnapForES(px, es)
                        py = PPa.SnapForES(py, es)
                    end
                end
            end
        end
        return anchor, pos.relPoint or anchor, px, py
    end

    function cdmPosGuard.VerifyBar(barKey)
        if not mod._active or verifying or type(barKey) ~= "string" or barKey == "focuskick" then return end
        local EUI = _G.EllesmereUI
        if not EUI or EUI._unlockActive then return end
        local cdmNS = GetCDMNS()
        local internals = cdmNS and cdmNS._internals
        local applyCentered = internals and internals.ApplyBarPositionCentered
        local barFrames = (cdmNS and cdmNS.cdmBarFrames) or (internals and internals.cdmBarFrames)
        local barDataByKey = (cdmNS and cdmNS.barDataByKey) or (internals and internals.barDataByKey)
        local positions = EUI._cdmBarPositions
        if not (type(applyCentered) == "function" and type(barFrames) == "table"
            and type(barDataByKey) == "table" and type(positions) == "table") then
            return
        end
        local frame = barFrames[barKey]
        local bd = barDataByKey[barKey]
        local pos = positions[barKey]
        if not (frame and bd and type(pos) == "table" and type(pos.point) == "string" and pos.point ~= "") then
            return
        end
        if frame.IsForbidden and frame:IsForbidden() then return end
        if IsModuleAnchoredCDM(bd) then return end
        if EUI.IsUnlockAnchored and EUI.IsUnlockAnchored("CDM_" .. barKey) then return end

        local expPt, expRelPt, expX, expY = ComputeExpectedBarAnchor(EUI, cdmNS, frame, pos, bd)
        local okP, curPt, curRelTo, curRelPt, curX, curY = pcall(frame.GetPoint, frame, 1)
        if not okP then return end
        curPt = F.PlainString(curPt, nil)
        curRelPt = F.PlainString(curRelPt, nil)
        curX = F.PlainNumber(curX, nil)
        curY = F.PlainNumber(curY, nil)

        local drifted = (curPt ~= expPt) or (curRelTo ~= _G.UIParent) or (curRelPt ~= expRelPt)
        if not drifted and curX and curY then
            if math_abs(curX - expX) > 0.75 or math_abs(curY - expY) > 0.75 then
                drifted = true
            end
        end
        if not drifted then return end

        if _G.InCombatLockdown and _G.InCombatLockdown() and frame.IsProtected and frame:IsProtected() then
            F.RunOutOfCombat("FUI_CDMBarPos_" .. barKey, function()
                if mod._active then cdmPosGuard.VerifyBar(barKey) end
            end)
            return
        end
        verifying = true
        pcall(applyCentered, frame, pos, barKey)
        verifying = false
    end

    function cdmPosGuard.VerifyAll()
        if not mod._active or verifying then return end
        local EUI = _G.EllesmereUI
        if not EUI or EUI._unlockActive then return end
        local cdmNS = GetCDMNS()
        local internals = cdmNS and cdmNS._internals
        local barFrames = (cdmNS and cdmNS.cdmBarFrames) or (internals and internals.cdmBarFrames)
        if type(barFrames) ~= "table" then return end
        for barKey in pairs(barFrames) do
            cdmPosGuard.VerifyBar(barKey)
        end
    end

    local function QueueVerifyAll(delay)
        if delay and delay > 0 then
            C_Timer.After(delay, function()
                if mod._active then cdmPosGuard.VerifyAll() end
            end)
            return
        end
        if verifyQueued then return end
        verifyQueued = true
        C_Timer.After(0, function()
            verifyQueued = false
            if mod._active then cdmPosGuard.VerifyAll() end
        end)
    end

    local function QueueVerifyBar(barKey)
        if not barKey or queuedBarKeys[barKey] then return end
        queuedBarKeys[barKey] = true
        C_Timer.After(0, function()
            queuedBarKeys[barKey] = nil
            if mod._active then cdmPosGuard.VerifyBar(barKey) end
        end)
    end

    local function HookCDMBarFrames()
        local cdmNS = GetCDMNS()
        local internals = cdmNS and cdmNS._internals
        local barFrames = (cdmNS and cdmNS.cdmBarFrames) or (internals and internals.cdmBarFrames)
        if type(barFrames) ~= "table" then return end
        -- 直接监听 EUI 自己的 ECME_CDMBar_* 容器（非暴雪受保护框体）的 SetPoint 与 OnSizeChanged，
        -- 即使 EUI 通过文件内局部上值调用 ApplyCenterPosition / LayoutCDMBar 也能 100% 捕获并自愈。
        for barKey, frame in pairs(barFrames) do
            if type(barKey) == "string" and barKey ~= "focuskick" and frame and not hookedBarFrames[frame]
                and not (frame.IsForbidden and frame:IsForbidden()) then
                hookedBarFrames[frame] = true
                local key = barKey
                if frame.SetPoint then
                    _G.hooksecurefunc(frame, "SetPoint", function()
                        if not mod._active or verifying then return end
                        local EUI = _G.EllesmereUI
                        if EUI and EUI._unlockActive then return end
                        QueueVerifyBar(key)
                    end)
                end
                if frame.HookScript and frame.HasScript and frame:HasScript("OnSizeChanged") then
                    frame:HookScript("OnSizeChanged", function()
                        if not mod._active or verifying then return end
                        local EUI = _G.EllesmereUI
                        if EUI and EUI._unlockActive then return end
                        QueueVerifyBar(key)
                    end)
                end
            end
        end
    end

    function cdmPosGuard.SyncTBBOnSave()
        if not mod._active then return end
        local EUI = _G.EllesmereUI
        if not EUI or EUI._unlockActive then return end
        local cdmNS = GetCDMNS()
        if not (cdmNS and type(cdmNS.BuildTrackedBuffBars) == "function") then return end
        if _G.InCombatLockdown and _G.InCombatLockdown() then
            F.RunOutOfCombat("FUI_TBBPostSave", function()
                if mod._active then cdmPosGuard.SyncTBBOnSave() end
            end)
            return
        end
        pcall(cdmNS.BuildTrackedBuffBars)
    end

    function cdmPosGuard.Install()
        local EUI = _G.EllesmereUI
        if not EUI then return end
        if not unlockRegistered and EUI.RegisterUnlockModeListener then
            unlockRegistered = true
            pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_CDMPosGuard", function(active, closeAction)
                if not mod._active or active then return end
                C_Timer.After(0, function()
                    if not mod._active then return end
                    HookCDMBarFrames()
                    cdmPosGuard.VerifyAll()
                    if closeAction == "save" then
                        cdmPosGuard.SyncTBBOnSave()
                    end
                end)
                C_Timer.After(0.12, function()
                    if mod._active then cdmPosGuard.VerifyAll() end
                end)
            end)
        end
        -- 严禁对 EUI._applySavedPositions 使用 hooksecurefunc：
        -- EUI_ActionBars_Setup.lua 会直接把 EllesmereUI._applySavedPositions 按引用传给 C_Timer.After(1.5, ...)，
        -- hooksecurefunc 替换后的包装函数会被 WoW 12.x 的 C_Timer.After 拒收并抛出 bad argument #2。
        -- 各条容器已有 SetPoint / LayoutCDMBar / CollectAndReanchor 监听，这里只需在 1.5s 延迟重排之后补扫一次即可。
        if not settleScheduled then
            settleScheduled = true
            C_Timer.After(1.8, function()
                if mod._active then
                    HookCDMBarFrames()
                    QueueVerifyAll(0)
                end
            end)
        end
        if not hookedNotifyResized and type(EUI.NotifyElementResized) == "function" then
            hookedNotifyResized = true
            _G.hooksecurefunc(EUI, "NotifyElementResized", function(key)
                if mod._active and type(key) == "string" and key:sub(1, 4) == "CDM_" then
                    QueueVerifyAll(0)
                    QueueVerifyAll(0.06)
                end
            end)
        end
        local cdmNS = GetCDMNS()
        if cdmNS then
            if not hookedLayoutCDMBar and type(cdmNS.LayoutCDMBar) == "function" then
                hookedLayoutCDMBar = true
                _G.hooksecurefunc(cdmNS, "LayoutCDMBar", function(barKey)
                    if mod._active and type(barKey) == "string" then
                        HookCDMBarFrames()
                        cdmPosGuard.VerifyBar(barKey)
                    end
                end)
            end
            if not hookedCollectAndReanchor and type(cdmNS.CollectAndReanchor) == "function" then
                hookedCollectAndReanchor = true
                _G.hooksecurefunc(cdmNS, "CollectAndReanchor", function()
                    if mod._active then
                        HookCDMBarFrames()
                        QueueVerifyAll(0)
                    end
                end)
            end
            HookCDMBarFrames()
        end
    end

    function cdmPosGuard.Remove()
        if not unlockRegistered then return end
        unlockRegistered = false
        local EUI = _G.EllesmereUI
        if EUI and EUI.UnregisterUnlockModeListener then
            pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_CDMPosGuard")
        end
    end
end

----------------------------------------------------------------------
--  6) 补齐遗漏暴雪 HUD 现代化（退出载具 / 返回墓地 / 额外技能 / 呼吸条 / 耐久小人）
--     + 飞行计时器去重（EUI 极简细线 vs Polestar 黑影卡片）
----------------------------------------------------------------------
local hudSkins = setmetatable({}, { __mode = "k" })
local hudHooked = setmetatable({}, { __mode = "k" })
local euiFlightBarRef = nil
local vehFlightSuppressed = false

local function SetTextureAlpha(tex, alpha)
    if tex and tex.SetAlpha then
        tex:SetAlpha(alpha)
    end
end

local function SetVehicleStockAlpha(btn, alpha)
    if btn.GetNormalTexture then SetTextureAlpha(btn:GetNormalTexture(), alpha) end
    if btn.GetPushedTexture then SetTextureAlpha(btn:GetPushedTexture(), alpha) end
    if btn.GetHighlightTexture then SetTextureAlpha(btn:GetHighlightTexture(), alpha) end
    if btn.GetDisabledTexture then SetTextureAlpha(btn:GetDisabledTexture(), alpha) end
    for _, reg in ipairs({ btn:GetRegions() }) do
        if reg.GetObjectType and reg:GetObjectType() == "Texture" then
            SetTextureAlpha(reg, alpha)
        end
    end
end

local flightBarLastScan = 0

local function FindAndHookEUIFlightBar(onChange)
    if euiFlightBarRef and euiFlightBarRef.exit then
        return euiFlightBarRef
    end
    if not F.IsAddOnLoaded("EllesmereUIForeverEssentials") then return nil end
    -- EUI 飞行条在本次登录第一次飞行时才懒创建：未找到前，战斗中不扫，同一帧内的连发调用只扫一次整个 UIParent。
    -- 只按「同一帧」去重（GetTime 在一帧内不变）：起飞时下一帧的补扫正是消除重复退出按钮的关键，不能被跳过
    if _G.InCombatLockdown and _G.InCombatLockdown() then return nil end
    local now = _G.GetTime and _G.GetTime() or 0
    if now == flightBarLastScan then return nil end
    flightBarLastScan = now
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return nil end
    for _, ch in ipairs({ ui:GetChildren() }) do
        if ch and not (ch.IsForbidden and ch:IsForbidden())
            and ch.exit and ch.track and ch.clip and ch.you and ch.ends then
            euiFlightBarRef = ch
            if not hudHooked[ch] and ch.HookScript then
                hudHooked[ch] = true
                ch:HookScript("OnShow", onChange)
                ch:HookScript("OnHide", onChange)
            end
            if ch.exit and not hudHooked[ch.exit] and ch.exit.HookScript then
                hudHooked[ch.exit] = true
                ch.exit:HookScript("OnShow", onChange)
                ch.exit:HookScript("OnHide", onChange)
            end
            return ch
        end
    end
    return nil
end

local function ShouldHideVehicleLeaveForFlight(onChange)
    local euiDB = _G.EllesmereUIDB
    local ft = euiDB and euiDB.flightTimer
    if ft and (ft.enabled == false or ft.earlyExit == false) then
        return false
    end
    -- EUI 实时飞行条是 UIParent 直接子框体（设置页预览条不是），且仅在飞行路线中显示；
    -- 起飞瞬间 UnitOnTaxi 尚未变 true 时飞行条已出现，直接以其 .exit 可见为准避免起飞闪现重复按钮
    local fb = FindAndHookEUIFlightBar(onChange)
    return (fb and fb:IsShown() and fb.exit and fb.exit:IsShown()) == true
end

local function RestoreVehicleLeaveVisibility(btn)
    if not (btn and vehFlightSuppressed) then return end
    vehFlightSuppressed = false
    pcall(btn.SetAlpha, btn, 1)
    if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
        pcall(btn.EnableMouse, btn, true)
    else
        F.RunOutOfCombat("FUI_VehLeaveMouse", function()
            local b = _G.MainMenuBarVehicleLeaveButton
            if b and not vehFlightSuppressed then
                pcall(b.EnableMouse, b, true)
            end
        end)
    end
end

local function SkinVehicleLeaveButton()
    local db = mod:GetDB()
    local btn = _G.MainMenuBarVehicleLeaveButton
    if not btn then return end
    if not (mod._active and db.modernBlizzHUD ~= false) then
        RestoreVehicleLeaveVisibility(btn)
        local sk = hudSkins[btn]
        if sk then sk:Hide() end
        SetVehicleStockAlpha(btn, 1)
        return
    end

    -- 按钮未显示（绝大多数时间：变形/潜行/姿态切换、被控）时无需重绘玻璃皮肤，也无需扫描飞行条；
    -- 按钮的 OnShow 钩子会在真正出现时再走完整流程
    if hudHooked[btn] and hudSkins[btn] and not vehFlightSuppressed and not btn:IsShown() then
        return
    end

    local cr, cg, cb = 0.93, 0.36, 0.43 -- 现代珊瑚红退出语义

    -- 静音原版木纹方框与红色掉头箭头材质，绝不触碰点击安全链
    local function StripStockArt()
        if not (mod._active and mod:GetDB().modernBlizzHUD ~= false) then return end
        SetVehicleStockAlpha(btn, 0)
    end
    StripStockArt()

    local function SyncIconSize(sk)
        if not (sk and sk._icon) then return end
        local w = F.PlainNumber(btn:GetWidth(), 32)
        local h = F.PlainNumber(btn:GetHeight(), 32)
        local sz = math_max(14, math_min(28, math_floor(math_min(w, h) * 0.60 + 0.5)))
        sk._icon:SetSize(sz, sz)
    end

    local sk = hudSkins[btn]
    if not sk then
        sk = CreateFrame("Frame", nil, btn)
        sk:SetAllPoints(btn)
        sk:SetFrameLevel(math_max(0, (btn:GetFrameLevel() or 1) + 1))
        sk:EnableMouse(false)

        local icon = sk:CreateTexture(nil, "OVERLAY", nil, 4)
        icon:SetPoint("CENTER", sk, "CENTER", 0, 0)
        icon:SetTexture(F.Theme.ICONS .. "VehicleLeave.tga")
        icon:SetTexCoord(0, 1, 0, 1)
        sk._icon = icon

        hudSkins[btn] = sk
    end

    F.Theme.StyleGlassSurface(sk, {
        accent = { cr, cg, cb },
        bgAlpha = 0.93,
        borderAlpha = 0.92,
        restAura = 0.14,
        hoverAura = 0.34,
        borderTintMix = 0.24,
        hovered = btn.IsMouseOver and btn:IsMouseOver() or false,
    })
    SyncIconSize(sk)
    if btn.IsMouseOver and btn:IsMouseOver() then
        sk._icon:SetVertexColor(1.0, 0.84, 0.86, 1.0)
    else
        sk._icon:SetVertexColor(0.97, 0.56, 0.61, 0.96)
    end

    -- 飞行坐骑期间若 EUI 飞行计时条已显示羽毛提前降落按钮，则无污染隐藏重复的暴雪退出载具按钮
    -- （真实载具/攻城车或飞行途中重载导致飞行条未显示时，仍自动保留本按钮）
    if ShouldHideVehicleLeaveForFlight(SkinVehicleLeaveButton) then
        vehFlightSuppressed = true
        pcall(btn.SetAlpha, btn, 0)
        sk:Hide()
        if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            pcall(btn.EnableMouse, btn, false)
        end
    else
        RestoreVehicleLeaveVisibility(btn)
        sk:Show()
    end

    if not hudHooked[btn] then
        hudHooked[btn] = true
        if btn.SetNormalTexture then
            _G.hooksecurefunc(btn, "SetNormalTexture", StripStockArt)
        end
        if btn.SetPushedTexture then
            _G.hooksecurefunc(btn, "SetPushedTexture", StripStockArt)
        end
        btn:HookScript("OnShow", function()
            SkinVehicleLeaveButton()
            C_Timer.After(0, SkinVehicleLeaveButton)
        end)
        btn:HookScript("OnSizeChanged", function()
            SyncIconSize(hudSkins[btn])
        end)
        btn:HookScript("OnEnter", function()
            if not (mod._active and mod:GetDB().modernBlizzHUD ~= false) then return end
            local s = hudSkins[btn]
            if not s then return end
            F.Theme.SetGlassState(s, true, false)
            if s._icon then s._icon:SetVertexColor(1.0, 0.84, 0.86, 1.0) end
        end)
        btn:HookScript("OnLeave", function()
            local s = hudSkins[btn]
            if not s then return end
            F.Theme.SetGlassState(s, false, false)
            if s._icon then
                s._icon:ClearAllPoints()
                s._icon:SetPoint("CENTER", s, "CENTER", 0, 0)
                s._icon:SetVertexColor(0.97, 0.56, 0.61, 0.96)
            end
        end)
        btn:HookScript("OnMouseDown", function()
            local s = hudSkins[btn]
            if s and s._icon then
                s._icon:ClearAllPoints()
                s._icon:SetPoint("CENTER", s, "CENTER", 0, -1)
                s._icon:SetVertexColor(0.92, 0.72, 0.75, 0.95)
            end
        end)
        btn:HookScript("OnMouseUp", function()
            local s = hudSkins[btn]
            if s and s._icon then
                s._icon:ClearAllPoints()
                s._icon:SetPoint("CENTER", s, "CENTER", 0, 0)
                if btn.IsMouseOver and btn:IsMouseOver() then
                    s._icon:SetVertexColor(1.0, 0.84, 0.86, 1.0)
                else
                    s._icon:SetVertexColor(0.97, 0.56, 0.61, 0.96)
                end
            end
        end)
    end
end

local function SetGhostStockAlpha(gf, alpha)
    for _, name in ipairs({ "GhostFrameLeft", "GhostFrameMiddle", "GhostFrameRight" }) do
        SetTextureAlpha(_G[name], alpha)
    end
    for _, reg in ipairs({ gf:GetRegions() }) do
        if reg.GetObjectType and reg:GetObjectType() == "Texture" then
            SetTextureAlpha(reg, alpha)
        end
    end
end

local function SkinGhostFrame()
    local db = mod:GetDB()
    local gf = _G.GhostFrame
    if not gf then return end
    local stockIcon = _G.GhostFrameContentsFrameIcon
    if not (mod._active and db.modernBlizzHUD ~= false) then
        local sk = hudSkins[gf]
        if sk then sk:Hide() end
        SetGhostStockAlpha(gf, 1)
        SetTextureAlpha(stockIcon, 1)
        return
    end

    SetGhostStockAlpha(gf, 0)
    SetTextureAlpha(stockIcon, 0)
    local text = _G.GhostFrameContentsFrameText
    if text then
        F.Theme.ApplyFont(text, 12, "", 0.92, 0.96, 0.99, 1)
    end

    local sk = hudSkins[gf]
    if not sk then
        sk = CreateFrame("Frame", nil, gf)
        sk:SetAllPoints(gf)
        sk:SetFrameLevel(math_max(0, (gf:GetFrameLevel() or 1) - 1))
        sk:EnableMouse(false)

        local vecIcon = sk:CreateTexture(nil, "OVERLAY", nil, 4)
        vecIcon:SetSize(18, 18)
        if stockIcon then
            vecIcon:SetPoint("CENTER", stockIcon, "CENTER", 0, 0)
        else
            vecIcon:SetPoint("LEFT", sk, "LEFT", 10, 0)
        end
        vecIcon:SetTexture(F.Theme.ICONS .. "GhostReturn.tga")
        vecIcon:SetTexCoord(0, 1, 0, 1)
        sk._vecIcon = vecIcon

        hudSkins[gf] = sk
    end

    F.Theme.StyleGlassSurface(sk, {
        accent = { 0.46, 0.84, 0.98 },
        bgAlpha = 0.92,
        borderAlpha = 0.90,
        restAura = 0.14,
        hoverAura = 0.32,
        borderTintMix = 0.24,
        hovered = gf.IsMouseOver and gf:IsMouseOver() or false,
    })
    if sk._vecIcon then
        sk._vecIcon:SetVertexColor(0.58, 0.88, 1.0, 0.96)
    end
    sk:Show()

    if not hudHooked[gf] then
        hudHooked[gf] = true
        gf:HookScript("OnShow", function()
            if mod._active and mod:GetDB().modernBlizzHUD ~= false then
                SetGhostStockAlpha(gf, 0)
                SetTextureAlpha(_G.GhostFrameContentsFrameIcon, 0)
            end
        end)
        gf:HookScript("OnEnter", function()
            if not (mod._active and mod:GetDB().modernBlizzHUD ~= false) then return end
            local s = hudSkins[gf]
            if not s then return end
            F.Theme.SetGlassState(s, true, false)
            if s._vecIcon then s._vecIcon:SetVertexColor(0.88, 0.97, 1.0, 1.0) end
            local t = _G.GhostFrameContentsFrameText
            if t then t:SetTextColor(1, 1, 1, 1) end
        end)
        gf:HookScript("OnLeave", function()
            local s = hudSkins[gf]
            if not s then return end
            F.Theme.SetGlassState(s, false, false)
            if s._vecIcon then s._vecIcon:SetVertexColor(0.58, 0.88, 1.0, 0.96) end
            local t = _G.GhostFrameContentsFrameText
            if t then t:SetTextColor(0.92, 0.96, 0.99, 1) end
        end)
    end
end

local function StripZoneAbilityStyle()
    local db = mod:GetDB()
    local alpha = (mod._active and db.modernBlizzHUD ~= false) and 0 or 1
    local zf = _G.ZoneAbilityFrame
    if zf and zf.Style then
        SetTextureAlpha(zf.Style, alpha)
    end
    local eab = _G.ExtraActionButton1
    if eab and eab.style then
        SetTextureAlpha(eab.style, alpha)
    end
end

local function ApplyBlizzDurabilityVisibility()
    local df = _G.DurabilityFrame
    if not df then return end
    local wantHide = mod._active and (mod:GetDB().hideBlizzDurability ~= false)
    if not hudHooked[df] then
        hudHooked[df] = true
        df:HookScript("OnShow", function(self)
            if mod._active and mod:GetDB().hideBlizzDurability ~= false then
                self:SetAlpha(0)
            end
        end)
    end
    df:SetAlpha(wantHide and 0 or 1)
end

local function ApplyEUIBuiltinHUDSkinsOnce()
    local db = mod:GetDB()
    if not (mod._active and db.modernBlizzHUD ~= false) then return end
    if db.hudSkinSeeded then return end
    local euiDB = _G.EllesmereUIDB
    if type(euiDB) ~= "table" then return end
    db.hudSkinSeeded = true
    -- 补齐 EUI 内置但默认关闭的两项现代 HUD 皮肤：额外技能钮 + 呼吸/疲劳/假死条
    if euiDB.reskinExtraActionButton == nil then
        euiDB.reskinExtraActionButton = true
    end
    if euiDB.reskinTimerBars == nil then
        euiDB.reskinTimerBars = true
    end
    if euiDB.timerBarsBorderTexture == "pixels-textured" then
        euiDB.timerBarsBorderTexture = "solid"
    end
end

local function ApplyFlightTimerDedup()
    local db = mod:GetDB()
    local mode = mod._active and (db.flightTimerMode or "keep_eui") or "both"
    local pFrame = _G.PolestarFlightTimer
    local pDB = _G.PolestarDB
    local euiDB = _G.EllesmereUIDB

    if pFrame and not hudHooked[pFrame] then
        hudHooked[pFrame] = true
        pFrame:HookScript("OnShow", function(self)
            if mod._active and (mod:GetDB().flightTimerMode or "keep_eui") == "keep_eui" then
                self:Hide()
            end
        end)
    end
    if mode == "keep_eui" then
        -- 关闭 Polestar 重复的黑影飞行卡片，保留下方极简细线 EUI 飞行条并同步职业色
        if type(pDB) == "table" and type(pDB.settings) == "table" then
            pDB.settings.maps = type(pDB.settings.maps) == "table" and pDB.settings.maps or {}
            if pDB.settings.maps.flightTimer ~= false then
                db.ftDisabledPolestar = true
            end
            pDB.settings.maps.flightTimer = false
        end
        if pFrame and pFrame:IsShown() then
            pFrame:Hide()
        end
        if type(euiDB) == "table" then
            euiDB.flightTimer = type(euiDB.flightTimer) == "table" and euiDB.flightTimer or {}
            euiDB.flightTimer.enabled = true
            db.ftDisabledEUI = nil
            -- 外观只预设一次，之后用户在 EUI 里改的材质/边框不再被每次刷新覆盖
            if not db.euiFlightStyleSeeded then
                db.euiFlightStyleSeeded = true
                euiDB.flightTimer.classColored = true
                euiDB.flightTimer.texture = "sm:MerfinMain"
                euiDB.flightTimer.borderSize = 1
                euiDB.flightTimer.borderTexture = "solid"
            end
        end
    elseif mode == "keep_polestar" then
        if type(pDB) == "table" and type(pDB.settings) == "table" then
            pDB.settings.maps = type(pDB.settings.maps) == "table" and pDB.settings.maps or {}
            pDB.settings.maps.flightTimer = true
            db.ftDisabledPolestar = nil
        end
        if type(euiDB) == "table" then
            euiDB.flightTimer = type(euiDB.flightTimer) == "table" and euiDB.flightTimer or {}
            if euiDB.flightTimer.enabled ~= false then
                db.ftDisabledEUI = true
            end
            euiDB.flightTimer.enabled = false
        end
    else
        -- 「不干预」：把此前由本模块关掉的那一方重新打开，其余保持用户自己的设置
        if db.ftDisabledPolestar and type(pDB) == "table" and type(pDB.settings) == "table"
            and type(pDB.settings.maps) == "table" then
            pDB.settings.maps.flightTimer = true
        end
        if db.ftDisabledEUI and type(euiDB) == "table" and type(euiDB.flightTimer) == "table" then
            euiDB.flightTimer.enabled = true
        end
        db.ftDisabledPolestar = nil
        db.ftDisabledEUI = nil
    end

    local ft = _G.EllesmereUI and _G.EllesmereUI._FlightTimer
    if type(ft) == "table" then
        if type(ft.Apply) == "function" then pcall(ft.Apply) end
        if type(ft.ApplyStyle) == "function" then pcall(ft.ApplyStyle) end
    end
end

-- 小地图/世界地图服务 NPC 去重：统一交由 Polestar 显示，自动关闭 Questie 重复城镇 NPC（完整保留 Questie 任务感叹号/问号）
local QUESTIE_TOWNSFOLK_KEYS = {
    "Flight Master", "Innkeeper", "Mailbox", "Meeting Stones", "Repair",
    "Class Trainer", "Banker", "Spirit Healer", "Battlemaster", "Weapon Master",
    "Auctioneer", "Stable Master", "Reagents", "Poisons", "Transmogrifier",
    "Arcane Reforger", "Barber", "Trade Goods", "Ammo", "Vendor",
}
local questieDedupSwept = false

local function ApplyQuestieTownsfolkDedup(forceFlush)
    if not (mod._active and mod:GetDB().dedupMinimapNPC ~= false) then return end
    if not (F.IsAddOnLoaded("Polestar") and F.IsAddOnLoaded("Questie")) then return end

    local pDB = _G.PolestarDB
    if type(pDB) == "table" and type(pDB.settings) == "table" then
        pDB.settings.maps = type(pDB.settings.maps) == "table" and pDB.settings.maps or {}
        if pDB.settings.maps.servicePins ~= true then
            pDB.settings.maps.servicePins = true
        end
        if pDB.settings.maps.serviceMinimap ~= true then
            pDB.settings.maps.serviceMinimap = true
        end
    end

    local q = _G.Questie
    local qProf = q and q.db and q.db.profile
    if type(qProf) ~= "table" then return end

    local changed = false
    if qProf.townsfolkKnownProfessions == true then
        qProf.townsfolkKnownProfessions = false
        changed = true
    end
    if type(qProf.townsfolkConfig) ~= "table" then
        qProf.townsfolkConfig = {}
        changed = true
    end
    local cfg = qProf.townsfolkConfig
    for k, v in pairs(cfg) do
        if v == true then
            cfg[k] = false
            changed = true
        end
    end
    for _, k in ipairs(QUESTIE_TOWNSFOLK_KEYS) do
        if cfg[k] ~= false then
            cfg[k] = false
            changed = true
        end
    end

    if (changed or forceFlush or not questieDedupSwept) and _G.QuestieLoader and _G.QuestieLoader.ImportModule then
        local okM, qMenu = pcall(_G.QuestieLoader.ImportModule, _G.QuestieLoader, "QuestieMenu")
        if okM and type(qMenu) == "table" then
            if type(qMenu.OnLogin) == "function" then
                -- Questie 登录后才异步初始化 townsfolk 表：早调用会报错，失败时不标记，留给下一次刷新重试
                local okSweep = pcall(qMenu.OnLogin, qMenu, true)
                if okSweep then questieDedupSwept = true end
            end
            if type(qMenu.RefreshKnownProfessionTrainers) == "function" then
                pcall(qMenu.RefreshKnownProfessionTrainers)
            end
        end
    end
end

----------------------------------------------------------------------
--  7) 高清矢量宠物快乐度图标（替换模糊 2004 低分辨率 UI-PetHappiness 图集，
--     完整保留 EUI 点击喂食菜单与提示）
----------------------------------------------------------------------
local PET_HAPPY_ICONS = {
    ["UI-PetHappiness"] = F.MEDIA .. "Icons\\PetHappy.tga",
    ["UI-PetNeutral"]   = F.MEDIA .. "Icons\\PetNeutral.tga",
    ["UI-PetMad"]       = F.MEDIA .. "Icons\\PetMad.tga",
}
local petHappyHooked = false
local petHappyFrameHooked = setmetatable({}, { __mode = "k" })

local function ApplyHDPetHappyTo(h)
    if not (h and h._tex) then return end
    if not (mod._active and mod:GetDB().hdPetHappy ~= false) then
        if h._atlas and h._tex.SetAtlas then
            pcall(h._tex.SetAtlas, h._tex, h._atlas)
        end
        return
    end
    local texPath = h._atlas and PET_HAPPY_ICONS[h._atlas]
    if not texPath and _G.C_PetInfo and _G.C_PetInfo.GetPetHappiness then
        local lv = F.PlainNumber(_G.C_PetInfo.GetPetHappiness(), nil)
        texPath = (lv == 3 and PET_HAPPY_ICONS["UI-PetHappiness"])
            or (lv == 2 and PET_HAPPY_ICONS["UI-PetNeutral"])
            or (lv == 1 and PET_HAPPY_ICONS["UI-PetMad"])
            or nil
    end
    if texPath then
        h._tex:SetTexCoord(0, 1, 0, 1)
        h._tex:SetTexture(texPath)
    end
end

local function RefreshHDPetHappiness()
    local EUI = _G.EllesmereUI
    local ufNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIUnitFrames
    if not ufNS then return end
    if not petHappyHooked then
        petHappyHooked = true
        if type(ufNS.UF_RefreshPetHappiness) == "function" then
            _G.hooksecurefunc(ufNS, "UF_RefreshPetHappiness", ApplyHDPetHappyTo)
        end
        if type(ufNS.UF_ApplyPetHappiness) == "function" then
            _G.hooksecurefunc(ufNS, "UF_ApplyPetHappiness", function()
                local pf = ufNS._internals and ufNS._internals.frames and ufNS._internals.frames.pet
                local h = pf and pf._petHappy
                if h then
                    if not petHappyFrameHooked[h] and h.HookScript then
                        petHappyFrameHooked[h] = true
                        h:HookScript("OnEvent", ApplyHDPetHappyTo)
                        h:HookScript("OnShow", ApplyHDPetHappyTo)
                    end
                    ApplyHDPetHappyTo(h)
                end
            end)
        end
    end
    local pf = ufNS._internals and ufNS._internals.frames and ufNS._internals.frames.pet
    local h = pf and pf._petHappy
    if h then
        if not petHappyFrameHooked[h] and h.HookScript then
            petHappyFrameHooked[h] = true
            h:HookScript("OnEvent", ApplyHDPetHappyTo)
            h:HookScript("OnShow", ApplyHDPetHappyTo)
        end
        ApplyHDPetHappyTo(h)
    end
end


MC.ApplyUnifiedResourceBars = ApplyUnifiedResourceBars
MC.RestoreResourceBarsStyle = RestoreResourceBarsStyle
MC.swingGuard = swingGuard
MC.cdmPosGuard = cdmPosGuard
MC.SkinVehicleLeaveButton = SkinVehicleLeaveButton
MC.SkinGhostFrame = SkinGhostFrame
MC.StripZoneAbilityStyle = StripZoneAbilityStyle
MC.ApplyBlizzDurabilityVisibility = ApplyBlizzDurabilityVisibility
MC.ApplyEUIBuiltinHUDSkinsOnce = ApplyEUIBuiltinHUDSkinsOnce
MC.ApplyFlightTimerDedup = ApplyFlightTimerDedup
MC.ApplyQuestieTownsfolkDedup = ApplyQuestieTownsfolkDedup
MC.RefreshHDPetHappiness = RefreshHDPetHappiness
