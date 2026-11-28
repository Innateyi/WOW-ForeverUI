----------------------------------------------------------------------
--  kkowoUI — Core/MotionEngine.lua
--  高性能公共动效原语引擎：
--    • DelayedTrailController（12.x 保密值双通道受击掉血延迟残影条）
--    • SmoothBar（帧率无关指数插值，空闲 0 OnUpdate 自动休眠）
--    • EdgeSpark（前沿高光切边光刃，直接锚定 StatusBar 填充纹理 0 OnUpdate）
--    • AnimPresets（纯原生 AnimationGroup：完成白闪上浮、打断红抖、弹入、旋转环、属性闪烁）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local math_abs, math_exp, math_max, math_min, next, pairs, pcall, setmetatable, type =
    math.abs, math.exp, math.max, math.min, next, pairs, pcall, setmetatable, type
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer

local M = {}
F.Motion = M

local ST = F.StyleTokens
local EASE_OUT_ENUM = _G.Enum and _G.Enum.StatusBarInterpolation and _G.Enum.StatusBarInterpolation.ExponentialEaseOut or nil
local IMMEDIATE_ENUM = _G.Enum and _G.Enum.StatusBarInterpolation and _G.Enum.StatusBarInterpolation.Immediate or nil

----------------------------------------------------------------------
--  1) 单例零 GC 共享驱动器：仅当存在活跃平滑插值任务时 Show，空闲立刻 Hide（0 CPU）
----------------------------------------------------------------------
local activeTasks = {}
local driver = CreateFrame("Frame")
driver:Hide()

driver:SetScript("OnUpdate", function(self, elapsed)
    local dt = elapsed or 0.016
    if dt > 0.1 then dt = 0.1 end
    local now = GetTime()
    local any = false
    for task in pairs(activeTasks) do
        local keep = task._tick(task, dt, now)
        if keep then
            any = true
        else
            activeTasks[task] = nil
        end
    end
    if not any then
        self:Hide()
    end
end)

local function WakeTask(task)
    activeTasks[task] = true
    if not driver:IsShown() then
        driver:Show()
    end
end

local function SleepTask(task)
    activeTasks[task] = nil
    if next(activeTasks) == nil and driver:IsShown() then
        driver:Hide()
    end
end

----------------------------------------------------------------------
--  2) DelayedTrailController：受击掉血延迟残影条
--     • 采用「fillTex 边沿裁剪子框 + 内部 StatusBar」架构：
--       1. 天然绘制在主条 bg 之上、护盾/治疗预测/文字之下，不遮挡任何元素
--       2. 回血时主填充右移瞬间裁掉残影，零拖尾伪影
--       3. 非保密数值：精确滞留 delay (0.15~0.20s) + 指数 Ease-Out 追赶
--       4. 12.x 保密数值：零 Lua 算术比较，直接延迟推值给 C 端 StatusBar
----------------------------------------------------------------------
local trailRegistry = setmetatable({}, { __mode = "k" })

local function TickTrail(ctrl, dt, now)
    if not ctrl._enabled or not ctrl._bar or not ctrl._bar:IsVisible() then
        return false
    end
    if ctrl._secretMode then
        return false
    end
    if ctrl._trailVal <= ctrl._targetVal + 0.0005 then
        ctrl._trailVal = ctrl._targetVal
        ctrl._bar:SetValue(ctrl._trailVal)
        return false
    end
    if now < ctrl._holdUntil then
        return true
    end
    local k = 1 - math_exp(-(ctrl._speed or 7.5) * dt)
    ctrl._trailVal = ctrl._trailVal + (ctrl._targetVal - ctrl._trailVal) * k
    if ctrl._trailVal <= ctrl._targetVal + 0.001 then
        ctrl._trailVal = ctrl._targetVal
        ctrl._bar:SetValue(ctrl._trailVal)
        return false
    end
    ctrl._bar:SetValue(ctrl._trailVal)
    return true
end

local function ReanchorTrailClip(ctrl)
    local host = ctrl._host
    local clip = ctrl._clip
    local bar = ctrl._bar
    if not (host and clip and bar) then return end
    local fillTex = host.GetStatusBarTexture and host:GetStatusBarTexture() or nil
    if not fillTex then return end
    local rev = ctrl._reverse
    if rev == nil and host.GetReverseFill then
        local ok, r = pcall(host.GetReverseFill, host)
        rev = ok and r == true or false
    end
    clip:ClearAllPoints()
    if rev then
        clip:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        clip:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
        clip:SetPoint("RIGHT", fillTex, "LEFT", 0, 0)
    else
        clip:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
        clip:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
        clip:SetPoint("LEFT", fillTex, "RIGHT", 0, 0)
    end
    if bar.SetReverseFill then
        bar:SetReverseFill(rev == true)
    end
    bar:ClearAllPoints()
    bar:SetAllPoints(host)
end

function M.AttachHealthTrail(healthBar, opts)
    if not (healthBar and healthBar.GetStatusBarTexture) then return nil end
    if healthBar.IsForbidden then
        local okF, forb = pcall(healthBar.IsForbidden, healthBar)
        if not okF or forb then return nil end
    end
    opts = opts or {}
    local existing = trailRegistry[healthBar]
    if existing then
        if opts.delay then existing._delay = opts.delay end
        if opts.speed then existing._speed = opts.speed end
        if opts.color then existing:SetColor(opts.color[1], opts.color[2], opts.color[3], opts.color[4]) end
        if opts.reverse ~= nil then existing._reverse = opts.reverse end
        ReanchorTrailClip(existing)
        return existing
    end

    local clip = CreateFrame("Frame", nil, healthBar)
    clip:SetClipsChildren(true)
    clip:EnableMouse(false)
    local hLvl = F.PlainNumber(healthBar.GetFrameLevel and healthBar:GetFrameLevel(), 10) or 10
    clip:SetFrameLevel(hLvl + (opts.levelOffset or 1))

    local trailBar = CreateFrame("StatusBar", nil, clip)
    trailBar:SetStatusBarTexture(ST.TEX.FLAT)
    trailBar:SetMinMaxValues(0, 1)
    trailBar:SetValue(1)
    trailBar:EnableMouse(false)
    trailBar:SetFrameLevel(clip:GetFrameLevel())

    local c = opts.color or ST.COLORS.trail
    trailBar:SetStatusBarColor(c[1], c[2], c[3], c[4] or 0.72)

    if opts.radius and opts.radius > 0 then
        local tTex = trailBar:GetStatusBarTexture()
        if tTex then
            ST.MaskTexture(healthBar, tTex, opts.radius)
        end
    end

    local ctrl = {
        _host       = healthBar,
        _clip       = clip,
        _bar        = trailBar,
        _delay      = opts.delay or 0.16,
        _speed      = opts.speed or 7.5,
        _reverse    = opts.reverse,
        _enabled    = true,
        _secretMode = false,
        _trailVal   = 1,
        _targetVal  = 1,
        _maxVal     = 1,
        _holdUntil  = 0,
        _secretGen  = 0,
        _tick       = TickTrail,
    }

    function ctrl:SetColor(r, g, b, a)
        self._bar:SetStatusBarColor(r, g, b, a or 0.72)
    end

    function ctrl:SetDelay(d)
        self._delay = math_max(0.04, math_min(0.60, d or 0.16))
    end

    function ctrl:SetReverse(rev)
        self._reverse = rev == true
        ReanchorTrailClip(self)
    end

    function ctrl:SetEnabled(on)
        self._enabled = on == true
        self._clip:SetShown(self._enabled)
        if not self._enabled then
            SleepTask(self)
        else
            ReanchorTrailClip(self)
        end
    end

    function ctrl:SyncAnchor()
        ReanchorTrailClip(self)
    end

    function ctrl:SetValue(cur, maxVal, instant)
        if not self._enabled then return end
        local isSec = F.IsSecret(cur) or F.IsSecret(maxVal)
        if isSec then
            self._secretMode = true
            SleepTask(self)
            pcall(self._bar.SetMinMaxValues, self._bar, 0, maxVal)
            self._secretGen = self._secretGen + 1
            if instant then
                if IMMEDIATE_ENUM then
                    pcall(self._bar.SetValue, self._bar, cur, IMMEDIATE_ENUM)
                else
                    pcall(self._bar.SetValue, self._bar, cur)
                end
                return
            end
            local gen = self._secretGen
            local unit = self._unit
            C_Timer.After(self._delay or 0.16, function()
                if not self._enabled or self._secretGen ~= gen then return end
                local liveCur = (unit and _G.UnitHealth) and _G.UnitHealth(unit)
                if type(liveCur) == "nil" then liveCur = cur end
                if EASE_OUT_ENUM then
                    pcall(self._bar.SetValue, self._bar, liveCur, EASE_OUT_ENUM)
                else
                    pcall(self._bar.SetValue, self._bar, liveCur)
                end
            end)
            return
        end

        self._secretMode = false
        local mx = (type(maxVal) == "number" and maxVal > 0) and maxVal or 1
        local val = (type(cur) == "number") and math_max(0, math_min(mx, cur)) or 0
        if self._maxVal ~= mx then
            self._maxVal = mx
            self._bar:SetMinMaxValues(0, mx)
            if self._trailVal > mx then self._trailVal = mx end
        end

        if instant or val >= self._trailVal then
            self._targetVal = val
            self._trailVal = val
            self._bar:SetValue(val)
            SleepTask(self)
            return
        end

        -- 掉血：若此前未处于掉血滞留状态，设定滞留截止时间；连击时稍微顺延避免顿挫
        local now = GetTime()
        if self._targetVal >= self._trailVal - 0.001 then
            self._holdUntil = now + (self._delay or 0.16)
        elseif now < self._holdUntil then
            self._holdUntil = math_min(now + (self._delay or 0.16) * 0.65, self._holdUntil + 0.04)
        end
        self._targetVal = val
        self._bar:SetValue(self._trailVal)
        WakeTask(self)
    end

    function ctrl:UpdateFromUnit(unit, instant)
        if not (self._enabled and unit) then return end
        self._unit = unit
        if not (_G.UnitExists and _G.UnitExists(unit)) then
            self:SetValue(0, 1, true)
            return
        end
        if _G.UnitIsDead then
            local okD, dead = pcall(_G.UnitIsDead, unit)
            if okD and not F.IsSecret(dead) and dead then
                self:SetValue(0, 1, true)
                return
            end
        end
        local hp = _G.UnitHealth and _G.UnitHealth(unit)
        if type(hp) == "nil" then hp = 0 end
        local mx = _G.UnitHealthMax and _G.UnitHealthMax(unit)
        if type(mx) == "nil" then mx = 1 end
        self:SetValue(hp, mx, instant)
    end

    ReanchorTrailClip(ctrl)
    trailRegistry[healthBar] = ctrl
    return ctrl
end

----------------------------------------------------------------------
--  3) SmoothBar：帧率无关平滑插值控制器（自动休眠零开销）
----------------------------------------------------------------------
local function TickSmooth(ctrl, dt)
    if not ctrl._bar or not ctrl._bar:IsVisible() then
        return false
    end
    local diff = ctrl._target - ctrl._current
    if math_abs(diff) <= ctrl._epsilon then
        ctrl._current = ctrl._target
        ctrl._bar:SetValue(ctrl._current)
        return false
    end
    local k = 1 - math_exp(-ctrl._speed * dt)
    ctrl._current = ctrl._current + diff * k
    ctrl._bar:SetValue(ctrl._current)
    return true
end

function M.CreateSmoothBar(statusBar, speed)
    local ctrl = {
        _bar     = statusBar,
        _speed   = speed or 14,
        _current = 0,
        _target  = 0,
        _epsilon = 0.001,
        _tick    = TickSmooth,
    }

    function ctrl:SetMinMax(lo, hi)
        local isSec = F.IsSecret(lo) or F.IsSecret(hi)
        pcall(self._bar.SetMinMaxValues, self._bar, lo, hi)
        if not isSec and type(hi) == "number" and type(lo) == "number" then
            self._epsilon = math_max(0.001, (hi - lo) * 0.0008)
        end
    end

    function ctrl:SetValue(v, instant)
        if F.IsSecret(v) then
            SleepTask(self)
            if not instant and EASE_OUT_ENUM then
                pcall(self._bar.SetValue, self._bar, v, EASE_OUT_ENUM)
            elseif IMMEDIATE_ENUM then
                pcall(self._bar.SetValue, self._bar, v, IMMEDIATE_ENUM)
            else
                pcall(self._bar.SetValue, self._bar, v)
            end
            return
        end
        local num = F.PlainNumber(v, 0) or 0
        self._target = num
        if instant then
            self._current = num
            self._bar:SetValue(num)
            SleepTask(self)
        else
            WakeTask(self)
        end
    end

    function ctrl:Stop()
        SleepTask(self)
    end

    return ctrl
end

----------------------------------------------------------------------
--  4) EdgeSpark：进度前沿高光切边控制器（纯锚定追踪，0 OnUpdate）
----------------------------------------------------------------------
function M.AttachEdgeSpark(statusBar, opts)
    if not (statusBar and statusBar.GetStatusBarTexture) then return nil end
    opts = opts or {}
    local host = CreateFrame("Frame", nil, statusBar)
    host:SetAllPoints(statusBar)
    host:SetClipsChildren(opts.clip ~= false)
    host:EnableMouse(false)
    local lvl = F.PlainNumber(statusBar.GetFrameLevel and statusBar:GetFrameLevel(), 10) or 10
    host:SetFrameLevel(lvl + (opts.levelOffset or 3))

    local spark = host:CreateTexture(nil, "OVERLAY", nil, 5)
    spark:SetTexture(opts.texture or ST.TEX.SPARK_BLADE)
    spark:SetBlendMode("ADD")
    if spark.SetSnapToPixelGrid then pcall(spark.SetSnapToPixelGrid, spark, false) end
    if spark.SetTexelSnappingBias then pcall(spark.SetTexelSnappingBias, spark, 0) end
    local w = opts.width or 18
    local extraH = opts.extraHeight or 6
    spark:SetWidth(w)

    local ctrl = {
        _host    = host,
        _bar     = statusBar,
        _spark   = spark,
        _width   = w,
        _extraH  = extraH,
        _reverse = opts.reverse == true,
    }

    function ctrl:SyncAnchor()
        local fillTex = self._bar:GetStatusBarTexture()
        if not fillTex then return end
        local h = F.PlainNumber(self._bar:GetHeight(), 12) or 12
        self._spark:SetSize(self._width, h + self._extraH)
        self._spark:ClearAllPoints()
        if self._reverse then
            self._spark:SetTexCoord(1, 0, 0, 1)
            self._spark:SetPoint("CENTER", fillTex, "LEFT", 2, 0)
        else
            self._spark:SetTexCoord(0, 1, 0, 1)
            self._spark:SetPoint("CENTER", fillTex, "RIGHT", -2, 0)
        end
    end

    function ctrl:SetColor(r, g, b, a)
        self._spark:SetVertexColor(r or 1, g or 1, b or 1, a or 0.92)
    end

    function ctrl:SetIntensity(alpha, widthScale)
        local sc = widthScale or 1
        local h = F.PlainNumber(self._bar:GetHeight(), 12) or 12
        self._spark:SetSize(self._width * sc, (h + self._extraH) * math_min(1.35, sc))
        self._spark:SetAlpha(alpha or 1)
    end

    function ctrl:SetShown(show)
        self._host:SetShown(show == true)
    end

    ctrl:SetColor(opts.r or 1, opts.g or 1, opts.b or 1, opts.a or 0.92)
    ctrl:SyncAnchor()
    return ctrl
end

----------------------------------------------------------------------
--  5) AnimPresets：原生 C 端 AnimationGroup 动效原语（零 Lua 逐帧开销）
----------------------------------------------------------------------
local animCache = setmetatable({}, { __mode = "k" })

local function GetSlot(obj, key)
    local t = animCache[obj]
    if not t then
        t = {}
        animCache[obj] = t
    end
    return t[key], t
end

function M.StopFrameAnims(frame)
    local t = frame and animCache[frame]
    if not t then return end
    for _, ag in pairs(t) do
        if ag and ag.Stop then ag:Stop() end
    end
end

-- 5a) 完成白闪 + 轻上浮平滑淡出（0.22s）
function M.PlayFlashFade(frame, duration, liftY, onDone)
    if not (frame and frame.CreateAnimationGroup) then return end
    M.StopFrameAnims(frame)
    local ag, cache = GetSlot(frame, "flashFade")
    if not ag then
        ag = frame:CreateAnimationGroup()
        local move = ag:CreateAnimation("Translation")
        move:SetOrder(1)
        move:SetSmoothing("OUT")
        ag._move = move
        local fade = ag:CreateAnimation("Alpha")
        fade:SetOrder(1)
        fade:SetFromAlpha(1)
        fade:SetToAlpha(0)
        fade:SetSmoothing("OUT")
        ag._fade = fade
        ag:SetScript("OnFinished", function(self)
            frame:Hide()
            frame:SetAlpha(1)
            if self._onDone then self._onDone() end
        end)
        ag:SetScript("OnStop", function()
            frame:SetAlpha(1)
        end)
        cache.flashFade = ag
    end
    local dur = duration or 0.22
    ag:Stop()
    ag._onDone = onDone
    ag._move:SetOffset(0, liftY or 5)
    ag._move:SetDuration(dur)
    ag._fade:SetDuration(dur)
    frame:SetAlpha(1)
    frame:Show()
    ag:Play()
end

-- 5b) 打断警示短促水平抖动（±4px, 0.18s）+ 淡出
function M.PlayInterruptShake(frame, amplitude, duration, onDone)
    if not (frame and frame.CreateAnimationGroup) then return end
    M.StopFrameAnims(frame)
    local ag, cache = GetSlot(frame, "shake")
    if not ag then
        ag = frame:CreateAnimationGroup()
        ag._steps = {}
        for i = 1, 4 do
            local tr = ag:CreateAnimation("Translation")
            tr:SetOrder(i)
            ag._steps[i] = tr
        end
        local hold = ag:CreateAnimation("Alpha")
        hold:SetOrder(5)
        hold:SetFromAlpha(1)
        hold:SetToAlpha(0)
        hold:SetSmoothing("IN")
        ag._fade = hold
        ag:SetScript("OnFinished", function(self)
            frame:Hide()
            frame:SetAlpha(1)
            if self._onDone then self._onDone() end
        end)
        ag:SetScript("OnStop", function()
            frame:SetAlpha(1)
        end)
        cache.shake = ag
    end
    local amp = amplitude or 4
    local stepDur = (duration or 0.18) / 4
    ag:Stop()
    ag._onDone = onDone
    ag._steps[1]:SetOffset(-amp, 0); ag._steps[1]:SetDuration(stepDur)
    ag._steps[2]:SetOffset(amp * 2, 0); ag._steps[2]:SetDuration(stepDur)
    ag._steps[3]:SetOffset(-amp * 1.6, 0); ag._steps[3]:SetDuration(stepDur)
    ag._steps[4]:SetOffset(amp * 0.6, 0); ag._steps[4]:SetDuration(stepDur)
    ag._fade:SetDuration(0.24)
    ag._fade:SetStartDelay(0.06)
    frame:SetAlpha(1)
    frame:Show()
    ag:Play()
end

-- 5c) 按钮/徽章缩放回弹（不修改实际布局尺寸）
function M.PlayScalePop(region, peakScale, duration)
    if not (region and region.CreateAnimationGroup) then return end
    local ag, cache = GetSlot(region, "pop")
    if not ag then
        ag = region:CreateAnimationGroup()
        local s1 = ag:CreateAnimation("Scale")
        s1:SetOrder(1)
        s1:SetOrigin("CENTER", 0, 0)
        s1:SetSmoothing("OUT")
        local s2 = ag:CreateAnimation("Scale")
        s2:SetOrder(2)
        s2:SetOrigin("CENTER", 0, 0)
        s2:SetSmoothing("IN")
        ag._s1, ag._s2 = s1, s2
        cache.pop = ag
    end
    local pk = peakScale or 1.14
    local half = (duration or 0.18) * 0.5
    ag:Stop()
    ag._s1:SetScaleFrom(1, 1); ag._s1:SetScaleTo(pk, pk); ag._s1:SetDuration(half)
    ag._s2:SetScaleFrom(pk, pk); ag._s2:SetScaleTo(1, 1); ag._s2:SetDuration(half)
    ag:Play()
end

-- 5d) 中央技能球丝滑双层交叉溶解切换（旧图标柔和缩放淡出 + 新图标平滑缓入，彻底告别生硬跳切）
function M.PlayIconCrossfade(newRegion, prevRegion, duration, isReturn)
    local dur = duration or (isReturn and 0.24 or 0.20)
    if prevRegion and prevRegion.CreateAnimationGroup then
        local pg, pCache = GetSlot(prevRegion, "crossOut")
        if not pg then
            pg = prevRegion:CreateAnimationGroup()
            local psc = pg:CreateAnimation("Scale")
            psc:SetOrder(1); psc:SetOrigin("CENTER", 0, 0)
            psc:SetSmoothing("IN_OUT")
            local pal = pg:CreateAnimation("Alpha")
            pal:SetOrder(1)
            pal:SetFromAlpha(1.0); pal:SetToAlpha(0.0)
            pal:SetSmoothing("IN_OUT")
            pg._sc, pg._al = psc, pal
            pg:SetScript("OnFinished", function()
                prevRegion:Hide()
                prevRegion:SetAlpha(1)
            end)
            pCache.crossOut = pg
        end
        pg:Stop()
        local outTo = isReturn and 0.88 or 0.84
        pg._sc:SetScaleFrom(1.0, 1.0); pg._sc:SetScaleTo(outTo, outTo); pg._sc:SetDuration(dur)
        pg._al:SetDuration(dur)
        prevRegion:SetAlpha(1.0)
        prevRegion:Show()
        pg:Play()
    end
    if newRegion and newRegion.CreateAnimationGroup then
        local ng, nCache = GetSlot(newRegion, "crossIn")
        if not ng then
            ng = newRegion:CreateAnimationGroup()
            local nsc = ng:CreateAnimation("Scale")
            nsc:SetOrder(1); nsc:SetOrigin("CENTER", 0, 0)
            nsc:SetSmoothing("OUT")
            local nal = ng:CreateAnimation("Alpha")
            nal:SetOrder(1)
            nal:SetFromAlpha(0.0); nal:SetToAlpha(1.0)
            nal:SetSmoothing("OUT")
            ng._sc, ng._al = nsc, nal
            ng:SetScript("OnFinished", function()
                newRegion:SetAlpha(1)
            end)
            nCache.crossIn = ng
        end
        ng:Stop()
        local inFrom = isReturn and 0.90 or 0.82
        ng._sc:SetScaleFrom(inFrom, inFrom); ng._sc:SetScaleTo(1.0, 1.0); ng._sc:SetDuration(dur)
        ng._al:SetDuration(dur * 0.88)
        newRegion:SetAlpha(1.0)
        ng:Play()
    end
end

-- 兼容旧调用：平滑缓入不生硬回弹
function M.PlayIconSpinIn(region, duration)
    M.PlayIconCrossfade(region, nil, duration or 0.22, false)
end

-- 5d2) 技能切换外圈柔和丝滑光波（克制高级质感：柔光缓扩 + 平滑淡出至 0，绝对零硬闪）
function M.PlayOrbBurst(ringTex, flashTex, duration)
    local dur = duration or 0.38
    if ringTex and ringTex.CreateAnimationGroup then
        local ag, cache = GetSlot(ringTex, "orbBurst")
        if not ag then
            ag = ringTex:CreateAnimationGroup()
            local sc = ag:CreateAnimation("Scale")
            sc:SetOrder(1); sc:SetOrigin("CENTER", 0, 0)
            sc:SetScaleFrom(0.92, 0.92); sc:SetScaleTo(1.36, 1.36)
            sc:SetSmoothing("OUT")
            local rot = ag:CreateAnimation("Rotation")
            rot:SetOrder(1); rot:SetOrigin("CENTER", 0, 0)
            rot:SetDegrees(-110)
            rot:SetSmoothing("OUT")
            local al = ag:CreateAnimation("Alpha")
            al:SetOrder(1); al:SetFromAlpha(0.62); al:SetToAlpha(0)
            al:SetSmoothing("OUT")
            ag._sc, ag._rot, ag._al = sc, rot, al
            ag:SetScript("OnFinished", function() ringTex:Hide() end)
            cache.orbBurst = ag
        end
        ag:Stop()
        ag._sc:SetDuration(dur)
        ag._rot:SetDuration(dur)
        ag._al:SetDuration(dur)
        ringTex:SetAlpha(0.62)
        ringTex:Show()
        ag:Play()
    end
    if flashTex and flashTex.CreateAnimationGroup then
        local fg, cache = GetSlot(flashTex, "orbFlash")
        if not fg then
            fg = flashTex:CreateAnimationGroup()
            local a = fg:CreateAnimation("Alpha")
            a:SetOrder(1); a:SetFromAlpha(0.36); a:SetToAlpha(0); a:SetSmoothing("OUT")
            fg._a = a
            fg:SetScript("OnFinished", function() flashTex:Hide() end)
            cache.orbFlash = fg
        end
        fg:Stop()
        fg._a:SetDuration(dur * 0.58)
        flashTex:SetAlpha(0.36)
        flashTex:Show()
        fg:Play()
    end
end

-- 5e) 外围光环持续顺/逆时针平滑旋转（C 端循环，0 Lua CPU）
function M.EnsureSpinRing(region, periodSeconds, reverseDir)
    if not (region and region.CreateAnimationGroup) then return nil end
    local ag, cache = GetSlot(region, "spinRing")
    if not ag then
        ag = region:CreateAnimationGroup()
        ag:SetLooping("REPEAT")
        local rot = ag:CreateAnimation("Rotation")
        rot:SetOrigin("CENTER", 0, 0)
        rot:SetDegrees(reverseDir and 360 or -360)
        ag._rot = rot
        cache.spinRing = ag
    end
    ag._rot:SetDuration(periodSeconds or 2.4)
    return ag
end

-- 5f) 水平呼吸往复微动效（用于姓名板当前目标左右箭头）
function M.EnsureBreatheShift(region, dx, periodSeconds)
    if not (region and region.CreateAnimationGroup) then return nil end
    local ag, cache = GetSlot(region, "breatheShift")
    if not ag then
        ag = region:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local tr = ag:CreateAnimation("Translation")
        tr:SetSmoothing("IN_OUT")
        ag._tr = tr
        cache.breatheShift = ag
    end
    ag._tr:SetOffset(dx or 3, 0)
    ag._tr:SetDuration((periodSeconds or 1.1) * 0.5)
    return ag
end

-- 5g) 呼吸透明度脉冲（低血量暗角 / 冷却高亮 / 警告）
function M.EnsurePulseAlpha(region, minA, maxA, periodSeconds)
    if not (region and region.CreateAnimationGroup) then return nil end
    local ag, cache = GetSlot(region, "pulseAlpha")
    if not ag then
        ag = region:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local al = ag:CreateAnimation("Alpha")
        al:SetSmoothing("IN_OUT")
        ag._al = al
        cache.pulseAlpha = ag
    end
    ag._al:SetFromAlpha(minA or 0.28)
    ag._al:SetToAlpha(maxA or 0.92)
    ag._al:SetDuration((periodSeconds or 1.2) * 0.5)
    return ag
end

-- 5h) 增益属性变化高亮微闪
function M.PlayStatBlink(region, duration)
    if not (region and region.CreateAnimationGroup) then return end
    local ag, cache = GetSlot(region, "statBlink")
    if not ag then
        ag = region:CreateAnimationGroup()
        local s1 = ag:CreateAnimation("Scale")
        s1:SetOrder(1); s1:SetOrigin("RIGHT", 0, 0)
        s1:SetScaleFrom(1, 1); s1:SetScaleTo(1.16, 1.16); s1:SetSmoothing("OUT")
        local s2 = ag:CreateAnimation("Scale")
        s2:SetOrder(2); s2:SetOrigin("RIGHT", 0, 0)
        s2:SetScaleFrom(1.16, 1.16); s2:SetScaleTo(1, 1); s2:SetSmoothing("IN")
        ag._s1, ag._s2 = s1, s2
        cache.statBlink = ag
    end
    local half = (duration or 0.34) * 0.5
    ag:Stop()
    ag._s1:SetDuration(half)
    ag._s2:SetDuration(half)
    ag:Play()
end
