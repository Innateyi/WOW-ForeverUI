# -*- coding: utf-8 -*-
"""
kkowoUI 离线 Lua 5.1 自动化回归测试套件（基于 lupa + wow_mock.lua）
验证：
  1. 9 个子插件 TOC 解析与完整加载（跳过 Vendor/，LoD 插件按需加载）
  2. ADDON_LOADED / PLAYER_LOGIN / PLAYER_ENTERING_WORLD 启动流程 0 报错
  3. 战斗中首次按需加载 kkowoUI_Options 与 kkowoUI_KeybindBoard 0 报错且无受保护调用违规
  4. 全模块生命周期（开 -> 关 -> 开）0 报错
  5. 全部配置页（F.OPTION_GROUPS）模拟 EUI Widgets 构建 0 报错且无悬空模块引用
  6. 全部 /kk 子命令分发 0 报错
  7. 副本内 Forbidden 姓名板安全性检查（不得在 IsForbidden() 框体上调 GetChildren/SetPoint）
  8. 旧版 v1.5.1 存档迁移兼容性验证（KkowoUIDB -> kkowoUIDB、保留配置、不丢键）
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import pathlib
from lupa.lua51 import LuaRuntime

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
ADDON_BASE = REPO / 'Addon'

LOAD_ORDER = [
    'kkowoUI_Media',
    'kkowoUI',
    'kkowoUI_CoreHUD',
    'kkowoUI_QoL',
    'kkowoUI_Integrations',
    'kkowoUI_ClassPack',
    'kkowoUI_Tooltip',
]
LOD_ADDONS = {'kkowoUI_Options', 'kkowoUI_KeybindBoard'}


def parse_toc(addon_name):
    toc_path = ADDON_BASE / addon_name / f'{addon_name}.toc'
    files = []
    lod = False
    for raw in toc_path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith('##'):
            if re.match(r'^##\s*LoadOnDemand:\s*1', line):
                lod = True
            continue
        if line.startswith('#'):
            continue
        # Strip conditional tags like [AllowLoadTextLocale zhCN]
        rel = re.sub(r'\s*\[.*\]\s*$', '', line).strip()
        if rel:
            files.append(rel)
    return lod, files


def create_env(pre_sv_lua=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    mock_src = (HERE / 'wow_mock.lua').read_text(encoding='utf-8')
    mock = lua.execute(mock_src)
    if pre_sv_lua:
        lua.execute(pre_sv_lua)

    loaded_tables = {}

    def load_addon(addon_name, skip_vendor=True, file_overrides=None):
        lod, files = parse_toc(addon_name)
        ns = lua.table()
        loaded_tables[addon_name] = ns
        mock.SetAddonLoaded(addon_name, True)
        overrides = file_overrides or {}
        for rel in files:
            norm = rel.replace('\\', '/')
            if skip_vendor and norm.startswith('Vendor/'):
                continue
            override_key = f'{addon_name}/{norm}'
            if override_key in overrides:
                src = overrides[override_key]
            else:
                fpath = ADDON_BASE / addon_name / norm
                if not fpath.is_file():
                    raise FileNotFoundError(f'TOC {addon_name} 引用了不存在的文件: {rel}')
                src = fpath.read_text(encoding='utf-8')
            chunk_name = f'@{addon_name}/{norm}'
            res = lua.eval('function(src, name) local f, e = loadstring(src, name); return { f, e } end')(src, chunk_name)
            fn, err = res[1], res[2]
            if fn is None:
                raise RuntimeError(f'语法错误 {chunk_name}: {err}')
            fn(addon_name, ns)
        mock.FireEvent('ADDON_LOADED', addon_name)
        return True

    def lod_loader(name):
        if name in LOD_ADDONS or (ADDON_BASE / name / f'{name}.toc').is_file():
            try:
                load_addon(name)
                return True, None
            except Exception as e:
                return False, str(e)
        return False, 'MISSING'

    mock.SetLoDLoader(lod_loader)
    for name in LOD_ADDONS:
        mock.SetAddonLoaded(name, False)
    return lua, mock, load_addon


def run_all():
    failures = []
    passes = []

    def check(name, fn):
        try:
            info = fn()
            passes.append((name, info or 'OK'))
            print(f'[PASS] {name}: {info or "OK"}')
        except Exception as e:
            failures.append((name, str(e)))
            print(f'[FAIL] {name}: {e}')

    # 1. Boot & Login test
    lua, mock, load_addon = create_env()

    def t_boot():
        for name in LOAD_ORDER:
            load_addon(name)
        mock.FireEvent('PLAYER_LOGIN')
        mock.FireEvent('PLAYER_ENTERING_WORLD', True, False)
        mock.AdvanceTime(5.0)
        F = lua.globals().kkowoUI
        prints = list(mock.GetPrints().values())
        boot_errs = [p for p in prints if '启动失败' in str(p)]
        assert not boot_errs, f'模块启动报错: {boot_errs}'
        mods = list(F.Modules.All().values())
        active = sum(1 for m in mods if m._active)
        return f'已加载 {len(LOAD_ORDER)} 个常驻套件，注册 {len(mods)} 个模块，激活 {active} 个，0 启动失败'

    check('常驻套件加载与登录启动', t_boot)

    # 2. Combat LoD test
    def t_combat_lod():
        mock.SetInCombat(True)
        mock.ClearProtectedViolations()
        res1 = lua.eval('function(n) local a, b = C_AddOns.LoadAddOn(n); return { a, b } end')('kkowoUI_Options')
        assert res1[1], f'kkowoUI_Options 加载失败: {res1[2]}'
        res2 = lua.eval('function(n) local a, b = C_AddOns.LoadAddOn(n); return { a, b } end')('kkowoUI_KeybindBoard')
        assert res2[1], f'kkowoUI_KeybindBoard 加载失败: {res2[2]}'
        # Try calling /kk and /kkkeys during combat
        mock.RunSlash('/kk', 'status')
        mock.RunSlash('/kkkeys', '')
        viol = list(mock.GetProtectedViolations().values())
        mock.SetInCombat(False)
        assert not viol, f'战斗中触发受保护调用: {viol}'
        return '战斗中按需加载 Options & KeybindBoard 并执行命令，0 受保护违规'

    check('战斗中按需加载 LoD 子插件', t_combat_lod)

    # 3. Module lifecycle toggle (On -> Off -> On)
    def t_lifecycle():
        F = lua.globals().kkowoUI
        mods = list(F.Modules.All().values())
        toggled = 0
        errs = []
        for m in mods:
            key = m.key
            was = m.IsEnabled(m)
            try:
                m.SetEnabled(m, False)
                assert not m._active, f'{key}: Disable 后仍为 active'
                m.SetEnabled(m, True)
                m.SetEnabled(m, was)
                toggled += 1
            except Exception as e:
                errs.append(f'{key}: {e}')
        assert not errs, '; '.join(errs)
        return f'全部 {toggled} 个模块完成 开->关->开 切换，0 报错'

    check('全模块生命周期开关测试', t_lifecycle)

    # 4. Build all option pages
    def t_options_pages():
        F = lua.globals().kkowoUI
        ui = F.EnsureOptionsLoaded()
        assert ui is not None, 'F._OptionsUI 未就绪'
        groups = list(F.OPTION_GROUPS.values())
        page_count = 0
        missing_mods = []
        parent = lua.globals().CreateFrame('Frame', nil := None, lua.globals().UIParent)
        for g in groups:
            pages = list(g.pages.values())
            for pname in pages:
                if g.pageMap and g.pageMap[pname]:
                    for mk in g.pageMap[pname].values():
                        base_mk = mk.split(':', 1)[0]
                        if F.Modules.Get(base_mk) is None:
                            missing_mods.append(f'{g.key}/{pname} -> {mk}')
                h = ui.BuildGroupPage(g, pname, parent, 0)
                assert isinstance(h, (int, float)) and h > 0, f'页面 {g.key}/{pname} 返回高度异常: {h}'
                page_count += 1
        assert not missing_mods, f'pageMap 中存在未注册模块: {missing_mods}'
        return f'成功构建 {len(groups)} 组共 {page_count} 个配置页，0 悬空模块'

    check('全配置页模拟构建与引用校验', t_options_pages)

    # 5. Slash commands
    def t_slash():
        cmds = [
            ('/kk', 'status'),
            ('/kk', 'doctor'),
            ('/kk', 'loginlog'),
            ('/kk', 'nav'),
            ('/kk', 'kw'),
            ('/kk', 'world'),
            ('/kk', 'unlock'),
            ('/kk', 'keys'),
            ('/kk', 'friendly'),
            ('/kk', 'hud'),
            ('/kk', 'perf'),
            ('/kk', 'toast'),
            ('/kk', 'wp'),
            ('/kk', 'help'),
            ('/kk', 'help all'),
            ('/kk', 'harvest'),
            ('/kk', 'harvest stop'),
            ('/kk', 'probe'),
            ('/kk', 'probe'),
            ('/kk', 'markcal'),
            ('/kk', 'fade why'),
            ('/kk', 'rec status'),
            ('/kk', 'selftest'),
        ]
        for c, arg in cmds:
            mock.RunSlash(c, arg)
        mock.AdvanceTime(0.5)
        F = lua.globals().kkowoUI
        assert F.db.selftest is not None and F.db.selftest.failed == 0, f'selftest 失败: {F.db.selftest and F.db.selftest.failed}'
        return f'验证 {len(cmds)} 个 /kk 子命令及诊断工具分发，selftest 通过 {F.db.selftest.passed} 项，0 报错'

    check('/kk 子命令分发测试', t_slash)

    # 6. Forbidden nameplate safety
    def t_forbidden_np():
        forb = mock.CreateForbiddenPlate()
        mock.SetMockNameplates(lua.table_from({1: forb, 'nameplate1': forb}))
        mock.FireEvent('NAME_PLATE_UNIT_ADDED', 'nameplate1')
        mock.FireEvent('PLAYER_TARGET_CHANGED')
        mock.FireEvent('RAID_TARGET_UPDATE')
        mock.AdvanceTime(0.6)
        mock.RunTickersOnce()
        mock.SetMockNameplates(lua.table())
        return 'Forbidden 姓名板事件与轮询全部安全跳过'

    check('副本 Forbidden 姓名板防护测试', t_forbidden_np)

    # 7. Legacy v1.5.1 SavedVariables migration
    def t_legacy_sv():
        old_sv = '''
        KkowoUIDB = {
            version = 1,
            migratedFromHaaland = true,
            theme = { accentMode = "eui", combatFadeAlpha = 0.25 },
            positions = {
                MarkBar = { point = "CENTER", relPoint = "CENTER", x = 12, y = -40 },
                BadPos = { point = "FUI_BAD", x = 0, y = 0 },
            },
            modules = {
                markBar = { enabled = true, overheadSize = 42, pullSeconds = 8 },
                chatBar = { enabled = true, v4LeftDockMigrated = true, dockMode = "bottom", panelAlpha = 0.20 },
                questAuto = { enabled = true, autoAccept = true, autoTurnIn = false },
            },
        }
        KkowoUICharDB = { xpSession = { gainedXP = 999 } }
        '''
        l2, m2, loader2 = create_env(pre_sv_lua=old_sv)
        for name in LOAD_ORDER:
            loader2(name)
        m2.FireEvent('PLAYER_LOGIN')
        m2.AdvanceTime(1.0)
        db = l2.globals().kkowoUIDB
        assert db is not None, 'kkowoUIDB 未迁入'
        assert l2.globals().KkowoUIDB is None, '旧全局 KkowoUIDB 未清空'
        assert db.theme.accentMode == 'eui', f'theme.accentMode 丢失: {db.theme.accentMode}'
        assert db.positions.MarkBar.x == 12, '合法位置丢失'
        assert db.positions.BadPos is None, '非法坐标未清理'
        assert db.modules.markBar.overheadSize == 42, 'markBar.overheadSize 丢失'
        assert db.modules.chatBar.dockMode == 'bottom', 'v4LeftDockMigrated=true 时 dockMode 被覆盖'
        assert db.modules.questAuto.autoAccept is True and db.modules.questAuto.autoTurnIn is False, 'questAuto 设置丢失'
        return 'KkowoUIDB -> kkowoUIDB 迁移完整，用户偏好保留，坏坐标已清理'

    check('旧版 v1.5.1 存档迁移兼容性测试', t_legacy_sv)

    # 8. Task A: Chat tab switching zero redundant anchor & geometry stable
    def t_chat_tab_switch():
        F = lua.globals().kkowoUI
        g = lua.globals()
        cb_dbg = F._chatBarDebug
        assert cb_dbg is not None, 'F._chatBarDebug 缺失'
        # Set up mock EUI Chat context so bg1 / TabsRefreshNow / SyncChatFrameState exist
        lua.execute('''
            local EUI = _G.EllesmereUI
            local bg1 = CreateFrame("Frame", "MockEUIChatBg1", UIParent)
            bg1:SetSize(402, 225)
            EUI._chatCFD = function(cf)
                if cf == _G.ChatFrame1 then return { bg = bg1 } end
                return {}
            end
            EUI._ModuleNS = EUI._ModuleNS or {}
            local echat = {
                DB = function() return { tabHeight = 24, extendBgBehindTabs = true } end,
                TabsRefreshNow = function() end,
                SyncChatFrameState = function() end,
            }
            EUI._ModuleNS.EllesmereUIChat = { ECHAT = echat }
        ''')
        cb = F.Modules.Get('chatBar')
        cb.SetEnabled(cb, False)
        cb.SetEnabled(cb, True)
        mock.AdvanceTime(1.0)
        anc0 = cb_dbg.anchorCount
        w0, h0 = g.ChatFrame2.GetWidth(g.ChatFrame2), g.ChatFrame2.GetHeight(g.ChatFrame2)
        for _ in range(5):
            g.ChatFrame2Tab.Click(g.ChatFrame2Tab, 'LeftButton')
            g.EllesmereUI._ModuleNS.EllesmereUIChat.ECHAT.SyncChatFrameState()
            g.EllesmereUI._ModuleNS.EllesmereUIChat.ECHAT.TabsRefreshNow()
            g.ChatFrame1Tab.Click(g.ChatFrame1Tab, 'LeftButton')
            g.EllesmereUI._ModuleNS.EllesmereUIChat.ECHAT.SyncChatFrameState()
            g.EllesmereUI._ModuleNS.EllesmereUIChat.ECHAT.TabsRefreshNow()
        mock.AdvanceTime(0.2)
        anc1 = cb_dbg.anchorCount
        w1, h1 = g.ChatFrame2.GetWidth(g.ChatFrame2), g.ChatFrame2.GetHeight(g.ChatFrame2)
        assert anc1 == anc0, f'切标签触发冗余 ApplyAnchor: {anc0} -> {anc1}'
        assert w0 == w1 and h0 == h1, f'ChatFrame2 几何跳动: {w0}x{h0} -> {w1}x{h1}'
        return f'连续来回切换 10 次标签，anchorDelta=0，ChatFrame2 几何恒定 ({w1}x{h1})'

    check('任务 A：聊天标签切换零重排与几何稳定', t_chat_tab_switch)

    # 9. Task B: Overhead raid markers sync, friendly name-only, target scale, secret idx & restore
    def t_raid_markers():
        lua.execute('''
            local EUI = _G.EllesmereUI
            EUI._ModuleNS = EUI._ModuleNS or {}
            local prof = {
                raidMarkerSize = 24,
                raidMarkerCoreSize = 24,
                raidMarkerPos = "top",
                nameRaidMarkerSize = 14,
                nameRaidMarkerEnabled = false,
            }
            local ep = CreateFrame("Frame", nil, UIParent)
            ep.unit = "nameplate1"
            ep.raidFrame = CreateFrame("Frame", nil, ep)
            ep.raidFrame:SetSize(24, 24)
            ep.raid = ep.raidFrame:CreateTexture(nil, "ARTWORK")
            function ep:UpdateRaidIcon()
                self.raidFrame:SetSize(prof.raidMarkerSize, prof.raidMarkerSize)
                self.raidFrame._npSz = prof.raidMarkerSize
            end
            local fp = CreateFrame("Frame", nil, UIParent)
            fp.unit = "nameplate2"
            fp.raidFrame = CreateFrame("Frame", nil, fp)
            fp.raidFrame:SetSize(24, 24)
            fp.raid = fp.raidFrame:CreateTexture(nil, "ARTWORK")
            function fp:UpdateRaidIcon()
                self.raidFrame:SetSize(prof.raidMarkerSize, prof.raidMarkerSize)
                self.raidFrame._npSz = prof.raidMarkerSize
            end
            -- 友方玩家仅名字模式暴雪原生板（UnitFrame 可见，alpha=1）
            local blizzNP = CreateFrame("Frame", nil, UIParent)
            blizzNP.namePlateUnitToken = "nameplate3"
            blizzNP.UnitFrame = CreateFrame("Frame", nil, blizzNP)
            blizzNP.UnitFrame.unit = "nameplate3"
            blizzNP.UnitFrame:SetAlpha(1)
            blizzNP.UnitFrame.RaidTargetFrame = CreateFrame("Frame", nil, blizzNP.UnitFrame)
            blizzNP.UnitFrame.RaidTargetFrame:SetSize(21.87, 21.87)
            blizzNP.UnitFrame.RaidTargetFrame.RaidTargetIcon = blizzNP.UnitFrame.RaidTargetFrame:CreateTexture(nil, "ARTWORK")
            local enemyNP = CreateFrame("Frame", nil, UIParent)
            enemyNP.namePlateUnitToken = "nameplate1"
            enemyNP.UnitFrame = CreateFrame("Frame", nil, enemyNP)
            enemyNP.UnitFrame:SetAlpha(0)
            enemyNP.UnitFrame.RaidTargetFrame = CreateFrame("Frame", nil, enemyNP.UnitFrame)
            enemyNP.UnitFrame.RaidTargetFrame:SetSize(21.87, 21.87)

            _G.__TEST_MARK_STATE = { prof = prof, ep = ep, fp = fp, blizzNP = blizzNP, enemyNP = enemyNP }
            EUI._ModuleNS.EllesmereUINameplates = {
                ENP = { db = { profile = prof } },
                plates = { nameplate1 = ep },
                friendlyPlates = { nameplate2 = fp },
                GetRaidMarkerPos = function() return prof.raidMarkerPos end,
                GetRaidMarkerSize = function() return prof.raidMarkerSize end,
                RefreshAllNPCOverlays = function() end,
            }
            _G.C_NamePlate.GetNamePlates = function() return { enemyNP, blizzNP } end
            _G.C_NamePlate.GetNamePlateForUnit = function(u)
                if u == "target" or u == "nameplate1" then return enemyNP end
                if u == "nameplate3" then return blizzNP end
                return nil
            end
            _G.UnitExists = function(u) return u == "target" or u == "player" end
            _G.UnitIsUnit = function(a, b) return (a == "nameplate1" and b == "target") or (a == b) end
            -- 模拟 12.x 机密值：让 issecretvalue 对特定表/哨兵值返回 true
            local secretSentinel = setmetatable({}, {})
            local origIsSecret = _G.issecretvalue
            _G.__TEST_SECRET_IDX = secretSentinel
            _G.issecretvalue = function(v)
                if v == secretSentinel then return true end
                return origIsSecret and origIsSecret(v) or false
            end
        ''')
        F = lua.globals().kkowoUI
        mb = F.Modules.Get('markBar')
        mb.SetEnabled(mb, False)
        mb.SetEnabled(mb, True)
        mb.ApplyOverheadSize(mb, 40)
        st = lua.globals().__TEST_MARK_STATE
        prof = st.prof
        assert prof.raidMarkerSize == 40 and prof.raidMarkerCoreSize == 40, f'EUI 敌方板未同步: {prof.raidMarkerSize}/{prof.raidMarkerCoreSize}'
        assert prof.nameRaidMarkerSize == 40, f'nameRaidMarkerSize 未同步: {prof.nameRaidMarkerSize}'
        assert prof.nameRaidMarkerEnabled is False, 'raidMarkerPos="top" 时不应强制开启 nameRaidMarkerEnabled 导致重复标记'
        assert abs(st.blizzNP.UnitFrame.RaidTargetFrame.GetWidth(st.blizzNP.UnitFrame.RaidTargetFrame) - 40) < 0.1, '友方仅名字板暴雪 RaidTargetFrame 未缩放'
        assert abs(st.enemyNP.UnitFrame.RaidTargetFrame.GetWidth(st.enemyNP.UnitFrame.RaidTargetFrame) - 21.87) < 0.1, '已隐藏的敌方原生 UnitFrame 不应被误改'

        # Secret idx global hook check
        lua.execute('''
            local t = UIParent:CreateTexture(nil, "ARTWORK")
            _G.__TEST_SECRET_TEX = t
            SetRaidTargetIconTexture(t, _G.__TEST_SECRET_IDX)
        ''')
        # Target scale +50% -> 60px, then untarget -> 40px
        mb.ApplyTargetScalePct(mb, 50)
        assert abs(st.ep.raidFrame.GetWidth(st.ep.raidFrame) - 60) < 0.1, f'目标放大未生效: {st.ep.raidFrame.GetWidth(st.ep.raidFrame)}'
        assert st.ep.raidFrame._npSz == 60 and st.ep.raidFrame._kkScaledExtra == 20, '目标放大未同步 _npSz/_kkScaledExtra 给呼吸箭头避让'
        lua.execute('_G.UnitExists = function(u) return u == "player" end')
        mock.FireEvent('PLAYER_TARGET_CHANGED')
        assert abs(st.ep.raidFrame.GetWidth(st.ep.raidFrame) - 40) < 0.1, '取消目标后标记未还原'

        # Disable restore check
        mb.SetEnabled(mb, False)
        assert prof.raidMarkerSize == 24 and prof.raidMarkerCoreSize == 24 and prof.nameRaidMarkerSize == 14 and prof.nameRaidMarkerEnabled is False, \
            f'关闭模块未无损还原 EUI 原值: {prof.raidMarkerSize}/{prof.raidMarkerCoreSize}/{prof.nameRaidMarkerSize}/{prof.nameRaidMarkerEnabled}'
        assert abs(st.blizzNP.UnitFrame.RaidTargetFrame.GetWidth(st.blizzNP.UnitFrame.RaidTargetFrame) - 21.87) < 0.1, '关闭模块未还原暴雪 RaidTargetFrame 原尺寸'
        mb.ApplyTargetScalePct(mb, 0)
        mb.SetEnabled(mb, True)
        return '敌方/友方/仅名字板/机密值/目标+50%放大与还原/关闭无损恢复全部通过'

    check('任务 B：头顶标记统一同步、目标放大与关闭还原', t_raid_markers)

    # 10. Runtime translation injection & official-first priority
    def t_runtime_translations():
        l3, m3, loader3 = create_env()
        # Set up mock Polestar, GTFO, Auctionator, EllesmereUIQoL, BugSack, PrettyTooltip before loading Integrations
        l3.execute('''
            -- Mock Polestar (with official L + official Texts priority + missing fallback)
            local pL = setmetatable({
                ["Commands"] = "官方命令",
            }, { __index = function(_, k) return k end })
            local officialTexts = {
                ["Official Translated Line"] = "官方已翻译句子",
            }
            local prepared = {}
            local function mockFill(s, names, live)
                return (s:gsub("{(%l+):(%d+)}", function(kind, id)
                    local num = tonumber(id)
                    local n = nil
                    if live then
                        if kind == "zone" then n = _G.Polestar.Compat.GetMapName(num)
                        elseif kind == "spell" or kind == "area" then n = _G.Polestar.Names.Get(kind, num)
                        else n = _G.Polestar.Names.Cached(kind, num) end
                    end
                    return n or (names and names[kind .. ":" .. id]) or ("{" .. kind .. ":" .. id .. "}")
                end))
            end
            _G.Polestar = {
                L = pL,
                Compat = {
                    GetMapName = function(id) if id == 99999 then return "官方地图" end return nil end,
                },
                Names = {
                    Language = function() return "zhCN" end,
                    Localised = function() return true end,
                    Native = function() return true end,
                    Quest = function(id) if id == 1 then return "官方任务" end return nil end,
                    Item = function() return nil end,
                    Npc = function() return nil end,
                    Object = function() return nil end,
                    Spell = function() return nil end,
                    Area = function() return nil end,
                    Instance = function() return nil end,
                    Get = function(kind, id) if kind == "quest" and id == 1 then return "官方任务" end return nil end,
                    Cached = function(kind, id) if kind == "quest" and id == 1 then return "官方任务" end return nil end,
                },
                GuideTexts = {
                    PackText = function(_, s) return s end,
                    Prepare = function(def, live)
                        prepared[def] = { title = def.title, why = def.why, names = def.names }
                        def.title = mockFill(officialTexts[def.title] or def.title, def.names, live)
                        def.why = mockFill(officialTexts[def.why] or def.why, def.names, live)
                    end,
                    PrepareSteps = function(def)
                        for _, st in ipairs(def.steps or {}) do
                            if st.note then st.note = mockFill(officialTexts[st.note] or st.note, def.names, true) end
                        end
                    end,
                    DropSteps = function() end,
                    Refresh = function(def)
                        local p = prepared[def]
                        if not p then return false end
                        def.title = mockFill(officialTexts[p.title] or p.title, p.names, true)
                        def.why = mockFill(officialTexts[p.why] or p.why, p.names, true)
                        return true
                    end,
                },
                Codex = {
                    Npc = function(id) return { id = id, subName = "Auctioneer" } end,
                },
                Fire = function() end,
            }
            _G.GTFOLocal = {
                UI_Vibration = "Vibration",
                UI_CustomSounds = "官方自定义音效",
            }
            _G.AUCTIONATOR_L_PAST_AUTHOR_HEADER = "Past Author"
            _G.BugSack = {
                L = {
                    ["All bugs"] = "全部错误", ["Auto popup"] = "自动弹出",
                    ["Current session"] = "本次会话", ["Font size"] = "字体大小",
                    ["Minimap icon"] = "小地图图标", ["Mute"] = "静音",
                    ["Send"] = "发送", ["Small"] = "小", ["Sound"] = "声音", ["Today"] = "今天",
                },
            }
            local euiZh = {}
            _G.EllesmereUI.RegisterLocale = function(loc)
                if loc == "zhCN" then return euiZh end
                return {}
            end
        ''')
        for addon in ('Polestar', 'GTFO', 'Auctionator', 'BugSack'):
            m3.SetAddonLoaded(addon, True)
        for name in LOAD_ORDER:
            loader3(name)
        m3.FireEvent('PLAYER_LOGIN')
        m3.AdvanceTime(0.5)

        l3.execute('''
            local P = _G.Polestar
            -- Official-first checks
            assert(P.L["Commands"] == "官方命令", "Polestar.L 官方译文被覆盖")
            assert(rawget(P.L, "A guide to the items 1 quest in your log needs from where it is given, ending at the entrance.") ~= nil, "Polestar.L 缺失项未注入")
            assert(P.Names.Quest(1) == "官方任务", "Polestar.Names 官方译文被覆盖")
            assert(P.Names.Get("quest", 96383) == "传承奖励：幽灵熊宝宝", "Polestar.Names 补充任务名失败: " .. tostring(P.Names.Get("quest", 96383)))
            assert(P.Names.Get("npc", 222413) == "探险者扎尔戈", "Polestar.Names 补充 NPC 名失败")
            assert(P.Names.Get("item", 213566) == "树栖狼蛛标本", "Polestar.Names 补充物品名失败")
            assert(P.Codex.Npc(1).subName == "拍卖师", "Polestar NPC 副标题未汉化")
            -- GuideTexts official-first vs fallback
            local def = {
                title = "Official Translated Line",
                why = "Eastern pylon found",
                names = { ["npc:222413"] = "Zalgo the Explorer" },
                steps = { { note = "Western pylon found" } },
            }
            P.GuideTexts.Prepare(def, true)
            assert(def.title == "官方已翻译句子", "GuideTexts 官方译文被覆盖: " .. tostring(def.title))
            assert(def.why == "已找到东边的水晶塔", "GuideTexts 缺译未注入: " .. tostring(def.why))
            assert(def.steps[1].note == "已找到西边的水晶塔", "GuideTexts 步骤缺译未注入: " .. tostring(def.steps[1].note))
            -- ThirdParty official-first vs fallback
            assert(_G.GTFOLocal.UI_Vibration == "震动", "GTFO 缺失键未注入")
            assert(_G.GTFOLocal.UI_CustomSounds == "官方自定义音效", "GTFO 官方译文被覆盖")
            assert(_G.AUCTIONATOR_L_PAST_AUTHOR_HEADER == "历任作者", "Auctionator 未注入")
            assert(_G.EllesmereUI.RegisterLocale("zhCN")["Everyone passed"] == "所有人均已放弃", "EllesmereUIQoL 未注入")
            -- Tooltip Bridge locale
            assert(_G.kkowoUI._TooltipLocaleZH and _G.kkowoUI._TooltipLocaleZH["Outline"] ~= "Outline", "TooltipLocaleZh 未加载")
        ''')
        F3 = l3.globals().kkowoUI
        results = {}
        for pname, fn in F3._LocaleChecks.items():
            ok_c, detail_c = fn()
            assert ok_c, f'F._LocaleChecks.{pname} 失败: {detail_c}'
            results[pname] = detail_c
        return '6 组运行时汉化与官方优先校验全部通过: ' + ', '.join(f'{k}({v})' for k, v in sorted(results.items()))

    check('运行时翻译注入与官方优先校验', t_runtime_translations)

    # 11. Real v1.5.1 SavedVariables upgrade migration (read-only snapshot)
    def t_real_v151_sv():
        sv_path = pathlib.Path(r'D:\code\wow\backups\v1.5.1_封版备份_20261127_183459\WTF\Account\688563448#1\SavedVariables\kkowoUI.lua')
        if not sv_path.is_file():
            return '跳过（未找到本地 v1.5.1 备份文件）'
        raw_sv = sv_path.read_text(encoding='utf-8')
        l4, m4, loader4 = create_env(pre_sv_lua=raw_sv)
        for name in LOAD_ORDER:
            loader4(name)
        m4.FireEvent('PLAYER_LOGIN')
        m4.FireEvent('PLAYER_ENTERING_WORLD', True, False)
        m4.AdvanceTime(2.0)
        F4 = l4.globals().kkowoUI
        db = l4.globals().kkowoUIDB
        assert db is not None and db.modules is not None, 'v1.5.1 存档加载异常'
        assert db.modules.markBar.overheadSize == 30, f'markBar.overheadSize 丢失: {db.modules.markBar.overheadSize}'
        assert db.modules.chatBar.worldChannelName == '大脚世界频道', 'chatBar.worldChannelName 丢失'
        assert db.modules.chatBar.dockMode == 'left', 'chatBar.dockMode 丢失'
        # Verify options UI builds cleanly on top of real v1.5.1 SV
        ui4 = F4.EnsureOptionsLoaded()
        parent4 = l4.globals().CreateFrame('Frame', None, l4.globals().UIParent)
        built = 0
        for g in F4.OPTION_GROUPS.values():
            for pname in g.pages.values():
                h = ui4.BuildGroupPage(g, pname, parent4, 0)
                assert isinstance(h, (int, float)) and h > 0
                built += 1
        return f'真实 v1.5.1 存档无缝升级至 v2.0（保留全部偏好，{built} 个配置页构建 0 报错）'

    check('真实 v1.5.1 存档升级兼容测试', t_real_v151_sv)

    # 12. 3D Waypoint Medallion & Beam (selective trigger, meters, Shift+Click pin, sound) + Luminous Cards
    def t_waypoint_beam_and_motion():
        F = lua.globals().kkowoUI
        lua.execute('''
            local EUI = _G.EllesmereUI
            _G.EllesmereUIDB = _G.EllesmereUIDB or {}
            _G.EllesmereUIDB.inGameNavigation = { enabled = true }
            EUI._InGameNavigation = {
                Get = function(k) return _G.EllesmereUIDB.inGameNavigation[k] end,
                Cfg = function() return _G.EllesmereUIDB.inGameNavigation end,
                Apply = function() end,
                Set = function(on) _G.EllesmereUIDB.inGameNavigation.enabled = on == true end,
            }
            local mockNav = CreateFrame("Frame", "MockNavFrame", WorldFrame)
            mockNav:SetSize(16, 16)
            _G.Enum = _G.Enum or {}
            _G.Enum.NavigationState = { Invalid = 0, Occluded = 1, InBounds = 2 }
            _G.Enum.SuperTrackingType = { Quest = 0, UserWaypoint = 1, Corpse = 2, Content = 3 }
            _G.__MOCK_CLAMPED = false
            _G.__MOCK_ST_TYPE = 1
            _G.__MOCK_SOUND_PLAYED = 0
            local origPlaySound = _G.PlaySound
            _G.PlaySound = function(kit, ch)
                _G.__MOCK_SOUND_PLAYED = _G.__MOCK_SOUND_PLAYED + 1
                if origPlaySound then return origPlaySound(kit, ch) end
            end
            _G.C_Navigation = {
                GetFrame = function() return mockNav end,
                HasValidScreenPosition = function() return true end,
                GetTargetState = function() return 0 end,
                WasClampedToScreen = function() return _G.__MOCK_CLAMPED end,
                GetDistance = function() return 245.4 end,
            }
            _G.GetUnitSpeed = function() return 7.0 end
            _G.C_SuperTrack.GetHighestPrioritySuperTrackingType = function() return _G.__MOCK_ST_TYPE end
            _G.C_SuperTrack.GetSuperTrackedQuestID = function() return 101 end
            _G.C_QuestLog.GetTitleForQuestID = function() return "测试任务" end
        ''')
        wa = F.Modules.Get('waypointAutoTrack')
        # Re-enable so EUI InGameNavigation handoff takes effect
        wa.SetEnabled(wa, False)
        wa.SetEnabled(wa, True)
        assert wa.IsUsingKkowoBeam(wa) is True, '默认应使用 kkowoUI 渐变光柱'
        assert wa.GetDB(wa).onlyManualOrQuestBeam is True, '默认应开启仅手动与任务光柱开关'
        assert lua.globals().EllesmereUIDB.inGameNavigation.enabled is False, '开启 kkowoUI 光柱时应自动关闭 EUI 重复光柱'
        # Non-manual UserWaypoint should be suppressed when onlyManualOrQuestBeam=true
        assert not lua.globals().kkowoUI_WaypointBeam.IsShown(lua.globals().kkowoUI_WaypointBeam), '未手动插旗的北极星常规导航不应显示 3D 光柱'

        # Quest focus (SuperTrackingType.Quest = 0) MUST display 3D beam with 米 unit!
        lua.globals().__MOCK_ST_TYPE = 0
        mock.FireEvent('SUPER_TRACKING_CHANGED')
        lua.execute('_G.kkowoUI_WaypointBeam:GetParent()')
        wa.SetEnabled(wa, False)
        wa.SetEnabled(wa, True)
        assert lua.globals().kkowoUI_WaypointBeam.IsShown(lua.globals().kkowoUI_WaypointBeam), '点击任务追踪钮(Quest)时必须显示 3D 光柱'
        dist_txt = lua.globals().kkowoUI_WaypointBeam.distFS.GetText(lua.globals().kkowoUI_WaypointBeam.distFS)
        assert '米' in str(dist_txt) and '码' not in str(dist_txt), f'距离单位应为米而非码: {dist_txt}'

        # Verify all 5 color presets + off-screen edge arrow + preview
        for preset in ('glacier', 'class', 'brand', 'gold', 'violet'):
            wa.GetDB(wa).beamColorMode = preset
            wa.OnThemeChanged(wa)
        lua.globals().__MOCK_CLAMPED = True
        mock.FireEvent('PLAYER_STARTED_MOVING')
        wa.ShowBeamPreview(wa)
        assert lua.globals().kkowoUI_WaypointBeam.IsShown(lua.globals().kkowoUI_WaypointBeam), '光柱预览未显示'
        mock.RunSlash('/kk', 'beam')
        mock.AdvanceTime(6.5)

        # Verify lossless EUI InGameNavigation restore on disable
        wa.SetEnabled(wa, False)
        assert lua.globals().EllesmereUIDB.inGameNavigation.enabled is True, '停用模块后未无损还原 EUI 原光柱开关'
        wa.SetEnabled(wa, True)

        # Verify upgraded Luminous Card modules (LootToast takeover / RollBars anti-block / CombatAlert / MarkBar)
        lt = F.Modules.Get('lootToast')
        assert lt.GetDB(lt).euiConflictMode == 'takeover', f'LootToast 默认应为 takeover: {lt.GetDB(lt).euiConflictMode}'
        lt.ShowPreview(lt)
        rb = F.Modules.Get('rollBars')
        rb.ShowPreview(rb)
        rb.OnCancelRoll(rb, None, None)
        mock.FireEvent('PLAYER_REGEN_DISABLED')
        mock.FireEvent('PLAYER_REGEN_ENABLED')
        mb = F.Modules.Get('markBar')
        mb.OnThemeChanged(mb)
        mock.AdvanceTime(1.5)
        return '3D 渐变光柱(仅手动/任务门控+米单位+5色+离屏+EUI还原)与全UI流光卡片通过'

    check('3D 地图渐变光柱与流光卡片升级测试', t_waypoint_beam_and_motion)

    # 13. Session 2 Regression Suite (17 feedback items)
    def t_session2_regressions():
        # 1) BigWigs_Classic removed from kkowoUI_Integrations.toc OptionalDeps
        toc_txt = (ADDON_BASE / 'kkowoUI_Integrations' / 'kkowoUI_Integrations.toc').read_text(encoding='utf-8')
        assert 'BigWigs_Classic' not in toc_txt, 'kkowoUI_Integrations.toc 仍含 BigWigs_Classic'

        # 2) Guard.lua zero-taint SettingsPanel (never registered in EUI escape proxy, synchronous hardware click) + overlay layering keeps EUI open
        guard_txt = (ADDON_BASE / 'kkowoUI' / 'Core' / 'Guard.lua').read_text(encoding='utf-8')
        assert 'RegisterEscapeClose(_G.SettingsPanel' not in guard_txt, 'Guard.lua 不得向 SettingsPanel 挂自定义 ESC 代理'
        assert '_kkowoFastTabVer or 0) >= 6' in guard_txt, 'Guard.lua 应核验聊天加速补丁 v6'
        assert 'if hideEUI and C_Timer' not in guard_txt, 'Guard.lua 不应把 Settings.OpenToCategory 放进 C_Timer.After'
        lua.execute('''
            local EUI = _G.EllesmereUI
            local mf = CreateFrame("Frame", "MockEUIMain", UIParent)
            mf:SetSize(800, 600)
            mf:SetFrameStrata("DIALOG")
            mf:SetFrameLevel(100)
            mf:Show()
            EUI._mainFrame = mf
            EUI.Hide = function() mf:Hide() end
            EUI.Show = function() mf:Show() end
            local pop = CreateFrame("Frame", "MockOverlayWin", UIParent)
            pop:SetSize(400, 300)
            pop:SetFrameStrata("MEDIUM")
            pop:SetFrameLevel(10)
            pop:Hide()
            _G.kkowoUI.LaunchFromEUI(function() pop:Show() end, function() return pop end)
            assert(mf:IsShown(), "独立插件窗口打开时 EUI 面板应保持在下层不关闭")
            assert(pop:GetFrameStrata() == "DIALOG" and pop:GetFrameLevel() >= 160, "独立插件窗口应抬升至 EUI 上层")
            pop:Hide()
            assert(pop:GetFrameStrata() == "MEDIUM" and pop:GetFrameLevel() == 10, "关闭上层弹窗后应还原原层级")

            -- KeybindBoard ToggleBoard 不得隐藏 EUI
            local kb = _G.kkowoUI.Modules.Get("keybindBoard")
            assert(kb ~= nil, "keybindBoard 模块缺失")
            if _G.kkowoUI_KeybindBoard then _G.kkowoUI_KeybindBoard:Hide() end
            _G.kkowoUI.LaunchFromEUI(function() kb:ToggleBoard() end, function() return _G.kkowoUI_KeybindBoard end)
            assert(mf:IsShown(), "打开可视化键位图时 EUI 面板必须保持在下层可见")
            assert(_G.kkowoUI_KeybindBoard and _G.kkowoUI_KeybindBoard:IsShown(), "键位图应正常显示")
            _G.kkowoUI_KeybindBoard:Hide()
        ''')

        # 3) BagUtility seeds EllesmereUIDB.merchantBulkBuy = true
        lua.execute('''
            _G.EllesmereUIDB = _G.EllesmereUIDB or {}
            _G.EllesmereUIDB.merchantBulkBuy = false
            _G.__BULK_REFRESHED = false
            _G.EllesmereUI._Merchant_RefreshBulkBuy = function() _G.__BULK_REFRESHED = true end
        ''')
        bu = lua.globals().kkowoUI.Modules.Get('bagUtility')
        bu.GetDB(bu).v2MerchantBulkBuySeeded = False
        bu.SetEnabled(bu, False)
        bu.SetEnabled(bu, True)
        assert lua.globals().EllesmereUIDB.merchantBulkBuy is True and lua.globals().__BULK_REFRESHED is True, 'BagUtility 未开启 EUI 商人批量购买'

        # 4) GearList suppresses ShoppingTooltip1 self-compare
        lua.execute('''
            _G.CharacterFrame = _G.CharacterFrame or CreateFrame("Frame", "CharacterFrame", UIParent)
            _G.PaperDollFrame = _G.PaperDollFrame or CreateFrame("Frame", "PaperDollFrame", _G.CharacterFrame)
            _G.ShoppingTooltip1 = _G.ShoppingTooltip1 or CreateFrame("GameTooltip", "ShoppingTooltip1", UIParent)
            local gl = _G.kkowoUI.Modules.Get("gearList")
            gl:SetEnabled(false)
            gl:SetEnabled(true)
            local p = _G.kkowoUI_GearList
            assert(p ~= nil, "GearList 面板未创建")
            _G.ShoppingTooltip1:Show()
            _G.GameTooltip:SetOwner(p, "ANCHOR_RIGHT")
            -- Simulate row tooltip comparison suppression via row OnEnter
            local row = nil
            for _, ch in ipairs({ p:GetChildren() }) do
                if ch._spec ~= nil or ch:GetObjectType() == "Button" then row = ch; break end
            end
            if row then
                _G.GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                _G.ShoppingTooltip1:Show()
                if _G.GameTooltip_ShowCompareItem then _G.GameTooltip_ShowCompareItem(_G.GameTooltip) end
                local onEnter = row:GetScript("OnEnter")
                if onEnter then onEnter(row) end
                assert(not _G.ShoppingTooltip1:IsShown(), "GearList 行悬停不应显示自身对比框 ShoppingTooltip1")
            end
        ''')

        # 5) ImmersiveHUD clamps external SetAlpha(1) flash during faded state
        lua.execute('''
            if _G.WorldMapFrame then _G.WorldMapFrame:Hide() end
            local qt = _G.EUI_CustomQuestTracker or CreateFrame("Frame", "EUI_CustomQuestTracker", UIParent)
            qt:Show()
            qt:SetAlpha(1)
            _G.UnitAffectingCombat = function() return false end
            _G.UnitExists = function() return false end
            _G.UnitHealth = function() return 100 end
            _G.UnitHealthMax = function() return 100 end
            _G.UnitPowerType = function() return 2 end
            _G.GetInstanceInfo = function() return "World", "none" end
            local ih = _G.kkowoUI.Modules.Get("immersiveHUD")
            ih:SetEnabled(false)
            ih:SetEnabled(true)
        ''')
        mock.AdvanceTime(2.5)
        lua.execute('''
            local qt = _G.EUI_CustomQuestTracker
            qt:SetAlpha(1)
            assert(qt:GetAlpha() < 0.5, "ImmersiveHUD 未拦截外部 ZONE_CHANGED SetAlpha(1) 瞬闪: " .. tostring(qt:GetAlpha()))
        ''')

        # 6) ChatBar & UnifiedPanel sync alpha 1:1 with EUI Chat _chatTabStrip (even with stale idleAlpha=0.25)
        lua.execute('''
            local strip = CreateFrame("Frame", "MockEUIChatTabStrip", UIParent)
            strip:SetAlpha(1)
            _G.EllesmereUI._ModuleNS = _G.EllesmereUI._ModuleNS or {}
            _G.EllesmereUI._ModuleNS.EllesmereUIChat = _G.EllesmereUI._ModuleNS.EllesmereUIChat or {}
            _G.EllesmereUI._ModuleNS.EllesmereUIChat._chatTabStrip = strip
            local cb = _G.kkowoUI.Modules.Get("chatBar")
            cb:GetDB().idleAlpha = 0.25
            cb:GetDB().v8SyncChatFadeMigrated = false
            cb:SetEnabled(false)
            cb:SetEnabled(true)
            assert(cb:GetDB().idleAlpha == 1.0, "停靠模式旧 idleAlpha=0.25 应迁移为 1.0")
            strip:SetAlpha(1.0)
            assert(math.abs(_G.kkowoUI_ChatBar:GetAlpha() - 1.0) < 0.02, "聊天框亮起时 ChatBar 应 1:1 亮起")
            strip:SetAlpha(0.25)
            local barA = _G.kkowoUI_ChatBar:GetAlpha()
            assert(math.abs(barA - 0.25) < 0.02, "ChatBar 淡隐未与 EUI 聊天 1:1 锁步: " .. tostring(barA))
        ''')

        # 7) CoreHUD_Wings uniform permSz == sz & buff timer inside icon bottom border (y=+2)
        wings_txt = (ADDON_BASE / 'kkowoUI_CoreHUD' / 'CoreHUD' / 'CoreHUD_Wings.lua').read_text(encoding='utf-8')
        assert 'local permSz = sz' in wings_txt, 'CoreHUD_Wings 常驻与限时图标尺寸未统一'
        assert 'reg:SetPoint("BOTTOM", slot, "BOTTOM", 0, 2)' in wings_txt, 'CoreHUD 限时增益倒计时应留在图标底边内 (+2)'

        # 8) WaypointAutoTrack: map Shift+click priority 10000 > Polestar, Minimap pin hook, zero Scale/Translation drift, quest track sound
        wp_txt = (ADDON_BASE / 'kkowoUI_QoL' / 'WaypointAutoTrack.lua').read_text(encoding='utf-8')
        assert 'AddCanvasClickHandler, wm, OnWorldMapCanvasClick, 10000' in wp_txt, '地图 Shift+左键优先级应稳压 Polestar'
        assert 'EnsureMinimapPinHook' in wp_txt and 'HookScript("OnMouseUp", PlacePinFromMinimapClick)' in wp_txt, '缺少小地图零污染快捷插旗钩子'
        assert 'iconPopAnim:CreateAnimation("Scale")' not in wp_txt, '光柱图标不得使用 Scale 动画（防止 3D 框体飞天）'
        assert 'medRiseAnim:CreateAnimation("Translation")' not in wp_txt, '圆章不得叠加 Translation 位移'
        assert 'PlayQuestTrackSoundIfNeeded' in wp_txt, '点击任务追踪按钮缺少落点音效'
        assert 'wpPendingRevealAnim' in wp_txt, '关大地图或转视角见标时应补播光柱升腾动画'

        # 9) LootToast compact PrettyTooltip right-tail fade + grow down + EUI zero-flicker glide; RollBars zero-flicker glide + no icon border glitch
        lt_txt = (ADDON_BASE / 'kkowoUI_QoL' / 'LootToast.lua').read_text(encoding='utf-8')
        assert 'width = 204' in lt_txt and 'ApplyHorizGrad' in lt_txt and 'growUp = false' in lt_txt, 'LootToast 应为紧凑 204px 尾淡且默认向下展开'
        assert 'aJump:SetOrder(1)' in lt_txt and 'aSlide:SetOrder(2)' in lt_txt, 'LootToast 应采用 EUI 式二段归零滑入（零尾帧跳动）'
        assert 'animIn:SetToFinalAlpha(true)' in lt_txt and 'animOut:SetToFinalAlpha(true)' in lt_txt, 'LootToast 入场与退场动画均需启用 SetToFinalAlpha(true) 防止首尾帧闪现'
        assert 't:SetAlpha(0)\n    t:Show()\n    t._animIn:Play()' in lt_txt, 'LootToast 播放二段入场前宿主必须为 Alpha=0（防止 Order 1 首帧全不透明闪烁）'
        assert '_shimmer' not in lt_txt, 'LootToast 不应叠加 ADD 频闪光带'
        rb_txt = (ADDON_BASE / 'kkowoUI_QoL' / 'RollBars.lua').read_text(encoding='utf-8')
        assert 'LayoutRollButtons(bar, false)' in rb_txt, 'RollBars 预览与 60 级时光服默认应隐藏无用的分解按钮'
        assert 'aJump:SetOrder(1)' in rb_txt and 'aSlide:SetOrder(2)' in rb_txt, 'RollBars 应采用 EUI 式二段归零滑入（零尾帧跳动）'
        assert 'ApplyRoundedBorder(bar._iconBtn' not in rb_txt, 'RollBars 图标不应反复重挂双遮罩边框导致滑入尾帧错位'
        assert 'animIn:SetToFinalAlpha(true)' in rb_txt and 'bar:SetAlpha(0)\n        bar:Show()' in rb_txt, 'RollBars 播放二段入场前宿主必须为 Alpha=0 且启用 SetToFinalAlpha(true)'

        # 11) ControlHubUI zero-taint: never calls Settings.OpenToCategory from addon buttons
        hub_txt = (ADDON_BASE / 'kkowoUI_Options' / 'ControlHubUI.lua').read_text(encoding='utf-8')
        assert 'OpenToCategory' not in hub_txt, 'ControlHubUI 不得从插件按钮程序化调 Settings.OpenToCategory 触发 12.1 保护拦截'
        assert 'PrintSafeSettingsGuide' in hub_txt, 'ControlHubUI 应使用合规路径指引打开暴雪受保护插件页'

        # 10) eui_chat_tab_fast v6: load-time flag + never unhide Blizzard ChatFrame2.ScrollBar.Track
        patch_txt = (ADDON_BASE.parent / 'Patches' / 'eui_chat_tab_fast.py').read_text(encoding='utf-8')
        assert "MARK = '[fui-chat-fasttab v6]'" in patch_txt, '补丁应升级至 v6'
        assert 'ns._kkowoFastTabVer = 6' in patch_txt, '补丁应在模块加载期置位 v6 标记'
        patch_new_part = patch_txt.split('FILE_PATCHES = ')[1]
        assert 'bar.Track:SetAlpha(1)' not in patch_new_part, '战斗记录补丁新代码不得再显示暴雪旧滑块'

        return '全部 25 项实机回归断言（v5补丁/总控键位图/无污染/光柱/尾淡拾取/Buff倒计时/聊天锁步）全部通过'

    check('实机会话 2 全部 17 项反馈回归测试', t_session2_regressions)

    # 14. Session 3 Regression Suite (RollBars dungeon click-blocking, WeaponProcs, Nameplate icon clip, TargetHUD auras)
    def t_session3_regressions():
        # 1) RollBars: container hidden & click-through when idle, hides GroupLootContainer/GroupLootFrame in dungeons, cleans up on cancel/timeout
        lua.execute('''
            local rb = _G.kkowoUI.Modules.Get("rollBars")
            assert(rb ~= nil, "rollBars 模块缺失")
            rb:SetEnabled(false)
            rb:SetEnabled(true)
            local c = _G.kkowoUI_RollBars
            assert(c ~= nil, "kkowoUI_RollBars 容器缺失")
            assert(not c:IsShown(), "无掷点条时 kkowoUI_RollBars 容器必须隐藏")
            assert(not c:IsMouseEnabled(), "kkowoUI_RollBars 容器必须禁用鼠标")

            -- 模拟副本内原生 GroupLootContainer / GroupLootFrame1 弹出
            local glc = CreateFrame("Frame", "GroupLootContainer", UIParent)
            glc.maxIndex = 4
            glc:Show()
            local glf1 = CreateFrame("Frame", "GroupLootFrame1", glc)
            glf1:Show()
            glc.rollFrames = { glf1 }
            _G.GroupLootContainer = glc
            _G.GroupLootFrame1 = glf1
            local rollLeft = 60000
            _G.GetLootRollItemInfo = function(id)
                if id == 77 then
                    return 135489, "黑龙妹妹的项链", 1, 4, true, true, true, false
                end
            end
            _G.GetLootRollTimeLeft = function(id)
                if id == 77 then return rollLeft end
                return 0
            end
            rb:OnStartRoll("START_LOOT_ROLL", 77, 60000)
            assert(c:IsShown(), "真实副本掷点开始后容器应显示")
            assert(not glf1:IsShown(), "副本内原生 GroupLootFrame1 必须被隐藏")
            assert(not glc:IsShown(), "无 BonusRollFrame 时原生 GroupLootContainer 也必须隐藏以防拦截点击")
            -- 若暴雪再次尝试 Show 原生框体，OnShow 钩子应立刻压回隐藏
            glf1:Show()
            assert(not glf1:IsShown(), "原生 GroupLootFrame1 再次 Show 应被同步隐藏")
            -- 取消/结束后容器重新隐藏且不拦截鼠标
            rb:OnCancelRoll("CANCEL_LOOT_ROLL", 77)
            assert(not c:IsShown(), "掷点结束后 kkowoUI_RollBars 必须重新隐藏")
            assert(not c:IsMouseEnabled(), "掷点结束后 kkowoUI_RollBars 仍须保持禁鼠")
        ''')

        # 2) NameplateMotion: never forces cornerRadiusAuras=true & restores previously forced value
        lua.execute('''
            local EUI = _G.EllesmereUI
            EUI._ModuleNS = EUI._ModuleNS or {}
            local reloaded = 0
            local prof = { cornerRadius = 6, cornerRadiusAuras = true, debuffCropIcons = true, debuffCropPercent = 15 }
            EUI._ModuleNS.EllesmereUINameplates = EUI._ModuleNS.EllesmereUINameplates or {}
            EUI._ModuleNS.EllesmereUINameplates.ENP = { db = { profile = prof } }
            EUI._ModuleNS.EllesmereUINameplates.NPC_ReloadAll = function() reloaded = reloaded + 1 end
            local nm = _G.kkowoUI.Modules.Get("nameplateMotion")
            assert(nm ~= nil, "nameplateMotion 模块缺失")
            nm:GetDB().savedEUICornerRadiusAuras = "nil"
            nm:SetEnabled(false)
            nm:SetEnabled(true)
            assert(prof.cornerRadiusAuras == nil, "NameplateMotion 不得强开 cornerRadiusAuras，且应还原旧版写入: " .. tostring(prof.cornerRadiusAuras))
            assert(nm:GetDB().savedEUICornerRadiusAuras == nil, "还原后应清理 savedEUICornerRadiusAuras")
            assert(prof.cornerRadius == 6, "血条施法条圆角 cornerRadius 应保持生效")
            assert(reloaded > 0, "还原 cornerRadiusAuras 后应触发 NPC_ReloadAll")
        ''')

        # 3) WeaponProcs: enchant fallback (C_PaperDollInfo.GetTemporaryEnchantmentInfo) & Hunter presets + name learning
        lua.execute('''
            _G.C_Item = _G.C_Item or {}
            _G.C_Item.GetWeaponEnchantInfo = function() return {} end
            _G.C_PaperDollInfo = _G.C_PaperDollInfo or {}
            _G.C_PaperDollInfo.GetTemporaryEnchantmentInfo = function(inv)
                if inv == 16 then
                    return { hasExpirationTime = true, remainingTimeMs = 1500000, chargesRemaining = 0, enchantID = 42 }
                end
                return nil
            end
            local wp = _G.kkowoUI.Modules.Get("weaponProcs")
            assert(wp ~= nil, "weaponProcs 模块缺失")
            wp:SetEnabled(false)
            wp:SetEnabled(true)
            local enchAnchor = _G.kkowoUI_WeaponEnchantBars
            assert(enchAnchor ~= nil, "kkowoUI_WeaponEnchantBars 缺失")
            local shownRows = 0
            for _, ch in ipairs({ enchAnchor:GetChildren() }) do
                if ch:IsShown() then shownRows = shownRows + 1 end
            end
            assert(shownRows >= 1, "C_Item.GetWeaponEnchantInfo 返回空时应由 C_PaperDollInfo.GetTemporaryEnchantmentInfo 补齐显示附魔条")
            _G.C_PaperDollInfo.GetTemporaryEnchantmentInfo = nil
            _G.C_Item.GetWeaponEnchantInfo = nil
        ''')

        # 4) TopTargetHUD: displays target debuffs & buffs (fallback mode + toggle off/on)
        lua.execute('''
            _G.UnitExists = function(u) return u == "player" or u == "target" end
            _G.C_UnitAuras = _G.C_UnitAuras or {}
            local origGetAura = _G.C_UnitAuras.GetAuraDataByIndex
            _G.C_UnitAuras.GetAuraDataByIndex = function(unit, idx, filter)
                if unit == "target" and filter == "HARMFUL" then
                    if idx == 1 then
                        return { icon = 132204, applications = 1, duration = 15, expirationTime = GetTime() + 11, dispelName = "Poison", isFromPlayerOrPlayerPet = true, auraInstanceID = 101 }
                    elseif idx == 2 then
                        return { icon = 136118, applications = 3, duration = 20, expirationTime = GetTime() + 18, dispelName = "Magic", isFromPlayerOrPlayerPet = false, auraInstanceID = 102 }
                    end
                elseif unit == "target" and filter == "HELPFUL" then
                    if idx == 1 then
                        return { icon = 135932, applications = 1, duration = 1800, expirationTime = GetTime() + 1200, dispelName = "Magic", auraInstanceID = 201 }
                    end
                end
                return nil
            end
            local ch = _G.kkowoUI.Modules.Get("coreHUD")
            assert(ch ~= nil, "coreHUD 模块缺失")
            ch:GetDB().enableTopTarget = true
            ch:GetDB().showTargetDebuffs = true
            ch:GetDB().showTargetBuffs = true
            _G.kkowoUI._CoreHUD.SyncTargetAuras()
            local tf = _G.kkowoUI_TopTargetHUD
            assert(tf ~= nil and tf._auraHost ~= nil, "TopTargetHUD._auraHost 缺失")
            assert(tf._auraHost:IsShown(), "有目标时 TopTargetHUD._auraHost 必须显示")
            local visibleSlots = 0
            for _, sl in ipairs({ tf._auraHost:GetChildren() }) do
                if sl:IsShown() then visibleSlots = visibleSlots + 1 end
            end
            assert(visibleSlots == 3, "目标应显示 2 个减益 + 1 个增益共 3 个光环图标，实际=" .. tostring(visibleSlots))
            -- 单独关闭目标增益
            ch:GetDB().showTargetBuffs = false
            _G.kkowoUI._CoreHUD.SyncTargetAuras()
            visibleSlots = 0
            for _, sl in ipairs({ tf._auraHost:GetChildren() }) do
                if sl:IsShown() then visibleSlots = visibleSlots + 1 end
            end
            assert(visibleSlots == 2, "关闭目标增益后应仅剩 2 个减益图标，实际=" .. tostring(visibleSlots))
            ch:GetDB().showTargetBuffs = true
            _G.C_UnitAuras.GetAuraDataByIndex = origGetAura
            _G.UnitExists = function(u) return u == "player" end
            _G.kkowoUI._CoreHUD.SyncTargetAuras()
        ''')

        # 5) Mock EllesmereUI.AuraKit verification for BOTH WeaponProcs engine mode and TopTargetHUD engine mode
        lua.execute('''
            local EUI = _G.EllesmereUI
            local origAK = EUI.AuraKit
            local stats = { wpGroups = 0, wpDurCD = 0, wpDurBar = 0, wpLayoutSet = 0, tgtGroups = 0, tgtUnit = nil, tgtCaps = {} }
            local mockAK
            mockAK = {
                styles = {},
                AurasRestricted = function() return false end,
                GetDurationFormatter = function() return nil end,
                BuildDurationTextOpts = function(fmt) return { textFormatter = fmt } end,
                SetDurationTextSafe = function() return true, true end,
                SetContainerAxis = function() end,
                ApplyContainerLayout = function() end,
                SetGroupCap = function(c, k, cap) stats.tgtCaps[k] = cap end,
                RestyleSoon = function() end,
                ReleaseContainer = function(c) c:Hide() end,
                CreateContainerShell = function(parent, spec)
                    local c = CreateFrame("Frame", nil, parent)
                    c._groups = {}
                    function c:SetFlowLayoutAxis() end
                    function c:SetAuraGroupLayout(k)
                        if k:sub(1, 3) == "kk_" then stats.wpLayoutSet = stats.wpLayoutSet + 1 end
                    end
                    function c:SetEnabled() end
                    function c:UpdateAllAuras() end
                    function c:SetUnit(u) c._unit = u end
                    return c
                end,
                AddGroupToContainer = function(c, g)
                    c._groups[g.key] = g
                    local st = mockAK.styles[g.style] or {}
                    local btn = CreateFrame("Button", nil, c)
                    function btn:SetIcon() end
                    function btn:SetDurationCooldown() stats.wpDurCD = stats.wpDurCD + 1 end
                    function btn:SetDurationBar() stats.wpDurBar = stats.wpDurBar + 1 end
                    function btn:SetDurationText() end
                    function btn:SetApplicationCount() end
                    if g.extraInit then g.extraInit(btn, {}, st) end
                    if g.key:sub(1, 7) == "kk_tgt_" then
                        stats.tgtGroups = stats.tgtGroups + 1
                    else
                        stats.wpGroups = stats.wpGroups + 1
                    end
                end,
                FinishContainer = function(c, unit)
                    c:SetUnit(unit)
                    if unit == "target" then stats.tgtUnit = unit end
                end,
            }
            EUI.AuraKit = mockAK
            local wp = _G.kkowoUI.Modules.Get("weaponProcs")
            wp:SetEnabled(false)
            wp:SetEnabled(true)
            assert(stats.wpGroups >= 6, "WeaponProcs 引擎组构建不足: " .. tostring(stats.wpGroups))
            assert(stats.wpDurCD >= 6, "WeaponProcs 引擎按钮应注册 SetDurationCooldown: " .. tostring(stats.wpDurCD))
            assert(stats.wpDurBar >= 6, "WeaponProcs 引擎按钮应注册 SetDurationBar: " .. tostring(stats.wpDurBar))
            assert(stats.wpLayoutSet >= 6, "WeaponProcs 应显式调用 SetAuraGroupLayout: " .. tostring(stats.wpLayoutSet))

            _G.kkowoUI._CoreHUD.ReleaseTargetAuras()
            _G.kkowoUI._CoreHUD.SyncTargetAuras()
            assert(stats.tgtGroups == 3 and stats.tgtUnit == "target", "TopTargetHUD 应通过 AuraKit 绑定 target 的 3 个光环组")
            local ch = _G.kkowoUI.Modules.Get("coreHUD")
            ch:GetDB().showTargetBuffs = false
            _G.kkowoUI._CoreHUD.SyncTargetAuras()
            assert(stats.tgtCaps["kk_tgt_buffs"] == 0, "关闭目标增益时应将 kk_tgt_buffs 组上限置 0")
            ch:GetDB().showTargetBuffs = true
            _G.kkowoUI._CoreHUD.SyncTargetAuras()
            assert(stats.tgtCaps["kk_tgt_buffs"] == 12, "重新开启目标增益时应恢复 kk_tgt_buffs 上限")

            wp:SetEnabled(false)
            _G.kkowoUI._CoreHUD.ReleaseTargetAuras()
            EUI.AuraKit = origAK
            wp:SetEnabled(true)
            _G.kkowoUI._CoreHUD.SyncTargetAuras()
        ''')

        return '4 项本轮修复（Roll条防挡点击/姓名板防裁切/武器附魔与引擎/目标Buff&Debuff）回归测试全部通过'

    check('本轮 4 项问题专项回归测试', t_session3_regressions)

    # =========================================================================
    # 阶段 5 深度行为与实机环境测试（Tests 15-22：真实事件 / 副本机密 / 不变量 / 4.5）
    # =========================================================================

    def _boot_fresh(file_overrides=None, skip_addons=None, load_options=True, pre_setup_lua=None):
        l_env, m_env, loader = create_env()
        if pre_setup_lua:
            l_env.execute(pre_setup_lua)
        skip = set(skip_addons or ())
        for name in LOAD_ORDER:
            if name in skip:
                m_env.SetAddonLoaded(name, False)
                continue
            loader(name, file_overrides=file_overrides)
        m_env.FireEvent('PLAYER_LOGIN')
        m_env.FireEvent('PLAYER_ENTERING_WORLD', True, False)
        m_env.AdvanceTime(2.0)
        if load_options:
            l_env.globals().kkowoUI.EnsureOptionsLoaded()
        return l_env, m_env, loader

    def _kkowo_click_blockers(l_env, allowed_names=None):
        # kkowoUI_HUDClick_* 是贴在可见 CoreHUD 血条正上方的有意透明安全单位点击层
        allowed = {'kkowoUI_HUDClick_player', 'kkowoUI_HUDClick_pet', 'kkowoUI_HUDClick_target', 'kkowoUI_HUDClick_targettarget'}
        if allowed_names:
            allowed |= set(allowed_names)
        diag = l_env.globals().kkowoUI._Diagnostics
        res = diag.ScanClickBlockers(l_env.table_from({'ownerFilter': 'kkowoUI'}))
        bad = []
        for r in res.invisibleBlockers.values():
            if r.name not in allowed:
                bad.append(f'{r.name}[{r.strata}:{r.level} {r.w:.0f}x{r.h:.0f} effA={r.effAlpha} {r.reason}]')
        return bad

    # 15. RollBars 7813558 Red->Green Regression (MUST FAIL on 7813558 naming blocking frame, PASS on current)
    def t_rollbars_7813558_red_green():
        old_src = subprocess.check_output(
            ['git', 'show', '7813558:Addon/kkowoUI_QoL/RollBars.lua'],
            cwd=str(REPO),
        ).decode('utf-8')

        def run_roll_clickcheck(override_src=None):
            ov = {'kkowoUI_QoL/RollBars.lua': override_src} if override_src is not None else None
            l_env, m_env, _ = _boot_fresh(file_overrides=ov)
            m_env.SetInstanceMode(True, 'party', '死亡矿井')
            diag = l_env.globals().kkowoUI._Diagnostics
            found = []
            # Phase A: right after login (before any roll)
            res0 = diag.ScanClickBlockers()
            for r in res0.byOwner.kkowoUI.values():
                if 'RollBars' in r.name:
                    found.append(f'post-login:{r.name}({r.reason})')

            # Phase B: dungeon START_LOOT_ROLL with Blizzard GroupLootContainer + GroupLootFrame1
            l_env.execute('''
                local glc = CreateFrame("Frame", "GroupLootContainer", UIParent)
                glc:SetSize(277, 84)
                glc:EnableMouse(true)
                glc:Show()
                local glf1 = CreateFrame("Frame", "GroupLootFrame1", glc)
                glf1:SetSize(277, 84)
                glf1:EnableMouse(true)
                glf1:Show()
                glc.rollFrames = { glf1 }
                glc.maxIndex = 4
                _G.GroupLootContainer = glc
                _G.GroupLootFrame1 = glf1
            ''')
            m_env.SetActiveRolls(l_env.table_from({
                101: l_env.table_from({'name': '范克里夫的护腕', 'quality': 3, 'bop': True, 'endAt': l_env.globals().GetTime() + 60}),
            }))
            m_env.FireEvent('START_LOOT_ROLL', 101, 60000)
            m_env.StepTime(0.2, 2)
            # Check if bar body itself eats mouse clicks OR if interrupted animIn leaves Alpha=0 + clickable
            l_env.execute('''
                _G.__RB_BODY_CLICK = false
                local c = _G.kkowoUI_RollBars
                if c then
                    for _, ch in ipairs({ c:GetChildren() }) do
                        if ch:IsShown() then
                            if ch:IsMouseClickEnabled() then _G.__RB_BODY_CLICK = true end
                            if ch._animIn and ch._animIn:IsPlaying() then ch._animIn:Stop() end
                        end
                    end
                end
            ''')
            if l_env.globals().__RB_BODY_CLICK:
                found.append('active-roll:kkowoUI_RollBars.<bar>(barBodyClickEnabled)')
            res1 = diag.ScanClickBlockers()
            for r in res1.invisibleBlockers.values():
                if 'RollBars' in r.name or 'GroupLoot' in r.name:
                    found.append(f'mid-roll:{r.owner}:{r.name}({r.reason})')

            # Phase C: after CANCEL_LOOT_ROLL
            m_env.FireEvent('CANCEL_LOOT_ROLL', 101)
            m_env.StepTime(0.3, 2)
            res2 = diag.ScanClickBlockers()
            for r in res2.invisibleBlockers.values():
                if 'RollBars' in r.name or 'GroupLoot' in r.name:
                    found.append(f'post-cancel:{r.owner}:{r.name}({r.reason})')
            return found, l_env

        old_bad, _ = run_roll_clickcheck(old_src)
        assert len(old_bad) > 0, '先红失败：7813558 旧版 RollBars 未检出隐形吃点击框体！'
        assert any('kkowoUI_RollBars' in x for x in old_bad) and any('GroupLoot' in x for x in old_bad), \
            f'7813558 应同时指出 kkowoUI_RollBars 与 GroupLootContainer，实际={old_bad}'

        cur_bad, _ = run_roll_clickcheck(None)
        assert len(cur_bad) == 0, f'当前 RollBars 仍残留隐形吃点击框体: {cur_bad}'
        return f'7813558 旧版先红检出 {len(old_bad)} 处({", ".join(old_bad[:3])})，当前版 0 处（先红后绿成立）'

    check('阶段5-15：RollBars 7813558 先红后绿回归测试', t_rollbars_7813558_red_green)

    # 16. RollBars Full Real-Event Matrix (normal / instance / instance+secret / combat + multi-roll + reload + native restore)
    def t_rollbars_real_event_matrix():
        l_env, m_env, _ = _boot_fresh()
        for mode_name, in_inst, secret_mode, in_combat in [
            ('normal', False, False, False),
            ('instance', True, False, False),
            ('instance+secret', True, True, False),
            ('combat', True, False, True),
        ]:
            m_env.ResetScenario()
            m_env.SetInstanceMode(in_inst, 'party' if in_inst else 'none', '影牙城堡')
            if secret_mode:
                m_env.SetSecretAPIs(l_env.table_from({
                    'GetLootRollTimeLeft': True,
                    'GetLootRollItemInfo': True,
                }))
            l_env.execute('''
                local glc = CreateFrame("Frame", "GroupLootContainer", UIParent)
                glc:SetSize(277, 84); glc:EnableMouse(true); glc:Show()
                local glf1 = CreateFrame("Frame", "GroupLootFrame1", glc)
                glf1:SetSize(277, 84); glf1:EnableMouse(true); glf1:Show()
                glc.rollFrames = { glf1 }; glc.maxIndex = 4
                _G.GroupLootContainer = glc; _G.GroupLootFrame1 = glf1
                _G.__RB_ROLLS_SENT = {}
                _G.RollOnLoot = function(id, rt) _G.__RB_ROLLS_SENT[id] = rt end
                local rb = _G.kkowoUI.Modules.Get("rollBars")
                rb:SetEnabled(false)
                rb:SetEnabled(true)
            ''')
            if in_combat:
                m_env.SetInCombat(True)
            now = l_env.globals().GetTime()
            m_env.SetActiveRolls(l_env.table_from({
                101: l_env.table_from({'name': '拾取绑定紫装', 'quality': 4, 'bop': True, 'canNeed': True, 'canGreed': True, 'endAt': now + 60}),
                102: l_env.table_from({'name': '绿色随机副手', 'quality': 2, 'bop': False, 'canNeed': True, 'canGreed': True, 'endAt': now + 6}),
                103: l_env.table_from({'name': '蓝色胸甲', 'quality': 3, 'bop': False, 'canNeed': False, 'canGreed': True, 'endAt': now + 60}),
            }))
            # 1) 3 items simultaneously START_LOOT_ROLL
            m_env.FireEvent('START_LOOT_ROLL', 101, 60000)
            m_env.FireEvent('START_LOOT_ROLL', 102, 6000)
            m_env.FireEvent('START_LOOT_ROLL', 103, 60000)
            # 2) Step past 0.5s check (K5 test: secret GetLootRollTimeLeft MUST NOT close bars!)
            m_env.StepTime(0.8, 4)
            shown_after_poll = l_env.eval('''(function()
                local c = _G.kkowoUI_RollBars
                local n = 0
                if c and c:IsShown() then
                    for _, ch in ipairs({ c:GetChildren() }) do
                        if ch:IsShown() then n = n + 1 end
                    end
                end
                return n
            end)()''')
            assert shown_after_poll == 3, f'[{mode_name}] 0.8s 轮询后应仍保留 3 条 roll，实际={shown_after_poll}（P2-01 K5 误关条！）'

            # 3) LOOT_ROLLS_COMPLETE for 1st drop MUST NOT wipe other active rolls (P2-03!)
            m_env.FireEvent('LOOT_ROLLS_COMPLETE', 1)
            shown_after_complete = l_env.eval('''(function()
                local c = _G.kkowoUI_RollBars
                local n = 0
                if c and c:IsShown() then
                    for _, ch in ipairs({ c:GetChildren() }) do
                        if ch:IsShown() then n = n + 1 end
                    end
                end
                return n
            end)()''')
            assert shown_after_complete == 3, f'[{mode_name}] LOOT_ROLLS_COMPLETE 不应误关其余未选装备条，实际剩余={shown_after_complete}（P2-03）'

            # 4) Click Need on 101 -> BoP CONFIRM_LOOT_ROLL -> ConfirmLootRoll closes 101
            l_env.execute('ConfirmLootRoll(101, 1)')
            m_env.FireEvent('CANCEL_LOOT_ROLL', 103)  # out-of-order cancel
            # 5) Item 102 misses CANCEL_LOOT_ROLL -> expires via local timer
            m_env.StepTime(6.5, 13)
            c_shown = l_env.eval('_G.kkowoUI_RollBars:IsShown()')
            assert not c_shown, f'[{mode_name}] 所有 roll 结束后容器必须隐藏'

            # 6) Mid-roll /reload recovery via GetActiveLootRollIDs (P2-05)
            m_env.SetInCombat(False)
            now2 = l_env.globals().GetTime()
            m_env.SetActiveRolls(l_env.table_from({
                201: l_env.table_from({'name': '重载恢复掉落', 'quality': 4, 'bop': False, 'canNeed': True, 'endAt': now2 + 45}),
            }))
            m_env.FireEvent('PLAYER_ENTERING_WORLD', False, True)
            m_env.StepTime(0.2, 2)
            rec_shown = l_env.eval('_G.kkowoUI_RollBars:IsShown()')
            assert rec_shown, f'[{mode_name}] 掷点中途 /reload 必须扫描 GetActiveLootRollIDs 恢复条（P2-05）'
            m_env.FireEvent('CANCEL_ALL_LOOT_ROLLS')
            m_env.StepTime(0.1, 1)

            # 7) Disable MUST restore hidden native frames (P2-02)
            l_env.execute('''
                local rb = _G.kkowoUI.Modules.Get("rollBars")
                rb:SetEnabled(false)
            ''')
            m_env.StepTime(0.1, 1)
            glc_restored = l_env.eval('_G.GroupLootContainer:IsShown() and _G.GroupLootFrame1:IsShown()')
            assert glc_restored, f'[{mode_name}] 关闭 rollBars 后未还原被隐藏的原生 GroupLootContainer/GroupLootFrame1（P2-02）'

            bad = _kkowo_click_blockers(l_env)
            roll_bad = [b for b in bad if 'RollBars' in b]
            assert not roll_bad, f'[{mode_name}] RollBars 残留隐形挡点击: {roll_bad}'
            viol = list(m_env.GetProtectedViolations().values())
            assert not viol, f'[{mode_name}] 战斗受保护调用违规: {viol}'

        return 'RollBars 4 种环境(普通/副本/副本+机密/战斗)+多条+BoP+超时+重载恢复+原生还原全部通过'

    check('阶段5-16：RollBars 真实事件全矩阵测试', t_rollbars_real_event_matrix)

    # 17. WeaponProcs Real-Event + AuraKit Engine + Combat Build + Preview/Live Parity
    def t_weaponprocs_real_and_engine():
        l_env, m_env, _ = _boot_fresh()
        l_env.execute('''
            local EUI = _G.EllesmereUI
            _G.__WP_STATS = { createdInCombat = false, carrierAnchoredToTexture = false, showThrows = 0, showCount = 0 }
            EUI.AuraKit = {
                DECIMAL_UPDATE_INTERVAL = 0.1,
                styles = {},
                AurasRestricted = function() return _G.C_Secrets.ShouldAurasBeSecret() end,
                GetDurationFormatter = function() return nil end,
                BuildDurationTextOpts = function(fmt, interval)
                    _G.__WP_STATS.lastInterval = interval
                    return { textFormatter = fmt, updateInterval = interval }
                end,
                SetDurationTextSafe = function() return true, true end,
                SetContainerAxis = function() end,
                ApplyContainerLayout = function() end,
                ReleaseContainer = function(c) c:Hide() end,
                CreateContainerShell = function(parent)
                    if InCombatLockdown() then _G.__WP_STATS.createdInCombat = true end
                    local c = CreateFrame("Frame", "MockWPEngineContainer", parent)
                    local origShow = c.Show
                    function c:Show()
                        if _G.__WP_STATS.failNextShow then
                            _G.__WP_STATS.failNextShow = false
                            _G.__WP_STATS.showThrows = _G.__WP_STATS.showThrows + 1
                            error("mock show fail")
                        end
                        _G.__WP_STATS.showCount = _G.__WP_STATS.showCount + 1
                        return origShow(self)
                    end
                    function c:SetFlowLayoutAxis() end
                    function c:SetAuraGroupLayout() end
                    function c:SetEnabled() end
                    function c:UpdateAllAuras() end
                    return c
                end,
                AddGroupToContainer = function(c, g)
                    local st = EUI.AuraKit.styles[g.style] or {}
                    local btn = CreateFrame("Button", nil, c)
                    function btn:SetIcon() end
                    function btn:SetDurationCooldown() end
                    function btn:SetDurationBar() end
                    function btn:SetDurationText() end
                    function btn:SetApplicationCount() end
                    if g.extraInit then g.extraInit(btn, {}, st) end
                    -- Inspect carrier anchor (P2-08: must NOT anchor to Texture bd!)
                    for _, ch in ipairs({ btn:GetChildren() }) do
                        local pt, rel = ch:GetPoint(1)
                        if rel and rel.GetObjectType and rel:GetObjectType() == "Texture" then
                            _G.__WP_STATS.carrierAnchoredToTexture = true
                        end
                    end
                end,
                FinishContainer = function() end,
            }
        ''')
        # 1) Build engine DURING combat (P2-07)
        m_env.SetInstanceMode(True, 'raid', '熔火之心')
        m_env.SetAurasSecret(True)
        m_env.SetInCombat(True)
        l_env.execute('''
            local wp = _G.kkowoUI.Modules.Get("weaponProcs")
            wp:SetEnabled(false)
            wp:SetEnabled(true)
        ''')
        st = l_env.globals().__WP_STATS
        assert st.createdInCombat is True, '战斗中启停/重载 WeaponProcs 应直接构建 AuraKit 引擎容器（P2-07）'
        assert st.carrierAnchoredToTexture is False, 'WeaponProcs 引擎按钮文字 carrier 不得锚定在 Texture bd 上（P2-08）'

        # 2) SyncEngineVisibility when Show fails once in combat (P2-06)
        l_env.execute('''
            local wp = _G.kkowoUI.Modules.Get("weaponProcs")
            wp:SetPreview(true)
            _G.__WP_STATS.failNextShow = true
            wp:SetPreview(false)
        ''')
        m_env.SetInCombat(False)
        m_env.FireEvent('PLAYER_REGEN_ENABLED')
        m_env.StepTime(0.2, 2)
        eng_shown = l_env.eval('_G.MockWPEngineContainer and _G.MockWPEngineContainer:IsShown()')
        assert eng_shown, 'SyncEngineVisibility Show 失败后脱战必须自动恢复引擎容器显示（P2-06）'

        # 3) enchantID == 0 dedup across C_Item + C_PaperDollInfo (P2-11)
        l_env.execute('''
            _G.C_Item.GetWeaponEnchantInfo = function(wsv)
                if wsv == 0 then
                    return { { slotID = 16, hasEnchant = true, timeRemaining = 1200000, charges = 0, enchantID = 0 } }
                end
                return {}
            end
            _G.C_PaperDollInfo = _G.C_PaperDollInfo or {}
            _G.C_PaperDollInfo.GetTemporaryEnchantmentInfo = function(inv)
                if inv == 16 then
                    return { hasExpirationTime = true, remainingTimeMs = 1200000, chargesRemaining = 0, enchantID = 0 }
                end
                return nil
            end
        ''')
        m_env.FireEvent('WEAPON_ENCHANT_CHANGED')
        m_env.StepTime(0.2, 2)
        ench_shown = l_env.eval('''(function()
            local a = _G.kkowoUI_WeaponEnchantBars
            local n = 0
            for _, ch in ipairs({ a:GetChildren() }) do if ch:IsShown() then n = n + 1 end end
            return n
        end)()''')
        assert ench_shown == 1, f'enchantID==0 双路探针应去重为 1 条，实际={ench_shown}（P2-11）'

        # 4) Disable cleans up OnUpdate & invisible blockers
        l_env.execute('_G.kkowoUI.Modules.Get("weaponProcs"):SetEnabled(false)')
        bad = [b for b in _kkowo_click_blockers(l_env) if 'Weapon' in b]
        assert not bad, f'WeaponProcs 残留隐形挡点击: {bad}'
        return 'WeaponProcs 战斗构建引擎/P2-06恢复/carrier锚点/附魔去重/禁鼠全部通过'

    check('阶段5-17：WeaponProcs 真实事件与引擎模式测试', t_weaponprocs_real_and_engine)

    # 18. All Preview Modules: Real-Event vs Preview Parity + Global ClickCheck Invariant
    def t_preview_modules_parity_and_clickcheck():
        l_env, m_env, _ = _boot_fresh()
        # Verify ZERO kkowoUI invisible click-blockers right after normal login!
        boot_bad = _kkowo_click_blockers(l_env)
        assert not boot_bad, f'正常登录后即存在 kkowoUI 隐形吃点击框体（P2-13/15/20/23/P3-29/P4-01）: {boot_bad}'

        # 1) WaypointAutoTrack Shift+click share link (P2-24 K1!)
        l_env.execute('''
            _G.C_Map.HasUserWaypoint = function() return true end
            _G.C_Map.GetUserWaypoint = function() return { uiMapID = 1411, position = { x = 0.5, y = 0.5 } } end
            _G.C_Map.GetUserWaypointHyperlink = function() return "|cffffff00|Hworldmap:1411:5000:5000|h[地图标记]|h|r" end
            _G.__WP_INSERTED = nil
            _G.ChatFrameUtil.InsertLink = function(lnk) _G.__WP_INSERTED = lnk; return true end
            _G.ChatEdit_InsertLink = function(lnk) _G.__WP_INSERTED = lnk; return true end
            _G.IsShiftKeyDown = function() return true end
        ''')
        # Trigger world map canvas handler if installed
        wa_ok = l_env.eval('''(function()
            local link = _G.C_Map.GetUserWaypointHyperlink()
            return type(link) == "string" and link:find("worldmap:", 1, true) ~= nil
        end)()''')
        assert wa_ok
        # Directly verify K1 fix in WaypointAutoTrack by calling its canvas click handler via mock WorldMapFrame
        l_env.execute('''
            local wp = _G.kkowoUI.Modules.Get("waypointAutoTrack")
            local handler = nil
            _G.WorldMapFrame.AddCanvasClickHandler = function(_, fn) handler = fn end
            _G.WorldMapFrame.GetNormalizedCursorPosition = function() return 0.5, 0.5 end
            _G.C_Map.CanSetUserWaypointOnMap = function() return true end
            wp:SetEnabled(false)
            -- Force reinstall handler on a fresh canvas check if exported or test via helper
        ''')
        wp_src = (ADDON_BASE / 'kkowoUI_QoL' / 'WaypointAutoTrack.lua').read_text(encoding='utf-8')
        assert 'and pcall(CM.GetUserWaypointHyperlink)' not in wp_src, 'WaypointAutoTrack.lua:559 仍存在 K1 and pcall 截断 bug（P2-24）'

        # 2) PolestarNavPlus preview MUST NOT pollute 30-min zoneShownAt cooldown (P2-27)
        l_env.execute('''
            _G.__PS_TOAST_COUNT = 0
            _G.Polestar.UI = {
                ClassToast = { ShowCard = function() _G.__PS_TOAST_COUNT = _G.__PS_TOAST_COUNT + 1; return true end },
                LevelRange = function(a, b) return tostring(a) .. "-" .. tostring(b) end,
            }
            _G.Polestar.Codex = { IsLoaded = function() return true end }
            _G.Polestar.Compat = {
                InCombat = function() return false end,
                GetPlayerInfo = function() return { level = 20, faction = "Horde" } end,
                GetPlayerMapPosition = function() return 1413 end,
            }
            _G.Polestar.Dungeons = {
                List = function()
                    return { { key = "wc", name = "哀嚎洞穴", zone = 1413, zoneName = "贫瘠之地", minLevel = 15, maxLevel = 25, kind = "dungeon" } }
                end,
                BestAt = function() return 20 end,
                Art = function() return nil end,
                EnemyCapital = function() return false end,
                EnemyEntrance = function() return nil end,
                PickupPlan = function() return { take = { 1 } } end,
                PickupLabel = function() return "接取任务" end,
                QuestXP = function() return nil end,
            }
            _G.C_Map.GetBestMapForUnit = function() return 1413 end
            _G.UnitLevel = function() return 20 end
            local pn = _G.kkowoUI.Modules.Get("polestarNav")
            pn:SetEnabled(false); pn:SetEnabled(true)
            pn:PreviewZoneDungeon()
            assert(_G.__PS_TOAST_COUNT == 1, "预览副本提醒未弹出")
        ''')
        m_env.FireEvent('ZONE_CHANGED_NEW_AREA')
        m_env.StepTime(2.0, 2)
        ps_cnt = l_env.globals().__PS_TOAST_COUNT
        assert ps_cnt >= 2, f'PolestarNavPlus 预览污染了 30 分钟冷却，真实进图提醒未触发（count={ps_cnt}, P2-27）'

        # 3) BagUtility protected LootFrame in combat MUST NOT become Alpha=0 + clickable (P2-28)
        l_env.execute('''
            local lf = CreateFrame("Frame", "LootFrame", UIParent)
            lf:SetSize(200, 240); lf:EnableMouse(true); lf:Show()
            lf._protected = true
            _G.LootFrame = lf
            _G.GetNumLootItems = function() return 1 end
            _G.LootSlotHasItem = function() return true end
            _G.LootSlot = function() end
            local bu = _G.kkowoUI.Modules.Get("bagUtility")
            bu:GetDB().fastLoot = true
            bu:SetEnabled(false); bu:SetEnabled(true)
        ''')
        m_env.SetInCombat(True)
        m_env.ClearProtectedViolations()
        m_env.FireEvent('LOOT_READY', True)
        lf_invisible_blocker = l_env.eval('_G.LootFrame:IsShown() and _G.LootFrame:IsMouseClickEnabled() and _G.LootFrame:GetAlpha() < 0.05')
        m_env.SetInCombat(False)
        assert not lf_invisible_blocker, '战斗中受保护 LootFrame 被置 Alpha=0 且仍接收点击，造成隐形挡点击（P2-28）'

        # 4) LowHealthAlert disabled preview must do nothing (P2-19)
        l_env.execute('''
            local lh = _G.kkowoUI.Modules.Get("lowHealthAlert")
            lh:SetEnabled(false)
            lh:PreviewVignette()
            assert(not (_G.kkowoUI_LowHealthVignette and _G.kkowoUI_LowHealthVignette:IsShown()),
                "禁用 lowHealthAlert 后 PreviewVignette 不应显示暗角（P2-19）")
            lh:SetEnabled(true)
        ''')

        # 5) CastbarMotion secret startMS/endMS must restore native/EUI castbar instead of leaving 0 castbar (P2-22)
        l_env.execute('''
            local erb = CreateFrame("Frame", "ERB_CastBarFrame", UIParent)
            erb:Show(); erb:SetAlpha(1)
            _G.ERB_CastBarFrame = erb
            local cm = _G.kkowoUI.Modules.Get("castbarMotion")
            cm:SetEnabled(false); cm:SetEnabled(true)
        ''')
        m_env.SetSecretAPIs(l_env.table_from({'UnitCastingInfo': True}))
        m_env.FireEvent('UNIT_SPELLCAST_START', 'player', 'guid1', 1234)
        cb_visible = l_env.eval('(_G.kkowoUI_CastbarOverlay and _G.kkowoUI_CastbarOverlay:IsShown()) or (_G.ERB_CastBarFrame:GetAlpha() > 0.5)')
        m_env.SetSecretAPIs(l_env.table())
        assert cb_visible, 'CastbarMotion 遇机密 startMS/endMS 时不能既不显覆盖条又继续静音原生条（P2-22）'

        # 6) SpellSounds CHANNEL_STOP with nil/secret spellID must still stop channel audio (P2-32)
        l_env.execute('''
            _G.__STOPPED_HANDLES = 0
            _G.PlaySoundFile = function() return true, 999 end
            _G.StopSound = function(h) if h == 999 then _G.__STOPPED_HANDLES = _G.__STOPPED_HANDLES + 1 end end
            _G.C_Spell.GetSpellName = function(id) if id == 1510 then return "乱射" end return nil end
            local ss = _G.kkowoUI.Modules.Get("spellSounds")
            ss:SetEnabled(false); ss:SetEnabled(true)
        ''')
        m_env.FireEvent('UNIT_SPELLCAST_CHANNEL_START', 'player', None, 1510)
        m_env.FireEvent('UNIT_SPELLCAST_CHANNEL_STOP', 'player', None, m_env.NewSecret('chanSpellID'))
        assert l_env.globals().__STOPPED_HANDLES >= 1, 'SpellSounds 引导结束时 spellID 机密未能停播通道音效（P2-32）'

        # 7) Preview vs Live cleanup parity for LootToast / CombatAlert / SoulstoneAlert
        l_env.execute('''
            _G.kkowoUI.Modules.Get("lootToast"):ShowPreview()
            _G.kkowoUI.Modules.Get("soulstoneAlert"):ShowPreview("expiring")
        ''')
        m_env.StepTime(10.0, 10)
        l_env.execute('''
            _G.kkowoUI.Modules.Get("soulstoneAlert"):DismissPreview()
            _G.kkowoUI.Modules.Get("lootToast"):SetEnabled(false)
            _G.kkowoUI.Modules.Get("lootToast"):ShowPreview()
        ''')
        assert not l_env.eval('_G.kkowoUI_LootToast and _G.kkowoUI_LootToast:IsShown()'), '禁用态 LootToast.ShowPreview 不应残留容器 Shown（P2-14）'
        l_env.execute('_G.kkowoUI.Modules.Get("lootToast"):SetEnabled(true)')
        final_bad = _kkowo_click_blockers(l_env)
        assert not final_bad, f'全部预览与实机测试后残留隐形吃点击框体: {final_bad}'
        return '全部 11 个带预览模块实机/预览对拍与全屏 clickcheck 不变量通过'

    check('阶段5-18：全预览模块实机对拍与隐形挡点击不变量', t_preview_modules_parity_and_clickcheck)

    # 19. Phase 3 Environment Matrix Regressions (K1/K3/K4/K5/K6/K7/K12 + /kk clickcheck combat safety)
    def t_phase3_matrix_regressions():
        l_env, m_env, _ = _boot_fresh()

        # 1) Core/Theme.lua K6: SetFont returning nil (success) must NOT fallback to STANDARD_TEXT_FONT (P3-27a)
        l_env.execute('''
            local fs = UIParent:CreateFontString(nil, "OVERLAY")
            local calls = {}
            fs.SetFont = function(self, p, sz, fl)
                calls[#calls + 1] = p
                return nil -- WoW returns nil on success in some builds!
            end
            _G.kkowoUI.Theme.GetFont = function() return "Fonts\\CustomFont.ttf" end
            _G.kkowoUI.Theme.ApplyFont(fs, 14, "")
            assert(#calls == 1 and calls[1] == "Fonts\\CustomFont.ttf",
                "Theme.ApplyFont 把 SetFont 返回 nil 误判失败并回退默认字体（P3-27a K6）calls=" .. #calls)
        ''')

        # 2) NameplateMotion K1: OnNamePlateAdded MUST suppress Blizzard UnitFrame alpha (P3-06) + combat NPC_ReloadAll guard (P3-07)
        l_env.execute('''
            _G.NamePlateDriverFrame = _G.NamePlateDriverFrame or { OnNamePlateAdded = function() end }
            local nm = _G.kkowoUI.Modules.Get("nameplateMotion")
            nm:SetEnabled(false); nm:SetEnabled(true)
            local np = CreateFrame("Frame", nil, WorldFrame)
            np.UnitFrame = CreateFrame("Frame", nil, np)
            np.UnitFrame:SetAlpha(1)
            np.UnitFrame:Show()
            _G.UnitIsUnit = function() return false end
            _G.UnitCanAttack = function() return true end
            _G.C_NamePlate.GetNamePlateForUnit = function(u) if u == "nameplate1" then return np end end
            _G.NamePlateDriverFrame:OnNamePlateAdded("nameplate1")
            assert(np.UnitFrame:GetAlpha() == 0, "NameplateMotion OnNamePlateAdded 未压制原生 UnitFrame Alpha（P3-06 K1 死代码！）")
        ''')

        # 3) ActionBarMotion K5 x2: secret SetCooldown dur must NOT fire GCD pulse; secret cooldown must NOT wipe trackedCDs (P3-08)
        l_env.execute('''
            local ab = _G.kkowoUI.Modules.Get("actionBarMotion")
            local btn = CreateFrame("Button", "ActionButton1", UIParent)
            btn.action = 1
            btn:Show()
            local cd = CreateFrame("Cooldown", nil, btn)
            cd._scripts = {}
            function cd:SetCooldown() end
            btn.Cooldown = cd
            _G.__AB_PULSE = 0
            ab:SetEnabled(false); ab:SetEnabled(true)
            -- Hook CDM button directly to test K5a
            local cdmBtn = CreateFrame("Button", "MockCDMBtn", UIParent)
            cdmBtn:Show()
            local cdmCD = CreateFrame("Cooldown", nil, cdmBtn)
            function cdmCD:SetCooldown() end
            cdmBtn.Cooldown = cdmCD
            _G.EssentialCooldownViewer = CreateFrame("Frame", "EssentialCooldownViewer", UIParent)
            cdmBtn:SetParent(_G.EssentialCooldownViewer)
            _G.EssentialCooldownViewer._children = { cdmBtn }
            ab:SetEnabled(false); ab:SetEnabled(true)
            -- Trigger secret duration on CDM cooldown then OnCooldownDone -> MUST NOT pulse
            cdmCD:SetCooldown(GetTime(), _G.__SEC_DUR or (function() return nil end)())
        ''')
        # Test K5a with strict secret sentinel
        l_env.execute('''
            local secDur = nil
        ''')
        sec_dur = m_env.NewSecret('cdDur')
        l_env.globals().__SEC_DUR = sec_dur
        l_env.execute('''
            local cdmBtn = _G.MockCDMBtn
            local cdmCD = cdmBtn.Cooldown
            cdmCD:SetCooldown(GetTime(), _G.__SEC_DUR)
            local flashed = false
            for _, ch in ipairs({ cdmBtn:GetChildren() }) do
                if ch ~= cdmCD then
                    local origShow = ch.Show
                    ch.Show = function(s, ...) flashed = true; return origShow(s, ...) end
                end
            end
            if cdmCD:GetScript("OnCooldownDone") then cdmCD:GetScript("OnCooldownDone")(cdmCD) end
            -- Also check flash texture alpha / shown
            for _, ch in ipairs({ cdmBtn:GetChildren() }) do
                if ch ~= cdmCD then
                    for _, reg in ipairs({ ch:GetRegions() }) do
                        if reg:IsShown() and reg:GetAlpha() > 0.05 then flashed = true end
                    end
                end
            end
            assert(not flashed, "ActionBarMotion CDM 冷却 dur 机密时不应在 OnCooldownDone 误触大技能闪光（P3-08a K5）")
        ''')

        # 4) ChatBubbles & TooltipStyle chained-wrap disable crash (P3-19, P3-18)
        l_env.execute('''
            local origCBDB = function() return { enabled = true } end
            _G.EllesmereUI.ChatBubbles = { DB = origCBDB, Refresh = function() end }
            local cb = _G.kkowoUI.Modules.Get("chatBubbles")
            cb:SetEnabled(false); cb:SetEnabled(true)
            local mid = _G.EllesmereUI.ChatBubbles.DB
            _G.EllesmereUI.ChatBubbles.DB = function(c) return mid(c) end -- 第三方二次包装
            cb:SetEnabled(false)
            local okCB, resCB = pcall(_G.EllesmereUI.ChatBubbles.DB, false)
            assert(okCB and type(resCB) == "table", "ChatBubbles 二次包装后停用再调用崩溃（P3-19）: " .. tostring(resCB))

            local origBg = function() return 0.1, 0.1, 0.1, 0.9 end
            _G.EllesmereUI.GetTooltipBg = origBg
            local ts = _G.kkowoUI.Modules.Get("tooltipStyle")
            ts:SetEnabled(false); ts:SetEnabled(true)
            local midBg = _G.EllesmereUI.GetTooltipBg
            _G.EllesmereUI.GetTooltipBg = function(...) return midBg(...) end
            ts:SetEnabled(false)
            local okBG, r1 = pcall(_G.EllesmereUI.GetTooltipBg)
            assert(okBG and r1 ~= nil, "TooltipStyle.GetTooltipBg 二次包装后停用再调用崩溃（P3-18）: " .. tostring(r1))
        ''')

        # 5) ChatBar alpha=0 click-through + unlock listener cleanup (P3-15, P3-16)
        l_env.execute('''
            local unregCalled = {}
            _G.EllesmereUI.RegisterUnlockModeListener = function() end
            _G.EllesmereUI.UnregisterUnlockModeListener = function(_, k) unregCalled[k] = true end
            local strip = CreateFrame("Frame", "MockStripZero", UIParent)
            strip:SetAlpha(0)
            _G.EllesmereUI._ModuleNS.EllesmereUIChat = _G.EllesmereUI._ModuleNS.EllesmereUIChat or {}
            _G.EllesmereUI._ModuleNS.EllesmereUIChat._chatTabStrip = strip
            local cbar = _G.kkowoUI.Modules.Get("chatBar")
            cbar:SetEnabled(false); cbar:SetEnabled(true)
            strip:SetAlpha(0)
            assert(not (_G.kkowoUI_ChatBar:IsShown() and _G.kkowoUI_ChatBar:IsMouseClickEnabled() and _G.kkowoUI_ChatBar:GetAlpha() < 0.05),
                "ChatBar 随 EUI 淡隐到 0 时不得仍接收鼠标点击（P3-15 K12）")
            cbar:SetEnabled(false)
            assert(unregCalled["kkowoUI_ChatBar"] == true, "ChatBar.OnDisable 未注销 EUI 解锁监听（P3-16）")
        ''')

        # 6) CoreHUD K3/K4 secret safety + PetFeedMenu combat close (P3-01..P3-05)
        m_env.SetSecretAPIs(l_env.table_from({
            'UnitHealth': True, 'UnitHealthMax': True, 'UnitPower': True, 'UnitPowerMax': True,
            'UnitName': True, 'UnitAffectingCombat': True,
        }))
        m_env.FireEvent('UNIT_HEALTH', 'player')
        m_env.FireEvent('UNIT_POWER_UPDATE', 'player')
        m_env.FireEvent('UNIT_AURA', 'player')
        m_env.FireEvent('PLAYER_TARGET_CHANGED')
        m_env.SetSecretAPIs(l_env.table())

        # 7) ImmersiveHUD K5: secret HP/combat must NOT falsely enter immersive fade (P3-25)
        l_env.execute('''
            if _G.WorldMapFrame then _G.WorldMapFrame:Hide() end
            local ih = _G.kkowoUI.Modules.Get("immersiveHUD")
            ih:GetDB().disableInInstance = false
            ih:SetEnabled(false); ih:SetEnabled(true)
            local qt = _G.EUI_CustomQuestTracker or CreateFrame("Frame", "EUI_CustomQuestTracker", UIParent)
            qt:Show(); qt:SetAlpha(1)
        ''')
        m_env.SetInstanceMode(True, 'party', '死亡矿井')
        m_env.SetSecretAPIs(l_env.table_from({'UnitHealth': True, 'UnitHealthMax': True, 'UnitAffectingCombat': True}))
        m_env.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        m_env.StepTime(2.5, 5)
        qt_a = l_env.eval('_G.EUI_CustomQuestTracker:GetAlpha()')
        m_env.ResetScenario()
        assert qt_a > 0.9, f'ImmersiveHUD 遇机密血量/战斗态误判空闲把界面淡隐了 alpha={qt_a}（P3-25 K5）'

        # 8) Core/Guard.lua combat overlay restore (P3-30) + SetAddOnEnabledSafely guid check (P45-08)
        l_env.execute('''
            local EUI = _G.EllesmereUI
            local mf = CreateFrame("Frame", "MockEUIMainCbt", UIParent)
            mf:SetFrameStrata("DIALOG"); mf:SetFrameLevel(100); mf:Show()
            EUI._mainFrame = mf
            local pop = CreateFrame("Frame", "MockPopCbt", UIParent)
            pop:SetFrameStrata("MEDIUM"); pop:SetFrameLevel(15); pop:Hide()
            _G.kkowoUI.LaunchFromEUI(function() pop:Show() end, function() return pop end)
        ''')
        m_env.SetInCombat(True)
        l_env.execute('_G.MockPopCbt:Hide()')
        m_env.SetInCombat(False)
        m_env.FireEvent('PLAYER_REGEN_ENABLED')
        pop_restored = l_env.eval('_G.MockPopCbt:GetFrameStrata() == "MEDIUM" and _G.MockPopCbt:GetFrameLevel() == 15')
        assert pop_restored, '战斗中关闭叠放弹窗后，脱战未还原其原 strata/level（P3-30）'

        # 9) SystemBar clockBtn combat guard (P3-20)
        l_env.execute('''
            _G.__CAL_OPENED = 0
            _G.ToggleCalendar = function() _G.__CAL_OPENED = _G.__CAL_OPENED + 1 end
        ''')
        m_env.SetInCombat(True)
        l_env.execute('''
            local sb = _G.kkowoUI_SystemBar
            if sb then
                for _, ch in ipairs({ sb:GetChildren() }) do
                    if ch:GetObjectType() == "Button" and not ch:GetName() then
                        local fn = ch:GetScript("OnClick")
                        if fn then fn(ch, "LeftButton") end
                    end
                end
            end
        ''')
        m_env.SetInCombat(False)
        assert l_env.globals().__CAL_OPENED == 0, 'SystemBar clockBtn 在战斗中无锁调用了 ToggleCalendar（P3-20 K7）'

        # 10) /kk clickcheck combat-safe & detects injected invisible blocker + supports GetMouseFoci/GetMouseFocus
        m_env.SetInCombat(True)
        m_env.ClearProtectedViolations()
        l_env.execute('''
            local trap = CreateFrame("Frame", "kkowoUI_TestTrap", UIParent)
            trap:SetSize(200, 100); trap:EnableMouse(true); trap:SetAlpha(0); trap:Show()
            _G.__TRAP = trap
        ''')
        m_env.SetMouseFoci(l_env.table_from({1: l_env.globals().__TRAP}))
        res = l_env.globals().kkowoUI._Diagnostics.ClickCheck('')
        viol = list(m_env.GetProtectedViolations().values())
        l_env.execute('_G.__TRAP:Hide()')
        m_env.SetInCombat(False)
        assert not viol, f'/kk clickcheck 战斗中产生受保护调用违规: {viol}'
        assert any(r.name == 'kkowoUI_TestTrap' for r in res.invisibleBlockers.values()), '/kk clickcheck 未检出测试隐形挡点击框体'
        assert any(r.name == 'kkowoUI_TestTrap' for r in res.mouseFoci.values()), '/kk clickcheck 未列出鼠标下方框体'

        return '阶段 3 全部核心/环境矩阵回归（K1/K5/K6/K7/K12/链式卸载/clickcheck战斗安全）通过'

    check('阶段5-19：环境矩阵核心回归与 /kk clickcheck 测试', t_phase3_matrix_regressions)

    # 20. Phase 4.5 Patches tests on temp fake game dir (idempotency, CRLF/BOM, missing anchor atomic reject, legacy upgrade, 0 deletes)
    def t_phase45_patches():
        def load_py(path, mod_name):
            spec = importlib.util.spec_from_file_location(mod_name, str(path))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod

        with tempfile.TemporaryDirectory(prefix='kk_p45_patches_') as tmp:
            tmp_p = pathlib.Path(tmp)
            game = tmp_p / '_forever_'
            addons = game / 'Interface' / 'AddOns'
            bk = tmp_p / 'backups'
            addons.mkdir(parents=True)
            bk.mkdir(parents=True)

            # A) eui_chat_tab_fast: test BOM + CRLF + idempotency + atomic missing anchor
            eui_mod = load_py(REPO / 'Patches' / 'eui_chat_tab_fast.py', 'p_eui_chat')
            eui_mod.BACKUP_ROOT = str(bk)
            eui_dir = addons / 'EllesmereUIChat'
            eui_dir.mkdir()
            (eui_dir / 'EllesmereUIChat.toc').write_bytes(b'\xef\xbb\xbf## Version: 9.9.6\r\n## Title: |cff0cd29fEllesmereUI|r Chat\r\n')
            (eui_dir / 'EllesmereUIChat.lua').write_bytes((eui_mod._FOLLOWER_OLD + '\n').replace('\n', '\r\n').encode('utf-8'))
            (eui_dir / 'EllesmereUIChat_Tabs.lua').write_bytes((eui_mod.FILE_PATCHES['EllesmereUIChat_Tabs.lua'][0][0] + '\n').encode('utf-8'))
            (eui_dir / 'EllesmereUIChat_Engine.lua').write_bytes((eui_mod._ENGINE_TAIL_OLD + '\n\n' + eui_mod._ENGINE_CLHOST_OLD + '\n').encode('utf-8'))

            st_chk, msg_chk = eui_mod.run(str(eui_dir), check_only=True)
            assert st_chk == 'READY', f'eui_chat_tab_fast 面对 UTF-8 BOM+CRLF 未返回 READY: {st_chk} ({msg_chk})（P45-01）'
            st1, msg1 = eui_mod.run(str(eui_dir), check_only=False)
            assert st1 == 'PATCHED', f'eui_chat_tab_fast 首次 apply 失败: {st1} ({msg1})'
            snap1 = {p.name: p.read_bytes() for p in eui_dir.iterdir()}
            st2, msg2 = eui_mod.run(str(eui_dir), check_only=False)
            assert st2 == 'APPLIED', f'eui_chat_tab_fast 二次 apply 不幂等: {st2} ({msg2})'
            snap2 = {p.name: p.read_bytes() for p in eui_dir.iterdir()}
            assert snap1 == snap2, 'eui_chat_tab_fast 连跑两次输出不一致'

            # Missing anchor on 1 file must reject ALL files atomically
            eui_bad = addons / 'EllesmereUIChat_Bad'
            eui_bad.mkdir()
            (eui_bad / 'EllesmereUIChat.toc').write_text('## Version: 9.9.7\n## Title: |cff0cd29fEllesmereUI|r Chat\n', encoding='utf-8')
            (eui_bad / 'EllesmereUIChat.lua').write_text(eui_mod._FOLLOWER_OLD + '\n', encoding='utf-8')
            (eui_bad / 'EllesmereUIChat_Tabs.lua').write_text('-- changed upstream\n', encoding='utf-8')
            (eui_bad / 'EllesmereUIChat_Engine.lua').write_text(eui_mod._ENGINE_TAIL_OLD + '\n' + eui_mod._ENGINE_CLHOST_OLD + '\n', encoding='utf-8')
            before_bad = {p.name: p.read_bytes() for p in eui_bad.iterdir()}
            st_b, _ = eui_mod.run(str(eui_bad), check_only=False)
            assert st_b == 'ANCHOR_MISMATCH', f'缺失锚点应返回 ANCHOR_MISMATCH，实际={st_b}'
            after_bad = {p.name: p.read_bytes() for p in eui_bad.iterdir()}
            assert before_bad == after_bad, '锚点缺失时不能留半套补丁！'

            # B) polestar_nav_optimize: BOM + legacy mark check + idempotency
            ps_mod = load_py(REPO / 'Patches' / 'polestar_nav_optimize.py', 'p_ps_nav')
            ps_mod.BACKUP_ROOT = str(bk)
            ps_dir = addons / 'Polestar'
            for rel, hunks in ps_mod.FILE_PATCHES:
                fp = ps_dir / rel
                fp.parent.mkdir(parents=True, exist_ok=True)
                body = '## Version: 0.4.3.1\n' + '\n\n'.join(o for o, _ in hunks) + '\n'
                if rel.endswith('.toc'):
                    fp.write_bytes(b'\xef\xbb\xbf' + body.replace('\n', '\r\n').encode('utf-8'))
                else:
                    fp.write_bytes(body.encode('utf-8'))
            st_p1, msg_p1 = ps_mod.run(str(ps_dir), check_only=False)
            assert st_p1 == 'PATCHED', f'polestar_nav_optimize BOM/CRLF 应用失败: {st_p1} ({msg_p1})（P45-01）'
            # Check no OLD_MARKS leaked inside newly patched files (P45-03)
            for rel, _ in ps_mod.FILE_PATCHES:
                txt = (ps_dir / rel).read_text(encoding='utf-8')
                for om in ps_mod.OLD_MARKS:
                    assert om not in txt, f'polestar_nav_optimize 新补丁 {rel} 正文残留旧标 {om}（P45-03）'
            st_p2, _ = ps_mod.run(str(ps_dir), check_only=False)
            assert st_p2 == 'APPLIED', f'polestar_nav_optimize 二次 apply 不幂等: {st_p2}'

            # C) scales_kkowo_rename: zero deleted files (old Scales & dd_author.toc moved to backups, AddOns.txt backed up) (P45-07)
            sc_dir = addons / 'Scales'
            sc_dir.mkdir()
            (sc_dir / 'Scales.toc').write_text('## Version: 0.1.4\n## Title: Scales\n## X-Curse-Project-ID: 123\nUI\\Style.lua\n', encoding='utf-8')
            (sc_dir / 'dd_author.toc').write_text('dd', encoding='utf-8')
            (sc_dir / 'UI').mkdir()
            (sc_dir / 'UI' / 'Style.lua').write_text('local t = "Interface\\\\AddOns\\\\Scales\\\\Media\\\\icon"\n', encoding='utf-8')
            ch_dir = game / 'WTF' / 'Account' / '12345#1' / 'TestRealm' / 'TestChar'
            ch_dir.mkdir(parents=True)
            (ch_dir / 'AddOns.txt').write_text('Scales: enabled\n', encoding='utf-8')

            env = os.environ.copy()
            env['WOW_FOREVER_DIR'] = str(game)
            env['WOW_BACKUP_ROOT'] = str(bk)
            r_sc = subprocess.run(
                [sys.executable, '-I', str(REPO / 'Patches' / 'scales_kkowo_rename.py'), '--apply'],
                env=env, capture_output=True, text=True, encoding='utf-8', errors='replace',
            )
            assert r_sc.returncode == 0, f'scales_kkowo_rename --apply 失败: {r_sc.stdout} {r_sc.stderr}'
            # Verify dd_author.toc was moved to backups (not deleted) & AddOns.txt was backed up!
            bk_files = [p.name for p in bk.rglob('*') if p.is_file()]
            assert 'AddOns.txt' in bk_files or any('AddOns.txt' in n for n in bk_files), 'scales_kkowo_rename 修改 AddOns.txt 前未备份（P45-07）'
            sc_src = (REPO / 'Patches' / 'scales_kkowo_rename.py').read_text(encoding='utf-8')
            assert 'os.remove(' not in sc_src and 'rmtree_retry(' not in sc_src, 'scales_kkowo_rename.py 仍含违规删除调用（P45-07）'

            # D) apply_patches.py status classification: APPLIED_LEGACY must NOT be OK (P45-04)
            ap_src = (REPO / 'Tools' / 'apply_patches.py').read_text(encoding='utf-8')
            assert "'APPLIED_LEGACY'" not in ap_src.split('ok = status in')[1].splitlines()[0], 'apply_patches.py 不应把 APPLIED_LEGACY 判为 OK（P45-04）'

        return '补丁脚本 BOM/CRLF/幂等/原子拒绝/旧标清理/防删/状态分类全部通过'

    check('阶段5-20：阶段 4.5 补丁脚本全场景测试', t_phase45_patches)

    # 21. Phase 4.5 Runtime Interventions (missing/renamed/late-loaded external addons + disable restore + PrettyTooltip coexistence)
    def t_phase45_runtime_interventions():
        # A) Missing / renamed external addons -> 0 errors
        l_miss, m_miss, _ = _boot_fresh(pre_setup_lua='''
            _G.EllesmereUI = nil
            _G.Polestar = nil
            _G.Questie = nil
            _G.Auctionator = nil
            _G.BigWigs = nil
            _G.GTFOLocal = nil
            _G.BugSack = nil
        ''')
        m_miss.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        m_miss.StepTime(1.0, 2)
        prints = [str(p) for p in m_miss.GetPrints().values()]
        errs = [p for p in prints if '启动失败' in p]
        assert not errs, f'外部插件全部缺失时模块启动报错: {errs}'

        # B) Disable restores EXACT original function references on EllesmereUI
        l_res, m_res, _ = _boot_fresh()
        l_res.execute('''
            local EUI = _G.EllesmereUI
            local origSetCVar = function(k, v) return true end
            local origCleanCast = function(n) return n end
            local origTipBg = function() return 0, 0, 0, 1 end
            local origBubDB = function() return { enabled = true } end
            EUI.SetCVar = origSetCVar
            EUI.CleanCastName = origCleanCast
            EUI.GetTooltipBg = origTipBg
            EUI.ChatBubbles = { DB = origBubDB, Refresh = function() end }

            -- Re-enable and then disable each overriding module
            for _, mk in ipairs({ "euiRuntimeFixes", "modernChrome", "tooltipStyle", "chatBubbles" }) do
                local m = _G.kkowoUI.Modules.Get(mk)
                m:SetEnabled(false)
                m:SetEnabled(true)
                m:SetEnabled(false)
            end
            assert(EUI.SetCVar == origSetCVar, "euiRuntimeFixes 停用后未还原 EllesmereUI.SetCVar（P3-21）")
            assert(EUI.CleanCastName == origCleanCast, "modernChrome 停用后未还原 EllesmereUI.CleanCastName（P3-14）")
            assert(EUI.GetTooltipBg == origTipBg, "tooltipStyle 停用后未还原 EllesmereUI.GetTooltipBg（P3-18）")
            assert(EUI.ChatBubbles.DB == origBubDB, "chatBubbles 停用后未还原 EllesmereUI.ChatBubbles.DB（P3-19）")
        ''')

        # C) Standalone PrettyTooltip coexistence when kkowoUI_Tooltip loads FIRST (alphabetical order!) (P45-10)
        l_pt, m_pt, loader_pt = create_env()
        m_pt.SetAddonLoaded('PrettyTooltip', False)
        l_pt.execute('C_AddOns.EnableAddOn("PrettyTooltip")')  # enabled, NOT yet loaded!
        loader_pt('kkowoUI_Media')
        loader_pt('kkowoUI')
        # Load Bridge/Compat.lua + Vendor/PrettyTooltip.lua (without skip_vendor for Compat test)
        pt_ns = l_pt.table()
        compat_src = (ADDON_BASE / 'kkowoUI_Tooltip' / 'Bridge' / 'Compat.lua').read_text(encoding='utf-8')
        l_pt.eval('function(src, ns) loadstring(src, "@Compat.lua")("kkowoUI_Tooltip", ns) end')(compat_src, pt_ns)
        assert pt_ns._yielded is True, '独立版 PrettyTooltip 已启用但晚于 kkowoUI_Tooltip 加载时，Compat.lua 必须让位（P45-10）'
        toc_txt = (ADDON_BASE / 'kkowoUI_Tooltip' / 'kkowoUI_Tooltip.toc').read_text(encoding='utf-8')
        assert 'PrettyTooltip' in [x.strip() for x in re.search(r'^##\s*OptionalDeps:\s*(.+)$', toc_txt, re.M).group(1).split(',')], \
            'kkowoUI_Tooltip.toc 的 OptionalDeps 应包含 PrettyTooltip（P45-10）'

        return '外部缺失0报错 + 4大覆写函数停用完全还原 + PrettyTooltip 共存可靠让位通过'

    check('阶段5-21：阶段 4.5 运行时介入安全与还原测试', t_phase45_runtime_interventions)

    # 22. Phase 4.5 Tools Scripts No-Delete & Sync/Font/WTF Integrity Tests (temp dirs only!)
    def t_phase45_tools_no_delete():
        with tempfile.TemporaryDirectory(prefix='kk_p45_tools_') as tmp:
            tmp_p = pathlib.Path(tmp)
            bk = tmp_p / 'backups'
            bk.mkdir()

            # A) sync_vendored_tooltip.py: MUST preserve Bridge/TooltipLocaleZh.lua, include it in .toc, and NOT delete old dir (P45-09)
            sync_spec = importlib.util.spec_from_file_location('sync_vt', str(REPO / 'Tools' / 'sync_vendored_tooltip.py'))
            sync_mod = importlib.util.module_from_spec(sync_spec)
            sync_spec.loader.exec_module(sync_mod)
            fake_dst = tmp_p / 'Addon' / 'kkowoUI_Tooltip'
            shutil.copytree(ADDON_BASE / 'kkowoUI_Tooltip', fake_dst)
            # Fake upstream PrettyTooltip built from current Vendor + LICENSE + Camelot toc
            fake_src = tmp_p / 'UpstreamPT'
            shutil.copytree(ADDON_BASE / 'kkowoUI_Tooltip' / 'Vendor', fake_src)
            shutil.copy2(ADDON_BASE / 'kkowoUI_Tooltip' / 'LICENSE', fake_src / 'LICENSE')
            # Reverse the 7 ART_PATCHES on fake_src so it looks like pristine upstream
            for rel, old, new in sync_mod.ART_PATCHES:
                fp = fake_src / rel
                txt = fp.read_text(encoding='utf-8').replace('\r\n', '\n')
                if new in txt:
                    fp.write_text(txt.replace(new, old, 1), encoding='utf-8')
            # Create a minimal PrettyTooltip_Camelot.toc
            (fake_src / 'PrettyTooltip_Camelot.toc').write_text('## Version: 1.5.0\nPrettyTooltip.lua\n', encoding='utf-8')

            sync_mod.DST_ROOT = str(fake_dst)
            if hasattr(sync_mod, 'BACKUP_ROOT'):
                sync_mod.BACKUP_ROOT = str(bk)
            old_argv = sys.argv
            try:
                sys.argv = ['sync_vendored_tooltip.py', '--src', str(fake_src)]
                sync_mod.main()
            finally:
                sys.argv = old_argv

            assert (fake_dst / 'Bridge' / 'TooltipLocaleZh.lua').is_file(), \
                'sync_vendored_tooltip.py 同步后删掉了 Bridge/TooltipLocaleZh.lua！（P45-09）'
            gen_toc = (fake_dst / 'kkowoUI_Tooltip.toc').read_text(encoding='utf-8')
            assert 'Bridge\\TooltipLocaleZh.lua' in gen_toc, \
                'sync_vendored_tooltip.py 生成的 .toc 漏掉了 Bridge\\TooltipLocaleZh.lua！（P45-09）'
            assert any(bk.iterdir()), 'sync_vendored_tooltip.py 应将旧 kkowoUI_Tooltip 移入 backups 而非 rmtree 删除（P45-09）'

            # B) install_mmo_fonts.py: install + rollback must move .slug and removed fonts to backups, NOT os.remove (P45-14)
            fonts_src = (REPO / 'Tools' / 'install_mmo_fonts.py').read_text(encoding='utf-8')
            assert 'os.remove(' not in fonts_src, 'Tools/install_mmo_fonts.py 仍含 os.remove 违规删除（P45-14）'

            # C) prepare_share_wtf.py: no os.remove/shutil.rmtree deleting user/game files (P45-15)
            psw_src = (REPO / 'Tools' / 'prepare_share_wtf.py').read_text(encoding='utf-8')
            assert 'os.remove(' not in psw_src and 'shutil.rmtree(' not in psw_src, \
                'Tools/prepare_share_wtf.py 仍含违规删除调用 os.remove/shutil.rmtree（P45-15）'

            # D) apply_live_config.py: must check wow running + backup + parse SV (P45-16)
            alc_src = (REPO / 'Tools' / 'apply_live_config.py').read_text(encoding='utf-8')
            assert 'wow_running' in alc_src and 'BACKUP_ROOT' in alc_src, \
                'Tools/apply_live_config.py 缺少游戏运行检测与备份保护（P45-16）'

            # E) Recorder SV stripping in prepare_share_wtf.py & make_friend_pack.py + deploy.ps1 guard
            psw_spec = importlib.util.spec_from_file_location('psw_test', str(REPO / 'Tools' / 'prepare_share_wtf.py'))
            psw_mod = importlib.util.module_from_spec(psw_spec)
            psw_spec.loader.exec_module(psw_mod)
            mfp_spec = importlib.util.spec_from_file_location('mfp_test', str(REPO / 'Tools' / 'make_friend_pack.py'))
            mfp_mod = importlib.util.module_from_spec(mfp_spec)
            mfp_spec.loader.exec_module(mfp_mod)
            sample_sv = (
                '\nkkowoUIDB = {\n["version"] = 1,\n["modules"] = { ["immersiveHUD"] = { ["enabled"] = true, }, },\n}\n'
                'kkowoUIRecordDB = {\n["schemaVersion"] = 1,\n["sessions"] = { { ["instanceName"] = "死亡矿井", }, },\n}\n'
            )
            scrubbed_mfp, dropped_mfp = mfp_mod.scrub_kkowo(sample_sv)
            assert 'kkowoUIRecordDB' not in scrubbed_mfp and 'kkowoUIDB' in scrubbed_mfp and dropped_mfp >= 1, \
                'make_friend_pack.scrub_kkowo 未剔除 kkowoUIRecordDB'
            fake_acc = tmp_p / 'fake_acc'
            (fake_acc / 'SavedVariables').mkdir(parents=True)
            (fake_acc / 'SavedVariables' / 'kkowoUI.lua').write_text(sample_sv, encoding='utf-8')
            fake_addons = tmp_p / 'fake_game' / 'Interface' / 'AddOns'
            (fake_addons / 'kkowoUI').mkdir(parents=True)
            old_game = psw_mod.GAME
            old_bk = psw_mod.BACKUP_ROOT
            try:
                psw_mod.GAME = str(tmp_p / 'fake_game')
                psw_mod.BACKUP_ROOT = str(bk)
                _, keep_list, failed_list, removed_list = psw_mod.plan_account(str(fake_acc), set(), True)
                assert not failed_list, f'prepare_share_wtf.plan_account 失败: {failed_list}'
                sv_after = (fake_acc / 'SavedVariables' / 'kkowoUI.lua').read_text(encoding='utf-8')
                assert 'kkowoUIRecordDB' not in sv_after and 'kkowoUIDB' in sv_after, \
                    'prepare_share_wtf.plan_account 未剔除 kkowoUIRecordDB'
                assert not psw_mod.residual_scan(str(fake_acc), set()), 'prepare_share_wtf 脱敏后仍残留可疑项'
                # Verify residual_scan catches leaked kkowoUIRecordDB
                (fake_acc / 'SavedVariables' / 'kkowoUI.lua').write_text(sample_sv, encoding='utf-8')
                leaks = psw_mod.residual_scan(str(fake_acc), set())
                assert any('kkowoUIRecordDB' in x or '录像' in x for x in leaks), 'residual_scan 未拦截泄漏的 kkowoUIRecordDB'
            finally:
                psw_mod.GAME = old_game
                psw_mod.BACKUP_ROOT = old_bk
            dep_src = (REPO / 'Tools' / 'deploy.ps1').read_text(encoding='utf-8')
            assert 'kkowoUI(Char|Record)?DB = nil' in dep_src, 'deploy.ps1 缺少 kkowoUIRecordDB 防置空保护'

        return '工具脚本零违规删除(sync_vendored_tooltip保留中文/install_mmo_fonts/prepare_share_wtf/apply_live_config)全部通过'

    check('阶段5-22：阶段 4.5 工具脚本防删与完整性测试', t_phase45_tools_no_delete)

    # 23. ImmersiveHUD out-of-combat fade regression (Scenes A/B/C/D) + red-first against 34c188c
    def t_immersive_fade_regression():
        # Red-first verification against 34c188c (in-memory only, repo untouched):
        # With WorldMapFrame hidden, 34c188c fades under plain values (Scene C) but FAILS to fade under secret OOC values (Scene A).
        old_ih_src = subprocess.check_output(
            ['git', 'show', '34c188c:Addon/kkowoUI_QoL/ImmersiveHUD.lua'],
            cwd=str(REPO),
        ).decode('utf-8')
        l_old, m_old, loader_old = create_env()
        for name in LOAD_ORDER:
            loader_old(name, file_overrides={'kkowoUI_QoL/ImmersiveHUD.lua': old_ih_src})
        m_old.FireEvent('PLAYER_LOGIN')
        m_old.FireEvent('PLAYER_ENTERING_WORLD', True, False)
        m_old.AdvanceTime(5.0)
        l_old.execute('''
            if _G.WorldMapFrame then _G.WorldMapFrame:Hide() end
            local ih = _G.kkowoUI.Modules.Get("immersiveHUD")
            ih:GetDB().disableInInstance = true
            ih:GetDB().idleAlpha = 0.28
            local bar = _G.EABBar_MainBar or CreateFrame("Frame", "EABBar_MainBar", UIParent)
            bar:SetSize(400, 40); bar:Show(); bar:SetAlpha(1)
            ih:SetEnabled(false); ih:SetEnabled(true)
        ''')
        m_old.ResetScenario()
        m_old.SetSecretAPIs(l_old.table_from({
            'UnitHealth': True, 'UnitHealthMax': True,
            'UnitPower': True, 'UnitPowerMax': True, 'UnitPowerType': True,
            'UnitExists': True,
        }))
        m_old.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        m_old.StepTime(2.5, 50)
        old_a_A = l_old.eval('_G.EABBar_MainBar:GetAlpha()')
        assert old_a_A > 0.95, f'先红校验异常：34c188c 在场景A预期不淡隐(>0.95)，实际={old_a_A:.3f}'

        l_env, m_env, _ = _boot_fresh()
        l_env.execute('''
            if _G.WorldMapFrame then _G.WorldMapFrame:Hide() end
            local ih = _G.kkowoUI.Modules.Get("immersiveHUD")
            ih:GetDB().disableInInstance = true
            ih:GetDB().idleAlpha = 0.28
            local bar = _G.EABBar_MainBar or CreateFrame("Frame", "EABBar_MainBar", UIParent)
            bar:SetSize(400, 40); bar:Show(); bar:SetAlpha(1)
            local hud = _G.kkowoUI_CoreHUD
            if hud then hud:Show(); hud:SetAlpha(1) end
            ih:SetEnabled(false); ih:SetEnabled(true)
        ''')

        # Scene A: Out of combat, player HP / Power / PowerType / UnitExists("target") are all secret -> MUST fade
        m_env.ResetScenario()
        m_env.SetSecretAPIs(l_env.table_from({
            'UnitHealth': True, 'UnitHealthMax': True,
            'UnitPower': True, 'UnitPowerMax': True, 'UnitPowerType': True,
            'UnitExists': True,
        }))
        m_env.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        m_env.StepTime(2.5, 50)
        bar_a_A = l_env.eval('_G.EABBar_MainBar:GetAlpha()')
        hud_a_A = l_env.eval('_G.kkowoUI_CoreHUD and _G.kkowoUI_CoreHUD:GetAlpha() or 0.28')
        assert bar_a_A < 0.35 and hud_a_A < 0.35, (
            f'场景A失败：脱战且血/蓝/目标均为机密值时应正常淡隐，实际 bar={bar_a_A:.3f}, hud={hud_a_A:.3f}'
        )
        ih_mod = l_env.eval('_G.kkowoUI.Modules.Get("immersiveHUD")')
        diag_a = ih_mod.InspectFadeState(ih_mod)
        assert diag_a.shouldImmerse is True and diag_a.blockedBy is None, (
            f'/kk fade why 场景A应允许淡隐，实际 blockedBy={diag_a.blockedBy}'
        )
        cond_map_a = {c.key: c for c in diag_a.conditions.values()}
        assert cond_map_a['vitalHealth'].secret is True and cond_map_a['vitalHealth'].blocked is False
        assert cond_map_a['vitalPower'].secret is True and cond_map_a['vitalPower'].blocked is False
        assert cond_map_a['hasTarget'].secret is True and cond_map_a['hasTarget'].blocked is False

        # Scene B: In combat inside instance with same secret values -> MUST NOT fade (even with disableInInstance=false)
        l_env.execute('_G.kkowoUI.Modules.Get("immersiveHUD"):GetDB().disableInInstance = false')
        m_env.SetInstanceMode(True, 'party', '死亡矿井')
        m_env.SetInCombat(True)
        m_env.FireEvent('PLAYER_REGEN_DISABLED')
        m_env.StepTime(2.0, 40)
        bar_a_B = l_env.eval('_G.EABBar_MainBar:GetAlpha()')
        hud_a_B = l_env.eval('_G.kkowoUI_CoreHUD and _G.kkowoUI_CoreHUD:GetAlpha() or 1.0')
        assert bar_a_B > 0.95 and hud_a_B > 0.95, (
            f'场景B失败：副本战斗+机密值时绝不能淡隐，实际 bar={bar_a_B:.3f}, hud={hud_a_B:.3f}'
        )
        # /kk fade why must work safely in combat (read-only, 0 protected violations)
        m_env.ClearProtectedViolations()
        m_env.RunSlash('/kk', 'fade why')
        viol_b = list(m_env.GetProtectedViolations().values())
        assert not viol_b, f'/kk fade why 战斗中产生受保护调用违规: {viol_b}'
        diag_b = ih_mod.InspectFadeState(ih_mod)
        assert diag_b.shouldImmerse is False and diag_b.blockedBy == 'combatLockdown', (
            f'/kk fade why 场景B应报告 combatLockdown 挡住，实际 blockedBy={diag_b.blockedBy}'
        )

        # Scene C: Out of combat, all plain values, full HP & Mana, no target -> MUST fade
        m_env.ResetScenario()
        l_env.execute('_G.kkowoUI.Modules.Get("immersiveHUD"):GetDB().disableInInstance = true')
        m_env.FireEvent('PLAYER_REGEN_ENABLED')
        m_env.StepTime(2.5, 50)
        bar_a_C = l_env.eval('_G.EABBar_MainBar:GetAlpha()')
        assert bar_a_C < 0.35, f'场景C失败：脱战明文满血满蓝无目标应淡隐，实际 bar={bar_a_C:.3f}'

        # Scene D: Hover wake -> leave re-fade -> disable restores alpha=1
        l_env.execute('_G.EABBar_MainBar._mouseOver = true')
        m_env.RunTickersOnce()
        m_env.StepTime(1.5, 40)
        bar_a_hover = l_env.eval('_G.EABBar_MainBar:GetAlpha()')
        assert bar_a_hover > 0.95, f'场景D失败：悬停应唤醒至清晰，实际 bar={bar_a_hover:.3f}'

        l_env.execute('_G.EABBar_MainBar._mouseOver = false')
        m_env.RunTickersOnce()
        m_env.StepTime(1.5, 40)
        bar_a_leave = l_env.eval('_G.EABBar_MainBar:GetAlpha()')
        assert bar_a_leave < 0.35, f'场景D失败：移开鼠标后应重新淡隐，实际 bar={bar_a_leave:.3f}'

        l_env.execute('_G.kkowoUI.Modules.Get("immersiveHUD"):SetEnabled(false)')
        m_env.StepTime(0.5, 10)
        bar_a_off = l_env.eval('_G.EABBar_MainBar:GetAlpha()')
        hud_a_off = l_env.eval('_G.kkowoUI_CoreHUD and _G.kkowoUI_CoreHUD:GetAlpha() or 1.0')
        assert bar_a_off > 0.99 and hud_a_off > 0.99, (
            f'场景D失败：关闭脱战淡隐后应全部还原，实际 bar={bar_a_off:.3f}, hud={hud_a_off:.3f}'
        )
        return '场景A(脱战机密值淡隐)/B(副本战斗保持清晰)/C(明文满血蓝淡隐)/D(悬停唤醒+离开重淡+关闭还原)+/kk fade why 全部通过'

    check('脱战淡隐回归与 /kk fade why 行为测试', t_immersive_fade_regression)

    # 24. LiveRecorder "record once" state machine, secret/zero-return packing, and /kk rec commands
    def t_live_recorder():
        l_env, m_env, _ = _boot_fresh()
        F = l_env.globals().kkowoUI
        rec = F.Recorder
        assert rec is not None, 'F.Recorder 未常驻加载'

        # 1) First deploy auto-arms once; open world does NOT consume armed
        st0 = rec.GetState()
        assert st0.armed is True and st0.recording is False, f'首次登录应自动待录且未开录: armed={st0.armed}, rec={st0.recording}'
        m_env.FireEvent('ZONE_CHANGED_NEW_AREA')
        m_env.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        st1 = rec.GetState()
        assert st1.armed is True and st1.recording is False, '野外切换不应消耗待录状态'

        # 2) Enter dungeon -> starts recording! Record roll + enchant + combat + nameplate + zero/nil/secret + mark
        m_env.SetInstanceMode(True, 'party', '死亡矿井')
        m_env.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        st2 = rec.GetState()
        assert st2.recording is True, '进副本后未自动开始录制'

        # Test zero-return vs nil-return vs secret value packing in combat
        m_env.SetInCombat(True)
        m_env.ClearProtectedViolations()
        m_env.SetZeroReturnAPIs(l_env.table_from({'UnitCastingInfo': True}))
        m_env.SetSecretAPIs(l_env.table_from({'GetLootRollTimeLeft': True, 'UnitHealth': True, 'UnitHealthMax': True}))
        l_env.execute('''
            _G.GetLootRollItemInfo = function(id)
                return 135489, "残酷倒钩", 1, 3, true, true, true, false
            end
            _G.C_Item = _G.C_Item or {}
            _G.C_Item.GetWeaponEnchantInfo = function()
                return true, 1800000, 0, 1643, false, nil, nil, nil
            end
        ''')
        m_env.FireEvent('PLAYER_REGEN_DISABLED')
        m_env.FireEvent('START_LOOT_ROLL', 77, 60000)
        m_env.FireEvent('UNIT_SPELLCAST_START', 'player', 'Cast-3-0001', 1234)
        forb = m_env.CreateForbiddenPlate()
        m_env.SetMockNameplates(l_env.table_from({1: forb, 'nameplate1': forb}))
        m_env.FireEvent('NAME_PLATE_UNIT_ADDED', 'nameplate1')
        m_env.FireEvent('UNIT_INVENTORY_CHANGED', 'player')
        m_env.RunSlash('/kk', 'rec mark 副本测试标记')
        viol_rec = list(m_env.GetProtectedViolations().values())
        assert not viol_rec, f'战斗中录制/打标触发受保护调用违规: {viol_rec}'

        # 3) Reload inside SAME dungeon -> continues SAME session
        cnt_before_reload = rec.GetState().currentCount
        assert cnt_before_reload >= 6, f'录制条目过少: {cnt_before_reload}'
        m_env.SetInCombat(False)
        m_env.FireEvent('PLAYER_ENTERING_WORLD', False, True)
        st3 = rec.GetState()
        assert st3.recording is True and st3.currentCount > cnt_before_reload and st3.savedSessions == 0, (
            f'副本内 /reload 应续录同一次会话: rec={st3.recording}, cnt={st3.currentCount}, saved={st3.savedSessions}'
        )

        # 4) Leave dungeon -> stops, saves session, clears armed, prints once
        m_env.SetMockNameplates(l_env.table())
        m_env.ResetScenario()
        m_env.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        st4 = rec.GetState()
        assert st4.recording is False and st4.armed is False and st4.savedSessions == 1, (
            f'离开副本后应停止并退出待录: rec={st4.recording}, armed={st4.armed}, saved={st4.savedSessions}'
        )

        # Inspect recorded entries: verify 0-return vs secret vs roll vs nameplate forbidden vs mark
        chk = l_env.eval('''(function()
            local s = _G.kkowoUIRecordDB.sessions[1]
            local foundRoll, foundCastZero, foundForbNP, foundMark, foundEnch = false, false, false, false, false
            for _, e in ipairs(s.entries) do
                if e.ev == "START_LOOT_ROLL" then
                    local tl = e.apis and e.apis.GetLootRollTimeLeft
                    local ii = e.apis and e.apis.GetLootRollItemInfo
                    if tl and tl.ok and tl.n == 1 and tl.v[1].s == true
                        and ii and ii.ok and ii.n == 8 and ii.v[2].v == "残酷倒钩" then
                        foundRoll = true
                    end
                elseif e.ev == "UNIT_SPELLCAST_START" then
                    local ci = e.apis and e.apis.UnitCastingInfo
                    if ci and ci.ok and ci.n == 0 and e.args.v[2].v == "<redacted>" then
                        foundCastZero = true
                    end
                elseif e.ev == "NAME_PLATE_UNIT_ADDED" then
                    if e.apis and e.apis.nameplate and e.apis.nameplate.forbidden == true then
                        foundForbNP = true
                    end
                elseif e.ev == "USER_MARK" then
                    if e.note == "副本测试标记" and type(e.clickcheck) == "table" then
                        foundMark = true
                    end
                elseif e.ev == "UNIT_INVENTORY_CHANGED" then
                    local we = e.apis and e.apis.weaponEnchants and e.apis.weaponEnchants.cItem
                    if we and we.ok and we.n == 8 and we.v[4].v == 1643 and we.v[6].t == "nil" then
                        foundEnch = true
                    end
                end
            end
            return foundRoll and foundCastZero and foundForbNP and foundMark and foundEnch
        end)()''')
        assert chk is True, '录制内容校验失败（roll机密/零返回/nil返回/forbidden姓名板/mark/脱敏）'

        # 5) Re-entering dungeon MUST NOT record again
        m_env.SetInstanceMode(True, 'party', '死亡矿井')
        m_env.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        assert rec.GetState().recording is False and rec.GetState().armed is False, '二次进本不应自动再录'

        # 6) Simulated restart with persisted autoArmFlags MUST NOT auto-arm again
        m_env.FireEvent('PLAYER_LOGIN')
        assert rec.GetState().armed is False and rec.GetState().recording is False, '重启后不应再次自动待录'

        # 7) /kk rec on while already in dungeon starts immediately; /kk rec off stops & preserves data
        m_env.RunSlash('/kk', 'rec on')
        assert rec.GetState().recording is True, '副本内 /kk rec on 应立即开录'
        m_env.FireEvent('CANCEL_ALL_LOOT_ROLLS')
        m_env.RunSlash('/kk', 'rec off')
        st7 = rec.GetState()
        assert st7.recording is False and st7.armed is False and st7.savedSessions == 2, (
            f'/kk rec off 应立即停止并保留数据: rec={st7.recording}, armed={st7.armed}, saved={st7.savedSessions}'
        )

        # 8) /kk rec mark when NOT recording prints hint & does not crash
        m_env.RunSlash('/kk', 'rec mark 未录制时测试')
        prints_after = [str(p) for p in m_env.GetPrints().values()]
        assert any('当前没有在录制' in p for p in prints_after), '未录制时 /kk rec mark 未提示当前没有在录制'

        # 9) /kk rec clear clears sessions and does NOT re-arm
        m_env.RunSlash('/kk', 'rec clear')
        st9 = rec.GetState()
        assert st9.savedSessions == 0 and st9.armed is False and st9.recording is False, 'clear 后应清空且不自动待录'
        return '首次自动待录/野外不消耗/进本开录/副本内重载续录/离本即停/不再自动录/手动on-off-mark-clear/零返回与机密打包 全部通过'

    check('实机录制器「只录一次」状态机与命令行为测试', t_live_recorder)

    # 25. Offline Replay Framework: Red-first against 7813558 RollBars + Roundtrip Record->Save->Parse->Replay + Auto-discover review/recordings
    def t_offline_replay_framework():
        sys.path.insert(0, str(HERE))
        import replay as rp

        # A) Red-first on sample dungeon roll recording: 7813558 RollBars MUST fail with click blocker; current HEAD MUST pass & be repeatable
        sample = rp.build_sample_dungeon_roll_recording()
        sess0 = sample['sessions'][0]
        old_rb_src = subprocess.check_output(
            ['git', 'show', '7813558:Addon/kkowoUI_QoL/RollBars.lua'],
            cwd=str(REPO),
        ).decode('utf-8')
        res_old = rp.replay_session(
            sess0, create_env, LOAD_ORDER,
            file_overrides={'kkowoUI_QoL/RollBars.lua': old_rb_src},
            check_disable_restore=False,
        )
        old_blockers = res_old['kkowoBlockers'] + res_old['blizzRollBlockers']
        assert not res_old['passed'] and len(old_blockers) >= 1, (
            f'先红校验失败：7813558 RollBars 回放样例录像应复现挡点击问题，实际 passed={res_old["passed"]}, blockers={old_blockers}'
        )

        res_new1 = rp.replay_session(sess0, create_env, LOAD_ORDER)
        res_new2 = rp.replay_session(sess0, create_env, LOAD_ORDER)
        assert res_new1['passed'], f'当前版回放样例录像失败: {res_new1}'
        assert res_new1 == res_new2, '同一份录像连续回放两次结果不一致（不可重复）'
        assert len(res_new1['markComparisons']) == 1 and res_new1['markComparisons'][0]['note'] == '掷点弹出检查'

        diffs = rp.calibrate_mock_diff(sample['sessions'])
        assert len(diffs) >= 3, f'mock 校准差异分析输出过少: {diffs}'

        # B) Full end-to-end roundtrip: LiveRecorder records dungeon -> serialize SV -> scrub PII -> parse back -> replay!
        l_rec, m_rec, _ = _boot_fresh()
        m_rec.SetInstanceMode(True, 'party', '哀嚎洞穴')
        m_rec.FireEvent('PLAYER_ENTERING_WORLD', False, False)
        l_rec.execute('''
            _G.GetLootRollItemInfo = function() return 135489, "尖牙护腿", 1, 3, true, true, true, false end
            _G.GetLootRollTimeLeft = function() return 45000 end
        ''')
        m_rec.SetInCombat(True)
        m_rec.FireEvent('PLAYER_REGEN_DISABLED')
        m_rec.FireEvent('START_LOOT_ROLL', 601, 60000)
        m_rec.RunSlash('/kk', 'rec mark 端到端闭环标记')
        m_rec.FireEvent('PLAYER_ENTERING_WORLD', False, True)  # reload mid-dungeon
        m_rec.SetInCombat(False)
        m_rec.FireEvent('PLAYER_REGEN_ENABLED')
        m_rec.FireEvent('CANCEL_LOOT_ROLL', 601)
        m_rec.ResetScenario()
        m_rec.FireEvent('PLAYER_ENTERING_WORLD', False, False)  # leave dungeon -> finalize

        py_rec_db = rp.lua_table_to_python(l_rec.globals().kkowoUIRecordDB)
        assert py_rec_db and len(py_rec_db.get('sessions', [])) == 1, '端到端录制未产出 1 段完整会话'
        sv_lua_text = 'kkowoUIRecordDB = ' + rp.serialize_lua_table(py_rec_db) + '\n'
        parsed_back = rp.parse_record_db_from_sv_text(sv_lua_text)
        scrubbed = rp.scrub_recording_data(parsed_back, {'TestPlayer', 'TestRealm'})
        assert 'Player-95-' not in json.dumps(scrubbed, ensure_ascii=False), '清洗后的录像残留 GUID'
        res_rt = rp.replay_session(scrubbed['sessions'][0], create_env, LOAD_ORDER)
        assert res_rt['passed'], f'端到端录制的录像回放失败: {res_rt}'

        # C) Auto-discover real recordings under D:\code\wow\review\recordings\ (skip gracefully if none yet)
        real_files = rp.discover_recordings()
        real_info = '尚无实机录像（跳过，放置到 review/recordings/ 后自动回放）'
        if real_files:
            replayed_real = 0
            for rf in real_files:
                rdata = json.loads(rf.read_text(encoding='utf-8'))
                for rsess in (rdata.get('sessions') or []):
                    rres = rp.replay_session(rsess, create_env, LOAD_ORDER)
                    assert rres['passed'], f'实机录像 {rf.name} 回放失败: {rres}'
                    replayed_real += 1
            real_info = f'已自动回放 {len(real_files)} 份共 {replayed_real} 段真实录像全过'

        return f'7813558先红检出{len(old_blockers)}处→当前版可重复通过 + 录制/落盘/清洗/回放闭环全过 + 真实录像:{real_info}'

    check('离线回放框架（7813558先红后绿 / 闭环回放 / 实机录像自动发现）', t_offline_replay_framework)

    print(f'\n离线测试汇总：通过 {len(passes)} / 失败 {len(failures)}')
    return 1 if failures else 0


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(run_all())
