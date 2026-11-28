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
local math_abs, math_exp, math_floor, math_max, math_min, next, pairs, pcall, setmetatable, type =
    math.abs, math.exp, math.floor, math.max, math.min, next, pairs, pcall, setmetatable, type
local CreateFrame = CreateFrame
local GetTime = GetTime
local C_Timer = C_Timer

local M = {}
F.Motion = M

local ST = F.StyleTokens
local EASE_OUT_ENUM = _G.Enum and _G.Enum.StatusBarInterpolation and _G.Enum.StatusBarInterpolation.ExponentialEaseOut or nil
local IMMEDIATE_ENUM = _G.Enum and _G.Enum.StatusBarInterpolation and _G.Enum.StatusBarInterpolation.Immediate or nil

local function GetInterpEnum()
    local interp = _G.Enum and _G.Enum.StatusBarInterpolation
    if interp then
        EASE_OUT_ENUM = interp.ExponentialEaseOut or EASE_OUT_ENUM
        IMMEDIATE_ENUM = interp.Immediate or IMMEDIATE_ENUM
    end
    return interp
end

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

function M.RegisterTask(task)
    if task and type(task._tick) == "function" then
        WakeTask(task)
    end
end

function M.UnregisterTask(task)
    if task then
        SleepTask(task)
    end
end

----------------------------------------------------------------------
--  1b) 共享低频文字计时器（最多 20 Hz，空闲自动取消，零 OnUpdate 占用）
----------------------------------------------------------------------
local textTickTasks = {}
local textTicker = nil
local TEXT_TICK_STEP = 0.05

local function StopTextTickerIfIdle()
    if next(textTickTasks) == nil and textTicker then
        pcall(textTicker.Cancel, textTicker)
        textTicker = nil
    end
end

local function RunTextTicks()
    local now = GetTime()
    for key, task in pairs(textTickTasks) do
        local iv = task.interval or 0.10
        if now - task.lastRun + 0.002 >= iv then
            task.lastRun = now
            local ok, keep = pcall(task.fn, now)
            if not ok or keep == false then
                textTickTasks[key] = nil
            end
        end
    end
    StopTextTickerIfIdle()
end

function M.RegisterTextTick(key, interval, fn)
    if key == nil or type(fn) ~= "function" then return end
    local iv = math_max(TEXT_TICK_STEP, interval or 0.10)
    local cur = textTickTasks[key]
    if cur then
        cur.interval = iv
        cur.fn = fn
    else
        textTickTasks[key] = {
            interval = iv,
            lastRun  = GetTime(),
            fn       = fn,
        }
    end
    if not textTicker and C_Timer and C_Timer.NewTicker then
        textTicker = C_Timer.NewTicker(TEXT_TICK_STEP, RunTextTicks)
    end
end

function M.SetTextTickInterval(key, interval)
    local cur = key ~= nil and textTickTasks[key] or nil
    if cur then
        cur.interval = math_max(TEXT_TICK_STEP, interval or 0.10)
    end
end

function M.UnregisterTextTick(key)
    if key == nil then return end
    textTickTasks[key] = nil
    StopTextTickerIfIdle()
end

function M.GetActiveTextTickCount()
    local n = 0
    for _ in pairs(textTickTasks) do n = n + 1 end
    return n
end

----------------------------------------------------------------------
--  1c) 过图后循环动画恢复注册表（怪癖 5：读条画面后防动画停摆）
----------------------------------------------------------------------
local loopAnimRegistry = setmetatable({}, { __mode = "k" })
local loadWatchFrame = CreateFrame("Frame")
loadWatchFrame:RegisterEvent("LOADING_SCREEN_DISABLED")
loadWatchFrame:SetScript("OnEvent", function()
    for ag, checkFn in pairs(loopAnimRegistry) do
        if ag and ag.Play then
            local want = true
            if type(checkFn) == "function" then
                local ok, res = pcall(checkFn, ag)
                want = ok and res == true
            end
            if want then
                if ag.Stop then pcall(ag.Stop, ag) end
                pcall(ag.Play, ag)
            end
        end
    end
end)

function M.RegisterLoopAnim(ag, isActiveFn)
    if not ag then return end
    loopAnimRegistry[ag] = isActiveFn or true
end

function M.UnregisterLoopAnim(ag)
    if not ag then return end
    loopAnimRegistry[ag] = nil
end

function M.IsLoopAnimRegistered(ag)
    return (ag ~= nil) and (loopAnimRegistry[ag] ~= nil)
end

function M.DisablePixelSnap(obj)
    if not obj then return end
    if obj.SetSnapToPixelGrid then pcall(obj.SetSnapToPixelGrid, obj, false) end
    if obj.SetTexelSnappingBias then pcall(obj.SetTexelSnappingBias, obj, 0) end
end

----------------------------------------------------------------------
--  1d) 统一 StatusBar 原生平滑入口（12.x ExponentialEaseOut + 怪癖 1/2 防护）
----------------------------------------------------------------------
local barRangeCache = setmetatable({}, { __mode = "k" })
local barSnapPending = setmetatable({}, { __mode = "k" })
local barShowHooked = setmetatable({}, { __mode = "k" })

local function EnsureBarShowHook(bar)
    if barShowHooked[bar] or not (bar and bar.HookScript) then return end
    barShowHooked[bar] = true
    pcall(bar.HookScript, bar, "OnShow", function(self)
        barSnapPending[self] = true
    end)
end

local function IsUnitDeadPlain(unit)
    if not (unit and _G.UnitIsDeadOrGhost) then return false end
    local ok, dead = pcall(_G.UnitIsDeadOrGhost, unit)
    return ok and not F.IsSecret(dead) and dead == true
end

function M.ResetBarCache(bar)
    if not bar then return end
    barRangeCache[bar] = nil
    barSnapPending[bar] = true
end

-- 仅在范围变化、机密值或 force=true 时重设 SetMinMaxValues（怪癖 2：避免每次事件打断原生平滑）
function M.SetBarMinMax(bar, lo, hi, opts)
    if not (bar and bar.SetMinMaxValues) then return false end
    local force = opts and opts.force == true
    local isSec = F.IsSecret(lo) or F.IsSecret(hi)
    local prev = barRangeCache[bar]
    if force or isSec or not prev or prev.secret or prev.lo ~= lo or prev.hi ~= hi then
        pcall(bar.SetMinMaxValues, bar, lo, hi)
        if isSec then
            barRangeCache[bar] = { secret = true }
        else
            barRangeCache[bar] = { lo = lo, hi = hi, secret = false }
        end
        return true
    end
    return false
end

-- 统一平滑设值入口：
--   • 开关关闭时严格走旧路径 1 参 SetValue(v)，与旧行为基线完全一致
--   • 开关开启且原生插值枚举存在时，常态传 ExponentialEaseOut（明文与机密统一），
--     换单位/最大值变/能量类型变/死亡或归零/刚显示传 Immediate（怪癖 1）
function M.SetBarValue(bar, value, opts)
    if not (bar and bar.SetValue) then return end
    local fxKey = (opts and opts.fxKey) or "fx_smoothMain"
    local smoothOn = ST and ST.IsFXEnabled and ST.IsFXEnabled(fxKey, opts and opts.override) or false
    if not smoothOn then
        pcall(bar.SetValue, bar, value)
        return
    end
    EnsureBarShowHook(bar)
    local interp = GetInterpEnum()
    if not interp then
        pcall(bar.SetValue, bar, value)
        return
    end
    local isSec = F.IsSecret(value)
    local snap = (barSnapPending[bar] ~= false)
        or (opts and (opts.instant == true or opts.maxChanged == true or opts.powerTypeChanged == true or opts.isDead == true))
        or (opts and opts.unit and IsUnitDeadPlain(opts.unit))
        or ((not isSec) and type(value) == "number" and value <= 0)
    barSnapPending[bar] = false
    if snap then
        if interp.Immediate ~= nil then
            pcall(bar.SetValue, bar, value, interp.Immediate)
        else
            pcall(bar.SetValue, bar, value)
        end
    else
        if interp.ExponentialEaseOut ~= nil then
            pcall(bar.SetValue, bar, value, interp.ExponentialEaseOut)
        else
            pcall(bar.SetValue, bar, value)
        end
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

local function ResolveTrailTune(ctrl)
    local override = ctrl and ctrl._fxOverride
    local tuned = ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_trailTune", override) or false
    if not tuned then
        return false, ctrl._delay or 0.16, ctrl._speed or 7.5, 1.0
    end
    local inten = ST.GetFXIntensity(override)
    if inten == "soft" then
        return true, 0.24, 9.5, 0.6
    end
    -- 标准强度：受击后停顿 ~0.38s 等平滑主条基本到位，再在 ~0.4s 内柔和收完
    return true, 0.38, 6.8, 1.0
end

local function ApplyTrailVisualColor(ctrl)
    if not (ctrl and ctrl._bar) then return end
    local bc = ctrl._baseColor or ST.COLORS.trail
    local tuned, _, _, scale = ResolveTrailTune(ctrl)
    if not tuned then
        ctrl._bar:SetStatusBarColor(bc[1], bc[2], bc[3], bc[4] or 0.72)
        return
    end
    -- 柔和浅色调 + 约 0.55 透明度（柔和强度乘以 0.6）
    local r = bc[1] * 0.55 + 0.45
    local g = bc[2] * 0.55 + 0.45
    local b = bc[3] * 0.55 + 0.45
    local a = 0.55 * scale
    ctrl._bar:SetStatusBarColor(r, g, b, a)
end

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
    local _, _, effSpeed = ResolveTrailTune(ctrl)
    local k = 1 - math_exp(-effSpeed * dt)
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
        _host          = healthBar,
        _clip          = clip,
        _bar           = trailBar,
        _delay         = opts.delay or 0.16,
        _speed         = opts.speed or 7.5,
        _baseColor     = { c[1], c[2], c[3], c[4] or 0.72 },
        _fxOverride    = opts.fxOverride,
        _reverse       = opts.reverse,
        _enabled       = true,
        _secretMode    = false,
        _trailVal      = 1,
        _targetVal     = 1,
        _maxVal        = 1,
        _holdUntil     = 0,
        _secretGen     = 0,
        _secretPending = false,
        _secretDueAt   = 0,
        _secretLastCur = nil,
        _tick          = TickTrail,
    }

    -- 机密分支复用单一回调 + 代数计数与截止时间，每次血量事件 0 闭包分配
    local function RunSecretCatchup()
        ctrl._secretPending = false
        if not ctrl._enabled then return end
        local now = GetTime()
        if ctrl._secretDueAt > now + 0.01 then
            ctrl._secretPending = true
            C_Timer.After(ctrl._secretDueAt - now, RunSecretCatchup)
            return
        end
        local unit = ctrl._unit
        local liveCur = (unit and _G.UnitHealth) and _G.UnitHealth(unit)
        if type(liveCur) == "nil" then liveCur = ctrl._secretLastCur end
        if type(liveCur) == "nil" then return end
        local interp = GetInterpEnum()
        if interp and interp.ExponentialEaseOut ~= nil then
            pcall(ctrl._bar.SetValue, ctrl._bar, liveCur, interp.ExponentialEaseOut)
        else
            pcall(ctrl._bar.SetValue, ctrl._bar, liveCur)
        end
    end
    ctrl._secretCatchupFn = RunSecretCatchup

    function ctrl:SetColor(r, g, b, a)
        self._baseColor = { r, g, b, a or 0.72 }
        ApplyTrailVisualColor(self)
    end

    function ctrl:RefreshStyle()
        ApplyTrailVisualColor(self)
    end

    function ctrl:SetDelay(d)
        self._delay = math_max(0.04, math_min(0.60, d or 0.16))
        ApplyTrailVisualColor(self)
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
            ApplyTrailVisualColor(self)
            ReanchorTrailClip(self)
        end
    end

    function ctrl:SyncAnchor()
        ApplyTrailVisualColor(self)
        ReanchorTrailClip(self)
    end

    function ctrl:SetValue(cur, maxVal, instant)
        if not self._enabled then return end
        ApplyTrailVisualColor(self)
        local tuned, effDelay = ResolveTrailTune(self)
        local isSec = F.IsSecret(cur) or F.IsSecret(maxVal)
        if isSec then
            self._secretMode = true
            SleepTask(self)
            pcall(self._bar.SetMinMaxValues, self._bar, 0, maxVal)
            self._secretGen = self._secretGen + 1
            self._secretLastCur = cur
            if instant then
                self._secretDueAt = 0
                local interp = GetInterpEnum()
                if interp and interp.Immediate ~= nil then
                    pcall(self._bar.SetValue, self._bar, cur, interp.Immediate)
                else
                    pcall(self._bar.SetValue, self._bar, cur)
                end
                return
            end
            local now = GetTime()
            local due = now + effDelay
            if due > self._secretDueAt then
                self._secretDueAt = due
            end
            if not self._secretPending then
                self._secretPending = true
                C_Timer.After(effDelay, self._secretCatchupFn)
            end
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
            self._holdUntil = now + effDelay
        elseif now < self._holdUntil then
            local capMul = tuned and 0.72 or 0.65
            self._holdUntil = math_min(now + effDelay * capMul, self._holdUntil + 0.04)
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
--  3) SmoothBar：兼容包装，统一委托给客户端原生平滑入口 M.SetBarMinMax / M.SetBarValue
----------------------------------------------------------------------
function M.CreateSmoothBar(statusBar, _speed)
    local ctrl = {
        _bar = statusBar,
    }

    function ctrl:SetMinMax(lo, hi, force)
        return M.SetBarMinMax(self._bar, lo, hi, force and { force = true } or nil)
    end

    function ctrl:SetValue(v, instant, opts)
        if type(opts) == "table" then
            M.SetBarValue(self._bar, v, opts)
        else
            M.SetBarValue(self._bar, v, { instant = instant == true })
        end
    end

    function ctrl:Stop()
        M.ResetBarCache(self._bar)
    end

    return ctrl
end

----------------------------------------------------------------------
--  4) EdgeSpark：进度前沿高光切边与柔和光晕 Bloom 控制器（纯锚定追踪，0 OnUpdate）
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

    local bloom = host:CreateTexture(nil, "OVERLAY", nil, 4)
    bloom:SetTexture(ST.GetEdgeBloomTexture and ST.GetEdgeBloomTexture(opts.fxOverride) or ST.TEX.SOFT_GLOW)
    bloom:SetBlendMode("ADD")
    M.DisablePixelSnap(bloom)

    local spark = host:CreateTexture(nil, "OVERLAY", nil, 5)
    local customTex = opts.texture
    spark:SetTexture(customTex or (ST.GetSparkTexture and ST.GetSparkTexture(opts.fxOverride) or ST.TEX.SPARK_BLADE))
    spark:SetBlendMode("ADD")
    M.DisablePixelSnap(spark)

    -- 变动瞬时提亮脉冲（纯 C 端 AnimationGroup，复用零分配，0 OnUpdate）
    local pulseAG = bloom:CreateAnimationGroup()
    local pRise = pulseAG:CreateAnimation("Alpha")
    pRise:SetOrder(1); pRise:SetDuration(0.05); pRise:SetSmoothing("OUT")
    local pFall = pulseAG:CreateAnimation("Alpha")
    pFall:SetOrder(2); pFall:SetDuration(0.20); pFall:SetSmoothing("OUT")
    pulseAG._rise = pRise
    pulseAG._fall = pFall

    local w = opts.width or 18
    local extraH = opts.extraHeight or 6
    spark:SetWidth(w)

    local ctrl = {
        _host        = host,
        _bar         = statusBar,
        _spark       = spark,
        _bloom       = bloom,
        _pulseAG     = pulseAG,
        _maskHost    = opts.maskHost or nil,
        _maskedRad   = -1,
        _customTex   = customTex,
        _fxOverride  = opts.fxOverride,
        _width       = w,
        _extraH      = extraH,
        _baseAlpha   = opts.a or 0.88,
        _r           = opts.r or 1,
        _g           = opts.g or 1,
        _b           = opts.b or 1,
        _reverse     = opts.reverse == true,
        _bloomEnabled = opts.noBloom ~= true,
    }

    local function UpdateBloomBaseAlpha()
        local inten = ST.GetFXIntensity(ctrl._fxOverride)
        local texOn = ST.IsFXEnabled("fx_barTexture", ctrl._fxOverride)
        if (not ctrl._bloomEnabled) or inten == "off" or not texOn then
            ctrl._bloomBaseA = 0
            ctrl._bloom:SetAlpha(0)
            ctrl._bloom:Hide()
            return
        end
        local ba = (inten == "soft") and 0.40 or math_min(0.86, (ctrl._baseAlpha or 0.72) * 0.92)
        ctrl._bloomBaseA = ba
        ctrl._bloom:SetAlpha(ba)
        ctrl._bloom:Show()
    end

    pulseAG:SetScript("OnFinished", function()
        if ctrl._bloom then ctrl._bloom:SetAlpha(ctrl._bloomBaseA or 0) end
    end)
    pulseAG:SetScript("OnStop", function()
        if ctrl._bloom then ctrl._bloom:SetAlpha(ctrl._bloomBaseA or 0) end
    end)

    function ctrl:RefreshTexture()
        if not self._customTex and ST.GetSparkTexture then
            self._spark:SetTexture(ST.GetSparkTexture(self._fxOverride))
        end
        if self._bloom and ST.GetEdgeBloomTexture then
            self._bloom:SetTexture(ST.GetEdgeBloomTexture(self._fxOverride))
        end
        UpdateBloomBaseAlpha()
    end

    function ctrl:SyncMask(maskHost, radius)
        local mh = maskHost or self._maskHost
        if not mh then return end
        self._maskHost = mh
        local rad = radius or 0
        if rad > 0 then
            ST.MaskTexture(mh, self._spark, rad)
            if self._bloom then ST.MaskTexture(mh, self._bloom, rad) end
        elseif ST.UnmaskTexture then
            ST.UnmaskTexture(mh, self._spark)
            if self._bloom then ST.UnmaskTexture(mh, self._bloom) end
        end
        self._maskedRad = rad
    end

    function ctrl:SyncAnchor()
        self:RefreshTexture()
        local fillTex = self._bar:GetStatusBarTexture()
        if not fillTex then return end
        local h = F.PlainNumber(self._bar:GetHeight(), 12) or 12
        self._spark:SetSize(self._width, h + self._extraH)
        self._spark:ClearAllPoints()
        local bloomW = math_max(18, self._width * 1.25)
        self._bloom:SetSize(bloomW, h + self._extraH + 6)
        self._bloom:ClearAllPoints()
        if self._reverse then
            self._spark:SetTexCoord(1, 0, 0, 1)
            self._spark:SetPoint("CENTER", fillTex, "LEFT", 2, 0)
            self._bloom:SetPoint("CENTER", fillTex, "LEFT", 3, 0)
        else
            self._spark:SetTexCoord(0, 1, 0, 1)
            self._spark:SetPoint("CENTER", fillTex, "RIGHT", -2, 0)
            self._bloom:SetPoint("CENTER", fillTex, "RIGHT", -3, 0)
        end
    end

    function ctrl:SetColor(r, g, b, a)
        self._r, self._g, self._b = r or 1, g or 1, b or 1
        if a ~= nil then self._baseAlpha = a end
        self._spark:SetVertexColor(self._r, self._g, self._b, self._baseAlpha)
        if self._bloom then
            self._bloom:SetVertexColor(self._r, self._g, self._b, 1)
            UpdateBloomBaseAlpha()
        end
    end

    function ctrl:Pulse(strength)
        if not (self._bloom and self._pulseAG and self._host:IsShown()) then return end
        local ba = self._bloomBaseA or 0
        if ba <= 0.01 then return end
        local peak = math_min(1.0, ba + 0.34 * (strength or 1.0))
        self._pulseAG:Stop()
        self._pulseAG._rise:SetFromAlpha(ba)
        self._pulseAG._rise:SetToAlpha(peak)
        self._pulseAG._fall:SetFromAlpha(peak)
        self._pulseAG._fall:SetToAlpha(ba)
        self._pulseAG:Play()
    end

    function ctrl:SetIntensity(alpha, widthScale)
        local sc = widthScale or 1
        local h = F.PlainNumber(self._bar:GetHeight(), 12) or 12
        self._spark:SetSize(self._width * sc, (h + self._extraH) * math_min(1.35, sc))
        self._spark:SetAlpha(alpha or 1)
        if self._bloom and (self._bloomBaseA or 0) > 0 then
            local bloomW = math_max(18, self._width * 1.25 * sc)
            self._bloom:SetSize(bloomW, (h + self._extraH + 6) * math_min(1.35, sc))
            self._bloom:SetAlpha(math_min(1, (self._bloomBaseA or 0.5) * (alpha or 1)))
        end
    end

    function ctrl:SetShown(show)
        local on = show == true
        self._host:SetShown(on)
        if not on and self._pulseAG and self._pulseAG:IsPlaying() then
            self._pulseAG:Stop()
        end
    end

    ctrl:SetColor(opts.r or 1, opts.g or 1, opts.b or 1, opts.a or 0.88)
    ctrl:SyncAnchor()
    return ctrl
end

----------------------------------------------------------------------
--  4b) AttachBarLivingFlow：条内柔和轻流光（fx_barFlow，纯 C 端 AnimationGroup 0 OnUpdate）
--      • clip 直接锚定于 statusBar:GetStatusBarTexture()（仅跟随填充宽度，绝不读取任何数值 -> 12.x 机密值 100% 安全）
--      • 纹理严格挂入外层 holder 圆角遮罩，绝不溢出圆角之外
--      • 注册进 M.RegisterLoopAnim，过图不冻住；关闭 fx_barFlow 或 intensity="off" 瞬间停播隐藏
----------------------------------------------------------------------
function M.AttachBarLivingFlow(holder, statusBar, opts)
    if not (holder and statusBar and statusBar.GetStatusBarTexture) then return nil end
    opts = opts or {}

    local clip = CreateFrame("Frame", nil, statusBar)
    clip:SetClipsChildren(true)
    clip:EnableMouse(false)
    local lvl = F.PlainNumber(statusBar.GetFrameLevel and statusBar:GetFrameLevel(), 10) or 10
    clip:SetFrameLevel(lvl + (opts.levelOffset or 2))

    local sheen = clip:CreateTexture(nil, "OVERLAY", nil, 2)
    sheen:SetTexture(ST.TEX.BAR_FLOW_SHEEN)
    sheen:SetBlendMode("ADD")
    sheen:SetVertexColor(opts.r or 1, opts.g or 1, opts.b or 1, 1)
    sheen:SetAlpha(0)
    M.DisablePixelSnap(sheen)

    local ag = sheen:CreateAnimationGroup()
    ag:SetLooping("REPEAT")
    local tr = ag:CreateAnimation("Translation")
    tr:SetOrder(1)
    tr:SetSmoothing("IN_OUT")
    local al = ag:CreateAnimation("Alpha")
    al:SetOrder(1)
    al:SetSmoothing("IN_OUT")
    local rest = ag:CreateAnimation("Alpha")
    rest:SetOrder(2)
    rest:SetFromAlpha(0)
    rest:SetToAlpha(0)

    local ctrl = {
        _holder     = holder,
        _bar        = statusBar,
        _clip       = clip,
        _sheen      = sheen,
        _ag         = ag,
        _tr         = tr,
        _al         = al,
        _rest       = rest,
        _reverse    = opts.reverse == true,
        _period     = opts.period or 6.5,
        _sweepRatio = opts.sweepRatio or 0.42,
        _peakStd    = opts.peakAlpha or 0.18,
        _peakSoft   = opts.softAlpha or 0.10,
        _fxOverride = opts.fxOverride,
        _enabled    = opts.enabled ~= false,
        _active     = false,
        _maskedRad  = -1,
    }

    local function IsFlowWantPlay()
        if not ctrl._enabled then return false end
        if not (ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_barFlow", ctrl._fxOverride)) then
            return false
        end
        if ctrl._holder and ctrl._holder.IsVisible and not ctrl._holder:IsVisible() then
            return false
        end
        return true
    end

    local function LayoutSheen(rad)
        local fillTex = ctrl._bar:GetStatusBarTexture()
        if fillTex then
            ctrl._clip:ClearAllPoints()
            ctrl._clip:SetAllPoints(fillTex)
        end
        local w = F.PlainNumber(ctrl._bar.GetWidth and ctrl._bar:GetWidth(), 140) or 140
        local h = F.PlainNumber(ctrl._bar.GetHeight and ctrl._bar:GetHeight(), 16) or 16
        if w < 20 then w = 140 end
        if h < 4 then h = 16 end
        local bandW = math_max(46, math_min(110, math_floor(w * 0.44)))
        local bandH = h + 6
        ctrl._sheen:SetSize(bandW, bandH)
        ctrl._sheen:ClearAllPoints()
        local travel = w + bandW + 8
        if ctrl._reverse then
            ctrl._sheen:SetTexCoord(1, 0, 0, 1)
            ctrl._sheen:SetPoint("LEFT", ctrl._bar, "RIGHT", 4, 0)
            ctrl._tr:SetOffset(-travel, 0)
        else
            ctrl._sheen:SetTexCoord(0, 1, 0, 1)
            ctrl._sheen:SetPoint("RIGHT", ctrl._bar, "LEFT", -4, 0)
            ctrl._tr:SetOffset(travel, 0)
        end
        local period = math_max(1.0, ctrl._period or 6.5)
        local sweepDur = math_max(0.75, math_min(period - 0.15, period * ctrl._sweepRatio))
        local restDur = math_max(0.10, period - sweepDur)
        ctrl._tr:SetDuration(sweepDur)
        ctrl._al:SetDuration(sweepDur)
        ctrl._rest:SetDuration(restDur)

        if rad ~= nil then
            if rad > 0 then
                ST.MaskTexture(ctrl._holder, ctrl._sheen, rad)
            elseif ST.UnmaskTexture then
                ST.UnmaskTexture(ctrl._holder, ctrl._sheen)
            end
            ctrl._maskedRad = rad
        end
    end

    function ctrl:SyncMask(rad)
        local r = rad or 0
        if r > 0 then
            ST.MaskTexture(self._holder, self._sheen, r)
        elseif ST.UnmaskTexture then
            ST.UnmaskTexture(self._holder, self._sheen)
        end
        self._maskedRad = r
    end

    function ctrl:Refresh(rad)
        local want = self._enabled and (ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_barFlow", self._fxOverride)) == true
        if not want then
            self._active = false
            if self._ag:IsPlaying() then self._ag:Stop() end
            M.UnregisterLoopAnim(self._ag)
            self._sheen:SetAlpha(0)
            self._sheen:Hide()
            self._clip:Hide()
            return
        end
        local isSoft = ST.GetFXIntensity(self._fxOverride) == "soft"
        local peak = isSoft and self._peakSoft or self._peakStd
        local useRad = rad
        if useRad == nil then
            local gRad = ST.GetCornerRadius(6)
            if gRad > 0 then
                local h = F.PlainNumber(self._holder.GetHeight and self._holder:GetHeight(), 16) or 16
                useRad = math_min(gRad, math_max(2, math_floor(h * 0.45)))
            else
                useRad = 0
            end
        end
        LayoutSheen(useRad)
        self._al:SetFromAlpha(peak * 0.72)
        self._al:SetToAlpha(peak)
        self._active = true
        self._clip:Show()
        self._sheen:Show()
        M.RegisterLoopAnim(self._ag, IsFlowWantPlay)
        if not self._ag:IsPlaying() then
            self._ag:Play()
        end
    end

    function ctrl:SetEnabled(on, rad)
        self._enabled = on == true
        self:Refresh(rad)
    end

    function ctrl:SetPeriod(period)
        self._period = math_max(1.0, period or 6.5)
        if self._active then self:Refresh(self._maskedRad >= 0 and self._maskedRad or nil) end
    end

    if statusBar.HookScript then
        pcall(statusBar.HookScript, statusBar, "OnSizeChanged", function()
            if ctrl._active then LayoutSheen(ctrl._maskedRad >= 0 and ctrl._maskedRad or nil) end
        end)
    end
    ctrl:Refresh()
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

-- 5a) 完成白闪 + 轻上浮平滑淡出（0.22s；可选 holdDelay 实现先亮闪再淡出）
function M.PlayFlashFade(frame, duration, liftY, onDone, holdDelay, startAlpha)
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
            frame:Hide()
            frame:SetAlpha(1)
        end)
        cache.flashFade = ag
    end
    local dur = duration or 0.22
    local delay = holdDelay or 0
    local fromA = startAlpha or 1
    ag:Stop()
    ag._onDone = onDone
    ag._move:SetOffset(0, liftY or 5)
    ag._move:SetStartDelay(delay)
    ag._move:SetDuration(dur)
    ag._fade:SetFromAlpha(fromA)
    ag._fade:SetToAlpha(0)
    ag._fade:SetStartDelay(delay)
    ag._fade:SetDuration(dur)
    frame:SetAlpha(fromA)
    frame:Show()
    ag:Play()
end

-- 5b) 打断警示短促水平抖动（±4px, 0.18s）+ 停留 + 淡出（任何退出路径严格 Hide）
function M.PlayInterruptShake(frame, amplitude, duration, onDone, holdDelay, fadeDur)
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
            frame:Hide()
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
    ag._fade:SetDuration(fadeDur or 0.24)
    ag._fade:SetStartDelay(holdDelay ~= nil and holdDelay or 0.06)
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

-- 5i) 受击冲击瞬闪 + 治疗光波扫条（ADD 混合，贴合主条填充并共用外层宿主圆角遮罩，纯 AnimationGroup 0 OnUpdate）
local hitFlashOverlays = setmetatable({}, { __mode = "k" })

local function SyncSingleHitFlashMask(state, maskHost, rad)
    if not (state and state.tex) then return end
    local r = rad or 0
    local prevHost = state.maskedHost
    local textures = { state.tex, state.redTex, state.sweepTex }
    if prevHost and prevHost ~= maskHost and ST.UnmaskTexture then
        for i = 1, #textures do
            if textures[i] then ST.UnmaskTexture(prevHost, textures[i]) end
        end
        state.maskedRad = -1
    end
    if r > 0 then
        if state.maskedRad ~= r or state.maskedHost ~= maskHost then
            for i = 1, #textures do
                if textures[i] then ST.MaskTexture(maskHost, textures[i], r) end
            end
            state.maskedHost = maskHost
            state.maskedRad = r
        end
    else
        if state.maskedRad and state.maskedRad > 0 then
            if ST.UnmaskTexture then
                for i = 1, #textures do
                    if textures[i] then ST.UnmaskTexture(maskHost, textures[i]) end
                end
            elseif maskHost == state.statusBar then
                ST.ClearRoundedMask(maskHost)
            end
        end
        state.maskedHost = maskHost
        state.maskedRad = 0
    end
end

function M.SyncBarHitFlashMask(statusBar, maskHost, radius)
    local state = statusBar and hitFlashOverlays[statusBar]
    if not state then return end
    local host = maskHost or state.maskedHost or statusBar
    state.maskedRad = -1
    SyncSingleHitFlashMask(state, host, radius or 0)
end

function M.TriggerBarHitFlash(statusBar, kind, opts)
    if not (statusBar and statusBar.CreateTexture and statusBar.GetStatusBarTexture) then return false end
    local override = opts and opts.override
    if not (ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_hitFlash", override)) then
        return false
    end
    local fillTex = statusBar:GetStatusBarTexture()
    if not fillTex then return false end

    local state = hitFlashOverlays[statusBar]
    if not state then
        local tex = statusBar:CreateTexture(nil, "OVERLAY", nil, 4)
        tex:SetTexture(ST.TEX.FLAT)
        tex:SetBlendMode("ADD")
        tex:SetAllPoints(fillTex)
        tex:SetAlpha(0)
        tex:Hide()

        local ag = tex:CreateAnimationGroup()
        local rise = ag:CreateAnimation("Alpha")
        rise:SetOrder(1)
        rise:SetFromAlpha(0)
        rise:SetDuration(0.05)
        rise:SetSmoothing("OUT")
        local fall = ag:CreateAnimation("Alpha")
        fall:SetOrder(2)
        fall:SetToAlpha(0)
        fall:SetDuration(0.22)
        fall:SetSmoothing("OUT")
        ag:SetScript("OnFinished", function()
            tex:SetAlpha(0)
            tex:Hide()
        end)
        ag:SetScript("OnStop", function()
            tex:SetAlpha(0)
            tex:Hide()
        end)

        -- 受击淡红回落叠层（冷白冲击 -> 淡红柔和收尾）
        local redTex = statusBar:CreateTexture(nil, "OVERLAY", nil, 3)
        redTex:SetTexture(ST.TEX.FLAT)
        redTex:SetBlendMode("ADD")
        redTex:SetVertexColor(1.00, 0.34, 0.38, 1)
        redTex:SetAllPoints(fillTex)
        redTex:SetAlpha(0)
        redTex:Hide()
        local redAG = redTex:CreateAnimationGroup()
        local rRise = redAG:CreateAnimation("Alpha")
        rRise:SetOrder(1); rRise:SetStartDelay(0.03); rRise:SetFromAlpha(0); rRise:SetDuration(0.05); rRise:SetSmoothing("OUT")
        local rFall = redAG:CreateAnimation("Alpha")
        rFall:SetOrder(2); rFall:SetToAlpha(0); rFall:SetDuration(0.24); rFall:SetSmoothing("OUT")
        redAG:SetScript("OnFinished", function() redTex:SetAlpha(0); redTex:Hide() end)
        redAG:SetScript("OnStop", function() redTex:SetAlpha(0); redTex:Hide() end)

        -- 治疗专属柔绿光波横扫（0.38s 沿填充方向扫过整条，纯 C 端 AnimationGroup）
        local sweepClip = CreateFrame("Frame", nil, statusBar)
        sweepClip:SetAllPoints(fillTex)
        sweepClip:SetClipsChildren(true)
        sweepClip:EnableMouse(false)
        local lvl = F.PlainNumber(statusBar.GetFrameLevel and statusBar:GetFrameLevel(), 10) or 10
        sweepClip:SetFrameLevel(lvl + 4)
        sweepClip:Hide()

        local sweepTex = sweepClip:CreateTexture(nil, "OVERLAY", nil, 5)
        sweepTex:SetTexture(ST.TEX.BAR_FLOW_SHEEN)
        sweepTex:SetBlendMode("ADD")
        sweepTex:SetVertexColor(0.42, 1.00, 0.68, 1)
        sweepTex:SetAlpha(0)
        M.DisablePixelSnap(sweepTex)

        local sweepAG = sweepTex:CreateAnimationGroup()
        local sTr = sweepAG:CreateAnimation("Translation")
        sTr:SetOrder(1); sTr:SetDuration(0.38); sTr:SetSmoothing("OUT")
        local sAl = sweepAG:CreateAnimation("Alpha")
        sAl:SetOrder(1); sAl:SetDuration(0.38); sAl:SetToAlpha(0); sAl:SetSmoothing("IN")
        sweepAG:SetScript("OnFinished", function()
            sweepTex:SetAlpha(0)
            sweepTex:Hide()
            sweepClip:Hide()
        end)
        sweepAG:SetScript("OnStop", function()
            sweepTex:SetAlpha(0)
            sweepTex:Hide()
            sweepClip:Hide()
        end)

        state = {
            statusBar = statusBar,
            tex = tex, ag = ag, rise = rise, fall = fall,
            redTex = redTex, redAG = redAG, rRise = rRise, rFall = rFall,
            sweepClip = sweepClip, sweepTex = sweepTex, sweepAG = sweepAG, sTr = sTr, sAl = sAl,
            maskedRad = -1, maskedHost = nil,
        }
        hitFlashOverlays[statusBar] = state
    else
        state.tex:ClearAllPoints()
        state.tex:SetAllPoints(fillTex)
        if state.redTex then
            state.redTex:ClearAllPoints()
            state.redTex:SetAllPoints(fillTex)
        end
        if state.sweepClip then
            state.sweepClip:ClearAllPoints()
            state.sweepClip:SetAllPoints(fillTex)
        end
    end

    -- 共享外层宿主圆角遮罩（每张纹理仅挂 1 个遮罩，严守怪癖 7；圆角归零时正确卸除）
    local maskHost = (opts and opts.maskHost) or statusBar
    local rad = (opts and opts.radius) or nil
    if rad == nil then
        local gRad = ST.GetCornerRadius(6)
        if gRad <= 0 then
            rad = 0
        else
            local h = F.PlainNumber(statusBar.GetHeight and statusBar:GetHeight(), 16) or 16
            rad = math_min(gRad, math_max(2, math_floor(h * 0.45)))
        end
    end
    SyncSingleHitFlashMask(state, maskHost, rad)

    local isHeal = (kind == "heal" or kind == "HEAL")
    local inten = ST.GetFXIntensity(override)
    local isSoft = (inten == "soft")
    local mul = (opts and opts.alphaMul) or 1.0

    if isHeal then
        -- 治疗：柔和绿闪 + 0.38s 柔绿丝绸光波沿填充方向横扫整条
        state.tex:SetVertexColor(0.54, 1.00, 0.74, 1)
        if state.redAG then state.redAG:Stop() end
        local peak = math_min(0.60, (isSoft and 0.18 or 0.32) * mul)
        state.ag:Stop()
        state.rise:SetToAlpha(peak)
        state.fall:SetFromAlpha(peak)
        state.tex:SetAlpha(0)
        state.tex:Show()
        state.ag:Play()

        if state.sweepClip and state.sweepTex and state.sweepAG then
            local w = F.PlainNumber(statusBar.GetWidth and statusBar:GetWidth(), 140) or 140
            local h = F.PlainNumber(statusBar.GetHeight and statusBar:GetHeight(), 16) or 16
            local rev = opts and opts.reverse
            if rev == nil and statusBar.GetReverseFill then
                local okR, rVal = pcall(statusBar.GetReverseFill, statusBar)
                rev = okR and rVal == true
            end
            local bandW = math_max(54, math_floor(w * 0.50))
            state.sweepTex:SetSize(bandW, h + 6)
            state.sweepTex:ClearAllPoints()
            local travel = w + bandW + 8
            if rev then
                state.sweepTex:SetTexCoord(1, 0, 0, 1)
                state.sweepTex:SetPoint("LEFT", statusBar, "RIGHT", 4, 0)
                state.sTr:SetOffset(-travel, 0)
            else
                state.sweepTex:SetTexCoord(0, 1, 0, 1)
                state.sweepTex:SetPoint("RIGHT", statusBar, "LEFT", -4, 0)
                state.sTr:SetOffset(travel, 0)
            end
            local sweepPeak = math_min(0.92, (isSoft and 0.42 or 0.72) * mul)
            state.sweepAG:Stop()
            state.sAl:SetFromAlpha(sweepPeak)
            state.sAl:SetToAlpha(0)
            state.sweepTex:SetAlpha(sweepPeak)
            state.sweepClip:Show()
            state.sweepTex:Show()
            state.sweepAG:Play()
        end
    else
        -- 受击：干脆冷白冲击（标准 0.48 / 柔和 0.28）-> 淡红柔和回落
        state.tex:SetVertexColor(1.00, 0.96, 0.95, 1)
        if state.sweepAG then state.sweepAG:Stop() end
        local peak = math_min(0.75, (isSoft and 0.28 or 0.48) * mul)
        state.ag:Stop()
        state.rise:SetToAlpha(peak)
        state.fall:SetFromAlpha(peak)
        state.tex:SetAlpha(0)
        state.tex:Show()
        state.ag:Play()

        if state.redTex and state.redAG then
            local redPeak = math_min(0.55, (isSoft and 0.18 or 0.34) * mul)
            state.redAG:Stop()
            state.rRise:SetToAlpha(redPeak)
            state.rFall:SetFromAlpha(redPeak)
            state.redTex:SetAlpha(0)
            state.redTex:Show()
            state.redAG:Play()
        end
    end
    return true
end

----------------------------------------------------------------------
--  6) HealPredictionOverlay：治疗预估、吸收盾、治疗吸收与超量护盾标记（2a）
--     • 链式 StatusBar 锚在前一根填充纹理边缘，完整支持反向填充（玩家左翼血条）
--     • 优先使用 12.x CreateUnitHealPredictionCalculator + UnitGetDetailedHealPrediction，
--       不存在时自动退回 UnitGetIncomingHeals / UnitGetTotalAbsorbs
--     • 同帧多次事件经 C_Timer.After(0) 合并，不改宿主尺寸（Q12）
----------------------------------------------------------------------
local healPredPending = {}
local healPredArmed = false

local function FlushHealPredictions()
    healPredArmed = false
    for ctrl in pairs(healPredPending) do
        healPredPending[ctrl] = nil
        if ctrl and ctrl._pendingUnit then
            local u = ctrl._pendingUnit
            local inst = ctrl._pendingInstant == true
            ctrl._pendingUnit = nil
            ctrl._pendingInstant = false
            ctrl:UpdateFromUnit(u, inst)
        end
    end
end

local function CreatePredictCalculator()
    if type(_G.CreateUnitHealPredictionCalculator) ~= "function"
        or type(_G.UnitGetDetailedHealPrediction) ~= "function" then
        return nil
    end
    local ok, calc = pcall(_G.CreateUnitHealPredictionCalculator)
    if not (ok and calc) then return nil end
    local E = _G.Enum
    if E and E.UnitMaximumHealthMode and E.UnitMaximumHealthMode.Default ~= nil and calc.SetMaximumHealthMode then
        pcall(calc.SetMaximumHealthMode, calc, E.UnitMaximumHealthMode.Default)
    end
    if E and E.UnitDamageAbsorbClampMode and E.UnitDamageAbsorbClampMode.MissingHealth ~= nil and calc.SetDamageAbsorbClampMode then
        pcall(calc.SetDamageAbsorbClampMode, calc, E.UnitDamageAbsorbClampMode.MissingHealth)
    end
    if E and E.UnitIncomingHealClampMode and E.UnitIncomingHealClampMode.MissingHealth ~= nil and calc.SetIncomingHealClampMode then
        pcall(calc.SetIncomingHealClampMode, calc, E.UnitIncomingHealClampMode.MissingHealth)
    end
    if calc.SetIncomingHealOverflowPercent then
        pcall(calc.SetIncomingHealOverflowPercent, calc, 1.25)
    end
    return calc
end

function M.AttachHealPrediction(healthBar, opts)
    if not (healthBar and healthBar.GetStatusBarTexture) then return nil end
    opts = opts or {}
    local rev = opts.reverse == true
    local hLvl = F.PlainNumber(healthBar.GetFrameLevel and healthBar:GetFrameLevel(), 10) or 10

    local clip = CreateFrame("Frame", nil, healthBar)
    clip:SetAllPoints(healthBar)
    clip:SetClipsChildren(true)
    clip:EnableMouse(false)
    clip:SetFrameLevel(hLvl + (opts.levelOffset or 2))

    local healBar = CreateFrame("StatusBar", nil, clip)
    healBar:SetStatusBarTexture(ST.TEX.FLAT)
    healBar:SetMinMaxValues(0, 1)
    healBar:SetValue(0)
    healBar:EnableMouse(false)
    healBar:SetFrameLevel(clip:GetFrameLevel())

    local absorbBar = CreateFrame("StatusBar", nil, clip)
    absorbBar:SetStatusBarTexture(ST.TEX.FLAT)
    absorbBar:SetMinMaxValues(0, 1)
    absorbBar:SetValue(0)
    absorbBar:EnableMouse(false)
    absorbBar:SetFrameLevel(clip:GetFrameLevel() + 1)

    local stripeTex = absorbBar:CreateTexture(nil, "ARTWORK", nil, 2)
    stripeTex:SetTexture(ST.TEX.DIAG_STRIPES, "REPEAT", "REPEAT")
    if stripeTex.SetHorizTile then stripeTex:SetHorizTile(true) end
    if stripeTex.SetVertTile then stripeTex:SetVertTile(true) end
    stripeTex:SetBlendMode("BLEND")
    stripeTex:SetVertexColor(1, 1, 1, 0.14)
    local absFill = absorbBar:GetStatusBarTexture()
    if absFill then stripeTex:SetAllPoints(absFill) end

    local healAbsorbBar = CreateFrame("StatusBar", nil, clip)
    healAbsorbBar:SetStatusBarTexture(ST.TEX.FLAT)
    healAbsorbBar:SetMinMaxValues(0, 1)
    healAbsorbBar:SetValue(0)
    healAbsorbBar:EnableMouse(false)
    healAbsorbBar:SetFrameLevel(clip:GetFrameLevel() + 2)

    local overMark = clip:CreateTexture(nil, "OVERLAY", nil, 4)
    overMark:SetTexture(ST.TEX.FLAT)
    overMark:SetVertexColor(0.92, 0.98, 1.00, 1)
    overMark:SetAlpha(0)
    overMark:SetWidth(3)

    local ctrl = {
        _host          = healthBar,
        _maskHost      = opts.maskHost or healthBar,
        _clip          = clip,
        _healBar       = healBar,
        _absorbBar     = absorbBar,
        _stripeTex     = stripeTex,
        _healAbsorbBar = healAbsorbBar,
        _overMark      = overMark,
        _reverse       = rev,
        _fxOverride    = opts.fxOverride,
        _calc          = nil,
        _maskedRad     = -1,
    }

    local function LayoutChain(forceMask)
        local fillTex = healthBar:GetStatusBarTexture()
        if not fillTex then return end
        local w = F.PlainNumber(healthBar.GetWidth and healthBar:GetWidth(), 136) or 136
        if w < 1 then w = 136 end
        local isRev = ctrl._reverse == true
        local lead = isRev and "LEFT" or "RIGHT"
        local back = isRev and "RIGHT" or "LEFT"

        -- 治疗预估锚在主血条填充边缘
        healBar:ClearAllPoints()
        healBar:SetPoint("TOP" .. back, fillTex, "TOP" .. lead, 0, 0)
        healBar:SetPoint("BOTTOM" .. back, fillTex, "BOTTOM" .. lead, 0, 0)
        healBar:SetWidth(w)
        if healBar.SetReverseFill then healBar:SetReverseFill(isRev) end

        -- 吸收盾锚在治疗预估填充边缘（链式接续）
        local hFill = healBar:GetStatusBarTexture() or fillTex
        absorbBar:ClearAllPoints()
        absorbBar:SetPoint("TOP" .. back, hFill, "TOP" .. lead, 0, 0)
        absorbBar:SetPoint("BOTTOM" .. back, hFill, "BOTTOM" .. lead, 0, 0)
        absorbBar:SetWidth(w)
        if absorbBar.SetReverseFill then absorbBar:SetReverseFill(isRev) end
        local aFill = absorbBar:GetStatusBarTexture()
        if aFill then
            stripeTex:ClearAllPoints()
            stripeTex:SetAllPoints(aFill)
        end

        -- 反向治疗吸收段：贴在主血条当前填充内侧边缘
        healAbsorbBar:ClearAllPoints()
        healAbsorbBar:SetPoint("TOP" .. lead, fillTex, "TOP" .. lead, 0, 0)
        healAbsorbBar:SetPoint("BOTTOM" .. lead, fillTex, "BOTTOM" .. lead, 0, 0)
        healAbsorbBar:SetWidth(w)
        if healAbsorbBar.SetReverseFill then healAbsorbBar:SetReverseFill(not isRev) end

        -- 超量护盾标记：条尾 3px 细亮条
        overMark:ClearAllPoints()
        overMark:SetPoint("TOP" .. lead, clip, "TOP" .. lead, 0, 0)
        overMark:SetPoint("BOTTOM" .. lead, clip, "BOTTOM" .. lead, 0, 0)

        local mHost = ctrl._maskHost or healthBar
        local gRad = ST.GetCornerRadius(6)
        local rad = 0
        if gRad > 0 then
            local h = F.PlainNumber(mHost.GetHeight and mHost:GetHeight(), nil)
                or F.PlainNumber(healthBar.GetHeight and healthBar:GetHeight(), 16) or 16
            rad = math_min(gRad, math_max(2, math.floor(h * 0.45)))
        end
        local haFill = healAbsorbBar:GetStatusBarTexture()
        if forceMask or ctrl._maskedRad ~= rad then
            if rad > 0 then
                if hFill then ST.MaskTexture(mHost, hFill, rad) end
                if aFill then ST.MaskTexture(mHost, aFill, rad) end
                ST.MaskTexture(mHost, stripeTex, rad)
                if haFill then ST.MaskTexture(mHost, haFill, rad) end
                ST.MaskTexture(mHost, overMark, rad)
            else
                if ST.UnmaskTexture then
                    if hFill then ST.UnmaskTexture(mHost, hFill) end
                    if aFill then ST.UnmaskTexture(mHost, aFill) end
                    ST.UnmaskTexture(mHost, stripeTex)
                    if haFill then ST.UnmaskTexture(mHost, haFill) end
                    ST.UnmaskTexture(mHost, overMark)
                end
            end
            ctrl._maskedRad = rad
        end
    end

    local function ApplyColors()
        local scale = ST.GetFXScale(ctrl._fxOverride)
        if scale <= 0 then scale = 1 end
        local seamTex = ST.GetBarFillTexture and ST.GetBarFillTexture(true, ctrl._fxOverride) or ST.TEX.FLAT
        if ctrl._appliedTex ~= seamTex then
            ctrl._appliedTex = seamTex
            healBar:SetStatusBarTexture(seamTex)
            absorbBar:SetStatusBarTexture(seamTex)
            healAbsorbBar:SetStatusBarTexture(seamTex)
            ctrl._maskedRad = -1
            LayoutChain(true)
        end
        local pos = ST.COLORS.positive or { 0.34, 0.88, 0.56 }
        healBar:SetStatusBarColor(pos[1], pos[2], pos[3], 0.42 * scale)
        absorbBar:SetStatusBarColor(0.92, 0.96, 1.00, 0.32 * scale)
        stripeTex:SetVertexColor(1, 1, 1, 0.14 * scale)
        healAbsorbBar:SetStatusBarColor(0.48, 0.12, 0.24, 0.52 * scale)
    end

    function ctrl:SyncLayout(forceMask)
        if forceMask then self._maskedRad = -1 end
        LayoutChain(forceMask == true)
        ApplyColors()
    end

    function ctrl:SetValues(maxVal, heals, absorbs, isOver, healAbsorbs, instant)
        if not ST.IsFXEnabled("fx_healPredict", self._fxOverride) then
            self._clip:Hide()
            return
        end
        self._clip:Show()
        ApplyColors()
        local barOpts = {
            fxKey = "fx_smoothMain",
            override = self._fxOverride,
            instant = instant == true,
        }
        M.SetBarMinMax(self._healBar, 0, maxVal)
        M.SetBarValue(self._healBar, heals or 0, barOpts)
        M.SetBarMinMax(self._absorbBar, 0, maxVal)
        M.SetBarValue(self._absorbBar, absorbs or 0, barOpts)
        if type(healAbsorbs) ~= "nil" then
            M.SetBarMinMax(self._healAbsorbBar, 0, maxVal)
            M.SetBarValue(self._healAbsorbBar, healAbsorbs, barOpts)
            self._healAbsorbBar:Show()
        else
            self._healAbsorbBar:SetValue(0)
            self._healAbsorbBar:Hide()
        end
        local scale = ST.GetFXScale(self._fxOverride)
        if type(isOver) ~= "nil" and self._overMark.SetAlphaFromBoolean then
            local okO = pcall(self._overMark.SetAlphaFromBoolean, self._overMark, isOver, 0.88 * scale, 0)
            if not okO then self._overMark:SetAlpha(0) end
        elseif not F.IsSecret(isOver) and isOver == true then
            self._overMark:SetAlpha(0.88 * scale)
        else
            self._overMark:SetAlpha(0)
        end
    end

    function ctrl:UpdateFromUnit(unit, instant)
        if not ST.IsFXEnabled("fx_healPredict", self._fxOverride) then
            self._clip:Hide()
            return
        end
        if not (unit and _G.UnitExists) then
            self._clip:Hide()
            return
        end
        local okEx, ex = pcall(_G.UnitExists, unit)
        if not okEx or (not F.IsSecret(ex) and not ex) then
            self._clip:Hide()
            return
        end
        local mx = _G.UnitHealthMax and _G.UnitHealthMax(unit)
        if type(mx) == "nil" then mx = 1 end

        local heals, absorbs, isOver, healAbsorbs = 0, 0, nil, nil
        if not self._calc then
            self._calc = CreatePredictCalculator()
        end
        local usedCalc = false
        if self._calc and type(_G.UnitGetDetailedHealPrediction) == "function" then
            local okCalc = pcall(_G.UnitGetDetailedHealPrediction, unit, nil, self._calc)
            if okCalc then
                usedCalc = true
                if self._calc.GetIncomingHeals then
                    local okH, hVal = pcall(self._calc.GetIncomingHeals, self._calc)
                    if okH and type(hVal) ~= "nil" then heals = hVal end
                end
                if self._calc.GetDamageAbsorbs then
                    local okA, aVal, ov = pcall(self._calc.GetDamageAbsorbs, self._calc)
                    if okA and type(aVal) ~= "nil" then
                        absorbs = aVal
                        isOver = ov
                    end
                end
                if self._calc.GetHealAbsorbs then
                    local okHA, haVal = pcall(self._calc.GetHealAbsorbs, self._calc)
                    if okHA and type(haVal) ~= "nil" then healAbsorbs = haVal end
                end
            end
        end
        if not usedCalc then
            if type(_G.UnitGetIncomingHeals) == "function" then
                local okH, hVal = pcall(_G.UnitGetIncomingHeals, unit)
                if okH and type(hVal) ~= "nil" then heals = hVal end
            end
            if type(_G.UnitGetTotalAbsorbs) == "function" then
                local okA, aVal = pcall(_G.UnitGetTotalAbsorbs, unit)
                if okA and type(aVal) ~= "nil" then absorbs = aVal end
            end
            if type(_G.UnitGetTotalHealAbsorbs) == "function" then
                local okHA, haVal = pcall(_G.UnitGetTotalHealAbsorbs, unit)
                if okHA and type(haVal) ~= "nil" then healAbsorbs = haVal end
            end
        end
        self:SetValues(mx, heals, absorbs, isOver, healAbsorbs, instant)
    end

    function ctrl:QueueUpdate(unit, instant)
        if not ST.IsFXEnabled("fx_healPredict", self._fxOverride) then
            self._clip:Hide()
            return
        end
        if instant then
            healPredPending[self] = nil
            self._pendingUnit = nil
            self._pendingInstant = false
            self:UpdateFromUnit(unit, true)
            return
        end
        self._pendingUnit = unit
        self._pendingInstant = self._pendingInstant == true
        healPredPending[self] = true
        if not healPredArmed then
            healPredArmed = true
            C_Timer.After(0, FlushHealPredictions)
        end
    end

    if healthBar.HookScript then
        pcall(healthBar.HookScript, healthBar, "OnSizeChanged", LayoutChain)
    end
    LayoutChain()
    ApplyColors()
    if not ST.IsFXEnabled("fx_healPredict", ctrl._fxOverride) then
        clip:Hide()
    end
    return ctrl
end

----------------------------------------------------------------------
--  7) PlayBarArriveGlide & PlayFrameArriveSlide：换目标轻快入场滑动（2b / 任务 8）
--     • 明文血量：先 Immediate 设至 55%（柔和 72%），下一帧用原生平滑滑至当前值
--     • 框体同步 8px 横向微滑 + 0.35 起步快淡入（纯 Translation+Alpha，不改最终锚点严守 Q12，机密血量同样生效）
--     • 快速连续切换目标时按代数取消旧回调，拖尾绝不露出伪影
----------------------------------------------------------------------
local arriveState = setmetatable({}, { __mode = "k" })

function M.CancelBarArriveGlide(bar)
    local st = bar and arriveState[bar]
    if st then
        st.gen = (st.gen or 0) + 1
    end
end

function M.PlayFrameArriveSlide(frame, opts)
    if not (frame and frame.CreateAnimationGroup) then return false end
    local override = opts and opts.override
    if not (ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_targetArrive", override)) then
        return false
    end
    local isSoft = ST.GetFXIntensity(override) == "soft"
    local dx = (opts and opts.dx) or (isSoft and 5 or 8)
    local startA = (opts and opts.startAlpha) or 0.35
    local slideDur = (opts and opts.duration) or 0.14
    local fadeDur = (opts and opts.fadeDuration) or 0.08

    local ag, cache = GetSlot(frame, "arriveSlide")
    if not ag then
        ag = frame:CreateAnimationGroup()
        local jump = ag:CreateAnimation("Translation")
        jump:SetOrder(1)
        jump:SetDuration(0)
        local slide = ag:CreateAnimation("Translation")
        slide:SetOrder(2)
        slide:SetSmoothing("OUT")
        local fade = ag:CreateAnimation("Alpha")
        fade:SetOrder(2)
        fade:SetToAlpha(1.0)
        fade:SetSmoothing("OUT")
        ag._jump, ag._slide, ag._fade = jump, slide, fade
        ag:SetScript("OnFinished", function() frame:SetAlpha(1) end)
        ag:SetScript("OnStop", function() frame:SetAlpha(1) end)
        cache.arriveSlide = ag
    end
    ag:Stop()
    ag._jump:SetOffset(dx, 0)
    ag._slide:SetOffset(-dx, 0)
    ag._slide:SetDuration(slideDur)
    ag._fade:SetFromAlpha(startA)
    ag._fade:SetToAlpha(1.0)
    ag._fade:SetDuration(fadeDur)
    frame:SetAlpha(1)
    ag:Play()
    return true
end

function M.PlayBarArriveGlide(bar, cur, maxVal, trailCtrl, opts)
    if not bar then return false end
    local override = opts and opts.override
    if not (ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_targetArrive", override)) then
        return false
    end
    if F.IsSecret(cur) or F.IsSecret(maxVal) then
        return false
    end
    local hp = F.PlainNumber(cur, nil)
    local mx = F.PlainNumber(maxVal, nil)
    if not (hp and mx and mx > 0 and hp > 0) then
        return false
    end
    if opts and opts.unit and IsUnitDeadPlain(opts.unit) then
        return false
    end

    local ratio = (ST.GetFXIntensity(override) == "soft") and 0.72 or 0.55
    local startVal = hp * ratio

    local st = arriveState[bar]
    if not st then
        st = { gen = 0, armedGen = 0, pending = false }
        arriveState[bar] = st
    end
    st.gen = st.gen + 1
    st.armedGen = st.gen
    st.targetVal = hp
    st.targetMax = mx
    st.trail = trailCtrl
    st.override = override
    st.unit = opts and opts.unit or nil

    M.SetBarMinMax(bar, 0, mx)
    M.SetBarValue(bar, startVal, {
        fxKey = "fx_smoothMain",
        override = override,
        instant = true,
    })
    -- 拖尾同步到起点值，确保向上滑入期间不会露出假掉血段
    if trailCtrl and trailCtrl.SetValue then
        trailCtrl:SetValue(startVal, mx, true)
    end

    if not st.timerCb then
        st.timerCb = function()
            st.pending = false
            if st.gen ~= st.armedGen then return end
            if not bar:IsVisible() then return end
            M.SetBarValue(bar, st.targetVal, {
                fxKey = "fx_smoothMain",
                override = st.override,
                unit = st.unit,
                instant = false,
            })
            if st.trail and st.trail.SetValue then
                st.trail:SetValue(st.targetVal, st.targetMax, true)
            end
        end
    end
    -- 复用单个已排队的回调（零额外闭包分配），快速连切或同帧 CancelBarArriveGlide 均按代数安全收口
    if not st.pending then
        st.pending = true
        C_Timer.After(0, st.timerCb)
    end
    return true
end

----------------------------------------------------------------------
--  8) ArmClientTimerBar：客户端原生计时条统一封装（2d：RollBars / WeaponProcs / SoulstoneAlert）
--     • 使用 C_DurationUtil.CreateDuration + StatusBar:SetTimerDuration，
--       消除每条独立 OnUpdate，开关关闭或 API 不存在时返回 false 走旧路径
----------------------------------------------------------------------
function M.ArmClientTimerBar(bar, startSec, durSec, isElapsed, override)
    if not (ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_timerBars", override)) then
        return false
    end
    if not (bar and type(bar.SetTimerDuration) == "function") then
        return false
    end
    local CU = _G.C_DurationUtil
    local dirEnum = _G.Enum and _G.Enum.StatusBarTimerDirection
    if not (CU and type(CU.CreateDuration) == "function" and dirEnum) then
        return false
    end
    local dur = (type(durSec) == "number" and durSec > 0.01) and durSec or 0.01
    local d = bar._kkTimerDurObj
    if not d then
        local okC, created = pcall(CU.CreateDuration)
        if not (okC and created) then return false end
        d = created
        bar._kkTimerDurObj = d
    end
    if d.SetTimeFromStart then
        local okS = pcall(d.SetTimeFromStart, d, startSec or GetTime(), dur)
        if not okS then return false end
    elseif d.SetTimeSpan then
        local st = startSec or GetTime()
        local okS = pcall(d.SetTimeSpan, d, st, st + dur)
        if not okS then return false end
    else
        return false
    end
    local dir = isElapsed and dirEnum.ElapsedTime or dirEnum.RemainingTime
    local imm = _G.Enum.StatusBarInterpolation and _G.Enum.StatusBarInterpolation.Immediate or nil
    local okT = pcall(bar.SetTimerDuration, bar, d, imm, dir)
    if not okT then return false end
    if bar.SetToTargetValue then pcall(bar.SetToTargetValue, bar) end
    M.DisablePixelSnap(bar)
    if bar.GetStatusBarTexture then M.DisablePixelSnap(bar:GetStatusBarTexture()) end
    return true
end

----------------------------------------------------------------------
--  9) 公共光环槽轻量动效（fx_auraFeel：供双翼自身光环与目标光环复用，零字段污染，0 OnUpdate）
----------------------------------------------------------------------
local auraSlotFeel = setmetatable({}, { __mode = "k" })

function M.PlayAuraSlotSlideIn(slot, dx, dy, override)
    if not (slot and slot.CreateAnimationGroup) then return false end
    if not (ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_auraFeel", override)) then
        return false
    end
    local isSoft = ST.GetFXIntensity(override) == "soft"
    local ox = (dx or 5) * (isSoft and 0.65 or 1.0)
    local oy = (dy or 0) * (isSoft and 0.65 or 1.0)
    local ag, cache = GetSlot(slot, "auraSlide")
    if not ag then
        ag = slot:CreateAnimationGroup()
        local jump = ag:CreateAnimation("Translation")
        jump:SetOrder(1); jump:SetDuration(0)
        local slide = ag:CreateAnimation("Translation")
        slide:SetOrder(2); slide:SetDuration(0.18); slide:SetSmoothing("OUT")
        local fade = ag:CreateAnimation("Alpha")
        fade:SetOrder(2); fade:SetFromAlpha(0); fade:SetToAlpha(1); fade:SetDuration(0.18); fade:SetSmoothing("OUT")
        ag._jump, ag._slide = jump, slide
        ag:SetScript("OnFinished", function() slot:SetAlpha(1) end)
        ag:SetScript("OnStop", function() slot:SetAlpha(1) end)
        cache.auraSlide = ag
    end
    ag:Stop()
    ag._jump:SetOffset(ox, oy)
    ag._slide:SetOffset(-ox, -oy)
    slot:SetAlpha(1)
    ag:Play()
    return true
end

function M.SyncAuraSlotExpireGlow(slot, expiring, radius, override)
    if not slot then return end
    local st = auraSlotFeel[slot]
    local want = expiring == true and (ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_auraFeel", override)) == true
    if not want then
        if st then
            if st.pulseAG then
                if st.pulseAG:IsPlaying() then st.pulseAG:Stop() end
                M.UnregisterLoopAnim(st.pulseAG)
            end
            if st.glow then st.glow:Hide() end
            st.active = false
        end
        return
    end
    if not st then
        if not slot.CreateTexture then return end
        local glow = slot:CreateTexture(nil, "OVERLAY", nil, 5)
        glow:SetAllPoints(slot)
        glow:SetTexture(ST.TEX.FLAT)
        glow:SetBlendMode("ADD")
        glow:SetVertexColor(1.00, 0.72, 0.24, 1)
        glow:Hide()
        st = { glow = glow, maskedRad = -1, active = false }
        auraSlotFeel[slot] = st
    end
    local rad = radius or 0
    if st.maskedRad ~= rad then
        if rad > 0 then
            ST.MaskTexture(slot, st.glow, rad)
        elseif ST.UnmaskTexture then
            ST.UnmaskTexture(slot, st.glow)
        end
        st.maskedRad = rad
    end
    local scale = ST.GetFXScale(override)
    st.pulseAG = M.EnsurePulseAlpha(st.glow, 0.20 * scale, 0.42 * scale, 1.15)
    st.glow:Show()
    st.active = true
    if st.pulseAG then
        M.RegisterLoopAnim(st.pulseAG, function()
            return st.active == true and slot:IsVisible() and ST.IsFXEnabled("fx_auraFeel", override)
        end)
        if not st.pulseAG:IsPlaying() then st.pulseAG:Play() end
    end
end
