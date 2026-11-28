-- Minimal WoW 12.x (Interface 16001) Lua 5.1 mock environment for kkowoUI offline tests
local M = {}

local _now = 100.0
local _inCombat = false
local _inInstance = false
local _instanceType = "none"
local _instanceName = "Kalimdor"
local _aurasSecret = false
local _secretAPIs = {}
local _zeroReturnAPIs = {}
local _mouseFoci = {}
local _locale = "zhCN"
local _eventListeners = {}
local _timers = {}
local _tickers = {}
local _cvars = {
    UnitNameFriendlyPlayerName = "0",
    nameplateShowFriends = "0",
    nameplateShowFriendlyPlayers = "0",
    nameplateShowFriendlyNPCs = "0",
    nameplateShowAll = "1",
    showInGameNavigation = "1",
    chatBubbles = "1",
    chatBubblesParty = "1",
    Outline = "2",
    SoftTargetInteract = "1",
    outlineModeShowLootEffectWhenDisabled = "0",
    WorldTextScale = "1",
}
local _loadedAddons = {
    EllesmereUI = true,
    EllesmereUIBlizzardSkin = true,
    EllesmereUIChat = true,
    EllesmereUIMinimap = true,
    EllesmereUINameplates = true,
    EllesmereUIUnitFrames = true,
    EllesmereUIResourceBars = true,
    EllesmereUIActionBars = true,
    EllesmereUICooldownManager = true,
    EllesmereUIDamageMeters = true,
    EllesmereUIBags = true,
    EllesmereUIQoL = true,
    EllesmereUIQuestTracker = true,
    EllesmereUIForeverEssentials = true,
    Polestar = true,
    Polestar_zhCN = true,
    Questie = true,
    BigWigs = true,
    BugSack = true,
    GTFO = true,
    Scales = true,
    Auctionator = true,
    DungeonsForever = true,
    SpellActivationOverlay = true,
}
local _addonEnabled = {}
for k in pairs(_loadedAddons) do _addonEnabled[k] = 2 end
local _lodLoader = nil
local _prints = {}
local _protectedViolations = {}
local _allFrames = {}
local _secretSentinels = setmetatable({}, { __mode = "k" })

local function makeSecretMT(label)
    local function forbid(op)
        return function()
            error("attempt to perform " .. op .. " on secret value (" .. tostring(label or "secret") .. ")", 2)
        end
    end
    return {
        __eq = forbid("comparison (==)"),
        __lt = forbid("comparison (<)"),
        __le = forbid("comparison (<=)"),
        __add = forbid("arithmetic (+)"),
        __sub = forbid("arithmetic (-)"),
        __mul = forbid("arithmetic (*)"),
        __div = forbid("arithmetic (/)"),
        __mod = forbid("arithmetic (%)"),
        __pow = forbid("arithmetic (^)"),
        __unm = forbid("unary minus (-)"),
        __concat = forbid("concatenation (..)"),
        __tostring = function() return "<secret:" .. tostring(label or "value") .. ">" end,
    }
end

local function newSecretSentinel(label)
    local s = setmetatable({}, makeSecretMT(label))
    _secretSentinels[s] = true
    return s
end

local function recordProtected(api, obj)
    if _inCombat then
        _protectedViolations[#_protectedViolations + 1] = api .. " on " .. tostring(obj and obj._name or obj)
    end
end

-- WoW string/math/table/bit extensions
string.trim = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
string.split = function(sep, s, max)
    local out = {}
    if not s then return end
    local pat = "([^" .. sep .. "]+)"
    for part in tostring(s):gmatch(pat) do
        out[#out + 1] = part
        if max and #out >= max then break end
    end
    return unpack(out)
end
function strsplit(sep, s, max) return string.split(sep, s, max) end
function strtrim(s) return string.trim(s) end
function wipe(t)
    if type(t) ~= "table" then return t end
    for k in pairs(t) do t[k] = nil end
    return t
end
table.wipe = wipe
function tinsert(t, a, b)
    if b == nil then table.insert(t, a) else table.insert(t, a, b) end
end
function tremove(t, i) return table.remove(t, i) end
function tContains(t, v)
    if type(t) ~= "table" then return false end
    for _, x in ipairs(t) do if x == v then return true end end
    return false
end
function CopyTable(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = CopyTable(v) end
    return o
end
function Mixin(obj, ...)
    for i = 1, select("#", ...) do
        local m = select(i, ...)
        if type(m) == "table" then
            for k, v in pairs(m) do obj[k] = v end
        end
    end
    return obj
end
bit = bit or {
    band = function(a, b)
        local r, p = 0, 1
        a, b = math.floor(a or 0), math.floor(b or 0)
        while a > 0 and b > 0 do
            if (a % 2 == 1) and (b % 2 == 1) then r = r + p end
            a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
        end
        return r
    end,
    bor = function(a, b)
        local r, p = 0, 1
        a, b = math.floor(a or 0), math.floor(b or 0)
        while a > 0 or b > 0 do
            if (a % 2 == 1) or (b % 2 == 1) then r = r + p end
            a = math.floor(a / 2); b = math.floor(b / 2); p = p * 2
        end
        return r
    end,
    lshift = function(a, n) return math.floor((a or 0) * (2 ^ (n or 0))) end,
    rshift = function(a, n) return math.floor((a or 0) / (2 ^ (n or 0))) end,
}

-- ColorMixin
function CreateColor(r, g, b, a)
    local c = { r = r or 1, g = g or 1, b = b or 1, a = a or 1 }
    function c:SetRGBA(nr, ng, nb, na) self.r, self.g, self.b, self.a = nr, ng, nb, na or 1 end
    function c:GetRGBA() return self.r, self.g, self.b, self.a end
    function c:GetRGB() return self.r, self.g, self.b end
    function c:GenerateHexColor()
        return string.format("%02x%02x%02x%02x",
            math.floor((self.a or 1) * 255), math.floor((self.r or 1) * 255),
            math.floor((self.g or 1) * 255), math.floor((self.b or 1) * 255))
    end
    function c:WrapTextInColorCode(t) return "|c" .. self:GenerateHexColor() .. tostring(t) .. "|r" end
    return c
end

-- Base Region / Frame prototype
local RegionProto = {}
RegionProto.__index = RegionProto

local function newRegion(objType, name, parent)
    local interactiveDefault = (objType == "Button" or objType == "CheckButton" or objType == "EditBox" or objType == "Slider")
    local r = setmetatable({
        _type = objType,
        _name = name,
        _parent = parent,
        _shown = true,
        _alpha = 1,
        _scale = 1,
        _w = 100,
        _h = 24,
        _points = {},
        _strata = "MEDIUM",
        _level = 1,
        _scripts = {},
        _events = {},
        _children = {},
        _regions = {},
        _attrs = {},
        _text = "",
        _font = { "Fonts\\ARKai_T.ttf", 12, "" },
        _drawLayer = "ARTWORK",
        _drawSublevel = 0,
        _mouseClick = interactiveDefault,
        _mouseMotion = interactiveDefault,
        _dragRegistered = false,
        _isMoving = false,
        _forbidden = false,
        _protected = false,
        _messages = {},
        _min = 0, _max = 100, _val = 50,
    }, RegionProto)
    if name and type(name) == "string" and name ~= "" then
        _G[name] = r
    end
    if parent and type(parent) == "table" then
        if objType == "Texture" or objType == "FontString" or objType == "MaskTexture" then
            if parent._regions then parent._regions[#parent._regions + 1] = r end
        else
            if parent._children then parent._children[#parent._children + 1] = r end
        end
    end
    return r
end

function RegionProto:GetObjectType() return self._type end
function RegionProto:IsObjectType(t) return self._type == t end
function RegionProto:GetName() return self._name end
function RegionProto:IsForbidden() return self._forbidden == true end
function RegionProto:IsProtected() return self._protected == true end
function RegionProto:GetParent() return self._parent end
function RegionProto:SetParent(p)
    if self._protected then recordProtected("SetParent", self) end
    self._parent = p
end
function RegionProto:GetChildren()
    if self._forbidden then error("Cannot access forbidden object: GetChildren") end
    return unpack(self._children)
end
function RegionProto:GetNumChildren()
    if self._forbidden then error("Cannot access forbidden object: GetNumChildren") end
    return #self._children
end
function RegionProto:GetRegions()
    if self._forbidden then error("Cannot access forbidden object: GetRegions") end
    return unpack(self._regions)
end
function RegionProto:GetNumRegions()
    if self._forbidden then error("Cannot access forbidden object: GetNumRegions") end
    return #self._regions
end
function RegionProto:Show()
    if self._protected then recordProtected("Show", self) end
    local was = self._shown
    self._shown = true
    if not was and self._scripts.OnShow then self._scripts.OnShow(self) end
end
function RegionProto:Hide()
    if self._protected then recordProtected("Hide", self) end
    local was = self._shown
    self._shown = false
    if was and self._scripts.OnHide then self._scripts.OnHide(self) end
end
function RegionProto:SetShown(v) if v then self:Show() else self:Hide() end end
function RegionProto:IsShown() return self._shown == true end
function RegionProto:IsVisible()
    local cur = self
    local guard = 0
    while cur and guard < 32 do
        guard = guard + 1
        if cur._shown == false then return false end
        local par = cur._parent
        if par == cur then break end
        cur = par
    end
    return true
end
function RegionProto:SetAlpha(a) self._alpha = a or 1 end
function RegionProto:GetAlpha() return self._alpha or 1 end
function RegionProto:GetEffectiveAlpha()
    local acc = 1
    local cur = self
    local guard = 0
    while cur and guard < 32 do
        guard = guard + 1
        acc = acc * (cur._alpha or 1)
        local par = cur._parent
        if par == cur then break end
        cur = par
    end
    return acc
end
function RegionProto:SetScale(s)
    if self._protected then recordProtected("SetScale", self) end
    self._scale = s or 1
end
function RegionProto:GetScale() return self._scale or 1 end
function RegionProto:GetEffectiveScale() return self._scale or 1 end
function RegionProto:SetWidth(w) self._w = w or 0 end
function RegionProto:SetHeight(h) self._h = h or 0 end
function RegionProto:SetSize(w, h) self._w, self._h = w or 0, h or w or 0 end
function RegionProto:GetWidth() return self._w or 0 end
function RegionProto:GetHeight() return self._h or 0 end
function RegionProto:GetSize() return self._w or 0, self._h or 0 end
function RegionProto:GetLeft() return 100 end
function RegionProto:GetRight() return 100 + (self._w or 0) end
function RegionProto:GetTop() return 500 end
function RegionProto:GetBottom() return 500 - (self._h or 0) end
function RegionProto:GetCenter() return 100 + (self._w or 0) / 2, 500 - (self._h or 0) / 2 end
function RegionProto:GetRect() return 100, 500 - (self._h or 0), self._w or 0, self._h or 0 end
function RegionProto:ClearAllPoints()
    if self._protected then recordProtected("ClearAllPoints", self) end
    self._points = {}
end
function RegionProto:SetPoint(pt, rel, rpt, x, y)
    if self._protected then recordProtected("SetPoint", self) end
    if type(rel) == "number" then x, y, rel, rpt = rel, rpt, self._parent, pt end
    self._points[#self._points + 1] = { pt or "CENTER", rel or self._parent, rpt or pt or "CENTER", x or 0, y or 0 }
end
function RegionProto:SetAllPoints(rel)
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", rel or self._parent, "TOPLEFT", 0, 0)
    self:SetPoint("BOTTOMRIGHT", rel or self._parent, "BOTTOMRIGHT", 0, 0)
end
function RegionProto:GetNumPoints() return #self._points end
function RegionProto:GetPoint(i)
    local p = self._points[i or 1]
    if not p then return nil end
    return p[1], p[2], p[3], p[4], p[5]
end
function RegionProto:SetFrameStrata(s) self._strata = s end
function RegionProto:GetFrameStrata() return self._strata end
function RegionProto:SetFrameLevel(l) self._level = l or 1 end
function RegionProto:GetFrameLevel() return self._level or 1 end
function RegionProto:SetFixedFrameStrata() end
function RegionProto:SetFixedFrameLevel() end
function RegionProto:SetToplevel() end
function RegionProto:Raise() end
function RegionProto:Lower() end
function RegionProto:SetClampedToScreen() end
function RegionProto:SetClampRectInsets() end
function RegionProto:SetClipsChildren() end
function RegionProto:EnableMouse(on)
    if self._protected then recordProtected("EnableMouse", self) end
    local v = (on == true)
    self._mouseClick = v
    self._mouseMotion = v
end
function RegionProto:SetMouseClickEnabled(on)
    if self._protected then recordProtected("SetMouseClickEnabled", self) end
    self._mouseClick = (on == true)
end
function RegionProto:SetMouseMotionEnabled(on)
    self._mouseMotion = (on == true)
end
function RegionProto:IsMouseClickEnabled() return self._mouseClick == true end
function RegionProto:IsMouseMotionEnabled() return self._mouseMotion == true end
function RegionProto:EnableMouseWheel() end
function RegionProto:EnableKeyboard() end
function RegionProto:SetPropagateKeyboardInput() end
function RegionProto:SetMovable(v) self._movable = (v == true) end
function RegionProto:IsMovable() return self._movable == true end
function RegionProto:SetResizable() end
function RegionProto:SetUserPlaced() end
function RegionProto:IsUserPlaced() return false end
function RegionProto:IsMouseOver() return false end
function RegionProto:IsMouseEnabled() return self._mouseClick == true or self._mouseMotion == true end
function RegionProto:StartMoving()
    if self._protected then recordProtected("StartMoving", self) end
    self._isMoving = true
end
function RegionProto:StopMovingOrSizing()
    if self._protected then recordProtected("StopMovingOrSizing", self) end
    self._isMoving = false
end
function RegionProto:RegisterForDrag(...)
    local has = select("#", ...) > 0
    self._dragRegistered = has
    if has then
        -- 模拟客户端中 RegisterForDrag 令框体参与鼠标拖拽命中（用于暴露被动容器未设 allowShiftDrag=false 的挡点击隐患）
        self._mouseClick = true
        self._mouseMotion = true
    end
end
function RegionProto:RegisterForClicks() end
function RegionProto:SetHitRectInsets() end
function RegionProto:SetIgnoreParentAlpha() end
function RegionProto:SetIgnoreParentScale() end
function RegionProto:SetAttribute(k, v)
    if self._protected then recordProtected("SetAttribute", self) end
    self._attrs[k] = v
end
function RegionProto:GetAttribute(k) return self._attrs[k] end
function RegionProto:SetID(id) self._id = id end
function RegionProto:GetID() return self._id or 0 end
function RegionProto:SetBackdrop(b) self._backdrop = b end
function RegionProto:GetBackdrop() return self._backdrop end
function RegionProto:SetBackdropColor() end
function RegionProto:SetBackdropBorderColor() end
function RegionProto:SetScript(name, fn) self._scripts[name] = fn end
function RegionProto:GetScript(name) return self._scripts[name] end
function RegionProto:HasScript() return true end
function RegionProto:HookScript(name, fn)
    local prev = self._scripts[name]
    if prev then
        self._scripts[name] = function(...)
            prev(...)
            fn(...)
        end
    else
        self._scripts[name] = fn
    end
end
function RegionProto:RegisterEvent(ev)
    self._events[ev] = true
    _eventListeners[ev] = _eventListeners[ev] or {}
    _eventListeners[ev][self] = true
end
function RegionProto:RegisterUnitEvent(ev) self:RegisterEvent(ev) end
function RegionProto:UnregisterEvent(ev)
    self._events[ev] = nil
    if _eventListeners[ev] then _eventListeners[ev][self] = nil end
end
function RegionProto:UnregisterAllEvents()
    for ev in pairs(self._events) do
        if _eventListeners[ev] then _eventListeners[ev][self] = nil end
    end
    self._events = {}
end
function RegionProto:IsEventRegistered(ev) return self._events[ev] == true end

-- Texture / FontString / StatusBar / Button / EditBox / SMF / Animation methods
function RegionProto:CreateTexture(name, layer, _, sublevel)
    local t = newRegion("Texture", name, self)
    t._drawLayer = layer or "ARTWORK"
    t._drawSublevel = sublevel or 0
    return t
end
function RegionProto:CreateMaskTexture(name) return newRegion("MaskTexture", name, self) end
function RegionProto:CreateFontString(name, layer)
    local fs = newRegion("FontString", name, self)
    fs._drawLayer = layer or "OVERLAY"
    return fs
end
function RegionProto:CreateLine(name) return newRegion("Line", name, self) end
function RegionProto:CreateAnimationGroup()
    local ag = newRegion("AnimationGroup", nil, self)
    ag._playing = false
    function ag:CreateAnimation(kind)
        local a = newRegion("Animation", nil, self)
        function a:SetFromAlpha() end
        function a:SetToAlpha() end
        function a:SetDuration() end
        function a:SetSmoothing() end
        function a:SetOrder() end
        function a:SetOffset() end
        function a:SetScale() end
        function a:SetScaleFrom() end
        function a:SetScaleTo() end
        function a:SetDegrees() end
        function a:SetOrigin() end
        function a:SetStartDelay() end
        function a:SetEndDelay() end
        function a:GetSmoothProgress() return 0.5 end
        return a
    end
    function ag:Play()
        self._playing = true
        if self._scripts.OnPlay then self._scripts.OnPlay(self) end
    end
    function ag:Stop()
        self._playing = false
        if self._scripts.OnStop then self._scripts.OnStop(self) end
    end
    function ag:Restart()
        self:Stop()
        self:Play()
    end
    function ag:Pause() self._playing = false end
    function ag:IsPlaying() return self._playing end
    function ag:SetLooping() end
    function ag:SetToFinalAlpha() end
    function ag:SetAnimationSpeedMultiplier() end
    function ag:GetProgress() return 0.5 end
    return ag
end
function RegionProto:SetTexture(t) self._texture = t; return true end
function RegionProto:GetTexture()
    if self._texture ~= nil then return self._texture end
    if self._colorTex ~= nil then return "Color-mock" end
    return nil
end
function RegionProto:SetAtlas(a) self._atlas = a; return true end
function RegionProto:GetAtlas() return self._atlas end
function RegionProto:SetColorTexture(r, g, b, a) self._colorTex = { r, g, b, a }; self._colorTexture = true end
function RegionProto:SetVertexColor() end
function RegionProto:SetDesaturated() end
function RegionProto:SetBlendMode() end
function RegionProto:SetTexCoord() end
function RegionProto:GetTexCoord() return 0, 1, 0, 1 end
function RegionProto:SetRotation() end
function RegionProto:SetDrawLayer(layer, sub) self._drawLayer = layer or "ARTWORK"; self._drawSublevel = sub or 0 end
function RegionProto:GetDrawLayer() return self._drawLayer or "ARTWORK", self._drawSublevel or 0 end
function RegionProto:SetGradient() end
function RegionProto:SetSnapToPixelGrid() end
function RegionProto:SetTexelSnappingBias() end
function RegionProto:SetBlockingLoadsRequested() end
function RegionProto:SetTextureSliceMargins() end
function RegionProto:SetTextureSliceMode() end
function RegionProto:AddMaskTexture() end
function RegionProto:RemoveMaskTexture() end
function RegionProto:SetFont(p, sz, fl) self._font = { p, sz, fl }; return true end
function RegionProto:GetFont() return self._font[1], self._font[2], self._font[3] end
function RegionProto:SetFontObject() end
function RegionProto:GetFontObject() return nil end
function RegionProto:SetText(t)
    if _secretSentinels[t] then
        self._text = t
    else
        self._text = t ~= nil and tostring(t) or ""
    end
end
function RegionProto:GetText() return self._text or "" end
function RegionProto:SetFormattedText(fmt, ...) self._text = string.format(fmt, ...) end
function RegionProto:SetTextColor() end
function RegionProto:GetTextColor() return 1, 1, 1, 1 end
function RegionProto:SetShadowColor() end
function RegionProto:SetShadowOffset() end
function RegionProto:SetJustifyH() end
function RegionProto:SetJustifyV() end
function RegionProto:SetWordWrap() end
function RegionProto:SetNonSpaceWrap() end
function RegionProto:SetMaxLines() end
function RegionProto:SetSpacing() end
function RegionProto:GetStringWidth() return #(self._text or "") * 6 end
function RegionProto:GetStringHeight() return 14 end
function RegionProto:GetNumLines() return 1 end
function RegionProto:GetFontString()
    if not self._fs then self._fs = self:CreateFontString() end
    return self._fs
end
function RegionProto:SetFontString(fs) self._fs = fs end
function RegionProto:SetNormalTexture() end
function RegionProto:GetNormalTexture() return self._normTex or self:CreateTexture() end
function RegionProto:SetPushedTexture() end
function RegionProto:SetHighlightTexture() end
function RegionProto:SetDisabledTexture() end
function RegionProto:SetPushedTextOffset() end
function RegionProto:SetEnabled(v) self._enabled = v ~= false end
function RegionProto:Enable() self._enabled = true end
function RegionProto:Disable() self._enabled = false end
function RegionProto:IsEnabled() return self._enabled ~= false end
function RegionProto:SetChecked(v) self._checked = v == true end
function RegionProto:GetChecked() return self._checked == true end
function RegionProto:Click()
    if self._scripts.OnClick then self._scripts.OnClick(self, "LeftButton") end
end
function RegionProto:SetStatusBarTexture(t)
    self._sbTex = self:CreateTexture()
    self._sbTex:SetTexture(t)
end
function RegionProto:GetStatusBarTexture()
    if not self._sbTex then self._sbTex = self:CreateTexture() end
    return self._sbTex
end
function RegionProto:SetStatusBarColor() end
function RegionProto:GetStatusBarColor() return 1, 1, 1, 1 end
function RegionProto:SetMinMaxValues(mn, mx) self._min, self._max = mn or 0, mx or 100 end
function RegionProto:GetMinMaxValues() return self._min or 0, self._max or 100 end
function RegionProto:SetValue(v) self._val = v or 0 end
function RegionProto:GetValue() return self._val or 0 end
function RegionProto:SetValueStep() end
function RegionProto:SetObeyStepOnDrag() end
function RegionProto:ClearLines() end
function RegionProto:GetFading() return false end
function RegionProto:SetOrientation() end
function RegionProto:SetReverseFill() end
function RegionProto:SetCooldown() end
function RegionProto:Clear() self._messages = {} end
function RegionProto:SetAutoFocus() end
function RegionProto:SetMultiLine() end
function RegionProto:SetNumeric() end
function RegionProto:SetMaxLetters() end
function RegionProto:HasFocus() return false end
function RegionProto:ClearFocus() end
function RegionProto:SetFocus() end
function RegionProto:HighlightText() end
function RegionProto:Insert(t) self._text = (self._text or "") .. tostring(t) end
function RegionProto:SetScrollChild(ch) self._scrollChild = ch end
function RegionProto:GetScrollChild() return self._scrollChild end
function RegionProto:SetVerticalScroll() end
function RegionProto:GetVerticalScroll() return 0 end
function RegionProto:GetVerticalScrollRange() return 0 end
function RegionProto:SetFading() end
function RegionProto:SetTimeVisible() end
function RegionProto:SetMaxLines() end
function RegionProto:ScrollToBottom() end
function RegionProto:AtBottom() return true end
function RegionProto:GetScrollOffset() return 0 end
function RegionProto:SetScrollOffset() end
function RegionProto:AddMessage(msg)
    self._messages[#self._messages + 1] = tostring(msg or "")
end
function RegionProto:GetNumMessages() return #self._messages end
function RegionProto:GetMessageInfo(i) return self._messages[i] end
function RegionProto:RemoveMessagesByPredicate(pred)
    local kept = {}
    for _, m in ipairs(self._messages) do
        if not pred(m) then kept[#kept + 1] = m end
    end
    self._messages = kept
end
function RegionProto:SetOwner() end
function RegionProto:AddLine() end
function RegionProto:AddDoubleLine() end
function RegionProto:SetHyperlink() end
function RegionProto:SetSpellByID() end
function RegionProto:SetItemByID() end
function RegionProto:SetUnit() end
function RegionProto:NumLines() return 0 end
function RegionProto:SetStartPoint() end
function RegionProto:SetEndPoint() end
function RegionProto:SetThickness() end

function CreateFrame(frameType, name, parent, template)
    local f = newRegion(frameType or "Frame", name, parent or UIParent)
    if type(template) == "string" and template:find("Secure") then
        f._protected = true
    end
    _allFrames[#_allFrames + 1] = f
    return f
end

-- Core global frames
UIParent = newRegion("Frame", "UIParent", nil)
UIParent:SetSize(1920, 1080)
WorldFrame = newRegion("Frame", "WorldFrame", nil)
WorldMapFrame = CreateFrame("Frame", "WorldMapFrame", UIParent)
WorldMapFrame.ScrollContainer = CreateFrame("Frame", nil, WorldMapFrame)
WorldMapFrame.ScrollContainer.Child = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer)
function WorldMapFrame:GetMapID() return 1411 end
function WorldMapFrame:OnMapChanged() end
GameTooltip = CreateFrame("GameTooltip", "GameTooltip", UIParent)
ItemRefTooltip = CreateFrame("GameTooltip", "ItemRefTooltip", UIParent)
ShoppingTooltip1 = CreateFrame("GameTooltip", "ShoppingTooltip1", UIParent)
ShoppingTooltip2 = CreateFrame("GameTooltip", "ShoppingTooltip2", UIParent)
GameMenuFrame = CreateFrame("Frame", "GameMenuFrame", UIParent); GameMenuFrame:Hide()
TaxiFrame = CreateFrame("Frame", "TaxiFrame", UIParent); TaxiFrame:Hide()
TradeFrame = CreateFrame("Frame", "TradeFrame", UIParent); TradeFrame:Hide()
SettingsPanel = CreateFrame("Frame", "SettingsPanel", UIParent); SettingsPanel:Hide()
QuestFrame = CreateFrame("Frame", "QuestFrame", UIParent); QuestFrame:Hide()
CharacterFrame = CreateFrame("Frame", "CharacterFrame", UIParent); CharacterFrame:Hide()
PlayerFrame = CreateFrame("Frame", "PlayerFrame", UIParent)
TargetFrame = CreateFrame("Frame", "TargetFrame", UIParent)
PetFrame = CreateFrame("Frame", "PetFrame", UIParent)
Minimap = CreateFrame("Frame", "Minimap", UIParent)
MinimapCluster = CreateFrame("Frame", "MinimapCluster", UIParent)
BuffFrame = CreateFrame("Frame", "BuffFrame", UIParent)
DebuffFrame = CreateFrame("Frame", "DebuffFrame", UIParent)
MainMenuBar = CreateFrame("Frame", "MainMenuBar", UIParent)
ChatFrame1 = CreateFrame("ScrollingMessageFrame", "ChatFrame1", UIParent)
ChatFrame1:SetID(1)
ChatFrame1EditBox = CreateFrame("EditBox", "ChatFrame1EditBox", UIParent); ChatFrame1EditBox:Hide()
ChatFrame1Tab = CreateFrame("Button", "ChatFrame1Tab", UIParent)
ChatFrame1Tab:SetScript("OnClick", function() FCFDock_SelectWindow(GENERAL_CHAT_DOCK, ChatFrame1) end)
ChatFrame2 = CreateFrame("ScrollingMessageFrame", "ChatFrame2", UIParent)
ChatFrame2:SetID(2)
ChatFrame2.FontStringContainer = CreateFrame("Frame", nil, ChatFrame2)
ChatFrame2.ScrollBar = CreateFrame("Frame", nil, ChatFrame2)
ChatFrame2Tab = CreateFrame("Button", "ChatFrame2Tab", UIParent)
ChatFrame2Tab:SetScript("OnClick", function() FCFDock_SelectWindow(GENERAL_CHAT_DOCK, ChatFrame2) end)
CombatLogQuickButtonFrame_Custom = CreateFrame("Frame", "CombatLogQuickButtonFrame_Custom", ChatFrame2)
GENERAL_CHAT_DOCK = { selected = ChatFrame1, DOCKED_CHAT_FRAMES = { ChatFrame1, ChatFrame2 } }
function FCFDock_GetSelectedWindow(dock) return dock and dock.selected or ChatFrame1 end
function FCFDock_SelectWindow(dock, cf) if dock then dock.selected = cf end end
function FCF_GetCurrentChatFrame() return GENERAL_CHAT_DOCK.selected end
NUM_CHAT_WINDOWS = 10
CHAT_FRAMES = { "ChatFrame1", "ChatFrame2" }
UISpecialFrames = {}
StaticPopupDialogs = {}
function StaticPopup_Show(which) return which end
function StaticPopup_Hide(which) return which end
BackdropTemplateMixin = {}
STANDARD_TEXT_FONT = "Fonts\\ARKai_T.ttf"
DAMAGE_TEXT_FONT = "Fonts\\ARKai_C.ttf"
CombatTextFont = CreateFrame("Frame", "CombatTextFont", UIParent)
HelpTip = { Show = function() end }
function MainMenuMicroButton_ShowAlert() end
function SharedTooltip_SetBackdropStyle() end
function GameTooltip_SetDefaultAnchor() end
function SetRaidTargetIconTexture() end
function GroupLootFrame_OpenNewFrame() end
function GroupLootContainer_AddFrame() end
function GroupLootContainer_Update() end
function ConfirmLootRoll() end
function RollOnLoot() end
local _activeRolls = {}
function GetActiveLootRollIDs()
    local out = {}
    for id in pairs(_activeRolls) do out[#out + 1] = id end
    return out
end
function GetLootRollItemInfo(id)
    local r = _activeRolls[id]
    if not r then return nil end
    if _secretAPIs.GetLootRollItemInfo then
        return r.tex or 135489, newSecretSentinel("rollName"), 1, r.quality or 4,
            newSecretSentinel("rollBoP"), newSecretSentinel("rollNeed"),
            newSecretSentinel("rollGreed"), newSecretSentinel("rollDisenchant")
    end
    return r.tex or 135489, r.name or "测试装备", r.count or 1, r.quality or 4,
        r.bop == true, r.canNeed ~= false, r.canGreed ~= false, r.canDisenchant == true
end
function GetLootRollItemLink(id)
    local r = _activeRolls[id]
    return r and r.link or ("|cffa335ee|Hitem:19019::::::::60:::::::|h[" .. tostring(r and r.name or "测试装备") .. "]|h|r")
end
function GetLootRollTimeLeft(id)
    if _secretAPIs.GetLootRollTimeLeft then
        return newSecretSentinel("rollTimeLeft")
    end
    local r = _activeRolls[id]
    if not r then return 0 end
    local left = (r.endAt or (_now + 60)) - _now
    return left > 0 and math.floor(left * 1000) or 0
end
function EnumerateFrames(prev)
    if prev == nil then return _allFrames[1] end
    for i = 1, #_allFrames do
        if _allFrames[i] == prev then return _allFrames[i + 1] end
    end
    return nil
end
function GetMouseFoci() return _mouseFoci end
function GetMouseFocus() return _mouseFoci[1] end
C_Secrets = {
    ShouldAurasBeSecret = function() return _aurasSecret == true end,
    ShouldSpellAuraBeSecret = function() return _aurasSecret == true end,
}
function ChatEdit_InsertLink() return true end
function SetItemRef() end
function UseAction() end
function ReloadUI() end
ChatFrameUtil = { InsertLink = function() return true end, GetActiveWindow = function() return nil end, ActivateChat = function() end }

-- Globals & Slash commands
SlashCmdList = {}
hash_SlashCmdList = {}
local _origPrint = print
print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    _prints[#_prints + 1] = table.concat(parts, "\t")
end

function hooksecurefunc(a, b, c)
    if type(a) == "string" then
        local fnName, hookFn = a, b
        local orig = _G[fnName]
        _G[fnName] = function(...)
            local r1, r2, r3, r4
            if type(orig) == "function" then r1, r2, r3, r4 = orig(...) end
            hookFn(...)
            return r1, r2, r3, r4
        end
    elseif type(a) == "table" and type(b) == "string" and type(c) == "function" then
        local tbl, fnName, hookFn = a, b, c
        local orig = tbl[fnName]
        tbl[fnName] = function(...)
            local r1, r2, r3, r4
            if type(orig) == "function" then r1, r2, r3, r4 = orig(...) end
            hookFn(...)
            return r1, r2, r3, r4
        end
    end
end

-- Core WoW APIs
function GetTime() return _now end
function GetLocale() return _locale end
function InCombatLockdown() return _inCombat end
function issecretvalue(v) return _secretSentinels[v] == true end
function IsShiftKeyDown() return false end
function IsControlKeyDown() return false end
function IsAltKeyDown() return false end
function GetRealmName() return "TestRealm" end
function UnitName(u)
    if _zeroReturnAPIs.UnitName then return end
    if _secretAPIs.UnitName then return newSecretSentinel("UnitName:" .. tostring(u)) end
    return u == "player" and "TestPlayer" or nil
end
function UnitFullName(u) return u == "player" and "TestPlayer" or nil, "TestRealm" end
function UnitClass(u) return "猎人", "HUNTER", 3 end
function UnitGUID(u) return u == "player" and "Player-95-00000001" or nil end
function UnitLevel(u) return 60 end
function UnitExists(u)
    if _secretAPIs.UnitExists then return newSecretSentinel("UnitExists:" .. tostring(u)) end
    return u == "player"
end
function UnitIsDeadOrGhost() return false end
function UnitAffectingCombat()
    if _secretAPIs.UnitAffectingCombat then return newSecretSentinel("UnitAffectingCombat") end
    return _inCombat
end
function UnitHealth()
    if _secretAPIs.UnitHealth then return newSecretSentinel("UnitHealth") end
    return 5000
end
function UnitHealthMax()
    if _secretAPIs.UnitHealthMax then return newSecretSentinel("UnitHealthMax") end
    return 5000
end
function UnitPower()
    if _secretAPIs.UnitPower then return newSecretSentinel("UnitPower") end
    return 3000
end
function UnitPowerMax()
    if _secretAPIs.UnitPowerMax then return newSecretSentinel("UnitPowerMax") end
    return 3000
end
function UnitPowerType() return 0, "MANA" end
function UnitXP() return 1000 end
function UnitXPMax() return 10000 end
function GetXPExhaustion() return 500 end
function UnitFactionGroup() return "Horde", "部落" end
function UnitReaction() return 5 end
function UnitIsPlayer(u) return u == "player" end
function UnitIsEnemy() return false end
function UnitIsFriend() return true end
function UnitCastingInfo()
    if _zeroReturnAPIs.UnitCastingInfo then return end
    if _secretAPIs.UnitCastingInfo then
        return "稳固射击", "稳固射击", 132213, newSecretSentinel("castStart"), newSecretSentinel("castEnd"), false, newSecretSentinel("castGUID"), false, newSecretSentinel("castSpellID")
    end
    return nil
end
function UnitChannelInfo()
    if _zeroReturnAPIs.UnitChannelInfo then return end
    if _secretAPIs.UnitChannelInfo then
        return "乱射", "乱射", 132222, newSecretSentinel("chanStart"), newSecretSentinel("chanEnd"), false, false, newSecretSentinel("chanSpellID")
    end
    return nil
end
function GetRaidTargetIndex() return nil end
function IsInGroup() return false end
function IsInRaid() return false end
function IsInInstance() return _inInstance == true, _instanceType or "none" end
function GetInstanceInfo() return _instanceName or "Kalimdor", _instanceType or "none", 0, "", 0, 0, false, 1 end
function IsResting() return false end
function GetZoneText() return "杜隆塔尔" end
function GetSubZoneText() return "森金村" end
function GetBuildInfo() return "1.15.8", "60000", "Nov 2026", 16001 end
function GetFramerate() return 120 end
function GetNetStats() return 0, 0, 20, 22 end
function UpdateAddOnMemoryUsage() end
function GetAddOnMemoryUsage() return 1024 end
function GetMoney() return 123456 end
function GetNumGroupMembers() return 0 end
function GetBindingAction() return "" end
function GetBindingKey() return nil end
function SetBinding() return true end
function SaveBindings() end
function GetCurrentBindingSet() return 1 end
function GetActionInfo() return nil end
function GetActionTexture() return nil end
function GetCursorInfo() return nil end
function ClearCursor() end
function PlaySoundFile() return true end
function PlaySound() return true end
function GetCVar(k) return _cvars[k] end
function SetCVar(k, v) _cvars[k] = tostring(v); return true end
function GetCVarBool(k) return _cvars[k] == "1" or _cvars[k] == "true" end
function IsAddOnLoaded(n) return _loadedAddons[n] == true, _loadedAddons[n] == true end
function LoadAddOn(n) return C_AddOns.LoadAddOn(n) end
function EnableAddOn(n) _addonEnabled[n] = 2 end
function DisableAddOn(n) _addonEnabled[n] = 0 end

RAID_CLASS_COLORS = {
    HUNTER = CreateColor(0.67, 0.83, 0.45, 1),
    WARLOCK = CreateColor(0.53, 0.53, 0.93, 1),
    WARRIOR = CreateColor(0.78, 0.61, 0.43, 1),
    MAGE = CreateColor(0.25, 0.78, 0.92, 1),
    PRIEST = CreateColor(1.0, 1.0, 1.0, 1),
    PALADIN = CreateColor(0.96, 0.55, 0.73, 1),
    ROGUE = CreateColor(1.0, 0.96, 0.41, 1),
    SHAMAN = CreateColor(0.0, 0.44, 0.87, 1),
    DRUID = CreateColor(1.0, 0.49, 0.04, 1),
}
C_ClassColor = { GetClassColor = function(tok) return RAID_CLASS_COLORS[tok] end }

C_CVar = {
    GetCVar = GetCVar,
    SetCVar = SetCVar,
    GetCVarBool = GetCVarBool,
    GetCVarDefault = function(k) return _cvars[k] or "0" end,
    GetCVarInfo = function(k) return _cvars[k], _cvars[k], false, false, false, false, false end,
}

C_Timer = {
    After = function(delay, fn)
        _timers[#_timers + 1] = { at = _now + (delay or 0), fn = fn }
    end,
    NewTimer = function(delay, fn)
        local t = { at = _now + (delay or 0), fn = fn, cancelled = false }
        function t:Cancel() self.cancelled = true end
        function t:IsCancelled() return self.cancelled end
        _timers[#_timers + 1] = t
        return t
    end,
    NewTicker = function(interval, fn, iters)
        local tk = { interval = interval or 1, fn = fn, cancelled = false, iters = iters }
        function tk:Cancel() self.cancelled = true end
        function tk:IsCancelled() return self.cancelled end
        _tickers[#_tickers + 1] = tk
        return tk
    end,
}

C_AddOns = {
    IsAddOnLoaded = function(n) return _loadedAddons[n] == true, _loadedAddons[n] == true end,
    DoesAddOnExist = function(n) return _loadedAddons[n] ~= nil or _addonEnabled[n] ~= nil end,
    GetAddOnEnableState = function(n) return _addonEnabled[n] or (_loadedAddons[n] and 2 or 0) end,
    EnableAddOn = function(n) _addonEnabled[n] = 2 end,
    DisableAddOn = function(n) _addonEnabled[n] = 0 end,
    SaveAddOns = function() end,
    GetAddOnMetadata = function(n, field)
        if field == "Version" then return "2.0.0" end
        return nil
    end,
    GetNumAddOns = function() return 0 end,
    LoadAddOn = function(n)
        if _loadedAddons[n] then return true end
        if _lodLoader then
            local ok, err = _lodLoader(n)
            if ok then
                _loadedAddons[n] = true
                return true
            end
            return false, err or "LOAD_FAILED"
        end
        return false, "MISSING"
    end,
}

local _mockNameplates = {}
C_NamePlate = {
    GetNamePlates = function() return _mockNameplates end,
    GetNamePlateForUnit = function(u) return _mockNameplates[u] end,
}
C_QuestLog = {
    GetNumQuestLogEntries = function() return 0 end,
    GetInfo = function() return nil end,
    IsComplete = function() return false end,
    GetTitleForQuestID = function() return nil end,
    GetLogIndexForQuestID = function() return nil end,
    GetQuestObjectives = function() return {} end,
    IsQuestTrivial = function() return false end,
}
C_Map = {
    GetBestMapForUnit = function() return 1411 end,
    GetMapInfo = function(id) return { mapID = id, name = "杜隆塔尔", mapType = 3 } end,
    GetAreaInfo = function() return "杜隆塔尔" end,
    GetUserWaypoint = function() return nil end,
    HasUserWaypoint = function() return false end,
    SetUserWaypoint = function() end,
    ClearUserWaypoint = function() end,
}
C_SuperTrack = {
    IsSuperTrackingAnything = function() return false end,
    IsSuperTrackingUserWaypoint = function() return false end,
    SetSuperTrackedUserWaypoint = function() end,
    GetHighestPrioritySuperTrackingType = function() return nil end,
}
C_Spell = {
    GetSpellInfo = function() return nil end,
    GetSpellName = function() return nil end,
    GetSpellTexture = function() return nil end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0, isEnabled = true } end,
}
C_Item = {
    GetItemInfo = function() return nil end,
    GetItemCount = function() return 0 end,
    IsUsableItem = function() return true end,
}
C_Container = {
    GetContainerNumSlots = function() return 0 end,
    GetContainerItemInfo = function() return nil end,
    GetContainerNumFreeSlots = function() return 16, 0 end,
}
C_ChatInfo = {
    InChatMessagingLockdown = function() return false end,
    SendChatMessage = function() end,
}
C_GossipInfo = {
    GetOptions = function() return {} end,
    GetAvailableQuests = function() return {} end,
    GetActiveQuests = function() return {} end,
}
Enum = {
    UITextureSliceMode = { Stretched = 0, Tiled = 1 },
    SuperTrackingType = { UserWaypoint = 2 },
    ItemQuality = { Poor = 0, Common = 1, Uncommon = 2, Rare = 3, Epic = 4 },
}

-- LibStub + LibSharedMedia-3.0 mock
local _lsmMedia = { font = {}, statusbar = {}, sound = {}, border = {}, background = {} }
local _lsm = {
    Register = function(_, mtype, key, path)
        _lsmMedia[mtype] = _lsmMedia[mtype] or {}
        _lsmMedia[mtype][key] = path
        return true
    end,
    Fetch = function(_, mtype, key)
        return _lsmMedia[mtype] and _lsmMedia[mtype][key] or nil
    end,
    HashTable = function(_, mtype) return _lsmMedia[mtype] or {} end,
    List = function(_, mtype)
        local o = {}
        for k in pairs(_lsmMedia[mtype] or {}) do o[#o + 1] = k end
        return o
    end,
}
function LibStub(name)
    if name == "LibSharedMedia-3.0" then return _lsm end
    return nil
end

-- Mock EllesmereUI with Widgets recorder
local _euiWidgetsCalled = {}
local MockWidgets = {}
local function widgetStub(kind)
    return function(self, parent, ...)
        _euiWidgetsCalled[#_euiWidgetsCalled + 1] = { kind = kind, args = { ... } }
        return CreateFrame("Frame", nil, parent), 32
    end
end
for _, mname in ipairs({ "SectionHeader", "DualRow", "Row", "SingleRow", "Spacer", "Header", "Description", "Note", "Slider", "Toggle", "Dropdown", "Button", "WideButton", "WideDualButton", "Divider", "SubHeader" }) do
    MockWidgets[mname] = widgetStub(mname)
end

EllesmereUIDB = {
    shifterEnabled = true,
    shifterNoShift = true,
    worldMapReveal = { enabled = true },
    mapTravel = { enabled = true, transports = true, exits = true, flights = true, instances = false },
    worldMapFade = { dim = true, dimOpacity = 0, dimClickThrough = true },
    zoneLevels = { enabled = false, fishing = true },
    inGameNavigation = { enabled = true },
    merchantBulkBuy = true,
}
EllesmereUINameplatesDB = {
    activeProfile = "Default",
    profiles = {
        Default = {
            raidMarkerSize = 24,
            raidMarkerCoreSize = 24,
            nameRaidMarkerSize = 14,
            nameRaidMarkerEnabled = false,
            cornerRadius = 0,
            cornerRadiusAuras = 0,
        },
    },
}
EllesmereUI = {
    Widgets = MockWidgets,
    BlankRowCfg = function() return { type = "blank" } end,
    RegisterPlugin = function(name, spec) EllesmereUI._plugins[name] = spec end,
    OpenPlugin = function(name) EllesmereUI._lastOpened = name end,
    RefreshPage = function() end,
    RegisterEscapeClose = function() end,
    SetCVar = function(k, v) _cvars[k] = tostring(v); return true end,
    GetAccentColor = function() return 0.86, 0.65, 0.50 end,
    GetPanelColor = function() return 0.06, 0.065, 0.075, 0.86 end,
    GetFont = function() return "Fonts\\ARKai_T.ttf" end,
    _plugins = {},
    _ModuleNS = {
        EllesmereUIChat = { _kkowoFastTab = true, _kkowoFastTabVer = 6 },
        EllesmereUINameplates = {
            plates = {},
            friendlyPlates = {},
            ENP = { db = { profile = EllesmereUINameplatesDB.profiles.Default } },
        },
    },
    _InGameNavigation = { Apply = function() end },
}
Polestar = {
    _kkowoNavOpt = true,
    L = setmetatable({}, { __index = function(_, k) return k end }),
    Compat = { GetMapName = function() return nil end },
    Names = {
        Language = function() return "zhCN" end,
        Localised = function() return true end,
        Native = function() return true end,
        Quest = function() return nil end,
        Item = function() return nil end,
        Npc = function() return nil end,
        Object = function() return nil end,
        Spell = function() return nil end,
        Area = function() return nil end,
        Instance = function() return nil end,
        Get = function() return nil end,
        Cached = function() return nil end,
    },
    GuideTexts = {
        PackText = function(_, s) return s end,
        Prepare = function() end,
        PrepareSteps = function() end,
        DropSteps = function() end,
        Refresh = function() return false end,
    },
    Codex = { Npc = function(id) return { id = id, subName = "Auctioneer" } end },
    Fire = function() end,
}
PolestarDB = { settings = { gear = { enabled = false }, nav = { mapPlan = true } } }
BugGrabberDB = { session = 1, errors = {} }
BugGrabber = {
    GetDB = function() return BugGrabberDB.errors end,
    GetSessionId = function() return BugGrabberDB.session end,
}
GTFOLocal = {}
BugSack = {
    L = {
        ["All bugs"] = "全部错误", ["Auto popup"] = "自动弹出",
        ["Current session"] = "本次会话", ["Font size"] = "字体大小",
        ["Minimap icon"] = "小地图图标", ["Mute"] = "静音",
        ["Send"] = "发送", ["Small"] = "小", ["Sound"] = "声音", ["Today"] = "今天",
    },
}
local _euiLocaleTables = {}
EllesmereUI.RegisterLocale = function(loc)
    _euiLocaleTables[loc] = _euiLocaleTables[loc] or {}
    return _euiLocaleTables[loc]
end

-- Harness control helpers
function M.SetLoDLoader(fn) _lodLoader = fn end
function M.SetAddonLoaded(name, val) _loadedAddons[name] = val; _addonEnabled[name] = val and 2 or 0 end
function M.SetInCombat(v) _inCombat = v == true end
function M.SetInstanceMode(inInst, instType, instName)
    _inInstance = inInst == true
    _instanceType = instType or (inInst and "party" or "none")
    _instanceName = instName or (inInst and "死亡矿井" or "Kalimdor")
end
function M.SetAurasSecret(v) _aurasSecret = v == true end
function M.SetSecretAPIs(map)
    _secretAPIs = {}
    if type(map) == "table" then
        for k, v in pairs(map) do _secretAPIs[k] = v end
    end
end
function M.SetZeroReturnAPIs(map)
    _zeroReturnAPIs = {}
    if type(map) == "table" then
        for k, v in pairs(map) do _zeroReturnAPIs[k] = v end
    end
end
function M.NewSecret(label) return newSecretSentinel(label) end
function M.SetMouseFoci(list) _mouseFoci = type(list) == "table" and list or {} end
function M.SetActiveRolls(map)
    _activeRolls = {}
    if type(map) == "table" then
        for k, v in pairs(map) do _activeRolls[k] = v end
    end
end
function M.ResetScenario()
    _inCombat = false
    _inInstance = false
    _instanceType = "none"
    _instanceName = "Kalimdor"
    _aurasSecret = false
    _secretAPIs = {}
    _zeroReturnAPIs = {}
    _mouseFoci = {}
    _activeRolls = {}
    _protectedViolations = {}
end
function M.GetProtectedViolations() return _protectedViolations end
function M.ClearProtectedViolations() _protectedViolations = {} end
function M.GetPrints() return _prints end
function M.ClearPrints() _prints = {} end
function M.GetWidgetsCalled() return _euiWidgetsCalled end
function M.ClearWidgetsCalled() _euiWidgetsCalled = {} end
function M.SetMockNameplates(list) _mockNameplates = list end
function M.CreateForbiddenPlate()
    local f = CreateFrame("Frame", nil, WorldFrame)
    f._forbidden = true
    return f
end
function M.TickOnUpdates(dt)
    dt = dt or 0.1
    for i = 1, #_allFrames do
        local f = _allFrames[i]
        if f and f._scripts and f._scripts.OnUpdate and f:IsVisible() then
            f._scripts.OnUpdate(f, dt)
        end
    end
end
function M.StepTime(totalDt, steps)
    steps = steps or 1
    local sub = (totalDt or 0.1) / steps
    for _ = 1, steps do
        M.AdvanceTime(sub)
        M.TickOnUpdates(sub)
    end
end
function M.GetActiveOnUpdates()
    local out = {}
    for i = 1, #_allFrames do
        local f = _allFrames[i]
        if f and f._scripts and f._scripts.OnUpdate and f:IsVisible() then
            out[#out + 1] = f._name or ("<anon:" .. tostring(f._type) .. ">")
        end
    end
    return out
end
function M.GetActiveTickers()
    local out = {}
    for i = 1, #_tickers do
        if not _tickers[i].cancelled then out[#out + 1] = _tickers[i] end
    end
    return out
end
function M.GetPendingTimers()
    local out = {}
    for i = 1, #_timers do
        if not _timers[i].cancelled then out[#out + 1] = _timers[i] end
    end
    return out
end
function M.FireEvent(ev, ...)
    local listeners = _eventListeners[ev]
    if not listeners then return end
    local snap = {}
    for frame in pairs(listeners) do snap[#snap + 1] = frame end
    for _, frame in ipairs(snap) do
        if frame._events[ev] and frame._scripts.OnEvent then
            frame._scripts.OnEvent(frame, ev, ...)
        end
    end
end
function M.AdvanceTime(dt)
    _now = _now + (dt or 0.1)
    local ran = true
    local guard = 0
    while ran and guard < 20 do
        ran = false
        guard = guard + 1
        local due = {}
        local keep = {}
        for _, t in ipairs(_timers) do
            if not t.cancelled then
                if t.at <= _now then due[#due + 1] = t else keep[#keep + 1] = t end
            end
        end
        _timers = keep
        for _, t in ipairs(due) do
            ran = true
            t.fn()
        end
    end
end
function M.RunTickersOnce()
    for _, tk in ipairs(_tickers) do
        if not tk.cancelled then tk.fn(tk) end
    end
end
function M.RunSlash(cmd, arg)
    local key = cmd:upper()
    if hash_SlashCmdList[key] then
        return hash_SlashCmdList[key](arg or "")
    end
    for k, fn in pairs(SlashCmdList) do
        for i = 1, 8 do
            local s = _G["SLASH_" .. k .. tostring(i)]
            if s and s:lower() == cmd:lower() then
                return fn(arg or "")
            end
        end
    end
    error("Unknown slash command: " .. tostring(cmd))
end

return M
