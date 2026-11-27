----------------------------------------------------------------------
--  kkowoUI — Modules/LowHealthAlert.lua
--  低血量沉浸预警：
--    • 全屏四边柔和渐变深红呼吸暗角（Screen Vignette，0 畸变自适应任意分辨率）
--    • 12.x 保密值双通道：常规态精确阈值触发 + 音效；受限保密态 C_CurveUtil C端求值零报错
--    • 联动核心血条微频脉冲 + 支持自定义音频/语音路径
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local math_max, math_min, pcall, tostring, type = math.max, math.min, pcall, tostring, type
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("lowHealthAlert", {
    title = "低血量全屏呼吸暗角预警",
    desc = "玩家生命值低于阈值时，屏幕四周浮现柔和深红渐变呼吸暗角并触发血条微频警报（兼容 12.x 保密值，支持自定义音效路径）。",
    group = "motion",
    order = 15,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        threshold = 30,       -- 触发百分比阈值（10% ~ 60%）
        combatOnly = false,   -- 是否仅在战斗中生效
        maxAlpha = 0.78,      -- 暗角最大不透明度
        edgeDepth = 150,      -- 四边渐变侵入深度（px）
        pulseBar = true,      -- 联动核心血条微频呼吸闪烁
        playSound = false,    -- 可选低血量音效提醒
        soundKit = 8959,      -- 默认暴雪团队警告音（自定义路径留空时使用）
        customSoundPath = "", -- 可选自定义 mp3/ogg/wav 路径，如 Interface\AddOns\kkowoUI\Media\SpellSounds\lowhp.mp3
    },
})

local vignetteFrame = nil
local pulseAG = nil
local isLowNow = false
local previewing = false
local lastSoundAt = 0
local cachedCurve = nil
local cachedCurveThr = nil

local function BuildVignette()
    if vignetteFrame then return end
    local f = CreateFrame("Frame", "kkowoUI_LowHealthVignette", _G.UIParent)
    f:SetAllPoints(_G.UIParent)
    f:SetFrameStrata("LOW")
    f:SetFrameLevel(0)
    f:EnableMouse(false)
    f:SetAlpha(0)
    f:Hide()

    local function MakeEdge()
        local t = f:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(ST.TEX.VIGNETTE)
        t:SetBlendMode("ADD")
        return t
    end

    -- 四边各自旋转 UV 指向屏幕中心（原图顶部实心、底部透明）
    local topE = MakeEdge()
    topE:SetPoint("TOPLEFT", f, "TOPLEFT")
    topE:SetPoint("TOPRIGHT", f, "TOPRIGHT")
    topE:SetTexCoord(0, 1, 0, 1)

    local botE = MakeEdge()
    botE:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT")
    botE:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT")
    botE:SetTexCoord(0, 1, 1, 0)

    local leftE = MakeEdge()
    leftE:SetPoint("TOPLEFT", f, "TOPLEFT")
    leftE:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT")
    -- 旋转 90° 让原图顶边贴在屏幕最左
    leftE:SetTexCoord(0, 0,  1, 0,  0, 1,  1, 1)

    local rightE = MakeEdge()
    rightE:SetPoint("TOPRIGHT", f, "TOPRIGHT")
    rightE:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT")
    rightE:SetTexCoord(0, 1,  1, 1,  0, 0,  1, 0)

    f._edges = { topE, botE, leftE, rightE }
    pulseAG = M.EnsurePulseAlpha(f, 0.32, 0.90, 1.15)
    vignetteFrame = f
end

local function ApplyVignetteGeom()
    if not vignetteFrame then return end
    local db = mod:GetDB()
    local depth = math_max(60, math_min(280, F.PlainNumber(db.edgeDepth, 150) or 150))
    local maxA = math_max(0.20, math_min(1.0, F.PlainNumber(db.maxAlpha, 0.78) or 0.78))
    local e = vignetteFrame._edges
    e[1]:SetHeight(depth)
    e[2]:SetHeight(depth)
    e[3]:SetWidth(depth)
    e[4]:SetWidth(depth)
    if pulseAG and pulseAG._al then
        pulseAG._al:SetFromAlpha(maxA * 0.36)
        pulseAG._al:SetToAlpha(maxA)
    end
end

local function PaintEdgesColor(r, g, b, a)
    if not vignetteFrame then return end
    for i = 1, 4 do
        vignetteFrame._edges[i]:SetVertexColor(r, g, b, a or 1)
    end
end

local function PlayLowHealthAudio()
    local db = mod:GetDB()
    if not db.playSound then return end
    local now = GetTime()
    if now - lastSoundAt < 4.0 then return end
    lastSoundAt = now
    local custom = F.PlainString(db.customSoundPath, "") or ""
    if custom ~= "" and _G.PlaySoundFile then
        pcall(_G.PlaySoundFile, custom, "Master")
    elseif _G.PlaySound then
        pcall(_G.PlaySound, F.PlainNumber(db.soundKit, 8959) or 8959, "Master")
    end
end

local function EnsureSecretCurve(thrFrac)
    if cachedCurve and cachedCurveThr == thrFrac then return cachedCurve end
    if not (_G.C_CurveUtil and _G.C_CurveUtil.CreateColorCurve and _G.CreateColor) then
        return nil
    end
    local ok, curve = pcall(_G.C_CurveUtil.CreateColorCurve)
    if not (ok and curve) then return nil end
    local c = ST.COLORS.vignette
    pcall(curve.AddPoint, curve, 0.0, _G.CreateColor(c[1], c[2], c[3], 1))
    pcall(curve.AddPoint, curve, thrFrac, _G.CreateColor(c[1], c[2], c[3], 1))
    pcall(curve.AddPoint, curve, math_min(1.0, thrFrac + 0.0002), _G.CreateColor(0, 0, 0, 1))
    pcall(curve.AddPoint, curve, 1.0, _G.CreateColor(0, 0, 0, 1))
    cachedCurve = curve
    cachedCurveThr = thrFrac
    return curve
end

local inSecretMode = false
local previewGen = 0

local function SetVignetteActive(on)
    if not vignetteFrame then return end
    local core = F.Modules.Get("coreHUD")
    local maxA = math_max(0.25, math_min(1.0, F.PlainNumber(mod:GetDB().maxAlpha, 0.78) or 0.78))
    if on then
        local c = ST.COLORS.vignette
        PaintEdgesColor(c[1], c[2], c[3], 1)
        -- 先中止可能仍在进行的淡出，并保持可读基础透明度，确保之后关闭时 0.35s 淡出动画能平滑过渡
        F.Theme.FadeTo(vignetteFrame, maxA * 0.70, 0)
        if not vignetteFrame:IsShown() then
            vignetteFrame:Show()
        end
        if pulseAG and not pulseAG:IsPlaying() then pulseAG:Play() end
        if core and core.SetLowHealthPulse and mod:GetDB().pulseBar ~= false then
            core:SetLowHealthPulse(true)
        end
    else
        if pulseAG and pulseAG:IsPlaying() then pulseAG:Stop() end
        if vignetteFrame:IsShown() then
            local curA = F.PlainNumber(vignetteFrame:GetAlpha(), 0) or 0
            if curA < 0.05 then vignetteFrame:SetAlpha(maxA * 0.55) end
            F.Theme.FadeTo(vignetteFrame, 0, 0.35, true)
        end
        if core and core.SetLowHealthPulse then
            core:SetLowHealthPulse(false)
        end
    end
end

local function EvaluateHealth()
    if previewing then return end
    if not mod._active then
        if isLowNow or inSecretMode then
            isLowNow = false
            inSecretMode = false
            SetVignetteActive(false)
        end
        return
    end
    local db = mod:GetDB()
    local inCombat = (_G.InCombatLockdown and _G.InCombatLockdown()) == true
    if not inCombat and _G.UnitAffectingCombat then
        local okC, cbt = pcall(_G.UnitAffectingCombat, "player")
        if okC and not F.IsSecret(cbt) and cbt == true then inCombat = true end
    end
    local isDead = false
    if _G.UnitIsDeadOrGhost then
        local okD, dead = pcall(_G.UnitIsDeadOrGhost, "player")
        if okD and not F.IsSecret(dead) and dead == true then isDead = true end
    end
    if isDead or (db.combatOnly == true and not inCombat) then
        if isLowNow or inSecretMode then
            isLowNow = false
            inSecretMode = false
            SetVignetteActive(false)
        end
        return
    end

    local thr = math_max(10, math_min(60, F.PlainNumber(db.threshold, 30) or 30))
    local hp = _G.UnitHealth and _G.UnitHealth("player")
    local mx = _G.UnitHealthMax and _G.UnitHealthMax("player")

    if F.IsSecret(hp) or F.IsSecret(mx) then
        -- 12.x 保密值安全通路：C 端 ColorCurve 直接驱动 ADD 纹理颜色，零 Lua 比较
        local curve = EnsureSecretCurve(thr / 100)
        if curve and _G.UnitHealthPercent then
            local ok, col = pcall(_G.UnitHealthPercent, "player", false, curve)
            if ok and col and col.GetRGBA then
                local okRgba, r, g, b = pcall(col.GetRGBA, col)
                if okRgba then
                    PaintEdgesColor(r, g, b, 1)
                    local maxA = math_max(0.25, math_min(1.0, F.PlainNumber(db.maxAlpha, 0.78) or 0.78))
                    if not inSecretMode then F.Theme.FadeTo(vignetteFrame, maxA * 0.70, 0) end
                    if not vignetteFrame:IsShown() then
                        vignetteFrame:Show()
                    end
                    if pulseAG and not pulseAG:IsPlaying() then pulseAG:Play() end
                    inSecretMode = true
                end
            end
        end
        return
    end

    local wasSecret = inSecretMode
    inSecretMode = false
    local pHp = F.PlainNumber(hp, 1) or 1
    local pMx = F.PlainNumber(mx, 1) or 1
    local pct = (pMx > 0) and (pHp / pMx * 100) or 100
    local wantLow = (pct > 0 and pct <= thr)
    if wasSecret or wantLow ~= isLowNow then
        local newlyLow = wantLow and not isLowNow
        isLowNow = wantLow
        SetVignetteActive(wantLow)
        if newlyLow then PlayLowHealthAudio() end
    end
end

function mod:PreviewVignette()
    BuildVignette()
    ApplyVignetteGeom()
    previewGen = previewGen + 1
    local myGen = previewGen
    previewing = true
    SetVignetteActive(true)
    PlayLowHealthAudio()
    C_Timer.After(2.8, function()
        if myGen ~= previewGen then return end
        previewing = false
        isLowNow = false
        inSecretMode = false
        SetVignetteActive(false)
        EvaluateHealth()
    end)
end

function mod:OnEnable()
    BuildVignette()
    ApplyVignetteGeom()
    self:RegisterUnitEvent("UNIT_HEALTH", "player", EvaluateHealth)
    self:RegisterUnitEvent("UNIT_MAXHEALTH", "player", EvaluateHealth)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", EvaluateHealth)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", EvaluateHealth)
    self:RegisterEvent("PLAYER_DEAD", EvaluateHealth)
    self:RegisterEvent("PLAYER_ALIVE", EvaluateHealth)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", EvaluateHealth)
    EvaluateHealth()
end

function mod:OnDisable()
    previewGen = previewGen + 1
    previewing = false
    isLowNow = false
    inSecretMode = false
    if pulseAG and pulseAG:IsPlaying() then pulseAG:Stop() end
    if vignetteFrame then
        vignetteFrame:SetAlpha(0)
        vignetteFrame:Hide()
    end
    local core = F.Modules.Get("coreHUD")
    if core and core.SetLowHealthPulse then core:SetLowHealthPulse(false) end
end

function mod:OnRefresh()
    ApplyVignetteGeom()
    EvaluateHealth()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "slider",
        text = "触发血量阈值（%）",
        tooltip = "玩家生命值低于该百分比时触发全屏红暗角预警（默认 30%）。",
        min = 10, max = 60, step = 5,
        getValue = function() return F.PlainNumber(db.threshold, 30) or 30 end,
        setValue = function(v)
            db.threshold = v
            cachedCurve = nil
            EvaluateHealth()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "暗角最大透明度",
        min = 0.25, max = 1.0, step = 0.05,
        getValue = function() return F.PlainNumber(db.maxAlpha, 0.78) or 0.78 end,
        setValue = function(v) db.maxAlpha = v; ApplyVignetteGeom() end,
    }, {
        type = "slider",
        text = "暗角边缘宽度（px）",
        min = 80, max = 260, step = 10,
        getValue = function() return F.PlainNumber(db.edgeDepth, 150) or 150 end,
        setValue = function(v) db.edgeDepth = v; ApplyVignetteGeom() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "仅战斗中触发",
        getValue = function() return db.combatOnly == true end,
        setValue = function(v) db.combatOnly = v == true; EvaluateHealth() end,
    }, {
        type = "toggle",
        text = "低血量音效提醒",
        tooltip = "低血量触发预警时播放警报音效（可在存档 customSoundPath 填自定义语音路径）。",
        getValue = function() return db.playSound == true end,
        setValue = function(v) db.playSound = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "labeledButton",
        text = "预览低血量红暗角",
        buttonText = "预览 3 秒",
        width = 110,
        tooltip = "立即预览 3 秒全屏四边深红呼吸暗角与血条脉动效果。",
        onClick = function() mod:PreviewVignette() end,
    }, {
        type = "toggle",
        text = "联动血条呼吸闪烁",
        getValue = function() return db.pulseBar ~= false end,
        setValue = function(v)
            db.pulseBar = v == true
            local core = F.Modules.Get("coreHUD")
            if core and core.SetLowHealthPulse then
                core:SetLowHealthPulse(db.pulseBar and (isLowNow or previewing))
            end
        end,
    })
    y = y - h

    return y
end
