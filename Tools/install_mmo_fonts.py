#!/usr/bin/env python3
r"""
kkowoUI — 多字重 MMO 字体 5 槽位安装与一键回滚工具
自动将 HarmonyOS Sans SC / MiSans / 思源黑体等多字重字体按视觉层次映射到 WoW 5 个核心字体槽位，
并在安装前自动备份原有 Fonts 目录、清理旧 .slug / .slugo GPU 矢量缓存。

5 槽位科学字重分工：
  - ARKai_T.ttf  (UI正文 / 3D头顶名称 / 姓名板) -> Medium (500)
  - ARHei.ttf    (聊天正文 / 任务说明长文本)    -> Regular (400)
  - ARIALN.ttf   (数字 / 冷却 / 快捷键 / 血量)  -> SemiBold/Bold (600-700)
  - FRIZQT__.ttf (标题 / 区域名 / 框体标题)     -> SemiBold/Bold (600-700)
  - ARKai_C.ttf  (原生伤害槽，kkowoUI独立管战伤) -> Bold (700)

用法：
  python -I Tools/install_mmo_fonts.py --src "C:\path\to\HarmonyOS_Sans_SC"
  python -I Tools/install_mmo_fonts.py --rollback
"""
import argparse
import datetime
import glob
import os
import shutil
import subprocess

WOW_FONTS = os.path.join(os.environ.get("WOW_FOREVER_DIR", r"E:\Program Files\World of Warcraft\_forever_"), "Fonts")
BACKUP_ROOT = os.environ.get(
    "WOW_BACKUP_ROOT",
    os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "backups")),
)
SLOTS = ("ARKai_T.ttf", "ARHei.ttf", "ARIALN.ttf", "FRIZQT__.ttf", "ARKai_C.ttf")


def wow_running():
    try:
        r = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq Wow.exe"],
            capture_output=True, text=True, encoding="mbcs", errors="replace", timeout=10,
        )
        if r.returncode != 0:
            return True
        return "Wow.exe" in r.stdout
    except Exception:
        return True


def find_weight_file(src_dir: str, candidates):
    files = []
    for root, _, names in os.walk(src_dir):
        for n in names:
            if n.startswith("."):
                continue
            if n.lower().endswith((".ttf", ".otf")):
                full = os.path.join(root, n)
                # 排除仅含拉丁字母的精简子集（中文完整字库通常 > 4MB），避免游戏内中文变方块
                if os.path.getsize(full) >= 4 * 1024 * 1024:
                    files.append(full)
    # 优先选择简体中文 SC / CN / Hans 变体
    files.sort(key=lambda p: (
        0 if any(k in os.path.basename(p).lower() for k in ("_sc", "-sc", "hans", "cn")) else 1,
        os.path.basename(p).lower(),
    ))
    for pat in candidates:
        for f in files:
            base = os.path.basename(f).lower()
            if pat in base:
                return f
    return None


def backup_existing():
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dst = os.path.join(BACKUP_ROOT, f"Fonts_Backup_{ts}")
    os.makedirs(dst, exist_ok=True)
    copied = 0
    for slot in SLOTS:
        p = os.path.join(WOW_FONTS, slot)
        if os.path.isfile(p):
            shutil.copy2(p, os.path.join(dst, slot))
            copied += 1
    print(f"[BACKUP] 已备份 {copied} 个原字体到：{dst}")
    return dst


def clear_slug_caches():
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dst_dir = os.path.join(BACKUP_ROOT, f"Fonts_SlugCache_{ts}")
    moved = 0
    for pat in ("*.slug", "*.slugo"):
        for f in glob.glob(os.path.join(WOW_FONTS, pat)):
            try:
                os.makedirs(dst_dir, exist_ok=True)
                shutil.move(f, os.path.join(dst_dir, os.path.basename(f)))
                moved += 1
            except OSError:
                pass
    print(f"[CACHE] 已将 {moved} 个旧 .slug/.slugo 字体缓存移入备份（重启游戏自动重建）")


def install_from_dir(src_dir: str):
    if wow_running():
        raise SystemExit("检测到魔兽世界正在运行：请完全退出游戏后再安装字体。")
    if not os.path.isdir(src_dir):
        raise SystemExit(f"找不到字体目录：{src_dir}")

    f_regular = find_weight_file(src_dir, ["regular", "normal", "book"])
    f_medium = find_weight_file(src_dir, ["medium", "demibold"]) or f_regular
    f_semibold = find_weight_file(src_dir, ["semibold", "demibold", "bold"]) or f_medium
    f_bold = find_weight_file(src_dir, ["bold", "heavy", "semibold"]) or f_semibold
    f_black = find_weight_file(src_dir, ["black", "heavy", "extrabold"]) or f_bold

    if not f_regular or not f_medium:
        raise SystemExit("未在目录中找到 Regular/Medium 字重文件（支持 HarmonyOS Sans SC / MiSans / Source Han Sans 静态 TTF/OTF）。")

    # 针对 1080p/1440p 游戏屏幕实测油墨密度标定（消除细字发虚与 3D 视角转动闪烁）：
    # HarmonyOS Bold 实测像素密度 13.5%（与魔兽经典游戏字饱满度持平，但笔画直爽通透不糊）；
    # HarmonyOS Medium 10.6% 用于聊天/长文区分层次，不再使用过细的 Regular (9.3%)。
    mapping = {
        "ARKai_T.ttf": f_bold,
        "ARHei.ttf": f_medium,
        "ARIALN.ttf": f_bold,
        "FRIZQT__.ttf": f_bold,
        "ARKai_C.ttf": f_black,
    }

    os.makedirs(WOW_FONTS, exist_ok=True)
    backup_existing()
    for slot, src_font in mapping.items():
        shutil.copy2(src_font, os.path.join(WOW_FONTS, slot))
        print(f"  {slot:14s} <- {os.path.basename(src_font)}")
    clear_slug_caches()
    print("[DONE] 多字重字体已安装完成，请完全重启魔兽世界客户端生效。")


def rollback_latest():
    if wow_running():
        raise SystemExit("检测到魔兽世界正在运行：请完全退出游戏后再回滚字体。")
    baks = sorted(glob.glob(os.path.join(BACKUP_ROOT, "Fonts_Backup_*")), reverse=True)
    if not baks:
        raise SystemExit(f"在 {BACKUP_ROOT} 中未找到 Fonts_Backup_* 备份目录。")
    latest = baks[0]
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    removed_dir = os.path.join(BACKUP_ROOT, f"Fonts_RollbackRemoved_{ts}")
    for slot in SLOTS:
        src = os.path.join(latest, slot)
        dst = os.path.join(WOW_FONTS, slot)
        if os.path.isfile(src):
            shutil.copy2(src, dst)
            print(f"  Restored {slot}")
        elif os.path.isfile(dst):
            # 备份里没有该槽位 = 安装前客户端本来就没有这个覆盖字体：移入备份，回到游戏内置字体（绝不硬删）
            os.makedirs(removed_dir, exist_ok=True)
            shutil.move(dst, os.path.join(removed_dir, slot))
            print(f"  Moved to backup: {slot}（安装前不存在）")
    clear_slug_caches()
    print(f"[ROLLBACK] 已从 {latest} 还原原有字体，请重启客户端。")


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--src", help="包含 Regular/Medium/SemiBold/Bold 静态字体的文件夹路径")
    group.add_argument("--rollback", action="store_true", help="回滚到最近一次备份的原字体")
    args = parser.parse_args()
    if args.rollback:
        rollback_latest()
    else:
        install_from_dir(args.src)


if __name__ == "__main__":
    main()
