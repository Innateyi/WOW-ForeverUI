----------------------------------------------------------------------
--  KkowoUI — Core/Theme.lua
--  现代 MMO 简洁统一视觉系统：实时同步 EllesmereUI 主色、字体与扁平材质
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local pairs, ipairs, pcall, type = pairs, ipairs, pcall, type
local math_abs, math_max, math_min = math.abs, math.max, math.min
local setmetatable = setmetatable
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown

local Theme = {}
F.Theme = Theme

-- 默认现代暖香槟金与中性暗灰面板（与 EllesmereUI 保持一致）
Theme.COLORS = {
    accent     = { 0.863, 0.655, 0.498 },  -- #DCA77F 暖香槟金
    bg         = { 0.06,  0.065, 0.075, 0.86 },
    bgSoft     = { 0.09,  0.095, 0.11,  0.76 },
    border     = { 0.22,  0.23,  0.26,  0.85 },
    borderSoft = { 1.0,   1.0,   1.0,   0.10 },
    text       = { 0.94,  0.94,  0.95,  1.00 },
    textMuted  = { 0.62,  0.64,  0.68,  1.00 },
    good       = { 0.37,  0.83,  0.65,  1.00 },  -- #5FD3A6 柔玉绿
    warn       = { 0.94,  0.75,  0.34,  1.00 },  -- #F0BF57 暖琥珀
    danger     = { 0.88,  0.32,  0.39,  1.00 },  -- #E05263 珊瑚红
    info       = { 0.45,  0.74,  0.95,  1.00 },  -- #73BDF2 雾蓝
}

Theme.FLAT_TEX = "Interface\\Buttons\\WHITE8x8"
Theme.MERFIN_TEX = "Interface\\AddOns\\YaMedia\\statusbar\\MerfinMain"
Theme.ICONS = F.MEDIA .. "Icons\\"

local skinAPI = nil
local themeListeners = {}

function Theme.GetBarTexture()
    local LSM = _G.LibStub and _G.LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local tex = LSM:Fetch("statusbar", "MerfinMain", true)
        if tex then
            return tex
        end
    end
    if F.IsAddOnLoaded("YaMedia") then
        return Theme.MERFIN_TEX
    end
    return Theme.FLAT_TEX
end

function Theme.GetClassColor()
    local classToken = F.GetPlayerClass()
    if _G.C_ClassColor and _G.C_ClassColor.GetClassColor then
        local c = _G.C_ClassColor.GetClassColor(classToken)
        if c then
            return c.r, c.g, c.b
        end
    end
    local colors = _G.RAID_CLASS_COLORS
    local c = colors and colors[classToken]
    if c then
        return c.r, c.g, c.b
    end
    local def = Theme.COLORS.accent
    return def[1], def[2], def[3]
end

function Theme.GetAccent()
    local mode = (F.db and F.db.theme and F.db.theme.accentMode) or "class"
    if mode == "class" then
        return Theme.GetClassColor()
    end
    if skinAPI and skinAPI.GetAccentColor then
        local ok, r, g, b = pcall(skinAPI.GetAccentColor)
        if ok and r and g and b then
            return r, g, b
        end
    end
    return Theme.GetClassColor()
end

function Theme.GetPanelColor()
    if skinAPI and skinAPI.GetPanelColor then
        local ok, r, g, b, a = pcall(skinAPI.GetPanelColor)
        if ok and r and g and b then
            return r, g, b, a or 0.86
        end
    end
    local c = Theme.COLORS.bg
    return c[1], c[2], c[3], c[4]
end

function Theme.GetFont()
    if skinAPI and skinAPI.GetFont then
        local ok, path = pcall(skinAPI.GetFont)
        if ok and type(path) == "string" and path ~= "" then
            return path
        end
    end
    return _G.STANDARD_TEXT_FONT or "Fonts\\ARKai_T.ttf"
end

local fontCache = setmetatable({}, { __mode = "k" })

-- 现代清爽排版：默认无硬描边 + 柔和投影（弱表缓存，参数未变时跳过 SetFont 避免重复字形重排）
function Theme.ApplyFont(fs, size, outline, r, g, b, a)
    if not (fs and fs.SetFont) then
        return
    end
    local path = Theme.GetFont()
    local sz = size or 12
    local fl = outline or ""
    local c = fontCache[fs]
    if not c or c[1] ~= path or c[2] ~= sz or c[3] ~= fl then
        local ok, applied = pcall(fs.SetFont, fs, path, sz, fl)
        if not (ok and applied) then
            local fallback = _G.STANDARD_TEXT_FONT or "Fonts\\ARKai_T.ttf"
            if fallback ~= path then
                pcall(fs.SetFont, fs, fallback, sz, fl)
            end
        end
        if fl == "" then
            fs:SetShadowColor(0, 0, 0, 0.85)
            fs:SetShadowOffset(1, -1)
        else
            fs:SetShadowColor(0, 0, 0, 0.45)
            fs:SetShadowOffset(0, 0)
        end
        if c then
            c[1], c[2], c[3] = path, sz, fl
        else
            fontCache[fs] = { path, sz, fl }
        end
    end
    if r and g and b then
        fs:SetTextColor(r, g, b, a or 1)
    end
end

-- 为框体建立 1px 现代暗色底板与细腻边框（纯纹理，不改暴雪 NineSlice）
function Theme.StylePanel(frame, alpha, borderAlpha)
    if not frame then
        return
    end
    local r, g, b, pa = Theme.GetPanelColor()
    local bg = frame._fuiBg
    if not bg then
        bg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        bg:SetAllPoints()
        frame._fuiBg = bg
    end
    bg:SetColorTexture(r, g, b, alpha or pa or 0.86)

    local borders = frame._fuiBorders
    if not borders then
        borders = {}
        local edges = {
            { "TOPLEFT",     "TOPRIGHT",    0,  1, nil, 1 },
            { "BOTTOMLEFT",  "BOTTOMRIGHT", 0, -1, nil, 1 },
            { "TOPLEFT",     "BOTTOMLEFT", -1,  0, 1, nil },
            { "TOPRIGHT",    "BOTTOMRIGHT", 1,  0, 1, nil },
        }
        for i, e in ipairs(edges) do
            local line = frame:CreateTexture(nil, "BORDER")
            line:SetPoint(e[1], frame, e[1], e[3], e[4])
            line:SetPoint(e[2], frame, e[2], e[3], e[4])
            if e[5] then line:SetWidth(e[5]) end
            if e[6] then line:SetHeight(e[6]) end
            borders[i] = line
        end
        frame._fuiBorders = borders
    end
    local bc = Theme.COLORS.border
    local ba = borderAlpha or bc[4]
    for _, line in ipairs(borders) do
        line:SetColorTexture(bc[1], bc[2], bc[3], ba)
    end
end

function Theme.SetBorderAccent(frame, useAccent)
    local borders = frame and frame._fuiBorders
    if not borders then
        return
    end
    if useAccent then
        local r, g, b = Theme.GetAccent()
        for _, line in ipairs(borders) do
            line:SetColorTexture(r, g, b, 0.9)
        end
    else
        local bc = Theme.COLORS.border
        for _, line in ipairs(borders) do
            line:SetColorTexture(bc[1], bc[2], bc[3], bc[4])
        end
    end
end

function Theme.StyleButton(btn, fontSize)
    if not btn then
        return
    end
    Theme.StylePanel(btn, 0.82, 0.7)
    local hl = btn._fuiHover
    if not hl then
        hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        btn._fuiHover = hl
    end
    local r, g, b = Theme.GetAccent()
    hl:SetColorTexture(r, g, b, 0.16)
    if btn.GetFontString and btn:GetFontString() then
        Theme.ApplyFont(btn:GetFontString(), fontSize or 12, "", 0.95, 0.95, 0.96, 1)
    end
end

-- 统一现代黑曜石玻璃按钮/卡片表面（纵向暗岩渐变 + 1px 顶部高光 + 无缺口 1px 边框 + 柔和底光与悬停微亮条）
-- 全部图层存入弱表，零污染暴雪框体，任何按钮/悬浮卡可直接复用
local glassParts = setmetatable({}, { __mode = "k" })
local scratchC1 = _G.CreateColor and _G.CreateColor(0, 0, 0, 1) or nil
local scratchC2 = _G.CreateColor and _G.CreateColor(0, 0, 0, 1) or nil

local function SetScratchGradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    if not (scratchC1 and scratchC2 and tex and tex.SetGradient) then return false end
    scratchC1:SetRGBA(r1, g1, b1, a1)
    scratchC2:SetRGBA(r2, g2, b2, a2)
    return pcall(tex.SetGradient, tex, orient, scratchC1, scratchC2)
end

local function PaintGlassParts(g, hovered, active)
    if not g then return end
    local ar, ag, ab
    if g.accent then
        ar, ag, ab = g.accent[1], g.accent[2], g.accent[3]
    else
        ar, ag, ab = Theme.GetAccent()
    end
    local isHot = hovered == true
    local isAct = active == true
    local bgA = g.bgAlpha or 0.92
    local borderA = g.borderAlpha or 0.92

    if scratchC1 and g.bg.SetGradient then
        local tint = isHot and 0.065 or (isAct and 0.045 or 0.025)
        SetScratchGradient(g.bg, "VERTICAL",
            0.035 + ar * tint, 0.041 + ag * tint, 0.058 + ab * tint, math_min(1, bgA + 0.03),
            0.086 + ar * (tint * 0.45), 0.098 + ag * (tint * 0.45), 0.132 + ab * (tint * 0.45), bgA)
    else
        g.bg:SetColorTexture(0.055, 0.062, 0.082, bgA)
    end

    local auraA = isHot and (g.hoverAura or 0.30) or (isAct and (g.activeAura or 0.20) or (g.restAura or 0.10))
    if auraA > 0.005 then
        if scratchC1 and g.aura.SetGradient then
            SetScratchGradient(g.aura, "VERTICAL",
                ar, ag, ab, auraA,
                ar, ag, ab, isHot and (auraA * 0.18) or 0)
        else
            g.aura:SetColorTexture(ar, ag, ab, auraA * 0.65)
        end
        g.aura:Show()
    else
        g.aura:Hide()
    end

    g.topSpec:SetColorTexture(1, 1, 1, isHot and 0.20 or 0.12)

    local mix = g.borderTintMix or 0.22
    local br, bg, bb, ba
    if isHot then
        br, bg, bb, ba = ar, ag, ab, 0.96
    elseif isAct then
        br, bg, bb, ba = ar * 0.78 + 0.12, ag * 0.78 + 0.12, ab * 0.78 + 0.12, 0.92
    else
        br = 0.17 + ar * mix
        bg = 0.19 + ag * mix
        bb = 0.24 + ab * mix
        ba = borderA
    end
    for _, ln in ipairs(g.borders) do
        ln:SetColorTexture(br, bg, bb, ba)
    end

    if isHot or isAct or g.showRestBottomBar then
        g.bottomBar:SetColorTexture(ar, ag, ab, isHot and 0.98 or (isAct and 0.90 or 0.48))
        g.bottomBar:Show()
    else
        g.bottomBar:Hide()
    end
end

function Theme.StyleGlassSurface(frame, opts)
    if not frame then return nil end
    opts = opts or {}
    local g = glassParts[frame]
    if not g then
        local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        bg:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
        bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        bg:SetColorTexture(1, 1, 1, 1)

        local aura = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
        aura:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
        aura:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        aura:SetColorTexture(1, 1, 1, 1)

        local topSpec = frame:CreateTexture(nil, "BORDER", nil, 1)
        topSpec:SetHeight(1)
        topSpec:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
        topSpec:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)

        local borders = {}
        local specs = {
            { "TOPLEFT",     "TOPRIGHT",    nil, 1 },
            { "BOTTOMLEFT",  "BOTTOMRIGHT", nil, 1 },
            { "TOPLEFT",     "BOTTOMLEFT",  1, nil },
            { "TOPRIGHT",    "BOTTOMRIGHT", 1, nil },
        }
        for i, sp in ipairs(specs) do
            local ln = frame:CreateTexture(nil, "OVERLAY", nil, 1)
            ln:SetPoint(sp[1], frame, sp[1])
            ln:SetPoint(sp[2], frame, sp[2])
            if sp[3] then ln:SetWidth(sp[3]) end
            if sp[4] then ln:SetHeight(sp[4]) end
            borders[i] = ln
        end

        local bottomBar = frame:CreateTexture(nil, "OVERLAY", nil, 3)
        bottomBar:SetHeight(2)
        bottomBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 2, 1)
        bottomBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 1)
        bottomBar:Hide()

        g = {
            bg = bg,
            aura = aura,
            topSpec = topSpec,
            borders = borders,
            bottomBar = bottomBar,
        }
        glassParts[frame] = g
    end

    g.accent            = opts.accent
    g.bgAlpha           = opts.bgAlpha or 0.92
    g.borderAlpha       = opts.borderAlpha or 0.92
    g.restAura          = opts.restAura
    g.hoverAura         = opts.hoverAura
    g.activeAura        = opts.activeAura
    g.borderTintMix     = opts.borderTintMix
    g.showRestBottomBar = opts.showRestBottomBar == true

    g.bg:Show()
    g.topSpec:Show()
    for _, ln in ipairs(g.borders) do ln:Show() end
    PaintGlassParts(g, opts.hovered == true, opts.active == true)
    return g
end

function Theme.SetGlassState(frame, hovered, active)
    local g = frame and glassParts[frame]
    if g then
        PaintGlassParts(g, hovered == true, active == true)
    end
end

function Theme.SetGlassShown(frame, shown)
    local g = frame and glassParts[frame]
    if not g then return end
    local show = shown == true
    g.bg:SetShown(show)
    g.topSpec:SetShown(show)
    for _, ln in ipairs(g.borders) do ln:SetShown(show) end
    if not show then
        g.aura:Hide()
        g.bottomBar:Hide()
    end
end

function Theme.OnChanged(fn)
    if type(fn) == "function" then
        themeListeners[#themeListeners + 1] = fn
    end
end

local function NotifyThemeChanged()
    for _, fn in ipairs(themeListeners) do
        pcall(fn)
    end
    if F.NotifyModulesTheme then
        F.NotifyModulesTheme()
    end
end

-- 原生 AnimationGroup 平滑淡入淡出（引擎驱动，零 Lua OnUpdate，绝不污染暴雪 FADEFRAMES）
local fadeGroups = setmetatable({}, { __mode = "k" })

local function CanToggleFrameVis(frame)
    return not (frame.IsProtected and frame:IsProtected() and InCombatLockdown and InCombatLockdown())
end

function Theme.FadeTo(frame, toAlpha, duration, hideAtZero)
    if not (frame and frame.SetAlpha) then return end
    local goal = toAlpha or 1
    local cur = F.PlainNumber(frame.GetAlpha and frame:GetAlpha(), goal)
    local dur = duration or 0.18

    if dur <= 0.01 or not frame.CreateAnimationGroup then
        local ag = fadeGroups[frame]
        if ag and ag:IsPlaying() then ag:Stop() end
        frame:SetAlpha(goal)
        if hideAtZero and goal <= 0.001 and CanToggleFrameVis(frame) then frame:Hide() end
        return
    end

    local ag = fadeGroups[frame]
    if not ag then
        ag = frame:CreateAnimationGroup()
        ag._fuiFade = true
        ag.anim = ag:CreateAnimation("Alpha")
        ag:SetScript("OnFinished", function(self)
            frame:SetAlpha(self.target or 1)
            if self.hideAtZero and (self.target or 1) <= 0.001 and CanToggleFrameVis(frame) then
                frame:Hide()
            end
        end)
        fadeGroups[frame] = ag
    end

    if ag:IsPlaying() then
        local prog = (ag.anim and ag.anim.GetSmoothProgress and ag.anim:GetSmoothProgress())
            or (ag.GetProgress and ag:GetProgress()) or 0
        if ag._from and ag._to then
            cur = ag._from + (ag._to - ag._from) * prog
        end
        ag:Stop()
        frame:SetAlpha(cur)
    end
    ag.target = goal
    ag.hideAtZero = hideAtZero == true
    if goal > 0 and not frame:IsShown() then
        if CanToggleFrameVis(frame) then
            frame:SetAlpha(0)
            cur = 0
            frame:Show()
        else
            frame:SetAlpha(goal)
            return
        end
    end
    if math_abs(cur - goal) < 0.015 then
        frame:SetAlpha(goal)
        if hideAtZero and goal <= 0.001 and CanToggleFrameVis(frame) then frame:Hide() end
        return
    end
    ag._from = cur
    ag._to = goal
    ag.anim:SetFromAlpha(cur)
    ag.anim:SetToAlpha(goal)
    ag.anim:SetDuration(dur)
    ag.anim:SetSmoothing(goal > cur and "OUT" or "IN")
    ag:Play()
end

-- 共用 PrettyTooltip 同款黑曜石渐变 + 外柔光晕 + 顶光带卡片材质覆层（零侵入、零污染、可复用）
local prettyOverlays = setmetatable({}, { __mode = "k" })
local PTIP_GLOW = "Interface\\AddOns\\PrettyTooltip\\art\\glow"

function Theme.EnsurePrettyCardOverlay(host)
    if not host then return nil end
    local ov = prettyOverlays[host]
    if ov then return ov end
    ov = CreateFrame("Frame", nil, host)
    ov:SetAllPoints(host)
    local lvl = F.PlainNumber(host.GetFrameLevel and host:GetFrameLevel(), 200)
    ov:SetFrameLevel(math_max(1, lvl - 1))
    ov:EnableMouse(false)

    -- 1) 外发光柔光晕（优先复用 PrettyTooltip\art\glow，未装时降级至内置 glowTex）
    if F.IsAddOnLoaded("PrettyTooltip") then
        local halo = ov:CreateTexture(nil, "BACKGROUND", nil, -8)
        halo:SetPoint("TOPLEFT", ov, "TOPLEFT", -14, 14)
        halo:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 14, -14)
        halo:SetTexture(PTIP_GLOW)
        if halo.SetTextureSliceMargins then
            pcall(halo.SetTextureSliceMargins, halo, 24, 24, 24, 24)
        end
        halo:SetBlendMode("ADD")
        ov._halo = halo
        ov._haloPTip = true
    elseif _G.BackdropTemplateMixin then
        local shadow = CreateFrame("Frame", nil, ov, "BackdropTemplate")
        shadow:SetPoint("TOPLEFT", ov, "TOPLEFT", -4, 4)
        shadow:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 4, -4)
        shadow:SetFrameLevel(math_max(0, ov:GetFrameLevel() - 1))
        shadow:EnableMouse(false)
        pcall(shadow.SetBackdrop, shadow, { edgeFile = F.MEDIA .. "Textures\\glowTex", edgeSize = 5 })
        pcall(shadow.SetBackdropBorderColor, shadow, 0, 0, 0, 0.65)
        ov._haloPTip = false
    end

    -- 2) 深黑曜石纵向微渐变底板 + 细腻暗纹
    local bg = ov:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 1)
    ov._bg = bg

    local grain = ov:CreateTexture(nil, "BACKGROUND", nil, -6)
    grain:SetAllPoints()
    grain:SetTexture(F.MEDIA .. "Textures\\bgTex", true, true)
    if grain.SetHorizTile then grain:SetHorizTile(true) end
    if grain.SetVertTile then grain:SetVertTile(true) end
    grain:SetBlendMode("ADD")
    grain:SetAlpha(0.24)
    ov._grain = grain

    -- 3) 顶部标题区柔和染色渐变带
    local header = ov:CreateTexture(nil, "BORDER", nil, 0)
    header:SetHeight(24)
    header:SetPoint("TOPLEFT", ov, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", ov, "TOPRIGHT", -1, -1)
    header:SetTexture(Theme.FLAT_TEX)
    ov._header = header

    -- 4) 四周内收微暗边阴影
    if _G.CreateColor then
        local function makeShade(orient, from, to, a1, a2, w, h)
            local sh = ov:CreateTexture(nil, "BORDER", nil, 2)
            sh:SetColorTexture(1, 1, 1, 1)
            sh:SetPoint(from, ov, from)
            sh:SetPoint(to, ov, to)
            if w then sh:SetWidth(w) end
            if h then sh:SetHeight(h) end
            pcall(sh.SetGradient, sh, orient, _G.CreateColor(0, 0, 0, a1), _G.CreateColor(0, 0, 0, a2))
            return sh
        end
        makeShade("VERTICAL", "TOPLEFT", "TOPRIGHT", 0, 0.28, nil, 8)
        makeShade("VERTICAL", "BOTTOMLEFT", "BOTTOMRIGHT", 0.42, 0, nil, 8)
        makeShade("HORIZONTAL", "TOPLEFT", "BOTTOMLEFT", 0.30, 0, 6, nil)
        makeShade("HORIZONTAL", "TOPRIGHT", "BOTTOMRIGHT", 0, 0.30, 6, nil)
    end

    -- 5) 2px 顶边高亮 + 1px 其余三边柔和描边
    local edges = {}
    local specs = {
        { "TOPLEFT", "TOPRIGHT", nil, 2 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil },
        { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }
    for i, sp in ipairs(specs) do
        local ln = ov:CreateTexture(nil, "OVERLAY")
        ln:SetTexture(Theme.FLAT_TEX)
        ln:SetPoint(sp[1], ov, sp[1])
        ln:SetPoint(sp[2], ov, sp[2])
        if sp[3] then ln:SetWidth(sp[3]) end
        if sp[4] then ln:SetHeight(sp[4]) end
        edges[i] = ln
    end
    ov._edges = edges

    prettyOverlays[host] = ov
    return ov
end

function Theme.PaintPrettyCardOverlay(host, r, g, b, headerMaxH)
    local ov = Theme.EnsurePrettyCardOverlay(host)
    if not ov then return nil end
    if not (r and g and b) then
        r, g, b = Theme.GetAccent()
    end
    local lvl = F.PlainNumber(host.GetFrameLevel and host:GetFrameLevel(), 200)
    ov:SetFrameLevel(math_max(1, lvl - 1))

    if scratchC1 and ov._bg.SetGradient then
        SetScratchGradient(ov._bg, "VERTICAL",
            0.016 + r * 0.02, 0.012 + g * 0.02, 0.016 + b * 0.02, 0.94,
            0.052 + r * 0.06, 0.040 + g * 0.06, 0.050 + b * 0.06, 0.94)
        SetScratchGradient(ov._header, "VERTICAL",
            r * 0.06, g * 0.06, b * 0.06, 0.00,
            r * 0.36, g * 0.36, b * 0.36, 0.56)
    else
        ov._bg:SetColorTexture(0.042, 0.046, 0.058, 0.95)
        ov._header:SetColorTexture(r * 0.22, g * 0.22, b * 0.22, 0.50)
    end

    if ov._haloPTip and ov._halo then
        ov._halo:SetVertexColor(r, g, b, 0.28)
    end
    local h = F.PlainNumber(host.GetHeight and host:GetHeight(), 40)
    ov._header:SetHeight(math_max(12, math_min(headerMaxH or 32, h - 2)))
    for i, ln in ipairs(ov._edges) do
        local strength = (i == 1) and 0.80 or 0.36
        ln:SetVertexColor(r * strength, g * strength, b * strength, 0.95)
    end
    ov:Show()
    return ov
end

function Theme.HidePrettyCardOverlay(host)
    local ov = host and prettyOverlays[host]
    if ov then ov:Hide() end
end

-- 战斗自动淡出管理器：非核心条进战自动柔和淡出，悬停立刻恢复
local fadeEntries = {}
local fadeByFrame = setmetatable({}, { __mode = "k" })
local fadeInCombat = false
local fadeFrame = CreateFrame("Frame")
fadeFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
fadeFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local function IsFadeCombat()
    return fadeInCombat or (InCombatLockdown and InCombatLockdown()) or false
end

local function ApplyFade(entry, hover)
    local frame = entry.frame
    if not (frame and frame:IsShown()) then
        return
    end
    local enabled = entry.isEnabled()
    local normal = entry.normalAlpha or 1
    local cur = F.PlainNumber(frame:GetAlpha(), normal)
    if not enabled then
        -- 关闭战斗淡出时若当前已为常规透明度，零开销直接跳过，不创建动画与回调
        if math_abs(cur - normal) < 0.015 then
            return
        end
        Theme.FadeTo(frame, normal, 0)
        return
    end
    local mouseOver = hover or (frame.IsMouseOver and frame:IsMouseOver())
    local target = normal
    if IsFadeCombat() and not mouseOver then
        target = entry.combatAlpha or 0.18
    end
    if math_abs(cur - target) < 0.015 then
        return
    end
    Theme.FadeTo(frame, target, target > cur and 0.16 or 0.24)
end

fadeFrame:SetScript("OnEvent", function(_, event)
    fadeInCombat = (event == "PLAYER_REGEN_DISABLED")
    for _, entry in ipairs(fadeEntries) do
        if entry.isEnabled() then
            ApplyFade(entry, entry.hovered)
        end
    end
end)

function Theme.AttachCombatFade(frame, isEnabledFn, combatAlpha, normalAlpha)
    if not frame then
        return
    end
    local existing = fadeByFrame[frame]
    if existing then
        if isEnabledFn then existing.isEnabled = isEnabledFn end
        if combatAlpha then existing.combatAlpha = combatAlpha end
        if normalAlpha then existing.normalAlpha = normalAlpha end
        ApplyFade(existing, existing.hovered)
        return existing.updater
    end
    local entry = {
        frame = frame,
        isEnabled = isEnabledFn or function() return false end,
        combatAlpha = combatAlpha or 0.18,
        normalAlpha = normalAlpha or 1.0,
        hovered = false,
    }
    fadeEntries[#fadeEntries + 1] = entry
    fadeByFrame[frame] = entry
    frame:HookScript("OnEnter", function()
        entry.hovered = true
        if entry.isEnabled() then
            ApplyFade(entry, true)
        end
    end)
    frame:HookScript("OnLeave", function()
        if not entry.isEnabled() then
            entry.hovered = false
            return
        end
        -- 延迟 0.06s 检查 IsMouseOver，避免鼠标移到子按钮上时闪烁淡出
        if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0.06, function()
                if frame and frame.IsMouseOver and frame:IsMouseOver() then
                    entry.hovered = true
                    ApplyFade(entry, true)
                else
                    entry.hovered = false
                    ApplyFade(entry, false)
                end
            end)
        else
            entry.hovered = false
            ApplyFade(entry, false)
        end
    end)
    entry.updater = function(newCombatAlpha, newNormalAlpha)
        if newCombatAlpha then entry.combatAlpha = newCombatAlpha end
        if newNormalAlpha then entry.normalAlpha = newNormalAlpha end
        ApplyFade(entry, entry.hovered)
    end
    return entry.updater
end

function Theme.GetSkinAPI()
    return skinAPI
end

-- 通过 EllesmereUI 官方 Skinning API 注册主题联动
local EUI = _G.EllesmereUI
if EUI and EUI.RegisterSkin then
    EUI.RegisterSkin(F.NAME, function(S)
        skinAPI = S
        if S.OnLooksChanged then
            S.OnLooksChanged(NotifyThemeChanged)
        end
        NotifyThemeChanged()
    end)
end
