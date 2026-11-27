----------------------------------------------------------------------
--  kkowoUI — Modules/NameplateMotion.lua
--  姓名板目标强辨识与动效增强（非侵入挂载 EllesmereUINameplates）：
--    • 当前目标左右白色锐角呼吸指向箭头（C端 BOUNCE 平滑内收呼吸，0 OnUpdate）
--    • 当前目标高对比斜向警示条纹 Overlay（复用 EUI striped-v2 或内置 DiagStripes）
--    • 非目标柔和降暗（清晰拉开多怪焦点反差）
--    • 当前目标 / 全量可见姓名板可选轻量掉血延迟残影条（12.x 保密值安全）
--    • 可打断 / 不可打断施法条高反差边光提示
--    • 全程弱表存储、全多点锚定防受限子树偏移、关闭一键无损还原
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_min, pairs, pcall, setmetatable, tostring, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, setmetatable, tostring, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local ST = F.StyleTokens
local M = F.Motion

local mod = F.RegisterModule("nameplateMotion", {
    title = "姓名板圆角、任务进度与目标动效",
    desc = "为姓名板血条/施法条施加统一圆角美化、头顶任务击杀进度（如 1/10，副本内同样生效）、目标呼吸箭头、斜向条纹、非目标压暗与掉血残影。",
    group = "motion",
    order = 40,
    masterKey = "motionFX",
    defaults = {
        enabled = true,
        roundBars = true,
        muteCrudeTargetGlow = true,
        showQuestProgress = true,
        breathingArrows = true,
        arrowStyle = "split",        -- "split" | "double" | "bracket" | "crystal" | "curved" | "winged"
        arrowColorMode = "amber",    -- "amber" | "class" | "green" | "cyan" | "crimson"
        arrowScale = 1.0,
        targetStripes = true,
        stripeAlpha = 0.42,
        dimNonTarget = true,
        nonTargetAlpha = 0.78,
        trailMode = "target", -- "target" = 仅当前目标(推荐) | "all" = 全部可见板 | "off" = 关闭
        castContrast = true,
        suppressTeleportFlash = true,
        redHostilePlayers = true, -- 敌对阵营玩家名字显示红色，与怪物区分
        savedEUICornerRadius = nil,
        savedEUICornerRadiusAuras = nil,
    },
})

local EUI_ARROW_DIR = "Interface\\AddOns\\EllesmereUINameplates\\Media\\Arrows\\"

local ARROW_STYLES = {
    split   = { l = "split-left.png",   r = "split-right.png",   w = 18, h = 14 },
    double  = { l = "arrow_leftx2.png", r = "arrow_rightx2.png", w = 18, h = 13 },
    bracket = { l = "bracket-left.png", r = "bracket-right.png", w = 17, h = 14 },
    crystal = { l = "crystal-left.png", r = "crystal-right.png", w = 17, h = 14 },
    curved  = { l = "curved-left.png",  r = "curved-right.png",  w = 17, h = 14 },
    winged  = { l = "winged-left.png",  r = "winged-right.png",  w = 22, h = 14 },
}

local function ResolveArrowColors(mode)
    if mode == "class" then
        local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
        return r2, g2, b2, r1, g1, b1
    elseif mode == "green" then
        return 0.62, 1.00, 0.72, 0.20, 0.88, 0.36
    elseif mode == "cyan" then
        return 0.66, 0.96, 1.00, 0.16, 0.78, 1.00
    elseif mode == "crimson" then
        return 1.00, 0.56, 0.48, 0.98, 0.22, 0.18
    end
    -- 默认 "amber"：熔金炽光核心 + 霓虹琥珀外晕（草地/暗地/各色血条下均极度炫酷醒目）
    return 1.00, 0.86, 0.42, 1.00, 0.48, 0.10
end

local plateFX = setmetatable({}, { __mode = "k" })
local knownPlates = {}
local questTextCache = {}
local borderHooked = setmetatable({}, { __mode = "k" })
local targetHooked = setmetatable({}, { __mode = "k" })
local glowGuarded = setmetatable({}, { __mode = "k" })
local plateResetHooked = setmetatable({}, { __mode = "k" })
local glowAlphaBusy = false
local lastReloadedRad = nil

local function WipeQuestCache()
    for k in pairs(questTextCache) do questTextCache[k] = nil end
end

-- 12.x 安全读取目标怪物任务进度（如 "1/10" 或 "60%"，野外与副本内均生效）
local function GetUnitQuestProgress(unit)
    if not unit then return nil end
    local cached = questTextCache[unit]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local tipInfo = _G.C_TooltipInfo and _G.C_TooltipInfo.GetUnit
    local LT = _G.Enum and _G.Enum.TooltipDataLineType
    if not (tipInfo and LT) then
        questTextCache[unit] = false
        return nil
    end
    local ok, info = pcall(tipInfo, unit)
    if not (ok and type(info) == "table" and type(info.lines) == "table") then
        questTextCache[unit] = false
        return nil
    end
    local isOnQuest = _G.C_QuestLog and _G.C_QuestLog.IsOnQuest
    local questID = nil
    local found = nil
    for _, line in ipairs(info.lines) do
        local kind = line.type
        if kind == LT.QuestTitle then
            local id = F.PlainNumber(line.id, nil)
            questID = id
        elseif kind == LT.QuestObjective then
            local done = line.completed
            if not F.IsSecret(done) and done == false then
                local onQ = true
                if questID and isOnQuest then
                    local okQ, r = pcall(isOnQuest, questID)
                    if okQ and not F.IsSecret(r) then onQ = (r == true) end
                end
                if onQ then
                    local have = F.PlainNumber(line.numFulfilled, nil)
                    local need = F.PlainNumber(line.numRequired, nil)
                    if have and need and need > 0 then
                        local lt = F.PlainString(line.leftText, nil)
                        local pct = lt and lt:match("(%d+)%s*%%") or nil
                        found = pct and (pct .. "%") or (tostring(have) .. "/" .. tostring(need))
                        break
                    else
                        local lt = F.PlainString(line.leftText, nil)
                        if lt then
                            local a, b = lt:match("(%d+)%s*/%s*(%d+)")
                            if a and b then
                                found = a .. "/" .. b
                                break
                            end
                            local pct = lt:match("(%d+)%s*%%")
                            if pct then
                                found = pct .. "%"
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    questTextCache[unit] = found or false
    return found
end

local function IsSafe(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function GetEUINPNS()
    local EUI = _G.EllesmereUI
    return EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUINameplates or nil
end

local function GetEUIPlates()
    local ns = GetEUINPNS()
    return ns and ns.plates or nil
end

-- 将 EUI 姓名板原生圆角半径与我们联动（直接驱动 EUI 内置 RoundedCorners 引擎，连带圆角化 _customBorder、血条、施法条；停用时原样恢复）
local function GetEUINPProfile()
    local npNS = GetEUINPNS()
    if npNS then
        local enp = npNS.ENP or (npNS._npInternals and npNS._npInternals.ENP)
        if enp and enp.db and type(enp.db.profile) == "table" then
            return enp.db.profile
        end
    end
    local EUI = _G.EllesmereUI
    if EUI and EUI.GetModule then
        local ok, m = pcall(EUI.GetModule, EUI, "EllesmereUINameplates", true)
        if ok and m and m.db and type(m.db.profile) == "table" then
            return m.db.profile
        end
    end
    return nil
end

-- 传送/过图防暴雪原生姓名板瞬闪：
-- 过图瞬间 EUI 的友方/敌方接管走 C_Timer.After(0) 延迟，期间暴雪原生 np.UnitFrame 会以 alpha=1 闪现 1~3 帧。
-- 我们在 OnNamePlateAdded 与过图事件同步把已由 EUI 接管的敌方板 / 友方 NPC 板原生 UnitFrame 压至 alpha=0（绝不误伤友方玩家仅名字模式）。
local driverHooked = false

local function SuppressBlizzFlashForPlate(np, unit)
    if not (mod._active and mod:GetDB().suppressTeleportFlash ~= false) then return end
    if not (np and IsSafe(np)) then return end
    local uf = np.UnitFrame
    if not (uf and IsSafe(uf)) then return end
    local npNS = GetEUINPNS()
    if not npNS then return end

    unit = unit or np.namePlateUnitToken or uf.unit
    if not unit or unit == "preview" then return end
    if _G.UnitIsUnit then
        local okSelf, isSelf = pcall(_G.UnitIsUnit, unit, "player")
        if okSelf and not F.IsSecret(isSelf) and isSelf then return end
    end

    local canAttack = false
    if _G.UnitCanAttack then
        local okA, resA = pcall(_G.UnitCanAttack, "player", unit)
        if okA and not F.IsSecret(resA) then canAttack = (resA == true) end
    end
    local hasEUIEnemy = (npNS.plates and npNS.plates[unit] ~= nil) or false
    local hasEUIFriendly = (npNS.friendlyPlates and npNS.friendlyPlates[unit] ~= nil) or false

    if canAttack or hasEUIEnemy then
        pcall(uf.SetAlpha, uf, 0)
        if type(npNS.HideBlizzardFrame) == "function" then
            pcall(npNS.HideBlizzardFrame, np, unit)
        end
        return
    end

    if hasEUIFriendly then
        pcall(uf.SetAlpha, uf, 0)
        return
    end

    -- 友方 NPC（非玩家）：若 EUI 友方覆盖层/仅名字系统已启用，过图瞬间同步压制暴雪原生血条框体
    local isPlayer = false
    if _G.UnitIsPlayer then
        local okP, resP = pcall(_G.UnitIsPlayer, unit)
        if okP and not F.IsSecret(resP) then isPlayer = (resP == true) end
    end
    if not isPlayer then
        local friendlyManaged = false
        if type(npNS.FriendlyOverlayActive) == "function" then
            local okF, rF = pcall(npNS.FriendlyOverlayActive)
            if okF and rF then friendlyManaged = true end
        end
        if (not friendlyManaged) and type(npNS.FriendlyNameOnlyNow) == "function" then
            local prof = GetEUINPProfile()
            local okN, rN = pcall(npNS.FriendlyNameOnlyNow, prof)
            if okN and rN then friendlyManaged = true end
        end
        if friendlyManaged then
            pcall(uf.SetAlpha, uf, 0)
            if type(npNS.TrySuppressNPCHealthBar) == "function" then
                pcall(npNS.TrySuppressNPCHealthBar, unit, np)
            end
        end
    end
end

local function SweepBlizzNameplateFlash()
    if not (mod._active and mod:GetDB().suppressTeleportFlash ~= false) then return end
    if not (_G.C_NamePlate and _G.C_NamePlate.GetNamePlates) then return end
    local ok, list = pcall(_G.C_NamePlate.GetNamePlates)
    if not (ok and type(list) == "table") then return end
    for _, np in ipairs(list) do
        SuppressBlizzFlashForPlate(np, nil)
    end
end

local function InstallTeleportFlashGuard()
    if driverHooked then return end
    local drv = _G.NamePlateDriverFrame
    if drv and type(drv.OnNamePlateAdded) == "function" then
        driverHooked = true
        _G.hooksecurefunc(drv, "OnNamePlateAdded", function(_, addedUnit)
            if not (mod._active and mod:GetDB().suppressTeleportFlash ~= false) then return end
            local u = F.PlainString(addedUnit, nil)
            if not u or u == "preview" then return end
            local okNP, np = _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit
                and pcall(_G.C_NamePlate.GetNamePlateForUnit, u)
            if okNP and np then
                SuppressBlizzFlashForPlate(np, u)
            end
        end)
    end
end

local function IsUnitTarget(unit)
    if not (unit and _G.UnitIsUnit) then return false end
    local ok, res = pcall(_G.UnitIsUnit, unit, "target")
    return ok and (not F.IsSecret(res)) and res == true
end

local function ClearPlateCastContrast(plate, fx)
    if not fx then return end
    if fx.castGlow then fx.castGlow:Hide() end
    if fx.castBorderApplied and plate and IsSafe(plate.cast) then
        fx.castBorderApplied = false
        if fx.rounded and not plate._npRounded then
            local cH = F.PlainNumber(plate.cast:GetHeight(), 10) or 10
            local cRad = math_min(ST.GetCornerRadius(5), math_max(2, math_floor(cH * 0.44)))
            ST.ApplyRoundedBorder(plate.cast, cRad, 0.03, 0.035, 0.05, 0.92, 5)
        else
            ST.ApplyRoundedBorder(plate.cast, 0)
        end
    end
end

local function ResetPlateFX(plate, fx)
    if not fx then return end
    if fx.leftAG and fx.leftAG:IsPlaying() then fx.leftAG:Stop() end
    if fx.rightAG and fx.rightAG:IsPlaying() then fx.rightAG:Stop() end
    if fx.leftGlowAG and fx.leftGlowAG:IsPlaying() then fx.leftGlowAG:Stop() end
    if fx.rightGlowAG and fx.rightGlowAG:IsPlaying() then fx.rightGlowAG:Stop() end
    if fx.leftBox then fx.leftBox:Hide() end
    if fx.rightBox then fx.rightBox:Hide() end
    if fx.arrowHost then fx.arrowHost:Hide() end
    if fx.questFS then fx.questFS:Hide() end
    if fx.stripeFillClip then fx.stripeFillClip:Hide() end
    if fx.stripeBgClip then fx.stripeBgClip:Hide() end
    if fx.trail then fx.trail:SetEnabled(false) end
    if fx.mutedEUIArrows and plate then
        if plate.leftArrow and plate.leftArrow.SetAlpha then pcall(plate.leftArrow.SetAlpha, plate.leftArrow, 1) end
        if plate.rightArrow and plate.rightArrow.SetAlpha then pcall(plate.rightArrow.SetAlpha, plate.rightArrow, 1) end
        fx.mutedEUIArrows = false
    end
    if fx.redName then
        fx.redName = false
        local fs = plate and plate.name
        local c = fx.euiNameColor
        if c and fs and fs.SetTextColor and IsSafe(fs) then
            fx.nameBusy = true
            pcall(fs.SetTextColor, fs, c[1], c[2], c[3], c[4] or 1)
            fx.nameBusy = false
        end
    end
    ClearPlateCastContrast(plate, fx)
end

local function EnsurePlateFX(plate)
    if not (IsSafe(plate) and IsSafe(plate.health)) then return nil end
    local fx = plateFX[plate]
    if fx then return fx end

    local health = plate.health
    local hLvl = F.PlainNumber(health.GetFrameLevel and health:GetFrameLevel(), 10) or 10

    -- 1) 兼容受限子树的箭头宿主框体（使用双端全锚，绝不用单点+尺寸防位移）
    local okTpl, arrowHost = pcall(CreateFrame, "Frame", nil, health, "DisableUntrustedLayoutScriptsTemplate")
    if not (okTpl and arrowHost) then
        arrowHost = CreateFrame("Frame", nil, health)
    end
    arrowHost:SetAllPoints(health)
    arrowHost:SetFrameLevel(hLvl + 8)
    arrowHost:EnableMouse(false)

    -- 左侧双层霓虹战术指向器（固定清晰纵横比不拉伸，底层柔和 ADD 辉光 + 顶层锐利核心）
    local leftBox = CreateFrame("Frame", nil, arrowHost)
    leftBox:SetSize(16, 13)
    leftBox:SetPoint("RIGHT", arrowHost, "LEFT", -4, 0)
    local leftGlow = leftBox:CreateTexture(nil, "OVERLAY", nil, 5)
    leftGlow:SetPoint("TOPLEFT", leftBox, "TOPLEFT", -1.5, 1.5)
    leftGlow:SetPoint("BOTTOMRIGHT", leftBox, "BOTTOMRIGHT", 1.5, -1.5)
    leftGlow:SetTexture(EUI_ARROW_DIR .. "split-left.png")
    leftGlow:SetBlendMode("ADD")
    leftGlow:SetAlpha(0.40)
    local leftTex = leftBox:CreateTexture(nil, "OVERLAY", nil, 6)
    leftTex:SetAllPoints(leftBox)
    leftTex:SetTexture(EUI_ARROW_DIR .. "split-left.png")
    local leftAG = M.EnsureBreatheShift(leftTex, 2.5, 0.95)
    local leftGlowAG = M.EnsureBreatheShift(leftGlow, 2.5, 0.95)

    -- 右侧双层霓虹战术指向器
    local rightBox = CreateFrame("Frame", nil, arrowHost)
    rightBox:SetSize(16, 13)
    rightBox:SetPoint("LEFT", arrowHost, "RIGHT", 4, 0)
    local rightGlow = rightBox:CreateTexture(nil, "OVERLAY", nil, 5)
    rightGlow:SetPoint("TOPLEFT", rightBox, "TOPLEFT", -1.5, 1.5)
    rightGlow:SetPoint("BOTTOMRIGHT", rightBox, "BOTTOMRIGHT", 1.5, -1.5)
    rightGlow:SetTexture(EUI_ARROW_DIR .. "split-right.png")
    rightGlow:SetBlendMode("ADD")
    rightGlow:SetAlpha(0.40)
    local rightTex = rightBox:CreateTexture(nil, "OVERLAY", nil, 6)
    rightTex:SetAllPoints(rightBox)
    rightTex:SetTexture(EUI_ARROW_DIR .. "split-right.png")
    local rightAG = M.EnsureBreatheShift(rightTex, -2.5, 0.95)
    local rightGlowAG = M.EnsureBreatheShift(rightGlow, -2.5, 0.95)

    arrowHost:Hide()

    -- 2) 当前目标精致斜向警示条纹（使用内置 2 次幂可无缝平铺 DiagStripes.tga，彻底消除非 POT 贴图重复拉伸/白块 bug，
    --    且宿主为独立内缩 1px 的圆角容器，绝不与 EUI 原生血条遮罩互相冲突或溢出边框）
    local stripeHost = CreateFrame("Frame", nil, health)
    stripeHost:SetPoint("TOPLEFT", health, "TOPLEFT", 1, -1)
    stripeHost:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", -1, 1)
    stripeHost:SetFrameLevel(hLvl + 2)
    stripeHost:EnableMouse(false)

    local fillTex = health:GetStatusBarTexture()
    local stripeFillClip = CreateFrame("Frame", nil, stripeHost)
    stripeFillClip:SetClipsChildren(true)
    stripeFillClip:SetPoint("TOPLEFT", stripeHost, "TOPLEFT", 0, 0)
    stripeFillClip:SetPoint("BOTTOMLEFT", stripeHost, "BOTTOMLEFT", 0, 0)
    if fillTex then
        stripeFillClip:SetPoint("RIGHT", fillTex, "RIGHT", 0, 0)
    else
        stripeFillClip:SetPoint("RIGHT", stripeHost, "RIGHT", 0, 0)
    end
    local stripeFill = stripeFillClip:CreateTexture(nil, "ARTWORK", nil, 4)
    stripeFill:SetAllPoints(stripeHost)
    stripeFill:SetTexture(ST.TEX.DIAG_STRIPES, "REPEAT", "REPEAT")
    stripeFill:SetHorizTile(true)
    stripeFill:SetVertTile(true)
    stripeFill:SetVertexColor(1, 1, 1, 0.42)
    stripeFillClip:Hide()

    local stripeBgClip = CreateFrame("Frame", nil, stripeHost)
    stripeBgClip:SetClipsChildren(true)
    stripeBgClip:SetPoint("TOPRIGHT", stripeHost, "TOPRIGHT", 0, 0)
    stripeBgClip:SetPoint("BOTTOMRIGHT", stripeHost, "BOTTOMRIGHT", 0, 0)
    if fillTex then
        stripeBgClip:SetPoint("LEFT", fillTex, "RIGHT", 0, 0)
    else
        stripeBgClip:SetPoint("LEFT", stripeHost, "LEFT", 0, 0)
    end
    local stripeBg = stripeBgClip:CreateTexture(nil, "ARTWORK", nil, 3)
    stripeBg:SetAllPoints(stripeHost)
    stripeBg:SetTexture(ST.TEX.DIAG_STRIPES, "REPEAT", "REPEAT")
    stripeBg:SetHorizTile(true)
    stripeBg:SetVertTile(true)
    stripeBg:SetVertexColor(1, 1, 1, 0.14)
    stripeBgClip:Hide()

    -- 3) 掉血延迟残影（12.x 保密值双通道，默认按需开启）
    local trail = M.AttachHealthTrail(health, {
        delay = 0.14,
        speed = 8.5,
        color = ST.COLORS.trail,
        levelOffset = 1,
    })
    if trail then trail:SetEnabled(false) end

    -- 4) 施法条高反差边光（挂载到 plate.cast 若存在）
    local castGlow = nil
    if IsSafe(plate.cast) then
        local cg = CreateFrame("Frame", nil, plate.cast)
        cg:SetPoint("TOPLEFT", plate.cast, "TOPLEFT", -2, 2)
        cg:SetPoint("BOTTOMRIGHT", plate.cast, "BOTTOMRIGHT", 2, -2)
        cg:SetFrameLevel(math_max(1, (F.PlainNumber(plate.cast:GetFrameLevel(), 10) or 10) + 4))
        cg:EnableMouse(false)
        local edges = {}
        local specs = {
            { "TOPLEFT", "TOPRIGHT", nil, 2 },
            { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 2 },
            { "TOPLEFT", "BOTTOMLEFT", 2, nil },
            { "TOPRIGHT", "BOTTOMRIGHT", 2, nil },
        }
        for i, sp in ipairs(specs) do
            local ln = cg:CreateTexture(nil, "OVERLAY", nil, 6)
            ln:SetTexture(ST.TEX.FLAT)
            ln:SetPoint(sp[1], cg, sp[1])
            ln:SetPoint(sp[2], cg, sp[2])
            if sp[3] then ln:SetWidth(sp[3]) end
            if sp[4] then ln:SetHeight(sp[4]) end
            edges[i] = ln
        end
        cg._edges = edges
        cg:Hide()
        castGlow = cg
    end

    -- 5) 头顶任务击杀进度文字（如 "1/10"，排在血条右上角，与左侧精英龙标对称且不挡怪名）
    local questFS = arrowHost:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(questFS, 11, "OUTLINE", 1.00, 0.84, 0.28, 1)
    questFS:SetPoint("BOTTOMRIGHT", health, "TOPRIGHT", 0, 3)
    questFS:SetJustifyH("RIGHT")
    questFS:Hide()

    fx = {
        arrowHost      = arrowHost,
        leftBox        = leftBox,
        rightBox       = rightBox,
        leftTex        = leftTex,
        rightTex       = rightTex,
        leftGlow       = leftGlow,
        rightGlow      = rightGlow,
        leftAG         = leftAG,
        rightAG        = rightAG,
        leftGlowAG     = leftGlowAG,
        rightGlowAG    = rightGlowAG,
        stripeHost     = stripeHost,
        stripeFillClip = stripeFillClip,
        stripeFill     = stripeFill,
        stripeBgClip   = stripeBgClip,
        stripeBg       = stripeBg,
        trail          = trail,
        castGlow       = castGlow,
        questFS        = questFS,
        mutedEUIArrows = false,
        mutedCustomBd  = false,
        dimmed         = false,
        rounded        = false,
    }
    plateFX[plate] = fx
    knownPlates[#knownPlates + 1] = plate

    -- 静音 EUI 粗糙宽大的 6px 方形目标外发光框（plate.glowFrame），并挂钩防止点击目标时被 EUI 强行拉回显示
    local function EnforceCrudeGlowMute(p)
        local gf = p and (p.glowFrame or p.glow)
        if not IsSafe(gf) then return end
        local wantMute = mod._active == true and mod:GetDB().muteCrudeTargetGlow ~= false
        if not glowGuarded[gf] then
            glowGuarded[gf] = true
            local function ClampGlow(self)
                if not glowAlphaBusy and mod._active == true and mod:GetDB().muteCrudeTargetGlow ~= false then
                    glowAlphaBusy = true
                    pcall(self.SetAlpha, self, 0)
                    glowAlphaBusy = false
                end
            end
            if gf.SetAlpha then
                _G.hooksecurefunc(gf, "SetAlpha", function(self, a)
                    if F.PlainNumber(a, 1) ~= 0 then ClampGlow(self) end
                end)
            end
            if gf.Show then _G.hooksecurefunc(gf, "Show", ClampGlow) end
            if gf.HookScript then gf:HookScript("OnShow", ClampGlow) end
        end
        glowAlphaBusy = true
        pcall(gf.SetAlpha, gf, wantMute and 0 or 1)
        glowAlphaBusy = false
    end
    fx.EnforceCrudeGlowMute = EnforceCrudeGlowMute

    -- 防止 EUI ApplyTarget 懒创建/重显宽大粗糙外发光，并同步更新精致 1px 目标细框
    if not targetHooked[plate] and type(plate.ApplyTarget) == "function" then
        targetHooked[plate] = true
        _G.hooksecurefunc(plate, "ApplyTarget", function(self)
            local f = plateFX[self]
            if f and f.EnforceCrudeGlowMute then
                f.EnforceCrudeGlowMute(self)
            end
        end)
    end

    -- 防止 EUI ApplyBorder 把直角边框盖回圆角姓名板上（绝不重复递归触发）
    if not borderHooked[plate] and type(plate.ApplyBorder) == "function" then
        borderHooked[plate] = true
        _G.hooksecurefunc(plate, "ApplyBorder", function(self)
            local f = plateFX[self]
            if f and f.rounded and mod._active and mod:GetDB().roundBars ~= false then
                if not self._npRounded then
                    local PP = _G.EllesmereUI and _G.EllesmereUI.PP
                    if PP and PP.HideBorder and self.health then pcall(PP.HideBorder, self.health) end
                    if self._customBorder and self._customBorder.SetAlpha then
                        pcall(self._customBorder.SetAlpha, self._customBorder, 0)
                        f.mutedCustomBd = true
                    end
                end
            end
        end)
    end
    -- 防止 EUI 回收/隐藏姓名板时残留呼吸箭头动画、红名或施法对比光边
    if not plateResetHooked[plate] then
        plateResetHooked[plate] = true
        if plate.HookScript then
            plate:HookScript("OnHide", function(self)
                local f = plateFX[self]
                if f then ResetPlateFX(self, f) end
            end)
        end
        if type(plate.ClearUnit) == "function" then
            _G.hooksecurefunc(plate, "ClearUnit", function(self)
                local f = plateFX[self]
                if f then ResetPlateFX(self, f) end
            end)
        end
    end
    return fx
end

local function SyncEUINPRoundProfile(enable)
    local db = mod:GetDB()
    local prof = GetEUINPProfile()
    local npNS = GetEUINPNS()
    if type(prof) ~= "table" then return end
    local changed = false
    if enable then
        local targetRad = math_max(4, math_min(8, ST.GetCornerRadius(6)))
        if db.savedEUICornerRadius == nil then
            db.savedEUICornerRadius = (prof.cornerRadius == nil) and "nil" or prof.cornerRadius
        end
        if prof.cornerRadius ~= targetRad then
            prof.cornerRadius = targetRad
            changed = true
        end
        if db.savedEUICornerRadiusAuras == nil then
            db.savedEUICornerRadiusAuras = (prof.cornerRadiusAuras == nil) and "nil" or prof.cornerRadiusAuras
        end
        if prof.cornerRadiusAuras ~= true then
            prof.cornerRadiusAuras = true
            changed = true
        end
        if (changed or lastReloadedRad ~= targetRad) and npNS and type(npNS.NPC_ReloadAll) == "function" then
            lastReloadedRad = targetRad
            pcall(npNS.NPC_ReloadAll)
        end
    else
        if db.savedEUICornerRadius ~= nil then
            prof.cornerRadius = (db.savedEUICornerRadius == "nil") and nil or db.savedEUICornerRadius
            db.savedEUICornerRadius = nil
            changed = true
        end
        if db.savedEUICornerRadiusAuras ~= nil then
            prof.cornerRadiusAuras = (db.savedEUICornerRadiusAuras == "nil") and nil or db.savedEUICornerRadiusAuras
            db.savedEUICornerRadiusAuras = nil
            changed = true
        end
        lastReloadedRad = nil
        if changed and npNS and type(npNS.NPC_ReloadAll) == "function" then
            pcall(npNS.NPC_ReloadAll)
        end
    end
end

-- 非目标压暗交给 EUI 自己的 Non-Target Opacity 引擎（ns.NT_Apply）：它按姓名板根框体做带缓存的
-- 透明度合成（含距离淡隐、脱战淡隐、施法保持不透明、焦点豁免）。直接 plate:SetAlpha 会绕过它的缓存，
-- 让远处怪变亮、取消目标后距离淡隐失效。这里只覆盖运行时缓存 _ntAlpha，绝不写入 EUI 存档；
-- 用户若已在 EUI 里自己开了非目标透明度，则完全尊重 EUI 的设置。
local ntOverrideActive = false

local function HasEUINonTargetEngine()
    local npNS = GetEUINPNS()
    return npNS ~= nil and type(npNS.NT_ApplyAll) == "function", npNS
end

local function SyncEUINonTargetDim()
    local ok, npNS = HasEUINonTargetEngine()
    if not ok then return end
    local db = mod:GetDB()
    local prof = GetEUINPProfile()
    local euiOwn = prof and F.PlainNumber(prof.nonTargetAlpha, 100) or 100
    local want = mod._active == true and db.dimNonTarget ~= false and euiOwn >= 100
    if want then
        local a = math_max(0.40, math_min(0.95, F.PlainNumber(db.nonTargetAlpha, 0.78) or 0.78))
        ntOverrideActive = true
        if npNS._ntAlpha ~= a then
            npNS._ntAlpha = a
            pcall(npNS.NT_ApplyAll)
        end
    elseif ntOverrideActive then
        ntOverrideActive = false
        if type(npNS.NT_RefreshSetting) == "function" then
            pcall(npNS.NT_RefreshSetting) -- 从 EUI 档案重新推导并重新套用全部姓名板
        else
            npNS._ntAlpha = math_max(0, math_min(1, euiOwn / 100))
            pcall(npNS.NT_ApplyAll)
        end
    end
end

local function ApplyPlateRounding(plate, fx, active, isTarget)
    local health = plate.health
    if not IsSafe(health) then return end
    local wantRound = active and mod:GetDB().roundBars ~= false
    local rad = math_min(ST.GetCornerRadius(6), math_max(3, math_floor((F.PlainNumber(health:GetHeight(), 14) or 14) * 0.44)))
    local EUI = _G.EllesmereUI
    local PP = EUI and EUI.PP
    local npNS = GetEUINPNS()

    -- 静音/恢复 EUI 粗糙宽大的 6px 方形目标外发光框
    if fx.EnforceCrudeGlowMute then
        fx.EnforceCrudeGlowMute(plate)
    end

    if wantRound and rad > 0 then
        -- 1) 优先调用 EUI 原生 GPU 圆角引擎（把血条、原边框与施法条平滑圆角化）
        if npNS and type(npNS.NP_ApplyRounding) == "function" then
            pcall(npNS.NP_ApplyRounding, plate)
        end

        -- 2) 斜向条纹与掉血残影使用独立的 1px 内缩宿主遮罩，绝不与 EUI 血条自身的 MaskTexture 冲突
        local innerRad = math_max(2, rad - 1)
        if fx.stripeHost then
            if fx.stripeFill then ST.MaskTexture(fx.stripeHost, fx.stripeFill, innerRad) end
            if fx.stripeBg then ST.MaskTexture(fx.stripeHost, fx.stripeBg, innerRad) end
        end
        if fx.trail and fx.trail._bar then
            local tTex = fx.trail._bar:GetStatusBarTexture()
            if tTex then ST.MaskTexture(fx.trail._bar, tTex, innerRad) end
        end

        -- 3) 精致 1px 贴边圆角目标细框 vs 兜底路径（绝不调用 SetFrameStrata("MEDIUM") 破坏姓名板景深排序！）
        if not plate._npRounded then
            local fillTex = health.GetStatusBarTexture and health:GetStatusBarTexture() or nil
            if fillTex then ST.MaskTexture(health, fillTex, rad) end
            if plate.healthBG then ST.MaskTexture(health, plate.healthBG, rad) end
            if plate.hashLine then ST.MaskTexture(health, plate.hashLine, rad) end
            if plate.highlight then ST.MaskTexture(health, plate.highlight, rad) end
            if plate.targetHighlight then ST.MaskTexture(health, plate.targetHighlight, rad) end
            if PP and PP.HideBorder then pcall(PP.HideBorder, health) end
            if plate._customBorder and plate._customBorder.SetAlpha then
                pcall(plate._customBorder.SetAlpha, plate._customBorder, 0)
                fx.mutedCustomBd = true
            end
            if isTarget then
                local cr, cg, cb = ResolveArrowColors(mod:GetDB().arrowColorMode or "amber")
                ST.ApplyRoundedBorder(health, rad, cr, cg, cb, 0.96, 6)
            else
                ST.ApplyRoundedBorder(health, rad, 0.04, 0.045, 0.06, 0.92, 6)
            end
        else
            -- EUI 原生圆角已接管血条主体：还原 _customBorder，仅在当前目标且已关闭粗糙外发光时叠加一条超精细 1px 贴边高亮细框
            if fx.mutedCustomBd and plate._customBorder and plate._customBorder.SetAlpha then
                pcall(plate._customBorder.SetAlpha, plate._customBorder, 1)
                fx.mutedCustomBd = false
            end
            if isTarget and mod:GetDB().muteCrudeTargetGlow ~= false then
                local cr, cg, cb = ResolveArrowColors(mod:GetDB().arrowColorMode or "amber")
                ST.ApplyRoundedBorder(health, rad, cr, cg, cb, 0.94, 7)
            else
                ST.ApplyRoundedBorder(health, 0)
            end
        end

        if IsSafe(plate.cast) and not plate._npRounded then
            local cH = F.PlainNumber(plate.cast:GetHeight(), 10) or 10
            local cRad = math_min(ST.GetCornerRadius(5), math_max(2, math_floor(cH * 0.44)))
            local cFill = plate.cast.GetStatusBarTexture and plate.cast:GetStatusBarTexture() or nil
            if cFill then ST.MaskTexture(plate.cast, cFill, cRad) end
            if plate.castBG then ST.MaskTexture(plate.cast, plate.castBG, cRad) end
            if PP and PP.HideBorder then pcall(PP.HideBorder, plate.cast) end
            ST.ApplyRoundedBorder(plate.cast, cRad, 0.03, 0.035, 0.05, 0.92, 5)
        end
        fx.rounded = true
    elseif fx.rounded then
        ST.ClearRoundedMask(health)
        if fx.stripeHost then ST.ClearRoundedMask(fx.stripeHost) end
        if fx.trail and fx.trail._bar then ST.ClearRoundedMask(fx.trail._bar) end
        if fx.mutedCustomBd and plate._customBorder and plate._customBorder.SetAlpha then
            pcall(plate._customBorder.SetAlpha, plate._customBorder, 1)
            fx.mutedCustomBd = false
        end
        if npNS and type(npNS.NP_ApplyRounding) == "function" then
            pcall(npNS.NP_ApplyRounding, plate)
        end
        if IsSafe(plate.cast) then
            fx.castBorderApplied = false
            ST.ClearRoundedMask(plate.cast)
            if PP and PP.ShowBorder then pcall(PP.ShowBorder, plate.cast) end
        end
        fx.rounded = false
        if PP and PP.ShowBorder then pcall(PP.ShowBorder, health) end
        if type(plate.ApplyBorder) == "function" then pcall(plate.ApplyBorder, plate) end
    end
end

-- 敌对阵营玩家红名：EUI 敌方姓名板的名字颜色按文字槽位统一着色，怪物与敌对玩家常是同一种颜色。
-- 这里只给「敌对阵营玩家」改成红名；挂钩记住 EUI 自己想要的颜色，单位不再是敌对玩家时原样还给 EUI。
local function IsHostilePlayer(unit)
    if not unit then return false end
    local okP, isP = pcall(_G.UnitIsPlayer, unit)
    if not (okP and not F.IsSecret(isP) and isP == true) then return false end
    if not _G.UnitIsFriend then return false end
    local okF, isFriend = pcall(_G.UnitIsFriend, "player", unit)
    return okF and not F.IsSecret(isFriend) and isFriend == false
end

local function ApplyHostileNameColor(plate, fx, unit, active)
    local fs = plate.name
    if not (fs and fs.SetTextColor and IsSafe(fs)) then return end
    if not fx.nameHooked then
        fx.nameHooked = true
        _G.hooksecurefunc(fs, "SetTextColor", function(self, r, g, b, a)
            if fx.nameBusy then return end
            local pr = F.PlainNumber(r, nil)
            local pg = F.PlainNumber(g, nil)
            local pb = F.PlainNumber(b, nil)
            local pa = F.PlainNumber(a, 1) or 1
            if pr and pg and pb then
                fx.euiNameColor = { pr, pg, pb, pa }
            end
            if fx.redName then
                local h = ST.COLORS.hostile
                fx.nameBusy = true
                pcall(self.SetTextColor, self, h[1], h[2], h[3], 1)
                fx.nameBusy = false
            end
        end)
    end
    local want = active and mod:GetDB().redHostilePlayers ~= false and IsHostilePlayer(unit)
    if want then
        if not fx.euiNameColor and fs.GetTextColor then
            local okC, cr, cg, cb, ca = pcall(fs.GetTextColor, fs)
            if okC then
                local pr = F.PlainNumber(cr, nil)
                local pg = F.PlainNumber(cg, nil)
                local pb = F.PlainNumber(cb, nil)
                local pa = F.PlainNumber(ca, 1) or 1
                if pr and pg and pb then
                    fx.euiNameColor = { pr, pg, pb, pa }
                end
            end
        end
        fx.redName = true
        local h = ST.COLORS.hostile
        fx.nameBusy = true
        pcall(fs.SetTextColor, fs, h[1], h[2], h[3], 1)
        fx.nameBusy = false
    elseif fx.redName then
        fx.redName = false
        local c = fx.euiNameColor
        if c then
            fx.nameBusy = true
            pcall(fs.SetTextColor, fs, c[1], c[2], c[3], c[4] or 1)
            fx.nameBusy = false
        end
    end
end

local function UpdatePlateCastContrast(plate, fx, unit)
    if not (fx and fx.castGlow) then return end
    if not (mod._active and mod:GetDB().castContrast ~= false and unit and plate.cast and plate.cast:IsShown()) then
        ClearPlateCastContrast(plate, fx)
        return
    end
    local hasCast = false
    local notInt = nil
    if _G.UnitCastingInfo then
        local okC, name, _, _, _, _, _, _, ni = pcall(_G.UnitCastingInfo, unit)
        if okC and type(name) ~= "nil" then
            hasCast = true
            notInt = ni
        end
    end
    if (not hasCast) and _G.UnitChannelInfo then
        local okCh, name, _, _, _, _, _, ni = pcall(_G.UnitChannelInfo, unit)
        if okCh and type(name) ~= "nil" then
            hasCast = true
            notInt = ni
        end
    end
    if (not hasCast) or F.IsSecret(notInt) then
        ClearPlateCastContrast(plate, fx)
        return
    end
    local isUnint = (notInt == true)
    local r, g, b, a
    if isUnint then
        r, g, b, a = 0.56, 0.58, 0.64, 0.78
    else
        r, g, b, a = 1.00, 0.78, 0.24, 0.96
    end
    if fx.rounded and IsSafe(plate.cast) then
        fx.castGlow:Hide()
        local cH = F.PlainNumber(plate.cast:GetHeight(), 10) or 10
        local cRad = math_min(ST.GetCornerRadius(5), math_max(2, math_floor(cH * 0.44)))
        ST.ApplyRoundedBorder(plate.cast, cRad, r, g, b, a, 6)
        fx.castBorderApplied = true
    else
        if fx.castBorderApplied and IsSafe(plate.cast) then
            fx.castBorderApplied = false
            ST.ApplyRoundedBorder(plate.cast, 0)
        end
        for i = 1, 4 do
            fx.castGlow._edges[i]:SetVertexColor(r, g, b, a)
        end
        fx.castGlow:Show()
    end
end

local function PaintSinglePlate(plate, instantTrail)
    if not (IsSafe(plate) and IsSafe(plate.health)) then return end
    local fx = EnsurePlateFX(plate)
    if not fx then return end

    local unit = plate.unit
    local db = mod:GetDB()
    local active = mod._active == true and unit ~= nil and plate:IsShown()
    local hasTarget = (_G.UnitExists and _G.UnitExists("target")) == true
    local isTarget = active and IsUnitTarget(unit)

    -- 0) 血条与施法条圆角美化
    ApplyPlateRounding(plate, fx, active, isTarget)

    -- 1) 呼吸箭头与任务击杀进度（若 EUI / Questie 本身已在姓名板左侧显示 1/8 进度，则自动让位，绝不重复显示两份）
    local function PlateAlreadyHasQuestText(p)
        if p.questTextFrame and p.questTextFrame.IsShown and p.questTextFrame:IsShown() then
            if p.questTextFrame.GetRegions then
                for _, reg in ipairs({ p.questTextFrame:GetRegions() }) do
                    if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" and reg:IsShown() then
                        local t = reg.GetText and F.PlainString(reg:GetText(), "") or ""
                        if t ~= "" then return true end
                    end
                end
            end
            if p.questText and p.questText.GetText then
                local t = F.PlainString(p.questText:GetText(), "") or ""
                if t ~= "" then return true end
            end
        end
        if p.questText and p.questText.IsShown and p.questText:IsShown() and p.questText.GetText then
            local t = F.PlainString(p.questText:GetText(), "") or ""
            if t ~= "" then return true end
        end
        return false
    end

    local wantArrows = active and isTarget and db.breathingArrows ~= false
    local qText = (active and db.showQuestProgress ~= false and not PlateAlreadyHasQuestText(plate))
        and GetUnitQuestProgress(unit) or nil
    if fx.questFS then
        if qText then
            fx.questFS:SetText(qText)
            fx.questFS:Show()
        else
            fx.questFS:Hide()
        end
    end

    if wantArrows then
        local sc = math_max(0.7, math_min(1.6, F.PlainNumber(db.arrowScale, 1.0) or 1.0))
        local st = ARROW_STYLES[db.arrowStyle or "split"] or ARROW_STYLES.split
        local cr, cg, cb, gr, gg, gb = ResolveArrowColors(db.arrowColorMode or "amber")
        local w = math_floor(st.w * sc + 0.5)
        local h = math_floor(st.h * sc + 0.5)

        fx.leftBox:SetSize(w, h)
        fx.rightBox:SetSize(w, h)
        fx.leftTex:SetTexture(EUI_ARROW_DIR .. st.l)
        fx.rightTex:SetTexture(EUI_ARROW_DIR .. st.r)
        fx.leftTex:SetVertexColor(cr, cg, cb, 0.98)
        fx.rightTex:SetVertexColor(cr, cg, cb, 0.98)
        fx.leftGlow:SetTexture(EUI_ARROW_DIR .. st.l)
        fx.rightGlow:SetTexture(EUI_ARROW_DIR .. st.r)
        fx.leftGlow:SetVertexColor(gr, gg, gb, 0.40)
        fx.rightGlow:SetVertexColor(gr, gg, gb, 0.40)

        fx.leftBox:Show()
        fx.rightBox:Show()
        fx.arrowHost:Show()
        if fx.leftAG and not fx.leftAG:IsPlaying() then fx.leftAG:Play() end
        if fx.rightAG and not fx.rightAG:IsPlaying() then fx.rightAG:Play() end
        if fx.leftGlowAG and not fx.leftGlowAG:IsPlaying() then fx.leftGlowAG:Play() end
        if fx.rightGlowAG and not fx.rightGlowAG:IsPlaying() then fx.rightGlowAG:Play() end
        -- 避免与 EUI 静态箭头重叠，临时静音原生箭头（停用时还原）
        if plate.leftArrow and plate.leftArrow.SetAlpha then pcall(plate.leftArrow.SetAlpha, plate.leftArrow, 0) end
        if plate.rightArrow and plate.rightArrow.SetAlpha then pcall(plate.rightArrow.SetAlpha, plate.rightArrow, 0) end
        fx.mutedEUIArrows = true
    else
        if fx.leftAG and fx.leftAG:IsPlaying() then fx.leftAG:Stop() end
        if fx.rightAG and fx.rightAG:IsPlaying() then fx.rightAG:Stop() end
        if fx.leftGlowAG and fx.leftGlowAG:IsPlaying() then fx.leftGlowAG:Stop() end
        if fx.rightGlowAG and fx.rightGlowAG:IsPlaying() then fx.rightGlowAG:Stop() end
        fx.leftBox:Hide()
        fx.rightBox:Hide()
        fx.arrowHost:SetShown(qText ~= nil)
        if fx.mutedEUIArrows then
            if plate.leftArrow and plate.leftArrow.SetAlpha then pcall(plate.leftArrow.SetAlpha, plate.leftArrow, 1) end
            if plate.rightArrow and plate.rightArrow.SetAlpha then pcall(plate.rightArrow.SetAlpha, plate.rightArrow, 1) end
            fx.mutedEUIArrows = false
        end
    end

    -- 2) 当前目标精致斜向警示条纹（严格内缩 1px 宿主容器内，零溢出）
    local wantStripes = active and isTarget and db.targetStripes ~= false
    if wantStripes and fx.stripeHost then
        local sa = math_max(0.15, math_min(0.85, F.PlainNumber(db.stripeAlpha, 0.42) or 0.42))
        local fillTex = plate.health:GetStatusBarTexture()
        if fillTex then
            fx.stripeFillClip:ClearAllPoints()
            fx.stripeFillClip:SetPoint("TOPLEFT", fx.stripeHost, "TOPLEFT", 0, 0)
            fx.stripeFillClip:SetPoint("BOTTOMLEFT", fx.stripeHost, "BOTTOMLEFT", 0, 0)
            fx.stripeFillClip:SetPoint("RIGHT", fillTex, "RIGHT", 0, 0)
            fx.stripeBgClip:ClearAllPoints()
            fx.stripeBgClip:SetPoint("TOPRIGHT", fx.stripeHost, "TOPRIGHT", 0, 0)
            fx.stripeBgClip:SetPoint("BOTTOMRIGHT", fx.stripeHost, "BOTTOMRIGHT", 0, 0)
            fx.stripeBgClip:SetPoint("LEFT", fillTex, "RIGHT", 0, 0)
        end
        fx.stripeFill:SetVertexColor(1, 1, 1, sa)
        fx.stripeBg:SetVertexColor(1, 1, 1, sa * 0.25)
        fx.stripeFillClip:Show()
        fx.stripeBgClip:Show()
    else
        fx.stripeFillClip:Hide()
        fx.stripeBgClip:Hide()
    end

    -- 3) 非目标柔和降暗（有 EUI 透明度引擎时由 SyncEUINonTargetDim 统一处理，这里只是兜底）
    local wantDim = (not HasEUINonTargetEngine()) and active and hasTarget and (not isTarget) and db.dimNonTarget ~= false
    if wantDim then
        local targetA = math_max(0.40, math_min(0.95, F.PlainNumber(db.nonTargetAlpha, 0.78) or 0.78))
        plate:SetAlpha(targetA)
        fx.dimmed = true
    elseif fx.dimmed then
        plate:SetAlpha(1)
        fx.dimmed = false
    end

    -- 4) 轻量受击掉血残影
    if fx.trail then
        local tMode = db.trailMode or "target"
        local wantTrail = active and (tMode == "all" or (tMode == "target" and isTarget))
        fx.trail:SetEnabled(wantTrail)
        if wantTrail then
            fx.trail:UpdateFromUnit(unit, instantTrail)
        end
    end

    -- 4b) 敌对阵营玩家红名
    ApplyHostileNameColor(plate, fx, unit, active)

    -- 5) 施法条打断高反差光边
    UpdatePlateCastContrast(plate, fx, unit)
end

local function SyncFriendlyPlateGlows()
    local npNS = GetEUINPNS()
    local fPlates = npNS and npNS.friendlyPlates
    if type(fPlates) ~= "table" then return end
    local wantMute = mod._active == true and mod:GetDB().muteCrudeTargetGlow ~= false
    for _, fp in pairs(fPlates) do
        local gf = fp and (fp.glowFrame or fp.glow)
        if IsSafe(gf) then
            if not glowGuarded[gf] then
                glowGuarded[gf] = true
                local function ClampGlow(self)
                    if not glowAlphaBusy and mod._active == true and mod:GetDB().muteCrudeTargetGlow ~= false then
                        glowAlphaBusy = true
                        pcall(self.SetAlpha, self, 0)
                        glowAlphaBusy = false
                    end
                end
                if gf.SetAlpha then
                    _G.hooksecurefunc(gf, "SetAlpha", function(self, a)
                        if F.PlainNumber(a, 1) ~= 0 then ClampGlow(self) end
                    end)
                end
                if gf.Show then _G.hooksecurefunc(gf, "Show", ClampGlow) end
            end
            glowAlphaBusy = true
            pcall(gf.SetAlpha, gf, wantMute and 0 or 1)
            glowAlphaBusy = false
        end
    end
end

local function RefreshAllPlates(instantTrail)
    SyncEUINPRoundProfile(mod._active == true and mod:GetDB().roundBars ~= false and ST.GetCornerRadius(6) > 0)
    SyncFriendlyPlateGlows()
    SyncEUINonTargetDim()
    local plates = GetEUIPlates()
    if type(plates) ~= "table" then return end
    for _, plate in pairs(plates) do
        PaintSinglePlate(plate, instantTrail)
    end
end

local function FindPlateByUnit(unit)
    local plates = GetEUIPlates()
    if type(plates) ~= "table" or not unit then return nil end
    local direct = plates[unit]
    if direct and direct.unit == unit then
        return direct
    end
    for _, plate in pairs(plates) do
        if plate and plate.unit == unit then
            return plate
        end
    end
    return nil
end

function mod:OnEnable()
    self:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        RefreshAllPlates(true)
        -- 下一帧再同步一次，确保拦截 EUI 在 PLAYER_TARGET_CHANGED 中懒创建的 glowFrame
        C_Timer.After(0, function()
            if mod._active then RefreshAllPlates(true) end
        end)
    end)
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, _, unit)
        local u = F.PlainString(unit, nil)
        if not u then return end
        questTextCache[u] = nil
        C_Timer.After(0.02, function()
            if not mod._active then return end
            local p = FindPlateByUnit(u)
            if p then
                PaintSinglePlate(p, true)
            else
                local npNS = GetEUINPNS()
                if npNS and type(npNS.friendlyPlates) == "table" and npNS.friendlyPlates[u] then
                    SyncFriendlyPlateGlows()
                end
            end
        end)
    end)
    self:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, _, unit)
        local u = F.PlainString(unit, nil)
        if not u then return end
        questTextCache[u] = nil
        local p = FindPlateByUnit(u)
        if p then
            local fx = plateFX[p]
            if fx then ResetPlateFX(p, fx) end
        end
    end)
    local QueueQuestRefresh = F.Debounce(0.15, function()
        WipeQuestCache()
        if mod._active then RefreshAllPlates(true) end
    end)
    self:RegisterEvent("QUEST_LOG_UPDATE", QueueQuestRefresh)
    self:RegisterUnitEvent("UNIT_QUEST_LOG_CHANGED", "player", QueueQuestRefresh)
    self:RegisterEvent("UNIT_HEALTH", function(_, _, unit)
        local u = F.PlainString(unit, nil)
        if not u or u:sub(1, 9) ~= "nameplate" then return end
        local tMode = mod:GetDB().trailMode or "target"
        if tMode == "off" then return end
        if tMode == "target" and not IsUnitTarget(u) then return end
        local p = FindPlateByUnit(u)
        if p then
            local fx = plateFX[p]
            if fx and fx.trail then fx.trail:UpdateFromUnit(u, false) end
        end
    end)
    local function OnPlateCast(_, _, unit)
        local u = F.PlainString(unit, nil)
        if not u or u:sub(1, 9) ~= "nameplate" then return end
        local p = FindPlateByUnit(u)
        if p then
            local fx = EnsurePlateFX(p)
            if fx then
                C_Timer.After(0, function()
                    if mod._active and p and p.unit == u then
                        UpdatePlateCastContrast(p, fx, u)
                    end
                end)
            end
        end
    end
    self:RegisterEvent("UNIT_SPELLCAST_START", OnPlateCast)
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START", OnPlateCast)
    self:RegisterEvent("UNIT_SPELLCAST_STOP", OnPlateCast)
    self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", OnPlateCast)
    self:RegisterEvent("UNIT_SPELLCAST_FAILED", OnPlateCast)
    self:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP", OnPlateCast)
    self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTIBLE", OnPlateCast)
    self:RegisterEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", OnPlateCast)
    InstallTeleportFlashGuard()

    local function RunTeleportSweepBurst()
        WipeQuestCache()
        SweepBlizzNameplateFlash()
        C_Timer.After(0.02, function() if mod._active then SweepBlizzNameplateFlash() end end)
        C_Timer.After(0.08, function() if mod._active then SweepBlizzNameplateFlash() end end)
        C_Timer.After(0.22, function() if mod._active then SweepBlizzNameplateFlash(); RefreshAllPlates(true) end end)
        C_Timer.After(0.55, function() if mod._active then SweepBlizzNameplateFlash(); RefreshAllPlates(true) end end)
    end
    self:RegisterEvent("PLAYER_ENTERING_WORLD", RunTeleportSweepBurst)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", RunTeleportSweepBurst)

    SweepBlizzNameplateFlash()
    RefreshAllPlates(true)
end

function mod:OnDisable()
    SyncEUINPRoundProfile(false)
    SyncFriendlyPlateGlows()
    SyncEUINonTargetDim()
    for _, plate in ipairs(knownPlates) do
        if IsSafe(plate) then
            PaintSinglePlate(plate, true)
        end
    end
end

function mod:OnRefresh()
    RefreshAllPlates(true)
end

function mod:OnThemeChanged()
    RefreshAllPlates(true)
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "姓名板血条与施法条圆角美化",
        tooltip = "将 EUI 姓名板的血条与施法条统一升级为抗锯齿圆角胶囊与 1px 圆角细框。",
        getValue = function() return db.roundBars ~= false end,
        setValue = function(v) db.roundBars = v == true; RefreshAllPlates(true) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "关闭粗糙宽大外发光，改用 1px 贴边圆角高亮框",
        tooltip = "屏蔽 EUI 原生 6px 宽糊外发光框，改用贴合血条边缘的 1px 锐利圆角锁敌细框，清晰精致不毛糙。",
        getValue = function() return db.muteCrudeTargetGlow ~= false end,
        setValue = function(v) db.muteCrudeTargetGlow = v == true; RefreshAllPlates(true) end,
    }, {
        type = "toggle",
        text = "头顶显示任务击杀/收集进度（如 1/10）",
        tooltip = "在任务目标怪物血条右上方醒目显示当前进度（野外与副本内同样生效，击杀后实时跳数，不与 EUI 自带进度重复）。",
        getValue = function() return db.showQuestProgress ~= false end,
        setValue = function(v) db.showQuestProgress = v == true; WipeQuestCache(); RefreshAllPlates(true) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "当前目标左右霓虹呼吸指向器",
        tooltip = "选中目标时在姓名板两侧展示双层霓虹呼吸指向标，清晰炫酷锁定焦点。",
        getValue = function() return db.breathingArrows ~= false end,
        setValue = function(v) db.breathingArrows = v == true; RefreshAllPlates(true) end,
    }, {
        type = "dropdown",
        text = "目标指向器造型",
        disabled = function() return db.breathingArrows == false end,
        values = {
            split   = "裂刃双翼（推荐·简洁炫酷）",
            double  = "流光双箭（Double）",
            bracket = "战术锁框（Bracket）",
            crystal = "霓虹棱晶（Crystal）",
            curved  = "弧光瞄准（Curved）",
            winged  = "锐翼准星（Winged）",
        },
        order = { "split", "double", "bracket", "crystal", "curved", "winged" },
        getValue = function() return db.arrowStyle or "split" end,
        setValue = function(v) db.arrowStyle = v; RefreshAllPlates(true) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "目标指向器流光配色",
        disabled = function() return db.breathingArrows == false end,
        values = {
            amber   = "熔金霓虹锁敌（推荐）",
            class   = "当前职业流光色",
            green   = "青草绿霓虹",
            cyan    = "冰蓝电弧",
            crimson = "炽焰猩红",
        },
        order = { "amber", "class", "green", "cyan", "crimson" },
        getValue = function() return db.arrowColorMode or "amber" end,
        setValue = function(v) db.arrowColorMode = v; RefreshAllPlates(true) end,
    }, {
        type = "toggle",
        text = "当前目标高对比斜向警示条纹",
        tooltip = "为当前目标血条叠加高辨识度斜向条纹，在多怪混战中一眼锁定焦点目标。",
        getValue = function() return db.targetStripes ~= false end,
        setValue = function(v) db.targetStripes = v == true; RefreshAllPlates(true) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "斜向条纹亮度",
        min = 0.20, max = 0.85, step = 0.05,
        disabled = function() return db.targetStripes == false end,
        getValue = function() return F.PlainNumber(db.stripeAlpha, 0.42) or 0.42 end,
        setValue = function(v) db.stripeAlpha = v; RefreshAllPlates(true) end,
    }, {
        type = "toggle",
        text = "非目标姓名板柔和压暗",
        getValue = function() return db.dimNonTarget ~= false end,
        setValue = function(v) db.dimNonTarget = v == true; RefreshAllPlates(true) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "非目标透明度",
        min = 0.45, max = 0.95, step = 0.05,
        disabled = function() return db.dimNonTarget == false end,
        getValue = function() return F.PlainNumber(db.nonTargetAlpha, 0.78) or 0.78 end,
        setValue = function(v) db.nonTargetAlpha = v; RefreshAllPlates(true) end,
    }, {
        type = "toggle",
        text = "施法条可打断 / 不可打断高反差光边",
        getValue = function() return db.castContrast ~= false end,
        setValue = function(v) db.castContrast = v == true; RefreshAllPlates(true) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "姓名板掉血延迟残影范围",
        tooltip = "推荐「仅当前目标」以保持大群拉怪极限帧率，高配机器可开启「全部可见姓名板」。",
        values = {
            target = "仅当前目标（推荐·低开销）",
            all    = "全部可见姓名板",
            off    = "关闭残影",
        },
        order = { "target", "all", "off" },
        getValue = function() return db.trailMode or "target" end,
        setValue = function(v) db.trailMode = v; RefreshAllPlates(true) end,
    }, {
        type = "toggle",
        text = "过图/传送瞬间拦截暴雪原生姓名板闪现",
        getValue = function() return db.suppressTeleportFlash ~= false end,
        setValue = function(v) db.suppressTeleportFlash = v == true; SweepBlizzNameplateFlash() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "敌对阵营玩家显示红名（区分怪物）",
        tooltip = "野外遇到敌对阵营玩家时，姓名板名字改成红色，与同色的怪物一眼区分；顶部目标条与目标的目标同样显示红名。",
        getValue = function() return db.redHostilePlayers ~= false end,
        setValue = function(v) db.redHostilePlayers = v == true; RefreshAllPlates(true) end,
    })
    y = y - h

    return y
end
