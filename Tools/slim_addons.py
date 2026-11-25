# -*- coding: utf-8 -*-
r"""
KkowoUI — 安全插件瘦身与 6 合 1 切换脚本
功能：
  1. 检测 WoW 客户端是否在运行（若运行中默认中止，防止退出游戏时覆盖 AddOns.txt）
  2. 自动备份 AddOns.txt 到 D:\code\wow\backups\PreSlim_<timestamp>\
  3. 停用已合并进 KkowoUI 的 7 个插件 + 17 个确认闲置/重叠/重型子插件（共释放 ~36+ MB 常驻 Lua）
  4. 完整保留全部核心玩法与界面布局插件（EllesmereUI 核心、Polestar、Questie、BigWigs、ArcAuras 核心、Auctionator、Leatrix_Maps、WaypointUI、VSS、DungeonsForever 主体等）
用法：
  python D:\code\wow\forever-ui\Tools\slim_addons.py
"""
import datetime
import os
import re
import shutil
import subprocess
import sys

ADDONS_TXT = os.environ.get("WOW_ADDONS_TXT", r"E:\Program Files\World of Warcraft\_forever_\WTF\Account\<YourAccountID>\<Realm>\<CharName>\AddOns.txt")
KKOWOUI_SV = os.environ.get("WOW_KKOWOUI_SV", r"E:\Program Files\World of Warcraft\_forever_\WTF\Account\<YourAccountID>\SavedVariables\KkowoUI.lua")
BACKUP_ROOT = os.environ.get("WOW_BACKUP_ROOT", r"D:\code\wow\backups")

# 已合并进 KkowoUI 的 6 个插件（PrettyTooltip 保留以完整呈现卡片提示）
MERGED_INTO_KKOWOUI = [
    "QFXSystemBar",
    "QFXSystemBar_Config",
    "QFXSystemBar_InfoBar",
    "QFXSystemBar_Locale",
    "QFXSystemBar_MeetingStone",
    "EllesmereUIDataBars",
]

# 确认闲置 / 练级无用 / 重叠重型插件（17 个）
IDLE_OR_REDUNDANT = [
    "TalentsForever",
    "ForeverFishing",
    "ArcAuras_Finds",
    "ArcAuras_LFG",
    "EllesmereUIAuraBuffReminders",
    "EllesmereUIQuickdraw",
    "EllesmereUIMythicTimer",
    "GlowingBars",
    "MiniMarkers",
    "DungeonsForeverPvP",
    "DungeonsForeverExplore",
    "DungeonsForeverClass",
    "DungeonsForeverProf",
    "DungeonsForeverGear",
    "DungeonsForeverSpell",
    "DungeonsForeverFaction",
    "DungeonsForeverQuest",
]

TO_DISABLE = set(MERGED_INTO_KKOWOUI + IDLE_OR_REDUNDANT)
TO_ENABLE = {"KkowoUI"}


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


def main():
    force = "--force" in sys.argv
    proc = is_wow_running()
    if proc and not force:
        print(f"WOW_RUNNING: {proc}")
        print("检测到魔兽世界正在运行。为防止游戏退出时覆盖 AddOns.txt，本次未修改文件。")
        print("请先完全退出游戏，再运行本脚本即可安全应用瘦身配置。")
        sys.exit(2)

    if not os.path.exists(ADDONS_TXT):
        sys.exit(f"找不到 AddOns.txt：{ADDONS_TXT}")

    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    bdir = os.path.join(BACKUP_ROOT, f"PreSlim_{ts}")
    os.makedirs(bdir, exist_ok=True)
    backup_path = os.path.join(bdir, "AddOns.txt")
    shutil.copy2(ADDONS_TXT, backup_path)
    print(f"已备份 AddOns.txt -> {backup_path}")

    raw = open(ADDONS_TXT, "rb").read()
    crlf = b"\r\n" in raw
    lines = raw.decode("utf-8", errors="replace").replace("\r\n", "\n").split("\n")

    seen = set()
    changed_disable = []
    changed_enable = []
    out_lines = []

    for line in lines:
        if ":" not in line:
            out_lines.append(line)
            continue
        name, state = line.split(":", 1)
        k = name.strip()
        s = state.strip().lower()
        seen.add(k)
        if k in TO_DISABLE:
            if s != "disabled":
                changed_disable.append(k)
            out_lines.append(f"{k}: disabled")
        elif k in TO_ENABLE:
            if s != "enabled":
                changed_enable.append(k)
            out_lines.append(f"{k}: enabled")
        else:
            out_lines.append(line)

    # 追加不在列表里但需明确标记的条目
    trailing_blank = len(out_lines) > 0 and out_lines[-1] == ""
    if trailing_blank:
        out_lines.pop()
    for k in sorted(TO_DISABLE):
        if k not in seen:
            out_lines.append(f"{k}: disabled")
            changed_disable.append(k)
    for k in sorted(TO_ENABLE):
        if k not in seen:
            out_lines.append(f"{k}: enabled")
            changed_enable.append(k)
    if trailing_blank:
        out_lines.append("")

    content = ("\r\n" if crlf else "\n").join(out_lines)
    open(ADDONS_TXT, "wb").write(content.encode("utf-8"))

    enabled_cnt = sum(1 for ln in out_lines if ln.strip().lower().endswith(": enabled"))
    disabled_cnt = sum(1 for ln in out_lines if ln.strip().lower().endswith(": disabled"))
    print(f"瘦身完成：新停用 {len(changed_disable)} 个插件，保留启用 {enabled_cnt} 个，已停用 {disabled_cnt} 个。")
    if changed_disable:
        print("本次停用清单：" + ", ".join(changed_disable))

    # 同步清理 SavedVariables\KkowoUI.lua 中旧版解锁模式写入的错位坐标与空服务器小号键
    if os.path.exists(KKOWOUI_SV):
        sv_backup = os.path.join(bdir, "KkowoUI.lua")
        shutil.copy2(KKOWOUI_SV, sv_backup)
        print(f"已备份 KkowoUI.lua -> {sv_backup}")
        sv_raw = open(KKOWOUI_SV, "rb").read()
        sv_crlf = b"\r\n" in sv_raw
        sv_text = sv_raw.decode("utf-8", errors="replace").replace("\r\n", "\n")

        removed_pos = []
        def _drop_corrupt_pos(m):
            key = m.group(1)
            body = m.group(2)
            if '["point"] = "FUI_' in body:
                removed_pos.append(key)
                return ""
            return m.group(0)

        sv_new = re.sub(
            r'\["([A-Za-z0-9_]+)"\] = \{\n([^{}]*?)\n\},\n',
            _drop_corrupt_pos,
            sv_text,
        )
        # 清理登录过早记录下的 [""] 空服务器键
        sv_new2, empty_realm_n = re.subn(
            r'\["alts"\] = \{\n\[""\] = \{\n(?:[^{}]*\{[^{}]*\},?\n)*\},\n\},',
            '["alts"] = {\n},',
            sv_new,
        )
        if removed_pos or empty_realm_n:
            final_sv = sv_new2.replace("\n", "\r\n") if sv_crlf else sv_new2
            open(KKOWOUI_SV, "wb").write(final_sv.encode("utf-8"))
            print(f"已清理 KkowoUI.lua 损坏坐标：{removed_pos}，空服务器键：{empty_realm_n} 处。")
        else:
            print("KkowoUI.lua 无需清理，数据已洁净。")


if __name__ == "__main__":
    main()
