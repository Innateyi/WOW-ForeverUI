----------------------------------------------------------------------
--  kkowoUI — Core/StyleTokens.lua
--  统一视觉 Token、全职业横向渐变色表、GPU 9 宫格圆角遮罩与战斗队列封装
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local math_ceil, math_floor, math_max, math_min, pairs, pcall, setmetatable, type =
    math.ceil, math.floor, math.max, math.min, pairs, pcall, setmetatable, type
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
    WP_DISC      = F.MEDIA .. "Waypoint\\WaypointDisc.tga",
    WP_RIM       = F.MEDIA .. "Waypoint\\WaypointCrescentRim.tga",
    WP_SWEEP     = F.MEDIA .. "Waypoint\\WaypointSweep.tga",
    WP_BEAM_CORE = F.MEDIA .. "Waypoint\\WaypointBeamCore.tga",
    WP_BEAM_HALO = F.MEDIA .. "Waypoint\\WaypointBeamHalo.tga",
    WP_RIPPLE    = F.MEDIA .. "Waypoint\\WaypointRipple.tga",
    WP_PIN       = F.MEDIA .. "Waypoint\\WaypointPin.tga",
    WP_QUEST     = F.MEDIA .. "Waypoint\\WaypointQuest.tga",
    WP_CORPSE    = F.MEDIA .. "Waypoint\\WaypointCorpse.tga",
    WP_ARROW     = F.MEDIA .. "Waypoint\\WaypointArrow.tga",
}

local EUI_ROUND_DIR = "Interface\\AddOns\\EllesmereUI\\media\\rounded\\"
local EUI_AURA_MASK_DIR = EUI_ROUND_DIR .. "aura-masks\\"
local EUI_AURA_SWIPE = EUI_AURA_MASK_DIR .. "aura-swipe.tga"
local SWIPE_UV_ZERO = { x = 0, y = 0 }
local SWIPE_UV_ONE = { x = 1, y = 1 }

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
local hookedHostShow = setmetatable({}, { __mode = "k" })
local hookedHostSize = setmetatable({}, { __mode = "k" })
local roundedSwipes = setmetatable({}, { __mode = "k" })
local maskedTexHost = setmetatable({}, { __mode = "kv" })
local attachedMask = setmetatable({}, { __mode = "kv" })
local isIconTex = setmetatable({}, { __mode = "k" })
local keepLoadedTex = setmetatable({}, { __mode = "k" })
local customMaskSpec = setmetatable({}, { __mode = "k" })
local hostCustomTex = setmetatable({}, { __mode = "k" })
local pendingMasks = {}
local pendingBorderHoles = {}
local stalledMasks = setmetatable({}, { __mode = "k" })
local stalledBorderHoles = setmetatable({}, { __mode = "k" })
local borderHoleTokens = setmetatable({}, { __mode = "k" })
local borderHoleSeq = 0
local maskWaitFrame = nil
local scaleWatchFrame = nil

-- 贴图加载三态：true = 已加载；false = 确定未加载；nil = 读不到（12.x 保密布尔值或调用失败）。
-- 读不到或确定未加载时绝不能强行挂圆角遮罩，否则 WoW 12.1 引擎会把该贴图整格画成空白且加载完也不重绘。
local function TextureLoadState(obj)
    if not obj then return false end
    if not obj.IsObjectLoaded then return true end
    local ok, loaded = pcall(obj.IsObjectLoaded, obj)
    if not ok then return nil end
    if F.IsSecret(loaded) then return nil end
    return loaded == true
end

local function IsVisibleSafe(obj)
    if not obj then return false end
    if not obj.IsVisible then return true end
    local ok, vis = pcall(obj.IsVisible, obj)
    if not ok or F.IsSecret(vis) then return false end
    return vis == true
end

-- 判断贴图对象当前是否处于「完全没赋图」的空槽状态（例如空动作条格的 icon）：
-- 空槽不需要挂遮罩，也绝不能在超时后强挂（否则之后拖入新技能或换页时遮罩已经挂在未加载的新图上）。
local function IsEmptyUnassignedTex(tex)
    if not tex or not tex.GetTexture then return false end
    local okT, t = pcall(tex.GetTexture, tex)
    if not okT or F.IsSecret(t) or t ~= nil then return false end
    if tex.GetAtlas then
        local okA, a = pcall(tex.GetAtlas, tex)
        if not okA or F.IsSecret(a) or a ~= nil then return false end
    end
    return true
end

-- 贴图确定没加载完时最多等约 10 秒（600 帧）；读不到（保密值）最多试 12 帧避免战斗中空转 OnUpdate；
-- 隐藏态最多等 5 帧即转入 stalledMasks（由 OnShow / Show / SetShown 瞬间唤醒，零后台轮询）。
-- 任何超时分支都绝不强行挂遮罩（宁可暂时直角，绝不空白）。
local MASK_WAIT_MAX = 600
local MASK_SECRET_MAX = 12
local MASK_HIDDEN_MAX = 5

local function DetachMaskTrack(tex, mask)
    if not (tex and mask) then return end
    if tex.RemoveMaskTexture then
        pcall(tex.RemoveMaskTexture, tex, mask)
    end
    if attachedMask[tex] == mask then
        attachedMask[tex] = nil
    end
end

local function ApplyMaskNow(tex, mask, forceRebind)
    if not (tex and mask and tex.AddMaskTexture) then return end
    if attachedMask[tex] == mask then
        if not forceRebind then return end
        if tex.RemoveMaskTexture then
            pcall(tex.RemoveMaskTexture, tex, mask)
        end
        attachedMask[tex] = nil
    end
    local ok = pcall(tex.AddMaskTexture, tex, mask)
    if ok then
        attachedMask[tex] = mask
    end
end

local function ResolveTexTarget(tex)
    local spec = customMaskSpec[tex]
    if spec and spec.mask then
        return spec.host, spec.mask, spec.isIcon == true, spec.keepIfLoaded == true
    end
    local h = maskedTexHost[tex]
    local st = h and roundState[h]
    if st and st.mask and st.masked[tex] then
        return h, st.mask, isIconTex[tex] == true, keepLoadedTex[tex] == true
    end
    return nil, nil, false, false
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
                local ls, lm = TextureLoadState(tex), TextureLoadState(mask)
                local needVis = (entry.settleNeed or 1) >= 2
                if ls == false and IsEmptyUnassignedTex(tex) then
                    -- 空技能格：不必每帧空轮询，等真正 SetTexture / SetAtlas / Show 时再挂
                    pendingMasks[tex] = nil
                    stalledMasks[tex] = mask
                elseif needVis and not IsVisibleSafe(tex) then
                    -- 隐藏中的动态图标不提交 GPU 渲染：短暂宽限几帧（覆盖 SetTexture 后紧接 Show），仍隐藏则停轮询等 OnShow 唤醒
                    entry.visibleReady = 0
                    entry.hiddenTicks = (entry.hiddenTicks or 0) + 1
                    if entry.hiddenTicks >= MASK_HIDDEN_MAX then
                        pendingMasks[tex] = nil
                        stalledMasks[tex] = mask
                    else
                        anyLeft = true
                    end
                else
                    entry.hiddenTicks = 0
                    if ls == true and lm == true then
                        entry.visibleReady = (entry.visibleReady or 0) + 1
                        -- 动态图标/换图后必须先在可见态完整绘制至少 1 帧无遮罩原图，确保 GPU 纹理上传就绪后再挂圆角遮罩
                        if entry.visibleReady >= (entry.settleNeed or 1) then
                            pendingMasks[tex] = nil
                            stalledMasks[tex] = nil
                            ApplyMaskNow(tex, mask, false)
                        else
                            anyLeft = true
                        end
                    elseif (ls == nil or lm == nil) and entry.tries >= MASK_SECRET_MAX then
                        pendingMasks[tex] = nil
                        stalledMasks[tex] = mask
                    elseif entry.tries < MASK_WAIT_MAX then
                        entry.visibleReady = 0
                        anyLeft = true
                    else
                        -- 绝不强挂遮罩：留在 stalledMasks 等后续事件/显形补挂
                        pendingMasks[tex] = nil
                        stalledMasks[tex] = mask
                    end
                end
            end
        end
        for keyObj, entry in pairs(pendingBorderHoles) do
            local fill, hole, outer = entry.fill, entry.hole, entry.outer
            if not (keyObj and fill and hole)
                or borderHoleTokens[keyObj] ~= entry.token
                or (keyObj.IsForbidden and keyObj:IsForbidden())
                or (fill.IsForbidden and fill:IsForbidden()) then
                pendingBorderHoles[keyObj] = nil
            else
                entry.tries = entry.tries + 1
                local lf = TextureLoadState(fill)
                local lh = TextureLoadState(hole)
                local lo = outer and TextureLoadState(outer) or true
                if lf == true and lh == true and lo == true then
                    pendingBorderHoles[keyObj] = nil
                    stalledBorderHoles[keyObj] = nil
                    if borderHoleTokens[keyObj] == entry.token then
                        if outer and fill.AddMaskTexture then
                            pcall(fill.AddMaskTexture, fill, outer)
                        end
                        if fill.AddMaskTexture then
                            pcall(fill.AddMaskTexture, fill, hole)
                        end
                        fill:Show()
                        if entry.onReady then pcall(entry.onReady, keyObj) end
                    end
                elseif (lf == nil or lh == nil or lo == nil) and entry.tries >= MASK_SECRET_MAX then
                    pendingBorderHoles[keyObj] = nil
                    stalledBorderHoles[keyObj] = entry
                elseif entry.tries < MASK_WAIT_MAX then
                    anyLeft = true
                else
                    -- 孔遮罩超时仍未就绪：保持 fill 隐藏，记入 stalledBorderHoles 等后续重试，绝不画成实心色块盖住图标
                    pendingBorderHoles[keyObj] = nil
                    stalledBorderHoles[keyObj] = entry
                end
            end
        end
        if not anyLeft then
            self:Hide()
        end
    end)
    return maskWaitFrame
end

-- WoW 12.1 异步贴图 + 遮罩引擎保护：
-- 1) 绝不对暴雪/外部图标强行调用 SetBlockingLoadsRequested(true)（仅用于我们自己的遮罩/描边 .tga）；
-- 2) 贴图未就绪、处于隐藏态、或刚经历 SetTexture/SetAtlas 换图时，一律先卸除遮罩，
--    待可见且 IsObjectLoaded() == true 后至少完整绘制 1 帧（settleNeed=2）再无感补回圆角，彻底根治整格变空与左上碎块。
local function AttachMaskSafely(tex, mask, host, fromSwap, isIcon, keepIfLoaded)
    if not (tex and mask and tex.AddMaskTexture) then return end
    stalledMasks[tex] = nil
    local ls, lm = TextureLoadState(tex), TextureLoadState(mask)
    if ls == false and IsEmptyUnassignedTex(tex) then
        DetachMaskTrack(tex, mask)
        pendingMasks[tex] = nil
        stalledMasks[tex] = mask
        return
    end
    local vis = IsVisibleSafe(tex)
    -- 圆形技能球/目标头像等高频切换图标：已挂遮罩且新图与遮罩均已加载且可见时直接保持，避免每次施法闪一帧方角
    if keepIfLoaded and attachedMask[tex] == mask and ls == true and lm == true and vis then
        pendingMasks[tex] = nil
        return
    end
    local needSettle = (isIcon == true) or (fromSwap == true)
    if not needSettle and ls == true and lm == true then
        pendingMasks[tex] = nil
        ApplyMaskNow(tex, mask, false)
        return
    end
    DetachMaskTrack(tex, mask)
    local settleNeed = needSettle and 2 or 1
    pendingMasks[tex] = {
        mask = mask,
        host = host,
        tries = 0,
        visibleReady = 0,
        hiddenTicks = 0,
        settleNeed = settleNeed,
    }
    EnsureMaskWaitFrame():Show()
end

local function RetryStalledBorderHole(keyObj, entry)
    if not (keyObj and entry and entry.fill and entry.hole) then return end
    if borderHoleTokens[keyObj] ~= entry.token then
        stalledBorderHoles[keyObj] = nil
        return
    end
    stalledBorderHoles[keyObj] = nil
    local fill, hole, outer = entry.fill, entry.hole, entry.outer
    local lf = TextureLoadState(fill)
    local lh = TextureLoadState(hole)
    local lo = outer and TextureLoadState(outer) or true
    if lf == true and lh == true and lo == true then
        if outer and fill.AddMaskTexture then pcall(fill.AddMaskTexture, fill, outer) end
        if fill.AddMaskTexture then pcall(fill.AddMaskTexture, fill, hole) end
        fill:Show()
        if entry.onReady then pcall(entry.onReady, keyObj) end
    else
        entry.tries = 0
        pendingBorderHoles[keyObj] = entry
        EnsureMaskWaitFrame():Show()
    end
end

local ReseatHostBodyMask -- 前向声明
local FitPixelRoundedBorder -- 前向声明
local SyncRoundedCooldownSwipe -- 前向声明

local function WakeHostStalled(host)
    if not host then return end
    local st = roundState[host]
    if st then
        if st.borderFrame and st.borderFrame:IsShown() and st.borderReqRadius and st.borderReqRadius > 0 then
            st.maskSizePending = nil
            FitPixelRoundedBorder(host, st)
        elseif st.maskSizePending and st.radius and st.radius > 0 then
            st.maskSizePending = nil
            ReseatHostBodyMask(host, st, st.maskReqR or st.radius, st.maskInset or 0)
        elseif st.roundedSwipeCDs then
            SyncRoundedCooldownSwipe(host, st)
        end
        if st.mask then
            for tex in pairs(st.masked) do
                if stalledMasks[tex] == st.mask then
                    AttachMaskSafely(tex, st.mask, host, false, isIconTex[tex] == true, keepLoadedTex[tex] == true)
                end
            end
        end
        if st.borderFrame and stalledBorderHoles[st.borderFrame] then
            RetryStalledBorderHole(st.borderFrame, stalledBorderHoles[st.borderFrame])
        end
    end
    local customSet = hostCustomTex[host]
    if customSet then
        for tex in pairs(customSet) do
            if stalledMasks[tex] then
                local h, m, ic, kl = ResolveTexTarget(tex)
                if m then AttachMaskSafely(tex, m, h, false, ic, kl) end
            end
        end
    end
    if stalledBorderHoles[host] then
        RetryStalledBorderHole(host, stalledBorderHoles[host])
    end
end

local function OnHostSizeChanged(host)
    if not host or (host.IsForbidden and host:IsForbidden()) then return end
    local st = roundState[host]
    if not st then return end
    if st.borderFrame and st.borderFrame:IsShown() and st.borderReqRadius and st.borderReqRadius > 0 then
        FitPixelRoundedBorder(host, st)
    elseif st.radius and st.radius > 0 then
        ReseatHostBodyMask(host, st, st.maskReqR or st.radius, st.maskInset or 0)
    elseif st.roundedSwipeCDs then
        SyncRoundedCooldownSwipe(host, st)
    end
end

local function EnsureHostSizeHook(host)
    if not host or hookedHostSize[host] or (host.IsForbidden and host:IsForbidden()) then return end
    if host.HookScript and host.HasScript and host:HasScript("OnSizeChanged") then
        hookedHostSize[host] = true
        host:HookScript("OnSizeChanged", OnHostSizeChanged)
    end
end

local function EnsureHostShowHook(host)
    if not host or (host.IsForbidden and host:IsForbidden()) then return end
    EnsureHostSizeHook(host)
    if hookedHostShow[host] then return end
    if host.HookScript and host.HasScript and host:HasScript("OnShow") then
        hookedHostShow[host] = true
        host:HookScript("OnShow", WakeHostStalled)
    end
end

local function OnMaskedTexChanged(self)
    local h, m, ic, kl = ResolveTexTarget(self)
    if m then
        AttachMaskSafely(self, m, h, true, ic, kl)
    end
end

local function OnMaskedColorChanged(self)
    local h, m, ic, kl = ResolveTexTarget(self)
    if not m then return end
    -- SetColorTexture 保留既有遮罩且无异步文件流；仅在未挂上或挂起时补挂，避免反复卸挂造成闪烁
    if attachedMask[self] == m and not pendingMasks[self] and not stalledMasks[self] then
        return
    end
    AttachMaskSafely(self, m, h, false, ic, kl)
end

local function OnMaskedTexShown(self)
    if not stalledMasks[self] then return end
    local h, m, ic, kl = ResolveTexTarget(self)
    if m then
        AttachMaskSafely(self, m, h, false, ic, kl)
    end
end

local function OnMaskedTexSetShown(self, shown)
    if not stalledMasks[self] then return end
    if not F.IsSecret(shown) and shown == false then return end
    local h, m, ic, kl = ResolveTexTarget(self)
    if m then
        AttachMaskSafely(self, m, h, false, ic, kl)
    end
end

local function EnsureTexHooks(tex)
    if not tex or hookedMaskedTex[tex] or (tex.IsForbidden and tex:IsForbidden()) then return end
    hookedMaskedTex[tex] = true
    if tex.SetTexture then _G.hooksecurefunc(tex, "SetTexture", OnMaskedTexChanged) end
    if tex.SetAtlas then _G.hooksecurefunc(tex, "SetAtlas", OnMaskedTexChanged) end
    if tex.SetColorTexture then _G.hooksecurefunc(tex, "SetColorTexture", OnMaskedColorChanged) end
    if tex.Show then _G.hooksecurefunc(tex, "Show", OnMaskedTexShown) end
    if tex.SetShown then _G.hooksecurefunc(tex, "SetShown", OnMaskedTexSetShown) end
end

-- 脱战 / 过图 / 法术与动作条变动后，把此前因受限态、隐藏或未加载而暂缓的圆角与描边孔洞补挂上
do
    local retry = CreateFrame("Frame")
    retry:RegisterEvent("PLAYER_REGEN_ENABLED")
    retry:RegisterEvent("PLAYER_ENTERING_WORLD")
    retry:RegisterEvent("SPELLS_CHANGED")
    retry:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    retry:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
    retry:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
    retry:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
    retry:RegisterEvent("PET_BAR_UPDATE")
    retry:SetScript("OnEvent", function()
        local list = {}
        for tex, mask in pairs(stalledMasks) do list[#list + 1] = { tex, mask } end
        for _, it in ipairs(list) do
            local tex, mask = it[1], it[2]
            local h, curMask, ic, kl = ResolveTexTarget(tex)
            if curMask == mask then
                stalledMasks[tex] = nil
                AttachMaskSafely(tex, mask, h, false, ic, kl)
            else
                stalledMasks[tex] = nil
            end
        end
        local holes = {}
        for keyObj, entry in pairs(stalledBorderHoles) do holes[#holes + 1] = { keyObj, entry } end
        for _, it in ipairs(holes) do
            RetryStalledBorderHole(it[1], it[2])
        end
    end)
end

local function HasEUIRounded()
    return _G.EllesmereUI ~= nil or F.IsAddOnLoaded("EllesmereUI")
end
ST.HasEUIRounded = HasEUIRounded
ST.EUI_ROUND_DIR = EUI_ROUND_DIR
ST.EUI_AURA_MASK_DIR = EUI_AURA_MASK_DIR

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
ST.SetNineSlice = SetNineSlice

-- WoW 12.1 (D3D12) 引擎铁律：绝不对整图 MaskTexture 调用 SetTextureSliceMargins（哪怕传 0,0,0,0）！
-- 只要对一个 MaskTexture 调过一次 SetTextureSliceMargins，引擎就会永久激活其 9 宫格着色器路径，
-- 导致部分 CASC 技能图标（例如「极速再生」FileDataID 1850550）在动作条整格空白、在 Tooltip 碎成左上残片。
local function SetWholeMask(obj, path)
    if not obj then return end
    if obj.SetBlockingLoadsRequested then
        pcall(obj.SetBlockingLoadsRequested, obj, true)
    end
    pcall(obj.SetTexture, obj, path, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
end
ST.SetWholeMask = SetWholeMask

local function GetSizeSafe(region)
    if not (region and region.GetSize) then return nil, nil end
    local ok, w, h = pcall(region.GetSize, region)
    if not ok then return nil, nil end
    w = F.PlainNumber(w, nil)
    h = F.PlainNumber(h, nil)
    if not (w and h) or w <= 0 or h <= 0 then return nil, nil end
    return w, h
end

local function GetHalfSideSafe(region)
    local w, h = GetSizeSafe(region)
    if not (w and h) then return nil end
    return math_min(w, h) * 0.5
end

-- 为正方形/近正方形图标计算 64x64 整图圆角遮罩（aura-masks/round-1..16.tga）编号，
-- 与 EllesmereUI.RoundAuraCorners 使用同一算法：绝不对动态游戏图标使用 9 宫格切片遮罩，
-- 且让圆角弧略微嵌进 1px 描边内沿，做到零缝隙、零锯齿、零空白。
local function ComputeWholeIconShape(innerRadius, w, h, edge)
    local ins = edge or 0
    local bodyW = math_max(2, (w or 36) - 2 * ins)
    local bodyH = math_max(2, (h or 36) - 2 * ins)
    local inner = math_max(1, innerRadius or 4)
    local outerR = inner + ins
    local shape = math_min(16, math_max(1, math_ceil(64 * inner / math_max(2, bodyW + bodyH))))
    if ins > 0 and shape > 1 and (shape - 1) * math_min(bodyW, bodyH) / 32 >= outerR - 3 * ins then
        shape = shape - 1
    end
    return shape
end

function ST.SetWholeIconMask(mask, innerRadius, w, h, edge)
    if not (mask and HasEUIRounded()) then return nil end
    local shape = ComputeWholeIconShape(innerRadius, w, h, edge)
    SetWholeMask(mask, EUI_AURA_MASK_DIR .. "round-" .. shape .. ".tga")
    return shape
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
    if (r - l) <= 0.01 or (t - b) <= 0.01 then return end
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
-- 图标宿主（st.iconMode == true 且纵横比 <= 1.65）使用独立的纯净 st.wholeMask（64x64 整图 aura-masks/round-N.tga，
-- 终生不碰 SetTextureSliceMargins）；条形/面板宿主使用独立的 st.sliceMask（9 宫格 rounded-N.tga），两者绝不混用。
ReseatHostBodyMask = function(host, st, reqRadius, insetPx)
    if not (host and st and host.CreateMaskTexture) then return end
    local ins = insetPx or 0
    local w, h = GetSizeSafe(host)
    local half = (w and h) and (math_min(w, h) * 0.5) or nil
    local useWhole = st.iconMode == true and HasEUIRounded()
    if useWhole and w and h and math_max(w, h) > math_min(w, h) * 1.65 then
        useWhole = false
    end

    local rFloat = math_max(1, math_min(16, reqRadius or 6))
    if half and half >= 1 then
        local cap = math_max(1, half - ins - 0.5)
        if rFloat > cap then rFloat = cap end
    end
    local r = math_max(1, math_min(16, math_floor(rFloat + 0.5)))
    local shapeKey, wholeShape
    if useWhole then
        if not (w and h) then
            st.maskSizePending = true
        else
            st.maskSizePending = nil
        end
        wholeShape = ComputeWholeIconShape(rFloat, w or 36, h or 36, ins)
        shapeKey = "W:" .. wholeShape
    else
        st.maskSizePending = nil
        shapeKey = "S:" .. r
    end
    st.maskReqR = reqRadius

    local targetMask
    if useWhole then
        if not st.wholeMask then
            st.wholeMask = host:CreateMaskTexture()
        end
        targetMask = st.wholeMask
    else
        if not st.sliceMask then
            st.sliceMask = host:CreateMaskTexture()
        end
        targetMask = st.sliceMask
    end

    if st.mask == targetMask and st.maskShapeKey == shapeKey and st.maskInset == ins then return end
    local oldMask = st.mask
    st.maskShapeKey = shapeKey
    st.maskActualR = r
    st.maskInset = ins
    st.mask = targetMask

    for tex in pairs(st.masked) do
        if oldMask then DetachMaskTrack(tex, oldMask) end
        if targetMask ~= oldMask then DetachMaskTrack(tex, targetMask) end
        if oldMask and pendingMasks[tex] and pendingMasks[tex].mask == oldMask then
            pendingMasks[tex] = nil
        end
        if oldMask and stalledMasks[tex] == oldMask then
            stalledMasks[tex] = nil
        end
    end
    if useWhole then
        SetWholeMask(targetMask, EUI_AURA_MASK_DIR .. "round-" .. wholeShape .. ".tga")
    else
        local maskPath, _, actualR = ST.ResolveMaskPath(r)
        SetNineSlice(targetMask, maskPath, actualR, "CLAMPTOBLACKADDITIVE")
    end
    targetMask:ClearAllPoints()
    if ins > 0 then
        targetMask:SetPoint("TOPLEFT", host, "TOPLEFT", ins, -ins)
        targetMask:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -ins, ins)
    else
        targetMask:SetAllPoints(host)
    end
    for tex in pairs(st.masked) do
        if tex and tex.AddMaskTexture then
            AttachMaskSafely(tex, targetMask, host, false, isIconTex[tex] == true, keepLoadedTex[tex] == true)
        end
    end
    if st.roundedSwipeCDs then
        SyncRoundedCooldownSwipe(host, st)
    end
end

-- 统一的空心描边孔洞保护：任一遮罩/填充未加载完前先隐藏 fill，绝不画成未挖空的实心方块盖住图标或卡片文字
function ST.CancelBorderHole(keyObj)
    if not keyObj then return end
    borderHoleSeq = borderHoleSeq + 1
    borderHoleTokens[keyObj] = borderHoleSeq
    pendingBorderHoles[keyObj] = nil
    stalledBorderHoles[keyObj] = nil
end

function ST.AttachBorderHole(keyObj, fillTex, holeMask, outerMask, host, onReady)
    if not (keyObj and fillTex and holeMask) then return false end
    if host then EnsureHostShowHook(host) end
    borderHoleSeq = borderHoleSeq + 1
    local token = borderHoleSeq
    borderHoleTokens[keyObj] = token
    pendingBorderHoles[keyObj] = nil
    stalledBorderHoles[keyObj] = nil

    local lf = TextureLoadState(fillTex)
    local lh = TextureLoadState(holeMask)
    local lo = outerMask and TextureLoadState(outerMask) or true
    if lf == true and lh == true and lo == true then
        if outerMask and fillTex.AddMaskTexture then
            pcall(fillTex.AddMaskTexture, fillTex, outerMask)
        end
        if fillTex.AddMaskTexture then
            pcall(fillTex.AddMaskTexture, fillTex, holeMask)
        end
        fillTex:Show()
        if onReady then pcall(onReady, keyObj) end
        return true
    end
    fillTex:Hide()
    pendingBorderHoles[keyObj] = {
        fill = fillTex,
        hole = holeMask,
        outer = outerMask,
        host = host,
        token = token,
        onReady = onReady,
        tries = 0,
    }
    EnsureMaskWaitFrame():Show()
    return false
end

SyncRoundedCooldownSwipe = function(host, st)
    if not (host and st and st.roundedSwipeCDs and HasEUIRounded()) then return end
    local rad = st.roundedSwipeRadius or st.maskReqR or st.radius or 0
    if rad <= 0 then return end
    local w, h = GetSizeSafe(host)
    if not (w and h) then return end
    local ins = st.maskInset or 0
    local bodyW = math_max(2, w - 2 * ins)
    local bodyH = math_max(2, h - 2 * ins)
    local inner = math_max(1, math_min(16, st.maskReqR or rad))
    local half = math_min(bodyW, bodyH) * 0.5
    if half >= 1 and inner > half then inner = half end
    local gx = math_min(16, math_max(1, math_ceil(32 * inner / bodyW))) - 1
    local gy = math_min(16, math_max(1, math_ceil(32 * inner / bodyH))) - 1
    local uvKey = gx * 32 + gy
    local uvS = st._swipeStart
    local uvE = st._swipeEnd
    if not uvS then
        uvS = { x = 0, y = 0 }
        uvE = { x = 1, y = 1 }
        st._swipeStart = uvS
        st._swipeEnd = uvE
    end
    uvS.x, uvS.y = gx / 16, gy / 16
    uvE.x, uvE.y = (gx + 1) / 16, (gy + 1) / 16
    for cd, lastKey in pairs(st.roundedSwipeCDs) do
        if cd and cd.SetSwipeTexture and cd.SetTexCoordRange
            and not (cd.IsForbidden and cd:IsForbidden()) then
            if lastKey ~= uvKey or roundedSwipes[cd] ~= host then
                pcall(cd.SetSwipeTexture, cd, EUI_AURA_SWIPE)
                pcall(cd.SetTexCoordRange, cd, uvS, uvE)
                st.roundedSwipeCDs[cd] = uvKey
                roundedSwipes[cd] = host
            end
        end
    end
end

function ST.ApplyRoundedCooldownSwipe(host, cd, radius)
    if not (host and cd and cd.SetSwipeTexture and cd.SetTexCoordRange and HasEUIRounded()) then return end
    if cd.IsForbidden and cd:IsForbidden() then return end
    local r = math_floor((radius or 6) + 0.5)
    local st = roundState[host]
    if not st then
        st = { masked = setmetatable({}, { __mode = "k" }) }
        roundState[host] = st
    end
    EnsureHostShowHook(host)
    if r <= 0 then
        ST.ClearRoundedCooldownSwipe(cd)
        if st.roundedSwipeCDs then
            st.roundedSwipeCDs[cd] = nil
            if next(st.roundedSwipeCDs) == nil then
                st.roundedSwipeCDs = nil
                st.roundedSwipeRadius = nil
            end
        end
        return
    end
    if not st.roundedSwipeCDs then
        st.roundedSwipeCDs = setmetatable({}, { __mode = "k" })
    end
    if st.roundedSwipeCDs[cd] == nil then
        st.roundedSwipeCDs[cd] = -1
    end
    st.roundedSwipeRadius = r
    SyncRoundedCooldownSwipe(host, st)
end

function ST.ClearRoundedCooldownSwipe(cd, fallbackSwipe)
    if not cd then return end
    if not roundedSwipes[cd] then return end
    roundedSwipes[cd] = nil
    if cd.IsForbidden and cd:IsForbidden() then return end
    if cd.SetSwipeTexture then
        pcall(cd.SetSwipeTexture, cd, fallbackSwipe or "")
    end
    if cd.SetTexCoordRange then
        pcall(cd.SetTexCoordRange, cd, SWIPE_UV_ZERO, SWIPE_UV_ONE)
    end
end

FitPixelRoundedBorder = function(host, st)
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

    if bf._fittedRPx ~= rPx or (not bf._holeAttached and not pendingBorderHoles[bf]) then
        local fill = bf._tex
        local hole = bf._innerHole
        if not hole then
            hole = bf:CreateMaskTexture()
            bf._innerHole = hole
        end
        ST.CancelBorderHole(bf)
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
        bf._fittedRPx = rPx
        ST.AttachBorderHole(bf, fill, hole, nil, host, function(frame)
            frame._holeAttached = true
        end)
    end

    -- 同步把宿主内部贴图遮罩精确内缩 1 物理像素（px = 1/k），使填充边缘恰好藏在 1px 清晰圆角细框内侧：
    -- 0 渗色灰晕、0 锯齿、0 缝隙！
    if st.radius and st.radius > 0 then
        local pxHost = 1 / k
        local innerBodyR = math_max(1, math_min(16, (rPx - 1) / k))
        ReseatHostBodyMask(host, st, innerBodyR, pxHost)
    end
    if st.roundedSwipeCDs then
        SyncRoundedCooldownSwipe(host, st)
    end
end

local function EnsureScaleWatcher()
    if scaleWatchFrame then return end
    scaleWatchFrame = CreateFrame("Frame")
    scaleWatchFrame:RegisterEvent("UI_SCALE_CHANGED")
    scaleWatchFrame:RegisterEvent("DISPLAY_SIZE_CHANGED")
    scaleWatchFrame:SetScript("OnEvent", function()
        for host, st in pairs(activePixelBorders) do
            if host and st and st.borderFrame and st.borderFrame:IsShown() then
                FitPixelRoundedBorder(host, st)
            end
        end
    end)
end

function ST.SetHostIconMode(host, enabled)
    if not host then return end
    local st = roundState[host]
    if not st then
        st = { masked = setmetatable({}, { __mode = "k" }) }
        roundState[host] = st
    end
    local want = enabled == true
    if st.iconMode ~= want then
        st.iconMode = want
        st.maskShapeKey = nil
        if st.radius and st.radius > 0 then
            if st.borderFrame and st.borderFrame:IsShown() and st.borderReqRadius and st.borderReqRadius > 0 and HasEUIRounded() then
                FitPixelRoundedBorder(host, st)
            else
                ReseatHostBodyMask(host, st, st.radius, st.maskInset or 0)
            end
        end
    end
end

function ST.EnsureRoundedMask(host, radius)
    if not (host and host.CreateMaskTexture) then return nil end
    local r = math_floor((radius or 6) + 0.5)
    local st = roundState[host]
    if not st then
        st = { masked = setmetatable({}, { __mode = "k" }) }
        roundState[host] = st
    end
    EnsureHostShowHook(host)
    if r <= 0 then
        for tex in pairs(st.masked) do
            pendingMasks[tex] = nil
            stalledMasks[tex] = nil
            maskedTexHost[tex] = nil
            isIconTex[tex] = nil
            keepLoadedTex[tex] = nil
            if st.mask then DetachMaskTrack(tex, st.mask) end
            if st.wholeMask and st.wholeMask ~= st.mask then DetachMaskTrack(tex, st.wholeMask) end
            if st.sliceMask and st.sliceMask ~= st.mask then DetachMaskTrack(tex, st.sliceMask) end
        end
        st.masked = setmetatable({}, { __mode = "k" })
        st.radius = 0
        st.maskActualR = nil
        st.maskShapeKey = nil
        st.maskInset = nil
        st.maskReqR = nil
        st.maskSizePending = nil
        return nil
    end
    if st.radius ~= r or not st.mask or not st.maskShapeKey then
        st.radius = r
        if st.borderFrame and st.borderFrame:IsShown() and st.borderReqRadius and st.borderReqRadius > 0 and HasEUIRounded() then
            FitPixelRoundedBorder(host, st)
        end
        if not st.mask or not st.maskShapeKey then
            ReseatHostBodyMask(host, st, r, 0)
        end
    end
    return st.mask
end

function ST.MaskTexture(host, tex, radius, opts)
    if not (host and tex and tex.AddMaskTexture) then return end
    local isIcon = (opts and opts.isIcon == true) or isIconTex[tex] == true
    local keepIfLoaded = (opts and opts.keepIfLoaded == true) or keepLoadedTex[tex] == true
    if opts and opts.isIcon ~= nil then isIconTex[tex] = opts.isIcon == true or nil end
    if opts and opts.keepIfLoaded ~= nil then keepLoadedTex[tex] = opts.keepIfLoaded == true or nil end
    local mask = ST.EnsureRoundedMask(host, radius)
    local st = roundState[host]
    if not (mask and st) then return end
    maskedTexHost[tex] = host
    EnsureTexHooks(tex)
    local pend = pendingMasks[tex]
    if not st.masked[tex] then
        st.masked[tex] = true
        AttachMaskSafely(tex, mask, host, false, isIcon, keepIfLoaded)
    elseif (pend and pend.mask ~= mask) or stalledMasks[tex] or (not pend and attachedMask[tex] ~= mask) then
        AttachMaskSafely(tex, mask, host, false, isIcon, keepIfLoaded)
    end
end

-- 专用于正方形/近正方形动态图标（动作条、冷却管理器、BUFF、Roll 条、拾取、装备一览、武器特效等）：
-- 自动启用 64x64 整图圆角遮罩（无 9 宫格切片）+ 2 帧可见稳态保护。
function ST.MaskIcon(host, tex, radius, opts)
    if not (host and tex and tex.AddMaskTexture) then return end
    if not (opts and opts.keepHostMode) then
        ST.SetHostIconMode(host, true)
    end
    ST.MaskTexture(host, tex, radius, {
        isIcon = true,
        keepIfLoaded = opts and opts.keepIfLoaded == true or false,
    })
end

-- 供自带独立 MaskTexture 的模块（Theme / TooltipStyle / WeaponProcs / CoreHUD / XPBar）复用同一套安全等待与唤醒机制
function ST.AttachCustomMask(host, tex, mask, opts)
    if not (tex and mask and tex.AddMaskTexture) then return end
    local isIcon = opts and opts.isIcon == true or false
    local keepIfLoaded = opts and opts.keepIfLoaded == true or false
    local fromSwap = opts and opts.fromSwap == true or false
    local prev = customMaskSpec[tex]
    if prev and prev.mask and prev.mask ~= mask then
        DetachMaskTrack(tex, prev.mask)
    end
    customMaskSpec[tex] = {
        host = host,
        mask = mask,
        isIcon = isIcon,
        keepIfLoaded = keepIfLoaded,
    }
    if host then
        EnsureHostShowHook(host)
        local set = hostCustomTex[host]
        if not set then
            set = setmetatable({}, { __mode = "k" })
            hostCustomTex[host] = set
        end
        set[tex] = true
    end
    EnsureTexHooks(tex)
    local pend = pendingMasks[tex]
    if fromSwap or (pend and pend.mask ~= mask) or stalledMasks[tex] or (not pend and attachedMask[tex] ~= mask) then
        AttachMaskSafely(tex, mask, host, fromSwap, isIcon, keepIfLoaded)
    end
end

function ST.DetachCustomMask(tex, mask)
    if not tex then return end
    local spec = customMaskSpec[tex]
    local m = mask or (spec and spec.mask)
    if spec then
        if spec.host and hostCustomTex[spec.host] then
            hostCustomTex[spec.host][tex] = nil
        end
        customMaskSpec[tex] = nil
    end
    pendingMasks[tex] = nil
    stalledMasks[tex] = nil
    if m then DetachMaskTrack(tex, m) end
end

-- 全局 C 函数（如 SetPortraitTexture）改图不会走 tex:SetTexture 钩子，调用此接口显式通知重新走安全稳态流程
function ST.NotifyTextureChanged(tex)
    if not tex then return end
    OnMaskedTexChanged(tex)
end

function ST.ClearRoundedMask(host)
    local st = host and roundState[host]
    if not st then return end
    for tex in pairs(st.masked) do
        pendingMasks[tex] = nil
        stalledMasks[tex] = nil
        maskedTexHost[tex] = nil
        isIconTex[tex] = nil
        keepLoadedTex[tex] = nil
        if st.mask then DetachMaskTrack(tex, st.mask) end
        if st.wholeMask and st.wholeMask ~= st.mask then DetachMaskTrack(tex, st.wholeMask) end
        if st.sliceMask and st.sliceMask ~= st.mask then DetachMaskTrack(tex, st.sliceMask) end
    end
    st.masked = setmetatable({}, { __mode = "k" })
    if st.borderFrame then
        ST.CancelBorderHole(st.borderFrame)
        st.borderFrame:Hide()
    end
    if st.roundedSwipeCDs then
        for cd in pairs(st.roundedSwipeCDs) do
            ST.ClearRoundedCooldownSwipe(cd)
        end
        st.roundedSwipeCDs = nil
    end
    st.roundedSwipeRadius = nil
    activePixelBorders[host] = nil
    st.radius = 0
    st.borderReqRadius = 0
    st.maskActualR = nil
    st.maskShapeKey = nil
    st.maskInset = nil
    st.maskReqR = nil
    st.maskSizePending = nil
end

-- 导出给其它直接管遮罩的模块复用（如 TooltipStyle）
ST.TextureLoadState = TextureLoadState

-- 为任意框体建立 1:1 物理像素锐利圆角 1px 同心描边（不修改宿主边框或 NineSlice）
function ST.ApplyRoundedBorder(host, radius, r, g, b, a, levelOffset)
    if not (host and host.CreateTexture) then return nil end
    local rad = math_floor((radius or 6) + 0.5)
    local st = roundState[host]
    if not st then
        st = { masked = setmetatable({}, { __mode = "k" }) }
        roundState[host] = st
    end
    EnsureHostShowHook(host)
    if rad <= 0 then
        st.borderReqRadius = 0
        activePixelBorders[host] = nil
        if st.borderFrame then
            ST.CancelBorderHole(st.borderFrame)
            st.borderFrame:Hide()
        end
        if st.radius and st.radius > 0 then
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
