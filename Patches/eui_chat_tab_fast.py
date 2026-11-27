# -*- coding: utf-8 -*-
"""
补丁：EllesmereUIChat 聊天标签页点击瞬时切换优化（v5，零污染）
根因修复：
  1) follower OnUpdate 原先在 accum < 0.1 (100ms) 后才检测 FCFDock_GetSelectedWindow 变化，
     再经 QueueTabPass + TabsRefresh 两轮 C_Timer.After(0)，导致点击标签延迟 ~150ms；
  2) 切换停靠标签时旧/新 ChatFrame 的 IsShown() 变化误触发重型 QueueFullPass（遍历 20 个窗口重设字体与引擎）；
  3) StyleGhost 对每个标签重复调用 RefreshBgTextureCatalogue()，切一次标签重建十余次材质目录；
  4) 切换到「战斗记录」（ChatFrame2）时，原版将渲染交回暴雪原生 FontStringContainer 与 ScrollBar，
     导致右侧弹出未美化/错位的暴雪老滑块，且切换瞬间因字号/行距/重过滤产生“重载标签页”跳变感。
     v5 改为与综合/私聊/队伍完全一致的 EUI 统一引擎渲染（win.smf + EUI 极细滑块）：
       • 模块加载期即写入 ns._kkowoFastTab = true / ns._kkowoFastTabVer = 5（无需先悬停即可通过自检）；
       • 永久隐藏暴雪 ChatFrame2.ScrollBar.Track（零滑块错位），超链接热区仍由暴雪隐形容器安全接管；
       • 切入或点击「我的动作 / 我发生了什么？」过滤按钮时静默隐藏进度条并锁定画面，待暴雪过滤稳定 2 帧后原子差分同步。
"""
import os, re, shutil, sys

# 游戏目录与备份目录可用环境变量覆盖：WOW_FOREVER_DIR（含 Interface 的客户端根目录）/ WOW_BACKUP_ROOT
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'EllesmereUIChat')
# 默认放在仓库同级的 backups 目录（绝不写进游戏目录）
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')))
MARK = '[fui-chat-fasttab v5]'
OLD_MARKS = ('[fui-chat-fasttab v1]', '[fui-chat-fasttab v2]', '[fui-chat-fasttab v3]', '[fui-chat-fasttab v4]')

# 9.9.2 原版锚点；9.9.3 起注释里的 colour 改成了 color，代码本身未变，两种拼写都接受
_FOLLOWER_OLD = '''        -- State compares are cheaper at a coarse cadence.
        accum = accum + elapsed
        if accum < 0.1 then return end
        accum = 0
        -- Edit Mode self-heal: OnHide is the normal disarm; this covers a missed
        -- one (reload inside Edit Mode etc.).
        if editMode and EditModeManagerFrame and not EditModeManagerFrame:IsShown() then
            editMode = false
        end
        -- Selected dock window changed (tab click, tab menu action).
        if GENERAL_CHAT_DOCK and FCFDock_GetSelectedWindow then
            local sel = FCFDock_GetSelectedWindow(GENERAL_CHAT_DOCK)
            if sel ~= lastSelected then
                lastSelected = sel
                if ECHAT.QueueTabPass then ECHAT.QueueTabPass() end
                -- Stock sidebar: the scroll flash follows the selected window.
                if ECHAT.SB_FlashSync then ECHAT.SB_FlashSync() end
            end
            -- Blizzard Style sidebar backdrop: the selected window's stored
            -- colour (tab-menu colour and opacity edits land while armed).
            if ECHAT.SB_SyncBackdrop then ECHAT.SB_SyncBackdrop() end
        end'''

_ENGINE_TAIL_OLD = '''    if win then
        win.smf:AddMessage(display, r, g, b, chatTypeID, ExtractLineID(eventArgs), event)
        -- Scrolled-view DOUBLE-PIN fix (field report 2026-08-16: "chat moves
        -- one line on a new message while scrolled, every zone off by one
        -- message after"): SMF:AddMessage auto-pins a scrolled view via an
        -- INTERNAL ScrollUp (Blizzard source, ScrollingMessageFrame.lua:12).
        -- cf's internal ScrollUp fires the scroll mirror mid-add (our offset
        -- = cf's pinned offset), and our own AddMessage above then auto-pins
        -- AGAIN -- one line past cf, visible text drifting off Blizzard's
        -- invisible interaction zones until the next wheel step re-mirrors.
        -- cf's offset is the scroll authority at every add: re-copy it after
        -- our add. No-op at bottom (0 == 0) and SetScrollOffset early-outs
        -- when equal, so the settled path stays zero-write.
        win.smf:SetScrollOffset(cf:GetScrollOffset())
        -- Divergence check: if Blizzard's buffer was cleared behind our back
        -- (window reset, a third-party Clear call, temp-window pool reuse),
        -- its count falls below ours the moment the next line lands. Both
        -- counts are cheap reads; the rebuild is deferred + coalesced.
        if cf:GetNumMessages() < win.smf:GetNumMessages() then
            if QueueDivergedRebuild then QueueDivergedRebuild(cf) end
        end
    end'''

_ENGINE_CLHOST_OLD = '''function ECHAT.EngineUpdateCombatLogHost()
    local cf2 = _G.ChatFrame2
    if not cf2 or not IsCombatLog or not IsCombatLog(cf2) then return end
    local selected = GENERAL_CHAT_DOCK and FCFDock_GetSelectedWindow
        and FCFDock_GetSelectedWindow(GENERAL_CHAT_DOCK)
    local host = (selected == cf2)
    if host == (ns._clHosted or false) then return end
    ns._clHosted = host
    local win = WINS[cf2]
    local fsc = cf2.FontStringContainer
    local bar = cf2.ScrollBar
    if host then
        if fsc then fsc:SetAlpha(1) end
        if bar then
            if bar.Track then bar.Track:SetAlpha(1) end
            SetBarMouse(bar, true)
        end
        if win then
            win.smf:Hide()
        end
    else
        if fsc then fsc:SetAlpha(0) end
        if bar then
            if bar.Track then bar.Track:SetAlpha(0) end
            SetBarMouse(bar, false)
        end
        if win then
            win.smf:Show()
            local theirs = cf2:GetNumMessages()
            if theirs < win.smf:GetNumMessages() then
                RebuildWindowFromBuffer(cf2)
            end
        end
    end
end'''

FILE_PATCHES = {
    'EllesmereUIChat.lua': [
        (
            (_FOLLOWER_OLD, _FOLLOWER_OLD.replace('colour', 'color')),
            '''        -- [fui-chat-fasttab v5] 选中标签切换改为当帧即时检测与同步刷新 + 战斗记录统一引擎零闪烁
        ns._kkowoFastTab = true
        ns._kkowoFastTabVer = 5
        if GENERAL_CHAT_DOCK and FCFDock_GetSelectedWindow then
            local sel = FCFDock_GetSelectedWindow(GENERAL_CHAT_DOCK)
            if sel ~= lastSelected then
                local prevSel = lastSelected
                lastSelected = sel
                if prevSel and prevSel.GetID then
                    local pid = prevSel:GetID()
                    if pid then lastShown[pid] = prevSel:IsShown() or false end
                end
                if sel and sel.GetID then
                    local sid = sel:GetID()
                    if sid then lastShown[sid] = sel:IsShown() or false end
                end
                ECHAT.SyncChatFrameState()
                if ECHAT.TabsRefreshNow then ECHAT.TabsRefreshNow() end
                if ECHAT.EngineUpdateCombatLogHost then ECHAT.EngineUpdateCombatLogHost() end
                if ECHAT.SB_FlashSync then ECHAT.SB_FlashSync() end
                if ECHAT.SB_SyncBackdrop then ECHAT.SB_SyncBackdrop() end
            end
        end
        if ns._clRefilterHold and ECHAT.EngineTickCombatLogHold then
            ECHAT.EngineTickCombatLogHold()
        end
        -- State compares are cheaper at a coarse cadence.
        accum = accum + elapsed
        if accum < 0.1 then return end
        accum = 0
        -- Edit Mode self-heal: OnHide is the normal disarm; this covers a missed
        -- one (reload inside Edit Mode etc.).
        if editMode and EditModeManagerFrame and not EditModeManagerFrame:IsShown() then
            editMode = false
        end
        if GENERAL_CHAT_DOCK and FCFDock_GetSelectedWindow then
            if ECHAT.SB_SyncBackdrop then ECHAT.SB_SyncBackdrop() end
        end''',
        ),
    ],
    'EllesmereUIChat_Tabs.lua': [
        (
            '''    local texKey = cfg.tabBackgroundTexture or "none"
    local texPath
    if texKey ~= "none" then
        if ECHAT.RefreshBgTextureCatalogue then ECHAT.RefreshBgTextureCatalogue() end
        if EUI.ResolveTexturePath then
            texPath = EUI.ResolveTexturePath(ns.chatBgTextures, texKey, nil)
        else
            texPath = ns.chatBgTextures and ns.chatBgTextures[texKey]
        end
    end''',
            '''    -- [fui-chat-fasttab v5] 按标签材质键缓存解析结果，避免每次切换对 6+ 标签重复遍历 SharedMedia
    local texKey = cfg.tabBackgroundTexture or "none"
    local texPath
    if texKey ~= "none" then
        if ns._fuiTabTexKey ~= texKey or not ns._fuiTabTexPath then
            if ECHAT.RefreshBgTextureCatalogue then ECHAT.RefreshBgTextureCatalogue() end
            local resolved
            if EUI.ResolveTexturePath then
                resolved = EUI.ResolveTexturePath(ns.chatBgTextures, texKey, nil)
            else
                resolved = ns.chatBgTextures and ns.chatBgTextures[texKey]
            end
            ns._fuiTabTexKey = texKey
            ns._fuiTabTexPath = resolved
        end
        texPath = ns._fuiTabTexPath
    end''',
        ),
    ],
    'EllesmereUIChat_Engine.lua': [
        (
            _ENGINE_TAIL_OLD,
            '''    -- [fui-chat-fasttab v5] 战斗记录过滤回填期间保持 win.smf 画面稳定，不被中间态冲清
    if win and not (ns._clRefilterHold and IsCombatLog and IsCombatLog(cf)) then
        win.smf:AddMessage(display, r, g, b, chatTypeID, ExtractLineID(eventArgs), event)
        win.smf:SetScrollOffset(cf:GetScrollOffset())
        if cf:GetNumMessages() < win.smf:GetNumMessages() then
            if QueueDivergedRebuild then QueueDivergedRebuild(cf) end
        end
    end''',
        ),
        (
            _ENGINE_CLHOST_OLD,
            '''-- [fui-chat-fasttab v5] 战斗记录统一引擎零闪烁渲染（模块加载期置位版本标记 + 永久隐藏暴雪旧滑块 + 过滤静默原子同步）
ns._kkowoFastTab = true
ns._kkowoFastTabVer = 5

local function RestoreCombatLogProgAlpha()
    if ns._clHidProg then
        ns._clHidProg = nil
        local prog = _G.CombatLogQuickButtonFrameProgressBar
        if prog and prog.SetAlpha then prog:SetAlpha(1) end
    end
end

local function KeepCombatLogUnified(cf2, win)
    ns._clHosted = false
    local fsc = cf2.FontStringContainer
    local bar = cf2.ScrollBar
    if fsc then fsc:SetAlpha(0) end
    if bar then
        if bar.Track then bar.Track:SetAlpha(0) end
        SetBarMouse(bar, false)
    end
    if win then
        if cf2.GetMaxLines and win.smf.SetMaxLines then
            local ml = max(300, cf2:GetMaxLines() or 300)
            if (win.smf:GetMaxLines() or 0) < ml then
                win.smf:SetMaxLines(ml)
            end
        end
        win.smf:Show()
    end
end

local function ArmCombatLogSyncHold(cf2, forceRebuild)
    ns._clRefilterHold = true
    ns._clHoldStart = GetTime()
    ns._clHoldLastN = cf2:GetNumMessages() or 0
    ns._clHoldStable = 0
    if forceRebuild then ns._clForceRebuild = true end
    local prog = _G.CombatLogQuickButtonFrameProgressBar
    if prog and prog.SetAlpha then
        prog:SetAlpha(0)
        ns._clHidProg = true
    end
    if ECHAT.FollowKick then ECHAT.FollowKick() end
end

local function HookCombatLogFilterButtons()
    if ns._clFilterBtnsHooked then return end
    local qbf = _G.CombatLogQuickButtonFrame_Custom
    if not (qbf and qbf.GetChildren) then return end
    ns._clFilterBtnsHooked = true
    local kids = { qbf:GetChildren() }
    for i = 1, #kids do
        local btn = kids[i]
        if btn and btn.HookScript and (btn:IsObjectType("CheckButton") or btn:IsObjectType("Button")) then
            btn:HookScript("OnClick", function()
                local cf2 = _G.ChatFrame2
                if cf2 then ArmCombatLogSyncHold(cf2, true) end
            end)
        end
    end
end

local function FinishCombatLogHold(cf2, win)
    local forceRebuild = ns._clForceRebuild
    ns._clRefilterHold = nil
    ns._clHoldStart = nil
    ns._clHoldLastN = nil
    ns._clHoldStable = nil
    ns._clForceRebuild = nil
    RestoreCombatLogProgAlpha()
    KeepCombatLogUnified(cf2, win)
    if not win then return end
    local theirs = cf2:GetNumMessages() or 0
    local ours = win.smf:GetNumMessages() or 0
    if theirs == 0 then
        if ours > 0 then
            win.smf:Clear()
            SyncBlizzardScroll(win)
        end
    elseif forceRebuild or theirs ~= ours then
        local savedScroll = win.smf:GetScrollOffset() or 0
        RebuildWindowFromBuffer(cf2)
        if not forceRebuild and savedScroll > 0 then
            local maxR = win.smf:GetMaxScrollRange() or 0
            if maxR > 0 then
                win.smf:SetScrollOffset(min(savedScroll, maxR))
                SyncBlizzardScroll(win)
            end
        end
    else
        UpdateScrollbar(win)
    end
end

function ECHAT.EngineTickCombatLogHold()
    if not ns._clRefilterHold then return end
    local cf2 = _G.ChatFrame2
    if not cf2 or not ns._clSelected then
        ns._clRefilterHold = nil
        ns._clForceRebuild = nil
        RestoreCombatLogProgAlpha()
        return
    end
    local win = WINS[cf2]
    KeepCombatLogUnified(cf2, win)
    local prog = _G.CombatLogQuickButtonFrameProgressBar
    if prog and prog.SetAlpha and prog:GetAlpha() ~= 0 then
        prog:SetAlpha(0)
        ns._clHidProg = true
    end
    local refiltering = prog and prog.IsShown and prog:IsShown() or false
    local curN = cf2:GetNumMessages() or 0
    local cachedN = win and win.smf:GetNumMessages() or 0
    local elapsed = GetTime() - (ns._clHoldStart or 0)
    if elapsed > 0.25 and elapsed < 0.85 and ECHAT.FollowKick then
        ECHAT.FollowKick()
    end
    if refiltering and elapsed < 0.85 then
        ns._clHoldLastN = curN
        ns._clHoldStable = 0
        return
    end
    if (not ns._clForceRebuild) and cachedN > 0 and curN == 0 and elapsed < 0.35 then
        ns._clHoldLastN = curN
        ns._clHoldStable = 0
        return
    end
    if curN ~= ns._clHoldLastN then
        ns._clHoldLastN = curN
        ns._clHoldStable = 0
        return
    end
    ns._clHoldStable = (ns._clHoldStable or 0) + 1
    if ns._clHoldStable >= 2 or elapsed >= 0.85 then
        FinishCombatLogHold(cf2, win)
    end
end

function ECHAT.EngineUpdateCombatLogHost()
    local cf2 = _G.ChatFrame2
    if not cf2 or not IsCombatLog or not IsCombatLog(cf2) then return end
    local selected = GENERAL_CHAT_DOCK and FCFDock_GetSelectedWindow
        and FCFDock_GetSelectedWindow(GENERAL_CHAT_DOCK)
    local isSel = (selected == cf2)
    local win = WINS[cf2]
    KeepCombatLogUnified(cf2, win)
    if isSel == (ns._clSelected or false) then return end
    ns._clSelected = isSel
    if isSel then
        HookCombatLogFilterButtons()
        if win then
            LayoutWindowSMF(cf2)
            local theirs = cf2:GetNumMessages() or 0
            local ours = win.smf:GetNumMessages() or 0
            if ours == 0 and theirs > 0 then
                RebuildWindowFromBuffer(cf2)
            end
            UpdateScrollbar(win)
        end
        ArmCombatLogSyncHold(cf2, false)
    else
        ns._clRefilterHold = nil
        ns._clForceRebuild = nil
        RestoreCombatLogProgAlpha()
    end
end''',
        ),
    ],
}


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
    bdir = os.path.join(BACKUP_ROOT, f'EllesmereUIChat_{ver}_原版')

    applied_count = 0
    pending = {}
    for fname, pairs in FILE_PATCHES.items():
        path = os.path.join(addon_dir, fname)
        if not os.path.exists(path):
            return ('MISSING', f'缺少文件: {fname}')
        text, crlf = read_text(path)
        if MARK in text:
            applied_count += 1
            continue
        if any(m in text for m in OLD_MARKS):
            orig_src = os.path.join(bdir, fname)
            if os.path.exists(orig_src):
                text, crlf = read_text(orig_src)
            else:
                # 兜底：若找不到原版备份，从 Upstream/downloads/EllesmereUI-v<ver>.zip 读纯净原版
                z_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'Upstream', 'downloads', f'EllesmereUI-v{ver}.zip')
                if os.path.isfile(z_path):
                    import zipfile
                    with zipfile.ZipFile(z_path, 'r') as zf:
                        arc = f'EllesmereUIChat/{fname}'
                        if arc in zf.namelist():
                            raw = zf.read(arc).decode('utf-8')
                            text, crlf = raw.replace('\r\n', '\n'), '\r\n' in raw
        for old, new in pairs:
            # 锚点可给多个版本的写法，取恰好匹配一次的那个
            olds = old if isinstance(old, tuple) else (old,)
            hit = next((o for o in olds if text.count(o) == 1), None)
            if hit is None:
                counts = '/'.join(str(text.count(o)) for o in olds)
                return ('ANCHOR_MISMATCH', f'{fname} 锚点匹配数={counts}（EUI 可能已更新）')
            text = text.replace(hit, new)
        pending[fname] = (path, text, crlf)

    if applied_count == len(FILE_PATCHES):
        return ('APPLIED', f'已应用 {MARK} (v{ver})')
    if check_only:
        return ('READY', f'可安全应用 {MARK} (v{ver})')

    os.makedirs(bdir, exist_ok=True)
    for fname, (path, text, crlf) in pending.items():
        dst = os.path.join(bdir, fname)
        cur, _ = read_text(path)
        if not os.path.exists(dst) and MARK not in cur:
            shutil.copy2(path, dst)
        out = text.replace('\n', '\r\n') if crlf else text
        open(path, 'wb').write(out.encode('utf-8'))
    return ('PATCHED', f'已成功打补丁 {MARK} (v{ver})')


if __name__ == '__main__':
    chk = '--check' in sys.argv
    args = [a for a in sys.argv[1:] if a != '--check']
    status, msg = run(args[0] if args else DEFAULT_DIR, check_only=chk)
    print(f'[eui_chat_tab_fast] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED') else 1)
