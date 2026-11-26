----------------------------------------------------------------------
--  kkowoUI — Modules/Durability.lua
--  现代一体化「核心属性 + 装备耐久」面板（无缝替代 EUI 杂乱彩虹次要属性文本）
--    • 锚定在 EUI_SecondaryStats 原位（完全支持 EUI 解锁模式直接拖动，零额外占位）
--    • 自动按职业精选核心属性：
--        猎人：远程攻强 / 远程暴击 / 远程命中 / 远程攻速 / 移动速度 / 装备耐久
--        近战：攻击强度 / 近战暴击 / 近战命中 / 护甲 / 移动速度 / 装备耐久
--        法系：法术强度 / 法术暴击 / 法术命中 / 5秒回蓝 / 移动速度 / 装备耐久
--    • 统一暗色微透玻璃卡片（可选透明无底板）+ 左右两端对齐等宽数字 + 职业色 1px 顶线
--    • 悬停整个面板即可查看全身各部位耐久明细与预计修理费
--    • 全程 12.x 保密值防护（PlainNumber / PlainString + 战斗末次干净值缓存），零污染
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, pcall, select, type, tostring =
    ipairs, math.floor, math.max, pcall, select, type, tostring
local setmetatable = setmetatable
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = _G.GameTooltip
local WorldFrame = _G.WorldFrame

local mod = F.RegisterModule("durability", {
    title = "核心属性与装备耐久面板",
    desc = "将角色核心属性与装备耐久融为一体：默认纯透明无边框清爽呈现（可自由调底板透明度）、全职业智能综合，悬停看全身耐久与修理费。",
    group = "utility",
    order = 20,
    defaults = {
        enabled = true,
        unifiedPanel = true,       -- true = 一体化现代属性+耐久面板；false = 仅在 EUI 原次要属性下追加耐久行
        statPreset = "smart",      -- "smart" | "classic" | "ranged" | "melee" | "caster"
        showBackdrop = true,       -- 默认开启现代清透圆角玻璃卡片（与整体圆角 UI 风格统一）
        backdropAlpha = 0.36,      -- 清透微熏玻璃透明度（0.00 纯透明 ~ 0.85 深色，推荐 0.36）
        showTopLine = true,        -- 顶部极细职业/主题色流光点缀线
        v2TransparentMigrated = false,
        v3GlassCardMigrated = false,
        useAverage = false,
        flashOnStatGain = true,    -- 触发增益 Buff 导致属性提升时数值短暂高亮闪烁
        alignLabel = "攻击强度: ",
    },
})

local STATS_FRAME_NAME = "EUI_SecondaryStats"
local DEFAULT_ROW_GAP = 3
local CARD_WIDTH = 172
local ROW_HEIGHT = 18

local SLOTS = {
    { 1,  _G.HEADSLOT or "头部" },
    { 3,  _G.SHOULDERSLOT or "肩部" },
    { 5,  _G.CHESTSLOT or "胸部" },
    { 9,  _G.WRISTSLOT or "护腕" },
    { 10, _G.HANDSSLOT or "手部" },
    { 6,  _G.WAISTSLOT or "腰部" },
    { 7,  _G.LEGSSLOT or "腿部" },
    { 8,  _G.FEETSLOT or "脚部" },
    { 16, _G.MAINHANDSLOT or "主手" },
    { 17, _G.SECONDARYHANDSLOT or "副手" },
    { 18, _G.RANGEDSLOT or "远程" },
}

local cardFrame = nil
local cardRows = {}
local legacyRowFrame = nil
local scanTip = nil
local hookedStats = setmetatable({}, { __mode = "k" })
local lastCleanStat = {}
local euiHideHooked = false
local speedTicker = nil

local function DurabilityColor(pct)
    if pct <= 0.10 then
        return 1.00, 0.30, 0.34
    elseif pct <= 0.30 then
        return 1.00, 0.58, 0.22
    elseif pct <= 0.60 then
        return 0.96, 0.82, 0.30
    end
    return 0.37, 0.86, 0.62
end

local durCachePct, durCacheBroken, durDirty = nil, false, true

local function CollectDurability(needDetails)
    if not _G.GetInventoryItemDurability then
        return nil
    end
    local sumCur, sumMax = 0, 0
    local lowest, broken = nil, false
    local details = needDetails and {} or nil
    for _, s in ipairs(SLOTS) do
        local ok, cur, max = pcall(_G.GetInventoryItemDurability, s[1])
        cur = ok and F.PlainNumber(cur, nil) or nil
        max = ok and F.PlainNumber(max, nil) or nil
        if cur and max and max > 0 then
            local ratio = cur / max
            sumCur = sumCur + cur
            sumMax = sumMax + max
            if not lowest or ratio < lowest then lowest = ratio end
            if cur == 0 then broken = true end
            if details then
                details[#details + 1] = { slot = s[1], name = s[2], cur = cur, max = max, ratio = ratio }
            end
        end
    end
    if sumMax == 0 then
        durCachePct, durCacheBroken, durDirty = nil, false, false
        return nil
    end
    local pct = mod:GetDB().useAverage and (sumCur / sumMax) or lowest
    durCachePct, durCacheBroken, durDirty = pct, broken, false
    return pct, broken, details
end

local function GetCachedDurability()
    if durDirty then
        return CollectDurability(false)
    end
    return durCachePct, durCacheBroken
end

local function GetSlotRepairCost(slotId)
    local C_TooltipInfo = _G.C_TooltipInfo
    if C_TooltipInfo and C_TooltipInfo.GetInventoryItem then
        local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", slotId)
        if ok and type(data) == "table" then
            local cost = F.PlainNumber(data.repairCost, nil)
            if cost then
                return cost
            end
        end
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "kkowoUI_DurabilityScanTip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    local ok, _, _, cost = pcall(scanTip.SetInventoryItem, scanTip, "player", slotId)
    scanTip:Hide()
    if ok then
        return F.PlainNumber(cost, 0)
    end
    return 0
end

local function FormatMoney(copper)
    local C_CurrencyInfo = _G.C_CurrencyInfo
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        return C_CurrencyInfo.GetCoinTextureString(copper)
    end
    if _G.GetCoinTextureString then
        return _G.GetCoinTextureString(copper)
    end
    return tostring(copper)
end

local function ShowDurabilityTooltip(owner)
    local _, _, details = CollectDurability(true)
    if not details then return end
    GameTooltip:SetOwner(owner, "ANCHOR_TOPRIGHT", 6, 0)
    GameTooltip:SetText("核心属性与装备耐久", 1, 1, 1)
    local totalCost = 0
    for _, d in ipairs(details) do
        local r, g, b = DurabilityColor(d.ratio)
        GameTooltip:AddDoubleLine(
            d.name,
            string_format("%d%%  (%d/%d)", math_floor(d.ratio * 100 + 0.5), d.cur, d.max),
            0.78, 0.81, 0.86,
            r, g, b
        )
        if d.cur < d.max then
            totalCost = totalCost + GetSlotRepairCost(d.slot)
        end
    end
    if totalCost > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("预计修理费", FormatMoney(totalCost), 0.96, 0.80, 0.30, 1, 1, 1)
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("所有装备均处于完好状态", 0.37, 0.86, 0.62)
    end
    GameTooltip:AddLine("在 EUI 解锁模式中拖动「次要属性」即可移动本面板", 0.56, 0.60, 0.66)
    GameTooltip:Show()
end

----------------------------------------------------------------------
--  12.x 安全属性采集（战斗中被保密时自动沿用上次干净值，绝不报错或闪烁）
----------------------------------------------------------------------
local function SafeSum(...)
    local total = 0
    for i = 1, select("#", ...) do
        local v = F.PlainNumber(select(i, ...), nil)
        if v == nil then return nil end
        total = total + v
    end
    return total
end

local function ReadCachedStat(key, getter)
    local ok, val = pcall(getter)
    val = ok and F.PlainNumber(val, nil) or nil
    if val ~= nil then
        lastCleanStat[key] = val
        return val
    end
    return lastCleanStat[key]
end

local STAT_GETTERS = {
    rap = {
        label = "远程攻强",
        fmt = function(v) return string_format("%.0f", v) end,
        tone = "accent",
        get = function()
            if not _G.UnitRangedAttackPower then return nil end
            return SafeSum(_G.UnitRangedAttackPower("player"))
        end,
    },
    rcrit = {
        label = "远程暴击",
        fmt = function(v) return string_format("%.2f%%", v) end,
        tone = "warm",
        get = function()
            return _G.GetRangedCritChance and _G.GetRangedCritChance() or nil
        end,
    },
    rhit = {
        label = "远程命中",
        fmt = function(v) return string_format("%.2f%%", v) end,
        tone = "clean",
        get = function()
            local cr = _G.CR_HIT_RANGED or _G.CR_HIT_MELEE
            local bonus = (cr and _G.GetCombatRatingBonus and _G.GetCombatRatingBonus(cr)) or 0
            local modHit = (_G.GetHitModifier and _G.GetHitModifier()) or 0
            return SafeSum(bonus, modHit)
        end,
    },
    rspeed = {
        label = "远程攻速",
        fmt = function(v) return string_format("%.2fs", v) end,
        tone = "muted",
        get = function()
            if not _G.UnitRangedDamage then return nil end
            local spd = _G.UnitRangedDamage("player")
            spd = F.PlainNumber(spd, nil)
            if spd and spd > 0 then return spd end
            return nil
        end,
    },
    ap = {
        label = "攻击强度",
        fmt = function(v) return string_format("%.0f", v) end,
        tone = "accent",
        get = function()
            if not _G.UnitAttackPower then return nil end
            return SafeSum(_G.UnitAttackPower("player"))
        end,
    },
    mcrit = {
        label = "近战暴击",
        fmt = function(v) return string_format("%.2f%%", v) end,
        tone = "warm",
        get = function()
            return _G.GetCritChance and _G.GetCritChance() or nil
        end,
    },
    mhit = {
        label = "近战命中",
        fmt = function(v) return string_format("%.2f%%", v) end,
        tone = "clean",
        get = function()
            local bonus = (_G.CR_HIT_MELEE and _G.GetCombatRatingBonus and _G.GetCombatRatingBonus(_G.CR_HIT_MELEE)) or 0
            local modHit = (_G.GetHitModifier and _G.GetHitModifier()) or 0
            return SafeSum(bonus, modHit)
        end,
    },
    armor = {
        label = "护甲值",
        fmt = function(v) return string_format("%.0f", v) end,
        tone = "muted",
        get = function()
            if not _G.UnitArmor then return nil end
            return select(2, _G.UnitArmor("player"))
        end,
    },
    sp = {
        label = "法术强度",
        fmt = function(v) return string_format("%.0f", v) end,
        tone = "accent",
        get = function()
            local best = 0
            if _G.GetSpellBonusDamage then
                for i = 2, 7 do
                    local v = F.PlainNumber(_G.GetSpellBonusDamage(i), nil)
                    if v == nil then return nil end
                    if v > best then best = v end
                end
            end
            if _G.GetSpellBonusHealing then
                local h = F.PlainNumber(_G.GetSpellBonusHealing(), nil)
                if h and h > best then best = h end
            end
            return best
        end,
    },
    scrit = {
        label = "法术暴击",
        fmt = function(v) return string_format("%.2f%%", v) end,
        tone = "warm",
        get = function()
            if not _G.GetSpellCritChance then return nil end
            local best = nil
            for i = 2, 7 do
                local ok, v = pcall(_G.GetSpellCritChance, i)
                v = ok and F.PlainNumber(v, nil) or nil
                if v and (not best or v > best) then best = v end
            end
            if best ~= nil then return best end
            local ok, v = pcall(_G.GetSpellCritChance)
            return ok and F.PlainNumber(v, nil) or nil
        end,
    },
    shit = {
        label = "法术命中",
        fmt = function(v) return string_format("%.2f%%", v) end,
        tone = "clean",
        get = function()
            local bonus = (_G.CR_HIT_SPELL and _G.GetCombatRatingBonus and _G.GetCombatRatingBonus(_G.CR_HIT_SPELL)) or 0
            local modHit = (_G.GetSpellHitModifier and _G.GetSpellHitModifier()) or 0
            return SafeSum(bonus, modHit)
        end,
    },
    mp5 = {
        label = "5秒回蓝",
        fmt = function(v) return string_format("%.0f", v) end,
        tone = "muted",
        get = function()
            if not _G.GetManaRegen then return nil end
            local base = F.PlainNumber(_G.GetManaRegen(), nil)
            return base and math_floor(base * 5 + 0.5) or nil
        end,
    },
    movespeed = {
        label = "移动速度",
        fmt = function(v) return string_format("%.0f%%", v) end,
        tone = "speed",
        get = function()
            if not _G.GetUnitSpeed then return nil end
            local cur, run, flight, swim = _G.GetUnitSpeed("player")
            cur = F.PlainNumber(cur, nil)
            run = F.PlainNumber(run, nil)
            flight = F.PlainNumber(flight, nil)
            swim = F.PlainNumber(swim, nil)
            local spd
            if _G.IsFlying and _G.IsFlying() and flight and flight > 0 then
                spd = flight
            elseif _G.IsSwimming and _G.IsSwimming() and swim and swim > 0 then
                spd = swim
            else
                spd = (cur and cur > 0) and cur or run or cur
            end
            if not spd then return nil end
            return math_floor(spd / 7 * 100 + 0.5)
        end,
    },
}

local PRESETS = {
    classic = { "ap", "mcrit", "mhit", "sp", "scrit", "shit", "movespeed" },
    ranged  = { "rap", "rcrit", "rhit", "rspeed", "movespeed" },
    melee   = { "ap", "mcrit", "mhit", "armor", "movespeed" },
    caster  = { "sp", "scrit", "shit", "mp5", "movespeed" },
}

local SMART_CASTER = { "sp", "scrit", "shit", "mp5", "movespeed" }
local SMART_HYBRID = { "ap", "mcrit", "sp", "scrit", "mhit", "shit", "movespeed" }
local smartKeyBuf = {}
local frameStatCache = {}

-- 全职业智能综合（专为《魔兽世界：无限》多流派/混伤环境优化，不偏科单一远程）
local function BuildSmartStatKeys()
    local cls = F.GetPlayerClass()
    if cls == "MAGE" or cls == "WARLOCK" or cls == "PRIEST" then
        return SMART_CASTER
    elseif cls == "PALADIN" or cls == "SHAMAN" or cls == "DRUID" then
        return SMART_HYBRID
    end

    local spVal = ReadCachedStat("sp", STAT_GETTERS.sp.get)
    local rapVal = ReadCachedStat("rap", STAT_GETTERS.rap.get)
    local rspd = ReadCachedStat("rspeed", STAT_GETTERS.rspeed.get)
    frameStatCache.sp = spVal
    frameStatCache.rap = rapVal
    frameStatCache.rspeed = rspd

    for i = #smartKeyBuf, 1, -1 do smartKeyBuf[i] = nil end
    if cls == "HUNTER" then
        -- 猎人：兼顾远程主力 + 近战织击，身上有法伤装备/附魔时自动补全法强与法暴
        smartKeyBuf[1] = "rap"
        smartKeyBuf[2] = "ap"
        smartKeyBuf[3] = "rcrit"
        smartKeyBuf[4] = "mcrit"
        smartKeyBuf[5] = "rhit"
        local idx = 5
        if (spVal or 0) > 0 then
            idx = idx + 1; smartKeyBuf[idx] = "sp"
            idx = idx + 1; smartKeyBuf[idx] = "scrit"
        elseif rspd and rspd > 0 then
            idx = idx + 1; smartKeyBuf[idx] = "rspeed"
        end
        smartKeyBuf[idx + 1] = "movespeed"
        return smartKeyBuf
    else
        -- 战士 / 盗贼等物理职业：展示近战核心 + 护甲，若有远程武器/法伤装自动适配
        local hasRanged = (rspd ~= nil and rspd > 0 and (rapVal or 0) > 0)
        smartKeyBuf[1] = "ap"
        smartKeyBuf[2] = "mcrit"
        smartKeyBuf[3] = "mhit"
        local idx = 4
        if hasRanged and cls ~= "WARRIOR" and cls ~= "ROGUE" then
            smartKeyBuf[idx] = "rap"
        else
            smartKeyBuf[idx] = "armor"
        end
        if (spVal or 0) > 0 then
            idx = idx + 1; smartKeyBuf[idx] = "sp"
        end
        smartKeyBuf[idx + 1] = "movespeed"
        return smartKeyBuf
    end
end

local function ResolveStatKeys()
    frameStatCache.sp = nil
    frameStatCache.rap = nil
    frameStatCache.rspeed = nil
    local preset = mod:GetDB().statPreset or "smart"
    if preset == "auto" or preset == "smart" then
        return BuildSmartStatKeys()
    end
    if PRESETS[preset] then
        return PRESETS[preset]
    end
    return BuildSmartStatKeys()
end

local function ToneColor(tone)
    local ar, ag, ab = F.Theme.GetAccent()
    if tone == "accent" then
        return ar, ag, ab
    elseif tone == "warm" then
        return 0.96, 0.86, 0.56
    elseif tone == "speed" then
        return 0.62, 0.90, 0.78
    elseif tone == "muted" then
        return 0.84, 0.87, 0.92
    end
    return 0.94, 0.95, 0.97
end

local refTextCache = setmetatable({}, { __mode = "k" })

local function FindStatsFontString(stats)
    if not (stats and stats.GetRegions) then return nil end
    local cached = refTextCache[stats]
    if cached and cached.GetParent and cached:GetParent() == stats then
        return cached
    end
    for _, region in ipairs({ stats:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "FontString" then
            refTextCache[stats] = region
            return region
        end
    end
    return nil
end

local UpdateAll
local ScheduleUpdate

local function OnStatsFrameChange()
    if not mod._active then return end
    ScheduleUpdate()
end

local function HookStatsFrame(stats)
    if not stats or hookedStats[stats] then
        return
    end
    hookedStats[stats] = true
    if stats.HookScript then
        pcall(stats.HookScript, stats, "OnShow", OnStatsFrameChange)
        pcall(stats.HookScript, stats, "OnHide", OnStatsFrameChange)
        pcall(stats.HookScript, stats, "OnSizeChanged", OnStatsFrameChange)
    end
end

local function EnsureCard(parent)
    if cardFrame then
        if cardFrame:GetParent() ~= parent then
            cardFrame:SetParent(parent)
        end
        return cardFrame
    end
    cardFrame = CreateFrame("Frame", "kkowoUI_StatsCard", parent)
    cardFrame:SetSize(CARD_WIDTH, 120)
    cardFrame:SetFrameLevel((parent:GetFrameLevel() or 2) + 3)
    if cardFrame.SetMouseMotionEnabled then
        cardFrame:SetMouseMotionEnabled(true)
        cardFrame:SetMouseClickEnabled(false)
    else
        cardFrame:EnableMouse(true)
    end

    local glassBg = cardFrame:CreateTexture(nil, "BACKGROUND", nil, -6)
    glassBg:SetAllPoints(cardFrame)
    glassBg:SetColorTexture(0.042, 0.048, 0.066, 0.36)
    cardFrame._glassBg = glassBg

    local glassSheen = cardFrame:CreateTexture(nil, "BACKGROUND", nil, -5)
    glassSheen:SetPoint("TOPLEFT", cardFrame, "TOPLEFT", 0, 0)
    glassSheen:SetPoint("TOPRIGHT", cardFrame, "TOPRIGHT", 0, 0)
    glassSheen:SetHeight(26)
    glassSheen:SetTexture(F.Theme.FLAT_TEX)
    if F.StyleTokens then
        F.StyleTokens.ApplyGradient(glassSheen, "VERTICAL", 1, 1, 1, 0.00, 1, 1, 1, 0.055)
    else
        glassSheen:SetVertexColor(1, 1, 1, 0.03)
    end
    cardFrame._glassSheen = glassSheen

    local topLine = cardFrame:CreateTexture(nil, "OVERLAY")
    topLine:SetHeight(2)
    topLine:SetPoint("TOPLEFT", cardFrame, "TOPLEFT", 10, -1)
    topLine:SetPoint("TOPRIGHT", cardFrame, "TOPRIGHT", -10, -1)
    cardFrame._topLine = topLine

    local divider = cardFrame:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetColorTexture(1, 1, 1, 0.09)
    cardFrame._divider = divider

    -- 底部装备耐久微型圆角进度条（直观呈现当前最低/平均耐久健康度）
    local durBarBg = cardFrame:CreateTexture(nil, "ARTWORK", nil, 1)
    durBarBg:SetHeight(3)
    durBarBg:SetColorTexture(1, 1, 1, 0.10)
    durBarBg:Hide()
    cardFrame._durBarBg = durBarBg

    local durBarFill = cardFrame:CreateTexture(nil, "OVERLAY", nil, 2)
    durBarFill:SetHeight(3)
    durBarFill:SetPoint("TOPLEFT", durBarBg, "TOPLEFT", 0, 0)
    durBarFill:SetPoint("BOTTOMLEFT", durBarBg, "BOTTOMLEFT", 0, 0)
    durBarFill:SetColorTexture(0.32, 0.84, 0.42, 0.92)
    durBarFill:Hide()
    cardFrame._durBarFill = durBarFill

    cardFrame:SetScript("OnEnter", ShowDurabilityTooltip)
    cardFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return cardFrame
end

local function AcquireCardRow(index)
    local row = cardRows[index]
    if row then return row end
    row = CreateFrame("Frame", nil, cardFrame)
    row:SetHeight(ROW_HEIGHT)

    local zebra = row:CreateTexture(nil, "BACKGROUND", nil, -2)
    zebra:SetPoint("TOPLEFT", row, "TOPLEFT", -4, 0)
    zebra:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 4, 0)
    zebra:SetColorTexture(1, 1, 1, 0.032)
    if F.StyleTokens then F.StyleTokens.MaskTexture(row, zebra, 4) end
    zebra:Hide()
    row._zebra = zebra

    local dot = row:CreateTexture(nil, "ARTWORK")
    dot:SetSize(4, 4)
    dot:SetPoint("LEFT", row, "LEFT", 0, 0)
    dot:SetTexture(F.StyleTokens and F.StyleTokens.TEX.CIRCLE_MASK or F.Theme.FLAT_TEX)
    row._dot = dot

    local lbl = row:CreateFontString(nil, "OVERLAY")
    lbl:SetPoint("LEFT", dot, "RIGHT", 6, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    row._label = lbl

    local val = row:CreateFontString(nil, "OVERLAY")
    val:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    val:SetJustifyH("RIGHT")
    val:SetWordWrap(false)
    row._value = val

    cardRows[index] = row
    return row
end

local function RenderUnifiedPanel(stats, refText)
    if legacyRowFrame then legacyRowFrame:Hide() end
    local db = mod:GetDB()
    local card = EnsureCard(stats)

    -- 静音 EUI 原本的杂色多行文本，保留 EUI_SecondaryStats 容器与解锁模式拖动锚点
    if refText and refText.SetAlpha then
        refText:SetAlpha(0)
    end

    local ST = F.StyleTokens
    local ar, ag, ab = F.Theme.GetAccent()
    local bgAlpha = (db.showBackdrop == false) and 0 or (F.PlainNumber(db.backdropAlpha, 0.36) or 0.36)
    if bgAlpha < 0 then bgAlpha = 0 elseif bgAlpha > 0.85 then bgAlpha = 0.85 end
    local showBg = bgAlpha >= 0.03
    local padX = showBg and 11 or 2
    local padTop = showBg and 9 or 2
    local padBot = showBg and 8 or 2
    local fontOutline = (bgAlpha < 0.24) and "OUTLINE" or ""
    local rad = ST and ST.GetCornerRadius(8) or 8

    local chromeSig = string_format("%.2f:%d:%d:%d:%.2f:%.2f:%.2f:%s",
        bgAlpha, showBg and 1 or 0, db.showTopLine ~= false and 1 or 0, rad, ar, ag, ab, fontOutline)
    local chromeDirty = (card._chromeSig ~= chromeSig)
    if chromeDirty then
        card._chromeSig = chromeSig
        if card._fuiBg then card._fuiBg:Hide() end
        if card._fuiBorders then
            for _, ln in ipairs(card._fuiBorders) do ln:Hide() end
        end
        if showBg then
            card._glassBg:SetColorTexture(0.042, 0.048, 0.066, bgAlpha)
            card._glassBg:Show()
            card._glassSheen:Show()
            if ST then
                ST.MaskTexture(card, card._glassBg, rad)
                ST.MaskTexture(card, card._glassSheen, rad)
                ST.ApplyRoundedBorder(card, rad, 0.20, 0.24, 0.32, math_max(0.42, bgAlpha * 1.15), 5)
            end
            if db.showTopLine ~= false then
                card._topLine:SetColorTexture(ar, ag, ab, 0.72)
                if ST then ST.MaskTexture(card, card._topLine, 2) end
                card._topLine:Show()
            else
                card._topLine:Hide()
            end
        else
            card._glassBg:Hide()
            card._glassSheen:Hide()
            if ST then ST.ClearRoundedMask(card) end
            card._topLine:Hide()
        end
    end

    local keys = ResolveStatKeys()
    local count = 0
    local y = -padTop
    card._speedRow = nil
    card._lastSpeedText = nil

    for _, k in ipairs(keys) do
        local def = STAT_GETTERS[k]
        if def then
            local num = frameStatCache[k]
            if num == nil then
                num = ReadCachedStat(k, def.get)
            end
            -- 远程攻速在没装备弓/枪时自动跳过，避免空行
            if num ~= nil or k ~= "rspeed" then
                count = count + 1
                local row = AcquireCardRow(count)
                if row._lastPadX ~= padX or row._lastY ~= y then
                    row._lastPadX, row._lastY = padX, y
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", card, "TOPLEFT", padX, y)
                    row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -padX, y)
                end
                if chromeDirty or row._lastKey ~= k then
                    row._lastKey = k
                    F.Theme.ApplyFont(row._label, 11, fontOutline, 0.72, 0.76, 0.82, 0.96)
                    local vr, vg, vb = ToneColor(def.tone)
                    F.Theme.ApplyFont(row._value, 12, fontOutline, vr, vg, vb, 1)
                    if fontOutline == "" then
                        row._label:SetShadowColor(0, 0, 0, 0.85); row._label:SetShadowOffset(1, -1)
                        row._value:SetShadowColor(0, 0, 0, 0.90); row._value:SetShadowOffset(1, -1)
                    end
                    if row._dot then row._dot:SetVertexColor(vr, vg, vb, 0.88) end
                    if row._zebra then row._zebra:SetShown(showBg and (count % 2 == 0)) end
                    row._label:SetText(def.label)
                end
                local valText = num ~= nil and def.fmt(num) or "--"
                if row._lastVal ~= valText then
                    local prevNum = row._lastNum
                    row._lastVal = valText
                    row._lastNum = num
                    row._value:SetText(valText)
                    if db.flashOnStatGain ~= false and F.Motion and F.Motion.PlayStatBlink
                        and type(prevNum) == "number" and type(num) == "number" then
                        local gained = (k == "rspeed") and (num < prevNum - 0.02) or (num > prevNum + 0.01)
                        if gained then
                            F.Motion.PlayStatBlink(row._value, 0.36)
                        end
                    end
                elseif num ~= nil and row._lastNum == nil then
                    row._lastNum = num
                end
                if not row:IsShown() then row:Show() end
                if k == "movespeed" then
                    card._speedRow = row
                    card._lastSpeedText = valText
                end
                y = y - ROW_HEIGHT
            end
        end
    end

    -- 装备耐久原生融入同一面板底部，以 1px 细分隔线自然区分（仅耐久变更事件时重扫装备，UNIT_AURA 零扫描）
    local pct, broken = GetCachedDurability()
    if pct ~= nil then
        y = y - 4
        if card._divPadX ~= padX or card._divY ~= y then
            card._divPadX, card._divY = padX, y
            card._divider:ClearAllPoints()
            card._divider:SetPoint("TOPLEFT", card, "TOPLEFT", padX, y + 2)
            card._divider:SetPoint("TOPRIGHT", card, "TOPRIGHT", -padX, y + 2)
        end
        card._divider:SetShown(showBg)
        y = y - 2

        count = count + 1
        local row = AcquireCardRow(count)
        if row._lastPadX ~= padX or row._lastY ~= y then
            row._lastPadX, row._lastY = padX, y
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", card, "TOPLEFT", padX, y)
            row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -padX, y)
        end
        local durValText = broken and "已损坏" or string_format("%d%%", math_floor(pct * 100 + 0.5))
        if chromeDirty or row._lastKey ~= "__dur__" or row._lastVal ~= durValText then
            row._lastKey = "__dur__"
            row._lastVal = durValText
            local dr, dg, dbCol = DurabilityColor(pct)
            F.Theme.ApplyFont(row._label, 11, fontOutline, 0.72, 0.76, 0.82, 0.96)
            F.Theme.ApplyFont(row._value, 12, fontOutline, dr, dg, dbCol, 1)
            if fontOutline == "" then
                row._label:SetShadowColor(0, 0, 0, 0.85); row._label:SetShadowOffset(1, -1)
                row._value:SetShadowColor(0, 0, 0, 0.90); row._value:SetShadowOffset(1, -1)
            end
            if row._dot then row._dot:SetVertexColor(dr, dg, dbCol, 0.95) end
            if row._zebra then row._zebra:Hide() end
            row._label:SetText("装备耐久")
            row._value:SetText(durValText)
        end
        if not row:IsShown() then row:Show() end
        y = y - ROW_HEIGHT
        -- 底部微型圆角耐久健康度进度条
        if card._durBarBg and card._durBarFill then
            local dr, dg, dbCol = DurabilityColor(pct)
            local barW = math_max(40, CARD_WIDTH - padX * 2)
            card._durBarBg:ClearAllPoints()
            card._durBarBg:SetPoint("TOPLEFT", card, "TOPLEFT", padX, y - 1)
            card._durBarBg:SetPoint("TOPRIGHT", card, "TOPRIGHT", -padX, y - 1)
            card._durBarBg:Show()
            card._durBarFill:SetColorTexture(dr, dg, dbCol, 0.90)
            card._durBarFill:SetWidth(math_max(2, math_floor(barW * pct + 0.5)))
            card._durBarFill:Show()
            y = y - 6
        end
    else
        card._divider:Hide()
        if card._durBarBg then card._durBarBg:Hide() end
        if card._durBarFill then card._durBarFill:Hide() end
    end

    for i = count + 1, #cardRows do
        cardRows[i]:Hide()
    end

    local totalH = math_max(24, (-y) + padBot)
    if card._lastH ~= totalH or card._lastHost ~= stats then
        card._lastH = totalH
        card._lastHost = stats
        card:SetSize(CARD_WIDTH, totalH)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", stats, "TOPLEFT", 0, 0)
    end
    if not card:IsShown() then card:Show() end
end

-- 兼容旧模式：保留 EUI 原生属性文本，仅在正下方对齐追加耐久行
local function RenderLegacyDurabilityRow(stats, refText)
    if cardFrame then cardFrame:Hide() end
    if refText and refText.SetAlpha then
        refText:SetAlpha(1)
    end
    local pct, broken = GetCachedDurability()
    if not (pct and stats and refText) then
        if legacyRowFrame then legacyRowFrame:Hide() end
        return
    end
    if not legacyRowFrame then
        legacyRowFrame = CreateFrame("Frame", "kkowoUI_DurabilityRow", stats)
        if legacyRowFrame.SetMouseMotionEnabled then
            legacyRowFrame:SetMouseMotionEnabled(true)
            legacyRowFrame:SetMouseClickEnabled(false)
        else
            legacyRowFrame:EnableMouse(true)
        end
        legacyRowFrame.label = legacyRowFrame:CreateFontString(nil, "OVERLAY")
        legacyRowFrame.label:SetPoint("TOPLEFT", 0, 0)
        legacyRowFrame.label:SetJustifyH("LEFT")
        legacyRowFrame.value = legacyRowFrame:CreateFontString(nil, "OVERLAY")
        legacyRowFrame.value:SetJustifyH("LEFT")
        legacyRowFrame.measure = legacyRowFrame:CreateFontString(nil, "OVERLAY")
        legacyRowFrame.measure:Hide()
        legacyRowFrame:SetScript("OnEnter", ShowDurabilityTooltip)
        legacyRowFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    elseif legacyRowFrame:GetParent() ~= stats then
        legacyRowFrame:SetParent(stats)
    end

    local font, size, flags = refText:GetFont()
    font = F.PlainString(font, nil)
    size = F.PlainNumber(size, 12)
    flags = F.PlainString(flags, "")
    if font then
        pcall(legacyRowFrame.label.SetFont, legacyRowFrame.label, font, size, flags)
        pcall(legacyRowFrame.value.SetFont, legacyRowFrame.value, font, size, flags)
        pcall(legacyRowFrame.measure.SetFont, legacyRowFrame.measure, font, size, flags)
    end
    local sx, sy = refText:GetShadowOffset()
    sx, sy = F.PlainNumber(sx, 0), F.PlainNumber(sy, 0)
    legacyRowFrame.label:SetShadowOffset(sx, sy)
    legacyRowFrame.value:SetShadowOffset(sx, sy)
    local sr, sg, sb, sa = refText:GetShadowColor()
    sr, sg, sb, sa = F.PlainNumber(sr, 0), F.PlainNumber(sg, 0), F.PlainNumber(sb, 0), F.PlainNumber(sa, 0.85)
    pcall(legacyRowFrame.label.SetShadowColor, legacyRowFrame.label, sr, sg, sb, sa)
    pcall(legacyRowFrame.value.SetShadowColor, legacyRowFrame.value, sr, sg, sb, sa)

    local r, g, b = DurabilityColor(pct)
    local hex = F.RGBToHex(r, g, b)
    local valStr = broken and "已损坏" or string_format("%d%%", math_floor(pct * 100 + 0.5))
    legacyRowFrame.label:SetText(string_format("|cff%s耐久度: |r", hex))
    legacyRowFrame.value:SetText(string_format("|cff%s%s|r", hex, valStr))
    legacyRowFrame.measure:SetText("耐久度: ")
    local offsetX = F.PlainNumber(legacyRowFrame.measure:GetStringWidth(), 48)

    local rowGap = DEFAULT_ROW_GAP
    if refText.GetSpacing then
        local sp = F.PlainNumber(refText:GetSpacing(), nil)
        if sp and sp >= 0 then rowGap = sp end
    end
    legacyRowFrame.value:ClearAllPoints()
    legacyRowFrame.value:SetPoint("TOPLEFT", legacyRowFrame, "TOPLEFT", offsetX, 0)
    legacyRowFrame:ClearAllPoints()
    legacyRowFrame:SetPoint("TOPLEFT", refText, "BOTTOMLEFT", 0, -rowGap)
    local vw = F.PlainNumber(legacyRowFrame.value:GetStringWidth(), 40)
    local lh = F.PlainNumber(legacyRowFrame.label:GetStringHeight(), 14)
    legacyRowFrame:SetSize(math_max(20, offsetX + vw), math_max(8, lh))
    legacyRowFrame:Show()
end

UpdateAll = function()
    local stats = _G[STATS_FRAME_NAME]
    if stats then
        HookStatsFrame(stats)
    end
    local refText = stats and FindStatsFontString(stats)

    if not mod._active then
        if cardFrame then cardFrame:Hide() end
        if legacyRowFrame then legacyRowFrame:Hide() end
        if refText and refText.SetAlpha then refText:SetAlpha(1) end
        return
    end
    if not (stats and stats:IsShown()) then
        if cardFrame then cardFrame:Hide() end
        if legacyRowFrame then legacyRowFrame:Hide() end
        return
    end

    if mod:GetDB().unifiedPanel ~= false then
        RenderUnifiedPanel(stats, refText)
    else
        RenderLegacyDurabilityRow(stats, refText)
    end
end

ScheduleUpdate = F.Debounce(0.35, UpdateAll)

local function ScheduleDurabilityUpdate()
    durDirty = true
    ScheduleUpdate()
end

local function HookEUIHideOnce()
    if euiHideHooked then return end
    local EUI = _G.EllesmereUI
    if EUI and EUI.RegisterOnHide then
        euiHideHooked = true
        pcall(EUI.RegisterOnHide, EUI, function()
            if not mod._active then return end
            C_Timer.After(0.2, function()
                if mod._active then UpdateAll() end
            end)
        end)
    end
end

function mod:OnEnable()
    local db = self:GetDB()
    -- 一次性迁移：自动切换至纯透明无边框、无顶部横线状态
    if not db.v2TransparentMigrated then
        db.v2TransparentMigrated = true
    end
    if not db.v3GlassCardMigrated then
        db.v3GlassCardMigrated = true
        db.showBackdrop = true
        db.backdropAlpha = 0.36
        db.showTopLine = true
    end
    durDirty = true

    self:RegisterEvent("UPDATE_INVENTORY_DURABILITY", ScheduleDurabilityUpdate)
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", ScheduleDurabilityUpdate)
    self:RegisterUnitEvent("UNIT_STATS", "player", ScheduleUpdate)
    self:RegisterUnitEvent("UNIT_AURA", "player", ScheduleUpdate)
    self:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED", ScheduleUpdate)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", ScheduleDurabilityUpdate)
    self:RegisterEvent("MERCHANT_CLOSED", ScheduleDurabilityUpdate)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", ScheduleUpdate)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        durDirty = true
        ScheduleUpdate()
        C_Timer.After(0.8, HookEUIHideOnce)
        C_Timer.After(1.5, function() if mod._active then UpdateAll() end end)
    end)

    -- 轻量移速微刷新：仅比较并更新移速单行文字，绝不每 1.5s 重建整张面板或扫描 11 件耐久
    if speedTicker then speedTicker:Cancel() end
    speedTicker = C_Timer.NewTicker(1.5, function()
        if not (mod._active and mod:GetDB().unifiedPanel ~= false and cardFrame and cardFrame:IsShown()) then
            return
        end
        local row = cardFrame._speedRow
        local def = STAT_GETTERS.movespeed
        if not (row and def) then return end
        local num = ReadCachedStat("movespeed", def.get)
        local txt = num ~= nil and def.fmt(num) or "--"
        if txt ~= cardFrame._lastSpeedText then
            cardFrame._lastSpeedText = txt
            row._lastVal = txt
            row._value:SetText(txt)
        end
    end)

    UpdateAll()
    C_Timer.After(1.0, HookEUIHideOnce)
    C_Timer.After(2.0, function() if mod._active then UpdateAll() end end)
end

function mod:OnDisable()
    if speedTicker then speedTicker:Cancel(); speedTicker = nil end
    UpdateAll()
end

function mod:OnThemeChanged()
    if cardFrame then cardFrame._chromeSig = nil end
    UpdateAll()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "一体化现代属性与耐久面板（推荐）",
        tooltip = "将 EUI 原本的杂色次要属性与耐久度整合为一张两端对齐、按职业精选属性的现代卡片；关闭后退回仅在 EUI 原属性下附加耐久行。",
        getValue = function() return db.unifiedPanel ~= false end,
        setValue = function(v) db.unifiedPanel = v == true; UpdateAll() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "属性展示方案",
        tooltip = "「智能动态综合」自动适配所有职业与无限服混伤配装（猎人兼顾远程/近战并在有法强时自动补全，混合职业同时展示物理+法术）；也可切为「经典全属性」固定显示全部 8 项。",
        values = {
            smart   = "智能动态综合（全职业推荐）",
            classic = "经典全属性（近战+法术+移速+耐久）",
            ranged  = "仅远程精简",
            melee   = "仅近战精简",
            caster  = "仅法系 / 治疗",
        },
        order = { "smart", "classic", "ranged", "melee", "caster" },
        getValue = function()
            local v = db.statPreset or "smart"
            return v == "auto" and "smart" or v
        end,
        setValue = function(v) db.statPreset = v; UpdateAll() end,
    }, {
        type = "slider",
        text = "底板透明度（0 = 纯透明）",
        tooltip = "调节属性与耐久面板的背景底板浓度（默认 0.00 纯透明无边框，调高可显示半透明玻璃底板）。",
        min = 0.0, max = 0.85, step = 0.04,
        getValue = function()
            if db.showBackdrop == false then return 0 end
            return db.backdropAlpha or 0
        end,
        setValue = function(v)
            local val = math_floor(v * 100 + 0.5) / 100
            db.backdropAlpha = val
            db.showBackdrop = val >= 0.03
            UpdateAll()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "显示全身平均耐久（关闭为最低单件）",
        tooltip = "默认显示损耗最严重单件的百分比，便于及时修理；开启后显示全身平均耐久。",
        getValue = function() return db.useAverage == true end,
        setValue = function(v) db.useAverage = v == true; durDirty = true; UpdateAll() end,
    }, {
        type = "toggle",
        text = "显示顶部装饰横线（仅底板开启时）",
        tooltip = "默认关闭，呈现无横线极简外观；若调高底板透明度并想要顶部 1px 职业色细线可开启。",
        getValue = function() return db.showTopLine == true end,
        setValue = function(v) db.showTopLine = v == true; UpdateAll() end,
    })
    y = y - h
    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "触发增益属性提升时数字短暂高亮闪烁",
        tooltip = "当触发饰品、嗜血、光环或增益 Buff 令攻强/暴击/法强/移速上升时，对应属性数字短促高亮回弹提示。",
        getValue = function() return db.flashOnStatGain ~= false end,
        setValue = function(v) db.flashOnStatGain = v == true end,
    }, blank)
    y = y - h
    return y
end
