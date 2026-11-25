#!/usr/bin/env python3
r"""
KkowoUI — 全局 3D 团队标记图标部署脚本
将 MarkBar 重绘的 512x512 无损多级 Mipmap BLP2 团队标记图集安装到客户端
E:\Program Files\World of Warcraft\_forever_\Interface\TargetingFrame\UI-RaidTargetingIcons.blp
以替换 3D 世界头顶标记、聊天频道 {rt1}-{rt8} 及全局单位框体/姓名板标记。

用法：
  python -I Tools/deploy_raid_markers.py --install
  python -I Tools/deploy_raid_markers.py --uninstall
"""
import argparse
import os
import shutil

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_BLP = os.path.join(REPO_ROOT, "Addon", "KkowoUI", "Media", "MarkBar", "UI-RaidTargetingIcons.blp")
DST_DIR = r"E:\Program Files\World of Warcraft\_forever_\Interface\TargetingFrame"
DST_BLP = os.path.join(DST_DIR, "UI-RaidTargetingIcons.blp")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--install", action="store_true", help="安装全局团队标记图标覆盖")
    group.add_argument("--uninstall", action="store_true", help="移除客户端覆盖，恢复暴雪原版 3D 标记")
    args = parser.parse_args()

    if args.install:
        if not os.path.isfile(SRC_BLP):
            raise SystemExit(f"找不到源文件：{SRC_BLP}，请先运行 Tools/gen_systembar_and_raid_icons.py")
        os.makedirs(DST_DIR, exist_ok=True)
        shutil.copy2(SRC_BLP, DST_BLP)
        print(f"[INSTALLED] {DST_BLP} ({os.path.getsize(DST_BLP)} bytes)")
        print("提示：重启魔兽世界客户端后，3D 世界头顶标记、单位框体与聊天标记图标将全部同步为新扁平矢量风格。")
    else:
        if os.path.isfile(DST_BLP):
            os.remove(DST_BLP)
            print(f"[REMOVED] {DST_BLP}")
        else:
            print("[OK] 客户端目录未检测到自定义覆盖文件。")


if __name__ == "__main__":
    main()
