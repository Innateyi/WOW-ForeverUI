----------------------------------------------------------------------
--  kkowoUI — Modules/CastbarMotion.lua
--  技能施法条圆角渐变与动作级状态机动效（挂接 EUI ERB_CastBarFrame 锚点）：
--    • 圆角胶囊条 + 全职业横向渐变填充 + 前沿高亮光刃（EdgeSpark）
--    • 条尾圆角珊瑚粉延迟安全区（自动测量发送延迟 + 网络世界延迟）
--    • 引导法术极细跳数刻度线
--    • 开启中央动态技能球时默认采用极简无左图标布局（关闭球自动还原左侧圆角技能图标）
--    • 完整状态机独立残影动效：
--        - 施法成功：瞬间白光高光闪耀 + 轻上浮平滑淡出（0.22s）
--        - 打断/失败：瞬间切警示红底 +「已打断」+ 水平短促抖动（±4px, 0.18s）后淡出
--    • 仅在读条/引导进行中启用 OnUpdate，静默态 0 CPU 开销
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_min, pcall, type =
    ipairs, math.floor, math.max, math.min, pcall, type
local string_format = string.format
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("castbarMotion", {
    title = "技能施法条圆角与动效升级",
    desc = "在原 EUI 施法条锚点上叠加圆角胶囊、职业色渐变、高光光刃、延迟安全区、引导刻度、完成白闪上浮与打断红底抖动。",
    group = "motion",
    order = 20,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        hideIconWhenOrb = true,   -- 中央技能球开启时自动隐藏施法条左侧重复图标
        textOutside = true,       -- 技能名与时间清爽排布在条外下方（左下/右下）
        showLatency = true,
        showChannelTicks = true,
        showSpark = true,
        finishFlash = true,
        interruptShake = true,
        enhanceTargetCast = true, -- 同步给目标施法条加前沿光刃与打断/完成反馈
        barHeight = 14,
    },
})

-- 经典/无限服主流引导法术跳数表（按法术名或 ID 自动匹配）
local CHANNEL_TICKS_BY_ID = {
    [5143] = 3, [5144] = 4, [5145] = 5, [8416] = 5, [8417] = 5, [10211] = 5, [10212] = 5, [25345] = 5, -- 奥术飞弹
    [10] = 8, [6141] = 8, [8427] = 8, [10185] = 8, [10186] = 8, [10187] = 8, -- 暴风雪
    [12051] = 4, -- 唤醒
    [15407] = 3, [17311] = 3, [17312] = 3, [17313] = 3, [17314] = 3, [18807] = 3, -- 精神鞭笞
    [689] = 5, [699] = 5, [709] = 5, [7651] = 5, [11699] = 5, [11700] = 5, -- 吸取生命
    [1120] = 5, [8288] = 5, [8289] = 5, [11675] = 5, -- 吸取灵魂
    [5138] = 5, [6226] = 5, [11703] = 5, [11704] = 5, -- 吸取法力
    [5740] = 4, [6219] = 4, [11677] = 4, [11678] = 4, -- 火焰之雨
    [1949] = 15, [11683] = 15, [11684] = 15, -- 地狱烈焰
    [1510] = 6, [14294] = 6, [14295] = 6, -- 乱射
    [740] = 5, [8918] = 5, [9862] = 5, [9863] = 5, -- 宁静
    [16914] = 10, [17401] = 10, [17402] = 10, -- 飓风
}

local CHANNEL_TICKS_BY_NAME = {
    ["奥术飞弹"] = 5, ["Arcane Missiles"] = 5,
    ["暴风雪"] = 8, ["Blizzard"] = 8,
    ["唤醒"] = 4, ["Evocation"] = 4,
    ["精神鞭笞"] = 3, ["Mind Flay"] = 3,
    ["吸取生命"] = 5, ["Drain Life"] = 5,
    ["吸取灵魂"] = 5, ["Drain Soul"] = 5,
    ["吸取法力"] = 5, ["Drain Mana"] = 5,
    ["火焰之雨"] = 4, ["Rain of Fire"] = 4,
    ["乱射"] = 6, ["Volley"] = 6,
    ["宁静"] = 5, ["Tranquility"] = 5,
    ["飓风"] = 10, ["Hurricane"] = 10,
}

local overlay = nil
local ghostFrame = nil
local mutedERB = false
local erbHooked = false
local erbAlphaBusy = false
local targetCastSpark = nil

local castState = {
    active = false,
    isChannel = false,
    castGUID = nil,
    spellName = "",
    spellID = nil,
    icon = nil,
    startTime = 0,
    endTime = 0,
    duration = 1,
    sentTime = 0,
    latency = 0,
    uninterruptible = false,
}

local function CleanSpellName(name)
    local plain = F.PlainString(name, "") or ""
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.CleanCastName) == "function" then
        local ok, clean = pcall(EUI.CleanCastName, plain)
        if ok and type(clean) == "string" and not F.IsSecret(clean) then
            return clean
        end
    end
    return plain
end

local function MuteOriginalERBCastBar(mute)
    local erb = _G.ERB_CastBarFrame
    if not erb then return end
    local unlockOn = _G.EllesmereUI and _G.EllesmereUI._unlockActive == true
    local wantMute = mute and (not unlockOn)

    -- 永久挂钩 ERB_CastBarFrame：施法瞬间 EUI 自身的 Show/SetAlpha 可能早于我们运行，
    -- 同步把原生矩形施法条压至 alpha=0，彻底消灭“先闪一下矩形再变圆角”的问题。
    if not erbHooked then
        erbHooked = true
        local function EnforceERBMute()
            if erbAlphaBusy or not (mod._active and mutedERB) then return end
            if _G.EllesmereUI and _G.EllesmereUI._unlockActive == true then return end
            erbAlphaBusy = true
            pcall(erb.SetAlpha, erb, 0)
            if erb._barClip then pcall(erb._barClip.SetAlpha, erb._barClip, 0) end
            if erb._bg then pcall(erb._bg.SetAlpha, erb._bg, 0) end
            if erb._border then pcall(erb._border.SetAlpha, erb._border, 0) end
            if erb._iconFrame then pcall(erb._iconFrame.SetAlpha, erb._iconFrame, 0) end
            if erb._textFrame then pcall(erb._textFrame.SetAlpha, erb._textFrame, 0) end
            erbAlphaBusy = false
        end
        if erb.HookScript then erb:HookScript("OnShow", EnforceERBMute) end
        if erb.SetAlpha then
            _G.hooksecurefunc(erb, "SetAlpha", function(_, a)
                if not erbAlphaBusy and a ~= 0 then EnforceERBMute() end
            end)
        end
        for _, part in ipairs({ erb._barClip, erb._bg, erb._border, erb._iconFrame, erb._textFrame }) do
            if part and part.SetAlpha then
                _G.hooksecurefunc(part, "SetAlpha", function(_, a)
                    if not erbAlphaBusy and a ~= 0 then EnforceERBMute() end
                end)
            end
        end
    end

    erbAlphaBusy = true
    if wantMute then
        mutedERB = true
        pcall(erb.SetAlpha, erb, 0)
        if erb._barClip then pcall(erb._barClip.SetAlpha, erb._barClip, 0) end
        if erb._bg then pcall(erb._bg.SetAlpha, erb._bg, 0) end
        if erb._border then pcall(erb._border.SetAlpha, erb._border, 0) end
        if erb._iconFrame then pcall(erb._iconFrame.SetAlpha, erb._iconFrame, 0) end
        if erb._textFrame then pcall(erb._textFrame.SetAlpha, erb._textFrame, 0) end
    elseif mutedERB then
        mutedERB = false
        pcall(erb.SetAlpha, erb, 1)
        if erb._barClip then pcall(erb._barClip.SetAlpha, erb._barClip, 1) end
        if erb._bg then pcall(erb._bg.SetAlpha, erb._bg, 1) end
        if erb._border then pcall(erb._border.SetAlpha, erb._border, 1) end
        if erb._iconFrame then pcall(erb._iconFrame.SetAlpha, erb._iconFrame, 1) end
        if erb._textFrame then pcall(erb._textFrame.SetAlpha, erb._textFrame, 1) end
    end
    erbAlphaBusy = false
end

local function SyncOverlayAnchor()
    if not overlay then return end
    local db = mod:GetDB()
    local h = math_max(8, math_min(26, F.PlainNumber(db.barHeight, 14) or 14))
    local erb = _G.ERB_CastBarFrame
    local core = F.Modules.Get("coreHUD")
    local coreAnchor = core and core.GetAnchorFrame and core:GetAnchorFrame()

    overlay:ClearAllPoints()
    if erb then
        local w = F.PlainNumber(erb:GetWidth(), 249) or 249
        if w < 120 then w = 249 end
        overlay:SetSize(w, h)
        overlay:SetPoint("CENTER", erb, "CENTER", 0, 0)
    elseif coreAnchor then
        overlay:SetSize(256, h)
        overlay:SetPoint("TOP", coreAnchor, "BOTTOM", 0, -34)
    else
        overlay:SetSize(250, h)
        overlay:SetPoint("CENTER", _G.UIParent, "CENTER", 0, -295)
    end
end

local function ShouldShowLeftIcon()
    local db = mod:GetDB()
    if db.hideIconWhenOrb == false then return true end
    local core = F.Modules.Get("coreHUD")
    if core and core.IsOrbActive and core:IsOrbActive() then
        return false
    end
    return true
end

local function RefreshOverlayChrome()
    if not overlay then return end
    SyncOverlayAnchor()
    local db = mod:GetDB()
    local h = F.PlainNumber(overlay:GetHeight(), 14) or 14
    local rad = math_min(ST.GetCornerRadius(6), math_max(2, math_floor(h * 0.48)))
    local showIcon = ShouldShowLeftIcon()
    local iconW = showIcon and (h + 4) or 0

    overlay._iconBox:SetShown(showIcon)
    if showIcon then
        overlay._iconBox:SetSize(h + 2, h + 2)
        ST.ClearRoundedMask(overlay._iconBox)
        if rad > 0 then
            ST.MaskTexture(overlay._iconBox, overlay._iconTex, math_min(rad, 5))
            ST.ApplyRoundedBorder(overlay._iconBox, math_min(rad, 5), 0.02, 0.02, 0.03, 0.96, 4)
        end
    end

    overlay._barHost:ClearAllPoints()
    overlay._barHost:SetPoint("TOPLEFT", overlay, "TOPLEFT", showIcon and (iconW + 2) or 0, 0)
    overlay._barHost:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 0, 0)

    ST.ClearRoundedMask(overlay._barHost)
    if rad > 0 then
        ST.MaskTexture(overlay._barHost, overlay._bg, rad)
        local fillTex = overlay._bar:GetStatusBarTexture()
        if fillTex then ST.MaskTexture(overlay._barHost, fillTex, rad) end
        ST.MaskTexture(overlay._barHost, overlay._latency, rad)
        if overlay._spark and overlay._spark._spark then
            ST.MaskTexture(overlay._barHost, overlay._spark._spark, rad)
        end
        ST.ApplyRoundedBorder(overlay._barHost, rad, 0.02, 0.02, 0.03, 0.96, 6)
    end

    overlay._nameFS:ClearAllPoints()
    overlay._timeFS:ClearAllPoints()
    if db.textOutside ~= false then
        overlay._nameFS:SetPoint("TOPLEFT", overlay._barHost, "BOTTOMLEFT", 2, -4)
        overlay._timeFS:SetPoint("TOPRIGHT", overlay._barHost, "BOTTOMRIGHT", -2, -4)
    else
        overlay._nameFS:SetPoint("LEFT", overlay._barHost, "LEFT", 6, 0)
        overlay._timeFS:SetPoint("RIGHT", overlay._barHost, "RIGHT", -6, 0)
    end
    if overlay._spark then
        overlay._spark:SyncAnchor()
        overlay._spark:SetShown(db.showSpark ~= false)
    end
end

local function BuildCastbarOverlay()
    if overlay then return end

    local f = CreateFrame("Frame", "kkowoUI_CastbarOverlay", _G.UIParent)
    f:SetSize(249, 14)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(20)
    f:EnableMouse(false)
    f:Hide()

    local iconBox = CreateFrame("Frame", nil, f)
    iconBox:SetPoint("LEFT", f, "LEFT", 0, 0)
    iconBox:SetSize(16, 16)
    local iconTex = iconBox:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints()
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f._iconBox = iconBox
    f._iconTex = iconTex

    local barHost = CreateFrame("Frame", nil, f)
    barHost:SetAllPoints(f)
    barHost:EnableMouse(false)
    f._barHost = barHost

    local bg = barHost:CreateTexture(nil, "BACKGROUND", nil, -6)
    bg:SetAllPoints()
    bg:SetTexture(ST.TEX.FLAT)
    local r1, g1, b1 = ST.GetClassGradient()
    bg:SetVertexColor(r1 * 0.14 + 0.06, g1 * 0.14 + 0.06, b1 * 0.14 + 0.08, 0.44)
    f._bg = bg

    local sb = CreateFrame("StatusBar", nil, barHost)
    sb:SetAllPoints()
    sb:SetStatusBarTexture(ST.TEX.FLAT)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    sb:EnableMouse(false)
    f._bar = sb

    -- 延迟安全区（圆角裁切在条尾）
    local lat = sb:CreateTexture(nil, "OVERLAY", nil, 1)
    lat:SetTexture(ST.TEX.FLAT)
    local lc = ST.COLORS.latency
    lat:SetVertexColor(lc[1], lc[2], lc[3], lc[4])
    lat:Hide()
    f._latency = lat

    -- 引导跳数刻度池
    f._ticks = {}
    for i = 1, 15 do
        local tk = sb:CreateTexture(nil, "OVERLAY", nil, 3)
        tk:SetWidth(1)
        tk:SetPoint("TOP", sb, "TOP", 0, -1)
        tk:SetPoint("BOTTOM", sb, "BOTTOM", 0, 1)
        tk:SetColorTexture(1, 1, 1, 0.45)
        tk:Hide()
        f._ticks[i] = tk
    end

    f._spark = M.AttachEdgeSpark(sb, { width = 18, extraHeight = 6, a = 0.96, levelOffset = 4 })

    local nameFS = f:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(nameFS, 12, "OUTLINE", 0.96, 0.97, 0.99, 1)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    f._nameFS = nameFS

    local timeFS = f:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(timeFS, 12, "OUTLINE", 0.94, 0.96, 0.99, 1)
    timeFS:SetJustifyH("RIGHT")
    timeFS:SetWordWrap(false)
    f._timeFS = timeFS

    -- 独立状态机残影帧（施法完成白闪上浮 / 被打断红底抖动，绝不被主条隐藏打断）
    local g = CreateFrame("Frame", "kkowoUI_CastbarGhost", _G.UIParent)
    g:SetFrameStrata("MEDIUM")
    g:SetFrameLevel(24)
    g:EnableMouse(false)
    g:Hide()

    local gFill = g:CreateTexture(nil, "ARTWORK")
    gFill:SetAllPoints()
    gFill:SetTexture(ST.TEX.FLAT)
    g._fill = gFill

    local gLabel = g:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(gLabel, 12, "OUTLINE", 1, 1, 1, 1)
    gLabel:SetPoint("TOPLEFT", g, "BOTTOMLEFT", 2, -4)
    gLabel:SetJustifyH("LEFT")
    g._label = gLabel

    ghostFrame = g
    overlay = f
    RefreshOverlayChrome()
end

local function LayoutChannelTicks(spellID, spellName)
    if not overlay then return end
    for i = 1, 15 do overlay._ticks[i]:Hide() end
    if mod:GetDB().showChannelTicks == false then return end
    local count = (spellID and CHANNEL_TICKS_BY_ID[spellID]) or (spellName and CHANNEL_TICKS_BY_NAME[spellName]) or 0
    if count <= 1 then return end
    local w = F.PlainNumber(overlay._barHost:GetWidth(), 220) or 220
    local nTicks = math_min(15, count - 1)
    for i = 1, nTicks do
        local tk = overlay._ticks[i]
        tk:ClearAllPoints()
        tk:SetPoint("TOP", overlay._barHost, "TOPLEFT", w * (i / count), -1)
        tk:SetPoint("BOTTOM", overlay._barHost, "BOTTOMLEFT", w * (i / count), 1)
        tk:Show()
    end
end

local function LayoutLatencyZone()
    if not overlay then return end
    if mod:GetDB().showLatency == false or castState.duration <= 0.05 then
        overlay._latency:Hide()
        return
    end
    local lat = castState.latency or 0
    if lat <= 0.01 and _G.GetNetStats then
        local _, _, homeMS, worldMS = _G.GetNetStats()
        lat = (F.PlainNumber(worldMS, 0) or F.PlainNumber(homeMS, 0) or 0) / 1000
    end
    local frac = math_max(0, math_min(0.42, lat / castState.duration))
    if frac < 0.015 then
        overlay._latency:Hide()
        return
    end
    local w = F.PlainNumber(overlay._barHost:GetWidth(), 220) or 220
    overlay._latency:ClearAllPoints()
    if castState.isChannel then
        overlay._latency:SetPoint("TOPLEFT", overlay._barHost, "TOPLEFT", 0, 0)
        overlay._latency:SetPoint("BOTTOMLEFT", overlay._barHost, "BOTTOMLEFT", 0, 0)
    else
        overlay._latency:SetPoint("TOPRIGHT", overlay._barHost, "TOPRIGHT", 0, 0)
        overlay._latency:SetPoint("BOTTOMRIGHT", overlay._barHost, "BOTTOMRIGHT", 0, 0)
    end
    overlay._latency:SetWidth(math_max(4, w * frac))
    overlay._latency:Show()
end

local function PaintCastFillColor()
    if not overlay then return end
    if castState.uninterruptible then
        ST.ApplyBarGradient(overlay._bar, 0.36, 0.38, 0.44, 0.62, 0.65, 0.72, 0.98, false)
    elseif castState.isChannel then
        local cc = ST.COLORS.channel
        ST.ApplyBarGradient(overlay._bar, cc[1] * 0.75, cc[2] * 0.85, cc[3] * 0.90, 0.78, 0.98, 0.94, 0.98, false)
    else
        local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
        ST.ApplyBarGradient(overlay._bar, r1, g1, b1, r2, g2, b2, 0.98, false)
    end
end

local function SpawnGhostFeedback(kind)
    if not (overlay and ghostFrame) then return end
    local db = mod:GetDB()
    if kind == "success" and db.finishFlash == false then return end
    if kind == "interrupt" and db.interruptShake == false then return end

    local bh = overlay._barHost
    local w = F.PlainNumber(bh:GetWidth(), 220) or 220
    local h = F.PlainNumber(bh:GetHeight(), 14) or 14
    local rad = math_min(ST.GetCornerRadius(6), math_max(2, math_floor(h * 0.48)))

    ghostFrame:ClearAllPoints()
    ghostFrame:SetSize(w, h)
    ghostFrame:SetPoint("CENTER", bh, "CENTER", 0, 0)
    ST.ClearRoundedMask(ghostFrame)
    if rad > 0 then
        ST.MaskTexture(ghostFrame, ghostFrame._fill, rad)
        ST.ApplyRoundedBorder(ghostFrame, rad, 0.02, 0.02, 0.03, 0.95, 4)
    end

    if kind == "success" then
        local _, _, _, r2, g2, b2 = ST.GetClassGradient()
        ST.ApplyGradient(ghostFrame._fill, "HORIZONTAL", r2, g2, b2, 0.95, 1, 1, 1, 1)
        ghostFrame._label:SetText(castState.spellName or "")
        ghostFrame._label:SetTextColor(1, 1, 1, 0.95)
        M.PlayFlashFade(ghostFrame, 0.22, 5)
    else
        local ic = ST.COLORS.interrupt
        ghostFrame._fill:SetVertexColor(ic[1], ic[2], ic[3], ic[4])
        ghostFrame._label:SetText("已打断")
        ghostFrame._label:SetTextColor(1, 0.45, 0.48, 1)
        M.PlayInterruptShake(ghostFrame, 4, 0.18)
    end
end

local function OnCastUpdate(self)
    if not (mod._active and castState.active) then
        self:SetScript("OnUpdate", nil)
        self:Hide()
        return
    end
    local now = GetTime()
    local dur = castState.duration
    local elapsed = now - castState.startTime
    local rem = castState.endTime - now
    if rem <= 0 then
        if castState.isChannel then
            overlay._bar:SetValue(0)
        else
            overlay._bar:SetValue(1)
        end
        return
    end
    local prog
    if castState.isChannel then
        prog = math_max(0, math_min(1, rem / dur))
        overlay._timeFS:SetText(string_format("%.1f / %.1f", rem, dur))
    else
        prog = math_max(0, math_min(1, elapsed / dur))
        overlay._timeFS:SetText(string_format("%.1f / %.1f", elapsed, dur))
    end
    overlay._bar:SetValue(prog)
end

local function StartCast(isChannel)
    BuildCastbarOverlay()
    local fn = isChannel and _G.UnitChannelInfo or _G.UnitCastingInfo
    if not fn then return end
    local name, _, tex, startMS, endMS, _, castID, notInt, spellID = fn("player")
    if not isChannel then
        -- UnitCastingInfo 返回值: name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellId
    else
        -- UnitChannelInfo 返回值: name, text, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellId
        spellID = notInt
        notInt = castID
        castID = nil
    end
    if not name then return end

    local sMS = F.PlainNumber(startMS, nil)
    local eMS = F.PlainNumber(endMS, nil)
    if not (sMS and eMS and eMS > sMS) then return end

    local now = GetTime()
    castState.active = true
    castState.isChannel = isChannel == true
    castState.castGUID = (not F.IsSecret(castID)) and castID or nil
    castState.spellName = CleanSpellName(name)
    castState.spellID = F.PlainNumber(spellID, nil)
    castState.icon = (not F.IsSecret(tex)) and tex or nil
    castState.startTime = sMS / 1000
    castState.endTime = eMS / 1000
    castState.duration = math_max(0.05, castState.endTime - castState.startTime)
    castState.uninterruptible = (not F.IsSecret(notInt)) and (notInt == true) or false
    if castState.sentTime > 0 and (now - castState.sentTime) < 1.2 then
        castState.latency = now - castState.sentTime
    else
        castState.latency = 0
    end
    castState.sentTime = 0

    MuteOriginalERBCastBar(true)
    RefreshOverlayChrome()
    if ghostFrame then ghostFrame:Hide() end
    if castState.icon then overlay._iconTex:SetTexture(castState.icon) end
    overlay._nameFS:SetText(castState.spellName)
    PaintCastFillColor()
    LayoutLatencyZone()
    if isChannel then
        LayoutChannelTicks(castState.spellID, castState.spellName)
    else
        for i = 1, 15 do overlay._ticks[i]:Hide() end
    end

    overlay:Show()
    overlay:SetScript("OnUpdate", OnCastUpdate)
    OnCastUpdate(overlay)
end

local function StopCast(feedbackKind, eventCastGUID)
    if not castState.active then return end
    if not castState.isChannel and eventCastGUID and castState.castGUID
        and not F.IsSecret(eventCastGUID) and eventCastGUID ~= castState.castGUID then
        return
    end
    castState.active = false
    if overlay then
        overlay:SetScript("OnUpdate", nil)
        overlay:Hide()
    end
    if feedbackKind then
        SpawnGhostFeedback(feedbackKind)
    end
end

local function AttachTargetCastSpark()
    if not mod:GetDB().enhanceTargetCast then
        if targetCastSpark then targetCastSpark:SetShown(false) end
        return
    end
    local tf = _G.EllesmereUIUnitFrames_Target
    local cb = tf and tf.Castbar
    if cb and cb.GetStatusBarTexture then
        if not targetCastSpark then
            targetCastSpark = M.AttachEdgeSpark(cb, { width = 14, extraHeight = 4, a = 0.85 })
        end
        targetCastSpark:SyncAnchor()
        targetCastSpark:SetShown(true)
    end
end

function mod:OnEnable()
    BuildCastbarOverlay()
    MuteOriginalERBCastBar(true)
    AttachTargetCastSpark()

    local EUI = _G.EllesmereUI
    if EUI and EUI.RegisterUnlockModeListener then
        pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_CastbarMotion", function(active)
            if not mod._active then return end
            if active then
                MuteOriginalERBCastBar(false)
                if overlay then overlay:Hide() end
            else
                SyncOverlayAnchor()
                MuteOriginalERBCastBar(true)
                if castState.active and overlay then
                    overlay:Show()
                end
            end
        end)
    end

    self:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player", function()
        castState.sentTime = GetTime()
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player", function() StartCast(false) end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED", "player", function() if castState.active and not castState.isChannel then StartCast(false) end end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", function() StartCast(true) end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player", function() if castState.active and castState.isChannel then StartCast(true) end end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, castGUID)
        if castState.active and not castState.isChannel then
            StopCast("success", castGUID)
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", function(_, _, _, castGUID)
        StopCast("interrupt", castGUID)
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", function(_, _, _, castGUID)
        if castState.active and not castState.isChannel then
            if _G.UnitCastingInfo and _G.UnitCastingInfo("player") then return end
            StopCast("interrupt", castGUID)
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player", function(_, _, _, castGUID)
        if castState.active and not castState.isChannel then
            StopCast(nil, castGUID)
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", function()
        if castState.active and castState.isChannel then
            StopCast("success", nil)
        end
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        MuteOriginalERBCastBar(true)
        AttachTargetCastSpark()
        RefreshOverlayChrome()
        C_Timer.After(0.5, function() if mod._active then MuteOriginalERBCastBar(true) end end)
    end)
    C_Timer.After(0.6, function() if mod._active then MuteOriginalERBCastBar(true) end end)
end

function mod:OnDisable()
    local EUI = _G.EllesmereUI
    if EUI and EUI.UnregisterUnlockModeListener then
        pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_CastbarMotion")
    end
    castState.active = false
    if overlay then
        overlay:SetScript("OnUpdate", nil)
        overlay:Hide()
    end
    if ghostFrame then ghostFrame:Hide() end
    if targetCastSpark then targetCastSpark:SetShown(false) end
    MuteOriginalERBCastBar(false)
end

function mod:OnRefresh()
    RefreshOverlayChrome()
    AttachTargetCastSpark()
end

function mod:OnThemeChanged()
    RefreshOverlayChrome()
    if castState.active then PaintCastFillColor() end
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "中央技能球开启时隐藏左侧重复图标",
        tooltip = "中央动态技能球已实时显示当前施法图标，开启本项可让施法条呈现纯粹圆角胶囊态（关闭技能球自动恢复左图标）。",
        getValue = function() return db.hideIconWhenOrb ~= false end,
        setValue = function(v) db.hideIconWhenOrb = v == true; RefreshOverlayChrome() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "技能名与计时排布在条外下方",
        tooltip = "左下显示技能名、右下显示「当前 / 总时长」，条体本身清爽无遮挡。",
        getValue = function() return db.textOutside ~= false end,
        setValue = function(v) db.textOutside = v == true; RefreshOverlayChrome() end,
    }, {
        type = "slider",
        text = "施法条高度（px）",
        min = 10, max = 24, step = 1,
        getValue = function() return F.PlainNumber(db.barHeight, 14) or 14 end,
        setValue = function(v) db.barHeight = math_floor(v + 0.5); RefreshOverlayChrome() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "延迟安全区与引导跳数刻度",
        getValue = function() return db.showLatency ~= false end,
        setValue = function(v) db.showLatency = v == true; db.showChannelTicks = v == true end,
    }, {
        type = "toggle",
        text = "前沿高光光刃 + 目标施法条光刃",
        getValue = function() return db.showSpark ~= false end,
        setValue = function(v) db.showSpark = v == true; db.enhanceTargetCast = v == true; RefreshOverlayChrome(); AttachTargetCastSpark() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "施法成功白闪上浮淡出",
        getValue = function() return db.finishFlash ~= false end,
        setValue = function(v) db.finishFlash = v == true end,
    }, {
        type = "toggle",
        text = "被打断红底短促水平抖动",
        getValue = function() return db.interruptShake ~= false end,
        setValue = function(v) db.interruptShake = v == true end,
    })
    y = y - h

    return y
end
