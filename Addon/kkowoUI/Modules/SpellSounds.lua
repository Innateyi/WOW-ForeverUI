----------------------------------------------------------------------
--  kkowoUI — Modules/SpellSounds.lua
--  猎人技能自定义音效（新增：职业过滤、急速射击脱战自动停播）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, type = ipairs, pairs, pcall, type
local GetTime = GetTime

local mod = F.RegisterModule("spellSounds", {
    title = "猎人技能音效",
    desc = "施放射击/陷阱/手雷/急速射击等技能播放自定义音效；支持自动识别枪械与弓/弩切换对应套音效，默认仅猎人生效。",
    group = "combat",
    order = 20,
    defaults = {
        enabled = true,
        hunterOnly = true,
        stopLongOnOOC = true,
        weaponMode = "auto", -- "auto" = 自动按远程装备切换枪/弓 | "gun" = 始终枪械 | "bow" = 始终弓箭
        channel = "Dialog",
        off = {},
    },
})

local MEDIA = F.MEDIA .. "SpellSounds\\"

local ENTRIES = {
    { key = "autoshot",  spell = "自动射击", sound = "98K 换弹",         file = "autoshot.mp3",  dur = 1.9,  bowSound = "轻弓弦鸣",   bowFile = "bow_autoshot.wav",  bowDur = 0.72, names = { "自动射击" } },
    { key = "arcane",    spell = "奥术射击", sound = "M24 消音",         file = "arcane.mp3",    dur = 1.6,  bowSound = "奥术光箭",   bowFile = "bow_arcane.wav",    bowDur = 1.12, names = { "奥术射击" } },
    { key = "multishot", spell = "多重射击", sound = "喷子退壳",         file = "multishot.mp3", dur = 1.2,  bowSound = "三连散射",   bowFile = "bow_multishot.wav", bowDur = 0.96, names = { "多重射击" } },
    { key = "aimed",     spell = "瞄准射击", sound = "AWM",              file = "aimed.mp3",     dur = 1.9,  bowSound = "重战弓破甲", bowFile = "bow_aimed.wav",     bowDur = 1.32, names = { "瞄准射击" } },
    { key = "volley",    spell = "乱射",     sound = "加特林",           file = "volley.mp3",    dur = 6.0,  bowSound = "箭雨齐射",   bowFile = "bow_volley.wav",    bowDur = 6.0,  names = { "乱射" }, channel = true },
    { key = "sniper",    spell = "狙击射击", sound = "巴雷特",           file = "sniper.mp3",    dur = 1.3,  bowSound = "猎龙长弓",   bowFile = "bow_sniper.wav",    bowDur = 1.26, names = { "狙击射击" } },
    { key = "grenade",   spell = "工程手雷", sound = "Fire in the hole", file = "grenade.mp3",   dur = 1.4,  patterns = { "手雷", "手榴弹", "炸弹", "炸药" }, noCraft = true },
    { key = "trap",      spell = "各类陷阱", sound = "Bomb planted",     file = "trap.mp3",      dur = 1.5,  patterns = { "陷阱$" } },
    { key = "rapidfire", spell = "急速射击", sound = "战歌（15 秒）",    file = "rapidfire.mp3", dur = 15.0, names = { "急速射击" }, longBGM = true },
    { key = "raptor",    spell = "猛禽一击", sound = "传奇攻杀",         file = "raptor.mp3",    dur = 0.6,  names = { "猛禽一击" } },
}

local playing = {}
local spellCache = {}
local equippedRangedKind = nil

local function DetectRangedWeaponKind()
    local slot = _G.INVSLOT_RANGED or 18
    local itemID = _G.GetInventoryItemID and F.PlainNumber(_G.GetInventoryItemID("player", slot), nil) or nil
    if not itemID then
        return "gun"
    end
    local getInstant = (_G.C_Item and _G.C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if type(getInstant) == "function" then
        local ok, _, _, subType, _, _, classID, subClassID = pcall(getInstant, itemID)
        if ok then
            local cid = F.PlainNumber(classID, nil)
            local scid = F.PlainNumber(subClassID, nil)
            if cid == 2 then
                -- Weapon SubClass: 2 = 弓(Bows), 18 = 弩(Crossbows), 3 = 枪械(Guns)
                if scid == 2 or scid == 18 then
                    return "bow"
                elseif scid == 3 then
                    return "gun"
                end
            end
            local st = F.PlainString(subType, nil)
            if st then
                local low = st:lower()
                if st:find("弓") or st:find("弩") or low:find("bow") then
                    return "bow"
                elseif st:find("枪") or low:find("gun") then
                    return "gun"
                end
            end
        end
    end
    return "gun"
end

local function RefreshEquippedWeapon()
    equippedRangedKind = DetectRangedWeaponKind()
end

local function GetActiveWeaponKind()
    local mode = mod:GetDB().weaponMode or "auto"
    if mode == "bow" then return "bow" end
    if mode == "gun" then return "gun" end
    if not equippedRangedKind then
        RefreshEquippedWeapon()
    end
    return equippedRangedKind or "gun"
end

local function ResolveEntrySound(e, forcedKind)
    local kind = forcedKind or GetActiveWeaponKind()
    if kind == "bow" and e.bowFile then
        return e.bowFile, e.bowDur or e.dur, e.bowSound or e.sound
    end
    return e.file, e.dur, e.sound
end

local function StopEntry(key, fade)
    local p = playing[key]
    if not p then
        return
    end
    playing[key] = nil
    -- 已自然播完的句柄无需再 Stop
    if p.handle and _G.StopSound and GetTime() < (p.endsAt or 0) then
        pcall(_G.StopSound, p.handle, fade or 0)
    end
end

local function StopAll(fade)
    for k in pairs(playing) do
        StopEntry(k, fade or 200)
    end
end

local function IsPlaying(key)
    local p = playing[key]
    return p ~= nil and GetTime() < p.endsAt
end

local function PlayEntry(e, forcedKind)
    StopEntry(e.key, 0)
    local db = mod:GetDB()
    local chan = db.channel or "Dialog"
    local file, dur = ResolveEntrySound(e, forcedKind)
    if _G.PlaySoundFile and file then
        local ok, willPlay, handle = pcall(_G.PlaySoundFile, MEDIA .. file, chan)
        if ok and willPlay then
            playing[e.key] = { handle = handle, endsAt = GetTime() + dur, longBGM = e.longBGM }
        end
    end
end

local function ResolveSpellName(id)
    local name
    if _G.C_Spell and _G.C_Spell.GetSpellName then
        local ok, n = pcall(_G.C_Spell.GetSpellName, id)
        if ok then name = n end
    end
    if name == nil and _G.GetSpellInfo then
        local ok, n = pcall(_G.GetSpellInfo, id)
        if ok then name = n end
    end
    return F.PlainString(name, nil)
end

local function MatchName(name)
    for _, e in ipairs(ENTRIES) do
        if e.names then
            for _, n in ipairs(e.names) do
                if name == n then return e end
            end
        end
        if e.patterns then
            for _, pat in ipairs(e.patterns) do
                if name:find(pat) then return e end
            end
        end
    end
    return nil
end

local function EntryForSpell(spellID)
    spellID = F.PlainNumber(spellID, nil)
    if not spellID then
        return nil
    end
    local hit = spellCache[spellID]
    if hit == nil then
        local name = ResolveSpellName(spellID)
        if not name or name == "" then
            return nil
        end
        hit = MatchName(name) or false
        spellCache[spellID] = hit
    end
    return hit or nil
end

local function IsCraftingOpen()
    for _, n in ipairs({ "TradeSkillFrame", "ProfessionsFrame" }) do
        local f = _G[n]
        if f and f.IsShown and f:IsShown() then
            return true
        end
    end
    return false
end

local function ShouldRunForClass()
    local db = mod:GetDB()
    if db.hunterOnly ~= false and F.GetPlayerClass() ~= "HUNTER" then
        return false
    end
    return true
end

function mod:OnSpellEvent(event, _, _, spellID)
    if event == "PLAYER_DEAD" then
        StopAll(150)
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if self:GetDB().stopLongOnOOC ~= false then
            for k, p in pairs(playing) do
                if p.longBGM then
                    StopEntry(k, 400)
                end
            end
        end
        return
    end
    if not ShouldRunForClass() then
        return
    end
    local e = EntryForSpell(spellID)
    if not e or self:GetDB().off[e.key] == true then
        return
    end
    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        if e.channel then PlayEntry(e) end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if e.channel then StopEntry(e.key, 300) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if e.channel then return end
        if e.noCraft and IsCraftingOpen() then return end
        PlayEntry(e)
    end
end

function mod:OnEnable()
    RefreshEquippedWeapon()
    self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", self.OnSpellEvent)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", self.OnSpellEvent)
    self:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", self.OnSpellEvent)
    self:RegisterEvent("PLAYER_DEAD", self.OnSpellEvent)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", self.OnSpellEvent)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", RefreshEquippedWeapon)
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function(_, _, slot)
        local rangedSlot = _G.INVSLOT_RANGED or 18
        if slot == nil or slot == rangedSlot then
            RefreshEquippedWeapon()
        end
    end)
end

function mod:OnDisable()
    StopAll(150)
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "远程武器音效模式",
        tooltip = "「自动识别」会根据你远程栏装备自动切换：装备弓/弩时播放物理弓弦箭雨音效，装备枪械时播放枪声音效；也可手动锁定某一套。",
        values = {
            auto = "自动识别装备（枪械 / 弓弩）",
            bow  = "始终使用弓箭音效",
            gun  = "始终使用枪械音效",
        },
        order = { "auto", "bow", "gun" },
        getValue = function() return db.weaponMode or "auto" end,
        setValue = function(v)
            db.weaponMode = v
            RefreshEquippedWeapon()
            local EUI = _G.EllesmereUI
            if EUI and EUI.RefreshPage then
                -- force=true 重建整页：否则 EUI 只走快速路径重读数值，「试听：枪/弓」按钮文字不会随武器模式更新
                pcall(EUI.RefreshPage, EUI, true)
            end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "声音通道",
        tooltip = "选择音效播放走系统哪条音量滑块。",
        values = { Master = "主音量", SFX = "音效", Dialog = "对话" },
        order = { "Master", "SFX", "Dialog" },
        getValue = function() return db.channel or "Dialog" end,
        setValue = function(v) db.channel = v end,
    }, {
        type = "toggle",
        text = "仅猎人角色生效",
        tooltip = "关闭后其他职业扔工程手雷也会触发音效；建议保持开启以免小号或朋友误触。",
        getValue = function() return db.hunterOnly ~= false end,
        setValue = function(v) db.hunterOnly = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "脱战自动停止急速射击战歌",
        tooltip = "战斗提前结束时淡出停止 15 秒战歌音效。",
        getValue = function() return db.stopLongOnOOC ~= false end,
        setValue = function(v) db.stopLongOnOOC = v == true end,
    }, blank)
    y = y - h

    local activeKind = GetActiveWeaponKind()
    local modeTag = (activeKind == "bow") and "当前弓箭" or "当前枪械"

    for _, entry in ipairs(ENTRIES) do
        local e = entry
        local _, _, activeSoundName = ResolveEntrySound(e, activeKind)
        local rowLabel = e.bowSound
            and (e.spell .. " · 枪:" .. e.sound .. " / 弓:" .. e.bowSound)
            or (e.spell .. " · " .. e.sound)
        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = rowLabel,
            tooltip = e.channel and "开始引导时播放，引导结束或被打断时停止。"
                or (e.noCraft and "施放含手雷/手榴弹/炸弹/炸药的物品时播放；专业制造窗口打开时不响。")
                or (e.patterns and "施放任意以「陷阱」结尾的技能时播放。")
                or (e.bowSound and ("施放成功时按远程武器自动播放（" .. modeTag .. "：" .. activeSoundName .. "）。") or "施放成功时播放。"),
            getValue = function() return db.off[e.key] ~= true end,
            setValue = function(v)
                db.off[e.key] = (not v) and true or nil
                if not v then StopEntry(e.key, 200) end
            end,
        }, {
            type = "button",
            text = "试听：" .. activeSoundName,
            noCapture = true,
            tooltip = e.bowSound
                and ("按当前模式（" .. modeTag .. "）试听「" .. activeSoundName .. "」，播放中再次点击停止。切换上方武器模式可试听另一套。")
                or ("点击试听「" .. e.sound .. "」，播放中再次点击停止。"),
            onClick = function()
                if IsPlaying(e.key) then
                    StopEntry(e.key, 200)
                else
                    PlayEntry(e)
                end
            end,
        })
        y = y - h
    end

    _, h = W:WideButton(parent, "停止全部正在播放的音效", y, function() StopAll(150) end)
    y = y - h
    return y
end
