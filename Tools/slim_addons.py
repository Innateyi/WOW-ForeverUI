# -*- coding: utf-8 -*-
r"""
kkowoUI — 安全插件瘦身与 6 合 1 切换脚本
功能：
  1. 检测 WoW 客户端是否在运行（若运行中默认中止，防止退出游戏时覆盖 AddOns.txt）
  2. 自动备份 AddOns.txt 到 D:\code\wow\backups\PreSlim_<timestamp>\
  3. 停用已合并进 kkowoUI 的 7 个插件 + 17 个确认闲置/重叠/重型子插件（共释放 ~36+ MB 常驻 Lua）
  4. 完整保留全部核心玩法与界面布局插件（EllesmereUI 核心含冷却管理器、Polestar、Questie、BigWigs、Auctionator、Leatrix_Maps、WaypointUI、VSS、DungeonsForever 主体等）
     ArcAuras 已由 EUI 冷却管理器替代（两者冲突），一并停用
用法：
  python D:\code\wow\kkowoUI\Tools\slim_addons.py
"""
import datetime
import importlib.util
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDONS_TXT = os.environ.get("WOW_ADDONS_TXT", r"E:\Program Files\World of Warcraft\_forever_\WTF\Account\<YourAccountID>\<Realm>\<CharName>\AddOns.txt")
KKOWOUI_SV = os.environ.get("WOW_KKOWOUI_SV", r"E:\Program Files\World of Warcraft\_forever_\WTF\Account\<YourAccountID>\SavedVariables\kkowoUI.lua")
BACKUP_ROOT = os.environ.get(
    "WOW_BACKUP_ROOT",
    os.path.normpath(os.path.join(HERE, "..", "..", "backups")),
)

# 已合并进 kkowoUI 或被原生接管的旧重叠插件
MERGED_INTO_KKOWOUI = [
    "QFXSystemBar",
    "QFXSystemBar_Config",
    "QFXSystemBar_InfoBar",
    "QFXSystemBar_Locale",
    "QFXSystemBar_MeetingStone",
    "EllesmereUIDataBars",
    "YaMedia",
    "BlizzMove",
    "Leatrix_Maps",
    "WaypointUI",
    "VamoosesSlipstream",
    "VamoosesSlipstream_kkowo",
    "PrettyTooltip",
]

# 确认闲置 / 正式服无用 / 调试 / 重叠重型插件
# 注意：DungeonsForever 的 8 个百科子库均为 LoadOnDemand 按需加载，不占启动内存，不再停用
IDLE_OR_REDUNDANT = [
    "TalentsForever",
    "ForeverFishing",
    "ArcAuras",
    "ArcAuras_Finds",
    "ArcAuras_LFG",
    "ArcUI",
    "EllesmereUIAuraBuffReminders",
    "EllesmereUIQuickdraw",
    "EllesmereUIMythicTimer",
    "EllesmereUIFriends",
    "EllesmereUIGroupFinder",
    "Polestar_Arcade",
    "GlowingBars",
    "MiniMarkers",
    "163UI_Info",
    "QuestieTrace",
    "BlizzMove_Debug",
]

TO_DISABLE = set(MERGED_INTO_KKOWOUI + IDLE_OR_REDUNDANT)
# 冷却显示改用 EUI 冷却管理器（替代 ArcAuras），启用全部 9 个 kkowoUI v2.0 套件目录
TO_ENABLE = {
    "kkowoUI", "kkowoUI_Media", "kkowoUI_CoreHUD", "kkowoUI_QoL",
    "kkowoUI_Tooltip", "kkowoUI_Integrations", "kkowoUI_ClassPack",
    "kkowoUI_Options", "kkowoUI_KeybindBoard",
    "EllesmereUICooldownManager",
}


def is_wow_running():
    try:
        res = subprocess.run(
            ["tasklist", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            encoding="mbcs",
            errors="replace",
            timeout=10,
        )
        if res.returncode != 0:
            return "UNKNOWN"
        for line in res.stdout.splitlines():
            low = line.lower()
            if '"wow' in low and '.exe"' in low:
                return line.split(",")[0].strip('"')
        return None
    except Exception:
        return "UNKNOWN"


def _verify_sv_parse(sv_text):
    spec = importlib.util.spec_from_file_location("prepare_share_wtf", os.path.join(HERE, "prepare_share_wtf.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    tops = mod.parse_sv(sv_text)
    if not tops:
        raise ValueError("解析后无顶层 SavedVariables")
    return tops


def main():
    force = "--force" in sys.argv
    proc = is_wow_running()
    if proc and not force:
        print(f"WOW_RUNNING: {proc}")
        print("检测到魔兽世界正在运行（或无法确认进程状态）。为防止游戏退出时覆盖 AddOns.txt，本次未修改文件。")
        print("请先完全退出游戏，再运行本脚本即可安全应用瘦身配置。")
        sys.exit(2)

    if any(ph in ADDONS_TXT for ph in ("<YourAccountID>", "<Realm>", "<CharName>")):
        sys.exit(f"WOW_ADDONS_TXT 仍是占位路径：{ADDONS_TXT}\n请先通过环境变量指定真实 AddOns.txt 路径。")
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

    to_disable = set(TO_DISABLE)

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
        if k in to_disable:
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
    for k in sorted(to_disable):
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

    # 同步清理 SavedVariables\kkowoUI.lua 中旧版解锁模式写入的错位坐标与空服务器小号键
    if os.path.exists(KKOWOUI_SV):
        sv_backup = os.path.join(bdir, "kkowoUI.lua")
        shutil.copy2(KKOWOUI_SV, sv_backup)
        print(f"已备份 kkowoUI.lua -> {sv_backup}")
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
            try:
                _verify_sv_parse(sv_new2)
            except Exception as exc:
                print(f"[WARN] kkowoUI.lua 清理结果未通过 Lua 语法校验（{exc}），已放弃写回并保持原文件不动。")
                return
            final_sv = sv_new2.replace("\n", "\r\n") if sv_crlf else sv_new2
            open(KKOWOUI_SV, "wb").write(final_sv.encode("utf-8"))
            print(f"已清理 kkowoUI.lua 损坏坐标：{removed_pos}，空服务器键：{empty_realm_n} 处。")
        else:
            print("kkowoUI.lua 无需清理，数据已洁净。")


if __name__ == "__main__":
    main()
