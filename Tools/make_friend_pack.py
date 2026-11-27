# -*- coding: utf-8 -*-
r"""
给其他人的 kkowoUI 整合包（压缩包 + 安装脚本 + 简要说明）

用法（游戏开着也能打包：只读游戏目录，配置取自上次退出游戏时的存档）：
  python -I Tools/make_friend_pack.py            # 生成 <仓库同级>\share\kkowoUI整合包_<版本>_<日期>.zip
  python -I Tools/make_friend_pack.py --dry-run  # 只检查清单与隐私扫描，不写压缩包

包里有什么：
  payload\Interface\AddOns   当前在用的全部插件（排除个人/调试/DD 元数据/已被 EUI 冷却管理器替代的 ArcAuras），
                             极速导航按 vss_kkowo_rename 的规则改名为 VamoosesSlipstream_kkowo
  payload\Fonts              界面字体（*.ttf）
  payload\Interface\Icons    材质图标
  payload\WTF\Account        账号级插件配置（先经 prepare_share_wtf 脱敏，再去掉只属于作者本机的 kkowoUI 状态）
  payload\WTF\Character      角色模板（启用插件列表、聊天框、按键等）
  安装.bat / install.ps1 / 说明.txt（Tools\friend_pack 下的模板）
合并规则由 install.ps1 实现：对方已有的配置文件一律保留，只补对方没有的。
"""
import argparse
import importlib.util
import os
import re
import shutil
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GAME = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
ADDONS = os.path.join(GAME, 'Interface', 'AddOns')
OUT_DEFAULT = os.path.normpath(os.path.join(ROOT, '..', 'share'))
TEMPLATE_DIR = os.path.join(HERE, 'friend_pack')

SKIP_ADDON_DIRS = {
    '163UI_Info',            # 网易DD 自己的同步插件
    'Polestar_Extras_Mei',   # 作者个人路线扩展
    'YaMedia',               # 已吸收 MerfinMain.tga 进 kkowoUI
    # 阶段 2 已由 EUI + Polestar + kkowoUI 原生无损接管的 4 个重叠插件（保留 Scales 装备对比）
    'BlizzMove', 'Leatrix_Maps', 'WaypointUI',
    'VamoosesSlipstream', 'VamoosesSlipstream_kkowo',
    # 阶段 3 已 MIT 合规吸收进 kkowoUI_Tooltip
    'PrettyTooltip',
    'BlizzMove_Debug', 'QuestieTrace', 'ArcUI',
    'ArcAuras', 'ArcAuras_Finds', 'ArcAuras_LFG',  # 作者已改用 EUI 冷却管理器
}

# 同步 update_upstream.py 的净包死目录规则（EUI×6 / BigWigs×8 / LittleWigs×11 / Polestar×9）
def _load_dead_folders():
    up_path = os.path.join(HERE, 'update_upstream.py')
    if not os.path.isfile(up_path):
        return set()
    spec = importlib.util.spec_from_file_location('update_upstream', up_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return set(getattr(mod, 'DEAD_FOLDERS', ()))

SKIP_ADDON_DIRS |= _load_dead_folders()
SKIP_ADDON_FILES = {'addon_strategy.txt', 'dd_author.toc'}
SKIP_ACC_SV = re.compile(r'^(!BugGrabber|BugSack|Auctionator|QuestieTrace|RXPGuides|EUI-RestedXP|ArcAuras.*|ArcUI|Blizzard_.*|Polestar_Extras_Mei)\.lua$', re.I)
ACC_FILES = ('bindings-cache.wtf', 'config-cache.wtf', 'edit-mode-cache-account.txt', 'macros-cache.txt')
CHAR_FILES = ('AddOns.txt', 'chat-cache.txt', 'click-bindings-cache.txt', 'config-cache.wtf',
              'edit-mode-cache-character.txt', 'layout-local.txt', 'macros-cache.txt')
# 只属于作者本机的 kkowoUI 状态：带给别人会误判（例如把对方的 ArcAuras 停掉、按作者的原值还原 EUI/CVar 设置）
KKOWO_DROP = [
    ('cdmReplacesArc',),
    ('slimBackup',),
    ('modules', 'modernChrome', 'euiSheetBackup'),
    ('modules', 'modernChrome', 'erbStyleBackup'),
    ('modules', 'modernChrome', 'wmDisabledLeatrix'),
    ('modules', 'modernChrome', 'wmDisabledCVars'),
    ('modules', 'modernChrome', 'soundMuteApplied'),
    ('modules', 'modernChrome', 'ftDisabledPolestar'),
    ('modules', 'modernChrome', 'ftDisabledEUI'),
    ('modules', 'modernChrome', 'savedWorldTextScale'),
    ('modules', 'tooltipStyle', 'ptipPanelsSynced'),
    ('modules', 'systemBar', 'euiFriendsTakenOver'),
    ('modules', 'systemBar', 'euiFriendsPrevHidden'),
    ('modules', 'chatBar', 'savedEUIShowFriends'),
    ('modules', 'chatBar', 'savedEUISidebarVis'),
    ('modules', 'chatBar', 'savedEUIScrollOnChat'),
    ('modules', 'chatBar', 'savedEUIExtendBg'),
    ('modules', 'chatBar', 'savedEUITabBg'),
    ('modules', 'chatBar', 'savedEUITabActA'),
    ('modules', 'chatBar', 'leftRoomDelta'),
    ('modules', 'questBar', 'zoneFilterSuspended'),
    ('modules', 'nodeReminder', 'savedCVars'),
    ('modules', 'nodeReminder', 'savedSparkleCVar'),
    ('modules', 'nameplateSmart', 'savedFriendly'),
    ('modules', 'nameplateSmart', 'savedNpcPlates'),
    ('modules', 'nameplateSmart', 'savedGuild'),
    ('modules', 'nameplateSmart', 'savedDistantNpc'),
    ('modules', 'nameplateMotion', 'savedEUICornerRadius'),
    ('modules', 'nameplateMotion', 'savedEUICornerRadiusAuras'),
    ('modules', 'markBar', 'savedEUIRaidMarker'),
    ('modules', 'cdPresets', 'v1SmoothCooldownsSeeded'),
    ('modules', 'lootToast', 'savedEUILootFeed'),
    ('modules', 'perfAutoTier', 'savedCVars'),
]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PSW = load('prepare_share_wtf', os.path.join(HERE, 'prepare_share_wtf.py'))
VSS = load('vss_kkowo_rename', os.path.join(ROOT, 'Patches', 'vss_kkowo_rename.py'))


def kkowo_version(kkowo_src):
    toc = open(os.path.join(kkowo_src, 'kkowoUI.toc'), encoding='utf-8').read()
    return re.search(r'^## Version:\s*(\S+)', toc, re.M).group(1)


def drop_keys(table, path):
    """在 parse_sv 的 Table 里按路径删掉一个键；返回是否删了"""
    key = path[0]
    for i, (k, v) in enumerate(table.entries):
        if k is not None and k[0] == 's' and k[1] == key:
            if len(path) == 1:
                del table.entries[i]
                return True
            return isinstance(v, PSW.Table) and drop_keys(v, path[1:])
    return False


def scrub_kkowo(text):
    tops = PSW.parse_sv(text)
    n = 0
    for name, v in tops:
        if name in ('kkowoUIDB', 'KkowoUIDB') and isinstance(v, PSW.Table):
            for p in KKOWO_DROP:
                n += drop_keys(v, p)
    # 改名前的旧存档变量名统一成新名字（游戏里 DB.Init 也会搬，这里先改好）
    tops = [(('kkowoUI' + name[7:]) if name in ('KkowoUIDB', 'KkowoUICharDB') else name, v) for name, v in tops]
    return PSW.write_sv(tops), n


def addons_txt_for_pack(text, pack_addons):
    out = []
    seen = set()
    for ln in text.replace('\r\n', '\n').split('\n'):
        if ':' not in ln:
            continue
        name, st = ln.split(':', 1)
        name = name.strip()
        if name == VSS.OLD_NAME:
            name = VSS.NEW_NAME
        elif name == 'KkowoUI':
            name = 'kkowoUI'
        elif name == 'PrettyTooltip' and 'kkowoUI_Tooltip' in pack_addons:
            name = 'kkowoUI_Tooltip'
        if name in pack_addons and name not in seen:
            seen.add(name)
            out.append(f'{name}: {st.strip()}')
    for kpkg in sorted(a for a in pack_addons if a.startswith('kkowoUI')):
        if kpkg not in seen:
            out.append(f'{kpkg}: enabled')
    return '\r\n'.join(out) + '\r\n'


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=OUT_DEFAULT)
    ap.add_argument('--kkowo-src', default=os.path.join(ROOT, 'Addon', 'kkowoUI'),
                    help='kkowoUI 源码目录（默认使用仓库 Addon\\kkowoUI，避免打包到游戏目录里的旧副本）')
    ap.add_argument('--version', default='', help='可选：覆盖压缩包版本号标签')
    ap.add_argument('--suffix', default='', help='可选：追加在日期前的说明后缀（如 任务追踪修复）')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    kkowo_src = os.path.abspath(args.kkowo_src)
    if not os.path.isfile(os.path.join(kkowo_src, 'kkowoUI.toc')):
        sys.exit(f'找不到 kkowoUI.toc：{kkowo_src}')

    acc = PSW.detect_account()
    if not acc:
        sys.exit('找不到唯一的 WTF\\Account\\<账号> 目录（可设置 WOW_ACCOUNT_DIR）')
    names = PSW.collect_profile_names(os.path.join(acc, 'SavedVariables')) | PSW.char_folder_names(acc)
    acct_id = os.path.basename(acc).split('#')[0]

    # 1) 脱敏副本（share-kkowo，不碰游戏目录）
    staged, hits = PSW.stage_share_copy(acc, names)
    if hits:
        sys.exit('脱敏副本复查发现可疑内容，已中止。')
    chars = [os.path.join(staged, r, c) for r in os.listdir(staged) if os.path.isdir(os.path.join(staged, r)) and r != 'SavedVariables'
             for c in os.listdir(os.path.join(staged, r)) if os.path.isdir(os.path.join(staged, r, c))]
    if len(chars) != 1:
        sys.exit(f'脱敏副本里应只有一个角色模板，实际 {len(chars)} 个')
    char_tpl = chars[0]

    # 2) 插件清单（仓库内所有 kkowoUI* 套件始终取自 Addon\，其余插件取自游戏目录）
    addon_base = os.path.dirname(kkowo_src)
    repo_kkowo_pkgs = {
        d: os.path.join(addon_base, d)
        for d in sorted(os.listdir(addon_base))
        if d.startswith('kkowoUI') and os.path.isfile(os.path.join(addon_base, d, d + '.toc'))
    }
    repo_kkowo_pkgs['kkowoUI'] = kkowo_src
    addon_dirs = sorted(
        {d for d in os.listdir(ADDONS) if os.path.isdir(os.path.join(ADDONS, d)) and d not in SKIP_ADDON_DIRS}
        | set(repo_kkowo_pkgs.keys())
    )
    if VSS.OLD_NAME in addon_dirs and VSS.NEW_NAME in addon_dirs:
        addon_dirs.remove(VSS.OLD_NAME)          # 已有改名版就用改名版
    pack_addons = {VSS.NEW_NAME if d == VSS.OLD_NAME else d for d in addon_dirs}
    pack_lower = {a.lower(): a for a in pack_addons}   # 存档文件名可能是改名前的大小写（KkowoUI.lua）
    print(f'插件 {len(pack_addons)} 个（kkowoUI 来源：{kkowo_src}；排除：{"、".join(sorted(SKIP_ADDON_DIRS))}）')

    ver = args.version.strip() or kkowo_version(kkowo_src)
    top = f'kkowoUI整合包_{ver}'
    zip_base = f'{top}_{args.suffix.strip()}' if args.suffix.strip() else top
    build = os.path.join(args.out, '_build_' + time.strftime('%Y%m%d_%H%M%S'))
    wtf_acc = os.path.join(build, 'acc')            # 按真实账号目录结构摆放，便于复用 residual_scan
    os.makedirs(os.path.join(wtf_acc, 'SavedVariables'))
    os.makedirs(os.path.join(wtf_acc, 'Realm', 'Character'))
    try:
        # 3) 账号级配置
        sv_src = os.path.join(staged, 'SavedVariables')
        n_sv = 0
        for fn in sorted(os.listdir(sv_src)):
            if not fn.endswith('.lua') or SKIP_ACC_SV.match(fn):
                continue
            owner = fn[:-4]
            if owner == VSS.OLD_NAME:
                owner = VSS.NEW_NAME
            owner = pack_lower.get(owner.lower())
            if not owner:
                continue
            text = PSW.read_raw(os.path.join(sv_src, fn))
            if owner == 'kkowoUI':
                text, dropped = scrub_kkowo(text)
                print(f'  kkowoUI.lua：去掉作者本机状态 {dropped} 项')
            PSW.write_raw(os.path.join(wtf_acc, 'SavedVariables', owner + '.lua'), text)
            n_sv += 1
        for fn in ACC_FILES:
            p = os.path.join(staged, fn)
            if os.path.exists(p):
                shutil.copy2(p, os.path.join(wtf_acc, fn))
        # 4) 角色模板
        for fn in CHAR_FILES:
            p = os.path.join(char_tpl, fn)
            if not os.path.exists(p):
                continue
            dst = os.path.join(wtf_acc, 'Realm', 'Character', fn)
            if fn == 'AddOns.txt':
                raw = open(p, 'rb').read().decode('utf-8', errors='replace')
                open(dst, 'wb').write(addons_txt_for_pack(raw, pack_addons).encode('utf-8'))
            else:
                shutil.copy2(p, dst)
        # 5) 隐私复查（作者角色名/服务器、GUID、账号号码）
        hits = PSW.residual_scan(wtf_acc, names)
        for base, _, files in os.walk(wtf_acc):
            for f in files:
                if acct_id and acct_id in open(os.path.join(base, f), 'rb').read().decode('utf-8', 'replace'):
                    hits.append(f'{f}: 含账号号码')
        if hits:
            for h in hits:
                print('  ! ' + h)
            sys.exit('隐私复查发现可疑内容，已中止打包。')
        print(f'  账号配置 {n_sv} 份，隐私复查通过')

        # 6) 极速导航改名副本
        vss_src = None
        if VSS.OLD_NAME in addon_dirs:
            vss_src = os.path.join(build, VSS.NEW_NAME)
            shutil.copytree(os.path.join(ADDONS, VSS.OLD_NAME), vss_src)
            VSS.rewrite_tree(vss_src)
            left = VSS.leftover_paths(vss_src)
            if left:
                sys.exit(f'极速导航改名后仍有旧路径：{left[:3]}')

        if args.dry_run:
            print('Dry-run 通过，未写压缩包。')
            return

        # 7) 写压缩包
        os.makedirs(args.out, exist_ok=True)
        zpath = os.path.join(args.out, f'{zip_base}_{time.strftime("%Y%m%d")}.zip')
        with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            def add_tree(src, arc_base):
                for dp, _, fns in os.walk(src):
                    for fn in fns:
                        if fn in SKIP_ADDON_FILES:
                            continue
                        full = os.path.join(dp, fn)
                        rel = os.path.relpath(full, src).replace(os.sep, '/')
                        z.write(full, f'{arc_base}/{rel}')
            for d in addon_dirs:
                if d == VSS.OLD_NAME:
                    add_tree(vss_src, f'{top}/payload/Interface/AddOns/{VSS.NEW_NAME}')
                elif d in repo_kkowo_pkgs:
                    add_tree(repo_kkowo_pkgs[d], f'{top}/payload/Interface/AddOns/{d}')
                else:
                    add_tree(os.path.join(ADDONS, d), f'{top}/payload/Interface/AddOns/{d}')
            fonts = os.path.join(GAME, 'Fonts')
            if os.path.isdir(fonts):
                for fn in os.listdir(fonts):
                    if fn.lower().endswith('.ttf'):
                        z.write(os.path.join(fonts, fn), f'{top}/payload/Fonts/{fn}')
            icons = os.path.join(GAME, 'Interface', 'Icons')
            if os.path.isdir(icons):
                add_tree(icons, f'{top}/payload/Interface/Icons')
            # 1024x1024 超高清 SDF 3D 世界头顶标记图集（同步到 Interface\TargetingFrame）
            media_src = repo_kkowo_pkgs.get('kkowoUI_Media', kkowo_src)
            raid_atlas = os.path.join(media_src, 'Media', 'MarkBar', 'UI-RaidTargetingIcons.blp')
            if os.path.isfile(raid_atlas):
                z.write(raid_atlas, f'{top}/payload/Interface/TargetingFrame/UI-RaidTargetingIcons.blp')
            add_tree(os.path.join(wtf_acc, 'SavedVariables'), f'{top}/payload/WTF/Account/SavedVariables')
            for fn in ACC_FILES:
                p = os.path.join(wtf_acc, fn)
                if os.path.exists(p):
                    z.write(p, f'{top}/payload/WTF/Account/{fn}')
            add_tree(os.path.join(wtf_acc, 'Realm', 'Character'), f'{top}/payload/WTF/Character')
            for fn in ('安装.bat', 'install.ps1', '说明.txt'):
                z.write(os.path.join(TEMPLATE_DIR, fn), f'{top}/{fn}')
        print(f'打包完成：{zpath}（{os.path.getsize(zpath) / 1048576:.0f} MB）')
    finally:
        shutil.rmtree(build, ignore_errors=True)


if __name__ == '__main__':
    main()
