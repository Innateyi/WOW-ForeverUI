# -*- coding: utf-8 -*-
"""
补丁：VamoosesSlipstream 极速导航「死亡后提示跑尸路线」开关
支持 --check 只读检测。
"""
import os, re, shutil, sys

# 游戏目录与备份目录可用环境变量覆盖：WOW_FOREVER_DIR（含 Interface 的客户端根目录）/ WOW_BACKUP_ROOT
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'VamoosesSlipstream')
# 默认放在仓库同级的 backups 目录（绝不写进游戏目录）
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')))
MARK = '[kkowo-corpse v2]'
OLD_MARK = '[kkowo-corpse]'

PATCHES = {
    os.path.join('UI', 'VSS_HUD.lua'): [
        (
            '    answered = VSS.Reactor.signal("")\n',
            '    answered = VSS.Reactor.signal("")\n'
            '    HUD.corpseTick = VSS.Reactor.signal(0) -- [kkowo-corpse v2]\n',
        ),
        (
            '    if version ~= "" then return answered() ~= version and "walk" or nil end\n',
            '    if version ~= "" then\n'
            '        -- [kkowo-corpse v2]\n'
            '        if HUD.corpseTick then HUD.corpseTick() end\n'
            '        if VSS_DB and VSS_DB.config and VSS_DB.config.corpseOffer == false then return nil end\n'
            '        return answered() ~= version and "walk" or nil\n'
            '    end\n',
        ),
    ],
    os.path.join('UI', 'VSS_Settings.lua'): [
        (
            '        function(v) VSS_DB.config.arrivalChime = v end)\n',
            '        function(v) VSS_DB.config.arrivalChime = v end)\n\n'
            '    -- [kkowo-corpse v2]\n'
            '    proxyBool("corpseOffer", "死亡后提示跑尸路线",\n'
            '        "死亡变成鬼魂后，在 HUD 上提示「走回你的尸体」并可一键规划路线。关掉后提示立刻消失，之后也不再弹。", true,\n'
            '        function() return VSS_DB.config.corpseOffer ~= false end,\n'
            '        function(v)\n'
            '            VSS_DB.config.corpseOffer = v\n'
            '            local tick = VSS.HUD and VSS.HUD.corpseTick\n'
            '            if tick then tick(VSS.Reactor.untrack(tick) + 1) end\n'
            '        end)\n',
        ),
    ],
}


def get_version(root):
    for n in os.listdir(root):
        if n.endswith('.toc') and n.startswith('VamoosesSlipstream'):
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
    bdir = os.path.join(BACKUP_ROOT, f'VamoosesSlipstream_{ver}_原版')
    plan = []
    already = True
    for rel, reps in PATCHES.items():
        path = os.path.join(addon_dir, rel)
        text, crlf = read_text(path)
        if MARK in text:
            continue
        already = False
        if OLD_MARK in text:
            src = os.path.join(bdir, rel)
            if not os.path.exists(src):
                return ('OLD_NO_BACKUP', f'{rel} 含旧版补丁且缺少备份 {src}')
            text, crlf = read_text(src)
        for old, new in reps:
            if text.count(old) != 1:
                return ('ANCHOR_MISMATCH', f'{rel} 锚点匹配数={text.count(old)}')
            text = text.replace(old, new)
        plan.append((rel, path, text, crlf))
    if already:
        return ('APPLIED', f'已应用 {MARK} (v{ver})')
    if check_only:
        return ('READY', f'可安全应用 {MARK} (v{ver})')
    for rel, path, _, _ in plan:
        dst = os.path.join(bdir, rel)
        cur, _ = read_text(path)
        if not os.path.exists(dst) and OLD_MARK not in cur:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(path, dst)
    for _, path, text, crlf in plan:
        out = text.replace('\n', '\r\n') if crlf else text
        open(path, 'wb').write(out.encode('utf-8'))
    return ('PATCHED', f'已成功打补丁 {MARK} (v{ver})')


if __name__ == '__main__':
    chk = '--check' in sys.argv
    args = [a for a in sys.argv[1:] if a != '--check']
    status, msg = run(args[0] if args else DEFAULT_DIR, check_only=chk)
    print(f'[vss_corpse_toggle] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED') else 1)
