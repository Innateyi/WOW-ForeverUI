----------------------------------------------------------------------
--  kkowoUI — Modules/XPBar.lua
--  极简圆角柔光经验条 + 左侧职业徽印（等级 & 冰青柔光装等）+ 声望条
--    • 9 宫格抗锯齿圆角半透明暗玻底槽（无厚重黑框 / 无复古塑料高光 / 无突兀白竖线）
--    • 水平哑光丝滑渐变填充 + 3 段均匀高斯背光晕（仅贴合已填充进度，空槽保持通透）
--    • 统一纯净阴影无黑描边排版 + 左侧清透冰青自发光装等 + 防重载错算精准速率（右键重置）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local math_floor, math_min, math_max = math.floor, math.min, math.max
local string_format = string.format
local table_concat = table.concat
local ipairs, pcall, tostring, type, GetTime = ipairs, pcall, tostring, type, GetTime
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = _G.GameTooltip

-- 5 套现代水平哑光渐变配色（左深右亮自然流向进度前沿 + 冰青清透装等）
local ILVL_AION_HEX = "c2fcf8"
local ILVL_AION_RGB = { 0.76, 0.99, 0.97 }
local SOFT_GLOW_TEX  = F.MEDIA .. "Textures\\SoftGlow"
local PILL_MASK_TEX  = F.MEDIA .. "Textures\\BarPillMask"
local PILL_RIM_TEX   = F.MEDIA .. "Textures\\BarPillRim"
local EUI_ROUND_MASK = "Interface\\AddOns\\EllesmereUI\\media\\rounded\\rounded-3.tga"
local EUI_ROUND_INV2 = "Interface\\AddOns\\EllesmereUI\\media\\rounded\\rounded-inv-2.tga"

local function UseEUIRounded()
    return _G.EllesmereUI ~= nil or F.IsAddOnLoaded("EllesmereUI")
end

local THEME_PRESETS = {
    violet = {
        label      = "琉璃幻紫（默认柔光风）",
        fillStart  = { 0.48, 0.32, 0.94 }, -- #7A52F0 深邃紫罗兰
        fill       = { 0.80, 0.66, 1.00 }, -- #CCA8FF 清透薰衣草紫
        questStart = { 0.88, 0.59, 0.28 }, -- #E09647 暖蜜琥珀
        quest      = { 0.99, 0.78, 0.48 }, -- #FCC77A 浅香槟橙
        rested     = { 0.28, 0.78, 0.99 }, -- #47C7FC 清透双倍蓝
        questHex   = "fcc87c",
        ilvlHex    = ILVL_AION_HEX,
    },
    class = {
        label = "职业主题色（动态职业渐变）",
    },
    emerald = {
        label      = "翡翠流光（猎人/自然）",
        fillStart  = { 0.16, 0.68, 0.46 },
        fill       = { 0.48, 0.94, 0.70 },
        questStart = { 0.88, 0.59, 0.28 },
        quest      = { 0.99, 0.78, 0.48 },
        rested     = { 0.28, 0.78, 0.99 },
        questHex   = "fcc87c",
        ilvlHex    = ILVL_AION_HEX,
    },
    cobalt = {
        label      = "冰川钴蓝（清透冷调）",
        fillStart  = { 0.20, 0.45, 0.92 },
        fill       = { 0.54, 0.79, 1.00 },
        questStart = { 0.88, 0.59, 0.28 },
        quest      = { 0.99, 0.78, 0.48 },
        rested     = { 0.34, 0.84, 0.99 },
        questHex   = "fcc87c",
        ilvlHex    = ILVL_AION_HEX,
    },
    gold = {
        label      = "暖香槟金（kkowoUI 同系）",
        fillStart  = { 0.76, 0.56, 0.32 },
        fill       = { 0.97, 0.86, 0.68 },
        questStart = { 0.22, 0.72, 0.54 },
        quest      = { 0.48, 0.94, 0.76 },
        rested     = { 0.28, 0.74, 0.96 },
        questHex   = "76efc2",
        ilvlHex    = ILVL_AION_HEX,
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
    desc = "显示职业徽印、等级装等、可交任务经验预览与独立声望条。",
    group = "quest",
    order = 40,
    defaults = {
        enabled = true,
        width = 430,
        height = 7,
        fontSize = 11,
        colorTheme = "violet",
        iconStyle = "glyph",
        showEmblem = true,
        showTicks = false,
        showGlow = true,
        softGlow = true,       -- 经验条进度背光晕、等级与装等浅柔光
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
        v8SleekPillXP = false,
    },
})

local xpFrame, xpHitBox, xpBar, restedBar, questBar
local xpPulse, xpPulseAG
local emblemFrame, emblemIconTex, emblemLevelFS, emblemIlvlFS
local xpTexts = {}
local repFrame, repBar, repLeft, repRight
local activeQuestHex = "fcc87c"
local activeQuestCol = { 0.99, 0.78, 0.48 }
local activeFillCol = { 0.80, 0.66, 1.00 }
local levelHalo, ilvlHalo
local fx = {}
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
            val = ok and F.PlainNumber(val, nil) or nil
            if val and val > 0 then
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
        return preset.fillStart or preset.fill, preset.fill, preset.questStart or preset.quest, preset.quest, preset.rested, preset.questHex, preset.ilvlHex
    end
    -- 职业主题色水平渐变：左侧沉稳本色，右侧向进度前沿自然提亮
    local ar, ag, ab = F.Theme.GetClassColor()
    local warmClass = (ar > 0.75 and ag > 0.45 and ab < 0.45)
    local fillStart = { Clamp01(ar * 0.72), Clamp01(ag * 0.72), Clamp01(ab * 0.74) }
    local fillEnd = { Clamp01(ar + (1 - ar) * 0.26), Clamp01(ag + (1 - ag) * 0.26), Clamp01(ab + (1 - ab) * 0.26) }
    local questStart = warmClass and { 0.22, 0.72, 0.54 } or { 0.88, 0.59, 0.28 }
    local questEnd = warmClass and { 0.48, 0.94, 0.76 } or { 0.99, 0.78, 0.48 }
    local questHex = warmClass and "76efc2" or "fcc87c"
    local rested = { 0.28, 0.78, 0.99 }
    return fillStart, fillEnd, questStart, questEnd, rested, questHex, ILVL_AION_HEX
end

local function ApplyHorizBarColor(bar, colStart, colEnd, alpha)
    if not bar or not colEnd then return end
    local a = alpha or 1
    if not bar._texBound then
        bar:SetStatusBarTexture(F.Theme.FLAT_TEX)
        bar._texBound = true
    end
    bar:SetStatusBarColor(colEnd[1], colEnd[2], colEnd[3], a)
    if colStart and _G.CreateColor and bar.GetStatusBarTexture then
        local tex = bar:GetStatusBarTexture()
        if tex and tex.SetGradient then
            local leftC = _G.CreateColor(colStart[1], colStart[2], colStart[3], a)
            local rightC = _G.CreateColor(colEnd[1], colEnd[2], colEnd[3], a)
            pcall(tex.SetGradient, tex, "HORIZONTAL", leftC, rightC)
        end
    end
end

local function ApplyCleanBarFont(fs, size, r, g, b, a, outline, shadowAlpha, shadowX)
    if not (fs and fs.SetFont) then return end
    local flags = (outline == nil) and "" or outline
    F.Theme.ApplyFont(fs, size, flags, r, g, b, a)
    if fs.SetShadowColor then
        pcall(fs.SetShadowColor, fs, 0, 0, 0, shadowAlpha or (flags == "" and 0.94 or 0.80))
    end
    if fs.SetShadowOffset then
        pcall(fs.SetShadowOffset, fs, shadowX or 1, -1)
    end
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

local function ResetXPSession(silent)
    local s = F.charDB and F.charDB.xpSession
    if not s then return end
    local now = GetTime()
    local level = F.PlainNumber(_G.UnitLevel and _G.UnitLevel("player"), 0)
    local cur = F.PlainNumber(_G.UnitXP and _G.UnitXP("player"), 0)
    local max = math_max(1, F.PlainNumber(_G.UnitXPMax and _G.UnitXPMax("player"), 1))
    s.startTime = now
    s.gainedXP = 0
    s.lastXP = cur
    s.maxXP = max
    s.lastLevel = level
    s.pendingLevel = nil
    s.refPerHour = nil
    s.v7RateClean = true
    if not s.levelStartTime or s.levelStartTime == 0 or s.levelStartTime > now then
        s.levelStartTime = now
    end
    if not silent and F.Print then
        F.Print("经验条：已重置本次升级速率统计。")
    end
end

local function UpdateSession(cur, max)
    local s = F.charDB and F.charDB.xpSession
    if not s then
        return 0, 0, 0, 0
    end
    local now = GetTime()
    local level = F.PlainNumber(_G.UnitLevel and _G.UnitLevel("player"), 0)
    -- 角色数据尚未同步完毕（登录首帧或切图瞬间 UnitXPMax <= 1 或等级无效）：绝不改写 lastXP/gainedXP
    if level <= 0 or max <= 1 then
        local sessionSec = (s.startTime and s.startTime > 0 and s.startTime <= now) and math_max(1, now - s.startTime) or 1
        local levelSec = (s.levelStartTime and s.levelStartTime > 0 and s.levelStartTime <= now) and math_max(1, now - s.levelStartTime) or 1
        return s.gainedXP or 0, 0, sessionSec, levelSec, F.PlainNumber(s.refPerHour, nil)
    end
    -- 一次性清理旧版本因 /reload 瞬间 cur=0 误判升级而污染的累计经验与参考速率
    local needReset = (not s.v7RateClean)
        or (not s.startTime or s.startTime == 0 or s.startTime > now)
        or (s.lastLevel and s.lastLevel > 0 and level < s.lastLevel)
    if needReset then
        -- GetTime() 是开机时长：startTime 比现在还大说明重启过电脑，旧会话必须清零
        s.startTime = now
        s.gainedXP = 0
        s.lastXP = cur
        s.maxXP = max
        s.lastLevel = level
        s.pendingLevel = nil
        if not s.v7RateClean then
            s.refPerHour = nil
            s.v7RateClean = true
        end
    else
        -- 切图或 /reload 瞬间同等级下 UnitXP("player") 偶发短暂返回 0：跳过该帧，绝不能误判成升级
        local isTransientZero = (s.lastLevel == level and cur == 0 and (s.lastXP or 0) > 0)
        if not isTransientZero then
            local lastXP = s.lastXP or 0
            local leveled = (s.lastLevel ~= nil and s.lastLevel > 0 and level > s.lastLevel)
            -- 升级时 UnitXP 常常先回绕、UnitLevel 稍后才刷新（PLAYER_LEVEL_UP 期间就是旧等级）：
            -- 同等级下经验变少就按升级结算一次，并记下应到的等级，等级刷新过来时不再重复结算
            local prepaid = leveled and s.pendingLevel ~= nil and level <= s.pendingLevel
            local wrapped = (not leveled) and cur < lastXP
            -- 反过来等级先刷新、经验还是旧值时先不结算，等经验刷新后再算，否则会多算一整级
            if not (leveled and not prepaid and cur == lastXP) then
                local delta = 0
                if ((leveled and not prepaid) or wrapped) and s.maxXP and s.maxXP > 0 then
                    delta = math_max(0, s.maxXP - lastXP) + cur
                    s.levelStartTime = now
                elseif cur > lastXP then
                    delta = cur - lastXP
                end
                if delta > 0 then
                    s.gainedXP = (s.gainedXP or 0) + delta
                end
                s.lastXP = cur
                s.maxXP = max
                s.lastLevel = level
                if wrapped then
                    s.pendingLevel = level + 1
                elseif leveled then
                    s.pendingLevel = nil
                end
            end
        end
    end
    if not s.levelStartTime or s.levelStartTime == 0 or s.levelStartTime > now then
        s.levelStartTime = now
    end
    local sessionSec = math_max(1, now - s.startTime)
    local levelSec = math_max(1, now - s.levelStartTime)
    -- 开局前 3 分钟用 180 秒窗口做平滑阻尼，防止刚上线交一个任务就算出 6~20 万/时的虚高瞬时峰值；满 3 分钟后转为精准在线均速
    local gained = s.gainedXP or 0
    local perHour = gained > 0 and (gained / math_max(sessionSec, 180) * 3600) or 0
    -- 在线满 5 分钟后才更新参考速率，确保下次登录首段展示的「参考预计」稳定可信
    if gained > 0 and sessionSec >= 300 then
        s.refPerHour = perHour
    end
    return gained, perHour, sessionSec, levelSec, F.PlainNumber(s.refPerHour, nil)
end

local function ApplyNineSlice(obj, texPath, radius, wrap)
    if not obj then return end
    if obj.SetBlockingLoadsRequested then
        pcall(obj.SetBlockingLoadsRequested, obj, true)
    end
    if wrap then
        pcall(obj.SetTexture, obj, texPath, wrap, wrap)
    else
        pcall(obj.SetTexture, obj, texPath)
    end
    if obj.SetTextureSliceMargins then
        pcall(obj.SetTextureSliceMargins, obj, radius, radius, radius, radius)
    end
    local sm = _G.Enum and _G.Enum.UITextureSliceMode and _G.Enum.UITextureSliceMode.Stretched
    if sm and obj.SetTextureSliceMode then
        pcall(obj.SetTextureSliceMode, obj, sm)
    end
end

local function AttachMask(tex, mask, host)
    if not (tex and mask and tex.AddMaskTexture) then return end
    local ST = F.StyleTokens
    if ST and ST.AttachCustomMask then
        ST.AttachCustomMask(host, tex, mask)
    else
        pcall(tex.AddMaskTexture, tex, mask)
    end
end

local function CreateThreeSliceGlow(parent, layer, sub)
    local l = parent:CreateTexture(nil, layer, nil, sub)
    local m = parent:CreateTexture(nil, layer, nil, sub)
    local r = parent:CreateTexture(nil, layer, nil, sub)
    for _, t in ipairs({ l, m, r }) do
        t:SetTexture(SOFT_GLOW_TEX)
        t:SetBlendMode("ADD")
        t:Hide()
    end
    l:SetTexCoord(0, 0.5, 0, 1)
    m:SetTexCoord(0.49, 0.51, 0, 1)
    r:SetTexCoord(0.5, 1, 0, 1)
    return { l = l, m = m, r = r }
end

local function HideThreeSliceGlow(g)
    if not g then return end
    g.l:Hide()
    g.m:Hide()
    g.r:Hide()
end

local function ShowThreeSliceGlow(g, anchorFrame, xStart, width, barH, padY, capW, col, alpha)
    if not g then return end
    if width <= 1 then
        HideThreeSliceGlow(g)
        return
    end
    local totalH = barH + padY * 2
    local cap = math_min(capW, math_floor((width + capW * 2) * 0.5))
    local leftX = xStart - capW
    local rightX = xStart + width + capW
    local midW = rightX - leftX - cap * 2

    g.l:ClearAllPoints()
    g.l:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", leftX, padY)
    g.l:SetSize(cap, totalH)

    g.r:ClearAllPoints()
    g.r:SetPoint("TOPRIGHT", anchorFrame, "TOPLEFT", rightX, padY)
    g.r:SetSize(cap, totalH)

    for _, t in ipairs({ g.l, g.m, g.r }) do
        t:SetVertexColor(col[1], col[2], col[3])
        t:SetAlpha(alpha)
    end
    g.l:Show()
    g.r:Show()

    if midW > 0.5 then
        g.m:ClearAllPoints()
        g.m:SetPoint("TOPLEFT", g.l, "TOPRIGHT", 0, 0)
        g.m:SetPoint("BOTTOMRIGHT", g.r, "BOTTOMLEFT", 0, 0)
        g.m:Show()
    else
        g.m:Hide()
    end
end

local function BuildPillTrack(frame)
    local maskPath = UseEUIRounded() and EUI_ROUND_MASK or PILL_MASK_TEX
    -- 9 宫格抗锯齿圆角遮罩：任意宽高下保持 3px 柔顺胶囊圆角（优先复用 EUI 已加载圆角图，/reload 即生效）
    if frame.CreateMaskTexture then
        local mask = frame:CreateMaskTexture()
        if mask then
            ApplyNineSlice(mask, maskPath, 3, "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(frame)
            frame._pillMask = mask
        end
    end

    -- 柔和圆角底影（替代生硬黑框，亮背景与暗背景下均轻盈立体）
    local drop = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
    ApplyNineSlice(drop, maskPath, 3)
    drop:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 0)
    drop:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
    drop:SetVertexColor(0, 0, 0, 0.44)
    frame._dropShadow = drop

    -- 半透明深邃暗玻底槽（使用 FLAT_TEX + VertexColor 确保与 MaskTexture 100% 兼容）
    local trackBg = frame:CreateTexture(nil, "BACKGROUND", nil, -5)
    if trackBg.SetBlockingLoadsRequested then pcall(trackBg.SetBlockingLoadsRequested, trackBg, true) end
    trackBg:SetAllPoints(frame)
    trackBg:SetTexture(F.Theme.FLAT_TEX)
    trackBg:SetVertexColor(0.04, 0.05, 0.085, 0.66)
    AttachMask(trackBg, frame._pillMask, frame)
    frame._trackBg = trackBg
end

local function CreatePillRim(parent, targetFrame)
    local host = targetFrame or parent
    local rim = parent:CreateTexture(nil, "OVERLAY", nil, 1)
    if rim.SetBlockingLoadsRequested then pcall(rim.SetBlockingLoadsRequested, rim, true) end
    rim:SetAllPoints(host)
    if UseEUIRounded() and host._pillMask and parent.CreateMaskTexture then
        local hole = parent:CreateMaskTexture()
        if hole then
            rim:SetTexture(F.Theme.FLAT_TEX)
            rim:SetVertexColor(1, 1, 1, 0.14)
            ApplyNineSlice(hole, EUI_ROUND_INV2, 2, "CLAMPTOWHITE")
            hole:SetPoint("TOPLEFT", host, "TOPLEFT", 1, -1)
            hole:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -1, 1)
            local ST = F.StyleTokens
            if ST and ST.AttachBorderHole then
                ST.AttachBorderHole(rim, rim, hole, host._pillMask, host)
            else
                AttachMask(rim, host._pillMask, host)
                AttachMask(rim, hole, host)
            end
            return rim
        end
    end
    ApplyNineSlice(rim, PILL_RIM_TEX, 3)
    rim:SetVertexColor(1, 1, 1, 0.14)
    return rim
end

local function ShowXPTooltip(anchor)
    local owner = xpHitBox or anchor or xpFrame
    if not owner then return end
    local level = _G.UnitLevel and F.PlainNumber(_G.UnitLevel("player"), 1) or 1
    local eqIlvl, overallIlvl = GetPlayerItemLevel()
    local cur = F.PlainNumber(_G.UnitXP("player"), 0)
    local max = math_max(1, F.PlainNumber(_G.UnitXPMax("player"), 1))
    local rem = math_max(0, max - cur)
    local rested = F.PlainNumber(_G.GetXPExhaustion and _G.GetXPExhaustion(), 0)
    local questXP = GetCompletedQuestXP()
    local gained, perHour, sessionSec, levelSec = UpdateSession(cur, max)

    -- 智能上下避让：经验条位于屏幕上侧时提示框朝下展开，彻底杜绝遮挡图标/等级/经验条
    local _, rawCy = owner:GetCenter()
    local cy = F.PlainNumber(rawCy, nil)
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
    GameTooltip:AddLine("Shift + 左键拖动可微调位置 · 右键点击重置本次速率", 0.58, 0.62, 0.70)
    GameTooltip:Show()
end

local function SyncUnifiedHoverVisual()
    if emblemIconTex then
        emblemIconTex:SetAlpha(isUnitHovered and 1.00 or 0.90)
    end
end

local function UpdateBarGlow(cur, max, questXP)
    if not xpFrame then return end
    local db = mod:GetDB()
    local glowOn = db.softGlow ~= false
    local w = db.width or 430
    local h = db.height or 7
    local ratio = (max and max > 0) and Clamp01((cur or 0) / max) or 0
    local fillW = math_floor(w * ratio + 0.5)
    local showQuest = db.showQuestXP ~= false and (questXP or 0) > 0
    local qEndW = showQuest and math_floor(w * Clamp01(((cur or 0) + questXP) / math_max(1, max or 1)) + 0.5) or fillW
    local qW = math_max(0, qEndW - fillW)

    -- 3 段均匀高斯背光晕：仅贴合已填充进度，空槽保持纯净深邃，无中心鼓包与方框糊边
    if glowOn and fillW > 2 then
        ShowThreeSliceGlow(fx.xpBloom, xpFrame, 0, fillW, h, 7, 10, activeFillCol, 0.28)
    else
        HideThreeSliceGlow(fx.xpBloom)
    end

    if glowOn and qW > 2 then
        ShowThreeSliceGlow(fx.questBloom, xpFrame, fillW, qW, h, 5, 7, activeQuestCol, 0.14)
    else
        HideThreeSliceGlow(fx.questBloom)
    end

    -- 紫色经验与暖橙可交任务段之间留 1px 柔和分隔线，无刺眼白竖线
    if fx.questSeam then
        if showQuest and qW > 1 and fillW > 2 and fillW < w - 2 then
            fx.questSeam:ClearAllPoints()
            fx.questSeam:SetPoint("TOP", xpFrame, "TOPLEFT", fillW, 0)
            fx.questSeam:SetPoint("BOTTOM", xpFrame, "BOTTOMLEFT", fillW, 0)
            fx.questSeam:Show()
        else
            fx.questSeam:Hide()
        end
    end
end

local function ApplyVisuals()
    local db = mod:GetDB()
    local w = db.width or 430
    local h = db.height or 7
    local fsSize = db.fontSize or 11
    local pctSize = math_max(13, fsSize + 2)
    local lvSize = math_max(14, fsSize + 3)
    local subSize = math_max(10, fsSize - 1)
    local showEmblem = db.showEmblem ~= false
    local showTicks = db.showTicks == true

    local themeKey = db.colorTheme or (db.useClassColor and "class" or "violet")
    local fillStart, fillEnd, questStart, questEnd, restedCol, questHex, ilvlHex = ResolveThemeColors(themeKey)
    activeFillCol = fillEnd
    activeQuestHex = questHex
    activeQuestCol = questEnd
    activeIlvlHex = ilvlHex

    if xpFrame then
        xpFrame:SetSize(w, h)
        if xpFrame._trackBg then
            xpFrame._trackBg:SetVertexColor(0.04, 0.05, 0.085, 0.66)
        end

        -- 水平哑光平滑渐变三层填充（无塑料感垂直高光）
        ApplyHorizBarColor(restedBar, nil,        restedCol, 0.30)
        ApplyHorizBarColor(questBar,  questStart, questEnd,  0.86)
        ApplyHorizBarColor(xpBar,     fillStart,  fillEnd,   1.00)

        -- 刻度线默认关闭（可在设置中开启）
        if xpFrame._ticks then
            for idx = 1, 9 do
                local tk = xpFrame._ticks[idx]
                if showTicks then
                    tk:ClearAllPoints()
                    tk:SetPoint("TOP", xpBar, "TOPLEFT", w * (idx * 0.1), 0)
                    tk:SetPoint("BOTTOM", xpBar, "BOTTOMLEFT", w * (idx * 0.1), 0)
                    tk:SetColorTexture(0, 0, 0, idx == 5 and 0.24 or 0.12)
                    tk:Show()
                else
                    tk:Hide()
                end
            end
        end

        if xpPulse then
            xpPulse:SetVertexColor(1, 1, 1, 1)
        end

        local topGap = 6
        local botGap = -6
        local showBottom = db.showBottomStats ~= false
        local emblemGap = 9
        local iconSz = math_max(28, math_min(34, h + pctSize + 10))

        -- 左侧简约职业徽印 + 紧致暖白等级 + 清透冰青柔光装等
        if emblemFrame then
            if showEmblem then
                local embW = math_max(40, iconSz + 6)
                emblemFrame:SetSize(embW, iconSz + subSize + 12)
                emblemFrame:ClearAllPoints()
                emblemFrame:SetPoint("RIGHT", xpFrame, "LEFT", -emblemGap, 0)
                emblemFrame:Show()

                if emblemIconTex then
                    emblemIconTex:SetSize(iconSz, iconSz)
                    emblemIconTex:ClearAllPoints()
                    emblemIconTex:SetPoint("BOTTOM", emblemFrame, "CENTER", 0, -math_floor(h * 0.5))
                    ApplyClassIcon(emblemIconTex, db.iconStyle or "glyph")
                    SyncUnifiedHoverVisual()
                end
                if emblemLevelFS then
                    ApplyCleanBarFont(emblemLevelFS, lvSize, 1.00, 0.99, 0.95, 1, "OUTLINE", 0.85, 0)
                    emblemLevelFS:ClearAllPoints()
                    emblemLevelFS:SetPoint("BOTTOMRIGHT", emblemIconTex, "BOTTOMRIGHT", 3, -1)
                end
                if emblemIlvlFS then
                    -- 纯净阴影 + 柔和椭圆冰青光晕（无黑描边阻挡、无生硬底线）
                    ApplyCleanBarFont(emblemIlvlFS, math_max(11, subSize + 1), ILVL_AION_RGB[1], ILVL_AION_RGB[2], ILVL_AION_RGB[3], 1, "", 0.94, 1)
                    emblemIlvlFS:ClearAllPoints()
                    emblemIlvlFS:SetPoint("TOP", emblemIconTex, "BOTTOM", 0, botGap)
                end
            else
                emblemFrame:Hide()
            end
        end

        -- 统一整体悬停与拖拽热区
        if xpHitBox then
            local leftExt = showEmblem and (math_max(40, iconSz + 6) + emblemGap) or 0
            local topExt = topGap + pctSize + (db.showTopTimers and (subSize + 6) or 3)
            local botExt = (showBottom or showEmblem) and (math_max(subSize, 12) + 10) or 4
            xpHitBox:ClearAllPoints()
            xpHitBox:SetPoint("TOPLEFT", xpFrame, "TOPLEFT", -leftExt, topExt)
            xpHitBox:SetPoint("BOTTOMRIGHT", xpFrame, "BOTTOMRIGHT", 2, -botExt)
        end

        -- 文字净空排版：上下排统一纯净阴影无黑描边，轻盈现代零笨重
        if showEmblem then
            xpTexts.level:Hide()
            xpTexts.percent:ClearAllPoints()
            xpTexts.percent:SetJustifyH("LEFT")
            xpTexts.percent:SetPoint("BOTTOMLEFT", xpFrame, "TOPLEFT", 1, topGap)

            xpTexts.xp:ClearAllPoints()
            xpTexts.xp:SetJustifyH("RIGHT")
            xpTexts.xp:SetPoint("BOTTOMRIGHT", xpFrame, "TOPRIGHT", -1, topGap)
        else
            xpTexts.level:Show()
            xpTexts.level:ClearAllPoints()
            xpTexts.level:SetPoint("BOTTOMLEFT", xpFrame, "TOPLEFT", 1, topGap)

            xpTexts.xp:ClearAllPoints()
            xpTexts.xp:SetJustifyH("CENTER")
            xpTexts.xp:SetPoint("BOTTOM", xpFrame, "TOP", 0, topGap)

            xpTexts.percent:ClearAllPoints()
            xpTexts.percent:SetJustifyH("RIGHT")
            xpTexts.percent:SetPoint("BOTTOMRIGHT", xpFrame, "TOPRIGHT", -1, topGap)
        end

        if xpTexts.questArrow and xpTexts.percentAfter then
            local arrowSz = math_max(10, pctSize - 2)
            xpTexts.questArrow:SetSize(arrowSz, arrowSz)
            xpTexts.questArrow:SetVertexColor(questEnd[1], questEnd[2], questEnd[3], 0.94)
            xpTexts.questArrow:ClearAllPoints()
            xpTexts.percentAfter:ClearAllPoints()
            if showEmblem then
                xpTexts.questArrow:SetPoint("LEFT", xpTexts.percent, "RIGHT", 4, 0)
                xpTexts.percentAfter:SetJustifyH("LEFT")
                xpTexts.percentAfter:SetPoint("LEFT", xpTexts.questArrow, "RIGHT", 4, 0)
            else
                xpTexts.questArrow:Hide()
                xpTexts.percentAfter:Hide()
            end
            ApplyCleanBarFont(xpTexts.percentAfter, pctSize, questEnd[1], questEnd[2], questEnd[3], 1, "", 0.94, 1)
        end

        local timerY = topGap + pctSize + 4
        xpTexts.levelTime:ClearAllPoints()
        xpTexts.levelTime:SetPoint("BOTTOMLEFT", xpFrame, "TOPLEFT", 1, timerY)
        xpTexts.sessionTime:ClearAllPoints()
        xpTexts.sessionTime:SetPoint("BOTTOMRIGHT", xpFrame, "TOPRIGHT", -1, timerY)

        xpTexts.rate:ClearAllPoints()
        xpTexts.rate:SetPoint("TOPLEFT", xpFrame, "BOTTOMLEFT", 1, botGap)
        xpTexts.completedRested:ClearAllPoints()
        xpTexts.completedRested:SetPoint("TOPRIGHT", xpFrame, "BOTTOMRIGHT", -1, botGap)

        ApplyCleanBarFont(xpTexts.level, math_max(13, fsSize + 2), 0.98, 0.99, 1.00, 1, "", 0.94, 1)
        ApplyCleanBarFont(xpTexts.percent, pctSize, 0.99, 0.995, 1.00, 1, "", 0.94, 1)
        ApplyCleanBarFont(xpTexts.xp, fsSize, 0.93, 0.95, 0.99, 0.98, "", 0.94, 1)
        ApplyCleanBarFont(xpTexts.levelTime, subSize, 0.80, 0.86, 0.94, 0.94, "", 0.94, 1)
        ApplyCleanBarFont(xpTexts.sessionTime, subSize, 0.80, 0.86, 0.94, 0.94, "", 0.94, 1)
        ApplyCleanBarFont(xpTexts.rate, subSize, 0.88, 0.92, 0.98, 0.96, "", 0.94, 1)
        ApplyCleanBarFont(xpTexts.completedRested, subSize, 0.88, 0.92, 0.98, 0.96, "", 0.94, 1)
    end

    if repFrame then
        local repH = math_max(6, h)
        repFrame:SetSize(w, repH)
        repLeft:ClearAllPoints()
        repLeft:SetPoint("BOTTOMLEFT", repFrame, "TOPLEFT", 1, 5)
        repRight:ClearAllPoints()
        repRight:SetPoint("BOTTOMRIGHT", repFrame, "TOPRIGHT", -1, 5)
        ApplyCleanBarFont(repLeft, fsSize, 0.96, 0.97, 1.00, 1, "", 0.94, 1)
        ApplyCleanBarFont(repRight, fsSize, 0.90, 0.93, 0.98, 1, "", 0.94, 1)
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

local function FitHalo(halo, fs, r, g, b, a, padW, padH)
    if not (halo and fs) then return end
    if mod:GetDB().softGlow == false then
        halo:Hide()
        return
    end
    local sw = F.PlainNumber(fs:GetStringWidth(), 0)
    local sh = F.PlainNumber(fs:GetStringHeight(), 0)
    if sw <= 0 or sh <= 0 then
        halo:Hide()
        return
    end
    halo:SetSize(sw + (padW or 16), sh + (padH or 10))
    halo:SetVertexColor(r, g, b)
    halo:SetAlpha(a)
    halo:Show()
end

local function UpdateEmblemStats()
    if not (mod._active and emblemFrame and emblemFrame:IsShown()) then return end
    local level = _G.UnitLevel and F.PlainNumber(_G.UnitLevel("player"), 1) or 1
    if emblemLevelFS then
        emblemLevelFS:SetText(tostring(level))
    end
    local hasIlvl = false
    if emblemIlvlFS then
        local eqIlvl = GetPlayerItemLevel()
        if eqIlvl and eqIlvl > 0 then
            hasIlvl = true
            emblemIlvlFS:SetText(string_format("|cff%s%.2f|r", activeIlvlHex, eqIlvl))
        else
            emblemIlvlFS:SetText("|cff9aa8be--|r")
        end
    end
    FitHalo(levelHalo, emblemLevelFS, 1.00, 0.94, 0.80, 0.16, 14, 8)
    FitHalo(ilvlHalo, emblemIlvlFS, 0.36, 0.95, 0.94, hasIlvl and 0.25 or 0.10, 22, 10)
end

local function UpdateXP()
    -- 防抖/延时回调可能在停用之后才触发：停用后绝不再把经验条显示出来
    if not (xpFrame and mod._active) then
        return
    end
    local db = mod:GetDB()
    local level = _G.UnitLevel and F.PlainNumber(_G.UnitLevel("player"), 1) or 1
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
    local _, perHour, sessionSec, levelSec, refPerHour = UpdateSession(cur, max)
    -- 本次还没获得经验时沿用上次速率估算（文字标注「参考」）
    local etaRate, etaIsRef = perHour, false
    if perHour <= 1 and refPerHour and refPerHour > 1 then
        etaRate, etaIsRef = refPerHour, true
    end

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
        if etaRate > 1 then
            local etaSec = rem / etaRate * 3600
            xpTexts.xp:SetText((etaIsRef and "参考预计 " or "预计 ") .. FormatDuration(etaSec))
        else
            xpTexts.xp:SetText(string_format("%s / %s", FormatComma(cur), FormatComma(max)))
        end
    elseif (db.width or 430) >= 360 then
        xpTexts.xp:SetText(string_format("%s / %s |cffb8c4d6· 剩余 %s|r", FormatComma(cur), FormatComma(max), FormatComma(rem)))
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
        if etaRate > 1 then
            local etaSec = rem / etaRate * 3600
            xpTexts.rate:SetText(string_format("%s %s |cffb8c7dc· %s/时%s|r",
                etaIsRef and "参考预计" or "预计", FormatDuration(etaSec), F.FormatShortNumber(etaRate),
                etaIsRef and "（上次）" or ""))
        else
            xpTexts.rate:SetText("|cffb0bfd4预计升级 · 计算中...|r")
        end

        local rightParts = {}
        if db.showQuestXP ~= false then
            local qPct = questXP / max * 100
            if questXP > 0 then
                rightParts[#rightParts + 1] = string_format("可交 |cff%s+%.1f%%|r", activeQuestHex, qPct)
            else
                rightParts[#rightParts + 1] = "|cffa8b6ca可交 0%|r"
            end
        end
        if db.showRested ~= false then
            local rPct = rested / max * 100
            if rested > 0 then
                rightParts[#rightParts + 1] = string_format("双倍 |cff5cd4ff%.0f%%|r", rPct)
            else
                rightParts[#rightParts + 1] = "|cffa8b6ca双倍 0%|r"
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
    UpdateBarGlow(cur, max, questXP)
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
    minV = F.PlainNumber(minV, 0) or 0
    maxV = F.PlainNumber(maxV, 0) or 0
    val = F.PlainNumber(val, 0) or 0
    reaction = F.PlainNumber(reaction, 4) or 4
    local isMaxed = (maxV <= minV) or (reaction >= 8 and val >= maxV)
    local span = isMaxed and 1 or math_max(1, maxV - minV)
    local cur = isMaxed and 1 or math_max(0, math_min(span, val - minV))
    repBar:SetMinMaxValues(0, span)
    repBar:SetValue(cur)

    local fr, fg, fb
    local fc = _G.FACTION_BAR_COLORS and _G.FACTION_BAR_COLORS[reaction]
    if fc then
        fr, fg, fb = fc.r, fc.g, fc.b
    else
        fr, fg, fb = F.Theme.GetAccent()
    end
    ApplyHorizBarColor(repBar, { Clamp01(fr * 0.74), Clamp01(fg * 0.74), Clamp01(fb * 0.74) }, { fr, fg, fb }, 1)

    repLeft:SetText(name)
    if isMaxed then
        repRight:SetText("已满级 |cff9aa6b8(100%)|r")
    else
        repRight:SetText(string_format("%s / %s |cff9aa6b8(%.1f%%)|r", FormatComma(cur), FormatComma(span), cur / span * 100))
    end
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
    xpFrame = CreateFrame("Frame", "kkowoUI_XPBar", _G.UIParent)
    xpFrame:SetFrameStrata("LOW")
    xpFrame:EnableMouse(true)

    BuildPillTrack(xpFrame)

    -- 3 段均匀高斯背光晕（位于暗玻底槽之后，仅贴合已填充进度与可交任务段）
    fx.questBloom = CreateThreeSliceGlow(xpFrame, "BACKGROUND", -8)
    fx.xpBloom = CreateThreeSliceGlow(xpFrame, "BACKGROUND", -7)

    restedBar = CreateFrame("StatusBar", nil, xpFrame)
    restedBar:SetAllPoints(xpFrame)
    restedBar:SetStatusBarTexture(F.Theme.FLAT_TEX)
    restedBar._texBound = true
    AttachMask(restedBar.GetStatusBarTexture and restedBar:GetStatusBarTexture(), xpFrame._pillMask, xpFrame)

    questBar = CreateFrame("StatusBar", nil, xpFrame)
    questBar:SetAllPoints(xpFrame)
    questBar:SetFrameLevel(restedBar:GetFrameLevel() + 1)
    questBar:SetStatusBarTexture(F.Theme.FLAT_TEX)
    questBar._texBound = true
    AttachMask(questBar.GetStatusBarTexture and questBar:GetStatusBarTexture(), xpFrame._pillMask, xpFrame)

    xpBar = CreateFrame("StatusBar", nil, xpFrame)
    xpBar:SetAllPoints(xpFrame)
    xpBar:SetFrameLevel(questBar:GetFrameLevel() + 1)
    xpBar:SetStatusBarTexture(F.Theme.FLAT_TEX)
    xpBar._texBound = true
    AttachMask(xpBar.GetStatusBarTexture and xpBar:GetStatusBarTexture(), xpFrame._pillMask, xpFrame)

    local ov = CreateFrame("Frame", nil, xpFrame)
    ov:SetAllPoints()
    ov:SetFrameLevel(xpBar:GetFrameLevel() + 2)

    -- 9 宫格轻透圆角玻璃细边
    xpFrame._glassRim = CreatePillRim(ov, xpFrame)

    -- 经验进度与可交任务之间的 1px 柔和暗色分隔线
    fx.questSeam = ov:CreateTexture(nil, "ARTWORK", nil, 2)
    fx.questSeam:SetWidth(1)
    fx.questSeam:SetColorTexture(0.04, 0.05, 0.08, 0.55)
    fx.questSeam:Hide()

    -- 可选 10% 极细刻度线（默认关闭，保持纯净通透条）
    xpFrame._ticks = {}
    for idx = 1, 9 do
        local tk = ov:CreateTexture(nil, "ARTWORK", nil, 3)
        tk:SetWidth(1)
        tk:Hide()
        xpFrame._ticks[idx] = tk
    end

    -- 获得经验时的克制闪光脉冲（与圆角遮罩对齐）
    xpPulse = ov:CreateTexture(nil, "ARTWORK", nil, 4)
    xpPulse:SetAllPoints(xpFrame)
    xpPulse:SetTexture(F.Theme.FLAT_TEX)
    xpPulse:SetBlendMode("ADD")
    xpPulse:SetAlpha(0)
    AttachMask(xpPulse, xpFrame._pillMask, xpFrame)
    xpPulse:Hide()

    xpPulseAG = xpPulse:CreateAnimationGroup()
    local pIn = xpPulseAG:CreateAnimation("Alpha")
    pIn:SetOrder(1)
    pIn:SetFromAlpha(0)
    pIn:SetToAlpha(0.24)
    pIn:SetDuration(0.10)
    pIn:SetSmoothing("OUT")
    local pOut = xpPulseAG:CreateAnimation("Alpha")
    pOut:SetOrder(2)
    pOut:SetFromAlpha(0.24)
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

    -- 左侧一体化简约职业徽印 + 紧致等级 + 清透柔光装等
    emblemFrame = CreateFrame("Frame", nil, xpFrame)
    emblemFrame:SetSize(42, 50)
    emblemFrame:SetFrameLevel(textLayer:GetFrameLevel() + 1)
    emblemFrame:EnableMouse(false)

    emblemIconTex = emblemFrame:CreateTexture(nil, "ARTWORK")
    emblemIconTex:SetSize(32, 32)
    emblemIconTex:SetAlpha(0.90)

    emblemLevelFS = emblemFrame:CreateFontString(nil, "OVERLAY")
    emblemLevelFS:SetJustifyH("RIGHT")
    emblemLevelFS:SetWordWrap(false)

    emblemIlvlFS = emblemFrame:CreateFontString(nil, "OVERLAY")
    emblemIlvlFS:SetJustifyH("CENTER")
    emblemIlvlFS:SetWordWrap(false)

    -- 等级 / 装等数字背后的克制柔光晕
    levelHalo = emblemFrame:CreateTexture(nil, "ARTWORK", nil, 6)
    levelHalo:SetTexture(SOFT_GLOW_TEX)
    levelHalo:SetBlendMode("ADD")
    levelHalo:SetPoint("CENTER", emblemLevelFS, "CENTER", 0, 0)
    levelHalo:Hide()

    ilvlHalo = emblemFrame:CreateTexture(nil, "ARTWORK", nil, 6)
    ilvlHalo:SetTexture(SOFT_GLOW_TEX)
    ilvlHalo:SetBlendMode("ADD")
    ilvlHalo:SetPoint("CENTER", emblemIlvlFS, "CENTER", 0, 0)
    ilvlHalo:Hide()

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
    xpHitBox:HookScript("OnHide", function()
        if not hitDragging then return end
        hitDragging = false
        if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            xpFrame:StopMovingOrSizing()
        end
    end)
    xpHitBox:SetScript("OnMouseUp", function(self, btn)
        if btn == "RightButton" and not hitDragging then
            ResetXPSession(false)
            UpdateXP()
            if isUnitHovered then
                ShowXPTooltip(self)
            end
        end
    end)
    xpHitBox:SetScript("OnEnter", function(self)
        isUnitHovered = true
        SyncUnifiedHoverVisual()
        ShowXPTooltip(self)
    end)
    xpHitBox:SetScript("OnLeave", function()
        isUnitHovered = false
        SyncUnifiedHoverVisual()
        GameTooltip:Hide()
    end)

    F.Mover.Register({
        key = "XPBar",
        label = "经验条",
        frame = xpFrame,
        order = 15,
        -- 默认贴屏幕顶部视觉居中（计入左侧职业徽印宽度偏移，确保整体视觉中轴与屏幕中线对齐）
        defaultPoint = "TOP",
        defaultRelPoint = "TOP",
        defaultX = 25,
        defaultY = -36,
        -- 告知 EUI 解锁模式包含左侧徽印与上下方文字的真实视觉包围盒，居中吸附时严格按整体视觉中心对齐
        getInsets = function()
            local db = mod:GetDB()
            local fsSize = math_max(9, math_min(18, F.PlainNumber(db.fontSize, 12) or 12))
            local pctSize = math_max(12, fsSize + 2)
            local subSize = math_max(10, fsSize - 1)
            local h = math_max(6, math_min(14, F.PlainNumber(db.height, 7) or 7))
            local showEmblem = db.showEmblem ~= false
            local showBottom = db.showBottomStats ~= false
            local iconSz = math_max(28, math_min(34, h + pctSize + 10))
            local leftExt = showEmblem and (math_max(40, iconSz + 6) + 9) or 0
            local topExt = 6 + pctSize + (db.showTopTimers and (subSize + 6) or 2)
            local botExt = (showBottom or showEmblem) and (math_max(subSize, 12) + 8) or 2
            return -leftExt, 0, -topExt, -botExt
        end,
    })

    updateXPFade = F.Theme.AttachCombatFade(xpFrame, function()
        return mod:GetDB().combatFade == true
    end, nil, nil, xpHitBox)

    -- 同款圆角暗玻声望条
    repFrame = CreateFrame("Frame", "kkowoUI_RepBar", _G.UIParent)
    repFrame:SetFrameStrata("LOW")
    BuildPillTrack(repFrame)

    repBar = CreateFrame("StatusBar", nil, repFrame)
    repBar:SetAllPoints(repFrame)
    repBar:SetStatusBarTexture(F.Theme.FLAT_TEX)
    repBar._texBound = true
    AttachMask(repBar.GetStatusBarTexture and repBar:GetStatusBarTexture(), repFrame._pillMask, repFrame)

    local repTextLayer = CreateFrame("Frame", nil, repFrame)
    repTextLayer:SetAllPoints()
    repTextLayer:SetFrameLevel(repBar:GetFrameLevel() + 2)
    repFrame._glassRim = CreatePillRim(repTextLayer, repFrame)
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
        getInsets = function()
            local db = mod:GetDB()
            local fsSize = math_max(9, math_min(18, F.PlainNumber(db.fontSize, 12) or 12))
            return 0, 0, -(fsSize + 7), 0
        end,
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
    if not db.v8SleekPillXP then
        db.v8SleekPillXP = true
        if db.height == 10 then
            db.height = 7
        end
    end

    questXPDirty = true
    lastRenderedXP = nil
    lastRenderedLevel = nil
    CreateFrames()
    ApplyVisuals()
    UpdateXP()
    UpdateRep()
    if updateXPFade then updateXPFade(ThemeCombatAlpha()) end
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
        text = "经验条配色主题",
        tooltip = "选择经验条与可交任务段的配色方案，可跟随当前职业色。",
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
        text = "显示职业徽印",
        tooltip = "在经验条左侧显示职业图标、角色等级与当前平均装等。",
        getValue = function() return db.showEmblem ~= false end,
        setValue = function(v) db.showEmblem = v == true; self:Refresh() end,
    }, {
        type = "dropdown",
        text = "职业图标风格",
        tooltip = "切换经验条左侧职业图标风格，可选现代、纹章或原版样式。",
        values = ICON_STYLE_VALUES,
        order = ICON_STYLE_ORDER,
        getValue = function() return db.iconStyle or "glyph" end,
        setValue = function(v) db.iconStyle = v; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "叠加任务经验",
        tooltip = "在经验条上预览已完成任务的总经验及交任务后的进度。",
        getValue = function() return db.showQuestXP ~= false end,
        setValue = function(v) db.showQuestXP = v == true; self:Refresh() end,
    }, {
        type = "toggle",
        text = "下方升级汇总",
        tooltip = "条下显示升级预计、速率与双倍统计，关闭则切换极简模式。",
        getValue = function() return db.showBottomStats ~= false end,
        setValue = function(v) db.showBottomStats = v == true; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示独立声望条",
        getValue = function() return db.showRepBar == true end,
        setValue = function(v) db.showRepBar = v == true; self:Refresh() end,
    }, {
        type = "toggle",
        text = "满级自动隐藏",
        getValue = function() return db.hideAtMaxLevel ~= false end,
        setValue = function(v) db.hideAtMaxLevel = v == true; self:Refresh() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "战斗中自动淡出",
        getValue = function() return db.combatFade == true end,
        setValue = function(v) db.combatFade = v == true; self:Refresh() end,
    }, {
        type = "button",
        text = "重置经验速率",
        noCapture = true,
        tooltip = "清零本次在线经验速率并重新计时，也可右键点击经验条重置。",
        onClick = function()
            ResetXPSession(false)
            UpdateXP()
        end,
    })
    y = y - h

    local function buildAdv(w, p, curY, blk)
        local _, rh
        _, rh = w:DualRow(p, curY, {
            type = "slider",
            text = "经验条宽度 (px)",
            min = 260, max = 680, step = 10,
            getValue = function() return db.width or 430 end,
            setValue = function(v) db.width = v; self:Refresh() end,
        }, {
            type = "slider",
            text = "经验条高度 (px)",
            min = 5, max = 18, step = 1,
            getValue = function() return db.height or 7 end,
            setValue = function(v) db.height = v; self:Refresh() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "slider",
            text = "文字大小 (px)",
            min = 10, max = 16, step = 1,
            getValue = function() return db.fontSize or 11 end,
            setValue = function(v) db.fontSize = v; self:Refresh() end,
        }, {
            type = "toggle",
            text = "显示等分刻度",
            tooltip = "在经验条上绘制 10% 等分刻度线，默认关闭。",
            getValue = function() return db.showTicks == true end,
            setValue = function(v) db.showTicks = v == true; self:Refresh() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "获经验闪光",
            tooltip = "获得经验时在经验条上显示简短闪光提示。",
            getValue = function() return db.showGlow ~= false end,
            setValue = function(v) db.showGlow = v == true; self:Refresh() end,
        }, {
            type = "toggle",
            text = "进度条浅发光",
            tooltip = "为经验条进度与左侧等级装等数字添加柔和光晕。",
            getValue = function() return db.softGlow ~= false end,
            setValue = function(v) db.softGlow = v == true; self:Refresh() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "显示升级耗时",
            tooltip = "在条上额外显示本级与本次耗时，关闭后悬停仍可查看。",
            getValue = function() return db.showTopTimers == true end,
            setValue = function(v) db.showTopTimers = v == true; self:Refresh() end,
        }, blk)
        curY = curY - rh
        return curY
    end

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("xpBar", W, parent, y, buildAdv, blank)
    else
        y = buildAdv(W, parent, y, blank)
    end
    return y
end
