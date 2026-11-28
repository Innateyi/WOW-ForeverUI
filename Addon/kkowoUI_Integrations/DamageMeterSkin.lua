----------------------------------------------------------------------
--  kkowoUI_Integrations — DamageMeterSkin.lua
--  零补丁美化 EllesmereUIDamageMeters：
--    • 悬停明细卡片（_ttFrame）：统一为 kkowoUI 圆角黑曜石类 PrettyTooltip 面板
--      （深色纵向渐变 + 顶色带 + 2px 亮顶边 + 外柔光 + 抗锯齿圆角）
--    • 明细内技能/目标条与技能图标：圆角进度条 + 圆角技能图标 + 柔和暗底轨
--    • 主伤害统计条（rowPool / stickyPlayer）：12.1 保密值安全 C++ 锚点圆角遮罩
--    • 100% 弱表、零污染、关闭即刻无损还原
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, math_floor, math_max, math_min, pairs, pcall, select, setmetatable, tostring, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, select, setmetatable, tostring, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local ST = F.StyleTokens

local mod = F.RegisterModule("damageMeterSkin", {
    title = "伤害统计美化",
    desc = "为伤害统计主进度条与悬停明细卡应用统一圆角与卡片样式。",
    group = "theme",
    order = 12,
    defaults = {
        enabled = true,
        skinTooltip = true,
        roundMainBars = true,
        barRadius = 4,
        tooltipRadius = 8,
    },
})

local EUI_ROUND_DIR = "Interface\\AddOns\\EllesmereUI\\media\\rounded\\"
local skinnedBars = setmetatable({}, { __mode = "k" })
local skinnedIcons = setmetatable({}, { __mode = "k" })
local hookedSetTex = setmetatable({}, { __mode = "k" })
local hookedTooltip = setmetatable({}, { __mode = "k" })
local hookedWindow = setmetatable({}, { __mode = "k" })
local allTrackedBars = setmetatable({}, { __mode = "k" })
local allTrackedRows = setmetatable({}, { __mode = "k" })
local ttBgHosts = setmetatable({}, { __mode = "k" })
local cachedTT = nil
local dmHooked = false

local function IsSafe(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function GetDMInternals()
    local EUI = _G.EllesmereUI
    local ns = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIDamageMeters
    return ns and ns._dmInternals or nil, ns
end

local function GetBarRadius()
    local db = mod:GetDB()
    return math_max(2, math_min(8, math_floor((F.PlainNumber(db.barRadius, 4) or 4) + 0.5)))
end

local function GetTooltipRadius()
    local db = mod:GetDB()
    return math_max(4, math_min(12, math_floor((F.PlainNumber(db.tooltipRadius, 8) or 8) + 0.5)))
end

local function SetupNineSliceMask(mask, rad)
    local path = (ST and ST.ResolveMaskPath) and select(1, ST.ResolveMaskPath(rad))
        or (EUI_ROUND_DIR .. "rounded-" .. tostring(rad) .. ".tga")
    if mask.SetBlockingLoadsRequested then
        pcall(mask.SetBlockingLoadsRequested, mask, true)
    end
    pcall(mask.SetTexture, mask, path, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    if mask.SetTextureSliceMargins then
        pcall(mask.SetTextureSliceMargins, mask, rad, rad, rad, rad)
    end
    local sm = _G.Enum and _G.Enum.UITextureSliceMode and _G.Enum.UITextureSliceMode.Stretched
    if sm and mask.SetTextureSliceMode then
        pcall(mask.SetTextureSliceMode, mask, sm)
    end
end

local dmBarTexBusy = false

-- 为单个 StatusBar 的填充贴图附加独立圆角 MaskTexture：
-- 锚点直接 SetAllPoints(fillTex)（纯 C++ 引擎锚定，零 Lua 宽度测量，100% 兼容 12.1 保密数值条）
local function ApplyRoundedStatusBar(fillBar, enable, rad, addTrack)
    if not IsSafe(fillBar) then return end
    local tex = fillBar.GetStatusBarTexture and fillBar:GetStatusBarTexture() or nil
    local rec = skinnedBars[fillBar]
    allTrackedBars[fillBar] = true

    if not enable then
        if rec then
            if rec.attachedTex and rec.mask and rec.attachedTex.RemoveMaskTexture then
                pcall(rec.attachedTex.RemoveMaskTexture, rec.attachedTex, rec.mask)
            end
            rec.attachedTex = nil
            if rec.origFillTex then
                if tex and tex.SetTexture then
                    pcall(tex.SetTexture, tex, rec.origFillTex)
                elseif fillBar.SetStatusBarTexture then
                    dmBarTexBusy = true
                    pcall(fillBar.SetStatusBarTexture, fillBar, rec.origFillTex)
                    dmBarTexBusy = false
                end
                rec.origFillTex = nil
                rec.appliedFillTex = nil
            end
            if rec.track then rec.track:Hide() end
            if rec.trackMask and rec.track and rec.track.RemoveMaskTexture then
                pcall(rec.track.RemoveMaskTexture, rec.track, rec.trackMask)
                rec.trackMasked = false
            end
        end
        return
    end

    if not rec then
        rec = {}
        skinnedBars[fillBar] = rec
    end

    -- 统一主伤害条/明细条材质为自制立体液态玻璃条体：
    -- 直接改 fillTex:SetTexture 绝不重置机密伤害 StatusBar 进度，按 appliedFillTex 幂等防副本内反复 OnShow 脱罩
    local texOn = ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_barTexture")
    if texOn then
        local wantFill = ST.GetBarFillTexture and ST.GetBarFillTexture(false) or nil
        if wantFill and rec.appliedFillTex ~= wantFill then
            local curP = nil
            if tex and tex.GetTexture then
                local okP, rawP = pcall(tex.GetTexture, tex)
                if okP and not F.IsSecret(rawP) then curP = rawP end
            end
            local already = curP and ST.SameTexturePath and ST.SameTexturePath(curP, wantFill)
            if rec.origFillTex == nil and curP and not already then
                rec.origFillTex = curP
            end
            if not already then
                if tex and tex.SetTexture then
                    pcall(tex.SetTexture, tex, wantFill)
                elseif fillBar.SetStatusBarTexture then
                    dmBarTexBusy = true
                    pcall(fillBar.SetStatusBarTexture, fillBar, wantFill)
                    dmBarTexBusy = false
                    tex = fillBar.GetStatusBarTexture and fillBar:GetStatusBarTexture() or tex
                end
            end
            rec.appliedFillTex = wantFill
        end
    elseif rec.origFillTex then
        if tex and tex.SetTexture then
            pcall(tex.SetTexture, tex, rec.origFillTex)
        elseif fillBar.SetStatusBarTexture then
            dmBarTexBusy = true
            pcall(fillBar.SetStatusBarTexture, fillBar, rec.origFillTex)
            dmBarTexBusy = false
            tex = fillBar.GetStatusBarTexture and fillBar:GetStatusBarTexture() or tex
        end
        rec.origFillTex = nil
        rec.appliedFillTex = nil
    end

    if not rec.mask and fillBar.CreateMaskTexture then
        rec.mask = fillBar:CreateMaskTexture()
    end
    if rec.mask and rec.rad ~= rad then
        SetupNineSliceMask(rec.mask, rad)
        rec.rad = rad
    end
    if tex and rec.mask and tex.AddMaskTexture then
        if rec.attachedTex and rec.attachedTex ~= tex and rec.attachedTex.RemoveMaskTexture then
            pcall(rec.attachedTex.RemoveMaskTexture, rec.attachedTex, rec.mask)
            rec.attachedTex = nil
        end
        rec.mask:ClearAllPoints()
        rec.mask:SetAllPoints(tex)
        if rec.attachedTex ~= tex then
            pcall(tex.AddMaskTexture, tex, rec.mask)
            rec.attachedTex = tex
        end
    end

    if addTrack then
        if not rec.track then
            local tr = fillBar:CreateTexture(nil, "BACKGROUND", nil, -4)
            tr:SetAllPoints(fillBar)
            tr:SetColorTexture(0.05, 0.055, 0.075, 0.55)
            rec.track = tr
        end
        if not rec.trackMask and fillBar.CreateMaskTexture then
            rec.trackMask = fillBar:CreateMaskTexture()
            rec.trackMask:SetAllPoints(fillBar)
        end
        if rec.trackMask and rec.trackRad ~= rad then
            SetupNineSliceMask(rec.trackMask, rad)
            rec.trackRad = rad
        end
        if rec.track and rec.trackMask and not rec.trackMasked and rec.track.AddMaskTexture then
            pcall(rec.track.AddMaskTexture, rec.track, rec.trackMask)
            rec.trackMasked = true
        end
        if rec.track then rec.track:Show() end
    elseif rec.track then
        rec.track:Hide()
    end

    if not hookedSetTex[fillBar] and type(fillBar.SetStatusBarTexture) == "function" then
        hookedSetTex[fillBar] = true
        _G.hooksecurefunc(fillBar, "SetStatusBarTexture", function(self)
            if dmBarTexBusy then return end
            rec.appliedFillTex = nil
            if mod._active then
                local wantMain = mod:GetDB().roundMainBars ~= false
                local isTT = rec.isTooltipBar == true
                local on = isTT and (mod:GetDB().skinTooltip ~= false) or wantMain
                if on then
                    ApplyRoundedStatusBar(self, true, GetBarRadius(), isTT)
                end
            end
        end)
    end
end

-- 动态 CASC 技能/职业图标严格使用 64x64 整图圆角遮罩（ST.SetWholeIconMask + ST.AttachCustomMask），
-- 遵循 WoW 12.1 D3D12 铁律：绝不对动态游戏图标挂 9 宫格切片遮罩，杜绝整格空白或碎角
local function ApplyRoundedIcon(parentRow, iconTex, enable, rad, sizeHint)
    if not (IsSafe(parentRow) and IsSafe(iconTex)) then return end
    local rec = skinnedIcons[iconTex]
    if not enable then
        if rec and rec.mask then
            if ST and ST.DetachCustomMask then
                ST.DetachCustomMask(iconTex, rec.mask)
            elseif iconTex.RemoveMaskTexture then
                pcall(iconTex.RemoveMaskTexture, iconTex, rec.mask)
            end
        end
        return
    end
    if not rec then
        rec = {}
        skinnedIcons[iconTex] = rec
    end
    if not rec.mask and parentRow.CreateMaskTexture then
        rec.mask = parentRow:CreateMaskTexture()
    end
    if rec.mask then
        local sz = sizeHint or 16
        if rec.rad ~= rad or rec.sz ~= sz then
            if ST and ST.SetWholeIconMask then
                ST.SetWholeIconMask(rec.mask, rad, sz, sz, 0)
            end
            rec.rad = rad
            rec.sz = sz
        end
        rec.mask:ClearAllPoints()
        rec.mask:SetAllPoints(iconTex)
        if ST and ST.AttachCustomMask then
            ST.AttachCustomMask(parentRow, iconTex, rec.mask, { isIcon = true })
        elseif iconTex.AddMaskTexture then
            pcall(iconTex.AddMaskTexture, iconTex, rec.mask)
        end
    end
end

local function EnsureTTBgHost(tt)
    local host = ttBgHosts[tt]
    if host then return host end
    host = CreateFrame("Frame", nil, tt)
    host:SetPoint("TOPLEFT", tt, "TOPLEFT", -6, 5)
    host:SetPoint("BOTTOMRIGHT", tt, "BOTTOMRIGHT", 6, -6)
    host:EnableMouse(false)
    local lvl = F.PlainNumber(tt.GetFrameLevel and tt:GetFrameLevel(), 1) or 1
    pcall(host.SetFrameLevel, host, math_max(1, lvl))
    ttBgHosts[tt] = host
    return host
end

-- ---------------------------------------------------------------------------
-- 1) 悬停伤害明细卡（_ttFrame）圆角 PrettyTooltip 风格美化
-- ---------------------------------------------------------------------------
local function SkinBreakdownTooltip(tt)
    if not IsSafe(tt) then return end
    cachedTT = tt
    local db = mod:GetDB()
    local active = mod._active and db.skinTooltip ~= false
    local EUI = _G.EllesmereUI
    local bgHost = ttBgHosts[tt]

    if not active then
        if bgHost then
            F.Theme.HidePrettyCardOverlay(bgHost)
            bgHost:Hide()
        end
        F.Theme.HidePrettyCardOverlay(tt)
        if tt._bg and tt._bg.SetAlpha then pcall(tt._bg.SetAlpha, tt._bg, 1) end
        if tt._hdrBg and tt._hdrBg.SetAlpha then pcall(tt._hdrBg.SetAlpha, tt._hdrBg, 1) end
        if tt._fvRim and tt._fvRim.SetAlpha then pcall(tt._fvRim.SetAlpha, tt._fvRim, 1) end
        if tt._legacyBorder and tt._legacyBorder._frame then pcall(tt._legacyBorder._frame.Show, tt._legacyBorder._frame) end
    else
        bgHost = EnsureTTBgHost(tt)
        local lvl = F.PlainNumber(tt.GetFrameLevel and tt:GetFrameLevel(), 1) or 1
        pcall(bgHost.SetFrameLevel, bgHost, math_max(1, lvl))
        bgHost:Show()
        local ar, ag, ab = F.Theme.GetAccent()
        local rad = GetTooltipRadius()
        F.Theme.PaintPrettyCardOverlay(bgHost, ar, ag, ab, 28, {
            rounded = true,
            radius = rad,
            alpha = 0.94,
            haloAlpha = 0.22,
            headerTopAlpha = 0.34,
        })
        if tt._bg and tt._bg.SetAlpha then pcall(tt._bg.SetAlpha, tt._bg, 0) end
        if tt._hdrBg and tt._hdrBg.SetAlpha then pcall(tt._hdrBg.SetAlpha, tt._hdrBg, 0) end
        if tt._fvRim and tt._fvRim.SetAlpha then pcall(tt._fvRim.SetAlpha, tt._fvRim, 0) end
        if tt._legacyBorder and tt._legacyBorder._frame then pcall(tt._legacyBorder._frame.Hide, tt._legacyBorder._frame) end
        if EUI and type(EUI._hideBlizzardConfiguredBorder) == "function" then
            pcall(EUI._hideBlizzardConfiguredBorder, tt)
        end
    end

    local I = GetDMInternals()
    local barRad = GetBarRadius()
    if I and type(I._ttBars) == "table" then
        for _, b in ipairs(I._ttBars) do
            if type(b) == "table" then
                if b.fill then
                    local r = skinnedBars[b.fill]
                    if not r then r = {}; skinnedBars[b.fill] = r end
                    r.isTooltipBar = true
                    ApplyRoundedStatusBar(b.fill, active, barRad, true)
                end
                if b.row and b.spellIcon then
                    ApplyRoundedIcon(b.row, b.spellIcon, active, math_min(barRad, 4), 16)
                end
            end
        end
    end
    if type(tt._tgtBars) == "table" then
        for _, tb in ipairs(tt._tgtBars) do
            if type(tb) == "table" and tb.fill then
                local r = skinnedBars[tb.fill]
                if not r then r = {}; skinnedBars[tb.fill] = r end
                r.isTooltipBar = true
                ApplyRoundedStatusBar(tb.fill, active, barRad, true)
            end
        end
    end
end

local function HookBreakdownTooltip(tt)
    if not IsSafe(tt) then return end
    cachedTT = tt
    if not hookedTooltip[tt] and tt.HookScript then
        hookedTooltip[tt] = true
        tt:HookScript("OnShow", function(self)
            SkinBreakdownTooltip(self)
        end)
        tt:HookScript("OnSizeChanged", function(self)
            if self:IsShown() then
                SkinBreakdownTooltip(self)
            end
        end)
    end
    SkinBreakdownTooltip(tt)
end

local function FindDMTooltipFrame()
    if cachedTT and IsSafe(cachedTT) then return cachedTT end
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return nil end
    local children = { ui:GetChildren() }
    for _, child in ipairs(children) do
        if IsSafe(child) and child._hdr and child._hdrText and child._combatMsg and child._bg then
            local okS, strata = pcall(child.GetFrameStrata, child)
            if okS and strata == "TOOLTIP" then
                cachedTT = child
                return child
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 2) 主伤害统计条（rowPool / stickyPlayer）圆角美化
-- ---------------------------------------------------------------------------
local function SkinWindowBars(w)
    if type(w) ~= "table" then return end
    local active = mod._active and mod:GetDB().roundMainBars ~= false
    local rad = GetBarRadius()

    local function skinRow(bar)
        if type(bar) ~= "table" or not bar.fill then return end
        local rec = skinnedBars[bar.fill]
        if not rec then rec = {}; skinnedBars[bar.fill] = rec end
        rec.isTooltipBar = false
        ApplyRoundedStatusBar(bar.fill, active, rad, false)
        local bgTex = bar._bg or bar.bg
        if bgTex and bar.row and ST and ST.MaskTexture then
            allTrackedRows[bar.row] = bar
            if active then
                ST.MaskTexture(bar.row, bgTex, rad)
            else
                ST.ClearRoundedMask(bar.row)
            end
        end
        if bar.row and bar.classIcon then
            ApplyRoundedIcon(bar.row, bar.classIcon, active, math_min(rad, 4), 18)
        end
    end

    if type(w.rowPool) == "table" then
        for _, bar in ipairs(w.rowPool) do
            skinRow(bar)
        end
    end
    if type(w.stickyPlayer) == "table" then
        skinRow(w.stickyPlayer)
    end

    if w.frame and IsSafe(w.frame) and not hookedWindow[w.frame] and w.frame.HookScript then
        hookedWindow[w.frame] = true
        w.frame:HookScript("OnShow", function()
            if mod._active then SkinWindowBars(w) end
        end)
    end
end

local function RefreshAll()
    local I = GetDMInternals()
    if I then
        if not dmHooked then
            dmHooked = true
            if type(I.ttFrameSetters) == "table" then
                I.ttFrameSetters[#I.ttFrameSetters + 1] = function(frame)
                    if frame then HookBreakdownTooltip(frame) end
                end
            end
            if type(I.EnsureTooltipFrame) == "function" then
                _G.hooksecurefunc(I, "EnsureTooltipFrame", function()
                    local tt = FindDMTooltipFrame()
                    if tt then HookBreakdownTooltip(tt) end
                end)
            end
        end
        if type(I._windows) == "table" then
            for _, w in ipairs(I._windows) do
                SkinWindowBars(w)
            end
        end
    end
    local tt = FindDMTooltipFrame()
    if tt then HookBreakdownTooltip(tt) end
end

function mod:OnEnable()
    if not F.IsAddOnLoaded("EllesmereUIDamageMeters") then return end
    RefreshAll()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        RefreshAll()
        C_Timer.After(1.0, function() if mod._active then RefreshAll() end end)
    end)
    C_Timer.After(0.6, function() if mod._active then RefreshAll() end end)
    C_Timer.After(2.0, function() if mod._active then RefreshAll() end end)
end

function mod:OnDisable()
    for fillBar in pairs(allTrackedBars) do
        ApplyRoundedStatusBar(fillBar, false, 4, false)
    end
    for row, bar in pairs(allTrackedRows) do
        if ST and ST.ClearRoundedMask then
            ST.ClearRoundedMask(row)
        end
        if type(bar) == "table" and bar.classIcon then
            ApplyRoundedIcon(row, bar.classIcon, false, 4, 18)
        end
    end
    if cachedTT and IsSafe(cachedTT) then
        SkinBreakdownTooltip(cachedTT)
    end
end

function mod:OnThemeChanged()
    RefreshAll()
end

function mod:OnRefresh()
    RefreshAll()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "明细卡统一样式",
        tooltip = "为伤害统计悬停明细卡应用圆角暗色底板与统一技能图标。",
        getValue = function() return db.skinTooltip ~= false end,
        setValue = function(v) db.skinTooltip = v == true; RefreshAll() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "主进度条圆角",
        tooltip = "为伤害与治疗统计主列表进度条添加柔和圆角。",
        getValue = function() return db.roundMainBars ~= false end,
        setValue = function(v) db.roundMainBars = v == true; RefreshAll() end,
    }, {
        type = "slider",
        text = "进度条圆角半径（px）",
        min = 2, max = 8, step = 1,
        getValue = function() return GetBarRadius() end,
        setValue = function(v) db.barRadius = math_floor(v + 0.5); RefreshAll() end,
    })
    y = y - h

    return y
end
