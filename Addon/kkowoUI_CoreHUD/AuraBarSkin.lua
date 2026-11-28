----------------------------------------------------------------------
--  kkowoUI — Modules/AuraBarSkin.lua
--  小地图左侧增益 / 减益图标现代圆角美化（零污染 BuffFrame / DebuffFrame）：
--    • 绝不向 BuffFrame / DebuffFrame 暴雪全局表写入任何自定义字段（全弱表）
--    • 严格按 btn.Icon 正方形区域建立独立 iconWrap 套壳（不包入底部倒计时空白区）
--    • 现代高清裁边（0.08~0.92）+ GPU 9 宫格圆角遮罩 + 1px 暗灰/减益类型语义色描边
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_floor, math_max, math_min, pcall, setmetatable, tostring, type =
    ipairs, math.floor, math.max, math.min, pcall, setmetatable, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("auraBarSkin", {
    title = "增益栏美化",
    desc = "美化小地图左侧增益与减益图标，应用圆角描边与清晰计时。",
    group = "motion",
    order = 6,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        radius = 5,
        showShadow = true,
        colorDebuffBorder = true,
        expireThreshold = 5,
    },
})

local ROOT_NAMES = { "BuffFrame", "DebuffFrame" }
local skinned = setmetatable({}, { __mode = "k" })
local origBorderAlpha = setmetatable({}, { __mode = "k" })
local origCountStyle = setmetatable({}, { __mode = "k" })
local origDurationStyle = setmetatable({}, { __mode = "k" })
local hookedRoots = setmetatable({}, { __mode = "k" })
local iconTexHooked = setmetatable({}, { __mode = "k" })
local buttonList = {}
local AURA_EXPIRE_TICK_KEY = "kkowoUI_AuraFeel_Expire"
local QueueRefresh -- 前向声明

local BORDER_KEYS = { "Border", "DebuffBorder", "TempEnchantBorder" }

local function SetSquareBorder(ov, show, r, g, b, a)
    if not ov or not ov.wrap then return end
    if show and not ov.sqEdges then
        local edges = {}
        local specs = {
            { "TOPLEFT", "TOPRIGHT", nil, 1 },
            { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
            { "TOPLEFT", "BOTTOMLEFT", 1, nil },
            { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
        }
        for i, sp in ipairs(specs) do
            local ln = ov.wrap:CreateTexture(nil, "OVERLAY", nil, 4)
            ln:SetPoint(sp[1], ov.wrap, sp[1])
            ln:SetPoint(sp[2], ov.wrap, sp[2])
            if sp[3] then ln:SetWidth(sp[3]) end
            if sp[4] then ln:SetHeight(sp[4]) end
            edges[i] = ln
        end
        ov.sqEdges = edges
    end
    if ov.sqEdges then
        for _, ln in ipairs(ov.sqEdges) do
            if show then
                ln:SetColorTexture(r, g, b, a)
                ln:Show()
            else
                ln:Hide()
            end
        end
    end
end

local function IsSafe(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function ResolveBorderColor(btn, isDebuff)
    if not isDebuff or mod:GetDB().colorDebuffBorder == false then
        return 0.14, 0.16, 0.22, 0.90
    end
    local b = btn.Border or btn.DebuffBorder
    if b and b.GetVertexColor then
        local ok, r, g, bCol = pcall(b.GetVertexColor, b)
        r = ok and F.PlainNumber(r, nil) or nil
        g = ok and F.PlainNumber(g, nil) or nil
        bCol = ok and F.PlainNumber(bCol, nil) or nil
        if r and g and bCol and not (r > 0.92 and g > 0.92 and bCol > 0.92) then
            return r, g, bCol, 0.96
        end
    end
    return 0.88, 0.26, 0.30, 0.95
end

-- 2f 增益滑入与快到期柔和脉动（严格零污染：全部状态收在弱表 ov 中，不写任何暴雪按钮字段）
local function StopAuraFeel(btn, ov)
    if not ov then return end
    if ov.nativeShownReg and btn and btn.RemoveAuraShownAnimation and ov.slideAG then
        pcall(btn.RemoveAuraShownAnimation, btn, ov.slideAG)
        ov.nativeShownReg = false
    end
    if ov.slideAG and ov.slideAG:IsPlaying() then
        ov.slideAG:Stop()
    end
    if ov.expPulseAG then
        if ov.expPulseAG:IsPlaying() then ov.expPulseAG:Stop() end
        if M and M.UnregisterLoopAnim then M.UnregisterLoopAnim(ov.expPulseAG) end
    end
    if ov.expGlow then
        ov.expGlow:Hide()
    end
    ov.expiring = false
end

local function EnsureAuraFeelAnims(btn, ov, rad)
    if not (ov and ov.wrap) then return end
    local want = mod._active == true and ST.IsFXEnabled("fx_auraFeel")
    if not want then
        StopAuraFeel(btn, ov)
        return
    end

    -- 1) 滑入动画（Translation + Alpha，不用 Scale 防怪癖 6）
    local isSoft = ST.GetFXIntensity() == "soft"
    local dx = isSoft and 4 or 6
    if not ov.slideAG then
        local ag = ov.wrap:CreateAnimationGroup()
        local jump = ag:CreateAnimation("Translation")
        jump:SetOrder(1)
        jump:SetOffset(dx, 0)
        jump:SetDuration(0)
        local slide = ag:CreateAnimation("Translation")
        slide:SetOrder(2)
        slide:SetOffset(-dx, 0)
        slide:SetDuration(0.18)
        slide:SetSmoothing("OUT")
        local fade = ag:CreateAnimation("Alpha")
        fade:SetOrder(2)
        fade:SetFromAlpha(0)
        fade:SetToAlpha(1)
        fade:SetDuration(0.18)
        fade:SetSmoothing("OUT")
        ag:SetScript("OnFinished", function() ov.wrap:SetAlpha(1) end)
        ag:SetScript("OnStop", function() ov.wrap:SetAlpha(1) end)
        ag._jump = jump
        ag._slide = slide
        ov.slideAG = ag
    else
        ov.slideAG._jump:SetOffset(dx, 0)
        ov.slideAG._slide:SetOffset(-dx, 0)
    end

    -- 优先交给客户端 AddAuraShownAnimation（按钮受限时仍可播），否则在 OnShow / 新光环实例时触发
    if type(btn.AddAuraShownAnimation) == "function" and type(btn.RemoveAuraShownAnimation) == "function" then
        if not ov.nativeShownReg then
            local okAdd = pcall(btn.AddAuraShownAnimation, btn, ov.slideAG)
            if okAdd then ov.nativeShownReg = true end
        end
    else
        if not ov.showHooked and btn.HookScript then
            ov.showHooked = true
            pcall(btn.HookScript, btn, "OnShow", function(self)
                local o = skinned[self]
                if o and o.slideAG and mod._active and ST.IsFXEnabled("fx_auraFeel") then
                    o.slideAG:Stop()
                    o.slideAG:Play()
                end
            end)
        end
        local info = btn.buttonInfo
        local instID = (type(info) == "table" and not F.IsSecret(info)) and F.PlainNumber(info.auraInstanceID, nil) or nil
        if instID and ov.lastAuraID ~= instID then
            local hadPrev = (ov.lastAuraID ~= nil)
            ov.lastAuraID = instID
            if hadPrev or btn:IsShown() then
                ov.slideAG:Stop()
                ov.slideAG:Play()
            end
        end
    end

    -- 2) 快到期柔光叠加层（不改图标尺寸与间距，BOUNCE 透明度动画 0.6..1.0，周期 ~1.2s）
    if not ov.expGlow then
        local glow = ov.wrap:CreateTexture(nil, "OVERLAY", nil, 5)
        glow:SetAllPoints(ov.wrap)
        glow:SetTexture(ST.TEX.FLAT)
        glow:SetBlendMode("ADD")
        glow:SetVertexColor(1.00, 0.72, 0.28, 1)
        glow:Hide()
        ov.expGlow = glow
        ov.expGlowRad = -1
    end
    if rad > 0 and ov.expGlowRad ~= rad then
        ST.MaskTexture(ov.wrap, ov.expGlow, rad)
        ov.expGlowRad = rad
    end
    local scale = ST.GetFXScale()
    local minA = 0.20 * scale
    local maxA = 0.34 * scale
    ov.expPulseAG = M and M.EnsurePulseAlpha and M.EnsurePulseAlpha(ov.expGlow, minA, maxA, 1.2) or ov.expPulseAG
end

local function ReadAuraRemainingSeconds(btn, now)
    local info = btn and btn.buttonInfo
    if type(info) ~= "table" or F.IsSecret(info) then return nil, false end
    -- 优先 12.x duration 对象 API（若存在）
    local instID = F.PlainNumber(info.auraInstanceID, nil)
    local UA = _G.C_UnitAuras
    if instID and UA and type(UA.GetAuraDuration) == "function" then
        local okD, durObj = pcall(UA.GetAuraDuration, "player", instID)
        if okD and durObj and type(durObj) == "table" and durObj.GetRemainingDuration then
            local okR, rawRem = pcall(durObj.GetRemainingDuration, durObj)
            if okR and not F.IsSecret(rawRem) then
                local rNum = F.PlainNumber(rawRem, nil)
                if rNum then return rNum, true end
            end
        end
    end
    local exp = F.PlainNumber(info.expirationTime, nil)
    local dur = F.PlainNumber(info.duration, nil)
    if exp and dur and dur > 0 and exp > 0 then
        return exp - now, true
    end
    return nil, false
end

local function TickExpiringAuras(now)
    if not (mod._active and ST.IsFXEnabled("fx_auraFeel")) then
        for _, btn in ipairs(buttonList) do
            local ov = skinned[btn]
            if ov and ov.expGlow then
                if ov.expPulseAG and ov.expPulseAG:IsPlaying() then ov.expPulseAG:Stop() end
                ov.expGlow:Hide()
                ov.expiring = false
            end
        end
        return false
    end
    local thresh = F.PlainNumber(mod:GetDB().expireThreshold, 5) or 5
    local anyTimed = false
    for _, btn in ipairs(buttonList) do
        if IsSafe(btn) and btn:IsShown() then
            local ov = skinned[btn]
            if ov and ov.expGlow then
                local rem, hasDur = ReadAuraRemainingSeconds(btn, now)
                if hasDur then
                    anyTimed = true
                end
                local wantPulse = (rem ~= nil and rem > 0 and rem <= thresh)
                if wantPulse then
                    ov.expGlow:Show()
                    if ov.expPulseAG and not ov.expPulseAG:IsPlaying() then
                        ov.expPulseAG:Play()
                        if M and M.RegisterLoopAnim then
                            M.RegisterLoopAnim(ov.expPulseAG, function()
                                return mod._active and ov.expiring == true and ov.expGlow:IsVisible()
                            end)
                        end
                    end
                    ov.expiring = true
                elseif ov.expiring or ov.expGlow:IsShown() then
                    if ov.expPulseAG and ov.expPulseAG:IsPlaying() then ov.expPulseAG:Stop() end
                    if M and M.UnregisterLoopAnim and ov.expPulseAG then M.UnregisterLoopAnim(ov.expPulseAG) end
                    ov.expGlow:Hide()
                    ov.expiring = false
                end
            end
        end
    end
    return anyTimed
end

local function SafeDetachIconMask(icon, ov)
    if ov and ov.iconMask and icon and type(icon.RemoveMaskTexture) == "function" then
        pcall(icon.RemoveMaskTexture, icon, ov.iconMask)
    end
    if ov then
        ov.maskAttached = false
        ov.maskShapeKey = nil
    end
end

-- 在 icon:GetParent()（即 btn）上创建并挂载 64x64 整图圆角遮罩（全弱表零污染、绝不碰 SetTextureSliceMargins），
-- 返回 (maskOK, okAdd, numMasks, maskLoaded, iconLoaded) 供视觉兜底与诊断使用。
local function ApplyWholeIconMaskOnParent(btn, icon, ov, rad)
    local iconParent = (icon.GetParent and icon:GetParent()) or btn
    if not (IsSafe(iconParent) and type(iconParent.CreateMaskTexture) == "function" and type(icon.AddMaskTexture) == "function") then
        ov.lastOkAdd, ov.lastNumMasks, ov.lastMaskLoaded, ov.lastIconLoaded, ov.lastMaskOK = false, nil, false, nil, false
        return false
    end

    -- 分离暴雪原生自带的 IconMask（如有），防止被置空/叠裁
    local blizzMask = btn.IconMask
    if blizzMask and type(icon.RemoveMaskTexture) == "function" then
        pcall(icon.RemoveMaskTexture, icon, blizzMask)
    end

    if not ov.iconMask or ov.iconMaskParent ~= iconParent then
        SafeDetachIconMask(icon, ov)
        local okM, m = pcall(iconParent.CreateMaskTexture, iconParent)
        if not (okM and m) then
            ov.lastOkAdd, ov.lastNumMasks, ov.lastMaskLoaded, ov.lastIconLoaded, ov.lastMaskOK = false, nil, false, nil, false
            return false
        end
        if m.SetBlockingLoadsRequested then
            pcall(m.SetBlockingLoadsRequested, m, true)
        end
        ov.iconMask = m
        ov.iconMaskParent = iconParent
        ov.maskShapeKey = nil
        ov.maskAttached = false
    end

    local m = ov.iconMask
    local w = F.PlainNumber(icon.GetWidth and icon:GetWidth(), nil) or F.PlainNumber(btn.GetWidth and btn:GetWidth(), 30) or 30
    local h = F.PlainNumber(icon.GetHeight and icon:GetHeight(), nil) or F.PlainNumber(btn.GetHeight and btn:GetHeight(), 30) or 30
    if w < 8 then w = 30 end
    if h < 8 then h = 30 end
    local px = (ST.GetPixel and ST.GetPixel(iconParent)) or 1
    if not px or px <= 0 then px = 1 end
    local innerR = math_max(1, math_min(rad, math_floor(math_min(w, h) * 0.45)))
    local shapeKey = string_format("%d:%d:%d:%.2f", innerR, math_floor(w + 0.5), math_floor(h + 0.5), px)

    if ov.maskShapeKey ~= shapeKey then
        if ov.maskAttached and type(icon.RemoveMaskTexture) == "function" then
            pcall(icon.RemoveMaskTexture, icon, m)
            ov.maskAttached = false
        end
        local usedShape = ST.SetWholeIconMask and ST.SetWholeIconMask(m, innerR, w, h, px) or nil
        if not usedShape and ST.SetWholeMask then
            ST.SetWholeMask(m, (innerR >= 5) and ST.TEX.PILL_MASK_6 or ST.TEX.PILL_MASK)
        end
        m:ClearAllPoints()
        m:SetPoint("TOPLEFT", icon, "TOPLEFT", px, -px)
        m:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -px, px)
        ov.maskShapeKey = shapeKey
    end

    -- 核验遮罩纹理加载态与图标加载态（绝不对机密 IsObjectLoaded 抛错或做布尔测试）
    local maskLoaded = true
    if ST.TextureLoadState then
        local stM = ST.TextureLoadState(m)
        if stM == false then maskLoaded = false end
    end
    local iconLoaded = ST.TextureLoadState and ST.TextureLoadState(icon) or true

    if not maskLoaded then
        ov.lastOkAdd, ov.lastNumMasks, ov.lastMaskLoaded, ov.lastIconLoaded, ov.lastMaskOK = false, nil, false, iconLoaded, false
        if C_Timer and C_Timer.After and not ov.maskRetryArmed then
            ov.maskRetryArmed = true
            C_Timer.After(0, function()
                ov.maskRetryArmed = false
                if mod._active and QueueRefresh then QueueRefresh() end
            end)
        end
        return false
    end

    -- 轻量 hook icon:SetTexture（仅挂一次、零污染），BuffFrame 刷新换图时及时复核遮罩
    if not iconTexHooked[icon] and type(icon.SetTexture) == "function" then
        iconTexHooked[icon] = true
        _G.hooksecurefunc(icon, "SetTexture", function(selfTex)
            if not mod._active then return end
            local par = selfTex.GetParent and selfTex:GetParent() or nil
            local stOv = par and skinned[par] or nil
            if not (stOv and stOv.iconMask and (stOv.lastRad or 0) > 0) then return end
            if not stOv.texResyncArmed and C_Timer and C_Timer.After then
                stOv.texResyncArmed = true
                C_Timer.After(0, function()
                    stOv.texResyncArmed = false
                    if mod._active and IsSafe(par) and par:IsShown() then
                        local okRe = pcall(selfTex.AddMaskTexture, selfTex, stOv.iconMask)
                        if okRe then stOv.maskAttached = true end
                    end
                end)
            end
        end)
    end

    local okAdd = pcall(icon.AddMaskTexture, icon, m)
    local numMasks = nil
    if type(icon.GetNumMaskTextures) == "function" then
        local okN, rawN = pcall(icon.GetNumMaskTextures, icon)
        if okN then numMasks = F.PlainNumber(rawN, nil) end
    end
    local maskOK = (okAdd == true) and (numMasks == nil or numMasks > 0)
    ov.maskAttached = maskOK
    ov.lastOkAdd = okAdd == true
    ov.lastNumMasks = numMasks
    ov.lastMaskLoaded = maskLoaded
    ov.lastIconLoaded = iconLoaded
    ov.lastMaskOK = maskOK
    return maskOK
end

local function SkinAuraButton(btn, isDebuff)
    if not IsSafe(btn) then return end
    local icon = btn.Icon or btn.icon
    if not (icon and icon.SetTexCoord) then return end

    local db = mod:GetDB()
    local rad = math_max(0, math_min(10, F.PlainNumber(db.radius, ST.GetCornerRadius(5)) or 5))

    -- 清除任何可能残留在外层 btn（含底部文字高度）上的旧 ST 遮罩/边框，只作用于 icon 正方形本身
    ST.ClearRoundedMask(btn)

    local ov = skinned[btn]
    if not mod._active then
        StopAuraFeel(btn, ov)
        SafeDetachIconMask(icon, ov)
        if ov then
            ov.lastRad = 0
            ov.lastMode = "disabled"
        end
        if ov and ov.wrap then
            ST.ClearRoundedMask(ov.wrap)
            SetSquareBorder(ov, false)
            ov.wrap:Hide()
        end
        if ov and ov.bgHost then
            ST.ClearRoundedMask(ov.bgHost)
            ov.bgHost:Hide()
        end
        if ov and ov.bg then ov.bg:Hide() end
        pcall(icon.SetTexCoord, icon, 0, 1, 0, 1)
        for _, bk in ipairs(BORDER_KEYS) do
            local brd = btn[bk]
            if brd and origBorderAlpha[brd] ~= nil and brd.SetAlpha then
                pcall(brd.SetAlpha, brd, origBorderAlpha[brd])
            end
        end
        local cnt = btn.Count
        local oc = cnt and origCountStyle[cnt]
        if cnt and oc then
            if oc.face and cnt.SetFont then pcall(cnt.SetFont, cnt, oc.face, oc.size, oc.flags) end
            if oc.r and cnt.SetTextColor then pcall(cnt.SetTextColor, cnt, oc.r, oc.g, oc.b, oc.a) end
        end
        local durFS = btn.Duration or btn.duration
        local od = durFS and origDurationStyle[durFS]
        if durFS and od and od.face and durFS.SetFont then
            pcall(durFS.SetFont, durFS, od.face, od.size, od.flags)
        end
        return
    end

    if not ov then
        ov = {}
        -- 严格贴合 icon 正方形的独立包装框，绝不把底部倒计时留白框进圆角里
        local wrap = CreateFrame("Frame", nil, btn)
        wrap:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
        wrap:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
        wrap:EnableMouse(false)
        local lvl = F.PlainNumber(btn.GetFrameLevel and btn:GetFrameLevel(), 5) or 5
        wrap:SetFrameLevel(lvl + 1)

        -- 独立外扩 1px 底衬遮罩宿主，避免被 wrap 内缩圆角遮罩裁成不可见
        local bgHost = CreateFrame("Frame", nil, btn)
        bgHost:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        bgHost:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        bgHost:EnableMouse(false)
        bgHost:SetFrameLevel(lvl)

        local bg = bgHost:CreateTexture(nil, "BACKGROUND", nil, -6)
        bg:SetAllPoints(bgHost)
        bg:SetColorTexture(0.03, 0.035, 0.045, 0.72)

        ov.wrap = wrap
        ov.bgHost = bgHost
        ov.bg = bg
        skinned[btn] = ov
        buttonList[#buttonList + 1] = btn
    end

    ov.lastRad = rad
    ov.wrap:ClearAllPoints()
    ov.wrap:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
    ov.wrap:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
    ov.wrap:Show()
    if ov.bgHost then
        ov.bgHost:ClearAllPoints()
        ov.bgHost:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        ov.bgHost:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        ov.bgHost:Show()
    end

    pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)

    -- 静音暴雪厚重方形原生边框（含 Border / DebuffBorder / TempEnchantBorder），改由 1px 描边呈现
    for _, bk in ipairs(BORDER_KEYS) do
        local brd = btn[bk]
        if brd and brd.SetAlpha then
            if origBorderAlpha[brd] == nil and brd.GetAlpha then
                local okA, a = pcall(brd.GetAlpha, brd)
                origBorderAlpha[brd] = (okA and F.PlainNumber(a, 1)) or 1
            end
            pcall(brd.SetAlpha, brd, 0)
        end
    end

    -- 仅在父框体建遮罩且实测 AddMaskTexture 生效时才绘制圆角描边；
    -- 否则无条件退回 1px 干净直角细框与方形底衬，100% 杜绝「圆框压方图」四角外露！
    local maskOK = false
    if rad > 0 then
        maskOK = ApplyWholeIconMaskOnParent(btn, icon, ov, rad)
    else
        SafeDetachIconMask(icon, ov)
        ov.lastOkAdd, ov.lastNumMasks, ov.lastMaskOK = false, 0, false
    end

    local effectiveRad = (rad > 0 and maskOK) and rad or 0
    local r, g, b, a = ResolveBorderColor(btn, isDebuff)
    if effectiveRad > 0 then
        ov.lastMode = "rounded"
        SetSquareBorder(ov, false)
        ST.SetHostIconMode(ov.wrap, true)
        ST.ApplyRoundedBorder(ov.wrap, effectiveRad, r, g, b, a, 4)
    else
        ov.lastMode = (rad > 0) and "square-fallback" or "square"
        SafeDetachIconMask(icon, ov)
        ST.ClearRoundedMask(ov.wrap)
        SetSquareBorder(ov, true, r, g, b, a)
    end

    if ov.bg then
        local showSh = db.showShadow ~= false
        ov.bg:SetShown(showSh)
        if showSh and effectiveRad > 0 and ov.bgHost then
            ST.MaskTexture(ov.bgHost, ov.bg, math_min(12, effectiveRad + 1))
        elseif ov.bgHost then
            ST.ClearRoundedMask(ov.bgHost)
        end
    end

    if btn.Count and btn.Count.SetFont then
        if not origCountStyle[btn.Count] then
            local rec = {}
            if btn.Count.GetFont then
                local okF, face, sz, fl = pcall(btn.Count.GetFont, btn.Count)
                if okF and type(face) == "string" and face ~= "" then
                    rec.face, rec.size, rec.flags = face, F.PlainNumber(sz, 12) or 12, F.PlainString(fl, "") or ""
                end
            end
            if btn.Count.GetTextColor then
                local okC, cr, cg, cb, ca = pcall(btn.Count.GetTextColor, btn.Count)
                if okC then
                    rec.r = F.PlainNumber(cr, 1) or 1
                    rec.g = F.PlainNumber(cg, 1) or 1
                    rec.b = F.PlainNumber(cb, 1) or 1
                    rec.a = F.PlainNumber(ca, 1) or 1
                end
            end
            origCountStyle[btn.Count] = rec
        end
        F.Theme.ApplyFont(btn.Count, 11, "OUTLINE", 1, 0.96, 0.80, 1)
    end

    local durFS = btn.Duration or btn.duration
    if durFS and durFS.SetFont then
        if not origDurationStyle[durFS] then
            local rec = {}
            if durFS.GetFont then
                local okF, face, sz, fl = pcall(durFS.GetFont, durFS)
                if okF and type(face) == "string" and face ~= "" then
                    rec.face, rec.size, rec.flags = face, F.PlainNumber(sz, 11) or 11, F.PlainString(fl, "") or ""
                end
            end
            origDurationStyle[durFS] = rec
        end
        F.Theme.ApplyFont(durFS, 10, "OUTLINE")
    end

    EnsureAuraFeelAnims(btn, ov, effectiveRad)
end

local function VisitContainer(c, isDebuff, seen)
    if not (IsSafe(c) and c.GetChildren) then return end
    for _, ch in ipairs({ c:GetChildren() }) do
        if IsSafe(ch) and not seen[ch] and (ch.Icon or ch.icon) then
            seen[ch] = true
            SkinAuraButton(ch, isDebuff)
        end
    end
end

local function EnsureRootHooks(root)
    if not IsSafe(root) or hookedRoots[root] then return end
    hookedRoots[root] = true
    local function OnRootUpdate()
        if mod._active and QueueRefresh then QueueRefresh() end
    end
    for _, m in ipairs({ "UpdateAuras", "UpdateAuraButtons", "Update" }) do
        if type(root[m]) == "function" then
            _G.hooksecurefunc(root, m, OnRootUpdate)
        end
    end
    if root.HookScript then
        pcall(root.HookScript, root, "OnShow", OnRootUpdate)
    end
end

local function RefreshAllAuras()
    local seen = {}
    for idx, rootName in ipairs(ROOT_NAMES) do
        local isDebuff = (idx == 2)
        local root = _G[rootName]
        if IsSafe(root) then
            if mod._active then EnsureRootHooks(root) end
            if type(root.auraFrames) == "table" then
                for _, btn in ipairs(root.auraFrames) do
                    if IsSafe(btn) and not seen[btn] then
                        seen[btn] = true
                        SkinAuraButton(btn, isDebuff)
                    end
                end
            end
            VisitContainer(root.AuraContainer, isDebuff, seen)
            VisitContainer(root, isDebuff, seen)
        end
    end
    if mod._active and ST.IsFXEnabled("fx_auraFeel") and M and M.RegisterTextTick then
        if TickExpiringAuras(GetTime()) then
            M.RegisterTextTick(AURA_EXPIRE_TICK_KEY, 0.25, TickExpiringAuras)
        else
            M.UnregisterTextTick(AURA_EXPIRE_TICK_KEY)
        end
    elseif M and M.UnregisterTextTick then
        M.UnregisterTextTick(AURA_EXPIRE_TICK_KEY)
    end
end

QueueRefresh = F.Debounce(0.06, RefreshAllAuras)

function mod:OnEnable()
    self:RegisterUnitEvent("UNIT_AURA", "player", QueueRefresh)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        QueueRefresh()
        C_Timer.After(0.8, function() if mod._active then RefreshAllAuras() end end)
    end)
    RefreshAllAuras()
end

function mod:OnDisable()
    if M and M.UnregisterTextTick then
        M.UnregisterTextTick(AURA_EXPIRE_TICK_KEY)
    end
    for _, btn in ipairs(buttonList) do
        if IsSafe(btn) then
            SkinAuraButton(btn, false)
        end
    end
end

function mod:OnRefresh()
    RefreshAllAuras()
end

function mod:OnThemeChanged()
    RefreshAllAuras()
end

-- 只读诊断（/kk auraskin）：输出 BuffFrame/DebuffFrame 按钮数、遮罩挂载与加载状态，战斗中亦可安全执行
function mod:DumpDiagnostics()
    local total, rounded, fallback, shown = 0, 0, 0, 0
    local sample = nil
    for _, btn in ipairs(buttonList) do
        if IsSafe(btn) then
            total = total + 1
            local ov = skinned[btn]
            local isSh = false
            if btn.IsShown then
                local okS, s = pcall(btn.IsShown, btn)
                if okS and not F.IsSecret(s) and s == true then isSh = true end
            end
            if isSh then shown = shown + 1 end
            if ov then
                if ov.lastMode == "rounded" then rounded = rounded + 1
                elseif ov.lastMode == "square-fallback" then fallback = fallback + 1 end
                if (not sample) or (isSh and not sample.shown) then
                    sample = {
                        shown = isSh,
                        okAdd = ov.lastOkAdd,
                        numMasks = ov.lastNumMasks,
                        iconLoaded = ov.lastIconLoaded,
                        maskLoaded = ov.lastMaskLoaded,
                        mode = ov.lastMode,
                    }
                end
            end
        end
    end
    local info = string_format(
        "AuraBarSkin 诊断：总按钮=%d 可见=%d 真圆角=%d 方形降级=%d",
        total, shown, rounded, fallback
    )
    if sample then
        info = info .. string_format(
            " | 样本: okAdd=%s numMasks=%s iconLoaded=%s maskLoaded=%s mode=%s",
            tostring(sample.okAdd), tostring(sample.numMasks),
            tostring(sample.iconLoaded), tostring(sample.maskLoaded), tostring(sample.mode)
        )
    end
    F.Print(info)
    return { total = total, shown = shown, rounded = rounded, fallback = fallback, sample = sample }
end

-- 供离线回归测试只读读取弱表状态（零污染暴雪按钮）
function mod:_GetSkinState(btn)
    return btn and skinned[btn] or nil
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "slider",
        text = "增益图标圆角半径（px）",
        min = 0, max = 10, step = 1,
        getValue = function() return F.PlainNumber(db.radius, 5) or 5 end,
        setValue = function(v) db.radius = math_floor(v + 0.5); RefreshAllAuras() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "减益类型着色",
        tooltip = "魔法蓝、诅咒紫、中毒绿、疾病棕、物理/流血红，一目了然。",
        getValue = function() return db.colorDebuffBorder ~= false end,
        setValue = function(v) db.colorDebuffBorder = v == true; RefreshAllAuras() end,
    }, {
        type = "toggle",
        text = "柔和暗色底衬",
        getValue = function() return db.showShadow ~= false end,
        setValue = function(v) db.showShadow = v == true; RefreshAllAuras() end,
    })
    y = y - h

    return y
end
