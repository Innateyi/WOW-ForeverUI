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

-- 5i) 受击/治疗柔光瞬闪（ADD 混合，贴合主条填充并共用遮罩，纯 AnimationGroup 0 OnUpdate，不改尺寸）
local hitFlashOverlays = setmetatable({}, { __mode = "k" })

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
        rise:SetDuration(0.06)
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
        state = { tex = tex, ag = ag, rise = rise, fall = fall, maskedRad = -1 }
        hitFlashOverlays[statusBar] = state
    else
        state.tex:ClearAllPoints()
        state.tex:SetAllPoints(fillTex)
    end

    -- 共享宿主圆角遮罩（每张纹理仅挂 1 个遮罩，严守怪癖 7）
    local rad = (opts and opts.radius) or nil
    if rad == nil then
        local h = F.PlainNumber(statusBar.GetHeight and statusBar:GetHeight(), 16) or 16
        rad = math_min(ST.GetCornerRadius(6), math_max(2, math.floor(h * 0.45)))
    end
    if rad > 0 and state.maskedRad ~= rad then
        ST.MaskTexture(statusBar, state.tex, rad)
        state.maskedRad = rad
    end

    local isHeal = (kind == "heal" or kind == "HEAL")
    if isHeal then
        state.tex:SetVertexColor(0.62, 1.00, 0.78, 1)
    else
        state.tex:SetVertexColor(1.00, 0.94, 0.90, 1)
    end

    local inten = ST.GetFXIntensity(override)
    local basePeak = (inten == "soft") and 0.20 or 0.35
    local peak = basePeak * ((opts and opts.alphaMul) or 1.0)
    state.ag:Stop()
    state.rise:SetToAlpha(peak)
    state.fall:SetFromAlpha(peak)
    state.tex:SetAlpha(0)
    state.tex:Show()
    state.ag:Play()
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

    local function LayoutChain()
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

        local h = F.PlainNumber(healthBar.GetHeight and healthBar:GetHeight(), 16) or 16
        local rad = math_min(ST.GetCornerRadius(6), math_max(2, math.floor(h * 0.45)))
        if rad > 0 and ctrl._maskedRad ~= rad then
            if hFill then ST.MaskTexture(healthBar, hFill, rad) end
            if aFill then ST.MaskTexture(healthBar, aFill, rad) end
            ST.MaskTexture(healthBar, stripeTex, rad)
            local haFill = healAbsorbBar:GetStatusBarTexture()
            if haFill then ST.MaskTexture(healthBar, haFill, rad) end
            ctrl._maskedRad = rad
        end
    end

    local function ApplyColors()
        local scale = ST.GetFXScale(ctrl._fxOverride)
        if scale <= 0 then scale = 1 end
        local pos = ST.COLORS.positive or { 0.34, 0.88, 0.56 }
        healBar:SetStatusBarColor(pos[1], pos[2], pos[3], 0.42 * scale)
        absorbBar:SetStatusBarColor(0.92, 0.96, 1.00, 0.32 * scale)
        stripeTex:SetVertexColor(1, 1, 1, 0.14 * scale)
        healAbsorbBar:SetStatusBarColor(0.48, 0.12, 0.24, 0.52 * scale)
    end

    function ctrl:SyncLayout()
        LayoutChain()
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
--  7) PlayBarArriveGlide：换目标轻快入场滑动（2b）
--     • 明文血量：先 Immediate 设至 80%（柔和 90%），下一帧用原生平滑滑至当前值
--     • 机密血量：不做算术，直接跳过滑动保留淡入
--     • 快速连续切换目标时按代数取消旧回调，拖尾绝不露出伪影
----------------------------------------------------------------------
local arriveState = setmetatable({}, { __mode = "k" })

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

    local ratio = (ST.GetFXIntensity(override) == "soft") and 0.90 or 0.80
    local startVal = hp * ratio

    local st = arriveState[bar]
    if not st then
        st = { gen = 0 }
        arriveState[bar] = st
    end
    st.gen = st.gen + 1
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

    if not st.fn then
        st.fn = function()
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
    local myGen = st.gen
    if not st.pending then
        st.pending = true
        C_Timer.After(0, function()
            st.pending = false
            if st.gen == myGen then
                st.fn()
            end
        end)
    else
        -- 已有待执行回调，直接更新目标值，下一帧以最新目标滑入（避免叠加）
        local latestGen = st.gen
        C_Timer.After(0, function()
            if st.gen == latestGen then
                st.fn()
            end
        end)
    end
    return true
end
