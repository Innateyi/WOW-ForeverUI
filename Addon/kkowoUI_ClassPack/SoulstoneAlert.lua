----------------------------------------------------------------------
--  kkowoUI — Modules/SoulstoneAlert.lua
--  术士灵魂石到期提醒（适配《魔兽世界：无限》16001 / 12.x 保密值安全）
--    • 核对全 5 阶灵魂石物品 ID（含 60 级最高阶 16896 特效灵魂石）与全阶复活光环：
--        5232 初级(20707) / 16892 次级(20762) / 16893 灵魂石(20763)
--        16895 强效(20764) / 16896 特效(20765)，并动态查询 C_Item.GetItemSpell 兜底
--    • 脱战实时读取队伍光环精确过期时间并按 GUID 追踪（小队转团队不丢失）；
--      战斗中 12.x 光环保密期间沿用已知过期时间戳平滑倒计时，脱战后自动校准
--    • 同步监听玩家施法事件，支持战斗中补绑实时追踪，并持久化跨 /reload 防重复播报
--    • 队友死亡消耗灵魂石时静默清理，绝不误报「已过期」
--    • 符合 kkowoUI 黑曜石玻璃设计风格（常态术士紫 → 预警琥珀 → 紧急珊瑚红呼吸描边）
--    • 内置系统 TTS 中文语音提醒与独立开关，提供完整预览与语音试听（非术士也可测试）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, next, pairs, pcall, tonumber, tostring, type = ipairs, next, pairs, pcall, tonumber, tostring, type
local math_ceil, math_floor, math_max, math_min = math.ceil, math.floor, math.max, math.min
local string_format = string.format
local table_remove, table_sort = table.remove, table.sort
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local time = time
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("soulstoneAlert", {
    title = "灵魂石到期提醒",
    desc = "监控术士绑在队友或自己身上的灵魂石（含 16896 特效灵魂石及全阶），快到期时高亮提醒并支持系统语音播报。",
    group = "combat",
    order = 15,
    defaults = {
        enabled = true,
        warlockOnly = true,
        trackScope = "mine",        -- "mine" = 仅我绑定的灵魂石 | "any" = 队伍内任意术士的灵魂石
        includeSelf = true,         -- 同时追踪绑在自己身上的灵魂石（关闭则仅追踪队友）
        displayMode = "always",     -- "always" = 绑定即显示紧凑计时卡 | "expiring" = 仅快到期时弹出提醒
        warnSeconds = 180,          -- 提前预警秒数（默认 180 秒 = 3 分钟）
        alertOnExpire = true,       -- 自然到期时短暂显示「已过期」提醒
        voiceAlert = true,          -- 语音提醒总开关（系统 TTS）
        voiceSecondAlert = false,   -- 剩余不足 30 秒时再催促一次
        voiceOnExpire = false,      -- 自然到期时也语音播报
        voiceIncludeName = false,   -- 语音播报中念出队友名字
        voiceID = "auto",           -- "auto" = 自动优先游戏/系统中文语音 | "id:<n>" = 指定音色
        voiceRate = 0,              -- 语速（-3 ~ 3，0 为正常语速）
        voiceVolume = 100,          -- 音量（20 ~ 100）
        soundCue = "none",          -- "none" 静音 | "ready" 就位确认(8960) | "raidwarn" 团队警报(8959)
        chatAlert = false,          -- 本地聊天框同步文字提示
        cardWidth = 248,
        growDown = true,
        lastKnownDuration = 1800,   -- 经典/无限服灵魂石默认 30 分钟（自动从真实光环校准）
    },
})

----------------------------------------------------------------------
--  灵魂石数据表（物品 ID 16896 = 60 级最高阶「特效灵魂石」）
----------------------------------------------------------------------
local SOULSTONE_ITEMS = { 16896, 16895, 16893, 16892, 5232 }
local SOULSTONE_ITEM_NAMES = {
    [16896] = "特效灵魂石",
    [16895] = "强效灵魂石",
    [16893] = "灵魂石",
    [16892] = "次级灵魂石",
    [5232]  = "初级灵魂石",
}

local SOULSTONE_BUFF_IDS = { 20765, 20764, 20763, 20762, 20707, 27239, 47883, 95750 }
local SOULSTONE_BUFF_ID_SET = {
    [20765] = true, -- 特效灵魂石复活 (16896)
    [20764] = true, -- 强效灵魂石复活 (16895)
    [20763] = true, -- 灵魂石复活 (16893)
    [20762] = true, -- 次级灵魂石复活 (16892)
    [20707] = true, -- 初级/统一灵魂石复活 (5232)
    [27239] = true, -- 极效灵魂石复活（兼容）
    [47883] = true, -- 恶魔灵魂石复活（兼容）
    [95750] = true, -- 灵魂石复活（兼容）
}

-- 预构建常量表：保密探测 / 默认图标 / 全阶名称解析都在高频路径上，避免每次调用新建临时表
local PRIMARY_BUFF_IDS = { 20765, 20707 }                 -- 特效 / 初级灵魂石复活
local RANK_BUFF_IDS = { 20765, 20764, 20763, 20762, 20707 } -- 经典 5 阶灵魂石复活

local SOUND_KITS = {
    none     = nil,
    ready    = 8960,
    raidwarn = 8959,
}

local FALLBACK_ICON = 136210 -- Spell_Shadow_SoulGem
local CARD_HEIGHT = 44
local CARD_GAP = 6
local MAX_CARDS = 4
local EXPIRE_HOLD_SEC = 8.0

-- 颜色主题（与 kkowoUI Theme.COLORS 严格一致）
local COLOR_WARLOCK = { 0.58, 0.51, 0.79 } -- #9482C9 术士紫（常态）
local COLOR_WARN    = F.Theme.COLORS.warn   -- #F0BF57 暖琥珀（即将到期）
local COLOR_DANGER  = F.Theme.COLORS.danger -- #E05263 珊瑚红（紧急 / 已过期）

-- 预构建队伍单位 O(1) 过滤表，避免 40 人团本高频 UNIT_AURA 扫到姓名板/宠物
local GROUP_UNIT_SET = { player = true }
for i = 1, 4 do GROUP_UNIT_SET["party" .. i] = true end
for i = 1, 40 do GROUP_UNIT_SET["raid" .. i] = true end

local soulstoneNames = {}
local soulstoneNameSet = {}
local metadataResolved = false
local itemDataRequested = false

local container = nil
local activeCards = {}
local spareCards = {}
local tracked = {}          -- [guid] = entry
local previewEntries = {}   -- 独立预览队列，绝不污染真实追踪数据
local dirtyUnits = {}
local dirtyFlushPending = false
local ticker = nil
local pendingCast = nil
local myCastTargetGUID = nil
local lastVoiceAt = 0
local lastVoiceKind = nil
local bagInfoCache = { at = 0, data = nil }
local eventsBound = false
local scanGeneration = 0

local gradC1 = _G.CreateColor and _G.CreateColor(0, 0, 0, 1) or nil
local gradC2 = _G.CreateColor and _G.CreateColor(0, 0, 0, 0) or nil

-- 前向声明（严格满足 check.js 零先用后声明规则）
local ScanGroup
local RenderAll
local EnsureTicker
local StopTicker
local DismissPreview

----------------------------------------------------------------------
--  12.x 安全基础工具
----------------------------------------------------------------------
local function PlainBool(v)
    if F.IsSecret(v) or type(v) ~= "boolean" then
        return nil
    end
    return v
end

local function StripRealm(name)
    if type(name) ~= "string" then return nil end
    local short = name:match("^([^%-]+)")
    return (short and short ~= "") and short or name
end

local function FormatClock(sec)
    sec = F.PlainNumber(sec, 0)
    sec = (sec > 0) and math_ceil(sec) or 0
    local m = math_floor(sec / 60)
    local s = sec % 60
    if m >= 60 then
        local h = math_floor(m / 60)
        return string_format("%d:%02d:%02d", h, m % 60, s)
    end
    return string_format("%02d:%02d", m, s)
end

local function GetClassRGB(classToken)
    if type(classToken) == "string" and classToken ~= "" then
        if _G.C_ClassColor and _G.C_ClassColor.GetClassColor then
            local ok, c = pcall(_G.C_ClassColor.GetClassColor, classToken)
            if ok and c and not F.IsSecret(c) then
                local r = F.PlainNumber(c.r, nil)
                local g = F.PlainNumber(c.g, nil)
                local b = F.PlainNumber(c.b, nil)
                if r and g and b then return r, g, b end
            end
        end
        local colors = _G.RAID_CLASS_COLORS
        local c = colors and colors[classToken]
        if c then
            local r = F.PlainNumber(c.r, nil)
            local g = F.PlainNumber(c.g, nil)
            local b = F.PlainNumber(c.b, nil)
            if r and g and b then return r, g, b end
        end
    end
    return 0.94, 0.95, 0.97
end

local function AreAurasSecret()
    local S = _G.C_Secrets
    if not S then return false end
    if S.ShouldAurasBeSecret then
        local ok, sec = pcall(S.ShouldAurasBeSecret)
        if not ok or F.IsSecret(sec) or sec == true then
            return true
        end
    end
    if S.ShouldSpellAuraBeSecret then
        for _, sid in ipairs(PRIMARY_BUFF_IDS) do
            local ok, sec = pcall(S.ShouldSpellAuraBeSecret, sid)
            if not ok or F.IsSecret(sec) or sec == true then
                return true
            end
        end
    end
    return false
end

local function AddSoulstoneName(name)
    name = F.PlainString(name, nil)
    if name and name ~= "" and not soulstoneNameSet[name] then
        soulstoneNameSet[name] = true
        soulstoneNames[#soulstoneNames + 1] = name
    end
end

local function AddSoulstoneSpellID(sid)
    sid = F.PlainNumber(sid, nil)
    if sid and sid > 0 and not SOULSTONE_BUFF_ID_SET[sid] then
        SOULSTONE_BUFF_ID_SET[sid] = true
        SOULSTONE_BUFF_IDS[#SOULSTONE_BUFF_IDS + 1] = sid
    end
end

local function ResolveSoulstoneMetadata(force)
    if metadataResolved and not force then
        return
    end
    AddSoulstoneName("灵魂石复活")
    AddSoulstoneName("Soulstone Resurrection")

    local getSpellName = (_G.C_Spell and _G.C_Spell.GetSpellName) or _G.GetSpellInfo
    if type(getSpellName) == "function" then
        for _, sid in ipairs(RANK_BUFF_IDS) do
            local ok, n = pcall(getSpellName, sid)
            if ok then AddSoulstoneName(n) end
        end
    end

    local getItemSpell = (_G.C_Item and _G.C_Item.GetItemSpell) or _G.GetItemSpell
    local requestLoad = _G.C_Item and _G.C_Item.RequestLoadItemDataByID
    if type(getItemSpell) == "function" then
        for _, itemID in ipairs(SOULSTONE_ITEMS) do
            local ok, sName, sID = pcall(getItemSpell, itemID)
            local gotAny = false
            if ok then
                sName = F.PlainString(sName, nil)
                sID = F.PlainNumber(sID, nil)
                if sName and sName ~= "" then
                    AddSoulstoneName(sName)
                    gotAny = true
                end
                if sID and sID > 0 then
                    AddSoulstoneSpellID(sID)
                    gotAny = true
                end
            end
            -- 物品未缓存时 GetItemSpell 返回空：只请求一次物品数据，到货后由 GET_ITEM_INFO_RECEIVED 强制重解析
            if not gotAny and not itemDataRequested and type(requestLoad) == "function" then
                pcall(requestLoad, itemID)
            end
        end
    end
    itemDataRequested = true
    -- 法术名已按 ID 解析完毕；不再因物品未缓存而在每次施法 / 每个单位上重跑整套查询
    metadataResolved = true
end

local function ResolveDefaultIcon()
    local getSpellTex = _G.C_Spell and _G.C_Spell.GetSpellTexture
    if type(getSpellTex) == "function" then
        for _, sid in ipairs(PRIMARY_BUFF_IDS) do
            local ok, tex = pcall(getSpellTex, sid)
            tex = ok and F.PlainNumber(tex, nil) or nil
            if tex and tex > 0 then return tex end
        end
    end
    local getItemIcon = (_G.C_Item and _G.C_Item.GetItemIconByID) or _G.GetItemIcon
    if type(getItemIcon) == "function" then
        local ok, tex = pcall(getItemIcon, 16896)
        tex = ok and F.PlainNumber(tex, nil) or nil
        if tex and tex > 0 then return tex end
    end
    return FALLBACK_ICON
end

local function IsSoulstoneSpell(spellID)
    spellID = F.PlainNumber(spellID, nil)
    if not spellID or spellID <= 0 then
        return false
    end
    if SOULSTONE_BUFF_ID_SET[spellID] then
        return true
    end
    ResolveSoulstoneMetadata(false)
    if SOULSTONE_BUFF_ID_SET[spellID] then
        return true
    end
    local getSpellName = (_G.C_Spell and _G.C_Spell.GetSpellName) or _G.GetSpellInfo
    if type(getSpellName) == "function" then
        local ok, name = pcall(getSpellName, spellID)
        name = ok and F.PlainString(name, nil) or nil
        if name and soulstoneNameSet[name] then
            AddSoulstoneSpellID(spellID)
            return true
        end
    end
    return false
end

----------------------------------------------------------------------
--  背包灵魂石与冷却状态查询（仅术士角色展示，带 1 秒缓存防高频重复读）
----------------------------------------------------------------------
local function ReadItemCooldown(itemID)
    local fn = (_G.C_Container and _G.C_Container.GetItemCooldown) or _G.GetItemCooldown
    if type(fn) ~= "function" then
        return 0
    end
    local ok, start, dur = pcall(fn, itemID)
    if not ok then return 0 end
    start = F.PlainNumber(start, 0)
    dur = F.PlainNumber(dur, 0)
    -- 忽略 1.5 秒公共冷却
    if start > 0 and dur > 1.5 then
        local rem = (start + dur) - GetTime()
        if rem > 0 then return rem end
    end
    return 0
end

local function GetBagSoulstoneInfo(force)
    if F.GetPlayerClass() ~= "WARLOCK" then
        return nil
    end
    local now = GetTime()
    if not force and bagInfoCache.data and (now - bagInfoCache.at) < 1.0 then
        return bagInfoCache.data
    end
    local getCount = (_G.C_Item and _G.C_Item.GetItemCount) or _G.GetItemCount
    local foundID = nil
    if type(getCount) == "function" then
        for _, itemID in ipairs(SOULSTONE_ITEMS) do
            local ok, cnt = pcall(getCount, itemID, false)
            cnt = ok and F.PlainNumber(cnt, 0) or 0
            if cnt > 0 then
                foundID = itemID
                break
            end
        end
    end
    local cdRem = ReadItemCooldown(foundID or 16896)
    local data = {
        hasStone = foundID ~= nil,
        itemID = foundID,
        itemName = foundID and SOULSTONE_ITEM_NAMES[foundID] or "特效灵魂石",
        cdRemaining = cdRem,
    }
    bagInfoCache.at = now
    bagInfoCache.data = data
    return data
end

----------------------------------------------------------------------
--  系统 TTS 语音提醒 + 音效兜底（兼容 12.x / 无限服 16001）
----------------------------------------------------------------------
local function GetAvailableVoices()
    local out = {}
    local VC = _G.C_VoiceChat
    if not (VC and VC.GetTtsVoices) then
        return out
    end
    local ok, list = pcall(VC.GetTtsVoices)
    if not (ok and type(list) == "table") then
        return out
    end
    for _, v in ipairs(list) do
        if type(v) == "table" then
            local vid = F.PlainNumber(v.voiceID, nil)
            local name = F.PlainString(v.name, nil)
            if vid ~= nil and name and name ~= "" then
                out[#out + 1] = { voiceID = vid, name = name }
            end
        end
    end
    return out
end

local function IsChineseVoiceName(name)
    if type(name) ~= "string" then return false end
    local low = name:lower()
    return low:find("chinese", 1, true) ~= nil
        or low:find("zh%-cn") ~= nil
        or low:find("zh_cn", 1, true) ~= nil
        or low:find("zh%-tw") ~= nil
        or low:find("huihui", 1, true) ~= nil
        or low:find("yaoyao", 1, true) ~= nil
        or low:find("kangkang", 1, true) ~= nil
        or low:find("xiaoxiao", 1, true) ~= nil
        or low:find("yating", 1, true) ~= nil
        or low:find("hanhan", 1, true) ~= nil
        or name:find("中文", 1, true) ~= nil
end

local function ResolveVoiceID(pref)
    local voices = GetAvailableVoices()
    if type(pref) == "string" then
        local explicit = pref:match("^id:(%-?%d+)$")
        if explicit then
            local want = tonumber(explicit)
            if want ~= nil then
                if #voices == 0 then
                    return want
                end
                for _, v in ipairs(voices) do
                    if v.voiceID == want then
                        return want
                    end
                end
            end
        end
    end

    -- 自动模式：优先读游戏无障碍 TTS 已选音色，其次优先中文音色，最后回退 0
    if type(_G.TextToSpeech_GetSelectedVoice) == "function"
        and _G.Enum and _G.Enum.TtsVoiceType and _G.Enum.TtsVoiceType.Standard ~= nil then
        local ok, v = pcall(_G.TextToSpeech_GetSelectedVoice, _G.Enum.TtsVoiceType.Standard)
        if ok and type(v) == "table" then
            local vid = F.PlainNumber(v.voiceID, nil)
            if vid ~= nil then return vid end
        end
    end
    if _G.C_TTSSettings and _G.C_TTSSettings.GetVoiceOptionID
        and _G.Enum and _G.Enum.TtsVoiceType and _G.Enum.TtsVoiceType.Standard ~= nil then
        local ok, vid = pcall(_G.C_TTSSettings.GetVoiceOptionID, _G.Enum.TtsVoiceType.Standard)
        vid = ok and F.PlainNumber(vid, nil) or nil
        if vid ~= nil then return vid end
    end
    local loc = _G.GetLocale and _G.GetLocale() or ""
    if loc == "zhCN" or loc == "zhTW" then
        for _, v in ipairs(voices) do
            if IsChineseVoiceName(v.name) then
                return v.voiceID
            end
        end
    end
    if voices[1] then
        return voices[1].voiceID
    end
    return 0
end

local function SpeakTTS(text, interruptPrev)
    local VC = _G.C_VoiceChat
    if not (VC and VC.SpeakText) then
        return false
    end
    if type(text) ~= "string" or text == "" then
        return false
    end
    local db = mod:GetDB()
    local vid = ResolveVoiceID(db.voiceID)
    local rate = F.PlainNumber(db.voiceRate, 0)
    if rate < -5 then rate = -5 elseif rate > 5 then rate = 5 end
    local vol = F.PlainNumber(db.voiceVolume, 100)
    if vol < 10 then vol = 10 elseif vol > 100 then vol = 100 end

    if interruptPrev and VC.StopSpeakingText then
        pcall(VC.StopSpeakingText)
    end

    -- 兼容旧版带 Enum.VoiceTtsDestination 的客户端与 12.x / 无限服 16001 的 5 参签名
    local dest = _G.Enum and _G.Enum.VoiceTtsDestination and _G.Enum.VoiceTtsDestination.LocalPlayback
    if dest ~= nil then
        local ok = pcall(VC.SpeakText, vid, text, dest, rate, vol)
        return ok
    end
    -- 无限服 (16001) 实测签名：C_VoiceChat.SpeakText(voiceID, text, rate, volume, allowOverlap)
    local ok = pcall(VC.SpeakText, vid, text, rate, vol, false)
    return ok
end

local function StopTTS()
    local VC = _G.C_VoiceChat
    if VC and VC.StopSpeakingText then
        pcall(VC.StopSpeakingText)
    end
end

local function BuildVoiceMessage(kind, targetName)
    local db = mod:GetDB()
    local shortName = db.voiceIncludeName == true and StripRealm(targetName) or nil
    if kind == "urgent" then
        if shortName then
            return shortName .. "的灵魂石即将过期，请立即补绑"
        end
        return "灵魂石剩余不足30秒，请立即补绑"
    elseif kind == "expired" then
        if shortName then
            return shortName .. "的灵魂石已过期，请重新绑定"
        end
        return "灵魂石已过期，请重新绑定"
    end
    if shortName then
        return shortName .. "的灵魂石即将到期，请及时补绑"
    end
    return "灵魂石即将到期，请及时补绑"
end

local function TriggerNotification(kind, entry, isPreview)
    local db = mod:GetDB()
    local now = GetTime()
    local targetName = (entry and entry.name) or "队友"

    -- 1) 辅助提示音效
    local cueKey = db.soundCue or "none"
    local kitID = SOUND_KITS[cueKey]
    if kitID and _G.PlaySound then
        pcall(_G.PlaySound, kitID, "Master")
    end

    -- 2) 系统语音提醒（含独立开关）
    local allowExpiredVoice = (kind ~= "expired") or (isPreview ~= nil) or (db.voiceOnExpire == true)
    local wantVoice = (isPreview == "voice") or (db.voiceAlert ~= false and allowExpiredVoice)
    if wantVoice then
        local throttled = (not isPreview) and (lastVoiceKind == kind) and ((now - lastVoiceAt) < 2.0)
        if not throttled then
            local msg = BuildVoiceMessage(kind, targetName)
            local spoke = SpeakTTS(msg, isPreview ~= nil)
            if spoke then
                lastVoiceAt = now
                lastVoiceKind = kind
            elseif not kitID and _G.PlaySound then
                -- 客户端未启用 TTS 时自动降级为团队警报音，避免静默漏提醒
                pcall(_G.PlaySound, SOUND_KITS.raidwarn, "Master")
            end
        end
    end

    -- 3) 本地聊天框提醒（仅自己可见，默认关闭）
    if not isPreview and db.chatAlert == true then
        local remStr = (entry and entry.expireAt) and FormatClock(math_max(0, entry.expireAt - now)) or "00:00"
        if kind == "expired" then
            F.Print("|cffe05263[灵魂石]|r " .. targetName .. " 身上的灵魂石已过期，请重新绑定。")
        elseif kind == "urgent" then
            F.Print("|cffe05263[灵魂石]|r " .. targetName .. " 身上的灵魂石仅剩 " .. remStr .. "，请立即补绑！")
        else
            F.Print("|cfff0bf57[灵魂石]|r " .. targetName .. " 身上的灵魂石即将到期（剩余 " .. remStr .. "），请及时补绑。")
        end
    end
end

----------------------------------------------------------------------
--  跨 /reload 轻量持久化（保存在 kkowoUICharDB）
----------------------------------------------------------------------
local function SaveTrackedToCharDB()
    if type(F.charDB) ~= "table" then return end
    local now = GetTime()
    local wallNow = time()
    local saved = {}
    local n = 0
    for guid, e in pairs(tracked) do
        if not e.expiredState and e.expireAt and e.expireAt > now + 2 then
            n = n + 1
            saved[guid] = {
                guid = e.guid,
                name = e.name,
                fullName = e.fullName,
                class = e.class,
                role = e.role,
                spellId = e.spellId,
                buffName = e.buffName,
                icon = e.icon,
                duration = e.duration,
                expireEpoch = wallNow + (e.expireAt - now),
                isMine = e.isMine == true,
                isSelf = e.isSelf == true,
                warned = e.warned == true,
                urgentWarned = e.urgentWarned == true,
            }
        end
    end
    F.charDB.soulstoneTracked = (n > 0) and saved or nil
end

local function RestoreTrackedFromCharDB()
    if type(F.charDB) ~= "table" or type(F.charDB.soulstoneTracked) ~= "table" then
        return
    end
    local db = mod:GetDB()
    local now = GetTime()
    local wallNow = time()
    local restoredAny = false
    for guid, s in pairs(F.charDB.soulstoneTracked) do
        if type(s) == "table" and type(s.expireEpoch) == "number" then
            local rem = s.expireEpoch - wallNow
            -- 只恢复仍在有效期内且合理的条目（上限 2 小时防系统时间跳变）
            if rem > 2 and rem <= 7200 then
                local scopeOk = (db.trackScope == "any") or (s.isMine == true)
                local selfOk = (db.includeSelf ~= false) or (s.isSelf ~= true)
                if scopeOk and selfOk then
                    tracked[guid] = {
                        guid = s.guid or guid,
                        unit = nil,
                        name = s.name or "队友",
                        fullName = s.fullName or s.name or "队友",
                        class = s.class,
                        role = s.role,
                        spellId = s.spellId,
                        buffName = s.buffName or "灵魂石复活",
                        icon = s.icon or ResolveDefaultIcon(),
                        duration = F.PlainNumber(s.duration, db.lastKnownDuration or 1800),
                        expireAt = now + rem,
                        auraInstanceID = nil,
                        isMine = s.isMine == true,
                        isSelf = s.isSelf == true,
                        confirmedByAura = false,
                        warned = s.warned == true,
                        urgentWarned = s.urgentWarned == true,
                        expiredState = false,
                        expiredHoldUntil = nil,
                        restoredUntil = now + 4.5,
                        lastSeenAt = now,
                    }
                    if s.isMine == true then
                        myCastTargetGUID = guid
                    end
                    restoredAny = true
                end
            end
        end
    end
    if restoredAny then
        EnsureTicker()
        RenderAll()
    end
end

----------------------------------------------------------------------
--  光环扫描与队伍枚举（全链路 12.x 保密值安全）
----------------------------------------------------------------------
local function ShouldTrackForClass()
    if not mod._active then return false end
    local db = mod:GetDB()
    if db.warlockOnly ~= false and F.GetPlayerClass() ~= "WARLOCK" then
        return false
    end
    return true
end

local function SafeUnitName(unit)
    local fn = (unit == "player" and _G.UnitNameUnmodified) or _G.UnitName
    local ok, name, realm = pcall(fn, unit)
    if not ok then return nil, nil end
    name = F.PlainString(name, nil)
    realm = F.PlainString(realm, nil)
    if not name or name == "" then return nil, nil end
    local EUI = _G.EllesmereUI
    local full
    if EUI and EUI.IS_FOREVER then
        if realm and realm ~= "" then
            if type(EUI.WithSurname) == "function" then
                full = F.PlainString(EUI.WithSurname(name, realm, true), nil)
            end
            if not full or full == "" then
                local suffix = " " .. realm
                if name:sub(-#suffix) == suffix then
                    full = name
                else
                    full = name .. suffix
                end
            end
        else
            full = name
        end
    else
        full = (realm and realm ~= "") and (name .. "-" .. realm) or name
    end
    return name, full
end

local function SafeUnitInfo(unit)
    local okEx, ex = pcall(_G.UnitExists, unit)
    if not okEx or PlainBool(ex) ~= true then return nil end

    local okG, guid = pcall(_G.UnitGUID, unit)
    guid = okG and F.PlainString(guid, nil) or nil
    if not guid or guid == "" then return nil end

    local name, fullName = SafeUnitName(unit)
    local okC, _, classToken = pcall(_G.UnitClass, unit)
    classToken = okC and F.PlainString(classToken, nil) or nil

    local okConn, conn = pcall(_G.UnitIsConnected, unit)
    local connected = okConn and PlainBool(conn)
    if connected == nil then connected = true end

    local okVis, vis = pcall(_G.UnitIsVisible, unit)
    local visible = okVis and PlainBool(vis)
    if visible == nil then visible = true end

    local okDead, dead = pcall(_G.UnitIsDeadOrGhost, unit)
    local isDead = okDead and PlainBool(dead) or false

    local isSelf = (unit == "player")
    if not isSelf and _G.UnitIsUnit then
        local okS, same = pcall(_G.UnitIsUnit, unit, "player")
        if okS and PlainBool(same) == true then
            isSelf = true
        end
    end

    local role = nil
    if _G.UnitGroupRolesAssigned then
        local okR, r = pcall(_G.UnitGroupRolesAssigned, unit)
        r = okR and F.PlainString(r, nil) or nil
        if r == "TANK" or r == "HEALER" or r == "DAMAGER" then
            role = r
        end
    end

    return {
        unit = unit,
        guid = guid,
        name = name or unit,
        fullName = fullName or name or unit,
        class = classToken,
        role = role,
        connected = connected,
        visible = visible,
        dead = isDead,
        isSelf = isSelf,
    }
end

local function CollectGroupUnits()
    local units = {}
    local okR, inRaid = pcall(_G.IsInRaid)
    if okR and PlainBool(inRaid) == true then
        local okN, n = pcall(_G.GetNumGroupMembers)
        n = okN and F.PlainNumber(n, 0) or 0
        for i = 1, math_min(40, n) do
            units[#units + 1] = "raid" .. i
        end
        return units
    end
    units[1] = "player"
    local okG, inGroup = pcall(_G.IsInGroup)
    if okG and PlainBool(inGroup) == true then
        local okN, n = pcall(_G.GetNumSubgroupMembers)
        n = okN and F.PlainNumber(n, 0) or 0
        for i = 1, math_min(4, n) do
            units[#units + 1] = "party" .. i
        end
    end
    return units
end

local function ResolveUnitForGUID(guid, hintUnit)
    if not guid then return nil end
    if type(hintUnit) == "string" then
        local okG, g = pcall(_G.UnitGUID, hintUnit)
        if okG and F.PlainString(g, nil) == guid then
            return hintUnit
        end
    end
    for _, u in ipairs(CollectGroupUnits()) do
        local okG, g = pcall(_G.UnitGUID, u)
        if okG and F.PlainString(g, nil) == guid then
            return u
        end
    end
    return nil
end

local function FindGroupUnitByName(targetName)
    targetName = F.PlainString(targetName, nil)
    if not targetName or targetName == "" then
        -- 拿不到目标名（空串，或 12.x 战斗中的保密值）时不猜：用焦点 / 鼠标指向宏绑石时，
        -- 「当前目标」和「自己」都可能是错的。交给光环扫描（UNIT_AURA / 脱战校准）确认真实绑定对象。
        return nil
    end

    local units = CollectGroupUnits()
    local shortTarget = StripRealm(targetName)
    local fuzzyHit = nil
    local fuzzyCount = 0
    for _, u in ipairs(units) do
        local info = SafeUnitInfo(u)
        if info then
            -- 精确匹配全名（本服成员 fullName == name，跨服成员 fullName == "名字-服务器"），防同名跨服误匹配
            if info.fullName == targetName then
                return info
            end
            if shortTarget and info.name == shortTarget then
                fuzzyHit = info
                fuzzyCount = fuzzyCount + 1
            end
        end
    end
    if fuzzyCount == 1 then
        return fuzzyHit
    end
    return nil
end

-- 查询指定单位上的灵魂石复活 Buff；返回 (auraTableOrNil, isRestrictedOrSecret)
local function FindSoulstoneAura(unit)
    local UA = _G.C_UnitAuras
    if not UA then
        return nil, false
    end
    if AreAurasSecret() then
        return nil, true
    end
    ResolveSoulstoneMetadata(false)

    -- 1) 按已知全阶灵魂石法术 ID 精确查找（最快）
    if UA.GetUnitAuraBySpellID then
        for _, sid in ipairs(SOULSTONE_BUFF_IDS) do
            local ok, aura = pcall(UA.GetUnitAuraBySpellID, unit, sid)
            if not ok or F.IsSecret(aura) then
                return nil, true
            end
            if type(aura) == "table" then
                return aura, false
            end
        end
    end

    -- 2) 按本地化光环名称兜底查找（兼容无限服可能的新法术 ID）
    if UA.GetAuraDataBySpellName then
        for _, sName in ipairs(soulstoneNames) do
            local ok, aura = pcall(UA.GetAuraDataBySpellName, unit, sName, "HELPFUL")
            if not ok or F.IsSecret(aura) then
                return nil, true
            end
            if type(aura) == "table" then
                return aura, false
            end
        end
    end

    return nil, false
end

local function EvaluateAuraOwnership(aura, targetGUID)
    local src = F.PlainString(aura.sourceUnit, nil)
    if src and src ~= "" then
        if src == "player" then
            return true, true
        end
        if _G.UnitIsUnit then
            local ok, same = pcall(_G.UnitIsUnit, src, "player")
            if ok then
                local b = PlainBool(same)
                if b ~= nil then
                    return b, true
                end
            end
        end
        return false, true
    end
    -- sourceUnit 为空（过图/重载/超出距离时可能出现）：回退记忆的施法目标
    local existing = tracked[targetGUID]
    if existing and existing.isMine then
        return true, false
    end
    if myCastTargetGUID and myCastTargetGUID == targetGUID then
        return true, false
    end
    return false, false
end

local function RemoveOtherMineEntries(keepGUID)
    for g, e in pairs(tracked) do
        if g ~= keepGUID and e.isMine then
            tracked[g] = nil
        end
    end
end

local function ProcessUnit(info)
    if not info or not info.guid then return false end
    local db = mod:GetDB()
    local guid = info.guid
    local existing = tracked[guid]

    -- 若关闭了「追踪绑给自己的灵魂石」，直接忽略并清理已有自身记录
    if info.isSelf and db.includeSelf == false then
        if existing then
            tracked[guid] = nil
            return true
        end
        return false
    end

    -- 目标离线或视野外时客户端拿不到光环，仅刷新单位信息，绝不误删倒计时
    if not (info.connected and info.visible) then
        if existing then
            existing.unit = info.unit
            existing.name = info.name
            existing.fullName = info.fullName
            existing.class = info.class or existing.class
            existing.role = info.role or existing.role
        end
        return false
    end

    local aura, restricted = FindSoulstoneAura(info.unit)
    if restricted then
        if existing then
            existing.unit = info.unit
        end
        return false
    end

    local now = GetTime()
    if aura then
        local expTime = F.PlainNumber(aura.expirationTime, nil)
        local dur = F.PlainNumber(aura.duration, nil)
        local sid = F.PlainNumber(aura.spellId, nil)
        local icon = F.PlainNumber(aura.icon, nil)
        local iid = F.PlainNumber(aura.auraInstanceID, nil)
        local bName = F.PlainString(aura.name, nil)
        -- 关键时间字段若是保密值，放弃本帧覆盖
        if expTime == nil or expTime <= 0 then
            return false
        end

        local isMine, srcCertain = EvaluateAuraOwnership(aura, guid)
        if db.trackScope ~= "any" and not isMine then
            -- 若之前记录为非自己的灵魂石（切换为仅追踪自己），或我的灵魂石被其他术士顶掉，均清除旧记录
            if existing and (not existing.isMine or srcCertain) then
                tracked[guid] = nil
                if myCastTargetGUID == guid then myCastTargetGUID = nil end
                return true
            end
            return false
        end

        if dur and dur >= 60 and dur <= 7200 then
            db.lastKnownDuration = dur
        else
            dur = (existing and existing.duration) or db.lastKnownDuration or 1800
        end

        if sid and sid > 0 then
            AddSoulstoneSpellID(sid)
        end

        local isFresh = (not existing)
            or existing.expiredState
            or (expTime > (existing.expireAt or 0) + 30)

        if isMine then
            myCastTargetGUID = guid
            RemoveOtherMineEntries(guid)
        end

        if not existing then
            existing = {}
            tracked[guid] = existing
        end

        existing.guid = guid
        existing.unit = info.unit
        existing.name = info.name
        existing.fullName = info.fullName
        existing.class = info.class or existing.class
        existing.role = info.role or existing.role
        existing.spellId = sid or existing.spellId
        existing.buffName = bName or existing.buffName or "灵魂石复活"
        existing.icon = icon or existing.icon or ResolveDefaultIcon()
        existing.duration = dur
        existing.expireAt = expTime
        existing.auraInstanceID = iid
        existing.isMine = isMine
        existing.isSelf = info.isSelf
        existing.confirmedByAura = true
        existing.restoredUntil = nil
        existing.lastSeenAt = now
        if isFresh then
            existing.warned = false
            existing.urgentWarned = false
            existing.expiredState = false
            existing.expiredHoldUntil = nil
        end
        return true
    else
        -- 确认视野内在线且非保密状态下已无灵魂石光环
        if existing and not existing.expiredState then
            -- 刚施法成功的前 1.5 秒 / 刚重载恢复的前 4.5 秒宽限期，等待服务器同步光环包
            if (not existing.confirmedByAura and (now - (existing.lastSeenAt or 0)) < 1.5)
                or (existing.restoredUntil and now < existing.restoredUntil) then
                return false
            end
            local rem = (existing.expireAt or 0) - now
            -- 队友死亡（使用/待用灵魂石复活）或提前很久被点掉：静默清除，绝不误报过期
            if info.dead or rem > 15 then
                tracked[guid] = nil
                if myCastTargetGUID == guid then myCastTargetGUID = nil end
                return true
            end
            -- 自然倒计时归零消失
            if db.alertOnExpire ~= false then
                existing.expiredState = true
                existing.expiredHoldUntil = now + EXPIRE_HOLD_SEC
                existing.auraInstanceID = nil
                TriggerNotification("expired", existing, nil)
            else
                tracked[guid] = nil
            end
            if myCastTargetGUID == guid then myCastTargetGUID = nil end
            return true
        end
    end
    return false
end

ScanGroup = function()
    if not ShouldTrackForClass() then
        local hadAny = false
        for g in pairs(tracked) do
            tracked[g] = nil
            hadAny = true
        end
        if hadAny then
            SaveTrackedToCharDB()
            RenderAll()
        end
        return
    end
    if AreAurasSecret() then
        return
    end

    local units = CollectGroupUnits()
    local seenGUIDs = {}
    local rosterValid = false
    local changed = false

    for _, u in ipairs(units) do
        local info = SafeUnitInfo(u)
        if info then
            rosterValid = true
            seenGUIDs[info.guid] = true
            if ProcessUnit(info) then
                changed = true
            end
        end
    end

    -- 清理已经离开小队/团队的旧目标（过图首帧 rosterValid 为 false 或刚重载恢复宽限期内不误清）
    if rosterValid then
        local now = GetTime()
        for guid, e in pairs(tracked) do
            if not seenGUIDs[guid] and not (e.restoredUntil and now < e.restoredUntil) then
                tracked[guid] = nil
                if myCastTargetGUID == guid then myCastTargetGUID = nil end
                changed = true
            end
        end
    end

    if changed then
        SaveTrackedToCharDB()
    end
    if next(tracked) ~= nil or #previewEntries > 0 then
        EnsureTicker()
    end
    RenderAll()
end

local function FlushDirtyUnits()
    dirtyFlushPending = false
    if not ShouldTrackForClass() or AreAurasSecret() then
        for k in pairs(dirtyUnits) do dirtyUnits[k] = nil end
        return
    end
    local changed = false
    for unit in pairs(dirtyUnits) do
        dirtyUnits[unit] = nil
        local info = SafeUnitInfo(unit)
        if info and ProcessUnit(info) then
            changed = true
        end
    end
    if changed then
        SaveTrackedToCharDB()
        if next(tracked) ~= nil or #previewEntries > 0 then
            EnsureTicker()
        end
        RenderAll()
    end
end

local function MarkUnitDirty(unit)
    dirtyUnits[unit] = true
    if not dirtyFlushPending then
        dirtyFlushPending = true
        C_Timer.After(0, FlushDirtyUnits)
    end
end

-- 移除 / 更新的光环实例里是否可能含有已追踪的灵魂石（文件级函数，避免每个 UNIT_AURA 新建闭包）
local function MatchTrackedInstance(idList, unitNeedsInstanceID)
    if idList == nil then return false end
    if unitNeedsInstanceID then return true end
    if F.IsSecret(idList) or type(idList) ~= "table" then return true end
    for i = 1, #idList do
        local iid = F.PlainNumber(idList[i], nil)
        if iid == nil then return true end
        for _, e in pairs(tracked) do
            if e.auraInstanceID == iid then
                return true
            end
        end
    end
    return false
end

-- 40 人团本 O(1) 快速过滤：仅与灵魂石相关的光环变动才触发该单位复查
local function OnUnitAura(_, _, unit, updateInfo)
    unit = F.PlainString(unit, nil)
    if not (unit and GROUP_UNIT_SET[unit]) then return end
    if not ShouldTrackForClass() then return end
    if AreAurasSecret() then return end

    if type(updateInfo) ~= "table" or F.IsSecret(updateInfo) then
        MarkUnitDirty(unit)
        return
    end
    local isFull = PlainBool(updateInfo.isFullUpdate)
    if isFull == nil or isFull == true then
        MarkUnitDirty(unit)
        return
    end

    local relevant = false
    local added = updateInfo.addedAuras
    if added ~= nil then
        if F.IsSecret(added) or type(added) ~= "table" then
            relevant = true
        else
            for i = 1, #added do
                local a = added[i]
                if F.IsSecret(a) or type(a) ~= "table" then
                    relevant = true
                    break
                end
                local sid = F.PlainNumber(a.spellId, nil)
                local nm = F.PlainString(a.name, nil)
                if (sid and SOULSTONE_BUFF_ID_SET[sid]) or (nm and soulstoneNameSet[nm]) then
                    relevant = true
                    break
                end
            end
        end
    end

    if not relevant and next(tracked) ~= nil then
        local unitNeedsInstanceID = false
        for _, e in pairs(tracked) do
            if e.unit == unit and e.auraInstanceID == nil then
                unitNeedsInstanceID = true
                break
            end
        end
        if MatchTrackedInstance(updateInfo.removedAuraInstanceIDs, unitNeedsInstanceID)
            or MatchTrackedInstance(updateInfo.updatedAuraInstanceIDs, unitNeedsInstanceID) then
            relevant = true
        end
    end

    if relevant then
        MarkUnitDirty(unit)
    end
end

----------------------------------------------------------------------
--  玩家施法监听（捕获战斗中补绑灵魂石 & 瞬间归属判定）
----------------------------------------------------------------------
local function OnSpellSent(_, _, unit, targetName, castGUID, spellID)
    if unit ~= "player" or not ShouldTrackForClass() then return end
    if not IsSoulstoneSpell(spellID) then return end
    pendingCast = {
        castGUID = F.PlainString(castGUID, nil),
        targetName = F.PlainString(targetName, nil),
        spellID = F.PlainNumber(spellID, nil),
        at = GetTime(),
    }
end

local function OnSpellFailed(_, _, unit, castGUID)
    if unit ~= "player" or not pendingCast then return end
    local cg = F.PlainString(castGUID, nil)
    if cg and pendingCast.castGUID and cg == pendingCast.castGUID then
        pendingCast = nil
    end
end

local function OnSpellSucceeded(_, _, unit, castGUID, spellID)
    if unit ~= "player" or not ShouldTrackForClass() then return end
    if not IsSoulstoneSpell(spellID) then return end

    local now = GetTime()
    local db = mod:GetDB()
    local cg = F.PlainString(castGUID, nil)
    local targetName = nil
    if pendingCast then
        local sameCast = (cg and pendingCast.castGUID and cg == pendingCast.castGUID)
            or ((now - (pendingCast.at or 0)) <= 10 and pendingCast.spellID == F.PlainNumber(spellID, nil))
        if sameCast then
            targetName = pendingCast.targetName
            pendingCast = nil
        end
    end

    local info = FindGroupUnitByName(targetName)
    if info then
        if db.includeSelf == false and info.isSelf then
            -- 关闭自身追踪时若术士改绑给自己，立即清掉原先绑在队友身上的旧记录
            RemoveOtherMineEntries(nil)
            myCastTargetGUID = nil
            bagInfoCache.at = 0
            SaveTrackedToCharDB()
            RenderAll()
        else
            local dur = F.PlainNumber(db.lastKnownDuration, 1800)
            if dur < 60 or dur > 7200 then dur = 1800 end
            local sid = F.PlainNumber(spellID, nil) or 20765
            RemoveOtherMineEntries(info.guid)
            myCastTargetGUID = info.guid
            tracked[info.guid] = {
                guid = info.guid,
                unit = info.unit,
                name = info.name,
                fullName = info.fullName,
                class = info.class,
                role = info.role,
                spellId = sid,
                buffName = "灵魂石复活",
                icon = ResolveDefaultIcon(),
                duration = dur,
                expireAt = now + dur,
                auraInstanceID = nil,
                isMine = true,
                isSelf = info.isSelf,
                confirmedByAura = false,
                warned = false,
                urgentWarned = false,
                expiredState = false,
                expiredHoldUntil = nil,
                lastSeenAt = now,
            }
            bagInfoCache.at = 0
            SaveTrackedToCharDB()
            EnsureTicker()
            RenderAll()
        end
    end

    -- 延迟 0.35 秒用服务器真实光环校准精确持续时长与过期时间
    local myGen = scanGeneration
    C_Timer.After(0.35, function()
        if myGen == scanGeneration and ShouldTrackForClass() then
            ScanGroup()
        end
    end)
end

----------------------------------------------------------------------
--  现代黑曜石卡片 UI（与 kkowoUI LootToast / RollBars 风格完全统一）
----------------------------------------------------------------------
local function EnsureContainer()
    if container then return end
    container = CreateFrame("Frame", "kkowoUI_SoulstoneAlert", _G.UIParent)
    container:SetSize(mod:GetDB().cardWidth or 248, CARD_HEIGHT)
    container:SetFrameStrata("MEDIUM")
    container:EnableMouse(false)

    container:HookScript("OnHide", function(self)
        if self._cardDragging then
            self._cardDragging = false
            if not (self.IsProtected and self:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown()) then
                self:StopMovingOrSizing()
            end
        end
    end)

    F.Mover.Register({
        key = "SoulstoneAlert",
        label = "灵魂石到期提醒",
        frame = container,
        order = 31,
        defaultPoint = "CENTER",
        defaultRelPoint = "CENTER",
        defaultX = 0,
        defaultY = 195,
        -- 只在真正挂载了监控（术士 / 关闭「仅术士」）或正在预览时出现在解锁模式里，其他职业不显示空移动框
        isHidden = function() return not mod._active or not (eventsBound or #previewEntries > 0) end,
    })
end

local function RoleTag(role)
    if role == "TANK" then return "坦克" end
    if role == "HEALER" then return "治疗" end
    if role == "DAMAGER" then return "输出" end
    return nil
end

local function ShowCardTooltip(card)
    local e = card._entry
    if not e or not GameTooltip then return end
    GameTooltip:SetOwner(card, "ANCHOR_BOTTOM", 0, -6)
    GameTooltip:SetText("灵魂石到期监控", 0.86, 0.78, 0.98)

    local cr, cg, cb = GetClassRGB(e.class)
    local roleTxt = RoleTag(e.role)
    local targetRight = roleTxt and (e.name .. "（" .. roleTxt .. "）") or (e.name or "队友")
    if e.isPreview then
        targetRight = targetRight .. " [预览]"
    elseif e.isSelf then
        targetRight = targetRight .. "（自己）"
    end
    GameTooltip:AddDoubleLine("绑定目标", targetRight, 0.68, 0.72, 0.78, cr, cg, cb)

    local now = GetTime()
    local rem = e.expiredState and 0 or math_max(0, (e.expireAt or now) - now)
    local timeStr = e.expiredState and "已过期" or FormatClock(rem)
    local tr, tg, tb = 0.94, 0.95, 0.97
    if e.expiredState or rem <= 60 then
        tr, tg, tb = COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3]
    elseif rem <= (mod:GetDB().warnSeconds or 180) then
        tr, tg, tb = COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3]
    end
    GameTooltip:AddDoubleLine("剩余时间", timeStr, 0.68, 0.72, 0.78, tr, tg, tb)
    GameTooltip:AddDoubleLine("来源", e.isMine and "你绑定的灵魂石" or "队友术士绑定", 0.68, 0.72, 0.78, 0.84, 0.86, 0.90)

    local bag = GetBagSoulstoneInfo(false)
    if bag then
        local bagText, br, bg, bb
        if bag.hasStone then
            if bag.cdRemaining > 1 then
                bagText = bag.itemName .. "（冷却 " .. FormatClock(bag.cdRemaining) .. "）"
                br, bg, bb = COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3]
            else
                bagText = bag.itemName .. "（已就绪）"
                br, bg, bb = F.Theme.COLORS.good[1], F.Theme.COLORS.good[2], F.Theme.COLORS.good[3]
            end
        else
            if bag.cdRemaining > 1 then
                bagText = "未携带（冷却 " .. FormatClock(bag.cdRemaining) .. "）"
                br, bg, bb = COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3]
            else
                bagText = "未携带（请先制造灵魂石）"
                br, bg, bb = COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3]
            end
        end
        GameTooltip:AddDoubleLine("背包状态", bagText, 0.68, 0.72, 0.78, br, bg, bb)
    end

    GameTooltip:AddLine(" ")
    if e.isPreview or e.expiredState then
        GameTooltip:AddLine("右键点击关闭当前提示；Shift+左键拖动位置", 0.56, 0.60, 0.66)
    else
        GameTooltip:AddLine("输入 /kk unlock 可调整位置（计时卡不拦截点击）", 0.56, 0.60, 0.66)
    end
    GameTooltip:Show()
end

local function CreateCard()
    local card = CreateFrame("Frame", nil, container)
    card:SetSize(mod:GetDB().cardWidth or 248, CARD_HEIGHT)
    card:EnableMouse(true)
    -- 常态卡片只接收悬停（看详情），点击穿透到游戏画面；预览 / 已过期卡片由 RenderAll 开启点击（右键关闭、Shift 拖动）
    if card.SetMouseClickEnabled then card:SetMouseClickEnabled(false) end
    card._clicksOn = false
    F.Theme.StylePanel(card, 0.90, 0.84)

    -- 顶部 1px 柔和镜面高光（与 kkowoUI 黑曜石卡片一致）
    local topSpec = card:CreateTexture(nil, "BORDER", nil, 1)
    topSpec:SetHeight(1)
    topSpec:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    topSpec:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -1)
    topSpec:SetColorTexture(1, 1, 1, 0.12)
    card._topSpec = topSpec

    -- 左侧 2px 状态竖条 + 柔和横向光晕
    local leftBar = card:CreateTexture(nil, "OVERLAY", nil, 2)
    leftBar:SetWidth(2)
    leftBar:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    leftBar:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 3)
    card._leftBar = leftBar

    local glow = card:CreateTexture(nil, "BACKGROUND", nil, -4)
    glow:SetWidth(92)
    glow:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    glow:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 3)
    glow:SetTexture(F.Theme.FLAT_TEX)
    card._glow = glow

    -- 预警呼吸描边层（原生 AnimationGroup 驱动，零 Lua OnUpdate 开销）
    local pulseHost = CreateFrame("Frame", nil, card)
    pulseHost:SetAllPoints()
    pulseHost:SetFrameLevel(card:GetFrameLevel() + 3)
    pulseHost:SetAlpha(0)
    pulseHost:Hide()
    local pulseEdges = {}
    local edgeSpecs = {
        { "TOPLEFT",    "TOPRIGHT",    0,  1, nil, 1 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", 0, -1, nil, 1 },
        { "TOPLEFT",    "BOTTOMLEFT", -1,  0, 1, nil },
        { "TOPRIGHT",   "BOTTOMRIGHT", 1,  0, 1, nil },
    }
    for i, sp in ipairs(edgeSpecs) do
        local ln = pulseHost:CreateTexture(nil, "OVERLAY", nil, 4)
        ln:SetPoint(sp[1], pulseHost, sp[1], sp[3], sp[4])
        ln:SetPoint(sp[2], pulseHost, sp[2], sp[3], sp[4])
        if sp[5] then ln:SetWidth(sp[5]) end
        if sp[6] then ln:SetHeight(sp[6]) end
        pulseEdges[i] = ln
    end
    local pulseAG = pulseHost:CreateAnimationGroup()
    pulseAG:SetLooping("BOUNCE")
    local pAnim = pulseAG:CreateAnimation("Alpha")
    pAnim:SetFromAlpha(0.18)
    pAnim:SetToAlpha(0.95)
    pAnim:SetDuration(0.75)
    pAnim:SetSmoothing("IN_OUT")
    card._pulseHost = pulseHost
    card._pulseEdges = pulseEdges
    card._pulseAG = pulseAG

    -- 图标框（28×28 + 1px 暗框裁边）
    local iconBg = card:CreateTexture(nil, "ARTWORK", nil, 0)
    iconBg:SetSize(30, 30)
    iconBg:SetPoint("LEFT", card, "LEFT", 8, 1)
    iconBg:SetColorTexture(0, 0, 0, 0.85)
    card._iconBg = iconBg

    local icon = card:CreateTexture(nil, "ARTWORK", nil, 1)
    icon:SetSize(28, 28)
    icon:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card._icon = icon

    -- 右侧醒目倒计时
    local timeFS = card:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(timeFS, 15, "", 0.96, 0.96, 0.98, 1)
    timeFS:SetPoint("RIGHT", card, "RIGHT", -10, 1)
    timeFS:SetJustifyH("RIGHT")
    timeFS:SetWordWrap(false)
    card._timeFS = timeFS

    -- 上行：队友名字（职业着色）
    local nameFS = card:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(nameFS, 12, "", 0.95, 0.95, 0.97, 1)
    nameFS:SetPoint("TOPLEFT", iconBg, "TOPRIGHT", 8, -1)
    nameFS:SetPoint("RIGHT", timeFS, "LEFT", -8, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    if nameFS.SetMaxLines then nameFS:SetMaxLines(1) end
    card._nameFS = nameFS

    -- 下行：状态副标题（常态 / 即将到期 / 背包冷却）
    local subFS = card:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(subFS, 10, "", 0.68, 0.72, 0.78, 0.95)
    subFS:SetPoint("BOTTOMLEFT", iconBg, "BOTTOMRIGHT", 8, 1)
    subFS:SetPoint("RIGHT", timeFS, "LEFT", -8, 0)
    subFS:SetJustifyH("LEFT")
    subFS:SetWordWrap(false)
    if subFS.SetMaxLines then subFS:SetMaxLines(1) end
    card._subFS = subFS

    -- 底部 2px 极细剩余进度条
    local barBg = card:CreateTexture(nil, "BACKGROUND", nil, -2)
    barBg:SetHeight(2)
    barBg:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 1)
    barBg:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -1, 1)
    barBg:SetColorTexture(1, 1, 1, 0.06)

    local sb = CreateFrame("StatusBar", nil, card)
    sb:SetHeight(2)
    sb:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 1)
    sb:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -1, 1)
    sb:SetStatusBarTexture(F.Theme.FLAT_TEX)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(1)
    card._bar = sb

    -- 丝滑出现淡入动画
    local fadeIn = card:CreateAnimationGroup()
    local fa = fadeIn:CreateAnimation("Alpha")
    fa:SetFromAlpha(0)
    fa:SetToAlpha(1)
    fa:SetDuration(0.20)
    fa:SetSmoothing("OUT")
    fadeIn:SetScript("OnFinished", function() card:SetAlpha(1) end)
    card._fadeIn = fadeIn

    -- 交互：悬停看详情 / Shift+左键拖动容器 / 右键关闭预览或过期卡片
    local function FinishCardDrag()
        if not (container and container._cardDragging) then return end
        container._cardDragging = false
        if not (container.IsProtected and container:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown()) then
            container:StopMovingOrSizing()
        end
        local pt, _, rpt, x, y = container:GetPoint(1)
        pt = F.PlainString(pt, nil)
        rpt = F.PlainString(rpt, nil)
        x = F.PlainNumber(x, nil)
        y = F.PlainNumber(y, nil)
        if pt and x and y then
            F.DB.SavePosition("SoulstoneAlert", pt, rpt or pt, x, y)
        end
    end

    card._finishDrag = FinishCardDrag
    card:RegisterForDrag("LeftButton")
    card:SetScript("OnEnter", function(self)
        ShowCardTooltip(self)
    end)
    card:SetScript("OnLeave", function(self)
        if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(self) then
            GameTooltip:Hide()
        end
    end)
    card:SetScript("OnDragStart", function()
        if _G.IsShiftKeyDown() and container
            and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            container._cardDragging = true
            container:StartMoving()
        end
    end)
    card:SetScript("OnDragStop", FinishCardDrag)
    card:SetScript("OnHide", FinishCardDrag)
    card:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            local e = self._entry
            if e and e.isPreview then
                DismissPreview()
            elseif e and e.expiredState and e.guid then
                tracked[e.guid] = nil
                RenderAll()
            end
        end
    end)

    card:Hide()
    return card
end

local function AcquireCard()
    local c = table_remove(spareCards)
    if not c then
        c = CreateCard()
    end
    return c
end

local function ReleaseCard(card)
    if not card then return end
    if card._pulseAG and card._pulseAG:IsPlaying() then card._pulseAG:Stop() end
    if card._pulseHost then card._pulseHost:Hide() end
    if card._fadeIn and card._fadeIn:IsPlaying() then card._fadeIn:Stop() end
    card._entry = nil
    card._lastTone = nil
    card:Hide()
    spareCards[#spareCards + 1] = card
end

local function PaintCardTone(card, tone, r, g, b, pulsing)
    if card._lastTone == tone then
        return
    end
    card._lastTone = tone
    card._leftBar:SetColorTexture(r, g, b, 0.96)
    card._bar:SetStatusBarColor(r, g, b, 0.92)
    if card._glow.SetGradient and gradC1 and gradC2 then
        gradC1:SetRGBA(r, g, b, pulsing and 0.28 or 0.16)
        gradC2:SetRGBA(r, g, b, 0.00)
        pcall(card._glow.SetGradient, card._glow, "HORIZONTAL", gradC1, gradC2)
    else
        card._glow:SetVertexColor(r, g, b, pulsing and 0.20 or 0.12)
    end
    if card._fuiBorders then
        local mix = pulsing and 0.65 or 0.34
        for _, ln in ipairs(card._fuiBorders) do
            ln:SetColorTexture(r * mix + 0.14, g * mix + 0.14, b * mix + 0.16, pulsing and 0.88 or 0.76)
        end
    end
    if pulsing then
        for _, ln in ipairs(card._pulseEdges) do
            ln:SetColorTexture(r, g, b, 0.95)
        end
        card._pulseHost:SetAlpha(1)
        card._pulseHost:Show()
        if not card._pulseAG:IsPlaying() then
            card._pulseAG:Play()
        end
    else
        if card._pulseAG:IsPlaying() then card._pulseAG:Stop() end
        card._pulseHost:SetAlpha(0)
        card._pulseHost:Hide()
    end
end

local function BuildSubtitle(e, state, bag)
    if state == "expired" then
        if bag and bag.hasStone and bag.cdRemaining <= 1 then
            return "已过期 · 背包就绪可立刻补绑"
        elseif bag and not bag.hasStone and bag.cdRemaining <= 1 then
            return "已过期 · 请先制造灵魂石"
        end
        return "灵魂石已过期 · 请重新绑定"
    elseif state == "urgent" then
        if bag then
            if bag.cdRemaining > 1 then
                return "马上过期 · 冷却 " .. FormatClock(bag.cdRemaining)
            elseif bag.hasStone then
                return "马上过期 · 背包就绪"
            else
                return "马上过期 · 需制造灵魂石"
            end
        end
        return "马上过期 · 请立即补绑"
    elseif state == "warn" then
        if bag then
            if bag.cdRemaining > 1 then
                return "即将到期 · 冷却 " .. FormatClock(bag.cdRemaining)
            elseif bag.hasStone then
                return "即将到期 · 背包就绪"
            else
                return "即将到期 · 需制造灵魂石"
            end
        end
        return "即将到期 · 请及时补绑"
    end
    if e.isPreview then
        return "灵魂石生效中 · 右键关闭预览"
    elseif e.isSelf then
        return "灵魂石已绑定（自己）"
    elseif not e.isMine then
        return "队友灵魂石生效中"
    end
    return "灵魂石生效中"
end

local function CollectVisibleEntries()
    local list = {}
    local db = mod:GetDB()
    local now = GetTime()
    local warnSec = F.PlainNumber(db.warnSeconds, 180)
    local onlyExpiring = (db.displayMode == "expiring")

    for _, e in pairs(tracked) do
        local rem = e.expiredState and 0 or math_max(0, (e.expireAt or now) - now)
        if e.expiredState or (not onlyExpiring) or (rem <= warnSec) then
            list[#list + 1] = e
        end
    end
    for _, p in ipairs(previewEntries) do
        list[#list + 1] = p
    end

    table_sort(list, function(a, b)
        if (a.isPreview == true) ~= (b.isPreview == true) then
            return a.isPreview == true
        end
        if (a.expiredState == true) ~= (b.expiredState == true) then
            return a.expiredState == true
        end
        local ea = a.expireAt or 0
        local eb = b.expireAt or 0
        if ea ~= eb then return ea < eb end
        return (a.name or "") < (b.name or "")
    end)
    return list
end

RenderAll = function()
    local list = CollectVisibleEntries()
    if #list == 0 then
        for i = #activeCards, 1, -1 do
            ReleaseCard(table_remove(activeCards, i))
        end
        if container then
            container:SetFrameStrata("MEDIUM")
            container:SetSize(F.PlainNumber(mod:GetDB().cardWidth, 248), CARD_HEIGHT)
            if not mod._active then
                container:Hide()
            end
        end
        return
    end

    EnsureContainer()
    -- 预览时置顶到设置窗口（DIALOG）之上，方便在 /kk 内直接看到卡片效果；常态回到 MEDIUM
    if #previewEntries > 0 then
        container:SetFrameStrata("FULLSCREEN_DIALOG")
    else
        container:SetFrameStrata("MEDIUM")
    end
    local db = mod:GetDB()
    local w = F.PlainNumber(db.cardWidth, 248)
    local warnSec = F.PlainNumber(db.warnSeconds, 180)
    local growDown = db.growDown ~= false
    local now = GetTime()
    local count = math_min(#list, MAX_CARDS)
    local bag = GetBagSoulstoneInfo(false)

    -- 调整卡片池数量
    while #activeCards > count do
        ReleaseCard(table_remove(activeCards))
    end
    while #activeCards < count do
        local c = AcquireCard()
        activeCards[#activeCards + 1] = c
    end

    container:SetSize(w, math_max(CARD_HEIGHT, count * CARD_HEIGHT + (count - 1) * CARD_GAP))
    if not container:IsShown() then
        container:Show()
    end

    for i = 1, count do
        local e = list[i]
        local card = activeCards[i]
        local wasHidden = not card:IsShown()
        card._entry = e

        card:SetSize(w, CARD_HEIGHT)
        card:ClearAllPoints()
        local yOff = (i - 1) * (CARD_HEIGHT + CARD_GAP)
        if growDown then
            card:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -yOff)
        else
            card:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, yOff)
        end

        local rem = e.expiredState and 0 or math_max(0, (e.expireAt or now) - now)
        local dur = math_max(1, F.PlainNumber(e.duration, 1800))
        local urgentCutoff = math_min(60, math_max(20, math_floor(warnSec * 0.5)))

        local state, tr, tg, tb, pulsing
        if e.expiredState then
            state, tr, tg, tb, pulsing = "expired", COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3], true
        elseif rem <= urgentCutoff then
            state, tr, tg, tb, pulsing = "urgent", COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3], true
        elseif rem <= warnSec then
            state, tr, tg, tb, pulsing = "warn", COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3], true
        else
            state, tr, tg, tb, pulsing = "normal", COLOR_WARLOCK[1], COLOR_WARLOCK[2], COLOR_WARLOCK[3], false
        end

        PaintCardTone(card, state, tr, tg, tb, pulsing)

        -- 卡片按排序复用，同一张卡可能从「已过期」换成常态条目：关点击前先结束进行中的拖动
        local wantClicks = (e.isPreview == true) or state == "expired"
        if card._clicksOn ~= wantClicks and card.SetMouseClickEnabled then
            if not wantClicks and card._finishDrag then card._finishDrag() end
            card._clicksOn = wantClicks
            card:SetMouseClickEnabled(wantClicks)
        end

        card._icon:SetTexture(e.icon or ResolveDefaultIcon())
        if card._icon.SetDesaturated then
            card._icon:SetDesaturated(state == "expired")
        end
        if state == "expired" then
            card._icon:SetVertexColor(1.0, 0.52, 0.56, 0.90)
        else
            card._icon:SetVertexColor(1, 1, 1, 1)
        end

        local cr, cg, cb = GetClassRGB(e.class)
        local title = e.name or "队友"
        if e.isPreview then
            title = title .. " |cff8f96a3[预览]|r"
        elseif e.isSelf then
            title = title .. " |cff8f96a3(自己)|r"
        end
        card._nameFS:SetText(title)
        card._nameFS:SetTextColor(cr, cg, cb, 1)

        local subText = BuildSubtitle(e, state, bag)
        card._subFS:SetText(subText)
        if state == "expired" or state == "urgent" then
            card._subFS:SetTextColor(1.0, 0.62, 0.66, 0.98)
        elseif state == "warn" then
            card._subFS:SetTextColor(0.98, 0.84, 0.50, 0.98)
        else
            card._subFS:SetTextColor(0.66, 0.70, 0.76, 0.92)
        end

        if state == "expired" then
            card._timeFS:SetText("已过期")
            card._timeFS:SetTextColor(COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3], 1)
            card._bar:SetMinMaxValues(0, 1)
            card._bar:SetValue(0)
        else
            card._timeFS:SetText(FormatClock(rem))
            if state == "urgent" then
                card._timeFS:SetTextColor(COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3], 1)
            elseif state == "warn" then
                card._timeFS:SetTextColor(COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3], 1)
            else
                card._timeFS:SetTextColor(0.95, 0.96, 0.98, 1)
            end
            card._bar:SetMinMaxValues(0, dur)
            card._bar:SetValue(math_min(dur, rem))
        end

        if wasHidden then
            card:SetAlpha(0)
            card:Show()
            card._fadeIn:Stop()
            card._fadeIn:Play()
        end
    end
end

----------------------------------------------------------------------
--  按需倒计时驱动（空闲时完全停止，零后台 CPU）
----------------------------------------------------------------------
local function OnTick()
    local now = GetTime()
    local db = mod:GetDB()
    local warnSec = F.PlainNumber(db.warnSeconds, 180)
    local urgentVoiceSec = math_min(30, math_floor(warnSec * 0.5))
    local stateChanged = false

    for guid, e in pairs(tracked) do
        if e.expiredState then
            if now >= (e.expiredHoldUntil or 0) then
                tracked[guid] = nil
                stateChanged = true
            end
        else
            local rem = (e.expireAt or 0) - now
            if rem <= 0 then
                -- 到点时按 GUID 核验目标单位是否死亡（防止团本换队导致 e.unit 指向他人）
                local isDead = false
                local curUnit = ResolveUnitForGUID(guid, e.unit)
                if curUnit then
                    e.unit = curUnit
                    if _G.UnitIsDeadOrGhost then
                        local okD, d = pcall(_G.UnitIsDeadOrGhost, curUnit)
                        if okD and PlainBool(d) == true then isDead = true end
                    end
                end
                if isDead or db.alertOnExpire == false then
                    tracked[guid] = nil
                else
                    e.expiredState = true
                    e.expiredHoldUntil = now + EXPIRE_HOLD_SEC
                    e.auraInstanceID = nil
                    TriggerNotification("expired", e, nil)
                end
                if myCastTargetGUID == guid then myCastTargetGUID = nil end
                stateChanged = true
            else
                if db.voiceSecondAlert == true and warnSec >= 60
                    and rem <= urgentVoiceSec and not e.urgentWarned then
                    e.warned = true
                    e.urgentWarned = true
                    TriggerNotification("urgent", e, nil)
                    stateChanged = true
                elseif rem <= warnSec and not e.warned then
                    e.warned = true
                    TriggerNotification("warn", e, nil)
                    stateChanged = true
                end
            end
        end
    end

    for i = #previewEntries, 1, -1 do
        local p = previewEntries[i]
        if now >= (p.previewEndsAt or 0) then
            table_remove(previewEntries, i)
        end
    end

    if stateChanged then
        SaveTrackedToCharDB()
    end

    RenderAll()

    if next(tracked) == nil and #previewEntries == 0 then
        StopTicker()
    end
end

EnsureTicker = function()
    if ticker then return end
    if C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(0.5, OnTick)
    end
end

StopTicker = function()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

----------------------------------------------------------------------
--  预览与测试接口（非术士角色也可直接验证 UI 与语音）
----------------------------------------------------------------------
DismissPreview = function()
    for i = #previewEntries, 1, -1 do
        previewEntries[i] = nil
    end
    StopTTS()
    RenderAll()
    if next(tracked) == nil then
        StopTicker()
    end
end

function mod:DismissPreview()
    DismissPreview()
end

function mod:TestVoice()
    local sample = { name = "圣光守护者" }
    TriggerNotification("warn", sample, "voice")
end

function mod:ShowPreview(mode)
    mode = mode or "expiring"
    DismissPreview()
    EnsureContainer()
    local now = GetTime()
    local db = self:GetDB()
    local warnSec = F.PlainNumber(db.warnSeconds, 180)
    local dur = F.PlainNumber(db.lastKnownDuration, 1800)
    if dur < 60 then dur = 1800 end

    if mode == "normal" then
        previewEntries[1] = {
            guid = "preview:normal",
            name = "风行牧师",
            class = "PRIEST",
            role = "HEALER",
            buffName = "灵魂石复活",
            icon = ResolveDefaultIcon(),
            duration = dur,
            expireAt = now + math_max(warnSec + 600, 1520),
            isMine = true,
            isSelf = false,
            isPreview = true,
            expiredState = false,
            previewEndsAt = now + 14,
        }
    elseif mode == "expired" then
        local e = {
            guid = "preview:expired",
            name = "铁壁防战",
            class = "WARRIOR",
            role = "TANK",
            buffName = "灵魂石复活",
            icon = ResolveDefaultIcon(),
            duration = dur,
            expireAt = now,
            isMine = true,
            isSelf = false,
            isPreview = true,
            expiredState = true,
            previewEndsAt = now + 10,
        }
        previewEntries[1] = e
        TriggerNotification("expired", e, "preview")
    else
        local rem = math_min(warnSec, 118)
        local e = {
            guid = "preview:expiring",
            name = "圣光守护者",
            class = "PALADIN",
            role = "HEALER",
            buffName = "灵魂石复活",
            icon = ResolveDefaultIcon(),
            duration = dur,
            expireAt = now + rem,
            isMine = true,
            isSelf = false,
            isPreview = true,
            expiredState = false,
            previewEndsAt = now + 14,
        }
        previewEntries[1] = e
        TriggerNotification("warn", e, "preview")
    end

    EnsureTicker()
    RenderAll()
end

----------------------------------------------------------------------
--  模块事件绑定与生命周期（非术士默认零事件零开销）
----------------------------------------------------------------------
local CHAT_RESTRICTION = _G.Enum and _G.Enum.AddOnRestrictionType and _G.Enum.AddOnRestrictionType.Chat

local debouncedRosterScan = F.Debounce(0.25, function()
    if ShouldTrackForClass() then
        ScanGroup()
    end
end)

local function SchedulePostCombatScan()
    local myGen = scanGeneration
    ScanGroup()
    -- 12.x 脱战后光环保密状态偶发延迟 0.5s~1.5s 解除，补扫两次确保精准校准
    C_Timer.After(0.55, function()
        if myGen == scanGeneration and ShouldTrackForClass() then
            ScanGroup()
        end
    end)
    C_Timer.After(1.60, function()
        if myGen == scanGeneration and ShouldTrackForClass() then
            ScanGroup()
        end
    end)
end

local function SyncEventRegistration()
    local want = ShouldTrackForClass()
    if want == eventsBound then
        return
    end
    eventsBound = want
    if not want then
        mod:UnregisterAllEvents()
        pendingCast = nil
        for k in pairs(dirtyUnits) do dirtyUnits[k] = nil end
        for k in pairs(tracked) do tracked[k] = nil end
        RenderAll()
        if #previewEntries == 0 then
            StopTicker()
        end
        return
    end

    ResolveSoulstoneMetadata(false)
    mod:RegisterEvent("UNIT_AURA", OnUnitAura)
    mod:RegisterEvent("GROUP_ROSTER_UPDATE", debouncedRosterScan)
    mod:RegisterEvent("PLAYER_ROLES_ASSIGNED", debouncedRosterScan)
    mod:RegisterEvent("UNIT_CONNECTION", function(_, _, unit)
        unit = F.PlainString(unit, nil)
        if unit and GROUP_UNIT_SET[unit] then
            MarkUnitDirty(unit)
        end
    end)
    mod:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        ResolveSoulstoneMetadata(false)
        bagInfoCache.at = 0
        local myGen = scanGeneration
        C_Timer.After(0.8, function()
            if myGen == scanGeneration and ShouldTrackForClass() then
                ScanGroup()
            end
        end)
        C_Timer.After(2.2, function()
            if myGen == scanGeneration and ShouldTrackForClass() then
                ScanGroup()
            end
        end)
        C_Timer.After(4.8, function()
            if myGen == scanGeneration and ShouldTrackForClass() then
                ScanGroup()
            end
        end)
    end)
    mod:RegisterEvent("PLAYER_REGEN_ENABLED", SchedulePostCombatScan)
    mod:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED", function(_, _, rtype)
        if rtype ~= CHAT_RESTRICTION then
            SchedulePostCombatScan()
        end
    end)
    mod:RegisterEvent("BAG_UPDATE_DELAYED", function()
        bagInfoCache.at = 0
    end)
    mod:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, _, itemID)
        itemID = F.PlainNumber(itemID, nil)
        if itemID and SOULSTONE_ITEM_NAMES[itemID] then
            ResolveSoulstoneMetadata(true)
        end
    end)
    mod:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player", OnSpellSent)
    mod:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", OnSpellSucceeded)
    mod:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", OnSpellFailed)
    mod:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", OnSpellFailed)
    mod:RegisterEvent("PLAYER_LOGOUT", SaveTrackedToCharDB)

    RestoreTrackedFromCharDB()
    ScanGroup()
end

function mod:OnEnable()
    scanGeneration = scanGeneration + 1
    EnsureContainer()
    if container then container:Show() end
    SyncEventRegistration()
end

function mod:OnDisable()
    scanGeneration = scanGeneration + 1
    SaveTrackedToCharDB()
    eventsBound = false
    pendingCast = nil
    for k in pairs(dirtyUnits) do dirtyUnits[k] = nil end
    for k in pairs(tracked) do tracked[k] = nil end
    DismissPreview()
    StopTicker()
    if container then container:Hide() end
end

function mod:OnThemeChanged()
    local function restyle(list)
        for _, c in ipairs(list) do
            F.Theme.StylePanel(c, 0.90, 0.84)
            F.Theme.ApplyFont(c._nameFS, 12, "")
            F.Theme.ApplyFont(c._subFS, 10, "")
            F.Theme.ApplyFont(c._timeFS, 15, "")
            c._lastTone = nil
        end
    end
    restyle(activeCards)
    restyle(spareCards)
    RenderAll()
end

----------------------------------------------------------------------
--  设置面板（/kk → 战斗与音效 → 灵魂石提醒）
----------------------------------------------------------------------
local function BuildVoiceDropdown()
    local values = { auto = "自动（优先游戏/系统中文语音）" }
    local order = { "auto" }
    for _, v in ipairs(GetAvailableVoices()) do
        local key = "id:" .. tostring(v.voiceID)
        values[key] = v.name
        order[#order + 1] = key
    end
    return values, order
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "仅术士角色生效",
        tooltip = "默认仅术士角色挂载事件监控（其他职业零开销）；非术士角色关闭此项时会自动切换为监控「全队任意灵魂石」，方便团长或治疗查看。",
        getValue = function() return db.warlockOnly ~= false end,
        setValue = function(v)
            db.warlockOnly = v == true
            if not db.warlockOnly and F.GetPlayerClass() ~= "WARLOCK" and db.trackScope == "mine" then
                db.trackScope = "any"
                local EUI = _G.EllesmereUI
                if EUI and EUI.RefreshPage then
                    pcall(EUI.RefreshPage, EUI)
                end
            end
            SyncEventRegistration()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "提醒显示模式",
        tooltip = "「常驻紧凑计时卡」只要灵魂石生效就会显示小巧倒计时条，快到期自动高亮闪烁；「仅快到期弹出」平时完全隐藏，到达预警时间才滑出提醒。",
        values = {
            always   = "常驻紧凑计时卡（推荐）",
            expiring = "仅快到期时弹出提醒",
        },
        order = { "always", "expiring" },
        getValue = function() return db.displayMode or "always" end,
        setValue = function(v)
            db.displayMode = v
            RenderAll()
        end,
    }, {
        type = "slider",
        text = "提前预警时间（秒）",
        tooltip = "灵魂石剩余时间低于该秒数时切换高亮预警并触发语音提醒（默认 180 秒 = 3 分钟）。",
        min = 30, max = 300, step = 30,
        getValue = function() return db.warnSeconds or 180 end,
        setValue = function(v)
            db.warnSeconds = v
            local now = GetTime()
            local urgentSec = math_min(30, math_floor(v * 0.5))
            for _, e in pairs(tracked) do
                if not e.expiredState and e.expireAt then
                    local rem = e.expireAt - now
                    if rem > v + 2 then e.warned = false end
                    if rem > urgentSec + 2 then e.urgentWarned = false end
                end
            end
            RenderAll()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "灵魂石监控范围",
        tooltip = "「仅我绑定的灵魂石」只追踪你自己施放的灵魂石；「全队任意灵魂石」可同时监控团本中多位术士的灵魂石。",
        values = {
            mine = "仅我绑定的灵魂石（推荐）",
            any  = "全队任意术士的灵魂石",
        },
        order = { "mine", "any" },
        getValue = function() return db.trackScope or "mine" end,
        setValue = function(v)
            db.trackScope = v
            if v ~= "any" then
                local pruned = false
                for g, e in pairs(tracked) do
                    if not e.isMine then
                        tracked[g] = nil
                        pruned = true
                    end
                end
                if pruned then
                    SaveTrackedToCharDB()
                    RenderAll()
                end
            end
            ScanGroup()
        end,
    }, {
        type = "toggle",
        text = "同时追踪绑给自己的灵魂石",
        tooltip = "关闭后仅追踪绑在队友身上的灵魂石；开启后绑在自己身上也会计时与预警。",
        getValue = function() return db.includeSelf ~= false end,
        setValue = function(v)
            db.includeSelf = v == true
            if not db.includeSelf then
                local pruned = false
                for g, e in pairs(tracked) do
                    if e.isSelf then
                        tracked[g] = nil
                        if myCastTargetGUID == g then myCastTargetGUID = nil end
                        pruned = true
                    end
                end
                if pruned then
                    SaveTrackedToCharDB()
                    RenderAll()
                end
            end
            ScanGroup()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "启用语音提醒（系统 TTS）",
        tooltip = "灵魂石快到期时通过游戏内置文字转语音（TTS）播报中文提醒，可随时关闭静音。",
        getValue = function() return db.voiceAlert ~= false end,
        setValue = function(v)
            db.voiceAlert = v == true
            if not v then StopTTS() end
        end,
    }, {
        type = "toggle",
        text = "语音播报包含队友名字",
        tooltip = "开启后播报「某某的灵魂石即将到期，请及时补绑」；关闭则播报简洁通用提示，避免生僻字符读音怪异。",
        getValue = function() return db.voiceIncludeName == true end,
        setValue = function(v) db.voiceIncludeName = v == true end,
    })
    y = y - h

    local voiceVals, voiceOrd = BuildVoiceDropdown()
    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "语音音色",
        tooltip = "列表实时读取当前 Windows/系统可用语音包；建议选带中文标识的音色或保持自动。",
        values = voiceVals,
        order = voiceOrd,
        getValue = function()
            local cur = db.voiceID or "auto"
            return voiceVals[cur] and cur or "auto"
        end,
        setValue = function(v) db.voiceID = v end,
    }, {
        type = "dropdown",
        text = "辅助提示音效",
        tooltip = "可额外叠加一段简短游戏内置提示音；若系统未安装 TTS 语音包，触发语音提醒时会自动用团队警报音兜底。",
        values = {
            none     = "无（仅语音 / 静音）",
            ready    = "就位确认（8960）",
            raidwarn = "团队警报（8959）",
        },
        order = { "none", "ready", "raidwarn" },
        getValue = function() return db.soundCue or "none" end,
        setValue = function(v) db.soundCue = v end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "语音音量",
        min = 20, max = 100, step = 10,
        getValue = function() return db.voiceVolume or 100 end,
        setValue = function(v) db.voiceVolume = v end,
    }, {
        type = "slider",
        text = "语音语速",
        tooltip = "0 为正常语速，正数加快，负数放慢。",
        min = -3, max = 3, step = 1,
        getValue = function() return db.voiceRate or 0 end,
        setValue = function(v) db.voiceRate = v end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "剩余 30 秒二次语音催促",
        tooltip = "除首次提前预警外，在剩余不足 30 秒时再进行一次紧急语音提醒（需预警时间 ≥ 60 秒）。",
        getValue = function() return db.voiceSecondAlert == true end,
        setValue = function(v) db.voiceSecondAlert = v == true end,
    }, {
        type = "toggle",
        text = "自然到期显示「已过期」提醒",
        tooltip = "灵魂石倒计时归零后短暂显示 8 秒红色补绑提示；队友死亡消耗灵魂石时不会误报。",
        getValue = function() return db.alertOnExpire ~= false end,
        setValue = function(v) db.alertOnExpire = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "自然到期时也语音播报",
        tooltip = "灵魂石自然过期消失瞬间额外播报「灵魂石已过期，请重新绑定」。",
        getValue = function() return db.voiceOnExpire == true end,
        setValue = function(v) db.voiceOnExpire = v == true end,
    }, {
        type = "toggle",
        text = "同步本地聊天框文字提醒",
        tooltip = "快到期或过期时在自己聊天框输出一条带颜色的本地提示（仅自己可见，绝不刷队聊）。",
        getValue = function() return db.chatAlert == true end,
        setValue = function(v) db.chatAlert = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "卡片宽度",
        min = 210, max = 320, step = 10,
        getValue = function() return db.cardWidth or 248 end,
        setValue = function(v)
            db.cardWidth = v
            RenderAll()
        end,
    }, {
        type = "button",
        text = "试听语音提醒",
        noCapture = true,
        tooltip = "立即按当前音色、音量与语速试听中文语音提醒（非术士角色也可测试）。",
        onClick = function() self:TestVoice() end,
    })
    y = y - h

    _, h = W:WideDualButton(parent, "预览：正常计时卡（无语音）", "预览：即将到期 + 语音", y,
        function() self:ShowPreview("normal") end,
        function() self:ShowPreview("expiring") end)
    y = y - h

    _, h = W:WideDualButton(parent, "预览：已过期 + 语音", "清除预览 / 停止语音", y,
        function() self:ShowPreview("expired") end,
        function() DismissPreview() end)
    y = y - h

    return y
end
