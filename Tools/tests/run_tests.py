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
import os
import re
import sys
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

    def load_addon(addon_name, skip_vendor=True):
        lod, files = parse_toc(addon_name)
        ns = lua.table()
        loaded_tables[addon_name] = ns
        mock.SetAddonLoaded(addon_name, True)
        for rel in files:
            norm = rel.replace('\\', '/')
            if skip_vendor and norm.startswith('Vendor/'):
                continue
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
        assert '_kkowoFastTabVer or 0) >= 5' in guard_txt, 'Guard.lua 应核验聊天加速补丁 v5'
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

        # 10) eui_chat_tab_fast v5: load-time flag + never unhide Blizzard ChatFrame2.ScrollBar.Track
        patch_txt = (ADDON_BASE.parent / 'Patches' / 'eui_chat_tab_fast.py').read_text(encoding='utf-8')
        assert "MARK = '[fui-chat-fasttab v5]'" in patch_txt, '补丁应升级至 v5'
        assert 'ns._kkowoFastTabVer = 5' in patch_txt, '补丁应在模块加载期置位 v5 标记'
        patch_new_part = patch_txt.split('FILE_PATCHES = ')[1]
        assert 'bar.Track:SetAlpha(1)' not in patch_new_part, '战斗记录补丁新代码不得再显示暴雪旧滑块'

        return '全部 25 项实机回归断言（v5补丁/总控键位图/无污染/光柱/尾淡拾取/Buff倒计时/聊天锁步）全部通过'

    check('实机会话 2 全部 17 项反馈回归测试', t_session2_regressions)

    print(f'\n离线测试汇总：通过 {len(passes)} / 失败 {len(failures)}')
    return 1 if failures else 0


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.exit(run_all())
