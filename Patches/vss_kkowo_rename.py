# -*- coding: utf-8 -*-
"""
VamoosesSlipstream（极速导航）改名为 VamoosesSlipstream_kkowo（极速导航 kkowo优化版）

为什么：网易 DD 按文件夹名认插件。原名的 VSS 会被 DD 当成「哈兰德汉化版」并在更新时整包覆盖，
本地补丁（死亡后提示跑尸路线开关）就丢了。改名后 DD 不再认得它，也就不会再覆盖。

做什么（--apply，必须先退出游戏）：
  1. 有原名文件夹时（第一次改名，或 DD 又把原版装回来了）：先整个备份到 backups，
     以它为底子生成 VamoosesSlipstream_kkowo：改 .toc 文件名与标题、把代码里写死的
     Interface\\AddOns\\VamoosesSlipstream\\ 贴图/字体路径改成新文件夹；原名文件夹移进 backups。
     已有的 kkowo 版会先移进 backups 再替换（DD 装回来的通常是更新的版本）。
  2. 存档：账号与各角色 SavedVariables 里的 VamoosesSlipstream.lua 复制一份为
     VamoosesSlipstream_kkowo.lua（新名的存档已存在则不动），设置与路线记录都保留。
  3. 各角色 AddOns.txt：原名是启用 / 停用，新名照抄一行。
跑尸开关补丁由随后的 vss_corpse_toggle.py 打到新文件夹上（apply_patches.py 会按顺序执行）。

支持 --check 只读检测。
"""
import os
import re
import shutil
import subprocess
import sys
import time

WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
ADDONS = os.path.join(WOW_ROOT, 'Interface', 'AddOns')
OLD_NAME = 'VamoosesSlipstream'
NEW_NAME = 'VamoosesSlipstream_kkowo'
OLD_DIR = os.path.join(ADDONS, OLD_NAME)
NEW_DIR = os.path.join(ADDONS, NEW_NAME)
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')))
TITLE = '|cFFFF007F极速导航|r |cffff559akkowo优化版|r'
MARK = 'X-kkowoUI-RenamedFrom'

# 代码里写死的自身路径（.lua 里是转义后的双反斜杠，.xml/.toc 里是单反斜杠或正斜杠）
PATH_FIXES = [
    (b'AddOns\\\\' + OLD_NAME.encode() + b'\\\\', b'AddOns\\\\' + NEW_NAME.encode() + b'\\\\'),
    (b'AddOns\\' + OLD_NAME.encode() + b'\\', b'AddOns\\' + NEW_NAME.encode() + b'\\'),
    (b'AddOns/' + OLD_NAME.encode() + b'/', b'AddOns/' + NEW_NAME.encode() + b'/'),
]
TEXT_EXT = ('.lua', '.xml', '.toc')


def wow_running():
    try:
        out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Wow.exe'], capture_output=True, text=True,
                             encoding='mbcs', errors='replace', timeout=10).stdout
        return 'Wow.exe' in out
    except Exception:
        return False


def toc_version(d):
    for n in os.listdir(d):
        if n.lower().endswith('.toc'):
            m = re.search(r'^## Version:\s*(\S+)', open(os.path.join(d, n), encoding='utf-8', errors='replace').read(), re.M)
            if m:
                return m.group(1)
    return 'unknown'


def leftover_paths(d):
    """新文件夹里仍指向旧文件夹名的路径（应为 0）"""
    hits = []
    for base, _, files in os.walk(d):
        for f in files:
            if f.lower().endswith(TEXT_EXT):
                data = open(os.path.join(base, f), 'rb').read()
                for old, _ in PATH_FIXES:
                    if old in data:
                        hits.append(os.path.relpath(os.path.join(base, f), d))
                        break
    return hits


def rewrite_tree(d):
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
    # .toc：文件名必须与文件夹同名；标题改成 kkowo优化版，并留一个来源标记
    old_toc = os.path.join(d, OLD_NAME + '.toc')
    new_toc = os.path.join(d, NEW_NAME + '.toc')
    if os.path.exists(old_toc):
        os.replace(old_toc, new_toc)
    raw = open(new_toc, 'rb').read().decode('utf-8-sig')
    crlf = '\r\n' in raw
    lines = raw.replace('\r\n', '\n').split('\n')
    out, has_mark = [], False
    for ln in lines:
        if re.match(r'^## Title(-zhCN|-zhTW)?:', ln):
            key = ln.split(':', 1)[0]
            ln = f'{key}: {TITLE}'
        if ln.startswith('## ' + MARK):
            has_mark = True
        out.append(ln)
    if not has_mark:
        # 放在 ## Version 之后
        idx = next((i for i, ln in enumerate(out) if ln.startswith('## Version:')), 0)
        out.insert(idx + 1, f'## {MARK}: {OLD_NAME}')
    text = '\n'.join(out)
    if crlf:
        text = text.replace('\n', '\r\n')
    open(new_toc, 'wb').write(text.encode('utf-8'))


def account_dirs():
    acc_root = os.path.join(WOW_ROOT, 'WTF', 'Account')
    if not os.path.isdir(acc_root):
        return []
    return [os.path.join(acc_root, a) for a in os.listdir(acc_root)
            if os.path.isdir(os.path.join(acc_root, a)) and a != 'SavedVariables']


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


def migrate_saved_variables(check_only):
    """返回 (待迁移数, 已迁移数)"""
    todo = done = 0
    for acc in account_dirs():
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


def migrate_addons_txt(check_only):
    todo = done = 0
    for acc in account_dirs():
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
                    while lines and lines[-1] == '':
                        lines.pop()
                    lines.append(f'{NEW_NAME}: {state}')
                    text = '\n'.join(lines) + '\n'
                    if crlf:
                        text = text.replace('\n', '\r\n')
                    open(p, 'wb').write(text.encode('utf-8'))
                    done += 1
    return todo, done


def run(check_only=False):
    has_old, has_new = os.path.isdir(OLD_DIR), os.path.isdir(NEW_DIR)
    if not has_old and not has_new:
        return ('MISSING', f'未找到 {OLD_NAME} 或 {NEW_NAME}')
    sv_todo, _ = migrate_saved_variables(True)
    txt_todo, _ = migrate_addons_txt(True)
    if not has_old and not sv_todo and not txt_todo:
        left = leftover_paths(NEW_DIR)
        if left:
            return ('BROKEN', f'{NEW_NAME} 里仍有 {len(left)} 个文件指向旧文件夹：{left[:3]}')
        return ('APPLIED', f'已改名为 {NEW_NAME} (v{toc_version(NEW_DIR)})')
    what = []
    if has_old:
        what.append(f'{OLD_NAME} (v{toc_version(OLD_DIR)}) 待改名' + ('并替换现有 kkowo 版' if has_new else ''))
    if sv_todo:
        what.append(f'{sv_todo} 份存档待复制')
    if txt_todo:
        what.append(f'{txt_todo} 个角色 AddOns.txt 待补一行')
    if check_only:
        return ('READY', '；'.join(what))
    if wow_running():
        return ('GAME_RUNNING', '游戏正在运行：请完全退出魔兽世界后再执行（存档与 AddOns.txt 会在退出时被覆盖）')

    stamp = time.strftime('%Y%m%d_%H%M%S')
    os.makedirs(BACKUP_ROOT, exist_ok=True)
    if has_old:
        ver = toc_version(OLD_DIR)
        tmp = os.path.join(BACKUP_ROOT, f'_vss_build_{stamp}')
        shutil.copytree(OLD_DIR, tmp)
        rewrite_tree(tmp)
        left = leftover_paths(tmp)
        if left:
            shutil.rmtree(tmp, ignore_errors=True)
            return ('ANCHOR_MISMATCH', f'改名后仍有文件指向旧文件夹：{left[:3]}，未做任何改动')
        if has_new:
            shutil.move(NEW_DIR, os.path.join(BACKUP_ROOT, f'{NEW_NAME}_v{toc_version(NEW_DIR)}_替换前_{stamp}'))
        shutil.move(tmp, NEW_DIR)
        shutil.move(OLD_DIR, os.path.join(BACKUP_ROOT, f'{OLD_NAME}_v{ver}_改名前原文件夹_{stamp}'))
    _, sv_done = migrate_saved_variables(False)
    _, txt_done = migrate_addons_txt(False)
    return ('PATCHED', f'{NEW_NAME} (v{toc_version(NEW_DIR)}) 就绪；复制存档 {sv_done} 份，补 AddOns.txt {txt_done} 个；原文件夹已移入 backups')


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    status, msg = run(check_only='--apply' not in sys.argv)
    print(f'[vss_kkowo_rename] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED') else 1)
