----------------------------------------------------------------------
--  kkowoUI — Core/Init.lua
--  基础命名空间、12.x 保密值防护、脱战队列、节流与通用工具
----------------------------------------------------------------------
local ADDON_NAME, F = ...

local _G = _G
local type, tostring, tonumber = type, tostring, tonumber
local pairs, ipairs, pcall, select = pairs, ipairs, pcall, select

_G.kkowoUI = F
F.NAME = ADDON_NAME
F.VERSION = "2.0.0"
do
    local ca = _G.C_AddOns
    local hasMedia = (ca and ca.DoesAddOnExist and select(2, pcall(ca.DoesAddOnExist, "kkowoUI_Media")) == true)
        or (ca and ca.IsAddOnLoaded and select(2, pcall(ca.IsAddOnLoaded, "kkowoUI_Media")) == true)
    F.MEDIA = hasMedia and "Interface\\AddOns\\kkowoUI_Media\\Media\\"
        or ("Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\")
end
F.PREFIX = "|cffdca77f[kkowoUI]|r "
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

-- UnitCastingInfo/UnitChannelInfo return NO values (not nil) when the unit is
-- idle, so type(UnitCastingInfo(u)) raises "bad argument #1 to 'type' (value
-- expected)". Read into a local first; type() is safe on secret values, == nil is not.
function F.UnitIsCasting(unit, channel)
    local fn = channel and _G.UnitChannelInfo or _G.UnitCastingInfo
    if type(fn) ~= "function" then
        return false
    end
    local ok, name = pcall(fn, unit or "player")
    return ok and type(name) ~= "nil"
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
        smName = "kkowoUI 战伤·优设标题黑",
        path = F.MEDIA .. "Fonts\\YouSheBiaoTiHei.ttf",
    },
    smiley = {
        smName = "kkowoUI 战伤·得意黑",
        path = F.MEDIA .. "Fonts\\SmileySans.ttf",
    },
}

local function ResolveBlizzDefaultDamageFont()
    local cur = _G.DAMAGE_TEXT_FONT
    -- 旧名 ForeverUI 时期写入的字体路径也不能当作暴雪默认字体
    -- 插件文件夹先后叫过 ForeverUI / KkowoUI / kkowoUI，按不区分大小写判断
    local lc = type(cur) == "string" and cur:lower() or ""
    if lc ~= "" and not lc:find("kkowoui", 1, true) and not lc:find("foreverui", 1, true) then
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
        -- 吸收原 YaMedia 的 MerfinMain 状态条材质，EUI / BigWigs / kkowoUI 共用且无需再装独立 YaMedia
        pcall(LSM.Register, LSM, "statusbar", "MerfinMain", F.MEDIA .. "Textures\\MerfinMain.tga")
    end

    local probeFS = nil
    local function IsFontAssetReady(path)
        if type(path) ~= "string" or path == "" then return false end
        if not probeFS and _G.UIParent then
            probeFS = _G.UIParent:CreateFontString(nil, "BACKGROUND")
            probeFS:Hide()
        end
        if not probeFS then return true end
        local ok, applied = pcall(probeFS.SetFont, probeFS, path, 16, "")
        return ok and applied ~= false
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
                and (euiDB.fctFont:lower():find("^smf:kkowoui 战伤·") or euiDB.fctFont:lower():find("^smf:foreverui 战伤·")) then
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
        local sv = _G.kkowoUIDB or _G.KkowoUIDB   -- 改名前的旧存档在 DB.Init 之前还叫 KkowoUIDB
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

----------------------------------------------------------------------
--  登录聊天窗口刷屏精简（零污染：只保留 kkowoUI 与 Bug/报错提醒）
--  • 遵循 12.1 零污染铁律：绝不替换 ChatFrame1.AddMessage 字段，仅使用
--    hooksecurefunc 后置监听 + 官方 RemoveMessagesByPredicate 同步清理
--    Blizzard ChatFrame1 与 EllesmereUIChat 的 ScrollingMessageFrame
--  • 仅在登录窗口期（进入世界后 12 秒内）生效，之后自动解除，绝不拦截
--    玩家正常聊天、系统提示、手动 /polestar /bw /df 等命令输出
--  • 被隐藏的第三方横幅按序保存在内存，随时可输入 /kk loginlog 回看
----------------------------------------------------------------------
do
    local suppressed = {}
    local suppressedSet = {}
    local MAX_LOG = 60
    local WINDOW_SEC = 30
    local active = true
    local enteredAt = nil
    local hookInstalled = false
    local sweeping = false
    local sweepQueued = false

    local KEEP_LINK_PATTERNS = {
        "|hplayer:",
        "|hbnplayer:",
        "|hchannel:",
        "|hclubticket:",
        "|hbuggrabber:",
        "|hitem:",
        "|hspell:",
        "|hquest:",
        "|hachievement:",
    }

    local KEEP_KEYWORDS = {
        "kkowoui",
        "foreverui",
        "buggrabber",
        "bugsack",
        "bug in your soup",
        "there's a bug",
        "lua error",
        "error:",
        "taint",
        "stack",
        "报错",
        "错误",
        "异常",
        "失败",
        "捕获",
        "污染",
        "警告",
    }

    local ADDON_BANNER_KEYWORDS = {
        "ellesmereui",
        "ellesmere",
        "polestar",
        "极星",
        "questie",
        "bigwigs",
        "littlewigs",
        "dungeonsforever",
        "无限副本手册",
        "df_cnlocale",
        "auctionator",
        "prettytooltip",
        "ptip",
        "gtfo",
        "spellactivationoverlay",
        "leatrix",
        "blizzmove",
        "scales",
        "waypoint",
        "vamoose",
        "slipstream",
        "[vss]",
        "极速导航",
        "汉化已启用",
        "已过期",
        "out of date",
        "out-of-date",
        "tomtom",
        "weakauras",
        "details!",
        "plater",
        "elvui",
        "163ui",
        "大脚",
        "网易",
        "已加载",
        "加载成功",
        "加载完成",
        " loaded",
        "type /",
        "for options",
        "for help",
        "输入 /",
    }

    local function IsLoginQuietEnabled()
        local sv = _G.kkowoUIDB or _G.KkowoUIDB
        local cb = type(sv) == "table" and type(sv.modules) == "table" and sv.modules.chatBar
        if type(cb) == "table" and cb.loginQuiet == false then
            return false
        end
        return true
    end

    local function StripEscapes(s)
        local out = s:gsub("|c%x%x%x%x%x%x%x%x", "")
        out = out:gsub("|cn[^:]+:", "")
        out = out:gsub("|r", "")
        out = out:gsub("|T.-|t", "")
        out = out:gsub("|A.-|a", "")
        out = out:gsub("^%s+", ""):gsub("%s+$", "")
        return out
    end

    local function RecordSuppressed(clean)
        if clean == "" or suppressedSet[clean] or #suppressed >= MAX_LOG then
            return
        end
        suppressedSet[clean] = true
        suppressed[#suppressed + 1] = clean
    end

    local function ShouldSuppressLine(msg, _, _, _, lineID, _, _, event)
        local plain = F.PlainString(msg, nil)
        if not plain or plain == "" then
            return false
        end
        -- 服务器聊天事件（带数字 chatTypeID 或 CHAT_MSG_* 事件）一律保留
        if type(lineID) == "number" and lineID > 0 then
            return false
        end
        local evPlain = F.PlainString(event, nil)
        if evPlain and evPlain:sub(1, 9) == "CHAT_MSG_" then
            return false
        end

        local rawLower = plain:lower()
        for i = 1, #KEEP_LINK_PATTERNS do
            if rawLower:find(KEEP_LINK_PATTERNS[i], 1, true) then
                return false
            end
        end

        local clean = StripEscapes(plain)
        if clean == "" then
            return false
        end
        local low = clean:lower()
        for i = 1, #KEEP_KEYWORDS do
            if low:find(KEEP_KEYWORDS[i], 1, true) then
                return false
            end
        end

        for i = 1, #ADDON_BANNER_KEYWORDS do
            if low:find(ADDON_BANNER_KEYWORDS[i], 1, true) then
                RecordSuppressed(clean)
                return true
            end
        end
        return false
    end

    local hookedSMF = setmetatable({}, { __mode = "k" })

    local function FindEUIChatSMF(cf)
        local EUI = _G.EllesmereUI
        local cfd = EUI and EUI._chatCFD
        if type(cfd) ~= "function" then
            return nil
        end
        local ok, d = pcall(cfd, cf)
        local bg = ok and type(d) == "table" and d.bg
        if not (bg and bg.GetChildren) then
            return nil
        end
        local children = { bg:GetChildren() }
        for i = 1, #children do
            local ch = children[i]
            if ch and ch.GetObjectType and ch:GetObjectType() == "ScrollingMessageFrame"
                and ch.RemoveMessagesByPredicate then
                return ch
            end
        end
        return nil
    end

    local OnChatAddMessage

    local function EnsureSMFHook(smf)
        if smf and not hookedSMF[smf] and _G.hooksecurefunc then
            hookedSMF[smf] = true
            _G.hooksecurefunc(smf, "AddMessage", OnChatAddMessage)
        end
    end

    local function SweepNow()
        sweepQueued = false
        if sweeping or not active or not IsLoginQuietEnabled() then
            return
        end
        if enteredAt and (GetTime() - enteredAt) > WINDOW_SEC then
            active = false
            return
        end
        sweeping = true
        local cf = _G.ChatFrame1
        if cf and cf.RemoveMessagesByPredicate then
            pcall(cf.RemoveMessagesByPredicate, cf, ShouldSuppressLine)
            local smf = FindEUIChatSMF(cf)
            if smf then
                EnsureSMFHook(smf)
                pcall(smf.RemoveMessagesByPredicate, smf, ShouldSuppressLine)
            end
        end
        sweeping = false
    end

    OnChatAddMessage = function()
        if sweeping or not active or not IsLoginQuietEnabled() then
            return
        end
        -- 同步在当帧立即清理，避免第三方横幅先闪现一帧再消失；再补一次 0s 防 EUI 后置镜像慢半拍
        SweepNow()
        if not sweepQueued then
            sweepQueued = true
            C_Timer.After(0, SweepNow)
        end
    end

    local function EnsureHook()
        local cf = _G.ChatFrame1
        if cf and not hookInstalled and _G.hooksecurefunc then
            hookInstalled = true
            _G.hooksecurefunc(cf, "AddMessage", OnChatAddMessage)
        end
        if cf then
            local smf = FindEUIChatSMF(cf)
            if smf then
                EnsureSMFHook(smf)
            end
        end
    end

    EnsureHook()

    function F.SweepLoginChatBanners()
        SweepNow()
    end

    function F.DumpSuppressedLoginMsgs()
        if #suppressed == 0 then
            F.Print("本次登录没有隐藏任何第三方插件刷屏提示。")
            return
        end
        F.Print("本次登录共隐藏 " .. tostring(#suppressed) .. " 条第三方插件提示：")
        for i = 1, #suppressed do
            _G.print("  |cff888888" .. tostring(i) .. ".|r " .. suppressed[i])
        end
    end

    local qf = CreateFrame("Frame")
    qf:RegisterEvent("PLAYER_LOGIN")
    qf:RegisterEvent("PLAYER_ENTERING_WORLD")
    qf:SetScript("OnEvent", function(self, event)
        if not IsLoginQuietEnabled() then
            active = false
            self:UnregisterAllEvents()
            return
        end
        EnsureHook()
        if event == "PLAYER_LOGIN" then
            SweepNow()
        elseif event == "PLAYER_ENTERING_WORLD" then
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
            self:UnregisterEvent("PLAYER_LOGIN")
            enteredAt = GetTime()
            for _, delay in ipairs({ 0.05, 0.4, 1.2, 2.5, 5.0, 9.0, 16.0, 22.0 }) do
                C_Timer.After(delay, SweepNow)
            end
            C_Timer.After(WINDOW_SEC + 0.5, function()
                active = false
            end)
        end
    end)
end
