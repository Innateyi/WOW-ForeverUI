# -*- coding: utf-8 -*-
r"""
kkowoUI 阶段 3 一键安全交接脚本（必须完全退出魔兽世界后运行；支持 --dry-run 只读预览）：
  1. 无损迁移 PrettyTooltip SavedVariables → kkowoUI_Tooltip.lua（先完整备份原档）
  2. 更新各角色 AddOns.txt：PrettyTooltip → kkowoUI_Tooltip（先备份每个 AddOns.txt）
  3. 将独立版 PrettyTooltip 整夹移入 backups\Phase3_Handoff_<时间>\RetiredAddOns\PrettyTooltip
  4. 调用 deploy.ps1 部署 kkowoUI + kkowoUI_Tooltip，并运行 apply_patches.py --apply
     将 3 个极简补丁升级到含 PatchGuard 运行时标记的 v2 版本，最后核验 --check。
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
ADDONS = os.path.join(WOW_ROOT, 'Interface', 'AddOns')
WTF_ACC = os.path.join(WOW_ROOT, 'WTF', 'Account')
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(ROOT, '..', 'backups')))


def wow_running():
    try:
        out = subprocess.run(
            ['tasklist', '/FI', 'IMAGENAME eq Wow.exe'],
            capture_output=True, text=True, encoding='mbcs', errors='replace', timeout=10,
        ).stdout
        return 'Wow.exe' in out
    except Exception:
        return False


def migrate_saved_variables(bk_dir, dry_run=False):
    print('=== 1) 无损迁移 PrettyTooltip SavedVariables → kkowoUI_Tooltip ===')
    if not os.path.isdir(WTF_ACC):
        print(f'  [SKIP] 未找到账号目录：{WTF_ACC}')
        return
    migrated = 0
    for acc in sorted(os.listdir(WTF_ACC)):
        sv_dir = os.path.join(WTF_ACC, acc, 'SavedVariables')
        if not os.path.isdir(sv_dir):
            continue
        src = os.path.join(sv_dir, 'PrettyTooltip.lua')
        dst = os.path.join(sv_dir, 'kkowoUI_Tooltip.lua')
        if not os.path.isfile(src):
            continue
        if os.path.isfile(dst):
            print(f'  [SKIP] {acc}\\SavedVariables\\kkowoUI_Tooltip.lua 已存在，保持现状')
            continue
        if dry_run:
            print(f'  [DRY ] 将复制 {acc}\\SavedVariables\\PrettyTooltip.lua → kkowoUI_Tooltip.lua ({os.path.getsize(src)} bytes)')
        else:
            sv_bk = os.path.join(bk_dir, 'SavedVariables', acc)
            os.makedirs(sv_bk, exist_ok=True)
            shutil.copy2(src, os.path.join(sv_bk, 'PrettyTooltip.lua'))
            shutil.copy2(src, dst)
            print(f'  [OK  ] 已迁移 {acc}\\SavedVariables\\PrettyTooltip.lua → kkowoUI_Tooltip.lua')
        migrated += 1
    if migrated == 0:
        print('  无待迁移的 PrettyTooltip.lua。')


def update_addons_txt(bk_dir, dry_run=False):
    print('\n=== 2) 更新各角色 AddOns.txt（PrettyTooltip → kkowoUI_Tooltip） ===')
    if not os.path.isdir(WTF_ACC):
        return
    updated = 0
    for dp, _, files in os.walk(WTF_ACC):
        for fn in files:
            if fn.lower() != 'addons.txt':
                continue
            p = os.path.join(dp, fn)
            raw = open(p, 'rb').read().decode('utf-8', errors='replace')
            nl = '\r\n' if '\r\n' in raw else '\n'
            lines = raw.replace('\r\n', '\n').split('\n')
            has_new = any(ln.strip().startswith('kkowoUI_Tooltip:') for ln in lines)
            changed = False
            out = []
            for ln in lines:
                s = ln.strip()
                if s.startswith('PrettyTooltip:'):
                    changed = True
                    if not has_new:
                        state = s.split(':', 1)[1].strip()
                        out.append(f'kkowoUI_Tooltip: {state}')
                        has_new = True
                    continue
                out.append(ln)
            if not has_new:
                # 确保未列出的角色也会启用 kkowoUI_Tooltip
                if out and out[-1] == '':
                    out.insert(-1, 'kkowoUI_Tooltip: enabled')
                else:
                    out.append('kkowoUI_Tooltip: enabled')
                changed = True
            if not changed:
                continue
            rel = os.path.relpath(p, WTF_ACC)
            if dry_run:
                print(f'  [DRY ] 将更新 {rel}')
            else:
                b = os.path.join(bk_dir, 'AddOnsTxt', rel)
                os.makedirs(os.path.dirname(b), exist_ok=True)
                shutil.copy2(p, b)
                open(p, 'wb').write(nl.join(out).encode('utf-8'))
                print(f'  [OK  ] 已更新 {rel}')
            updated += 1
    if updated == 0:
        print('  所有 AddOns.txt 均已就绪。')


def retire_standalone_prettytooltip(bk_dir, dry_run=False):
    print('\n=== 3) 退场独立版 PrettyTooltip（移入 backups/，绝不硬删） ===')
    p = os.path.join(ADDONS, 'PrettyTooltip')
    if not os.path.isdir(p):
        print('  独立版 PrettyTooltip 已不存在（已清理）。')
        return
    mb = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(p) for f in fs) / 1048576
    if dry_run:
        print(f'  [DRY ] 将移入备份：PrettyTooltip ({mb:.2f} MB)')
    else:
        dst_dir = os.path.join(bk_dir, 'RetiredAddOns')
        os.makedirs(dst_dir, exist_ok=True)
        shutil.move(p, os.path.join(dst_dir, 'PrettyTooltip'))
        print(f'  [OK  ] 已移入备份：PrettyTooltip ({mb:.2f} MB)')


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='kkowoUI 阶段 3 安全交接脚本（MIT 整合 PrettyTooltip + 补丁守卫 v2）')
    ap.add_argument('--dry-run', action='store_true', help='只读预览，不写入任何游戏文件')
    args = ap.parse_args()

    if not args.dry_run and wow_running():
        sys.exit('魔兽世界正在运行：请完全退出游戏后再执行阶段 3 交接。')

    stamp = time.strftime('%Y%m%d_%H%M%S')
    bk_dir = os.path.join(BACKUP_ROOT, f'Phase3_Handoff_{stamp}')

    migrate_saved_variables(bk_dir, dry_run=args.dry_run)
    update_addons_txt(bk_dir, dry_run=args.dry_run)
    retire_standalone_prettytooltip(bk_dir, dry_run=args.dry_run)

    if args.dry_run:
        print('\nDry-run 完成，未修改游戏文件。')
        return 0

    print('\n=== 4) 部署 kkowoUI + kkowoUI_Tooltip 并升级 3 个极简补丁至 v2（含 PatchGuard 标记） ===')
    subprocess.run(
        ['powershell', '-ExecutionPolicy', 'Bypass', '-File', os.path.join(HERE, 'deploy.ps1')],
        check=True,
    )
    subprocess.run([sys.executable, '-I', os.path.join(HERE, 'apply_patches.py'), '--apply'], check=True)
    subprocess.run([sys.executable, '-I', os.path.join(HERE, 'apply_patches.py'), '--check'], check=True)
    print(f'\n阶段 3 交接完成！原 PrettyTooltip 与存档备份位于：{bk_dir}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
