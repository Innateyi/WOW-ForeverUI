----------------------------------------------------------------------
--  kkowoUI — Modules/WeaponProcs.lua
--  武器附魔与攻击特效计时条：
--    • 攻击特效（十字军「神圣力量」、菲斯克等武器触发的自身 Buff）：触发后显示圆角持续时间条。
--      无限服在战斗中把光环字段变成保密值，插件也读不到战斗日志，所以优先交给
--      EllesmereUI AuraKit 的引擎光环容器（AuraContainer）按法术 ID 匹配：条的进度与倒计时
--      由引擎绘制，战斗中照常显示。EUI 不提供该接口时退回「可读时扫描」（脱战 / 未受限时）。
--    • 武器附魔（毒药 / 磨刀石 / 武器油 / 萨满灌注）：装备数据可读，自绘剩余时间条。
--    • 两组各自接入 EUI 解锁模式移动；每个附魔 / 特效可单独设颜色；圆角跟随全局圆角半径。
--  引擎按钮的子框体只在「创建窗口」（initializeFrame 回调）里允许插件读写，
--  所以引擎条的全部贴图都在创建时一次性画好（静态 9 宫格圆角，不挂任何延迟回调）。
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, type, tostring, tonumber = ipairs, pairs, pcall, type, tostring, tonumber
local math_floor, math_max, math_min, math_ceil, math_abs = math.floor, math.max, math.min, math.ceil, math.abs
local string_format = string.format
local table_sort, table_remove = table.sort, table.remove
local CreateFrame = CreateFrame
local GetTime = GetTime

local ST = F.StyleTokens

local mod = F.RegisterModule("weaponProcs", {
    title = "武器附魔与特效计时条",
    desc = "武器攻击特效（十字军「神圣力量」等触发 Buff）触发后显示圆角持续时间条，战斗中由引擎光环容器驱动；"
        .. "武器临时附魔 / 职业灌注显示剩余时间。每项可单独设颜色，可在 EUI 解锁模式中移动。",
    group = "combat",
    order = 12,
    defaults = {
        enabled = true,
        width = 190,
        height = 16,
        spacing = 3,
        showIcon = true,
        showName = true,
        procGrow = "up",          -- "up" | "down"
        enchantMode = "always",   -- "always" | "combat" | "low" | "off"
        enchantLowMinutes = 5,
        presetOn = {},            -- [presetKey] = false 表示关闭（nil = 默认开启）
        colors = {},              -- [entryKey] = { r, g, b }（nil = 默认色）
        custom = {},              -- { { key, id, name }, ... }
        learned = {},             -- [entryKey] = { [spellID] = true }（按名称识别到的无限服法术 ID）
    },
})

----------------------------------------------------------------------
-- 预设：只收录会给自己加 Buff 的经典旧世武器特效（无限服沿用经典法术 ID）。
-- 烈焰武器、生命偷取、正义之手额外攻击等不加 Buff 的效果只能靠战斗日志，无限服不开放，无法计时。
----------------------------------------------------------------------
local PRESETS = {
    { key = "crusader",   ids = { 20007 }, fallback = "神圣力量",          source = "附魔：十字军",              color = { 0.98, 0.80, 0.34 } },
    { key = "felstriker", ids = { 16551 }, fallback = "Felstriker",        item = 12590,                         color = { 0.62, 0.92, 0.36 } },
    { key = "empyrean",   ids = { 21165 }, fallback = "Haste",             item = 17112,                         color = { 0.98, 0.56, 0.30 } },
    { key = "untamed",    ids = { 23719 }, fallback = "Untamed Fury",      item = 19334,                         color = { 0.94, 0.38, 0.42 } },
    { key = "bonereaver", ids = { 21153 }, fallback = "Bonereaver's Edge", item = 17076,                         color = { 0.78, 0.84, 0.94 } },
    { key = "eskhandar",  ids = { 22640 }, fallback = "Eskhandar's Rage",  item = 18203,                         color = { 0.86, 0.52, 0.98 } },
    { key = "quickshots", ids = { 6150 },  fallback = "快速射击",          source = "猎人天赋：强化雄鹰守护", classes = { HUNTER = true }, color = { 0.40, 0.86, 0.98 } },
}

local ENCH_COLOR_DEFAULTS = {
    ench_mh_temp  = { 0.40, 0.76, 0.98 },
    ench_oh_temp  = { 0.64, 0.56, 0.98 },
    ench_rg_temp  = { 0.42, 0.88, 0.60 },
    ench_mh_imbue = { 0.30, 0.86, 0.84 },
    ench_oh_imbue = { 0.98, 0.64, 0.34 },
}
local CUSTOM_PALETTE = {
    { 0.98, 0.48, 0.62 }, { 0.50, 0.70, 1.00 }, { 0.96, 0.86, 0.40 },
    { 0.56, 0.94, 0.76 }, { 0.88, 0.60, 0.98 }, { 1.00, 0.66, 0.40 },
}

local WEAPONS = {
    { slot = "mh", inv = 16, ws = "MainHand", label = "主手" },
    { slot = "oh", inv = 17, ws = "OffHand",  label = "副手" },
    { slot = "rg", inv = 18, ws = "Ranged",   label = "远程" },
}

local MAX_PER_ENTRY = 2     -- 同一特效最多并列两条（双持两把都带十字军时各自触发）
local MAX_RECENT = 16

----------------------------------------------------------------------
-- 运行状态
----------------------------------------------------------------------
local procAnchor, enchAnchor, driver = nil, nil, nil
local entries, entryByKey, idIndex, nameIndex = {}, {}, {}, {}
local layout = nil
local layoutGen = 0
local procRows, enchRows = {}, {}
local scanItems = {}        -- 兼容扫描模式下当前显示的特效 { entry, exp, dur, icon, stacks }
local previewItems = nil    -- 预览中的示例条
local previewOn, previewByUnlock = false, false
local enchItems = {}
local enchTrack = {}        -- [slot..kind] = { id, exp, total }
local enchNameCache = {}    -- [inv .. ":" .. enchantID] = 名称（false = 认不出）
local enchSessionStart = 0
local inCombat = false
local recent, recentOrder = {}, {}
local engine = { container = nil, fp = nil, failed = false, styleKeys = {}, gen = 0, initErr = nil }
local auraScanPending = false
local tickAccum = 0
local colorGen = 0          -- 颜色改动计数：自绘条比对它决定要不要重新上色

local function GetAK()
    local EUI = _G.EllesmereUI
    return EUI and EUI.AuraKit or nil
end

----------------------------------------------------------------------
-- 通用小工具
----------------------------------------------------------------------
local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function PlainIcon(v)
    if F.IsSecret(v) then return nil end
    if type(v) == "number" and v > 0 then return v end
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

local function SpellName(id)
    if not id then return nil end
    local CS = _G.C_Spell
    if CS and CS.GetSpellName then
        local ok, n = pcall(CS.GetSpellName, id)
        if ok then return F.PlainString(n, nil) end
    elseif _G.GetSpellInfo then
        local ok, n = pcall(_G.GetSpellInfo, id)
        if ok then return F.PlainString(n, nil) end
    end
    return nil
end

local function SpellIcon(id)
    if not id then return nil end
    local CS = _G.C_Spell
    if CS and CS.GetSpellTexture then
        local ok, ic = pcall(CS.GetSpellTexture, id)
        if ok then return PlainIcon(ic) end
    end
    return nil
end

local function ItemName(itemID)
    if not itemID then return nil end
    local CI = _G.C_Item
    if CI and CI.GetItemNameByID then
        local ok, n = pcall(CI.GetItemNameByID, itemID)
        if ok then return F.PlainString(n, nil) end
    end
    return nil
end

local function RequestItemData()
    local CI = _G.C_Item
    if not (CI and CI.RequestLoadItemDataByID) then return end
    for _, p in ipairs(PRESETS) do
        if p.item then pcall(CI.RequestLoadItemDataByID, p.item) end
    end
end

local function ClassOK(p)
    return not p.classes or p.classes[F.GetPlayerClass()] == true
end

local function AurasRestricted()
    local AK = GetAK()
    if AK and AK.AurasRestricted then
        local ok, r = pcall(AK.AurasRestricted)
        if ok then return r == true end
    end
    local S = _G.C_Secrets
    if S and S.ShouldAurasBeSecret then
        local ok, sec = pcall(S.ShouldAurasBeSecret)
        if not ok or F.IsSecret(sec) or sec == true then return true end
    end
    return false
end

local function FormatRemain(rem)
    if rem >= 5400 then
        return string_format("%dh", math_ceil(rem / 3600))
    elseif rem >= 90 then
        return string_format("%dm", math_ceil(rem / 60))
    end
    return string_format("%d", math_max(0, math_ceil(rem)))
end

----------------------------------------------------------------------
-- 颜色
----------------------------------------------------------------------
local function DefaultColor(key)
    for _, p in ipairs(PRESETS) do
        if p.key == key then return p.color end
    end
    if ENCH_COLOR_DEFAULTS[key] then return ENCH_COLOR_DEFAULTS[key] end
    local db = mod:GetDB()
    for i, c in ipairs(db.custom) do
        if c.key == key then return CUSTOM_PALETTE[(i - 1) % #CUSTOM_PALETTE + 1] end
    end
    return CUSTOM_PALETTE[1]
end

local function GetColor(key)
    local c = mod:GetDB().colors[key]
    if type(c) == "table" then
        local r, g, b = F.PlainNumber(c[1], nil), F.PlainNumber(c[2], nil), F.PlainNumber(c[3], nil)
        if r and g and b then return r, g, b end
    end
    local d = DefaultColor(key)
    return d[1], d[2], d[3]
end

----------------------------------------------------------------------
-- 条目（预设 + 自定义）
----------------------------------------------------------------------
local function AddID(e, id)
    if not id or e.ids[id] then return end
    e.ids[id] = true
    e.idList[#e.idList + 1] = id
    if not idIndex[id] then idIndex[id] = e end
end

local function BuildEntries()
    local db = mod:GetDB()
    for i = #entries, 1, -1 do entries[i] = nil end
    for k in pairs(entryByKey) do entryByKey[k] = nil end
    for k in pairs(idIndex) do idIndex[k] = nil end
    for k in pairs(nameIndex) do nameIndex[k] = nil end

    local function Add(e)
        entries[#entries + 1] = e
        entryByKey[e.key] = e
        local learned = type(db.learned[e.key]) == "table" and db.learned[e.key] or nil
        if learned then
            for id in pairs(learned) do
                if type(id) == "number" then AddID(e, id) end
            end
        end
    end

    for _, p in ipairs(PRESETS) do
        if ClassOK(p) then
            local e = { key = p.key, preset = p, ids = {}, idList = {}, enabled = db.presetOn[p.key] ~= false }
            for _, id in ipairs(p.ids) do AddID(e, id) end
            e.label = SpellName(p.ids[1]) or p.fallback
            e.icon = SpellIcon(p.ids[1])
            Add(e)
        end
    end
    for _, c in ipairs(db.custom) do
        if type(c) == "table" and type(c.key) == "string" then
            local id = F.PlainNumber(c.id, nil)
            local e = { key = c.key, custom = c, ids = {}, idList = {}, enabled = true }
            if id then AddID(e, id) end
            e.label = (id and SpellName(id)) or F.PlainString(c.name, nil) or ("法术 " .. tostring(id or "?"))
            e.icon = id and SpellIcon(id) or nil
            -- 只有自定义条目按名称识别（预设名称如「急速」可能撞名，按 ID 匹配更可靠）
            local nm = F.PlainString(c.name, nil) or e.label
            if nm and nm ~= "" then nameIndex[nm] = e end
            Add(e)
        end
    end
end

local function Learn(e, sid)
    if not (e and sid) or e.ids[sid] then return end
    local db = mod:GetDB()
    if type(db.learned[e.key]) ~= "table" then db.learned[e.key] = {} end
    db.learned[e.key][sid] = true
    AddID(e, sid)
    if not e.icon then e.icon = SpellIcon(sid) end
    if mod.ScheduleEngineBuild then mod:ScheduleEngineBuild() end
end

----------------------------------------------------------------------
-- 布局
----------------------------------------------------------------------
local function ComputeLayout()
    local db = mod:GetDB()
    local w = math_floor(Clamp(F.PlainNumber(db.width, 190) or 190, 120, 360) + 0.5)
    local h = math_floor(Clamp(F.PlainNumber(db.height, 16) or 16, 10, 30) + 0.5)
    local sp = math_floor(Clamp(F.PlainNumber(db.spacing, 3) or 3, 0, 12) + 0.5)
    local showIcon = db.showIcon ~= false
    local radius = math_min(ST.GetCornerRadius(4), math_floor(h * 0.5))
    if radius < 0 then radius = 0 end
    local px = ST.GetPixel(_G.UIParent)
    if not px or px <= 0 or px > 2 then px = 1 end
    local L = {
        rowW = w, h = h, spacing = sp,
        showIcon = showIcon, showName = db.showName ~= false,
        gap = showIcon and math_max(2, math_floor(h * 0.18 + 0.5)) or 0,
        radius = radius, px = px,
        font = (h >= 20) and ST.FONT.body or ((h >= 14) and 11 or ST.FONT.caption),
        up = db.procGrow ~= "down",
    }
    L.iconW = showIcon and h or 0
    L.fp = table.concat({ w, h, sp, showIcon and 1 or 0, L.showName and 1 or 0, radius, L.up and 1 or 0,
        string_format("%.4f", px) }, ":")
    return L
end

----------------------------------------------------------------------
-- 圆角条外观（引擎按钮与自绘条共用；全部静态，创建后不再需要回调）
--   外层圆角 = 1px 深色描边，内缩 1 物理像素的圆角 = 轨道底色，填充条用同半径圆角遮罩裁切
----------------------------------------------------------------------
local SLICE_STRETCH = _G.Enum and _G.Enum.UITextureSliceMode and _G.Enum.UITextureSliceMode.Stretched
-- 与核心双翼血条（CoreHUD ApplyWingStyle）同一描边色
local WING_BORDER = { 0.05, 0.06, 0.09, 0.86 }

local function ApplyShape(tex, radius, wrap)
    if radius and radius > 0 then
        local path, _, r = ST.ResolveMaskPath(radius)
        if tex.SetBlockingLoadsRequested then pcall(tex.SetBlockingLoadsRequested, tex, true) end
        if wrap then
            pcall(tex.SetTexture, tex, path, wrap, wrap)
        else
            pcall(tex.SetTexture, tex, path)
        end
        if tex.SetTextureSliceMargins then pcall(tex.SetTextureSliceMargins, tex, r, r, r, r) end
        if SLICE_STRETCH ~= nil and tex.SetTextureSliceMode then pcall(tex.SetTextureSliceMode, tex, SLICE_STRETCH) end
    else
        pcall(tex.SetTexture, tex, ST.TEX.FLAT)
    end
end

local function AddRoundMask(owner, tex, anchor, radius)
    if not (radius and radius > 0 and owner.CreateMaskTexture and tex.AddMaskTexture) then return nil end
    local m = owner:CreateMaskTexture()
    m:SetAllPoints(anchor)
    ApplyShape(m, radius, "CLAMPTOBLACKADDITIVE")
    pcall(tex.AddMaskTexture, tex, m)
    return m
end

local function BuildRowRegions(host, L)
    local row = {}
    local px, r = L.px, L.radius
    local inner = math_max(1, r - 1)
    local bc = WING_BORDER
    local barLeft = L.showIcon and (L.iconW + L.gap) or 0

    if L.showIcon then
        local ib = host:CreateTexture(nil, "BACKGROUND", nil, 1)
        ib:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        ib:SetSize(L.iconW, L.h)
        ApplyShape(ib, r)
        ib:SetVertexColor(bc[1], bc[2], bc[3], bc[4])
        local icon = host:CreateTexture(nil, "ARTWORK", nil, 1)
        icon:SetPoint("TOPLEFT", ib, "TOPLEFT", px, -px)
        icon:SetPoint("BOTTOMRIGHT", ib, "BOTTOMRIGHT", -px, px)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        AddRoundMask(host, icon, icon, (r > 0) and inner or 0)
        row.iconBorder, row.icon = ib, icon
    end

    -- 1px 描边必须是「空心」的：底槽是半透明玻璃，实心的深色描边底会从底槽里透出来把它压暗
    local bd = host:CreateTexture(nil, "BACKGROUND", nil, 1)
    bd:SetPoint("TOPLEFT", host, "TOPLEFT", barLeft, 0)
    bd:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
    bd:SetVertexColor(bc[1], bc[2], bc[3], bc[4])
    local _, invPath = ST.ResolveMaskPath(r)
    if r > 0 and invPath and host.CreateMaskTexture then
        -- 与 EUI 圆角描边同法：外圈圆角实心 + 内缩 1px 的反向圆角遮罩挖空中间
        ApplyShape(bd, r)
        local hole = host:CreateMaskTexture()
        hole:SetPoint("TOPLEFT", bd, "TOPLEFT", px, -px)
        hole:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT", -px, px)
        if hole.SetBlockingLoadsRequested then pcall(hole.SetBlockingLoadsRequested, hole, true) end
        pcall(hole.SetTexture, hole, invPath, "CLAMPTOWHITE", "CLAMPTOWHITE")
        if hole.SetTextureSliceMargins then pcall(hole.SetTextureSliceMargins, hole, inner, inner, inner, inner) end
        if SLICE_STRETCH ~= nil and hole.SetTextureSliceMode then pcall(hole.SetTextureSliceMode, hole, SLICE_STRETCH) end
        pcall(bd.AddMaskTexture, bd, hole)
    else
        -- 直角：四条 1px 边线
        bd:Hide()
        local edges = {}
        for i = 1, 4 do
            local e = host:CreateTexture(nil, "BACKGROUND", nil, 1)
            e:SetColorTexture(bc[1], bc[2], bc[3], bc[4])
            edges[i] = e
        end
        edges[1]:SetPoint("TOPLEFT", bd, "TOPLEFT"); edges[1]:SetPoint("TOPRIGHT", bd, "TOPRIGHT"); edges[1]:SetHeight(px)
        edges[2]:SetPoint("BOTTOMLEFT", bd, "BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT"); edges[2]:SetHeight(px)
        edges[3]:SetPoint("TOPLEFT", bd, "TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT", bd, "BOTTOMLEFT"); edges[3]:SetWidth(px)
        edges[4]:SetPoint("TOPRIGHT", bd, "TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT"); edges[4]:SetWidth(px)
        row.edges = edges
    end

    -- 底槽颜色随条色在 PaintRow 里设（与核心双翼血条掉血后露出的底色同一算法）
    local track = host:CreateTexture(nil, "BACKGROUND", nil, 2)
    track:SetPoint("TOPLEFT", bd, "TOPLEFT", px, -px)
    track:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT", -px, px)
    ApplyShape(track, (r > 0) and inner or 0)

    local bar = CreateFrame("StatusBar", nil, host)
    bar:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 0, 0)
    bar:SetStatusBarTexture(ST.TEX.FLAT)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    if bar.EnableMouse then bar:EnableMouse(false) end
    local fill = bar:GetStatusBarTexture()
    if fill then
        -- 关掉像素吸附：否则慢速缩短的填充边缘按整像素跳格（15 秒的条每秒才缩约 10 像素），看起来一顿一顿的
        if fill.SetSnapToPixelGrid then pcall(fill.SetSnapToPixelGrid, fill, false) end
        if fill.SetTexelSnappingBias then pcall(fill.SetTexelSnappingBias, fill, 0) end
        AddRoundMask(bar, fill, bar, (r > 0) and inner or 0)
    end

    -- 文字载体放在填充条之上
    local carrier = CreateFrame("Frame", nil, host)
    carrier:SetPoint("TOPLEFT", bd, "TOPLEFT", 0, 0)
    carrier:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT", 0, 0)
    carrier:SetFrameLevel((F.PlainNumber(bar:GetFrameLevel(), 1) or 1) + 2)
    if carrier.EnableMouse then carrier:EnableMouse(false) end

    local timeFS = carrier:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(timeFS, L.font)
    timeFS:SetPoint("RIGHT", carrier, "RIGHT", -5, 0)
    timeFS:SetJustifyH("RIGHT")
    timeFS:SetWordWrap(false)
    timeFS:SetText("")

    local nameFS = carrier:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(nameFS, L.font)
    nameFS:SetPoint("LEFT", carrier, "LEFT", 5, 0)
    nameFS:SetPoint("RIGHT", carrier, "RIGHT", -math_floor(L.font * 2.8 + 6), 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    nameFS:SetText("")
    nameFS:SetShown(L.showName)

    local countHost = row.iconBorder or bd
    local countFS = carrier:CreateFontString(nil, "OVERLAY")
    ST.ApplyText(countFS, ST.FONT.caption)
    countFS:SetPoint("BOTTOMRIGHT", countHost, "BOTTOMRIGHT", -1, 1)
    countFS:SetJustifyH("RIGHT")
    countFS:SetText("")

    row.border, row.track, row.bar, row.carrier = bd, track, bar, carrier
    row.time, row.name, row.count = timeFS, nameFS, countFS
    return row
end

local function PaintRow(row, r, g, b)
    if not row then return end
    local lr, lg, lb = r * 0.70, g * 0.70, b * 0.70
    ST.ApplyBarGradient(row.bar, lr, lg, lb, math_min(1, r * 1.04), math_min(1, g * 1.04), math_min(1, b * 1.04), 0.96, false)
    -- 底槽 = 核心双翼血条的掉血底色：按条色轻染的半透明玻璃（深色条稍透一些），不是统一的近黑色块
    local a = (lr + lg + lb < 0.25) and 0.34 or 0.42
    row.track:SetVertexColor(lr * 0.16 + 0.06, lg * 0.16 + 0.06, lb * 0.16 + 0.08, a)
end

----------------------------------------------------------------------
-- 自绘条（武器附魔、兼容扫描模式下的特效、预览）
----------------------------------------------------------------------
local function AcquireRow(pool, parent, i)
    local row = pool[i]
    if row and row._gen ~= layoutGen then
        row.frame:Hide()
        row = nil
    end
    if not row then
        local f = CreateFrame("Frame", nil, parent)
        f:SetSize(layout.rowW, layout.h)
        f:EnableMouse(false)
        row = BuildRowRegions(f, layout)
        row.frame = f
        row._gen = layoutGen
        pool[i] = row
    end
    return row
end

-- 每帧都会调用：只在换了条目 / 颜色改过（colorGen 变化）时才重设文字与上色，不在每帧拼字符串
local function SetupRow(row, it)
    if row._item ~= it then
        row._item = it
        row._sec = nil
        row._colorGen = nil
        row.name:SetText(it.label or "")
        if row.icon then row.icon:SetTexture(it.icon or 134400) end
        local st = F.PlainNumber(it.stacks, 0) or 0
        row.count:SetText(st > 1 and tostring(st) or "")
    end
    if row._colorGen ~= colorGen then
        row._colorGen = colorGen
        PaintRow(row, GetColor(it.colorKey))
    end
end

local function FillRow(row, it, now)
    local dur = (it.dur and it.dur > 0) and it.dur or 1
    local rem = (it.exp or now) - now
    if rem < 0 then rem = 0 end
    if row._max ~= dur then
        row._max = dur
        row.bar:SetMinMaxValues(0, dur)
    end
    row.bar:SetValue(math_min(rem, dur))
    -- 倒计时文字每秒最多变一次：整秒没变就不重新格式化
    local sec = math_ceil(rem)
    if row._sec ~= sec then
        row._sec = sec
        local t = FormatRemain(rem)
        if row._t ~= t then
            row._t = t
            row.time:SetText(t)
        end
    end
end

local function PlaceRows(pool, anchor, count, up)
    if pool._n == count and pool._gen == layoutGen and pool._up == up then return end
    pool._n, pool._gen, pool._up = count, layoutGen, up
    local step = layout.h + layout.spacing
    for i = 1, count do
        local row = pool[i]
        local f = row.frame
        f:ClearAllPoints()
        if up then
            f:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, (i - 1) * step)
        else
            f:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, -(i - 1) * step)
        end
        f:Show()
    end
    for i = count + 1, #pool do
        if pool[i] then pool[i].frame:Hide() end
    end
end

local function HideRows(pool)
    for _, row in ipairs(pool) do row.frame:Hide() end
    pool._n = nil
end

----------------------------------------------------------------------
-- 武器附魔读取
----------------------------------------------------------------------
local ENCH_UNITS = {
    { "小时", 3600 }, { "分钟", 60 }, { "分", 60 }, { "秒", 1 },
    { "hour", 3600 }, { "hr", 3600 }, { "min", 60 }, { "sec", 1 },
}
local ENCH_SKIP_PREFIX = { "使用", "装备", "击中时", "Use:", "Equip:", "Chance on hit" }

-- 鼠标提示里的临时附魔行形如「致命毒药 V (29 分钟)」：去掉末尾带时间的括号，剩下的就是附魔名
local function ParseEnchantLine(text)
    local s = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    for _, p in ipairs(ENCH_SKIP_PREFIX) do
        if s:sub(1, #p) == p then return nil end
    end
    if s:find("冷却", 1, true) or s:lower():find("cooldown", 1, true) then return nil end
    local secs = nil
    for _ = 1, 3 do
        local head, inner = s:match("^(.-)%s*%(([^%(%)]*)%)%s*$")
        if not head then head, inner = s:match("^(.-)%s*（(.-)）%s*$") end
        if not head then break end
        local n = tonumber(inner:match("(%d+)") or "")
        if n and not secs then
            local low = inner:lower()
            for _, u in ipairs(ENCH_UNITS) do
                if low:find(u[1], 1, true) then
                    secs = n * u[2]
                    break
                end
            end
        end
        s = head
    end
    if secs and s ~= "" and #s <= 60 then return s, secs end
    return nil
end

local function TooltipEnchantLines(inv)
    local TI = _G.C_TooltipInfo
    if not (TI and TI.GetInventoryItem) then return nil end
    local ok, data = pcall(TI.GetInventoryItem, "player", inv)
    if not ok or F.IsSecret(data) or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local out = {}
    for _, line in ipairs(data.lines) do
        if type(line) == "table" then
            local text = F.PlainString(line.leftText, nil)
            local col = line.leftColor
            local green = true
            if type(col) == "table" and not F.IsSecret(col) then
                local cr, cg = F.PlainNumber(col.r, nil), F.PlainNumber(col.g, nil)
                if cr and cg then green = (cg > 0.7 and cr < 0.4) end
            end
            if text and green then
                local name, secs = ParseEnchantLine(text)
                if name then out[#out + 1] = { name = name, secs = secs } end
            end
        end
    end
    return out
end

-- 每把武器的附魔名只在附魔 ID 变化时读一次鼠标提示，按剩余时间最接近的行配对
local function ResolveEnchantNames(list)
    local byInv = {}
    for _, it in ipairs(list) do
        local ck = it.inv .. ":" .. tostring(it.enchantID)
        local cached = enchNameCache[ck]
        if cached ~= nil then
            -- false = 读过鼠标提示但没认出名称，不再反复读
            it.enchName = cached or nil
        else
            byInv[it.inv] = byInv[it.inv] or {}
            byInv[it.inv][#byInv[it.inv] + 1] = it
        end
    end
    for inv, items in pairs(byInv) do
        local lines = TooltipEnchantLines(inv)
        -- 这把武器只剩一个待认的附魔、提示里也只有一行候选：直接对上（提示里的分钟数是取整显示的）
        local single = lines and #lines == 1 and #items == 1
        for _, it in ipairs(items) do
            local bestI, bestD = nil, nil
            if single then
                bestI = 1
            elseif lines then
                for i, ln in ipairs(lines) do
                    local d = math_abs(ln.secs - it.left)
                    if d <= math_max(120, it.left * 0.15) and (not bestD or d < bestD) then
                        bestI, bestD = i, d
                    end
                end
            end
            local ck = inv .. ":" .. tostring(it.enchantID)
            if bestI then
                it.enchName = lines[bestI].name
                enchNameCache[ck] = it.enchName
                table_remove(lines, bestI)
            elseif lines then
                enchNameCache[ck] = false
            end
        end
    end
end

local function ReadEnchants()
    local out = {}
    local CI = _G.C_Item
    local WS = _G.Enum and _G.Enum.WeaponSlot
    local ET = _G.Enum and _G.Enum.ItemEnchantType
    if CI and CI.GetWeaponEnchantInfo and WS then
        for _, w in ipairs(WEAPONS) do
            local wsv = WS[w.ws]
            if wsv ~= nil then
                local ok, list = pcall(CI.GetWeaponEnchantInfo, wsv)
                if ok and not F.IsSecret(list) and type(list) == "table" then
                    for _, e in ipairs(list) do
                        if type(e) == "table" and not F.IsSecret(e) then
                            local has = e.hasEnchant
                            local leftMs = F.PlainNumber(e.timeLeft, nil)
                            if not F.IsSecret(has) and has == true and leftMs and leftMs > 0 then
                                local et = F.PlainNumber(e.enchantType, nil)
                                local imbue = ET ~= nil and ET.Imbue ~= nil and et ~= nil and et == ET.Imbue
                                out[#out + 1] = {
                                    slot = w.slot, inv = w.inv, weapon = w.label,
                                    kind = imbue and "imbue" or "temp",
                                    enchantID = F.PlainNumber(e.enchantID, 0) or 0,
                                    left = leftMs / 1000,
                                    charges = F.PlainNumber(e.charges, 0) or 0,
                                    icon = PlainIcon(e.enchantIconID),
                                }
                            end
                        end
                    end
                end
            end
        end
        return out
    end
    if _G.GetWeaponEnchantInfo then
        local ok, hasMH, mhExp, mhCh, mhID, hasOH, ohExp, ohCh, ohID, hasR, rExp, rCh, rID = pcall(_G.GetWeaponEnchantInfo)
        if not ok then return out end
        local raw = {
            { WEAPONS[1], hasMH, mhExp, mhCh, mhID },
            { WEAPONS[2], hasOH, ohExp, ohCh, ohID },
            { WEAPONS[3], hasR, rExp, rCh, rID },
        }
        for _, t in ipairs(raw) do
            local w, has, exp = t[1], t[2], F.PlainNumber(t[3], nil)
            if not F.IsSecret(has) and has and exp and exp > 0 then
                out[#out + 1] = {
                    slot = w.slot, inv = w.inv, weapon = w.label, kind = "temp",
                    enchantID = F.PlainNumber(t[5], 0) or 0,
                    left = exp / 1000,
                    charges = F.PlainNumber(t[4], 0) or 0,
                }
            end
        end
    end
    return out
end

-- 登录时已有的附魔不知道总时长：按常见时长档位（1/5/10/15/30/60/120 分钟）取整，进度条才不会从满格开始
local DURATION_BUCKETS = { 60, 300, 600, 900, 1800, 3600, 7200 }
local function BucketTotal(left)
    for _, b in ipairs(DURATION_BUCKETS) do
        if left <= b + 5 then return b end
    end
    return left
end

local function InvTexture(inv)
    if not _G.GetInventoryItemTexture then return nil end
    local ok, tex = pcall(_G.GetInventoryItemTexture, "player", inv)
    return ok and PlainIcon(tex) or nil
end

local function RefreshEnchants()
    local now = GetTime()
    local list = ReadEnchants()
    ResolveEnchantNames(list)
    for k in pairs(enchItems) do enchItems[k] = nil end
    -- 登录 / 过图后的头几秒读到的附魔是「早就涂上的」，总时长未知；之后新出现的才是刚涂上的
    local settled = (now - enchSessionStart) > 5
    for _, it in ipairs(list) do
        local tk = it.slot .. it.kind
        local exp = now + it.left
        local tr = enchTrack[tk]
        -- 同一个附魔：ID 相同且到期时间没有往后跳（重新涂抹会让到期时间变晚）。
        -- 读不到的附魔条目不删：过图时接口可能短暂返回空，回来后仍按原总时长续上
        local same = tr ~= nil and tr.id == it.enchantID and exp <= tr.exp + 3
        if not same then
            tr = { id = it.enchantID, total = settled and it.left or BucketTotal(it.left) }
            enchTrack[tk] = tr
        end
        tr.exp = exp
        if it.left > tr.total then tr.total = it.left end
        local kindLabel = (it.kind == "imbue") and "武器灌注" or "临时附魔"
        local label = it.weapon .. " · " .. (it.enchName or kindLabel)
        if it.charges and it.charges > 0 then label = label .. " ×" .. it.charges end
        enchItems[#enchItems + 1] = {
            label = label,
            icon = it.icon or InvTexture(it.inv),
            colorKey = "ench_" .. it.slot .. "_" .. ((it.kind == "imbue" and it.slot ~= "rg") and "imbue" or "temp"),
            exp = exp, dur = tr.total,
            order = (it.slot == "mh" and 1 or (it.slot == "oh" and 2 or 3)) * 10 + (it.kind == "imbue" and 0 or 1),
        }
    end
    table_sort(enchItems, function(a, b) return a.order < b.order end)
end

----------------------------------------------------------------------
-- 光环扫描（未受限时）：兼容模式下画特效条；引擎模式下只做「按名称识别 ID」与「最近出现的 Buff」列表
----------------------------------------------------------------------
local function RememberRecent(sid, name, icon, dur)
    if recent[sid] then
        recent[sid].t = GetTime()
        return
    end
    recent[sid] = { id = sid, name = name, icon = icon, dur = dur, t = GetTime() }
    recentOrder[#recentOrder + 1] = sid
    if #recentOrder > MAX_RECENT then
        local old = table_remove(recentOrder, 1)
        recent[old] = nil
    end
end

local function ScanAuras()
    if AurasRestricted() then return false end
    local CU = _G.C_UnitAuras
    local get = CU and CU.GetAuraDataByIndex
    if not get then return false end
    local found = {}
    for i = 1, 40 do
        local ok, a = pcall(get, "player", i, "HELPFUL")
        if not ok then return false end
        if not a then break end
        if type(a) == "table" and not F.IsSecret(a) then
            local sid = F.PlainNumber(a.spellId, nil)
            local name = F.PlainString(a.name, nil)
            local dur = F.PlainNumber(a.duration, nil)
            local exp = F.PlainNumber(a.expirationTime, nil)
            if sid and dur and dur > 0 and dur <= 180 then
                RememberRecent(sid, name, PlainIcon(a.icon), dur)
            end
            local e = (sid and idIndex[sid]) or (name and nameIndex[name]) or nil
            if e and e.enabled then
                if sid and not e.ids[sid] then Learn(e, sid) end
                if dur and exp and dur > 0 then
                    found[#found + 1] = {
                        entry = e, label = e.label, colorKey = e.key,
                        icon = PlainIcon(a.icon) or e.icon,
                        stacks = F.PlainNumber(a.applications, 0) or 0,
                        exp = exp, dur = dur,
                    }
                end
            end
        end
    end
    -- 兼容模式：按条目顺序排，同一条目最多两条
    local order = {}
    for i, e in ipairs(entries) do order[e] = i end
    table_sort(found, function(a, b)
        local oa, ob = order[a.entry] or 99, order[b.entry] or 99
        if oa ~= ob then return oa < ob end
        return a.exp < b.exp
    end)
    for k in pairs(scanItems) do scanItems[k] = nil end
    local perEntry = {}
    for _, it in ipairs(found) do
        local n = (perEntry[it.entry] or 0) + 1
        perEntry[it.entry] = n
        if n <= MAX_PER_ENTRY then scanItems[#scanItems + 1] = it end
    end
    return true
end

----------------------------------------------------------------------
-- 引擎光环容器（EllesmereUI AuraKit）
----------------------------------------------------------------------
local function EngineAvailable()
    local AK = GetAK()
    return AK ~= nil and type(AK.CreateContainerShell) == "function"
        and type(AK.AddGroupToContainer) == "function"
        and type(AK.FinishContainer) == "function"
        and type(AK.styles) == "table"
end

local function EngineActive()
    return engine.container ~= nil
end

local function ReleaseEngine()
    local c = engine.container
    engine.container = nil
    engine.hiddenForPreview = false
    for k in pairs(engine.styleKeys) do engine.styleKeys[k] = nil end
    if c then
        local AK = GetAK()
        if AK and AK.ReleaseContainer then
            pcall(AK.ReleaseContainer, c)
        else
            pcall(c.Hide, c)
        end
    end
end

-- 引擎按钮的创建窗口：此刻按钮子框体可读写，之后（光环受限时）一律被引擎拒绝
local function EngineInitButton(button, d, style)
    local ok, err = pcall(function()
        local AK = GetAK()
        local L = style.kkLayout
        if button.SetMouseClickEnabled then button:SetMouseClickEnabled(false) end
        if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(false) end
        local row = BuildRowRegions(button, L)
        d.kkRow = row
        PaintRow(row, GetColor(style.kkEntryKey))
        row.name:SetText(style.kkLabel or "")
        if row.icon then
            row.icon:SetTexture(style.kkIcon or 134400)
            pcall(button.SetIcon, button, row.icon)
        end
        local opts = {}
        local E = _G.Enum
        if E and E.StatusBarInterpolation then opts.interpolation = E.StatusBarInterpolation.Immediate end
        if E and E.StatusBarTimerDirection then opts.direction = E.StatusBarTimerDirection.RemainingTime end
        -- 与 EUI 团队框架同样的两级尝试：先带选项，不认选项的版本再裸调用
        local okBar = false
        if button.SetDurationBar then
            okBar = pcall(button.SetDurationBar, button, row.bar, opts)
            if not okBar then okBar = pcall(button.SetDurationBar, button, row.bar) end
        end
        if not okBar then engine.initErr = "SetDurationBar 不可用（条不会随时间缩短，倒计时文字仍有效）" end
        local fmt = AK.GetDurationFormatter and AK.GetDurationFormatter() or nil
        if AK.SetDurationTextSafe and AK.BuildDurationTextOpts then
            AK.SetDurationTextSafe(button, row.time, AK.BuildDurationTextOpts(fmt))
        else
            pcall(button.SetDurationText, button, row.time, { textFormatter = fmt })
        end
        if button.SetApplicationCount then pcall(button.SetApplicationCount, button, row.count, {}) end
    end)
    if not ok then engine.initErr = tostring(err) end
end

-- AuraKit 重新套用样式时（只在光环未受限时执行；受限时它自己推迟到解除后）只改颜色
local function EngineApplyExtra(button, d, style)
    if d and d.kkRow and style and style.kkEntryKey then
        PaintRow(d.kkRow, GetColor(style.kkEntryKey))
    end
end

local function EngineFingerprint(list)
    local parts = { layout.fp }
    for _, e in ipairs(list) do
        local ids = {}
        for _, id in ipairs(e.idList) do ids[#ids + 1] = id end
        table_sort(ids)
        parts[#parts + 1] = e.key .. "=" .. table.concat(ids, ",") .. "=" .. tostring(e.label)
    end
    return table.concat(parts, "|")
end

local function BuildEngine()
    if not mod._active or engine.failed or not EngineAvailable() or not procAnchor then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("kkowoUI_WeaponProcs_Engine", BuildEngine)
        return
    end
    local list = {}
    for _, e in ipairs(entries) do
        if e.enabled and e.idList[1] then list[#list + 1] = e end
    end
    local fp = EngineFingerprint(list)
    if engine.container and engine.fp == fp then return end
    ReleaseEngine()
    engine.fp = fp
    if #list == 0 then return end

    local AK = GetAK()
    local L = layout
    local FlowDir = _G.AnchorUtil and _G.AnchorUtil.FlowDirection
    local corner = L.up and "BOTTOMLEFT" or "TOPLEFT"
    engine.gen = engine.gen + 1
    local ok, err = pcall(function()
        local container = AK.CreateContainerShell(procAnchor, {
            point = { corner, procAnchor, corner, 0, 0 },
            layout = {
                anchorPoint = corner,
                padding = { 0, 0, 0, 0 },
                -- 每行只放得下一条：行宽 = 条宽 + 间距（引擎在每个元素后都追加 elementSpacing）
                rowWidth = L.rowW + L.spacing,
                growthH = FlowDir and FlowDir.Right or nil,
                growthV = FlowDir and (L.up and FlowDir.Up or FlowDir.Down) or nil,
            },
        })
        engine.container = container
        if AK.SetContainerAxis then pcall(AK.SetContainerAxis, container, false) end
        -- 排序枚举随 Blizzard_AuraContainer 按需加载（上面创建容器时才载入），所以这里再取
        local SM, SD = _G.AuraContainerSortMethod, _G.AuraContainerSortDirection
        local sortMethod = SM and SM.ExpirationOnly or nil
        local sortDir = SD and SD.Reverse or nil
        for _, e in ipairs(list) do
            local styleKey = "kkowoUI_wp_" .. e.key .. "_" .. engine.gen
            AK.styles[styleKey] = {
                noRegions = true,
                width = L.rowW,
                height = L.h,
                applyExtra = EngineApplyExtra,
                kkEntryKey = e.key,
                kkLabel = e.label,
                kkIcon = e.icon,
                kkLayout = L,
            }
            engine.styleKeys[e.key] = styleKey
            local ids = {}
            for _, id in ipairs(e.idList) do ids[id] = true end
            AK.AddGroupToContainer(container, {
                key = "kk_" .. e.key,
                filter = { "HELPFUL" },
                maxFrameCount = MAX_PER_ENTRY,
                sortMethod = sortMethod,
                sortDirection = sortDir,
                candidateFilters = { includeSpellIDs = ids },
                style = styleKey,
                extraInit = EngineInitButton,
                layout = {
                    elementWidth = L.rowW,
                    elementHeight = L.h,
                    elementSpacing = L.spacing,
                    lineSpacing = L.spacing,
                    groupSpacing = 0,
                    groupLineSpacing = L.spacing,
                },
            })
        end
        AK.FinishContainer(container, "player")
    end)
    if not ok then
        engine.failed = true
        ReleaseEngine()
        F.Print("|cffe05263武器特效计时条：引擎光环容器创建失败，已改用兼容扫描模式（战斗中可能不显示新触发）。|r " .. tostring(err))
    elseif engine.initErr then
        F.PrintOnce("kkowoUI_wp_initErr", "|cffe05263武器特效计时条：引擎条样式初始化出错：|r" .. engine.initErr)
    end
    if mod.SyncEngineVisibility then mod.SyncEngineVisibility() end
end

-- 尾随防抖：连续改动（拖滑块、连续识别到 ID）只在停下 0.35 秒后重建一次。
-- 每次重建都会新建一批引擎按钮（框体无法销毁），所以绝不能每一步都建
local engineBuildToken = 0
function mod:ScheduleEngineBuild()
    engineBuildToken = engineBuildToken + 1
    local my = engineBuildToken
    _G.C_Timer.After(0.35, function()
        if my ~= engineBuildToken then return end
        if mod._active then BuildEngine() end
    end)
end

local function RestyleEngine()
    local AK = GetAK()
    if not (AK and engine.container) then return end
    for _, styleKey in pairs(engine.styleKeys) do
        if AK.RestyleSoon then
            AK.RestyleSoon(styleKey)
        elseif AK.Restyle and not AurasRestricted() then
            pcall(AK.Restyle, styleKey)
        end
    end
end

----------------------------------------------------------------------
-- 显示与刷新
----------------------------------------------------------------------
local function EnchantVisible(it, now)
    local mode = mod:GetDB().enchantMode or "always"
    if mode == "off" then return false end
    if mode == "combat" then return inCombat end
    if mode == "low" then
        local lim = (F.PlainNumber(mod:GetDB().enchantLowMinutes, 5) or 5) * 60
        return (it.exp - now) <= lim
    end
    return true
end

local visibleEnch = {}
local function CurrentProcItems()
    if previewItems then return previewItems.procs end
    if EngineActive() then return nil end
    return scanItems
end

local function Render()
    if not (mod._active and layout) then return false end
    local now = GetTime()
    local live = false

    -- 特效：预览 / 兼容扫描时自绘；引擎模式下由引擎绘制
    local procs = CurrentProcItems()
    local np = 0
    if procs then
        for i = #procs, 1, -1 do
            local it = procs[i]
            if not it.loop and it.exp <= now then table_remove(procs, i) end
        end
        for _, it in ipairs(procs) do
            if it.loop and it.exp <= now then it.exp = now + it.dur end
            np = np + 1
            local row = AcquireRow(procRows, procAnchor, np)
            SetupRow(row, it)
            FillRow(row, it, now)
        end
        live = np > 0
    end
    PlaceRows(procRows, procAnchor, np, layout.up)

    -- 武器附魔
    local src = previewItems and previewItems.ench or enchItems
    local enchOff = (mod:GetDB().enchantMode == "off")
    for k in pairs(visibleEnch) do visibleEnch[k] = nil end
    for _, it in ipairs(src) do
        if it.loop and it.exp <= now then it.exp = now + it.dur end
        if it.exp > now and not enchOff and (previewItems or EnchantVisible(it, now)) then
            visibleEnch[#visibleEnch + 1] = it
        end
    end
    for i, it in ipairs(visibleEnch) do
        local row = AcquireRow(enchRows, enchAnchor, i)
        SetupRow(row, it)
        FillRow(row, it, now)
    end
    PlaceRows(enchRows, enchAnchor, #visibleEnch, false)
    -- 附魔条显示中要刷新剩余时间；「剩余不足」模式下还要盯着门槛，其它情况靠事件唤醒
    local mode = mod:GetDB().enchantMode
    return live or #visibleEnch > 0 or (#src > 0 and mode == "low")
end

local function OnTick(self, elapsed)
    tickAccum = tickAccum + (elapsed or 0)
    -- 特效条每帧平滑；只有附魔时 4 次/秒就够
    local procLive = (previewItems ~= nil) or (not EngineActive() and #scanItems > 0)
    if not procLive and tickAccum < 0.25 then return end
    tickAccum = 0
    if not Render() then self:SetScript("OnUpdate", nil) end
end

local function Wake()
    if not driver then return end
    Render()
    driver:SetScript("OnUpdate", OnTick)
end

local function FullRefresh(immediate)
    if not mod._active then return end
    local L = ComputeLayout()
    -- 只有外观参数真的变了才换新一代自绘条（过图等刷新不重建，避免白白多建框体）
    if not layout or layout.fp ~= L.fp or layout.font ~= L.font then
        layoutGen = layoutGen + 1
    end
    layout = L
    procAnchor:SetSize(layout.rowW, layout.h)
    enchAnchor:SetSize(layout.rowW, layout.h)
    BuildEntries()
    RefreshEnchants()
    ScanAuras()
    -- 登录 / 过图立即建；设置页改动走尾随防抖（指纹没变时 BuildEngine 直接返回，不会重建）
    if immediate then BuildEngine() else mod:ScheduleEngineBuild() end
    Wake()
end

----------------------------------------------------------------------
-- 预览（设置页开关 / EUI 解锁模式）
----------------------------------------------------------------------
local function BuildPreviewItems()
    local now = GetTime()
    local procs, n = {}, 0
    for _, e in ipairs(entries) do
        if e.enabled and n < 4 then
            n = n + 1
            procs[#procs + 1] = {
                label = e.label, colorKey = e.key, icon = e.icon,
                stacks = (e.key == "bonereaver") and 2 or 0,
                dur = 15, exp = now + 15 - n * 3.5, loop = true,
            }
        end
    end
    if n == 0 then
        procs[1] = { label = "攻击特效示例", colorKey = "crusader", icon = SpellIcon(20007), dur = 15, exp = now + 11, loop = true }
    end
    local ench = {
        { label = "主手 · 临时附魔（示例）", colorKey = "ench_mh_temp", icon = InvTexture(16), dur = 1800, exp = now + 1500, loop = true },
        { label = "副手 · 武器灌注（示例）", colorKey = "ench_oh_imbue", icon = InvTexture(17), dur = 300, exp = now + 140, loop = true },
    }
    return { procs = procs, ench = ench }
end

-- 预览时把引擎容器藏起来，示例条画在同一位置；预览结束再显示并让引擎重新读一遍光环
local function SyncEngineVisibility()
    local c = engine.container
    if not c then return end
    local hide = previewItems ~= nil
    if hide and not engine.hiddenForPreview then
        engine.hiddenForPreview = true
        pcall(c.Hide, c)
    elseif not hide and engine.hiddenForPreview then
        engine.hiddenForPreview = false
        pcall(c.Show, c)
        if c.UpdateAllAuras then pcall(c.UpdateAllAuras, c) end
    end
end
mod.SyncEngineVisibility = SyncEngineVisibility

local function ApplyPreviewState()
    local want = mod._active and (previewOn or previewByUnlock)
    if want then
        if not previewItems then previewItems = BuildPreviewItems() end
    else
        previewItems = nil
    end
    SyncEngineVisibility()
    if mod._active then Wake() end
end

function mod:SetPreview(on)
    previewOn = on == true
    if previewOn and _G.InCombatLockdown and _G.InCombatLockdown() then previewOn = false end
    previewItems = nil   -- 条目可能变了：按当前设置重建示例
    ApplyPreviewState()
end

function mod:TogglePreview()
    if not self._active then
        F.Print("武器附魔与特效计时条未启用。")
        return
    end
    self:SetPreview(not previewOn)
    F.Print(previewOn and "已显示武器特效计时条示例，可用 /kk unlock 拖动位置；再次输入 /kk wp 关闭。" or "已关闭武器特效计时条示例。")
end

----------------------------------------------------------------------
-- 自定义条目
----------------------------------------------------------------------
local function NewCustomKey()
    local db = mod:GetDB()
    local n = 1
    while true do
        local key = "custom" .. n
        local used = false
        for _, c in ipairs(db.custom) do
            if c.key == key then used = true break end
        end
        if not used then return key end
        n = n + 1
    end
end

local function HasEntryForID(id)
    return id and idIndex[id] ~= nil
end

function mod:AddCustom(id, name)
    local db = self:GetDB()
    id = F.PlainNumber(id, nil)
    name = F.PlainString(name, nil)
    if id and HasEntryForID(id) then
        return false, "这个法术已经在列表里了：" .. tostring(idIndex[id].label)
    end
    if not id and name and nameIndex[name] then
        return false, "这个名称已经在列表里了：" .. name
    end
    if not id and not name then return false, nil end
    db.custom[#db.custom + 1] = { key = NewCustomKey(), id = id, name = name or SpellName(id) }
    FullRefresh()
    return true, nil
end

local function ResolveSpellID(text)
    local CS = _G.C_Spell
    if CS and CS.GetSpellIDForSpellIdentifier then
        local ok, sid = pcall(CS.GetSpellIDForSpellIdentifier, text)
        sid = ok and F.PlainNumber(sid, nil) or nil
        if sid then return sid end
    end
    if CS and CS.GetSpellInfo then
        local ok, info = pcall(CS.GetSpellInfo, text)
        if ok and type(info) == "table" and not F.IsSecret(info) then
            local sid = F.PlainNumber(info.spellID, nil)
            if sid then return sid end
        end
    end
    for _, sid in ipairs(recentOrder) do
        if recent[sid] and recent[sid].name == text then return sid end
    end
    return nil
end

function mod:AddCustomFromText(text)
    text = F.PlainString(text, "") or ""
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false, nil end
    local id = tonumber(text)
    if id then
        id = math_floor(id)
        if not SpellName(id) then return false, "找不到法术 ID " .. id .. "。" end
        return self:AddCustom(id, SpellName(id))
    end
    local sid = ResolveSpellID(text)
    if sid then return self:AddCustom(sid, text) end
    local ok, msg = self:AddCustom(nil, text)
    if ok then
        msg = "已按名称添加「" .. text .. "」：下次在脱战（光环可读）时出现会自动识别法术 ID，之后战斗中也能显示。"
    end
    return ok, msg
end

function mod:RemoveCustom(key)
    local db = self:GetDB()
    for i = #db.custom, 1, -1 do
        if db.custom[i].key == key then table_remove(db.custom, i) end
    end
    db.colors[key] = nil
    db.learned[key] = nil
    FullRefresh()
end

----------------------------------------------------------------------
-- 生命周期
----------------------------------------------------------------------
local function EnsureFrames()
    if procAnchor then return end
    procAnchor = CreateFrame("Frame", "kkowoUI_WeaponProcBars", _G.UIParent)
    procAnchor:SetSize(190, 16)
    procAnchor:SetFrameStrata("MEDIUM")
    procAnchor:SetFrameLevel(20)
    procAnchor:EnableMouse(false)

    enchAnchor = CreateFrame("Frame", "kkowoUI_WeaponEnchantBars", _G.UIParent)
    enchAnchor:SetSize(190, 16)
    enchAnchor:SetFrameStrata("MEDIUM")
    enchAnchor:SetFrameLevel(20)
    enchAnchor:EnableMouse(false)

    driver = CreateFrame("Frame")
end

local function RegisterMovers()
    F.Mover.Register({
        key = "WeaponProcBars",
        label = "武器攻击特效计时条",
        frame = procAnchor,
        order = 17,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 285,
        defaultY = -215,
        allowShiftDrag = false,
        isHidden = function() return not mod._active end,
    })
    F.Mover.Register({
        key = "WeaponEnchantBars",
        label = "武器附魔计时条",
        frame = enchAnchor,
        order = 18,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 285,
        defaultY = -241,
        allowShiftDrag = false,
        isHidden = function() return not (mod._active and mod:GetDB().enchantMode ~= "off") end,
    })
end

local function QueueAuraScan()
    if auraScanPending then return end
    auraScanPending = true
    _G.C_Timer.After(0.05, function()
        auraScanPending = false
        if not mod._active then return end
        if ScanAuras() and not EngineActive() then Wake() end
    end)
end

function mod:OnEnable()
    EnsureFrames()
    procAnchor:Show()
    enchAnchor:Show()
    RegisterMovers()
    RequestItemData()
    inCombat = (_G.InCombatLockdown and _G.InCombatLockdown()) == true
    engine.failed = false
    enchSessionStart = GetTime()
    FullRefresh(true)

    self:RegisterUnitEvent("UNIT_AURA", "player", QueueAuraScan)
    self:RegisterEvent("WEAPON_ENCHANT_CHANGED", function() RefreshEnchants(); Wake() end)
    self:RegisterEvent("WEAPON_SLOT_CHANGED", function() RefreshEnchants(); Wake() end)
    self:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player", function() RefreshEnchants(); Wake() end)
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function() RefreshEnchants(); Wake() end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        enchSessionStart = GetTime()
        FullRefresh(true)
    end)
    self:RegisterEvent("SPELLS_CHANGED", function()
        -- 法术数据到齐后补上名称 / 图标（登录首帧 GetSpellName 可能还没缓存）
        local before = {}
        for _, e in ipairs(entries) do before[e.key] = e.label end
        BuildEntries()
        for _, e in ipairs(entries) do
            if before[e.key] ~= e.label then mod:ScheduleEngineBuild() break end
        end
    end)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        inCombat = true
        if previewOn then
            previewOn = false
            ApplyPreviewState()
        end
        Wake()
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        inCombat = false
        QueueAuraScan()
        RefreshEnchants()
        Wake()
    end)

    local EUI = _G.EllesmereUI
    if EUI and EUI.RegisterUnlockModeListener then
        pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_WeaponProcs", function(active)
            previewByUnlock = active == true
            if mod._active then ApplyPreviewState() end
        end)
    end
end

function mod:OnDisable()
    local EUI = _G.EllesmereUI
    if EUI and EUI.UnregisterUnlockModeListener then
        pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_WeaponProcs")
    end
    previewOn, previewByUnlock, previewItems = false, false, nil
    ReleaseEngine()
    engine.fp = nil
    if driver then driver:SetScript("OnUpdate", nil) end
    HideRows(procRows)
    HideRows(enchRows)
    for k in pairs(scanItems) do scanItems[k] = nil end
    if procAnchor then procAnchor:Hide() end
    if enchAnchor then enchAnchor:Hide() end
end

function mod:OnRefresh()
    FullRefresh()
end

function mod:OnThemeChanged()
    FullRefresh()
end

-- 设置页改动后调用：只改颜色走轻量重绘，结构性改动（条目 / 尺寸 / 方向）整体重建。
-- 结构性改动同样尾随防抖：拖滑块时只在停下后重建一次自绘条
local structuralToken = 0
local function QueueStructural()
    structuralToken = structuralToken + 1
    local my = structuralToken
    _G.C_Timer.After(0.15, function()
        if my == structuralToken and mod._active then FullRefresh() end
    end)
end

local function ColorsChanged()
    colorGen = colorGen + 1
    RestyleEngine()
    if mod._active then Wake() end
end

----------------------------------------------------------------------
-- 设置页
----------------------------------------------------------------------
local function EntrySourceText(e)
    local p = e.preset
    if p then
        if p.source then return p.source end
        if p.item then return "武器：" .. (ItemName(p.item) or ("物品 #" .. p.item)) end
    end
    return "自定义"
end

local function ColorSwatch(key)
    return {
        tooltip = nil,
        hasAlpha = false,
        getValue = function() return GetColor(key) end,
        setValue = function(r, g, b)
            mod:GetDB().colors[key] = { r, g, b }
            ColorsChanged()
        end,
    }
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local EUI = _G.EllesmereUI
    local function RebuildPage()
        if EUI and EUI.RefreshPage then pcall(EUI.RefreshPage, EUI, true) end
    end
    local Structural = QueueStructural
    if not self._active then BuildEntries() end
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "显示示例条（摆放位置用）",
        tooltip = "显示示例计时条，再用 EUI 解锁模式（/kk unlock）拖动「武器攻击特效计时条」「武器附魔计时条」两个框；进入战斗自动关闭。也可输入 /kk wp 开关。",
        disabled = function() return not mod._active end,
        getValue = function() return previewOn end,
        setValue = function(v) mod:SetPreview(v == true) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider", text = "条宽度（含图标）", min = 120, max = 340, step = 5,
        getValue = function() return F.PlainNumber(db.width, 190) or 190 end,
        setValue = function(v) db.width = math_floor(v + 0.5); Structural() end,
    }, {
        type = "slider", text = "条高度", min = 10, max = 28, step = 1,
        getValue = function() return F.PlainNumber(db.height, 16) or 16 end,
        setValue = function(v) db.height = math_floor(v + 0.5); Structural() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider", text = "条间距", min = 0, max = 10, step = 1,
        getValue = function() return F.PlainNumber(db.spacing, 3) or 3 end,
        setValue = function(v) db.spacing = math_floor(v + 0.5); Structural() end,
    }, {
        type = "dropdown", text = "特效条叠加方向",
        values = { up = "向上叠加", down = "向下叠加" },
        order = { "up", "down" },
        getValue = function() return db.procGrow == "down" and "down" or "up" end,
        setValue = function(v) db.procGrow = v; Structural() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle", text = "显示图标",
        getValue = function() return db.showIcon ~= false end,
        setValue = function(v) db.showIcon = v == true; Structural() end,
    }, {
        type = "toggle", text = "显示名称",
        getValue = function() return db.showName ~= false end,
        setValue = function(v) db.showName = v == true; Structural() end,
    })
    y = y - h

    -- 武器附魔
    _, h = W:DualRow(parent, y, {
        type = "dropdown", text = "武器附魔计时条",
        tooltip = "毒药 / 磨刀石 / 武器油（临时附魔）与萨满武器技能、盗贼毒药等（职业灌注）的剩余时间。",
        values = { always = "有附魔时始终显示", combat = "仅战斗中显示", low = "剩余不足时才显示", off = "不显示" },
        order = { "always", "combat", "low", "off" },
        getValue = function() return db.enchantMode or "always" end,
        setValue = function(v) db.enchantMode = v; if mod._active then Wake() end end,
    }, {
        type = "slider", text = "「剩余不足」阈值（分钟）", min = 1, max = 30, step = 1,
        disabled = function() return db.enchantMode ~= "low" end,
        getValue = function() return F.PlainNumber(db.enchantLowMinutes, 5) or 5 end,
        setValue = function(v) db.enchantLowMinutes = math_floor(v + 0.5); if mod._active then Wake() end end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "multiSwatch", text = "临时附魔颜色：主手 / 副手 / 远程",
        swatches = { ColorSwatch("ench_mh_temp"), ColorSwatch("ench_oh_temp"), ColorSwatch("ench_rg_temp") },
    }, {
        type = "multiSwatch", text = "职业灌注颜色：主手 / 副手",
        swatches = { ColorSwatch("ench_mh_imbue"), ColorSwatch("ench_oh_imbue") },
    })
    y = y - h

    -- 攻击特效
    local modeText
    if engine.container then
        modeText = "攻击特效：引擎光环容器驱动（战斗中也能显示）"
    elseif engine.failed or not EngineAvailable() then
        modeText = "攻击特效：兼容扫描模式（战斗中光环受限时新触发可能不显示）"
    else
        modeText = "攻击特效：勾选下面的特效后生效"
    end
    _, h = W:DualRow(parent, y, {
        type = "label", text = modeText,
        tooltip = "只能追踪会给自己加 Buff 的特效（例如十字军的「神圣力量」）。烈焰武器、生命偷取、正义之手额外攻击这类不加 Buff 的效果，"
            .. "需要战斗日志，无限服不对插件开放，无法计时。\n\n引擎模式按法术 ID 匹配：自定义特效最好填法术 ID；只填名称的，会在脱战可读时自动识别 ID。",
    }, blank)
    y = y - h

    for _, e in ipairs(entries) do
        local ent = e
        if ent.preset then
            _, h = W:DualRow(parent, y, {
                type = "toggle",
                text = ent.label,
                tooltip = EntrySourceText(ent) .. "\n法术 ID：" .. table.concat(ent.idList, " / "),
                getValue = function() return db.presetOn[ent.key] ~= false end,
                setValue = function(v)
                    if v then db.presetOn[ent.key] = nil else db.presetOn[ent.key] = false end
                    Structural()
                end,
            }, {
                type = "colorpicker", text = "条颜色",
                getValue = function() return GetColor(ent.key) end,
                setValue = function(r, g, b)
                    db.colors[ent.key] = { r, g, b }
                    ColorsChanged()
                end,
            })
            y = y - h
        end
    end

    for _, e in ipairs(entries) do
        local ent = e
        if ent.custom then
            local idText = ent.idList[1] and table.concat(ent.idList, " / ") or "未识别（脱战时出现后自动识别）"
            _, h = W:DualRow(parent, y, {
                type = "colorpicker",
                text = ent.label,
                tooltip = "自定义特效\n法术 ID：" .. idText,
                getValue = function() return GetColor(ent.key) end,
                setValue = function(r, g, b)
                    db.colors[ent.key] = { r, g, b }
                    ColorsChanged()
                end,
            }, {
                type = "button", text = "删除「" .. ent.label .. "」", width = 200, noCapture = true,
                onClick = function()
                    mod:RemoveCustom(ent.key)
                    RebuildPage()
                end,
            })
            y = y - h
        end
    end

    local recentValues, recentKeys = { ["_"] = "选择一个 Buff…" }, { "_" }
    for i = #recentOrder, 1, -1 do
        local sid = recentOrder[i]
        local r = recent[sid]
        if r and not HasEntryForID(sid) then
            local k = tostring(sid)
            local icon = r.icon and ("|T" .. tostring(r.icon) .. ":14:14:0:0:64:64:5:59:5:59|t ") or ""
            recentValues[k] = icon .. (r.name or ("法术 " .. k)) .. " (" .. k .. ")"
            recentKeys[#recentKeys + 1] = k
        end
    end
    _, h = W:DualRow(parent, y, {
        type = "input", text = "添加特效：法术 ID 或 Buff 名称",
        inputWidth = 140, inputStyle = "popup", placeholder = "例如 20007",
        getValue = function() return "" end,
        setValue = function(text)
            local ok, msg = mod:AddCustomFromText(text)
            if msg then F.Print(msg) end
            if ok then RebuildPage() end
        end,
    }, {
        type = "dropdown", text = "从最近出现过的 Buff 添加",
        tooltip = "列出本次登录后脱战时读到的、持续 3 分钟以内的 Buff。",
        values = recentValues,
        order = recentKeys,
        getValue = function() return "_" end,
        setValue = function(v)
            local sid = tonumber(v)
            if sid then
                local r = recent[sid]
                local ok, msg = mod:AddCustom(sid, r and r.name or nil)
                if msg then F.Print(msg) end
                if ok then RebuildPage() end
            end
        end,
    })
    y = y - h

    _, h = W:WideButton(parent, "恢复全部默认颜色", y, function()
        for k in pairs(db.colors) do db.colors[k] = nil end
        ColorsChanged()
        RebuildPage()
    end)
    y = y - h
    return y
end
