----------------------------------------------------------------------
--  kkowoUI_CoreHUD — MotionDemo.lua
--  /kk motion demo：脱战新旧条形动效并排对比演示面板（Q7）
--    • 严格脱战可用：战斗中执行提示并拒绝；演示中进战立即自动关闭清理
--    • 绝不触碰真实 HUD / 施法条 / 经验条 / 计时条 / Buff / 动作条框体
--    • 复用真实构建函数（CH.CreateWingBar / CH.ApplyWingStyle / F._BuildDemoCastbar）
--    • 上排「旧效果（全部 fx_ 关闭）」vs 下排「新效果（关 / 柔和 / 标准）」同剧本齐播
--    • 严格遵守 K12：容器与条形全禁鼠标，仅交互按钮接收点击；关闭严格 Hide + 0 残留 OnUpdate
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, math_floor, math_max, math_min, pairs, pcall, string_format, table_insert, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, string.format, table.insert, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime

local ST = F.StyleTokens
local M = F.Motion

local DEMO_FRAME_NAME = "kkowoUI_MotionDemoFrame"
local DEMO_TICK_KEY = "kkowoUI_MotionDemo_Text"

local panel = nil
local eventFrame = nil
local demoIntensity = "standard" -- "off" | "soft" | "standard"（仅影响演示面板，绝不改 F.db）
local demoGen = 0
local demoPlayAllIndex = 0
local demoActiveScript = nil
local oldRow = nil
local newRow = nil
local statusFS = nil
local intensityBtns = {}
local scriptBtns = {}

local OLD_OVERRIDE = { forceOff = true }

local function MakeNewOverride()
    if demoIntensity == "off" then
        return { forceOff = true }
    end
    return { intensity = demoIntensity, forceAll = true }
end

local function IsInCombatNow()
    if _G.InCombatLockdown and _G.InCombatLockdown() then return true end
    if _G.UnitAffectingCombat then
        local ok, cbt = pcall(_G.UnitAffectingCombat, "player")
        if ok and not F.IsSecret(cbt) and cbt == true then return true end
    end
    return false
end

----------------------------------------------------------------------
--  演示共享驱动任务（所有演示态逐帧动画共用 1 个 F.Motion 任务，空闲自动休眠）
----------------------------------------------------------------------
local demoAnimState = {
    jobs = {},
}

local function ClearDemoJobs()
    for k in pairs(demoAnimState.jobs) do
        demoAnimState.jobs[k] = nil
    end
    if M and M.UnregisterTask then M.UnregisterTask(demoAnimState) end
    if M and M.UnregisterTextTick then M.UnregisterTextTick(DEMO_TICK_KEY) end
end

demoAnimState._tick = function(self, dt)
    if not (panel and panel:IsShown()) then
        ClearDemoJobs()
        return false
    end
    local clamped = math_min(0.1, math_max(0.001, dt or 0.016))
    local any = false
    for key, job in pairs(self.jobs) do
        local keep = job(clamped)
        if keep then
            any = true
        else
            self.jobs[key] = nil
        end
    end
    return any
end

local function AddDemoJob(key, fn)
    demoAnimState.jobs[key] = fn
    if M and M.RegisterTask then
        M.RegisterTask(demoAnimState)
    end
end

local function ScheduleStep(myGen, delay, fn)
    C_Timer.After(delay, function()
        if demoGen ~= myGen or not (panel and panel:IsShown()) then return end
        fn()
    end)
end

----------------------------------------------------------------------
--  辅助：小按钮与每排（旧 / 新）演示控件组构建
----------------------------------------------------------------------
local function CreateMiniButton(parent, text, w, h, onClick)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w, h)
    btn:EnableMouse(true)
    if btn.RegisterForClicks then btn:RegisterForClicks("LeftButtonUp") end

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.14, 0.16, 0.20, 0.92)
    btn._bg = bg

    local bd = btn:CreateTexture(nil, "BORDER")
    bd:SetAllPoints()
    bd:SetColorTexture(0.32, 0.36, 0.44, 0.55)
    btn._bd = bd

    local fs = btn:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(fs, ST.FONT.caption, 0.94, 0.96, 0.99, 1)
    fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
    fs:SetText(text)
    btn._fs = fs

    btn:SetScript("OnEnter", function(self)
        if not self._selected then
            self._bg:SetColorTexture(0.22, 0.26, 0.34, 0.96)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if not self._selected then
            self._bg:SetColorTexture(0.14, 0.16, 0.20, 0.92)
        end
    end)
    btn:SetScript("OnClick", onClick)
    return btn
end

local function StyleMiniButtonSelected(btn, sel)
    btn._selected = sel == true
    if sel then
        btn._bg:SetColorTexture(0.72, 0.52, 0.32, 0.96)
        btn._fs:SetTextColor(0.08, 0.08, 0.10, 1)
    else
        btn._bg:SetColorTexture(0.14, 0.16, 0.20, 0.92)
        btn._fs:SetTextColor(0.94, 0.96, 0.99, 1)
    end
end

local function ApplyOutlineEdges(ol, w, h, progress, cr, cg, cb, a)
    local px = math_max(1, ST.GetPixel(ol) or 1)
    local p = math_max(0, math_min(1, progress))
    local e = 1 - (1 - p) * (1 - p) * (1 - p)

    local fL = math_min(1, e / 0.15)
    ol._left:SetVertexColor(cr, cg, cb, a)
    ol._left:SetSize(px, math_max(0.01, h * fL))
    ol._left:SetTexCoord(0, 1, 0, fL)
    ol._left:SetShown(fL > 0.001)

    local fH = math_max(0, math_min(1, (e - 0.15) / 0.70))
    ol._top:SetVertexColor(cr, cg, cb, a)
    ol._top:SetSize(math_max(0.01, w * fH), px)
    ol._top:SetTexCoord(0, fH, 0, 1)
    ol._top:SetShown(fH > 0.001)

    ol._bottom:SetVertexColor(cr, cg, cb, a)
    ol._bottom:SetSize(math_max(0.01, w * fH), px)
    ol._bottom:SetTexCoord(0, fH, 0, 1)
    ol._bottom:SetShown(fH > 0.001)

    local fR = math_max(0, math_min(1, (e - 0.85) / 0.15))
    ol._right:SetVertexColor(cr, cg, cb, a)
    ol._right:SetSize(px, math_max(0.01, h * fR))
    ol._right:SetTexCoord(0, 1, 0, fR)
    ol._right:SetShown(fR > 0.001)
    ol:Show()
end

local function BuildComparisonRow(parent, titleText, isNew, yTop)
    local CH = F._CoreHUD
    local ov = isNew and MakeNewOverride() or OLD_OVERRIDE

    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(748, 128)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yTop)
    box:EnableMouse(false)

    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(isNew and 0.09 or 0.07, isNew and 0.11 or 0.08, isNew and 0.14 or 0.10, 0.88)

    local title = box:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(title, ST.FONT.body, isNew and 0.96 or 0.74, isNew and 0.82 or 0.78, isNew and 0.56 or 0.84, 1)
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -7)
    title:SetText(titleText)

    local row = {
        box = box,
        title = title,
        isNew = isNew,
        override = ov,
    }

    -- 1) 主血条/目标条（严格复用 CoreHUD_Wings.lua 的 CH.CreateWingBar + CH.ApplyWingStyle）
    local hpLbl = box:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(hpLbl, ST.FONT.caption, 0.78, 0.84, 0.90, 0.92)
    hpLbl:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -28)
    hpLbl:SetText("主血条 / 目标 / 治疗预估")

    local hpHolder
    if CH and CH.CreateWingBar then
        hpHolder = CH.CreateWingBar(box, 200, 16, false)
    else
        hpHolder = CreateFrame("Frame", nil, box)
        hpHolder:SetSize(200, 16)
        hpHolder:EnableMouse(false)
        hpHolder._bar = CreateFrame("StatusBar", nil, hpHolder)
        hpHolder._bar:SetAllPoints()
        hpHolder._bar:SetStatusBarTexture(ST.TEX.FLAT)
        hpHolder._bar:EnableMouse(false)
    end
    hpHolder:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -44)
    hpHolder._trail = M.AttachHealthTrail(hpHolder._bar, {
        delay = 0.14, speed = 7.2, color = ST.COLORS.trail, levelOffset = 1, fxOverride = ov,
    })
    hpHolder._spark = M.AttachEdgeSpark(hpHolder._bar, {
        width = 16, extraHeight = 4, a = 0.90, levelOffset = 3, fxOverride = ov,
    })
    hpHolder._healPred = M.AttachHealPrediction(hpHolder._bar, {
        reverse = false, levelOffset = 2, fxOverride = ov,
    })
    if CH and CH.ApplyWingStyle then
        local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
        CH.ApplyWingStyle(hpHolder, r1, g1, b1, r2, g2, b2, 5, ov)
    end
    M.SetBarMinMax(hpHolder._bar, 0, 1000)
    M.SetBarValue(hpHolder._bar, 1000, { fxKey = "fx_smoothMain", override = ov, instant = true })
    if hpHolder._trail then hpHolder._trail:SetValue(1000, 1000, true) end
    row.hpHolder = hpHolder

    -- 2) 施法条（严格复用 CastbarMotion.lua 的 F._BuildDemoCastbar）
    local castLbl = box:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(castLbl, ST.FONT.caption, 0.78, 0.84, 0.90, 0.92)
    castLbl:SetPoint("TOPLEFT", box, "TOPLEFT", 224, -28)
    castLbl:SetText("施法 / 引导 / 推迟 / 收尾")

    local castBar
    if type(F._BuildDemoCastbar) == "function" then
        castBar = F._BuildDemoCastbar(box, 186, 16, ov)
    else
        castBar = CreateFrame("Frame", nil, box)
        castBar:SetSize(186, 16)
        castBar:EnableMouse(false)
        castBar._bar = CreateFrame("StatusBar", nil, castBar)
        castBar._bar:SetAllPoints()
        castBar._bar:SetStatusBarTexture(ST.TEX.FLAT)
        castBar._bar:EnableMouse(false)
    end
    castBar:SetPoint("TOPLEFT", box, "TOPLEFT", 224, -44)
    if castBar._nameFS then castBar._nameFS:SetText("待机") end
    if castBar._timeFS then castBar._timeFS:SetText("") end
    row.castBar = castBar

    -- 3) 经验条（复用 CH.CreateWingBar + 增益提示段）
    local xpLbl = box:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(xpLbl, ST.FONT.caption, 0.78, 0.84, 0.90, 0.92)
    xpLbl:SetPoint("TOPLEFT", box, "TOPLEFT", 424, -28)
    xpLbl:SetText("经验条 / 升级")

    local xpHolder = (CH and CH.CreateWingBar) and CH.CreateWingBar(box, 150, 12, false) or CreateFrame("Frame", nil, box)
    if not xpHolder._bar then
        xpHolder:SetSize(150, 12)
        xpHolder:EnableMouse(false)
        xpHolder._bar = CreateFrame("StatusBar", nil, xpHolder)
        xpHolder._bar:SetAllPoints()
        xpHolder._bar:SetStatusBarTexture(ST.TEX.FLAT)
        xpHolder._bar:EnableMouse(false)
    end
    xpHolder:SetPoint("TOPLEFT", box, "TOPLEFT", 424, -46)
    if CH and CH.ApplyWingStyle then
        CH.ApplyWingStyle(xpHolder, 0.36, 0.44, 0.86, 0.62, 0.72, 1.00, 4, ov)
    end
    local xpGain = CreateFrame("StatusBar", nil, xpHolder)
    xpGain:SetAllPoints(xpHolder._bar)
    xpGain:SetFrameLevel(math_max(1, xpHolder._bar:GetFrameLevel() - 1))
    xpGain:SetStatusBarTexture(ST.GetBarFillTexture and ST.GetBarFillTexture(true, ov) or ST.TEX.FLAT)
    xpGain:SetStatusBarColor(0.76, 0.84, 1.00, 0.68)
    xpGain:SetMinMaxValues(0, 1000)
    xpGain:SetValue(0)
    xpGain:EnableMouse(false)
    xpGain:Hide()
    xpHolder._gain = xpGain
    M.SetBarMinMax(xpHolder._bar, 0, 1000)
    M.SetBarValue(xpHolder._bar, 450, { fxKey = "fx_xpSmooth", override = ov, instant = true })
    row.xpHolder = xpHolder

    -- 4) 计时条（Roll 倒计时 / 附魔条）
    local tmLbl = box:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(tmLbl, ST.FONT.caption, 0.78, 0.84, 0.90, 0.92)
    tmLbl:SetPoint("TOPLEFT", box, "TOPLEFT", 588, -28)
    tmLbl:SetText("Roll / 附魔计时条")

    local timerHolder = (CH and CH.CreateWingBar) and CH.CreateWingBar(box, 148, 12, false) or CreateFrame("Frame", nil, box)
    if not timerHolder._bar then
        timerHolder:SetSize(148, 12)
        timerHolder:EnableMouse(false)
        timerHolder._bar = CreateFrame("StatusBar", nil, timerHolder)
        timerHolder._bar:SetAllPoints()
        timerHolder._bar:SetStatusBarTexture(ST.TEX.FLAT)
        timerHolder._bar:EnableMouse(false)
    end
    timerHolder:SetPoint("TOPLEFT", box, "TOPLEFT", 588, -46)
    if CH and CH.ApplyWingStyle then
        CH.ApplyWingStyle(timerHolder, 0.86, 0.56, 0.20, 1.00, 0.84, 0.44, 4, ov)
    end
    local tmFS = timerHolder:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(tmFS, ST.FONT.caption, 0.96, 0.96, 0.98, 1)
    tmFS:SetPoint("RIGHT", timerHolder, "RIGHT", -4, 0)
    tmFS:SetText("就绪")
    timerHolder._timeFS = tmFS
    M.SetBarMinMax(timerHolder._bar, 0, 10)
    M.SetBarValue(timerHolder._bar, 10, { fxKey = "fx_timerBars", override = ov, instant = true })
    row.timerHolder = timerHolder

    -- 下半排微预览：5) Buff 滑入/快到期  6) 按键反馈  7) 淡隐曲线  8) 姓名板描边
    local subY = -74

    -- 5) Buff 图标
    local buffBox = CreateFrame("Frame", nil, box)
    buffBox:SetSize(28, 28)
    buffBox:SetPoint("TOPLEFT", box, "TOPLEFT", 14, subY)
    buffBox:EnableMouse(false)
    local buffTex = buffBox:CreateTexture(nil, "ARTWORK")
    buffTex:SetAllPoints()
    buffTex:SetTexture("Interface\\Icons\\Spell_Holy_PowerWordShield")
    buffTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local buffGlow = buffBox:CreateTexture(nil, "OVERLAY", nil, 5)
    buffGlow:SetPoint("TOPLEFT", buffBox, "TOPLEFT", -2, 2)
    buffGlow:SetPoint("BOTTOMRIGHT", buffBox, "BOTTOMRIGHT", 2, -2)
    buffGlow:SetTexture(ST.TEX.FLAT)
    buffGlow:SetBlendMode("ADD")
    buffGlow:SetVertexColor(1.00, 0.72, 0.22, 0.55)
    buffGlow:Hide()
    local buffSlideAG = buffBox:CreateAnimationGroup()
    local bTr = buffSlideAG:CreateAnimation("Translation")
    bTr:SetOrder(1); bTr:SetOffset(-6, 0); bTr:SetDuration(0.18); bTr:SetSmoothing("OUT")
    local bAl = buffSlideAG:CreateAnimation("Alpha")
    bAl:SetOrder(1); bAl:SetFromAlpha(0); bAl:SetToAlpha(1); bAl:SetDuration(0.18); bAl:SetSmoothing("OUT")
    local buffPulseAG = M.EnsurePulseAlpha(buffGlow, 0.45, 0.92, 1.2)
    local buffLbl = box:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(buffLbl, ST.FONT.caption, 0.76, 0.82, 0.88, 0.90)
    buffLbl:SetPoint("LEFT", buffBox, "RIGHT", 6, 0)
    buffLbl:SetText("Buff 滑入/到期")
    row.buffBox, row.buffGlow, row.buffSlideAG, row.buffPulseAG = buffBox, buffGlow, buffSlideAG, buffPulseAG

    -- 6) 动作按键（仅移动图标纹理 1 物理像素，绝不用 Scale）
    local keyBox = CreateFrame("Frame", nil, box)
    keyBox:SetSize(28, 28)
    keyBox:SetPoint("TOPLEFT", box, "TOPLEFT", 168, subY)
    keyBox:EnableMouse(false)
    local keyBg = keyBox:CreateTexture(nil, "BACKGROUND")
    keyBg:SetAllPoints()
    keyBg:SetColorTexture(0.05, 0.06, 0.08, 0.92)
    local keyIcon = keyBox:CreateTexture(nil, "ARTWORK")
    keyIcon:SetPoint("TOPLEFT", keyBox, "TOPLEFT", 2, -2)
    keyIcon:SetPoint("BOTTOMRIGHT", keyBox, "BOTTOMRIGHT", -2, 2)
    keyIcon:SetTexture("Interface\\Icons\\Spell_Fire_FireBolt")
    keyIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local keyRelAG = keyIcon:CreateAnimationGroup()
    local kTr = keyRelAG:CreateAnimation("Translation")
    kTr:SetOrder(1); kTr:SetOffset(0, 1); kTr:SetDuration(0.08); kTr:SetSmoothing("OUT")
    local keyLbl = box:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(keyLbl, ST.FONT.caption, 0.76, 0.82, 0.88, 0.90)
    keyLbl:SetPoint("LEFT", keyBox, "RIGHT", 6, 0)
    keyLbl:SetText("按键 1px 回弹")
    row.keyBox, row.keyIcon, row.keyRelAG = keyBox, keyIcon, keyRelAG

    -- 7) 脱战淡隐曲线预览块
    local fadeCard = CreateFrame("Frame", nil, box)
    fadeCard:SetSize(84, 24)
    fadeCard:SetPoint("TOPLEFT", box, "TOPLEFT", 326, subY - 2)
    fadeCard:EnableMouse(false)
    local fadeBg = fadeCard:CreateTexture(nil, "ARTWORK")
    fadeBg:SetAllPoints()
    fadeBg:SetColorTexture(0.32, 0.62, 0.92, 0.90)
    local fadeFS = fadeCard:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(fadeFS, ST.FONT.caption, 0.98, 0.99, 1.0, 1)
    fadeFS:SetPoint("CENTER", fadeCard, "CENTER", 0, 0)
    fadeFS:SetText("淡隐预览")
    row.fadeCard = fadeCard

    -- 8) 姓名板描边预览块（4 边增长 + TexCoord 裁剪）
    local plateBox = CreateFrame("Frame", nil, box)
    plateBox:SetSize(130, 16)
    plateBox:SetPoint("TOPLEFT", box, "TOPLEFT", 448, subY - 6)
    plateBox:EnableMouse(false)
    local pFill = plateBox:CreateTexture(nil, "ARTWORK")
    pFill:SetAllPoints()
    pFill:SetColorTexture(0.78, 0.24, 0.22, 0.88)
    local pOl = CreateFrame("Frame", nil, plateBox)
    pOl:SetAllPoints(plateBox)
    pOl:SetFrameLevel(plateBox:GetFrameLevel() + 4)
    pOl:EnableMouse(false)
    local olL = pOl:CreateTexture(nil, "OVERLAY", nil, 6); olL:SetTexture(ST.TEX.FLAT); olL:SetPoint("TOPLEFT", pOl, "TOPLEFT")
    local olT = pOl:CreateTexture(nil, "OVERLAY", nil, 6); olT:SetTexture(ST.TEX.FLAT); olT:SetPoint("TOPLEFT", pOl, "TOPLEFT")
    local olB = pOl:CreateTexture(nil, "OVERLAY", nil, 6); olB:SetTexture(ST.TEX.FLAT); olB:SetPoint("BOTTOMLEFT", pOl, "BOTTOMLEFT")
    local olR = pOl:CreateTexture(nil, "OVERLAY", nil, 6); olR:SetTexture(ST.TEX.FLAT); olR:SetPoint("TOPRIGHT", pOl, "TOPRIGHT")
    pOl._left, pOl._top, pOl._bottom, pOl._right = olL, olT, olB, olR
    pOl:Hide()
    local plateLbl = box:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(plateLbl, ST.FONT.caption, 0.76, 0.82, 0.88, 0.90)
    plateLbl:SetPoint("LEFT", plateBox, "RIGHT", 8, 0)
    plateLbl:SetText("姓名板描边")
    row.plateBox, row.plateOl = plateBox, pOl

    return row
end

local function RefreshNewRowOverride()
    if not newRow then return end
    local ov = MakeNewOverride()
    newRow.override = ov
    local label = (demoIntensity == "off") and "关" or ((demoIntensity == "soft") and "柔和" or "标准")
    newRow.title:SetText("新效果（预览强度：" .. label .. "，不改真实设置）")
    local CH = F._CoreHUD
    local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
    if CH and CH.ApplyWingStyle then
        CH.ApplyWingStyle(newRow.hpHolder, r1, g1, b1, r2, g2, b2, 5, ov)
        CH.ApplyWingStyle(newRow.xpHolder, 0.36, 0.44, 0.86, 0.62, 0.72, 1.00, 4, ov)
        CH.ApplyWingStyle(newRow.timerHolder, 0.86, 0.56, 0.20, 1.00, 0.84, 0.44, 4, ov)
    end
    if newRow.hpHolder._trail then newRow.hpHolder._trail._fxOverride = ov; newRow.hpHolder._trail:RefreshStyle() end
    if newRow.hpHolder._spark then newRow.hpHolder._spark._fxOverride = ov; newRow.hpHolder._spark:RefreshTexture() end
    if newRow.hpHolder._healPred then newRow.hpHolder._healPred._fxOverride = ov; newRow.hpHolder._healPred:SyncLayout() end
    if newRow.castBar and newRow.castBar.ApplyDemoStyle then newRow.castBar:ApplyDemoStyle(ov) end
end

local function ResetRowBaseline(row)
    if not row then return end
    local ov = row.override
    M.SetBarMinMax(row.hpHolder._bar, 0, 1000)
    M.SetBarValue(row.hpHolder._bar, 1000, { fxKey = "fx_smoothMain", override = ov, instant = true })
    if row.hpHolder._trail then
        row.hpHolder._trail:SetEnabled(true)
        row.hpHolder._trail:SetValue(1000, 1000, true)
    end
    if row.hpHolder._healPred and row.hpHolder._healPred._clip then
        row.hpHolder._healPred._clip:Hide()
    end
    if row.castBar then
        if row.castBar._ghost then
            M.StopFrameAnims(row.castBar._ghost)
            row.castBar._ghost:Hide()
        end
        row.castBar._bar:SetMinMaxValues(0, 1)
        row.castBar._bar:SetValue(0)
        if row.castBar._nameFS then row.castBar._nameFS:SetText("待机") end
        if row.castBar._timeFS then row.castBar._timeFS:SetText("") end
    end
    if row.xpHolder and row.xpHolder._gain then row.xpHolder._gain:Hide() end
    if row.buffPulseAG then row.buffPulseAG:Stop() end
    if row.buffSlideAG then row.buffSlideAG:Stop() end
    if row.buffGlow then row.buffGlow:Hide() end
    if row.keyRelAG then row.keyRelAG:Stop() end
    if row.keyIcon then
        row.keyIcon:ClearAllPoints()
        row.keyIcon:SetPoint("TOPLEFT", row.keyBox, "TOPLEFT", 2, -2)
        row.keyIcon:SetPoint("BOTTOMRIGHT", row.keyBox, "BOTTOMRIGHT", -2, 2)
    end
    if row.fadeCard then row.fadeCard:SetAlpha(1) end
    if row.plateOl then row.plateOl:Hide() end
end

----------------------------------------------------------------------
--  全部 19 个对比剧本（每条同时驱动 Old 排与 New 排）
----------------------------------------------------------------------
local function RunCastOnRow(row, label, dur, isChannel, myGen, onFinish)
    local ov = row.override
    local cb = row.castBar
    if not cb then return end
    if cb._ghost then M.StopFrameAnims(cb._ghost); cb._ghost:Hide() end
    if cb._nameFS then cb._nameFS:SetText(label) end
    local useClient = ST.IsFXEnabled("fx_castTimer", ov) and M.ArmClientTimerBar ~= nil
    local startAt = GetTime()
    if useClient then
        M.ArmClientTimerBar(cb._bar, startAt, dur, not isChannel, ov)
    else
        cb._bar:SetMinMaxValues(0, dur)
        cb._bar:SetValue(isChannel and dur or 0)
    end
    local elapsed = 0
    AddDemoJob((row.isNew and "new" or "old") .. "_cast", function(dt)
        elapsed = elapsed + dt
        local rem = math_max(0, dur - elapsed)
        if not useClient then
            cb._bar:SetValue(isChannel and rem or math_min(dur, elapsed))
        end
        if cb._timeFS then cb._timeFS:SetText(string_format("%.1fs", rem)) end
        if elapsed >= dur then
            if onFinish then onFinish(row, cb, ov) end
            return false
        end
        return demoGen == myGen
    end)
end

local SCRIPTS = {
    {
        id = "small_dmg", label = "小额掉血", dur = 1.1,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                M.SetBarValue(row.hpHolder._bar, 1000, { fxKey = "fx_smoothMain", override = ov, instant = true })
                if row.hpHolder._trail then row.hpHolder._trail:SetValue(1000, 1000, true) end
                ScheduleStep(myGen, 0.12, function()
                    M.SetBarValue(row.hpHolder._bar, 880, { fxKey = "fx_smoothMain", override = ov, instant = false })
                    if row.hpHolder._trail then row.hpHolder._trail:SetValue(880, 1000, false) end
                end)
            end
        end,
    },
    {
        id = "big_dmg", label = "大额伤害", dur = 1.3,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                M.SetBarValue(row.hpHolder._bar, 920, { fxKey = "fx_smoothMain", override = ov, instant = true })
                if row.hpHolder._trail then row.hpHolder._trail:SetValue(920, 1000, true) end
                ScheduleStep(myGen, 0.12, function()
                    M.SetBarValue(row.hpHolder._bar, 440, { fxKey = "fx_smoothMain", override = ov, instant = false })
                    if row.hpHolder._trail then row.hpHolder._trail:SetValue(440, 1000, false) end
                    M.TriggerBarHitFlash(row.hpHolder._bar, "damage", { override = ov, force = true })
                end)
            end
        end,
    },
    {
        id = "small_heal", label = "回血", dur = 1.0,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                M.SetBarValue(row.hpHolder._bar, 500, { fxKey = "fx_smoothMain", override = ov, instant = true })
                if row.hpHolder._trail then row.hpHolder._trail:SetValue(500, 1000, true) end
                ScheduleStep(myGen, 0.12, function()
                    M.SetBarValue(row.hpHolder._bar, 620, { fxKey = "fx_smoothMain", override = ov, instant = false })
                    if row.hpHolder._trail then row.hpHolder._trail:SetValue(620, 1000, true) end
                end)
            end
        end,
    },
    {
        id = "big_heal", label = "大额治疗", dur = 1.2,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                M.SetBarValue(row.hpHolder._bar, 420, { fxKey = "fx_smoothMain", override = ov, instant = true })
                if row.hpHolder._trail then row.hpHolder._trail:SetValue(420, 1000, true) end
                ScheduleStep(myGen, 0.12, function()
                    M.SetBarValue(row.hpHolder._bar, 940, { fxKey = "fx_smoothMain", override = ov, instant = false })
                    if row.hpHolder._trail then row.hpHolder._trail:SetValue(940, 1000, true) end
                    M.TriggerBarHitFlash(row.hpHolder._bar, "heal", { override = ov, force = true })
                end)
            end
        end,
    },
    {
        id = "heal_shield", label = "护盾和治疗预估", dur = 1.4,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                M.SetBarValue(row.hpHolder._bar, 620, { fxKey = "fx_smoothMain", override = ov, instant = true })
                if row.hpHolder._trail then row.hpHolder._trail:SetValue(620, 1000, true) end
                ScheduleStep(myGen, 0.10, function()
                    if row.hpHolder._healPred then
                        row.hpHolder._healPred:SetValues(1000, 220, 360, true, 40, false)
                    end
                end)
                ScheduleStep(myGen, 1.25, function()
                    if row.hpHolder._healPred and row.hpHolder._healPred._clip then
                        row.hpHolder._healPred._clip:Hide()
                    end
                end)
            end
        end,
    },
    {
        id = "death_snap", label = "死亡（直接跳）", dur = 1.0,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                M.SetBarValue(row.hpHolder._bar, 720, { fxKey = "fx_smoothMain", override = ov, instant = true })
                if row.hpHolder._trail then row.hpHolder._trail:SetValue(720, 1000, true) end
                ScheduleStep(myGen, 0.18, function()
                    M.SetBarValue(row.hpHolder._bar, 0, { fxKey = "fx_smoothMain", override = ov, instant = true })
                    if row.hpHolder._trail then row.hpHolder._trail:SetValue(0, 1000, true) end
                end)
            end
        end,
    },
    {
        id = "target_arrive", label = "换目标入场", dur = 1.0,
        run = function()
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                if not M.PlayBarArriveGlide(row.hpHolder._bar, 1000, 1000, row.hpHolder._trail, { override = ov }) then
                    M.SetBarValue(row.hpHolder._bar, 1000, { fxKey = "fx_smoothMain", override = ov, instant = true })
                    if row.hpHolder._trail then row.hpHolder._trail:SetValue(1000, 1000, true) end
                end
            end
        end,
    },
    {
        id = "cast_ok", label = "施法成功", dur = 1.5,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                RunCastOnRow(row, "炎爆术", 0.95, false, myGen, function(_, cb, ov)
                    if ST.IsFXEnabled("fx_castFinish", ov) and cb._ghost then
                        local pos = ST.COLORS.positive or { 0.34, 0.88, 0.56 }
                        cb._ghost._fill:SetVertexColor(pos[1], pos[2], pos[3], 0.92)
                        cb._ghost._label:SetText("施法完成")
                        M.PlayFlashFade(cb._ghost, 0.30, 3, nil, 0.05, 0.95)
                    end
                    cb._bar:SetValue(0)
                    if cb._nameFS then cb._nameFS:SetText("待机") end
                    if cb._timeFS then cb._timeFS:SetText("") end
                end)
            end
        end,
    },
    {
        id = "cast_interrupt", label = "施法被打断", dur = 1.5,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                RunCastOnRow(row, "火球术", 0.50, false, myGen, function(_, cb, ov)
                    if ST.IsFXEnabled("fx_castFinish", ov) and cb._ghost then
                        local d = ST.COLORS.danger or { 0.95, 0.24, 0.22 }
                        cb._ghost._fill:SetVertexColor(d[1], d[2], d[3], 0.92)
                        cb._ghost._label:SetText("已打断")
                        M.PlayInterruptShake(cb._ghost, 4, 0.16, nil, 0.50, 0.22)
                    end
                    cb._bar:SetValue(0)
                    if cb._nameFS then cb._nameFS:SetText("待机") end
                    if cb._timeFS then cb._timeFS:SetText("") end
                end)
            end
        end,
    },
    {
        id = "cast_channel", label = "引导", dur = 1.3,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                RunCastOnRow(row, "奥术飞弹", 0.90, true, myGen, function(_, cb, ov)
                    if ST.IsFXEnabled("fx_castFinish", ov) and cb._ghost then
                        local r1, g1, b1 = ST.GetClassGradient()
                        cb._ghost._fill:SetVertexColor(r1, g1, b1, 0.65)
                        cb._ghost._label:SetText("")
                        M.PlayFlashFade(cb._ghost, 0.20, 0, nil, 0, 0.65)
                    end
                    cb._bar:SetValue(0)
                    if cb._nameFS then cb._nameFS:SetText("待机") end
                    if cb._timeFS then cb._timeFS:SetText("") end
                end)
            end
        end,
    },
    {
        id = "cast_pushback", label = "施法被推迟", dur = 1.5,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                RunCastOnRow(row, "寒冰箭", 1.15, false, myGen, function(_, cb)
                    cb._bar:SetValue(0)
                    if cb._nameFS then cb._nameFS:SetText("待机") end
                    if cb._timeFS then cb._timeFS:SetText("") end
                end)
                ScheduleStep(myGen, 0.45, function()
                    -- 模拟中途被击退 0.35s：重设新时长
                    RunCastOnRow(row, "寒冰箭（推迟）", 0.85, false, myGen, function(_, cb)
                        cb._bar:SetValue(0)
                        if cb._nameFS then cb._nameFS:SetText("待机") end
                        if cb._timeFS then cb._timeFS:SetText("") end
                    end)
                end)
            end
        end,
    },
    {
        id = "xp_gain", label = "获得经验", dur = 1.1,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                M.SetBarMinMax(row.xpHolder._bar, 0, 1000)
                M.SetBarValue(row.xpHolder._bar, 420, { fxKey = "fx_xpSmooth", override = ov, instant = true })
                ScheduleStep(myGen, 0.12, function()
                    if ST.IsFXEnabled("fx_xpSmooth", ov) and row.xpHolder._gain then
                        row.xpHolder._gain:SetMinMaxValues(0, 1000)
                        row.xpHolder._gain:SetValue(740)
                        row.xpHolder._gain:Show()
                    elseif row.xpHolder._gain then
                        row.xpHolder._gain:Hide()
                    end
                    M.SetBarValue(row.xpHolder._bar, 740, { fxKey = "fx_xpSmooth", override = ov, instant = false })
                end)
                ScheduleStep(myGen, 0.95, function()
                    if row.xpHolder._gain then row.xpHolder._gain:Hide() end
                end)
            end
        end,
    },
    {
        id = "xp_levelup", label = "升级", dur = 1.2,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                M.SetBarMinMax(row.xpHolder._bar, 0, 1000)
                M.SetBarValue(row.xpHolder._bar, 950, { fxKey = "fx_xpSmooth", override = ov, instant = true })
                ScheduleStep(myGen, 0.16, function()
                    if ST.IsFXEnabled("fx_xpSmooth", ov) then
                        M.SetBarValue(row.xpHolder._bar, 0, { fxKey = "fx_xpSmooth", override = ov, instant = true })
                        if row.xpHolder._gain then
                            row.xpHolder._gain:SetMinMaxValues(0, 1000)
                            row.xpHolder._gain:SetValue(280)
                            row.xpHolder._gain:Show()
                        end
                        ScheduleStep(myGen, 0.04, function()
                            M.SetBarValue(row.xpHolder._bar, 280, { fxKey = "fx_xpSmooth", override = ov, instant = false })
                        end)
                    else
                        row.xpHolder._bar:SetValue(280)
                    end
                end)
                ScheduleStep(myGen, 1.05, function()
                    if row.xpHolder._gain then row.xpHolder._gain:Hide() end
                end)
            end
        end,
    },
    {
        id = "roll_timer", label = "roll 条倒计时", dur = 1.4,
        run = function(myGen)
            local now = GetTime()
            local dur = 1.2
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                local useClient = ST.IsFXEnabled("fx_timerBars", ov) and M.ArmClientTimerBar ~= nil
                if useClient then
                    M.ArmClientTimerBar(row.timerHolder._bar, now, dur, false, ov)
                else
                    row.timerHolder._bar:SetMinMaxValues(0, dur)
                    row.timerHolder._bar:SetValue(dur)
                end
                local el = 0
                AddDemoJob((row.isNew and "new" or "old") .. "_roll", function(dt)
                    el = el + dt
                    local rem = math_max(0, dur - el)
                    if not useClient then row.timerHolder._bar:SetValue(rem) end
                    row.timerHolder._timeFS:SetText(string_format("Roll %.1fs", rem))
                    return el < dur and demoGen == myGen
                end)
            end
        end,
    },
    {
        id = "enchant_timer", label = "附魔条", dur = 1.3,
        run = function(myGen)
            local now = GetTime()
            local dur = 1.1
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                local useClient = ST.IsFXEnabled("fx_timerBars", ov) and M.ArmClientTimerBar ~= nil
                if useClient then
                    M.ArmClientTimerBar(row.timerHolder._bar, now, dur, false, ov)
                else
                    row.timerHolder._bar:SetMinMaxValues(0, dur)
                    row.timerHolder._bar:SetValue(dur)
                end
                local el = 0
                AddDemoJob((row.isNew and "new" or "old") .. "_ench", function(dt)
                    el = el + dt
                    local rem = math_max(0, dur - el)
                    if not useClient then row.timerHolder._bar:SetValue(rem) end
                    row.timerHolder._timeFS:SetText(string_format("附魔 %.1fs", rem))
                    return el < dur and demoGen == myGen
                end)
            end
        end,
    },
    {
        id = "buff_feel", label = "buff 滑入和快到期", dur = 1.4,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                if ST.IsFXEnabled("fx_auraFeel", ov) then
                    if row.buffSlideAG then row.buffSlideAG:Stop(); row.buffSlideAG:Play() end
                    ScheduleStep(myGen, 0.25, function()
                        row.buffGlow:Show()
                        if row.buffPulseAG then row.buffPulseAG:Stop(); row.buffPulseAG:Play() end
                    end)
                else
                    if row.buffPulseAG then row.buffPulseAG:Stop() end
                    row.buffGlow:Hide()
                end
            end
        end,
    },
    {
        id = "button_press", label = "按键反馈", dur = 0.9,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local ov = row.override
                if ST.IsFXEnabled("fx_buttonPress", ov) then
                    local px = ST.GetPixel(row.keyBox) or 1
                    row.keyIcon:ClearAllPoints()
                    row.keyIcon:SetPoint("TOPLEFT", row.keyBox, "TOPLEFT", 2, -2 - px)
                    row.keyIcon:SetPoint("BOTTOMRIGHT", row.keyBox, "BOTTOMRIGHT", -2, 2 - px)
                    ScheduleStep(myGen, 0.22, function()
                        row.keyIcon:ClearAllPoints()
                        row.keyIcon:SetPoint("TOPLEFT", row.keyBox, "TOPLEFT", 2, -2)
                        row.keyIcon:SetPoint("BOTTOMRIGHT", row.keyBox, "BOTTOMRIGHT", -2, 2)
                        if row.keyRelAG then row.keyRelAG:Stop(); row.keyRelAG:Play() end
                    end)
                end
            end
        end,
    },
    {
        id = "fade_curve", label = "淡隐和淡出", dur = 1.4,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local smooth = ST.IsFXEnabled("fx_fadeCurve", row.override)
                local el = 0
                local half = 0.60
                AddDemoJob((row.isNew and "new" or "old") .. "_fade", function(dt)
                    el = el + dt
                    local a
                    if el <= half then
                        local t = math_min(1, el / half)
                        local e = smooth and (t * t * (3 - 2 * t)) or t
                        a = 1.0 + (0.28 - 1.0) * e
                    else
                        local t = math_min(1, (el - half) / half)
                        local e = smooth and (t * t * (3 - 2 * t)) or t
                        a = 0.28 + (1.0 - 0.28) * e
                    end
                    row.fadeCard:SetAlpha(a)
                    return el < (half * 2) and demoGen == myGen
                end)
            end
        end,
    },
    {
        id = "plate_outline", label = "姓名板描边", dur = 1.0,
        run = function(myGen)
            for _, row in ipairs({ oldRow, newRow }) do
                local w = F.PlainNumber(row.plateBox:GetWidth(), 130) or 130
                local h = F.PlainNumber(row.plateBox:GetHeight(), 16) or 16
                if ST.IsFXEnabled("fx_plateOutline", row.override) then
                    local el = 0
                    local dur = (ST.GetFXIntensity(row.override) == "soft") and 0.32 or 0.40
                    ApplyOutlineEdges(row.plateOl, w, h, 0.02, 1.00, 0.86, 0.42, 0.94)
                    AddDemoJob((row.isNew and "new" or "old") .. "_outline", function(dt)
                        el = el + dt
                        local p = math_min(1, el / dur)
                        ApplyOutlineEdges(row.plateOl, w, h, p, 1.00, 0.86, 0.42, 0.94)
                        return p < 1 and demoGen == myGen
                    end)
                else
                    ApplyOutlineEdges(row.plateOl, w, h, 1, 1.00, 0.86, 0.42, 0.94)
                end
            end
        end,
    },
}

----------------------------------------------------------------------
--  清理、打开、关闭与剧本播放控制
----------------------------------------------------------------------
local function CleanupDemoRuntime()
    demoGen = demoGen + 1
    demoPlayAllIndex = 0
    demoActiveScript = nil
    ClearDemoJobs()
    for _, row in ipairs({ oldRow, newRow }) do
        if row then
            if row.hpHolder and row.hpHolder._trail then row.hpHolder._trail:SetEnabled(false) end
            if row.castBar and row.castBar._ghost then
                M.StopFrameAnims(row.castBar._ghost)
                row.castBar._ghost:Hide()
            end
            if row.buffPulseAG then row.buffPulseAG:Stop() end
            if row.buffSlideAG then row.buffSlideAG:Stop() end
            if row.keyRelAG then row.keyRelAG:Stop() end
        end
    end
    for _, b in pairs(scriptBtns) do StyleMiniButtonSelected(b, false) end
end

local function CloseDemo(reason)
    CleanupDemoRuntime()
    if panel and panel:IsShown() then
        panel:Hide()
    end
    if reason and reason ~= "" then
        F.Print(reason)
    end
end

local function PlayScriptByIndex(idx, chainNext)
    if not (panel and panel:IsShown()) then return false end
    local sc = SCRIPTS[idx]
    if not sc then return false end
    demoGen = demoGen + 1
    local myGen = demoGen
    ClearDemoJobs()
    demoActiveScript = sc.id
    for i, b in ipairs(scriptBtns) do
        StyleMiniButtonSelected(b, i == idx)
    end
    ResetRowBaseline(oldRow)
    ResetRowBaseline(newRow)
    if statusFS then
        statusFS:SetText("正在演示：" .. sc.label .. (chainNext and string_format("（连播 %d/%d）", idx, #SCRIPTS) or ""))
    end
    sc.run(myGen)
    if chainNext then
        demoPlayAllIndex = idx
        ScheduleStep(myGen, sc.dur or 1.2, function()
            if idx < #SCRIPTS then
                PlayScriptByIndex(idx + 1, true)
            else
                demoPlayAllIndex = 0
                if statusFS then statusFS:SetText("全部 19 项对比演示完毕，可点选单项复看或切换强度。") end
                for _, b in ipairs(scriptBtns) do StyleMiniButtonSelected(b, false) end
            end
        end)
    end
    return true
end

local function SetDemoIntensity(level)
    if level ~= "off" and level ~= "soft" and level ~= "standard" then
        level = "standard"
    end
    demoIntensity = level
    for k, btn in pairs(intensityBtns) do
        StyleMiniButtonSelected(btn, k == level)
    end
    RefreshNewRowOverride()
end

local function EnsurePanel()
    if panel then return panel end
    local f = CreateFrame("Frame", DEMO_FRAME_NAME, _G.UIParent)
    f:SetSize(780, 520)
    f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 20)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(40)
    -- 严格遵循 K12：容器本身禁止接收鼠标点击，仅按钮响应鼠标
    f:EnableMouse(false)
    f:Hide()

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.055, 0.07, 0.94)
    ST.ApplyRoundedBorder(f, 8, 0.86, 0.65, 0.50, 0.72, 8)

    local header = f:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(header, ST.FONT.heading or ST.FONT.body, 0.96, 0.82, 0.58, 1)
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -14)
    header:SetText("kkowoUI 动效新旧对比演示（仅脱战预览，不修改真实 HUD 与设置）")

    local closeBtn = CreateMiniButton(f, "关闭 (Esc)", 76, 22, function()
        CloseDemo()
    end)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -12)

    -- 控制栏：强度切换（关 / 柔和 / 标准）+ 一键连播全部 + 停止
    local intLbl = f:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(intLbl, ST.FONT.caption, 0.82, 0.86, 0.92, 1)
    intLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -44)
    intLbl:SetText("演示强度：")

    local intDefs = {
        { key = "off",      text = "关" },
        { key = "soft",     text = "柔和" },
        { key = "standard", text = "标准" },
    }
    for i, d in ipairs(intDefs) do
        local b = CreateMiniButton(f, d.text, 54, 22, function()
            SetDemoIntensity(d.key)
        end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 82 + (i - 1) * 60, -39)
        intensityBtns[d.key] = b
    end

    local playAllBtn = CreateMiniButton(f, "一键连播全部 (19 项)", 142, 22, function()
        PlayScriptByIndex(1, true)
    end)
    playAllBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 282, -39)

    local stopBtn = CreateMiniButton(f, "停止并重置", 82, 22, function()
        CleanupDemoRuntime()
        ResetRowBaseline(oldRow)
        ResetRowBaseline(newRow)
        if statusFS then statusFS:SetText("已停止，请点击任意剧本或「一键连播全部」。") end
    end)
    stopBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 432, -39)

    statusFS = f:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(statusFS, ST.FONT.caption, 0.72, 0.88, 0.78, 1)
    statusFS:SetPoint("LEFT", stopBtn, "RIGHT", 12, 0)
    statusFS:SetText("就绪：点击下方任意剧本查看上下新旧对比")

    -- 上下两排对比舞台
    oldRow = BuildComparisonRow(f, "旧效果（全部 fx_ 关闭，贴近改动前基线）", false, -72)
    newRow = BuildComparisonRow(f, "新效果（预览强度：标准，不改真实设置）", true, -208)

    -- 19 个独立剧本按钮网格（每行 5 个，共 4 行）
    local gridTop = -352
    local cols = 5
    local bw, bh, gx, gy = 142, 26, 10, 8
    for i, sc in ipairs(SCRIPTS) do
        local r = math_floor((i - 1) / cols)
        local c = (i - 1) % cols
        local idx = i
        local btn = CreateMiniButton(f, sc.label, bw, bh, function()
            PlayScriptByIndex(idx, false)
        end)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + c * (bw + gx), gridTop - r * (bh + gy))
        scriptBtns[i] = btn
    end

    local tipFS = f:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(tipFS, ST.FONT.caption, 0.66, 0.72, 0.80, 0.92)
    tipFS:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
    tipFS:SetText("提示：进入战斗或按 Esc 将自动关闭；喜欢/不喜欢某项可在「界面外观 → 主题与圆角 → 圆角与动效」单独开关。")

    f:HookScript("OnHide", CleanupDemoRuntime)

    -- 注册 Esc 关闭
    if type(_G.UISpecialFrames) == "table" then
        local exists = false
        for _, nm in ipairs(_G.UISpecialFrames) do
            if nm == DEMO_FRAME_NAME then exists = true; break end
        end
        if not exists then
            table_insert(_G.UISpecialFrames, DEMO_FRAME_NAME)
        end
    end
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.RegisterEscapeClose) == "function" then
        pcall(EUI.RegisterEscapeClose, f)
    end

    if not eventFrame then
        eventFrame = CreateFrame("Frame")
        eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        eventFrame:SetScript("OnEvent", function(_, ev)
            if ev == "PLAYER_REGEN_DISABLED" and panel and panel:IsShown() then
                CloseDemo("已进入战斗，自动关闭动效对比演示面板。")
            end
        end)
    end

    panel = f
    SetDemoIntensity(demoIntensity)
    return f
end

local function OpenDemo()
    if IsInCombatNow() then
        F.Print("请脱战后再使用 /kk motion demo。")
        return false
    end
    local f = EnsurePanel()
    RefreshNewRowOverride()
    ResetRowBaseline(oldRow)
    ResetRowBaseline(newRow)
    f:Show()
    if statusFS then
        statusFS:SetText("就绪：点击「一键连播全部」或下方任意剧本观看新旧对比")
    end
    return true
end

F.MotionDemo = {
    Open = OpenDemo,
    Close = CloseDemo,
    Toggle = function()
        if panel and panel:IsShown() then
            CloseDemo()
            return false
        end
        return OpenDemo()
    end,
    IsOpen = function()
        return panel ~= nil and panel:IsShown() == true
    end,
    SetIntensity = SetDemoIntensity,
    GetIntensity = function() return demoIntensity end,
    GetState = function()
        return {
            open = panel ~= nil and panel:IsShown() == true,
            intensity = demoIntensity,
            activeScript = demoActiveScript,
            playAllIndex = demoPlayAllIndex,
        }
    end,
    GetScripts = function() return SCRIPTS end,
    PlayAll = function()
        if not (panel and panel:IsShown()) then
            if not OpenDemo() then return false end
        end
        return PlayScriptByIndex(1, true)
    end,
    PlayScript = function(idOrIdx)
        if not (panel and panel:IsShown()) then
            if not OpenDemo() then return false end
        end
        if type(idOrIdx) == "number" then
            return PlayScriptByIndex(idOrIdx, false)
        end
        for i, sc in ipairs(SCRIPTS) do
            if sc.id == idOrIdx or sc.label == idOrIdx then
                return PlayScriptByIndex(i, false)
            end
        end
        return false
    end,
    HandleSlash = function(rest)
        local sub = ((rest or ""):match("^(%S+)") or ""):lower()
        if sub == "" or sub == "demo" or sub == "open" then
            return OpenDemo()
        elseif sub == "close" or sub == "hide" or sub == "stop" then
            CloseDemo()
            return true
        elseif sub == "all" then
            if OpenDemo() then return PlayScriptByIndex(1, true) end
            return false
        end
        F.Print("用法：/kk motion demo（打开脱战新旧动效对比面板）| /kk motion close（关闭）")
        return false
    end,
}
