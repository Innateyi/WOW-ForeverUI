#!/usr/bin/env python3
r"""
kkowoUI — 全局团队标记图标部署脚本
将 MarkBar 重绘的 1024x1024 超高清 SDF 无损多级 Mipmap BLP2 团队标记图集安装到客户端
E:\Program Files\World of Warcraft\_forever_\Interface\TargetingFrame\UI-RaidTargetingIcons.blp
以替换单位框体、姓名板与聊天频道 {rt1}-{rt8} 团队标记图标（注：12.x 引擎对角色自身 3D 世界头顶标记做了硬编码，不受松散贴图替换影响）。

用法：
  python -I Tools/deploy_raid_markers.py --install
  python -I Tools/deploy_raid_markers.py --uninstall
"""
import argparse
import datetime
import os
import shutil

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKUP_ROOT = os.environ.get("WOW_BACKUP_ROOT", os.path.normpath(os.path.join(REPO_ROOT, "..", "backups")))
SRC_BLP = os.path.join(REPO_ROOT, "Addon", "kkowoUI_Media", "Media", "MarkBar", "UI-RaidTargetingIcons.blp")
DST_DIR = os.path.join(os.environ.get("WOW_FOREVER_DIR", r"E:\Program Files\World of Warcraft\_forever_"), "Interface", "TargetingFrame")
DST_BLP = os.path.join(DST_DIR, "UI-RaidTargetingIcons.blp")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--install", action="store_true", help="安装全局团队标记图标覆盖")
    group.add_argument("--uninstall", action="store_true", help="移走客户端覆盖并备份，恢复暴雪原版团队标记")
    args = parser.parse_args()

    if args.install:
        if not os.path.isfile(SRC_BLP):
            raise SystemExit(f"找不到源文件：{SRC_BLP}，请先运行 Tools/gen_systembar_and_raid_icons.py")
        os.makedirs(DST_DIR, exist_ok=True)
        if os.path.isfile(DST_BLP):
            ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            bdir = os.path.join(BACKUP_ROOT, f"raid_markers_before_install_{ts}")
            os.makedirs(bdir, exist_ok=True)
            shutil.copy2(DST_BLP, os.path.join(bdir, os.path.basename(DST_BLP)))
        shutil.copy2(SRC_BLP, DST_BLP)
        print(f"[INSTALLED] {DST_BLP} ({os.path.getsize(DST_BLP)} bytes)")
        print("提示：重启魔兽世界客户端后，单位框体、姓名板与聊天 {rt1}-{rt8} 团队标记图标将同步为新扁平矢量风格。")
    else:
        if os.path.isfile(DST_BLP):
            ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            bdir = os.path.join(BACKUP_ROOT, f"raid_markers_uninstall_{ts}")
            os.makedirs(bdir, exist_ok=True)
            dst_bk = os.path.join(bdir, os.path.basename(DST_BLP))
            shutil.move(DST_BLP, dst_bk)
            print(f"[MOVED_TO_BACKUP] {DST_BLP} -> {dst_bk}")
        else:
            print("[OK] 客户端目录未检测到自定义覆盖文件。")


if __name__ == "__main__":
    main()
