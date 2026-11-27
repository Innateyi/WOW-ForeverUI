# -*- coding: utf-8 -*-
r"""
kkowoUI — 受控上游插件更新管家（脱离网易 DD 自动更新，安全备份 + 净包过滤 + Diff 报告）

用法：
  python -I Tools/update_upstream.py --check                   # 只读对比本地版本与 GitHub 最新 Release（游戏开着可用）
  python -I Tools/update_upstream.py --fetch [名称...]          # 下载新版 zip 到 Upstream/downloads/ 并生成 Diff 报告（游戏开着可用）
  python -I Tools/update_upstream.py --apply [名称...]          # 退出游戏后：全量备份旧目录 → 净包解压更新 → 检查补丁状态
  python -I Tools/update_upstream.py --apply --repatch [名称...] # 同上，并自动重打仍适用的极简补丁
  python -I Tools/update_upstream.py --purge-dead              # 退出游戏后：将实机中已确认无用的死目录移入 backups/
  python -I Tools/update_upstream.py --import <本地.zip>        # 导入国服独有包（如无限副本手册/Auctionator/GTFO），自动备份+净包+Diff

安全约定：
  - 绝不删除任何游戏文件：被替换与被清理的旧目录全部整夹移入 backups/
  - 所有 zip 解压前做 Zip Slip 越界路径校验
  - 写入游戏 AddOns 前强制检查 Wow.exe 未在运行
"""
import argparse
import fnmatch
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
ADDONS_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns')
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(ROOT, '..', 'backups')))
DOWNLOADS_DIR = os.path.join(ROOT, 'Upstream', 'downloads')
REPORTS_DIR = os.path.join(ROOT, 'Upstream', 'reports')

# 全局净包黑名单：无限服（16001 / camelot）下明确无效、冗余或正式服专属的子目录
DEAD_FOLDERS = {
    # 网易 DD 失效同步插件
    '163UI_Info',
    # EllesmereUI 无用 / 正式服 / 已被 kkowoUI 替代的 6 个子目录
    'EllesmereUIDataBars',
    'EllesmereUIMythicTimer',
    'EllesmereUIQuickdraw',
    'EllesmereUIAuraBuffReminders',
    'EllesmereUIFriends',
    'EllesmereUIGroupFinder',
    # BigWigs 正式服 Midnight 团本 8 个死目录（TOC 不含 16001）
    'BigWigs_MarchOnQuelDanas',
    'BigWigs_MidnightLairs',
    'BigWigs_MidnightWorld',
    'BigWigs_Sporefall',
    'BigWigs_TheDreamrift',
    'BigWigs_TheUnbindingOfKithix',
    'BigWigs_TheVenomousAbyss',
    'BigWigs_TheVoidspire',
    # LittleWigs 非无限服资料片 11 个死目录（含不含 camelot 的 LittleWigs_Classic）
    'LittleWigs_BattleForAzeroth',
    'LittleWigs_BurningCrusade',
    'LittleWigs_Cataclysm',
    'LittleWigs_Classic',
    'LittleWigs_Dragonflight',
    'LittleWigs_Legion',
    'LittleWigs_MistsOfPandaria',
    'LittleWigs_Shadowlands',
    'LittleWigs_TheWarWithin',
    'LittleWigs_WarlordsOfDraenor',
    'LittleWigs_WrathOfTheLichKing',
    # Polestar 小游戏（25.6MB）与 8 个非简体中文外语包（35.6MB）
    'Polestar_Arcade',
    'Polestar_deDE',
    'Polestar_esES',
    'Polestar_esMX',
    'Polestar_frFR',
    'Polestar_koKR',
    'Polestar_ptBR',
    'Polestar_ruRU',
    'Polestar_zhTW',
    # Questie 开发者调试包 & BlizzMove 调试包 & 无效迁移存根
    'QuestieTrace',
    'BlizzMove_Debug',
    'ArcUI',
}

# GitHub Releases 上游受控清单
UPSTREAM_SPECS = [
    {
        'key': 'EllesmereUI',
        'repo': 'EllesmereGaming/EllesmereUI',
        'asset_glob': 'EllesmereUI-*.zip',
        'exclude_glob': None,
        'primary_folder': 'EllesmereUI',
        'allow_folders': None,
        'mode': 'addon',
    },
    {
        'key': 'Polestar',
        'repo': 'fitzforge/polestar',
        'asset_glob': 'Polestar-*.zip',
        'exclude_glob': 'Polestar_Recorder*',
        'primary_folder': 'Polestar',
        'allow_folders': None,
        'mode': 'addon',
    },
    {
        'key': 'BigWigs',
        'repo': 'BigWigsMods/BigWigs',
        'asset_glob': 'BigWigs-*.zip',
        'exclude_glob': None,
        'primary_folder': 'BigWigs',
        'allow_folders': {'BigWigs', 'BigWigs_Core', 'BigWigs_Plugins', 'BigWigs_Options'},
        'mode': 'addon',
    },
    {
        'key': 'BigWigs_Classic',
        'repo': 'BigWigsMods/BigWigs_Classic',
        'asset_glob': 'BigWigs_Classic-*.zip',
        'exclude_glob': None,
        'primary_folder': 'BigWigs_Classic',
        'allow_folders': {'BigWigs_Classic'},
        # 注意：上游 v12.1.3 尚未将 16001/camelot 写进 BigWigs_Classic.toc，
        # 默认只下载做 Diff 审核，等官方支持 16001 后再切回 mode='addon'
        'mode': 'vendor_diff',
    },
    {
        'key': 'LittleWigs',
        'repo': 'BigWigsMods/LittleWigs',
        'asset_glob': 'LittleWigs-*.zip',
        'exclude_glob': None,
        'primary_folder': 'LittleWigs',
        'allow_folders': {'LittleWigs', 'LittleWigs_Forever'},
        'mode': 'addon',
    },
    {
        'key': 'Questie',
        'repo': 'Questie/Questie',
        'asset_glob': 'Questie-*.zip',
        'exclude_glob': None,
        'primary_folder': 'Questie',
        'allow_folders': {'Questie', 'QuestieDB'},
        'mode': 'addon',
    },
    {
        'key': 'SpellActivationOverlay',
        'repo': 'ennvina/spellactivationoverlay',
        'asset_glob': 'SpellActivationOverlay-*-forever.zip',
        'exclude_glob': None,
        'primary_folder': 'SpellActivationOverlay',
        'allow_folders': {'SpellActivationOverlay'},
        'mode': 'addon',
    },
    {
        'key': 'BugSack',
        'repo': 'funkydude/BugSack',
        'asset_glob': 'BugSack-*.zip',
        'exclude_glob': None,
        'primary_folder': 'BugSack',
        'allow_folders': {'BugSack'},
        'mode': 'addon',
    },
    {
        'key': 'PrettyTooltip',
        'repo': 'FallenShard/PrettyTooltip',
        'asset_glob': 'PrettyTooltip-*.zip',
        'exclude_glob': None,
        'primary_folder': 'PrettyTooltip',
        'allow_folders': {'PrettyTooltip'},
        'mode': 'vendor_diff',  # 后续内嵌为 kkowoUI_Tooltip 时只拉取做 Diff，不盲目覆盖
    },
]

SPEC_BY_KEY = {s['key'].lower(): s for s in UPSTREAM_SPECS}


def load_tool(name):
    p = os.path.join(HERE, name + '.py')
    spec = importlib.util.spec_from_file_location(name, p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wow_running():
    try:
        out = subprocess.run(
            ['tasklist', '/FI', 'IMAGENAME eq Wow.exe'],
            capture_output=True, text=True, encoding='mbcs', errors='replace', timeout=10,
        ).stdout
        return 'Wow.exe' in out
    except Exception:
        return False


def local_version(folder):
    p = os.path.join(ADDONS_DIR, folder)
    if not os.path.isdir(p):
        return None
    tocs = sorted(f for f in os.listdir(p) if f.endswith('.toc') and f != 'dd_author.toc')
    # 优先匹配 Forever / Camelot / 同名 TOC
    preferred = sorted(
        tocs,
        key=lambda f: (
            0 if ('forever' in f.lower() or 'camelot' in f.lower()) else (1 if f[:-4].lower() == folder.lower() else 2),
            f,
        ),
    )
    for fn in preferred:
        txt = open(os.path.join(p, fn), encoding='utf-8', errors='replace').read()
        m = re.search(r'^##\s*Version:\s*(.+)$', txt, re.M)
        if m and m.group(1).strip():
            return m.group(1).strip()
    return 'unknown'


def norm_ver(v):
    if not v:
        return ''
    s = v.strip().lower()
    s = re.sub(r'^bundle/', '', s)
    s = s.split('+')[0]
    return s.lstrip('v')


def github_latest(repo):
    url = f'https://api.github.com/repos/{repo}/releases/latest'
    headers = {'User-Agent': 'kkowoUI-updater/2.0', 'Accept': 'application/vnd.github+json'}
    tok = os.environ.get('GITHUB_TOKEN')
    if tok:
        headers['Authorization'] = f'Bearer {tok}'
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode('utf-8'))


def pick_asset(release, asset_glob, exclude_glob=None):
    for a in release.get('assets') or []:
        name = a.get('name', '')
        if not fnmatch.fnmatch(name, asset_glob):
            continue
        if exclude_glob and fnmatch.fnmatch(name, exclude_glob):
            continue
        return name, a.get('browser_download_url')
    return None, None


def download_file(url, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + '.part'
    req = urllib.request.Request(url, headers={'User-Agent': 'kkowoUI-updater/2.0'})
    with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, 'wb') as fh:
        shutil.copyfileobj(resp, fh)
    os.replace(tmp, dst)


def safe_extract(zip_path, dst_dir):
    with zipfile.ZipFile(zip_path, 'r') as z:
        base = os.path.realpath(dst_dir)
        for info in z.infolist():
            target = os.path.realpath(os.path.join(base, info.filename))
            if target != base and not target.startswith(base + os.sep):
                raise RuntimeError(f'压缩包含越界路径，已拒绝解压：{info.filename}')
        z.extractall(dst_dir)


def find_addon_dirs(root):
    found = {}
    for dp, dns, fns in os.walk(root):
        if any(f.endswith('.toc') and f != 'dd_author.toc' for f in fns):
            name = os.path.basename(dp)
            found[name] = dp
            dns[:] = []
    return found


def select_specs(names):
    if not names or 'all' in [n.lower() for n in names]:
        return list(UPSTREAM_SPECS)
    out = []
    for n in names:
        spec = SPEC_BY_KEY.get(n.lower())
        if not spec:
            sys.exit(f'未知上游插件键名：{n}；可选：{", ".join(s["key"] for s in UPSTREAM_SPECS)}')
        out.append(spec)
    return out


def cmd_check(specs):
    print(f'=== kkowoUI 受控上游版本检查（{ADDONS_DIR}） ===')
    print(f'{"插件":<24} | {"本地版本":<16} | {"GitHub 最新":<20} | {"发布日期":<10} | 状态')
    print('-' * 92)
    updates = []
    for s in specs:
        loc = local_version(s['primary_folder']) or '(未安装)'
        try:
            rel = github_latest(s['repo'])
            tag = rel.get('tag_name') or ''
            dt = str(rel.get('published_at') or '')[:10]
            aname, _ = pick_asset(rel, s['asset_glob'], s['exclude_glob'])
            if not aname:
                st = '未找到匹配 zip'
            elif loc == '(未安装)':
                st = '未安装'
                updates.append((s, rel, aname))
            elif norm_ver(loc) == norm_ver(tag):
                st = '已是最新'
            else:
                st = '有新版可更'
                updates.append((s, rel, aname))
            print(f'{s["key"]:<24} | {loc:<16} | {tag:<20} | {dt:<10} | {st}')
        except Exception as e:
            print(f'{s["key"]:<24} | {loc:<16} | {"(查询失败)":<20} | {"":<10} | {e}')
    return updates


def run_compare(zip_path, label):
    cmp_mod = load_tool('compare_update')
    os.makedirs(REPORTS_DIR, exist_ok=True)
    out = os.path.join(REPORTS_DIR, f'update_{label}_{time.strftime("%Y%m%d_%H%M%S")}.md')
    old_argv = sys.argv
    try:
        sys.argv = ['compare_update.py', zip_path, '--addons-dir', ADDONS_DIR, '--out', out]
        cmp_mod.main()
    finally:
        sys.argv = old_argv
    return out


def folder_supports_forever(addon_dir):
    """检查插件目录内是否存在支持无限服（Interface 16001 且未排除 camelot）的 .toc"""
    tocs = [f for f in os.listdir(addon_dir) if f.endswith('.toc') and f != 'dd_author.toc']
    if not tocs:
        return False
    for fn in tocs:
        txt = open(os.path.join(addon_dir, fn), encoding='utf-8', errors='replace').read()
        m_if = re.search(r'^##\s*Interface:\s*(.+)$', txt, re.M)
        if not (m_if and '16001' in m_if.group(1)):
            continue
        m_allow = re.search(r'^##\s*AllowLoadGameType:\s*(.+)$', txt, re.M)
        if m_allow:
            types = {x.strip().lower() for x in m_allow.group(1).split(',')}
            if 'camelot' not in types:
                continue
        m_excl = re.search(r'^##\s*ExcludeLoadGameType:\s*(.+)$', txt, re.M)
        if m_excl:
            ex = {x.strip().lower() for x in m_excl.group(1).split(',')}
            if 'camelot' in ex:
                continue
        return True
    return False


def install_zip_clean(zip_path, allow_folders=None, label='import', dry_run=False, force=False):
    with tempfile.TemporaryDirectory(prefix='kk_up_') as tmp:
        safe_extract(zip_path, tmp)
        dirs = find_addon_dirs(tmp)
        if not dirs:
            raise RuntimeError(f'压缩包内未检测到任何插件目录：{zip_path}')
        kept = {}
        skipped = []
        blocked_16001 = []
        for name, src in sorted(dirs.items()):
            if name in DEAD_FOLDERS:
                skipped.append(name)
                continue
            if allow_folders is not None and name not in allow_folders:
                skipped.append(name)
                continue
            dst_old = os.path.join(ADDONS_DIR, name)
            if (not force) and os.path.isdir(dst_old) and folder_supports_forever(dst_old) and not folder_supports_forever(src):
                blocked_16001.append(name)
                continue
            kept[name] = src
        if blocked_16001:
            raise RuntimeError(
                f'[{label}] 安全拦截：新版 {", ".join(blocked_16001)} 的 .toc 不再支持无限服 16001/camelot，'
                f'已拒绝覆盖（加 --force 才允许强行写入）！'
            )
        print(f'[{label}] 净包识别：保留 {len(kept)} 个目录，过滤死包/冗余 {len(skipped)} 个目录')
        if skipped:
            print('  已过滤：' + ', '.join(skipped))
        if dry_run:
            return kept, skipped
        stamp = time.strftime('%Y%m%d_%H%M%S')
        bk = os.path.join(BACKUP_ROOT, f'Upstream_{label}_{stamp}')
        backed = 0
        for name, src in kept.items():
            dst = os.path.join(ADDONS_DIR, name)
            if os.path.exists(dst):
                os.makedirs(bk, exist_ok=True)
                shutil.move(dst, os.path.join(bk, name))
                backed += 1
            shutil.copytree(src, dst)
        print(f'[{label}] 安装完成：{len(kept)} 个目录已写入（旧版 {backed} 个目录已移入 {bk if backed else "无需备份"}）')
        return kept, skipped


def cmd_fetch(specs, force=False):
    os.makedirs(DOWNLOADS_DIR, exist_ok=True)
    fetched = []
    for s in specs:
        loc = local_version(s['primary_folder']) or '(未安装)'
        try:
            rel = github_latest(s['repo'])
        except Exception as e:
            print(f'[ERR] {s["key"]}: 查询失败 {e}')
            continue
        tag = rel.get('tag_name') or ''
        aname, url = pick_asset(rel, s['asset_glob'], s['exclude_glob'])
        if not aname or not url:
            print(f'[SKIP] {s["key"]}: Release {tag} 无匹配资产 ({s["asset_glob"]})')
            continue
        if not force and norm_ver(loc) == norm_ver(tag):
            print(f'[OK  ] {s["key"]}: 本地 {loc} 已是最新 {tag}（加 --force 可强制下载）')
            continue
        dst = os.path.join(DOWNLOADS_DIR, aname)
        if not os.path.exists(dst) or force:
            print(f'[DOWN] {s["key"]} ({loc} -> {tag}): 下载 {aname} ...')
            download_file(url, dst)
        else:
            print(f'[CACH] {s["key"]}: 复用已下载 {aname}')
        fetched.append((s, tag, dst))
        run_compare(dst, f'{s["key"]}_{norm_ver(tag)}')
    return fetched


def cmd_purge_dead(dry_run=False):
    present = sorted(d for d in os.listdir(ADDONS_DIR) if d in DEAD_FOLDERS and os.path.isdir(os.path.join(ADDONS_DIR, d)))
    if not present:
        print('实机 AddOns 目录已非常洁净，未发现任何已知死目录。')
        return 0
    total_mb = 0.0
    for d in present:
        p = os.path.join(ADDONS_DIR, d)
        sz = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(p) for f in fs)
        total_mb += sz / 1048576
    print(f'检测到 {len(present)} 个无限服无效/冗余死目录（共 {total_mb:.2f} MB）：')
    for d in present:
        print('  - ' + d)
    if dry_run:
        print('（--dry-run 预览模式，未移动任何目录）')
        return len(present)
    if wow_running():
        sys.exit('魔兽世界正在运行：请完全退出游戏后再清理死目录。')
    stamp = time.strftime('%Y%m%d_%H%M%S')
    bk = os.path.join(BACKUP_ROOT, f'DeadPurge_{stamp}')
    os.makedirs(bk, exist_ok=True)
    for d in present:
        shutil.move(os.path.join(ADDONS_DIR, d), os.path.join(bk, d))
    print(f'已将 {len(present)} 个死目录（{total_mb:.2f} MB）全部移入备份：{bk}')
    return len(present)


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='kkowoUI 受控上游插件更新管家')
    ap.add_argument('--check', action='store_true', help='只读检查本地与 GitHub 最新版本')
    ap.add_argument('--fetch', action='store_true', help='下载新版 zip 并生成 Diff 对比报告')
    ap.add_argument('--apply', action='store_true', help='退出游戏后净包安装更新并备份旧版')
    ap.add_argument('--repatch', action='store_true', help='配合 --apply 自动重打极简补丁')
    ap.add_argument('--purge-dead', action='store_true', help='清理实机中的 34+ 个无限服无效/冗余死目录到 backups/')
    ap.add_argument('--import-zip', metavar='ZIP', help='导入本地 zip（无限副本手册 / Auctionator 等）')
    ap.add_argument('--force', action='store_true', help='即使版本一致也强制重新下载/应用')
    ap.add_argument('--dry-run', action='store_true', help='预览操作，不修改游戏目录')
    ap.add_argument('names', nargs='*', help='指定要处理的插件键名（省略或 all 表示全部）')
    args = ap.parse_args()

    if not any([args.check, args.fetch, args.apply, args.purge_dead, args.import_zip]):
        args.check = True

    if args.purge_dead:
        cmd_purge_dead(dry_run=args.dry_run)
        if not (args.check or args.fetch or args.apply or args.import_zip):
            return 0

    if args.import_zip:
        zp = os.path.abspath(args.import_zip)
        if not os.path.isfile(zp):
            sys.exit(f'找不到本地压缩包：{zp}')
        label = os.path.splitext(os.path.basename(zp))[0]
        run_compare(zp, label)
        if not args.dry_run:
            if wow_running():
                sys.exit('魔兽世界正在运行：请完全退出游戏后再导入安装。')
            install_zip_clean(zp, allow_folders=None, label=label, dry_run=False)
        return 0

    specs = select_specs(args.names)
    if args.check:
        cmd_check(specs)
    if args.fetch:
        cmd_fetch(specs, force=args.force)
    if args.apply:
        if not args.dry_run and wow_running():
            sys.exit('魔兽世界正在运行：请完全退出游戏后再应用更新。')
        fetched = cmd_fetch(specs, force=args.force)
        for s, tag, zp in fetched:
            if s['mode'] == 'vendor_diff':
                print(f'[INFO] {s["key"]} 为内嵌基准包，已下载至 {zp} 并生成 Diff 报告，需人工审核后再同步进 kkowoUI_Tooltip。')
                continue
            install_zip_clean(zp, allow_folders=s['allow_folders'], label=f'{s["key"]}_{norm_ver(tag)}', dry_run=args.dry_run)
        if not args.dry_run and fetched:
            ap_mod = load_tool('apply_patches')
            old_argv = sys.argv
            try:
                sys.argv = ['apply_patches.py', '--apply' if args.repatch else '--check']
                ap_mod.main()
            finally:
                sys.argv = old_argv
    return 0


if __name__ == '__main__':
    sys.exit(main())
