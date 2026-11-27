----------------------------------------------------------------------
--  kkowoUI — Modules/ClassEmote.lua
--  趣味职业表情喊话（/e 橙色自定义表情 + 按职业定制文案 + /kk emote 宏）
--    • 100% 12.x 保密值安全（PlainNumber / PlainString + InChatMessagingLockdown 守卫）
--    • 副本内自动发 /e 橙色表情（配合 EUI 聊天职业着色呈现「职业色名字 + 橙色文案」）；
--      野外组队自动切换小队/团队频道，避免暴雪拦截非硬件事件 /e；单人默认静默不扰民
--    • 支持 3 类自动触发（坐下喝水精准蓝量%、复活/拉人/开门/灵魂石、招牌技能）
--      + 3 个自定义快捷槽位 + /kk 设置页多行弹窗编辑 + /kk emote 一键宏
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_floor, math_max, math_random, pairs, pcall, tostring, type =
    ipairs, math.floor, math.max, math.random, pairs, pcall, tostring, type
local string_byte, string_format = string.byte, string.format
local table_concat = table.concat
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local mod = F.RegisterModule("classEmote", {
    title = "趣味职业表情喊话",
    desc = "按职业发送坐下喝水、复活、传送门与招牌技能表情喊话。",
    group = "social",
    order = 30,
    defaults = {
        enabled = true,
        channelMode = "smart",   -- "smart"（副本/e，野外组队小队） | "instance_emote"（仅副本/e） | "emote_only"（仅/e）
        enableDrink = true,
        drinkManaMax = 85,       -- 蓝量低于该百分比且坐下喝水时触发
        enableUtility = true,    -- 复活 / 灵魂石 / 拉人 / 传送门 / 造水糖
        enableCombat = true,     -- 职业招牌技能通告（脱战/非锁定状态安全发送）
        cooldown = 20,           -- 同类事件防刷屏冷却（秒）
        customLines = {},        -- [classToken] = { [catKey] = "多行文案..." }
        macros = {},             -- ["1"|"2"|"3"] = "自定义宏文案..."
    },
})

local DRINK_SPELL_IDS = {
    [430] = true, [431] = true, [432] = true,
    [1133] = true, [1135] = true, [1137] = true,
    [22734] = true, [25696] = true, [26261] = true,
    [26402] = true, [26473] = true, [27089] = true,
    [29007] = true, [43182] = true, [43183] = true,
    [46755] = true, [57073] = true, [61830] = true,
    [167152] = true, [192002] = true, [274914] = true,
}

-- 默认按职业区分的趣味 /e 文案库（多行自动随机轮换）
-- 支持占位符：{mana}（如 31%）、{target}（目标名）、{spell}（技能名）
local CLASS_PRESETS = {
    PRIEST = {
        drink = {
            "一位法力仅剩{mana}的疲惫医师开始回蓝，TA看起来对队友的死活并不关心",
            "法力只剩{mana}了，默默坐下喝水——现在谁掉血谁自己负责",
            "蓝条见底（{mana}），圣光暂时打烊，请各位施主自求多福",
        },
        utility = {
            "正在施放【{spell}】拉起 {target}，下次站火里记得交挂号费",
            "叹了口气开始吟唱【{spell}】，把 {target} 从天使姐姐手里抢回来",
        },
        combat = {
            "释放了【{spell}】，圣光保佑大家别乱引怪！",
        },
        spells = {
            ["能量灌注"] = { "把【能量灌注】塞进了 {target} 怀里，快打输出别浪费！" },
            ["暗影魔"]   = { "放出了加班狗【暗影魔】，替疲惫的牧师咬回几口蓝" },
            ["渐隐术"]   = { "发动【渐隐术】瞬间降低存在感：别看我，看坦克！" },
            ["心灵尖啸"] = { "忍不住尖叫出【心灵尖啸】，周围的怪被吓得四散奔逃" },
        },
    },
    PALADIN = {
        drink = {
            "一位法力仅剩{mana}的圣光骑士蹲下来喝水，圣光说今天先歇会儿",
            "蓝量仅剩{mana}，正在给圣光电池充电，请坦克手下留情",
        },
        utility = {
            "高举双手对 {target} 施放【{spell}】，圣光叫你起来继续搬砖！",
        },
        combat = {
            "高喊一声为了圣光，施放了【{spell}】！",
        },
        spells = {
            ["圣疗术"]   = { "掏出全部家底对 {target} 拍下【圣疗术】，这条命算圣光借你的！" },
            ["保护祝福"] = { "给 {target} 套上了【保护祝福】，物理怪现在拿你毫无办法" },
            ["保护之手"] = { "给 {target} 套上了【保护之手】，物理怪现在拿你毫无办法" },
            ["圣盾术"]   = { "撑起无敌金身【圣盾术】，优雅地原地看戏几秒" },
            ["自由祝福"] = { "给 {target} 挂上【自由祝福】，快跑，别回头！" },
        },
    },
    DRUID = {
        drink = {
            "一位法力仅剩{mana}的大自然打工仔蹲地喝水，回春术暂时缺货",
            "蓝条仅剩{mana}，正在原地光合作用回蓝，请勿打扰",
        },
        utility = {
            "呼唤翡翠梦境对 {target} 施放【{spell}】，大自然不允许你现在躺平",
        },
        combat = {
            "借着自然之力施放了【{spell}】！",
        },
        spells = {
            ["激活"] = { "给 {target} 塞了一管【激活】，蓝条满血复活！" },
            ["复生"] = { "紧急对 {target} 拍下战复【复生】，快爬起来干活！" },
            ["宁静"] = { "展开双臂吟唱【宁静】，全体站好接受大自然洗礼" },
        },
    },
    SHAMAN = {
        drink = {
            "一位法力仅剩{mana}的元素萨满坐下喝水，图腾都在替TA叹气",
            "蓝量只剩{mana}，元素们拒绝免费加班，先喝两口水",
        },
        utility = {
            "呼唤先祖对 {target} 施放【{spell}】，醒醒，工资还没结呢",
        },
        combat = {
            "引动四方元素施放了【{spell}】！",
        },
        spells = {
            ["嗜血"]         = { "拉响了【嗜血】号角！全员红眼爆发，冲啊！" },
            ["英勇"]         = { "拉响了【英勇】号角！全员红眼爆发，冲啊！" },
            ["法力之潮图腾"] = { "插下了【法力之潮图腾】，法系兄弟快过来蹭蓝！" },
        },
    },
    MAGE = {
        drink = {
            "一位法力仅剩{mana}的移动饮水机正在给自己续杯，喝完这口再轰",
            "蓝量仅剩{mana}，正在猛灌自己搓的矿泉水，别开怪！",
        },
        utility = {
            "挥动法杖施放【{spell}】，要蹭车的抓紧，过时不候！",
        },
        combat = {
            "念动奥术咒语施放了【{spell}】！",
        },
        spells = {
            ["变形术"] = { "把 {target} 变成了可爱的绵羊【变形术】，手滑破羊自觉罚款！" },
            ["唤醒"]   = { "原地旋转【唤醒】吸蓝，请勿打断大型充电现场" },
            ["寒冰屏障"] = { "把自己冻进了【寒冰屏障】，变成了一块安静的冰雕" },
        },
    },
    WARLOCK = {
        drink = {
            "一位法力仅剩{mana}的术士放弃了分流自残，老老实实坐下喝水",
            "蓝量仅剩{mana}，为了不把治疗气哭，决定体面地喝口水",
        },
        utility = {
            "正在进行黑暗仪式【{spell}】，大家快帮忙点一下！",
        },
        combat = {
            "低声念出暗影咒文施放了【{spell}】！",
        },
        spells = {
            ["召唤仪式"] = { "架起了【召唤仪式】，速来两位壮丁点门拉人！" },
            ["灵魂之井"] = { "摆出了【灵魂之井】，绿糖管够，吃完记得给好评" },
            ["制造灵魂石"] = { "搓出了一块散发微光的灵魂石，准备给队友上保险" },
            ["放逐术"]   = { "将 {target} 塞进了异次元【放逐术】，先让它冷静一会" },
        },
    },
    HUNTER = {
        drink = {
            "一位法力仅剩{mana}的猎人蹲下来喝水，宠物在一旁无聊地抠脚",
            "蓝条只剩{mana}，先喝口水再继续给怪修脚",
        },
        utility = {
            "吹响口哨施放【{spell}】，呼唤忠实伙伴归队",
        },
        combat = {
            "拉满弓弦施放了【{spell}】！",
        },
        spells = {
            ["假死"]     = { "演技爆发，一个标准【假死】原地躺平，怪们居然信以为真" },
            ["误导"]     = { "把仇恨礼盒精准打包送给了 {target}，请查收【误导】" },
            ["宁神射击"] = { "一发精准的【宁神射击】给 {target} 降了降火气" },
        },
    },
    WARRIOR = {
        drink = {
            "默默蹲下来喝了口水，虽然没有蓝条但气氛不能输",
        },
        utility = {
            "发出一声震耳欲聋的【{spell}】，振奋全队士气！",
        },
        combat = {
            "怒吼着施放了【{spell}】！",
        },
        spells = {
            ["破釜沉舟"] = { "咬牙拍下【破釜沉舟】强行续命，治疗快看我一眼！" },
            ["盾墙"]     = { "举起大盾开启【盾墙】，现在就算天塌下来也能顶住" },
            ["嘲讽"]     = { "冲着 {target} 大喊一声【嘲讽】：有本事冲我来！" },
            ["挑战怒吼"] = { "发动【挑战怒吼】把全场仇恨都揽到了自己怀里！" },
        },
    },
    ROGUE = {
        drink = {
            "躲在阴影角落里喝了口水，假装自己是个优雅的法系",
        },
        utility = {
            "鬼鬼祟祟地施放了【{spell}】",
        },
        combat = {
            "从阴影中闪现施放了【{spell}】！",
        },
        spells = {
            ["嫁祸诀窍"] = { "顺手把【嫁祸诀窍】塞给 {target}，锅你背，伤害我来打" },
            ["消失"]     = { "扔出一把烟雾弹【消失】得无影无踪，剩下的交给兄弟们了" },
            ["闷棍"]     = { "悄悄给 {target} 敲了一记【闷棍】，大家先别碰它！" },
            ["脚踢"]     = { "干脆利落一记【脚踢】打断了 {target} 的读条！" },
        },
    },
}

local FALLBACK_PRESET = {
    drink = { "法力仅剩{mana}，正在坐下回蓝，请稍等片刻" },
    utility = { "正在施放【{spell}】" },
    combat = { "施放了【{spell}】" },
    spells = {},
}

-- 辅助类法术名称关键字（跨等级匹配，兼容无限服不同等级技能 ID）
local UTILITY_PATTERNS = {
    "复活术", "救赎", "先祖之魂", "复生",
    "灵魂石", "召唤仪式", "灵魂之井",
    "传送门：", "传送门:", "造餐术", "造水术", "造食术",
    "Resurrection", "Redemption", "Ancestral Spirit", "Rebirth",
    "Ritual of Summoning", "Ritual of Souls", "Portal:",
}

local DEFAULT_MACROS = {
    ["1"] = "法力仅剩{mana}，先原地回口蓝，各位请稳住！",
    ["2"] = "正在对 {target} 施放关键支援，请留意走位！",
    ["3"] = "已经准备就绪，随时可以开怪！",
}

local EDIT_CATEGORIES = {
    { key = "drink",   label = "坐下喝水回蓝（自动带 {mana}）" },
    { key = "utility", label = "复活 / 拉人 / 开门 / 灵魂石" },
    { key = "combat",  label = "招牌技能通用兜底文案" },
    { key = "macro1",  label = "自定义快捷宏 1（/kk emote 1）" },
    { key = "macro2",  label = "自定义快捷宏 2（/kk emote 2）" },
    { key = "macro3",  label = "自定义快捷宏 3（/kk emote 3）" },
}

local wasDrinking = false
local lastSentAt = {}
local lastLineIdx = {}
local selectedEditCat = "drink"
local editorFrame = nil

local function CutUTF8Bytes(s, maxBytes)
    if type(s) ~= "string" then return "" end
    if #s <= maxBytes then return s end
    local pos, lastGood = 1, 0
    local len = #s
    while pos <= len do
        local b = string_byte(s, pos)
        local step = (b >= 240 and 4) or (b >= 224 and 3) or (b >= 192 and 2) or 1
        if pos + step - 1 > maxBytes then break end
        lastGood = pos + step - 1
        pos = pos + step
    end
    return s:sub(1, lastGood)
end

local function Trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function GetClassPreset()
    local cls = F.GetPlayerClass()
    return CLASS_PRESETS[cls] or FALLBACK_PRESET, cls
end

local function GetManaPct()
    if not (_G.UnitPowerType and _G.UnitPower and _G.UnitPowerMax) then return nil end
    local pType = F.PlainNumber(_G.UnitPowerType("player"), nil)
    if pType ~= 0 then return nil end -- 仅法力槽（MANA=0）
    local cur = F.PlainNumber(_G.UnitPower("player", 0), nil)
    local max = F.PlainNumber(_G.UnitPowerMax("player", 0), nil)
    if not (cur and max and max > 0) then return nil end
    local pct = math_floor((cur / max) * 100 + 0.5)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    return pct
end

local function SplitLines(raw)
    local out = {}
    if type(raw) ~= "string" or raw == "" then return out end
    for line in (raw:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
        local t = Trim(line)
        if t ~= "" then
            out[#out + 1] = t
        end
    end
    return out
end

local function GetCategoryLines(catKey)
    local db = mod:GetDB()
    local preset, cls = GetClassPreset()
    if catKey == "macro1" or catKey == "macro2" or catKey == "macro3" then
        local idx = catKey:sub(6)
        local custom = type(db.macros) == "table" and db.macros[idx]
        if type(custom) == "string" and Trim(custom) ~= "" then
            return SplitLines(custom)
        end
        return { DEFAULT_MACROS[idx] or DEFAULT_MACROS["1"] }
    end
    local clsMap = type(db.customLines) == "table" and db.customLines[cls]
    local custom = type(clsMap) == "table" and clsMap[catKey]
    if type(custom) == "string" and Trim(custom) ~= "" then
        local parsed = SplitLines(custom)
        if #parsed > 0 then return parsed end
    end
    return preset[catKey] or FALLBACK_PRESET[catKey] or {}
end

local function PickRandomLine(key, list)
    if type(list) ~= "table" or #list == 0 then return nil end
    if #list == 1 then return list[1] end
    local prev = lastLineIdx[key]
    local idx = math_random(1, #list)
    if idx == prev then
        idx = (idx % #list) + 1
    end
    lastLineIdx[key] = idx
    return list[idx]
end

local function FormatTemplate(tpl, ctx)
    if type(tpl) ~= "string" or tpl == "" then return "" end
    local mp = (ctx and ctx.mana) or GetManaPct()
    local manaStr = mp and (tostring(mp) .. "%") or "少量"
    local tgt = (ctx and ctx.target and ctx.target ~= "") and ctx.target or nil
    if not tgt and _G.UnitExists then
        local okE, exists = pcall(_G.UnitExists, "target")
        if okE and not F.IsSecret(exists) and exists then
            local okN, rawN = pcall(_G.UnitName, "target")
            local tn = okN and F.PlainString(rawN, nil) or nil
            if tn and tn ~= "" then tgt = tn end
        end
    end
    tgt = tgt or "目标"
    local sp = (ctx and ctx.spell and ctx.spell ~= "") and ctx.spell or "技能"
    local out = tpl
    -- 内层 gsub 必须加括号只取字符串：其第 2 个返回值（替换次数）会被当成外层 gsub 的最大替换数，为 0 时占位符不会被替换
    out = out:gsub("{mana}", (manaStr:gsub("%%", "%%%%")))
    out = out:gsub("{target}", (tgt:gsub("%%", "%%%%")))
    out = out:gsub("{spell}", (sp:gsub("%%", "%%%%")))
    return CutUTF8Bytes(Trim(out), 240)
end

local function IsInCombatInstance()
    if not _G.GetInstanceInfo then return false end
    local _, iType = _G.GetInstanceInfo()
    return iType == "party" or iType == "raid" or iType == "scenario" or iType == "arena" or iType == "pvp"
end

local function ResolveGroupChannel()
    if not (_G.IsInGroup and _G.IsInGroup()) then return nil end
    local instCat = _G.LE_PARTY_CATEGORY_INSTANCE
    if instCat and _G.IsInGroup(instCat) then
        return "INSTANCE_CHAT"
    elseif _G.IsInRaid and _G.IsInRaid() then
        return "RAID"
    end
    return "PARTY"
end

local function SendEmoteMessage(text, isManual)
    if type(text) ~= "string" or text == "" then return false end
    local ci = _G.C_ChatInfo
    if ci and ci.InChatMessagingLockdown then
        local okL, locked = pcall(ci.InChatMessagingLockdown)
        if okL and not F.IsSecret(locked) and locked == true then
            return false
        end
    end
    local sendFn = (ci and ci.SendChatMessage) or _G.SendChatMessage
    if not sendFn then return false end

    local db = mod:GetDB()
    local mode = db.channelMode or "smart"
    local inInst = IsInCombatInstance()
    local grpChan = ResolveGroupChannel()
    local targetChan = nil

    if isManual then
        -- 手动点击宏/输入 /kk emote 属于硬件事件，任何场景都可直接发送 /e 橙色表情
        targetChan = "EMOTE"
    elseif mode == "instance_emote" then
        if inInst then targetChan = "EMOTE" end
    elseif mode == "emote_only" then
        if inInst or grpChan then targetChan = "EMOTE" end
    else
        -- 默认 "smart"：副本内发 /e 橙色表情；野外组队自动切小队/团队；单人不刷屏
        if inInst then
            targetChan = "EMOTE"
        elseif grpChan then
            targetChan = grpChan
        end
    end

    if not targetChan then return false end
    local ok = pcall(sendFn, text, targetChan)
    return ok == true
end

local function PreviewLocalEmote(text)
    if type(text) ~= "string" or text == "" then return end
    local first, second
    local nameFn = _G.UnitNameUnmodified or _G.UnitName
    if nameFn then first, second = nameFn("player") end
    first = F.PlainString(first, "你")
    second = F.PlainString(second, nil)
    local fullName = (second and second ~= "" and _G.EllesmereUI and _G.EllesmereUI.IS_FOREVER)
        and (first .. " " .. second) or first
    local cls = F.GetPlayerClass()
    local c = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[cls]
    local hex = c and string_format("%02x%02x%02x", math_floor(c.r * 255 + 0.5), math_floor(c.g * 255 + 0.5), math_floor(c.b * 255 + 0.5)) or "ffffff"
    local cf = _G.DEFAULT_CHAT_FRAME
    if cf and cf.AddMessage then
        cf:AddMessage(string_format("|cff%s%s|r |cffff8040%s|r", hex, fullName, text))
    end
end

local function IsOnCooldown(cdKey)
    local now = _G.GetTime and _G.GetTime() or 0
    local cd = mod:GetDB().cooldown or 20
    return lastSentAt[cdKey] ~= nil and (now - lastSentAt[cdKey]) < cd
end

local function MarkCooldown(cdKey)
    lastSentAt[cdKey] = _G.GetTime and _G.GetTime() or 0
end

-- 1) 坐下喝水回蓝检测（仅脱战，100% 避开战斗保密值）
local function IsPlayerDrinkingNow()
    local CA = _G.C_UnitAuras
    if not (CA and CA.GetBuffDataByIndex) then return false end
    for i = 1, 40 do
        local ok, aura = pcall(CA.GetBuffDataByIndex, "player", i)
        if not ok or F.IsSecret(aura) or type(aura) ~= "table" then break end
        local sid = F.PlainNumber(aura.spellId, nil)
        if sid and DRINK_SPELL_IDS[sid] then
            return true
        end
        local name = F.PlainString(aura.name, nil)
        if name and (name:find("喝水", 1, true) or name:find("饮水", 1, true) or name:find("Drink", 1, true) or name:find("Refreshment", 1, true)) then
            return true
        end
    end
    return false
end

local function OnPlayerAuraChanged()
    if not mod._active then return end
    local db = mod:GetDB()
    if db.enableDrink == false then
        wasDrinking = false
        return
    end
    if (_G.InCombatLockdown and _G.InCombatLockdown()) or (_G.UnitAffectingCombat and _G.UnitAffectingCombat("player")) then
        wasDrinking = false
        return
    end
    local drinking = IsPlayerDrinkingNow()
    if drinking and not wasDrinking then
        wasDrinking = true
        local pct = GetManaPct()
        local maxPct = db.drinkManaMax or 85
        if pct and pct <= maxPct and pct < 100 then
            if not IsOnCooldown("drink") then
                local lines = GetCategoryLines("drink")
                local tpl = PickRandomLine("drink", lines)
                if tpl and SendEmoteMessage(FormatTemplate(tpl, { mana = pct }), false) then
                    MarkCooldown("drink")
                end
            end
        end
    elseif not drinking then
        wasDrinking = false
    end
end

-- 2) 辅助技能与职业招牌技能检测
local function ResolveSpellName(spellID)
    if not spellID then return nil end
    if _G.C_Spell and _G.C_Spell.GetSpellInfo then
        local ok, info = pcall(_G.C_Spell.GetSpellInfo, spellID)
        if ok and type(info) == "table" then
            return F.PlainString(info.name, nil)
        end
    elseif _G.GetSpellInfo then
        local ok, name = pcall(_G.GetSpellInfo, spellID)
        if ok then return F.PlainString(name, nil) end
    end
    return nil
end

local function IsUtilitySpell(spellName)
    if type(spellName) ~= "string" or spellName == "" then return false end
    for _, pat in ipairs(UTILITY_PATTERNS) do
        if spellName:find(pat, 1, true) then
            return true
        end
    end
    return false
end

local function OnPlayerSpellSent(_, _, unit, targetName, _, spellID)
    if not mod._active or unit ~= "player" then return end
    local sid = F.PlainNumber(spellID, nil)
    if not sid then return end
    local spellName = ResolveSpellName(sid)
    if not spellName or spellName == "" then return end

    local db = mod:GetDB()
    local preset = GetClassPreset()
    local cleanTarget = F.PlainString(targetName, nil)
    if cleanTarget and cleanTarget:find("-", 1, true) then
        cleanTarget = cleanTarget:match("^([^%-]+)") or cleanTarget
    end

    -- 优先匹配本职业招牌技能专属文案（若用户自定义了对应分类文案则优先采用用户自定义）
    local spellMap = preset.spells
    local clsCustom = type(db.customLines) == "table" and db.customLines[F.GetPlayerClass()]
    if type(spellMap) == "table" and spellMap[spellName] then
        local isUtil = IsUtilitySpell(spellName)
        if (isUtil and db.enableUtility ~= false) or (not isUtil and db.enableCombat ~= false) then
            if not IsOnCooldown("spell:" .. spellName) then
                local customCat = isUtil and "utility" or "combat"
                local customRaw = type(clsCustom) == "table" and clsCustom[customCat]
                local pool = (type(customRaw) == "string" and Trim(customRaw) ~= "") and SplitLines(customRaw) or spellMap[spellName]
                local tpl = PickRandomLine("spell:" .. spellName, pool)
                if tpl and SendEmoteMessage(FormatTemplate(tpl, { target = cleanTarget, spell = spellName }), false) then
                    MarkCooldown("spell:" .. spellName)
                end
            end
        end
        return
    end

    -- 复活 / 拉人 / 传送门 / 造水糖等辅助技能
    if db.enableUtility ~= false and IsUtilitySpell(spellName) then
        if not IsOnCooldown("utility:" .. spellName) then
            local lines = GetCategoryLines("utility")
            local tpl = PickRandomLine("utility", lines)
            if tpl and SendEmoteMessage(FormatTemplate(tpl, { target = cleanTarget, spell = spellName }), false) then
                MarkCooldown("utility:" .. spellName)
            end
        end
    end
end

-- 3) /kk emote 命令入口（绑定宏随时在野外/主城/副本发 /e）
function mod:TriggerCommand(arg)
    local raw = Trim(arg or "")
    local low = raw:lower()
    if low == "preview" or low == "test" then
        local lines = GetCategoryLines("drink")
        local tpl = PickRandomLine("preview", lines) or FALLBACK_PRESET.drink[1]
        PreviewLocalEmote(FormatTemplate(tpl, { mana = GetManaPct() or 31 }))
        F.Print("以上为本地预览；宏用法：/kk emote drink 或 /kk emote 1。")
        return
    end

    local catKey = nil
    if low == "" or low == "drink" or low == "mana" or low == "回蓝" or low == "喝水" then
        catKey = "drink"
    elseif low == "utility" or low == "res" or low == "辅助" or low == "复活" then
        catKey = "utility"
    elseif low == "combat" or low == "skill" or low == "技能" then
        catKey = "combat"
    elseif low == "1" or low == "2" or low == "3" then
        catKey = "macro" .. low
    end

    local msg
    if catKey then
        local lines = GetCategoryLines(catKey)
        local tpl = PickRandomLine("cmd:" .. catKey, lines)
        if not tpl then
            F.Print("该分类暂无文案，请在「职业专属 → 职业表情」中编辑。")
            return
        end
        msg = FormatTemplate(tpl, { mana = GetManaPct() })
    else
        msg = FormatTemplate(raw, { mana = GetManaPct() })
    end

    if msg ~= "" then
        SendEmoteMessage(msg, true)
    end
end

-- 4) 多行自定义文案弹窗编辑器
local function OpenTextEditor(catKey)
    if not editorFrame then
        local f = CreateFrame("Frame", "kkowoUI_EmoteEditor", _G.UIParent)
        f:SetSize(460, 260)
        f:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 80)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetFrameLevel(260)
        f:SetToplevel(true)
        f:SetClampedToScreen(true)
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:HookScript("OnHide", f.StopMovingOrSizing)
        f:Hide()
        F.Theme.StylePanel(f, 0.96, 0.92)
        F.Theme.SetBorderAccent(f, true)

        local title = f:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(title, 13, "", 0.96, 0.96, 0.98, 1)
        title:SetPoint("TOPLEFT", 14, -12)
        f._title = title

        local hint = f:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(hint, 11, "", 0.66, 0.72, 0.80, 1)
        hint:SetPoint("TOPLEFT", 14, -32)
        hint:SetText("每行一条随机文案，支持占位符：{mana} 法力% · {target} 目标 · {spell} 技能名")

        local closeBtn = CreateFrame("Button", nil, f)
        closeBtn:SetSize(22, 22)
        closeBtn:SetPoint("TOPRIGHT", -10, -9)
        F.Theme.StyleGlassSurface(closeBtn, {
            accent = { 0.93, 0.36, 0.43 },
            bgAlpha = 0.78,
            borderAlpha = 0.62,
            restAura = 0.04,
            hoverAura = 0.34,
            borderTintMix = 0.10,
        })
        local cxIcon = closeBtn:CreateTexture(nil, "OVERLAY", nil, 4)
        cxIcon:SetSize(11, 11)
        cxIcon:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
        cxIcon:SetTexture(F.Theme.ICONS .. "Close.tga")
        cxIcon:SetTexCoord(0, 1, 0, 1)
        cxIcon:SetVertexColor(0.80, 0.84, 0.90, 0.92)
        closeBtn:SetScript("OnEnter", function(self)
            F.Theme.SetGlassState(self, true, false)
            cxIcon:SetVertexColor(1.0, 0.88, 0.90, 1.0)
        end)
        closeBtn:SetScript("OnLeave", function(self)
            F.Theme.SetGlassState(self, false, false)
            cxIcon:ClearAllPoints()
            cxIcon:SetPoint("CENTER", self, "CENTER", 0, 0)
            cxIcon:SetVertexColor(0.80, 0.84, 0.90, 0.92)
        end)
        closeBtn:SetScript("OnMouseDown", function(self)
            cxIcon:ClearAllPoints()
            cxIcon:SetPoint("CENTER", self, "CENTER", 0, -1)
        end)
        closeBtn:SetScript("OnMouseUp", function(self)
            cxIcon:ClearAllPoints()
            cxIcon:SetPoint("CENTER", self, "CENTER", 0, 0)
        end)
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        local boxHost = CreateFrame("Frame", nil, f)
        boxHost:SetPoint("TOPLEFT", 14, -52)
        boxHost:SetPoint("BOTTOMRIGHT", -14, 46)
        F.Theme.StylePanel(boxHost, 0.98, 0.75)

        local sf = CreateFrame("ScrollFrame", nil, boxHost, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 6, -6)
        sf:SetPoint("BOTTOMRIGHT", -24, 6)

        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetSize(396, 150)
        eb:SetMaxLetters(1200)
        F.Theme.ApplyFont(eb, 12, "", 0.96, 0.97, 0.99, 1)
        -- 顶部留 3px：当前中文字体的字顶会高出文字框，贴着滚动裁切区时首行字顶会被切掉
        if eb.SetTextInsets then eb:SetTextInsets(2, 2, 3, 2) end
        eb:SetScript("OnEscapePressed", function()
            eb:ClearFocus()
            f:Hide()
        end)
        sf:SetScrollChild(eb)
        boxHost:EnableMouse(true)
        boxHost:SetScript("OnMouseDown", function() eb:SetFocus() end)
        f:SetScript("OnHide", function()
            if eb.ClearFocus then eb:ClearFocus() end
        end)
        f._eb = eb

        F.Theme.RegisterEscapeClose(f, function()
            if eb.ClearFocus then eb:ClearFocus() end
            f:Hide()
        end)

        local saveBtn = CreateFrame("Button", nil, f)
        saveBtn:SetSize(96, 26)
        saveBtn:SetPoint("BOTTOMRIGHT", -14, 12)
        F.Theme.StyleButton(saveBtn, 12)
        saveBtn:SetText("保存文案")
        saveBtn:SetScript("OnClick", function()
            local key = f._catKey
            if not key then return end
            local txt = Trim(eb:GetText() or "")
            local db = mod:GetDB()
            local preset, cls = GetClassPreset()
            if key == "macro1" or key == "macro2" or key == "macro3" then
                db.macros = type(db.macros) == "table" and db.macros or {}
                local defText = Trim(DEFAULT_MACROS[key:sub(6)] or "")
                db.macros[key:sub(6)] = (txt ~= "" and txt ~= defText) and txt or nil
            else
                db.customLines = type(db.customLines) == "table" and db.customLines or {}
                db.customLines[cls] = type(db.customLines[cls]) == "table" and db.customLines[cls] or {}
                local defList = preset[key] or FALLBACK_PRESET[key] or {}
                local defText = Trim(table_concat(defList, "\n"))
                db.customLines[cls][key] = (txt ~= "" and txt ~= defText) and txt or nil
            end
            F.Print("已保存自定义表情文案，留空时恢复职业默认。")
            f:Hide()
        end)

        local prevBtn = CreateFrame("Button", nil, f)
        prevBtn:SetSize(96, 26)
        prevBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
        F.Theme.StyleButton(prevBtn, 12)
        prevBtn:SetText("本地预览")
        prevBtn:SetScript("OnClick", function()
            local lines = SplitLines(eb:GetText() or "")
            local tpl = lines[1] or FALLBACK_PRESET.drink[1]
            PreviewLocalEmote(FormatTemplate(tpl, { mana = GetManaPct() or 31, spell = "复活术" }))
        end)

        local resetBtn = CreateFrame("Button", nil, f)
        resetBtn:SetSize(110, 26)
        resetBtn:SetPoint("BOTTOMLEFT", 14, 12)
        F.Theme.StyleButton(resetBtn, 12)
        resetBtn:SetText("恢复职业默认")
        resetBtn:SetScript("OnClick", function()
            local key = f._catKey
            if not key then return end
            local preset = GetClassPreset()
            if key == "macro1" or key == "macro2" or key == "macro3" then
                eb:SetText(DEFAULT_MACROS[key:sub(6)] or "")
            else
                local def = preset[key] or FALLBACK_PRESET[key] or {}
                eb:SetText(table_concat(def, "\n"))
            end
        end)

        editorFrame = f
    end

    local catLabel = catKey
    for _, c in ipairs(EDIT_CATEGORIES) do
        if c.key == catKey then catLabel = c.label; break end
    end
    editorFrame._catKey = catKey
    editorFrame._title:SetText("编辑表情文案 — " .. catLabel)
    editorFrame._eb:SetText(table_concat(GetCategoryLines(catKey), "\n"))
    editorFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    editorFrame:SetFrameLevel(260)
    editorFrame:Show()
    editorFrame:Raise()
    editorFrame._eb:SetFocus()
end

function mod:OnEnable()
    wasDrinking = false
    self:RegisterUnitEvent("UNIT_AURA", "player", OnPlayerAuraChanged)
    self:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player", OnPlayerSpellSent)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        wasDrinking = false
    end)
end

function mod:OnDisable()
    wasDrinking = false
    if editorFrame then editorFrame:Hide() end
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "频道与触发策略",
        tooltip = "副本内发自定义表情，野外组队自动切小队或团队频道。",
        values = {
            smart          = "组队/副本智能切换（推荐）",
            instance_emote = "仅副本内发自定义表情",
            emote_only     = "组队优先发自定义表情",
        },
        order = { "smart", "instance_emote", "emote_only" },
        getValue = function() return db.channelMode or "smart" end,
        setValue = function(v) db.channelMode = v end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "喝水回蓝喊话",
        tooltip = "脱战坐下喝水且法力低于阈值时发送回蓝表情并带当前百分比。",
        getValue = function() return db.enableDrink ~= false end,
        setValue = function(v) db.enableDrink = v == true end,
    }, {
        type = "slider",
        text = "喝水法力上限 (%)",
        tooltip = "当前法力不高于此值时，坐下喝水才会触发喊话。",
        min = 20, max = 95, step = 5,
        getValue = function() return db.drinkManaMax or 85 end,
        setValue = function(v) db.drinkManaMax = v end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "复活与功能喊话",
        tooltip = "施放复活、灵魂石、召唤仪式、传送门或造餐时发出职业表情。",
        getValue = function() return db.enableUtility ~= false end,
        setValue = function(v) db.enableUtility = v == true end,
    }, {
        type = "toggle",
        text = "招牌技能通告",
        tooltip = "施放本职业招牌技能时发出表情，战斗限制期间自动跳过。",
        getValue = function() return db.enableCombat ~= false end,
        setValue = function(v) db.enableCombat = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "防刷屏冷却 (秒)",
        min = 5, max = 60, step = 5,
        getValue = function() return db.cooldown or 20 end,
        setValue = function(v) db.cooldown = v end,
    }, {
        type = "button",
        text = "本地预览效果",
        noCapture = true,
        tooltip = "仅在自己聊天框预览职业表情效果，不发给他人。",
        onClick = function() mod:TriggerCommand("preview") end,
    })
    y = y - h

    local function buildAdv(w, p, curY)
        local _, rh
        local catVals, catOrd = {}, {}
        for _, c in ipairs(EDIT_CATEGORIES) do
            catVals[c.key] = c.label
            catOrd[#catOrd + 1] = c.key
        end
        _, rh = w:DualRow(p, curY, {
            type = "dropdown",
            text = "自定义文案分类",
            tooltip = "按当前职业独立保存，每行一条随机轮换并支持占位符。",
            values = catVals,
            order = catOrd,
            getValue = function() return selectedEditCat end,
            setValue = function(v) selectedEditCat = v end,
        }, {
            type = "button",
            text = "编辑分类文案",
            noCapture = true,
            tooltip = "打开编辑器修改当前分类文案，也可用 /kk emote 宏触发。",
            onClick = function() OpenTextEditor(selectedEditCat) end,
        })
        curY = curY - rh
        return curY
    end

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("classEmote", W, parent, y, buildAdv, blank)
    else
        y = buildAdv(W, parent, y)
    end
    return y
end
