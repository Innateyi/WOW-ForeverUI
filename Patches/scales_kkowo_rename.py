# -*- coding: utf-8 -*-
"""
Scales 改名为 Scales_kkowo（游戏内及自定义列表显示为 Scales by kkowo）

为什么：网易 DD 按文件夹名 + dd_author.toc / X-Curse-Project-ID 认插件。
原名的 Scales 文件夹会被网易 DD 匹配成「Scales哈兰德汉化版」并触发误识别/覆盖。
改名为 Scales_kkowo 并清除 DD/Curse 指纹后，网易 DD 不再将其识别为「Scales哈兰德汉化版」。

做什么（--apply，必须先退出游戏）：
  1. 有原名 Scales 文件夹时：整夹复制到临时目录，移除 dd_author.toc / addon_version.txt，
     重命名全部 Scales*.toc 为 Scales_kkowo*.toc，修改 ## Title 为「Scales by kkowo」，
     注释掉 ## X-Curse-Project-ID，把 UI/Style.lua 与 .toc 中写死的
     Interface\\AddOns\\Scales\\ 路径改为 Scales_kkowo；原 Scales 文件夹整夹移进 backups。
  2. 存档：账号与各角色 SavedVariables 中的 Scales.lua 复制为 Scales_kkowo.lua
     （目标已存在则不动），完整保留权重与小地图设置。
  3. 各角色 AddOns.txt：照抄 Scales 的启用状态补写一行 Scales_kkowo。

支持 --check 只读检测（apply_patches.py 统一调用 run(check_only=...)）。
"""
import os
import re
import shutil
import subprocess
import sys
import time

WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
ADDONS = os.path.join(WOW_ROOT, 'Interface', 'AddOns')
OLD_NAME = 'Scales'
NEW_NAME = 'Scales_kkowo'
OLD_DIR = os.path.join(ADDONS, OLD_NAME)
NEW_DIR = os.path.join(ADDONS, NEW_NAME)
BACKUP_ROOT = os.environ.get(
    'WOW_BACKUP_ROOT',
    os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')),
)
TITLE = '|cff33ccffScales|r by kkowo'
MARK = 'X-KkowoUI-RenamedFrom'
DD_META_FILES = ('dd_author.toc', 'addon_version.txt')

PATH_FIXES = [
    (b'AddOns\\\\' + OLD_NAME.encode() + b'\\\\', b'AddOns\\\\' + NEW_NAME.encode() + b'\\\\'),
    (b'AddOns\\' + OLD_NAME.encode() + b'\\', b'AddOns\\' + NEW_NAME.encode() + b'\\'),
    (b'AddOns/' + OLD_NAME.encode() + b'/', b'AddOns/' + NEW_NAME.encode() + b'/'),
]
TEXT_EXT = ('.lua', '.xml', '.toc')


def wow_running():
    try:
        r = subprocess.run(
            ['tasklist', '/FI', 'IMAGENAME eq Wow.exe'],
            capture_output=True, text=True, encoding='mbcs', errors='replace', timeout=10,
        )
        if r.returncode != 0:
            return True
        return 'Wow.exe' in r.stdout
    except Exception:
        # fail-closed：无法确认游戏是否退出时禁止改盘
        return True


def toc_version(d):
    for n in sorted(os.listdir(d)):
        if n.lower().endswith('.toc') and n.lower() != 'dd_author.toc':
            m = re.search(
                r'^## Version:\s*(\S+)',
                open(os.path.join(d, n), encoding='utf-8', errors='replace').read(),
                re.M,
            )
            if m:
                return m.group(1)
    return 'unknown'


def leftover_paths(d):
    hits = []
    for base, _, files in os.walk(d):
        for f in files:
            if f.lower().endswith(TEXT_EXT) and f.lower() != 'dd_author.toc':
                data = open(os.path.join(base, f), 'rb').read()
                for old, _ in PATH_FIXES:
                    if old in data:
                        hits.append(os.path.relpath(os.path.join(base, f), d))
                        break
    return hits


def has_dd_meta(d):
    return [fn for fn in DD_META_FILES if os.path.exists(os.path.join(d, fn))]


def rewrite_toc(toc_path):
    raw = open(toc_path, 'rb').read().decode('utf-8-sig')
    crlf = '\r\n' in raw
    lines = raw.replace('\r\n', '\n').split('\n')
    out, has_mark = [], False
    for ln in lines:
        if re.match(r'^## Title(?:-[A-Za-z]{4})?:', ln):
            key = ln.split(':', 1)[0]
            ln = f'{key}: {TITLE}'
        elif re.match(r'^## X-Curse-Project-ID:', ln):
            ln = '# Upstream-Curse-Project-ID:' + ln.split(':', 1)[1]
        if ln.startswith('## ' + MARK):
            has_mark = True
        out.append(ln)
    if not has_mark:
        idx = next((i for i, ln in enumerate(out) if ln.startswith('## Version:')), 0)
        out.insert(idx + 1, f'## {MARK}: {OLD_NAME}')
    text = '\n'.join(out)
    if crlf:
        text = text.replace('\n', '\r\n')
    open(toc_path, 'wb').write(text.encode('utf-8'))


def rewrite_tree(d, meta_backup_dir=None):
    # 清除网易 DD 来源指纹文件（移入 backups，绝不直接删除）
    for fn in DD_META_FILES:
        p = os.path.join(d, fn)
        if os.path.exists(p):
            if meta_backup_dir:
                os.makedirs(meta_backup_dir, exist_ok=True)
                shutil.move(p, os.path.join(meta_backup_dir, fn))
            else:
                os.replace(p, p + '.disabled_meta')

    # 替换所有代码/TOC 中写死的贴图路径
    for base, _, files in os.walk(d):
        for f in files:
            if not f.lower().endswith(TEXT_EXT):
                continue
            p = os.path.join(base, f)
            data = open(p, 'rb').read()
            new = data
            for old, rep in PATH_FIXES:
                new = new.replace(old, rep)
            if new != data:
                open(p, 'wb').write(new)

    # 重命名所有 Scales*.toc 为 Scales_kkowo*.toc 并统一标题与去指纹
    for fn in sorted(os.listdir(d)):
        if not fn.lower().endswith('.toc'):
            continue
        src = os.path.join(d, fn)
        if fn == OLD_NAME + '.toc':
            dst = os.path.join(d, NEW_NAME + '.toc')
        elif fn.startswith(OLD_NAME + '_'):
            dst = os.path.join(d, NEW_NAME + fn[len(OLD_NAME):])
        else:
            dst = src
        if dst != src:
            os.replace(src, dst)
        rewrite_toc(dst)


def account_dirs(wow_root=None):
    acc_root = os.path.join(wow_root or os.environ.get('WOW_FOREVER_DIR', WOW_ROOT), 'WTF', 'Account')
    if not os.path.isdir(acc_root):
        return []
    return [
        os.path.join(acc_root, a) for a in os.listdir(acc_root)
        if os.path.isdir(os.path.join(acc_root, a)) and a != 'SavedVariables'
    ]


def char_dirs(acc):
    res = []
    for realm in os.listdir(acc):
        rp = os.path.join(acc, realm)
        if not os.path.isdir(rp) or realm == 'SavedVariables':
            continue
        for ch in os.listdir(rp):
            cp = os.path.join(rp, ch)
            if os.path.isdir(cp):
                res.append(cp)
    return res


def migrate_saved_variables(check_only, wow_root=None):
    todo = done = 0
    for acc in account_dirs(wow_root):
        places = [os.path.join(acc, 'SavedVariables')] + [os.path.join(c, 'SavedVariables') for c in char_dirs(acc)]
        for sv in places:
            src = os.path.join(sv, OLD_NAME + '.lua')
            dst = os.path.join(sv, NEW_NAME + '.lua')
            if os.path.exists(src) and not os.path.exists(dst):
                todo += 1
                if not check_only:
                    shutil.copy2(src, dst)
                    done += 1
    return todo, done


def migrate_addons_txt(check_only, wow_root=None, bk_dir=None):
    todo = done = 0
    root_dir = wow_root or os.environ.get('WOW_FOREVER_DIR', WOW_ROOT)
    acc_root = os.path.join(root_dir, 'WTF', 'Account')
    for acc in account_dirs(root_dir):
        for c in char_dirs(acc):
            p = os.path.join(c, 'AddOns.txt')
            if not os.path.exists(p):
                continue
            raw = open(p, 'rb').read().decode('utf-8', errors='replace')
            crlf = '\r\n' in raw
            lines = raw.replace('\r\n', '\n').split('\n')
            state = None
            has_new = False
            for ln in lines:
                if ':' in ln:
                    name, st = ln.split(':', 1)
                    if name.strip() == OLD_NAME:
                        state = st.strip()
                    elif name.strip() == NEW_NAME:
                        has_new = True
            if state and not has_new:
                todo += 1
                if not check_only:
                    if bk_dir:
                        rel = os.path.relpath(p, acc_root)
                        b_dst = os.path.join(bk_dir, 'AddOnsTxt', rel)
                        os.makedirs(os.path.dirname(b_dst), exist_ok=True)
                        shutil.copy2(p, b_dst)
                    while lines and lines[-1] == '':
                        lines.pop()
                    lines.append(f'{NEW_NAME}: {state}')
                    text = '\n'.join(lines) + '\n'
                    if crlf:
                        text = text.replace('\n', '\r\n')
                    open(p, 'wb').write(text.encode('utf-8'))
                    done += 1
    return todo, done


def title_needs_update(d):
    for fn in sorted(os.listdir(d)):
        if fn.lower().endswith('.toc') and fn.lower() != 'dd_author.toc':
            txt = open(os.path.join(d, fn), encoding='utf-8', errors='replace').read()
            if TITLE not in txt or '## X-Curse-Project-ID:' in txt:
                return True
    return False


def dir_has_files(d):
    if not os.path.isdir(d):
        return False
    for _, _, fns in os.walk(d):
        if fns:
            return True
    return False


def move_retry(src, dst, retries=6, delay=0.4):
    last_err = None
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    for _ in range(retries):
        try:
            shutil.move(src, dst)
            return True, None
        except OSError as e:
            last_err = e
            time.sleep(delay)
    return False, last_err


def run(check_only=False):
    wow_root = os.environ.get('WOW_FOREVER_DIR', WOW_ROOT)
    addons_dir = os.path.join(wow_root, 'Interface', 'AddOns')
    old_dir = os.path.join(addons_dir, OLD_NAME)
    new_dir = os.path.join(addons_dir, NEW_NAME)
    backup_root = os.environ.get('WOW_BACKUP_ROOT', BACKUP_ROOT)

    has_old_dir = os.path.isdir(old_dir)
    has_old = has_old_dir and dir_has_files(old_dir)
    has_old_empty = has_old_dir and not has_old
    has_new = os.path.isdir(new_dir) and dir_has_files(new_dir)
    if not has_old and not has_new:
        return ('SKIPPED', f'未安装 {OLD_NAME}（可选插件，已跳过）')

    sv_todo, _ = migrate_saved_variables(True, wow_root)
    txt_todo, _ = migrate_addons_txt(True, wow_root)
    new_dirty = has_new and (bool(has_dd_meta(new_dir)) or title_needs_update(new_dir))

    if not has_old and not has_old_empty and not sv_todo and not txt_todo and not new_dirty:
        left = leftover_paths(new_dir)
        if left:
            return ('BROKEN', f'{NEW_NAME} 里仍有 {len(left)} 个文件指向旧文件夹：{left[:3]}')
        return ('APPLIED', f'已改名为 {NEW_NAME} (Scales by kkowo, v{toc_version(new_dir)})')

    what = []
    if has_old:
        what.append(f'{OLD_NAME} (v{toc_version(old_dir)}) 待改名为 {NEW_NAME}' + ('并替换现有版' if has_new else ''))
    elif has_old_empty:
        what.append(f'空残留目录 {OLD_NAME} 待移入备份')
    if new_dirty and not has_old:
        what.append(f'{NEW_NAME} 待统一标题并清理 DD/Curse 指纹')
    if sv_todo:
        what.append(f'{sv_todo} 份存档待复制')
    if txt_todo:
        what.append(f'{txt_todo} 个角色 AddOns.txt 待补一行')
    if check_only:
        return ('READY', '；'.join(what))

    if wow_running():
        return ('GAME_RUNNING', '游戏正在运行：请完全退出魔兽世界后再执行（存档与 AddOns.txt 会在退出时被覆盖）')

    stamp = time.strftime('%Y%m%d_%H%M%S')
    bk_session = os.path.join(backup_root, f'{OLD_NAME}_rename_{stamp}')
    os.makedirs(bk_session, exist_ok=True)
    lock_note = ''
    if has_old:
        ver = toc_version(old_dir)
        tmp = os.path.join(bk_session, f'_scales_build_{stamp}')
        shutil.copytree(old_dir, tmp)
        rewrite_tree(tmp, meta_backup_dir=os.path.join(bk_session, 'removed_dd_meta'))
        left = leftover_paths(tmp)
        if left:
            return ('ANCHOR_MISMATCH', f'改名后仍有文件指向旧文件夹：{left[:3]}，未做任何改动（暂存见 {tmp}）')
        if has_new:
            shutil.move(new_dir, os.path.join(bk_session, f'{NEW_NAME}_v{toc_version(new_dir)}_替换前'))
        shutil.move(tmp, new_dir)
        bk_old = os.path.join(bk_session, f'{OLD_NAME}_v{ver}_改名前原文件夹')
        ok_mv, err_mv = move_retry(old_dir, bk_old)
        if not ok_mv:
            lock_note = f'（旧目录 {OLD_NAME} 仍被占用：{err_mv}，关闭网易DD后再运行即可移入备份）'
    elif has_old_empty:
        bk_empty = os.path.join(bk_session, f'{OLD_NAME}_空残留目录')
        ok_mv, err_mv = move_retry(old_dir, bk_empty)
        if not ok_mv:
            lock_note = f'（空目录 {OLD_NAME} 仍被占用：{err_mv}，请先关闭网易DD后再运行）'
    if new_dirty and not has_old:
        shutil.copytree(new_dir, os.path.join(bk_session, f'{NEW_NAME}_v{toc_version(new_dir)}_清理前'))
        rewrite_tree(new_dir, meta_backup_dir=os.path.join(bk_session, 'removed_dd_meta'))

    _, sv_done = migrate_saved_variables(False, wow_root)
    _, txt_done = migrate_addons_txt(False, wow_root, bk_dir=bk_session)
    status = 'WARN_LOCKED' if lock_note else 'PATCHED'
    return (
        status,
        f'{NEW_NAME} (Scales by kkowo, v{toc_version(new_dir)}) 就绪；'
        f'复制存档 {sv_done} 份，补 AddOns.txt {txt_done} 个{lock_note}',
    )


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    status, msg = run(check_only='--apply' not in sys.argv)
    print(f'[scales_kkowo_rename] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED', 'SKIPPED') else 1)
