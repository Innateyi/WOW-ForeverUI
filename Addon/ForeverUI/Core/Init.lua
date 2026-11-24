----------------------------------------------------------------------
--  ForeverUI — Core/Init.lua
--  基础命名空间、12.x 保密值防护、脱战队列、节流与通用工具
----------------------------------------------------------------------
local ADDON_NAME, F = ...

F.NAME = ADDON_NAME
F.VERSION = "1.0.0"
F.MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
F.PREFIX = "|cffdca77f[ForeverUI]|r "

local _G = _G
local type, tostring, tonumber = type, tostring, tonumber
local pairs, ipairs, pcall = pairs, ipairs, pcall
local math_floor, math_abs = math.floor, math.abs
local string_format = string.format
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetTime = GetTime
local C_Timer = C_Timer

local rawIsSecret = _G.issecretvalue

function F.IsSecret(v)
    return rawIsSecret ~= nil and rawIsSecret(v) or false
end

function F.PlainNumber(v, fallback)
    if type(v) ~= "number" or F.IsSecret(v) then
        return fallback
    end
    return v
end

function F.PlainString(v, fallback)
    if type(v) ~= "string" or F.IsSecret(v) then
        return fallback
    end
    return v
end

function F.SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

function F.IsAddOnLoaded(name)
    local fn = (_G.C_AddOns and _G.C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(fn) ~= "function" then
        return false
    end
    local ok, loaded = pcall(fn, name)
    return ok and loaded == true
end

function F.Print(msg)
    _G.print(F.PREFIX .. tostring(msg))
end

local printedOnce = {}
function F.PrintOnce(key, msg)
    if printedOnce[key] then
        return
    end
    printedOnce[key] = true
    F.Print(msg or key)
end

-- 脱战延迟执行队列（同 key 自动覆盖，避免堆积）
local oocQueue = {}
local oocFrame = CreateFrame("Frame")
oocFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
oocFrame:SetScript("OnEvent", function()
    if InCombatLockdown and InCombatLockdown() then
        return
    end
    local snapshot = {}
    for k, fn in pairs(oocQueue) do
        snapshot[k] = fn
        oocQueue[k] = nil
    end
    for _, fn in pairs(snapshot) do
        pcall(fn)
    end
end)

function F.RunOutOfCombat(key, fn)
    if type(fn) ~= "function" then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        oocQueue[key] = fn
    else
        fn()
    end
end

-- 防抖：interval 秒内只执行最后一次（复用回调闭包，避免高频路径重复 GC）
function F.Debounce(interval, fn)
    local pending = false
    local function run()
        pending = false
        fn()
    end
    return function()
        if pending then
            return
        end
        pending = true
        C_Timer.After(interval, run)
    end
end

-- 节流：至多每 interval 秒执行一次
function F.Throttle(interval, fn)
    local last = 0
    return function(...)
        local now = GetTime()
        if now - last < interval then
            return
        end
        last = now
        fn(...)
    end
end

function F.GetPlayerClass()
    local _, classToken = _G.UnitClass("player")
    return classToken or "UNKNOWN"
end

function F.GetCharKey()
    local name, realm = _G.UnitFullName("player")
    name = F.PlainString(name, nil)
    realm = F.PlainString(realm, nil)
    if not realm or realm == "" then
        realm = F.PlainString(_G.GetRealmName and _G.GetRealmName(), nil) or "Unknown"
    end
    return (name and name ~= "" and name or "Unknown") .. "-" .. realm
end

function F.FormatShortNumber(n)
    n = F.PlainNumber(n, 0)
    local absN = math_abs(n)
    if absN >= 1e8 then
        return string_format("%.2f亿", n / 1e8)
    elseif absN >= 1e4 then
        return string_format("%.1f万", n / 1e4)
    elseif absN >= 1e3 then
        return string_format("%.1fk", n / 1e3)
    end
    return tostring(math_floor(n + 0.5))
end

function F.FormatMoney(copper)
    copper = F.PlainNumber(copper, 0)
    if copper <= 0 then
        return "|cffb873330铜|r"
    end
    local g = math_floor(copper / 10000)
    local s = math_floor((copper % 10000) / 100)
    local c = math_floor(copper % 100)
    if g > 0 then
        return string_format("|cffffd100%d金|r |cffc7c7cf%02d银|r", g, s)
    elseif s > 0 then
        return string_format("|cffc7c7cf%d银|r |cffeda55f%02d铜|r", s, c)
    end
    return string_format("|cffeda55f%d铜|r", c)
end

-- 查询 Auctionator 拍卖行参考价（返回单价铜币或 nil）
function F.GetAuctionPrice(itemLinkOrID)
    local api = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
    if not api then
        return nil
    end
    if type(itemLinkOrID) == "string" and api.GetAuctionPriceByItemLink then
        local ok, price = pcall(api.GetAuctionPriceByItemLink, ADDON_NAME, itemLinkOrID)
        if ok and type(price) == "number" and price > 0 then
            return price
        end
    end
    if type(itemLinkOrID) == "number" and api.GetAuctionPriceByItemID then
        local ok, price = pcall(api.GetAuctionPriceByItemID, ADDON_NAME, itemLinkOrID)
        if ok and type(price) == "number" and price > 0 then
            return price
        end
    end
    return nil
end

function F.DeepCopy(src)
    if type(src) ~= "table" then
        return src
    end
    local out = {}
    for k, v in pairs(src) do
        out[k] = F.DeepCopy(v)
    end
    return out
end

function F.MergeDefaults(target, defaults)
    if type(target) ~= "table" then
        target = {}
    end
    for k, v in pairs(defaults) do
        if target[k] == nil then
            target[k] = F.DeepCopy(v)
        elseif type(v) == "table" and type(target[k]) == "table" then
            F.MergeDefaults(target[k], v)
        end
    end
    return target
end

function F.RGBToHex(r, g, b)
    r = math_floor((F.PlainNumber(r, 1)) * 255 + 0.5)
    g = math_floor((F.PlainNumber(g, 1)) * 255 + 0.5)
    b = math_floor((F.PlainNumber(b, 1)) * 255 + 0.5)
    return string_format("%02x%02x%02x", r, g, b)
end

----------------------------------------------------------------------
--  仅修改战斗伤害/治疗浮动数字字体（零影响其他界面字体，支持完整中文防方框）
--  • 必须在文件顶层与 ADDON_LOADED 阶段尽早设置 DAMAGE_TEXT_FONT，
--    并同步写入 EllesmereUIDB.fctFont（EllesmereUI_Startup.lua 启动首帧即生效）
--  • 内置安全探测：若玩家仅 /reload 尚未重启客户端加载新 .ttf，自动保护原生字体不消失
----------------------------------------------------------------------
F.DAMAGE_FONTS = {
    youshe = {
        smName = "ForeverUI 战伤·优设标题黑",
        path = F.MEDIA .. "Fonts\\YouSheBiaoTiHei.ttf",
    },
    smiley = {
        smName = "ForeverUI 战伤·得意黑",
        path = F.MEDIA .. "Fonts\\SmileySans.ttf",
    },
}

local function ResolveBlizzDefaultDamageFont()
    local cur = _G.DAMAGE_TEXT_FONT
    if type(cur) == "string" and cur ~= "" and not cur:find("ForeverUI", 1, true) then
        return cur
    end
    local loc = _G.GetLocale and _G.GetLocale() or ""
    if loc == "zhCN" then
        return "Fonts\\ARKai_C.ttf"
    elseif loc == "zhTW" then
        return "Fonts\\bKAI00M.ttf"
    elseif loc == "koKR" then
        return "Fonts\\2002B.TTF"
    end
    return "Fonts\\FRIZQT__.TTF"
end

F._DEFAULT_DAMAGE_FONT = ResolveBlizzDefaultDamageFont()

do
    local LSM = _G.LibStub and _G.LibStub("LibSharedMedia-3.0", true)
    if LSM and LSM.Register then
        for _, spec in pairs(F.DAMAGE_FONTS) do
            pcall(LSM.Register, LSM, "font", spec.smName, spec.path, 255)
        end
    end

    local probeFS = nil
    local function IsFontAssetReady(path)
        if type(path) ~= "string" or path == "" then return false end
        if not probeFS and _G.UIParent then
            probeFS = _G.UIParent:CreateFontString(nil, "BACKGROUND")
            probeFS:Hide()
        end
        if not probeFS then return true end
        return (pcall(probeFS.SetFont, probeFS, path, 16, "")) == true
    end

    function F.ApplyDamageFont(presetKey, syncEUI)
        local key = presetKey or "youshe"
        local euiDB = _G.EllesmereUIDB
        if key == "default" or key == "off" then
            if F._DEFAULT_DAMAGE_FONT then
                _G.DAMAGE_TEXT_FONT = F._DEFAULT_DAMAGE_FONT
                if _G.CombatTextFont and _G.CombatTextFont.SetFont then
                    pcall(_G.CombatTextFont.SetFont, _G.CombatTextFont, F._DEFAULT_DAMAGE_FONT, 64, "")
                end
            end
            if syncEUI and type(euiDB) == "table" and type(euiDB.fctFont) == "string"
                and euiDB.fctFont:find("^smf:ForeverUI 战伤·") then
                euiDB.fctFont = nil
                euiDB.fctFontPath = nil
                euiDB.fctFontPathFor = nil
            end
            return true, true
        end

        local spec = F.DAMAGE_FONTS[key] or F.DAMAGE_FONTS.youshe
        local smKey = "smf:" .. spec.smName

        -- 先写入 EllesmereUIDB.fctFont，保证下次重登/重启游戏时由 EllesmereUI_Startup.lua 首帧生效
        if syncEUI and type(euiDB) == "table" then
            euiDB.fctFont = smKey
            euiDB.fctFontPath = spec.path
            euiDB.fctFontPathFor = smKey
        end

        -- 探测客户端是否已索引该新 .ttf（新增字体文件需重启游戏一次后才可见）
        if not IsFontAssetReady(spec.path) then
            return false, false
        end

        _G.DAMAGE_TEXT_FONT = spec.path
        if _G.CombatTextFont and _G.CombatTextFont.SetFont then
            pcall(_G.CombatTextFont.SetFont, _G.CombatTextFont, spec.path, 64, "")
        end
        return true, true
    end

    local dmgBoot = CreateFrame("Frame")
    dmgBoot:RegisterEvent("ADDON_LOADED")
    dmgBoot:RegisterEvent("PLAYER_LOGIN")
    dmgBoot:SetScript("OnEvent", function(self, event, name)
        if event == "ADDON_LOADED" and name ~= ADDON_NAME and name ~= "Blizzard_CombatText" then
            return
        end
        local sv = _G.ForeverUIDB
        local mc = type(sv) == "table" and type(sv.modules) == "table" and sv.modules.modernChrome
        local preset = (type(mc) == "table" and mc.damageFont) or "youshe"
        local enabled = (type(mc) ~= "table") or (mc.enabled ~= false)
        if enabled then
            F.ApplyDamageFont(preset, event == "PLAYER_LOGIN" or name == ADDON_NAME)
        end
        if event == "PLAYER_LOGIN" then
            self:UnregisterEvent("PLAYER_LOGIN")
        end
    end)
end
