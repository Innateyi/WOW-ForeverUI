# -*- coding: utf-8 -*-
r"""
KkowoUI — 停用插件安全归档工具（方案 A）
功能：
  1. 读取当前角色的 AddOns.txt（环境变量 WOW_ADDONS_TXT），识别全部已停用（disabled）的非 Blizzard 插件
  2. 校验所有已启用插件的 .toc RequiredDeps / Dependencies，确认无任何必需依赖
  3. 将停用插件文件夹安全移出至 <备份目录>\ArchivedAddOns\<timestamp>\（环境变量 WOW_BACKUP_ROOT 可覆盖）
  4. 生成 RESTORE_MANIFEST.txt（记录原路径、目标路径与体积，随时可一键还原）
  5. 若魔兽客户端未运行，自动备份 AddOns.txt 并同步移除已归档的停用条目
"""
import datetime
import os
import re
import shutil
import subprocess
import sys

ADDONS_DIR = os.environ.get("WOW_ADDONS_DIR") or os.path.join(
    os.environ.get("WOW_FOREVER_DIR", r"E:\Program Files\World of Warcraft\_forever_"), "Interface", "AddOns")
ADDONS_TXT = os.environ.get("WOW_ADDONS_TXT", r"E:\Program Files\World of Warcraft\_forever_\WTF\Account\<YourAccountID>\<Realm>\<CharName>\AddOns.txt")
# WOW_BACKUP_ROOT 与 Patches/*.py 含义一致：备份总目录（默认仓库同级的 backups），本工具在其下建 ArchivedAddOns
ARCHIVE_ROOT = os.path.join(
    os.environ.get("WOW_BACKUP_ROOT", os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "backups"))),
    "ArchivedAddOns",
)

PROTECTED_ALWAYS = {"KkowoUI", "EllesmereUI", "YaMedia"}


def is_wow_running():
    try:
        out = subprocess.check_output(
            ["tasklist", "/FO", "CSV", "/NH"],
            stderr=subprocess.DEVNULL,
            text=True,
            errors="ignore",
        )
        for line in out.splitlines():
            low = line.lower()
            if '"wow' in low and '.exe"' in low:
                return line.split(",")[0].strip('"')
    except Exception:
        pass
    return None


def dir_size_bytes(path):
    total = 0
    for root, _, files in os.walk(path):
        for fn in files:
            try:
                total += os.path.getsize(os.path.join(root, fn))
            except OSError:
                pass
    return total


def parse_required_deps(addon_dir):
    deps = set()
    if not os.path.isdir(addon_dir):
        return deps
    for fn in os.listdir(addon_dir):
        if fn.lower().endswith(".toc"):
            p = os.path.join(addon_dir, fn)
            try:
                txt = open(p, "r", encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            for m in re.finditer(r"(?im)^##\s*(?:RequiredDeps|Dependencies)\s*:\s*(.+)$", txt):
                for dep in m.group(1).split(","):
                    d = dep.strip()
                    if d:
                        deps.add(d)
    return deps


def main():
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

    if not os.path.exists(ADDONS_TXT):
        sys.exit(f"ERROR: AddOns.txt not found: {ADDONS_TXT}")
    if not os.path.isdir(ADDONS_DIR):
        sys.exit(f"ERROR: AddOns dir not found: {ADDONS_DIR}")

    raw = open(ADDONS_TXT, "rb").read()
    crlf = b"\r\n" in raw
    lines = raw.decode("utf-8", errors="replace").replace("\r\n", "\n").split("\n")

    enabled = []
    disabled = []
    for line in lines:
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        name = k.strip()
        state = v.strip().lower()
        if state == "enabled":
            enabled.append(name)
        elif state == "disabled":
            disabled.append(name)

    # 校验所有已启用插件的硬依赖
    hard_deps = set()
    for name in enabled:
        hard_deps |= parse_required_deps(os.path.join(ADDONS_DIR, name))

    blocked = []
    candidates = []
    missing_dirs = []
    for name in disabled:
        if name.startswith("Blizzard_") or name in PROTECTED_ALWAYS:
            blocked.append((name, "protected"))
            continue
        if name in hard_deps:
            blocked.append((name, "required_by_enabled"))
            continue
        src = os.path.join(ADDONS_DIR, name)
        if not os.path.exists(src):
            missing_dirs.append(name)
            continue
        # NTFS 目录联接（deploy.ps1 -Link 创建的就是这种）在 os.path.islink 下返回 False，必须单独识别：
        # 跨盘 shutil.move 会把联接指向的仓库内容整份拷走再删掉联接
        is_junction = hasattr(os.path, "isjunction") and os.path.isjunction(src)
        if os.path.islink(src) or is_junction:
            blocked.append((name, "symlink/junction"))
            continue
        candidates.append((name, src))

    wow_proc = is_wow_running()
    if wow_proc and "--force" not in sys.argv:
        print("检测到魔兽客户端正在运行：请先退出游戏再归档（或加 --force 强制执行）。")
        return 1
    if not candidates:
        print("没有可归档的停用插件。")
        return 0
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dest_dir = os.path.join(ARCHIVE_ROOT, ts)
    os.makedirs(dest_dir, exist_ok=True)

    moved = []
    failed = []
    total_bytes = 0

    for name, src in candidates:
        sz = dir_size_bytes(src)
        dst = os.path.join(dest_dir, name)
        try:
            shutil.move(src, dst)
            moved.append((name, sz))
            total_bytes += sz
        except Exception as exc:
            failed.append((name, str(exc)))

    # 写入归档清单
    manifest_path = os.path.join(dest_dir, "RESTORE_MANIFEST.txt")
    with open(manifest_path, "w", encoding="utf-8") as mf:
        mf.write(f"Archive Time: {ts}\n")
        mf.write(f"Source AddOns Dir: {ADDONS_DIR}\n")
        mf.write(f"Moved Count: {len(moved)} | Total MB: {total_bytes / (1024 * 1024):.2f}\n\n")
        for name, sz in moved:
            mf.write(f"{name}\t{sz / (1024 * 1024):.2f} MB\n")

    # 仅在 WoW 未运行时同步清理 AddOns.txt 中已移走的条目（先备份）
    cleaned_txt = False
    moved_names = {n for n, _ in moved}
    if not wow_proc and moved_names:
        shutil.copy2(ADDONS_TXT, os.path.join(dest_dir, "AddOns.txt.bak"))
        new_lines = []
        for line in lines:
            if ":" in line:
                k = line.split(":", 1)[0].strip()
                if k in moved_names:
                    continue
            new_lines.append(line)
        content = ("\r\n" if crlf else "\n").join(new_lines)
        open(ADDONS_TXT, "wb").write(content.encode("utf-8"))
        cleaned_txt = True

    # 检查 AddOns 目录下剩余的第三方文件夹数量
    remaining_dirs = sorted(
        d for d in os.listdir(ADDONS_DIR)
        if os.path.isdir(os.path.join(ADDONS_DIR, d)) and not d.startswith("Blizzard_")
    )

    print(f"WOW_RUNNING: {wow_proc or 'NO'}")
    print(f"ARCHIVE_DIR: {dest_dir}")
    print(f"MOVED_COUNT: {len(moved)}")
    print(f"TOTAL_MB: {total_bytes / (1024 * 1024):.2f}")
    print(f"CLEANED_ADDONS_TXT: {cleaned_txt}")
    print(f"REMAINING_ADDON_DIRS: {len(remaining_dirs)}")
    if blocked:
        print("BLOCKED:", blocked)
    if missing_dirs:
        print("MISSING_ON_DISK:", missing_dirs)
    if failed:
        print("FAILED:", failed)
    print("MOVED_LIST:", ", ".join(n for n, _ in moved))


if __name__ == "__main__":
    sys.exit(main() or 0)
