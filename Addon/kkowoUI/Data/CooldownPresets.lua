----------------------------------------------------------------------
--  kkowoUI — Data/CooldownPresets.lua（由 Tools/gen_cd_presets.py 生成，勿手改）
--  无限服各职业预设冷却条：法术 ID 取自客户端内 DungeonsForever 的无限服法术数据，
--  每项列出全部等级（高 → 低），运行时取角色已学会的最高等级。
----------------------------------------------------------------------
local _, F = ...

F.CooldownPresets = {
    HUNTER = {
        { key = "rapidfire", ids = { 3045 } }, -- 急速射击
        { key = "aimed", ids = { 20904, 20903, 20902, 20901, 20900, 19434 } }, -- 瞄准射击
        { key = "multishot", ids = { 2643 } }, -- 多重射击
        { key = "arcaneshot", ids = { 14287, 14286, 14285, 14284, 14283, 14282, 14281, 3044 } }, -- 奥术射击
        { key = "sniper", ids = { 1310786, 1310785, 1310687 } }, -- 狙击
        { key = "bestialwrath", ids = { 19574 } }, -- 狂野怒火
        { key = "intimidation", ids = { 19577 } }, -- 胁迫
        { key = "deterrence", ids = { 19263 } }, -- 威慑
        { key = "feign", ids = { 5384 } }, -- 假死
        { key = "traps", ids = { 14311, 14310, 1499 }, label = "陷阱" }, -- 冰冻陷阱
    },
    WARRIOR = {
        { key = "mortalstrike", ids = { 21553, 21552, 21551, 12294 } }, -- 致死打击
        { key = "bloodthirst", ids = { 23894, 23893, 23892, 23881 } }, -- 嗜血
        { key = "shieldslam", ids = { 23925, 23924, 23923, 23922 } }, -- 盾牌猛击
        { key = "whirlwind", ids = { 1680 } }, -- 旋风斩
        { key = "overpower", ids = { 11585, 11584, 7887, 7384 } }, -- 压制
        { key = "revenge", ids = { 25288, 11601, 11600, 7379, 6574, 6572 } }, -- 复仇
        { key = "shieldblock", ids = { 2565 } }, -- 盾牌格挡
        { key = "sweeping", ids = { 12292 } }, -- 横扫攻击
        { key = "deathwish", ids = { 12328 } }, -- 死亡之愿
        { key = "recklessness", ids = { 1719 } }, -- 鲁莽
        { key = "shieldwall", ids = { 871 } }, -- 盾墙
        { key = "laststand", ids = { 12975 } }, -- 破釜沉舟
        { key = "intercept", ids = { 20617, 20616, 20252 } }, -- 拦截
        { key = "pummel", ids = { 6554, 6552 } }, -- 拳击
        { key = "shieldbash", ids = { 1672, 1671, 72 } }, -- 盾击
        { key = "berserkerrage", ids = { 18499 } }, -- 狂暴之怒
    },
    ROGUE = {
        { key = "kidney", ids = { 8643, 408 } }, -- 肾击
        { key = "gouge", ids = { 11286, 11285, 8629, 1777, 1776 } }, -- 凿击
        { key = "kick", ids = { 1769, 1768, 1767, 1766 } }, -- 脚踢
        { key = "coldblood", ids = { 14177 } }, -- 冷血
        { key = "bladeflurry", ids = { 13877 } }, -- 剑刃乱舞
        { key = "adrenaline", ids = { 13750 } }, -- 冲动
        { key = "premeditation", ids = { 14183 } }, -- 预谋
        { key = "ghostly", ids = { 14278 } }, -- 鬼魅攻击
        { key = "preparation", ids = { 14185 } }, -- 伺机待发
        { key = "evasion", ids = { 5277 } }, -- 闪避
        { key = "sprint", ids = { 11305, 8696, 2983 } }, -- 疾跑
        { key = "vanish", ids = { 1857, 1856 } }, -- 消失
        { key = "blind", ids = { 2094 } }, -- 致盲
    },
    MAGE = {
        { key = "arcanewrath", ids = { 1326082, 1326081, 1326080, 1326079 } }, -- 奥术愤怒
        { key = "fireblast", ids = { 10199, 10197, 8413, 8412, 2138, 2137, 2136 } }, -- 火焰冲击
        { key = "blastwave", ids = { 13021, 13020, 13019, 13018, 11113 } }, -- 冲击波
        { key = "coneofcold", ids = { 10161, 10160, 10159, 8492, 120 } }, -- 冰锥术
        { key = "frostnova", ids = { 10230, 6131, 865, 122 } }, -- 冰霜新星
        { key = "arcanepower", ids = { 12042 } }, -- 奥术强化
        { key = "pom", ids = { 12043 } }, -- 气定神闲
        { key = "combustion", ids = { 11129 } }, -- 燃烧
        { key = "coldsnap", ids = { 12472 } }, -- 急速冷却
        { key = "icebarrier", ids = { 13033, 13032, 13031, 11426 } }, -- 寒冰护体
        { key = "iceblock", ids = { 11958 } }, -- 寒冰屏障
        { key = "counterspell", ids = { 2139 } }, -- 法术反制
        { key = "blink", ids = { 1953 } }, -- 闪现术
        { key = "evocation", ids = { 12051 } }, -- 唤醒
    },
    PRIEST = {
        { key = "mindblast", ids = { 10947, 10946, 10945, 8106, 8105, 8104, 8103, 8102, 8092 } }, -- 心灵震爆
        { key = "swd", ids = { 1309636, 1309635, 1309633, 1309595 } }, -- 暗言术：灭
        { key = "penance", ids = { 1316995, 1240721, 1240720, 402174 } }, -- 苦修
        { key = "pom", ids = { 1240827, 1240826, 401859 } }, -- 愈合祷言
        { key = "powerinfusion", ids = { 10060 } }, -- 能量灌注
        { key = "innerfocus", ids = { 14751 } }, -- 心灵专注
        { key = "silence", ids = { 15487 } }, -- 沉默
        { key = "scream", ids = { 10890, 10888, 8124, 8122 } }, -- 心灵尖啸
        { key = "fade", ids = { 10942, 10941, 9592, 9579, 9578, 586 } }, -- 渐隐术
        { key = "desperate", ids = { 19243, 19242, 19241, 19240, 19238, 19236, 13908 } }, -- 绝望祷言
        { key = "fearward", ids = { 6346 } }, -- 防护恐惧结界
    },
    PALADIN = {
        { key = "judgement", ids = { 20271 } }, -- 审判
        { key = "holystrike", ids = { 10333, 10332, 5569, 2495, 680, 1866, 678, 679 } }, -- 神圣打击
        { key = "holyshield", ids = { 1239570, 20928, 20927, 20925 } }, -- 神圣之盾
        { key = "consecration", ids = { 20924, 20923, 20922, 20116, 26573 } }, -- 奉献
        { key = "holyshock", ids = { 20930, 20929, 20473, 1311606 } }, -- 神圣震击
        { key = "exorcism", ids = { 10314, 10313, 10312, 5615, 5614, 879 } }, -- 驱邪术
        { key = "hammerofwrath", ids = { 24239, 24274, 24275 } }, -- 愤怒之锤
        { key = "holywrath", ids = { 10318, 2812 } }, -- 神圣愤怒
        { key = "swiftjudgement", ids = { 1310994 } }, -- 迅捷审判
        { key = "divinefavor", ids = { 20216 } }, -- 神恩术
        { key = "bulwark", ids = { 1311015 } }, -- 圣殿骑士壁垒
        { key = "hoj", ids = { 10308, 5589, 5588, 853 } }, -- 制裁之锤
        { key = "repentance", ids = { 20066 } }, -- 忏悔
        { key = "divineprotection", ids = { 5573, 498 } }, -- 圣佑术
        { key = "bop", ids = { 10278, 5599, 1022 } }, -- 保护祝福
        { key = "divineshield", ids = { 1020, 642 } }, -- 圣盾术
        { key = "layonhands", ids = { 10310, 2800, 633 } }, -- 圣疗术
    },
    SHAMAN = {
        { key = "shock", ids = { 10414, 10413, 10412, 8046, 8045, 8044, 8042 }, label = "震击" }, -- 地震术
        { key = "stormstrike", ids = { 17364 } }, -- 风暴打击
        { key = "chainlightning", ids = { 10605, 2860, 930, 421 } }, -- 闪电链
        { key = "firenova", ids = { 408345, 408344, 408343, 408342, 408341 } }, -- 火焰新星
        { key = "riptide", ids = { 1239243, 1239242, 408521 } }, -- 激流
        { key = "prophetrage", ids = { 425336 } }, -- 先知之怒
        { key = "lightningmastery", ids = { 16166 } }, -- 闪电掌握
        { key = "ns", ids = { 16188 } }, -- 自然迅捷
        { key = "manatide", ids = { 1325256, 17359, 17354, 16190 } }, -- 法力之潮图腾
        { key = "grounding", ids = { 8177 } }, -- 根基图腾
        { key = "reincarnation", ids = { 21169 } }, -- 复生
    },
    WARLOCK = {
        { key = "shadowburn", ids = { 18871, 18870, 18869, 18868, 18867, 17877 } }, -- 暗影灼烧
        { key = "conflagrate", ids = { 18932, 18931, 18930, 17962, 1293818, 1293817 } }, -- 燃烧
        { key = "torment", ids = { 1316697 } }, -- 折磨
        { key = "deathcoil", ids = { 17926, 17925, 6789 } }, -- 死亡缠绕
        { key = "howl", ids = { 17928, 5484 } }, -- 恐惧嚎叫
        { key = "amplify", ids = { 18288 } }, -- 诅咒增幅
        { key = "feldomination", ids = { 18708 } }, -- 恶魔支配
        { key = "bod", ids = { 603 } }, -- 末日灾祸
        { key = "inferno", ids = { 1122 } }, -- 地狱火
    },
    DRUID = {
        { key = "feralcharge", ids = { 1238122 } }, -- 野性冲锋
        { key = "primalbite", ids = { 1238073, 1238070, 1238069, 407995 } }, -- 原始撕咬
        { key = "bash", ids = { 8983, 6798, 5211 } }, -- 重击
        { key = "enrage", ids = { 5229 } }, -- 狂怒
        { key = "powershift", ids = { 1322605 } }, -- 变形之力
        { key = "dash", ids = { 9821, 1850 } }, -- 急奔
        { key = "challengingroar", ids = { 5209 } }, -- 挑战咆哮
        { key = "barkskin", ids = { 22812 } }, -- 树皮术
        { key = "swiftmend", ids = { 18562 } }, -- 迅捷治愈
        { key = "ns", ids = { 17116 } }, -- 自然迅捷
        { key = "wildgrowth", ids = { 1238215, 1238214, 408120 } }, -- 野性成长
        { key = "innervate", ids = { 29166 } }, -- 激活
        { key = "rebirth", ids = { 20748, 20747, 20742, 20739, 20484 } }, -- 复生
        { key = "tranquility", ids = { 9863, 9862, 8918, 740 } }, -- 宁静
        { key = "hurricane", ids = { 17402, 17401, 16914 } }, -- 飓风
    },
}
