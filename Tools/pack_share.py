# -*- coding: utf-8 -*-
r"""
干净脱敏的朋友分享包打包脚本（修复旧脚本残留角色名与调试插件问题）
用法：
  python Tools/pack_share.py [--out <输出目录，默认仓库同级 share>] [--char <WTF 角色目录>] [--dry-run]
  需先设置环境变量 WOW_ACCOUNT_DIR（WTF\Account\<你的账号目录>），可选 WOW_GAME_DIR / WOW_CHAR_DIR
"""
import argparse
import os
import re
import sys
import time
import zipfile

GAME = os.environ.get('WOW_GAME_DIR') or os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
ACCOUNT = os.environ.get('WOW_ACCOUNT_DIR', os.path.join(GAME, 'WTF', 'Account', '<YourAccountID>'))
DEFAULT_CHAR = os.environ.get('WOW_CHAR_DIR', os.path.join(ACCOUNT, '<Realm>', '<CharName>'))

# 排除个人自用插件、网易DD元插件、调试插件与过时迁移存根
SKIP_ADDON_DIRS = {
    '163UI_Info',
    'Polestar_Extras_Mei',
    'BlizzMove_Debug',
    'QuestieTrace',
    'ArcUI',
    # 冷却显示已改用 EUI 冷却管理器，ArcAuras 全家不再随包分发
    'ArcAuras',
    'ArcAuras_Finds',
    'ArcAuras_LFG',
}
SKIP_ADDON_FILES = {'addon_strategy.txt', 'dd_author.toc'}
SKIP_ACC_SV = re.compile(r'^(!BugGrabber|BugSack|Auctionator|QuestieTrace|RXPGuides|EUI-RestedXP|ArcAuras.*|ArcUI|Blizzard_.*)\.lua$')
PRIVACY_RE = re.compile(r'CHAT_MSG_|\|Hplayer:|[^\s"#]{2,}#\d{4,6}\b', re.I)

# 脱敏清空表：(文件名, 外层键, [内层键列表])
BLANK_RULES = [
    ('EUI_Haalandtool.lua', 'contacts', ['favorites', 'alts']),
    ('EUI_Haalandtool.lua', 'general', ['_char']),
    ('EUI_Haalandtool.lua', 'warband', ['characters']),
    ('KkowoUI.lua', 'socialTools', ['favorites', 'alts']),
]


def _table_end(text, open_pos):
    depth, i, n = 0, open_pos, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError('unbalanced lua table')


def scrub_sv(text, rules):
    for _, outer, inners in rules:
        o = text.find(f'["{outer}"] = {{')
        if o < 0:
            continue
        o_open = text.index('{', o)
        o_end = _table_end(text, o_open)
        for key in inners:
            block = text[o_open:o_end]
            k = block.find(f'["{key}"] = {{')
            if k < 0:
                continue
            k_open = o_open + block.index('{', k)
            k_end = _table_end(text, k_open)
            text = text[:k_open] + '{\n}' + text[k_end + 1:]
            o_end = _table_end(text, o_open)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--char', default=DEFAULT_CHAR,
                    help='本人角色目录 WTF\\Account\\<账号>\\<服务器>\\<角色>：其中的角色名/服务器名会加入隐私扫描')
    ap.add_argument('--out', default=os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'share')))
    ap.add_argument('--dry-run', action='store_true', help='只检查打包清单与脱敏结果，不写 zip')
    args = ap.parse_args()

    sv_dir = os.path.join(ACCOUNT, 'SavedVariables')
    addons_dir = os.path.join(GAME, 'Interface', 'AddOns')
    if not os.path.isdir(addons_dir):
        sys.exit(f'找不到 AddOns 目录：{addons_dir}')
    # 未设置 WOW_ACCOUNT_DIR 时路径里还是占位符：以前会静默打出一个不含任何配置的包
    if '<YourAccountID>' in sv_dir or not os.path.isdir(sv_dir):
        sys.exit(f'找不到 SavedVariables 目录：{sv_dir}\n请先设置环境变量 WOW_ACCOUNT_DIR 指向 WTF\\Account\\<你的账号目录>。')

    # 本人角色名 / 服务器名一旦出现在任何待打包的 SavedVariables 里就中止（例如 AceDB 的 profileKeys["角色 - 服务器"]）
    own_names = []
    char_dir = os.path.normpath(args.char)
    if '<CharName>' not in char_dir and '<Realm>' not in char_dir:
        char_name = os.path.basename(char_dir)
        realm_name = os.path.basename(os.path.dirname(char_dir))
        own_names = [n for n in (char_name, realm_name) if n and len(n) >= 2]
    own_re = re.compile('|'.join(re.escape(n) for n in own_names)) if own_names else None

    addons = [d for d in sorted(os.listdir(addons_dir))
              if os.path.isdir(os.path.join(addons_dir, d)) and d not in SKIP_ADDON_DIRS]
    print(f'预计打包插件目录：{len(addons)} 个（已自动排除：{", ".join(sorted(SKIP_ADDON_DIRS))}）')

    privacy_hits = []
    scrubbed_svs = {}
    if os.path.isdir(sv_dir):
        for fn in sorted(os.listdir(sv_dir)):
            full = os.path.join(sv_dir, fn)
            if not fn.endswith('.lua') or not os.path.isfile(full) or SKIP_ACC_SV.match(fn):
                continue
            txt = open(full, encoding='utf-8', errors='replace').read()
            rules = [r for r in BLANK_RULES if r[0] == fn]
            if rules:
                txt = scrub_sv(txt, rules)
            scrubbed_svs[fn] = txt
            m = PRIVACY_RE.search(txt) or (own_re.search(txt) if own_re else None)
            if m:
                privacy_hits.append((fn, txt[max(0, m.start() - 40):m.end() + 40].replace('\n', ' ')))

    if privacy_hits:
        print('隐私扫描命中：')
        for fn, ctx in privacy_hits:
            print(f'  {fn}: ...{ctx}...')
        sys.exit('检测到潜在隐私信息，已中止打包。')

    if args.dry_run:
        print(f'Dry-run 通过：共 {len(scrubbed_svs)} 份 SavedVariables 通过脱敏与隐私扫描，未生成文件。')
        return

    os.makedirs(args.out, exist_ok=True)
    stamp = time.strftime('%Y%m%d')
    zpath = os.path.join(args.out, f'KkowoUI整合包_{stamp}.zip')
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for d in addons:
            base = os.path.join(addons_dir, d)
            for dp, _, fns in os.walk(base):
                for fn in fns:
                    if fn in SKIP_ADDON_FILES:
                        continue
                    full = os.path.join(dp, fn)
                    rel = os.path.relpath(full, addons_dir).replace(os.sep, '/')
                    z.write(full, f'Interface/AddOns/{rel}')
        for fn, txt in scrubbed_svs.items():
            z.writestr(f'WTF/Account/SavedVariables/{fn}', txt.encode('utf-8'))
    print(f'打包完成：{zpath} ({os.path.getsize(zpath) / 1048576:.1f} MB)')


if __name__ == '__main__':
    main()
