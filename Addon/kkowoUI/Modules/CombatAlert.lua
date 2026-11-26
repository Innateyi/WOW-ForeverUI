----------------------------------------------------------------------
--  kkowoUI — Modules/CombatAlert.lua
--  现代简洁进/脱战提醒（保留经典剑盾动画，柔化现代配色与阴影排版）
--  • 修复动画关闭时旧动画回调可能误触发队列的问题
--  • 支持进战/脱战分别预览，并始终显示在设置面板之上
----------------------------------------------------------------------
local _, F = ...

local _G = _G
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
        animation = true,
        text = true,
        sound = false,
        soundEnter = "raidwarn",
        soundLeave = "ready",
        animationSize = 0.55,
        animationAlpha = 0.65,
        speed = 1.0,
        fontSize = 22,
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

local function StopAllAnimations()
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
        textFrame:Hide()
    end
end

local PlayAlert -- 前向声明

local function FinishCurrent()
    isPlaying = false
    curAlertType = nil
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
    shield.enter:SetScript("OnFinished", function() shield:Hide(); FinishCurrent() end)

    shield.leave = shield:CreateAnimationGroup()
    local slIn = AddAnim(shield.leave, "Alpha", 0.3, 0); slIn:SetFromAlpha(0); slIn:SetToAlpha(1); slIn:SetSmoothing("IN")
    local slSc = AddAnim(shield.leave, "Scale", 0.55, 0.55); slSc:SetScaleFrom(1, 1); slSc:SetScaleTo(0.15, 0.15)
    local slOut = AddAnim(shield.leave, "Alpha", 0.55, 0.55); slOut:SetFromAlpha(1); slOut:SetToAlpha(0); slOut:SetSmoothing("OUT")
    shield.leave:SetScript("OnFinished", function() shield:Hide(); FinishCurrent() end)
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
                if animFrame and animFrame.shield and isPlaying then
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

    -- 现代阴影文字帧
    textFrame = CreateAnimChild(alertFrame, 4, nil, false)
    textFrame.text = textFrame:CreateFontString(nil, "OVERLAY")
    textFrame.text:SetPoint("CENTER", 0, 0)

    local function onTextFinished()
        textFrame:Hide()
        if mod:GetDB().animation == false then
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

    animGroups = {
        animFrame.shield.enter, animFrame.shield.leave,
        animFrame.swordL.enter, animFrame.swordL.leave,
        animFrame.swordR.enter, animFrame.swordR.leave,
    }
    allSpeedGroups = {
        animFrame.shield.enter, animFrame.shield.leave,
        animFrame.swordL.enter, animFrame.swordL.leave,
        animFrame.swordR.enter, animFrame.swordR.leave,
        textFrame.enter, textFrame.leave,
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

    F.Theme.ApplyFont(textFrame.text, db.fontSize or 22, "", 1, 1, 1, 1)
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
    local useAnim = db.animation ~= false
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
            textFrame.text:SetText(db.enterText or "进入战斗")
            textFrame.text:SetTextColor(c[1], c[2], c[3], 1)
            local tw = F.PlainNumber(textFrame.text:GetStringWidth(), 100)
            local th = F.PlainNumber(textFrame.text:GetStringHeight(), 24)
            textFrame:SetSize(math.max(80, tw + 8), math.max(24, th + 4))
            textFrame:ClearAllPoints()
            textFrame:SetPoint("TOP", useAnim and animFrame or alertFrame, "BOTTOM", 0, -110 * sz)
            textFrame:Show()
            textFrame.enter:Restart()
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
            textFrame.text:SetText(db.leaveText or "脱离战斗")
            textFrame.text:SetTextColor(c[1], c[2], c[3], 1)
            local tw = F.PlainNumber(textFrame.text:GetStringWidth(), 100)
            local th = F.PlainNumber(textFrame.text:GetStringHeight(), 24)
            textFrame:SetSize(math.max(80, tw + 8), math.max(24, th + 4))
            textFrame:ClearAllPoints()
            textFrame:SetPoint("TOP", useAnim and animFrame or alertFrame, "BOTTOM", 0, -18 * sz)
            textFrame:Show()
            textFrame.leave:Restart()
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
    end)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function() PlayAlert("ENTER", false) end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function() PlayAlert("LEAVE", false) end)
end

function mod:OnDisable()
    table_wipe(alertQueue)
    StopAllAnimations()
    isPlaying = false
    curAlertType = nil
    if alertFrame then alertFrame:Hide() end
end

function mod:OnThemeChanged()
    ApplySizes()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "显示经典剑盾动画",
        tooltip = "进/脱战时播放柔和尺寸与透明度的剑盾动效。",
        getValue = function() return db.animation ~= false end,
        setValue = function(v) db.animation = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示提示文字",
        getValue = function() return db.text ~= false end,
        setValue = function(v) db.text = v == true end,
    }, {
        type = "toggle",
        text = "启用提示音效",
        getValue = function() return db.sound == true end,
        setValue = function(v) db.sound = v == true end,
    })
    y = y - h

    local soundVals = { none = "静音", raidwarn = "团队警报（8959）", ready = "就位确认（8960）" }
    local soundOrd = { "none", "raidwarn", "ready" }
    _, h = W:DualRow(parent, y, {
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
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "动画缩放",
        min = 0.3, max = 1.0, step = 0.05,
        getValue = function() return db.animationSize or 0.55 end,
        setValue = function(v) db.animationSize = v; ApplySizes() end,
    }, {
        type = "slider",
        text = "文字字号",
        min = 14, max = 32, step = 1,
        getValue = function() return db.fontSize or 22 end,
        setValue = function(v) db.fontSize = v; ApplySizes() end,
    })
    y = y - h

    _, h = W:WideDualButton(parent, "预览：进入战斗", "预览：脱离战斗", y,
        function() PlayAlert("ENTER", true) end,
        function() PlayAlert("LEAVE", true) end)
    y = y - h
    return y
end
