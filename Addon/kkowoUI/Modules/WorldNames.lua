----------------------------------------------------------------------
--  kkowoUI — Modules/WorldNames.lua
--  游戏物件英文名汉化：
--    无限服新加的传送门等物件，服务器下发的名字只有英文（如「Portal to Grom'gol」），
--    中文客户端数据里没有对应译名，靠近时头顶的交互名牌就显示英文大写。
--    这里在物件名牌（软目标交互名牌）出现时找到显示该名字的文字，换成中文；
--    并给那段文字挂一个 SetText 钩子，名牌被复用、重新写名字时也自动换成中文。
--    只翻译下面规则能识别的名字，其余一律原样放行；保密值一律不读。
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pcall, setmetatable, type = ipairs, pcall, setmetatable, type
local string_lower, string_match, string_find = string.lower, string.match, string.find
local C_Timer = C_Timer

local mod = F.RegisterModule("worldNames", {
    title = "游戏物件英文名汉化",
    desc = "无限服新增的传送门等物件只有英文名（例如 PORTAL TO GROM'GOL），在它们的头顶名牌上改显示中文（传送门：格罗姆高）。",
    group = "quest",
    order = 70,
    defaults = {
        enabled = true,
    },
})

-- 地名（键统一小写，便于匹配引擎写成全大写的名牌）
local PLACE = {}
do
    local raw = {
        ["Grom'gol"] = "格罗姆高", ["Grom'gol Base Camp"] = "格罗姆高营地",
        ["Orgrimmar"] = "奥格瑞玛", ["Undercity"] = "幽暗城", ["Thunder Bluff"] = "雷霆崖",
        ["Silvermoon"] = "银月城", ["Silvermoon City"] = "银月城",
        ["Stormwind"] = "暴风城", ["Stormwind City"] = "暴风城", ["Ironforge"] = "铁炉堡",
        ["Darnassus"] = "达纳苏斯", ["Exodar"] = "埃索达", ["The Exodar"] = "埃索达",
        ["Booty Bay"] = "藏宝海湾", ["Ratchet"] = "棘齿城", ["Menethil Harbor"] = "米奈希尔港",
        ["Theramore"] = "塞拉摩", ["Theramore Isle"] = "塞拉摩岛", ["Auberdine"] = "奥伯丁",
        ["Rut'theran Village"] = "鲁瑟兰村", ["Shattrath"] = "沙塔斯城", ["Shattrath City"] = "沙塔斯城",
        ["Dalaran"] = "达拉然", ["Tirisfal Glades"] = "提瑞斯法林地", ["Durotar"] = "杜隆塔尔",
        ["Stranglethorn"] = "荆棘谷", ["Stranglethorn Vale"] = "荆棘谷", ["Tanaris"] = "塔纳利斯",
        ["Moonglade"] = "月光林地", ["Blasted Lands"] = "诅咒之地", ["Feralas"] = "菲拉斯",
        ["Azshara"] = "艾萨拉", ["Ashenvale"] = "灰谷", ["The Barrens"] = "贫瘠之地",
        ["Mulgore"] = "莫高雷", ["Silithus"] = "希利苏斯", ["Winterspring"] = "冬泉谷",
        ["Un'Goro Crater"] = "安戈洛环形山", ["Felwood"] = "费伍德森林", ["Desolace"] = "凄凉之地",
        ["Dustwallow Marsh"] = "尘泥沼泽", ["Thousand Needles"] = "千针石林", ["Stonetalon Mountains"] = "石爪山脉",
        ["Darkshore"] = "黑海岸", ["Teldrassil"] = "泰达希尔", ["Elwynn Forest"] = "艾尔文森林",
        ["Westfall"] = "西部荒野", ["Duskwood"] = "暮色森林", ["Redridge Mountains"] = "赤脊山",
        ["Loch Modan"] = "洛克莫丹", ["Dun Morogh"] = "丹莫罗", ["Wetlands"] = "湿地",
        ["Arathi Highlands"] = "阿拉希高地", ["Hillsbrad Foothills"] = "希尔斯布莱德丘陵",
        ["Alterac Mountains"] = "奥特兰克山脉", ["Silverpine Forest"] = "银松森林",
        ["Badlands"] = "荒芜之地", ["Searing Gorge"] = "灼热峡谷", ["Burning Steppes"] = "燃烧平原",
        ["Swamp of Sorrows"] = "悲伤沼泽", ["Deadwind Pass"] = "逆风小径", ["The Hinterlands"] = "辛特兰",
        ["Western Plaguelands"] = "西瘟疫之地", ["Eastern Plaguelands"] = "东瘟疫之地",
        ["Hellfire Peninsula"] = "地狱火半岛", ["Caverns of Time"] = "时光之穴",
        ["Karazhan"] = "卡拉赞", ["Zul'Gurub"] = "祖尔格拉布", ["Ahn'Qiraj"] = "安其拉",
        ["Blackrock Mountain"] = "黑石山", ["Light's Hope Chapel"] = "圣光之愿礼拜堂",
        ["Cenarion Hold"] = "塞纳里奥要塞", ["Gadgetzan"] = "加基森", ["Everlook"] = "永望镇",
    }
    for k, v in _G.pairs(raw) do PLACE[string_lower(k)] = v end
end

-- 物件类型前缀（小写模式，() 捕获地名起点 -> 中文前缀）
local RULES = {
    { "^portal to%s+()",   "传送门：" },
    { "^portal:%s*()",     "传送门：" },
    { "^zeppelin to%s+()", "飞艇：" },
    { "^boat to%s+()",     "渡船：" },
    { "^ship to%s+()",     "渡船：" },
    { "^teleport to%s+()", "传送：" },
}

local function PlaceName(lc)
    local zh = PLACE[lc]
    if zh then return zh, true end
    -- 「地名, 区域」两段式
    local a, b = string_match(lc, "^(.-),%s*(.+)$")
    if a and PLACE[a] then
        return PLACE[a] .. "（" .. (PLACE[b] or b) .. "）", true
    end
    return nil, false
end

-- 返回中文名；无法识别或不是纯英文时返回 nil
local function Translate(name)
    if type(name) ~= "string" or F.IsSecret(name) or name == "" then return nil end
    if string_find(name, "[\128-\255]") then return nil end   -- 已含中文等非 ASCII 字符
    local lc = string_lower(name)
    for _, rule in ipairs(RULES) do
        local pos = string_match(lc, rule[1])
        if pos and pos <= #lc then
            -- 纯 ASCII，小写串与原串逐字节对齐，可以按同一位置截出原样大小写的地名
            local zh = PlaceName(lc:sub(pos))
            return rule[2] .. (zh or name:sub(pos))
        end
    end
    return nil
end
mod.Translate = Translate

----------------------------------------------------------------------
--  名牌文字替换
----------------------------------------------------------------------
local WEAK = { __mode = "k" }
local hookedFS = setmetatable({}, WEAK)
local writing = false

local function SetTextRaw(fs, text) fs:SetText(text) end
local function GetTextRaw(fs) return fs:GetText() end

local function OnNameSetText(fs, text)
    if writing or not mod._active then return end
    local zh = Translate(text)
    if not zh then return end
    writing = true
    pcall(SetTextRaw, fs, zh)
    writing = false
end

local function HookAndTranslate(fs, zh)
    if not hookedFS[fs] then
        hookedFS[fs] = true
        pcall(_G.hooksecurefunc, fs, "SetText", OnNameSetText)
    end
    writing = true
    pcall(SetTextRaw, fs, zh)
    writing = false
end

local function GetRegionsRaw(f) return { f:GetRegions() } end
local function GetChildrenRaw(f) return { f:GetChildren() } end
local function GetTypeRaw(o) return o:GetObjectType() end
local function NameFieldRaw(plate)
    local uf = plate.UnitFrame
    return uf and (uf.name or uf.Name)
end

-- 在名牌树里找文字（不分大小写）等于物件英文名的 FontString
local function FindAndTranslate(root, lcName, zh, depth)
    if depth > 5 or not root then return 0 end
    local hits = 0
    local okR, regs = pcall(GetRegionsRaw, root)
    if okR and type(regs) == "table" then
        for _, r in ipairs(regs) do
            local okT, t = pcall(GetTypeRaw, r)
            if okT and t == "FontString" then
                local okG, txt = pcall(GetTextRaw, r)
                if okG and type(txt) == "string" and not F.IsSecret(txt) and string_lower(txt) == lcName then
                    HookAndTranslate(r, zh)
                    hits = hits + 1
                end
            end
        end
    end
    local okC, kids = pcall(GetChildrenRaw, root)
    if okC and type(kids) == "table" then
        for _, ch in ipairs(kids) do
            hits = hits + FindAndTranslate(ch, lcName, zh, depth + 1)
        end
    end
    return hits
end

local function TranslatePlate(unit)
    if not mod._active or type(unit) ~= "string" then return end
    local isObj = _G.UnitIsGameObject and _G.UnitIsGameObject(unit)
    if F.IsSecret(isObj) or not isObj then return end
    local name = _G.UnitName and _G.UnitName(unit)
    local zh = Translate(name)
    if not zh then return end
    local api = _G.C_NamePlate
    if not (api and api.GetNamePlateForUnit) then return end
    local okP, plate = pcall(api.GetNamePlateForUnit, unit)
    if not (okP and plate) then return end
    local hits = FindAndTranslate(plate, string_lower(name), zh, 0)
    if hits == 0 then
        -- 12.1 名牌树里文字可能读出保密值而匹配不上：直接写暴雪名牌的名字字段
        local okF, fs = pcall(NameFieldRaw, plate)
        local okT, t = pcall(GetTypeRaw, okF and fs or nil)
        if okF and fs and okT and t == "FontString" then HookAndTranslate(fs, zh) end
    end
end

local function OnPlateAdded(_, _, unit)
    TranslatePlate(unit)
    -- 名牌的名字有时在事件之后才写进去：下一帧和稍后各补一次
    C_Timer.After(0, function() TranslatePlate(unit) end)
    C_Timer.After(0.15, function() TranslatePlate(unit) end)
end

function mod:OnEnable()
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED", OnPlateAdded)
    self:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED", function()
        OnPlateAdded(nil, nil, "softinteract")
    end)
end

function mod:OnDisable()
    -- 已替换的名牌在下次被引擎写名字时自然恢复英文（钩子检查 _active）
end
