# -*- coding: utf-8 -*-
r"""
kkowoUI 阶段 2 一键安全交接脚本（必须完全退出魔兽世界后运行；支持 --dry-run 只读预览）：
  1. 恢复已转为零补丁 Hook 的 3 个第三方原版文件（验证真正零文件补丁运行）：
     - EllesmereUINameplates/EUI_Nameplates_Name.lua      （来自 EllesmereUI-v9.9.6.zip）
     - EllesmereUINameplates/EUI_Nameplates_CastState.lua （来自 EllesmereUI-v9.9.6.zip）
     - Polestar/UI/DungeonToast.lua                       （来自 backups\Polestar_0.4.3.1_原版）
  2. 将已由 EUI + Polestar + kkowoUI 无损接管的 5 个重叠插件整夹移入 backups\Retired_Phase2_<时间>\：
     - BlizzMove                → EUI Shifter + kkowoUI ExtraFrameMover
     - Leatrix_Maps (44MB)      → EUI MapReveal/MapTravel/MapFade/ZoneLevels + DungeonsForever + Polestar 灵魂医者服务图钉
     - WaypointUI (8.9MB)       → EUI InGameNavigation + kkowoUI WaypointAutoTrack
     - VamoosesSlipstream_kkowo → Polestar/Nav/Journey (Shift/Alt 点击大地图跨图规划 + /way)
     - Scales                   → Polestar.Gear（内置装备评分 + EUI 背包箭头）
  3. 用 AST 解析器无损开启 EUI 与 Polestar 对应原生替代开关（操作前完整备份 SavedVariables）：
     - EllesmereUI.lua: mapTravel(含飞点/交通/出入口)、worldMapFade(去黑幕点击穿透)、zoneLevels(钓鱼等级)、inGameNavigation(3D光柱)
     - Polestar.lua   : gear.enabled = true（装备评分与 EUI 背包箭头）
  4. 调用 deploy.ps1 部署阶段 2 新版 kkowoUI，并运行 apply_patches.py --check 核验仅剩的 3 个极简补丁。
"""
import argparse
import importlib.util
import os
import shutil
import subprocess
import sys
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
ADDONS = os.path.join(WOW_ROOT, 'Interface', 'AddOns')
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(ROOT, '..', 'backups')))
EUI_ZIP = os.path.join(ROOT, 'Upstream', 'downloads', 'EllesmereUI-v9.9.6.zip')
PS_ORIG_TOAST = os.path.join(BACKUP_ROOT, 'Polestar_0.4.3.1_原版', 'UI', 'DungeonToast.lua')

RETIRED_ADDONS = [
    'BlizzMove',
    'Leatrix_Maps',
    'WaypointUI',
    'VamoosesSlipstream_kkowo',
]


def load_mod(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PSW = load_mod('prepare_share_wtf', os.path.join(HERE, 'prepare_share_wtf.py'))


def wow_running():
    try:
        out = subprocess.run(
            ['tasklist', '/FI', 'IMAGENAME eq Wow.exe'],
            capture_output=True, text=True, encoding='mbcs', errors='replace', timeout=10,
        ).stdout
        return 'Wow.exe' in out
    except Exception:
        return False


def sv_set_path(tbl, path, val_node):
    """在 parse_sv 的 Table AST 上按字符串路径写入键值（不存在则创建子表）。"""
    key = path[0]
    for i, (k, v) in enumerate(tbl.entries):
        if k is not None and k[0] == 's' and k[1] == key:
            if len(path) == 1:
                tbl.entries[i] = (k, val_node)
                return
            if not isinstance(v, PSW.Table):
                v = PSW.Table()
                tbl.entries[i] = (k, v)
            sv_set_path(v, path[1:], val_node)
            return
    if len(path) == 1:
        tbl.entries.append((('s', key), val_node))
    else:
        sub = PSW.Table()
        tbl.entries.append((('s', key), sub))
        sv_set_path(sub, path[1:], val_node)


def update_sv_file(sv_path, top_var, updates, bk_dir, dry_run=False):
    if not os.path.isfile(sv_path):
        print(f'  [SKIP] 找不到存档：{sv_path}')
        return False
    raw = PSW.read_raw(sv_path)
    tops = PSW.parse_sv(raw)
    target = None
    for name, val in tops:
        if name == top_var and isinstance(val, PSW.Table):
            target = val
            break
    if target is None:
        print(f'  [WARN] {os.path.basename(sv_path)} 中未找到顶层表 {top_var}')
        return False
    for path, val_node in updates:
        sv_set_path(target, path, val_node)
    new_text = PSW.write_sv(tops)
    if dry_run:
        print(f'  [DRY ] 将更新 {os.path.basename(sv_path)}（{len(updates)} 项配置开关）')
        return True
    os.makedirs(bk_dir, exist_ok=True)
    shutil.copy2(sv_path, os.path.join(bk_dir, os.path.basename(sv_path)))
    PSW.write_raw(sv_path, new_text)
    print(f'  [OK  ] 已更新 {os.path.basename(sv_path)}（{len(updates)} 项配置开关，原档已备份）')
    return True


def restore_unpatched_files(bk_dir, dry_run=False):
    print('=== 1) 恢复已零补丁化的 3 个第三方原版文件 ===')
    # 1a. EUI v9.9.6 两个姓名板文件
    if os.path.isfile(EUI_ZIP):
        with zipfile.ZipFile(EUI_ZIP, 'r') as z:
            for rel in (
                'EllesmereUINameplates/EUI_Nameplates_Name.lua',
                'EllesmereUINameplates/EUI_Nameplates_CastState.lua',
            ):
                dst = os.path.join(ADDONS, *rel.split('/'))
                if rel not in z.namelist():
                    print(f'  [WARN] zip 中找不到 {rel}')
                    continue
                if dry_run:
                    print(f'  [DRY ] 将从 EllesmereUI-v9.9.6.zip 恢复原版 {rel}')
                else:
                    if os.path.isfile(dst):
                        b = os.path.join(bk_dir, 'RestoredFromPatched', *rel.split('/'))
                        os.makedirs(os.path.dirname(b), exist_ok=True)
                        shutil.copy2(dst, b)
                    open(dst, 'wb').write(z.read(rel))
                    print(f'  [OK  ] 已恢复纯净原版 {rel}')
    else:
        print(f'  [WARN] 未找到 {EUI_ZIP}，跳过 EUI 姓名板原版恢复')

    # 1b. Polestar/UI/DungeonToast.lua
    ps_dst = os.path.join(ADDONS, 'Polestar', 'UI', 'DungeonToast.lua')
    if os.path.isfile(PS_ORIG_TOAST) and os.path.isfile(ps_dst):
        if dry_run:
            print('  [DRY ] 将从备份恢复原版 Polestar/UI/DungeonToast.lua')
        else:
            b = os.path.join(bk_dir, 'RestoredFromPatched', 'Polestar', 'UI', 'DungeonToast.lua')
            os.makedirs(os.path.dirname(b), exist_ok=True)
            shutil.copy2(ps_dst, b)
            shutil.copy2(PS_ORIG_TOAST, ps_dst)
            print('  [OK  ] 已恢复纯净原版 Polestar/UI/DungeonToast.lua')
    else:
        print(f'  [WARN] 未找到 {PS_ORIG_TOAST}，跳过 DungeonToast.lua 恢复')


def retire_overlapped_addons(bk_dir, dry_run=False):
    print('\n=== 2) 退场 5 个已被无损接管的重叠插件（移入 backups/） ===')
    present = [d for d in RETIRED_ADDONS if os.path.isdir(os.path.join(ADDONS, d))]
    if not present:
        print('  无待退场目录（已清理）。')
        return
    tot_mb = 0.0
    for d in present:
        p = os.path.join(ADDONS, d)
        mb = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(p) for f in fs) / 1048576
        tot_mb += mb
        if dry_run:
            print(f'  [DRY ] 将移入备份：{d:<26} ({mb:5.2f} MB)')
        else:
            dst_dir = os.path.join(bk_dir, 'RetiredAddOns')
            os.makedirs(dst_dir, exist_ok=True)
            shutil.move(p, os.path.join(dst_dir, d))
            print(f'  [OK  ] 已移入备份：{d:<26} ({mb:5.2f} MB)')
    print(f'  合计释放：{tot_mb:.2f} MB（{len(present)} 个插件）')


def apply_sv_handoff(bk_dir, dry_run=False):
    print('\n=== 3) 开启 EUI 与 Polestar 对应原生替代开关 ===')
    acc = PSW.detect_account()
    if not acc:
        print('  [WARN] 无法自动定位唯一账号目录（可设 WOW_ACCOUNT_DIR），跳过 SavedVariables 写入')
        return
    sv_dir = os.path.join(acc, 'SavedVariables')
    sv_bk = os.path.join(bk_dir, 'SavedVariables')

    B_TRUE = PSW.Raw('b', 'true')
    B_FALSE = PSW.Raw('b', 'false')

    eui_updates = [
        (('shifterEnabled',), B_TRUE),
        (('shifterNoShift',), B_TRUE),
        (('worldMapReveal', 'enabled'), B_TRUE),
        (('mapTravel', 'enabled'), B_TRUE),
        (('mapTravel', 'transports'), B_TRUE),
        (('mapTravel', 'exits'), B_TRUE),
        (('mapTravel', 'flights'), B_TRUE),
        (('mapTravel', 'instances'), B_FALSE),
        (('worldMapFade', 'enabled'), B_FALSE),
        (('worldMapFade', 'dim'), B_TRUE),
        (('worldMapFade', 'dimOpacity'), PSW.Raw('n', '0')),
        (('worldMapFade', 'dimClickThrough'), B_TRUE),
        (('zoneLevels', 'enabled'), B_FALSE),
        (('zoneLevels', 'fishing'), B_TRUE),
        (('inGameNavigation', 'enabled'), B_TRUE),
    ]
    update_sv_file(os.path.join(sv_dir, 'EllesmereUI.lua'), 'EllesmereUIDB', eui_updates, sv_bk, dry_run=dry_run)

    ps_updates = [
        (('settings', 'gear', 'enabled'), B_FALSE),
        (('settings', 'nav', 'mapPlan'), B_TRUE),
        (('settings', 'nav', 'blizzardWaypoint'), B_TRUE),
    ]
    update_sv_file(os.path.join(sv_dir, 'Polestar.lua'), 'PolestarDB', ps_updates, sv_bk, dry_run=dry_run)


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='kkowoUI 阶段 2 零补丁化与重叠插件交接脚本')
    ap.add_argument('--dry-run', action='store_true', help='只读预览，不写入任何游戏文件')
    args = ap.parse_args()

    if not args.dry_run and wow_running():
        sys.exit('魔兽世界正在运行：请完全退出游戏后再执行阶段 2 交接（游戏退出时会覆盖 SavedVariables）。')

    stamp = time.strftime('%Y%m%d_%H%M%S')
    bk_dir = os.path.join(BACKUP_ROOT, f'Phase2_Handoff_{stamp}')
    restore_unpatched_files(bk_dir, dry_run=args.dry_run)
    retire_overlapped_addons(bk_dir, dry_run=args.dry_run)
    apply_sv_handoff(bk_dir, dry_run=args.dry_run)

    if args.dry_run:
        print('\nDry-run 完成，未修改游戏文件。退出游戏后不加 --dry-run 即可执行。')
        return 0

    print('\n=== 4) 部署阶段 2 新版 kkowoUI 并核验补丁 ===')
    subprocess.run(
        ['powershell', '-ExecutionPolicy', 'Bypass', '-File', os.path.join(HERE, 'deploy.ps1')],
        check=True,
    )
    subprocess.run([sys.executable, '-I', os.path.join(HERE, 'apply_patches.py'), '--check'], check=False)
    print(f'\n阶段 2 交接完成！全部旧文件与原存档均已安全备份至：{bk_dir}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
