----------------------------------------------------------------------
--  kkowoUI — Core/Theme.lua
--  现代 MMO 简洁统一视觉系统：实时同步 EllesmereUI 主色、字体与扁平材质
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local pairs, ipairs, pcall, type = pairs, ipairs, pcall, type
local math_abs, math_floor, math_max, math_min = math.abs, math.floor, math.max, math.min
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
    local fs = btn.GetFontString and btn:GetFontString()
    if not fs and btn.CreateFontString and btn.SetFontString then
        fs = btn:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
        fs:SetJustifyH("CENTER")
        fs:SetJustifyV("MIDDLE")
        btn:SetFontString(fs)
    end
    if fs then
        Theme.ApplyFont(fs, fontSize or 12, "", 0.95, 0.95, 0.96, 1)
    end
    if btn.SetPushedTextOffset then
        pcall(btn.SetPushedTextOffset, btn, 0, -1)
    end
end

-- 统一注册弹窗按 Esc 关闭：优先接入 EllesmereUI 退出栈（在 EUI 设置界面上层弹窗时，先关弹窗不误关设置页），
-- 非 EUI 环境下自动回退到暴雪 UISpecialFrames
local escapeRegistered = setmetatable({}, { __mode = "k" })
function Theme.RegisterEscapeClose(frame, onEscape)
    if not frame or escapeRegistered[frame] then
        return
    end
    escapeRegistered[frame] = true
    local eui = _G.EllesmereUI
    if eui and type(eui.RegisterEscapeClose) == "function" then
        pcall(eui.RegisterEscapeClose, frame, {
            notOwned = true,
            onEscape = type(onEscape) == "function" and onEscape or nil,
        })
        return
    end
    local name = frame.GetName and frame:GetName()
    local special = _G.UISpecialFrames
    if type(name) == "string" and name ~= "" and type(special) == "table" then
        for _, existing in ipairs(special) do
            if existing == name then return end
        end
        special[#special + 1] = name
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

-- 半透明「磨砂玻璃」（悬浮提示 / 小地图卡片 / 聊天气泡共用）：
-- 冷灰蓝底色 + 上半部柔和白色光泽（纵向渐变）+ 1px 顶部高光线。
-- 只用纯色与渐变（系统栏玻璃按钮同款写法，游戏里显示可靠）；不再叠平铺颗粒贴图：
-- 颗粒层在 EUI 小部件提示上整片显示成了灰色噪点。
-- opts.noTint：宿主自己已有底色（EUI 提示由 TooltipStyle 加深底色），只叠光泽与高光线。
Theme.FROST_RGB = { 0.045, 0.050, 0.066 }
local frostParts = setmetatable({}, { __mode = "k" })

function Theme.ApplyFrostedGlass(frame, opts)
    if not (frame and frame.CreateTexture) then return nil end
    opts = opts or {}
    local p = frostParts[frame]
    if not p then
        p = {}
        -- 光泽压在宿主底色之上（EUI 提示底色在 BACKGROUND -8 或 0 层）；noTint 模式不创建多余底板纹理
        p.sheen = frame:CreateTexture(nil, "BACKGROUND", nil, 4)
        p.sheen:SetColorTexture(1, 1, 1, 1)
        p.topLine = frame:CreateTexture(nil, "BORDER", nil, 6)
        p.topLine:SetHeight(1)
        frostParts[frame] = p
    end

    local inset = opts.inset or 0
    if not opts.noTint and not p.tint then
        p.tint = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        p.tintInset = nil
    end
    if p.tint and p.tintInset ~= inset then
        p.tintInset = inset
        p.tint:ClearAllPoints()
        p.tint:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
        p.tint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    end
    if p.inset ~= inset then
        p.inset = inset
        p.sheen:ClearAllPoints()
        p.sheen:SetPoint("TOPLEFT", frame, "TOPLEFT", inset + 1, -inset - 1)
        p.sheen:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset - 1, -inset - 1)
        p.sheen:SetPoint("BOTTOM", frame, "CENTER", 0, 0)
        p.topLine:ClearAllPoints()
        p.topLine:SetPoint("TOPLEFT", frame, "TOPLEFT", inset + 1, -inset - 1)
        p.topLine:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -inset - 1, -inset - 1)
    end

    if opts.noTint then
        if p.tint then p.tint:Hide() end
    else
        local a = math_max(0, math_min(1, opts.alpha or 0.84))
        local c = Theme.FROST_RGB
        p.tint:SetColorTexture(c[1], c[2], c[3], a)
        p.tint:Show()
    end
    -- VERTICAL：第一色 = 底部（透明），第二色 = 顶部（淡白）；渐变不可用时干脆不画光泽
    if SetScratchGradient(p.sheen, "VERTICAL", 1, 1, 1, 0, 1, 1, 1, opts.sheen or 0.06) then
        p.sheen:Show()
    else
        p.sheen:Hide()
    end
    p.topLine:SetColorTexture(1, 1, 1, opts.topLine or 0.13)
    p.topLine:Show()
    return p
end

function Theme.IsFrostRegion(frame, region)
    local p = frame and frostParts[frame]
    return p ~= nil and region ~= nil
        and ((p.tint and region == p.tint) or region == p.sheen or region == p.topLine)
end

function Theme.SetFrostedGlassShown(frame, shown)
    local p = frame and frostParts[frame]
    if not p then return end
    if shown == true then
        p.sheen:Show()
        p.topLine:Show()
    else
        if p.tint then p.tint:Hide() end
        p.sheen:Hide()
        p.topLine:Hide()
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

-- 共用 PrettyTooltip 100% 复刻卡片表面（深黑曜石纵向渐变 + 顶色带 + 四周内暗晕 + 2px 顶亮边 + 外柔光）
-- 支持 square（严格复刻 PrettyTooltip 平铺卡）与 rounded（现代 MMO 抗锯齿圆角卡，用于聊天气泡与圆角卡片）
local prettyOverlays = setmetatable({}, { __mode = "k" })
local PTIP_GLOW = "Interface\\AddOns\\PrettyTooltip\\art\\glow"
local EUI_ROUND_DIR = "Interface\\AddOns\\EllesmereUI\\media\\rounded\\"

local function ApplyNineSliceMask(obj, path, radius, wrap)
    if not obj then return end
    if obj.SetBlockingLoadsRequested then
        pcall(obj.SetBlockingLoadsRequested, obj, true)
    end
    if wrap then
        pcall(obj.SetTexture, obj, path, wrap, wrap)
    else
        pcall(obj.SetTexture, obj, path)
    end
    if obj.SetTextureSliceMargins then
        pcall(obj.SetTextureSliceMargins, obj, radius, radius, radius, radius)
    end
    local sm = _G.Enum and _G.Enum.UITextureSliceMode and _G.Enum.UITextureSliceMode.Stretched
    if sm and obj.SetTextureSliceMode then
        pcall(obj.SetTextureSliceMode, obj, sm)
    end
end

local function AddMaskSafe(tex, mask)
    if tex and mask and tex.AddMaskTexture then
        pcall(tex.AddMaskTexture, tex, mask)
    end
end

local function RemoveMaskSafe(tex, mask)
    if tex and mask and tex.RemoveMaskTexture then
        pcall(tex.RemoveMaskTexture, tex, mask)
    end
end

local function HasEUIRoundedMasks()
    return _G.EllesmereUI ~= nil or F.IsAddOnLoaded("EllesmereUI")
end

-- 读取 PrettyTooltipDB 的实时外观参数，确保玩家在 /ptip 中的改动自动同步到所有统一卡片
local function ReadPrettyLiveMetrics()
    local db = _G.PrettyTooltipDB
    local bodyA = 0.94
    local glowA = 0.22
    local headTop = 0.40
    local headBot = 0.00
    if type(db) == "table" then
        local ba = F.PlainNumber(db.backdropAlpha, nil) or F.PlainNumber(db.backdropAlphaItems, nil)
        if ba and ba >= 0.40 and ba <= 1.00 then bodyA = ba end
        local ga = F.PlainNumber(db.glowAlphaItems, nil) or F.PlainNumber(db.glowAlphaUnits, nil)
        if ga and ga >= 0 and ga <= 1.50 then glowA = ga end
        local ht = F.PlainNumber(db.headerTopAlphaItems, nil) or F.PlainNumber(db.headerTopAlphaUnits, nil)
        if ht and ht >= 0 and ht <= 1.00 then headTop = ht end
        local hb = F.PlainNumber(db.headerBottomAlphaItems, nil) or F.PlainNumber(db.headerBottomAlphaUnits, nil)
        if hb and hb >= 0 and hb <= 1.00 then headBot = hb end
    end
    return bodyA, glowA, headTop, headBot
end

local LOWER_STRATA = {
    TOOLTIP           = "FULLSCREEN_DIALOG",
    FULLSCREEN_DIALOG = "FULLSCREEN",
    FULLSCREEN        = "DIALOG",
    DIALOG            = "HIGH",
    HIGH              = "MEDIUM",
    MEDIUM            = "LOW",
    LOW               = "BACKGROUND",
}

local prettyOrderHooked = setmetatable({}, { __mode = "k" })

local function SyncPrettyOverlayOrder(host, ov)
    if not (host and ov) then return end
    if host.IsForbidden and host:IsForbidden() then return end
    local strata = host.GetFrameStrata and F.PlainString(host:GetFrameStrata(), nil) or nil
    local lvl = F.PlainNumber(host.GetFrameLevel and host:GetFrameLevel(), 200) or 200
    if ov.SetFixedFrameStrata then pcall(ov.SetFixedFrameStrata, ov, false) end
    if ov.SetFixedFrameLevel then pcall(ov.SetFixedFrameLevel, ov, false) end
    if lvl >= 1 then
        if strata and ov.SetFrameStrata then pcall(ov.SetFrameStrata, ov, strata) end
        pcall(ov.SetFrameLevel, ov, lvl - 1)
        if ov.SetFixedFrameLevel then pcall(ov.SetFixedFrameLevel, ov, true) end
    else
        local lower = strata and LOWER_STRATA[strata] or nil
        if lower and ov.SetFrameStrata then
            pcall(ov.SetFrameStrata, ov, lower)
            pcall(ov.SetFrameLevel, ov, 9999)
            if ov.SetFixedFrameStrata then pcall(ov.SetFixedFrameStrata, ov, true) end
            if ov.SetFixedFrameLevel then pcall(ov.SetFixedFrameLevel, ov, true) end
        else
            if strata and ov.SetFrameStrata then pcall(ov.SetFrameStrata, ov, strata) end
            pcall(ov.SetFrameLevel, ov, 0)
        end
    end
    if ov._shadowFallback then
        local sh = ov._shadowFallback
        if sh.SetFixedFrameStrata then pcall(sh.SetFixedFrameStrata, sh, false) end
        if sh.SetFixedFrameLevel then pcall(sh.SetFixedFrameLevel, sh, false) end
        local ovStrata = ov.GetFrameStrata and F.PlainString(ov:GetFrameStrata(), nil) or nil
        local ovLvl = F.PlainNumber(ov.GetFrameLevel and ov:GetFrameLevel(), 0) or 0
        if ovStrata and sh.SetFrameStrata then pcall(sh.SetFrameStrata, sh, ovStrata) end
        pcall(sh.SetFrameLevel, sh, math_max(0, ovLvl - 1))
        if sh.SetFixedFrameLevel then pcall(sh.SetFixedFrameLevel, sh, true) end
    end
end

function Theme.EnsurePrettyCardOverlay(host, opts)
    if not host then return nil end
    local ov = prettyOverlays[host]
    if ov then return ov end
    ov = CreateFrame("Frame", nil, host)
    ov:SetAllPoints(host)
    SyncPrettyOverlayOrder(host, ov)
    ov:EnableMouse(false)
    if not prettyOrderHooked[host] and not (host.IsForbidden and host:IsForbidden()) then
        prettyOrderHooked[host] = true
        local function resync(self)
            local cur = prettyOverlays[self]
            if cur then SyncPrettyOverlayOrder(self, cur) end
        end
        if type(host.SetFrameLevel) == "function" then _G.hooksecurefunc(host, "SetFrameLevel", resync) end
        if type(host.SetFrameStrata) == "function" then _G.hooksecurefunc(host, "SetFrameStrata", resync) end
        if host.HookScript and host.HasScript and host:HasScript("OnShow") then
            host:HookScript("OnShow", resync)
        end
    end

    -- 1) 外发光柔光晕（与 PrettyTooltip\Panel\Layout.lua 完全同源：art\glow 9 宫格 + ADD 混合）
    local spread = (opts and opts.haloSpread) or 16
    if F.IsAddOnLoaded("PrettyTooltip") then
        local halo = ov:CreateTexture(nil, "BACKGROUND", nil, -8)
        halo:SetPoint("TOPLEFT", ov, "TOPLEFT", -spread, spread)
        halo:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", spread, -spread)
        halo:SetTexture(PTIP_GLOW)
        if halo.SetTextureSliceMargins then
            pcall(halo.SetTextureSliceMargins, halo, 24, 24, 24, 24)
        end
        halo:SetBlendMode("ADD")
        ov._halo = halo
        ov._haloPTip = true
    elseif _G.BackdropTemplateMixin then
        local shadow = CreateFrame("Frame", nil, ov, "BackdropTemplate")
        shadow:SetPoint("TOPLEFT", ov, "TOPLEFT", -5, 5)
        shadow:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 5, -5)
        shadow:SetFrameLevel(math_max(0, ov:GetFrameLevel() - 1))
        shadow:EnableMouse(false)
        pcall(shadow.SetBackdrop, shadow, { edgeFile = F.MEDIA .. "Textures\\glowTex", edgeSize = 5 })
        pcall(shadow.SetBackdropBorderColor, shadow, 0, 0, 0, 0.65)
        ov._haloPTip = false
        ov._shadowFallback = shadow
    end

    -- 2) 深黑曜石纵向微渐变底板（使用 FLAT_TEX 兼容圆角 MaskTexture，去除原版无的杂纹层以 100% 复刻 PrettyTooltip）
    local bg = ov:CreateTexture(nil, "BACKGROUND", nil, -7)
    if bg.SetBlockingLoadsRequested then pcall(bg.SetBlockingLoadsRequested, bg, true) end
    bg:SetAllPoints()
    bg:SetTexture(Theme.FLAT_TEX)
    ov._bg = bg

    -- 3) 顶部柔和染色渐变带
    local header = ov:CreateTexture(nil, "BORDER", nil, 0)
    if header.SetBlockingLoadsRequested then pcall(header.SetBlockingLoadsRequested, header, true) end
    header:SetHeight(24)
    header:SetPoint("TOPLEFT", ov, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", ov, "TOPRIGHT", -1, -1)
    header:SetTexture(Theme.FLAT_TEX)
    ov._header = header

    -- 4) 四周内收微暗边阴影（与 PrettyTooltip 数值一致：顶 10px 0.30 / 底 10px 0.45 / 左 8px 0.35 / 右 8px 0.35）
    ov._shades = {}
    if _G.CreateColor then
        local function makeShade(orient, from, to, a1, a2, w, h)
            local sh = ov:CreateTexture(nil, "BORDER", nil, 2)
            sh:SetTexture(Theme.FLAT_TEX)
            sh:SetPoint(from, ov, from)
            sh:SetPoint(to, ov, to)
            if w then sh:SetWidth(w) end
            if h then sh:SetHeight(h) end
            pcall(sh.SetGradient, sh, orient, _G.CreateColor(0, 0, 0, a1), _G.CreateColor(0, 0, 0, a2))
            ov._shades[#ov._shades + 1] = sh
            return sh
        end
        makeShade("VERTICAL", "TOPLEFT", "TOPRIGHT", 0, 0.30, nil, 10)
        makeShade("VERTICAL", "BOTTOMLEFT", "BOTTOMRIGHT", 0.45, 0, nil, 10)
        makeShade("HORIZONTAL", "TOPLEFT", "BOTTOMLEFT", 0.35, 0, 8, nil)
        makeShade("HORIZONTAL", "TOPRIGHT", "BOTTOMRIGHT", 0, 0.35, 8, nil)
    end

    -- 5) 直角 2px 顶亮边 + 1px 三边描边（严格复刻 PrettyTooltip 平铺边框）
    local edges = {}
    local specs = {
        { "TOPLEFT", "TOPRIGHT", nil, 2 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
        { "TOPLEFT", "BOTTOMLEFT", 1, nil },
        { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
    }
    for i, sp in ipairs(specs) do
        local ln = ov:CreateTexture(nil, "OVERLAY", nil, 1)
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

local function SyncPrettyRoundedState(ov, rounded, radius)
    local wantRound = (rounded == true) and HasEUIRoundedMasks() and (ov.CreateMaskTexture ~= nil)
    local r = wantRound and math_max(3, math_min(12, radius or 8)) or 0
    if ov._roundRadius == r then return end

    local ST = F.StyleTokens
    local function detach(tex, mask)
        if not (tex and mask) then return end
        if ST and ST.DetachCustomMask then
            ST.DetachCustomMask(tex, mask)
        else
            RemoveMaskSafe(tex, mask)
        end
    end
    local function attach(tex, mask)
        if not (tex and mask) then return end
        if ST and ST.AttachCustomMask then
            ST.AttachCustomMask(ov, tex, mask)
        else
            AddMaskSafe(tex, mask)
        end
    end

    -- 先卸载旧遮罩（若切换半径或切回直角；含内孔反遮罩，否则切半径时圆角孔洞不刷新）
    if ST and ST.CancelBorderHole then ST.CancelBorderHole(ov) end
    if ov._bodyMask then
        detach(ov._bg, ov._bodyMask)
        detach(ov._header, ov._bodyMask)
        for _, sh in ipairs(ov._shades or {}) do detach(sh, ov._bodyMask) end
        if ov._roundBorder then RemoveMaskSafe(ov._roundBorder, ov._bodyMask) end
        if ov._roundTopEdge then detach(ov._roundTopEdge, ov._bodyMask) end
    end
    if ov._roundBorder and ov._roundHole then
        RemoveMaskSafe(ov._roundBorder, ov._roundHole)
    end
    ov._roundHoleReady = false

    ov._roundRadius = r
    if r > 0 then
        local maskPath = EUI_ROUND_DIR .. "rounded-" .. r .. ".tga"
        local holePath = EUI_ROUND_DIR .. "rounded-inv-" .. math_max(1, r - 1) .. ".tga"
        if not ov._bodyMask then
            ov._bodyMask = ov:CreateMaskTexture()
        end
        if ov._bodyMask then
            ApplyNineSliceMask(ov._bodyMask, maskPath, r, "CLAMPTOBLACKADDITIVE")
            ov._bodyMask:SetAllPoints(ov)
            attach(ov._bg, ov._bodyMask)
            attach(ov._header, ov._bodyMask)
            for _, sh in ipairs(ov._shades or {}) do attach(sh, ov._bodyMask) end
        end

        if not ov._roundBorder then
            local rb = ov:CreateTexture(nil, "OVERLAY", nil, 1)
            if rb.SetBlockingLoadsRequested then pcall(rb.SetBlockingLoadsRequested, rb, true) end
            rb:SetAllPoints(ov)
            rb:SetTexture(Theme.FLAT_TEX)
            ov._roundBorder = rb
            ov._roundHole = ov:CreateMaskTexture()
        end
        if ov._roundBorder and ov._bodyMask and ov._roundHole then
            ApplyNineSliceMask(ov._roundHole, holePath, math_max(1, r - 1), "CLAMPTOWHITE")
            ov._roundHole:ClearAllPoints()
            ov._roundHole:SetPoint("TOPLEFT", ov, "TOPLEFT", 1, -1)
            ov._roundHole:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", -1, 1)
            if ST and ST.AttachBorderHole then
                ST.AttachBorderHole(ov, ov._roundBorder, ov._roundHole, ov._bodyMask, ov, function()
                    ov._roundHoleReady = true
                end)
            else
                AddMaskSafe(ov._roundBorder, ov._bodyMask)
                AddMaskSafe(ov._roundBorder, ov._roundHole)
                ov._roundHoleReady = true
                ov._roundBorder:Show()
            end
            for _, ln in ipairs(ov._edges) do ln:Hide() end
            -- 顶部柔和亮色圆角呼应条（保留 PrettyTooltip 顶部亮边基因）
            if not ov._roundTopEdge then
                local te = ov:CreateTexture(nil, "OVERLAY", nil, 2)
                if te.SetBlockingLoadsRequested then pcall(te.SetBlockingLoadsRequested, te, true) end
                te:SetPoint("TOPLEFT", ov, "TOPLEFT", 0, 0)
                te:SetPoint("TOPRIGHT", ov, "TOPRIGHT", 0, 0)
                te:SetHeight(2)
                te:SetTexture(Theme.FLAT_TEX)
                ov._roundTopEdge = te
            end
            attach(ov._roundTopEdge, ov._bodyMask)
            ov._roundTopEdge:Show()
            return
        end
    end

    if ov._roundBorder then ov._roundBorder:Hide() end
    if ov._roundTopEdge then ov._roundTopEdge:Hide() end
    for _, ln in ipairs(ov._edges) do ln:Show() end
end

function Theme.PaintPrettyCardOverlay(host, r, g, b, headerMaxH, opts)
    opts = opts or {}
    local ov = Theme.EnsurePrettyCardOverlay(host, opts)
    if not ov then return nil end
    if not (r and g and b) then
        r, g, b = Theme.GetAccent()
    end
    SyncPrettyOverlayOrder(host, ov)

    local defRound = true
    local defRadius = 8
    local tsMod = F.Modules and F.Modules.Get and F.Modules.Get("tooltipStyle")
    if tsMod then
        local tsDB = tsMod:GetDB()
        if tsDB and tsDB.roundedPrettyTips == false then
            defRound = false
        end
        local tr = tsDB and F.PlainNumber(tsDB.roundedRadius, nil) or nil
        if tr and tr >= 0 then defRadius = math_floor(tr + 0.5) end
    end
    local wantRound
    if opts.rounded ~= nil then
        wantRound = (opts.rounded == true)
    else
        wantRound = (defRound and defRadius > 0)
    end
    local wantRadius = opts.radius or defRadius
    SyncPrettyRoundedState(ov, wantRound, wantRadius)

    local defBody, defGlow, defHeadTop, defHeadBot = ReadPrettyLiveMetrics()
    local bodyA = opts.alpha or defBody
    local strength = opts.strength or 1
    local glowA = opts.haloAlpha or (0.55 * strength * defGlow)
    local headTop = opts.headerTopAlpha or defHeadTop
    local headBot = opts.headerBottomAlpha or defHeadBot

    if scratchC1 and ov._bg.SetGradient then
        SetScratchGradient(ov._bg, "VERTICAL",
            0.016 + r * 0.02 * strength, 0.012 + g * 0.02 * strength, 0.016 + b * 0.02 * strength, bodyA,
            0.052 + r * 0.06 * strength, 0.040 + g * 0.06 * strength, 0.050 + b * 0.06 * strength, bodyA)
        SetScratchGradient(ov._header, "VERTICAL",
            r * 0.12, g * 0.12, b * 0.12, headBot,
            r * 0.38, g * 0.38, b * 0.38, headTop)
    else
        ov._bg:SetVertexColor(0.036, 0.032, 0.040, bodyA)
        ov._header:SetVertexColor(r * 0.25, g * 0.25, b * 0.25, headTop * 0.8)
    end

    if ov._haloPTip and ov._halo then
        local sp = opts.haloSpread or 16
        ov._halo:ClearAllPoints()
        ov._halo:SetPoint("TOPLEFT", ov, "TOPLEFT", -sp, sp)
        ov._halo:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", sp, -sp)
        ov._halo:SetVertexColor(r, g, b, math_max(0, math_min(0.60, glowA)))
        ov._halo:SetShown(glowA > 0.005)
    end

    local h = F.PlainNumber(host.GetHeight and host:GetHeight(), 40)
    local hdrH = math_max(8, math_min(headerMaxH or 30, math_max(8, h - 2)))
    ov._header:SetHeight(hdrH)

    if ov._roundRadius and ov._roundRadius > 0 and ov._roundBorder then
        ov._roundBorder:SetVertexColor(r * 0.46 + 0.08, g * 0.46 + 0.08, b * 0.46 + 0.08, 0.88)
        if ov._roundTopEdge then
            ov._roundTopEdge:SetVertexColor(r * 0.82, g * 0.82, b * 0.82, 0.72)
        end
    else
        for i, ln in ipairs(ov._edges) do
            local edgeStr = (i == 1) and 0.80 or 0.36
            ln:SetVertexColor(r * edgeStr, g * edgeStr, b * edgeStr, 0.95)
        end
    end
    ov:Show()
    return ov
end

function Theme.HidePrettyCardOverlay(host)
    local ov = host and prettyOverlays[host]
    if ov then ov:Hide() end
end

function Theme.IsPrettyOverlayRegion(host, region)
    local ov = host and prettyOverlays[host]
    return ov ~= nil and region == ov
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
    local ag = fadeGroups[frame]
    local playing = ag and ag:IsPlaying()
    if not enabled then
        -- 关闭战斗淡出时若当前已为常规透明度且无残留动画，零开销直接跳过，不创建动画与回调
        if not playing and math_abs(cur - normal) < 0.015 then
            return
        end
        Theme.FadeTo(frame, normal, 0)
        return
    end
    local hf = entry.hoverFrame or frame
    local mouseOver = hover or (hf and hf.IsMouseOver and hf:IsMouseOver())
        or (hf ~= frame and frame.IsMouseOver and frame:IsMouseOver())
    local target = normal
    if IsFadeCombat() and not mouseOver then
        target = entry.combatAlpha or 0.18
    end
    if not playing and math_abs(cur - target) < 0.015 then
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

function Theme.AttachCombatFade(frame, isEnabledFn, combatAlpha, normalAlpha, hoverFrame)
    if not frame then
        return
    end
    local existing = fadeByFrame[frame]
    if existing then
        if isEnabledFn then existing.isEnabled = isEnabledFn end
        if combatAlpha then existing.combatAlpha = combatAlpha end
        if normalAlpha then existing.normalAlpha = normalAlpha end
        if hoverFrame then existing.hoverFrame = hoverFrame end
        ApplyFade(existing, existing.hovered)
        return existing.updater
    end
    local hf = hoverFrame or frame
    local entry = {
        frame = frame,
        hoverFrame = hf,
        isEnabled = isEnabledFn or function() return false end,
        combatAlpha = combatAlpha or 0.18,
        normalAlpha = normalAlpha or 1.0,
        hovered = false,
    }
    fadeEntries[#fadeEntries + 1] = entry
    fadeByFrame[frame] = entry
    hf:HookScript("OnEnter", function()
        entry.hovered = true
        if entry.isEnabled() then
            ApplyFade(entry, true)
        end
    end)
    hf:HookScript("OnLeave", function()
        if not entry.isEnabled() then
            entry.hovered = false
            return
        end
        -- 延迟 0.06s 检查 IsMouseOver，避免鼠标移到子按钮上时闪烁淡出
        if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0.06, function()
                local over = (hf and hf.IsMouseOver and hf:IsMouseOver())
                    or (frame and frame.IsMouseOver and frame:IsMouseOver())
                if over then
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
