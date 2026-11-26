----------------------------------------------------------------------
--  kkowoUI — Core/StyleTokens.lua
--  统一视觉 Token、全职业横向渐变色表、GPU 9 宫格圆角遮罩与战斗队列封装
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local math_floor, math_max, math_min, pairs, pcall, setmetatable, type =
    math.floor, math.max, math.min, pairs, pcall, setmetatable, type
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown

local ST = {}
F.StyleTokens = ST

ST.TEX = {
    FLAT         = "Interface\\Buttons\\WHITE8x8",
    PILL_MASK    = F.MEDIA .. "Textures\\BarPillMask.tga",
    PILL_RIM     = F.MEDIA .. "Textures\\BarPillRim.tga",
    PILL_MASK_6  = F.MEDIA .. "Textures\\BarPillMask6.tga",
    PILL_RIM_6   = F.MEDIA .. "Textures\\BarPillRim6.tga",
    CIRCLE_MASK  = F.MEDIA .. "Textures\\CircleMask.tga",
    CIRCLE_RING  = F.MEDIA .. "Textures\\CircleRing.tga",
    CIRCLE_ARC   = F.MEDIA .. "Textures\\CircleArcGlow.tga",
    SPARK_BLADE  = F.MEDIA .. "Textures\\SparkBlade.tga",
    SOFT_GLOW    = F.MEDIA .. "Textures\\SoftGlow.tga",
    VIGNETTE     = F.MEDIA .. "Textures\\VignetteEdge.tga",
    DIAG_STRIPES = F.MEDIA .. "Textures\\DiagStripes.tga",
    LOGO_FLAT    = F.MEDIA .. "Icons\\kkowoUI.tga",
}

local EUI_ROUND_DIR = "Interface\\AddOns\\EllesmereUI\\media\\rounded\\"

ST.COLORS = {
    brand       = { 0.322, 0.839, 0.412, 1.00 }, -- 青草绿 #52D669
    track       = { 0.045, 0.050, 0.065, 0.88 },
    trackDeep   = { 0.030, 0.034, 0.046, 0.92 },
    border      = { 0.020, 0.022, 0.030, 0.96 },
    borderLight = { 0.240, 0.260, 0.310, 0.85 },
    trail       = { 0.960, 0.880, 0.880, 0.72 },
    latency     = { 0.960, 0.580, 0.450, 0.86 },
    interrupt   = { 0.920, 0.220, 0.260, 0.96 },
    channel     = { 0.280, 0.820, 0.680, 1.00 },
    aimGo       = { 0.360, 0.860, 0.560, 0.92 },
    aimStill    = { 0.980, 0.780, 0.280, 0.94 },
    aimClip     = { 0.940, 0.340, 0.380, 0.92 },
    combatIn    = { 0.960, 0.360, 0.380, 1.00 },
    combatOut   = { 0.340, 0.880, 0.700, 1.00 },
    vignette    = { 0.780, 0.060, 0.090, 1.00 },
    -- 语义强调色（统一规则）：战斗 HUD 用职业色；信息卡片 / 提示类用 info 青绿；
    -- positive 只表示「正面状态」（已附魔、增益、满耐久）；hostile 用于敌对玩家红名
    info        = { 0.440, 0.900, 0.920, 1.00 },
    positive    = { 0.360, 0.920, 0.560, 1.00 },
    hostile     = { 1.000, 0.300, 0.300, 1.00 },
    -- 全 UI 共用的「清透玻璃」底色：比全透明略深，能看清文字又不挡场景
    glass       = { 0.040, 0.046, 0.062, 0.24 },
}

-- 字号三档：说明 / 正文 / 标题（数值大字另用 value）
ST.FONT = { caption = 10, body = 12, title = 14, value = 16 }

-- 条内 / 卡片文字统一排版：无硬描边 + 1px 柔和投影（叠在亮色渐变条上依旧锐利，
-- OUTLINE + 投影两层叠加会把中文字形糊成一团）
function ST.ApplyText(fs, size, r, g, b, a)
    if not fs then return end
    F.Theme.ApplyFont(fs, size or ST.FONT.body, "", r or 0.96, g or 0.97, b or 0.99, a or 1)
    if fs.SetShadowColor then
        fs:SetShadowColor(0, 0, 0, 0.78)
        fs:SetShadowOffset(1, -1)
    end
end

-- 全职业双端横向渐变色表：
--   bright = 左职业本色 -> 右向柔和亮白高光过渡（通透现代）
--   dark   = 左深沉暗职业基调 -> 右标准职业亮色（沉稳暗黑）
local CLASS_GRADIENTS = {
    HUNTER      = {
        bright = { 0.34, 0.68, 0.30,  0.76, 0.96, 0.68 },
        dark   = { 0.16, 0.38, 0.16,  0.60, 0.84, 0.45 },
    },
    MAGE        = {
        bright = { 0.20, 0.62, 0.86,  0.84, 0.95, 1.00 },
        dark   = { 0.10, 0.34, 0.58,  0.34, 0.78, 0.96 },
    },
    ROGUE       = {
        bright = { 0.84, 0.62, 0.22,  1.00, 0.93, 0.66 },
        dark   = { 0.48, 0.34, 0.10,  0.98, 0.86, 0.36 },
    },
    WARRIOR     = {
        bright = { 0.64, 0.42, 0.28,  0.94, 0.78, 0.62 },
        dark   = { 0.36, 0.22, 0.14,  0.78, 0.58, 0.42 },
    },
    PRIEST      = {
        bright = { 0.70, 0.74, 0.82,  0.98, 0.99, 1.00 },
        dark   = { 0.42, 0.46, 0.54,  0.92, 0.94, 0.98 },
    },
    WARLOCK     = {
        bright = { 0.46, 0.32, 0.74,  0.84, 0.74, 1.00 },
        dark   = { 0.26, 0.16, 0.46,  0.64, 0.50, 0.90 },
    },
    PALADIN     = {
        bright = { 0.86, 0.44, 0.62,  1.00, 0.82, 0.90 },
        dark   = { 0.52, 0.22, 0.36,  0.96, 0.58, 0.74 },
    },
    SHAMAN      = {
        bright = { 0.12, 0.42, 0.84,  0.56, 0.82, 1.00 },
        dark   = { 0.06, 0.22, 0.52,  0.22, 0.58, 0.96 },
    },
    DRUID       = {
        bright = { 0.86, 0.42, 0.12,  1.00, 0.78, 0.44 },
        dark   = { 0.50, 0.22, 0.06,  0.98, 0.54, 0.18 },
    },
    DEATHKNIGHT = {
        bright = { 0.70, 0.16, 0.24,  0.98, 0.54, 0.58 },
        dark   = { 0.40, 0.08, 0.12,  0.82, 0.22, 0.30 },
    },
    MONK        = {
        bright = { 0.12, 0.74, 0.52,  0.64, 0.98, 0.84 },
        dark   = { 0.06, 0.42, 0.30,  0.18, 0.88, 0.62 },
    },
    DEMONHUNTER = {
        bright = { 0.58, 0.20, 0.74,  0.90, 0.64, 1.00 },
        dark   = { 0.32, 0.10, 0.44,  0.72, 0.32, 0.88 },
    },
    EVOKER      = {
        bright = { 0.18, 0.58, 0.52,  0.62, 0.94, 0.86 },
        dark   = { 0.10, 0.34, 0.30,  0.28, 0.72, 0.64 },
    },
}

-- 主资源类型渐变（蓝/怒气/集中/能量/符能等）
local POWER_GRADIENTS = {
    [0] = { -- MANA
        bright = { 0.18, 0.50, 0.88,  0.64, 0.88, 1.00 },
        dark   = { 0.10, 0.28, 0.58,  0.28, 0.66, 0.98 },
    },
    [1] = { -- RAGE
        bright = { 0.78, 0.20, 0.22,  0.98, 0.56, 0.44 },
        dark   = { 0.44, 0.10, 0.12,  0.88, 0.28, 0.28 },
    },
    [2] = { -- FOCUS
        bright = { 0.82, 0.46, 0.18,  1.00, 0.80, 0.48 },
        dark   = { 0.48, 0.24, 0.08,  0.94, 0.58, 0.24 },
    },
    [3] = { -- ENERGY
        bright = { 0.86, 0.64, 0.18,  1.00, 0.92, 0.58 },
        dark   = { 0.50, 0.36, 0.08,  0.98, 0.82, 0.28 },
    },
    [6] = { -- RUNIC_POWER
        bright = { 0.12, 0.64, 0.82,  0.66, 0.95, 1.00 },
        dark   = { 0.06, 0.36, 0.50,  0.22, 0.82, 0.96 },
    },
}

local REACTION_GRADIENTS = {
    hostile  = { 0.78, 0.24, 0.28,  0.96, 0.52, 0.54 },
    neutral  = { 0.82, 0.64, 0.22,  0.98, 0.86, 0.48 },
    friendly = { 0.26, 0.72, 0.42,  0.62, 0.94, 0.70 },
}

-- 全局设置读取（未建档前自动回退合理默认）
function ST.GetMotionDB()
    if F.Modules and F.Modules.Get then
        local m = F.Modules.Get("motionFX")
        if m then return m:GetDB() end
    end
    return nil
end

function ST.IsMasterEnabled()
    local db = ST.GetMotionDB()
    return (not db) or (db.enabled ~= false)
end

function ST.GetGradientMode()
    local db = ST.GetMotionDB()
    return (db and db.gradientStyle) or "bright"
end

function ST.GetCornerRadius(fallback)
    local db = ST.GetMotionDB()
    local r = db and F.PlainNumber(db.cornerRadius, nil) or nil
    if r == nil then return fallback or 6 end
    return math_max(0, math_min(12, math_floor(r + 0.5)))
end

function ST.GetClassGradient(classToken, mode)
    local cls = classToken or F.GetPlayerClass()
    local m = mode or ST.GetGradientMode()
    local entry = CLASS_GRADIENTS[cls]
    if entry then
        local g = entry[m] or entry.bright
        return g[1], g[2], g[3], g[4], g[5], g[6]
    end
    local r, g, b = F.Theme.GetAccent()
    if m == "dark" then
        return r * 0.5, g * 0.5, b * 0.5, r, g, b
    end
    return r * 0.85, g * 0.85, b * 0.85, math_min(1, r * 0.45 + 0.55), math_min(1, g * 0.45 + 0.55), math_min(1, b * 0.45 + 0.55)
end

function ST.GetPowerGradient(powerType, mode)
    local pt = F.PlainNumber(powerType, 0) or 0
    local m = mode or ST.GetGradientMode()
    local entry = POWER_GRADIENTS[pt]
    if entry then
        local g = entry[m] or entry.bright
        return g[1], g[2], g[3], g[4], g[5], g[6]
    end
    return ST.GetClassGradient(nil, m)
end

function ST.GetUnitGradient(unit, mode)
    if not unit then
        return ST.GetClassGradient(nil, mode)
    end
    local okP, isPlayer = pcall(_G.UnitIsPlayer, unit)
    if okP and not F.IsSecret(isPlayer) and isPlayer then
        local okC, _, cls = pcall(_G.UnitClass, unit)
        if okC and not F.IsSecret(cls) and cls then
            return ST.GetClassGradient(cls, mode)
        end
    end
    local okR, react = pcall(_G.UnitReaction, unit, "player")
    react = okR and F.PlainNumber(react, nil) or nil
    local g
    if react and react <= 3 then
        g = REACTION_GRADIENTS.hostile
    elseif react == 4 then
        g = REACTION_GRADIENTS.neutral
    elseif react and react >= 5 then
        g = REACTION_GRADIENTS.friendly
    else
        g = REACTION_GRADIENTS.hostile
    end
    return g[1], g[2], g[3], g[4], g[5], g[6]
end

-- 零 GC 复用 Color 对象，安全应用水平/垂直渐变
local c1 = _G.CreateColor and _G.CreateColor(1, 1, 1, 1) or nil
local c2 = _G.CreateColor and _G.CreateColor(1, 1, 1, 1) or nil

function ST.ApplyGradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    if not tex then return false end
    if c1 and c2 and tex.SetGradient then
        c1:SetRGBA(r1, g1, b1, a1 or 1)
        c2:SetRGBA(r2, g2, b2, a2 or 1)
        local ok = pcall(tex.SetGradient, tex, orient or "HORIZONTAL", c1, c2)
        if ok then return true end
    end
    if tex.SetVertexColor then
        pcall(tex.SetVertexColor, tex, (r1 + r2) * 0.5, (g1 + g2) * 0.5, (b1 + b2) * 0.5, a1 or 1)
    end
    return false
end

function ST.ApplyBarGradient(statusBar, r1, g1, b1, r2, g2, b2, alpha, reverse)
    if not statusBar then return end
    local tex = statusBar.GetStatusBarTexture and statusBar:GetStatusBarTexture() or nil
    if not tex then return end
    local a = alpha or 1
    if reverse then
        ST.ApplyGradient(tex, "HORIZONTAL", r2, g2, b2, a, r1, g1, b1, a)
    else
        ST.ApplyGradient(tex, "HORIZONTAL", r1, g1, b1, a, r2, g2, b2, a)
    end
end

-- 物理 1:1 像素对齐系数与整像素吸附
local function GetPerfectScale()
    local EUI = _G.EllesmereUI
    if EUI and EUI.PP and type(EUI.PP.perfect) == "number" and EUI.PP.perfect > 0 then
        return EUI.PP.perfect
    end
    local ph = nil
    if _G.GetPhysicalScreenSize then
        local _, h = _G.GetPhysicalScreenSize()
        ph = h
    end
    ph = F.PlainNumber(ph, 1080) or 1080
    if ph <= 0 then ph = 1080 end
    return 768 / ph
end

function ST.GetPixel(frame)
    local perfect = GetPerfectScale()
    local sc = nil
    if frame and frame.GetEffectiveScale then
        local ok, es = pcall(frame.GetEffectiveScale, frame)
        if ok then sc = F.PlainNumber(es, nil) end
    end
    if not sc or sc <= 0 then
        local EUI = _G.EllesmereUI
        if EUI and EUI.PP and type(EUI.PP.mult) == "number" and EUI.PP.mult > 0 then
            return EUI.PP.mult
        end
        sc = _G.UIParent and F.PlainNumber(_G.UIParent:GetScale(), 1) or 1
    end
    if sc <= 0 then sc = 1 end
    return perfect / sc
end

function ST.Snap(v)
    local px = ST.GetPixel()
    return math_floor(v / px + 0.5) * px
end

-- 1 物理像素细线：按宿主有效缩放算出恰好 1 物理像素的粗细，并关闭像素吸附，
-- 非整数 UI 缩放下也不会发虚或忽粗忽细。vertical = true 时设置宽度，否则设置高度。
function ST.Hairline(tex, vertical)
    if not tex then return end
    local px = ST.GetPixel(tex.GetParent and tex:GetParent() or nil)
    if vertical then tex:SetWidth(px) else tex:SetHeight(px) end
    local PP = _G.EllesmereUI and _G.EllesmereUI.PP
    if PP and PP.DisablePixelSnap then
        pcall(PP.DisablePixelSnap, tex)
    elseif tex.SetSnapToPixelGrid then
        pcall(tex.SetSnapToPixelGrid, tex, false)
        if tex.SetTexelSnappingBias then pcall(tex.SetTexelSnappingBias, tex, 0) end
    end
end

-- GPU 9 宫格物理像素级圆角遮罩与 1px 同心抗锯齿细描边
-- （复用 EllesmereUI/media/rounded 1~16px 资产，border 运行于 1:1 物理像素层 + 整像素边吸附 +
--  正文遮罩内缩 1px 杜绝高光色渗透黑边形成毛边/锯齿；每次改半径前严格先分离再重绑，弱表零污染）
local roundState = setmetatable({}, { __mode = "k" })
local activePixelBorders = setmetatable({}, { __mode = "k" })
local hookedMaskedTex = setmetatable({}, { __mode = "k" })
local maskedTexHost = setmetatable({}, { __mode = "kv" })
local pendingMasks = {}
local maskWaitFrame = nil
local scaleWatchFrame = nil

local function IsTextureLoadedSafe(obj)
    if not obj then return false end
    if not obj.IsObjectLoaded then return true end
    local ok, loaded = pcall(obj.IsObjectLoaded, obj)
    if not ok or F.IsSecret(loaded) then return true end
    return loaded == true
end

local function EnsureMaskWaitFrame()
    if maskWaitFrame then return maskWaitFrame end
    maskWaitFrame = CreateFrame("Frame")
    maskWaitFrame:Hide()
    maskWaitFrame:SetScript("OnUpdate", function(self)
        local anyLeft = false
        for tex, entry in pairs(pendingMasks) do
            local mask = entry.mask
            if not (tex and mask)
                or (tex.IsForbidden and tex:IsForbidden())
                or (mask.IsForbidden and mask:IsForbidden()) then
                pendingMasks[tex] = nil
            else
                entry.tries = entry.tries + 1
                if (IsTextureLoadedSafe(tex) and IsTextureLoadedSafe(mask)) or entry.tries >= 60 then
                    pendingMasks[tex] = nil
                    if tex.AddMaskTexture then
                        pcall(tex.AddMaskTexture, tex, mask)
                    end
                else
                    anyLeft = true
                end
            end
        end
        if not anyLeft then
            self:Hide()
        end
    end)
    return maskWaitFrame
end

-- WoW 12.1 异步贴图 + 遮罩引擎保护：贴图尚未加载完成时挂载遮罩会导致图标整格空白或残留左上极小碎块；
-- 先请求同步加载，若仍未就绪则暂卸遮罩并在 IsObjectLoaded() 转 true 的当帧无感补回（空闲 0 CPU）
local function AttachMaskSafely(tex, mask)
    if not (tex and mask and tex.AddMaskTexture) then return end
    if tex.SetBlockingLoadsRequested then
        pcall(tex.SetBlockingLoadsRequested, tex, true)
    end
    if IsTextureLoadedSafe(tex) and IsTextureLoadedSafe(mask) then
        pendingMasks[tex] = nil
        pcall(tex.AddMaskTexture, tex, mask)
    else
        if tex.RemoveMaskTexture then
            pcall(tex.RemoveMaskTexture, tex, mask)
        end
        pendingMasks[tex] = { mask = mask, tries = 0 }
        EnsureMaskWaitFrame():Show()
    end
end

local function HasEUIRounded()
    return _G.EllesmereUI ~= nil or F.IsAddOnLoaded("EllesmereUI")
end

local function SetNineSlice(obj, path, margin, wrap)
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
        pcall(obj.SetTextureSliceMargins, obj, margin, margin, margin, margin)
    end
    local sm = _G.Enum and _G.Enum.UITextureSliceMode and _G.Enum.UITextureSliceMode.Stretched
    if sm and obj.SetTextureSliceMode then
        pcall(obj.SetTextureSliceMode, obj, sm)
    end
end

local function GetHalfSideSafe(region)
    if not (region and region.GetSize) then return nil end
    local ok, w, h = pcall(region.GetSize, region)
    if not ok then return nil end
    w = F.PlainNumber(w, nil)
    h = F.PlainNumber(h, nil)
    if not (w and h) or w <= 0 or h <= 0 then return nil end
    return math_min(w, h) * 0.5
end

local function SeatPixelLayer(bf, host, k)
    if not (bf and host and host.GetLeft) then return end
    local okL, l = pcall(host.GetLeft, host)
    if not okL then return end
    local okT, t = pcall(host.GetTop, host)
    local okR, r = pcall(host.GetRight, host)
    local okB, b = pcall(host.GetBottom, host)
    if not (okT and okR and okB) then return end
    l = F.PlainNumber(l, nil); t = F.PlainNumber(t, nil)
    r = F.PlainNumber(r, nil); b = F.PlainNumber(b, nil)
    if not (l and t and r and b) then return end
    l, t, r, b = l * k, t * k, r * k, b * k
    local dl = math_floor(l + 0.5) - l
    local dt = math_floor(t + 0.5) - t
    local dr = math_floor(r + 0.5) - r
    local db = math_floor(b + 0.5) - b
    if bf._sl == dl and bf._st == dt and bf._sr == dr and bf._sb == db then return end
    bf._sl, bf._st, bf._sr, bf._sb = dl, dt, dr, db
    bf:ClearAllPoints()
    bf:SetPoint("TOPLEFT", host, "TOPLEFT", dl, dt)
    bf:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", dr, db)
end

function ST.ResolveMaskPath(radius)
    local r = math_max(1, math_min(16, math_floor((radius or 6) + 0.5)))
    if HasEUIRounded() then
        return EUI_ROUND_DIR .. "rounded-" .. r .. ".tga",
               EUI_ROUND_DIR .. "rounded-inv-" .. math_max(1, r - 1) .. ".tga",
               r
    end
    if r >= 5 then
        return ST.TEX.PILL_MASK_6, nil, 6
    end
    return ST.TEX.PILL_MASK, nil, 3
end

-- 统一重塑宿主正文遮罩（严格遵循 WoW 引擎：先从全部贴图分离 -> 改贴图与锚点 -> 重新绑定）
local function ReseatHostBodyMask(host, st, reqRadius, insetPx)
    if not (host and st and st.mask) then return end
    local r = math_max(1, math_min(16, math_floor((reqRadius or 6) + 0.5)))
    local half = GetHalfSideSafe(host)
    if half and half >= 1 then
        local cap = math_max(1, math_floor(half - (insetPx or 0) - 0.5))
        if r > cap then r = cap end
    end
    local ins = insetPx or 0
    if st.maskActualR == r and st.maskInset == ins then return end
    st.maskActualR = r
    st.maskInset = ins

    local m = st.mask
    for tex in _G.pairs(st.masked) do
        if tex and tex.RemoveMaskTexture then pcall(tex.RemoveMaskTexture, tex, m) end
    end
    local maskPath, _, actualR = ST.ResolveMaskPath(r)
    SetNineSlice(m, maskPath, actualR, "CLAMPTOBLACKADDITIVE")
    m:ClearAllPoints()
    if ins > 0 then
        m:SetPoint("TOPLEFT", host, "TOPLEFT", ins, -ins)
        m:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -ins, ins)
    else
        m:SetAllPoints(host)
    end
    for tex in pairs(st.masked) do
        if tex and tex.AddMaskTexture then AttachMaskSafely(tex, m) end
    end
end

local function FitPixelRoundedBorder(host, st)
    local bf = st and st.borderFrame
    if not (bf and bf:IsShown() and st.borderReqRadius and st.borderReqRadius > 0) then return end
    local rad = st.borderReqRadius
    local useEUI = HasEUIRounded() and bf.CreateMaskTexture ~= nil
    if not useEUI then return end

    local perfect = GetPerfectScale()
    if bf._pxScale ~= perfect then
        bf._pxScale = perfect
        pcall(bf.SetIgnoreParentScale, bf, true)
        pcall(bf.SetScale, bf, perfect)
        bf._sl = nil
    end

    local okS, hs = pcall(host.GetEffectiveScale, host)
    hs = okS and F.PlainNumber(hs, nil) or nil
    if not hs or hs <= 0 then
        hs = _G.UIParent and F.PlainNumber(_G.UIParent:GetScale(), 1) or 1
    end
    local k = hs / perfect
    if k <= 0 then k = 1 end

    SeatPixelLayer(bf, host, k)

    local half = GetHalfSideSafe(host)
    local rPx = math_floor(rad * k + 0.5)
    if half then
        local capPx = math_floor(half * k - 0.5)
        if rPx > capPx then rPx = capPx end
    end
    if rPx > 16 then rPx = 16 elseif rPx < 2 then rPx = 2 end

    if bf._fittedRPx ~= rPx then
        local fill = bf._tex
        local hole = bf._innerHole
        if not hole then
            hole = bf:CreateMaskTexture()
            bf._innerHole = hole
        end
        -- 严格先分离孔遮罩，再重设外圈圆角贴图与内孔 1px 物理内缩同心反遮罩，杜绝圆角发粗发虚
        if bf._holeAttached and fill.RemoveMaskTexture then
            pcall(fill.RemoveMaskTexture, fill, hole)
            bf._holeAttached = false
        end
        local innerPx = math_max(1, rPx - 1)
        SetNineSlice(fill, EUI_ROUND_DIR .. "rounded-" .. rPx .. ".tga", rPx, nil)
        SetNineSlice(hole, EUI_ROUND_DIR .. "rounded-inv-" .. innerPx .. ".tga", innerPx, "CLAMPTOWHITE")
        hole:ClearAllPoints()
        hole:SetPoint("TOPLEFT", bf, "TOPLEFT", 1, -1)
        hole:SetPoint("BOTTOMRIGHT", bf, "BOTTOMRIGHT", -1, 1)
        pcall(fill.AddMaskTexture, fill, hole)
        bf._holeAttached = true
        bf._fittedRPx = rPx
    end

    -- 同步把宿主内部贴图遮罩精确内缩 1 物理像素（px = 1/k），使填充边缘恰好藏在 1px 清晰圆角细框内侧：
    -- 0 渗色灰晕、0 锯齿、0 缝隙！
    if st.mask and st.radius and st.radius > 0 then
        local pxHost = 1 / k
        local innerBodyR = math_max(1, math_min(16, math_floor((rPx - 1) / k)))
        ReseatHostBodyMask(host, st, innerBodyR, pxHost)
    end
end

local function EnsureScaleWatcher()
    if scaleWatchFrame then return end
    scaleWatchFrame = CreateFrame("Frame")
    scaleWatchFrame:RegisterEvent("UI_SCALE_CHANGED")
    scaleWatchFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
    scaleWatchFrame:SetScript("OnEvent", function()
        for host, st in _G.pairs(activePixelBorders) do
            if host and st and st.borderFrame and st.borderFrame:IsShown() then
                FitPixelRoundedBorder(host, st)
            end
        end
    end)
end

function ST.EnsureRoundedMask(host, radius)
    if not (host and host.CreateMaskTexture) then return nil end
    local r = math_floor((radius or 6) + 0.5)
    local st = roundState[host]
    if not st then
        st = { masked = setmetatable({}, { __mode = "k" }) }
        roundState[host] = st
    end
    if r <= 0 then
        if st.mask then
            for tex in pairs(st.masked) do
                pendingMasks[tex] = nil
                maskedTexHost[tex] = nil
                if tex and tex.RemoveMaskTexture then pcall(tex.RemoveMaskTexture, tex, st.mask) end
            end
            st.masked = setmetatable({}, { __mode = "k" })
        end
        st.radius = 0
        st.maskActualR = nil
        st.maskInset = nil
        return nil
    end
    if not st.mask then
        st.mask = host:CreateMaskTexture()
        st.mask:SetAllPoints(host)
    end
    if st.radius ~= r or not st.maskActualR then
        st.radius = r
        if st.borderFrame and st.borderFrame:IsShown() and st.borderReqRadius and st.borderReqRadius > 0 then
            FitPixelRoundedBorder(host, st)
        else
            ReseatHostBodyMask(host, st, r, 0)
        end
    end
    return st.mask
end

function ST.MaskTexture(host, tex, radius)
    if not (host and tex and tex.AddMaskTexture) then return end
    local mask = ST.EnsureRoundedMask(host, radius)
    local st = roundState[host]
    if not (mask and st) then return end
    maskedTexHost[tex] = host
    if not hookedMaskedTex[tex] and tex.SetTexture and not (tex.IsForbidden and tex:IsForbidden()) then
        hookedMaskedTex[tex] = true
        _G.hooksecurefunc(tex, "SetTexture", function(self)
            local h = maskedTexHost[self]
            local curSt = h and roundState[h]
            if curSt and curSt.mask and curSt.masked[self] then
                AttachMaskSafely(self, curSt.mask)
            end
        end)
    end
    if not st.masked[tex] then
        st.masked[tex] = true
        AttachMaskSafely(tex, mask)
    elseif pendingMasks[tex] then
        AttachMaskSafely(tex, mask)
    end
end

function ST.ClearRoundedMask(host)
    local st = host and roundState[host]
    if not st then return end
    if st.mask then
        for tex in pairs(st.masked) do
            pendingMasks[tex] = nil
            maskedTexHost[tex] = nil
            if tex and tex.RemoveMaskTexture then pcall(tex.RemoveMaskTexture, tex, st.mask) end
        end
        st.masked = setmetatable({}, { __mode = "k" })
    end
    if st.borderFrame then st.borderFrame:Hide() end
    activePixelBorders[host] = nil
    st.radius = 0
    st.borderReqRadius = 0
    st.maskActualR = nil
    st.maskInset = nil
end

-- 为任意框体建立 1:1 物理像素锐利圆角 1px 同心描边（不修改宿主边框或 NineSlice）
function ST.ApplyRoundedBorder(host, radius, r, g, b, a, levelOffset)
    if not (host and host.CreateTexture) then return nil end
    local rad = math_floor((radius or 6) + 0.5)
    local st = roundState[host]
    if not st then
        st = { masked = setmetatable({}, { __mode = "k" }) }
        roundState[host] = st
    end
    if rad <= 0 then
        st.borderReqRadius = 0
        activePixelBorders[host] = nil
        if st.borderFrame then st.borderFrame:Hide() end
        if st.mask and st.radius and st.radius > 0 then
            ReseatHostBodyMask(host, st, st.radius, 0)
        end
        return nil
    end

    local useEUI = HasEUIRounded()
    local bf = st.borderFrame
    if not bf then
        bf = CreateFrame("Frame", nil, host)
        bf:SetAllPoints(host)
        bf:EnableMouse(false)
        local tex = bf:CreateTexture(nil, "OVERLAY", nil, 6)
        tex:SetAllPoints(bf)
        bf._tex = tex
        bf:SetScript("OnShow", function()
            if st.borderReqRadius and st.borderReqRadius > 0 then
                FitPixelRoundedBorder(host, st)
            end
        end)
        st.borderFrame = bf
    end
    local hostLvl = F.PlainNumber(host.GetFrameLevel and host:GetFrameLevel(), 10) or 10
    bf:SetFrameLevel(math_max(0, hostLvl + (levelOffset or 6)))
    st.borderReqRadius = rad

    if useEUI and bf.CreateMaskTexture then
        EnsureScaleWatcher()
        activePixelBorders[host] = st
        bf:Show()
        FitPixelRoundedBorder(host, st)
        -- 新建尚未完成首帧锚定的框体在下一帧补做一次物理像素吸附
        if not bf._postFitDone then
            bf._postFitDone = true
            if _G.C_Timer and _G.C_Timer.After then
                _G.C_Timer.After(0, function()
                    if bf and bf:IsShown() and st.borderReqRadius and st.borderReqRadius > 0 then
                        FitPixelRoundedBorder(host, st)
                    end
                end)
            end
        end
    else
        local rimPath = (rad >= 5) and ST.TEX.PILL_RIM_6 or ST.TEX.PILL_RIM
        local rimR = (rad >= 5) and 6 or 3
        if st.borderRadius ~= rimR then
            st.borderRadius = rimR
            SetNineSlice(bf._tex, rimPath, rimR, nil)
        end
        bf:Show()
    end
    bf._tex:SetVertexColor(r or 0.02, g or 0.02, b or 0.03, a or 0.96)
    return bf
end

-- 战斗安全延迟队列：优先复用 EllesmereUI.NewCombatQueue（空闲 0 事件开销）
local combatQueue = nil
local function EnsureCombatQueue()
    if combatQueue ~= nil then return combatQueue end
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.NewCombatQueue) == "function" then
        local ok, q = pcall(EUI.NewCombatQueue, CreateFrame("Frame"))
        if ok and type(q) == "table" and type(q.Defer) == "function" then
            combatQueue = q
            return combatQueue
        end
    end
    combatQueue = false
    return combatQueue
end

function F.CombatDefer(key, fn)
    if type(fn) ~= "function" then return end
    if not (InCombatLockdown and InCombatLockdown()) then
        fn()
        return
    end
    local q = EnsureCombatQueue()
    if q then
        q.Defer(key, fn)
    else
        F.RunOutOfCombat(key, fn)
    end
end
