----------------------------------------------------------------------
--  kkowoUI — Modules/LootToast.lua
--  现代 MMO 悬浮拾取与收益微播报（配合极速静默拾取，彻底告别掉落闪窗与翻聊天框）
--    • 物品拾取（按品质着色左竖条 + 图标 + 数量自动合并，任务物品无视品质门槛始终显示）
--    • 金币拾取（自动合并连续拾取收益）
--    • 经验值获取（+XP 柔和紫 / 职业色微条）
--    • 声望提升（翡翠绿阵营声望微条）
--    • 纯事件驱动 + 原生 AnimationGroup 丝滑滑入淡出（零 Lua OnUpdate，极低开销）
--    • 脱战悬停物品卡片可查看完整装备鼠标提示并暂停消失
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_floor, math_max, math_min, pcall, tonumber, type = ipairs, math.floor, math.max, math.min, pcall, tonumber, type
local string_format = string.format
local table_remove = table.remove
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("lootToast", {
    title = "拾取微播报",
    desc = "在屏幕侧边堆叠播报拾取物品、金币、经验与声望，同类自动合并。",
    group = "utility",
    order = 18,
    defaults = {
        enabled = true,
        euiConflictMode = "takeover", -- "takeover"（默认：停用 EUI 拾取播报，由本模块 PrettyTooltip 渐变尾淡卡片接管）| "auto_yield"（让位给 EUI）| "both"
        v2TakeoverMigrated = false,
        v3PrettyFadeMigrated = false,
        v4GrowDownMigrated = false,
        showItems = true,
        showMoney = true,
        showXP = true,
        showRep = true,
        minQuality = 1,       -- 0=含灰装, 1=白装起（默认，任务物品无视此限制）, 2=绿装起
        maxVisible = 5,
        holdSeconds = 3.2,
        width = 204,
        growUp = false,
    },
})

local ICON_COIN = 133784
local ICON_XP   = 134939
local ICON_REP  = 236681

local container = nil
local activeToasts = {}
local spareToasts = {}
local pendingQueue = {}
local queueTimerActive = false
local queueGen = 0
local lastPushTime = 0
local selfLootPatterns = nil

-- 将暴雪本地化格式化模板（如 "你获得了物品：%s。"）转成安全的 Lua 匹配正则
local function GlobalPatternToLua(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local escaped = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    escaped = escaped:gsub("%%%%%d+%%%$s", "(.+)")
    escaped = escaped:gsub("%%%%%d+%%%$d", "(%%d+)")
    escaped = escaped:gsub("%%%%s", "(.+)")
    escaped = escaped:gsub("%%%%d", "(%%d+)")
    return "^" .. escaped .. "$"
end

local function EnsureSelfLootPatterns()
    if selfLootPatterns then return selfLootPatterns end
    selfLootPatterns = {}
    local keys = {
        "LOOT_ITEM_SELF_MULTIPLE",
        "LOOT_ITEM_SELF",
        "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
        "LOOT_ITEM_PUSHED_SELF",
        "LOOT_ITEM_CREATED_SELF_MULTIPLE",
        "LOOT_ITEM_CREATED_SELF",
    }
    for _, k in ipairs(keys) do
        local pat = GlobalPatternToLua(_G[k])
        if pat then
            selfLootPatterns[#selfLootPatterns + 1] = pat
        end
    end
    return selfLootPatterns
end

local function IsSelfLootMessage(msg)
    for _, pat in ipairs(EnsureSelfLootPatterns()) do
        if msg:match(pat) then
            return true
        end
    end
    -- 兜底中文/英文前缀（排除“XXX获得了...”）
    if msg:find("^你获得了") or msg:find("^你制造了") or msg:find("^You receive") or msg:find("^You create") then
        return true
    end
    return false
end

local function ParseMoneyCopper(msg)
    local total = 0
    local g = msg:match("(%d+)%s*金") or msg:match("(%d+)%s*[Gg]old")
    local s = msg:match("(%d+)%s*银") or msg:match("(%d+)%s*[Ss]ilver")
    local c = msg:match("(%d+)%s*铜") or msg:match("(%d+)%s*[Cc]opper")
    if g then total = total + (tonumber(g) or 0) * 10000 end
    if s then total = total + (tonumber(s) or 0) * 100 end
    if c then total = total + (tonumber(c) or 0) end
    return total
end

local function ParseXPGain(msg)
    local xp = msg:match("(%d+)%s*点经验")
        or msg:match("获得%s*(%d+)%s*经验")
        or msg:match("gain%s+(%d+)%s+experience")
    return xp and tonumber(xp) or nil
end

local function ParseRepGain(msg)
    local fac, amt = msg:match("你在(.+)中的声望提高了(%d+)点")
    if not fac then
        fac, amt = msg:match("你对(.+)的声望提高了(%d+)点")
    end
    if not fac then
        fac, amt = msg:match("Your reputation with (.+) has increased by (%d+)")
    end
    if not fac then
        fac, amt = msg:match("Reputation with (.+) increased by (%d+)")
    end
    if fac and amt then
        return fac, tonumber(amt)
    end
    return nil, nil
end

local TOAST_H = 28
local SLIDE_OFFSET = 24
local FADE_IN_DUR = 0.35
local FADE_OUT_DUR = 0.52
local STAGGER_STEP = 0.11

local function EnsureContainer()
    if container then return end
    local db = mod:GetDB()
    local w = db.width or 204
    local maxVis = db.maxVisible or 5
    container = CreateFrame("Frame", "kkowoUI_LootToast", _G.UIParent)
    container:SetSize(w, maxVis * (TOAST_H + 4))
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(10)

    F.Mover.Register({
        key = "LootToast",
        label = "现代拾取与收益微播报",
        frame = container,
        order = 32,
        defaultPoint = "RIGHT",
        defaultRelPoint = "RIGHT",
        defaultX = -24,
        defaultY = -170,
        isHidden = function() return not mod._active end,
    })
end

local LayoutToasts
local ReleaseToast

local function DisableSnap(tex)
    if not tex then return end
    local PP = _G.EllesmereUI and _G.EllesmereUI.PP
    if PP and PP.DisablePixelSnap then
        pcall(PP.DisablePixelSnap, tex)
    else
        if tex.SetSnapToPixelGrid then pcall(tex.SetSnapToPixelGrid, tex, false) end
        if tex.SetTexelSnappingBias then pcall(tex.SetTexelSnappingBias, tex, 0) end
    end
end

local function ApplyHorizGrad(tex, r1, g1, b1, a1, r2, g2, b2, a2)
    local ST = F.StyleTokens
    if ST and ST.ApplyGradient then
        ST.ApplyGradient(tex, "HORIZONTAL", r1, g1, b1, a1, r2, g2, b2, a2)
    else
        tex:SetColorTexture(r1, g1, b1, (a1 + a2) * 0.5)
    end
end

local ArmToastFade

local function AcquireToast()
    local t = table_remove(spareToasts)
    if t then return t end

    t = CreateFrame("Frame", nil, container)
    t:SetSize(204, TOAST_H)
    t:SetClampedToScreen(true)
    if t.SetMouseMotionEnabled and t.SetMouseClickEnabled then
        t:SetMouseMotionEnabled(true)
        t:SetMouseClickEnabled(false)
    else
        t:EnableMouse(true)
    end

    local ST = F.StyleTokens
    -- PrettyTooltip 同款深邃黑曜石底 + 向右尾部渐淡至透明（紧凑比例、关闭像素吸附避免滑动闪烁）
    local bg = t:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints(t)
    bg:SetColorTexture(1, 1, 1, 1)
    DisableSnap(bg)
    t._bg = bg

    local headGlow = t:CreateTexture(nil, "BACKGROUND", nil, -5)
    headGlow:SetPoint("TOPLEFT", t, "TOPLEFT", 2, -1)
    headGlow:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 2, 1)
    headGlow:SetWidth(128)
    headGlow:SetColorTexture(1, 1, 1, 1)
    DisableSnap(headGlow)
    t._headGlow = headGlow

    local leftBar = t:CreateTexture(nil, "OVERLAY", nil, 3)
    leftBar:SetWidth(2)
    leftBar:SetPoint("TOPLEFT", t, "TOPLEFT", 0, -1)
    leftBar:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 0, 1)
    leftBar:SetColorTexture(1, 1, 1, 1)
    DisableSnap(leftBar)
    t._leftBar = leftBar

    local topLine = t:CreateTexture(nil, "ARTWORK", nil, 4)
    topLine:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
    topLine:SetPoint("TOPRIGHT", t, "TOPRIGHT", 0, 0)
    topLine:SetColorTexture(1, 1, 1, 1)
    if ST and ST.Hairline then ST.Hairline(topLine) else topLine:SetHeight(1); DisableSnap(topLine) end
    t._topLine = topLine

    local botLine = t:CreateTexture(nil, "ARTWORK", nil, 3)
    botLine:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 0, 0)
    botLine:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 0, 0)
    botLine:SetColorTexture(1, 1, 1, 1)
    if ST and ST.Hairline then ST.Hairline(botLine) else botLine:SetHeight(1); DisableSnap(botLine) end
    t._botLine = botLine

    local iconBg = t:CreateTexture(nil, "ARTWORK", nil, 0)
    iconBg:SetSize(20, 20)
    iconBg:SetPoint("LEFT", t, "LEFT", 7, 0)
    iconBg:SetColorTexture(0.14, 0.16, 0.22, 0.84)
    DisableSnap(iconBg)
    local icon = t:CreateTexture(nil, "ARTWORK", nil, 1)
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    DisableSnap(icon)
    t._iconBg = iconBg
    t._icon = icon

    local rightFS = t:CreateFontString(nil, "OVERLAY")
    rightFS:SetDrawLayer("OVERLAY", 5)
    F.Theme.ApplyFont(rightFS, 11, "OUTLINE", 0.94, 0.96, 0.98, 1)
    rightFS:SetHeight(TOAST_H)
    rightFS:SetPoint("RIGHT", t, "RIGHT", -10, 0)
    rightFS:SetJustifyH("RIGHT")
    rightFS:SetWordWrap(false)
    t._right = rightFS

    local nameFS = t:CreateFontString(nil, "OVERLAY")
    nameFS:SetDrawLayer("OVERLAY", 5)
    F.Theme.ApplyFont(nameFS, 12, "OUTLINE", 0.96, 0.97, 0.99, 1)
    nameFS:SetHeight(TOAST_H)
    nameFS:SetPoint("LEFT", iconBg, "RIGHT", 6, 0)
    nameFS:SetPoint("RIGHT", rightFS, "LEFT", -6, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    t._name = nameFS

    -- 与 EUI LootFeed 同款零闪烁入场：播放前 SetAlpha(0) 防止 Order 1 首帧全不透明闪现，
    -- Order 2 位移与淡入等长并启用 SetToFinalAlpha(true)，结束后自动接管停留+淡出。
    local animIn = t:CreateAnimationGroup()
    animIn:SetToFinalAlpha(true)
    local aJump = animIn:CreateAnimation("Translation")
    aJump:SetOrder(1)
    aJump:SetOffset(SLIDE_OFFSET, 0)
    aJump:SetDuration(0)
    local aSlide = animIn:CreateAnimation("Translation")
    aSlide:SetOrder(2)
    aSlide:SetOffset(-SLIDE_OFFSET, 0)
    aSlide:SetDuration(FADE_IN_DUR)
    aSlide:SetSmoothing("OUT")
    local aFadeIn = animIn:CreateAnimation("Alpha")
    aFadeIn:SetOrder(2)
    aFadeIn:SetFromAlpha(0)
    aFadeIn:SetToAlpha(1)
    aFadeIn:SetDuration(FADE_IN_DUR)
    aFadeIn:SetSmoothing("OUT")
    animIn:SetScript("OnFinished", function()
        t:SetAlpha(1)
        ArmToastFade(t)
    end)
    t._animIn = animIn

    local animOut = t:CreateAnimationGroup()
    animOut:SetToFinalAlpha(true)
    local aOutSlide = animOut:CreateAnimation("Translation")
    aOutSlide:SetOrder(1)
    aOutSlide:SetOffset(14, 0)
    aOutSlide:SetDuration(FADE_OUT_DUR)
    aOutSlide:SetSmoothing("IN_OUT")
    local aFadeOut = animOut:CreateAnimation("Alpha")
    aFadeOut:SetOrder(1)
    aFadeOut:SetFromAlpha(1)
    aFadeOut:SetToAlpha(0)
    aFadeOut:SetDuration(FADE_OUT_DUR)
    aFadeOut:SetSmoothing("IN_OUT")
    animOut:SetScript("OnFinished", function()
        ReleaseToast(t)
    end)
    t._animOut = animOut
    t._outSlide = aOutSlide
    t._outFade = aFadeOut

    t:SetScript("OnEnter", function(self)
        self._hovered = true
        self._fadeStartAt = nil
        if not self._animIn:IsPlaying() then
            self._animOut:Stop()
            self:SetAlpha(1)
        end
        if self._link and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT", -6, 0)
            pcall(GameTooltip.SetHyperlink, GameTooltip, self._link)
            GameTooltip:Show()
        end
    end)
    t:SetScript("OnLeave", function(self)
        self._hovered = false
        if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(self) then
            GameTooltip:Hide()
        end
        ArmToastFade(self, 1.0)
    end)

    t:Hide()
    return t
end

ReleaseToast = function(t, skipLayout)
    if not t then return end
    t._animIn:Stop()
    t._animOut:Stop()
    t:Hide()
    t._key = nil
    t._link = nil
    t._isPreview = nil
    t._lastColor = nil
    t._slotPt = nil
    t._slotY = nil
    t._slotW = nil
    t._amount = 0
    t._fadeStartAt = nil
    t._hovered = false
    local removed = false
    for i = #activeToasts, 1, -1 do
        if activeToasts[i] == t then
            table_remove(activeToasts, i)
            removed = true
            break
        end
    end
    if not removed then return end
    spareToasts[#spareToasts + 1] = t
    if not skipLayout and LayoutToasts then LayoutToasts() end
end

local function ClearAllToasts()
    queueGen = queueGen + 1
    queueTimerActive = false
    for i = #pendingQueue, 1, -1 do
        pendingQueue[i] = nil
    end
    lastPushTime = 0
    if #activeToasts == 0 then return end
    for i = #activeToasts, 1, -1 do
        ReleaseToast(activeToasts[i], true)
    end
    if LayoutToasts then LayoutToasts() end
end

LayoutToasts = function()
    if not container then return end
    local db = mod:GetDB()
    local w = db.width or 204
    local h = TOAST_H
    local gap = 4
    local growUp = db.growUp == true
    local maxVis = db.maxVisible or 5
    container:SetSize(w, maxVis * (h + gap))

    local hasPreview = false
    for _, t in ipairs(activeToasts) do
        if t._isPreview then hasPreview = true; break end
    end
    local strata = hasPreview and "FULLSCREEN_DIALOG" or "MEDIUM"
    local baseLvl = hasPreview and 230 or 10
    container:SetFrameStrata(strata)
    container:SetFrameLevel(baseLvl)

    local now = GetTime()
    local pt = growUp and "BOTTOMLEFT" or "TOPLEFT"
    for i, t in ipairs(activeToasts) do
        local yOff = (i - 1) * (h + gap)
        local newY = growUp and yOff or -yOff
        -- 已经在右侧淡出退场中的卡片保持原位平稳消失，不因前方卡片退场而突兀跳格
        local isFading = t._slotPt ~= nil and t._fadeStartAt ~= nil and now >= t._fadeStartAt
        if not isFading then
            local geomChanged = (t._slotPt ~= pt) or (t._slotY ~= newY) or (t._slotW ~= w)
            t._slotPt = pt
            t._slotY = newY
            t._slotW = w
            if geomChanged then
                t:SetSize(w, h)
                if t._headGlow then t._headGlow:SetWidth(math_max(96, math_floor(w * 0.64))) end
                t:ClearAllPoints()
                t:SetPoint(pt, container, pt, 0, newY)
            end
        end
    end
end

local function PaintToastVisual(t, r, g, b, useClassGrad)
    t._lastColor = { r = r, g = g, b = b, cls = useClassGrad == true }
    local ST = F.StyleTokens
    local r1, g1, b1 = r, g, b
    local r2, g2, b2 = math_min(1, r * 0.55 + 0.45), math_min(1, g * 0.55 + 0.45), math_min(1, b * 0.55 + 0.45)
    if useClassGrad and ST and ST.GetClassGradient then
        r1, g1, b1, r2, g2, b2 = ST.GetClassGradient(nil, "bright")
    end

    -- 1) PrettyTooltip 深邃黑曜石底色，从左（0.88）平滑向右尾部淡化至透明（0.00）
    local bgR = 0.028 + r1 * 0.032
    local bgG = 0.025 + g1 * 0.032
    local bgB = 0.036 + b1 * 0.036
    ApplyHorizGrad(t._bg, bgR, bgG, bgB, 0.88, bgR * 0.7, bgG * 0.7, bgB * 0.7, 0.00)

    -- 2) 左侧品质微光晕（仿 PrettyTooltip 顶光渐变，柔和向右消散）
    ApplyHorizGrad(t._headGlow, r1 * 0.34, g1 * 0.34, b1 * 0.34, 0.32, r2 * 0.16, g2 * 0.16, b2 * 0.16, 0.00)

    -- 3) 左侧 2px 品质竖条（上下微渐变）
    if ST and ST.ApplyGradient then
        ST.ApplyGradient(t._leftBar, "VERTICAL", r1, g1, b1, 0.90, r2, g2, b2, 0.98)
    else
        t._leftBar:SetColorTexture(r1, g1, b1, 0.92)
    end

    -- 4) 上下 1px 渐隐细线（左侧呼应 PrettyTooltip 品质亮边，向右平滑淡出至 0）
    ApplyHorizGrad(t._topLine, r2 * 0.78, g2 * 0.78, b2 * 0.78, 0.58, r1 * 0.40, g1 * 0.40, b1 * 0.40, 0.00)
    ApplyHorizGrad(t._botLine, r1 * 0.42, g1 * 0.42, b1 * 0.42, 0.24, r1 * 0.20, g1 * 0.20, b1 * 0.20, 0.00)

    if t._iconBg then
        t._iconBg:SetColorTexture(
            math_min(1, r1 * 0.56 + 0.08),
            math_min(1, g1 * 0.56 + 0.08),
            math_min(1, b1 * 0.56 + 0.08), 0.84)
    end
end

ArmToastFade = function(t, delayOverride)
    if not (t and t:IsShown()) then return end
    if t._animIn and t._animIn:IsPlaying() then return end
    t._animOut:Stop()
    t:SetAlpha(1)
    if t._hovered or (t.IsMouseOver and t:IsMouseOver()) then
        t._fadeStartAt = nil
        return
    end
    local hold = delayOverride or (mod:GetDB().holdSeconds or 3.2)
    t._outSlide:SetStartDelay(hold)
    t._outFade:SetStartDelay(hold)
    t._fadeStartAt = GetTime() + hold
    t._animOut:Play()
end

local function IsEUILootFeedEnabled()
    local EUI = _G.EllesmereUI
    if not (EUI and EUI._LootFeed) then return false end
    local euiDB = _G.EllesmereUIDB
    return type(euiDB) == "table" and type(euiDB.lootFeed) == "table" and euiDB.lootFeed.enabled == true
end

local function ApplyEUILootFeedLive()
    local EUI = _G.EllesmereUI
    if EUI and EUI._LootFeed and EUI._LootFeed.Apply then
        pcall(EUI._LootFeed.Apply)
    end
end

local function SyncEUILootFeedPolicy()
    local db = mod:GetDB()
    local euiDB = _G.EllesmereUIDB
    local hasEUI = type(euiDB) == "table" and type(euiDB.lootFeed) == "table"
    if not hasEUI then return end
    local mode = db.euiConflictMode or "takeover"
    if mod._active and mode == "takeover" then
        if euiDB.lootFeed.enabled == true then
            if db.savedEUILootFeed == nil then
                db.savedEUILootFeed = true
            end
            euiDB.lootFeed.enabled = false
            ApplyEUILootFeedLive()
        end
    elseif db.savedEUILootFeed ~= nil then
        euiDB.lootFeed.enabled = db.savedEUILootFeed == true
        db.savedEUILootFeed = nil
        ApplyEUILootFeedLive()
    end
end

local function ShouldYieldToEUILootFeed()
    local mode = mod:GetDB().euiConflictMode or "takeover"
    return mode == "auto_yield" and IsEUILootFeedEnabled()
end

local LINK_HEX_QUALITY = {
    ["9d9d9d"] = 0,
    ["ffffff"] = 1,
    ["1eff00"] = 2,
    ["0070dd"] = 3,
    ["a335ee"] = 4,
    ["ff8000"] = 5,
    ["e6cc80"] = 6,
    ["00ccff"] = 7,
}

local function FormatItemCount(n) return n > 1 and ("x" .. n) or "x1" end
local function FormatMoneyRight(c) return "+" .. F.FormatMoney(c) end
local function FormatXPRight(n) return "+" .. F.FormatShortNumber(n) .. " XP" end
local function FormatRepRight(n) return "+" .. n .. " 声望" end

local function PushToastNow(spec)
    if not (mod._active or spec.isPreview) then return end
    if not spec.isPreview and ShouldYieldToEUILootFeed() then return end
    EnsureContainer()
    if container and not container:IsShown() then container:Show() end
    local db = mod:GetDB()
    local maxVis = db.maxVisible or 5

    -- 同类未进入淡出阶段的卡片直接原地合并累加，避免刷屏（不打断入场滑入动画）
    if spec.key then
        local now = GetTime()
        for _, existing in ipairs(activeToasts) do
            local isFading = existing._fadeStartAt and now >= existing._fadeStartAt
            if existing._key == spec.key and not isFading then
                existing._amount = (existing._amount or 0) + (spec.amount or 1)
                if spec.formatRight then
                    existing._right:SetText(spec.formatRight(existing._amount))
                end
                if not spec.isPreview and F.Motion and F.Motion.PlayScalePop then
                    F.Motion.PlayScalePop(existing._iconWrap or existing._icon, 1.18, 0.18)
                end
                ArmToastFade(existing)
                return
            end
        end
    end

    -- 超出上限时淘汰最旧的一条（批量移除避免 O(N^2) 布局）
    while #activeToasts >= maxVis do
        ReleaseToast(activeToasts[1], true)
    end

    -- 先把容器层级与尺寸同步到位，再创建/布局卡片，确保首卡与后续卡片诞生于完全相同的容器层级与尺寸
    if spec.isPreview then
        container:SetSize(db.width or 204, maxVis * (TOAST_H + 4))
        container:SetFrameStrata("FULLSCREEN_DIALOG")
        container:SetFrameLevel(230)
    end

    local t = AcquireToast()
    t._key = spec.key
    t._link = spec.link
    t._isPreview = spec.isPreview == true
    t._amount = spec.amount or 1

    activeToasts[#activeToasts + 1] = t
    LayoutToasts()

    t._icon:SetTexture(spec.icon or 134400)
    t._icon:Show()
    t._iconBg:Show()
    -- 锚定定宽后再写右侧与左侧文字，确保首次冷创建时字体串立即获得准确矩形
    t._right:SetText(spec.formatRight and spec.formatRight(t._amount) or (spec.rightText or ""))
    t._right:SetTextColor(spec.rr or 0.92, spec.rg or 0.94, spec.rb or 0.96, 1)
    t._right:Show()
    t._name:SetText(spec.title or "")
    t._name:SetTextColor(spec.tr or 0.95, spec.tg or 0.95, spec.tb or 0.97, 1)
    t._name:Show()
    local cr, cg, cb = spec.r or 0.65, spec.g or 0.68, spec.b or 0.74
    PaintToastVisual(t, cr, cg, cb, spec.useClassGrad)

    t._animOut:Stop()
    t._animIn:Stop()
    t._fadeStartAt = nil
    t:SetAlpha(0)
    t:Show()
    t._animIn:Play()
end

local DrainQueue
DrainQueue = function(gen)
    if gen ~= nil and gen ~= queueGen then return end
    queueTimerActive = false
    local nextSpec = table_remove(pendingQueue, 1)
    if not nextSpec then return end
    lastPushTime = GetTime()
    PushToastNow(nextSpec)
    if #pendingQueue > 0 and C_Timer and C_Timer.After then
        queueTimerActive = true
        local myGen = queueGen
        C_Timer.After(STAGGER_STEP, function() DrainQueue(myGen) end)
    end
end

local function PushToast(spec)
    if not (mod._active or spec.isPreview) then return end
    if not spec.isPreview and ShouldYieldToEUILootFeed() then return end

    -- 同类卡片直接原地合并（涵盖已显示的卡片与排队中的待播条目）
    if spec.key then
        local now = GetTime()
        for _, existing in ipairs(activeToasts) do
            local isFading = existing._fadeStartAt and now >= existing._fadeStartAt
            if existing._key == spec.key and not isFading then
                PushToastNow(spec)
                return
            end
        end
        for _, queued in ipairs(pendingQueue) do
            if queued.key == spec.key then
                queued.amount = (queued.amount or 0) + (spec.amount or 1)
                return
            end
        end
    end

    -- 单次掉落立即滑入；同一帧连发多条（极速拾取 / 预览）按 0.11s 错峰依次滑入与依次滑出
    local now = GetTime()
    local elapsed = now - lastPushTime
    if #pendingQueue == 0 and elapsed >= STAGGER_STEP then
        lastPushTime = now
        PushToastNow(spec)
        return
    end
    pendingQueue[#pendingQueue + 1] = spec
    if not queueTimerActive and C_Timer and C_Timer.After then
        queueTimerActive = true
        local myGen = queueGen
        local delay = math_max(0.02, STAGGER_STEP - math_max(0, elapsed))
        C_Timer.After(delay, function() DrainQueue(myGen) end)
    elseif not (C_Timer and C_Timer.After) then
        DrainQueue(queueGen)
    end
end

function mod:OnChatLoot(_, text)
    if ShouldYieldToEUILootFeed() then return end
    local db = self:GetDB()
    if db.showItems == false then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" or not IsSelfLootMessage(msg) then return end

    local link = msg:match("(|c%x%x%x%x%x%x%x%x|Hitem:[^|]+|h%[[^%]]+%]|h|r)")
        or msg:match("(|Hitem:[^|]+|h%[[^%]]+%]|h)")
    if not link then return end

    local itemID = tonumber(link:match("item:(%d+)"))
    local count = tonumber(msg:match("|h|r%s*x(%d+)")) or tonumber(msg:match("|h%s*x(%d+)")) or 1
    local getInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    local name, _, quality, _, _, itemType, _, _, _, icon
    if getInfo then
        name, _, quality, _, _, itemType, _, _, _, icon = getInfo(link)
    end
    local classID
    if itemID and _G.C_Item and _G.C_Item.GetItemInfoInstant then
        local _, _, _, _, instIcon, instClassID = _G.C_Item.GetItemInfoInstant(itemID)
        if not icon then icon = instIcon end
        classID = F.PlainNumber(instClassID, nil)
    end
    if not icon and itemID then
        local getIcon = (_G.C_Item and _G.C_Item.GetItemIconByID) or _G.GetItemIcon
        if getIcon then icon = getIcon(itemID) end
    end
    name = F.PlainString(name, nil) or link:match("%[([^%]]+)%]") or "物品"
    quality = F.PlainNumber(quality, nil)
    if quality == nil and itemID and _G.C_Item and _G.C_Item.GetItemQualityByID then
        quality = F.PlainNumber(_G.C_Item.GetItemQualityByID(itemID), nil)
    end
    if quality == nil then
        local hex = link:match("^|c%x%x(%x%x%x%x%x%x)")
        quality = (hex and LINK_HEX_QUALITY[hex:lower()]) or 1
    end
    itemType = F.PlainString(itemType, "")
    local questClass = _G.Enum and _G.Enum.ItemClass and _G.Enum.ItemClass.Questitem or 12
    local isQuest = (classID == questClass) or (itemType == "任务" or itemType == "Quest")

    if not isQuest and quality < (db.minQuality or 1) then
        return
    end

    local r, g, b = 0.86, 0.88, 0.92
    local getQualColor = (_G.C_Item and _G.C_Item.GetItemQualityColor) or _G.GetItemQualityColor
    if isQuest then
        r, g, b = 0.98, 0.84, 0.34
    elseif getQualColor then
        local qr, qg, qb = getQualColor(quality)
        if qr and qg and qb then r, g, b = qr, qg, qb end
    end

    PushToast({
        key = itemID and ("item:" .. itemID) or ("item:" .. name),
        link = link,
        icon = icon or 134400,
        title = name,
        amount = count,
        quality = quality,
        isQuest = isQuest,
        r = r, g = g, b = b,
        tr = r, tg = g, tb = b,
        rr = 0.96, rg = 0.96, rb = 0.98,
        formatRight = FormatItemCount,
    })
end

function mod:OnChatMoney(_, text)
    if ShouldYieldToEUILootFeed() then return end
    if self:GetDB().showMoney == false then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" then return end
    local copper = ParseMoneyCopper(msg)
    if copper <= 0 then return end

    PushToast({
        key = "money",
        icon = ICON_COIN,
        title = "拾取金币",
        amount = copper,
        r = 0.96, g = 0.80, b = 0.30,
        tr = 0.96, tg = 0.88, tb = 0.64,
        rr = 1, rg = 1, rb = 1,
        formatRight = FormatMoneyRight,
    })
end

function mod:OnChatXP(_, text)
    if ShouldYieldToEUILootFeed() then return end
    if self:GetDB().showXP == false then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" then return end
    local xp = ParseXPGain(msg)
    if not xp or xp <= 0 then return end

    PushToast({
        key = "xp",
        icon = ICON_XP,
        title = "经验值",
        amount = xp,
        r = 0.74, g = 0.56, b = 0.96,
        tr = 0.86, tg = 0.78, tb = 0.98,
        rr = 0.86, rg = 0.74, rb = 1.00,
        formatRight = FormatXPRight,
    })
end

function mod:OnChatRep(_, text)
    if ShouldYieldToEUILootFeed() then return end
    if self:GetDB().showRep == false then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" then return end
    local fac, amt = ParseRepGain(msg)
    if not (fac and amt and amt > 0) then return end

    PushToast({
        key = "rep:" .. fac,
        icon = ICON_REP,
        title = fac,
        amount = amt,
        r = 0.34, g = 0.84, b = 0.62,
        tr = 0.74, tg = 0.96, tb = 0.84,
        rr = 0.42, rg = 0.92, rb = 0.68,
        formatRight = FormatRepRight,
    })
end

function mod:ShowPreview()
    EnsureContainer()
    local db = self:GetDB()
    container:SetSize(db.width or 204, (db.maxVisible or 5) * (TOAST_H + 4))
    container:SetFrameStrata("FULLSCREEN_DIALOG")
    container:SetFrameLevel(230)
    queueGen = queueGen + 1
    queueTimerActive = false
    for i = #pendingQueue, 1, -1 do
        if pendingQueue[i].isPreview then
            table_remove(pendingQueue, i)
        end
    end
    for i = #activeToasts, 1, -1 do
        if activeToasts[i]._isPreview then
            ReleaseToast(activeToasts[i], true)
        end
    end
    lastPushTime = 0
    PushToast({
        isPreview = true,
        key = "preview_epic",
        icon = 135489,
        title = "史诗猎人长弓",
        amount = 1,
        quality = 4,
        r = 0.64, g = 0.21, b = 0.93,
        tr = 0.78, tg = 0.44, tb = 0.98,
        formatRight = FormatItemCount,
    })
    PushToast({
        isPreview = true,
        key = "preview_item",
        icon = 132834,
        title = "异种蝎卵（任务）",
        amount = 1,
        isQuest = true,
        r = 0.98, g = 0.84, b = 0.34,
        tr = 0.98, tg = 0.84, tb = 0.34,
        formatRight = FormatItemCount,
    })
    PushToast({
        isPreview = true,
        key = "preview_money",
        icon = ICON_COIN,
        title = "拾取金币",
        amount = 1485,
        r = 0.96, g = 0.80, b = 0.30,
        tr = 0.96, tg = 0.88, tb = 0.64,
        formatRight = FormatMoneyRight,
    })
    PushToast({
        isPreview = true,
        key = "preview_xp",
        icon = ICON_XP,
        title = "经验值",
        amount = 340,
        r = 0.74, g = 0.56, b = 0.96,
        tr = 0.86, tg = 0.78, tb = 0.98,
        formatRight = FormatXPRight,
    })
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2TakeoverMigrated then
        db.v2TakeoverMigrated = true
        if db.euiConflictMode == nil or db.euiConflictMode == "auto_yield" then
            db.euiConflictMode = "takeover"
        end
    end
    if not db.v3PrettyFadeMigrated then
        db.v3PrettyFadeMigrated = true
        if db.width == nil or db.width == 236 or db.width == 248 then
            db.width = 204
        end
    end
    if not db.v4GrowDownMigrated then
        db.v4GrowDownMigrated = true
        db.growUp = false
    end
    EnsureContainer()
    if container then container:Show() end
    SyncEUILootFeedPolicy()
    self:RegisterEvent("CHAT_MSG_LOOT", self.OnChatLoot)
    self:RegisterEvent("CHAT_MSG_MONEY", self.OnChatMoney)
    self:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN", self.OnChatXP)
    self:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE", self.OnChatRep)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        ClearAllToasts()
        SyncEUILootFeedPolicy()
    end)
end

function mod:OnDisable()
    ClearAllToasts()
    SyncEUILootFeedPolicy()
    if container then container:Hide() end
end

function mod:OnThemeChanged()
    local function restyle(list)
        for _, t in ipairs(list) do
            if t._lastColor then
                PaintToastVisual(t, t._lastColor.r, t._lastColor.g, t._lastColor.b, t._lastColor.cls)
            end
            F.Theme.ApplyFont(t._name, 12, "OUTLINE")
            F.Theme.ApplyFont(t._right, 11, "OUTLINE")
        end
    end
    restyle(activeToasts)
    restyle(spareToasts)
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "重复播报策略",
        tooltip = "默认由本插件流光卡片接管拾取播报，也可切换让位给 EUI。",
        values = {
            takeover   = "本插件流光卡片接管（推荐）",
            auto_yield = "自动让位给 EUI 拾取播报",
            both       = "两者同时显示",
        },
        order = { "takeover", "auto_yield", "both" },
        getValue = function() return db.euiConflictMode or "takeover" end,
        setValue = function(v)
            db.euiConflictMode = v
            ClearAllToasts()
            SyncEUILootFeedPolicy()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "物品最低播报品质",
        tooltip = "任务物品不受品质过滤限制，始终会播报提醒。",
        values = { [0] = "全部物品（含灰装）", [1] = "白色普通起（推荐）", [2] = "绿色优秀起" },
        order = { 0, 1, 2 },
        getValue = function() return db.minQuality or 1 end,
        setValue = function(v) db.minQuality = v end,
    }, blank)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "播报拾取物品",
        getValue = function() return db.showItems ~= false end,
        setValue = function(v) db.showItems = v == true end,
    }, {
        type = "toggle",
        text = "播报拾取金币",
        getValue = function() return db.showMoney ~= false end,
        setValue = function(v) db.showMoney = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "播报经验收益",
        getValue = function() return db.showXP ~= false end,
        setValue = function(v) db.showXP = v == true end,
    }, {
        type = "toggle",
        text = "播报声望提升",
        getValue = function() return db.showRep ~= false end,
        setValue = function(v) db.showRep = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "停留秒数",
        min = 1.5, max = 6.0, step = 0.5,
        getValue = function() return db.holdSeconds or 3.2 end,
        setValue = function(v) db.holdSeconds = v end,
    }, {
        type = "toggle",
        text = "向下堆叠",
        tooltip = "新拾取从上方往下依次展开，关闭则改为向上堆叠。",
        getValue = function() return db.growUp ~= true end,
        setValue = function(v) db.growUp = not (v == true); LayoutToasts() end,
    })
    y = y - h

    _, h = W:WideButton(parent, "预览拾取与收益微播报", y, function() self:ShowPreview() end)
    y = y - h
    return y
end
