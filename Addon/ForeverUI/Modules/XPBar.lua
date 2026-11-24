----------------------------------------------------------------------
--  ForeverUI — Modules/XPBar.lua
--  现代扁平风经验条 + 左侧高清职业纹章（等级 & 装等）+ 声望条
--    • 100% 纯扁平实色填充（WHITE8x8 + 1px 锐利黑框，去渐变/去高光/去糊边光晕）
--    • 默认经典幻紫配暖橙任务段（内置 5 套纯扁平主题配色，可随时切换）
--    • 左侧高清职业图标（优先复用 EllesmereUI 128×128 锐利职业图集 / 暴雪高清纹章）
--      图标下方醒目大号等级数字 + 青蓝装等铭牌（实时随换装刷新）
--    • 净空防重叠双栏排版：关闭条下统计时自动切换极简双词模式（左百分比 / 右预计时间）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local math_floor, math_min, math_max = math.floor, math.min, math.max
local string_format = string.format
local table_concat = table.concat
local ipairs, pcall, tostring, type, GetTime = ipairs, pcall, tostring, type, GetTime
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = _G.GameTooltip

-- 5 套现代纯扁平配色（主进度实色 + 可交任务实色 + 双倍实色 + AION2 清透青蓝装等高亮）
local ILVL_AION_HEX = "55e2e4"
local ILVL_AION_RGB = { 0.33, 0.89, 0.89 }

local THEME_PRESETS = {
    violet = {
        label    = "经典幻紫（默认扁平风）",
        fill     = { 0.64, 0.31, 0.96 }, -- #A34FF5 纯净现代紫
        quest    = { 0.93, 0.54, 0.21 }, -- #ED8A36 暖橙任务段
        rested   = { 0.22, 0.74, 0.97 }, -- #38BDF8 清透双倍蓝
        questHex = "f59e42",
        ilvlHex  = ILVL_AION_HEX,
    },
    class = {
        label = "职业纯色（动态职业扁平）",
    },
    emerald = {
        label    = "翡翠纯绿（猎人/自然）",
        fill     = { 0.16, 0.78, 0.48 }, -- #29C77A 清爽翡翠绿
        quest    = { 0.93, 0.54, 0.21 }, -- #ED8A36 暖橙任务段
        rested   = { 0.22, 0.74, 0.97 },
        questHex = "f59e42",
        ilvlHex  = ILVL_AION_HEX,
    },
    cobalt = {
        label    = "清透钴蓝（简洁冷调）",
        fill     = { 0.24, 0.55, 0.96 }, -- #3D8CF5 明快钴蓝
        quest    = { 0.93, 0.54, 0.21 }, -- #ED8A36 暖橙任务段
        rested   = { 0.32, 0.80, 0.98 },
        questHex = "f59e42",
        ilvlHex  = ILVL_AION_HEX,
    },
    gold = {
        label    = "暖香槟金（ForeverUI 同系）",
        fill     = { 0.86, 0.65, 0.50 }, -- #DCA77F 暖香槟金
        quest    = { 0.20, 0.82, 0.60 }, -- #33D199 翡翠任务段（与金强区分）
        rested   = { 0.28, 0.70, 0.95 },
        questHex = "45d9a4",
        ilvlHex  = ILVL_AION_HEX,
    },
}

local THEME_ALIASES = {
    aion      = "violet",
    astral    = "violet",
    aurora    = "cobalt",
    champagne = "gold",
    solar     = "gold",
}

local THEME_ORDER = { "violet", "class", "emerald", "cobalt", "gold" }
local THEME_VALUES = {}
for _, key in ipairs(THEME_ORDER) do
    THEME_VALUES[key] = THEME_PRESETS[key].label
end

local ICON_STYLE_ORDER = { "glyph", "modern", "midnight", "runic", "blizzard" }
local ICON_STYLE_VALUES = {
    glyph    = "简约徽印（默认·无底半透明）",
    modern   = "现代高清",
    midnight = "暗夜纹章",
    runic    = "符文纹章",
    blizzard = "暴雪原生高清",
}

local EQUIP_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }

local mod = F.RegisterModule("xpBar", {
    title = "经验与声望条",
    desc = "一体化现代纯扁平经验条，左侧无缝融合半透明简约职业徽印、等级与角色面板同款装等，支持统一悬停提示、可交任务预览与双倍经验。",
    group = "quest",
    order = 40,
    defaults = {
        enabled = true,
        width = 430,
        height = 10,
        fontSize = 11,
        colorTheme = "violet",
        iconStyle = "glyph",
        showEmblem = true,
        showTicks = false,
        showGlow = true,
        showQuestXP = true,
        showRested = true,
        showTopTimers = false,
        showBottomStats = true,
        useClassColor = false,
        hideAtMaxLevel = true,
        showRepBar = false,
        combatFade = false,
        v3LuminousXP = false,
        v4RefinedXP = false,
        v5FlatEmblemXP = false,
        v6IntegratedXP = false,
    },
})

local xpFrame, xpHitBox, xpBar, restedBar, questBar
local xpPulse, xpPulseAG
local emblemFrame, emblemIconTex, emblemLevelFS, emblemIlvlFS
local xpTexts = {}
local repFrame, repBar, repLeft, repRight
local activeQuestHex = "f59e42"
local activeQuestCol = { 0.93, 0.54, 0.21 }
local activeIlvlHex = ILVL_AION_HEX
local isUnitHovered = false
local updateXPFade = nil
local liveTicker = nil
local cachedQuestXP = 0
local questXPDirty = true
local lastRenderedXP = nil
local lastRenderedLevel = nil

local function Clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function FormatComma(n)
    n = math_floor(F.PlainNumber(n, 0) + 0.5)
    if _G.BreakUpLargeNumbers then
        local ok, s = pcall(_G.BreakUpLargeNumbers, n)
        if ok and type(s) == "string" then return s end
    end
    local s = tostring(n)
    while true do
        local changed
        s, changed = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if changed == 0 then break end
    end
    return s
end

local function FormatDuration(seconds)
    seconds = F.PlainNumber(seconds, 0)
    if seconds <= 0 then return "--" end
    if seconds < 60 then return "< 1分" end
    local mins = math_floor(seconds / 60)
    local hours = math_floor(mins / 60)
    local days = math_floor(hours / 24)
    if days > 0 then
        return string_format("%d天%d时", days, hours % 24)
    elseif hours > 0 then
        return string_format("%d时%d分", hours, mins % 60)
    end
    return string_format("%d分", mins)
end

local function GetPlayerItemLevel()
    if _G.GetAverageItemLevel then
        local ok, overall, equipped = pcall(_G.GetAverageItemLevel)
        local eq = ok and F.PlainNumber(equipped, 0) or 0
        local ov = ok and F.PlainNumber(overall, 0) or 0
        if eq > 0 then
            return eq, ov > 0 and ov or eq
        elseif ov > 0 then
            return ov, ov
        end
    end
    -- 兜底：逐格统计已穿戴装备装等（排除衬衣 4 / 战袍 19）
    local total, count = 0, 0
    local CItem = _G.C_Item
    local ItemLoc = _G.ItemLocation
    for _, slot in ipairs(EQUIP_SLOTS) do
        local ilvl = 0
        if ItemLoc and CItem and CItem.DoesItemExist and CItem.GetCurrentItemLevel then
            local ok, loc = pcall(ItemLoc.CreateFromEquipmentSlot, ItemLoc, slot)
            if ok and loc and loc:IsValid() and CItem.DoesItemExist(loc) then
                ilvl = F.PlainNumber(CItem.GetCurrentItemLevel(loc), 0)
            end
        end
        if ilvl <= 0 and _G.GetInventoryItemLink then
            local link = _G.GetInventoryItemLink("player", slot)
            if link and CItem and CItem.GetDetailedItemLevelInfo then
                ilvl = F.PlainNumber(CItem.GetDetailedItemLevelInfo(link), 0)
            end
        end
        if ilvl > 0 then
            total = total + ilvl
            count = count + 1
        end
    end
    if count > 0 then
        local avg = total / count
        return avg, avg
    end
    return 0, 0
end

local function GetCompletedQuestXP(force)
    if not force and not questXPDirty then
        return cachedQuestXP
    end
    questXPDirty = false
    local QL = _G.C_QuestLog
    if not (QL and QL.GetNumQuestLogEntries and QL.GetInfo and QL.IsComplete and _G.GetQuestLogRewardXP) then
        cachedQuestXP = 0
        return 0
    end
    local total = 0
    for i = 1, QL.GetNumQuestLogEntries() do
        local info = QL.GetInfo(i)
        if info and info.questID and not info.isHeader and QL.IsComplete(info.questID) then
            local ok, val = pcall(_G.GetQuestLogRewardXP, info.questID)
            if ok and type(val) == "number" and val > 0 then
                total = total + val
            end
        end
    end
    cachedQuestXP = total
    return total
end

local function ResolveThemeColors(themeKey)
    local resolvedKey = THEME_ALIASES[themeKey] or themeKey
    local preset = THEME_PRESETS[resolvedKey]
    if preset and preset.fill then
        return preset.fill, preset.quest, preset.rested, preset.questHex, preset.ilvlHex
    end
    -- 职业纯色扁平
    local ar, ag, ab = F.Theme.GetClassColor()
    local fill = { Clamp01(ar), Clamp01(ag), Clamp01(ab) }
    local warmClass = (ar > 0.75 and ag > 0.45 and ab < 0.45)
    local quest = warmClass and { 0.20, 0.82, 0.60 } or { 0.93, 0.54, 0.21 }
    local questHex = warmClass and "45d9a4" or "f59e42"
    local rested = { 0.22, 0.74, 0.97 }
    return fill, quest, rested, questHex, ILVL_AION_HEX
end

local function ApplyFlatBarColor(bar, col, alpha)
    if not bar or not col then return end
    bar:SetStatusBarTexture(F.Theme.FLAT_TEX)
    bar:SetStatusBarColor(col[1], col[2], col[3], alpha or 1)
end

local function ApplyCleanBarFont(fs, size, r, g, b, a, outline)
    if not (fs and fs.SetFont) then return end
    F.Theme.ApplyFont(fs, size, outline or "OUTLINE", r, g, b, a)
    if fs.SetShadowColor then pcall(fs.SetShadowColor, fs, 0, 0, 0, 0.55) end
    if fs.SetShadowOffset then pcall(fs.SetShadowOffset, fs, 0, -1) end
end

local function ApplyClassIcon(tex, style)
    if not tex then return end
    local classToken = F.GetPlayerClass()
    local chosen = style or "glyph"
    local EUI = _G.EllesmereUI
    local coords = EUI and EUI.CLASS_ICON_SPRITE_COORDS and EUI.CLASS_ICON_SPRITE_COORDS[classToken]
    if chosen ~= "blizzard" and coords then
        tex:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\icons\\class-full\\" .. chosen .. ".tga")
        -- 略微向内收 0.002 UV，避免非整数 UI 缩放时边缘采样到相邻职业格子导致锯齿/串色
        tex:SetTexCoord(coords[1] + 0.002, coords[2] - 0.002, coords[3] + 0.002, coords[4] - 0.002)
    else
        local atlasName = "classicon-" .. tostring(classToken or "WARRIOR"):lower()
        local hasAtlas = _G.C_Texture and _G.C_Texture.GetAtlasInfo and _G.C_Texture.GetAtlasInfo(atlasName)
        if hasAtlas and tex.SetAtlas then
            tex:SetTexCoord(0, 1, 0, 1)
            tex:SetAtlas(atlasName, false)
        else
            tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
            local blz = _G.CLASS_ICON_TCOORDS and _G.CLASS_ICON_TCOORDS[classToken]
            if blz then
                tex:SetTexCoord(blz[1] + 0.015, blz[2] - 0.015, blz[3] + 0.015, blz[4] - 0.015)
            else
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
        end
    end
    if tex.SetSnapToPixelGrid then pcall(tex.SetSnapToPixelGrid, tex, true) end
    if tex.SetTexelSnappingBias then pcall(tex.SetTexelSnappingBias, tex, 0) end
end

local function UpdateSession(cur, max)
    local s = F.charDB and F.charDB.xpSession
    if not s then
        return 0, 0, 0, 0
    end
    local now = GetTime()
    local level = F.PlainNumber(_G.UnitLevel and _G.UnitLevel("player"), 0)
    if not s.startTime or s.startTime == 0 or s.startTime > now then
        -- GetTime() 是开机时长：startTime 比现在还大说明重启过电脑，旧会话的累计经验必须一起清零，
        -- 否则「昨天的总经验 / 1 秒」会算出上亿每小时
        s.startTime = now
        s.gainedXP = 0
        s.lastXP = cur
        s.maxXP = max
        s.lastLevel = level
        s.levelStartTime = now
    else
        local delta = 0
        local leveled = (s.lastLevel ~= nil and level > s.lastLevel)
        if s.maxXP and s.maxXP > 0 and (leveled or cur < (s.lastXP or 0)) then
            -- 升级：上一级剩余经验 + 本级已得经验（新经验 >= 旧值的升级也要识别，不能只看 cur < lastXP）
            delta = (s.maxXP - (s.lastXP or 0)) + cur
            s.levelStartTime = now
        elseif cur > (s.lastXP or 0) then
            delta = cur - (s.lastXP or 0)
        end
        if delta > 0 then
            s.gainedXP = (s.gainedXP or 0) + delta
        end
        s.lastXP = cur
        s.maxXP = max
        s.lastLevel = level
    end
    if not s.levelStartTime or s.levelStartTime == 0 or s.levelStartTime > now then
        s.levelStartTime = now
    end
    local sessionSec = math_max(1, now - s.startTime)
    local levelSec = math_max(1, now - s.levelStartTime)
    local perHour = (s.gainedXP or 0) / sessionSec * 3600
    return s.gainedXP or 0, perHour, sessionSec, levelSec
end

local function CreateFlatBorder(frame, r, g, b, a)
    local borders = {}
    local specs = {
        { "TOPLEFT",     "TOPRIGHT",    0,  1, nil, 1 },
        { "BOTTOMLEFT",  "BOTTOMRIGHT", 0, -1, nil, 1 },
        { "TOPLEFT",     "BOTTOMLEFT", -1,  0, 1, nil },
        { "TOPRIGHT",    "BOTTOMRIGHT", 1,  0, 1, nil },
    }
    for i, sp in ipairs(specs) do
        local ln = frame:CreateTexture(nil, "BORDER")
        ln:SetPoint(sp[1], frame, sp[1], sp[3], sp[4])
        ln:SetPoint(sp[2], frame, sp[2], sp[3], sp[4])
        if sp[5] then ln:SetWidth(sp[5]) end
        if sp[6] then ln:SetHeight(sp[6]) end
        ln:SetColorTexture(r or 0.02, g or 0.02, b or 0.03, a or 0.98)
        borders[i] = ln
    end
    return borders
end

local function BuildFlatTrack(frame)
    local trackBg = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(0.07, 0.072, 0.10, 0.94)
    frame._trackBg = trackBg
    frame._borders = CreateFlatBorder(frame, 0.02, 0.02, 0.03, 0.98)
end

local function ShowXPTooltip(anchor)
    local owner = xpHitBox or anchor or xpFrame
    if not owner then return end
    local level = _G.UnitLevel("player") or 1
    local eqIlvl, overallIlvl = GetPlayerItemLevel()
    local cur = F.PlainNumber(_G.UnitXP("player"), 0)
    local max = math_max(1, F.PlainNumber(_G.UnitXPMax("player"), 1))
    local rem = math_max(0, max - cur)
    local rested = F.PlainNumber(_G.GetXPExhaustion and _G.GetXPExhaustion(), 0)
    local questXP = GetCompletedQuestXP()
    local gained, perHour, sessionSec, levelSec = UpdateSession(cur, max)

    -- 智能上下避让：经验条位于屏幕上侧时提示框朝下展开，彻底杜绝遮挡图标/等级/经验条
    local _, cy = owner:GetCenter()
    local screenH = (_G.UIParent and _G.UIParent.GetHeight and F.PlainNumber(_G.UIParent:GetHeight(), 768)) or 768
    if cy and cy > screenH * 0.5 then
        GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM", 0, -6)
    else
        GameTooltip:SetOwner(owner, "ANCHOR_TOP", 0, 6)
    end

    GameTooltip:AddLine("经验与角色概览", 1, 1, 1)
    if eqIlvl > 0 then
        local ilvlStr = (overallIlvl - eqIlvl >= 0.05)
            and string_format("%.2f（背包 %.2f）", eqIlvl, overallIlvl)
            or string_format("%.2f", eqIlvl)
        GameTooltip:AddDoubleLine("等级 / 装等", string_format("%d 级 · %s", level, ilvlStr), 0.78, 0.80, 0.86, ILVL_AION_RGB[1], ILVL_AION_RGB[2], ILVL_AION_RGB[3])
    else
        GameTooltip:AddDoubleLine("当前等级", string_format("%d 级", level), 0.78, 0.80, 0.86, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("当前 / 上限", string_format("%s / %s (%.1f%%)", FormatComma(cur), FormatComma(max), cur / max * 100), 0.78, 0.80, 0.86, 1, 1, 1)
    GameTooltip:AddDoubleLine("升级还需", FormatComma(rem), 0.78, 0.80, 0.86, 1, 0.85, 0.42)
    if questXP > 0 then
        local afterPct = math_min(100, (cur + questXP) / max * 100)
        GameTooltip:AddDoubleLine("可交任务经验", string_format("+%s (+%.1f%% -> %.1f%%)", FormatComma(questXP), questXP / max * 100, afterPct), 0.95, 0.62, 0.26, 1.00, 0.76, 0.36)
    end
    if rested > 0 then
        GameTooltip:AddDoubleLine("双倍经验储备", string_format("%s (%.0f%%)", FormatComma(rested), rested / max * 100), 0.28, 0.76, 0.98, 0.45, 0.86, 1.00)
    end
    GameTooltip:AddDoubleLine("本次获得 / 速率", string_format("%s (%s/时)", FormatComma(gained), F.FormatShortNumber(perHour)), 0.78, 0.80, 0.86, 0.37, 0.88, 0.68)
    GameTooltip:AddDoubleLine("本级耗时 / 本次在线", string_format("%s / %s", FormatDuration(levelSec), FormatDuration(sessionSec)), 0.78, 0.80, 0.86, 0.86, 0.88, 0.94)
    GameTooltip:AddLine("Shift + 左键拖动可微调位置", 0.55, 0.58, 0.64)
    GameTooltip:Show()
end

local function SyncUnifiedHoverVisual()
    if emblemIconTex then
        emblemIconTex:SetAlpha(isUnitHovered and 1.00 or 0.82)
    end
end

local function ApplyVisuals()
    local db = mod:GetDB()
    local w = db.width or 430
    local h = db.height or 10
    local fsSize = db.fontSize or 11
    local pctSize = math_max(12, fsSize + 2)
    local lvSize = math_max(16, fsSize + 6)
    local subSize = math_max(10, fsSize - 1)
    local showEmblem = db.showEmblem ~= false
    local showTicks = db.showTicks == true

    local themeKey = db.colorTheme or (db.useClassColor and "class" or "violet")
    local fillCol, questCol, restedCol, questHex, ilvlHex = ResolveThemeColors(themeKey)
    activeQuestHex = questHex
    activeQuestCol = questCol
    activeIlvlHex = ilvlHex

    if xpFrame then
        xpFrame:SetSize(w, h)
        if xpFrame._trackBg then
            xpFrame._trackBg:SetColorTexture(0.07, 0.072, 0.10, 0.94)
        end

        -- 纯扁平实色三层填充：双倍蓝 → 可交任务橙 → 当前经验纯色
        ApplyFlatBarColor(restedBar, restedCol, 0.34)
        ApplyFlatBarColor(questBar,  questCol,  0.96)
        ApplyFlatBarColor(xpBar,     fillCol,   1.00)

        -- 刻度线默认关闭（参照扁平净色风，可在设置中开启）
        if xpFrame._ticks then
            local innerW = math_max(1, w - 2)
            for idx = 1, 9 do
                local tk = xpFrame._ticks[idx]
                if showTicks then
                    tk:ClearAllPoints()
                    tk:SetPoint("TOP", xpBar, "TOPLEFT", innerW * (idx * 0.1), 0)
                    tk:SetPoint("BOTTOM", xpBar, "BOTTOMLEFT", innerW * (idx * 0.1), 0)
                    tk:SetColorTexture(0, 0, 0, idx == 5 and 0.28 or 0.14)
                    tk:Show()
                else
                    tk:Hide()
                end
            end
        end

        if xpPulse then
            xpPulse:SetVertexColor(1, 1, 1, 1)
        end

        local topGap = 5
        local botGap = -5
        local showBottom = db.showBottomStats ~= false
        local emblemGap = 7
        local iconSz = math_max(28, math_min(36, h + pctSize + 9))

        -- 左侧无底无框半透明简约职业徽印 + 右下角等级 + 与条下基线对齐的精准装等
        if emblemFrame then
            if showEmblem then
                local embW = math_max(38, iconSz + 4)
                emblemFrame:SetSize(embW, iconSz + subSize + 10)
                emblemFrame:ClearAllPoints()
                emblemFrame:SetPoint("RIGHT", xpFrame, "LEFT", -emblemGap, 0)
                emblemFrame:Show()

                if emblemIconTex then
                    emblemIconTex:SetSize(iconSz, iconSz)
                    emblemIconTex:ClearAllPoints()
                    -- 图标顶缘与条上百分比平齐、底缘紧贴经验条底，与经验条天然融为一体
                    emblemIconTex:SetPoint("BOTTOM", emblemFrame, "CENTER", 0, -math_floor(h * 0.5))
                    ApplyClassIcon(emblemIconTex, db.iconStyle or "glyph")
                    SyncUnifiedHoverVisual()
                end
                if emblemLevelFS then
                    ApplyCleanBarFont(emblemLevelFS, math_max(14, lvSize - 2), 1.00, 0.99, 0.94, 1, "OUTLINE")
                    emblemLevelFS:ClearAllPoints()
                    emblemLevelFS:SetPoint("BOTTOMRIGHT", emblemIconTex, "BOTTOMRIGHT", 3, -1)
                end
                if emblemIlvlFS then
                    ApplyCleanBarFont(emblemIlvlFS, math_max(10, subSize), ILVL_AION_RGB[1], ILVL_AION_RGB[2], ILVL_AION_RGB[3], 1, "OUTLINE")
                    emblemIlvlFS:ClearAllPoints()
                    -- 与右侧条下统计行严格同基线对齐（无底框、无边框）
                    emblemIlvlFS:SetPoint("TOP", emblemIconTex, "BOTTOM", 0, botGap)
                end
            else
                emblemFrame:Hide()
            end
        end

        -- 统一整体悬停与拖拽热区（覆盖左侧图标/装等 + 间隙 + 右侧经验条与上下文字，绝不割裂或二次闪烁）
        if xpHitBox then
            local leftExt = showEmblem and (math_max(38, iconSz + 4) + emblemGap) or 0
            local topExt = topGap + pctSize + (db.showTopTimers and (subSize + 6) or 3)
            local botExt = (showBottom or showEmblem) and (math_max(subSize, 12) + 8) or 4
            xpHitBox:ClearAllPoints()
            xpHitBox:SetPoint("TOPLEFT", xpFrame, "TOPLEFT", -leftExt, topExt)
            xpHitBox:SetPoint("BOTTOMRIGHT", xpFrame, "BOTTOMRIGHT", 2, -botExt)
        end

        -- 文字净空排版：开启左侧徽标时，条上方仅左（百分比）+ 右（数值/预计），极致清爽零拥挤
        if showEmblem then
            xpTexts.level:Hide()
            xpTexts.percent:ClearAllPoints()
            xpTexts.percent:SetJustifyH("LEFT")
            xpTexts.percent:SetPoint("BOTTOMLEFT", xpFrame, "TOPLEFT", 2, topGap)

            xpTexts.xp:ClearAllPoints()
            xpTexts.xp:SetJustifyH("RIGHT")
            xpTexts.xp:SetPoint("BOTTOMRIGHT", xpFrame, "TOPRIGHT", -2, topGap)
        else
            xpTexts.level:Show()
            xpTexts.level:ClearAllPoints()
            xpTexts.level:SetPoint("BOTTOMLEFT", xpFrame, "TOPLEFT", 2, topGap)

            xpTexts.xp:ClearAllPoints()
            xpTexts.xp:SetJustifyH("CENTER")
            xpTexts.xp:SetPoint("BOTTOM", xpFrame, "TOP", 0, topGap)

            xpTexts.percent:ClearAllPoints()
            xpTexts.percent:SetJustifyH("RIGHT")
            xpTexts.percent:SetPoint("BOTTOMRIGHT", xpFrame, "TOPRIGHT", -2, topGap)
        end

        if xpTexts.questArrow and xpTexts.percentAfter then
            local arrowSz = math_max(10, pctSize - 1)
            xpTexts.questArrow:SetSize(arrowSz, arrowSz)
            xpTexts.questArrow:SetVertexColor(questCol[1], questCol[2], questCol[3], 0.96)
            xpTexts.questArrow:ClearAllPoints()
            xpTexts.percentAfter:ClearAllPoints()
            if showEmblem then
                xpTexts.questArrow:SetPoint("LEFT", xpTexts.percent, "RIGHT", 4, 0)
                xpTexts.percentAfter:SetJustifyH("LEFT")
                xpTexts.percentAfter:SetPoint("LEFT", xpTexts.questArrow, "RIGHT", 4, 0)
            else
                -- 无徽标模式下百分比在右侧，隐藏独立箭头并在单字内展示避免越界
                xpTexts.questArrow:Hide()
                xpTexts.percentAfter:Hide()
            end
            ApplyCleanBarFont(xpTexts.percentAfter, pctSize, questCol[1], questCol[2], questCol[3], 1)
        end

        local timerY = topGap + pctSize + 4
        xpTexts.levelTime:ClearAllPoints()
        xpTexts.levelTime:SetPoint("BOTTOMLEFT", xpFrame, "TOPLEFT", 2, timerY)
        xpTexts.sessionTime:ClearAllPoints()
        xpTexts.sessionTime:SetPoint("BOTTOMRIGHT", xpFrame, "TOPRIGHT", -2, timerY)

        xpTexts.rate:ClearAllPoints()
        xpTexts.rate:SetPoint("TOPLEFT", xpFrame, "BOTTOMLEFT", 2, botGap)
        xpTexts.completedRested:ClearAllPoints()
        xpTexts.completedRested:SetPoint("TOPRIGHT", xpFrame, "BOTTOMRIGHT", -2, botGap)

        ApplyCleanBarFont(xpTexts.level, math_max(13, fsSize + 2), 0.98, 0.98, 1.00, 1)
        ApplyCleanBarFont(xpTexts.percent, pctSize, 0.98, 0.99, 1.00, 1)
        ApplyCleanBarFont(xpTexts.xp, fsSize, 0.92, 0.94, 0.98, 1)
        ApplyCleanBarFont(xpTexts.levelTime, subSize, 0.72, 0.78, 0.86, 0.90)
        ApplyCleanBarFont(xpTexts.sessionTime, subSize, 0.72, 0.78, 0.86, 0.90)
        ApplyCleanBarFont(xpTexts.rate, subSize, 0.84, 0.88, 0.94, 0.95)
        ApplyCleanBarFont(xpTexts.completedRested, subSize, 0.84, 0.88, 0.94, 0.95)
    end

    if repFrame then
        local repH = math_max(8, h)
        repFrame:SetSize(w, repH)
        repLeft:ClearAllPoints()
        repLeft:SetPoint("BOTTOMLEFT", repFrame, "TOPLEFT", 2, 5)
        repRight:ClearAllPoints()
        repRight:SetPoint("BOTTOMRIGHT", repFrame, "TOPRIGHT", -2, 5)
        ApplyCleanBarFont(repLeft, fsSize, 0.96, 0.97, 1.00, 1)
        ApplyCleanBarFont(repRight, fsSize, 0.90, 0.93, 0.98, 1)
    end
end

local function PlayGainPulse()
    if not (xpPulseAG and xpPulse) then return end
    local db = mod:GetDB()
    if db.showGlow == false then return end
    if xpPulseAG:IsPlaying() then
        xpPulseAG:Stop()
    end
    xpPulse:Show()
    xpPulseAG:Play()
end

local function UpdateEmblemStats()
    if not (mod._active and emblemFrame and emblemFrame:IsShown()) then return end
    local level = _G.UnitLevel("player") or 1
    if emblemLevelFS then
        emblemLevelFS:SetText(tostring(level))
    end
    if emblemIlvlFS then
        local eqIlvl = GetPlayerItemLevel()
        if eqIlvl and eqIlvl > 0 then
            emblemIlvlFS:SetText(string_format("|cff%s%.2f|r", activeIlvlHex, eqIlvl))
        else
            emblemIlvlFS:SetText("|cff8892a4--|r")
        end
    end
end

local function UpdateXP()
    -- 防抖/延时回调可能在停用之后才触发：停用后绝不再把经验条显示出来
    if not (xpFrame and mod._active) then
        return
    end
    local db = mod:GetDB()
    local level = _G.UnitLevel("player") or 1
    local maxLevel = (_G.GetMaxLevelForPlayerExpansion and _G.GetMaxLevelForPlayerExpansion())
        or _G.MAX_PLAYER_LEVEL or 60
    if db.hideAtMaxLevel and level >= maxLevel then
        xpFrame:Hide()
        return
    end

    local cur = F.PlainNumber(_G.UnitXP("player"), 0)
    local max = math_max(1, F.PlainNumber(_G.UnitXPMax("player"), 1))
    local rem = math_max(0, max - cur)
    local rested = F.PlainNumber(_G.GetXPExhaustion and _G.GetXPExhaustion(), 0)
    local questXP = db.showQuestXP and GetCompletedQuestXP() or 0
    local _, perHour, sessionSec, levelSec = UpdateSession(cur, max)

    if lastRenderedXP ~= nil and lastRenderedLevel ~= nil then
        if level > lastRenderedLevel or (level == lastRenderedLevel and cur > lastRenderedXP) then
            PlayGainPulse()
        end
    end
    lastRenderedXP = cur
    lastRenderedLevel = level

    xpBar:SetMinMaxValues(0, max)
    xpBar:SetValue(cur)

    if db.showRested ~= false and rested > 0 then
        restedBar:SetMinMaxValues(0, max)
        restedBar:SetValue(math_min(max, cur + rested))
        restedBar:Show()
    else
        restedBar:Hide()
    end

    if db.showQuestXP ~= false and questXP > 0 then
        questBar:SetMinMaxValues(0, max)
        questBar:SetValue(math_min(max, cur + questXP))
        questBar:Show()
    else
        questBar:Hide()
    end

    local showEmblem = db.showEmblem ~= false
    local showBottom = db.showBottomStats ~= false
    local curPct = cur / max * 100

    if not showEmblem then
        xpTexts.level:SetText(string_format("等级 %d", level))
    end

    -- 百分比（含可交任务矢量箭矢跳升提示，彻底告别中文字体描边糊箭头）
    if db.showQuestXP ~= false and questXP > 0 then
        local afterTotal = cur + questXP
        local afterLabel = (afterTotal >= max) and "可升级!" or string_format("%.0f%%", afterTotal / max * 100)
        if showEmblem and xpTexts.questArrow and xpTexts.percentAfter then
            xpTexts.percent:SetText(string_format("%.1f%%", curPct))
            xpTexts.questArrow:SetVertexColor(activeQuestCol[1], activeQuestCol[2], activeQuestCol[3], 0.96)
            xpTexts.questArrow:Show()
            xpTexts.percentAfter:SetText(afterLabel)
            xpTexts.percentAfter:Show()
        else
            xpTexts.percent:SetText(string_format("%.1f%% |cff%s+%s|r", curPct, activeQuestHex, afterLabel))
            if xpTexts.questArrow then xpTexts.questArrow:Hide() end
            if xpTexts.percentAfter then xpTexts.percentAfter:Hide() end
        end
    else
        xpTexts.percent:SetText(string_format("%.1f%%", curPct))
        if xpTexts.questArrow then xpTexts.questArrow:Hide() end
        if xpTexts.percentAfter then xpTexts.percentAfter:Hide() end
    end

    -- 上排右侧（关闭条下统计且启用左侧徽标时，直接切换图2极简风格：右显「预计 XX分」）
    if showEmblem and not showBottom then
        if perHour > 1 then
            local etaSec = rem / perHour * 3600
            xpTexts.xp:SetText("预计 " .. FormatDuration(etaSec))
        else
            xpTexts.xp:SetText(string_format("%s / %s", FormatComma(cur), FormatComma(max)))
        end
    elseif (db.width or 430) >= 360 then
        xpTexts.xp:SetText(string_format("%s / %s |cff9aa6b8· 剩余 %s|r", FormatComma(cur), FormatComma(max), FormatComma(rem)))
    else
        xpTexts.xp:SetText(string_format("%s / %s", FormatComma(cur), FormatComma(max)))
    end

    if db.showTopTimers == true then
        xpTexts.levelTime:SetText("本级 " .. FormatDuration(levelSec))
        xpTexts.sessionTime:SetText("本次 " .. FormatDuration(sessionSec))
        xpTexts.levelTime:Show()
        xpTexts.sessionTime:Show()
    else
        xpTexts.levelTime:Hide()
        xpTexts.sessionTime:Hide()
    end

    if showBottom then
        if perHour > 1 then
            local etaSec = rem / perHour * 3600
            xpTexts.rate:SetText(string_format("预计 %s |cff8f9bae· %s/时|r", FormatDuration(etaSec), F.FormatShortNumber(perHour)))
        else
            xpTexts.rate:SetText("|cff8f9bae预计升级 · 计算中...|r")
        end

        local rightParts = {}
        if db.showQuestXP ~= false then
            local qPct = questXP / max * 100
            if questXP > 0 then
                rightParts[#rightParts + 1] = string_format("可交 |cff%s+%.1f%%|r", activeQuestHex, qPct)
            else
                rightParts[#rightParts + 1] = "|cff6e7887可交 0%|r"
            end
        end
        if db.showRested ~= false then
            local rPct = rested / max * 100
            if rested > 0 then
                rightParts[#rightParts + 1] = string_format("双倍 |cff38bdf8%.0f%%|r", rPct)
            else
                rightParts[#rightParts + 1] = "|cff6e7887双倍 0%|r"
            end
        end
        xpTexts.completedRested:SetText(table_concat(rightParts, "   "))
        xpTexts.rate:Show()
        xpTexts.completedRested:Show()
    else
        xpTexts.rate:Hide()
        xpTexts.completedRested:Hide()
    end

    xpFrame:Show()
    UpdateEmblemStats()
end

local function UpdateRep()
    if not (repFrame and mod._active) then
        return
    end
    local db = mod:GetDB()
    if not db.showRepBar then
        repFrame:Hide()
        return
    end
    local name, reaction, minV, maxV, val
    if _G.C_Reputation and _G.C_Reputation.GetWatchedFactionData then
        local d = _G.C_Reputation.GetWatchedFactionData()
        if d and d.name and d.name ~= "" then
            name = d.name
            reaction = d.reaction
            minV = d.currentReactionThreshold or 0
            maxV = d.nextReactionThreshold or 1
            val = d.currentStanding or 0
        end
    elseif _G.GetWatchedFactionInfo then
        name, reaction, minV, maxV, val = _G.GetWatchedFactionInfo()
    end
    if not name then
        repFrame:Hide()
        return
    end
    local span = math_max(1, (maxV or 1) - (minV or 0))
    local cur = math_max(0, (val or 0) - (minV or 0))
    repBar:SetMinMaxValues(0, span)
    repBar:SetValue(cur)

    local fr, fg, fb
    local fc = _G.FACTION_BAR_COLORS and _G.FACTION_BAR_COLORS[reaction or 4]
    if fc then
        fr, fg, fb = fc.r, fc.g, fc.b
    else
        fr, fg, fb = F.Theme.GetAccent()
    end
    ApplyFlatBarColor(repBar, { fr, fg, fb }, 1)

    repLeft:SetText(name)
    repRight:SetText(string_format("%s / %s |cff9aa6b8(%.1f%%)|r", FormatComma(cur), FormatComma(span), cur / span * 100))
    repFrame:Show()
end

local function MakeBarFS(parent, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetJustifyH(justify)
    fs:SetWordWrap(false)
    return fs
end

local function CreateFrames()
    if xpFrame then
        return
    end
    xpFrame = CreateFrame("Frame", "ForeverUI_XPBar", _G.UIParent)
    xpFrame:SetFrameStrata("LOW")
    xpFrame:EnableMouse(true)

    BuildFlatTrack(xpFrame)

    restedBar = CreateFrame("StatusBar", nil, xpFrame)
    restedBar:SetPoint("TOPLEFT", 1, -1)
    restedBar:SetPoint("BOTTOMRIGHT", -1, 1)

    questBar = CreateFrame("StatusBar", nil, xpFrame)
    questBar:SetPoint("TOPLEFT", 1, -1)
    questBar:SetPoint("BOTTOMRIGHT", -1, 1)
    questBar:SetFrameLevel(restedBar:GetFrameLevel() + 1)

    xpBar = CreateFrame("StatusBar", nil, xpFrame)
    xpBar:SetPoint("TOPLEFT", 1, -1)
    xpBar:SetPoint("BOTTOMRIGHT", -1, 1)
    xpBar:SetFrameLevel(questBar:GetFrameLevel() + 1)

    local ov = CreateFrame("Frame", nil, xpFrame)
    ov:SetAllPoints()
    ov:SetFrameLevel(xpBar:GetFrameLevel() + 2)

    -- 可选 10% 极细刻度线（默认关闭，保持纯净扁平条）
    xpFrame._ticks = {}
    for idx = 1, 9 do
        local tk = ov:CreateTexture(nil, "ARTWORK", nil, 3)
        tk:SetWidth(1)
        tk:Hide()
        xpFrame._ticks[idx] = tk
    end

    -- 获得经验时的克制平涂闪光脉冲
    xpPulse = ov:CreateTexture(nil, "ARTWORK", nil, 4)
    xpPulse:SetPoint("TOPLEFT", xpBar, "TOPLEFT")
    xpPulse:SetPoint("BOTTOMRIGHT", xpBar, "BOTTOMRIGHT")
    xpPulse:SetTexture(F.Theme.FLAT_TEX)
    xpPulse:SetBlendMode("ADD")
    xpPulse:SetAlpha(0)
    xpPulse:Hide()

    xpPulseAG = xpPulse:CreateAnimationGroup()
    local pIn = xpPulseAG:CreateAnimation("Alpha")
    pIn:SetOrder(1)
    pIn:SetFromAlpha(0)
    pIn:SetToAlpha(0.28)
    pIn:SetDuration(0.10)
    pIn:SetSmoothing("OUT")
    local pOut = xpPulseAG:CreateAnimation("Alpha")
    pOut:SetOrder(2)
    pOut:SetFromAlpha(0.28)
    pOut:SetToAlpha(0)
    pOut:SetDuration(0.32)
    pOut:SetSmoothing("IN")
    xpPulseAG:SetScript("OnFinished", function()
        if xpPulse then xpPulse:Hide() end
    end)

    -- 文字层
    local textLayer = CreateFrame("Frame", nil, xpFrame)
    textLayer:SetAllPoints()
    textLayer:SetFrameLevel(ov:GetFrameLevel() + 2)

    xpTexts.level           = MakeBarFS(textLayer, "LEFT")
    xpTexts.xp              = MakeBarFS(textLayer, "RIGHT")
    xpTexts.percent         = MakeBarFS(textLayer, "LEFT")
    xpTexts.percentAfter    = MakeBarFS(textLayer, "LEFT")
    xpTexts.percentAfter:Hide()
    xpTexts.levelTime       = MakeBarFS(textLayer, "LEFT")
    xpTexts.sessionTime     = MakeBarFS(textLayer, "RIGHT")
    xpTexts.rate            = MakeBarFS(textLayer, "LEFT")
    xpTexts.completedRested = MakeBarFS(textLayer, "RIGHT")

    local questArrow = textLayer:CreateTexture(nil, "OVERLAY")
    questArrow:SetTexture(F.Theme.ICONS .. "ArrowRight.tga")
    questArrow:SetTexCoord(0, 1, 0, 1)
    questArrow:Hide()
    xpTexts.questArrow = questArrow

    -- 左侧一体化无底无框半透明职业徽印 + 右下角等级 + 精准装等（无独立边框与底色）
    emblemFrame = CreateFrame("Frame", nil, xpFrame)
    emblemFrame:SetSize(40, 48)
    emblemFrame:SetFrameLevel(textLayer:GetFrameLevel() + 1)
    emblemFrame:EnableMouse(false)

    emblemIconTex = emblemFrame:CreateTexture(nil, "ARTWORK")
    emblemIconTex:SetSize(34, 34)
    emblemIconTex:SetAlpha(0.82)

    emblemLevelFS = emblemFrame:CreateFontString(nil, "OVERLAY")
    emblemLevelFS:SetJustifyH("RIGHT")
    emblemLevelFS:SetWordWrap(false)

    emblemIlvlFS = emblemFrame:CreateFontString(nil, "OVERLAY")
    emblemIlvlFS:SetJustifyH("CENTER")
    emblemIlvlFS:SetWordWrap(false)

    -- 统一悬停与拖拽热区：鼠标从左侧职业徽印滑向经验条任意处，仅呈现一份稳定不遮挡的概览提示
    xpFrame:EnableMouse(false)
    xpHitBox = CreateFrame("Frame", nil, xpFrame)
    xpHitBox:SetFrameLevel(emblemFrame:GetFrameLevel() + 2)
    xpHitBox:EnableMouse(true)
    xpHitBox:RegisterForDrag("LeftButton")

    local hitDragging = false
    xpHitBox:SetScript("OnDragStart", function()
        if _G.IsShiftKeyDown and _G.IsShiftKeyDown() and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            hitDragging = true
            xpFrame:StartMoving()
        end
    end)
    xpHitBox:SetScript("OnDragStop", function()
        if not hitDragging then return end
        hitDragging = false
        xpFrame:StopMovingOrSizing()
        local pt, _, rpt, x, y = xpFrame:GetPoint(1)
        if type(pt) == "string" and type(x) == "number" and type(y) == "number" and F.DB and F.DB.SavePosition then
            F.DB.SavePosition("XPBar", pt, type(rpt) == "string" and rpt or pt, x, y)
        end
    end)
    xpHitBox:SetScript("OnEnter", function(self)
        isUnitHovered = true
        SyncUnifiedHoverVisual()
        if mod:GetDB().combatFade == true then
            F.Theme.FadeTo(xpFrame, 1.0, 0.16)
        end
        ShowXPTooltip(self)
    end)
    xpHitBox:SetScript("OnLeave", function()
        isUnitHovered = false
        SyncUnifiedHoverVisual()
        if mod:GetDB().combatFade == true and _G.InCombatLockdown and _G.InCombatLockdown() then
            local a = (F.db and F.db.theme and F.db.theme.combatFadeAlpha) or 0.18
            F.Theme.FadeTo(xpFrame, a, 0.24)
        elseif updateXPFade then
            updateXPFade()
        end
        GameTooltip:Hide()
    end)

    F.Mover.Register({
        key = "XPBar",
        label = "经验条",
        frame = xpFrame,
        order = 15,
        -- 默认贴屏幕顶部居中（旧默认 CENTER -750,510 只适合超宽屏/小 UI 缩放，常规 16:9 会落在屏幕外）
        defaultPoint = "TOP",
        defaultRelPoint = "TOP",
        defaultX = 0,
        defaultY = -36,
    })

    updateXPFade = F.Theme.AttachCombatFade(xpFrame, function()
        return mod:GetDB().combatFade == true
    end)

    -- 同款纯扁平声望条
    repFrame = CreateFrame("Frame", "ForeverUI_RepBar", _G.UIParent)
    repFrame:SetFrameStrata("LOW")
    BuildFlatTrack(repFrame)

    repBar = CreateFrame("StatusBar", nil, repFrame)
    repBar:SetPoint("TOPLEFT", 1, -1)
    repBar:SetPoint("BOTTOMRIGHT", -1, 1)

    local repTextLayer = CreateFrame("Frame", nil, repFrame)
    repTextLayer:SetAllPoints()
    repTextLayer:SetFrameLevel(repBar:GetFrameLevel() + 2)
    repLeft = MakeBarFS(repTextLayer, "LEFT")
    repRight = MakeBarFS(repTextLayer, "RIGHT")

    F.Mover.Register({
        key = "RepBar",
        label = "声望条",
        frame = repFrame,
        order = 16,
        defaultPoint = "TOP",
        defaultRelPoint = "TOP",
        defaultX = 0,
        defaultY = -64,
    })
end

local function ThemeCombatAlpha()
    return F.db and F.db.theme and F.PlainNumber(F.db.theme.combatFadeAlpha, nil) or nil
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v3LuminousXP then
        db.v3LuminousXP = true
        if db.width == 420 then db.width = 430 end
        if db.height == 13 then db.height = 10 end
        db.showTopTimers = false
    end
    if not db.v4RefinedXP then
        db.v4RefinedXP = true
        if db.fontSize == 12 then db.fontSize = 11 end
    end
    if not db.v5FlatEmblemXP then
        db.v5FlatEmblemXP = true
        -- 一次性迁移至扁平经典紫 + 左侧高清职业/等级/装等徽标（保留后续手动切换）
        if not db.colorTheme or db.colorTheme == "aurora" or db.colorTheme == "astral" or db.colorTheme == "aion" then
            db.colorTheme = "violet"
        elseif db.colorTheme == "champagne" or db.colorTheme == "solar" then
            db.colorTheme = "gold"
        end
        db.showEmblem = true
        db.showTicks = false
        db.iconStyle = db.iconStyle or "glyph"
    end
    if not db.v6IntegratedXP then
        db.v6IntegratedXP = true
        if not db.iconStyle or db.iconStyle == "modern" then
            db.iconStyle = "glyph"
        end
    end

    questXPDirty = true
    lastRenderedXP = nil
    lastRenderedLevel = nil
    CreateFrames()
    ApplyVisuals()
    UpdateXP()
    UpdateRep()
    self:RegisterEvent("PLAYER_XP_UPDATE", UpdateXP)
    self:RegisterEvent("UPDATE_EXHAUSTION", UpdateXP)
    self:RegisterEvent("PLAYER_LEVEL_UP", function()
        questXPDirty = true
        UpdateXP()
    end)
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", F.Debounce(0.2, UpdateEmblemStats))
    self:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_UPDATE", F.Debounce(0.2, UpdateEmblemStats))
    self:RegisterEvent("QUEST_LOG_UPDATE", F.Debounce(0.25, function()
        questXPDirty = true
        UpdateXP()
    end))
    self:RegisterEvent("UPDATE_FACTION", UpdateRep)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, _, isInitialLogin, isReloadingUi)
        -- 真正的新登录（非 /reload）开启新的「本次在线」统计：下线期间的时长不计入经验/小时
        if isInitialLogin and not isReloadingUi then
            local s = F.charDB and F.charDB.xpSession
            if s then s.startTime = 0 end
        end
        questXPDirty = true
        UpdateXP()
        UpdateRep()
        if updateXPFade then updateXPFade(ThemeCombatAlpha()) end
        C_Timer.After(0.8, function()
            questXPDirty = true
            UpdateXP()
            UpdateRep()
        end)
    end)
    if liveTicker then liveTicker:Cancel() end
    liveTicker = C_Timer.NewTicker(10, function()
        if mod._active and xpFrame and xpFrame:IsShown() then
            UpdateXP()
        end
    end)
end

function mod:OnDisable()
    if liveTicker then liveTicker:Cancel(); liveTicker = nil end
    if xpFrame then xpFrame:Hide() end
    if repFrame then repFrame:Hide() end
end

function mod:OnRefresh()
    ApplyVisuals()
    UpdateXP()
    UpdateRep()
    if updateXPFade then updateXPFade(ThemeCombatAlpha()) end
end

function mod:OnThemeChanged()
    ApplyVisuals()
    UpdateXP()
    UpdateRep()
    -- 设置面板里拖动「战斗淡出透明度」后即时推给经验条的战斗淡出
    if updateXPFade then updateXPFade(ThemeCombatAlpha()) end
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "扁平配色主题",
        tooltip = "纯扁平实色配色：「经典幻紫」紫条配暖橙任务段、「职业纯色」跟随当前职业色、「翡翠纯绿」、「清透钴蓝」、「暖香槟金」。",
        values = THEME_VALUES,
        order = THEME_ORDER,
        getValue = function()
            local k = db.colorTheme or "violet"
            return THEME_ALIASES[k] or k
        end,
        setValue = function(v)
            db.colorTheme = v
            db.useClassColor = (v == "class")
            self:Refresh()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "左侧职业图标（含大号等级与装等）",
        tooltip = "在经验条左端显示高清职业图标，并在图标下方展示大号等级与实时平均装等。",
        getValue = function() return db.showEmblem ~= false end,
        setValue = function(v) db.showEmblem = v == true; self:Refresh() end,
    }, {
        type = "dropdown",
        text = "职业图标风格",
        tooltip = "切换经验条左侧的高清职业图标样式（现代高清 / 暗夜纹章 / 简约徽印 / 符文纹章 / 暴雪原生）。",
        values = ICON_STYLE_VALUES,
        order = ICON_STYLE_ORDER,
        getValue = function() return db.iconStyle or "glyph" end,
        setValue = function(v) db.iconStyle = v; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "叠加已完成任务经验",
        tooltip = "在经验条上以高对比实色段预览可交任务总经验，并在百分比旁用箭头提示交任务后进度。",
        getValue = function() return db.showQuestXP ~= false end,
        setValue = function(v) db.showQuestXP = v == true; self:Refresh() end,
    }, {
        type = "toggle",
        text = "条下显示升级预计与汇总",
        tooltip = "开启时在条下展示预计升级时间、速率与可交/双倍统计；关闭则切换为极简两词模式（左百分比 / 右预计时间）。",
        getValue = function() return db.showBottomStats ~= false end,
        setValue = function(v) db.showBottomStats = v == true; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示 10% 等分刻度线",
        tooltip = "默认关闭以保持纯净无割裂的现代扁平条风格。",
        getValue = function() return db.showTicks == true end,
        setValue = function(v) db.showTicks = v == true; self:Refresh() end,
    }, {
        type = "toggle",
        text = "获得经验时轻闪反馈",
        tooltip = "获得经验瞬间在经验条上触发一次极克制的纯平闪光反馈。",
        getValue = function() return db.showGlow ~= false end,
        setValue = function(v) db.showGlow = v == true; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "经验条宽度",
        min = 260, max = 680, step = 10,
        getValue = function() return db.width or 430 end,
        setValue = function(v) db.width = v; self:Refresh() end,
    }, {
        type = "slider",
        text = "经验条高度",
        min = 6, max = 20, step = 1,
        getValue = function() return db.height or 10 end,
        setValue = function(v) db.height = v; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "文字大小",
        min = 10, max = 16, step = 1,
        getValue = function() return db.fontSize or 11 end,
        setValue = function(v) db.fontSize = v; self:Refresh() end,
    }, {
        type = "toggle",
        text = "条上额外显示本级/本次耗时",
        tooltip = "默认关闭以保持清爽（鼠标悬停经验条或职业图标随时可看详细耗时）。",
        getValue = function() return db.showTopTimers == true end,
        setValue = function(v) db.showTopTimers = v == true; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示独立声望条",
        getValue = function() return db.showRepBar == true end,
        setValue = function(v) db.showRepBar = v == true; self:Refresh() end,
    }, {
        type = "toggle",
        text = "战斗中自动淡出",
        getValue = function() return db.combatFade == true end,
        setValue = function(v) db.combatFade = v == true; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "满级自动隐藏",
        getValue = function() return db.hideAtMaxLevel ~= false end,
        setValue = function(v) db.hideAtMaxLevel = v == true; self:Refresh() end,
    }, blank)
    y = y - h
    return y
end
