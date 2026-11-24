# -*- coding: utf-8 -*-
"""
补丁：EllesmereUINameplates 姓名板任务计数与名字防重叠 + 字号同步（v3：上方任务计数默认对齐名字字号）
支持 --check 只读检测。
"""
import os, re, shutil, sys

# 游戏目录与备份目录可用环境变量覆盖：WOW_FOREVER_DIR（含 Interface 的客户端根目录）/ WOW_BACKUP_ROOT
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'EllesmereUINameplates')
# 默认放在仓库同级的 backups 目录（绝不写进游戏目录）
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')))
MARK = '[fui-np-qtname v3]'
OLD_MARKS = ('[fui-np-qtname v2]', '[kkowo-qtname]')
FILE = 'EUI_Nameplates_Name.lua'

PATCHES = [
    (
        '''    if text then
        local size, font, outline = ns.NP_QuestTextSize(), ns.GetFont(), GetNPOutline()
''',
        '''    if text then
        -- [fui-np-qtname v3] 任务计数与怪物名字同处上方行且未单独指定字号时，自动对齐名字字号保持视觉一致
        local size = (p and p.questObjectiveTextSize)
            or ((slot == "top" or slot == "topleft" or slot == "topright") and GetTextSlotSize("textSlotTop"))
            or ns.NP_QuestTextSize()
        local font, outline = ns.GetFont(), GetNPOutline()
''',
    ),
    (
        '''    if OnNameRow(GetClassificationSlot()) then
        if self.classFrame:IsShown() then
            nameW = nameW - ((self.classFrame._npSz or GetRareEliteIconSize()) + 4)
        end
        local qi = self.questFrame
        if qi and qi:IsShown() then nameW = nameW - ((qi._npSz or GetRareEliteIconSize()) + 4) end
    end
    local qf = self.questTextFrame
    if qf and qf:IsShown() and OnNameRow(ns.NP_GetQuestTextSlot()) then
        nameW = nameW - ((qf._npW or 0) + 4)
    end
    -- Stacked behind an indicator ("Rare/Quest + Faction") it takes no extra width;
    -- alone it reserves its own.
    local stacked = p and p.classificationIncludeFaction and ns.NP_RideFrame(self)
    if self.factionFrame and self.factionFrame:IsShown() and not stacked
        and OnNameRow(ns.NP_GetFactionSlot()) then
        nameW = nameW - (ns.NP_GetFactionIconSize() + 4)
    end
    return nameW
end
''',
        '''    -- [fui-np-qtname v2] 统计左上/右上角元素占宽，将上方居中名字向空余侧平移一半，避免压字
    local leftRes, rightRes = 0, 0
    local rmPos = GetRaidMarkerPos()
    if OnNameRow(rmPos) and self.raidFrame and self.raidFrame:IsShown() then
        local w = GetRaidMarkerSize() + 2
        if rmPos == "topleft" then leftRes = leftRes + w elseif rmPos == "topright" then rightRes = rightRes + w end
    end
    local cs = GetClassificationSlot()
    if OnNameRow(cs) then
        local w = 0
        if self.classFrame:IsShown() then
            w = w + ((self.classFrame._npSz or GetRareEliteIconSize()) + 4)
        end
        local qi = self.questFrame
        if qi and qi:IsShown() then w = w + ((qi._npSz or GetRareEliteIconSize()) + 4) end
        nameW = nameW - w
        if cs == "topleft" then leftRes = leftRes + w elseif cs == "topright" then rightRes = rightRes + w end
    end
    local qf = self.questTextFrame
    local qs = ns.NP_GetQuestTextSlot()
    if qf and qf:IsShown() and OnNameRow(qs) then
        local w = (qf._npW or 0) + 4
        nameW = nameW - w
        if qs == "topleft" then leftRes = leftRes + w elseif qs == "topright" then rightRes = rightRes + w end
    end
    local stacked = p and p.classificationIncludeFaction and ns.NP_RideFrame(self)
    local fs = ns.NP_GetFactionSlot()
    if self.factionFrame and self.factionFrame:IsShown() and not stacked
        and OnNameRow(fs) then
        local w = ns.NP_GetFactionIconSize() + 4
        nameW = nameW - w
        if fs == "topleft" then leftRes = leftRes + w elseif fs == "topright" then rightRes = rightRes + w end
    end
    self._npNameShift = (leftRes - rightRes) / 2
    return nameW
end
-- [fui-np-qtname v2] 重锚上方名字槽位
local function FuiAnchorTopName(self)
    local txOff, tyOff = GetTextSlotOffsets("textSlotTop")
    local mr = self._nameRaidMarkerShown == true
        and (((p and p.nameRaidMarkerSize) or defaults.nameRaidMarkerSize or 14) + 3) or 0
    local shift = self._npNameShift or 0
    self.name:ClearAllPoints()
    PP.Point(self.name, "BOTTOM", self.health, "TOP", txOff + mr * 0.5 + shift,
        4 + GetNameYOffset() + GetClassPowerTopPush(self) + tyOff)
    self._npNameShiftAt = shift
    if ns.DebuffColors_NameChanged then ns.DebuffColors_NameChanged(self) end
end
''',
    ),
    (
        '''        local nameW = TopNameWidth(self, barW) - nameMarkerReserve
        PP.Width(self.name, math.max(nameW * pct / 100, 20))
''',
        '''        local nameW = TopNameWidth(self, barW) - nameMarkerReserve
        PP.Width(self.name, math.max(nameW * pct / 100, 20))
        if (self._npNameShift or 0) ~= (self._npNameShiftAt or 0) then FuiAnchorTopName(self) end -- [fui-np-qtname v2]
''',
    ),
    (
        '''        PP.Point(self.name, "BOTTOM", self.health, "TOP", txOff + (nameMarkerReserve * 0.5), 4 + nameYOff + cpPush + tyOff)
''',
        '''        PP.Point(self.name, "BOTTOM", self.health, "TOP", txOff + (nameMarkerReserve * 0.5) + (self._npNameShift or 0), 4 + nameYOff + cpPush + tyOff)
        self._npNameShiftAt = self._npNameShift or 0 -- [fui-np-qtname v2]
''',
    ),
]


def get_version(root):
    for n in os.listdir(root):
        if n.endswith('.toc'):
            m = re.search(r'^## Version:\s*(\S+)', open(os.path.join(root, n), encoding='utf-8', errors='replace').read(), re.M)
            if m:
                return m.group(1)
    return 'unknown'


def read_text(path):
    raw = open(path, 'rb').read().decode('utf-8')
    return raw.replace('\r\n', '\n'), '\r\n' in raw


def run(addon_dir=DEFAULT_DIR, check_only=False):
    if not os.path.isdir(addon_dir):
        return ('MISSING', f'未找到目录: {addon_dir}')
    ver = get_version(addon_dir)
    bdir = os.path.join(BACKUP_ROOT, f'EllesmereUINameplates_{ver}_原版')
    path = os.path.join(addon_dir, FILE)
    text, crlf = read_text(path)
    if MARK in text:
        return ('APPLIED', f'已应用 {MARK} (v{ver})')
    if any(m in text for m in OLD_MARKS):
        src = os.path.join(bdir, FILE)
        if os.path.exists(src):
            text, crlf = read_text(src)
            hunks = PATCHES
        elif text.count(PATCHES[0][0]) == 1:
            # 旧版 [kkowo-qtname] / v2 已防重叠，仅增量补打 v3 任务计数与名字字号同步块
            hunks = [PATCHES[0]]
        else:
            return ('APPLIED_LEGACY', f'已含旧版补丁 (v{ver})；下次 EUI 更新后将自动套用新版 {MARK}')
    else:
        hunks = PATCHES
    for old, new in hunks:
        if text.count(old) != 1:
            return ('ANCHOR_MISMATCH', f'{FILE} 锚点匹配数={text.count(old)}（EUI 可能已更新）')
        text = text.replace(old, new)
    if check_only:
        return ('READY', f'可安全应用 {MARK} (v{ver})')
    os.makedirs(bdir, exist_ok=True)
    dst = os.path.join(bdir, FILE)
    cur, _ = read_text(path)
    if not os.path.exists(dst) and MARK not in cur and not any(m in cur for m in OLD_MARKS):
        shutil.copy2(path, dst)
    out = text.replace('\n', '\r\n') if crlf else text
    open(path, 'wb').write(out.encode('utf-8'))
    return ('PATCHED', f'已成功打补丁 {MARK} (v{ver})')


if __name__ == '__main__':
    chk = '--check' in sys.argv
    args = [a for a in sys.argv[1:] if a != '--check']
    status, msg = run(args[0] if args else DEFAULT_DIR, check_only=chk)
    print(f'[eui_np_questtext_name] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED') else 1)
