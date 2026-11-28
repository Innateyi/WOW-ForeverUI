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
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_floor, math_max, math_min, pcall, type =
    ipairs, math.floor, math.max, math.min, pcall, type
local string_format = string.format
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("castbarMotion", {
    title = "施法条动效",
    desc = "为施法条叠加圆角渐变、延迟安全区、引导刻度与完成反馈。",
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
    isEmpower = false,
    nativeTimer = false,
    secretTime = false,
    durationObj = nil,
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
    lastTimeTenths = -1,
}

local CAST_TICK_KEY = "kkowoUI_CastbarTime"

local function CanUseNativeCastTimer(bar)
    if not ST.IsFXEnabled("fx_castTimer") then return false end
    if not (bar and type(bar.SetTimerDuration) == "function") then return false end
    local dirEnum = _G.Enum and _G.Enum.StatusBarTimerDirection
    if not (dirEnum and dirEnum.ElapsedTime ~= nil and dirEnum.RemainingTime ~= nil) then
        return false
    end
    return type(_G.UnitCastingDuration) == "function" or type(_G.UnitChannelDuration) == "function"
end

local function FetchCastDurationObj(isChannel, isEmpower)
    if isEmpower and type(_G.UnitEmpoweredChannelDuration) == "function" then
        local okE, durE = pcall(_G.UnitEmpoweredChannelDuration, "player", true)
        if okE and type(durE) ~= "nil" then return durE end
    end
    if isChannel then
        if type(_G.UnitChannelDuration) == "function" then
            local okC, durC = pcall(_G.UnitChannelDuration, "player")
            if okC and type(durC) ~= "nil" then return durC end
        end
    else
        if type(_G.UnitCastingDuration) == "function" then
            local okS, durS = pcall(_G.UnitCastingDuration, "player")
            if okS and type(durS) ~= "nil" then return durS end
        end
    end
    -- 若施法时间明文可用且客户端有 C_DurationUtil，兜底构造 duration 对象
    if not castState.secretTime and castState.duration > 0.05
        and _G.C_DurationUtil and type(_G.C_DurationUtil.CreateDuration) == "function" then
        local okD, d = pcall(_G.C_DurationUtil.CreateDuration)
        if okD and d and d.SetTimeFromStart then
            pcall(d.SetTimeFromStart, d, castState.startTime, castState.duration)
            return d
        end
    end
    return nil
end

local function UpdateNativeCastText()
    if not (mod._active and castState.active and castState.nativeTimer and overlay) then
        return false
    end
    local d = castState.durationObj
    if not d then return false end
    if not castState.secretTime then
        local now = GetTime()
        local dur = castState.duration
        local dispVal = castState.isChannel and math_max(0, castState.endTime - now) or math_max(0, math_min(dur, now - castState.startTime))
        local tenths = math_floor(dispVal * 10 + 0.5)
        if tenths ~= castState.lastTimeTenths then
            castState.lastTimeTenths = tenths
            overlay._timeFS:SetText(string_format("%.1f / %.1f", tenths * 0.1, dur))
        end
        return true
    end
    -- 机密时长：优先直接读 durationObj 剩余时间，明文或机密均可交由 C 端 SetFormattedText 格式化
    if d.GetRemainingDuration then
        local okR, rawRem = pcall(d.GetRemainingDuration, d)
        if okR and type(rawRem) ~= "nil" then
            if F.IsSecret(rawRem) then
                if overlay._timeFS.SetFormattedText then
                    local okF = pcall(overlay._timeFS.SetFormattedText, overlay._timeFS, "%.1f", rawRem)
                    if not okF then overlay._timeFS:SetText("") end
                else
                    overlay._timeFS:SetText("")
                end
            else
                local remNum = F.PlainNumber(rawRem, 0) or 0
                local tenths = math_floor(math_max(0, remNum) * 10 + 0.5)
                if tenths ~= castState.lastTimeTenths then
                    castState.lastTimeTenths = tenths
                    overlay._timeFS:SetText(string_format("%.1f", tenths * 0.1))
                end
            end
        end
    end
    return true
end

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
                if not erbAlphaBusy and F.PlainNumber(a, 1) ~= 0 then EnforceERBMute() end
            end)
        end
        for _, part in ipairs({ erb._barClip, erb._bg, erb._border, erb._iconFrame, erb._textFrame }) do
            if part and part.SetAlpha then
                _G.hooksecurefunc(part, "SetAlpha", function(_, a)
                    if not erbAlphaBusy and F.PlainNumber(a, 1) ~= 0 then EnforceERBMute() end
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

----------------------------------------------------------------------
--  宿主选择：圆角施法条只替换玩家「实际在用」的那条施法条，绝不在被关掉的施法条位置上另起一条
--    1) EUI 资源条施法条（ERB）开启时 -> 覆盖在 ERB 上并静音 ERB
--    2) EUI 单位框架的玩家施法条开启时 -> 覆盖在它上面并静音它
--    3) 都没开（使用暴雪原生施法条）-> 停在暴雪原生施法条的位置，并通过 EUI 的协作接口收起暴雪原生条
----------------------------------------------------------------------
local castHostKind = nil
local mutedUFBar = nil
local ufAlphaBusy = false
local ufHooked = setmetatable({}, { __mode = "k" })
local blizzSuppressed = false

local function GetERBCastCfg()
    local EUI = _G.EllesmereUI
    local rb = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIResourceBars
    local erbObj = rb and rb.ERB
    local prof = erbObj and erbObj.db and erbObj.db.profile
    return prof and prof.castBar or nil
end

local function GetUFPlayerCastbarHost()
    local EUI = _G.EllesmereUI
    local uf = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIUnitFrames
    local s = uf and uf.db and uf.db.profile and uf.db.profile.player
    if not (s and s.showPlayerCastbar) then return nil end
    local pf = (uf.frames and uf.frames.player) or _G.EllesmereUIUnitFrames_Player
    local cb = pf and pf.Castbar
    if not cb then return nil end
    if pf.IsElementEnabled then
        local ok, en = pcall(pf.IsElementEnabled, pf, "Castbar")
        if ok and not en then return nil end
    end
    return (cb.GetParent and cb:GetParent()) or cb
end

local function ResolveCastHost()
    local erb = _G.ERB_CastBarFrame
    local cfg = GetERBCastCfg()
    if erb and ((type(cfg) == "table" and cfg.enabled == true) or (cfg == nil and erb:IsShown())) then
        return "erb", erb
    end
    local ufHost = GetUFPlayerCastbarHost()
    if ufHost then return "uf", ufHost end
    return "blizz", _G.PlayerCastingBarFrame
end

local function SetBlizzCastSuppressed(on)
    on = on == true
    if on == blizzSuppressed then return end
    blizzSuppressed = on
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.SetPlayerCastBarSuppressed) == "function" then
        pcall(EUI.SetPlayerCastBarSuppressed, "kkowoUI_Castbar", on)
    end
end

local function MuteUFCastbar(host, on)
    if mutedUFBar and (mutedUFBar ~= host or not on) then
        ufAlphaBusy = true
        pcall(mutedUFBar.SetAlpha, mutedUFBar, 1)
        ufAlphaBusy = false
        mutedUFBar = nil
    end
    if not (on and host and host.SetAlpha) then return end
    if not ufHooked[host] then
        ufHooked[host] = true
        local function Enforce(self)
            if ufAlphaBusy or mutedUFBar ~= self or not mod._active then return end
            if _G.EllesmereUI and _G.EllesmereUI._unlockActive == true then return end
            ufAlphaBusy = true
            pcall(self.SetAlpha, self, 0)
            ufAlphaBusy = false
        end
        _G.hooksecurefunc(host, "SetAlpha", function(self, a) if F.PlainNumber(a, 1) ~= 0 then Enforce(self) end end)
        if host.HookScript then host:HookScript("OnShow", Enforce) end
    end
    mutedUFBar = host
    ufAlphaBusy = true
    pcall(host.SetAlpha, host, 0)
    ufAlphaBusy = false
end

local function ApplyHostMute(on)
    local unlockOn = _G.EllesmereUI and _G.EllesmereUI._unlockActive == true
    local want = on and not unlockOn
    local kind, host = ResolveCastHost()
    castHostKind = kind
    MuteOriginalERBCastBar(want and kind == "erb")
    MuteUFCastbar(host, want and kind == "uf")
    SetBlizzCastSuppressed(want and kind == "blizz")
end

local function SyncOverlayAnchor()
    if not overlay then return end
    local db = mod:GetDB()
    local h = math_max(8, math_min(26, F.PlainNumber(db.barHeight, 14) or 14))
    local core = F.Modules.Get("coreHUD")
    local coreAnchor = core and core.GetAnchorFrame and core:GetAnchorFrame()
    local kind, host = ResolveCastHost()
    castHostKind = kind

    overlay:ClearAllPoints()
    if (kind == "erb" or kind == "uf") and host then
        local w = F.PlainNumber(host:GetWidth(), 249) or 249
        if w < 120 then w = 249 end
        overlay:SetSize(w, h)
        overlay:SetPoint("CENTER", host, "CENTER", 0, 0)
        return
    end
    -- 暴雪原生施法条当宿主：圆角施法条自己占位，位置由 EUI 解锁模式拖动保存（默认底部居中）
    if kind == "blizz" and overlay._applyMoverPos then
        overlay:SetSize(249, h)
        overlay._applyMoverPos()
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
        if rad > 0 then
            local iRad = math_min(rad, 5)
            ST.SetHostIconMode(overlay._iconBox, true)
            ST.ApplyRoundedBorder(overlay._iconBox, iRad, 0.02, 0.02, 0.03, 0.96, 4)
            ST.MaskIcon(overlay._iconBox, overlay._iconTex, iRad, { keepIfLoaded = true })
            overlay._lastIconRad = iRad
        elseif overlay._lastIconRad and overlay._lastIconRad > 0 then
            ST.ClearRoundedMask(overlay._iconBox)
            overlay._lastIconRad = 0
        end
    end

    overlay._barHost:ClearAllPoints()
    overlay._barHost:SetPoint("TOPLEFT", overlay, "TOPLEFT", showIcon and (iconW + 2) or 0, 0)
    overlay._barHost:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", 0, 0)

    local wantFill = ST.GetBarFillTexture and ST.GetBarFillTexture(false) or ST.TEX.FLAT
    if overlay._bar and overlay._bar._kkFillPath ~= wantFill then
        overlay._bar:SetStatusBarTexture(wantFill)
        overlay._bar._kkFillPath = wantFill
        local ft = overlay._bar:GetStatusBarTexture()
        if ft and M.DisablePixelSnap then M.DisablePixelSnap(ft) end
    end

    if rad > 0 then
        ST.MaskTexture(overlay._barHost, overlay._bg, rad)
        local fillTex = overlay._bar:GetStatusBarTexture()
        if fillTex then ST.MaskTexture(overlay._barHost, fillTex, rad) end
        ST.MaskTexture(overlay._barHost, overlay._latency, rad)
        if overlay._spark then
            if overlay._spark.SyncMask then
                overlay._spark:SyncMask(overlay._barHost, rad)
            elseif overlay._spark._spark then
                ST.MaskTexture(overlay._barHost, overlay._spark._spark, rad)
            end
        end
        if overlay._lockTex then
            ST.MaskTexture(overlay._barHost, overlay._lockTex, rad)
        end
        ST.ApplyRoundedBorder(overlay._barHost, rad, 0.02, 0.02, 0.03, 0.96, 6)
        overlay._lastBarRad = rad
    elseif overlay._lastBarRad and overlay._lastBarRad > 0 then
        if overlay._spark and overlay._spark.SyncMask then
            overlay._spark:SyncMask(overlay._barHost, 0)
        end
        ST.ClearRoundedMask(overlay._barHost)
        overlay._lastBarRad = 0
    end
    if overlay._flow and overlay._flow.Refresh then
        overlay._flow:Refresh(rad)
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
    if sb.SetSnapToPixelGrid then pcall(sb.SetSnapToPixelGrid, sb, false) end
    if sb.SetTexelSnappingBias then pcall(sb.SetTexelSnappingBias, sb, 0) end
    local sbFill = sb:GetStatusBarTexture()
    if sbFill then
        if sbFill.SetSnapToPixelGrid then pcall(sbFill.SetSnapToPixelGrid, sbFill, false) end
        if sbFill.SetTexelSnappingBias then pcall(sbFill.SetTexelSnappingBias, sbFill, 0) end
    end
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

    if sb.SetSnapToPixelGrid then pcall(sb.SetSnapToPixelGrid, sb, false) end
    if sb.SetTexelSnappingBias then pcall(sb.SetTexelSnappingBias, sb, 0) end
    local sbFillTex = sb.GetStatusBarTexture and sb:GetStatusBarTexture()
    if sbFillTex then
        if sbFillTex.SetSnapToPixelGrid then pcall(sbFillTex.SetSnapToPixelGrid, sbFillTex, false) end
        if sbFillTex.SetTexelSnappingBias then pcall(sbFillTex.SetTexelSnappingBias, sbFillTex, 0) end
    end
    f._spark = M.AttachEdgeSpark(sb, { width = 22, extraHeight = 6, a = 0.96, levelOffset = 4, maskHost = barHost })
    if f._spark and f._spark._spark then
        local sp = f._spark._spark
        if sp.SetSnapToPixelGrid then pcall(sp.SetSnapToPixelGrid, sp, false) end
        if sp.SetTexelSnappingBias then pcall(sp.SetTexelSnappingBias, sp, 0) end
    end
    f._flow = M.AttachBarLivingFlow(barHost, sb, {
        reverse = false, period = 2.2, sweepRatio = 0.72, peakAlpha = 0.22, softAlpha = 0.12, enabled = false,
    })

    -- 文字宿置于高于 StatusBar 与圆角边框的子框体，避免“条内显示”时被血条/圆角遮挡
    local textHost = CreateFrame("Frame", nil, f)
    textHost:SetAllPoints(f)
    textHost:SetFrameLevel(30)
    textHost:EnableMouse(false)
    f._textHost = textHost

    local nameFS = textHost:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(nameFS, ST.FONT.body, 0.96, 0.97, 0.99, 1)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    f._nameFS = nameFS

    local timeFS = textHost:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(timeFS, ST.FONT.body, 0.94, 0.96, 0.99, 1)
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
    ST.ApplyText(gLabel, ST.FONT.body, 1, 1, 1, 1)
    gLabel:SetPoint("TOPLEFT", g, "BOTTOMLEFT", 2, -4)
    gLabel:SetJustifyH("LEFT")
    g._label = gLabel

    ghostFrame = g
    overlay = f
    f._applyMoverPos = F.Mover.Register({
        key = "CastbarOverlay",
        label = "kkowoUI 圆角施法条",
        frame = f,
        order = 17,
        defaultPoint = "BOTTOM",
        defaultRelPoint = "BOTTOM",
        defaultX = 0,
        defaultY = 215,
        allowShiftDrag = false,
        -- 覆盖在 ERB / 单位框架施法条上时跟随宿主（拖宿主即可），只有暴雪宿主模式才由它自己占位
        isHidden = function() return not (mod._active and castHostKind == "blizz") end,
        isAnchored = function() return castHostKind ~= "blizz" end,
        onReanchor = function() end,
    })
    f:EnableMouse(false)
    RefreshOverlayChrome()
end

-- 供 /kk motion demo 复用与真实施法条一致的构建样式（完全独立副本，绝不触碰真实 overlay/ghostFrame）
function F._BuildDemoCastbar(parent, w, h, fxOverride)
    w = w or 186
    h = h or 16
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f:EnableMouse(false)

    local barHost = CreateFrame("Frame", nil, f)
    barHost:SetAllPoints(f)
    barHost:EnableMouse(false)
    f._barHost = barHost

    local bg = barHost:CreateTexture(nil, "BACKGROUND", nil, -6)
    bg:SetAllPoints()
    bg:SetTexture(ST.TEX.FLAT)
    local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
    bg:SetVertexColor(r1 * 0.14 + 0.06, g1 * 0.14 + 0.06, b1 * 0.14 + 0.08, 0.44)
    f._bg = bg

    local sb = CreateFrame("StatusBar", nil, barHost)
    sb:SetAllPoints()
    local fillTexPath = ST.GetBarFillTexture and ST.GetBarFillTexture(false, fxOverride) or ST.TEX.FLAT
    sb:SetStatusBarTexture(fillTexPath)
    sb._kkFillPath = fillTexPath
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    sb:EnableMouse(false)
    if M.DisablePixelSnap then M.DisablePixelSnap(sb) end
    local sbFill = sb:GetStatusBarTexture()
    if sbFill and M.DisablePixelSnap then M.DisablePixelSnap(sbFill) end
    f._bar = sb

    f._spark = M.AttachEdgeSpark(sb, { width = 18, extraHeight = 4, a = 0.94, levelOffset = 4, maskHost = barHost, fxOverride = fxOverride })
    if f._spark and f._spark._spark and M.DisablePixelSnap then
        M.DisablePixelSnap(f._spark._spark)
    end
    f._flow = M.AttachBarLivingFlow(barHost, sb, {
        reverse = false, period = 2.2, sweepRatio = 0.72, peakAlpha = 0.22, softAlpha = 0.12, fxOverride = fxOverride, enabled = false,
    })

    local textHost = CreateFrame("Frame", nil, f)
    textHost:SetAllPoints(f)
    textHost:SetFrameLevel(sb:GetFrameLevel() + 6)
    textHost:EnableMouse(false)
    f._textHost = textHost

    local nameFS = textHost:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(nameFS, ST.FONT.caption, 0.96, 0.97, 0.99, 1)
    nameFS:SetPoint("LEFT", barHost, "LEFT", 5, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    f._nameFS = nameFS

    local timeFS = textHost:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(timeFS, ST.FONT.caption, 0.94, 0.96, 0.99, 1)
    timeFS:SetPoint("RIGHT", barHost, "RIGHT", -5, 0)
    timeFS:SetJustifyH("RIGHT")
    timeFS:SetWordWrap(false)
    f._timeFS = timeFS

    local g = CreateFrame("Frame", nil, f)
    g:SetAllPoints(f)
    g:SetFrameLevel(textHost:GetFrameLevel() + 2)
    g:EnableMouse(false)
    g:Hide()
    local gFill = g:CreateTexture(nil, "ARTWORK")
    gFill:SetAllPoints()
    gFill:SetTexture(ST.TEX.FLAT)
    g._fill = gFill
    local gLabel = g:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(gLabel, ST.FONT.caption, 1, 1, 1, 1)
    gLabel:SetPoint("CENTER", g, "CENTER", 0, 0)
    g._label = gLabel
    f._ghost = g

    local rad = math_min(ST.GetCornerRadius(6), math_max(2, math_floor(h * 0.45)))
    if rad > 0 then
        ST.MaskTexture(barHost, bg, rad)
        if sbFill then ST.MaskTexture(barHost, sbFill, rad) end
        if f._spark and f._spark.SyncMask then f._spark:SyncMask(barHost, rad) end
        ST.ApplyRoundedBorder(barHost, rad, 0.02, 0.02, 0.03, 0.94, 5)
    end
    ST.ApplyBarGradient(sb, r1, g1, b1, r2, g2, b2, 0.96, false)

    function f:ApplyDemoStyle(ov)
        local wantFill = ST.GetBarFillTexture and ST.GetBarFillTexture(false, ov) or ST.TEX.FLAT
        if sb._kkFillPath ~= wantFill then
            sb:SetStatusBarTexture(wantFill)
            sb._kkFillPath = wantFill
            local ft = sb:GetStatusBarTexture()
            if ft and M.DisablePixelSnap then M.DisablePixelSnap(ft) end
            if rad > 0 and ft then ST.MaskTexture(barHost, ft, rad) end
        end
        if f._spark then
            f._spark._fxOverride = ov
            f._spark:RefreshTexture()
            if f._spark.SyncMask then f._spark:SyncMask(barHost, rad) end
        end
        if f._flow then
            f._flow._fxOverride = ov
            f._flow:Refresh(rad)
        end
        ST.ApplyBarGradient(sb, r1, g1, b1, r2, g2, b2, 0.96, false)
    end
    return f
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
    if mod:GetDB().showLatency == false or castState.secretTime or castState.duration <= 0.05 then
        overlay._latency:Hide()
        return
    end
    local lat = castState.latency or 0
    if lat <= 0.01 and _G.GetNetStats then
        local _, _, homeMS, worldMS = _G.GetNetStats()
        -- PlainNumber 的回退值 0 在 Lua 里也是真值，`a or b` 永远走不到 homeMS，必须显式判断
        local ms = F.PlainNumber(worldMS, 0) or 0
        if ms <= 0 then ms = F.PlainNumber(homeMS, 0) or 0 end
        lat = ms / 1000
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

local function GetEUICastBarProfile()
    local EUI = _G.EllesmereUI
    local rbNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIResourceBars
    local p = rbNS and rbNS.ERB and rbNS.ERB.db and rbNS.ERB.db.profile
    if type(p) == "table" and type(p.castBar) == "table" then
        return p.castBar
    end
    local raw = _G.EllesmereUIResourceBarsDB
    if type(raw) == "table" and type(raw.profiles) == "table" then
        local def = raw.profiles.Default
        if type(def) == "table" and type(def.castBar) == "table" then
            return def.castBar
        end
    end
    return nil
end

local function PaintCastFillColor()
    if not overlay then return end
    local cb = GetEUICastBarProfile()
    -- 玩家自己的读条不看「不可打断」标记（无限服对自身施法常返回 true，整条会变成灰色）
    if castState.isChannel then
        if cb and cb.channelOverride == true and F.PlainNumber(cb.channelR, nil) then
            local cr = F.PlainNumber(cb.channelR, 0.30) or 0.30
            local cg = F.PlainNumber(cb.channelG, 0.80) or 0.80
            local cbCol = F.PlainNumber(cb.channelB, 0.70) or 0.70
            ST.ApplyBarGradient(overlay._bar,
                cr * 0.76, cg * 0.76, cbCol * 0.76,
                math_min(1, cr * 0.82 + 0.22), math_min(1, cg * 0.82 + 0.22), math_min(1, cbCol * 0.82 + 0.22),
                0.98, false)
            return
        end
        local cc = ST.COLORS.channel
        ST.ApplyBarGradient(overlay._bar, cc[1] * 0.75, cc[2] * 0.85, cc[3] * 0.90, 0.78, 0.98, 0.94, 0.98, false)
    else
        -- 同步尊重 EUI 施法条的自定义颜色设置（取消「职业着色」并自选颜色时立刻生效）
        if cb and cb.classColored == false and F.PlainNumber(cb.fillR, nil) then
            local fr = F.PlainNumber(cb.fillR, 0.90) or 0.90
            local fg = F.PlainNumber(cb.fillG, 0.70) or 0.70
            local fb = F.PlainNumber(cb.fillB, 0.20) or 0.20
            if cb.gradientEnabled and F.PlainNumber(cb.gradientR, nil) then
                local gr = F.PlainNumber(cb.gradientR, fr) or fr
                local gg = F.PlainNumber(cb.gradientG, fg) or fg
                local gb = F.PlainNumber(cb.gradientB, fb) or fb
                ST.ApplyBarGradient(overlay._bar, fr, fg, fb, gr, gg, gb, 0.98, false)
            else
                ST.ApplyBarGradient(overlay._bar,
                    fr * 0.78, fg * 0.78, fb * 0.78,
                    math_min(1, fr * 0.80 + 0.24), math_min(1, fg * 0.80 + 0.24), math_min(1, fb * 0.80 + 0.24),
                    0.98, false)
            end
            return
        end
        local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
        ST.ApplyBarGradient(overlay._bar, r1, g1, b1, r2, g2, b2, 0.98, false)
    end
end

local function SpawnGhostFeedback(kind)
    if not (overlay and ghostFrame) then return end
    local db = mod:GetDB()
    if (kind == "success" or kind == "channel_end") and db.finishFlash == false then return end
    if (kind == "interrupt" or kind == "failed") and db.interruptShake == false then return end

    local bh = overlay._barHost
    local w = F.PlainNumber(bh:GetWidth(), 220) or 220
    local h = F.PlainNumber(bh:GetHeight(), 14) or 14
    local rad = math_min(ST.GetCornerRadius(6), math_max(2, math_floor(h * 0.48)))

    ghostFrame:ClearAllPoints()
    ghostFrame:SetSize(w, h)
    ghostFrame:SetPoint("CENTER", bh, "CENTER", 0, 0)
    if rad > 0 then
        ST.MaskTexture(ghostFrame, ghostFrame._fill, rad)
        ST.ApplyRoundedBorder(ghostFrame, rad, 0.02, 0.02, 0.03, 0.95, 4)
        ghostFrame._lastRad = rad
    elseif ghostFrame._lastRad and ghostFrame._lastRad > 0 then
        ST.ClearRoundedMask(ghostFrame)
        ghostFrame._lastRad = 0
    end

    M.StopFrameAnims(ghostFrame)
    local polished = ST.IsFXEnabled("fx_castFinish")
    if not polished then
        -- 开关关闭时严格恢复改动前的两种反馈表现
        if kind == "success" or kind == "channel_end" then
            local _, _, _, r2, g2, b2 = ST.GetClassGradient()
            ST.ApplyGradient(ghostFrame._fill, "HORIZONTAL", r2, g2, b2, 0.95, 1, 1, 1, 1)
            ghostFrame._label:SetText(castState.spellName or "")
            ghostFrame._label:SetTextColor(1, 1, 1, 0.95)
            M.PlayFlashFade(ghostFrame, 0.22, 5)
        else
            local ic = ST.COLORS.interrupt
            ST.ApplyGradient(ghostFrame._fill, "HORIZONTAL", ic[1], ic[2], ic[3], ic[4], ic[1], ic[2], ic[3], ic[4])
            ghostFrame._label:SetText("已打断")
            ghostFrame._label:SetTextColor(1, 0.45, 0.48, 1)
            M.PlayInterruptShake(ghostFrame, 4, 0.18)
        end
        return
    end

    local isSoft = ST.GetFXIntensity() == "soft"
    local alphaScale = isSoft and 0.68 or 1.0

    if kind == "success" then
        -- 成功：约 0.15s 亮闪停留，再用约 0.16s 轻上浮淡出
        local _, _, _, r2, g2, b2 = ST.GetClassGradient()
        ST.ApplyGradient(ghostFrame._fill, "HORIZONTAL", r2, g2, b2, 0.92 * alphaScale, 1, 1, 1, 0.98 * alphaScale)
        ghostFrame._label:SetText(castState.spellName or "")
        ghostFrame._label:SetTextColor(1, 1, 1, 0.96)
        M.PlayFlashFade(ghostFrame, 0.16, isSoft and 3 or 5, nil, 0.15, alphaScale)
    elseif kind == "channel_end" then
        -- 引导结束：柔和淡出，无刺眼白闪
        local cc = ST.COLORS.channel
        ST.ApplyGradient(ghostFrame._fill, "HORIZONTAL", cc[1] * 0.8, cc[2] * 0.88, cc[3] * 0.92, 0.78 * alphaScale, cc[1], cc[2], cc[3], 0.82 * alphaScale)
        ghostFrame._label:SetText(castState.spellName or "")
        ghostFrame._label:SetTextColor(0.84, 0.96, 0.94, 0.88)
        M.PlayFlashFade(ghostFrame, 0.20, isSoft and 1.5 or 2.5, nil, 0, 0.82 * alphaScale)
    elseif kind == "failed" then
        -- 失败：与被打断区分开，更淡、更短、不重抖
        local ic = ST.COLORS.interrupt
        ST.ApplyGradient(ghostFrame._fill, "HORIZONTAL", ic[1] * 0.85, ic[2] * 0.85, ic[3] * 0.85, 0.65 * alphaScale, ic[1] * 0.95, ic[2] * 0.90, ic[3] * 0.85, 0.65 * alphaScale)
        ghostFrame._label:SetText("施法失败")
        ghostFrame._label:SetTextColor(1, 0.68, 0.62, 0.90)
        M.PlayFlashFade(ghostFrame, 0.18, 0, nil, 0.08, 0.72 * alphaScale)
    else
        -- 被打断：打断色停留约 0.50s，柔和强度抖动幅度减半（±2px vs ±4px），结束后严格 Hide
        local ic = ST.COLORS.interrupt
        ST.ApplyGradient(ghostFrame._fill, "HORIZONTAL", ic[1], ic[2], ic[3], ic[4], ic[1], ic[2], ic[3], ic[4])
        ghostFrame._label:SetText("已打断")
        ghostFrame._label:SetTextColor(1, 0.45, 0.48, 1)
        M.PlayInterruptShake(ghostFrame, isSoft and 2 or 4, 0.18, nil, 0.50, 0.20)
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
        if rem <= -0.35 then
            if not F.UnitIsCasting("player", castState.isChannel) then
                castState.active = false
                self:SetScript("OnUpdate", nil)
                self:Hide()
                return
            end
        end
        if castState.isChannel then
            overlay._bar:SetValue(0)
        else
            overlay._bar:SetValue(1)
        end
        return
    end
    local prog, dispVal
    if castState.isChannel then
        prog = math_max(0, math_min(1, rem / dur))
        dispVal = rem
    else
        prog = math_max(0, math_min(1, elapsed / dur))
        dispVal = elapsed
    end
    -- 进度条与流光每帧全速推进，时间文字按 0.1s 缓存节流，消除长时间施法 120Hz 重排微卡顿
    local tenths = math_floor(dispVal * 10 + 0.5)
    if tenths ~= castState.lastTimeTenths then
        castState.lastTimeTenths = tenths
        overlay._timeFS:SetText(string_format("%.1f / %.1f", tenths * 0.1, dur))
    end
    overlay._bar:SetValue(prog)
end

local function ApplySecretUninterruptibleOverlay(notInt)
    if not (overlay and overlay._bar) then return end
    -- 仅对机密不可打断标志准备安全 C 端布尔透明叠层（玩家自身读条明文时保持现有逻辑不变）
    if not F.IsSecret(notInt) then
        if overlay._lockTex then overlay._lockTex:Hide() end
        return
    end
    if not overlay._lockTex then
        local fillTex = overlay._bar:GetStatusBarTexture()
        local lt = overlay._bar:CreateTexture(nil, "ARTWORK", nil, 3)
        lt:SetTexture(ST.TEX.FLAT)
        lt:SetVertexColor(0.56, 0.58, 0.64, 0.55)
        if fillTex then lt:SetAllPoints(fillTex) else lt:SetAllPoints(overlay._bar) end
        overlay._lockTex = lt
    end
    local gRad = ST.GetCornerRadius(6)
    local h = F.PlainNumber(overlay._barHost:GetHeight(), 14) or 14
    local rad = (gRad > 0) and math_min(gRad, math_max(2, math_floor(h * 0.48))) or 0
    if rad > 0 then
        ST.MaskTexture(overlay._barHost, overlay._lockTex, rad)
    elseif ST.UnmaskTexture then
        ST.UnmaskTexture(overlay._barHost, overlay._lockTex)
    end
    if overlay._lockTex.SetAlphaFromBoolean then
        local okA = pcall(overlay._lockTex.SetAlphaFromBoolean, overlay._lockTex, notInt, 0.55, 0)
        if okA then
            overlay._lockTex:Show()
            return
        end
    end
    overlay._lockTex:Hide()
end

local function StartCast(isChannel, isEmpower)
    BuildCastbarOverlay()
    local fn = isChannel and _G.UnitChannelInfo or _G.UnitCastingInfo
    if not fn then return end
    local okC, name, _, tex, startMS, endMS, _, castID, notInt, spellID = pcall(fn, "player")
    if not okC then return end
    if not isChannel then
        -- UnitCastingInfo 返回值: name, text, texture, startTimeMS, endTimeMS, isTradeSkill, castID, notInterruptible, spellId
    else
        -- UnitChannelInfo 返回值: name, text, texture, startTimeMS, endTimeMS, isTradeSkill, notInterruptible, spellId
        spellID = notInt
        notInt = castID
        castID = nil
    end
    if type(name) == "nil" then return end

    local sMS = F.PlainNumber(startMS, nil)
    local eMS = F.PlainNumber(endMS, nil)
    local hasPlainTime = (sMS ~= nil and eMS ~= nil and eMS > sMS)
    local wantNative = CanUseNativeCastTimer(overlay._bar)

    castState.isChannel = isChannel == true
    castState.isEmpower = isEmpower == true
    castState.secretTime = not hasPlainTime
    if hasPlainTime then
        castState.startTime = sMS / 1000
        castState.endTime = eMS / 1000
        castState.duration = math_max(0.05, castState.endTime - castState.startTime)
    else
        castState.startTime = 0
        castState.endTime = 0
        castState.duration = 0
    end

    local durObj = wantNative and FetchCastDurationObj(isChannel, isEmpower) or nil
    local useNative = false
    if wantNative and durObj ~= nil then
        local dirEnum = _G.Enum.StatusBarTimerDirection
        local dir = (isChannel and not isEmpower) and dirEnum.RemainingTime or dirEnum.ElapsedTime
        local imm = _G.Enum.StatusBarInterpolation and _G.Enum.StatusBarInterpolation.Immediate or nil
        local okT = pcall(overlay._bar.SetTimerDuration, overlay._bar, durObj, imm, dir)
        if okT then
            if overlay._bar.SetToTargetValue then pcall(overlay._bar.SetToTargetValue, overlay._bar) end
            useNative = true
        end
    end

    if not useNative and not hasPlainTime then
        -- 旧路径或 SetTimerDuration 不可用且起止时间为机密值：兜底退回宿主条
        castState.active = false
        castState.nativeTimer = false
        castState.durationObj = nil
        castState.secretFallback = true
        M.UnregisterTextTick(CAST_TICK_KEY)
        if overlay then
            overlay:SetScript("OnUpdate", nil)
            overlay:Hide()
        end
        ApplyHostMute(false)
        return
    end
    castState.secretFallback = false

    local now = GetTime()
    castState.active = true
    castState.nativeTimer = useNative
    castState.durationObj = useNative and durObj or nil
    castState.lastTimeTenths = -1
    castState.castGUID = (type(castID) ~= "nil" and not F.IsSecret(castID)) and castID or nil
    castState.spellName = F.IsSecret(name) and "" or CleanSpellName(name)
    castState.spellID = F.PlainNumber(spellID, nil)
    castState.icon = (type(tex) ~= "nil" and not F.IsSecret(tex)) and tex or nil
    castState.uninterruptible = (not F.IsSecret(notInt)) and (notInt == true) or false
    if castState.sentTime > 0 and (now - castState.sentTime) < 1.2 then
        castState.latency = now - castState.sentTime
    else
        castState.latency = 0
    end
    castState.sentTime = 0

    RefreshOverlayChrome()
    ApplyHostMute(true)
    if ghostFrame then
        M.StopFrameAnims(ghostFrame)
        ghostFrame:Hide()
    end
    if type(tex) ~= "nil" then
        pcall(overlay._iconTex.SetTexture, overlay._iconTex, tex)
    end
    if F.IsSecret(name) then
        pcall(overlay._nameFS.SetText, overlay._nameFS, name)
    else
        overlay._nameFS:SetText(castState.spellName)
    end
    PaintCastFillColor()
    ApplySecretUninterruptibleOverlay(notInt)
    LayoutLatencyZone()
    if isChannel then
        LayoutChannelTicks(castState.spellID, castState.spellName)
    else
        for i = 1, 15 do overlay._ticks[i]:Hide() end
    end
    if overlay._spark then
        overlay._spark:SetShown(mod:GetDB().showSpark ~= false)
        overlay._spark:SyncAnchor()
    end

    overlay:Show()
    if overlay._flow then
        overlay._flow:SetEnabled(true, overlay._lastBarRad or 0)
    end
    if useNative then
        overlay:SetScript("OnUpdate", nil)
        if overlay._spark then
            overlay._spark:SetShown(mod:GetDB().showSpark ~= false)
            overlay._spark:SyncAnchor()
        end
        UpdateNativeCastText()
        M.RegisterTextTick(CAST_TICK_KEY, 0.05, UpdateNativeCastText)
    else
        M.UnregisterTextTick(CAST_TICK_KEY)
        overlay:SetScript("OnUpdate", OnCastUpdate)
        OnCastUpdate(overlay)
    end
end

local function StopCast(feedbackKind, eventCastGUID)
    if castState.secretFallback then
        castState.secretFallback = false
        ApplyHostMute(true)
    end
    if not castState.active then return end
    if not castState.isChannel and type(eventCastGUID) ~= "nil" and not F.IsSecret(eventCastGUID)
        and castState.castGUID and eventCastGUID ~= castState.castGUID then
        return
    end
    castState.active = false
    castState.nativeTimer = false
    castState.durationObj = nil
    M.UnregisterTextTick(CAST_TICK_KEY)
    if overlay then
        overlay:SetScript("OnUpdate", nil)
        if overlay._flow then overlay._flow:SetEnabled(false) end
        if overlay._lockTex then overlay._lockTex:Hide() end
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
    ApplyHostMute(true)
    AttachTargetCastSpark()

    local EUI = _G.EllesmereUI
    if EUI and EUI.RegisterUnlockModeListener then
        pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_CastbarMotion", function(active)
            if not mod._active then return end
            if active then
                ApplyHostMute(false)
                if overlay and castHostKind == "blizz" and not castState.active then
                    -- 解锁预览：显示一条静态示意条，方便在 EUI 解锁模式里拖动摆放
                    overlay:SetScript("OnUpdate", nil)
                    overlay._bar:SetValue(0.6)
                    overlay._nameFS:SetText("kkowoUI 圆角施法条")
                    overlay._timeFS:SetText("拖动调整位置")
                    PaintCastFillColor()
                    overlay:Show()
                elseif overlay then
                    overlay:Hide()
                end
            else
                SyncOverlayAnchor()
                ApplyHostMute(true)
                if overlay and not castState.active then overlay:Hide() end
                if castState.active and overlay then
                    overlay:Show()
                end
            end
        end)
    end

    self:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player", function()
        castState.sentTime = GetTime()
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_START", "player", function() StartCast(false, false) end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED", "player", function() if castState.active and not castState.isChannel then StartCast(false, false) end end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", function() StartCast(true, false) end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE", "player", function() if castState.active and castState.isChannel then StartCast(true, castState.isEmpower) end end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", "player", function() StartCast(true, true) end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_UPDATE", "player", function() if castState.active and castState.isEmpower then StartCast(true, true) end end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", "player", function()
        if castState.active and castState.isEmpower then
            StopCast("success", nil)
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, castGUID, spellID)
        -- 只认当前读条的法术：无限服读条信息可能不带 castGUID，此时自动射击等别的法术的成功事件
        -- 不能把正在读的瞄准射击提前判成「施法成功」
        local sid = F.PlainNumber(spellID, nil)
        if sid and castState.spellID and sid ~= castState.spellID then return end
        if castState.active and not castState.isChannel then
            StopCast("success", castGUID)
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", function(_, _, _, castGUID, spellID)
        local sid = F.PlainNumber(spellID, nil)
        if sid and castState.spellID and sid ~= castState.spellID then return end
        StopCast("interrupt", castGUID)
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", function(_, _, _, castGUID, spellID)
        local sid = F.PlainNumber(spellID, nil)
        if sid and castState.spellID and sid ~= castState.spellID then return end
        if castState.active and not castState.isChannel then
            if F.UnitIsCasting("player") then return end
            StopCast("failed", castGUID)
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player", function(_, _, _, castGUID, spellID)
        local sid = F.PlainNumber(spellID, nil)
        if sid and castState.spellID and sid ~= castState.spellID then return end
        if castState.active and not castState.isChannel then
            StopCast(nil, castGUID)
        end
    end)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", function()
        if castState.active and castState.isChannel then
            StopCast("channel_end", nil)
        end
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if castState.active then
            local stillCasting = F.UnitIsCasting("player") or F.UnitIsCasting("player", true)
            if not stillCasting then
                castState.active = false
                if overlay then
                    overlay:SetScript("OnUpdate", nil)
                    overlay:Hide()
                end
            end
        end
        AttachTargetCastSpark()
        RefreshOverlayChrome()
        ApplyHostMute(true)
        C_Timer.After(0.5, function() if mod._active then RefreshOverlayChrome(); ApplyHostMute(true) end end)
    end)
    C_Timer.After(0.6, function() if mod._active then RefreshOverlayChrome(); ApplyHostMute(true) end end)
end

function mod:OnDisable()
    local EUI = _G.EllesmereUI
    if EUI and EUI.UnregisterUnlockModeListener then
        pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_CastbarMotion")
    end
    castState.active = false
    castState.nativeTimer = false
    castState.durationObj = nil
    M.UnregisterTextTick(CAST_TICK_KEY)
    if overlay then
        overlay:SetScript("OnUpdate", nil)
        if overlay._flow then overlay._flow:SetEnabled(false) end
        if overlay._lockTex then overlay._lockTex:Hide() end
        overlay:Hide()
    end
    if ghostFrame then
        M.StopFrameAnims(ghostFrame)
        ghostFrame:Hide()
    end
    if targetCastSpark then targetCastSpark:SetShown(false) end
    ApplyHostMute(false)
end

function mod:OnRefresh()
    RefreshOverlayChrome()
    ApplyHostMute(true)
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
        text = "技能球去重图标",
        tooltip = "中央技能球开启时隐藏施法条左侧重复图标，关闭后恢复。",
        getValue = function() return db.hideIconWhenOrb ~= false end,
        setValue = function(v) db.hideIconWhenOrb = v == true; RefreshOverlayChrome() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "文字置于条外",
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
        text = "延迟与引导刻度",
        getValue = function() return db.showLatency ~= false end,
        setValue = function(v) db.showLatency = v == true; db.showChannelTicks = v == true end,
    }, {
        type = "toggle",
        text = "前沿高光光刃",
        getValue = function() return db.showSpark ~= false end,
        setValue = function(v) db.showSpark = v == true; db.enhanceTargetCast = v == true; RefreshOverlayChrome(); AttachTargetCastSpark() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "施法完成闪光",
        getValue = function() return db.finishFlash ~= false end,
        setValue = function(v) db.finishFlash = v == true end,
    }, {
        type = "toggle",
        text = "打断红底抖动",
        getValue = function() return db.interruptShake ~= false end,
        setValue = function(v) db.interruptShake = v == true end,
    })
    y = y - h

    return y
end
