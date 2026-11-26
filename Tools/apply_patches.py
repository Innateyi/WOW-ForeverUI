# -*- coding: utf-8 -*-
"""
统一本地补丁管理脚本：
  python Tools/apply_patches.py --check   # 只读检查全部补丁状态（玩游戏期间可安全运行）
  python Tools/apply_patches.py --apply   # 退出游戏后一键应用全部补丁（带自动备份）
"""
import importlib.util
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATCH_DIR = os.path.join(ROOT, 'Patches')
PATCH_LIST = [
    'eui_np_questtext_name.py',
    'eui_friendly_player_names.py',
    'eui_chat_tab_fast.py',
    'vss_kkowo_rename.py',      # 先改名为 VamoosesSlipstream_kkowo（DD 不再认得、不会覆盖），再打跑尸开关
    'vss_corpse_toggle.py',
    'polestar_zhcn_fill.py',
]


def load_patch(path):
    spec = importlib.util.spec_from_file_location(os.path.basename(path), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def wow_running():
    try:
        out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Wow.exe'], capture_output=True, text=True,
                             encoding='mbcs', errors='replace', timeout=10).stdout
        return 'Wow.exe' in out
    except Exception:
        return False


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    apply_mode = '--apply' in sys.argv
    check_only = not apply_mode
    if apply_mode and wow_running():
        print('魔兽世界正在运行：请完全退出游戏后再打补丁（改名会动存档与 AddOns.txt，游戏退出时会覆盖它们）。')
        return 2
    print('=== kkowoUI 补丁检查（只读） ===' if check_only else '=== kkowoUI 一键应用补丁 ===')
    failed = 0
    for name in PATCH_LIST:
        try:
            mod = load_patch(os.path.join(PATCH_DIR, name))
            status, msg = mod.run(check_only=check_only)
        except (OSError, UnicodeDecodeError) as e:
            # 目标插件文件被改名/删除或编码异常：报告并继续检查其余补丁，而不是整个脚本崩溃
            status, msg = 'ERROR', f'{type(e).__name__}: {e}'
        ok = status in ('APPLIED', 'APPLIED_LEGACY', 'READY', 'PATCHED')
        mark = 'OK  ' if ok else 'WARN'
        print(f'[{mark}] {name:<30} | {status:<15} | {msg}')
        if not ok:
            failed += 1
    if check_only:
        print('\n提示：以上为只读检查，未修改游戏文件。退出游戏后加 --apply 即可写入。')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
