# -*- coding: utf-8 -*-
"""Generate Addon/kkowoUI_Integrations/Data/CooldownPresets.lua from DungeonsForever's WoW Forever spell data.

Spell IDs on Forever differ from Classic Era (new talents, re-numbered ranks), so the IDs are
read from the client's own DungeonsForeverSpell / DungeonsForeverClass data instead of
Wowhead. Each preset lists every rank, highest first; kkowoUI tracks the highest rank the
character knows and upgrades the bar when a new rank is learned.

Which cooldowns each class tracks follows common Classic-era cooldown packs (Luxthos-style
class packs) and the NGA 无限 class boards (2026-11): rotational cooldowns first, then
major offensive / defensive cooldowns, then utility. Spells with no cooldown never show
(bars hide while the spell is ready), so including a borderline one costs nothing.

Usage: python Tools/gen_cd_presets.py   (re-run after DungeonsForever updates its data)
"""
import io
import os
import re
import sys

ADDONS = os.environ.get("WOW_ADDONS_DIR") or os.path.join(
    os.environ.get("WOW_FOREVER_DIR", r"E:\Program Files\World of Warcraft\_forever_"), "Interface", "AddOns")
SPELLBOOK_EN = os.path.join(ADDONS, "DungeonsForeverSpell", "Core", "Data", "enUS", "Data_SpellBook.lua")
SPELLBOOK_ZH = os.path.join(ADDONS, "DungeonsForeverSpell", "Core", "Data", "Data_SpellBook.lua")
TALENTS = os.path.join(ADDONS, "DungeonsForeverClass", "Core", "Data", "Data_TalentTrees.lua")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Addon", "kkowoUI_Integrations", "Data", "CooldownPresets.lua")

# (key, spellbook English name or None, talent zhCN name or None, custom bar label or None)
PRESETS = {
    "HUNTER": [
        ("rapidfire", "Rapid Fire", None, None),
        ("aimed", "Aimed Shot", None, None),
        ("multishot", "Multi-Shot", None, None),
        ("arcaneshot", "Arcane Shot", None, None),
        ("sniper", "Sniper Shot", "狙击", None),
        ("bestialwrath", None, "狂野怒火", None),
        ("intimidation", None, "胁迫", None),
        ("deterrence", None, "威慑", None),
        ("feign", "Feign Death", None, None),
        ("traps", "Freezing Trap", None, "陷阱"),
    ],
    "WARRIOR": [
        ("mortalstrike", "Mortal Strike", "致死打击", None),
        ("bloodthirst", "Bloodthirst", "嗜血", None),
        ("shieldslam", "Shield Slam", "盾牌猛击", None),
        ("whirlwind", "Whirlwind", None, None),
        ("overpower", "Overpower", None, None),
        ("revenge", "Revenge", None, None),
        ("shieldblock", "Shield Block", None, None),
        ("sweeping", None, "横扫攻击", None),
        ("deathwish", None, "死亡之愿", None),
        ("recklessness", "Recklessness", None, None),
        ("shieldwall", "Shield Wall", None, None),
        ("laststand", None, "破釜沉舟", None),
        ("intercept", "Intercept", None, None),
        ("pummel", "Pummel", None, None),
        ("shieldbash", "Shield Bash", None, None),
        ("berserkerrage", "Berserker Rage", None, None),
    ],
    "ROGUE": [
        ("kidney", "Kidney Shot", None, None),
        ("gouge", "Gouge", None, None),
        ("kick", "Kick", None, None),
        ("coldblood", None, "冷血", None),
        ("bladeflurry", None, "剑刃乱舞", None),
        ("adrenaline", None, "冲动", None),
        ("premeditation", None, "预谋", None),
        ("ghostly", None, "鬼魅攻击", None),
        ("preparation", None, "伺机待发", None),
        ("evasion", "Evasion", None, None),
        ("sprint", "Sprint", None, None),
        ("vanish", "Vanish", None, None),
        ("blind", "Blind", None, None),
    ],
    "MAGE": [
        ("arcanewrath", "Arcane Wrath", "奥术愤怒", None),
        ("fireblast", "Fire Blast", None, None),
        ("blastwave", "Blast Wave", "冲击波", None),
        ("coneofcold", "Cone of Cold", None, None),
        ("frostnova", "Frost Nova", None, None),
        ("arcanepower", None, "奥术强化", None),
        ("pom", None, "气定神闲", None),
        ("combustion", None, "燃烧", None),
        ("coldsnap", None, "急速冷却", None),
        ("icebarrier", "Ice Barrier", "寒冰护体", None),
        ("iceblock", None, "寒冰屏障", None),
        ("counterspell", "Counterspell", None, None),
        ("blink", "Blink", None, None),
        ("evocation", "Evocation", None, None),
    ],
    "PRIEST": [
        ("mindblast", "Mind Blast", None, None),
        ("swd", "Shadow Word: Death", None, None),
        ("penance", "Penance", "苦修", None),
        ("pom", "Prayer of Mending", "愈合祷言", None),
        ("powerinfusion", None, "能量灌注", None),
        ("innerfocus", None, "心灵专注", None),
        ("silence", None, "沉默", None),
        ("scream", "Psychic Scream", None, None),
        ("fade", "Fade", None, None),
        ("desperate", "Desperate Prayer", None, None),
        ("fearward", "Fear Ward", None, None),
    ],
    "PALADIN": [
        ("judgement", "Judgement", None, None),
        ("holystrike", "Holy Strike", None, None),
        ("holyshield", "Holy Shield", "神圣之盾", None),
        ("consecration", "Consecration", None, None),
        ("holyshock", "Holy Shock", "神圣震击", None),
        ("exorcism", "Exorcism", None, None),
        ("hammerofwrath", "Hammer of Wrath", None, None),
        ("holywrath", "Holy Wrath", None, None),
        ("swiftjudgement", None, "迅捷审判", None),
        ("divinefavor", None, "神恩术", None),
        ("bulwark", None, "圣殿骑士壁垒", None),
        ("hoj", "Hammer of Justice", None, None),
        ("repentance", None, "忏悔", None),
        ("divineprotection", "Divine Protection", None, None),
        ("bop", "Blessing of Protection", None, None),
        ("divineshield", "Divine Shield", None, None),
        ("layonhands", "Lay on Hands", None, None),
    ],
    "SHAMAN": [
        # 震击共用冷却：一条「震击」就够，大地 / 烈焰 / 冰霜震击任一施放都会让它走条
        ("shock", "Earth Shock", None, "震击"),
        ("stormstrike", None, "风暴打击", None),
        ("chainlightning", "Chain Lightning", None, None),
        ("firenova", "Fire Nova", None, None),
        ("riptide", "Riptide", "激流", None),
        ("prophetrage", None, "先知之怒", None),
        ("lightningmastery", None, "闪电掌握", None),
        ("ns", None, "自然迅捷", None),
        ("manatide", "Mana Tide Totem", "法力之潮图腾", None),
        ("grounding", "Grounding Totem", None, None),
        ("reincarnation", "Reincarnation", None, None),
    ],
    "WARLOCK": [
        ("shadowburn", "Shadowburn", "暗影灼烧", None),
        ("conflagrate", "Conflagrate", "燃烧", None),
        ("torment", None, "折磨", None),
        ("deathcoil", "Death Coil", None, None),
        ("howl", "Howl of Terror", None, None),
        ("amplify", None, "诅咒增幅", None),
        ("feldomination", None, "恶魔支配", None),
        ("bod", "Bane of Doom", None, None),
        ("inferno", "Inferno", None, None),
    ],
    "DRUID": [
        ("feralcharge", None, "野性冲锋", None),
        ("primalbite", "Primal Bite", "原始撕咬", None),
        ("bash", "Bash", None, None),
        ("enrage", "Enrage", None, None),
        ("powershift", None, "变形之力", None),
        ("dash", "Dash", None, None),
        ("challengingroar", "Challenging Roar", None, None),
        ("barkskin", "Barkskin", None, None),
        ("swiftmend", None, "迅捷治愈", None),
        ("ns", None, "自然迅捷", None),
        ("wildgrowth", "Wild Growth", "野性成长", None),
        ("innervate", "Innervate", None, None),
        ("rebirth", "Rebirth", None, None),
        ("tranquility", "Tranquility", None, None),
        ("hurricane", "Hurricane", None, None),
    ],
}


def parse_spellbook(path):
    src = io.open(path, encoding="utf-8").read()
    data, cls, cur = {}, None, None
    for line in src.splitlines():
        m = re.match(r"^\s{4}([A-Z]+) = \{", line)
        if m:
            cls = m.group(1)
            data[cls] = {}
            continue
        m = re.search(r'\{ name = "([^"]+)", icon = "[^"]*", id = (\d+), learnLv = (\d+)', line)
        if m and cls:
            cur = {"name": m.group(1), "id": int(m.group(2)), "ranks": []}
            data[cls][cur["name"]] = cur
            data[cls].setdefault("_byid", {})[cur["id"]] = cur
            continue
        m = re.search(r"\{ rank = (\d+), learn = \d+, id = (\d+) \}", line)
        if m and cur is not None:
            cur["ranks"].append((int(m.group(1)), int(m.group(2))))
    return data


def parse_talents(path):
    src = io.open(path, encoding="utf-8").read()
    data, cls = {}, None
    for line in src.splitlines():
        m = re.match(r"^\s{4}([A-Z]+) = \{ key", line)
        if m:
            cls = m.group(1)
            data[cls] = {}
            continue
        m = re.search(r'\{ n = "([^"]+)", max = \d+, row = \d+.*?spid = (\d+)', line)
        if m and cls:
            data[cls].setdefault(m.group(1), int(m.group(2)))
    return data


def main():
    book = parse_spellbook(SPELLBOOK_EN)
    bookzh = parse_spellbook(SPELLBOOK_ZH)
    talents = parse_talents(TALENTS)
    lines = [
        "----------------------------------------------------------------------",
        "--  kkowoUI — Data/CooldownPresets.lua（由 Tools/gen_cd_presets.py 生成，勿手改）",
        "--  无限服各职业预设冷却条：法术 ID 取自客户端内 DungeonsForever 的无限服法术数据，",
        "--  每项列出全部等级（高 → 低），运行时取角色已学会的最高等级。",
        "----------------------------------------------------------------------",
        "local _, F = ...",
        "",
        "F.CooldownPresets = {",
    ]
    problems = []
    for cls, entries in PRESETS.items():
        lines.append(f"    {cls} = {{")
        cb = book.get(cls, {})
        byid = cb.get("_byid", {})
        for key, en, tz, label in entries:
            ids = []
            zh = None
            if en:
                sp = cb.get(en)
                if not sp:
                    problems.append(f"{cls}: spellbook has no '{en}'")
                else:
                    ranks = sorted(sp["ranks"], key=lambda r: -r[0])
                    ids = [sp["id"]] + [rid for _, rid in ranks if rid != sp["id"]]
                    zsp = bookzh.get(cls, {}).get("_byid", {}).get(sp["id"])
                    zh = zsp["name"] if zsp else None
            if tz:
                tid = talents.get(cls, {}).get(tz)
                if not tid:
                    problems.append(f"{cls}: talent tree has no '{tz}'")
                elif tid not in ids:
                    ids.append(tid)
                zh = zh or tz
            if not ids:
                continue
            idlist = ", ".join(str(i) for i in ids)
            lab = f', label = "{label}"' if label else ""
            lines.append(f'        {{ key = "{key}", ids = {{ {idlist} }}{lab} }}, -- {zh or en}')
        lines.append("    },")
    lines.append("}")
    io.open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("wrote", os.path.normpath(OUT))
    for p in problems:
        print("WARN", p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
