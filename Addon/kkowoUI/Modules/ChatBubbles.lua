----------------------------------------------------------------------
--  kkowoUI — Modules/ChatBubbles.lua
--  头顶聊天气泡统一：
--    • 接管引擎画出的每一个气泡（说 / 喊 / 表情 / NPC / 队伍），不再依赖「气泡文字 = 聊天事件文字」
--      的匹配。EUI 自带的气泡皮肤只认得能匹配上的气泡，带物品/附魔链接的喊话匹配失败，
--      于是同屏出现「EUI 小框」和「暴雪原版大气泡」两种样式。
--    • 统一为半透明磨砂玻璃 + 适中字号；出现时淡入，引擎收起气泡时原地渐隐，而不是瞬间消失。
--    • 启用期间让 EUI 的气泡皮肤在运行时停手（不改它的存档），停用本模块即交还。
--    • 副本内气泡被暴雪设为受保护框体，插件无法读取或改样式，保持原样。
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local pairs, pcall, setmetatable, type = pairs, pcall, setmetatable, type
local math_abs, math_floor, math_max, math_min = math.abs, math.floor, math.max, math.min
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local mod = F.RegisterModule("chatBubbles", {
    title = "头顶聊天气泡统一",
    desc = "野外头顶气泡统一为 PrettyTooltip 同源黑曜石圆角卡片与适中字号（淡入/渐隐），自动接管 EUI 旧气泡皮肤；副本内受暴雪保护无法换肤，但会自动按界面缩放调小系统 ChatBubbleFont，避免副本气泡大得挡视野。",
    group = "social",
    order = 15,
    defaults = {
        enabled = true,
        fontSize = 14,        -- 适中：介于 EUI 12 号小框与暴雪原版大气泡之间
        maxWidth = 300,
        bgAlpha = 0.84,       -- PrettyTooltip 同源黑曜石底色浓度
        cornerRadius = 8,     -- 现代 MMO 柔和圆角半径（6~12px）
        fadeIn = 0.15,
        fadeOut = 0.80,       -- 引擎收起气泡后原地渐隐的时长
        followColor = true,   -- 沿用引擎给的频道颜色（说白 / 喊红 / NPC 等）
        partyBubbles = true,  -- 队伍 / 副本队伍频道也显示气泡
        scaleInstanceBubble = true,  -- 副本内自动缩放系统 ChatBubbleFont，避免原生气泡过大
        instanceBubbleScale = 0.90,  -- 相对「野外气泡字号 × 界面缩放」的微调倍率
        v2RoundedPretty = false,
    },
})

local WEAK = { __mode = "k" }
local hooked = setmetatable({}, WEAK)        -- 暴雪外层气泡框 -> true（钩子终身有效，处理函数自行判断启用状态）
local childOf = setmetatable({}, WEAK)       -- 外层框 -> 画气泡的子框（固定配对，可缓存）
local live = setmetatable({}, WEAK)          -- 外层框 -> 我们正在显示的气泡
local pendingRetry = setmetatable({}, WEAK)  -- 外层框 -> 剩余重试帧数（引擎先显示、后填字时用）
local pool = {}
local suspended = false                      -- 副本内：气泡受保护，什么都不做
local uiHidden = false                       -- Alt+Z 隐藏界面：我们的框随 UIParent 隐藏，原版气泡交还给引擎
local retryQueued = false
local scanQueued = false
local heldCVars = {}                         -- CVar 名 -> 接管前的原值
local euiOrigDB = nil
local proxyOf = setmetatable({}, WEAK)

local function Clamp(v, lo, hi, fallback)
    v = F.PlainNumber(v, fallback)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

----------------------------------------------------------------------
--  受保护读写：暴雪气泡框在过图时可能被重新归类为 forbidden，
--  对它的任何索引都会直接报错，所以连取方法本身也放进 pcall。
----------------------------------------------------------------------
local function IsForbiddenRaw(f) return f:IsForbidden() end
local function IsShownRaw(f) return f:IsShown() end
local function GetTextRaw(fs) return fs:GetText() end
local function GetColorRaw(fs) return fs:GetTextColor() end
local function SetAlphaRaw(f, a) f:SetAlpha(a) end
local function ResolvePartsRaw(outer)
    local child = childOf[outer] or outer:GetChildren()
    return child, child and child.String
end

local function IsForbiddenSafe(f)
    if not f then return true end
    local ok, forb = pcall(IsForbiddenRaw, f)
    return (not ok) or forb == true
end

local function BlizzShown(outer)
    local ok, shown = pcall(IsShownRaw, outer)
    return ok and shown == true
end

local function BlizzParts(outer)
    local ok, child, fs = pcall(ResolvePartsRaw, outer)
    if not ok or not child then return nil, nil end
    childOf[outer] = child
    return child, fs
end

local function SetBlizzAlpha(child, a)
    if child then pcall(SetAlphaRaw, child, a) end
end

local function ReadText(fs)
    if not fs then return nil end
    local ok, text = pcall(GetTextRaw, fs)
    if not ok then return nil end
    return text
end

local function ReadColor(fs)
    local ok, r, g, b = pcall(GetColorRaw, fs)
    if not ok or type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
    if F.IsSecret(r) or F.IsSecret(g) or F.IsSecret(b) then return nil end
    return r, g, b
end

-- 两边都可能是保密字符串，比较本身会抛错，所以放进 pcall；比较失败按「没变」处理
local _eqA, _eqB, _eqOut
local function RawEq() _eqOut = (_eqA == _eqB) end
local function SafeEq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return a == b end
    _eqA, _eqB, _eqOut = a, b, true
    pcall(RawEq)
    _eqA, _eqB = nil, nil
    return _eqOut == true
end

----------------------------------------------------------------------
--  我们的气泡框
----------------------------------------------------------------------
local Release   -- forward
local fading = {}

local function OnFadeFinished(ag)
    local f = ag:GetParent()
    if f._fadingOut then
        Release(f)
    else
        f:SetAlpha(1)
    end
end

local function NewBubble()
    local f = CreateFrame("Frame", nil, _G.UIParent)
    -- LOW：盖在 3D 场景与暴雪原气泡之上，但压在动作条 / 聊天框（MEDIUM）之下，不挡界面
    f:SetFrameStrata("LOW")
    f:SetFrameLevel(2)
    f:EnableMouse(false)
    f:Hide()

    f.text = f:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(f.text, 14, "")   -- SetText 前必须先有字体
    f.text:SetJustifyH("CENTER")
    f.text:SetJustifyV("MIDDLE")
    f.text:SetWordWrap(true)
    if f.text.SetNonSpaceWrap then f.text:SetNonSpaceWrap(true) end
    -- 鸿蒙字体字身略偏上，轻微下移 1px 让文字在圆角气泡内视觉绝对居中
    f.text:SetPoint("CENTER", f, "CENTER", 0, -1)

    f.anim = f:CreateAnimationGroup()
    f.fade = f.anim:CreateAnimation("Alpha")
    f.anim:SetToFinalAlpha(true)
    f.anim:SetScript("OnFinished", OnFadeFinished)
    return f
end

local function Acquire()
    local f = pool[#pool]
    if f then
        pool[#pool] = nil
        return f
    end
    return NewBubble()
end

function Release(f)
    if not f then return end
    fading[f] = nil
    f.anim:Stop()
    f._fadingOut = false
    f:SetScript("OnUpdate", nil)
    f:Hide()
    f:ClearAllPoints()
    f.outer, f.child, f.src, f.srcText = nil, nil, nil, nil
    pool[#pool + 1] = f
end

local function PlayFade(f, from, to, dur, out)
    f.anim:Stop()
    f._fadingOut = out == true
    if out then
        fading[f] = true
    else
        fading[f] = nil
    end
    if dur <= 0.01 then
        f:SetAlpha(to)
        if out then Release(f) end
        return
    end
    f:SetAlpha(from)
    f.fade:SetFromAlpha(from)
    f.fade:SetToAlpha(to)
    f.fade:SetDuration(dur)
    f.fade:SetSmoothing(out and "IN" or "OUT")
    f.anim:Play()
end

-- 量字：先按最大宽度量单行宽，再把实际宽度设回去量折行后的高度（与 EUI 同一顺序）。
-- 保密字符串可以显示但不能量，量失败就按最大宽度 + 估算高度兜底。
local _mFS, _mMax, _mW, _mH
local function RawMeasure()
    _mFS:SetWidth(_mMax)
    local w = _mFS:GetStringWidth()
    if w > _mMax then w = _mMax end
    if w < 24 then w = 24 end
    w = math_floor(w + 1.5)
    if w > _mMax then w = _mMax end
    _mFS:SetWidth(w)
    local parent = _mFS:GetParent()
    if parent then parent:SetHeight(10) end
    local h = _mFS:GetStringHeight()
    if h < 1 then h = 1 end
    _mW, _mH = w, h
end

local function Measure(fs, maxW, size)
    _mFS, _mMax, _mW, _mH = fs, maxW, nil, nil
    local ok = pcall(RawMeasure)
    _mFS = nil
    if not ok or not _mW or not _mH then
        fs:SetWidth(maxW)
        return maxW, size * 1.35 * 3
    end
    return _mW, _mH
end

local function ResolveBubbleAccent(f, db)
    if db.followColor ~= false and f.cr and f.cg and f.cb then
        local hi = math_max(f.cr, f.cg, f.cb)
        local lo = math_min(f.cr, f.cg, f.cb)
        -- 频道本身有鲜明色（大喊红、队伍蓝、NPC 暖金）则沿用频道色，纯白说话用 PrettyTooltip 暖金中性色
        if hi - lo > 0.12 then
            return f.cr, f.cg, f.cb
        end
    end
    return 0.80, 0.68, 0.48
end

local function Layout(f)
    local db = mod:GetDB()
    local size = Clamp(db.fontSize, 10, 22, 14)
    local maxW = Clamp(db.maxWidth, 160, 480, 300)
    F.Theme.ApplyFont(f.text, size, "")
    if db.followColor ~= false and f.cr then
        f.text:SetTextColor(f.cr, f.cg, f.cb, 1)
    else
        f.text:SetTextColor(0.96, 0.96, 0.97, 1)
    end
    local w, h = Measure(f.text, maxW, size)
    local padH = math_max(12, math_floor(size * 0.90 + 0.5))
    local padV = math_max(7, math_floor(size * 0.55 + 0.5))
    local totalH = h + padV * 2
    f:SetSize(w + padH * 2, totalH)

    local ar, ag, ab = ResolveBubbleAccent(f, db)
    local radius = math_floor(Clamp(db.cornerRadius, 4, 12, 8) + 0.5)
    F.Theme.SetFrostedGlassShown(f, false)
    F.Theme.PaintPrettyCardOverlay(f, ar, ag, ab, math_min(24, math_floor(totalH * 0.55)), {
        rounded = true,
        radius = radius,
        alpha = Clamp(db.bgAlpha, 0.40, 0.95, 0.84),
        haloAlpha = 0.22,
        haloSpread = 12,
        headerTopAlpha = 0.28,
        headerBottomAlpha = 0.00,
    })
end

local _anF, _anTo
local function RawAnchor()
    _anF:ClearAllPoints()
    _anF:SetPoint("CENTER", _anTo, "CENTER", 0, 0)
end

local function AnchorTo(f, child)
    _anF, _anTo = f, child
    local ok = pcall(RawAnchor)
    _anF, _anTo = nil, nil
    return ok
end

-- 引擎会在同一个气泡里换新句子（同一个人连续说话），没有任何回调，只能低频比对
local function BubbleOnUpdate(f, elapsed)
    f._acc = (f._acc or 0) + elapsed
    if f._acc < 0.25 then return end
    f._acc = 0
    local text = ReadText(f.src)
    if type(text) ~= "string" or SafeEq(text, f.srcText) then return end
    if not F.IsSecret(text) and text == "" then return end
    f.srcText = text
    f.cr, f.cg, f.cb = ReadColor(f.src)
    f.text:SetText(text)
    Layout(f)
end

----------------------------------------------------------------------
--  认领暴雪气泡
----------------------------------------------------------------------
-- 返回：是否已接管；未接管时第二个值表示「文字还没填，下一帧可能就能接管」
local function Claim(outer)
    if not mod._active or suspended or uiHidden then return false end
    if live[outer] then return true end
    if IsForbiddenSafe(outer) then return false end
    local child, fs = BlizzParts(outer)
    if not (child and fs) then return false end
    local text = ReadText(fs)
    if type(text) ~= "string" then return false, true end
    if not F.IsSecret(text) and text == "" then return false, true end

    local f = Acquire()
    f.outer, f.child, f.src, f.srcText = outer, child, fs, text
    f.cr, f.cg, f.cb = ReadColor(fs)
    f.anim:Stop()
    f._fadingOut = false
    f.text:SetText(text)
    -- 先以 0 透明度显示再排版：隐藏框体上的字形尺寸不准
    f:SetAlpha(0)
    f:Show()
    Layout(f)
    if not AnchorTo(f, child) then
        Release(f)
        return false
    end
    SetBlizzAlpha(child, 0)
    live[outer] = f
    f._acc = 0
    f:SetScript("OnUpdate", BubbleOnUpdate)
    PlayFade(f, 0, 1, Clamp(mod:GetDB().fadeIn, 0, 1, 0.15), false)
    return true
end

-- 引擎收起气泡：把我们的框定在当前位置原地渐隐，并把原版样式交还给这个会被复用的框
local function Detach(outer, instant)
    local f = live[outer]
    if not f then return end
    live[outer] = nil
    SetBlizzAlpha(f.child, 1)
    f:SetScript("OnUpdate", nil)
    local x, y = f:GetCenter()
    local dur = instant and 0 or Clamp(mod:GetDB().fadeOut, 0, 3, 0.8)
    if dur <= 0.01 or not (x and y) or F.IsSecret(x) or F.IsSecret(y) then
        Release(f)
        return
    end
    f:ClearAllPoints()
    f:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", x, y)
    local a = F.PlainNumber(f:GetAlpha(), 1)
    if f.anim:IsPlaying() and not f._fadingOut then
        -- 还在淡入：基础透明度仍是 0，按动画进度估算当前可见度
        local prog = f.fade.GetSmoothProgress and f.fade:GetSmoothProgress()
        a = F.PlainNumber(prog, 1)
        if a < 0.2 then a = 0.2 end
    end
    PlayFade(f, a, 0, dur * a, true)
end

local RunRetries   -- forward

local function QueueRetry(outer)
    pendingRetry[outer] = 3
    if not retryQueued then
        retryQueued = true
        C_Timer.After(0, RunRetries)
    end
end

function RunRetries()
    retryQueued = false
    local again = false
    for outer, left in pairs(pendingRetry) do
        local claimed, notReady = false, false
        if mod._active and not suspended and BlizzShown(outer) then
            claimed, notReady = Claim(outer)
        end
        if claimed or not notReady or left <= 1 then
            pendingRetry[outer] = nil
            if not claimed then SetBlizzAlpha(childOf[outer], 1) end
        else
            pendingRetry[outer] = left - 1
            again = true
        end
    end
    if again and not retryQueued then
        retryQueued = true
        C_Timer.After(0, RunRetries)
    end
end

local function OnBlizzShow(outer)
    if not mod._active or suspended or uiHidden then return end
    local claimed, notReady = Claim(outer)
    if not claimed and notReady then
        -- 文字下一帧才到：先把原版气泡藏住，免得闪一下暴雪大气泡
        SetBlizzAlpha(childOf[outer], 0)
        QueueRetry(outer)
    end
end

local function OnBlizzHide(outer)
    if pendingRetry[outer] then
        pendingRetry[outer] = nil
        SetBlizzAlpha(childOf[outer], 1)
    end
    Detach(outer, false)
end

local _hookOuter
local function RawHook()
    _hookOuter:HookScript("OnShow", OnBlizzShow)
    _hookOuter:HookScript("OnHide", OnBlizzHide)
end

local function HookOuter(outer)
    if hooked[outer] then return end
    -- 先标记再挂：同一个框绝不能叠两份钩子；挂不上的框我们本来也读不了、改不了
    hooked[outer] = true
    _hookOuter = outer
    pcall(RawHook)
    _hookOuter = nil
end

local function ScanBubbles()
    scanQueued = false
    if not mod._active or suspended or uiHidden then return end
    local api = _G.C_ChatBubbles
    if not (api and api.GetAllChatBubbles) then return end
    local ok, list = pcall(api.GetAllChatBubbles)   -- 不带 includeForbidden：受保护气泡碰不得
    if not ok or type(list) ~= "table" then return end
    for i = 1, #list do
        local outer = list[i]
        if outer then
            HookOuter(outer)
            if not live[outer] and not pendingRetry[outer] and BlizzShown(outer) then
                OnBlizzShow(outer)
            end
        end
    end
end

local function QueueScan()
    ScanBubbles()
    -- 引擎可能晚一帧才建出新气泡框：下一帧再扫一次（同帧多条消息合并为一次）
    if not scanQueued then
        scanQueued = true
        C_Timer.After(0, ScanBubbles)
    end
end

local function ReleaseAll()
    for outer in pairs(pendingRetry) do
        pendingRetry[outer] = nil
        SetBlizzAlpha(childOf[outer], 1)
    end
    for outer in pairs(live) do
        Detach(outer, true)
    end
    for f in pairs(fading) do
        Release(f)
    end
end

local function RestyleAll()
    for _, f in pairs(live) do
        Layout(f)
    end
end

----------------------------------------------------------------------
--  暴雪气泡开关：启用期间保持打开，停用 / 登出时还原成接管前的值
----------------------------------------------------------------------
local function GetCVarSafe(name)
    local cv = _G.C_CVar
    if not (cv and cv.GetCVar) then return nil end
    local ok, v = pcall(cv.GetCVar, name)
    if ok and type(v) == "string" then return v end
    return nil
end

local function SetCVarSafe(name, value)
    local cv = _G.C_CVar
    if cv and cv.SetCVar then pcall(cv.SetCVar, name, value) end
end

local function HoldCVar(name, want)
    local cur = GetCVarSafe(name)
    if cur == nil then return end
    if want then
        if cur ~= "1" then
            if heldCVars[name] == nil then heldCVars[name] = cur end
            SetCVarSafe(name, "1")
        end
    elseif heldCVars[name] ~= nil then
        SetCVarSafe(name, heldCVars[name])
        heldCVars[name] = nil
    end
end

local function ApplyCVars()
    if not mod._active then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        -- EUI 在战斗中让位时也把 CVar 交还推迟到脱战；晚它一拍再接手，免得被它还原成关闭
        F.RunOutOfCombat("chatBubblesCVars", function() C_Timer.After(0.3, ApplyCVars) end)
        return
    end
    HoldCVar("chatBubbles", true)
    HoldCVar("chatBubblesParty", mod:GetDB().partyBubbles ~= false)
end

local function RestoreCVars(immediate)
    if next(heldCVars) == nil then return end
    if not immediate and _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("chatBubblesCVars", function()
            if not mod._active then RestoreCVars(true) end
        end)
        return
    end
    for name, prev in pairs(heldCVars) do
        SetCVarSafe(name, prev)
        heldCVars[name] = nil
    end
end

----------------------------------------------------------------------
--  让 EUI 的气泡皮肤在运行时停手：EUI 每次都经 EllesmereUI.ChatBubbles.DB(false) 取设置，
--  这里让该读取在本模块启用期间看到 enabled = false（写入仍落到原表，不改 EUI 存档）。
----------------------------------------------------------------------
local function EUIBubbleAPI()
    local E = _G.EllesmereUI
    local CB = E and E.ChatBubbles
    if type(CB) == "table" and type(CB.DB) == "function" then return CB end
    return nil
end

local function ProxyFor(t)
    local p = proxyOf[t]
    if not p then
        p = setmetatable({}, {
            __index = function(_, k)
                if k == "enabled" then return false end
                return t[k]
            end,
            __newindex = t,
        })
        proxyOf[t] = p
    end
    return p
end

local function WrappedEUIDB(create)
    local t = euiOrigDB(create)
    if create or not mod._active or type(t) ~= "table" then return t end
    return ProxyFor(t)
end

local function SetEUIBubblesSuppressed(on)
    local CB = EUIBubbleAPI()
    if not CB then return end
    if on and not euiOrigDB then
        euiOrigDB = CB.DB
        CB.DB = WrappedEUIDB
    elseif not on and euiOrigDB then
        if CB.DB == WrappedEUIDB then CB.DB = euiOrigDB end
        euiOrigDB = nil
    end
    if type(CB.Refresh) == "function" then pcall(CB.Refresh) end
end

----------------------------------------------------------------------
--  副本内原生气泡字号缩放（通过全局 ChatBubbleFont 对象生效）：
--    • 副本内气泡框体受暴雪保护（IsForbidden），插件不能改框体但可以改全局字体对象 ChatBubbleFont；
--      原生气泡渲染在 WorldFrame（缩放 1.0）而非 UIParent（2K 屏常为 0.71/0.53），
--      加上黑体字库字身饱满，原生 13~16 号字在副本里会显得比野外气泡与姓名板大近一倍。
--    • 绝不直接改共享 FontFamily 成员（避免连带缩小 GameFontNormal 等其它系统字）：
--      优先通过 EUI.GetFontFamily 给 ChatBubbleFont 绑定独立字体族，校验生效后再保留；
--      否则回退到 ChatBubbleFont:SetFont 仅改该对象本身。关闭模块时无损还原快照。
----------------------------------------------------------------------
local origBubbleFontSnap = nil
local bubbleFontApplied = false

local function SnapshotBlizzBubbleFont()
    if origBubbleFontSnap then return end
    local cbf = _G.ChatBubbleFont
    if not (cbf and type(cbf) == "table" and cbf.GetFont) then return end
    local snap = {}
    if cbf.GetFontObject then
        local okO, fo = pcall(cbf.GetFontObject, cbf)
        if okO and fo then snap.fontObject = fo end
    end
    local okF, face, size, flags = pcall(cbf.GetFont, cbf)
    if okF and type(face) == "string" and face ~= "" then
        snap.face = face
        snap.size = F.PlainNumber(size, 13) or 13
        snap.flags = F.PlainString(flags, "") or ""
    end
    if cbf.GetTextColor then
        local okC, r, g, b, a = pcall(cbf.GetTextColor, cbf)
        if okC and F.PlainNumber(r, nil) then
            snap.color = { r, F.PlainNumber(g, 1) or 1, F.PlainNumber(b, 1) or 1, F.PlainNumber(a, 1) or 1 }
        end
    end
    if cbf.GetShadowColor then
        local okS, sr, sg, sb, sa = pcall(cbf.GetShadowColor, cbf)
        if okS and F.PlainNumber(sr, nil) then
            snap.shadowColor = { sr, F.PlainNumber(sg, 0) or 0, F.PlainNumber(sb, 0) or 0, F.PlainNumber(sa, 1) or 1 }
        end
    end
    if cbf.GetShadowOffset then
        local okOff, sx, sy = pcall(cbf.GetShadowOffset, cbf)
        if okOff and F.PlainNumber(sx, nil) then
            snap.shadowOffset = { sx, F.PlainNumber(sy, 0) or 0 }
        end
    end
    local EUI = _G.EllesmereUI
    if not cbf.SetFontObject and EUI and type(EUI.SnapshotFontObject) == "function" then
        local okE, es = pcall(EUI.SnapshotFontObject, cbf)
        if okE and es then snap.euiSnap = es end
    end
    origBubbleFontSnap = snap
end

local function RestoreBubbleFontAttrs(cbf, snap)
    if not (cbf and snap) then return end
    if snap.color and cbf.SetTextColor then
        pcall(cbf.SetTextColor, cbf, snap.color[1], snap.color[2], snap.color[3], snap.color[4])
    end
    if snap.shadowColor and cbf.SetShadowColor then
        pcall(cbf.SetShadowColor, cbf, snap.shadowColor[1], snap.shadowColor[2], snap.shadowColor[3], snap.shadowColor[4])
    end
    if snap.shadowOffset and cbf.SetShadowOffset then
        pcall(cbf.SetShadowOffset, cbf, snap.shadowOffset[1], snap.shadowOffset[2])
    end
end

local function RestoreInstanceBubbleFont()
    if not (bubbleFontApplied and origBubbleFontSnap) then return end
    local cbf = _G.ChatBubbleFont
    if not (cbf and type(cbf) == "table") then return end
    bubbleFontApplied = false
    local EUI = _G.EllesmereUI
    if origBubbleFontSnap.euiSnap and EUI and type(EUI.RestoreFontObject) == "function" then
        pcall(EUI.RestoreFontObject, cbf, origBubbleFontSnap.euiSnap)
    elseif origBubbleFontSnap.fontObject and cbf.SetFontObject then
        pcall(cbf.SetFontObject, cbf, origBubbleFontSnap.fontObject)
        RestoreBubbleFontAttrs(cbf, origBubbleFontSnap)
    elseif origBubbleFontSnap.face and origBubbleFontSnap.size and cbf.SetFont then
        pcall(cbf.SetFont, cbf, origBubbleFontSnap.face, origBubbleFontSnap.size, origBubbleFontSnap.flags or "")
        RestoreBubbleFontAttrs(cbf, origBubbleFontSnap)
    end
end

local function ApplyInstanceBubbleFont()
    local db = mod:GetDB()
    if not mod._active or db.scaleInstanceBubble == false then
        RestoreInstanceBubbleFont()
        return
    end
    local cbf = _G.ChatBubbleFont
    if not (cbf and type(cbf) == "table" and cbf.SetFont) then return end
    SnapshotBlizzBubbleFont()

    local baseSize = Clamp(db.fontSize, 10, 22, 14)
    local uiScale = _G.UIParent and F.PlainNumber(_G.UIParent:GetEffectiveScale(), 1) or 1
    if uiScale < 0.35 or uiScale > 1.8 then uiScale = 1 end
    local factor = Clamp(db.instanceBubbleScale, 0.60, 1.30, 0.90)
    local targetSize = Clamp(math_floor(baseSize * uiScale * factor + 0.5), 7, 20, 10)

    local face = (origBubbleFontSnap and origBubbleFontSnap.face) or F.Theme.GetFont()
    local flags = (origBubbleFontSnap and origBubbleFontSnap.flags) or ""
    local applied = false
    local EUI = _G.EllesmereUI

    if cbf.SetFontObject and EUI and type(EUI.GetFontFamily) == "function" then
        local okF, fam = pcall(EUI.GetFontFamily, face, targetSize, flags, flags == "")
        if okF and fam then
            local okS = pcall(cbf.SetFontObject, cbf, fam)
            if okS then
                local okG, _, gotSize = pcall(cbf.GetFont, cbf)
                local gs = okG and F.PlainNumber(gotSize, nil) or nil
                if gs and math_abs(gs - targetSize) <= 0.5 then
                    RestoreBubbleFontAttrs(cbf, origBubbleFontSnap)
                    applied = true
                end
            end
        end
    end

    if not applied then
        if not cbf.SetFontObject and EUI and type(EUI.SetFontObjectFace) == "function" then
            pcall(EUI.SetFontObjectFace, cbf, nil, targetSize, nil, nil)
        else
            pcall(cbf.SetFont, cbf, face, targetSize, flags)
            RestoreBubbleFontAttrs(cbf, origBubbleFontSnap)
        end
    end
    bubbleFontApplied = true
end

----------------------------------------------------------------------
--  生命周期
----------------------------------------------------------------------
local BUBBLE_EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_MONSTER_SAY", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_EMOTE",
    "CHAT_MSG_MONSTER_PARTY", "CHAT_MSG_MONSTER_WHISPER",
}

local function UpdateSuspended()
    local inInst, iType = false, nil
    if _G.IsInInstance then inInst, iType = _G.IsInInstance() end
    local was = suspended
    suspended = (inInst == true) and iType ~= "none"
    if suspended and not was then ReleaseAll() end
end

local uiHooked = false
local function HookUIParentVisibility()
    if uiHooked or not _G.UIParent then return end
    uiHooked = true
    _G.UIParent:HookScript("OnHide", function()
        uiHidden = true
        if mod._active then ReleaseAll() end
    end)
    _G.UIParent:HookScript("OnShow", function()
        uiHidden = false
        if mod._active and not suspended then QueueScan() end
    end)
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v2RoundedPretty then
        db.v2RoundedPretty = true
        if db.bgAlpha == 0.70 then db.bgAlpha = 0.84 end
        db.cornerRadius = db.cornerRadius or 8
    end
    HookUIParentVisibility()
    uiHidden = _G.UIParent and not _G.UIParent:IsShown() or false
    SetEUIBubblesSuppressed(true)
    ApplyCVars()
    ApplyInstanceBubbleFont()
    UpdateSuspended()

    for _, ev in pairs(BUBBLE_EVENTS) do
        self:RegisterEvent(ev, QueueScan)
    end
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        UpdateSuspended()
        ApplyInstanceBubbleFont()
        if not suspended then QueueScan() end
    end)
    self:RegisterEvent("UI_SCALE_CHANGED", ApplyInstanceBubbleFont)
    self:RegisterEvent("DISPLAY_SIZE_CHANGED", ApplyInstanceBubbleFont)
    -- 过图前交还所有原版样式：之后这些框可能被重新归类为受保护，届时就改不回来了
    self:RegisterEvent("PLAYER_LEAVING_WORLD", ReleaseAll)
    self:RegisterEvent("PLAYER_LOGOUT", function()
        ReleaseAll()
        RestoreCVars(true)
    end)
    QueueScan()
end

function mod:OnDisable()
    ReleaseAll()
    RestoreInstanceBubbleFont()
    RestoreCVars(false)
    SetEUIBubblesSuppressed(false)
end

function mod:OnThemeChanged()
    RestyleAll()
    ApplyInstanceBubbleFont()
end

----------------------------------------------------------------------
--  设置面板
----------------------------------------------------------------------
function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "沿用频道颜色",
        tooltip = "开启：说话白色、大喊红色、NPC 与表情保持游戏原本的颜色。关闭：全部白字。",
        getValue = function() return db.followColor ~= false end,
        setValue = function(v) db.followColor = v == true; RestyleAll() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "气泡字号",
        tooltip = "默认 14：比 EUI 旧皮肤的 12 号小框大，比暴雪原版气泡小。副本内原生气泡也会随之联动缩放。",
        min = 11, max = 20, step = 1,
        getValue = function() return Clamp(db.fontSize, 10, 22, 14) end,
        setValue = function(v) db.fontSize = math_floor(v + 0.5); RestyleAll(); ApplyInstanceBubbleFont() end,
    }, {
        type = "slider",
        text = "气泡最大宽度",
        tooltip = "超过此宽度自动换行，长喊话不会横穿半个屏幕。",
        min = 180, max = 420, step = 10,
        getValue = function() return Clamp(db.maxWidth, 160, 480, 300) end,
        setValue = function(v) db.maxWidth = math_floor(v + 0.5); RestyleAll() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "底色浓度",
        tooltip = "PrettyTooltip 圆角气泡的黑曜石底色不透明度，越大越好读，越小越通透。",
        min = 0.40, max = 0.95, step = 0.05,
        getValue = function() return Clamp(db.bgAlpha, 0.40, 0.95, 0.84) end,
        setValue = function(v) db.bgAlpha = v; RestyleAll() end,
    }, {
        type = "slider",
        text = "圆角半径",
        tooltip = "现代 MMO 聊天气泡圆角弧度（默认 8px，拖动实时生效）。",
        min = 4, max = 12, step = 1,
        getValue = function() return Clamp(db.cornerRadius, 4, 12, 8) end,
        setValue = function(v) db.cornerRadius = math_floor(v + 0.5); RestyleAll() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "消失渐隐时长（秒）",
        tooltip = "气泡停留时长由游戏决定；时间到后在原位置用这段时间慢慢淡出。",
        min = 0.2, max = 2.0, step = 0.1,
        getValue = function() return Clamp(db.fadeOut, 0, 3, 0.8) end,
        setValue = function(v) db.fadeOut = v end,
    }, {
        type = "toggle",
        text = "强制显示队伍频道气泡",
        tooltip = "开启：强制打开队伍 / 副本队伍发言的头顶气泡。关闭：不再强制，沿用你在游戏「界面 → 社交」里的设置（团队频道始终沿用游戏设置）。",
        getValue = function() return db.partyBubbles ~= false end,
        setValue = function(v) db.partyBubbles = v == true; ApplyCVars() end,
    })
    y = y - h
    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "副本内自动缩小原生气泡",
        tooltip = "副本内气泡受暴雪保护无法换肤，且渲染在世界缩放 1.0 上显得过大；开启后自动按界面缩放调整系统 ChatBubbleFont 字号，使其与野外气泡和姓名板协调一致。",
        getValue = function() return db.scaleInstanceBubble ~= false end,
        setValue = function(v) db.scaleInstanceBubble = v == true; ApplyInstanceBubbleFont() end,
    }, {
        type = "slider",
        text = "副本内气泡缩放倍率",
        tooltip = "在自动匹配界面缩放的基础上微调副本内原生气泡大小（默认 0.90，拖动即时生效）。",
        min = 0.60, max = 1.30, step = 0.05,
        disabled = function() return db.scaleInstanceBubble == false end,
        getValue = function() return Clamp(db.instanceBubbleScale, 0.60, 1.30, 0.90) end,
        setValue = function(v) db.instanceBubbleScale = v; ApplyInstanceBubbleFont() end,
    })
    y = y - h
    return y
end
