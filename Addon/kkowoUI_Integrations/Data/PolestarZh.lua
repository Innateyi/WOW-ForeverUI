----------------------------------------------------------------------
--  kkowoUI_Integrations — Data/PolestarZh.lua
--  Polestar 全家桶零文件补丁运行时简中注入（官方有译文优先官方，仅补空缺）：
--    • Polestar.L：补齐 74 条界面缺译（原 polestar_zhcn_fill 72 条 + 2 条新增）
--    • Polestar.Names & Compat.GetMapName：补齐 2,090 条实体译名（官方 API + Questie + 43 条审批 AI）
--    • Polestar.GuideTexts：补齐全部缺译指南正文（原补丁迁移 + 669 条新增），保留全部 {kind:id} 占位符
--    • Polestar.Codex.Npc：补齐 456 条 NPC 副标题中文
--  仅简体中文客户端且 Polestar 当前显示语言为 zhCN 时生效；随时可无损卸载。
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, pairs, pcall, rawget, setmetatable, tonumber, type =
    ipairs, pairs, pcall, rawget, setmetatable, tonumber, type
local string_find, string_sub, table_concat = string.find, string.sub, table.concat
local CreateFrame = CreateFrame
local GetLocale = _G.GetLocale

local SUB = {
    ["Accessories Quartermaster"] = "饰品军需官",
    ["Agent of the Black Market"] = "黑市商人",
    ["Alchemist"] = "炼金师",
    ["Alchemy & Herbalism Supplies"] = "炼金和草药学供应商",
    ["Alchemy Supplies"] = "炼金供应商",
    ["Alchemy Trainer"] = "炼金术训练师",
    ["Ale and Wine"] = "麦酒和葡萄酒",
    ["Alterac Valley Battlemaster"] = "奥特兰克山谷战场军官",
    ["Ammunition Vendor"] = "弹药商",
    ["Antiques"] = "古董商",
    ["Apprentice Armorer"] = "护甲商学徒",
    ["Apprentice Clothier"] = "布料商学徒",
    ["Apprentice Herbalist"] = "草药师学徒",
    ["Apprentice Weaponsmith"] = "武器锻造师学徒",
    ["Apprentice Witch Doctor"] = "巫医学徒",
    ["Apprentice of Cheese"] = "奶酪学徒",
    ["Arathi Basin Battlemaster"] = "阿拉希盆地战场军官",
    ["Arcane Goods"] = "奥术物品商",
    ["Arcane Goods Vendor"] = "奥术物品商",
    ["Arcane Trinkets Vendor"] = "奥术饰品商",
    ["Armor Crafter"] = "护甲匠",
    ["Armor Quartermaster"] = "护甲军需官",
    ["Armorer"] = "护甲商",
    ["Armorer & Shieldcrafter"] = "护甲和盾牌商",
    ["Armorer & Shieldsmith"] = "护甲和盾牌商",
    ["Armorer and Shieldcrafter"] = "护甲和盾牌商",
    ["Armorsmith"] = "护甲锻造师",
    ["Artisan Alchemist"] = "专家级炼金师",
    ["Artisan Armorsmith"] = "专家级护甲锻造师",
    ["Artisan Blacksmith"] = "专家级铁匠",
    ["Artisan Clothier"] = "专家级裁缝",
    ["Artisan Enchanter"] = "专家级附魔师",
    ["Artisan Engineer"] = "专家级工程师",
    ["Artisan Leather Goods"] = "专家级皮具商",
    ["Artisan Leatherworker"] = "专家级制皮师",
    ["Artisan Tailor"] = "专家级裁缝",
    ["Artisan Weapon Crafter"] = "专家级武器匠",
    ["Assistant Innkeeper"] = "旅店老板助手",
    ["Auctioneer"] = "拍卖师",
    ["Axe & Polearm Merchant"] = "斧和长柄武器商",
    ["Axe Merchant"] = "斧商",
    ["Axecrafter"] = "制斧匠",
    ["Bael'dun Morale Officer"] = "巴尔丹士气官",
    ["Bag Merchant"] = "背包商",
    ["Bag Vendor"] = "背包商",
    ["Bags & Sacks"] = "背包和口袋",
    ["Bait and Tackle Supplier"] = "鱼饵和渔具供应商",
    ["Baker"] = "面包师",
    ["Banker"] = "银行职员",
    ["Barmaid"] = "女侍",
    ["Bartender"] = "酒吧侍者",
    ["Basket Weaver"] = "编篮匠",
    ["Bat Handler"] = "蝙蝠管理员",
    ["Beverage Merchant"] = "饮料商",
    ["Blacksmith"] = "铁匠",
    ["Blacksmithing & Mining Supplies"] = "锻造和采矿供应商",
    ["Blacksmithing Supplier"] = "锻造供应商",
    ["Blacksmithing Supplies"] = "锻造供应商",
    ["Blade Merchant"] = "刀剑商",
    ["Blade Trader"] = "刀剑商人",
    ["Blue Moon Odds and Ends"] = "蓝月杂货",
    ["Boat Vendor"] = "船只商人",
    ["Book Dealer"] = "书商",
    ["Booty Bay Quartermaster"] = "藏宝海湾军需官",
    ["Bow & Arrow Merchant"] = "弓箭商",
    ["Bow & Gun Merchant"] = "弓枪商",
    ["Bow Merchant"] = "弓商",
    ["Bowyer"] = "弓匠",
    ["Bowyer & Fletching Goods"] = "弓匠和箭羽商",
    ["Bowyer & Gunsmith"] = "弓匠和枪匠",
    ["Boy with kittens"] = "抱小猫的男孩",
    ["Bread & Cheese Vendor"] = "面包和奶酪商",
    ["Bread Merchant"] = "面包商",
    ["Bread Vendor"] = "面包商",
    ["Brewmaiden"] = "酿酒女",
    ["Brotherhood of the Light"] = "圣光兄弟会",
    ["Butcher"] = "屠夫",
    ["Butler"] = "管家",
    ["Camp Trader"] = "营地商人",
    ["Cenarion Circle"] = "塞纳里奥议会",
    ["Chef"] = "厨师",
    ["Church of the Holy Light"] = "圣光教会",
    ["Cloaks"] = "披风商",
    ["Cloth & Leather Armor"] = "布甲和皮甲",
    ["Cloth & Leather Armor Merchant"] = "布甲和皮甲商",
    ["Cloth Armor Merchant"] = "布甲商",
    ["Cloth Armor and Accessories"] = "布甲和饰品",
    ["Clothier"] = "布料商",
    ["Cobbler"] = "鞋匠",
    ["Cockroach Vendor"] = "蟑螂商",
    ["Consumables and Skillbooks"] = "消耗品和技能书",
    ["Cook"] = "厨师",
    ["Cooking Supplier"] = "烹饪供应商",
    ["Cooking Supplies"] = "烹饪供应商",
    ["Cooking Trainer"] = "烹饪训练师",
    ["Cool Guy"] = "酷哥",
    ["Crazy Cat Lady"] = "疯狂的猫女士",
    ["Dagger & Fist Weapon Merchant"] = "匕首和拳套商",
    ["Darkmoon Faire Cards & Exotic Goods"] = "暗月马戏团卡片和奇异物品",
    ["Darkmoon Faire Drink Vendor"] = "暗月马戏团饮料商",
    ["Darkmoon Faire Exotic Goods"] = "暗月马戏团奇异物品",
    ["Darkmoon Faire Food Vendor"] = "暗月马戏团食物商",
    ["Darkmoon Faire Ticket Redemption"] = "暗月马戏团奖券兑换",
    ["Darkspear Islands Battlemaster"] = "暗矛群岛战场军官",
    ["Darkspear Raiders Quartermaster"] = "暗矛掠夺者军需官",
    ["Darnassus Flight Master"] = "达纳苏斯飞行管理员",
    ["Defilers Supply Officer"] = "污染者补给官",
    ["Demon Master"] = "恶魔大师",
    ["Demon Trainer"] = "恶魔训练师",
    ["Drink Vendor"] = "饮料商",
    ["Druid Trainer"] = "德鲁伊训练师",
    ["Dwarven Weaponsmith"] = "矮人武器锻造师",
    ["Elder Far Seer"] = "年迈的先知",
    ["Emerald Circle"] = "翡翠议会",
    ["Enchanter"] = "附魔师",
    ["Enchanting Supplier"] = "附魔供应商",
    ["Enchanting Supplies"] = "附魔供应商",
    ["Enchanting Trainer"] = "附魔训练师",
    ["Enchants"] = "附魔",
    ["Engineer"] = "工程师",
    ["Engineering & General Goods Supplier"] = "工程学和杂货供应商",
    ["Engineering Goods"] = "工程学物品",
    ["Engineering Supplier"] = "工程学供应商",
    ["Engineering Supplies"] = "工程学供应商",
    ["Engineering Trainer"] = "工程学训练师",
    ["Engineering and Mining Supplies"] = "工程学和采矿供应商",
    ["Everlook Quartermaster"] = "永望镇军需官",
    ["Exotic Item Vendor"] = "奇异物品商",
    ["Exotic Reagent Merchant"] = "奇异材料商",
    ["Expert Alchemist"] = "高级炼金师",
    ["Expert Blacksmith"] = "高级铁匠",
    ["Expert Enchanter"] = "高级附魔师",
    ["Expert Engineer"] = "高级工程师",
    ["Expert Leathercrafter"] = "高级皮革工匠",
    ["Expert Leatherworker"] = "高级制皮师",
    ["Expert Tailor"] = "高级裁缝",
    ["Fashion Designer"] = "时装设计师",
    ["Fireworks Merchant"] = "烟花商",
    ["Fireworks Vendor"] = "烟花商",
    ["First Aid Trainer"] = "急救训练师",
    ["Fish Merchant"] = "鱼商",
    ["Fish Merchant & Supplies"] = "鱼商和渔具供应商",
    ["Fish Vendor"] = "鱼商",
    ["Fisher"] = "渔夫",
    ["Fisherman"] = "渔夫",
    ["Fisherman Supplies"] = "渔夫供应商",
    ["Fishing Supplier"] = "钓鱼供应商",
    ["Fishing Supplies"] = "钓鱼供应商",
    ["Fishing Trainer"] = "钓鱼训练师",
    ["Fishing Trainer & Supplies"] = "钓鱼训练师和供应商",
    ["Fishmaster Apprentice"] = "渔夫学徒",
    ["Fletcher"] = "箭匠",
    ["Flight Master"] = "飞行管理员",
    ["Flight Mistress"] = "飞行管理员",
    ["Florist"] = "花匠",
    ["Food & Drink"] = "食物和饮料",
    ["Food & Drink Merchant"] = "食物和饮料商",
    ["Food & Drink Vendor"] = "食物和饮料商",
    ["Food Vendor"] = "食物商",
    ["Food and Drink"] = "食物和饮料",
    ["Food and Drinks"] = "食物和饮料",
    ["Free Wheeling Merchant"] = "自由商人",
    ["Freewheeling Tradeswoman"] = "自由女商人",
    ["Fresh Apples"] = "新鲜苹果",
    ["Frostwolf Supply Officer"] = "霜狼补给官",
    ["Fruit Seller"] = "水果商",
    ["Fruit Vendor"] = "水果商",
    ["Fungus Vendor"] = "蘑菇商",
    ["Gadgetzan Quartermaster"] = "加基森军需官",
    ["Gearhead"] = "机械师",
    ["Gelkis Clan Quartermaster"] = "吉尔吉斯氏族军需官",
    ["General & Trade Supplies"] = "杂货和商业供应",
    ["General Goods"] = "杂货商",
    ["General Goods Merchant"] = "杂货商",
    ["General Goods Vendor"] = "杂货商",
    ["General Supplies"] = "日用品",
    ["General Trade Goods Merchant"] = "商业货物商",
    ["General Trade Goods Vendor"] = "商业货物商",
    ["General Trade Supplier"] = "商业供应商",
    ["Girl with Puppies"] = "抱小狗的女孩",
    ["Grand Master Rogue"] = "盗贼大宗师",
    ["Gryphon Master"] = "狮鹫管理员",
    ["Guild Tabard Designer"] = "公会徽章设计师",
    ["Guild Tabard Vendor"] = "公会战袍商",
    ["Gun Merchant"] = "枪械商",
    ["Guns Merchant"] = "枪械商",
    ["Guns Vendor"] = "枪械商",
    ["Guns and Ammo Merchant"] = "枪械和弹药商",
    ["Gunsmith"] = "枪匠",
    ["Gunsmith & Bowyer"] = "枪匠和弓匠",
    ["Gurubashi Bloodchanger"] = "古拉巴什换血者",
    ["Hatter"] = "帽匠",
    ["Head Chef"] = "主厨",
    ["Heavy Armor Merchant"] = "重甲商",
    ["Herbalism & Alchemy Supplies"] = "草药学和炼金供应商",
    ["Herbalism Supplier"] = "草药学供应商",
    ["Herbalism Trainer"] = "草药学训练师",
    ["Herbalist"] = "草药师",
    ["High Priest"] = "大祭司",
    ["Hippogryph Master"] = "角鹰兽管理员",
    ["Holiday Fireworks Vendor"] = "节日烟花商",
    ["Horse Breeder"] = "马匹饲养员",
    ["Horse Riding Instructor"] = "骑马教练",
    ["Horse Vendor"] = "马商",
    ["Hunter Trainer"] = "猎人训练师",
    ["Ice Cream Vendor"] = "冰淇淋商",
    ["Innkeeper"] = "旅店老板",
    ["Jewelry Vendor"] = "珠宝商",
    ["Journeyman Alchemist"] = "中级炼金师",
    ["Journeyman Alchemist Trainer"] = "中级炼金术训练师",
    ["Journeyman Blacksmith"] = "中级铁匠",
    ["Journeyman Enchanter"] = "中级附魔师",
    ["Journeyman Engineer"] = "中级工程师",
    ["Journeyman Leatherworker"] = "中级制皮师",
    ["Journeyman Tailor"] = "中级裁缝",
    ["Junior Herbalism Trainer"] = "初级草药学训练师",
    ["Junior Mining Trainer"] = "初级采矿训练师",
    ["Junior Skinning Trainer"] = "初级剥皮训练师",
    ["Keeper of Knowledge"] = "知识守护者",
    ["Kennel Master"] = "犬舍管理员",
    ["Kodo Handler"] = "科多兽管理员",
    ["Kodo Mounts"] = "科多兽坐骑",
    ["Kodo Riding Instructor"] = "科多兽骑术教练",
    ["League of Arathor Supply Officer"] = "阿拉索联军补给官",
    ["Leather & Mail Armor Merchant"] = "皮甲和锁甲商",
    ["Leather Armor & Leatherworking Supplies"] = "皮甲和制皮供应商",
    ["Leather Armor Merchant"] = "皮甲商",
    ["Leatherworker"] = "制皮师",
    ["Leatherworking"] = "制皮",
    ["Leatherworking & Tailoring Supplies"] = "制皮和裁缝供应商",
    ["Leatherworking Recipes"] = "制皮配方",
    ["Leatherworking Supplies"] = "制皮供应商",
    ["Leatherworking Trainer"] = "制皮训练师",
    ["Librarian"] = "图书管理员",
    ["Light Armor & Weapons Merchant"] = "轻甲和武器商",
    ["Light Armor Merchant"] = "轻甲商",
    ["Lorekeeper"] = "博学者",
    ["Lost and Found"] = "失物招领",
    ["Lumberjack"] = "伐木工",
    ["Mace & Staff Merchant"] = "锤和法杖商",
    ["Mace & Staves Vendor"] = "锤和法杖商",
    ["Mace Merchant"] = "锤商",
    ["Macecrafter"] = "制锤匠",
    ["Maces & Staves"] = "锤和法杖",
    ["Mage Trainer"] = "法师训练师",
    ["Magnificent Mystic"] = "华丽的神秘师",
    ["Magram Clan Quartermaster"] = "玛格拉姆氏族军需官",
    ["Mail & Plate Merchant"] = "锁甲和板甲商",
    ["Mail Armor Merchant"] = "锁甲商",
    ["Master Alchemist"] = "炼金大师",
    ["Master Blacksmith"] = "锻造大师",
    ["Master Dragonscale Leatherworker"] = "龙鳞制皮大师",
    ["Master Elemental Leatherworker"] = "元素制皮大师",
    ["Master Enchanter"] = "附魔大师",
    ["Master Engineer"] = "工程大师",
    ["Master Gnome Engineer"] = "侏儒工程大师",
    ["Master Goblin Engineer"] = "地精工程大师",
    ["Master Leatherworker"] = "制皮大师",
    ["Master Leatherworking Trainer"] = "制皮大师训练师",
    ["Master Mage"] = "法师大师",
    ["Master Shadoweave Tailor"] = "暗影布裁缝大师",
    ["Master Tailor"] = "裁缝大师",
    ["Master Tribal Leatherworker"] = "部族制皮大师",
    ["Master Weaponsmith"] = "武器锻造大师",
    ["Master of Cooking Recipes"] = "烹饪配方大师",
    ["Meat Vendor"] = "肉商",
    ["Mechanostrider Merchant"] = "机械陆行鸟商人",
    ["Mechanostrider Pilot"] = "机械陆行鸟驾驶员",
    ["Medic"] = "医师",
    ["Merchant Supreme"] = "至高商人",
    ["Merlot Connoisseur"] = "梅洛葡萄酒鉴赏家",
    ["Metalsmith"] = "金属工匠",
    ["Miner"] = "矿工",
    ["Mining Supplier"] = "采矿供应商",
    ["Mining Supplies"] = "采矿供应商",
    ["Mining Trainer"] = "采矿训练师",
    ["Mining and Smithing Supplies"] = "采矿和锻造供应商",
    ["Mistress of Cheese"] = "奶酪女主人",
    ["Morale Officer"] = "士气官",
    ["Mount Quartermaster"] = "坐骑军需官",
    ["Mount Vendor"] = "坐骑商",
    ["Mule Handler"] = "骡子管理员",
    ["Mushroom Farmer"] = "蘑菇农夫",
    ["Mushroom Merchant"] = "蘑菇商",
    ["Mushroom Seller"] = "蘑菇商",
    ["Mushroom Vendor"] = "蘑菇商",
    ["Mustard Queen"] = "芥末女王",
    ["Night Elf Armorer"] = "暗夜精灵护甲商",
    ["Nightsaber Riding Instructor"] = "夜刃豹骑术教练",
    ["Officer Accessories Quartermaster"] = "军官饰品军需官",
    ["Opportunist Engineer"] = "投机工程师",
    ["Owl Trainer"] = "猫头鹰训练师",
    ["Paladin Trainer"] = "圣骑士训练师",
    ["Panda Cub Caretaker"] = "熊猫幼崽看护者",
    ["Pet Trainer"] = "宠物训练师",
    ["Physician"] = "医师",
    ["Pie Vendor"] = "馅饼商",
    ["Pirate Supplies"] = "海盗补给",
    ["Pissed Vendor"] = "生气的商人",
    ["Poison Supplier"] = "毒药供应商",
    ["Poison Supplies"] = "毒药供应商",
    ["Poison Vendor"] = "毒药商",
    ["Poisons & Reagents"] = "毒药和材料",
    ["Portal Trainer"] = "传送门训练师",
    ["Potions & Herbs"] = "药水和草药",
    ["Potions%2C Scrolls and Reagents"] = "药水、卷轴和材料",
    ["Potions, Scrolls and Reagents"] = "药水、卷轴和材料",
    ["Prairie Dog Vendor"] = "草原土拨鼠商人",
    ["Priest Trainer"] = "牧师训练师",
    ["Purveyor of Lost Goods"] = "失物供应商",
    ["PvP Essentials Vendor"] = "PvP 必需品商",
    ["Quartermaster"] = "军需官",
    ["Race Vendor"] = "竞速商人",
    ["Raid Loot"] = "团队战利品",
    ["Ram Breeder"] = "山羊饲养员",
    ["Ram Riding Instructor"] = "山羊骑术教练",
    ["Raptor Handler"] = "迅猛龙管理员",
    ["Raptor Riding Trainer"] = "迅猛龙骑术训练师",
    ["Rare Goods"] = "稀有物品商",
    ["Ratchet Quartermaster"] = "棘齿城军需官",
    ["Reagent Merchant"] = "材料商",
    ["Reagent Supplier"] = "材料供应商",
    ["Reagent Supplies"] = "材料供应商",
    ["Reagent Vendor"] = "材料商",
    ["Reagents & Magical Goods"] = "材料和魔法物品",
    ["Reagents & Poisons"] = "材料和毒药",
    ["Reagents Vendor"] = "材料商",
    ["Reagents and Herbs"] = "材料和草药",
    ["Reagents/Totems Vendor"] = "材料和图腾商",
    ["Recipe Vendor"] = "配方商",
    ["Repairs"] = "修理",
    ["Robe Merchant"] = "长袍商",
    ["Robe Vendor"] = "长袍商",
    ["Rogue Trainer"] = "盗贼训练师",
    ["Rogue Trainer?"] = "盗贼训练师？",
    ["Royal Apothecary Society"] = "皇家药剂师协会",
    ["Saber Handler"] = "豹类管理员",
    ["Scarlet Quartermaster"] = "血色军需官",
    ["Scrolls & Potions"] = "卷轴和药水",
    ["Security"] = "安保",
    ["Shady Dealer"] = "黑心商人",
    ["Shady Goods"] = "可疑商品",
    ["Shaman Trainer"] = "萨满祭司训练师",
    ["Shield Crafter"] = "盾牌匠",
    ["Shield Merchant"] = "盾牌商",
    ["Shields"] = "盾牌",
    ["Silverwing Supply Officer"] = "银翼补给官",
    ["Skinner"] = "剥皮师",
    ["Skinning Trainer"] = "剥皮训练师",
    ["Smokywood Pastures"] = "烟林牧场",
    ["Snake Vendor"] = "蛇商",
    ["Someone's Minion"] = "某人的仆从",
    ["Soul Seer"] = "灵魂先知",
    ["Special Goods Dealer"] = "特殊物品商",
    ["Special Weapon Crafter"] = "特殊武器匠",
    ["Specialist Leatherworking Supplies"] = "专业制皮供应商",
    ["Specialist Tailoring Supplies"] = "专业裁缝供应商",
    ["Speciality Dress Maker"] = "特殊服装设计师",
    ["Speciality Goods"] = "特殊物品",
    ["Speciality Tailoring Supplies"] = "特殊裁缝供应商",
    ["Specialty Engineer"] = "特殊工程师",
    ["Specialty Goods"] = "特殊物品",
    ["Spirit Spirits"] = "烈酒商",
    ["Stable Master"] = "兽栏管理员",
    ["Stablemaster"] = "兽栏管理员",
    ["Stablemaster and Riding Trainer"] = "兽栏管理员和骑术训练师",
    ["Staff & Mace Merchant"] = "法杖和锤商",
    ["Staff Merchant"] = "法杖商",
    ["Staves Merchant"] = "法杖商",
    ["Stormpike Supply Officer"] = "雷矛补给官",
    ["Stylish Clothier"] = "时尚布料商",
    ["Superior Armor Crafter"] = "精良护甲匠",
    ["Superior Armorer"] = "精良护甲商",
    ["Superior Armorsmith"] = "精良护甲锻造师",
    ["Superior Axecrafter"] = "精良制斧匠",
    ["Superior Bowyer"] = "精良弓匠",
    ["Superior Butcher"] = "精良屠夫",
    ["Superior Cook"] = "精良厨师",
    ["Superior Fisherman"] = "精良渔夫",
    ["Superior Herbalist"] = "精良草药师",
    ["Superior Leatherworker"] = "精良制皮师",
    ["Superior Macecrafter"] = "精良制锤匠",
    ["Superior Tradesman"] = "精良商人",
    ["Superior Weaponsmith"] = "精良武器锻造师",
    ["Supply Officer"] = "补给官",
    ["Sword Merchant"] = "剑商",
    ["Sword and Dagger Merchant"] = "剑和匕首商",
    ["Tabard Vendor"] = "战袍商",
    ["Tackle and Bait"] = "渔具和鱼饵",
    ["Tailor"] = "裁缝",
    ["Tailoring"] = "裁缝",
    ["Tailoring & Leatherworking Supplies"] = "裁缝和制皮供应商",
    ["Tailoring Recipes"] = "裁缝配方",
    ["Tailoring Supplies"] = "裁缝供应商",
    ["Tailoring Supplies & Specialty Goods"] = "裁缝供应和特殊物品",
    ["Tailoring Trainer"] = "裁缝训练师",
    ["The Argent Dawn"] = "银色黎明",
    ["The Drunk"] = "醉汉",
    ["The Thorium Brotherhood"] = "瑟银兄弟会",
    ["Theramore Expeditionary Force Quartermaster"] = "塞拉摩远征军军需官",
    ["Thrown Weapons Merchant"] = "投掷武器商",
    ["Thunder Bluff Flight Master"] = "雷霆崖飞行管理员",
    ["Tools & Supplies"] = "工具和日用品",
    ["Totem Merchent"] = "图腾商",
    ["Toy Vendor"] = "玩具商",
    ["Trade Goods"] = "商业货物",
    ["Trade Goods Supplier"] = "商业货物供应商",
    ["Trade Goods Supplies"] = "商业货物供应商",
    ["Trade Supplier"] = "商业供应商",
    ["Trade Supplies"] = "商业供应商",
    ["Tradesman"] = "商人",
    ["Tradeswoman"] = "女商人",
    ["Transmogrifier"] = "幻化师",
    ["Trauma Surgeon"] = "创伤外科医生",
    ["Traveling Baker"] = "旅行面包师",
    ["Traveling Merchant"] = "旅行商人",
    ["Traveling Ranged Weapon Salesman"] = "旅行远程武器商",
    ["Traveling Salesman"] = "旅行推销员",
    ["Tribal Leatherworking Trainer"] = "部族制皮训练师",
    ["Trinkets & Charms"] = "饰品和护符",
    ["Two Handed Weapon Merchant"] = "双手武器商",
    ["Two-Handed Weapons Merchant"] = "双手武器商",
    ["Uncertified Scribe"] = "无证抄写员",
    ["Undead Horse Merchant"] = "亡灵战马商",
    ["Undead Horse Riding Instructor"] = "亡灵战马骑术教练",
    ["Undermine Trader"] = "安德麦商人",
    ["Venture Armor Salesman"] = "风险投资公司护甲推销员",
    ["Venture Co. Merchant"] = "风险投资公司商人",
    ["Vintner"] = "酿酒师",
    ["Waitress"] = "女服务员",
    ["Wand Merchant"] = "魔杖商",
    ["Wand Vendor"] = "魔杖商",
    ["Wands"] = "魔杖",
    ["Wands Merchant"] = "魔杖商",
    ["War Harness Maker"] = "战斗挽具匠",
    ["War Harness Vendor"] = "战斗挽具商",
    ["Warlock Trainer"] = "术士训练师",
    ["Warrior Trainer"] = "战士训练师",
    ["Warsong Gulch Battlemaster"] = "战歌峡谷战场军官",
    ["Warsong Supply Officer"] = "战歌补给官",
    ["Weapon Crafter"] = "武器匠",
    ["Weapon Dealer"] = "武器商",
    ["Weapon Master"] = "武器大师",
    ["Weapon Merchant"] = "武器商",
    ["Weapon Vendor"] = "武器商",
    ["Weapons Merchant"] = "武器商",
    ["Weapons Quartermaster"] = "武器军需官",
    ["Weaponsmith"] = "武器锻造师",
    ["Weaponsmith & Armorcrafter"] = "武器和护甲锻造师",
    ["Weaponsmith & Armorer"] = "武器锻造师和护甲商",
    ["Weaponsmith & Gunsmith"] = "武器锻造师和枪匠",
    ["Wind Rider Master"] = "双足飞龙管理员",
    ["Wine Vendor"] = "葡萄酒商",
    ["Wintersaber Trainers"] = "冬刃豹训练师",
    ["Wolf Riding Instructor"] = "骑狼教练",
    ["Zandalar Supplies and Repair"] = "赞达拉补给和修理",
}

local function IsZhCN(P)
    if P and P.Names and type(P.Names.Language) == "function" then
        local ok, lang = pcall(P.Names.Language)
        if ok and type(lang) == "string" then
            return lang == "zhCN"
        end
    end
    return GetLocale and GetLocale() == "zhCN"
end

local function ValidStr(s)
    return type(s) == "string" and s ~= ""
end

-- 1) Polestar.L：仅在 rawget(L, k) == nil 时补齐，官方 Polestar_zhCN\Interface.lua 永远优先
local function ApplyInterface(P)
    local L = P and P.L
    local IFACE = F._PolestarInterfaceZH
    if not (IsZhCN(P) and type(L) == "table" and type(IFACE) == "table") then return false end
    for k, v in pairs(IFACE) do
        if rawget(L, k) == nil then
            L[k] = v
        end
    end
    return true
end

-- 2) Polestar.Names & Compat.GetMapName：官方客户端/学习名/官方包永远优先，仅在返回 nil 时兜底
local function HookNames(P)
    local N = P and P.Names
    if not (N and type(N) == "table") then return false end
    if N._kkowoZhNames then return true end
    N._kkowoZhNames = true

    local function Fallback(kind, id)
        if not IsZhCN(P) or type(id) ~= "number" then return nil end
        local data = F._PolestarNamesData
        if type(data) ~= "table" then return nil end
        local t = data[kind]
        if t and t[id] then return t[id] end
        if kind == "map" and data.zone and data.zone[id] then
            return data.zone[id]
        end
        return nil
    end

    local function WrapSingle(field, kind)
        local orig = N[field]
        if type(orig) ~= "function" then return end
        N[field] = function(id, ...)
            local ok, v, r2, r3, r4 = pcall(orig, id, ...)
            if ok and ValidStr(v) then return v, r2, r3, r4 end
            local fb = Fallback(kind, id)
            if fb ~= nil then return fb end
            if ok then return v, r2, r3, r4 end
            return nil
        end
    end

    WrapSingle("Quest", "quest")
    WrapSingle("Item", "item")
    WrapSingle("Npc", "npc")
    WrapSingle("Object", "object")
    WrapSingle("Spell", "spell")
    WrapSingle("Area", "area")
    WrapSingle("Instance", "map")

    if type(N.Get) == "function" then
        local origGet = N.Get
        N.Get = function(kind, id, ...)
            local ok, v, r2, r3, r4 = pcall(origGet, kind, id, ...)
            if ok and ValidStr(v) then return v, r2, r3, r4 end
            local fb = Fallback(kind, id)
            if fb ~= nil then return fb end
            if ok then return v, r2, r3, r4 end
            return nil
        end
    end

    if type(N.Cached) == "function" then
        local origCached = N.Cached
        N.Cached = function(kind, id, cursor, ...)
            local ok, v, r2, r3, r4 = pcall(origCached, kind, id, cursor, ...)
            if ok and ValidStr(v) then return v, r2, r3, r4 end
            local fb = Fallback(kind, id)
            if fb ~= nil then return fb end
            if ok then return v, r2, r3, r4 end
            return nil
        end
    end

    local C = P.Compat
    if C and type(C.GetMapName) == "function" and not C._kkowoZhMap then
        C._kkowoZhMap = true
        local origMap = C.GetMapName
        C.GetMapName = function(id, ...)
            local ok, v, r2, r3 = pcall(origMap, id, ...)
            if ok and ValidStr(v) then return v, r2, r3 end
            if IsZhCN(P) and type(id) == "number" then
                local data = F._PolestarNamesData
                local fb = data and data.zone and data.zone[id] or nil
                if fb ~= nil then return fb end
            end
            if ok then return v, r2, r3 end
            return nil
        end
    end
    return true
end

-- 3) Polestar.GuideTexts：精准识别官方 Texts.lua 未翻译的原文并套用补充译文 + 动态填词
local GUIDE_FIELDS = { "title", "why", "pitch" }
local GUIDE_LISTS = { "pros", "cons" }
local STEP_FIELDS = { "title", "note" }
local GOAL_FIELDS = { "note", "text" }
local EMPTY_GOALS = {}
local FILL_CAP = 8192
local fbState = setmetatable({}, { __mode = "k" })

local function HookGuideTexts(P)
    local GT = P and P.GuideTexts
    if not (GT and type(GT) == "table") then return false end
    if GT._kkowoZhGT then return true end
    GT._kkowoZhGT = true

    local function LocalTokenName(kind, id, en)
        if kind == "zone" then
            if P.Names and P.Names.Localised and P.Names.Native and P.Names.Localised() and P.Names.Native() then
                if P.Compat and P.Compat.GetMapName then
                    local zn = P.Compat.GetMapName(id)
                    if ValidStr(zn) then return zn end
                end
            end
            local data = F._PolestarNamesData
            return data and data.zone and data.zone[id] or nil
        end
        if kind == "skill" then
            return P.L and P.L[en] or nil
        end
        if kind == "spell" or kind == "faction" or kind == "area" then
            return P.Names and P.Names.Get and P.Names.Get(kind, id) or nil
        end
        return P.Names and P.Names.Cached and P.Names.Cached(kind, id) or nil
    end

    local function FillTokens(s, names, live)
        if not string_find(s, "{", 1, true) then return s end
        local parts, n, at, total = {}, 0, 1, 0
        local zh = IsZhCN(P)
        while true do
            local a, b, kind, idStr = string_find(s, "{(%l+):(%d+)}", at)
            if not a then break end
            local prefix = string_sub(s, at, a - 1)
            n = n + 1; parts[n] = prefix; total = total + #prefix
            local en = names and names[kind .. ":" .. idStr]
            local name = en and live and zh and LocalTokenName(kind, tonumber(idStr), en) or nil
            local tok
            if ValidStr(name) then
                tok = name
            elseif ValidStr(en) then
                tok = en
            else
                tok = string_sub(s, a, b)
            end
            n = n + 1; parts[n] = tok; total = total + #tok
            at = b + 1
            if total >= FILL_CAP then break end
        end
        n = n + 1; parts[n] = string_sub(s, at)
        return table_concat(parts, "", 1, n)
    end

    local function NewEntry(def)
        local names = type(def.names) == "table" and def.names or nil
        if names then
            local raw = {}
            for k, v in pairs(names) do
                if ValidStr(k) and ValidStr(v) then raw[k] = v end
            end
            names = raw
        end
        return { names = names, fields = {} }
    end

    local function CollectFields(def, entry, withHeader)
        local fields = entry.fields
        local function Add(holder, key)
            local en = holder[key]
            if not ValidStr(en) then return end
            local n = #fields
            fields[n + 1] = holder ~= def and holder or false
            fields[n + 2] = key
            fields[n + 3] = en
        end
        if withHeader then
            for _, f in ipairs(GUIDE_FIELDS) do Add(def, f) end
            for _, f in ipairs(GUIDE_LISTS) do
                local list = def[f]
                if type(list) == "table" then
                    for i = 1, #list do Add(list, i) end
                end
            end
            if type(def.reward) == "table" then
                for _, r in ipairs(def.reward) do
                    if type(r) == "table" then Add(r, "text") end
                end
            end
        end
        local steps = rawget(def, "steps")
        if type(steps) == "table" then
            for _, step in ipairs(steps) do
                for _, f in ipairs(STEP_FIELDS) do Add(step, f) end
                for _, goal in ipairs(step.goals or EMPTY_GOALS) do
                    if type(goal) == "table" then
                        for _, f in ipairs(GOAL_FIELDS) do Add(goal, f) end
                        if goal.t == "kill" and goal.npc == nil then Add(goal, "target") end
                    end
                end
            end
        end
    end

    local function ApplyFallback(def, entry, from, live, escapeFn)
        if not IsZhCN(P) then return false end
        local GUIDE_ZH = F._PolestarGuideZH
        if type(GUIDE_ZH) ~= "table" then return false end
        local changed = false
        local fields = entry.fields
        for i = from, #fields, 3 do
            local holder, key, en = fields[i] or def, fields[i + 1], fields[i + 2]
            local zh = GUIDE_ZH[en]
            if zh then
                local enRendered = FillTokens(en, entry.names, live)
                if escapeFn then enRendered = escapeFn(enRendered) end
                if holder[key] == enRendered then
                    local zhRendered = FillTokens(zh, entry.names, live)
                    if escapeFn then zhRendered = escapeFn(zhRendered) end
                    if holder[key] ~= zhRendered then
                        holder[key] = zhRendered
                        changed = true
                    end
                end
            end
        end
        return changed
    end

    if type(GT.PackText) == "function" then
        local origPackText = GT.PackText
        GT.PackText = function(packId, s, ...)
            local ok, out, r2, r3 = pcall(origPackText, packId, s, ...)
            if not ok then return s end
            if out == s and IsZhCN(P) and ValidStr(s) then
                local GUIDE_ZH = F._PolestarGuideZH
                if type(GUIDE_ZH) == "table" and GUIDE_ZH[s] then
                    return GUIDE_ZH[s], r2, r3
                end
            end
            return out, r2, r3
        end
    end

    if type(GT.Prepare) == "function" then
        local origPrepare = GT.Prepare
        GT.Prepare = function(def, live, ...)
            local entry = type(def) == "table" and NewEntry(def) or nil
            if entry then
                pcall(CollectFields, def, entry, true)
                fbState[def] = entry
            end
            local ok, r1, r2, r3 = pcall(origPrepare, def, live, ...)
            if entry then pcall(ApplyFallback, def, entry, 1, live, nil) end
            if ok then return r1, r2, r3 end
        end
    end

    if type(GT.PrepareSteps) == "function" then
        local origPrepareSteps = GT.PrepareSteps
        GT.PrepareSteps = function(def, ...)
            local entry = type(def) == "table" and fbState[def] or nil
            local from = 1
            if type(def) == "table" then
                if not entry then
                    entry = NewEntry(def)
                    fbState[def] = entry
                end
                from = #entry.fields + 1
                entry.header = entry.header or (from - 1)
                pcall(CollectFields, def, entry, false)
            end
            local ok, r1, r2, r3 = pcall(origPrepareSteps, def, ...)
            if entry then pcall(ApplyFallback, def, entry, from, true, nil) end
            if ok then return r1, r2, r3 end
        end
    end

    if type(GT.DropSteps) == "function" then
        local origDropSteps = GT.DropSteps
        GT.DropSteps = function(def, ...)
            local ok, r1, r2, r3 = pcall(origDropSteps, def, ...)
            local entry = type(def) == "table" and fbState[def] or nil
            if entry and entry.header then
                for i = #entry.fields, entry.header + 1, -1 do
                    entry.fields[i] = nil
                end
            end
            if ok then return r1, r2, r3 end
        end
    end

    if type(GT.Refresh) == "function" then
        local origRefresh = GT.Refresh
        GT.Refresh = function(def, ...)
            local ok, changed, r2, r3 = pcall(origRefresh, def, ...)
            if not ok then return false end
            local entry = type(def) == "table" and fbState[def] or nil
            if entry then
                local okF, did = pcall(ApplyFallback, def, entry, 1, true, P.EscapeText)
                if okF and did then changed = true end
            end
            return changed, r2, r3
        end
    end
    return true
end

-- 4) Polestar.Codex.Npc：NPC 副标题中文映射
local function HookCodex(P)
    local C = P and P.Codex
    if C and C._kkowoZhSub then return true end
    if not (C and type(C.Npc) == "function") then return false end
    local orig = C.Npc
    C.Npc = function(id, ...)
        local ok, rec, r2, r3 = pcall(orig, id, ...)
        if not ok then return nil end
        if type(rec) == "table" and IsZhCN(P) then
            local s = rec.subName
            if type(s) == "string" and SUB[s] then rec.subName = SUB[s] end
        end
        return rec, r2, r3
    end
    C._kkowoZhSub = true
    return true
end

local function InstallAll()
    local P = _G.Polestar
    if type(P) ~= "table" then return false end
    local okI = ApplyInterface(P)
    local okN = HookNames(P)
    local okG = HookGuideTexts(P)
    HookCodex(P)
    if okI or okN or okG then
        P._kkowoZhRuntime = true
    end
    return P._kkowoZhRuntime == true and (P.Codex and P.Codex._kkowoZhSub == true)
end

if GetLocale and GetLocale() == "zhCN" then
    InstallAll()
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(_, event, name)
        if event == "PLAYER_LOGIN" then
            InstallAll()
            local P = _G.Polestar
            if P and P.Fire and not P._kkowoZhNamesFired and IsZhCN(P) then
                P._kkowoZhNamesFired = true
                pcall(P.Fire, "NAMES_LOADED")
            end
        elseif name == "Polestar" or name == "Polestar_zhCN" or name == "Polestar_Codex" then
            InstallAll()
        end
    end)
end

F.PolestarSubtitleZH = SUB

-- 注册到 /kk selftest 抽查（覆盖 L / Names / GuideTexts / Subtitles 四层共 10 项）
F._LocaleChecks = F._LocaleChecks or {}
F._LocaleChecks.Polestar = function()
    local P = _G.Polestar
    if not (P or F.IsAddOnLoaded("Polestar")) then
        return true, "skipped (not loaded)"
    end
    if type(P) ~= "table" then
        return false, "Polestar table missing"
    end
    InstallAll()
    local hit, total = 0, 10
    if P._kkowoZhRuntime then hit = hit + 1 end
    local L = P.L
    if type(L) == "table" then
        if ValidStr(rawget(L, "A guide to the items 1 quest in your log needs from where it is given, ending at the entrance.")) then hit = hit + 1 end
        if ValidStr(rawget(L, "A guide to the items %d quests in your log need from where they are given, ending at the entrance.")) then hit = hit + 1 end
    end
    local N = P.Names
    if type(N) == "table" and type(N.Get) == "function" then
        if ValidStr(N.Get("quest", 96383)) then hit = hit + 1 end
        if ValidStr(N.Get("npc", 222413)) then hit = hit + 1 end
        if ValidStr(N.Get("item", 213566)) then hit = hit + 1 end
    end
    local GZH = F._PolestarGuideZH
    if type(GZH) == "table" then
        if ValidStr(GZH["Eastern pylon found"]) then hit = hit + 1 end
        if ValidStr(GZH["Western pylon found"]) then hit = hit + 1 end
    end
    if ValidStr(SUB["Auctioneer"]) then hit = hit + 1 end
    if ValidStr(SUB["Banker"]) then hit = hit + 1 end
    return hit == total, "Polestar " .. hit .. "/" .. total
end
