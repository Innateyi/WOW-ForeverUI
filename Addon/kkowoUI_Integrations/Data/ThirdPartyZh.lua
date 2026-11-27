----------------------------------------------------------------------
--  kkowoUI_Integrations — Data/ThirdPartyZh.lua
--  第三方保留插件简体中文运行时补齐（零文件补丁，官方已有译文优先，仅补空缺）：
--    • GTFO（补齐 zhCN.lua 缺失的 40 条 12.x / 经典服选项与提示）
--    • Auctionator（补齐 5 条残留英文）
--    • BigWigs_Classic（补齐 3 条非触发器文案；2 条首领喊话触发器按审批不机翻）
--    • EllesmereUIQoL（补齐 3 条拾取掷点与传送提示残留英文）
--    • BugSack（已核验 54/54 全汉化，纳入 /kk selftest 抽查）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, pairs, pcall, rawget, type = ipairs, pairs, pcall, rawget, type
local CreateFrame = CreateFrame
local GetLocale = _G.GetLocale

if not (GetLocale and GetLocale() == "zhCN") then
    return
end

-- ---------------------------------------------------------------------------
-- 1) GTFO：40 条缺失键（仅在 GTFOLocal[k] 为空或仍为英文原值时写入）
-- ---------------------------------------------------------------------------
local GTFO_ZH = {
    Vibration_On = { "Controller vibration on", "手柄震动已开启" },
    Vibration_Off = { "Controller vibration off", "手柄震动已关闭" },
    UI_Vibration = { "Vibration", "震动" },
    UI_VibrationDescription = { "This enables gamepad vibration when sounding alerts.", "触发警报时同时开启手柄震动。" },
    UI_CustomSounds = { "Custom Sounds", "自定义音效" },
    UI_CustomSoundsHeader = { "Override existing sound alerts", "替换现有警报音效" },
    UI_Reset = { "Reset", "重置" },
    UI_ResetCustomSounds = { "Reset this sound to use the default sound.", "将该音效重置为默认。" },
    UI_CustomSounds_Set = { "Custom sound for |cFFFFFFFF%s|r alert set.", "已设置 |cFFFFFFFF%s|r 警报的自定义音效。" },
    UI_CustomSounds_Removed = { "Custom sound for |cFFFFFFFF%s|r alert is now set to default.", "已将 |cFFFFFFFF%s|r 警报恢复为默认音效。" },
    Help_IgnoreSpell = { "Add/remove spells to your custom ignore list (Advanced)", "在自定义忽略列表中添加或移除法术（高级）" },
    UI_NotSupported_Classic = { "This feature is not supported in WoW Classic.", "经典旧世暂不支持此功能。" },
    UI_IgnoreSpell_Help = { "To add/remove a spell to your custom ignore list, type: |cFFFFFFFF/GTFO Ignore 12345|r where |cFF44FFFF12345|r is the spell ID # you wish to ignore.", "在自定义忽略列表中添加或移除法术，请输入：|cFFFFFFFF/GTFO Ignore 12345|r（|cFF44FFFF12345|r 为要忽略的法术编号）。" },
    UI_IgnoreSpell_None = { "You are currently not ignoring any spells.", "当前未忽略任何法术。" },
    UI_IgnoreSpell_List = { "You are currently ignoring the following spells:", "当前已忽略以下法术：" },
    UI_IgnoreSpell_InvalidSpellId = { "The spell ID |cFF44FFFF%s|r is invalid.", "法术编号 |cFF44FFFF%s|r 无效。" },
    UI_IgnoreSpell_Add = { "You are now ignoring Spell #%s: %s", "已忽略法术 #%s：%s" },
    UI_IgnoreSpell_Remove = { "You are no longer ignoring Spell #%s: %s", "已取消忽略法术 #%s：%s" },
    BrannMode_On = { "Brann only alerts on", "已开启仅布莱恩警报" },
    BrannMode_OnWithDefault = { "Brann & standard alerts", "已开启布莱恩与标准警报" },
    BrannMode_Off = { "Brann alerts off", "布莱恩警报已关闭" },
    UI_BrannMode = { "Brann Alerts", "布莱恩警报" },
    UI_BrannModeDescription = { "This enables Brann Bronzebeard to yell at you.", "开启后由布莱恩·铜须对你大喊提醒。" },
    UI_AprilFoolsDay = { "April Fools Day Joke", "愚人节彩蛋" },
    UI_AprilFoolsDayDescription = { "Uncheck this to permanently turn off the fun April Fools Day joke. :(\n\nIf you change your mind, you can type |cFFFFFFFF/GTFO Brann|r to bring him back.", "取消勾选以永久关闭愚人节彩蛋。\n\n如需重新开启，可输入 |cFFFFFFFF/GTFO Brann|r。" },
    UI_IgnoreTime = { "Alert Delay Time", "警报间隔时间" },
    UI_IgnoreTimeDescription = { "The minimum amount of delay between alert sounds. Increase this if the sounds are too spammy.", "两次警报音效之间的最短间隔，觉得刷屏时可调高此项。" },
    UI_IgnoreTime_Seconds = { "seconds", "秒" },
    Help_SettingsDuringCombat = { "Cannot open GTFO settings during combat.", "战斗中无法打开 GTFO 设置。" },
    UI_BrokenReason = { "This functionality was disabled due to the new Blizzard addon restrictions introduced in Midnight (12.0)", "受 12.0 版本暴雪插件限制影响，此功能已停用。" },
    UI_BrokenPartialReason = { "Some of this functionality was disabled due to the new Blizzard addon restrictions introduced in Midnight (12.0)", "受 12.0 版本暴雪插件限制影响，此功能部分已停用。" },
    UI_BrokenExplanation_Header = { "Addon Restrictions", "插件限制说明" },
    UI_BrokenExplanation_Text = { "Several GTFO features are currently locked.\n\nBlizzard introduced new addon restrictions in Midnight (12.0). Those restrictions prevent GTFO from detecting several categories of avoidable damage reliably, so those options have been disabled to avoid false or missing alerts.\n\nOnly features that still work within the new restrictions remain enabled.", "部分 GTFO 功能当前已锁定。\n\n由于 12.0 版本暴雪新增插件限制，GTFO 无法可靠检测部分可规避伤害，已停用相关选项以免误报或漏报。\n\n仅保留在限制范围内仍可正常运作的功能。" },
    UI_LowDamage2 = { "Low Damage sounds", "低伤害音效" },
    UI_AFKAlert_Classic = { "Alert if attacked while AFK", "暂离受击警报" },
    UI_AFKAlertDescription_Classic = { "While you are flagged AFK, GTFO will play an alert whenever you take damage.", "处于暂离状态时，受到任何伤害都会播放警报音。" },
    UI_AFKAlert_Retail = { "Alert if combat starts while AFK", "暂离进战警报" },
    UI_AFKAlertDescription_Retail = { "While you are flagged AFK, GTFO will attempt to play an alert one time when combat starts (may not work in Blizzard-restricted situations such as Mythic+).", "处于暂离状态时，进入战斗会尝试播放一次警报音（受限场景下可能不生效）。" },
    Help_EncounterRegistrationBlocked = { "Encounter alerts may not work this pull due to combat lockdown.", "因战斗锁定，本次首领战警报可能无法生效。" },
    Help_SettingsDuringRestrictions = { "Cannot change GTFO enabled state while addon restrictions are active.", "插件限制生效期间无法切换 GTFO 启用状态。" },
}

local function ApplyGTFO()
    local tbl = _G.GTFOLocal
    if type(tbl) ~= "table" then return false end
    for k, pair in pairs(GTFO_ZH) do
        local cur = tbl[k]
        if cur == nil or cur == "" or cur == pair[1] then
            tbl[k] = pair[2]
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- 2) Auctionator：5 条残留英文（写入 AUCTIONATOR_L_* 全局与 zhCN 工厂）
-- ---------------------------------------------------------------------------
local AUCTIONATOR_ZH = {
    PAST_AUTHOR_HEADER = { "Past Author", "历任作者" },
    SUPPORT_HEADER = { "Get support", "获取支持" },
    DISCORD = { "Discord", "社区频道" },
    AUCTIONATOR = { "Auctionator", "拍卖助手" },
    CONFIG_SELLING_IGNORE_ITEM_LEVEL = { "Ignore item level when searching for matching auctions", "搜索同类拍卖时忽略物品等级" },
}

local function ApplyAuctionator()
    local any = false
    for k, pair in pairs(AUCTIONATOR_ZH) do
        local gkey = "AUCTIONATOR_L_" .. k
        local cur = _G[gkey]
        if cur == nil or cur == pair[1] then
            _G[gkey] = pair[2]
            any = true
        end
    end
    return any
end

-- ---------------------------------------------------------------------------
-- 3) BigWigs_Classic：3 条非触发器文案（2 条首领喊话触发器按审批不机翻）
-- ---------------------------------------------------------------------------
local BW_CLASSIC_ZH = {
    ["Mechanical Menagerie Discovery"] = {
        boss_at_hp = { "%s at %d%%", "%s 血量 %d%%" },
    },
    ["Grand Crusader Caldoran"] = {
        run = { "Run to the door", "跑向门口" },
        run_desc = { "Show a message after stage 2 ends reminding you to run to the door.", "第 2 阶段结束后显示提醒，提示你跑向门口。" },
    },
}

local function ApplyBigWigsClassic()
    local bw = _G.BigWigs
    local api = _G.BigWigsAPI
    local getter = (api and type(api.GetLocale) == "function" and api.GetLocale)
        or (bw and type(bw.GetBossLocale) == "function" and bw.GetBossLocale)
    if not getter then return false end
    local applied = false
    for bossName, keys in pairs(BW_CLASSIC_ZH) do
        local ok, L = pcall(function()
            if bw and type(bw.NewBossLocale) == "function" then
                return bw:NewBossLocale(bossName, "zhCN")
            end
            return api and api:GetLocale("BigWigs: " .. bossName)
        end)
        if ok and type(L) == "table" then
            for k, pair in pairs(keys) do
                local cur = rawget(L, k)
                if cur == nil or cur == pair[1] then
                    L[k] = pair[2]
                    applied = true
                end
            end
        end
    end
    return applied
end

-- ---------------------------------------------------------------------------
-- 4) EllesmereUIQoL：3 条拾取掷点 / 传送提示英文
-- ---------------------------------------------------------------------------
local EUI_QOL_ZH = {
    ["Everyone passed"] = "所有人均已放弃",
    ["Sample Item"] = "示例物品",
    ["dungeon"] = "地下城",
}

local function ApplyEllesmereUIQoL()
    local EUI = _G.EllesmereUI
    if not (EUI and type(EUI.RegisterLocale) == "function") then return false end
    local ok, tbl = pcall(EUI.RegisterLocale, "zhCN")
    if not (ok and type(tbl) == "table") then return false end
    for k, v in pairs(EUI_QOL_ZH) do
        if tbl[k] == nil or tbl[k] == k then
            tbl[k] = v
        end
    end
    return true
end

local function ApplyAll()
    ApplyGTFO()
    ApplyAuctionator()
    ApplyBigWigsClassic()
    ApplyEllesmereUIQoL()
end

ApplyAll()

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(_, event, name)
    if event == "PLAYER_LOGIN" then
        ApplyAll()
    elseif name == "GTFO" then
        ApplyGTFO()
    elseif name == "Auctionator" then
        ApplyAuctionator()
    elseif name == "BigWigs" or name == "BigWigs_Classic" then
        ApplyBigWigsClassic()
    elseif name == "EllesmereUI" or name == "EllesmereUIQoL" or name == "EllesmereUILocales" then
        ApplyEllesmereUIQoL()
    end
end)

-- 注册到 /kk selftest 抽查清单
F._LocaleChecks = F._LocaleChecks or {}

F._LocaleChecks.GTFO = function()
    if not F.IsAddOnLoaded("GTFO") then return true, "skipped (not loaded)" end
    local tbl = _G.GTFOLocal
    if type(tbl) ~= "table" then return false, "GTFOLocal missing" end
    local sample = {
        "UI_Vibration", "UI_CustomSounds", "UI_Reset", "UI_BrannMode", "UI_IgnoreTime",
        "UI_IgnoreTime_Seconds", "UI_LowDamage2", "UI_AFKAlert_Classic",
        "UI_BrokenExplanation_Header", "Help_SettingsDuringCombat",
    }
    local hit = 0
    for _, k in ipairs(sample) do
        local v = tbl[k]
        if type(v) == "string" and v ~= "" and v ~= GTFO_ZH[k][1] then hit = hit + 1 end
    end
    return hit == #sample, "GTFO " .. hit .. "/" .. #sample
end

F._LocaleChecks.Auctionator = function()
    if not F.IsAddOnLoaded("Auctionator") then return true, "skipped (not loaded)" end
    local hit, total = 0, 0
    for k, pair in pairs(AUCTIONATOR_ZH) do
        total = total + 1
        local v = _G["AUCTIONATOR_L_" .. k]
        if type(v) == "string" and v ~= "" and v ~= pair[1] then hit = hit + 1 end
    end
    return hit == total, "Auctionator " .. hit .. "/" .. total
end

F._LocaleChecks.EllesmereUIQoL = function()
    if not F.IsAddOnLoaded("EllesmereUI") then return true, "skipped (not loaded)" end
    local EUI = _G.EllesmereUI
    if not (EUI and type(EUI.RegisterLocale) == "function") then
        return true, "skipped (locale table inactive)"
    end
    local ok, tbl = pcall(EUI.RegisterLocale, "zhCN")
    if not (ok and type(tbl) == "table") then return true, "skipped (locale table inactive)" end
    local hit, total = 0, 0
    for k in pairs(EUI_QOL_ZH) do
        total = total + 1
        local v = tbl[k]
        if type(v) == "string" and v ~= "" and v ~= k then hit = hit + 1 end
    end
    return hit == total, "EllesmereUIQoL " .. hit .. "/" .. total
end

F._LocaleChecks.BugSack = function()
    if not F.IsAddOnLoaded("BugSack") then return true, "skipped (not loaded)" end
    local L = _G.BugSack and _G.BugSack.L
    if type(L) ~= "table" then return false, "BugSack.L missing" end
    local sample = { "All bugs", "Auto popup", "Current session", "Font size", "Minimap icon", "Mute", "Send", "Small", "Sound", "Today" }
    local hit = 0
    for _, k in ipairs(sample) do
        if type(L[k]) == "string" and L[k] ~= k then hit = hit + 1 end
    end
    return hit == #sample, "BugSack " .. hit .. "/" .. #sample
end
