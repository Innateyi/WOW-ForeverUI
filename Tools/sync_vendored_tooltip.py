# -*- coding: utf-8 -*-
r"""
kkowoUI — MIT 合规 PrettyTooltip 同步器（生成 Addon\kkowoUI_Tooltip）
上游仓库：https://github.com/FallenShard/PrettyTooltip (MIT License)

用法：
  python -I Tools/sync_vendored_tooltip.py                   # 从当前游戏目录 AddOns\PrettyTooltip 同步
  python -I Tools/sync_vendored_tooltip.py --src <路径或zip>  # 从指定解压目录或 GitHub Release zip 同步

设计原则：
  1. 完整保留上游 MIT LICENSE（原样复制至根目录与 Vendor/）并生成 ATTRIBUTION.md 注明来源、版本与改动清单；
  2. 跳过与无限服（16001/camelot）无关的 Retail/ 目录，保持极简纯净；
  3. 仅在 Vendor/ 中做 5 处可自动复现的极小适配（4 处贴图路径改为动态 ns._artPath + 1 处防双开让位守卫）；
  4. Bridge\Compat.lua 负责检测独立版 PrettyTooltip 防双钩冲突，SavedVariables 沿用 PrettyTooltipDB 零迁移损耗。
"""
import argparse
import os
import re
import shutil
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_SRC = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'PrettyTooltip')
DST_ROOT = os.path.join(ROOT, 'Addon', 'kkowoUI_Tooltip')

SKIP_DIRS = {'Retail', '.git', '.github', '__pycache__'}
SKIP_FILES = {'addon_strategy.txt', 'dd_author.toc'}

COMPAT_LUA = '''----------------------------------------------------------------------
--  kkowoUI_Tooltip — Bridge/Compat.lua
--  MIT 合规内嵌 PrettyTooltip 引擎桥接层：
--    1) 动态计算本插件目录的 Vendor\\art\\ 贴图路径，兼容改名与打包
--    2) 若玩家目录里仍误开独立版 PrettyTooltip，自动让位避免双重 Hook
----------------------------------------------------------------------
local addonName, ns = ...
local _G = _G

ns._addonName = addonName
ns._artPath = "Interface\\\\AddOns\\\\" .. addonName .. "\\\\Vendor\\\\art\\\\"

local function IsStandaloneLoaded()
    local fn = (_G.C_AddOns and _G.C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(fn) ~= "function" then
        return false
    end
    local ok, loaded = pcall(fn, "PrettyTooltip")
    return ok and loaded == true
end

if IsStandaloneLoaded() then
    ns._yielded = true
end
'''

ART_PATCHES = [
    (
        'Data/Stats.lua',
        'stats.MARKER = "|TInterface\\\\AddOns\\\\PrettyTooltip\\\\art\\\\stat-marker:9:9:0:-2|t"',
        'stats.MARKER = "|T" .. (ns._artPath or "Interface\\\\AddOns\\\\kkowoUI_Tooltip\\\\Vendor\\\\art\\\\") .. "stat-marker:9:9:0:-2|t"',
    ),
    (
        'Panel/Layout.lua',
        'local ART = "Interface\\\\AddOns\\\\PrettyTooltip\\\\art\\\\"',
        'local ART = ns._artPath or "Interface\\\\AddOns\\\\kkowoUI_Tooltip\\\\Vendor\\\\art\\\\"',
    ),
    (
        'Tooltips/Item.lua',
        'local ART = "Interface\\\\AddOns\\\\PrettyTooltip\\\\art\\\\"',
        'local ART = ns._artPath or "Interface\\\\AddOns\\\\kkowoUI_Tooltip\\\\Vendor\\\\art\\\\"',
    ),
    (
        'Tooltips/Unit.lua',
        'local ART = "Interface\\\\AddOns\\\\PrettyTooltip\\\\art\\\\"',
        'local ART = ns._artPath or "Interface\\\\AddOns\\\\kkowoUI_Tooltip\\\\Vendor\\\\art\\\\"',
    ),
    (
        'PrettyTooltip.lua',
        'function ns.start()\n    if started then return end',
        'function ns.start()\n    if ns._yielded or started then return end',
    ),
    (
        'Panel/Layout.lua',
        '    font:SetText(content)\n    font:Show()\n    return math.max(size + 2, font:GetStringHeight() or 0)\nend',
        '    font:SetText(content)\n    font:Show()\n    local numLines = font.GetNumLines and font:GetNumLines() or 1\n    return math.max(size + 2, numLines * (size + 3), font:GetStringHeight() or 0)\nend',
    ),
    (
        'Panel/Layout.lua',
        '''    local width = textWidth(font, text)
    if texturesCounted then return width end
    local _, textures = text:gsub("|T", "")
    return width + textures * (size + 2)
end

local function measureStyled(panel, text, style)
    if style.caps then text = capitalize(text) end
    return measure(panel, text, style.size, style.font, style.flags)
end

local function rowWidth(panel, row, style)
    if row.blank then return 0 end
    style = asStyle(style, panel)
    local width = measureStyled(panel, row.left, style)
    if row.right and row.right ~= "" then
        -- The 2 matches the slack drawRow gives the right column.
        return width + COLUMN_GAP + measureStyled(panel, row.right, style) + 2
    end
    return width
end

local function headerInsets(indent, panel)
    if ns.option("iconRight", panel and panel.tooltipType) then return 0, indent end
    return indent, 0
end

local function drawRow(panel, row, y, style, color, indent, gap, rightIndent)
    style = asStyle(style, panel)
    local left = row.left
    local right = row.right
    local leftColor = row.color or color
    indent, gap, rightIndent = indent or 0, rowGap(gap or 3, panel), rightIndent or 0
    -- What the row leaves under its letters, its line's leading and the gap:
    -- a divider or rule after it counts this in (Panel/Render.lua).
    local lineHeight = math.floor(style.size * 1.15 + .5)
    panel.rowTail = lineHeight - style.size + gap
    -- A blank row, as another addon's between its sections: one empty line.
    if row.blank then return y + lineHeight + gap end
    local w = panel.width - 2 * pad(panel) - indent - rightIndent
    if right and right ~= "" then
        local rightWidth = math.min(measureStyled(panel, right, style) + 2,
            math.max(w * .5, w - measureStyled(panel, left, style) - COLUMN_GAP))
        local leftHeight = styledAt(panel, left, pad(panel) + indent, y,
            w - rightWidth - COLUMN_GAP, style, leftColor)
        local rightHeight = styledAt(panel, right, panel.width - pad(panel) - rightIndent - rightWidth, y,
            rightWidth, style, row.rightColor or leftColor, "RIGHT")
        return y + math.max(leftHeight, rightHeight) + gap
    end
    return y + styledAt(panel, left, pad(panel) + indent, y, w, style, leftColor) + gap
end''',
        '''    local width = textWidth(font, text)
    if texturesCounted then
        if text:find("|T", 1, true) then return width + 4 end
        return width
    end
    local _, textures = text:gsub("|T", "")
    return width + textures * (size + 2)
end

local function measureStyled(panel, text, style)
    if style.caps then text = capitalize(text) end
    return measure(panel, text, style.size, style.font, style.flags)
end

local function rowWidth(panel, row, style)
    if row.blank then return 0 end
    style = asStyle(style, panel)
    local width = measureStyled(panel, row.left, style)
    if row.right and row.right ~= "" then
        -- Left & right columns each keep 4px slack so CJK + inline |T| icons never wrap the last character.
        return width + 4 + COLUMN_GAP + measureStyled(panel, row.right, style) + 4
    end
    return width + 2
end

local function headerInsets(indent, panel)
    if ns.option("iconRight", panel and panel.tooltipType) then return 0, indent end
    return indent, 0
end

local function drawRow(panel, row, y, style, color, indent, gap, rightIndent)
    style = asStyle(style, panel)
    local left = row.left
    local right = row.right
    local leftColor = row.color or color
    indent, gap, rightIndent = indent or 0, rowGap(gap or 3, panel), rightIndent or 0
    -- What the row leaves under its letters, its line's leading and the gap:
    -- a divider or rule after it counts this in (Panel/Render.lua).
    local lineHeight = math.floor(style.size * 1.15 + .5)
    panel.rowTail = lineHeight - style.size + gap
    -- A blank row, as another addon's between its sections: one empty line.
    if row.blank then return y + lineHeight + gap end
    local w = panel.width - 2 * pad(panel) - indent - rightIndent
    if right and right ~= "" then
        local leftNeed = measureStyled(panel, left, style) + 4
        local rightNeed = measureStyled(panel, right, style) + 4
        local avail = math.max(32, w - COLUMN_GAP)
        local rightWidth
        if leftNeed + rightNeed <= avail then
            rightWidth = rightNeed
        else
            rightWidth = math.min(rightNeed, math.max(avail * .5, avail - leftNeed))
        end
        local leftWidth = math.max(16, avail - rightWidth)
        local leftHeight = styledAt(panel, left, pad(panel) + indent, y,
            leftWidth, style, leftColor)
        local rightHeight = styledAt(panel, right, panel.width - pad(panel) - rightIndent - rightWidth, y,
            rightWidth, style, row.rightColor or leftColor, "RIGHT")
        return y + math.max(leftHeight, rightHeight) + gap
    end
    return y + styledAt(panel, left, pad(panel) + indent, y, w, style, leftColor) + gap
end''',
    ),
]


def extract_src(src_path):
    """返回 (src_dir, temp_dir_or_none)。支持目录或 zip 包。"""
    if os.path.isdir(src_path):
        return src_path, None
    if os.path.isfile(src_path) and src_path.lower().endswith('.zip'):
        tmp = tempfile.mkdtemp(prefix='kkowo_ptip_')
        with zipfile.ZipFile(src_path, 'r') as z:
            for member in z.infolist():
                norm = os.path.normpath(member.filename)
                if norm.startswith('..') or os.path.isabs(norm):
                    raise ValueError(f'不安全的 zip 路径: {member.filename}')
            z.extractall(tmp)
        cand = os.path.join(tmp, 'PrettyTooltip')
        if os.path.isdir(cand):
            return cand, tmp
        for ent in os.listdir(tmp):
            p = os.path.join(tmp, ent)
            if os.path.isdir(p) and os.path.isfile(os.path.join(p, 'PrettyTooltip.lua')):
                return p, tmp
        shutil.rmtree(tmp, ignore_errors=True)
        raise SystemExit(f'压缩包内找不到 PrettyTooltip 目录：{src_path}')
    raise SystemExit(f'找不到 PrettyTooltip 源路径：{src_path}')


def parse_camelot_toc(toc_path):
    raw = open(toc_path, encoding='utf-8').read().replace('\r\n', '\n')
    ver_m = re.search(r'^## Version:\s*(\S+)', raw, re.M)
    version = ver_m.group(1) if ver_m else '1.5.0'
    files = []
    for ln in raw.split('\n'):
        s = ln.strip()
        if not s or s.startswith('#'):
            continue
        files.append(s)
    return version, files


def build_toc(version, vendor_files):
    lines = [
        '## Interface: 16001',
        '## AllowLoadGameType: camelot',
        '## Title: |cffdca77fkkowoUI|r 悬浮提示引擎 (PrettyTooltip)',
        f'## Notes: kkowoUI 现代悬浮提示引擎（基于 MIT 开源协议整合 PrettyTooltip v{version}，保留完整原作者署名与 /ptip 样式编辑器）',
        '## Author: FallenShard (PrettyTooltip, MIT) & Mei (kkowoUI Integration)',
        f'## Version: {version}-kkowo',
        '## X-License: MIT',
        '## X-Upstream: https://github.com/FallenShard/PrettyTooltip',
        r'## IconTexture: Interface\AddOns\kkowoUI_Tooltip\Vendor\art\logo',
        '## SavedVariables: PrettyTooltipDB, PrettyTooltipCaptures',
        '## OptionalDeps: kkowoUI, Questie, Auctionator, DialogueUI, EllesmereUI, LibSharedMedia-3.0',
        '',
        r'Bridge\Compat.lua',
        '',
    ]
    for entry in vendor_files:
        lines.append('Vendor\\' + entry)
    lines.append('')
    lines.append(r'Bridge\TooltipStyle.lua')
    return '\r\n'.join(lines) + '\r\n'


def build_attribution(version):
    return f"""# Third-Party Attribution — kkowoUI_Tooltip

`kkowoUI_Tooltip` vendors **PrettyTooltip v{version}** (WoW Forever / Camelot edition) under the terms of the **MIT License**.

- **Upstream Project**: PrettyTooltip (`https://github.com/FallenShard/PrettyTooltip`)
- **Upstream Author**: Copyright (c) 2026 FallenShard
- **License**: MIT License (full text preserved verbatim in [LICENSE](LICENSE) and [Vendor/LICENSE](Vendor/LICENSE))

## Minimal Integration Adaptations
To avoid addon folder conflicts with NetEase DD while keeping upstream updates easy to merge, only 5 lines in `Vendor/` are adapted by `Tools/sync_vendored_tooltip.py`:
1. `Vendor/Data/Stats.lua`, `Vendor/Panel/Layout.lua`, `Vendor/Tooltips/Item.lua`, `Vendor/Tooltips/Unit.lua`: resolve `art\\` via `ns._artPath` instead of a hardcoded `Interface\\AddOns\\PrettyTooltip\\art\\` path.
2. `Vendor/PrettyTooltip.lua`: respect `ns._yielded` set by `Bridge/Compat.lua` if a standalone `PrettyTooltip` addon is also loaded.
3. Retail-only files under upstream `Retail/` are omitted (not loaded on WoW Forever `16001/camelot`).
"""


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='MIT 合规同步 PrettyTooltip 至 Addon/kkowoUI_Tooltip')
    ap.add_argument('--src', default=DEFAULT_SRC, help='PrettyTooltip 源码目录或 Release zip')
    args = ap.parse_args()

    src_dir, tmp_dir = extract_src(args.src)
    try:
        toc_path = os.path.join(src_dir, 'PrettyTooltip_Camelot.toc')
        if not os.path.isfile(toc_path):
            raise SystemExit(f'源目录缺少 PrettyTooltip_Camelot.toc：{src_dir}')
        lic_path = os.path.join(src_dir, 'LICENSE')
        if not os.path.isfile(lic_path):
            raise SystemExit(f'源目录缺少 LICENSE（MIT 合规必须保留）：{src_dir}')

        version, vendor_files = parse_camelot_toc(toc_path)

        # 保留既有的 Bridge/TooltipStyle.lua（如有），清理并重建 Vendor/
        saved_tooltip_style = None
        ts_path = os.path.join(DST_ROOT, 'Bridge', 'TooltipStyle.lua')
        if os.path.isfile(ts_path):
            saved_tooltip_style = open(ts_path, 'rb').read()
        if os.path.isdir(DST_ROOT):
            shutil.rmtree(DST_ROOT)
        vendor_dst = os.path.join(DST_ROOT, 'Vendor')
        bridge_dst = os.path.join(DST_ROOT, 'Bridge')
        os.makedirs(vendor_dst, exist_ok=True)
        os.makedirs(bridge_dst, exist_ok=True)
        if saved_tooltip_style is not None:
            open(os.path.join(bridge_dst, 'TooltipStyle.lua'), 'wb').write(saved_tooltip_style)

        # 复制除 Retail / *.toc / DD 元数据外的全部原版文件
        copied = 0
        for root_dp, dirs, files in os.walk(src_dir):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            rel_dir = os.path.relpath(root_dp, src_dir)
            out_dir = vendor_dst if rel_dir == '.' else os.path.join(vendor_dst, rel_dir)
            os.makedirs(out_dir, exist_ok=True)
            for fn in files:
                if fn in SKIP_FILES or fn.endswith('.toc'):
                    continue
                shutil.copy2(os.path.join(root_dp, fn), os.path.join(out_dir, fn))
                copied += 1

        # 根目录保留原版 MIT LICENSE 与 ATTRIBUTION.md
        shutil.copy2(lic_path, os.path.join(DST_ROOT, 'LICENSE'))
        open(os.path.join(DST_ROOT, 'ATTRIBUTION.md'), 'w', encoding='utf-8', newline='\n').write(build_attribution(version))
        open(os.path.join(bridge_dst, 'Compat.lua'), 'w', encoding='utf-8', newline='\n').write(COMPAT_LUA)
        open(os.path.join(DST_ROOT, 'kkowoUI_Tooltip.toc'), 'w', encoding='utf-8', newline='').write(build_toc(version, vendor_files))

        # 应用 5 处极小适配
        for rel, old, new in ART_PATCHES:
            p = os.path.join(vendor_dst, *rel.split('/'))
            raw = open(p, 'rb').read().decode('utf-8')
            crlf = '\r\n' in raw
            norm = raw.replace('\r\n', '\n')
            cnt = norm.count(old)
            if cnt != 1:
                raise SystemExit(f'适配锚点异常：{rel} 匹配数={cnt}')
            norm = norm.replace(old, new, 1)
            out = norm.replace('\n', '\r\n') if crlf else norm
            open(p, 'wb').write(out.encode('utf-8'))

        print(f'[OK] 已生成 MIT 合规 Addon/kkowoUI_Tooltip（上游 PrettyTooltip v{version}，{copied} 个原版文件 + Bridge/Compat.lua + LICENSE + ATTRIBUTION.md）')
        return 0
    finally:
        if tmp_dir:
            shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
