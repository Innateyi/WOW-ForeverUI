# -*- coding: utf-8 -*-
"""
补丁：给 Polestar 的简体中文包（Polestar_zhCN）补齐它没翻译的文字。
  * Interface.lua：把注释掉、值为空的界面字符串（-- L["..."] = ""）换成中文
  * Texts.lua：给各指南补上缺译的说明 / 目标文字（why / note / text / pitch）
翻译数据在同目录 polestar_zhcn_fill.json：
  { "interface": { 英文原样(Lua 转义形式): 中文 }, "guides": { 指南 id: { 英文原样: 中文 } } }
规则：
  * 只补 Polestar 自己没翻译的；Polestar 以后版本自己翻译了，以它的为准（我们插在前面，表里后写的覆盖前面的）
  * 中文必须保留英文里的全部 {kind:id} 占位符和 %s / %d / %% 格式符，不一致的条目跳过并报告
  * 插入的每一行都带 -- [kkowo-zh] 标记，重复运行先清掉旧的再按数据重插，幂等
  * 第一次修改前把原文件备份到 <备份目录>\\Polestar_zhCN_<版本>_原版\\
支持 --check 只读检测（apply_patches.py 统一调用 run(check_only=...)）。
"""
import json
import os
import re
import shutil
import sys

WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'Polestar_zhCN')
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')))
DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'polestar_zhcn_fill.json')
MARK = '-- [kkowo-zh]'
STR = r'"((?:[^"\\]|\\.)*)"'

TOKEN_RE = re.compile(r'\{[a-z]+:[^}]*\}')
FMT_RE = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[sdif%]')


def lua_unescape(raw):
    out, i = [], 0
    while i < len(raw):
        c = raw[i]
        if c == '\\' and i + 1 < len(raw):
            n = raw[i + 1]
            if n.isdigit():
                j = i + 1
                while j < len(raw) and j < i + 4 and raw[j].isdigit():
                    j += 1
                out.append(chr(int(raw[i + 1:j])))
                i = j
                continue
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def lua_escape(text):
    return text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '')


def placeholders_ok(en_raw, zh):
    en = lua_unescape(en_raw)
    if sorted(TOKEN_RE.findall(en)) != sorted(TOKEN_RE.findall(zh)):
        return False
    return sorted(FMT_RE.findall(en)) == sorted(FMT_RE.findall(zh))


def get_version(root):
    for n in os.listdir(root):
        if n.endswith('.toc'):
            m = re.search(r'^## Version:\s*(\S+)', open(os.path.join(root, n), encoding='utf-8', errors='replace').read(), re.M)
            if m:
                return m.group(1)
    return 'unknown'


def load_data():
    if not os.path.exists(DATA):
        return {'interface': {}, 'guides': {}}
    d = json.load(open(DATA, encoding='utf-8'))
    d.setdefault('interface', {})
    d.setdefault('guides', {})
    return d


def fill_interface(text, data, bad):
    lines = text.split('\n')
    filled = 0
    pending = 0
    for i, line in enumerate(lines):
        m = re.match(r'^\s*--\s*L\[' + STR + r'\]\s*=\s*""\s*$', line)
        mine = re.match(r'^L\[' + STR + r'\] = ' + STR + r' ' + re.escape(MARK) + r'$', line)
        key = (m or mine).group(1) if (m or mine) else None
        if key is None or key not in data:
            continue
        zh = data[key]
        if not placeholders_ok(key, zh):
            bad.append('界面: ' + key[:60])
            continue
        new = f'L["{key}"] = "{lua_escape(zh)}" {MARK}'
        if line != new:
            lines[i] = new
            pending += 1
        filled += 1
    return '\n'.join(lines), filled, pending


def fill_texts(text, guides, bad):
    # 先去掉上次插入的行（含整块新建的指南表，以及新建块后面跟着的那一个空行）
    kept, skip_blank = [], False
    for l in text.split('\n'):
        if MARK in l:
            skip_blank = l.startswith('} end)()')
            continue
        if skip_blank and l == '':
            skip_blank = False
            continue
        skip_blank = False
        kept.append(l)
    base = '\n'.join(kept)
    out = base
    filled = 0
    for gid, pairs in guides.items():
        head = f't.guides["{gid}"] = (function() return {{'
        good = {}
        for en, zh in pairs.items():
            if placeholders_ok(en, zh):
                good[en] = zh
            else:
                bad.append(f'{gid}: {en[:60]}')
        if not good:
            continue
        at = out.find(head)
        if at >= 0:
            end = out.find('\n} end)()', at)
            block = out[at:end]
            existing = set(re.findall(r'^\s*\[' + STR + r'\] = ', block, re.M))
            add = [f'\t\t["{en}"] = "{lua_escape(zh)}", {MARK}' for en, zh in good.items() if en not in existing]
            if add:
                nl = out.index('\n', at) + 1
                out = out[:nl] + '\n'.join(add) + '\n' + out[nl:]
                filled += len(add)
        else:
            reg = out.rfind('Polestar.RegisterGuideTexts(')
            body = [f'{head} {MARK}'] + [f'\t\t["{en}"] = "{lua_escape(zh)}", {MARK}' for en, zh in good.items()] + [f'}} end)() {MARK}']
            out = out[:reg] + '\n'.join(body) + '\n\n' + out[reg:]
            filled += len(good)
    return out, filled, out != text


def run(addon_dir=DEFAULT_DIR, check_only=False):
    if not os.path.isdir(addon_dir):
        return ('MISSING', f'未找到目录: {addon_dir}')
    data = load_data()
    if not data['interface'] and not data['guides']:
        return ('APPLIED', '暂无翻译数据')
    ver = get_version(addon_dir)
    ipath = os.path.join(addon_dir, 'Interface.lua')
    tpath = os.path.join(addon_dir, 'Texts.lua')
    itext = open(ipath, 'rb').read().decode('utf-8')
    ttext = open(tpath, 'rb').read().decode('utf-8')
    bad = []
    new_i, i_filled, i_pending = fill_interface(itext, data['interface'], bad)
    new_t, t_filled, t_changed = fill_texts(ttext, data['guides'], bad)
    msg = f'界面 {i_filled}/{len(data["interface"])} 条，指南 {t_filled} 条 (v{ver})'
    if bad:
        msg += f'；占位符不一致已跳过 {len(bad)} 条'
    if not i_pending and not t_changed:
        return ('APPLIED', '已补齐 ' + msg)
    if check_only:
        return ('READY', '可补齐 ' + msg)
    bdir = os.path.join(BACKUP_ROOT, f'Polestar_zhCN_{ver}_原版')
    os.makedirs(bdir, exist_ok=True)
    for p in (ipath, tpath):
        dst = os.path.join(bdir, os.path.basename(p))
        if not os.path.exists(dst) and MARK not in open(p, encoding='utf-8').read():
            shutil.copy2(p, dst)
    open(ipath, 'wb').write(new_i.encode('utf-8'))
    open(tpath, 'wb').write(new_t.encode('utf-8'))
    return ('PATCHED', '已补齐 ' + msg)


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    chk = '--check' in sys.argv
    args = [a for a in sys.argv[1:] if a != '--check']
    status, msg = run(args[0] if args else DEFAULT_DIR, check_only=chk)
    print(f'[polestar_zhcn_fill] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED') else 1)
