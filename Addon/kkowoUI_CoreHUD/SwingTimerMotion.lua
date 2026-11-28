----------------------------------------------------------------------
--  kkowoUI — Modules/SwingTimerMotion.lua
--  武器挥砍计时器（100% 适配无限服原生 PLAYER_SWING / C_SwingTimer API）：
--    • 模式 A（默认 enhance_eui）：原地为 EUI 挥砍条叠加圆角遮罩 + <0.25s 出手临界光刃提亮 + 出手瞬闪
--    • 模式 B（standalone）：3~5px 极简圆角细条（自动适配双持上下双条 & 猎人自动射击防卡平射色段），
--      可吸附核心血条下方或接入 EUI 解锁模式自由移动，脱战静止 0 OnUpdate 开销
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_floor, math_max, math_min, pairs, pcall, setmetatable, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, setmetatable, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("swingTimerMotion", {
    title = "挥砍条动效",
    desc = "原地增强 EUI 挥砍条或启用独立细条，支持双持与猎人平射。",
    group = "motion",
    order = 25,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        mode = "enhance_eui", -- "enhance_eui" | "standalone"
        width = 249,
        height = 4,
        hideOOC = true,
        criticalBoost = true, -- < 0.25s 出手临界光点提亮
        flashOnSwing = true,
    },
})

local SWING_ENUM = _G.Enum and _G.Enum.PlayerSwingType or nil
local AIM_CLASSES = { HUNTER = true, PRIEST = true, MAGE = true, WARLOCK = true }
local AIM_TIME = 0.50

local container = nil
local mhBar, ohBar = nil, nil
local flashTex = nil
local flashAG = nil
local isAimClass = AIM_CLASSES[F.GetPlayerClass()] == true
local inCombat = false

local state = {
    mhS = 0, mhE = 0, mhD = 0,
    ohS = 0, ohE = 0, ohD = 0,
    rS  = 0, rE  = 0, rD  = 0,
    lastKind = "mh",
    moving = false,
    autoRepeat = false,
}

local function MakeThinBar(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f:EnableMouse(false)

    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    bg:SetAllPoints()
    bg:SetTexture(ST.TEX.FLAT)
    local tc = ST.COLORS.track
    bg:SetVertexColor(tc[1], tc[2], tc[3], tc[4])
    f._bg = bg

    local sb = CreateFrame("StatusBar", nil, f)
    sb:SetAllPoints()
    local fillPath = ST.GetBarFillTexture and ST.GetBarFillTexture(false) or ST.TEX.FLAT
    sb:SetStatusBarTexture(fillPath)
    sb._kkFillPath = fillPath
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    if M.DisablePixelSnap then M.DisablePixelSnap(sb) end
    local sbFill = sb:GetStatusBarTexture()
    if sbFill and M.DisablePixelSnap then M.DisablePixelSnap(sbFill) end
    f._bar = sb

    local sheen = sb:CreateTexture(nil, "OVERLAY", nil, 2)
    ST.Hairline(sheen)
    sheen:SetPoint("TOPLEFT", sb, "TOPLEFT", 2, -1)
    sheen:SetPoint("TOPRIGHT", sb, "TOPRIGHT", -2, -1)
    sheen:SetColorTexture(1, 1, 1, 0.14)
    f._sheen = sheen

    local aim = sb:CreateTexture(nil, "ARTWORK", nil, 2)
    aim:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)
    aim:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
    aim:SetColorTexture(1, 0.80, 0.24, 0.34)
    aim:Hide()
    f._aim = aim

    f._spark = M.AttachEdgeSpark(sb, { width = 14, extraHeight = 4, a = 0.90, maskHost = f })
    f._spark:SetShown(false)
    f._flow = M.AttachBarLivingFlow(f, sb, {
        reverse = false, period = 1.8, peakAlpha = 0.28, softAlpha = 0.15, depthAlpha = 0.22, enabled = false,
    })
    return f
end

local function StyleThinBar(f, h)
    if not f then return end
    local wantFill = ST.GetBarFillTexture and ST.GetBarFillTexture(false) or ST.TEX.FLAT
    if f._bar and f._bar._kkFillPath ~= wantFill then
        f._bar:SetStatusBarTexture(wantFill)
        f._bar._kkFillPath = wantFill
        local ft = f._bar:GetStatusBarTexture()
        if ft and M.DisablePixelSnap then M.DisablePixelSnap(ft) end
    end
    local rad = math_min(ST.GetCornerRadius(6), math_max(2, math_floor(h * 0.48)))
    ST.ClearRoundedMask(f)
    if rad > 0 then
        ST.MaskTexture(f, f._bg, rad)
        local t = f._bar:GetStatusBarTexture()
        if t then ST.MaskTexture(f, t, rad) end
        if f._sheen then ST.MaskTexture(f, f._sheen, rad) end
        if f._aim then ST.MaskTexture(f, f._aim, rad) end
        if f._spark and f._spark.SyncMask then
            f._spark:SyncMask(f, rad)
        elseif f._spark and f._spark._spark then
            ST.MaskTexture(f, f._spark._spark, rad)
        end
        if f == mhBar and flashTex then
            ST.MaskTexture(f, flashTex, rad)
        end
        ST.ApplyRoundedBorder(f, rad, 0.02, 0.02, 0.03, 0.94, 5)
    else
        if f._spark and f._spark.SyncMask then f._spark:SyncMask(f, 0) end
    end
    if f._flow and f._flow.Refresh then f._flow:Refresh(rad) end
    if f._spark then f._spark:SyncAnchor() end
end

local function BuildStandalone()
    if container then return end
    local db = mod:GetDB()
    local w = F.PlainNumber(db.width, 249) or 249
    local h = F.PlainNumber(db.height, 4) or 4

    local f = CreateFrame("Frame", "kkowoUI_SwingTimer", _G.UIParent)
    f:SetSize(w, h * 2 + 2)
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(18)
    f:EnableMouse(false)

    mhBar = MakeThinBar(f, w, h)
    mhBar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    mhBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)

    ohBar = MakeThinBar(f, w, h)
    ohBar:SetPoint("TOPLEFT", mhBar, "BOTTOMLEFT", 0, -2)
    ohBar:SetPoint("TOPRIGHT", mhBar, "BOTTOMRIGHT", 0, -2)
    ohBar:Hide()

    flashTex = mhBar._bar:CreateTexture(nil, "OVERLAY", nil, 7)
    flashTex:SetAllPoints(mhBar._bar)
    flashTex:SetColorTexture(1, 1, 1, 0.85)
    flashTex:SetBlendMode("ADD")
    flashTex:SetAlpha(0)
    flashAG = flashTex:CreateAnimationGroup()
    local fa = flashAG:CreateAnimation("Alpha")
    fa:SetFromAlpha(0.85); fa:SetToAlpha(0); fa:SetDuration(0.16); fa:SetSmoothing("OUT")

    F.Mover.Register({
        key = "SwingTimerHUD",
        label = "独立极细挥砍计时条",
        frame = f,
        order = 16,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 0,
        defaultY = -262,
        allowShiftDrag = false,
        isHidden = function() return not (mod._active and mod:GetDB().mode == "standalone") end,
    })
    f:EnableMouse(false)

    f:Hide()
    container = f
end

local mutedSwingBorders = setmetatable({}, { __mode = "k" })
local hookedSwingBorder = setmetatable({}, { __mode = "k" })
local hookedSwingShell = setmetatable({}, { __mode = "k" })
local euiRowState = setmetatable({}, { __mode = "k" })
local euiHookedRow = setmetatable({}, { __mode = "k" })
local euiHookedBar = setmetatable({}, { __mode = "k" })
local euiHookedFillVC = setmetatable({}, { __mode = "k" })
local euiHookedSpark = setmetatable({}, { __mode = "k" })
local euiTrackedRows = {}
local euiTrackedSet = setmetatable({}, { __mode = "k" })
local hookedSTApply = false
local swingBorderBusy = false
local swingBarTexBusy = false
local swingFillVCBusy = false
local swingSparkAlphaBusy = false

local function IsSafeObj(obj)
    if not obj then return false end
    if obj.IsForbidden then
        local ok, forb = pcall(obj.IsForbidden, obj)
        if not ok or forb then return false end
    end
    return true
end

local function GetERBSwingCfg()
    local EUI = _G.EllesmereUI
    local rb = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIResourceBars
    local erbObj = rb and rb.ERB
    local prof = erbObj and erbObj.db and erbObj.db.profile
    return prof and prof.swingTimer or nil
end

local function ComputeEUIRowRadius(row)
    local h = F.PlainNumber(row and row.GetHeight and row:GetHeight(), 14) or 14
    local gRad = ST.GetCornerRadius(6)
    if gRad <= 0 then return 0 end
    return math_min(gRad, math_max(2, math_floor(h * 0.48)))
end

local function IsShownSafe(obj)
    if not (obj and obj.IsShown) then return false end
    local ok, vis = pcall(obj.IsShown, obj)
    return ok and (not F.IsSecret(vis)) and vis == true
end

local function GetTextureSafe(tex)
    if not (tex and tex.GetTexture) then return nil end
    local ok, raw = pcall(tex.GetTexture, tex)
    if not ok or F.IsSecret(raw) then return nil end
    return raw
end

local function SyncEUISwingRowZonesAndPhase(row)
    if not (IsSafeObj(row) and row._bar and row._bg) then return end
    local want = mod._active and mod:GetDB().mode == "enhance_eui" and row._merged ~= true
    local st = euiRowState[row]
    if not want then return end

    local euiOwnRound = type(row._roundRadius) == "number" and row._roundRadius > 0
    local rad = euiOwnRound and 0 or ComputeEUIRowRadius(row)
    local texOn = ST.IsFXEnabled("fx_barTexture")
    local wantFill = ST.GetBarFillTexture and ST.GetBarFillTexture(false) or ST.TEX.FLAT

    -- 补挂延迟/瞄准分区贴图圆角遮罩与立体明暗材质（按 appliedZoneTex 幂等门控，严禁每刀重复 SetTexture 导致 2 帧脱罩闪方角）
    local zones = row._zones
    if type(zones) == "table" then
        for _, key in ipairs({ "lat", "aim" }) do
            local z = zones[key]
            if type(z) == "table" then
                for _, part in ipairs({ "back", "front" }) do
                    local tex = z[part]
                    if IsSafeObj(tex) then
                        if texOn and tex.SetTexture and st and st.appliedZoneTex and st.appliedZoneTex[tex] ~= wantFill then
                            local curPlain = GetTextureSafe(tex)
                            local alreadyWant = curPlain and ST.SameTexturePath and ST.SameTexturePath(curPlain, wantFill)
                            if st.origZoneTex and st.origZoneTex[tex] == nil and curPlain and not alreadyWant then
                                st.origZoneTex[tex] = curPlain
                            end
                            if not alreadyWant then
                                pcall(tex.SetTexture, tex, wantFill)
                            end
                            st.appliedZoneTex[tex] = wantFill
                        end
                        if M.DisablePixelSnap then M.DisablePixelSnap(tex) end
                        if rad > 0 then
                            ST.MaskTexture(row, tex, rad)
                        end
                    end
                end
            end
        end
    end

    if rad > 0 then
        local ft = row._bar.GetStatusBarTexture and row._bar:GetStatusBarTexture() or nil
        if ft then ST.MaskTexture(row, ft, rad) end
        ST.MaskTexture(row, row._bg, rad)
        if row._spark then ST.MaskTexture(row, row._spark, rad) end
    end

    -- 同步施法条同款柔和光刃与连续液态流：仅在挥砍活跃期点亮，空闲/停泊时克制收起
    if st then
        local isShownRow = IsShownSafe(row)
        local isLive = row._live == true and row._waiting ~= true and isShownRow
        if st.edgeSpark then
            local showSpark = isLive and texOn
            st.edgeSpark:SyncAnchor()
            st.edgeSpark:SetShown(showSpark)
            if rad > 0 then st.edgeSpark:SyncMask(row, rad) end
        end
        if st.flow then
            st.flow:SetEnabled(isShownRow and (row._live == true or row._waiting == true), rad > 0 and rad or nil)
        end
    end
end

local function PlayEUIRowSwingFlash()
    local erb = _G.ERB_SwingTimerFrame
    if not (IsSafeObj(erb) and IsShownSafe(erb) and erb.GetChildren) then return end
    for _, row in ipairs({ erb:GetChildren() }) do
        if IsSafeObj(row) and IsShownSafe(row) and row._merged ~= true then
            local st = euiRowState[row]
            if st and st.flashAG and st.flashTex then
                st.flashAG:Stop()
                st.flashTex:SetAlpha(0)
                st.flashTex:Show()
                st.flashAG:Play()
            end
        end
    end
end

local function TriggerSwingFlash()
    if mod:GetDB().flashOnSwing == false then return end
    if mod:GetDB().mode == "standalone" and flashAG then
        flashAG:Stop()
        flashAG:Play()
    else
        -- 严禁对父容器 ERB_SwingTimerFrame 播放 Scale 动画（会与 SetIgnoreParentScale 圆角描边错位变成矩形）；
        -- 改用行内圆角遮罩叠加白闪，与施法条收尾质感保持一致
        PlayEUIRowSwingFlash()
    end
end

local StyleEUISwingRow -- 前向声明

local function HookEUIFillVertexColor(row, ft)
    if not (IsSafeObj(ft) and ft.SetVertexColor) or euiHookedFillVC[ft] then return end
    euiHookedFillVC[ft] = true
    _G.hooksecurefunc(ft, "SetVertexColor", function(self, r, g, b, a)
        if swingFillVCBusy then return end
        if not (mod._active and mod:GetDB().mode == "enhance_eui" and row._merged ~= true) then return end
        if not ST.IsFXEnabled("fx_barTexture") then return end
        local cfg = GetERBSwingCfg()
        if cfg and cfg.gradientEnabled then return end
        swingFillVCBusy = true
        ST.ApplySoftFlatGradient(self, r, g, b, a, false)
        swingFillVCBusy = false
    end)
end

StyleEUISwingRow = function(row, forceDisable)
    if not (IsSafeObj(row) and row._bar and row._bg) then return end
    if not euiTrackedSet[row] then
        euiTrackedSet[row] = true
        euiTrackedRows[#euiTrackedRows + 1] = row
    end

    local want = (not forceDisable) and mod._active and mod:GetDB().mode == "enhance_eui" and row._merged ~= true
    local st = euiRowState[row]
    local bar = row._bar
    local ft = bar.GetStatusBarTexture and bar:GetStatusBarTexture() or nil

    if not want then
        if st then
            if st.flow then st.flow:SetEnabled(false) end
            if st.edgeSpark then st.edgeSpark:SetShown(false) end
            if st.sheen then st.sheen:Hide() end
            if st.flashAG then st.flashAG:Stop() end
            if st.flashTex then st.flashTex:Hide() end
            if st.origFillTex then
                local curFt = bar.GetStatusBarTexture and bar:GetStatusBarTexture() or nil
                if curFt and curFt.SetTexture then
                    pcall(curFt.SetTexture, curFt, st.origFillTex)
                elseif bar.SetStatusBarTexture then
                    swingBarTexBusy = true
                    pcall(bar.SetStatusBarTexture, bar, st.origFillTex)
                    swingBarTexBusy = false
                end
                st.origFillTex = nil
                st.appliedFillTex = nil
            end
            if st.origZoneTex then
                for tex, origPath in pairs(st.origZoneTex) do
                    if IsSafeObj(tex) and tex.SetTexture and origPath then
                        pcall(tex.SetTexture, tex, origPath)
                    end
                    st.origZoneTex[tex] = nil
                    if st.appliedZoneTex then st.appliedZoneTex[tex] = nil end
                end
            end
            if st.mutedRawSpark and row._spark and row._spark.SetAlpha then
                st.mutedRawSpark = false
                swingSparkAlphaBusy = true
                pcall(row._spark.SetAlpha, row._spark, 1)
                swingSparkAlphaBusy = false
            end
        end
        ST.ClearRoundedMask(row)
        if row._border and mutedSwingBorders[row._border] and row._border.SetAlpha then
            mutedSwingBorders[row._border] = nil
            if not row._merged then
                swingBorderBusy = true
                pcall(row._border.SetAlpha, row._border, 1)
                swingBorderBusy = false
            end
        end
        return
    end

    if not st then
        st = {
            origZoneTex = setmetatable({}, { __mode = "k" }),
            appliedZoneTex = setmetatable({}, { __mode = "k" }),
        }
        euiRowState[row] = st
    end

    if not euiHookedRow[row] and row.HookScript then
        euiHookedRow[row] = true
        row:HookScript("OnShow", function(self)
            if mod._active and mod:GetDB().mode == "enhance_eui" then
                StyleEUISwingRow(self)
            end
        end)
        row:HookScript("OnHide", function(self)
            local rSt = euiRowState[self]
            if rSt then
                if rSt.flow then rSt.flow:SetEnabled(false) end
                if rSt.edgeSpark then rSt.edgeSpark:SetShown(false) end
            end
        end)
    end

    if not euiHookedBar[bar] then
        euiHookedBar[bar] = true
        if bar.SetStatusBarTexture then
            _G.hooksecurefunc(bar, "SetStatusBarTexture", function()
                if swingBarTexBusy then return end
                local rSt = euiRowState[row]
                if rSt then
                    rSt.appliedFillTex = nil
                    if rSt.appliedZoneTex then
                        for k in pairs(rSt.appliedZoneTex) do rSt.appliedZoneTex[k] = nil end
                    end
                end
                if mod._active and mod:GetDB().mode == "enhance_eui" and row._merged ~= true then
                    C_Timer.After(0, function()
                        if mod._active and mod:GetDB().mode == "enhance_eui" then
                            StyleEUISwingRow(row)
                        end
                    end)
                end
            end)
        end
        if bar.SetTimerDuration then
            _G.hooksecurefunc(bar, "SetTimerDuration", function()
                if mod._active and mod:GetDB().mode == "enhance_eui" and row._merged ~= true then
                    SyncEUISwingRowZonesAndPhase(row)
                    C_Timer.After(0, function()
                        if mod._active and mod:GetDB().mode == "enhance_eui" then
                            SyncEUISwingRowZonesAndPhase(row)
                        end
                    end)
                end
            end)
        end
    end

    local euiOwnRound = type(row._roundRadius) == "number" and row._roundRadius > 0
    local rad = euiOwnRound and 0 or ComputeEUIRowRadius(row)
    local texOn = ST.IsFXEnabled("fx_barTexture")

    -- 1) 统一为施法条同款液态玻璃明暗填充 + 柔和横向渐变（直接写 fillTex 保留计时器与对象引用，严格幂等避免反复 SetTexture 脱罩）
    if texOn then
        local wantFill = ST.GetBarFillTexture and ST.GetBarFillTexture(false) or ST.TEX.FLAT
        if st.appliedFillTex ~= wantFill then
            local curPath = GetTextureSafe(ft)
            local alreadyWant = curPath and ST.SameTexturePath and ST.SameTexturePath(curPath, wantFill)
            if st.origFillTex == nil and curPath and not alreadyWant then
                st.origFillTex = curPath
            end
            if not alreadyWant then
                if ft and ft.SetTexture then
                    pcall(ft.SetTexture, ft, wantFill)
                elseif bar.SetStatusBarTexture then
                    swingBarTexBusy = true
                    pcall(bar.SetStatusBarTexture, bar, wantFill)
                    swingBarTexBusy = false
                    ft = bar.GetStatusBarTexture and bar:GetStatusBarTexture() or nil
                end
            end
            st.appliedFillTex = wantFill
        end
    elseif st.origFillTex then
        if ft and ft.SetTexture then
            pcall(ft.SetTexture, ft, st.origFillTex)
        elseif bar.SetStatusBarTexture then
            swingBarTexBusy = true
            pcall(bar.SetStatusBarTexture, bar, st.origFillTex)
            swingBarTexBusy = false
            ft = bar.GetStatusBarTexture and bar:GetStatusBarTexture() or nil
        end
        st.origFillTex = nil
        st.appliedFillTex = nil
    end

    if M.DisablePixelSnap then
        M.DisablePixelSnap(bar)
        if ft then M.DisablePixelSnap(ft) end
    end

    if ft then
        HookEUIFillVertexColor(row, ft)
        local cfg = GetERBSwingCfg()
        if texOn and not (cfg and cfg.gradientEnabled) and ft.GetVertexColor then
            local okC, cr, cg, cb, ca = pcall(ft.GetVertexColor, ft)
            if okC then
                swingFillVCBusy = true
                ST.ApplySoftFlatGradient(ft, cr, cg, cb, ca, false)
                swingFillVCBusy = false
            end
        end
    end

    -- 2) 统一柔和前沿光刃 + 羽化光晕（替代 EUI 硬白细条，停用即还原）
    if not st.edgeSpark then
        st.edgeSpark = M.AttachEdgeSpark(bar, {
            width = 18, extraHeight = 4, a = 0.88, levelOffset = 3, maskHost = row,
        })
        st.edgeSpark:SetShown(false)
    end
    if row._spark and row._spark.SetAlpha then
        if not euiHookedSpark[row._spark] then
            euiHookedSpark[row._spark] = true
            _G.hooksecurefunc(row._spark, "SetAlpha", function(self, a)
                local rSt = euiRowState[row]
                if not swingSparkAlphaBusy and rSt and rSt.mutedRawSpark and F.PlainNumber(a, 1) ~= 0 then
                    swingSparkAlphaBusy = true
                    pcall(self.SetAlpha, self, 0)
                    swingSparkAlphaBusy = false
                end
            end)
        end
        if texOn then
            st.mutedRawSpark = true
            swingSparkAlphaBusy = true
            pcall(row._spark.SetAlpha, row._spark, 0)
            swingSparkAlphaBusy = false
        elseif st.mutedRawSpark then
            st.mutedRawSpark = false
            swingSparkAlphaBusy = true
            pcall(row._spark.SetAlpha, row._spark, 1)
            swingSparkAlphaBusy = false
        end
    end

    -- 3) 统一 1px 顶部玻璃高光线 + 连续双层液态流动 + 出手瞬闪叠层
    if not st.sheen then
        local sheen = bar:CreateTexture(nil, "OVERLAY", nil, 1)
        ST.Hairline(sheen)
        sheen:SetPoint("TOPLEFT", bar, "TOPLEFT", 2, -1)
        sheen:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -2, -1)
        sheen:SetColorTexture(1, 1, 1, 0.14)
        st.sheen = sheen
    end
    st.sheen:SetShown(texOn)

    if not st.flashTex then
        local fl = bar:CreateTexture(nil, "OVERLAY", nil, 6)
        fl:SetAllPoints(bar)
        fl:SetTexture(ST.TEX.FLAT)
        fl:SetBlendMode("ADD")
        fl:SetVertexColor(1, 1, 1, 1)
        fl:SetAlpha(0)
        fl:Hide()
        local ag = fl:CreateAnimationGroup()
        local a1 = ag:CreateAnimation("Alpha")
        a1:SetOrder(1); a1:SetFromAlpha(0); a1:SetToAlpha(0.42); a1:SetDuration(0.03); a1:SetSmoothing("OUT")
        local a2 = ag:CreateAnimation("Alpha")
        a2:SetOrder(2); a2:SetFromAlpha(0.42); a2:SetToAlpha(0); a2:SetDuration(0.16); a2:SetSmoothing("OUT")
        ag:SetScript("OnFinished", function() fl:SetAlpha(0); fl:Hide() end)
        ag:SetScript("OnStop", function() fl:SetAlpha(0); fl:Hide() end)
        st.flashTex = fl
        st.flashAG = ag
    end

    if not st.flow then
        st.flow = M.AttachBarLivingFlow(row, bar, {
            reverse = false, period = 1.8, peakAlpha = 0.28, softAlpha = 0.15, depthAlpha = 0.22, levelOffset = 2, enabled = false,
        })
    end

    -- 4) 全纹理圆角遮罩 + 1px 抗锯齿描边（覆盖 bg / fill / spark / bloom / sheen / flash / zones / flow）
    if rad > 0 then
        ST.MaskTexture(row, row._bg, rad)
        if ft then ST.MaskTexture(row, ft, rad) end
        if row._spark then ST.MaskTexture(row, row._spark, rad) end
        if st.sheen then ST.MaskTexture(row, st.sheen, rad) end
        if st.flashTex then ST.MaskTexture(row, st.flashTex, rad) end
        if st.edgeSpark then st.edgeSpark:SyncMask(row, rad) end
        if row._border and row._border.SetAlpha then
            local bd = row._border
            mutedSwingBorders[bd] = true
            if not hookedSwingBorder[bd] then
                hookedSwingBorder[bd] = true
                _G.hooksecurefunc(bd, "SetAlpha", function(self, a)
                    if not swingBorderBusy and mutedSwingBorders[self] and F.PlainNumber(a, 1) ~= 0 then
                        swingBorderBusy = true
                        pcall(self.SetAlpha, self, 0)
                        swingBorderBusy = false
                    end
                end)
                if bd.Show then
                    _G.hooksecurefunc(bd, "Show", function(self)
                        if not swingBorderBusy and mutedSwingBorders[self] then
                            swingBorderBusy = true
                            pcall(self.SetAlpha, self, 0)
                            swingBorderBusy = false
                        end
                    end)
                end
            end
            swingBorderBusy = true
            pcall(bd.SetAlpha, bd, 0)
            swingBorderBusy = false
        end
        ST.ApplyRoundedBorder(row, rad, 0.02, 0.02, 0.03, 0.94, 6)
    elseif not euiOwnRound then
        ST.ClearRoundedMask(row)
        if st.edgeSpark then st.edgeSpark:SyncMask(row, 0) end
        if row._border and mutedSwingBorders[row._border] and row._border.SetAlpha then
            mutedSwingBorders[row._border] = nil
            swingBorderBusy = true
            pcall(row._border.SetAlpha, row._border, 1)
            swingBorderBusy = false
        end
    end

    -- 确保文字层始终高于流光、高光线与圆角描边
    if row._textFrame and row._textFrame.SetFrameLevel then
        local barLvl = F.PlainNumber(bar.GetFrameLevel and bar:GetFrameLevel(), 10) or 10
        local rowLvl = F.PlainNumber(row.GetFrameLevel and row:GetFrameLevel(), 10) or 10
        local wantTxtLvl = math_max(barLvl + 8, rowLvl + 8)
        local curTxtLvl = F.PlainNumber(row._textFrame.GetFrameLevel and row._textFrame:GetFrameLevel(), 0) or 0
        if curTxtLvl < wantTxtLvl then
            pcall(row._textFrame.SetFrameLevel, row._textFrame, wantTxtLvl)
        end
    end

    if st.flow then st.flow:Refresh(rad > 0 and rad or nil) end
    SyncEUISwingRowZonesAndPhase(row)
end

local function EnhanceEUISwingFrame(forceDisable)
    local EUI = _G.EllesmereUI
    local rbNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIResourceBars
    if rbNS and not hookedSTApply and type(rbNS.ST_Apply) == "function" then
        hookedSTApply = true
        _G.hooksecurefunc(rbNS, "ST_Apply", function()
            for _, row in ipairs(euiTrackedRows) do
                local rSt = euiRowState[row]
                if rSt then
                    rSt.appliedFillTex = nil
                    if rSt.appliedZoneTex then
                        for k in pairs(rSt.appliedZoneTex) do rSt.appliedZoneTex[k] = nil end
                    end
                end
            end
            if mod._active and mod:GetDB().mode == "enhance_eui" then
                EnhanceEUISwingFrame(false)
            end
        end)
    end

    local erb = _G.ERB_SwingTimerFrame
    if not IsSafeObj(erb) then
        if forceDisable then
            for _, row in ipairs(euiTrackedRows) do
                StyleEUISwingRow(row, true)
            end
        end
        return
    end
    -- 外壳 ERB_SwingTimerFrame 仅是多行排布容器，绝不能在外壳上套圆角框
    ST.ClearRoundedMask(erb)
    if not hookedSwingShell[erb] and erb.HookScript then
        hookedSwingShell[erb] = true
        erb:HookScript("OnShow", function()
            if mod._active and mod:GetDB().mode == "enhance_eui" then
                EnhanceEUISwingFrame(false)
            end
        end)
    end
    if not erb.GetChildren then return end
    for _, row in ipairs({ erb:GetChildren() }) do
        if IsSafeObj(row) and row._bar and row._bg then
            StyleEUISwingRow(row, forceDisable)
        end
    end
end

local function SyncAllEUISwingRows()
    local erb = _G.ERB_SwingTimerFrame
    if not (IsSafeObj(erb) and erb.GetChildren) then return end
    for _, row in ipairs({ erb:GetChildren() }) do
        if IsSafeObj(row) and row._bar and row._bg then
            if not euiTrackedSet[row] then
                StyleEUISwingRow(row, false)
            else
                SyncEUISwingRowZonesAndPhase(row)
            end
        end
    end
end

local function MaybeHideIdleStandalone()
    if not (mod._active and mod:GetDB().mode == "standalone" and container and container:IsShown()) then return end
    local db = mod:GetDB()
    if db.hideOOC == false or inCombat or state.autoRepeat then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end
    local now = GetTime()
    if state.mhE > now or state.ohE > now or state.rE > now then return end
    F.Theme.FadeTo(container, 0, 0.25, true)
end

local function UpdateStandaloneTick(self)
    if not (mod._active and mod:GetDB().mode == "standalone") then
        self:SetScript("OnUpdate", nil)
        self:Hide()
        return
    end
    local now = GetTime()
    local db = mod:GetDB()
    local s, e, d, kind
    if state.lastKind == "ranged" and state.rE > now then
        s, e, d, kind = state.rS, state.rE, state.rD, "ranged"
    elseif state.mhE > now then
        s, e, d, kind = state.mhS, state.mhE, state.mhD, "mh"
    elseif state.rE > now then
        s, e, d, kind = state.rS, state.rE, state.rD, "ranged"
    end

    local ohLive = state.ohE > now and state.ohD > 0.01
    if not s and not ohLive then
        mhBar._bar:SetValue(0)
        mhBar._spark:SetShown(false)
        if mhBar._flow then mhBar._flow:SetEnabled(false) end
        if ohBar._flow then ohBar._flow:SetEnabled(false) end
        ohBar:Hide()
        self:SetScript("OnUpdate", nil)
        if db.hideOOC ~= false and not inCombat and not (_G.InCombatLockdown and _G.InCombatLockdown()) and not state.autoRepeat then
            F.Theme.FadeTo(self, 0, 0.25, true)
        end
        return
    end

    if s and d and d > 0.01 then
        local prog = math_max(0, math_min(1, (now - s) / d))
        local rem = e - now
        mhBar._bar:SetValue(prog)
        if mhBar._flow and not mhBar._flow._enabled then mhBar._flow:SetEnabled(true) end
        if kind == "ranged" and isAimClass then
            local w = F.PlainNumber(mhBar:GetWidth(), 249) or 249
            mhBar._aim:SetWidth(math_max(4, w * math_min(0.65, AIM_TIME / d)))
            mhBar._aim:Show()
            local cKey = (rem <= AIM_TIME) and (state.moving and "clip" or "still") or "go"
            if mhBar._lastColorKey ~= cKey then
                mhBar._lastColorKey = cKey
                local c = (cKey == "clip") and ST.COLORS.aimClip
                    or (cKey == "still" and ST.COLORS.aimStill or ST.COLORS.aimGo)
                ST.ApplyBarGradient(mhBar._bar, c[1] * 0.78, c[2] * 0.78, c[3] * 0.78, c[1], c[2], c[3], 0.98, false)
            end
        else
            mhBar._aim:Hide()
            if mhBar._lastColorKey ~= "class" then
                mhBar._lastColorKey = "class"
                local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
                ST.ApplyBarGradient(mhBar._bar, r1, g1, b1, r2, g2, b2, 0.98, false)
            end
        end
        mhBar._spark:SetShown(prog > 0.02 and prog < 0.99)
        if db.criticalBoost ~= false and rem <= 0.25 then
            mhBar._spark:SetIntensity(1.0, 1.45)
        else
            mhBar._spark:SetIntensity(0.80, 0.95)
        end
    end

    if ohLive then
        ohBar:Show()
        local ohProg = math_max(0, math_min(1, (now - state.ohS) / state.ohD))
        ohBar._bar:SetValue(ohProg)
        if ohBar._flow and not ohBar._flow._enabled then ohBar._flow:SetEnabled(true) end
        if ohBar._lastColorKey ~= "class" then
            ohBar._lastColorKey = "class"
            local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
            ST.ApplyBarGradient(ohBar._bar, r1 * 0.75, g1 * 0.75, b1 * 0.75, r2 * 0.9, g2 * 0.9, b2 * 0.9, 0.92, false)
        end
        ohBar._spark:SetShown(ohProg > 0.02 and ohProg < 0.99)
    else
        if ohBar._flow then ohBar._flow:SetEnabled(false) end
        ohBar:Hide()
    end
end

local function ApplyModeLayout()
    local db = mod:GetDB()
    EnhanceEUISwingFrame()
    if db.mode == "standalone" then
        BuildStandalone()
        local w = math_max(120, math_min(360, F.PlainNumber(db.width, 249) or 249))
        local h = math_max(3, math_min(10, F.PlainNumber(db.height, 4) or 4))
        container:SetSize(w, h * 2 + 2)
        mhBar:SetHeight(h)
        ohBar:SetHeight(h)
        mhBar._lastColorKey = nil
        ohBar._lastColorKey = nil
        StyleThinBar(mhBar, h)
        StyleThinBar(ohBar, h)
    elseif container then
        container:SetScript("OnUpdate", nil)
        container:Hide()
    end
end

function mod:OnEnable()
    isAimClass = AIM_CLASSES[F.GetPlayerClass()] == true
    inCombat = (_G.InCombatLockdown and _G.InCombatLockdown()) == true
    ApplyModeLayout()
    self:RegisterEvent("PLAYER_SWING", function(_, _, duration, swingType)
        local dur = F.PlainNumber(duration, nil)
        local stype = F.PlainNumber(swingType, nil)
        if not dur or dur <= 0.05 then return end
        local now = GetTime()
        if SWING_ENUM and stype == SWING_ENUM.Ranged then
            state.rS, state.rE, state.rD = now, now + dur, dur
            state.lastKind = "ranged"
        elseif SWING_ENUM and stype == SWING_ENUM.OffHand then
            state.ohS, state.ohE, state.ohD = now, now + dur, dur
        else
            state.mhS, state.mhE, state.mhD = now, now + dur, dur
            state.lastKind = "mh"
        end
        if mod:GetDB().mode == "enhance_eui" then
            SyncAllEUISwingRows()
            -- 同帧 EUI 的 PLAYER_SWING 处理若晚于我们创建/定位 _zones，下一帧补齐遮罩与阶段状态
            C_Timer.After(0, function()
                if mod._active and mod:GetDB().mode == "enhance_eui" then
                    SyncAllEUISwingRows()
                end
            end)
        end
        TriggerSwingFlash()
        if mod:GetDB().mode == "standalone" then
            BuildStandalone()
            -- 中止脱战淡出（其结束回调会 Hide 容器），否则淡出期间来的新一刀会被藏掉
            F.Theme.FadeTo(container, 1, 0)
            container:Show()
            container:SetScript("OnUpdate", UpdateStandaloneTick)
            UpdateStandaloneTick(container)
        end
    end)
    self:RegisterEvent("START_AUTOREPEAT_SPELL", function() state.autoRepeat = true end)
    self:RegisterEvent("STOP_AUTOREPEAT_SPELL", function()
        state.autoRepeat = false
        MaybeHideIdleStandalone()
    end)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function() inCombat = true end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        inCombat = false
        MaybeHideIdleStandalone()
    end)
    self:RegisterEvent("PLAYER_STARTED_MOVING", function() state.moving = true end)
    self:RegisterEvent("PLAYER_STOPPED_MOVING", function() state.moving = false end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", ApplyModeLayout)
end

function mod:OnDisable()
    inCombat = false
    if mhBar and mhBar._flow then mhBar._flow:SetEnabled(false) end
    if ohBar and ohBar._flow then ohBar._flow:SetEnabled(false) end
    if container then
        container:SetScript("OnUpdate", nil)
        container:Hide()
    end
    EnhanceEUISwingFrame(true)
end

function mod:OnRefresh()
    ApplyModeLayout()
end

function mod:OnThemeChanged()
    ApplyModeLayout()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "挥砍条运行模式",
        tooltip = "原地增强避免双条重叠，也可切为 4px 独立条支持双持与平射。",
        values = {
            enhance_eui = "原地增强 EUI 挥砍条（推荐·防重复）",
            standalone  = "独立 4px 极细圆角挥砍条（支持双持）",
        },
        order = { "enhance_eui", "standalone" },
        getValue = function() return db.mode or "enhance_eui" end,
        setValue = function(v) db.mode = v; ApplyModeLayout() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "独立细条高度（px）",
        min = 3, max = 8, step = 1,
        disabled = function() return db.mode ~= "standalone" end,
        getValue = function() return F.PlainNumber(db.height, 4) or 4 end,
        setValue = function(v) db.height = math_floor(v + 0.5); ApplyModeLayout() end,
    }, {
        type = "slider",
        text = "独立细条宽度（px）",
        min = 140, max = 340, step = 5,
        disabled = function() return db.mode ~= "standalone" end,
        getValue = function() return F.PlainNumber(db.width, 249) or 249 end,
        setValue = function(v) db.width = math_floor(v + 0.5); ApplyModeLayout() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "临界前沿提亮",
        getValue = function() return db.criticalBoost ~= false end,
        setValue = function(v) db.criticalBoost = v == true end,
    }, {
        type = "toggle",
        text = "出手瞬间轻闪重置",
        getValue = function() return db.flashOnSwing ~= false end,
        setValue = function(v) db.flashOnSwing = v == true end,
    })
    y = y - h

    return y
end
