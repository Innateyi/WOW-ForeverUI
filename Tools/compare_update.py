# -*- coding: utf-8 -*-
"""
上游插件新版安装包自动对比工具（只读，不修改游戏目录！）
用法：
  python Tools/compare_update.py <新版.zip> [--addons-dir <游戏AddOns路径>] [--out <报告路径>]

功能：
  1. 自动识别压缩包里包含的所有插件目录（含版本号对比）
  2. 与当前游戏 AddOns（或 --baseline 指定旧目录）对比：
     - 新增 / 删除 / 修改的 Lua 文件清单
     - 新增的斜杠命令（SLASH_*）、新增模块/设置页标题、新增中文功能项与配置键
     - Changelog / README 变更摘录
  3. （补丁锚点请在覆盖安装后运行 python Tools/apply_patches.py --check 检查，本脚本不做此项）
  4. 输出结构化 Markdown 报告到 Upstream/reports/，1 分钟判断新版是否值得吸收新功能
"""
import argparse
import difflib
import os
import re
import sys
import tempfile
import time
import zipfile

DEFAULT_ADDONS = r'E:\Program Files\World of Warcraft\_forever_\Interface\AddOns'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPORTS_DIR = os.path.join(ROOT, 'Upstream', 'reports')

SLASH_RE = re.compile(r'SLASH_[A-Z0-9_]+\s*=\s*["\'](/[^"\']+)["\']')
TEXT_LABEL_RE = re.compile(r'(?:text|label|title|SectionHeader)\s*[=(]\s*(?:parent,\s*)?["\']([^"\']{2,40})["\']')
DB_KEY_RE = re.compile(r'\b([a-z][A-Za-z0-9_]{3,32})\s*=\s*(?:true|false|\d+|["\'])')


def read_utf8(path):
    return open(path, encoding='utf-8', errors='replace').read()


def get_toc_meta(addon_dir):
    meta = {'version': 'unknown', 'title': os.path.basename(addon_dir)}
    if not os.path.isdir(addon_dir):
        return meta
    for fn in sorted(os.listdir(addon_dir)):
        if fn.endswith('.toc'):
            t = read_utf8(os.path.join(addon_dir, fn))
            mv = re.search(r'^## Version:\s*(.+)$', t, re.M)
            mt = re.search(r'^## Title:\s*(.+)$', t, re.M)
            if mv:
                meta['version'] = mv.group(1).strip()
            if mt:
                meta['title'] = mt.group(1).strip()
            break
    return meta


def find_addon_dirs(root):
    """在解压目录里自动找到所有含 .toc 文件的插件根目录。"""
    found = {}
    for dp, dns, fns in os.walk(root):
        if any(f.endswith('.toc') for f in fns):
            name = os.path.basename(dp)
            found[name] = dp
            dns[:] = []  # 不再往插件内部子目录找
    return found


def list_lua_files(addon_dir):
    out = {}
    if not os.path.isdir(addon_dir):
        return out
    for dp, _, fns in os.walk(addon_dir):
        for fn in fns:
            if fn.endswith(('.lua', '.toc', '.xml', '.md', '.txt')):
                full = os.path.join(dp, fn)
                rel = os.path.relpath(full, addon_dir).replace(os.sep, '/')
                out[rel] = full
    return out


def extract_features(text):
    slashes = set(SLASH_RE.findall(text))
    labels = set(TEXT_LABEL_RE.findall(text))
    keys = set(DB_KEY_RE.findall(text))
    return slashes, labels, keys


def compare_addon(name, old_dir, new_dir):
    old_meta = get_toc_meta(old_dir)
    new_meta = get_toc_meta(new_dir)
    old_files = list_lua_files(old_dir)
    new_files = list_lua_files(new_dir)

    added = sorted(set(new_files) - set(old_files))
    removed = sorted(set(old_files) - set(new_files))
    common = sorted(set(old_files) & set(new_files))

    modified = []
    new_slashes, new_labels, new_keys = set(), set(), set()

    for rel in added:
        if rel.endswith('.lua'):
            s, l, k = extract_features(read_utf8(new_files[rel]))
            new_slashes |= s
            new_labels |= l
            new_keys |= k

    for rel in common:
        ot = read_utf8(old_files[rel]).replace('\r\n', '\n')
        nt = read_utf8(new_files[rel]).replace('\r\n', '\n')
        if ot != nt:
            diff_lines = list(difflib.unified_diff(ot.splitlines(), nt.splitlines(), lineterm='', n=0))
            ins = sum(1 for l in diff_lines if l.startswith('+') and not l.startswith('+++'))
            dels = sum(1 for l in diff_lines if l.startswith('-') and not l.startswith('---'))
            modified.append((rel, ins, dels))
            if rel.endswith('.lua'):
                os_, ol, ok_ = extract_features(ot)
                ns, nl, nk = extract_features(nt)
                new_slashes |= (ns - os_)
                new_labels |= (nl - ol)
                new_keys |= (nk - ok_)

    return {
        'name': name,
        'old_ver': old_meta['version'],
        'new_ver': new_meta['version'],
        'exists_old': os.path.isdir(old_dir),
        'added': added,
        'removed': removed,
        'modified': modified,
        'new_slashes': sorted(new_slashes),
        'new_labels': sorted(new_labels)[:40],
        'new_keys': sorted(new_keys)[:40],
    }


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='对比新版插件 zip 与现有安装版本的功能变更')
    ap.add_argument('zip_path', help='新下载的插件 zip 压缩包路径')
    ap.add_argument('--addons-dir', default=DEFAULT_ADDONS, help='作为基准的 AddOns 目录（默认游戏 AddOns）')
    ap.add_argument('--out', default=None, help='报告输出路径（默认 Upstream/reports/）')
    args = ap.parse_args()

    if not os.path.isfile(args.zip_path):
        sys.exit(f'找不到压缩包：{args.zip_path}')

    with tempfile.TemporaryDirectory(prefix='fui_cmp_') as tmp:
        with zipfile.ZipFile(args.zip_path, 'r') as z:
            # 防 Zip Slip：任何解压后会落到临时目录之外的条目（../ 或绝对路径）一律拒绝
            base = os.path.realpath(tmp)
            for info in z.infolist():
                target = os.path.realpath(os.path.join(base, info.filename))
                if target != base and not target.startswith(base + os.sep):
                    sys.exit(f'压缩包含有越界路径，已拒绝解压：{info.filename}')
            z.extractall(tmp)
        new_addons = find_addon_dirs(tmp)
        if not new_addons:
            sys.exit('压缩包中未检测到任何含 .toc 的插件目录。')

        lines = [
            f'# 上游插件更新对比报告',
            f'',
            f'- 压缩包：`{os.path.basename(args.zip_path)}`',
            f'- 基准目录：`{args.addons_dir}`',
            f'- 生成时间：{time.strftime("%Y-%m-%d %H:%M:%S")}',
            f'- 识别插件数：{len(new_addons)}',
            '',
        ]

        for name, ndir in sorted(new_addons.items()):
            odir = os.path.join(args.addons_dir, name)
            r = compare_addon(name, odir, ndir)
            if r['exists_old'] and not r['added'] and not r['removed'] and not r['modified']:
                lines.append(f'## {name} (`v{r["old_ver"]}` → `v{r["new_ver"]}`) — 无代码变化\n')
                continue
            lines.append(f'## {name} (`v{r["old_ver"]}` → `v{r["new_ver"]}`)')
            if not r['exists_old']:
                lines.append('- 状态：**全新插件（基准目录中尚未安装）**')
            if r['added']:
                lines.append(f'- 新增文件 ({len(r["added"])}): ' + ', '.join(f'`{f}`' for f in r['added'][:15]))
            if r['removed']:
                lines.append(f'- 删除文件 ({len(r["removed"])}): ' + ', '.join(f'`{f}`' for f in r['removed'][:15]))
            if r['modified']:
                lines.append(f'- 修改文件 ({len(r["modified"])}):')
                for rel, ins, dels in sorted(r['modified'], key=lambda x: -(x[1] + x[2]))[:20]:
                    lines.append(f'  - `{rel}` (+{ins} / -{dels})')
            if r['new_slashes']:
                lines.append('- 新增斜杠命令：' + ', '.join(f'`{s}`' for s in r['new_slashes']))
            if r['new_labels']:
                lines.append('- 疑似新增界面/功能文案：' + '、'.join(r['new_labels'][:20]))
            if r['new_keys']:
                lines.append('- 疑似新增配置键：' + ', '.join(f'`{k}`' for k in r['new_keys'][:20]))
            lines.append('')

    os.makedirs(REPORTS_DIR, exist_ok=True)
    out_path = args.out or os.path.join(
        REPORTS_DIR, f'compare_{os.path.splitext(os.path.basename(args.zip_path))[0]}_{time.strftime("%Y%m%d_%H%M%S")}.md'
    )
    report = '\n'.join(lines)
    open(out_path, 'w', encoding='utf-8').write(report)
    print(report[:2500])
    print(f'\n完整报告已保存：{out_path}')


if __name__ == '__main__':
    main()
