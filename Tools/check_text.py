# -*- coding: utf-8 -*-
"""
kkowoUI UI 文案规范自动检查器（对应验收标准 #6）
检查项：
  1. 选项名（text / title / buttonText）去色码与单位后 <= 8 个字（不含 StaticPopup 对话框正文与例外项）
  2. 悬停说明（tooltip / desc / disabledTooltip）<= 38 字且为单句（无换行）
  3. 禁用宣传词与实现细节词
  4. StaticPopupDialogs 弹窗正文 <= 3 行且不含禁用词
  5. F.Print 聊天输出单行且不含表情符号与禁用词
用法：
  python Tools/check_text.py           # 输出汇总与违规明细
  python Tools/check_text.py --strict  # 违规时以非零退出码返回
"""
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ADDON_BASE = HERE.parent / 'Addon'

HYPE_WORDS = [
    '100%', '零污染', '零延迟', '零补丁', '零误差', '零偏移',
    '彻底', '完美', '全方位', '黑曜石', '烟熏', '丝滑', '极速',
    '超高清', '炫光', '无损', '呼吸',
]
TECH_WORDS = [
    'CVar', 'Hook', '钩子', '补丁', 'LoD', 'LoadOnDemand', 'API',
    'SMF', 'SDF', 'BLP', 'SuperTrack', 'Shifter', 'InGameNavigation',
    'MapReveal', 'MapTravel', 'MapFade', 'PatchGuard', 'DeadGuard',
    'SavedVariables', 'hash_SlashCmdList', 'C_GossipInfo',
]

# 例外文件：纯诊断与采集命令工具（不向普通用户设置页暴露）
EXEMPT_FILES = {
    'kkowoUI_Options/Diagnostics.lua',
    'kkowoUI_Options/HarvestTargets.lua',
}

# 显式记录的 UI 弹窗/动态标签例外（对应验收标准 #6 例外项清单）：
#   • Options.lua StaticPopupDialogs["KKOWOUI_SLIM_CONFIRM"]：弹窗正文按 <= 3 行检查，不按 8 字选项名检查
#   • ControlHubUI.lua 瘦身明细 label：可展开只读名单，由展开按钮控制，不计入 8 字选项名
STATIC_POPUP_LINES = {
    ('kkowoUI_Options/Options.lua', 'KKOWOUI_SLIM_CONFIRM'),
}

STR_FIELD_RE = re.compile(r'\b(title|desc|text|tooltip|disabledTooltip|buttonText)\s*=\s*"((?:[^"\\]|\\.)*)"')
FPRINT_RE = re.compile(r'\bF\.Print(?:Once)?\s*\(\s*(?:"[^"]*"\s*,\s*)?"((?:[^"\\]|\\.)*)"')
UNIT_SUFFIX_RE = re.compile(r'[\(（]\s*(?:px|%|秒|分钟|倍|码|/\w+(?:\s+\w+)?)\s*[\)）]$')
EMOJI_RE = re.compile(r'[\U0001F300-\U0001FAFF\u2600-\u27BF]')


def strip_colors(s):
    s = re.sub(r'\|c[0-9a-fA-F]{8}', '', s)
    s = s.replace('|r', '').replace('\\n', '\n')
    return s.strip()


def effective_label_len(s):
    c = strip_colors(s)
    c = UNIT_SUFFIX_RE.sub('', c).strip()
    return len(c)


def scan():
    issues = []
    total_checked = 0
    for pkg in sorted(ADDON_BASE.iterdir()):
        if not (pkg.is_dir() and pkg.name.startswith('kkowoUI')):
            continue
        for f in sorted(pkg.rglob('*.lua')):
            if 'Vendor' in f.parts or 'Data' in f.parts:
                continue
            rel = str(f.relative_to(ADDON_BASE)).replace('\\', '/')
            if rel in EXEMPT_FILES:
                continue
            lines = f.read_text(encoding='utf-8', errors='replace').splitlines()
            in_popup = False
            for i, ln in enumerate(lines, 1):
                stripped = ln.strip()
                if stripped.startswith('--'):
                    continue
                if 'StaticPopupDialogs[' in ln:
                    in_popup = True
                if in_popup and stripped == '}':
                    in_popup = False
                for m in STR_FIELD_RE.finditer(ln):
                    kind, raw = m.group(1), m.group(2)
                    total_checked += 1
                    clean = strip_colors(raw)
                    errs = []
                    if in_popup and kind == 'text':
                        popup_lines = [x for x in clean.split('\n') if x.strip()]
                        if len(popup_lines) > 3:
                            errs.append(f'弹窗超3行({len(popup_lines)})')
                    elif kind in ('text', 'title', 'buttonText'):
                        elen = effective_label_len(raw)
                        if elen > 8:
                            errs.append(f'选项名超长({elen}>8)')
                    elif kind in ('tooltip', 'desc', 'disabledTooltip'):
                        if len(clean) > 38:
                            errs.append(f'说明超长({len(clean)}>38)')
                        if '\n' in clean:
                            errs.append('说明含换行')
                    for w in HYPE_WORDS:
                        if w in clean:
                            errs.append(f'宣传词:{w}')
                    for w in TECH_WORDS:
                        if w in clean:
                            errs.append(f'实现词:{w}')
                    if errs:
                        issues.append((rel, i, kind, ', '.join(errs), clean[:60]))
                for pm in FPRINT_RE.finditer(ln):
                    raw = pm.group(1)
                    total_checked += 1
                    clean = strip_colors(raw)
                    errs = []
                    if '\n' in clean:
                        errs.append('聊天输出含换行')
                    if EMOJI_RE.search(clean):
                        errs.append('聊天输出含表情')
                    for w in HYPE_WORDS:
                        if w in clean:
                            errs.append(f'聊天宣传词:{w}')
                    for w in TECH_WORDS:
                        if w in clean:
                            errs.append(f'聊天实现词:{w}')
                    if errs:
                        issues.append((rel, i, 'F.Print', ', '.join(errs), clean[:60]))
    return total_checked, issues


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    strict = '--strict' in sys.argv
    total, issues = scan()
    print(f'文案检查完成：共扫描 {total} 条 UI/聊天文字，违规 {len(issues)} 条')
    for rel, line, kind, reason, txt in issues[:40]:
        print(f'  [{rel}:{line}] ({kind}) {reason} -> "{txt}"')
    if len(issues) > 40:
        print(f'  ... 另有 {len(issues) - 40} 条未展开')
    return 1 if (strict and issues) else 0


if __name__ == '__main__':
    sys.exit(main())
