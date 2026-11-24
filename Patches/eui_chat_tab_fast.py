# -*- coding: utf-8 -*-
"""
补丁：EllesmereUIChat 聊天标签页点击瞬时切换优化（v1，零污染）
根因修复：
  1) follower OnUpdate 原先在 accum < 0.1 (100ms) 后才检测 FCFDock_GetSelectedWindow 变化，
     再经 QueueTabPass + TabsRefresh 两轮 C_Timer.After(0)，导致点击标签延迟 ~150ms；
  2) 切换停靠标签时旧/新 ChatFrame 的 IsShown() 变化误触发重型 QueueFullPass（遍历 20 个窗口重设字体与引擎）；
  3) StyleGhost 对每个标签重复调用 RefreshBgTextureCatalogue()，切一次标签重建十余次材质目录。
优化后：零污染在 follower 当帧同步切换面板与高亮，缓存材质路径，点击 0ms 丝滑响应。
"""
import os, re, shutil, sys

# 游戏目录与备份目录可用环境变量覆盖：WOW_FOREVER_DIR（含 Interface 的客户端根目录）/ WOW_BACKUP_ROOT
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'EllesmereUIChat')
# 默认放在仓库同级的 backups 目录（绝不写进游戏目录）
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')))
MARK = '[fui-chat-fasttab v1]'

FILE_PATCHES = {
    'EllesmereUIChat.lua': [
        (
            '''        -- State compares are cheaper at a coarse cadence.
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
        end''',
            '''        -- [fui-chat-fasttab v1] 选中标签切换改为当帧即时检测与同步刷新（零 100ms 延迟、不误触 QueueFullPass）
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
            '''    -- [fui-chat-fasttab v1] 按标签材质键缓存解析结果，避免每次切换对 6+ 标签重复遍历 SharedMedia
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
        for old, new in pairs:
            if text.count(old) != 1:
                return ('ANCHOR_MISMATCH', f'{fname} 锚点匹配数={text.count(old)}（EUI 可能已更新）')
            text = text.replace(old, new)
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
