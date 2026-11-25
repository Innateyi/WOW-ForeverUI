----------------------------------------------------------------------
--  KkowoUI — Modules/LootToast.lua
--  现代 MMO 悬浮拾取与收益微播报（配合极速静默拾取，彻底告别掉落闪窗与翻聊天框）
--    • 物品拾取（按品质着色左竖条 + 图标 + 数量自动合并，任务物品无视品质门槛始终显示）
--    • 金币拾取（自动合并连续拾取收益）
--    • 经验值获取（+XP 柔和紫 / 职业色微条）
--    • 声望提升（翡翠绿阵营声望微条）
--    • 纯事件驱动 + 原生 AnimationGroup 丝滑滑入淡出（零 Lua OnUpdate，极低开销）
--    • 脱战悬停物品卡片可查看完整装备鼠标提示并暂停消失
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, math_floor, math_max, math_min, pcall, tonumber, type = ipairs, math.floor, math.max, math.min, pcall, tonumber, type
local string_format = string.format
local table_remove = table.remove
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("lootToast", {
    title = "现代拾取与收益微播报",
    desc = "屏幕侧边丝滑堆叠展示拾取物品、金币、经验与声望收益（同类自动合并防刷屏），完美配合无闪烁极速静默拾取。",
    group = "utility",
    order = 18,
    defaults = {
        enabled = true,
        euiConflictMode = "auto_yield", -- "auto_yield"（EUI 拾取播报开启时自动让位，零重复）| "takeover"（停用 EUI 拾取播报，由本模块接管）| "both"
        showItems = true,
        showMoney = true,
        showXP = true,
        showRep = true,
        minQuality = 1,       -- 0=含灰装, 1=白装起（默认，任务物品无视此限制）, 2=绿装起
        maxVisible = 5,
        holdSeconds = 3.2,
        width = 236,
        growUp = true,
    },
})

local ICON_COIN = 133784
local ICON_XP   = 134939
local ICON_REP  = 236681

local container = nil
local activeToasts = {}
local spareToasts = {}
local selfLootPatterns = nil

-- 将暴雪本地化格式化模板（如 "你获得了物品：%s。"）转成安全的 Lua 匹配正则
local function GlobalPatternToLua(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    local escaped = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    escaped = escaped:gsub("%%%%%d+%%%$s", "(.+)")
    escaped = escaped:gsub("%%%%%d+%%%$d", "(%%d+)")
    escaped = escaped:gsub("%%%%s", "(.+)")
    escaped = escaped:gsub("%%%%d", "(%%d+)")
    return "^" .. escaped .. "$"
end

local function EnsureSelfLootPatterns()
    if selfLootPatterns then return selfLootPatterns end
    selfLootPatterns = {}
    local keys = {
        "LOOT_ITEM_SELF_MULTIPLE",
        "LOOT_ITEM_SELF",
        "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
        "LOOT_ITEM_PUSHED_SELF",
        "LOOT_ITEM_CREATED_SELF_MULTIPLE",
        "LOOT_ITEM_CREATED_SELF",
    }
    for _, k in ipairs(keys) do
        local pat = GlobalPatternToLua(_G[k])
        if pat then
            selfLootPatterns[#selfLootPatterns + 1] = pat
        end
    end
    return selfLootPatterns
end

local function IsSelfLootMessage(msg)
    for _, pat in ipairs(EnsureSelfLootPatterns()) do
        if msg:match(pat) then
            return true
        end
    end
    -- 兜底中文/英文前缀（排除“XXX获得了...”）
    if msg:find("^你获得了") or msg:find("^你制造了") or msg:find("^You receive") or msg:find("^You create") then
        return true
    end
    return false
end

local function ParseMoneyCopper(msg)
    local total = 0
    local g = msg:match("(%d+)%s*金") or msg:match("(%d+)%s*[Gg]old")
    local s = msg:match("(%d+)%s*银") or msg:match("(%d+)%s*[Ss]ilver")
    local c = msg:match("(%d+)%s*铜") or msg:match("(%d+)%s*[Cc]opper")
    if g then total = total + (tonumber(g) or 0) * 10000 end
    if s then total = total + (tonumber(s) or 0) * 100 end
    if c then total = total + (tonumber(c) or 0) end
    return total
end

local function ParseXPGain(msg)
    local xp = msg:match("(%d+)%s*点经验")
        or msg:match("获得%s*(%d+)%s*经验")
        or msg:match("gain%s+(%d+)%s+experience")
    return xp and tonumber(xp) or nil
end

local function ParseRepGain(msg)
    local fac, amt = msg:match("你在(.+)中的声望提高了(%d+)点")
    if not fac then
        fac, amt = msg:match("你对(.+)的声望提高了(%d+)点")
    end
    if not fac then
        fac, amt = msg:match("Your reputation with (.+) has increased by (%d+)")
    end
    if not fac then
        fac, amt = msg:match("Reputation with (.+) increased by (%d+)")
    end
    if fac and amt then
        return fac, tonumber(amt)
    end
    return nil, nil
end

local function EnsureContainer()
    if container then return end
    container = CreateFrame("Frame", "KkowoUI_LootToast", _G.UIParent)
    container:SetSize(236, 150)
    container:SetFrameStrata("MEDIUM")

    F.Mover.Register({
        key = "LootToast",
        label = "现代拾取与收益微播报",
        frame = container,
        order = 32,
        defaultPoint = "RIGHT",
        defaultRelPoint = "RIGHT",
        defaultX = -24,
        defaultY = -170,
        isHidden = function() return not mod._active end,
    })
end

local LayoutToasts
local ReleaseToast

local function AcquireToast()
    local t = table_remove(spareToasts)
    if t then return t end

    t = CreateFrame("Frame", nil, container)
    t:SetSize(236, 26)
    t:EnableMouse(true)
    F.Theme.StylePanel(t, 0.88, 0.78)

    local leftBar = t:CreateTexture(nil, "OVERLAY")
    leftBar:SetWidth(2)
    leftBar:SetPoint("TOPLEFT", t, "TOPLEFT", 1, -1)
    leftBar:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 1, 1)
    t._leftBar = leftBar

    local glow = t:CreateTexture(nil, "BACKGROUND", nil, -4)
    glow:SetWidth(54)
    glow:SetPoint("TOPLEFT", t, "TOPLEFT", 1, -1)
    glow:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 1, 1)
    glow:SetTexture(F.Theme.FLAT_TEX)
    t._glow = glow

    local icon = t:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", t, "LEFT", 6, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t._icon = icon

    local rightFS = t:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(rightFS, 11, "", 0.92, 0.94, 0.96, 1)
    rightFS:SetPoint("RIGHT", t, "RIGHT", -8, 0)
    rightFS:SetJustifyH("RIGHT")
    rightFS:SetWordWrap(false)
    t._right = rightFS

    local nameFS = t:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(nameFS, 11, "", 0.95, 0.95, 0.97, 1)
    nameFS:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    nameFS:SetPoint("RIGHT", rightFS, "LEFT", -6, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    t._name = nameFS

    -- 原生丝滑淡入与淡出动画（零 Lua OnUpdate、零回弹跳动）
    local animIn = t:CreateAnimationGroup()
    local aFadeIn = animIn:CreateAnimation("Alpha")
    aFadeIn:SetFromAlpha(0)
    aFadeIn:SetToAlpha(1)
    aFadeIn:SetDuration(0.18)
    aFadeIn:SetSmoothing("OUT")
    animIn:SetScript("OnFinished", function() t:SetAlpha(1) end)
    t._animIn = animIn

    local animOut = t:CreateAnimationGroup()
    local aFadeOut = animOut:CreateAnimation("Alpha")
    aFadeOut:SetFromAlpha(1)
    aFadeOut:SetToAlpha(0)
    aFadeOut:SetDuration(0.40)
    animOut:SetScript("OnFinished", function()
        ReleaseToast(t)
    end)
    t._animOut = animOut

    t:SetScript("OnEnter", function(self)
        self._hovered = true
        self._animOut:Stop()
        self:SetAlpha(1)
        if self._link and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT", -6, 0)
            pcall(GameTooltip.SetHyperlink, GameTooltip, self._link)
            GameTooltip:Show()
        end
    end)
    t:SetScript("OnLeave", function(self)
        self._hovered = false
        if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(self) then
            GameTooltip:Hide()
        end
        self._gen = (self._gen or 0) + 1
        local myGen = self._gen
        C_Timer.After(1.0, function()
            if self._gen == myGen and not self._hovered and self:IsShown() then
                self._fadingOut = true
                self._animOut:Play()
            end
        end)
    end)

    return t
end

ReleaseToast = function(t, skipLayout)
    if not t then return end
    t._animIn:Stop()
    t._animOut:Stop()
    t:Hide()
    t._key = nil
    t._link = nil
    t._isPreview = nil
    t._amount = 0
    t._fadingOut = false
    t._hovered = false
    t._gen = (t._gen or 0) + 1
    local removed = false
    for i = #activeToasts, 1, -1 do
        if activeToasts[i] == t then
            table_remove(activeToasts, i)
            removed = true
            break
        end
    end
    if not removed then return end
    spareToasts[#spareToasts + 1] = t
    if not skipLayout and LayoutToasts then LayoutToasts() end
end

local function ClearAllToasts()
    if #activeToasts == 0 then return end
    for i = #activeToasts, 1, -1 do
        ReleaseToast(activeToasts[i], true)
    end
    if LayoutToasts then LayoutToasts() end
end

LayoutToasts = function()
    if not container then return end
    local db = mod:GetDB()
    local w = db.width or 236
    local h = 26
    local gap = 4
    local growUp = db.growUp ~= false
    local maxVis = db.maxVisible or 5
    container:SetSize(w, maxVis * (h + gap))

    local hasPreview = false
    for i, t in ipairs(activeToasts) do
        if t._isPreview then hasPreview = true end
        t:SetSize(w, h)
        t:ClearAllPoints()
        local yOff = (i - 1) * (h + gap)
        if growUp then
            t:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, yOff)
        else
            t:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -yOff)
        end
    end
    if hasPreview then
        container:SetFrameStrata("FULLSCREEN_DIALOG")
        container:SetFrameLevel(230)
    else
        container:SetFrameStrata("MEDIUM")
    end
end

local toastGradC1 = _G.CreateColor and _G.CreateColor(0, 0, 0, 1) or nil
local toastGradC2 = _G.CreateColor and _G.CreateColor(0, 0, 0, 0) or nil

local function PaintToastVisual(t, r, g, b)
    t._leftBar:SetColorTexture(r, g, b, 0.95)
    if t._glow.SetGradient and toastGradC1 and toastGradC2 then
        toastGradC1:SetRGBA(r, g, b, 0.22)
        toastGradC2:SetRGBA(r, g, b, 0.00)
        t._glow:SetGradient("HORIZONTAL", toastGradC1, toastGradC2)
    else
        t._glow:SetVertexColor(r, g, b, 0.14)
    end
    if t._fuiBorders then
        for _, ln in ipairs(t._fuiBorders) do
            ln:SetColorTexture(r * 0.40 + 0.15, g * 0.40 + 0.15, b * 0.40 + 0.17, 0.72)
        end
    end
end

local function ArmToastExpire(t, preserveFadeIn)
    local hold = mod:GetDB().holdSeconds or 3.2
    t._gen = (t._gen or 0) + 1
    local myGen = t._gen
    t._fadingOut = false
    t._animOut:Stop()
    if not preserveFadeIn then
        t:SetAlpha(1)
    end
    C_Timer.After(hold, function()
        if t._gen == myGen and not t._hovered and t:IsShown() then
            t._fadingOut = true
            t._animOut:Play()
        end
    end)
end

local function IsEUILootFeedEnabled()
    local euiDB = _G.EllesmereUIDB
    return type(euiDB) == "table" and type(euiDB.lootFeed) == "table" and euiDB.lootFeed.enabled == true
end

local function ApplyEUILootFeedLive()
    local EUI = _G.EllesmereUI
    if EUI and EUI._LootFeed and EUI._LootFeed.Apply then
        pcall(EUI._LootFeed.Apply)
    end
end

local function SyncEUILootFeedPolicy()
    local db = mod:GetDB()
    local euiDB = _G.EllesmereUIDB
    local hasEUI = type(euiDB) == "table" and type(euiDB.lootFeed) == "table"
    if not hasEUI then return end
    local mode = db.euiConflictMode or "auto_yield"
    if mod._active and mode == "takeover" then
        if euiDB.lootFeed.enabled == true then
            if db.savedEUILootFeed == nil then
                db.savedEUILootFeed = true
            end
            euiDB.lootFeed.enabled = false
            ApplyEUILootFeedLive()
        end
    elseif db.savedEUILootFeed ~= nil then
        euiDB.lootFeed.enabled = db.savedEUILootFeed == true
        db.savedEUILootFeed = nil
        ApplyEUILootFeedLive()
    end
end

local function ShouldYieldToEUILootFeed()
    local mode = mod:GetDB().euiConflictMode or "auto_yield"
    return mode == "auto_yield" and IsEUILootFeedEnabled()
end

local LINK_HEX_QUALITY = {
    ["9d9d9d"] = 0,
    ["ffffff"] = 1,
    ["1eff00"] = 2,
    ["0070dd"] = 3,
    ["a335ee"] = 4,
    ["ff8000"] = 5,
    ["e6cc80"] = 6,
    ["00ccff"] = 7,
}

local function FormatItemCount(n) return n > 1 and ("x" .. n) or "x1" end
local function FormatMoneyRight(c) return "+" .. F.FormatMoney(c) end
local function FormatXPRight(n) return "+" .. F.FormatShortNumber(n) .. " XP" end
local function FormatRepRight(n) return "+" .. n .. " 声望" end

local function PushToast(spec)
    if not (mod._active or spec.isPreview) then return end
    if not spec.isPreview and ShouldYieldToEUILootFeed() then return end
    EnsureContainer()
    if container and not container:IsShown() then container:Show() end
    local db = mod:GetDB()
    local maxVis = db.maxVisible or 5

    -- 同类未淡出卡片直接原地合并累加，避免刷屏
    if spec.key then
        for _, existing in ipairs(activeToasts) do
            if existing._key == spec.key and not existing._fadingOut then
                existing._amount = (existing._amount or 0) + (spec.amount or 1)
                if spec.formatRight then
                    existing._right:SetText(spec.formatRight(existing._amount))
                end
                ArmToastExpire(existing, false)
                return
            end
        end
    end

    -- 超出上限时淘汰最旧的一条（批量移除避免 O(N^2) 布局）
    while #activeToasts >= maxVis do
        ReleaseToast(activeToasts[1], true)
    end

    local t = AcquireToast()
    t._key = spec.key
    t._link = spec.link
    t._isPreview = spec.isPreview == true
    t._amount = spec.amount or 1
    t._icon:SetTexture(spec.icon or 134400)
    t._name:SetText(spec.title or "")
    t._name:SetTextColor(spec.tr or 0.95, spec.tg or 0.95, spec.tb or 0.97, 1)
    t._right:SetText(spec.formatRight and spec.formatRight(t._amount) or (spec.rightText or ""))
    t._right:SetTextColor(spec.rr or 0.92, spec.rg or 0.94, spec.rb or 0.96, 1)
    PaintToastVisual(t, spec.r or 0.65, spec.g or 0.68, spec.b or 0.74)

    activeToasts[#activeToasts + 1] = t
    LayoutToasts()
    t._animIn:Stop()
    t:SetAlpha(0)
    t:Show()
    t._animIn:Play()
    ArmToastExpire(t, true)
end

function mod:OnChatLoot(_, text)
    if ShouldYieldToEUILootFeed() then return end
    local db = self:GetDB()
    if db.showItems == false then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" or not IsSelfLootMessage(msg) then return end

    local link = msg:match("(|c%x%x%x%x%x%x%x%x|Hitem:[^|]+|h%[[^%]]+%]|h|r)")
        or msg:match("(|Hitem:[^|]+|h%[[^%]]+%]|h)")
    if not link then return end

    local itemID = tonumber(link:match("item:(%d+)"))
    local count = tonumber(msg:match("|h|r%s*x(%d+)")) or tonumber(msg:match("|h%s*x(%d+)")) or 1
    local getInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    local name, _, quality, _, _, itemType, _, _, _, icon
    if getInfo then
        name, _, quality, _, _, itemType, _, _, _, icon = getInfo(link)
    end
    local classID
    if itemID and _G.C_Item and _G.C_Item.GetItemInfoInstant then
        local _, _, _, _, instIcon, instClassID = _G.C_Item.GetItemInfoInstant(itemID)
        if not icon then icon = instIcon end
        classID = F.PlainNumber(instClassID, nil)
    end
    if not icon and itemID then
        local getIcon = (_G.C_Item and _G.C_Item.GetItemIconByID) or _G.GetItemIcon
        if getIcon then icon = getIcon(itemID) end
    end
    name = F.PlainString(name, nil) or link:match("%[([^%]]+)%]") or "物品"
    quality = F.PlainNumber(quality, nil)
    if quality == nil and itemID and _G.C_Item and _G.C_Item.GetItemQualityByID then
        quality = F.PlainNumber(_G.C_Item.GetItemQualityByID(itemID), nil)
    end
    if quality == nil then
        local hex = link:match("^|c%x%x(%x%x%x%x%x%x)")
        quality = (hex and LINK_HEX_QUALITY[hex:lower()]) or 1
    end
    itemType = F.PlainString(itemType, "")
    local questClass = _G.Enum and _G.Enum.ItemClass and _G.Enum.ItemClass.Questitem or 12
    local isQuest = (classID == questClass) or (itemType == "任务" or itemType == "Quest")

    if not isQuest and quality < (db.minQuality or 1) then
        return
    end

    local r, g, b = 0.86, 0.88, 0.92
    local getQualColor = (_G.C_Item and _G.C_Item.GetItemQualityColor) or _G.GetItemQualityColor
    if isQuest then
        r, g, b = 0.98, 0.84, 0.34
    elseif getQualColor then
        local qr, qg, qb = getQualColor(quality)
        if qr and qg and qb then r, g, b = qr, qg, qb end
    end

    PushToast({
        key = itemID and ("item:" .. itemID) or ("item:" .. name),
        link = link,
        icon = icon or 134400,
        title = name,
        amount = count,
        r = r, g = g, b = b,
        tr = r, tg = g, tb = b,
        rr = 0.96, rg = 0.96, rb = 0.98,
        formatRight = FormatItemCount,
    })
end

function mod:OnChatMoney(_, text)
    if ShouldYieldToEUILootFeed() then return end
    if self:GetDB().showMoney == false then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" then return end
    local copper = ParseMoneyCopper(msg)
    if copper <= 0 then return end

    PushToast({
        key = "money",
        icon = ICON_COIN,
        title = "拾取金币",
        amount = copper,
        r = 0.96, g = 0.80, b = 0.30,
        tr = 0.96, tg = 0.88, tb = 0.64,
        rr = 1, rg = 1, rb = 1,
        formatRight = FormatMoneyRight,
    })
end

function mod:OnChatXP(_, text)
    if ShouldYieldToEUILootFeed() then return end
    if self:GetDB().showXP == false then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" then return end
    local xp = ParseXPGain(msg)
    if not xp or xp <= 0 then return end

    PushToast({
        key = "xp",
        icon = ICON_XP,
        title = "经验值",
        amount = xp,
        r = 0.74, g = 0.56, b = 0.96,
        tr = 0.86, tg = 0.78, tb = 0.98,
        rr = 0.86, rg = 0.74, rb = 1.00,
        formatRight = FormatXPRight,
    })
end

function mod:OnChatRep(_, text)
    if ShouldYieldToEUILootFeed() then return end
    if self:GetDB().showRep == false then return end
    local msg = F.PlainString(text, nil)
    if not msg or msg == "" then return end
    local fac, amt = ParseRepGain(msg)
    if not (fac and amt and amt > 0) then return end

    PushToast({
        key = "rep:" .. fac,
        icon = ICON_REP,
        title = fac,
        amount = amt,
        r = 0.34, g = 0.84, b = 0.62,
        tr = 0.74, tg = 0.96, tb = 0.84,
        rr = 0.42, rg = 0.92, rb = 0.68,
        formatRight = FormatRepRight,
    })
end

function mod:ShowPreview()
    EnsureContainer()
    PushToast({
        isPreview = true,
        key = "preview_item",
        icon = 135489,
        title = "异种蝎卵（任务）",
        amount = 1,
        r = 0.98, g = 0.84, b = 0.34,
        tr = 0.98, tg = 0.84, tb = 0.34,
        formatRight = FormatItemCount,
    })
    PushToast({
        isPreview = true,
        key = "preview_money",
        icon = ICON_COIN,
        title = "拾取金币",
        amount = 1485,
        r = 0.96, g = 0.80, b = 0.30,
        tr = 0.96, tg = 0.88, tb = 0.64,
        formatRight = FormatMoneyRight,
    })
    PushToast({
        isPreview = true,
        key = "preview_xp",
        icon = ICON_XP,
        title = "经验值",
        amount = 340,
        r = 0.74, g = 0.56, b = 0.96,
        tr = 0.86, tg = 0.78, tb = 0.98,
        formatRight = FormatXPRight,
    })
end

function mod:OnEnable()
    EnsureContainer()
    if container then container:Show() end
    SyncEUILootFeedPolicy()
    self:RegisterEvent("CHAT_MSG_LOOT", self.OnChatLoot)
    self:RegisterEvent("CHAT_MSG_MONEY", self.OnChatMoney)
    self:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN", self.OnChatXP)
    self:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE", self.OnChatRep)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        ClearAllToasts()
        SyncEUILootFeedPolicy()
    end)
end

function mod:OnDisable()
    ClearAllToasts()
    SyncEUILootFeedPolicy()
    if container then container:Hide() end
end

function mod:OnThemeChanged()
    local function restyle(list)
        for _, t in ipairs(list) do
            F.Theme.StylePanel(t, 0.88, 0.78)
            F.Theme.ApplyFont(t._name, 11, "")
            F.Theme.ApplyFont(t._right, 11, "")
        end
    end
    restyle(activeToasts)
    restyle(spareToasts)
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "与 EUI 拾取播报防重复策略",
        tooltip = "检测到 EUI 内置拾取播报已开启时，默认自动让位避免屏幕上同时出现两条拾取/经验提示；也可切换为由 KkowoUI 统一接管。",
        values = {
            auto_yield = "自动让位给 EUI 拾取播报（默认，零重复）",
            takeover   = "停用 EUI 播报，改用本模块黑曜石卡片",
            both       = "两者同时显示",
        },
        order = { "auto_yield", "takeover", "both" },
        getValue = function() return db.euiConflictMode or "auto_yield" end,
        setValue = function(v)
            db.euiConflictMode = v
            ClearAllToasts()
            SyncEUILootFeedPolicy()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "物品最低播报品质",
        tooltip = "任务物品不受品质过滤限制，始终会播报提醒。",
        values = { [0] = "全部物品（含灰装）", [1] = "白色普通起（推荐）", [2] = "绿色优秀起" },
        order = { 0, 1, 2 },
        getValue = function() return db.minQuality or 1 end,
        setValue = function(v) db.minQuality = v end,
    }, blank)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "播报拾取物品",
        getValue = function() return db.showItems ~= false end,
        setValue = function(v) db.showItems = v == true end,
    }, {
        type = "toggle",
        text = "播报拾取金币",
        getValue = function() return db.showMoney ~= false end,
        setValue = function(v) db.showMoney = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "播报击杀/探索经验 (+XP)",
        getValue = function() return db.showXP ~= false end,
        setValue = function(v) db.showXP = v == true end,
    }, {
        type = "toggle",
        text = "播报声望提升",
        getValue = function() return db.showRep ~= false end,
        setValue = function(v) db.showRep = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "停留秒数",
        min = 1.5, max = 6.0, step = 0.5,
        getValue = function() return db.holdSeconds or 3.2 end,
        setValue = function(v) db.holdSeconds = v end,
    }, {
        type = "toggle",
        text = "向上堆叠（关闭为向下）",
        getValue = function() return db.growUp ~= false end,
        setValue = function(v) db.growUp = v == true; LayoutToasts() end,
    })
    y = y - h

    _, h = W:WideButton(parent, "预览拾取与收益微播报", y, function() self:ShowPreview() end)
    y = y - h
    return y
end
