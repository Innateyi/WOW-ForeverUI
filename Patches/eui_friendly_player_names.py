# -*- coding: utf-8 -*-
"""
补丁：EllesmereUINameplates 不再每次登录强制打开原生友方玩家名字（v2）
「仅名称」样式只在 EUI 首次安装时打开一次；之后尊重玩家在暴雪「姓名板 → 名字 → 友方玩家」里的勾选。
可从原版或已打的 v1 补丁直接升级。支持 --check 只读检测。
"""
import os, re, shutil, sys

# 游戏目录与备份目录可用环境变量覆盖：WOW_FOREVER_DIR（含 Interface 的客户端根目录）/ WOW_BACKUP_ROOT
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'EllesmereUINameplates')
# 默认放在仓库同级的 backups 目录（绝不写进游戏目录）
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')))
MARK = '[kkowo-friendlyname v2]'
MARK_V1 = '[kkowo-friendlyname]'
FILE = 'EUI_Nameplates_CastState.lua'
OLD = '            EllesmereUI.SetCVar("UnitNameFriendlyPlayerName", 1, "EllesmereUINameplates")\n'
V1 = (
    '            -- ' + MARK_V1 + ' 只有「仅名称」样式才需要原生友方玩家名字；「姓名板」样式下保留玩家自己的设置\n'
    '            if nameOnly then EllesmereUI.SetCVar("UnitNameFriendlyPlayerName", 1, "EllesmereUINameplates") end\n'
)
NEW = (
    '            -- ' + MARK + ' 「仅名称」样式只在 EUI 首次安装时打开一次原生友方玩家名字；\n'
    '            -- 之后尊重玩家在暴雪「姓名板 → 名字 → 友方玩家」里的勾选，不再每次登录强制打开\n'
    '            if nameOnly and EllesmereUI._firstInstallPending then EllesmereUI.SetCVar("UnitNameFriendlyPlayerName", 1, "EllesmereUINameplates") end\n'
)


def get_version(root):
    for n in os.listdir(root):
        if n.endswith('.toc'):
            m = re.search(r'^## Version:\s*(\S+)', open(os.path.join(root, n), encoding='utf-8', errors='replace').read(), re.M)
            if m:
                return m.group(1)
    return 'unknown'


def run(addon_dir=DEFAULT_DIR, check_only=False):
    if not os.path.isdir(addon_dir):
        return ('MISSING', f'未找到目录: {addon_dir}')
    ver = get_version(addon_dir)
    path = os.path.join(addon_dir, FILE)
    raw = open(path, 'rb').read().decode('utf-8')
    crlf = '\r\n' in raw
    text = raw.replace('\r\n', '\n')
    if MARK in text:
        return ('APPLIED', f'已应用 {MARK} (v{ver})')
    if text.count(V1) == 1:
        anchor, label = V1, '从 v1 升级'
    elif text.count(OLD) == 1:
        anchor, label = OLD, '原版'
    else:
        return ('ANCHOR_MISMATCH', f'{FILE} 锚点匹配数 原版={text.count(OLD)} v1={text.count(V1)}')
    if check_only:
        return ('READY', f'可安全应用 {MARK}（{label}） (v{ver})')
    bdir = os.path.join(BACKUP_ROOT, f'EllesmereUINameplates_{ver}_原版')
    os.makedirs(bdir, exist_ok=True)
    dst = os.path.join(bdir, FILE)
    if not os.path.exists(dst) and anchor == OLD:
        shutil.copy2(path, dst)
    text = text.replace(anchor, NEW)
    out = text.replace('\n', '\r\n') if crlf else text
    open(path, 'wb').write(out.encode('utf-8'))
    return ('PATCHED', f'已成功打补丁 {MARK}（{label}） (v{ver})')


if __name__ == '__main__':
    chk = '--check' in sys.argv
    args = [a for a in sys.argv[1:] if a != '--check']
    status, msg = run(args[0] if args else DEFAULT_DIR, check_only=chk)
    print(f'[eui_friendly_player_names] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED') else 1)
