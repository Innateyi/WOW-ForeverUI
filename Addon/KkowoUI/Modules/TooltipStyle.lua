----------------------------------------------------------------------
--  KkowoUI — Modules/TooltipStyle.lua
--  PrettyTooltip 联动 + 全界面悬浮卡片统一 + 可调字号缩放：
--    • 当 PrettyTooltip 已加载时：完全尊重其主提示渲染（零卡顿、零跳动、保留职业/品质色），
--      并在 /kk 提供一站式「字号倍率 / 卡片缩放」滑块，实时同步 PrettyTooltipDB 与原生提示字体
--    • 自动统一所有 EllesmereUI 私有悬浮卡片为 PrettyTooltip 黑曜石柔光质感（含外发光、顶光带、深邃渐变）：
--      - 小地图「公会 / 好友在线列表」（_friendsTT）及右键快捷菜单（_fttMenu）
--      - 小地图「日历副本进度」（_calendarTT）与「宏伟宝库」（_vaultTT）
--      - 全界面 EUI 私有提示（ShowWidgetTooltip：宠物快乐度、小地图图标、聊天侧边栏、设置说明等）
--      - 同步 EUI 小地图 customTooltipScale 与全局字号倍率，彻底告别 10px 过小模糊字
--    • 若玩家手动关闭 PrettyTooltip，自动启用轻量零跳动黑曜石回退皮肤（含职业色目标的目标）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_min, pcall, setmetatable, type =
    ipairs, math.floor, math.max, math.min, pcall, setmetatable, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("tooltipStyle", {
    title = "悬浮提示美化与字号统一（PrettyTooltip 联动）",
    desc = "全界面悬浮提示 100% 统一为 PrettyTooltip 视觉风格（装备/技能/NPC/路牌/小地图/好友卡片/系统栏与第三方图标提示完全一致），并支持全局字号倍率与紧凑度调节。",
    group = "theme",
    order = 30,
    defaults = {
        enabled = true,
        fontScale = 1.00,         -- 全局悬浮提示文字倍率（精致清晰，配合均衡正文尺寸）
        tooltipScale = 0.94,      -- 全局悬浮卡片整体缩放（紧凑耐看）
        prettyPadding = 12,       -- PrettyTooltip 内边距（原版 19 留白过大，12 紧凑清爽）
        prettyMinWidth = 188,     -- PrettyTooltip 最小宽度（原版 260 过宽，188 贴合单行 NPC/技能）
        balancePrettyBody = true, -- 均衡 PrettyTooltip 标题与信息正文比例（放大 11-12px 偏小的正文行、微收过大标题）
        prettyOriginalKey = "NONE", -- 默认关闭按 Alt 切回原版面板，防止按 Alt 组合键时误切（可选 NONE / ALT / CTRL）
        prettyDetailsKey = "SHIFT", -- NPC ID / 分解等扩展信息默认按住 Shift 展示，平时卡片更紧凑（可选 SHIFT / ALWAYS）
        unifyEUICards = true,     -- 默认开启：100% 复刻 PrettyTooltip 样式统一全界面所有悬浮提示与小地图卡片
        frostedGlass = true,      -- 仅在关闭 PrettyTooltip 全面统一时作为磨砂玻璃备用风格
        glassOpacity = 0.82,      -- 磨砂备用浓度
        plainWorldTipsFrosted = false, -- 默认关闭：场景牌子/草药/矿点/小地图/鸟点全部交回 PrettyTooltip 统一绘制
        v2Migrated = false,
        v3PrettyUnified = false,
        v4FontTuned = false,
        v5LayeredGlass = false,
        v6CompactPretty = false,
        v7BalancedPrettyBody = false,
        v8UnifiedGlass = false,
        v9AllPrettyTooltips = false,
        scale = 1.0,
        titleFontSize = 15,
        bodyFontSize = 13,
        showItemIcon = true,
        showDividers = true,
        anchorCursor = false,
        showTargetOfTarget = true,
        slimHealthBar = true,
        hideHealthBar = false,
        showItemLevel = true,
        hideInCombat = false,
    },
})

local fallbackHooked = false
local euiWidgetHooked = false
local euiMinimapHooksDone = false
local savedEUICustomTooltips = nil

local tipSkins = setmetatable({}, { __mode = "k" })
local euiCardHooked = setmetatable({}, { __mode = "k" })
local euiCardOrigBg = setmetatable({}, { __mode = "k" })
local euiCardOrigBorder = setmetatable({}, { __mode = "k" })
local euiBtnHooked = setmetatable({}, { __mode = "k" })
local cachedWidgetTT = nil
local cachedCalendarTT = nil
local cachedVaultTT = nil

local TARGET_TIPS = {
    "GameTooltip",
    "ItemRefTooltip",
    "ItemRefShoppingTooltip1",
    "ItemRefShoppingTooltip2",
    "ShoppingTooltip1",
    "ShoppingTooltip2",
    "EmbeddedItemTooltip",
}

local ALLOWED_TIPS = {}
for _, tipName in ipairs(TARGET_TIPS) do
    ALLOWED_TIPS[tipName] = true
end

local function HasPrettyTooltip()
    return F.IsAddOnLoaded("PrettyTooltip")
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function GetFontScale()
    local db = mod:GetDB()
    return Clamp(F.PlainNumber(db.fontScale, 0.96), 0.80, 1.40)
end

local function GetCardScale()
    local db = mod:GetDB()
    return Clamp(F.PlainNumber(db.tooltipScale, 0.92), 0.70, 1.30)
end

local function GetPrettyPadding()
    local db = mod:GetDB()
    return math_floor(Clamp(F.PlainNumber(db.prettyPadding, 12), 8, 22) + 0.5)
end

local function GetPrettyMinWidth()
    local db = mod:GetDB()
    return math_floor(Clamp(F.PlainNumber(db.prettyMinWidth, 188), 150, 280) + 0.5)
end

-- EUI 私有卡片（公会/好友/日历/宠物快乐度等）原本硬编码 10px 极小字体，
-- 保持足够可读下限（不因收紧 PrettyTooltip 大卡片而把小地图公会/好友卡片压回过小模糊字）
local function GetEUICardCombinedScale()
    local base = math_max(1.18, GetFontScale() * 1.18)
    return Clamp(math_floor(base * 100 + 0.5) / 100, 1.00, 1.45)
end

----------------------------------------------------------------------
--  1) 同步 PrettyTooltipDB、原生 GameTooltip 字体对象与 EUI 小地图缩放
----------------------------------------------------------------------
local BALANCED_PRETTY_SIZES = {
    -- 标题微收 1–2px 避免头重脚轻
    unitName = 15, title = 17, spellTitle = 16, objectTitle = 16, questTitle = 15,
    -- 单位/宠物/NPC 信息正文由原版 11–12px 提升至 13–14px，清晰易读
    unitGuild = 13, unitRealm = 13, unitInfo = 14, unitBadges = 14,
    unitDetails = 14, unitSkinning = 13, unitQuests = 14,
    -- 装备/技能/物件/光环/任务信息正文同步均衡放大
    subtitle = 14, header = 13, damage = 13, stats = 14,
    equipEffects = 14, enchants = 14, effects = 14, flavor = 13,
    setItems = 13, setBonuses = 13, footer = 12, extras = 11, disenchant = 11,
    spellBadges = 13, spellText = 14, spellDetails = 13,
    objectKind = 13, objectDetails = 14, objectQuests = 14, objectLoot = 13, objectPrices = 13,
    auraBadges = 13, auraText = 14, auraTime = 13,
    questInfo = 13, questBadges = 13, questText = 14, questObjectives = 14,
}

local function SyncPrettyTooltipSettings()
    if not mod._active then return end
    local db = mod:GetDB()
    local fs = GetFontScale()
    local ts = GetCardScale()

    if HasPrettyTooltip() and type(_G.PrettyTooltipDB) == "table" then
        _G.PrettyTooltipDB.fontScale = fs
        _G.PrettyTooltipDB.tooltipScale = ts
        _G.PrettyTooltipDB.padding = GetPrettyPadding()
        _G.PrettyTooltipDB.minWidth = GetPrettyMinWidth()
        local origKey = db.prettyOriginalKey
        if origKey == "NONE" or origKey == "ALT" or origKey == "CTRL" then
            _G.PrettyTooltipDB.originalKey = origKey
        end
        local detKey = db.prettyDetailsKey
        if detKey == "SHIFT" or detKey == "ALWAYS" then
            _G.PrettyTooltipDB.detailsKey = detKey
        end
        -- 只在 KkowoUI 这边的开关变化时写一次：之后你在 /ptip 里单独改这三项会被保留
        local usePrettyWorld = (db.plainWorldTipsFrosted ~= true)
        if db.ptipPanelsSynced ~= usePrettyWorld then
            db.ptipPanelsSynced = usePrettyWorld
            _G.PrettyTooltipDB.objectPanels = usePrettyWorld
            _G.PrettyTooltipDB.minimapPanels = usePrettyWorld
            _G.PrettyTooltipDB.taxiPanels = usePrettyWorld
        end
        if db.balancePrettyBody ~= false then
            if type(_G.PrettyTooltipDB.styles) ~= "table" then
                _G.PrettyTooltipDB.styles = {}
            end
            local styles = _G.PrettyTooltipDB.styles
            for k, sz in _G.pairs(BALANCED_PRETTY_SIZES) do
                if type(styles[k]) ~= "table" then styles[k] = {} end
                styles[k].size = sz
            end
        elseif type(_G.PrettyTooltipDB.styles) == "table" then
            local styles = _G.PrettyTooltipDB.styles
            for k in _G.pairs(BALANCED_PRETTY_SIZES) do
                if type(styles[k]) == "table" then
                    styles[k].size = nil
                end
            end
        end
        if type(_G.EllesmereUIDB) == "table" and _G.EllesmereUIDB.customTooltips == false then
            _G.EllesmereUIDB.customTooltips = true
        end
    end

    -- 同步 EllesmereUIMinimap 的自定义悬浮卡缩放（控制公会/好友/日历/小地图图标提示）
    local EUI = _G.EllesmereUI
    local mmNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIMinimap
    local mmEBS = mmNS and mmNS._internals and mmNS._internals.EBS
    local mp = mmEBS and mmEBS.db and mmEBS.db.profile and mmEBS.db.profile.minimap
    if type(mp) == "table" then
        mp.customTooltipScale = GetEUICardCombinedScale()
    end
end

-- 改写全局提示字体对象前先记下原始字体/阴影，停用模块时原样还原
local TOOLTIP_FONT_OBJ_NAMES = { "GameTooltipHeaderText", "GameTooltipText", "GameTooltipTextSmall", "Tooltip_Med", "Tooltip_Small" }
local fontObjBackup = nil

local function BackupTooltipFontObjects()
    if fontObjBackup then return end
    fontObjBackup = {}
    for _, name in ipairs(TOOLTIP_FONT_OBJ_NAMES) do
        local obj = _G[name]
        if obj and obj.GetFont then
            local okF, face, size, flags = pcall(obj.GetFont, obj)
            if okF and F.PlainString(face, nil) and F.PlainNumber(size, nil) then
                local entry = { face = face, size = size, flags = F.PlainString(flags, "") }
                if obj.GetShadowColor then
                    local okC, r, g, b, a = pcall(obj.GetShadowColor, obj)
                    if okC then entry.sc = { F.PlainNumber(r, 0), F.PlainNumber(g, 0), F.PlainNumber(b, 0), F.PlainNumber(a, 1) } end
                end
                if obj.GetShadowOffset then
                    local okO, x, y = pcall(obj.GetShadowOffset, obj)
                    if okO then entry.so = { F.PlainNumber(x, 0), F.PlainNumber(y, 0) } end
                end
                fontObjBackup[name] = entry
            end
        end
    end
end

local function RestoreTooltipFontObjects()
    if not fontObjBackup then return end
    for name, e in pairs(fontObjBackup) do
        local obj = _G[name]
        if obj and obj.SetFont then
            pcall(obj.SetFont, obj, e.face, e.size, e.flags)
            if e.sc and obj.SetShadowColor then pcall(obj.SetShadowColor, obj, e.sc[1], e.sc[2], e.sc[3], e.sc[4]) end
            if e.so and obj.SetShadowOffset then pcall(obj.SetShadowOffset, obj, e.so[1], e.so[2]) end
        end
    end
    fontObjBackup = nil
end

local function SyncBlizzTooltipFontObjects()
    if not mod._active then return end
    BackupTooltipFontObjects()
    local fs = GetFontScale()
    local face = F.Theme.GetFont()
    local titleSz = math_max(12, math_min(24, math_floor(14 * fs + 0.5)))
    local bodySz = math_max(11, math_min(22, math_floor(12 * fs + 0.5)))
    local smallSz = math_max(10, math_min(20, math_floor(11 * fs + 0.5)))

    local function applyObj(obj, sz)
        if obj and obj.SetFont then
            pcall(obj.SetFont, obj, face, sz, "")
            if obj.SetShadowColor then pcall(obj.SetShadowColor, obj, 0, 0, 0, 0.90) end
            if obj.SetShadowOffset then pcall(obj.SetShadowOffset, obj, 1, -1) end
        end
    end
    applyObj(_G.GameTooltipHeaderText, titleSz)
    applyObj(_G.GameTooltipText, bodySz)
    applyObj(_G.GameTooltipTextSmall, smallSz)
    applyObj(_G.Tooltip_Med, bodySz)
    applyObj(_G.Tooltip_Small, smallSz)
end

----------------------------------------------------------------------
--  2) 统一 EllesmereUI 私有悬浮卡片（公会/好友/日历/宝库/宠物快乐度等）
--     使用与 PrettyTooltip 同源的黑曜石渐变 + 外发光柔晕 + 顶光带
----------------------------------------------------------------------
local function IsSafeFrame(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function PolishCardFontStrings(frame, depth)
    if not IsSafeFrame(frame) or (depth or 0) > 2 then return end
    if frame.GetRegions then
        local ok, regs = pcall(function() return { frame:GetRegions() } end)
        if ok and type(regs) == "table" then
            for _, reg in ipairs(regs) do
                if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                    if reg.SetShadowColor then pcall(reg.SetShadowColor, reg, 0, 0, 0, 0.92) end
                    if reg.SetShadowOffset then pcall(reg.SetShadowOffset, reg, 1, -1) end
                end
            end
        end
    end
    if frame.GetChildren then
        local ok, kids = pcall(function() return { frame:GetChildren() } end)
        if ok and type(kids) == "table" then
            for _, ch in ipairs(kids) do
                if ch and ch.GetObjectType and ch:GetObjectType() == "Button" then
                    PolishCardFontStrings(ch, (depth or 0) + 1)
                end
            end
        end
    end
end

local function GetGlassAlpha()
    return Clamp(F.PlainNumber(mod:GetDB().glassOpacity, 0.82), 0.50, 0.95)
end

local function UseFrostedGlass()
    return mod._active and mod:GetDB().frostedGlass ~= false
end

local function MuteEUICardFlatChrome(tt, mode, ov)
    if not IsSafeFrame(tt) then return end
    local isPretty = (mode == "pretty")
    local isGlass = (mode == "glass")
    -- 磨砂模式：让所有 EUI 私有提示与小地图卡片复用与 GameTooltip 完全一致的底色、EUI 配置边框与磨砂光泽
    local isFrost = isGlass and UseFrostedGlass()
    local fr, fg, fb = F.Theme.FROST_RGB[1], F.Theme.FROST_RGB[2], F.Theme.FROST_RGB[3]
    local fa = GetGlassAlpha()
    local EUI = _G.EllesmereUI
    local applyCfgBrd = EUI and EUI._applyBlizzardConfiguredBorder
    local hideCfgBrd = EUI and EUI._hideBlizzardConfiguredBorder
    local useUnifiedBorder = isFrost and type(applyCfgBrd) == "function"

    -- 1) BackdropTemplate 卡片（如 _vaultTT）
    if tt.SetBackdropColor and tt.SetBackdropBorderColor then
        if isPretty then
            pcall(tt.SetBackdropColor, tt, 0, 0, 0, 0)
            pcall(tt.SetBackdropBorderColor, tt, 0, 0, 0, 0)
        elseif useUnifiedBorder then
            pcall(tt.SetBackdropColor, tt, fr, fg, fb, fa)
            pcall(tt.SetBackdropBorderColor, tt, 0, 0, 0, 0)
        elseif isFrost then
            pcall(tt.SetBackdropColor, tt, fr, fg, fb, fa)
            pcall(tt.SetBackdropBorderColor, tt, 1, 1, 1, 0.16)
        elseif isGlass then
            pcall(tt.SetBackdropColor, tt, 0.040, 0.045, 0.060, 0.84)
            pcall(tt.SetBackdropBorderColor, tt, 1, 1, 1, 0.14)
        else
            pcall(tt.SetBackdropColor, tt, 0.06, 0.06, 0.06, 0.90)
            pcall(tt.SetBackdropBorderColor, tt, 0.25, 0.25, 0.25, 1)
        end
    end

    -- 2) 直接挂在卡片上的平铺底板 Texture（ShowWidgetTooltip.bg）与圆角边框（_brd）
    -- 磨砂模式下关闭 _brd（会同步卸载 tt.bg 上的 bodyMask），改为调用与 GameTooltip 同源的 _applyBlizzardConfiguredBorder，
    -- 彻底消除圆角遮罩与缩放/底板重绘冲突（焦点提示变绿根因）并保证外观与 GameTooltip 完全一致。
    if tt._brd then
        if useUnifiedBorder or isPretty then
            if tt._brd.SetShown then pcall(tt._brd.SetShown, tt._brd, false) end
        else
            if tt._brd.SetShown then pcall(tt._brd.SetShown, tt._brd, true) end
            if tt._brd.SetColor then
                if isPretty then
                    pcall(tt._brd.SetColor, tt._brd, 0, 0, 0, 0)
                elseif isFrost then
                    pcall(tt._brd.SetColor, tt._brd, 1, 1, 1, 0.16)
                elseif isGlass then
                    pcall(tt._brd.SetColor, tt._brd, 1, 1, 1, 0.10)
                else
                    pcall(tt._brd.SetColor, tt._brd, 1, 1, 1, 0.15)
                end
            end
            if tt._brd.Fit then pcall(tt._brd.Fit, tt._brd) end
        end
    end
    if tt.bg then
        if isPretty then
            if tt.bg.SetAlpha then pcall(tt.bg.SetAlpha, tt.bg, 0) end
        elseif isFrost then
            if tt.bg.SetAlpha then pcall(tt.bg.SetAlpha, tt.bg, 1) end
            if tt.bg.SetColorTexture then pcall(tt.bg.SetColorTexture, tt.bg, fr, fg, fb, fa) end
        elseif isGlass then
            if tt.bg.SetAlpha then pcall(tt.bg.SetAlpha, tt.bg, 1) end
            if tt.bg.SetColorTexture then pcall(tt.bg.SetColorTexture, tt.bg, 0.040, 0.045, 0.060, 0.84) end
        else
            if tt.bg.SetAlpha then pcall(tt.bg.SetAlpha, tt.bg, 1) end
        end
    end

    -- 仅对没有 tt.bg / SetBackdropColor 的私有卡片（如小地图 _friendsTT / _calendarTT）扫描匿名 BACKGROUND 底板，
    -- 绝不扫描 tooltipFrame，避免误触 MaskTexture 或辅助贴图
    local origBg = euiCardOrigBg[tt]
    if not origBg and not tt.bg and not tt.SetBackdropColor and tt.GetRegions then
        local ok, regs = pcall(function() return { tt:GetRegions() } end)
        if ok and type(regs) == "table" then
            for _, reg in ipairs(regs) do
                if reg and not F.Theme.IsFrostRegion(tt, reg)
                    and reg.GetObjectType and reg:GetObjectType() == "Texture"
                    and not (reg.IsObjectType and reg:IsObjectType("MaskTexture")) then
                    local okL, layer = pcall(reg.GetDrawLayer, reg)
                    if okL and layer == "BACKGROUND" then
                        origBg = reg
                        euiCardOrigBg[tt] = reg
                        break
                    end
                end
            end
        end
    end
    if origBg then
        if isPretty then
            if origBg.SetAlpha then pcall(origBg.SetAlpha, origBg, 0) end
        elseif isFrost then
            if origBg.SetAlpha then pcall(origBg.SetAlpha, origBg, 1) end
            if origBg.SetColorTexture then pcall(origBg.SetColorTexture, origBg, fr, fg, fb, fa) end
        elseif isGlass then
            -- 统一小地图「公会/好友」与「日历」卡片为轻盈半透明烟熏玻璃（替代 EUI 硬编码的 0.92 实心灰块）
            if origBg.SetAlpha then pcall(origBg.SetAlpha, origBg, 1) end
            if origBg.SetColorTexture then pcall(origBg.SetColorTexture, origBg, 0.045, 0.050, 0.068, 0.66) end
        else
            if origBg.SetAlpha then pcall(origBg.SetAlpha, origBg, 1) end
            if origBg.SetColorTexture then pcall(origBg.SetColorTexture, origBg, 0.067, 0.067, 0.067, 0.92) end
        end
    end

    -- 3) EllesmereUI.MakeBorder 生成的 1px 边框子框体（无鼠标、仅含 4 条 BORDER 纹理）
    local origBrd = euiCardOrigBorder[tt]
    if not origBrd and not tt._brd and tt.GetChildren then
        local ok, kids = pcall(function() return { tt:GetChildren() } end)
        if ok and type(kids) == "table" then
            for _, ch in ipairs(kids) do
                if ch and ch ~= ov and IsSafeFrame(ch)
                    and ch.GetObjectType and ch:GetObjectType() == "Frame"
                    and not (ch.IsMouseEnabled and ch:IsMouseEnabled())
                    and ch.GetRegions then
                    local okR, regs = pcall(function() return { ch:GetRegions() } end)
                    if okR and type(regs) == "table" and #regs == 4 then
                        local allBorderTex = true
                        for _, r in ipairs(regs) do
                            if not (r.GetObjectType and r:GetObjectType() == "Texture") then
                                allBorderTex = false
                                break
                            end
                        end
                        if allBorderTex then
                            origBrd = ch
                            euiCardOrigBorder[tt] = ch
                            break
                        end
                    end
                end
            end
        end
    end
    if origBrd then
        local hideOrigBrd = isPretty or useUnifiedBorder
        if origBrd.SetAlpha then
            pcall(origBrd.SetAlpha, origBrd, hideOrigBrd and 0 or 1)
        end
        if not hideOrigBrd and origBrd.GetRegions then
            local okR, regs = pcall(function() return { origBrd:GetRegions() } end)
            if okR and type(regs) == "table" then
                local ba = isFrost and 0.16 or (isGlass and 0.10 or 0.15)
                for _, ln in ipairs(regs) do
                    if ln and ln.SetColorTexture then
                        pcall(ln.SetColorTexture, ln, 1, 1, 1, ba)
                    end
                end
            end
        end
    end

    -- 4) 统一套用与 GameTooltip 完全一致的 EUI 配置边框 + 磨砂光泽与 1px 顶部高光线
    if useUnifiedBorder then
        local bsNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIBlizzardSkin
        local bsFFD = bsNS and bsNS._internals and bsNS._internals.FFD
        local cb = type(bsFFD) == "table" and bsFFD[tt] and bsFFD[tt].configBorder
        if cb and cb.Show then pcall(cb.Show, cb) end
        pcall(applyCfgBrd, tt, "tooltip", 1)
    elseif type(hideCfgBrd) == "function" then
        pcall(hideCfgBrd, tt)
    end
    if isFrost then
        F.Theme.ApplyFrostedGlass(tt, { noTint = true })
    else
        F.Theme.SetFrostedGlassShown(tt, false)
    end
end

-- 暴雪原生提示与 EUI 小部件提示的底色都来自 EllesmereUI.GetTooltipBg()（EUI 每次显示时现取）。
-- 磨砂开启时让它返回加深的冷灰蓝底：不低于「磨砂玻璃底色浓度」，你在 EUI 里调得更深则沿用你的。
-- 只改这一个取色函数，不改 EUI 存档；停用模块或关掉磨砂即交还原函数。
local origGetTooltipBg = nil

local function FrostedTooltipBg()
    local r, g, b, a = origGetTooltipBg()
    if not UseFrostedGlass() then return r, g, b, a end
    local want = GetGlassAlpha()
    a = F.PlainNumber(a, want)
    if a < want then a = want end
    local c = F.Theme.FROST_RGB
    return c[1], c[2], c[3], a
end

local function SetTooltipBgOverride(on)
    local E = _G.EllesmereUI
    if type(E) ~= "table" then return end
    if on and not origGetTooltipBg and type(E.GetTooltipBg) == "function" then
        origGetTooltipBg = E.GetTooltipBg
        E.GetTooltipBg = FrostedTooltipBg
    elseif not on and origGetTooltipBg then
        if E.GetTooltipBg == FrostedTooltipBg then E.GetTooltipBg = origGetTooltipBg end
        origGetTooltipBg = nil
    end
end

-- 暴雪原生文字提示（系统栏、小地图插件按钮 LibDBIconTooltip、设置说明、好友提示等）：
-- 覆盖全部命名辅助提示并挂钩 SharedTooltip_SetBackdropStyle 捕获懒加载提示；
-- EUI 的 _ttInitVisual 因 ipairs 遇到无限服缺失的 WarCampaignTooltip(nil) 会提前中止、漏掉 LibDBIconTooltip 等，
-- 这里在辅助提示显示时主动补调一次 EUI._skinBlizzardTooltipFrame 刷新磨砂底色与边框，彻底统一为图 10 样式。
local FROST_TIPS = {
    "GameTooltip",
    "ItemRefTooltip",
    "ItemRefShoppingTooltip1",
    "ItemRefShoppingTooltip2",
    "ShoppingTooltip1",
    "ShoppingTooltip2",
    "LibDBIconTooltip",
    "SettingsTooltip",
    "FriendsTooltip",
    "GameSmallHeaderTooltip",
    "QuickKeybindTooltip",
    "BattlePetTooltip",
    "FloatingBattlePetTooltip",
    "ReputationParagonTooltip",
    "WarCampaignTooltip",
    "EllesmereUIGroupFinderRioTip",
    "EllesmereUILootRollsTip",
    "DungeonsForeverSpellCompareTip",
}
local frostTipHookedMap = setmetatable({}, { __mode = "k" })
local sharedBackdropHooked = false

local function UseAllPrettyMode()
    return mod._active and mod:GetDB().unifyEUICards ~= false
end

local function ResolveNativeTipAccent(tip)
    local name = tip and tip.GetName and F.PlainString(tip:GetName(), nil)
    local fs = (name and _G[name .. "TextLeft1"]) or (tip and tip.GetLeftLine and tip:GetLeftLine(1))
    if fs and fs.GetTextColor then
        local okC, r, g, b = pcall(fs.GetTextColor, fs)
        r = okC and F.PlainNumber(r, nil) or nil
        g = okC and F.PlainNumber(g, nil) or nil
        b = okC and F.PlainNumber(b, nil) or nil
        if r and g and b then
            -- 若标题行自带鲜明颜色（如绿色/蓝色/紫色/红警/任务金），同步该色给顶边与光晕；纯白/纯灰则用 PrettyTooltip 暖金中性色
            local hi = math_max(r, g, b)
            local lo = math_min(r, g, b)
            if hi - lo > 0.16 and not (r > 0.95 and g > 0.78 and g < 0.86 and b < 0.08) then
                return r, g, b
            end
        end
    end
    return 0.78, 0.66, 0.46
end

local mutedNativeRegs = setmetatable({}, { __mode = "k" })

local function HideNativeTipChrome(tip, hide)
    if not IsSafeFrame(tip) then return end
    if tip.NineSlice and tip.NineSlice.SetAlpha then
        pcall(tip.NineSlice.SetAlpha, tip.NineSlice, hide and 0 or 1)
    end
    local E = _G.EllesmereUI
    local hideCfg = E and E._hideBlizzardConfiguredBorder
    if hide then
        if type(hideCfg) == "function" then pcall(hideCfg, tip) end
        -- 隐藏 EUI 给原生提示挂载的平铺底色层（保留文字），由 PrettyCardOverlay 接管全部底板与边框
        if tip.GetRegions then
            local okR, regs = pcall(function() return { tip:GetRegions() } end)
            if okR and type(regs) == "table" then
                local list = mutedNativeRegs[tip]
                if not list then list = {}; mutedNativeRegs[tip] = list end
                for _, reg in ipairs(regs) do
                    if reg and reg.GetObjectType and reg:GetObjectType() == "Texture"
                        and not F.Theme.IsFrostRegion(tip, reg) then
                        local okL, layer = pcall(reg.GetDrawLayer, reg)
                        if okL and (layer == "BACKGROUND" or layer == "BORDER") then
                            if list[reg] == nil and reg.GetAlpha then
                                local okA, a = pcall(reg.GetAlpha, reg)
                                list[reg] = okA and F.PlainNumber(a, 1) or 1
                            end
                            pcall(reg.SetAlpha, reg, 0)
                        end
                    end
                end
            end
        end
    else
        local list = mutedNativeRegs[tip]
        if list then
            for reg, origA in _G.pairs(list) do
                if reg and reg.SetAlpha then pcall(reg.SetAlpha, reg, origA) end
            end
            mutedNativeRegs[tip] = nil
        end
        if tip ~= GameTooltip and E and type(E._skinBlizzardTooltipFrame) == "function" then
            pcall(E._skinBlizzardTooltipFrame, tip)
        end
    end
end

local function FrostNativeTip(tip)
    if not IsSafeFrame(tip) or tip.IsEmbedded == true then return end
    local E = _G.EllesmereUI
    if UseAllPrettyMode() then
        F.Theme.SetFrostedGlassShown(tip, false)
        HideNativeTipChrome(tip, true)
        local r, g, b = ResolveNativeTipAccent(tip)
        F.Theme.PaintPrettyCardOverlay(tip, r, g, b, 28)
        PolishCardFontStrings(tip, 0)
    elseif UseFrostedGlass() then
        F.Theme.HidePrettyCardOverlay(tip)
        HideNativeTipChrome(tip, false)
        if tip ~= GameTooltip and E and type(E._skinBlizzardTooltipFrame) == "function" then
            pcall(E._skinBlizzardTooltipFrame, tip)
        end
        F.Theme.ApplyFrostedGlass(tip, { noTint = true })
    else
        F.Theme.HidePrettyCardOverlay(tip)
        HideNativeTipChrome(tip, false)
        F.Theme.SetFrostedGlassShown(tip, false)
        if tip ~= GameTooltip and E and type(E._skinBlizzardTooltipFrame) == "function" then
            pcall(E._skinBlizzardTooltipFrame, tip)
        end
    end
end

local function EnsureFrostTipHook(tip)
    if not IsSafeFrame(tip) or tip.IsEmbedded == true or frostTipHookedMap[tip] then return end
    if not tip.HookScript then return end
    frostTipHookedMap[tip] = true
    tip:HookScript("OnShow", FrostNativeTip)
    tip:HookScript("OnSizeChanged", function(self)
        if UseAllPrettyMode() and self:IsShown() then
            FrostNativeTip(self)
        end
    end)
    if tip.IsShown and tip:IsShown() then
        FrostNativeTip(tip)
    end
end

local function HookNativeTipFrost()
    for _, name in ipairs(FROST_TIPS) do
        local tip = _G[name]
        if tip then EnsureFrostTipHook(tip) end
    end
    local qsf = _G.QuestScrollFrame
    if qsf then
        if qsf.StoryTooltip then EnsureFrostTipHook(qsf.StoryTooltip) end
        if qsf.CampaignTooltip then EnsureFrostTipHook(qsf.CampaignTooltip) end
    end
    if not sharedBackdropHooked and type(_G.SharedTooltip_SetBackdropStyle) == "function" then
        sharedBackdropHooked = true
        _G.hooksecurefunc("SharedTooltip_SetBackdropStyle", function(tip)
            if not mod._active or not IsSafeFrame(tip) or tip.IsEmbedded == true then return end
            EnsureFrostTipHook(tip)
            if tip.IsShown and tip:IsShown() then
                C_Timer.After(0, function()
                    if mod._active and IsSafeFrame(tip) and tip:IsShown() then
                        FrostNativeTip(tip)
                    end
                end)
            end
        end)
    end
end

local function RefreshNativeTipFrost()
    SetTooltipBgOverride(mod._active and (not UseAllPrettyMode()) and UseFrostedGlass())
    HookNativeTipFrost()
    for tip in _G.pairs(frostTipHookedMap) do
        FrostNativeTip(tip)
    end
end

local function ApplyPrettyStyleToEUICard(tt, r, g, b, headerMaxH)
    if not IsSafeFrame(tt) then return end
    if not mod._active then
        F.Theme.HidePrettyCardOverlay(tt)
        MuteEUICardFlatChrome(tt, "restore", nil)
        return
    end
    if mod:GetDB().unifyEUICards == false then
        F.Theme.HidePrettyCardOverlay(tt)
        MuteEUICardFlatChrome(tt, "glass", nil)
        PolishCardFontStrings(tt, 0)
        return
    end
    local ov = F.Theme.PaintPrettyCardOverlay(tt, r, g, b, headerMaxH or 28)
    MuteEUICardFlatChrome(tt, "pretty", ov)
    PolishCardFontStrings(tt, 0)
end

local function AttachEUICardHook(tt, headerMaxH)
    if not IsSafeFrame(tt) then return end
    if not euiCardHooked[tt] then
        euiCardHooked[tt] = true
        tt:HookScript("OnShow", function(self)
            local ar, ag, ab = F.Theme.GetAccent()
            ApplyPrettyStyleToEUICard(self, ar, ag, ab, headerMaxH)
        end)
    end
    if tt:IsShown() then
        local ar, ag, ab = F.Theme.GetAccent()
        ApplyPrettyStyleToEUICard(tt, ar, ag, ab, headerMaxH)
    end
end

local function FindEUIWidgetTooltip()
    if cachedWidgetTT and IsSafeFrame(cachedWidgetTT) then
        return cachedWidgetTT
    end
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return nil end
    local okC, children = pcall(function() return { ui:GetChildren() } end)
    if not (okC and type(children) == "table") then return nil end
    for _, f in ipairs(children) do
        if IsSafeFrame(f) and f.bg and f.text and f._brd then
            local okS, strata = pcall(f.GetFrameStrata, f)
            local okSh, shown = pcall(f.IsShown, f)
            if okS and strata == "TOOLTIP" and okSh and shown then
                cachedWidgetTT = f
                return f
            end
        end
    end
    return nil
end

local function IsPanelFamilyAnchor(region)
    local EUI = _G.EllesmereUI
    if not (EUI and region) then return false end
    local mf = EUI._mainFrame
    local pops = EUI._popupFrames
    local node = region
    local guard = 0
    while node and guard < 16 do
        guard = guard + 1
        if node == mf then return true end
        if type(pops) == "table" then
            for i = 1, #pops do
                if pops[i] and pops[i].popup == node then return true end
            end
        end
        node = node.GetParent and node:GetParent() or nil
    end
    return false
end

local function ResolveWidgetAccent(label, text)
    local EUI = _G.EllesmereUI
    local ufNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIUnitFrames
    local pf = ufNS and ufNS._internals and ufNS._internals.frames and ufNS._internals.frames.pet
    local isPetHappy = (pf and pf._petHappy and label == pf._petHappy)
    local plain = F.PlainString(text, nil)
    if isPetHappy or (plain and (plain:find("忠诚度", 1, true) or plain:find("喂养你的宠物", 1, true))) then
        local lv = _G.C_PetInfo and _G.C_PetInfo.GetPetHappiness
            and F.PlainNumber(_G.C_PetInfo.GetPetHappiness(), nil)
        if lv == 3 or (plain and plain:find("^快乐")) then
            return 0.36, 0.86, 0.56
        elseif lv == 2 or (plain and plain:find("^满足")) then
            return 0.95, 0.78, 0.32
        elseif lv == 1 or (plain and plain:find("^不高兴")) then
            return 0.92, 0.34, 0.38
        end
    end
    return F.Theme.GetAccent()
end

local function RefitWidgetTooltipSize(tt, opts)
    if not (tt and tt.text and tt.SetWidth and tt.SetHeight) then return end
    local maxW = 250
    if not (opts and opts.width) then
        -- 缩放后中文字符像素进位可能多出 1~2px，先放宽测出新缩放下的真实单行宽，再加足量留白，杜绝「焦点」被折成两行溢出
        pcall(tt.SetWidth, tt, maxW)
        local okW, rawW = pcall(tt.text.GetStringWidth, tt.text)
        local sw = okW and F.PlainNumber(rawW, nil) or nil
        if sw and sw > 0 then
            pcall(tt.SetWidth, tt, math_min(math_max(math_floor(sw + 22.5), 40), maxW))
        end
    end
    local okH, rawH = pcall(tt.text.GetStringHeight, tt.text)
    local sh = okH and F.PlainNumber(rawH, nil) or nil
    if sh and sh > 0 then
        pcall(tt.SetHeight, tt, math_max(24, math_floor(sh + 16.5)))
    end
end

local function OnEUIWidgetTooltipShown(label, text, opts)
    local tt = FindEUIWidgetTooltip()
    if not tt then return end

    -- 未显式传入 scale（例如「焦点」、宠物快乐度、小地图图标、侧边栏）时同步全局字号缩放，并在缩放后重算宽高防中文折行
    if mod._active and not (opts and opts.scale) then
        local wantScale = GetEUICardCombinedScale()
        if label and IsPanelFamilyAnchor(label) then
            local ps = _G.EllesmereUIDB and F.PlainNumber(_G.EllesmereUIDB.panelScale, 1) or 1
            wantScale = Clamp(wantScale * ps, 0.85, 1.55)
        end
        pcall(tt.SetScale, tt, wantScale)
        RefitWidgetTooltipSize(tt, opts)
        if opts and opts.anchor == "cursor" and _G.GetCursorPosition then
            local eff = F.PlainNumber(tt.GetEffectiveScale and tt:GetEffectiveScale(), 0)
            local cx, cy = _G.GetCursorPosition()
            cx = F.PlainNumber(cx, nil)
            cy = F.PlainNumber(cy, nil)
            if eff > 0 and cx and cy then
                pcall(tt.ClearAllPoints, tt)
                pcall(tt.SetPoint, tt, "BOTTOM", _G.UIParent, "BOTTOMLEFT", cx / eff, cy / eff + 4)
            end
        end
    elseif mod._active then
        RefitWidgetTooltipSize(tt, opts)
    end
    -- 停用后不再改动 EUI 小部件提示的尺寸，只走下方的还原分支

    local r, g, b = ResolveWidgetAccent(label, text)
    ApplyPrettyStyleToEUICard(tt, r, g, b, 26)
end

local function HookEUIWidgetTooltip()
    if euiWidgetHooked then return end
    local EUI = _G.EllesmereUI
    if type(EUI) == "table" and type(EUI.ShowWidgetTooltip) == "function" then
        euiWidgetHooked = true
        _G.hooksecurefunc(EUI, "ShowWidgetTooltip", function(label, text, opts)
            pcall(OnEUIWidgetTooltipShown, label, text, opts)
        end)
    end
end

-- 捕获 EllesmereUIMinimap 私有卡片（公会/好友 _friendsTT、右键菜单 _fttMenu、日历 _calendarTT、宝库 _vaultTT）
local function DiscoverShownMinimapCard(excludeFriends, wantVault)
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return nil end
    local okC, children = pcall(function() return { ui:GetChildren() } end)
    if not (okC and type(children) == "table") then return nil end
    for _, f in ipairs(children) do
        if IsSafeFrame(f) and f ~= excludeFriends and f ~= cachedWidgetTT
            and f ~= GameTooltip and f ~= _G.ItemRefTooltip then
            local okS, strata = pcall(f.GetFrameStrata, f)
            local okSh, shown = pcall(f.IsShown, f)
            if okS and strata == "TOOLTIP" and okSh and shown then
                local name = f.GetName and f:GetName()
                if not name then
                    if wantVault then
                        if f._title and f._fadeInAG then return f end
                    else
                        local lvl = F.PlainNumber(f.GetFrameLevel and f:GetFrameLevel(), 0)
                        if lvl == 200 and not f.bg and not f._brd then
                            return f
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function DiscoverShownFTTMenu()
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return nil end
    local okC, children = pcall(function() return { ui:GetChildren() } end)
    if not (okC and type(children) == "table") then return nil end
    for _, f in ipairs(children) do
        if IsSafeFrame(f) and f._target ~= nil then
            local okS, strata = pcall(f.GetFrameStrata, f)
            local lvl = F.PlainNumber(f.GetFrameLevel and f:GetFrameLevel(), 0)
            if okS and strata == "TOOLTIP" and lvl == 500 then
                return f
            end
        end
    end
    return nil
end

local function SkinFriendsTTNow(mmEBS)
    local ftt = mmEBS and mmEBS._friendsTT
    if not ftt then return end
    AttachEUICardHook(ftt, 30)

    -- 顺手美化公会/好友行右键弹出的「密语 / 邀请」小菜单（_fttMenu）
    if ftt.GetChildren then
        local okK, kids = pcall(function() return { ftt:GetChildren() } end)
        if okK and type(kids) == "table" then
            for _, rowBtn in ipairs(kids) do
                if rowBtn and rowBtn.GetObjectType and rowBtn:GetObjectType() == "Button" and not euiBtnHooked[rowBtn] then
                    euiBtnHooked[rowBtn] = true
                    rowBtn:HookScript("OnClick", function(_, mouseBtn)
                        if mouseBtn == "RightButton" then
                            local menu = DiscoverShownFTTMenu()
                            if menu then AttachEUICardHook(menu, 18) end
                        end
                    end)
                end
            end
        end
    end
end

local function HookEUIMinimapCards()
    local EUI = _G.EllesmereUI
    local mmNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIMinimap
    local mmI = mmNS and mmNS._internals
    if not mmI then return end

    local mmEBS = mmI.EBS
    if mmEBS and mmEBS._friendsTT then
        SkinFriendsTTNow(mmEBS)
    end

    local ci = mmI._customIndicators
    if type(ci) == "table" then
        if ci.friends and not euiBtnHooked[ci.friends] then
            euiBtnHooked[ci.friends] = true
            ci.friends:HookScript("OnEnter", function()
                if mmEBS and mmEBS._friendsTT then
                    SkinFriendsTTNow(mmEBS)
                end
            end)
        end
        if ci.calendar and not euiBtnHooked[ci.calendar] then
            euiBtnHooked[ci.calendar] = true
            ci.calendar:HookScript("OnEnter", function()
                if not cachedCalendarTT then
                    cachedCalendarTT = DiscoverShownMinimapCard(mmEBS and mmEBS._friendsTT, false)
                end
                if cachedCalendarTT then
                    AttachEUICardHook(cachedCalendarTT, 28)
                end
            end)
        end
    end

    if not euiMinimapHooksDone then
        euiMinimapHooksDone = true
        if type(mmI.ShowFriendsTooltip) == "function" then
            _G.hooksecurefunc(mmI, "ShowFriendsTooltip", function()
                if mmEBS and mmEBS._friendsTT then
                    SkinFriendsTTNow(mmEBS)
                end
            end)
        end
        if type(mmI.ShowCalendarTooltip) == "function" then
            _G.hooksecurefunc(mmI, "ShowCalendarTooltip", function()
                if not cachedCalendarTT then
                    cachedCalendarTT = DiscoverShownMinimapCard(mmEBS and mmEBS._friendsTT, false)
                end
                if cachedCalendarTT then
                    AttachEUICardHook(cachedCalendarTT, 28)
                end
            end)
        end
        if type(mmI.ShowVaultTooltip) == "function" then
            _G.hooksecurefunc(mmI, "ShowVaultTooltip", function()
                if not cachedVaultTT then
                    cachedVaultTT = DiscoverShownMinimapCard(mmEBS and mmEBS._friendsTT, true)
                end
                if cachedVaultTT then
                    AttachEUICardHook(cachedVaultTT, 24)
                end
            end)
        end
    end
end

local function RefreshAllEUICards()
    SyncPrettyTooltipSettings()
    SyncBlizzTooltipFontObjects()
    local EUI = _G.EllesmereUI
    local mmNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIMinimap
    local mmEBS = mmNS and mmNS._internals and mmNS._internals.EBS
    local ar, ag, ab = F.Theme.GetAccent()
    if mmEBS and mmEBS._friendsTT then
        ApplyPrettyStyleToEUICard(mmEBS._friendsTT, ar, ag, ab, 30)
    end
    if cachedCalendarTT then
        ApplyPrettyStyleToEUICard(cachedCalendarTT, ar, ag, ab, 28)
    end
    if cachedVaultTT then
        ApplyPrettyStyleToEUICard(cachedVaultTT, ar, ag, ab, 24)
    end
    if cachedWidgetTT and cachedWidgetTT:IsShown() then
        ApplyPrettyStyleToEUICard(cachedWidgetTT, ar, ag, ab, 26)
    end
end

----------------------------------------------------------------------
--  3) 回退皮肤（仅当未启用 PrettyTooltip 时生效，绝不与 PrettyTooltip 冲突）
----------------------------------------------------------------------
local function IsSafeTooltip(tip)
    if not IsSafeFrame(tip) then return false end
    local okName, name = pcall(tip.GetName, tip)
    if not okName or type(name) ~= "string" or not ALLOWED_TIPS[name] then
        return false
    end
    local okW, w = pcall(tip.GetWidth, tip)
    if not okW or F.IsSecret(w) then return false end
    local okL = pcall(tip.GetFrameLevel, tip)
    if not okL then return false end
    return true
end

local function SuppressEUITooltipConflict(suppress)
    if HasPrettyTooltip() then return end
    local euiDB = _G.EllesmereUIDB
    if type(euiDB) ~= "table" then return end
    if suppress then
        if euiDB.customTooltips ~= false then
            savedEUICustomTooltips = (euiDB.customTooltips == nil) and "nil" or euiDB.customTooltips
            euiDB.customTooltips = false
        end
    elseif savedEUICustomTooltips ~= nil then
        if savedEUICustomTooltips == "nil" then
            euiDB.customTooltips = nil
        else
            euiDB.customTooltips = savedEUICustomTooltips
        end
        savedEUICustomTooltips = nil
    end
end

local function GetUnitColor(unit)
    if not unit then
        return F.Theme.GetAccent()
    end
    local okP, isPlayer = pcall(_G.UnitIsPlayer, unit)
    if okP and not F.IsSecret(isPlayer) and isPlayer then
        local okC, _, classToken = pcall(_G.UnitClass, unit)
        if okC and not F.IsSecret(classToken) and classToken then
            local c = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classToken]
            if c then return c.r, c.g, c.b end
        end
    end
    if _G.UnitReaction then
        local okR, reaction = pcall(_G.UnitReaction, unit, "player")
        reaction = okR and F.PlainNumber(reaction, nil) or nil
        if reaction then
            if reaction <= 3 then
                return 0.92, 0.34, 0.38
            elseif reaction == 4 then
                return 0.94, 0.78, 0.32
            else
                return 0.38, 0.85, 0.56
            end
        end
    end
    return F.Theme.GetAccent()
end

local function ResolveTooltipInfo(tip)
    if tip.GetUnit then
        local okU, _, unit = pcall(tip.GetUnit, tip)
        if okU and not F.IsSecret(unit) and unit then
            local r, g, b = GetUnitColor(unit)
            return r, g, b, nil
        end
    end
    if tip.GetItem then
        local okI, _, link = pcall(tip.GetItem, tip)
        if okI and type(link) == "string" and not F.IsSecret(link) then
            local getInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
            local quality, icon
            if getInfo then
                local okQ, _, _, q, _, _, _, _, _, _, ic = pcall(getInfo, link)
                if okQ then
                    quality = F.PlainNumber(q, nil)
                    icon = ic
                end
            end
            if not icon then
                local getIcon = (_G.C_Item and _G.C_Item.GetItemIconByID) or _G.GetItemIcon
                if getIcon then
                    local okIc, ic = pcall(getIcon, link)
                    if okIc then icon = ic end
                end
            end
            local getQualColor = (_G.C_Item and _G.C_Item.GetItemQualityColor) or _G.GetItemQualityColor
            if quality and getQualColor then
                local qr, qg, qb = getQualColor(quality)
                if qr and qg and qb then
                    return qr, qg, qb, icon
                end
            end
            local ar, ag, ab = F.Theme.GetAccent()
            return ar, ag, ab, icon
        end
    end
    local ar, ag, ab = F.Theme.GetAccent()
    return ar, ag, ab, nil
end

local function EnsureFallbackIconPlate(tip)
    local holder = tipSkins[tip]
    if holder then return holder end
    holder = CreateFrame("Frame", nil, tip)
    holder:SetPoint("TOPLEFT", tip, "TOPLEFT", 1, -1)
    holder:SetPoint("BOTTOMRIGHT", tip, "BOTTOMRIGHT", -1, 1)
    holder:EnableMouse(false)

    local iconPlate = CreateFrame("Frame", nil, holder)
    iconPlate:SetSize(36, 36)
    iconPlate:SetPoint("TOPRIGHT", holder, "TOPLEFT", -4, 1)
    iconPlate:EnableMouse(false)
    F.Theme.StylePanel(iconPlate, 0.96, 0.90)
    local ic = iconPlate:CreateTexture(nil, "ARTWORK")
    ic:SetPoint("TOPLEFT", iconPlate, "TOPLEFT", 2, -2)
    ic:SetPoint("BOTTOMRIGHT", iconPlate, "BOTTOMRIGHT", -2, 2)
    ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconPlate._icon = ic
    iconPlate:Hide()
    holder._iconPlate = iconPlate

    tipSkins[tip] = holder
    return holder
end

local function StyleHealthBar(r, g, b)
    local sb = _G.GameTooltipStatusBar
    if not sb or not IsSafeFrame(sb) then return end
    local db = mod:GetDB()
    if db.hideHealthBar then
        sb:Hide()
        return
    end
    if db.slimHealthBar ~= false then
        sb:SetHeight(3)
        sb:ClearAllPoints()
        sb:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 2, -3)
        sb:SetPoint("TOPRIGHT", GameTooltip, "BOTTOMRIGHT", -2, -3)
        sb:SetStatusBarTexture(F.Theme.GetBarTexture())
        sb:SetStatusBarColor(r, g, b, 0.95)
    end
end

local function PaintFallbackTooltip(tip, forceR, forceG, forceB)
    if HasPrettyTooltip() then return end
    if not (mod._active and IsSafeTooltip(tip)) then return end
    local db = mod:GetDB()

    if tip.NineSlice and tip.NineSlice.SetAlpha then
        pcall(tip.NineSlice.SetAlpha, tip.NineSlice, 0)
    end
    if tip == GameTooltip and tip.SetScale then
        pcall(tip.SetScale, tip, GetCardScale())
    end

    local r, g, b, itemIcon = ResolveTooltipInfo(tip)
    if forceR and forceG and forceB then
        r, g, b = forceR, forceG, forceB
    end
    F.Theme.PaintPrettyCardOverlay(tip, r, g, b, 34)

    local holder = EnsureFallbackIconPlate(tip)
    local plate = holder._iconPlate
    if plate then
        if db.showItemIcon ~= false and itemIcon and tip ~= _G.EmbeddedItemTooltip then
            plate._icon:SetTexture(itemIcon)
            if plate._fuiBorders then
                for _, ln in ipairs(plate._fuiBorders) do
                    ln:SetColorTexture(r * 0.65 + 0.14, g * 0.65 + 0.14, b * 0.65 + 0.16, 0.92)
                end
            end
            plate:Show()
        else
            plate:Hide()
        end
    end
    holder:Show()

    if tip == GameTooltip then
        StyleHealthBar(r, g, b)
    end
end

local function EnhanceFallbackUnitTooltip(tip)
    if HasPrettyTooltip() then return end
    if not (mod._active and tip == GameTooltip and IsSafeTooltip(tip)) then return end
    local okU, _, unit = pcall(tip.GetUnit, tip)
    if not (okU and not F.IsSecret(unit) and unit) then return end

    local r, g, b = GetUnitColor(unit)
    local titleFS = _G.GameTooltipTextLeft1
    if titleFS and titleFS.SetTextColor then
        pcall(titleFS.SetTextColor, titleFS, r, g, b)
    end

    if mod:GetDB().showTargetOfTarget ~= false then
        local targetUnit = unit .. "target"
        local okE, exists = pcall(_G.UnitExists, targetUnit)
        if okE and not F.IsSecret(exists) and exists then
            local okS, isSelf = pcall(_G.UnitIsUnit, targetUnit, "player")
            if okS and not F.IsSecret(isSelf) and isSelf then
                tip:AddDoubleLine("目标", ">> 你 <<", 0.62, 0.65, 0.70, 0.95, 0.34, 0.38)
            else
                local tName = F.PlainString(_G.UnitName and _G.UnitName(targetUnit), nil)
                if tName and tName ~= "" then
                    local tr, tg, tb = GetUnitColor(targetUnit)
                    tip:AddDoubleLine("目标", tName, 0.62, 0.65, 0.70, tr, tg, tb)
                end
            end
        end
    end
    PaintFallbackTooltip(tip, r, g, b)
end

local function EnhanceFallbackItemTooltip(tip)
    if HasPrettyTooltip() then return end
    if not (mod._active and IsSafeTooltip(tip)) then return end
    if mod:GetDB().showItemLevel ~= false and tip.GetItem then
        local okI, _, link = pcall(tip.GetItem, tip)
        if okI and type(link) == "string" and not F.IsSecret(link) then
            local getInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
            local getILvl = (_G.C_Item and _G.C_Item.GetDetailedItemLevelInfo) or _G.GetDetailedItemLevelInfo
            if getInfo then
                local okE, _, _, _, baseILvl, _, _, _, _, equipLoc = pcall(getInfo, link)
                if okE and equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" then
                    local ilvl = F.PlainNumber(baseILvl, nil)
                    if getILvl then
                        local okLvl, detLvl = pcall(getILvl, link)
                        if okLvl then ilvl = F.PlainNumber(detLvl, ilvl) end
                    end
                    if ilvl and ilvl > 0 then
                        local prefix = tip.GetName and tip:GetName()
                        local exists = false
                        if prefix then
                            local nLines = F.PlainNumber(tip:NumLines(), 0)
                            for i = 2, math_min(nLines, 30) do
                                local fs = _G[prefix .. "TextLeft" .. i]
                                local t = fs and F.PlainString(fs:GetText(), nil)
                                if t and (t:find("物品等级", 1, true) or t:find("Item Level", 1, true)) then
                                    exists = true
                                    break
                                end
                            end
                        end
                        if not exists then
                            local ar, ag, ab = F.Theme.GetAccent()
                            tip:AddDoubleLine("物品等级", string_format("%d", ilvl), 0.62, 0.65, 0.70, ar, ag, ab)
                        end
                    end
                end
            end
        end
    end
    PaintFallbackTooltip(tip)
end

local function SetupTooltipHooks()
    if fallbackHooked then return end
    fallbackHooked = true

    if _G.GameTooltip_SetDefaultAnchor then
        _G.hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tip, parent)
            if mod._active and mod:GetDB().anchorCursor and tip and parent and IsSafeTooltip(tip) then
                pcall(tip.SetOwner, tip, parent, "ANCHOR_CURSOR_RIGHT", 14, 14)
            end
        end)
    end

    if HasPrettyTooltip() then
        -- PrettyTooltip 接管主提示，仅保留可选的战斗中隐藏钩子，绝不干扰其面板绘制与锚点
        if GameTooltip and GameTooltip.HookScript then
            GameTooltip:HookScript("OnShow", function(self)
                if mod._active and mod:GetDB().hideInCombat and _G.InCombatLockdown and _G.InCombatLockdown() then
                    self:Hide()
                end
            end)
        end
        return
    end

    for _, name in ipairs(TARGET_TIPS) do
        local tip = _G[name]
        if tip and tip.HookScript then
            tip:HookScript("OnShow", function(self)
                if not mod._active or HasPrettyTooltip() then return end
                if self == GameTooltip and mod:GetDB().hideInCombat and _G.InCombatLockdown and _G.InCombatLockdown() then
                    self:Hide()
                    return
                end
                PaintFallbackTooltip(self)
            end)
            tip:HookScript("OnTooltipCleared", function(self)
                local holder = tipSkins[self]
                if holder and holder._iconPlate then
                    holder._iconPlate:Hide()
                end
            end)
        end
    end

    if _G.GameTooltipStatusBar and _G.GameTooltipStatusBar.HookScript then
        _G.GameTooltipStatusBar:HookScript("OnShow", function(self)
            if mod._active and not HasPrettyTooltip() and mod:GetDB().hideHealthBar then
                self:Hide()
            end
        end)
    end

    if _G.TooltipDataProcessor and _G.TooltipDataProcessor.AddTooltipPostCall and _G.Enum and _G.Enum.TooltipDataType then
        local DT = _G.Enum.TooltipDataType
        if DT.Unit then
            pcall(_G.TooltipDataProcessor.AddTooltipPostCall, DT.Unit, EnhanceFallbackUnitTooltip)
        end
        if DT.Item then
            pcall(_G.TooltipDataProcessor.AddTooltipPostCall, DT.Item, EnhanceFallbackItemTooltip)
        end
    end
end

----------------------------------------------------------------------
--  模块生命周期与设置面板
----------------------------------------------------------------------
local HookScalesTooltipPolish
do
    local hookedScalesTips = setmetatable({}, { __mode = "k" })
    local scalesGapIdx = setmetatable({}, { __mode = "k" })

    local function GetTipLineFS(tip, idx, isRight)
        if isRight then
            if tip.GetRightLine then
                local ok, fs = pcall(tip.GetRightLine, tip, idx)
                if ok and fs then return fs end
            end
            local nm = tip.GetName and F.PlainString(tip:GetName(), nil)
            return nm and _G[nm .. "TextRight" .. idx] or nil
        else
            if tip.GetLeftLine then
                local ok, fs = pcall(tip.GetLeftLine, tip, idx)
                if ok and fs then return fs end
            end
            local nm = tip.GetName and F.PlainString(tip:GetName(), nil)
            return nm and _G[nm .. "TextLeft" .. idx] or nil
        end
    end

    local function CleanScalesText(s)
        if type(s) ~= "string" then return s end
        -- 将 Scales 的 14px 基线图标改为与 PrettyTooltip 11px 扩展行严格垂直对齐的 11:11:0:-2，并收紧双空格防折行
        local out = s:gsub("|TInterface\\AddOns\\Scales\\Media\\Logo:%d+|t",
            "|TInterface\\AddOns\\Scales\\Media\\Logo:11:11:0:-2|t")
        out = out:gsub("|TInterface\\AddOns\\Scales\\Media\\(Arrow%a+):%d+|t",
            "|TInterface\\AddOns\\Scales\\Media\\%1:10:10:0:-1|t")
        out = out:gsub("|T([^|:]+):14|t", "|T%1:11:11:0:-2|t")
        out = out:gsub("Scales|r  +", "Scales|r ")
        if out:sub(1, 3) == "   " then
            out = "  " .. out:sub(4)
        end
        return out
    end

    local function IsBlankLine(tip, idx)
        if idx < 1 then return false end
        local lfs = GetTipLineFS(tip, idx, false)
        local rfs = GetTipLineFS(tip, idx, true)
        local lt = lfs and lfs.GetText and F.PlainString(lfs:GetText(), "") or ""
        local rt = rfs and rfs.GetText and F.PlainString(rfs:GetText(), "") or ""
        return (lt:match("^%s*$") ~= nil) and (rt:match("^%s*$") ~= nil)
    end

    local function CopyLine(tip, srcIdx, dstIdx, newLeft, newRight)
        local sL, dL = GetTipLineFS(tip, srcIdx, false), GetTipLineFS(tip, dstIdx, false)
        local sR, dR = GetTipLineFS(tip, srcIdx, true), GetTipLineFS(tip, dstIdx, true)
        if dL and dL.SetText then
            pcall(dL.SetText, dL, newLeft or "")
            if sL and sL.GetTextColor and dL.SetTextColor then
                local okC, r, g, b, a = pcall(sL.GetTextColor, sL)
                if okC and r then pcall(dL.SetTextColor, dL, r, g, b, a or 1) end
            end
        end
        if dR and dR.SetText then
            pcall(dR.SetText, dR, newRight or "")
            if sR and sR.GetTextColor and dR.SetTextColor then
                local okC, r, g, b, a = pcall(sR.GetTextColor, sR)
                if okC and r then pcall(dR.SetTextColor, dR, r, g, b, a or 1) end
            end
            if newRight and newRight ~= "" and dR.Show then pcall(dR.Show, dR) end
        end
        -- 腾空的那一行清字并隐藏：只清字的话空行只是被挪到了 Scales 最后一行之后，仍然隔一行
        -- （ClearLines 时暴雪会统一重置各行，下一次提示照常使用）
        if sL and sL.SetText then pcall(sL.SetText, sL, "") end
        if sR and sR.SetText then pcall(sR.SetText, sR, "") end
        if sL and sL.Hide then pcall(sL.Hide, sL) end
        if sR and sR.Hide then pcall(sR.Hide, sR) end
    end

    local function HandleScalesRow(tip, leftArg, rightArg)
        if not mod._active or not IsSafeFrame(tip) then return end
        local left = F.PlainString(leftArg, nil)
        if not left then return end
        local isScalesHeader = left:find("Interface\\AddOns\\Scales\\Media\\", 1, true) ~= nil
        local gap = scalesGapIdx[tip]
        local n = tip.NumLines and F.PlainNumber(tip:NumLines(), 0) or 0
        if n <= 0 then return end

        local isScalesFollow = (gap ~= nil) and (n == gap + 1) and (left:sub(1, 3) == "   " or isScalesHeader)
        if not (isScalesHeader or isScalesFollow) then
            if gap ~= nil then scalesGapIdx[tip] = nil end
            return
        end

        local lfs = GetTipLineFS(tip, n, false)
        local rfs = GetTipLineFS(tip, n, true)
        local curL = (lfs and lfs.GetText and F.PlainString(lfs:GetText(), left)) or left
        local curR = (rfs and rfs.GetText and F.PlainString(rfs:GetText(), "")) or F.PlainString(rightArg, "")
        local fixedL = CleanScalesText(curL)
        local fixedR = CleanScalesText(curR)

        if isScalesHeader and n >= 2 and IsBlankLine(tip, n - 1) then
            -- 吞掉 Scales 自己插在前面的空行（AddLine(" ")），消除「隔行」空洞
            CopyLine(tip, n, n - 1, fixedL, fixedR)
            scalesGapIdx[tip] = n
        elseif isScalesFollow and gap then
            CopyLine(tip, n, gap, fixedL, fixedR)
            scalesGapIdx[tip] = n
        else
            if lfs and lfs.SetText and fixedL ~= curL then pcall(lfs.SetText, lfs, fixedL) end
            if rfs and rfs.SetText and fixedR ~= curR then pcall(rfs.SetText, rfs, fixedR) end
        end
    end

    HookScalesTooltipPolish = function()
        for _, name in ipairs({ "GameTooltip", "ItemRefTooltip" }) do
            local tip = _G[name]
            if IsSafeFrame(tip) and not hookedScalesTips[tip] then
                hookedScalesTips[tip] = true
                if type(tip.AddDoubleLine) == "function" then
                    _G.hooksecurefunc(tip, "AddDoubleLine", function(self, l, r)
                        HandleScalesRow(self, l, r)
                    end)
                end
                if type(tip.AddLine) == "function" then
                    _G.hooksecurefunc(tip, "AddLine", function(self, l)
                        HandleScalesRow(self, l, nil)
                    end)
                end
                if tip.HookScript then
                    if tip.HasScript and tip:HasScript("OnTooltipCleared") then
                        tip:HookScript("OnTooltipCleared", function(self) scalesGapIdx[self] = nil end)
                    end
                    tip:HookScript("OnHide", function(self) scalesGapIdx[self] = nil end)
                end
            end
        end
    end
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2Migrated then
        db.v2Migrated = true
        if db.scale == 0.90 then db.scale = 1.0 end
    end
    if not db.v3PrettyUnified then
        db.v3PrettyUnified = true
        -- 一次性修复过小偏模糊的默认缩放（0.85 → 1.00）并适度增大字号（1.10x）
        db.fontScale = 1.10
        db.tooltipScale = 1.00
        db.unifyEUICards = true
    end
    if not db.v4FontTuned then
        db.v4FontTuned = true
        -- 将上一版 1.18x 默认字号精准回调约 1px 至 1.10x（正文约 14.3px，较原版 0.85x 清晰 3px+ 且更精致）
        if db.fontScale == 1.18 then
            db.fontScale = 1.10
        end
    end
    if not db.v5LayeredGlass then
        db.v5LayeredGlass = true
        -- 一次性切至分层统一方案：装备/技能/NPC 走 PrettyTooltip，其余按钮与小地图卡片保持与 GameTooltip 一致的半透明烟熏玻璃
        db.unifyEUICards = false
    end
    if not db.v6CompactPretty then
        db.v6CompactPretty = true
        -- 一次性收紧 PrettyTooltip 过大的默认卡片尺寸与留白，并关闭按 Alt 误切原版提示
        db.fontScale = 1.00
        db.tooltipScale = 0.94
        db.prettyPadding = 12
        db.prettyMinWidth = 188
        db.prettyOriginalKey = "NONE"
        db.prettyDetailsKey = "SHIFT"
    end
    if not db.v7BalancedPrettyBody then
        db.v7BalancedPrettyBody = true
        -- 一次性均衡 PrettyTooltip 标题与下方信息正文比例（解决标题大、正文行过小）
        db.balancePrettyBody = true
        db.fontScale = 1.00
        db.tooltipScale = 0.94
    end
    if not db.v8UnifiedGlass then
        db.v8UnifiedGlass = true
        db.plainWorldTipsFrosted = true
    end
    if not db.v9AllPrettyTooltips then
        db.v9AllPrettyTooltips = true
        -- 一次性全面统一：全部原生提示、EUI 私有卡片、小地图/场景物件/鸟点 100% 复刻/交由 PrettyTooltip 统一呈现
        db.unifyEUICards = true
        db.plainWorldTipsFrosted = false
    end

    SuppressEUITooltipConflict(true)
    SyncPrettyTooltipSettings()
    SyncBlizzTooltipFontObjects()
    SetupTooltipHooks()
    SetTooltipBgOverride((not UseAllPrettyMode()) and UseFrostedGlass())
    HookNativeTipFrost()
    HookScalesTooltipPolish()
    HookEUIWidgetTooltip()
    HookEUIMinimapCards()

    if not HasPrettyTooltip() then
        PaintFallbackTooltip(GameTooltip)
    end

    C_Timer.After(1.0, function()
        if not mod._active then return end
        SyncPrettyTooltipSettings()
        SyncBlizzTooltipFontObjects()
        HookNativeTipFrost()
        HookEUIWidgetTooltip()
        HookEUIMinimapCards()
    end)

    -- 过图/读条不再重写 PrettyTooltipDB（登录/重载时 OnEnable 已同步一次；每次过图都覆盖会抹掉玩家在 /ptip 里的改动）
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        SuppressEUITooltipConflict(true)
        SyncBlizzTooltipFontObjects()
        SetupTooltipHooks()
        HookNativeTipFrost()
        HookEUIWidgetTooltip()
        HookEUIMinimapCards()
        if not HasPrettyTooltip() then
            PaintFallbackTooltip(GameTooltip)
        end
    end)
end

function mod:OnDisable()
    SuppressEUITooltipConflict(false)
    RestoreTooltipFontObjects()
    RefreshAllEUICards()
    SetTooltipBgOverride(false)
    local E = _G.EllesmereUI
    for tip in _G.pairs(frostTipHookedMap) do
        F.Theme.HidePrettyCardOverlay(tip)
        HideNativeTipChrome(tip, false)
        F.Theme.SetFrostedGlassShown(tip, false)
        if tip ~= GameTooltip and IsSafeFrame(tip) and E and type(E._skinBlizzardTooltipFrame) == "function" then
            pcall(E._skinBlizzardTooltipFrame, tip)
        end
    end
    for _, name in ipairs(FROST_TIPS) do
        if _G[name] then F.Theme.SetFrostedGlassShown(_G[name], false) end
    end
    if not HasPrettyTooltip() then
        for _, name in ipairs(TARGET_TIPS) do
            local tip = _G[name]
            local holder = tip and tipSkins[tip]
            if holder then holder:Hide() end
            if tip then F.Theme.HidePrettyCardOverlay(tip) end
            if tip and IsSafeFrame(tip) and tip.NineSlice and tip.NineSlice.SetAlpha then
                pcall(tip.NineSlice.SetAlpha, tip.NineSlice, 1)
            end
        end
        if GameTooltip and GameTooltip.SetScale then
            pcall(GameTooltip.SetScale, GameTooltip, 1.0)
        end
    end
end

function mod:OnThemeChanged()
    RefreshAllEUICards()
    RefreshNativeTipFrost()
    if not HasPrettyTooltip() then
        PaintFallbackTooltip(GameTooltip)
    end
end

local function OpenPrettyTooltipPanel()
    local handler = _G.SlashCmdList and _G.SlashCmdList.PRETTYTOOLTIP
    if type(handler) == "function" then
        pcall(handler, "")
    else
        F.Print("未检测到 PrettyTooltip 插件，可在插件列表启用后再使用精细编辑器。")
    end
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "全部悬浮提示 100% 复刻 PrettyTooltip 样式",
        tooltip = "默认开启：将按钮说明、小地图好友/公会/日历卡片、系统栏与第三方图标提示全部 100% 复刻 PrettyTooltip 的黑曜石渐变、顶色带、2px 亮顶边与外柔光，全游戏悬浮提示零割裂；关闭则切回磨砂玻璃。",
        getValue = function() return db.unifyEUICards ~= false end,
        setValue = function(v)
            db.unifyEUICards = v == true
            RefreshAllEUICards()
            RefreshNativeTipFrost()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "文字提示与小地图卡片使用磨砂玻璃（备用）",
        tooltip = "仅在关闭上方「全部悬浮提示 100% 复刻 PrettyTooltip 样式」时生效：将按钮说明、系统栏、好友/公会列表改为半透明冷灰蓝磨砂玻璃。",
        disabled = function() return db.unifyEUICards ~= false end,
        getValue = function() return db.frostedGlass ~= false end,
        setValue = function(v)
            db.frostedGlass = v == true
            RefreshAllEUICards()
            RefreshNativeTipFrost()
        end,
    }, {
        type = "slider",
        text = "磨砂玻璃底色浓度",
        tooltip = "仅在磨砂备用模式下生效：数值越大越不透明、越好读；默认 0.82。",
        min = 0.50, max = 0.95, step = 0.02,
        disabled = function() return db.unifyEUICards ~= false or db.frostedGlass == false end,
        getValue = function() return GetGlassAlpha() end,
        setValue = function(v)
            db.glassOpacity = v
            RefreshAllEUICards()
            RefreshNativeTipFrost()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "悬浮提示字号倍率",
        tooltip = "同步调节 PrettyTooltip 与暴雪默认提示文字大小（默认 0.96，步进 0.02 精细调节，滑动后重新悬停即刻生效）。",
        min = 0.80, max = 1.40, step = 0.02,
        getValue = function() return GetFontScale() end,
        setValue = function(v)
            db.fontScale = v
            RefreshAllEUICards()
            if not HasPrettyTooltip() then PaintFallbackTooltip(GameTooltip) end
        end,
    }, {
        type = "slider",
        text = "悬浮卡片整体缩放",
        tooltip = "同步调节 PrettyTooltip 悬浮卡片整体尺寸（默认 0.92 更紧凑，1.00 为原比例）。",
        min = 0.70, max = 1.30, step = 0.02,
        getValue = function() return GetCardScale() end,
        setValue = function(v)
            db.tooltipScale = v
            RefreshAllEUICards()
            if not HasPrettyTooltip() then PaintFallbackTooltip(GameTooltip) end
        end,
    })
    y = y - h

    if HasPrettyTooltip() then
        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "均衡卡片标题与信息正文字号比例",
            tooltip = "PrettyTooltip 原版标题 17–19px、下方说明仅 11–12px 落差过大；开启后自动将信息正文放大至 13–14px、标题微收，卡片依然紧凑且阅读更轻松。",
            getValue = function() return db.balancePrettyBody ~= false end,
            setValue = function(v)
                db.balancePrettyBody = v == true
                RefreshAllEUICards()
            end,
        }, {
            type = "toggle",
            text = "场景物件/小地图/鸟点改用磨砂玻璃",
            tooltip = "默认关闭：路牌、邮箱、草药/矿点、小地图图钉与飞行点全部交给 PrettyTooltip 统一绘制；开启则改回磨砂玻璃纯文字框。",
            getValue = function() return db.plainWorldTipsFrosted == true end,
            setValue = function(v)
                db.plainWorldTipsFrosted = v == true
                if type(_G.PrettyTooltipDB) == "table" then
                    local usePretty = not db.plainWorldTipsFrosted
                    db.ptipPanelsSynced = usePretty
                    _G.PrettyTooltipDB.objectPanels = usePretty
                    _G.PrettyTooltipDB.minimapPanels = usePretty
                    _G.PrettyTooltipDB.taxiPanels = usePretty
                end
                RefreshAllEUICards()
                RefreshNativeTipFrost()
            end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "slider",
            text = "卡片内边距（留白紧凑度）",
            tooltip = "PrettyTooltip 原版默认 19px 留白偏大，调至 10–13px 卡片显著更紧凑精致。",
            min = 8, max = 22, step = 1,
            getValue = function() return GetPrettyPadding() end,
            setValue = function(v)
                db.prettyPadding = math_floor(v + 0.5)
                RefreshAllEUICards()
            end,
        }, {
            type = "slider",
            text = "卡片最小宽度",
            tooltip = "PrettyTooltip 原版最小宽度 260px 对短 NPC 提示偏宽，默认收紧至 188px。",
            min = 150, max = 280, step = 4,
            getValue = function() return GetPrettyMinWidth() end,
            setValue = function(v)
                db.prettyMinWidth = math_floor(v + 0.5)
                RefreshAllEUICards()
            end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "dropdown",
            text = "按住快捷键临时切回原版提示",
            tooltip = "PrettyTooltip 原版默认按住 Alt 会临时切回暴雪小框提示；关闭可彻底避免按 Alt 组合键时面板乱切。",
            values = {
                NONE = "关闭（推荐·防按 Alt 误切）",
                ALT  = "按住 Alt 查看原版提示",
                CTRL = "按住 Ctrl 查看原版提示",
            },
            order = { "NONE", "ALT", "CTRL" },
            getValue = function() return db.prettyOriginalKey or "NONE" end,
            setValue = function(v)
                db.prettyOriginalKey = v
                RefreshAllEUICards()
            end,
        }, {
            type = "dropdown",
            text = "NPC ID / 分解等扩展信息",
            tooltip = "改为「按住 Shift 展开」后，平时悬停 NPC/装备卡片更短更紧凑，需要查 ID 或分解数据时按住 Shift 即可。",
            values = {
                SHIFT  = "按住 Shift 展开（更紧凑·推荐）",
                ALWAYS = "始终展开",
            },
            order = { "SHIFT", "ALWAYS" },
            getValue = function() return db.prettyDetailsKey or "SHIFT" end,
            setValue = function(v)
                db.prettyDetailsKey = v
                RefreshAllEUICards()
            end,
        })
        y = y - h
    end

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "跟随鼠标显示",
        tooltip = "让鼠标提示跟随光标右上方显示。",
        getValue = function() return db.anchorCursor == true end,
        setValue = function(v) db.anchorCursor = v == true end,
    }, {
        type = "toggle",
        text = "战斗中隐藏鼠标提示",
        getValue = function() return db.hideInCombat == true end,
        setValue = function(v) db.hideInCombat = v == true end,
    })
    y = y - h

    if HasPrettyTooltip() then
        _, h = W:DualRow(parent, y, {
            type = "labeledButton",
            text = "PrettyTooltip 精细样式编辑器",
            buttonText = "打开 /ptip",
            width = 140,
            tooltip = "打开 PrettyTooltip 原生可视化编辑器，可按装备/单位/技能单独微调各元素字号、边框与光晕。",
            onClick = OpenPrettyTooltipPanel,
        }, blank)
        y = y - h
    else
        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "物品卡片左上显示高清图标徽章",
            getValue = function() return db.showItemIcon ~= false end,
            setValue = function(v) db.showItemIcon = v == true; PaintFallbackTooltip(GameTooltip) end,
        }, {
            type = "toggle",
            text = "显示目标的目标（含职业色）",
            getValue = function() return db.showTargetOfTarget ~= false end,
            setValue = function(v) db.showTargetOfTarget = v == true end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "极简 3px 底部血条",
            getValue = function() return db.slimHealthBar ~= false end,
            setValue = function(v) db.slimHealthBar = v == true; PaintFallbackTooltip(GameTooltip) end,
        }, {
            type = "toggle",
            text = "隐藏单位血条",
            getValue = function() return db.hideHealthBar == true end,
            setValue = function(v) db.hideHealthBar = v == true; PaintFallbackTooltip(GameTooltip) end,
        })
        y = y - h
    end

    return y
end
