----------------------------------------------------------------------
--  kkowoUI — Modules/AuraBarSkin.lua
--  小地图左侧增益 / 减益图标现代圆角美化（零污染 BuffFrame / DebuffFrame）：
--    • 绝不向 BuffFrame / DebuffFrame 暴雪全局表写入任何自定义字段（全弱表）
--    • 严格按 btn.Icon 正方形区域建立独立 iconWrap 套壳（不包入底部倒计时空白区）
--    • 现代高清裁边（0.08~0.92）+ GPU 9 宫格圆角遮罩 + 1px 暗灰/减益类型语义色描边
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_min, pcall, setmetatable, type =
    ipairs, math.floor, math.max, math.min, pcall, setmetatable, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local ST = F.StyleTokens

local mod = F.RegisterModule("auraBarSkin", {
    title = "小地图左侧增益 / 减益圆角美化",
    desc = "将小地图左侧的增益与减益图标升级为现代圆角裁边 + 1px 语义细描边 + 清晰计时排版（零污染，关闭即还原）。",
    group = "motion",
    order = 6,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        radius = 5,
        showShadow = true,
        colorDebuffBorder = true,
    },
})

local ROOT_NAMES = { "BuffFrame", "DebuffFrame" }
local skinned = setmetatable({}, { __mode = "k" })
local origBorderAlpha = setmetatable({}, { __mode = "k" })
local origCountStyle = setmetatable({}, { __mode = "k" })
local buttonList = {}

local BORDER_KEYS = { "Border", "DebuffBorder", "TempEnchantBorder" }

local function SetSquareBorder(ov, show, r, g, b, a)
    if not ov or not ov.wrap then return end
    if show and not ov.sqEdges then
        local edges = {}
        local specs = {
            { "TOPLEFT", "TOPRIGHT", nil, 1 },
            { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 1 },
            { "TOPLEFT", "BOTTOMLEFT", 1, nil },
            { "TOPRIGHT", "BOTTOMRIGHT", 1, nil },
        }
        for i, sp in ipairs(specs) do
            local ln = ov.wrap:CreateTexture(nil, "OVERLAY", nil, 4)
            ln:SetPoint(sp[1], ov.wrap, sp[1])
            ln:SetPoint(sp[2], ov.wrap, sp[2])
            if sp[3] then ln:SetWidth(sp[3]) end
            if sp[4] then ln:SetHeight(sp[4]) end
            edges[i] = ln
        end
        ov.sqEdges = edges
    end
    if ov.sqEdges then
        for _, ln in ipairs(ov.sqEdges) do
            if show then
                ln:SetColorTexture(r, g, b, a)
                ln:Show()
            else
                ln:Hide()
            end
        end
    end
end

local function IsSafe(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function ResolveBorderColor(btn, isDebuff)
    if not isDebuff or mod:GetDB().colorDebuffBorder == false then
        return 0.14, 0.16, 0.22, 0.90
    end
    local b = btn.Border or btn.DebuffBorder
    if b and b.GetVertexColor then
        local ok, r, g, bCol = pcall(b.GetVertexColor, b)
        r = ok and F.PlainNumber(r, nil) or nil
        g = ok and F.PlainNumber(g, nil) or nil
        bCol = ok and F.PlainNumber(bCol, nil) or nil
        if r and g and bCol and not (r > 0.92 and g > 0.92 and bCol > 0.92) then
            return r, g, bCol, 0.96
        end
    end
    return 0.88, 0.26, 0.30, 0.95
end

local function SkinAuraButton(btn, isDebuff)
    if not IsSafe(btn) then return end
    local icon = btn.Icon or btn.icon
    if not (icon and icon.SetTexCoord) then return end

    local db = mod:GetDB()
    local rad = math_max(0, math_min(10, F.PlainNumber(db.radius, ST.GetCornerRadius(5)) or 5))

    -- 清除任何可能残留在外层 btn（含底部文字高度）上的旧遮罩/边框，只作用于 icon 正方形本身
    ST.ClearRoundedMask(btn)

    local ov = skinned[btn]
    if not mod._active then
        if ov and ov.wrap then
            ST.ClearRoundedMask(ov.wrap)
            SetSquareBorder(ov, false)
            ov.wrap:Hide()
        end
        if ov and ov.bgHost then
            ST.ClearRoundedMask(ov.bgHost)
            ov.bgHost:Hide()
        end
        if ov and ov.bg then ov.bg:Hide() end
        pcall(icon.SetTexCoord, icon, 0, 1, 0, 1)
        for _, bk in ipairs(BORDER_KEYS) do
            local brd = btn[bk]
            if brd and origBorderAlpha[brd] ~= nil and brd.SetAlpha then
                pcall(brd.SetAlpha, brd, origBorderAlpha[brd])
            end
        end
        local cnt = btn.Count
        local oc = cnt and origCountStyle[cnt]
        if cnt and oc then
            if oc.face and cnt.SetFont then pcall(cnt.SetFont, cnt, oc.face, oc.size, oc.flags) end
            if oc.r and cnt.SetTextColor then pcall(cnt.SetTextColor, cnt, oc.r, oc.g, oc.b, oc.a) end
        end
        return
    end

    if not ov then
        ov = {}
        -- 严格贴合 icon 正方形的独立包装框，绝不把底部倒计时留白框进圆角里
        local wrap = CreateFrame("Frame", nil, btn)
        wrap:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
        wrap:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
        wrap:EnableMouse(false)
        local lvl = F.PlainNumber(btn.GetFrameLevel and btn:GetFrameLevel(), 5) or 5
        wrap:SetFrameLevel(lvl + 1)

        -- 独立外扩 1px 底衬遮罩宿主，避免被 wrap 内缩圆角遮罩裁成不可见
        local bgHost = CreateFrame("Frame", nil, btn)
        bgHost:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        bgHost:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        bgHost:EnableMouse(false)
        bgHost:SetFrameLevel(lvl)

        local bg = bgHost:CreateTexture(nil, "BACKGROUND", nil, -6)
        bg:SetAllPoints(bgHost)
        bg:SetColorTexture(0.03, 0.035, 0.045, 0.72)

        ov.wrap = wrap
        ov.bgHost = bgHost
        ov.bg = bg
        skinned[btn] = ov
        buttonList[#buttonList + 1] = btn
    end

    ov.wrap:ClearAllPoints()
    ov.wrap:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
    ov.wrap:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
    ov.wrap:Show()
    if ov.bgHost then
        ov.bgHost:ClearAllPoints()
        ov.bgHost:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
        ov.bgHost:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        ov.bgHost:Show()
    end

    pcall(icon.SetTexCoord, icon, 0.08, 0.92, 0.08, 0.92)
    if ov.bg then
        local showSh = db.showShadow ~= false
        ov.bg:SetShown(showSh)
        if showSh and rad > 0 and ov.bgHost then
            ST.MaskTexture(ov.bgHost, ov.bg, math_min(12, rad + 1))
        elseif ov.bgHost then
            ST.ClearRoundedMask(ov.bgHost)
        end
    end

    -- 静音暴雪厚重方形原生边框（含 Border / DebuffBorder / TempEnchantBorder），改由 1px 描边呈现
    for _, bk in ipairs(BORDER_KEYS) do
        local brd = btn[bk]
        if brd and brd.SetAlpha then
            if origBorderAlpha[brd] == nil and brd.GetAlpha then
                local okA, a = pcall(brd.GetAlpha, brd)
                origBorderAlpha[brd] = (okA and F.PlainNumber(a, 1)) or 1
            end
            pcall(brd.SetAlpha, brd, 0)
        end
    end

    local r, g, b, a = ResolveBorderColor(btn, isDebuff)
    if rad > 0 then
        SetSquareBorder(ov, false)
        ST.SetHostIconMode(ov.wrap, true)
        ST.ApplyRoundedBorder(ov.wrap, rad, r, g, b, a, 4)
        ST.MaskIcon(ov.wrap, icon, rad)
    else
        ST.ClearRoundedMask(ov.wrap)
        SetSquareBorder(ov, true, r, g, b, a)
    end

    if btn.Count and btn.Count.SetFont then
        if not origCountStyle[btn.Count] then
            local rec = {}
            if btn.Count.GetFont then
                local okF, face, sz, fl = pcall(btn.Count.GetFont, btn.Count)
                if okF and type(face) == "string" and face ~= "" then
                    rec.face, rec.size, rec.flags = face, F.PlainNumber(sz, 12) or 12, F.PlainString(fl, "") or ""
                end
            end
            if btn.Count.GetTextColor then
                local okC, cr, cg, cb, ca = pcall(btn.Count.GetTextColor, btn.Count)
                if okC then
                    rec.r = F.PlainNumber(cr, 1) or 1
                    rec.g = F.PlainNumber(cg, 1) or 1
                    rec.b = F.PlainNumber(cb, 1) or 1
                    rec.a = F.PlainNumber(ca, 1) or 1
                end
            end
            origCountStyle[btn.Count] = rec
        end
        F.Theme.ApplyFont(btn.Count, 11, "OUTLINE", 1, 0.96, 0.80, 1)
    end
end

local function VisitContainer(c, isDebuff)
    if not (IsSafe(c) and c.GetChildren) then return end
    for _, ch in ipairs({ c:GetChildren() }) do
        if IsSafe(ch) and (ch.Icon or ch.icon) then
            SkinAuraButton(ch, isDebuff)
        end
    end
end

local function RefreshAllAuras()
    for idx, rootName in ipairs(ROOT_NAMES) do
        local isDebuff = (idx == 2)
        local root = _G[rootName]
        if IsSafe(root) then
            if type(root.auraFrames) == "table" then
                for _, btn in ipairs(root.auraFrames) do
                    SkinAuraButton(btn, isDebuff)
                end
            else
                VisitContainer(root.AuraContainer, isDebuff)
                VisitContainer(root, isDebuff)
            end
        end
    end
end

local QueueRefresh = F.Debounce(0.10, RefreshAllAuras)

function mod:OnEnable()
    self:RegisterUnitEvent("UNIT_AURA", "player", QueueRefresh)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        QueueRefresh()
        C_Timer.After(0.8, function() if mod._active then RefreshAllAuras() end end)
    end)
    RefreshAllAuras()
end

function mod:OnDisable()
    for _, btn in ipairs(buttonList) do
        if IsSafe(btn) then
            SkinAuraButton(btn, false)
        end
    end
end

function mod:OnRefresh()
    RefreshAllAuras()
end

function mod:OnThemeChanged()
    RefreshAllAuras()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "slider",
        text = "增益图标圆角半径（px）",
        min = 0, max = 10, step = 1,
        getValue = function() return F.PlainNumber(db.radius, 5) or 5 end,
        setValue = function(v) db.radius = math_floor(v + 0.5); RefreshAllAuras() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "减益按法术类型着色圆角细框",
        tooltip = "魔法蓝、诅咒紫、中毒绿、疾病棕、物理/流血红，一目了然。",
        getValue = function() return db.colorDebuffBorder ~= false end,
        setValue = function(v) db.colorDebuffBorder = v == true; RefreshAllAuras() end,
    }, {
        type = "toggle",
        text = "柔和暗色底衬",
        getValue = function() return db.showShadow ~= false end,
        setValue = function(v) db.showShadow = v == true; RefreshAllAuras() end,
    })
    y = y - h

    return y
end
