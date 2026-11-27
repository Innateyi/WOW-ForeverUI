# -*- coding: utf-8 -*-
"""
补丁：Polestar 导航重算提速 + 减少山路切弯 + 任务怪就近选点防赶人 + 原生进入副本所在地图提醒（v1）
修改文件（全部自动备份到 backups\\Polestar_<版本>_原版\\）：
  1. Nav/Walk.lua       ：缩短偏离重算冷却（10s→2.5s / 2s→1s）、缩小 STRAY（25→18）、
                          偏离超过 32 码时无视 fstate.sighted 强制重算，走上正确道路立即贴合
  2. Nav/Follow.lua     ：收紧山路过度拉直与切弯（SMOOTH_SPAN 150→65, SIGHT_AHEAD 150→75,
                          OPEN 100→45, PAD 20→12, CORNER_PAD 10→6）
  3. Core/Engine.lua    ：优化任务怪 Spots 选点（DWELL 7→20s, FORGET 300→90s, ABOVE 1→3, SWITCH 40→25），
                          普通刷怪营地不再因 workedNear 被拉黑，身处备选怪区（alt）时允许就近锁定，
                          并支持 kkowoUI 实时视野任务怪回调禁止 Own.dwelt 赶人
  4. UI/DungeonToast.lua：直接在 Polestar 原生卡片（UI.ClassToast）里增加「到达地下城所在地图」提醒，
                          支持多入口（如黑石山双入口）、飞艇/飞行路线经过不误报、一键导航入口/接取任务，
                          并接受 kkowoUI 配置（适级过滤 / 包含团本）与 /polestar dungeontoast zone 测试
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
MARK = '[kkowo-polestar-nav v1]'
OLD_MARKS = ()

FILE_PATCHES = [
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
                '''local STRAY = 18            -- [kkowo-polestar-nav v1] yards off the path: ask again (原 25)
local JOIN = 30             -- [kkowo-polestar-nav v1] yards from a path's start (原 50，避免斜穿山坡)
local ASK_EVERY = 1.0       -- [kkowo-polestar-nav v1] seconds between asks for the same goal (原 2)
local ASK_FAR, ASK_FAR_EVERY = 2000, 2.5 -- [kkowo-polestar-nav v1] 长路偏离后最快 2.5s 重算（原 10s）
local GOAL_MOVED = 1        -- yards: the goal is another one
local FAIL_RETRY, FAIL_MOVED, FAIL_AGAIN = 4, 4, 1.5 -- [kkowo-polestar-nav v1] 寻路失败后更快重试（原 15, 5, 2）''',
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
                '''local PAD = 12         -- [kkowo-polestar-nav v1] 收紧道路走廊容差（原 20），减少山路切弯
local CORNER_PAD = 6   -- [kkowo-polestar-nav v1] 减少拐角内切（原 10）''',
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
                '''local Spots = {
\tSWITCH = 25, -- [kkowo-polestar-nav v1] yards (原 40，更灵敏切换就近怪区)
\tLEAVE = 4, -- yards past the arrival radius
\tFORGET = 90, -- [kkowo-polestar-nav v1] seconds (原 300，缩短拉黑时长)
\tABOVE = 3, -- [kkowo-polestar-nav v1] levels (原 1，避免怪高 2 级就跳过脚下怪区)
\tDWELL = 20, -- [kkowo-polestar-nav v1] seconds (原 7，避免喝水/找怪/等刷新 7 秒被踢去别区)
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
    (
        'UI/DungeonToast.lua',
        [
            (
                '''function DT.Model(c)
\tlocal Dg = D()
\tlocal m = { dungeon = c.key, art = Dg.Art and Dg.Art(c.key), icon = Theme.Media("icon-dungeon"), iconColor = "dungeon", titleColor = "text" }
\tm.head = format(L["LEVEL %d · DUNGEON"], c.level)
\tm.facts = format(L["Level %d · Dungeon"], c.level)
\tm.title = format(L["%s is open to you"], c.name)
\tlocal quests = c.take == 1 and L["1 quest to pick up"] or format(L["%d quests to pick up"], c.take)
\tlocal range = UI.LevelRange and UI.LevelRange(c.minLevel, c.maxLevel)
\tlocal where = { quests }
\tif range then where[#where + 1] = format(L["Levels %s"], range) end
\tif c.zoneName then where[#where + 1] = c.zoneName end
\tm.giver = table.concat(where, "  \\194\\183  ")
\t-- A way in through the other faction's land (Dungeons.EnemyEntrance): it
\t-- says so in the warning colour and leads with the dungeon's page, where the
\t-- player decides; the pick-up guide is the second button.
\tlocal enemy = Dg.EnemyEntrance and Dg.EnemyEntrance(c.key, SIDE[player().faction or ""])
\tif enemy then m.giver = m.giver .. "\\n|c" .. Theme.Hex("warning") .. enemy .. "|r" end
\t-- What its quests are worth, as on the dungeon's page (Dungeons.QuestXP).
\tlocal LT = UI.LevelTip
\tlocal xs = Dg.QuestXP and Dg.QuestXP(c.key)
\tif xs and not xs.maxed and (xs.levels or 0) > 0 and LT and LT.Text then m.badge = ns.Upper(LT.Text(xs.levels)) end
\tlocal pick = { label = c.pickLabel or L["Pick up the quests"], run = function() return DT.PickUp(c.key) end }
\tlocal page = { label = L["Open in Dungeons"], run = function() return DT.SeePage(c.key) end }
\tif enemy then m.act, m.more = page, pick else m.act, m.more = pick, page end
\tm.off = { label = L["Turn these off"], run = DT.TurnOff }
\t-- Later below the dungeon's best-at level: back once at best-at.
\tlocal best = c.best or (Dg.BestAt and Dg.BestAt(c.key))
\tm.later = { label = L["Later"], run = function(shown) if best and c.level < best then shown.backAtBest = true end end }
\treturn m
end

-- A card that waits for the hidden guide window (UI.ClassToast keeps it as
-- .current and shows it with the window) counts as told once it is on
-- screen.
local hooked = false
local function toldWhenShown()
\tlocal w = UI.GuideFrame and UI.GuideFrame.frame
\tif hooked or not w then return end
\thooked = true
\tw:HookScript("OnShow", function()
\t\tlocal T = CT()
\t\tlocal m = T and T.current
\t\tif m and m.dungeon and T.frame and T.frame:IsShown() then seen()[m.dungeon] = true end
\tend)
end

-- Show the card for candidate c. -> true when on screen (the dungeon is told)
function DT.Show(c)
\tlocal T = CT()
\tif not (c and T and T.ShowCard) then return false end
\tlocal shown = T.ShowCard(DT.Model(c))
\tif shown then
\t\tseen()[c.key] = true
\telseif T.current and T.current.dungeon == c.key then
\t\ttoldWhenShown()
\tend
\treturn shown
end

-- A dungeon card dismissed (Later, the close button, one of its buttons)
-- counts as told; with Later below best-at, only until best-at ("later").
ns.On("HEADS_UP_HIDDEN", function(m)
\tif type(m) == "table" and m.dungeon then seen()[m.dungeon] = m.backAtBest and "later" or true end
end)''',
                '''DT._zoneShownAt = DT._zoneShownAt or {} -- [kkowo-polestar-nav v1]
DT._zoneDismissed = DT._zoneDismissed or {}

function DT.Model(c)
\tlocal Dg = D()
\tlocal m = { dungeon = c.key, zoneAlert = c.zoneAlert and true or nil, art = Dg.Art and Dg.Art(c.key), icon = Theme.Media("icon-dungeon"), iconColor = "dungeon", titleColor = "text" }
\tlocal range = UI.LevelRange and UI.LevelRange(c.minLevel, c.maxLevel)
\tlocal enemy = Dg.EnemyEntrance and Dg.EnemyEntrance(c.key, SIDE[player().faction or ""])
\tlocal pick = { label = c.pickLabel or L["Pick up the quests"], run = function() return DT.PickUp(c.key) end }
\tlocal page = { label = L["Open in Dungeons"], run = function() return DT.SeePage(c.key) end }
\tif c.zoneAlert then
\t\t-- [kkowo-polestar-nav v1] 到达地下城/团本所在地图时的原生 Polestar 卡片提醒
\t\tlocal isRaid = c.kind == "raid"
\t\tm.head = isRaid and "当前地图 · 团队副本" or "当前地图 · 地下城"
\t\tm.facts = m.head
\t\tm.title = format("本图副本：%s", c.name)
\t\tlocal where = {}
\t\tif (c.take or 0) > 0 then
\t\t\twhere[#where + 1] = c.take == 1 and L["1 quest to pick up"] or format(L["%d quests to pick up"], c.take)
\t\telse
\t\t\twhere[#where + 1] = "已到达副本所在地图"
\t\tend
\t\tif range then where[#where + 1] = format(L["Levels %s"], range) end
\t\tif c.zoneName then where[#where + 1] = c.zoneName end
\t\tm.giver = table.concat(where, "  \\194\\183  ")
\t\tif c.extraNames and c.extraNames ~= "" then
\t\t\tm.giver = m.giver .. "\\n同图另有：" .. c.extraNames
\t\tend
\t\tif enemy then m.giver = m.giver .. "\\n|c" .. Theme.Hex("warning") .. enemy .. "|r" end
\t\tlocal LT = UI.LevelTip
\t\tlocal xs = (c.take or 0) > 0 and Dg.QuestXP and Dg.QuestXP(c.key) or nil
\t\tif xs and not xs.maxed and (xs.levels or 0) > 0 and LT and LT.Text then m.badge = ns.Upper(LT.Text(xs.levels)) end
\t\tlocal guideBtn = {
\t\t\tlabel = "导航至入口",
\t\t\trun = function()
\t\t\t\tlocal ok = Dg.GuideTo and Dg.GuideTo(c.key)
\t\t\t\tif ok then CT().Hide() end
\t\t\t\treturn ok
\t\t\tend,
\t\t}
\t\tif enemy then
\t\t\tm.act, m.more = page, (c.take or 0) > 0 and pick or (c.hasEntrance and guideBtn or nil)
\t\telseif (c.take or 0) > 0 then
\t\t\tm.act, m.more = pick, c.hasEntrance and guideBtn or page
\t\telseif c.hasEntrance then
\t\t\tm.act, m.more = guideBtn, page
\t\telse
\t\t\tm.act, m.more = page, nil
\t\tend
\t\tm.off = { label = L["Turn these off"], run = DT.TurnOff }
\t\tm.later = { label = L["Later"], run = function() DT._zoneDismissed[c.key] = GetTime() end }
\t\treturn m
\tend
\tm.head = format(L["LEVEL %d · DUNGEON"], c.level)
\tm.facts = format(L["Level %d · Dungeon"], c.level)
\tm.title = format(L["%s is open to you"], c.name)
\tlocal quests = c.take == 1 and L["1 quest to pick up"] or format(L["%d quests to pick up"], c.take)
\tlocal where = { quests }
\tif range then where[#where + 1] = format(L["Levels %s"], range) end
\tif c.zoneName then where[#where + 1] = c.zoneName end
\tm.giver = table.concat(where, "  \\194\\183  ")
\t-- A way in through the other faction's land (Dungeons.EnemyEntrance): it
\t-- says so in the warning colour and leads with the dungeon's page, where the
\t-- player decides; the pick-up guide is the second button.
\tif enemy then m.giver = m.giver .. "\\n|c" .. Theme.Hex("warning") .. enemy .. "|r" end
\t-- What its quests are worth, as on the dungeon's page (Dungeons.QuestXP).
\tlocal LT = UI.LevelTip
\tlocal xs = Dg.QuestXP and Dg.QuestXP(c.key)
\tif xs and not xs.maxed and (xs.levels or 0) > 0 and LT and LT.Text then m.badge = ns.Upper(LT.Text(xs.levels)) end
\tif enemy then m.act, m.more = page, pick else m.act, m.more = pick, page end
\tm.off = { label = L["Turn these off"], run = DT.TurnOff }
\t-- Later below the dungeon's best-at level: back once at best-at.
\tlocal best = c.best or (Dg.BestAt and Dg.BestAt(c.key))
\tm.later = { label = L["Later"], run = function(shown) if best and c.level < best then shown.backAtBest = true end end }
\treturn m
end

-- A card that waits for the hidden guide window (UI.ClassToast keeps it as
-- .current and shows it with the window) counts as told once it is on
-- screen.
local hooked = false
local function toldWhenShown()
\tlocal w = UI.GuideFrame and UI.GuideFrame.frame
\tif hooked or not w then return end
\thooked = true
\tw:HookScript("OnShow", function()
\t\tlocal T = CT()
\t\tlocal m = T and T.current
\t\tif m and m.dungeon and not m.zoneAlert and T.frame and T.frame:IsShown() then seen()[m.dungeon] = true end
\tend)
end

-- Show the card for candidate c. -> true when on screen (the dungeon is told)
function DT.Show(c)
\tlocal T = CT()
\tif not (c and T and T.ShowCard) then return false end
\tlocal shown = T.ShowCard(DT.Model(c))
\tif shown then
\t\tif c.zoneAlert then DT._zoneShownAt[c.key] = GetTime() else seen()[c.key] = true end
\telseif T.current and T.current.dungeon == c.key then
\t\tif c.zoneAlert then DT._zoneShownAt[c.key] = GetTime() else toldWhenShown() end
\tend
\treturn shown
end

-- A dungeon card dismissed (Later, the close button, one of its buttons)
-- counts as told; with Later below best-at, only until best-at ("later").
ns.On("HEADS_UP_HIDDEN", function(m)
\tif type(m) == "table" and m.dungeon then
\t\tif m.zoneAlert then
\t\t\tDT._zoneDismissed[m.dungeon] = GetTime()
\t\telse
\t\t\tseen()[m.dungeon] = m.backAtBest and "later" or true
\t\tend
\tend
end)''',
            ),
            (
                '''ns.RegisterEvent("PLAYER_REGEN_ENABLED", retry)
ns.On("HEADS_UP_HIDDEN", retry)

ns.RegisterCommand("dungeontoast", function(rest)
\tlocal Dg = D()
\tlocal key = rest and rest ~= "" and Dg and Dg.Find and Dg.Find(rest) or nil''',
                '''ns.RegisterEvent("PLAYER_REGEN_ENABLED", retry)
ns.On("HEADS_UP_HIDDEN", retry)

-- [kkowo-polestar-nav v1] 进入包含地下城/团本的地图时，使用 Polestar 原生卡片提醒（支持 /polestar dungeontoast zone 测试）
do
\tlocal KNOWN_ZONES = {
\t\t[1413] = true, [1416] = true, [1418] = true, [1420] = true, [1421] = true,
\t\t[1422] = true, [1423] = true, [1426] = true, [1427] = true, [1428] = true,
\t\t[1434] = true, [1435] = true, [1436] = true, [1437] = true, [1440] = true,
\t\t[1443] = true, [1444] = true, [1445] = true, [1446] = true, [1447] = true,
\t\t[1449] = true, [1451] = true, [1453] = true, [1454] = true, [1455] = true,
\t\t[1458] = true, [2548] = true,
\t}
\tlocal ZONE_COOLDOWN = 1800
\tlocal lastZoneMap, pendingZone, zoneTimerGen = nil, nil, 0

\tlocal function zoneCfg()
\t\tif type(_G.kkowoUI_PolestarZoneDungeonCfg) == "function" then
\t\t\tlocal ok, cfg = pcall(_G.kkowoUI_PolestarZoneDungeonCfg)
\t\t\tif ok and type(cfg) == "table" then return cfg end
\t\tend
\t\treturn { enabled = true, levelFilter = true, includeRaids = false }
\tend

\tlocal function currentZoneMap()
\t\tif IsInInstance and (select(1, IsInInstance())) then return nil end
\t\tlocal C = ns.Compat
\t\tif C and C.GetPlayerMapPosition then
\t\t\tlocal m = C.GetPlayerMapPosition()
\t\t\tif type(m) == "number" and m > 0 then return m end
\t\tend
\t\tif C_Map and C_Map.GetBestMapForUnit then
\t\t\tlocal m = C_Map.GetBestMapForUnit("player")
\t\t\tif type(m) == "number" and m > 0 then return m end
\t\tend
\t\treturn nil
\tend

\tlocal function matchesZone(d, mapID)
\t\tif d.zone == mapID then return true end
\t\tif d.entrance and d.entrance.map == mapID then return true end
\t\tif (mapID == 1427 or mapID == 1428) and (d.zone == 1427 or d.zone == 1428) then return true end
\t\treturn false
\tend

\tfunction DT.CheckZone(force)
\t\tlocal cfg = zoneCfg()
\t\tif not force and (not on() or cfg.enabled == false) then return false end
\t\tif not force and UnitOnTaxi and UnitOnTaxi("player") then return false end
\t\tlocal mapID = currentZoneMap()
\t\tif not mapID then return false end
\t\tlocal C, T, Dg = ns.Compat, CT(), D()
\t\tif not (Dg and Dg.List) then return false end
\t\tif not force and not codexLoaded() and not KNOWN_ZONES[mapID] then return false end
\t\tif (C and C.InCombat and C.InCombat()) or (not force and T and T.current) then
\t\t\tpendingZone = mapID
\t\t\treturn false
\t\tend
\t\tif not codexLoaded() and Dg.Load then
\t\t\tlocal ok = Dg.Load()
\t\t\tif not ok then return false end
\t\tend
\t\tlocal p = player()
\t\tlocal level = p.level
\t\tlocal side = SIDE[p.faction or ""]
\t\tif type(level) ~= "number" or not side then return false end
\t\tlocal now = GetTime()
\t\tlocal found = {}
\t\tfor _, d in ipairs(Dg.List()) do
\t\t\tif matchesZone(d, mapID) then
\t\t\t\tlocal isRaid = d.kind == "raid"
\t\t\t\tlocal kindOk = (not isRaid) or (cfg.includeRaids == true) or force
\t\t\t\tlocal enemyCap = Dg.EnemyCapital and Dg.EnemyCapital(d.key, side)
\t\t\t\tlocal lo, hi = d.minLevel or 1, d.maxLevel or d.minLevel or 60
\t\t\t\tlocal levelOk = force or (cfg.levelFilter == false) or (isRaid and level >= 58) or (not isRaid and level >= lo - 2 and level <= hi + 5)
\t\t\t\tlocal cooled = force or ((now - (DT._zoneShownAt[d.key] or -1e9)) >= ZONE_COOLDOWN and not DT._zoneDismissed[d.key])
\t\t\t\tif kindOk and not enemyCap and levelOk and cooled then
\t\t\t\t\tlocal plan = Dg.PickupPlan and Dg.PickupPlan(d.key) or nil
\t\t\t\t\tlocal take = plan and plan.take and #plan.take or 0
\t\t\t\t\tlocal best = Dg.BestAt and Dg.BestAt(d.key) or lo
\t\t\t\t\tfound[#found + 1] = {
\t\t\t\t\t\tkey = d.key, name = d.name, kind = d.kind, zoneName = d.zoneName,
\t\t\t\t\t\tminLevel = d.minLevel, maxLevel = d.maxLevel, best = best, take = take,
\t\t\t\t\t\tlevel = level, hasEntrance = d.entrance ~= nil, zoneAlert = true,
\t\t\t\t\t\tpickLabel = plan and Dg.PickupLabel and Dg.PickupLabel(plan) or nil,
\t\t\t\t\t\tgap = math.abs((best or lo) - level),
\t\t\t\t\t}
\t\t\t\tend
\t\t\tend
\t\tend
\t\tif #found == 0 then return false end
\t\tsort(found, function(a, b)
\t\t\tif (a.kind == "raid") ~= (b.kind == "raid") then return a.kind ~= "raid" end
\t\t\tif (a.take > 0) ~= (b.take > 0) then return a.take > 0 end
\t\t\tif a.gap ~= b.gap then return a.gap < b.gap end
\t\t\treturn a.key < b.key
\t\tend)
\t\tlocal pick = found[1]
\t\tif #found > 1 then
\t\t\tlocal extras = {}
\t\t\tfor i = 2, #found do extras[#extras + 1] = found[i].name end
\t\t\tpick.extraNames = table.concat(extras, "、")
\t\tend
\t\tlocal ok = DT.Show(pick)
\t\tif ok then
\t\t\tfor i = 2, #found do DT._zoneShownAt[found[i].key] = now end
\t\tend
\t\treturn ok
\tend

\tlocal function scheduleZoneCheck(delay)
\t\tzoneTimerGen = zoneTimerGen + 1
\t\tlocal gen = zoneTimerGen
\t\tns.After(delay or 1.2, function()
\t\t\tif gen ~= zoneTimerGen then return end
\t\t\tif UnitOnTaxi and UnitOnTaxi("player") then return end
\t\t\tlocal mapID = currentZoneMap()
\t\t\tif not mapID or mapID == lastZoneMap then return end
\t\t\tlastZoneMap = mapID
\t\t\tpendingZone = nil
\t\t\tDT.CheckZone(false)
\t\tend)
\tend

\tns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
\t\tlastZoneMap = currentZoneMap()
\tend)
\tns.RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
\t\tscheduleZoneCheck(1.2)
\tend)
\tns.RegisterEvent("PLAYER_CONTROL_GAINED", function()
\t\tscheduleZoneCheck(0.8)
\tend)
\tlocal function retryZone()
\t\tif not pendingZone then return end
\t\tlocal m = pendingZone
\t\tpendingZone = nil
\t\tns.After(0.6, function()
\t\t\tif currentZoneMap() == m then DT.CheckZone(false) end
\t\tend)
\tend
\tns.RegisterEvent("PLAYER_REGEN_ENABLED", retryZone)
\tns.On("HEADS_UP_HIDDEN", retryZone)
end

ns.RegisterCommand("dungeontoast", function(rest)
\tif rest == "zone" then
\t\tif not DT.CheckZone(true) then ns.Print("当前地图未检测到副本。") end
\t\treturn
\tend
\tlocal Dg = D()
\tlocal key = rest and rest ~= "" and Dg and Dg.Find and Dg.Find(rest) or nil''',
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
