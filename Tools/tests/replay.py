# -*- coding: utf-8 -*-
r"""
kkowoUI 实机录像导入、隐私清洗、离线回放与 mock 校准引擎

用法：
  # 从游戏 SavedVariables 读取 kkowoUIRecordDB，隐私清洗后导出到 D:\code\wow\review\recordings\<时间>\
  python Tools/tests/replay.py --import

  # 回放指定目录或文件，并输出与 mock 默认行为的校准差异
  python Tools/tests/replay.py --replay D:\code\wow\review\recordings\<时间>\recording.json

  # 扫描并回放 review\recordings\ 下全部录像
  python Tools/tests/replay.py --scan
"""
import argparse
import datetime
import json
import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
TOOLS = REPO / 'Tools'
REVIEW_RECORDINGS = REPO.parent / 'review' / 'recordings'

GUID_RE = re.compile(r'(?:Player|Pet|BNet)-\d+-[0-9A-Fa-f-]+')
CHAR_REALM_RE = re.compile(r'^[^-\s]{2,24}-[^-\s]{2,24}$')


def _load_psw():
    import importlib.util
    p = TOOLS / 'prepare_share_wtf.py'
    if not p.is_file():
        return None
    spec = importlib.util.spec_from_file_location('psw_replay', str(p))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def lua_table_to_python(val, _depth=0, _max_depth=12):
    """递归把 lupa LuaTable 转为纯 Python dict/list/scalar（保留 1..N 数组为 list，防环路爆栈）。"""
    if val is None or isinstance(val, (bool, int, float, str)):
        return val
    if not hasattr(val, 'items'):
        return str(val)
    if _depth >= _max_depth:
        return None
    items = list(val.items())
    if not items:
        return []
    int_keys = [k for k, _ in items if isinstance(k, int) and not isinstance(k, bool)]
    if len(int_keys) == len(items):
        int_keys.sort()
        if int_keys == list(range(1, len(int_keys) + 1)):
            return [lua_table_to_python(val[k], _depth + 1, _max_depth) for k in int_keys]
    out = {}
    for k, v in items:
        sk = str(k) if not isinstance(k, str) else k
        if sk == 'frame':
            continue
        out[sk] = lua_table_to_python(v, _depth + 1, _max_depth)
    return out


def scrub_recording_data(obj, forbidden_names=None):
    """深度清洗录像对象：移除账号 ID、角色-服务器名、Player/BNet GUID 与已知玩家名。"""
    names = {n for n in (forbidden_names or set()) if isinstance(n, str) and len(n) >= 2}

    def clean_str(s):
        if GUID_RE.search(s):
            s = GUID_RE.sub('<redacted:guid>', s)
        for nm in names:
            if nm in s:
                s = s.replace(nm, '<redacted:name>')
        return s

    def walk(x):
        if isinstance(x, str):
            return clean_str(x)
        if isinstance(x, list):
            return [walk(v) for v in x]
        if isinstance(x, dict):
            out = {}
            for k, v in x.items():
                ck = clean_str(k) if isinstance(k, str) else k
                if ck in ('char', 'charKey', 'account', 'accountId', 'playerName', 'playerGUID'):
                    continue
                out[ck] = walk(v)
            return out
        return x

    return walk(obj)


def parse_record_db_from_sv_text(sv_text):
    """用 Lua 5.1 沙箱安全解析 SavedVariables 文本中的 kkowoUIRecordDB。"""
    from lupa.lua51 import LuaRuntime
    lua = LuaRuntime(unpack_returned_tuples=True)
    # 纯数据解析，不暴露任何 OS/IO API
    lua.execute('''
        io = nil; os = nil; dofile = nil; loadfile = nil; require = nil
    ''')
    lua.execute(sv_text)
    raw = lua.globals().kkowoUIRecordDB
    if raw is None:
        return None
    return lua_table_to_python(raw)


def serialize_lua_table(obj, indent=0):
    """将 Python 对象序列化为标准 Lua SavedVariables 字面量（供测试闭环验证）。"""
    sp = '  ' * indent
    if obj is None:
        return 'nil'
    if isinstance(obj, bool):
        return 'true' if obj else 'false'
    if isinstance(obj, (int, float)):
        return repr(obj)
    if isinstance(obj, str):
        esc = obj.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r')
        return f'"{esc}"'
    if isinstance(obj, list):
        if not obj:
            return '{}'
        parts = [f'{sp}  {serialize_lua_table(v, indent + 1)},' for v in obj]
        return '{\n' + '\n'.join(parts) + f'\n{sp}}}'
    if isinstance(obj, dict):
        if not obj:
            return '{}'
        parts = []
        for k, v in obj.items():
            if isinstance(k, int):
                kk = f'[{k}]'
            elif isinstance(k, str) and k.isdigit():
                kk = f'[{k}]'
            else:
                ks = str(k).replace('\\', '\\\\').replace('"', '\\"')
                kk = f'["{ks}"]'
            parts.append(f'{sp}  {kk} = {serialize_lua_table(v, indent + 1)},')
        return '{\n' + '\n'.join(parts) + f'\n{sp}}}'
    return 'nil'


def import_from_game(out_root=None):
    """从真实游戏 WTF SavedVariables 读取、清洗并导出录像到 review/recordings/<时间>/。"""
    psw = _load_psw()
    if psw is None:
        raise RuntimeError('找不到 Tools/prepare_share_wtf.py，无法自动探测账号目录')
    acc = psw.detect_account()
    if not acc:
        raise RuntimeError('找不到唯一的 WTF\\Account\\<账号> 目录（可设 WOW_ACCOUNT_DIR）')
    sv_file = pathlib.Path(acc) / 'SavedVariables' / 'kkowoUI.lua'
    if not sv_file.is_file():
        raise FileNotFoundError(f'找不到 {sv_file}')
    raw_text = sv_file.read_text(encoding='utf-8', errors='replace')
    rec_db = parse_record_db_from_sv_text(raw_text)
    if not rec_db or not rec_db.get('sessions'):
        return None, 'kkowoUI.lua 中尚无已保存的实机录像会话'

    names = psw.collect_profile_names(str(pathlib.Path(acc) / 'SavedVariables')) | psw.char_folder_names(acc)
    acct_id = pathlib.Path(acc).name.split('#')[0]
    if acct_id and len(acct_id) >= 3:
        names.add(acct_id)

    cleaned = scrub_recording_data(rec_db, names)
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    dest_dir = pathlib.Path(out_root or REVIEW_RECORDINGS) / stamp
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest_file = dest_dir / 'recording.json'
    dest_file.write_text(json.dumps(cleaned, ensure_ascii=False, indent=2), encoding='utf-8')
    return dest_file, f'已导入并清洗 {len(cleaned.get("sessions", []))} 段录像 -> {dest_file}'


def _unpack_tuple_js_to_lua(lua, mock, tup, api_name):
    """在 Lua 环境里根据录制元组构造返回多值的闭包（严格区分 n=0 与 nil 及机密哨兵）。"""
    if not isinstance(tup, dict):
        return None
    if tup.get('missing'):
        return None
    if tup.get('ok') is False:
        return lua.eval('function() error("recorded_api_error:' + api_name + '") end')
    n = int(tup.get('n', 0) or 0)
    vals = tup.get('v') or []
    if isinstance(vals, dict):
        vals = [vals.get(str(i)) for i in range(1, n + 1)]
    if n == 0:
        return lua.eval('function() return end')
    arr = lua.table()
    for i in range(n):
        item = vals[i] if i < len(vals) else None
        if not isinstance(item, dict):
            arr[i + 1] = None
        elif item.get('s'):
            arr[i + 1] = mock.NewSecret(f'{api_name}:{i + 1}')
        elif item.get('t') == 'nil':
            arr[i + 1] = None
        else:
            arr[i + 1] = item.get('v')
    maker = lua.eval('''function(tbl, count)
        return function()
            return unpack(tbl, 1, count)
        end
    end''')
    return maker(arr, n)


def calibrate_mock_diff(sessions):
    """将录像中的真实观测与 wow_mock.lua 默认行为逐项对比，返回差异清单。"""
    diffs = []
    seen = set()

    def add_diff(api, mock_default, observed, detail):
        key = (api, observed)
        if key in seen:
            return
        seen.add(key)
        diffs.append({
            'api': api,
            'mockDefault': mock_default,
            'observed': observed,
            'detail': detail,
        })

    for sess in sessions:
        entries = sess.get('entries') or []
        for e in entries:
            ctx = e.get('ctx') or {}
            if ctx.get('inst'):
                add_diff(
                    'IsInInstance()',
                    'false, "none"',
                    f'true, "{ctx.get("instType", "?")}"',
                    f'录像处于副本 {ctx.get("instName", "?")}，需按帧切换 SetInstanceMode',
                )
            apis = e.get('apis') or {}
            for api_name, payload in apis.items():
                if not isinstance(payload, dict):
                    continue
                if 'n' in payload and payload.get('ok'):
                    n = int(payload.get('n', 0) or 0)
                    vals = payload.get('v') or []
                    if isinstance(vals, dict):
                        vals = [vals.get(str(i)) for i in range(1, n + 1)]
                    if n == 0:
                        add_diff(api_name, '单返回值/nil', '0 返回值 (n=0)', f'事件 {e.get("ev")} 观测到零返回')
                    for idx, item in enumerate(vals, 1):
                        if isinstance(item, dict) and item.get('s'):
                            add_diff(
                                f'{api_name}[#{idx}]',
                                '明文默认返回值',
                                f'机密值 (type={item.get("t")}, secret=true)',
                                f'事件 {e.get("ev")}（combat={ctx.get("combat")}, inst={ctx.get("instType")}）',
                            )
                elif api_name == 'nameplate' and payload.get('forbidden'):
                    add_diff('C_NamePlate.GetNamePlateForUnit', '普通可读框体', 'IsForbidden()=true', f'事件 {e.get("ev")}')
                elif api_name == 'lootFrame' and payload.get('protected'):
                    add_diff('LootFrame:IsProtected()', 'false', 'true', f'事件 {e.get("ev")}')
    return diffs


def replay_session(session, create_env_fn, load_order, file_overrides=None, check_disable_restore=True):
    """
    在全新 wow_mock.lua 环境中按时间戳与事件顺序确定性回放单段录像。
    返回结构化报告（含错误、战斗受保护违规、隐形挡点击检查、mark 对拍、停用还原结果）。
    """
    lua, mock, load_addon = create_env_fn()
    # 记录加载插件前的原始外部函数引用，用于验证模块停用后完整还原
    lua.execute('''
        _G.__REPLAY_ORIG_EUI = {
            SetCVar = _G.EllesmereUI and _G.EllesmereUI.SetCVar,
            CleanCastName = _G.EllesmereUI and _G.EllesmereUI.CleanCastName,
            GetTooltipBg = _G.EllesmereUI and _G.EllesmereUI.GetTooltipBg,
        }
    ''')
    for addon_name in load_order:
        load_addon(addon_name, file_overrides=file_overrides)
    mock.FireEvent('PLAYER_LOGIN')
    mock.FireEvent('PLAYER_ENTERING_WORLD', True, False)
    mock.AdvanceTime(5.0)
    # 载入 Options 以使用战斗安全 ClickCheck
    lua.eval('C_AddOns.LoadAddOn("kkowoUI_Options")')
    # 关闭 LiveRecorder 本身在回放期间重复录制，避免干扰被测模块
    lua.execute('''
        if _G.kkowoUI and _G.kkowoUI.Recorder then
            local db = _G.kkowoUI.Recorder.GetDB()
            db.armed = false
            db.recording = false
        end
    ''')

    # 按录像动态覆盖的原生框体辅助器
    lua.execute('''
        function _G.__REPLAY_SYNC_NATIVE_ROLL(nr)
            if type(nr) ~= "table" then return end
            for key, st in pairs(nr) do
                if type(st) == "table" and not st.forbidden then
                    local f = _G[key]
                    if not f and st.shown then
                        f = CreateFrame("Frame", key, UIParent)
                        f:SetSize(277, 67)
                        f:EnableMouse(st.mouseEnabled ~= false)
                        if f.SetMouseClickEnabled then f:SetMouseClickEnabled(st.mouseClick ~= false) end
                        f._protected = st.protected == true
                        _G[key] = f
                    end
                    if f then
                        if st.shown then f:Show() else f:Hide() end
                        if st.alpha ~= nil then f:SetAlpha(st.alpha) end
                    end
                end
            end
        end
    ''')

    entries = session.get('entries') or []
    prev_t = None
    lua_errors = []
    protected_violations = []
    mark_comparisons = []
    roll_item_cache = {}
    roll_time_cache = {}

    # 安装可动态切换的 API 代理
    g = lua.globals()
    orig_apis = {
        'GetLootRollItemInfo': g.GetLootRollItemInfo,
        'GetLootRollTimeLeft': g.GetLootRollTimeLeft,
        'GetActiveLootRollIDs': g.GetActiveLootRollIDs,
        'UnitHealth': g.UnitHealth,
        'UnitHealthMax': g.UnitHealthMax,
        'UnitPower': g.UnitPower,
        'UnitPowerMax': g.UnitPowerMax,
        'UnitPowerType': g.UnitPowerType,
        'UnitAffectingCombat': g.UnitAffectingCombat,
        'UnitExists': g.UnitExists,
        'UnitCastingInfo': g.UnitCastingInfo,
        'UnitChannelInfo': g.UnitChannelInfo,
        'GetNumLootItems': g.GetNumLootItems,
        'LootSlotHasItem': g.LootSlotHasItem,
    }

    def apply_api_tuple(global_name, tup):
        fn = _unpack_tuple_js_to_lua(lua, mock, tup, global_name)
        if fn is not None:
            g[global_name] = fn

    mock.ClearProtectedViolations()

    for idx, entry in enumerate(entries):
        ctx = entry.get('ctx') or {}
        ev = entry.get('ev') or ''
        t = ctx.get('t')
        if isinstance(t, (int, float)):
            if prev_t is not None and t > prev_t:
                dt = min(float(t - prev_t), 10.0)
                steps = max(1, min(20, int(dt * 10)))
                mock.StepTime(dt, steps)
            prev_t = t

        # 同步环境上下文
        mock.SetInstanceMode(bool(ctx.get('inst')), str(ctx.get('instType') or 'none'), str(ctx.get('instName') or 'World'))
        mock.SetInCombat(bool(ctx.get('combat')))
        grp = ctx.get('grp') or 'solo'
        grp_n = int(ctx.get('grpN') or 0)
        g.IsInRaid = lua.eval(f'function() return {"true" if grp == "raid" else "false"} end')
        g.IsInGroup = lua.eval(f'function() return {"true" if grp in ("party", "raid") else "false"} end')
        g.GetNumGroupMembers = lua.eval(f'function() return {grp_n} end')

        # 同步该事件时刻捕获的 API 快照
        apis = entry.get('apis') or {}
        for simple_api in (
            'UnitHealth', 'UnitHealthMax', 'UnitPower', 'UnitPowerMax', 'UnitPowerType',
            'UnitAffectingCombat', 'UnitCastingInfo', 'UnitChannelInfo',
            'GetNumLootItems',
        ):
            if simple_api in apis:
                apply_api_tuple(simple_api, apis[simple_api])
        if 'UnitExistsTarget' in apis:
            tgt_fn = _unpack_tuple_js_to_lua(lua, mock, apis['UnitExistsTarget'], 'UnitExists')
            if tgt_fn is not None:
                g.UnitExists = lua.eval('function(f) return function(u) if u == "target" then return f() end return u == "player" end end')(tgt_fn)
        if 'LootSlotHasItem1' in apis:
            apply_api_tuple('LootSlotHasItem', apis['LootSlotHasItem1'])
        if 'GetLootRollItemInfo' in apis or 'GetLootRollTimeLeft' in apis:
            args_v = (entry.get('args') or {}).get('v') or []
            rid = args_v[0].get('v') if (args_v and isinstance(args_v[0], dict) and not args_v[0].get('s')) else None
            if 'GetLootRollItemInfo' in apis:
                fn = _unpack_tuple_js_to_lua(lua, mock, apis['GetLootRollItemInfo'], 'GetLootRollItemInfo')
                if fn is not None:
                    if rid is not None:
                        roll_item_cache[rid] = fn
                    else:
                        g.GetLootRollItemInfo = fn
            if 'GetLootRollTimeLeft' in apis:
                fn = _unpack_tuple_js_to_lua(lua, mock, apis['GetLootRollTimeLeft'], 'GetLootRollTimeLeft')
                if fn is not None:
                    if rid is not None:
                        roll_time_cache[rid] = fn
                    else:
                        g.GetLootRollTimeLeft = fn
            if roll_item_cache:
                tbl = lua.table_from(roll_item_cache)
                g.GetLootRollItemInfo = lua.eval('function(m, fb) return function(id) if m[id] then return m[id]() end if fb then return fb(id) end end end')(tbl, orig_apis['GetLootRollItemInfo'])
            if roll_time_cache:
                tbl = lua.table_from(roll_time_cache)
                g.GetLootRollTimeLeft = lua.eval('function(m, fb) return function(id) if m[id] then return m[id]() end if fb then return fb(id) end end end')(tbl, orig_apis['GetLootRollTimeLeft'])
        if 'activeRollIDs' in apis and isinstance(apis['activeRollIDs'], dict):
            ar = apis['activeRollIDs']
            if ar.get('ok') and isinstance(ar.get('list'), list):
                ids_tbl = lua.table()
                for k_i, item in enumerate(ar['list'], 1):
                    ids_tbl[k_i] = mock.NewSecret(f'activeRollID:{k_i}') if item.get('s') else item.get('v')
                g.GetActiveLootRollIDs = lua.eval('function(t) return function() return t end end')(ids_tbl)
        if 'nativeRoll' in apis and isinstance(apis['nativeRoll'], dict):
            # Convert nested dict into lua table for sync helper
            nr_lua = lua.table()
            for fk, fv in apis['nativeRoll'].items():
                if isinstance(fv, dict):
                    nr_lua[fk] = lua.table_from(fv)
            g.__REPLAY_SYNC_NATIVE_ROLL(nr_lua)
        if 'weaponEnchants' in apis and isinstance(apis['weaponEnchants'], dict):
            we = apis['weaponEnchants']
            if 'cItem' in we:
                fn = _unpack_tuple_js_to_lua(lua, mock, we['cItem'], 'C_Item.GetWeaponEnchantInfo')
                if fn is not None:
                    if g.C_Item is None:
                        g.C_Item = lua.table()
                    g.C_Item.GetWeaponEnchantInfo = fn
            if 'aurasSecret' in we:
                fn = _unpack_tuple_js_to_lua(lua, mock, we['aurasSecret'], 'C_Secrets.ShouldAurasBeSecret')
                if fn is not None:
                    if g.C_Secrets is None:
                        g.C_Secrets = lua.table()
                    g.C_Secrets.ShouldAurasBeSecret = fn
        if 'nameplate' in apis and isinstance(apis['nameplate'], dict):
            np = apis['nameplate']
            args_v = (entry.get('args') or {}).get('v') or []
            u_tok = args_v[0].get('v') if (args_v and isinstance(args_v[0], dict)) else 'nameplate1'
            if np.get('exists'):
                plate = mock.CreateForbiddenPlate() if np.get('forbidden') else lua.eval('CreateFrame("Frame", nil, WorldFrame)')
                mock.SetMockNameplates(lua.table_from({1: plate, u_tok: plate}))
            else:
                mock.SetMockNameplates(lua.table())

        # 特殊事件：USER_MARK -> 输出当时框体状态对比
        if ev == 'USER_MARK':
            cc_now = lua_table_to_python(g.kkowoUI._Diagnostics.ScanClickBlockers(lua.table()))
            mark_comparisons.append({
                'seq': entry.get('seq', idx + 1),
                'note': entry.get('note', ''),
                'recordedClickcheck': entry.get('clickcheck') or {},
                'replayedBlockerCount': len(cc_now.get('invisibleBlockers') or []),
                'replayedKkowoBlockers': [
                    b.get('name') for b in (cc_now.get('byOwner', {}).get('kkowoUI') or [])
                ],
            })
            continue

        if ev in ('SESSION_START', 'SESSION_END', ''):
            continue

        # 还原事件参数并派发
        args_spec = entry.get('args') or {}
        n_args = int(args_spec.get('n', 0) or 0)
        raw_v = args_spec.get('v') or []
        if isinstance(raw_v, dict):
            raw_v = [raw_v.get(str(i)) for i in range(1, n_args + 1)]
        ev_args = []
        for ai in range(n_args):
            it = raw_v[ai] if ai < len(raw_v) else None
            if not isinstance(it, dict) or it.get('t') == 'nil':
                ev_args.append(None)
            elif it.get('s'):
                ev_args.append(mock.NewSecret(f'{ev}:arg{ai + 1}'))
            else:
                ev_args.append(it.get('v'))

        try:
            mock.FireEvent(ev, *ev_args)
            mock.StepTime(0.05, 1)
        except Exception as exc:
            lua_errors.append(f'#{idx + 1} {ev}: {exc}')

    # 推进尾部延迟计时器，确保动画与退场全部落定
    mock.StepTime(2.0, 20)

    # 收集战斗违规与隐形挡点击不变量（排除有意的 CoreHUD 透明安全单位点击层）
    allowed_click_layers = {
        'kkowoUI_HUDClick_player', 'kkowoUI_HUDClick_pet',
        'kkowoUI_HUDClick_target', 'kkowoUI_HUDClick_targettarget',
    }
    protected_violations = [str(v) for v in mock.GetProtectedViolations().values()]
    cc_final = lua_table_to_python(g.kkowoUI._Diagnostics.ScanClickBlockers(lua.table()))
    kkowo_blockers = [
        f"{b.get('name')}({b.get('reason')})"
        for b in (cc_final.get('byOwner', {}).get('kkowoUI') or [])
        if b.get('name') not in allowed_click_layers
    ]
    # 也检查 RollBars 活跃条体是否误开左/右键点击（针对 7813558 等历史回归）
    blizz_roll_blockers = [
        f"{b.get('name')}({b.get('reason')})"
        for b in (cc_final.get('byOwner', {}).get('Blizzard') or [])
        if 'GroupLoot' in str(b.get('name') or '')
    ]

    # 检查停用还原不变量
    restore_failures = []
    if check_disable_restore:
        mock.SetInCombat(False)
        for mkey in ('rollBars', 'immersiveHUD', 'weaponProcs', 'euiRuntimeFixes', 'modernChrome'):
            try:
                lua.execute(f'local m = _G.kkowoUI.Modules.Get("{mkey}"); if m then m:SetEnabled(false) end')
            except Exception as exc:
                restore_failures.append(f'disable {mkey}: {exc}')
        mock.StepTime(0.5, 5)
        eui_ok = lua.eval('''(function()
            local o = _G.__REPLAY_ORIG_EUI
            local e = _G.EllesmereUI
            if not (o and e) then return true end
            return e.SetCVar == o.SetCVar and e.CleanCastName == o.CleanCastName
        end)()''')
        if not eui_ok:
            restore_failures.append('停用后 EllesmereUI 原函数引用未完整还原')

    return {
        'sessionId': session.get('id'),
        'instanceName': session.get('instanceName'),
        'eventCount': len(entries),
        'luaErrors': lua_errors,
        'protectedViolations': protected_violations,
        'kkowoBlockers': kkowo_blockers,
        'blizzRollBlockers': blizz_roll_blockers,
        'markComparisons': mark_comparisons,
        'restoreFailures': restore_failures,
        'passed': (
            not lua_errors
            and not protected_violations
            and not kkowo_blockers
            and not blizz_roll_blockers
            and not restore_failures
        ),
    }


def build_sample_dungeon_roll_recording():
    """无任何隐私信息的标准格式样例录像（模拟 5 人副本内掷点+机密时间+进战+打标+重载+结束）。"""
    return {
        'schemaVersion': 1,
        'sessions': [{
            'id': 'sample_dungeon_roll_v1',
            'startedAt': '2026-11-28 00:00:00',
            'addonVersion': '2.0.0',
            'locale': 'zhCN',
            'instanceType': 'party',
            'instanceName': '死亡矿井',
            'instanceID': 36,
            'entries': [
                {
                    'seq': 1,
                    'ev': 'PLAYER_ENTERING_WORLD',
                    'ctx': {'t': 10.0, 'inst': True, 'instType': 'party', 'instName': '死亡矿井', 'combat': False, 'grp': 'party', 'grpN': 5},
                    'args': {'n': 2, 'v': [{'t': 'boolean', 's': False, 'v': False}, {'t': 'boolean', 's': False, 'v': False}]},
                    'apis': {
                        'UnitHealth': {'ok': True, 'n': 1, 'v': [{'t': 'number', 's': True}]},
                        'UnitHealthMax': {'ok': True, 'n': 1, 'v': [{'t': 'number', 's': True}]},
                    },
                },
                {
                    'seq': 2,
                    'ev': 'PLAYER_REGEN_DISABLED',
                    'ctx': {'t': 12.0, 'inst': True, 'instType': 'party', 'instName': '死亡矿井', 'combat': True, 'grp': 'party', 'grpN': 5},
                    'args': {'n': 0, 'v': []},
                    'apis': {
                        'UnitAffectingCombat': {'ok': True, 'n': 1, 'v': [{'t': 'boolean', 's': True}]},
                    },
                },
                {
                    'seq': 3,
                    'ev': 'NAME_PLATE_UNIT_ADDED',
                    'ctx': {'t': 12.5, 'inst': True, 'instType': 'party', 'instName': '死亡矿井', 'combat': True, 'grp': 'party', 'grpN': 5},
                    'args': {'n': 1, 'v': [{'t': 'string', 's': False, 'v': 'nameplate1'}]},
                    'apis': {'nameplate': {'exists': True, 'forbidden': True, 'protected': True}},
                },
                {
                    'seq': 4,
                    'ev': 'START_LOOT_ROLL',
                    'ctx': {'t': 15.0, 'inst': True, 'instType': 'party', 'instName': '死亡矿井', 'combat': True, 'grp': 'party', 'grpN': 5},
                    'args': {'n': 2, 'v': [{'t': 'number', 's': False, 'v': 501}, {'t': 'number', 's': False, 'v': 60000}]},
                    'apis': {
                        'GetLootRollItemInfo': {
                            'ok': True, 'n': 8, 'v': [
                                {'t': 'number', 's': False, 'v': 135489},
                                {'t': 'string', 's': False, 'v': '残酷倒钩'},
                                {'t': 'number', 's': False, 'v': 1},
                                {'t': 'number', 's': False, 'v': 3},
                                {'t': 'boolean', 's': False, 'v': True},
                                {'t': 'boolean', 's': False, 'v': True},
                                {'t': 'boolean', 's': False, 'v': True},
                                {'t': 'boolean', 's': False, 'v': False},
                            ],
                        },
                        'GetLootRollTimeLeft': {'ok': True, 'n': 1, 'v': [{'t': 'number', 's': True}]},
                        'activeRollIDs': {'ok': True, 'count': 1, 'list': [{'t': 'number', 's': False, 'v': 501}]},
                        'nativeRoll': {
                            'GroupLootContainer': {'shown': True, 'visible': True, 'mouseClick': True, 'mouseEnabled': True, 'protected': False, 'alpha': 1},
                            'GroupLootFrame1': {'shown': True, 'visible': True, 'mouseClick': True, 'mouseEnabled': True, 'protected': False, 'alpha': 1},
                        },
                    },
                },
                {
                    'seq': 5,
                    'ev': 'USER_MARK',
                    'note': '掷点弹出检查',
                    'ctx': {'t': 16.0, 'inst': True, 'instType': 'party', 'instName': '死亡矿井', 'combat': True, 'grp': 'party', 'grpN': 5},
                    'clickcheck': {'source': 'sample', 'mouseFoci': [], 'invisibleBlockers': []},
                },
                {
                    'seq': 6,
                    'ev': 'PLAYER_REGEN_ENABLED',
                    'ctx': {'t': 18.0, 'inst': True, 'instType': 'party', 'instName': '死亡矿井', 'combat': False, 'grp': 'party', 'grpN': 5},
                    'args': {'n': 0, 'v': []},
                    'apis': {
                        'UnitAffectingCombat': {'ok': True, 'n': 1, 'v': [{'t': 'boolean', 's': False, 'v': False}]},
                    },
                },
                {
                    'seq': 7,
                    'ev': 'CANCEL_LOOT_ROLL',
                    'ctx': {'t': 20.0, 'inst': True, 'instType': 'party', 'instName': '死亡矿井', 'combat': False, 'grp': 'party', 'grpN': 5},
                    'args': {'n': 1, 'v': [{'t': 'number', 's': False, 'v': 501}]},
                    'apis': {
                        'activeRollIDs': {'ok': True, 'count': 0, 'list': []},
                        'nativeRoll': {
                            'GroupLootContainer': {'shown': True, 'visible': True, 'mouseClick': True, 'mouseEnabled': True, 'protected': False, 'alpha': 1},
                            'GroupLootFrame1': {'shown': False, 'visible': False, 'mouseClick': False, 'mouseEnabled': False, 'protected': False, 'alpha': 1},
                        },
                    },
                },
                {
                    'seq': 8,
                    'ev': 'PLAYER_ENTERING_WORLD',
                    'ctx': {'t': 24.0, 'inst': False, 'instType': 'none', 'instName': '西部荒野', 'combat': False, 'grp': 'solo', 'grpN': 0},
                    'args': {'n': 2, 'v': [{'t': 'boolean', 's': False, 'v': False}, {'t': 'boolean', 's': False, 'v': False}]},
                    'apis': {},
                },
            ],
        }],
    }


def discover_recordings(root=None):
    base = pathlib.Path(root or REVIEW_RECORDINGS)
    if not base.is_dir():
        return []
    return sorted(base.rglob('*.json'))


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description='kkowoUI 实机录像导入与离线回放')
    ap.add_argument('--import', dest='do_import', action='store_true', help='从游戏 SavedVariables 读取、清洗并导出到 review/recordings/')
    ap.add_argument('--replay', default='', help='回放指定 JSON 录像文件')
    ap.add_argument('--scan', action='store_true', help='扫描并回放 review/recordings/ 下全部录像')
    args = ap.parse_args()

    if args.do_import:
        dest, msg = import_from_game()
        print(msg)
        return 0 if dest else 1

    sys.path.insert(0, str(HERE))
    import run_tests as rt

    files = []
    if args.replay:
        files = [pathlib.Path(args.replay)]
    elif args.scan:
        files = discover_recordings()
        if not files:
            print(f'[SKIP] {REVIEW_RECORDINGS} 下尚无实机录像文件')
            return 0
    else:
        ap.print_help()
        return 0

    any_fail = False
    for fp in files:
        data = json.loads(fp.read_text(encoding='utf-8'))
        sessions = data.get('sessions') if isinstance(data, dict) else []
        diffs = calibrate_mock_diff(sessions)
        print(f'=== 回放 {fp}（{len(sessions)} 段会话，校准差异 {len(diffs)} 项）===')
        for d in diffs:
            print(f'  [DIFF] {d["api"]}: mock={d["mockDefault"]} vs 实机={d["observed"]} ({d["detail"]})')
        for sess in sessions:
            res = replay_session(sess, rt.create_env, rt.LOAD_ORDER)
            status = 'PASS' if res['passed'] else 'FAIL'
            print(f'  [{status}] {res["sessionId"]} ({res["instanceName"]}, {res["eventCount"]}条) errs={len(res["luaErrors"])} viol={len(res["protectedViolations"])} blockers={res["kkowoBlockers"] + res["blizzRollBlockers"]}')
            if not res['passed']:
                any_fail = True
    return 1 if any_fail else 0


if __name__ == '__main__':
    sys.exit(main())
