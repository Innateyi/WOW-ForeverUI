# -*- coding: utf-8 -*-
"""
外科手术式迁移配置：保留 100% 现有界面布局与其他插件设置，仅做：
  1. 预生成 ForeverUI.lua（精准继承原哈兰德各框体坐标、开关与常用联系人）
  2. 更新 当前角色的 AddOns.txt（启用 ForeverUI，停用已被替代/调试/过时插件）
  3. Leatrix_Maps.lua 仅关闭 ShowZoneLevels（避免地图区域等级重复）
  4. EllesmereUI.lua 仅将 euiAccent.useClass 设为 true（全界面统一职业主题色）
"""
import os
import re
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

WTF_ACC = os.environ.get('WOW_ACCOUNT_DIR', r'E:\Program Files\World of Warcraft\_forever_\WTF\Account\<YourAccountID>')
SV_DIR = os.path.join(WTF_ACC, 'SavedVariables')
ADDONS_TXT = os.environ.get('WOW_ADDONS_TXT', os.path.join(WTF_ACC, '<Realm>', '<CharName>', 'AddOns.txt'))

FOREVER_UI_SV = """
ForeverUIDB = {
["version"] = 1,
["migratedFromHaaland"] = true,
["theme"] = {
["accentMode"] = "class",
["combatFadeAlpha"] = 0.18,
},
["positions"] = {
["XPBar"] = {
["point"] = "CENTER",
["relPoint"] = "CENTER",
["x"] = -750,
["y"] = 510,
},
["RepBar"] = {
["point"] = "CENTER",
["relPoint"] = "CENTER",
["x"] = 0,
["y"] = 410,
},
["QuestBar"] = {
["point"] = "CENTER",
["relPoint"] = "CENTER",
["x"] = 820,
["y"] = 290,
},
["CombatAlert"] = {
["point"] = "CENTER",
["relPoint"] = "CENTER",
["x"] = 0,
["y"] = 318.625,
},
["LowValueList"] = {
["point"] = "TOP",
["relPoint"] = "TOP",
["x"] = 383.75,
["y"] = -191.25,
},
},
["modules"] = {
["questAuto"] = {
["enabled"] = true,
["autoAccept"] = false,
["autoTurnIn"] = true,
["skipTrivial"] = true,
["pickBestReward"] = false,
["protectEquipRewards"] = true,
["autoGossip"] = false,
["autoConfirmBind"] = false,
},
["questBar"] = {
["enabled"] = true,
["announce"] = false,
["combatFade"] = true,
["scale"] = 1,
},
["xpBar"] = {
["enabled"] = true,
["width"] = 420,
["height"] = 13,
["fontSize"] = 13,
["showQuestXP"] = true,
["showRested"] = true,
["useClassColor"] = true,
["hideAtMaxLevel"] = true,
["showRepBar"] = false,
["combatFade"] = false,
},
["combatAlert"] = {
["enabled"] = true,
["animation"] = true,
["text"] = true,
["sound"] = false,
["soundEnter"] = "raidwarn",
["soundLeave"] = "ready",
["animationSize"] = 0.5,
["animationAlpha"] = 0.6,
["speed"] = 1,
["fontSize"] = 23,
["enterText"] = "进入战斗",
["leaveText"] = "脱离战斗",
},
["spellSounds"] = {
["enabled"] = true,
["hunterOnly"] = true,
["stopLongOnOOC"] = true,
["channel"] = "Dialog",
["off"] = {
},
},
["durability"] = {
["enabled"] = true,
["useAverage"] = false,
["alignLabel"] = "攻击强度: ",
},
["zoneLabels"] = {
["enabled"] = true,
["showName"] = true,
["colorByDifficulty"] = true,
["fontSize"] = 11,
},
["socialTools"] = {
["enabled"] = true,
["contextMenu"] = true,
["mailContacts"] = true,
["favorites"] = {
},
["alts"] = {
},
},
},
}
"""


def update_addons_txt():
    raw = open(ADDONS_TXT, 'rb').read().decode('utf-8')
    crlf = '\r\n' in raw
    lines = raw.replace('\r\n', '\n').splitlines()

    overrides = {
        'ForeverUI': 'enabled',
        'EUI_Haalandtool': 'disabled',
        'ForeverLootSparkles': 'disabled',
        'ArcUI': 'disabled',
        'BlizzMove_Debug': 'disabled',
        'QuestieTrace': 'disabled',
        'EUI-RestedXP': 'disabled',
    }
    seen = set()
    out = []
    for line in lines:
        m = re.match(r'^([^:]+):\s*(enabled|disabled)\s*$', line)
        if m:
            name = m.group(1).strip()
            if name in overrides:
                out.append(f'{name}: {overrides[name]}')
                seen.add(name)
            else:
                out.append(line)
        else:
            out.append(line)
    for name, state in overrides.items():
        if name not in seen:
            out.append(f'{name}: {state}')

    res = ('\r\n' if crlf else '\n').join(out) + ('\r\n' if crlf else '\n')
    open(ADDONS_TXT, 'wb').write(res.encode('utf-8'))
    print(f'[OK] Updated {ADDONS_TXT}')


def update_leatrix():
    path = os.path.join(SV_DIR, 'Leatrix_Maps.lua')
    raw = open(path, 'rb').read().decode('utf-8')
    crlf = '\r\n' in raw
    text = raw.replace('\r\n', '\n')
    old = '["ShowZoneLevels"] = "On",'
    new = '["ShowZoneLevels"] = "Off",'
    if old in text:
        text = text.replace(old, new, 1)
        out = text.replace('\n', '\r\n') if crlf else text
        open(path, 'wb').write(out.encode('utf-8'))
        print('[OK] Leatrix_Maps.lua: ShowZoneLevels -> Off (船艇/飞点/副本图标均保留)')
    elif new in text:
        print('[OK] Leatrix_Maps.lua: ShowZoneLevels 已是 Off')
    else:
        print('[WARN] Leatrix_Maps.lua: 未找到 ShowZoneLevels 键，跳过')


def update_eui_accent():
    path = os.path.join(SV_DIR, 'EllesmereUI.lua')
    raw = open(path, 'rb').read().decode('utf-8')
    crlf = '\r\n' in raw
    text = raw.replace('\r\n', '\n')
    old = '["euiAccent"] = {\n["useClass"] = false,'
    new = '["euiAccent"] = {\n["useClass"] = true,'
    if old in text:
        text = text.replace(old, new, 1)
        out = text.replace('\n', '\r\n') if crlf else text
        open(path, 'wb').write(out.encode('utf-8'))
        print('[OK] EllesmereUI.lua: euiAccent.useClass -> true（全界面默认职业主题色，布局 100% 不动）')
    elif new in text:
        print('[OK] EllesmereUI.lua: euiAccent.useClass 已是 true')
    else:
        print('[WARN] EllesmereUI.lua: 未找到 euiAccent 块，跳过')


def seed_forever_ui_sv():
    path = os.path.join(SV_DIR, 'ForeverUI.lua')
    open(path, 'wb').write(FOREVER_UI_SV.replace('\n', '\r\n').encode('utf-8'))
    print(f'[OK] Seeded {path}（已继承原哈兰德坐标、自动任务、技能音效、耐久度与常用联系人）')


def main():
    seed_forever_ui_sv()
    update_addons_txt()
    update_leatrix()
    update_eui_accent()


if __name__ == '__main__':
    main()
