----------------------------------------------------------------------
--  kkowoUI — Modules/CombatAlert.lua
--  现代简洁进/脱战提醒（保留经典剑盾动画，柔化现代配色与阴影排版）
--  • 修复动画关闭时旧动画回调可能误触发队列的问题
--  • 支持进战/脱战分别预览，并始终显示在设置面板之上
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, pcall, unpack = ipairs, pcall, unpack
local table_insert, table_remove, table_wipe = table.insert, table.remove, table.wipe
local CreateFrame = CreateFrame

local mod = F.RegisterModule("combatAlert", {
    title = "进/脱战警报",
    desc = "保留经典剑盾动效，采用现代柔和珊瑚红/柔玉绿配色与轻量阴影文字。",
    group = "combat",
    order = 10,
    defaults = {
        enabled = true,
        alertStyle = "modern", -- "modern" = 现代粗斜体缩放发光 | "classic" = 经典剑盾 | "both" = 剑盾+斜体发光
        textPreset = "en",     -- "en" = Entering/Leaving Combat | "zh" = 进入/脱离战斗
        animation = true,
        text = true,
        sound = false,
        soundEnter = "raidwarn",
        soundLeave = "ready",
        animationSize = 0.55,
        animationAlpha = 0.65,
        speed = 1.0,
        fontSize = 24,
        enterText = "进入战斗",
        leaveText = "脱离战斗",
    },
})

local TEX_SHIELD = F.MEDIA .. "CombatAlert\\Shield.tga"
local TEX_SWORD  = F.MEDIA .. "CombatAlert\\Sword.tga"

local SOUND_KITS = {
    none = nil,
    raidwarn = 8959,
    ready = 8960,
}

local alertFrame, animFrame, textFrame
local isPlaying = false
local alertQueue = {}

local function CreateAnimChild(parent, level, texture, mirror)
    local f = CreateFrame("Frame", nil, parent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(level)
    f:SetAlpha(0)
    f:Hide()
    if texture then
        local tex = f:CreateTexture(nil, "ARTWORK")
        tex:SetTexture(texture)
        if mirror then
            local ULx, ULy, LLx, LLy, URx, URy, LRx, LRy = tex:GetTexCoord()
            tex:SetTexCoord(URx, URy, LRx, LRy, ULx, ULy, LLx, LLy)
        end
        tex:SetAllPoints()
        f.texture = tex
    end
    return f
end

local function AddAnim(group, kind, dur, delay)
    local a = group:CreateAnimation(kind)
    a:SetDuration(dur)
    a:SetStartDelay(delay or 0)
    return a
end

local animGroups = nil
local allSpeedGroups = nil
local curAlertType = nil
local curUseAnim = false
local alertGen = 0

local function StopAllAnimations()
    alertGen = alertGen + 1
    if animGroups then
        for _, g in ipairs(animGroups) do
            if g then g:Stop() end
        end
    end
    if animFrame then
        animFrame.shield:Hide()
        animFrame.swordL:Hide()
        animFrame.swordR:Hide()
    end
    if textFrame then
        textFrame.enter:Stop()
        textFrame.leave:Stop()
        if textFrame.modernPop then textFrame.modernPop:Stop() end
        if textFrame.beamAnim then textFrame.beamAnim:Stop() end
        if textFrame.beamLine then textFrame.beamLine:Hide() end
        textFrame:Hide()
    end
end

local PlayAlert -- 前向声明

local function FinishCurrent()
    isPlaying = false
    curAlertType = nil
    curUseAnim = false
    if #alertQueue > 0 then
        local nextType = table_remove(alertQueue, 1)
        PlayAlert(nextType, false)
    end
end

local function BuildFrames()
    if alertFrame then
        return
    end
    alertFrame = CreateFrame("Frame", "kkowoUI_CombatAlert", _G.UIParent)
    alertFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    alertFrame:SetSize(160, 140)

    F.Mover.Register({
        key = "CombatAlert",
        label = "进/脱战警报",
        frame = alertFrame,
        order = 30,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 0,
        defaultY = 260,
        isHidden = function() return not mod._active end,
    })

    animFrame = CreateFrame("Frame", nil, alertFrame)
    animFrame:SetPoint("TOP", alertFrame, "TOP", 0, 0)

    -- 盾
    local shield = CreateAnimChild(animFrame, 3, TEX_SHIELD, false)
    shield.enter = shield:CreateAnimationGroup()
    shield.enter.move = AddAnim(shield.enter, "Translation", 0.2, 0)
    local sfIn = AddAnim(shield.enter, "Alpha", 0.2, 0); sfIn:SetFromAlpha(0); sfIn:SetToAlpha(1); sfIn:SetSmoothing("IN")
    local sfOut = AddAnim(shield.enter, "Alpha", 0.3, 0.5); sfOut:SetFromAlpha(1); sfOut:SetToAlpha(0); sfOut:SetSmoothing("OUT")
    shield.enter:SetScript("OnFinished", function()
        shield:Hide()
        if isPlaying and curUseAnim then FinishCurrent() end
    end)

    shield.leave = shield:CreateAnimationGroup()
    local slIn = AddAnim(shield.leave, "Alpha", 0.3, 0); slIn:SetFromAlpha(0); slIn:SetToAlpha(1); slIn:SetSmoothing("IN")
    local slSc = AddAnim(shield.leave, "Scale", 0.55, 0.55); slSc:SetScaleFrom(1, 1); slSc:SetScaleTo(0.15, 0.15)
    local slOut = AddAnim(shield.leave, "Alpha", 0.55, 0.55); slOut:SetFromAlpha(1); slOut:SetToAlpha(0); slOut:SetSmoothing("OUT")
    shield.leave:SetScript("OnFinished", function()
        shield:Hide()
        if isPlaying and curUseAnim then FinishCurrent() end
    end)
    animFrame.shield = shield

    -- 剑（左、右）
    local function BuildSword(mirror, triggerShield)
        local sw = CreateAnimChild(animFrame, 2, TEX_SWORD, mirror)
        sw.enter = sw:CreateAnimationGroup()
        sw.enter.move = AddAnim(sw.enter, "Translation", 0.38, 0)
        local fin = AddAnim(sw.enter, "Alpha", 0.38, 0); fin:SetFromAlpha(0); fin:SetToAlpha(1); fin:SetSmoothing("IN")
        local fout = AddAnim(sw.enter, "Alpha", 0.3, 0.85); fout:SetFromAlpha(1); fout:SetToAlpha(0); fout:SetSmoothing("OUT")
        sw.enter:SetScript("OnFinished", function() sw:Hide() end)
        if triggerShield then
            fin:SetScript("OnFinished", function()
                if animFrame and animFrame.shield and isPlaying and curUseAnim then
                    animFrame.shield:Show()
                    animFrame.shield.enter:Play()
                end
            end)
        end

        sw.leave = sw:CreateAnimationGroup()
        local lin = AddAnim(sw.leave, "Alpha", 0.3, 0); lin:SetFromAlpha(0); lin:SetToAlpha(1); lin:SetSmoothing("IN")
        sw.leave.move = AddAnim(sw.leave, "Translation", 0.55, 0.55)
        local lout = AddAnim(sw.leave, "Alpha", 0.55, 0.55); lout:SetFromAlpha(1); lout:SetToAlpha(0); lout:SetSmoothing("OUT")
        sw.leave:SetScript("OnFinished", function() sw:Hide() end)
        return sw
    end

    animFrame.swordL = BuildSword(false, true)
    animFrame.swordR = BuildSword(true, false)

    -- 现代阴影文字帧（含现代粗斜体发光弹入动效）
    textFrame = CreateAnimChild(alertFrame, 4, nil, false)
    local halo = textFrame:CreateTexture(nil, "BACKGROUND")
    halo:SetTexture(F.MEDIA .. "Textures\\SoftGlow.tga")
    halo:SetBlendMode("ADD")
    halo:SetPoint("CENTER", textFrame, "CENTER", 0, 0)
    halo:SetSize(220, 56)
    halo:Hide()
    textFrame.halo = halo

    -- 现代流光横刃底线（进/脱战时自中心向两侧展开并柔散）
    local beamLine = textFrame:CreateTexture(nil, "ARTWORK")
    beamLine:SetTexture(F.MEDIA .. "Textures\\SoftGlow.tga")
    beamLine:SetBlendMode("ADD")
    beamLine:SetPoint("BOTTOM", textFrame, "BOTTOM", 0, 0)
    beamLine:SetSize(220, 4)
    beamLine:SetAlpha(0)
    beamLine:Hide()
    textFrame.beamLine = beamLine

    local beamAnim = beamLine:CreateAnimationGroup()
    local bSc1 = AddAnim(beamAnim, "Scale", 0.22, 0); bSc1:SetOrder(1); bSc1:SetOrigin("CENTER", 0, 0); bSc1:SetScaleFrom(0.08, 1.0); bSc1:SetScaleTo(1.08, 1.0); bSc1:SetSmoothing("OUT")
    local bAl1 = AddAnim(beamAnim, "Alpha", 0.12, 0); bAl1:SetOrder(1); bAl1:SetFromAlpha(0); bAl1:SetToAlpha(0.92); bAl1:SetSmoothing("OUT")
    local bSc2 = AddAnim(beamAnim, "Scale", 0.36, 0.24); bSc2:SetOrder(2); bSc2:SetOrigin("CENTER", 0, 0); bSc2:SetScaleFrom(1.08, 1.0); bSc2:SetScaleTo(0.68, 1.0); bSc2:SetSmoothing("IN")
    local bAl2 = AddAnim(beamAnim, "Alpha", 0.36, 0.24); bAl2:SetOrder(2); bAl2:SetFromAlpha(0.92); bAl2:SetToAlpha(0); bAl2:SetSmoothing("OUT")
    beamAnim:SetScript("OnFinished", function() beamLine:SetAlpha(0); beamLine:Hide() end)
    beamAnim:SetScript("OnStop", function() beamLine:SetAlpha(0); beamLine:Hide() end)
    textFrame.beamAnim = beamAnim

    textFrame.text = textFrame:CreateFontString(nil, "OVERLAY")
    textFrame.text:SetPoint("CENTER", 0, 0)

    local function onTextFinished()
        textFrame:Hide()
        if isPlaying and not curUseAnim then
            FinishCurrent()
        end
    end

    textFrame.enter = textFrame:CreateAnimationGroup()
    textFrame.enter.up = AddAnim(textFrame.enter, "Translation", 0.38, 0)
    textFrame.enter.down = AddAnim(textFrame.enter, "Translation", 0.1, 0.38)
    local tin = AddAnim(textFrame.enter, "Alpha", 0.45, 0); tin:SetFromAlpha(0); tin:SetToAlpha(1); tin:SetSmoothing("IN")
    local tout = AddAnim(textFrame.enter, "Alpha", 0.3, 0.85); tout:SetFromAlpha(1); tout:SetToAlpha(0); tout:SetSmoothing("OUT")
    textFrame.enter:SetScript("OnFinished", onTextFinished)

    textFrame.leave = textFrame:CreateAnimationGroup()
    local ltin = AddAnim(textFrame.leave, "Alpha", 0.3, 0); ltin:SetFromAlpha(0); ltin:SetToAlpha(1); ltin:SetSmoothing("IN")
    textFrame.leave.up = AddAnim(textFrame.leave, "Translation", 0.55, 0.55)
    local ltout = AddAnim(textFrame.leave, "Alpha", 0.55, 0.55); ltout:SetFromAlpha(1); ltout:SetToAlpha(0); ltout:SetSmoothing("OUT")
    textFrame.leave:SetScript("OnFinished", onTextFinished)

    -- 现代粗斜体缩放弹入 + 平滑淡出动效（零 OnUpdate，分段 Order 防止缩放重叠冲突）
    textFrame.modernPop = textFrame:CreateAnimationGroup()
    local mIn = AddAnim(textFrame.modernPop, "Alpha", 0.14, 0); mIn:SetOrder(1); mIn:SetFromAlpha(0); mIn:SetToAlpha(1); mIn:SetSmoothing("OUT")
    local mSc1 = AddAnim(textFrame.modernPop, "Scale", 0.16, 0); mSc1:SetOrder(1); mSc1:SetOrigin("CENTER", 0, 0); mSc1:SetScaleFrom(0.72, 0.72); mSc1:SetScaleTo(1.06, 1.06); mSc1:SetSmoothing("OUT")
    local mSc2 = AddAnim(textFrame.modernPop, "Scale", 0.10, 0); mSc2:SetOrder(2); mSc2:SetOrigin("CENTER", 0, 0); mSc2:SetScaleFrom(1.06, 1.06); mSc2:SetScaleTo(1.0, 1.0); mSc2:SetSmoothing("IN")
    local mLift = AddAnim(textFrame.modernPop, "Translation", 0.32, 0.52); mLift:SetOrder(3); mLift:SetOffset(0, 14); mLift:SetSmoothing("IN")
    local mOut = AddAnim(textFrame.modernPop, "Alpha", 0.32, 0.52); mOut:SetOrder(3); mOut:SetFromAlpha(1); mOut:SetToAlpha(0); mOut:SetSmoothing("IN")
    textFrame.modernPop:SetScript("OnFinished", onTextFinished)

    animGroups = {
        animFrame.shield.enter, animFrame.shield.leave,
        animFrame.swordL.enter, animFrame.swordL.leave,
        animFrame.swordR.enter, animFrame.swordR.leave,
    }
    allSpeedGroups = {
        animFrame.shield.enter, animFrame.shield.leave,
        animFrame.swordL.enter, animFrame.swordL.leave,
        animFrame.swordR.enter, animFrame.swordR.leave,
        textFrame.enter, textFrame.leave, textFrame.modernPop, textFrame.beamAnim,
    }
end

local function ApplySizes()
    if not alertFrame then
        return
    end
    local db = mod:GetDB()
    local sz = db.animationSize or 0.55
    local texSize = 200 * sz
    local swordRange = 125 * sz
    local shieldRange = 62 * sz

    animFrame:SetSize(240 * sz, 210 * sz)
    animFrame:SetAlpha(db.animationAlpha or 0.65)
    animFrame.shield:SetSize(0.8 * texSize, 0.8 * texSize)
    animFrame.shield.enter.move:SetOffset(0, -shieldRange)

    animFrame.swordL:SetSize(texSize, texSize)
    animFrame.swordL.enter.move:SetOffset(swordRange, swordRange)
    animFrame.swordL.leave.move:SetOffset(swordRange, swordRange)

    animFrame.swordR:SetSize(texSize, texSize)
    animFrame.swordR.enter.move:SetOffset(-swordRange, swordRange)
    animFrame.swordR.leave.move:SetOffset(-swordRange, swordRange)

    local style = db.alertStyle or "modern"
    if style == "modern" then
        alertFrame:SetSize(220, 48)
    else
        alertFrame:SetSize(160, 140)
    end
    local fsz = db.fontSize or 24
    if style == "modern" or style == "both" then
        local italicFont = F.MEDIA .. "Fonts\\YouSheBiaoTiHei.ttf"
        local okF, applied = pcall(textFrame.text.SetFont, textFrame.text, italicFont, fsz, "OUTLINE")
        if not okF or applied == false then
            pcall(textFrame.text.SetFont, textFrame.text, F.Theme.GetFont(), fsz, "OUTLINE")
        end
        textFrame.text:SetShadowOffset(2, -2)
    else
        -- 绕开 Theme.ApplyFont 的字号缓存：从 modern 切回 classic 时即使字号未变也必须把优设字体换回主题正文字体
        pcall(textFrame.text.SetFont, textFrame.text, F.Theme.GetFont(), fsz, "")
        textFrame.text:SetTextColor(1, 1, 1, 1)
        textFrame.text:SetShadowColor(0, 0, 0, 0.85)
        textFrame.text:SetShadowOffset(1, -1)
    end
    textFrame.enter.up:SetOffset(0, 150 * sz)
    textFrame.enter.down:SetOffset(0, -36 * sz)
    textFrame.leave.up:SetOffset(0, 36 * sz)

    local spd = db.speed or 1.0
    if allSpeedGroups then
        for _, g in ipairs(allSpeedGroups) do
            if g and g.SetAnimationSpeedMultiplier then
                g:SetAnimationSpeedMultiplier(spd)
            end
        end
    end
end

PlayAlert = function(alertType, preview)
    if not alertFrame then
        BuildFrames()
        ApplySizes()
    end
    if not alertFrame:IsShown() then alertFrame:Show() end
    local db = mod:GetDB()
    local style = db.alertStyle or "modern"
    local useAnim = (style ~= "modern") and (db.animation ~= false)
    -- 「显示提示文字」在任何风格下都生效（关掉文字 + 开音效 = 只听声音不出字）
    local useText = db.text ~= false
    if not preview and not useAnim and not useText and not db.sound then
        return
    end
    if isPlaying then
        if preview then
            table_wipe(alertQueue)
            StopAllAnimations()
        else
            -- 最多仅排队 1 条最新状态转换，避免速刷小怪时旧提示堆积滞后回放
            if alertType == curAlertType then
                table_wipe(alertQueue)
            else
                alertQueue[1] = alertType
            end
            return
        end
    else
        StopAllAnimations()
    end
    isPlaying = true
    curAlertType = alertType
    curUseAnim = useAnim
    alertGen = alertGen + 1

    if preview or db.sound then
        local kitKey = (alertType == "ENTER") and db.soundEnter or db.soundLeave
        local kitID = SOUND_KITS[kitKey]
        if kitID and _G.PlaySound then
            pcall(_G.PlaySound, kitID, "Master")
        end
    end

    local sz = db.animationSize or 0.55

    if alertType == "ENTER" then
        if useAnim then
            animFrame.shield:ClearAllPoints()
            animFrame.shield:SetPoint("CENTER", animFrame, "CENTER", 0, 48 * sz)
            animFrame.swordL:ClearAllPoints()
            animFrame.swordL:SetPoint("CENTER", animFrame, "CENTER", -145 * sz, -145 * sz)
            animFrame.swordR:ClearAllPoints()
            animFrame.swordR:SetPoint("CENTER", animFrame, "CENTER", 145 * sz, -145 * sz)
            animFrame.swordL:Show()
            animFrame.swordR:Show()
            animFrame.swordL.enter:Restart()
            animFrame.swordR.enter:Restart()
        end
        if useText then
            local c = F.Theme.COLORS.danger
            local label = (db.textPreset == "en") and "Entering Combat" or (db.enterText or "进入战斗")
            textFrame.text:SetText(label)
            if style == "modern" or style == "both" then
                textFrame.text:SetTextColor(1, 0.96, 0.96, 1)
                textFrame.text:SetShadowColor(c[1], c[2], c[3], 0.95)
                if textFrame.halo then
                    if F.StyleTokens and F.StyleTokens.ApplyGradient then
                        F.StyleTokens.ApplyGradient(textFrame.halo, "HORIZONTAL", c[1], c[2], c[3], 0.56, 1.0, 0.62, 0.28, 0.52)
                    else
                        textFrame.halo:SetVertexColor(c[1], c[2], c[3], 0.55)
                    end
                    textFrame.halo:Show()
                end
            else
                textFrame.text:SetTextColor(c[1], c[2], c[3], 1)
                if textFrame.halo then textFrame.halo:Hide() end
            end
            local tw = F.PlainNumber(textFrame.text:GetStringWidth(), 120)
            local th = F.PlainNumber(textFrame.text:GetStringHeight(), 26)
            textFrame:SetSize(math.max(100, tw + 16), math.max(28, th + 8))
            if textFrame.halo then textFrame.halo:SetSize(math.max(160, tw + 72), math.max(44, th + 28)) end
            if textFrame.beamLine then
                textFrame.beamLine:SetSize(math.max(150, tw + 56), 4)
                if style == "modern" or style == "both" then
                    if F.StyleTokens and F.StyleTokens.ApplyGradient then
                        F.StyleTokens.ApplyGradient(textFrame.beamLine, "HORIZONTAL", c[1], c[2], c[3], 0.92, 1.0, 0.72, 0.36, 0.92)
                    else
                        textFrame.beamLine:SetVertexColor(c[1], c[2], c[3], 0.92)
                    end
                    textFrame.beamLine:SetAlpha(0)
                    textFrame.beamLine:Show()
                    textFrame.beamAnim:Restart()
                else
                    textFrame.beamLine:Hide()
                end
            end
            textFrame:ClearAllPoints()
            if style == "modern" then
                textFrame:SetPoint("CENTER", alertFrame, "CENTER", 0, 0)
                textFrame:Show()
                textFrame.modernPop:Restart()
            else
                textFrame:SetPoint("TOP", useAnim and animFrame or alertFrame, "BOTTOM", 0, -110 * sz)
                textFrame:Show()
                textFrame.enter:Restart()
            end
        end
    else
        if useAnim then
            animFrame.shield:ClearAllPoints()
            animFrame.shield:SetPoint("CENTER", animFrame, "CENTER", 0, -14 * sz)
            animFrame.swordL:ClearAllPoints()
            animFrame.swordL:SetPoint("CENTER", animFrame, "CENTER", -18 * sz, -18 * sz)
            animFrame.swordR:ClearAllPoints()
            animFrame.swordR:SetPoint("CENTER", animFrame, "CENTER", 18 * sz, -18 * sz)
            animFrame.shield:Show()
            animFrame.swordL:Show()
            animFrame.swordR:Show()
            animFrame.shield.leave:Restart()
            animFrame.swordL.leave:Restart()
            animFrame.swordR.leave:Restart()
        end
        if useText then
            local c = F.Theme.COLORS.good
            local label = (db.textPreset == "en") and "Leaving Combat" or (db.leaveText or "脱离战斗")
            textFrame.text:SetText(label)
            if style == "modern" or style == "both" then
                textFrame.text:SetTextColor(0.95, 1.0, 0.98, 1)
                textFrame.text:SetShadowColor(c[1], c[2], c[3], 0.95)
                if textFrame.halo then
                    if F.StyleTokens and F.StyleTokens.ApplyGradient then
                        F.StyleTokens.ApplyGradient(textFrame.halo, "HORIZONTAL", c[1], c[2], c[3], 0.52, 0.42, 0.92, 1.0, 0.48)
                    else
                        textFrame.halo:SetVertexColor(c[1], c[2], c[3], 0.50)
                    end
                    textFrame.halo:Show()
                end
            else
                textFrame.text:SetTextColor(c[1], c[2], c[3], 1)
                if textFrame.halo then textFrame.halo:Hide() end
            end
            local tw = F.PlainNumber(textFrame.text:GetStringWidth(), 120)
            local th = F.PlainNumber(textFrame.text:GetStringHeight(), 26)
            textFrame:SetSize(math.max(100, tw + 16), math.max(28, th + 8))
            if textFrame.halo then textFrame.halo:SetSize(math.max(160, tw + 72), math.max(44, th + 28)) end
            if textFrame.beamLine then
                textFrame.beamLine:SetSize(math.max(150, tw + 56), 4)
                if style == "modern" or style == "both" then
                    if F.StyleTokens and F.StyleTokens.ApplyGradient then
                        F.StyleTokens.ApplyGradient(textFrame.beamLine, "HORIZONTAL", c[1], c[2], c[3], 0.90, 0.50, 0.94, 1.0, 0.90)
                    else
                        textFrame.beamLine:SetVertexColor(c[1], c[2], c[3], 0.90)
                    end
                    textFrame.beamLine:SetAlpha(0)
                    textFrame.beamLine:Show()
                    textFrame.beamAnim:Restart()
                else
                    textFrame.beamLine:Hide()
                end
            end
            textFrame:ClearAllPoints()
            if style == "modern" then
                textFrame:SetPoint("CENTER", alertFrame, "CENTER", 0, 0)
                textFrame:Show()
                textFrame.modernPop:Restart()
            else
                textFrame:SetPoint("TOP", useAnim and animFrame or alertFrame, "BOTTOM", 0, -18 * sz)
                textFrame:Show()
                textFrame.leave:Restart()
            end
        end
    end

    if not useAnim and not useText then
        FinishCurrent()
    end
end

function mod:OnEnable()
    BuildFrames()
    ApplySizes()
    if alertFrame then alertFrame:Show() end
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        -- 过图若打断播放中的动效，暴雪不会补发 OnFinished，必须复位队列防止后续进/脱战提醒卡死
        table_wipe(alertQueue)
        StopAllAnimations()
        isPlaying = false
        curAlertType = nil
        curUseAnim = false
    end)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function() PlayAlert("ENTER", false) end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function() PlayAlert("LEAVE", false) end)
end

function mod:OnDisable()
    table_wipe(alertQueue)
    StopAllAnimations()
    isPlaying = false
    curAlertType = nil
    curUseAnim = false
    if alertFrame then alertFrame:Hide() end
end

function mod:OnThemeChanged()
    ApplySizes()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "进/脱战提醒风格",
        tooltip = "选择现代粗斜体、经典剑盾动画或两者叠加样式。",
        values = {
            modern  = "现代粗斜体（推荐）",
            classic = "经典剑盾动画",
            both    = "剑盾 + 现代斜体",
        },
        order = { "modern", "classic", "both" },
        getValue = function() return db.alertStyle or "modern" end,
        setValue = function(v) db.alertStyle = v; ApplySizes() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示提示文字",
        tooltip = "关闭后不再显示进脱战文字，可仅保留音效或动画。",
        getValue = function() return db.text ~= false end,
        setValue = function(v) db.text = v == true end,
    }, {
        type = "dropdown",
        text = "提示文案预设",
        values = {
            en = "英文（Entering / Leaving Combat）",
            zh = "中文（进入战斗 / 脱离战斗）",
        },
        order = { "en", "zh" },
        getValue = function() return db.textPreset or "en" end,
        setValue = function(v) db.textPreset = v end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "启用提示音效",
        getValue = function() return db.sound == true end,
        setValue = function(v) db.sound = v == true end,
    }, {
        type = "toggle",
        text = "显示剑盾动画",
        tooltip = "仅在经典剑盾或叠加风格下生效。",
        disabled = function() return (db.alertStyle or "modern") == "modern" end,
        getValue = function() return db.animation ~= false end,
        setValue = function(v) db.animation = v == true end,
    })
    y = y - h

    _, h = W:WideDualButton(parent, "预览：进入战斗", "预览：脱离战斗", y,
        function() PlayAlert("ENTER", true) end,
        function() PlayAlert("LEAVE", true) end)
    y = y - h

    local function buildAdv(w, p, curY)
        local _, rh
        local soundVals = { none = "静音", raidwarn = "团队警报（8959）", ready = "就位确认（8960）" }
        local soundOrd = { "none", "raidwarn", "ready" }
        _, rh = w:DualRow(p, curY, {
            type = "dropdown",
            text = "进战音效",
            values = soundVals, order = soundOrd,
            getValue = function() return db.soundEnter or "raidwarn" end,
            setValue = function(v) db.soundEnter = v end,
        }, {
            type = "dropdown",
            text = "脱战音效",
            values = soundVals, order = soundOrd,
            getValue = function() return db.soundLeave or "ready" end,
            setValue = function(v) db.soundLeave = v end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "slider",
            text = "动画缩放 (倍)",
            min = 0.3, max = 1.0, step = 0.05,
            getValue = function() return db.animationSize or 0.55 end,
            setValue = function(v) db.animationSize = v; ApplySizes() end,
        }, {
            type = "slider",
            text = "文字字号 (px)",
            min = 14, max = 32, step = 1,
            getValue = function() return db.fontSize or 24 end,
            setValue = function(v) db.fontSize = v; ApplySizes() end,
        })
        curY = curY - rh
        return curY
    end

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("combatAlert", W, parent, y, buildAdv, blank)
    else
        y = buildAdv(W, parent, y)
    end
    return y
end
