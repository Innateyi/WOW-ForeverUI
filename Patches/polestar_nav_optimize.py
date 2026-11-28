# -*- coding: utf-8 -*-
"""
补丁：Polestar 导航重算提速 + 减少山路切弯 + 任务怪就近选点防赶人（v2，极简 3 文件版）
修改文件（全部自动备份到 backups\\Polestar_<版本>_原版\\）：
  1. Nav/Walk.lua   ：缩短偏离重算冷却（10s→2.5s / 2s→1s）、缩小 STRAY（25→18）、
                      偏离超过 32 码时无视 fstate.sighted 强制重算，走上正确道路立即贴合
  2. Nav/Follow.lua ：收紧山路过度拉直与切弯（SMOOTH_SPAN 150→65, SIGHT_AHEAD 150→75,
                      OPEN 100→45, PAD 20→12, CORNER_PAD 10→6）
  3. Core/Engine.lua：优化任务怪 Spots 选点（DWELL 7→20s, FORGET 300→90s, ABOVE 1→3, SWITCH 40→25），
                      普通刷怪营地不再因 workedNear 被拉黑，身处备选怪区（alt）时允许就近锁定，
                      并支持 kkowoUI 实时视野任务怪回调禁止 Own.dwelt 赶人
注：原 v1 中的 UI/DungeonToast.lua（350 行进入副本所在地图提醒）已整体迁入
    kkowoUI/Modules/PolestarNavPlus.lua 零补丁驱动，不再修改 DungeonToast.lua。
支持 --check 只读检测（apply_patches.py 统一调用 run(check_only=...)）。
"""
import os
import re
import shutil
import sys

WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'Polestar')
BACKUP_ROOT = os.environ.get(
    'WOW_BACKUP_ROOT',
    os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')),
)
MARK = '[kkowo-polestar-nav v2]'
OLD_MARKS = ('[kkowo-polestar-nav v1]',)

FILE_PATCHES = [
    (
        'Polestar.toc',
        [
            (
                '## Title: Polestar\n',
                '# [kkowo-polestar-nav v2]\n## Title: Polestar by kkowo\n',
            ),
            (
                '## Title-zhCN: Polestar\n',
                '## Title-zhCN: Polestar by kkowo\n',
            ),
            (
                '## Title-zhTW: Polestar\n',
                '## Title-zhTW: Polestar by kkowo\n',
            ),
        ],
    ),
    (
        'Nav/Walk.lua',
        [
            (
                '''local STRAY = 25            -- yards off the path: ask again
local JOIN = 50             -- yards from a path's start: its first turn there, outdoors, is joining a road (Nav/Follow.lua)
local ASK_EVERY = 2         -- seconds between asks for the same goal
local ASK_FAR, ASK_FAR_EVERY = 2000, 10 -- yards left along the path past which a stray is asked again at most this often
local GOAL_MOVED = 1        -- yards: the goal is another one
local FAIL_RETRY, FAIL_MOVED, FAIL_AGAIN = 15, 5, 2 -- a failed search is asked again this late, this far away; a refusal for no policy reason once this soon''',
                '''local STRAY = 18            -- [kkowo-polestar-nav v2] yards off the path: ask again (原 25)
local JOIN = 30             -- [kkowo-polestar-nav v2] yards from a path's start (原 50，避免斜穿山坡)
local ASK_EVERY = 1.0       -- [kkowo-polestar-nav v2] seconds between asks for the same goal (原 2)
local ASK_FAR, ASK_FAR_EVERY = 2000, 2.5 -- [kkowo-polestar-nav v2] 长路偏离后最快 2.5s 重算（原 10s）
local GOAL_MOVED = 1        -- yards: the goal is another one
local FAIL_RETRY, FAIL_MOVED, FAIL_AGAIN = 4, 4, 1.5 -- [kkowo-polestar-nav v2] 寻路失败后更快重试（原 15, 5, 2）''',
            ),
            (
                '''\tlocal every = lastLeft > ASK_FAR and ASK_FAR_EVERY or ASK_EVERY
\tif fstate.off > STRAY and not fstate.sighted and token == nil and not wanted and GetTime() - askedAt >= every then ask(P, pc, px, py) end
\treturn pc, ax, ay, lastLeft''',
                '''\tlocal every = lastLeft > ASK_FAR and ASK_FAR_EVERY or ASK_EVERY
\t-- [kkowo-polestar-nav v1] 偏离超过 32 码时无视 fstate.sighted 强制重算，走上正确山路后立刻贴合新路线
\tif (fstate.off > 32 or (fstate.off > STRAY and not fstate.sighted)) and token == nil and not wanted and GetTime() - askedAt >= every then ask(P, pc, px, py) end
\treturn pc, ax, ay, lastLeft''',
            ),
        ],
    ),
    (
        'Nav/Follow.lua',
        [
            (
                '''local PAD = 20         -- yards: path points this close to the line to the aim lie on the way (a road's wiggles)
local CORNER_PAD = 10  -- yards: how far the aim may cut inside a real corner''',
                '''local PAD = 12         -- [kkowo-polestar-nav v2] 收紧道路走廊容差（原 20），减少山路切弯
local CORNER_PAD = 6   -- [kkowo-polestar-nav v2] 减少拐角内切（原 10）''',
            ),
            (
                '''local OPEN = 100       -- yards beside the path the player may run with the arrow aiming ahead by sight (open ground)
local SIGHT_AHEAD = 150 -- yards along the path past the projection the sight aim may lie''',
                '''local OPEN = 45        -- [kkowo-polestar-nav v1] 缩小允许离路直瞄的范围（原 100），避免走上另一条路不重算
local SIGHT_AHEAD = 75 -- [kkowo-polestar-nav v1] 缩短直线前瞻距离（原 150），贴合弯道与山路''',
            ),
            (
                '''local LOOK_AHEAD = 40  -- yards along the path the aim may lie ahead on it, at a point the player can walk to straight (open ground)
local SMOOTH_SPAN = 150 -- yards: the longest straightened line''',
                '''local LOOK_AHEAD = 32  -- [kkowo-polestar-nav v1] 路上直线前瞻（原 40）
local SMOOTH_SPAN = 65 -- [kkowo-polestar-nav v1] 限制路径拉直跨度（原 150），保留山路与盘山拐弯''',
            ),
        ],
    ),
    (
        'Core/Engine.lua',
        [
            (
                '''local Spots = {
\tSWITCH = 40, -- yards
\tLEAVE = 4, -- yards past the arrival radius
\tFORGET = 300, -- seconds a visited spot is skipped
\tABOVE = 1, -- levels above the player a spot's mobs may be
\tDWELL = 7, -- seconds in a place with no progress before the arrow moves on
\tSTILL = 10, -- yards the player may move while a dwell is counted''',
                '''ns._kkowoNavOpt = true -- [kkowo-polestar-nav v2]
local Spots = {
\tSWITCH = 25, -- [kkowo-polestar-nav v2] yards (原 40，更灵敏切换就近怪区)
\tLEAVE = 4, -- yards past the arrival radius
\tFORGET = 90, -- [kkowo-polestar-nav v2] seconds (原 300，缩短拉黑时长)
\tABOVE = 3, -- [kkowo-polestar-nav v2] levels (原 1，避免怪高 2 级就跳过脚下怪区)
\tDWELL = 20, -- [kkowo-polestar-nav v2] seconds (原 7，避免喝水/找怪/等刷新 7 秒被踢去别区)
\tSTILL = 10, -- yards the player may move while a dwell is counted''',
            ),
            (
                '''\tlocal function fresh(s)
\t\tif Spots.isLeft(goal, s, now) then return false end
\t\t-- Ground worked lately (a camp cleared) counts as visited unless the
\t\t-- player is on it, where it holds; moving on after a dwell, always.
\t\tif not exact and Own.workedNear(goal, s, now) then
\t\t\tlocal d = not moveOn and c and Spots.edge(goal, s, c, px, py)
\t\t\tif not (d and d <= reach + Spots.SWITCH) then return false end
\t\tend
\t\tlocal t = (spread or moveOn) and Spots.seen[s]
\t\tif not t or now - t > Spots.FORGET then return true end
\t\tif moveOn or not c or exact then return false end
\t\tlocal d = Spots.edge(goal, s, c, px, py)
\t\treturn d ~= nil and d <= reach
\tend
\t-- Nearest fresh spot (unknown distances rank after known ones, in order
\t-- from the current spot); with none fresh, the one visited longest ago.
\tlocal at = 0
\tfor i, s in ipairs(spots) do
\t\tif s == cur then at = i end
\tend
\tlocal best, bestKey, old, oldT
\tfor i, s in ipairs(spots) do
\t\tif not (moveOn and s == cur) and (manual or not s.alt) and not (cap and (s.lvl or lvl or 0) > cap) then''',
                '''\tlocal function fresh(s)
\t\tif Spots.isLeft(goal, s, now) then return false end
\t\t-- [kkowo-polestar-nav v1] 仅对 spread 巡逻搜索点按 workedNear 跳过；普通刷怪营地刚打过怪说明此地有怪，不拉黑
\t\tif spread and not exact and Own.workedNear(goal, s, now) then
\t\t\tlocal d = not moveOn and c and Spots.edge(goal, s, c, px, py)
\t\t\tif not (d and d <= reach + Spots.SWITCH) then return false end
\t\tend
\t\tlocal t = (spread or moveOn) and Spots.seen[s]
\t\tif not t or now - t > Spots.FORGET then return true end
\t\tif moveOn or not c or exact then return false end
\t\tlocal d = Spots.edge(goal, s, c, px, py)
\t\treturn d ~= nil and d <= reach
\tend
\t-- Nearest fresh spot (unknown distances rank after known ones, in order
\t-- from the current spot); with none fresh, the one visited longest ago.
\tlocal at = 0
\tfor i, s in ipairs(spots) do
\t\tif s == cur then at = i end
\tend
\tlocal best, bestKey, old, oldT
\tfor i, s in ipairs(spots) do
\t\t-- [kkowo-polestar-nav v1] 玩家正位于或紧邻备选怪区（alt，<= 48 码）时纳入自动候选，不再硬拖去远处主点
\t\tlocal altNear = s.alt and not moveOn and c and (Spots.edge(goal, s, c, px, py) or 1e9) <= reach + 40
\t\tif not (moveOn and s == cur) and (manual or not s.alt or altNear) and not (cap and (s.lvl or lvl or 0) > cap) then''',
            ),
            (
                '''\tif Own.workedNear(goal, place, now) then return false end
\tif now - st.since < Spots.DWELL then return false end
\tSpots.left[place], Spots.seen[place] = now, now''',
                '''\tif Own.workedNear(goal, place, now) then return false end
\t-- [kkowo-polestar-nav v1] 周围视野/目标存在存活任务怪时重置停留计时，绝不把玩家从怪堆里赶走
\tif type(_G.kkowoUI_PolestarHasNearbyQuestMob) == "function" then
\t\tlocal okNear, hasMob = pcall(_G.kkowoUI_PolestarHasNearbyQuestMob, goal)
\t\tif okNear and hasMob then
\t\t\tst.since, st.x, st.y = now, px, py
\t\t\treturn false
\t\tend
\tend
\tif now - st.since < Spots.DWELL then return false end
\tSpots.left[place], Spots.seen[place] = now, now''',
            ),
        ],
    ),
]


def get_version(root):
    for n in os.listdir(root):
        if n.endswith('.toc'):
            m = re.search(
                r'^## Version:\s*(\S+)',
                open(os.path.join(root, n), encoding='utf-8', errors='replace').read(),
                re.M,
            )
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
    bdir = os.path.join(BACKUP_ROOT, f'Polestar_{ver}_原版')

    pending_writes = []
    already = 0
    for rel, hunks in FILE_PATCHES:
        path = os.path.join(addon_dir, *rel.split('/'))
        if not os.path.exists(path):
            return ('MISSING', f'缺少文件: {rel} (v{ver})')
        text, crlf = read_text(path)
        if MARK in text:
            already += 1
            continue
        if any(m in text for m in OLD_MARKS):
            src = os.path.join(bdir, *rel.split('/'))
            if os.path.exists(src):
                text, crlf = read_text(src)
            else:
                return ('APPLIED_LEGACY', f'{rel} 已含旧版补丁 (v{ver})；下次 Polestar 更新后自动应用新版 {MARK}')
        for idx, (old, new) in enumerate(hunks, 1):
            cnt = text.count(old)
            if cnt != 1:
                return ('ANCHOR_MISMATCH', f'{rel} 第 {idx} 段锚点匹配数={cnt}（Polestar 可能已更新）')
            text = text.replace(old, new)
        pending_writes.append((rel, path, text, crlf))

    if not pending_writes:
        return ('APPLIED', f'已应用 {MARK} ({already}/{len(FILE_PATCHES)} 个文件, v{ver})')
    if check_only:
        return ('READY', f'可安全应用 {MARK} ({len(pending_writes)}/{len(FILE_PATCHES)} 个文件待打, v{ver})')

    for rel, path, text, crlf in pending_writes:
        dst = os.path.join(bdir, *rel.split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        cur, _ = read_text(path)
        if not os.path.exists(dst) and MARK not in cur and not any(m in cur for m in OLD_MARKS):
            shutil.copy2(path, dst)
        out = text.replace('\n', '\r\n') if crlf else text
        open(path, 'wb').write(out.encode('utf-8'))
    return ('PATCHED', f'已成功打补丁 {MARK} ({len(pending_writes)} 个文件, v{ver})')


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    chk = '--check' in sys.argv
    args = [a for a in sys.argv[1:] if a != '--check']
    status, msg = run(args[0] if args else DEFAULT_DIR, check_only=chk)
    print(f'[polestar_nav_optimize] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED') else 1)
