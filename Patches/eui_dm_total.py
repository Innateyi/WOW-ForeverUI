# -*- coding: utf-8 -*-
"""
补丁：EllesmereUIDamageMeters 标题栏「总计」显示（修复窄窗遮挡、空数据 0 显示与自动备份）
支持 --check 只读检测，默认执行幂等补丁。
"""
import os, re, shutil, sys

# 游戏目录与备份目录可用环境变量覆盖：WOW_FOREVER_DIR（含 Interface 的客户端根目录）/ WOW_BACKUP_ROOT
WOW_ROOT = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
DEFAULT_DIR = os.path.join(WOW_ROOT, 'Interface', 'AddOns', 'EllesmereUIDamageMeters')
# 默认放在仓库同级的 backups 目录（绝不写进游戏目录）
BACKUP_ROOT = os.environ.get('WOW_BACKUP_ROOT', os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')))
MARK = '[fui-dm-total v3]'
OLD_MARKS = ('[kkowo-total]', '[fui-dm-total v2]')

PATCHES = {
    'EUI_DamageMeters_Window.lua': [
        (
            '    if wdb.hideTimer then W.timerText:Hide() end\n',
            '    if wdb.hideTimer then W.timerText:Hide() end\n'
            '    -- [fui-dm-total v3] 标题后显示当前段落合计（空数据时隐藏，窄窗自动避让按钮）\n'
            '    W.totalText = header:CreateFontString(nil, "OVERLAY"); SetDMFont(W.totalText, hdrFS)\n'
            '    W.totalText:SetTextColor(1, 1, 1, 0.72)\n'
            '    -- 12.x 首领战中合计是保密字符串，GetStringWidth 会返回保密数字：做加减比较前一律过滤\n'
            '    local function DMPlainNum(v) if type(v) ~= "number" or (issecretvalue and issecretvalue(v)) then return nil end return v end\n'
            '    function W.AnchorTotal()\n'
            '        W.totalText:ClearAllPoints()\n'
            '        local timerVisible = W.timerText and W.timerText:IsShown() and (W.timerText:GetText() or "") ~= ""\n'
            '        local anchor = timerVisible and W.timerText or W.titleText\n'
            '        W.totalText:SetPoint("LEFT", anchor, "RIGHT", 6, 0)\n'
            '        local hw = DMPlainNum(header:GetWidth()) or 0\n'
            '        local tw = (DMPlainNum(W.titleText and W.titleText:GetStringWidth()) or 0) + (timerVisible and ((DMPlainNum(W.timerText:GetStringWidth()) or 0) + 6) or 0)\n'
            '        local totW = DMPlainNum(W.totalText:GetStringWidth()) or 56\n'
            '        -- 窄窗时隐藏、拉宽后重新显示（只在本段确有合计时）\n'
            '        W.totalText:SetShown(W._totalActive == true and not (hw > 0 and (tw + totW + 86) > hw))\n'
            '    end\n'
            '    W.AnchorTotal()\n',
        ),
        (
            '        W.FitTitle()\n        if winIdx == 1 then UpdateSATimerText() end\n',
            '        W.FitTitle()\n        if winIdx == 1 then UpdateSATimerText() end\n'
            '        -- [fui-dm-total v3] 优先用 totalAmount；非保密且为 0 或无记录时不显示\n'
            '        if W.totalText then\n'
            '            local total\n'
            '            if session and W.curDMType ~= "threat" and (not Enum.DamageMeterType or W.curDMType ~= Enum.DamageMeterType.Deaths) then\n'
            '                total = session.totalAmount\n'
            '                if type(total) ~= "number" and session.combatSources and #session.combatSources > 0 then\n'
            '                    local sum = 0\n'
            '                    for _, s in ipairs(session.combatSources) do\n'
            '                        local a = s.totalAmount\n'
            '                        if type(a) == "number" then\n'
            '                            if issecretvalue and issecretvalue(a) then sum = nil; break end\n'
            '                            sum = sum + a\n'
            '                        end\n'
            '                    end\n'
            '                    if sum and sum > 0 then total = sum end\n'
            '                elseif type(total) == "number" and (not issecretvalue or not issecretvalue(total)) and total <= 0 then\n'
            '                    total = nil\n'
            '                end\n'
            '            end\n'
            '            if total then\n'
            '                W.totalText:SetText(format("总计 %s", AbbrevNumber(total)))\n'
            '                W._totalActive = true\n'
            '            else\n'
            '                W.totalText:SetText("")\n'
            '                W._totalActive = false\n'
            '            end\n'
            '            W.AnchorTotal()\n'
            '        end\n',
        ),
        (
            '        W.timerText:SetText("(0:00)")\n        W.timerText:SetShown(not wdb.hideTimer)\n',
            '        W.timerText:SetText("(0:00)")\n        W.timerText:SetShown(not wdb.hideTimer)\n'
            '        if W.totalText then SetDMFont(W.totalText, titleFS); W.AnchorTotal() end -- [fui-dm-total v3]\n',
        ),
    ],
    'EUI_DamageMeters_Apply.lua': [
        (
            '        if w.timerText then\n            SetDMFont(w.timerText, hdrFS)\n        end\n',
            '        if w.timerText then\n            SetDMFont(w.timerText, hdrFS)\n        end\n'
            '        if w.totalText then SetDMFont(w.totalText, hdrFS); if w.AnchorTotal then w.AnchorTotal() end end -- [fui-dm-total v3]\n',
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
    bdir = os.path.join(BACKUP_ROOT, f'EllesmereUIDamageMeters_{ver}_原版')
    plans = []
    already = True
    for fname, reps in PATCHES.items():
        path = os.path.join(addon_dir, fname)
        if not os.path.exists(path):
            return ('MISSING', f'未找到文件: {fname}（EUI 可能已改名/重构）')
        text, crlf = read_text(path)
        if MARK in text:
            continue
        already = False
        if any(m in text for m in OLD_MARKS):
            src = os.path.join(bdir, fname)
            if os.path.exists(src):
                text, crlf = read_text(src)
            else:
                return ('APPLIED_LEGACY', f'已含旧版补丁 (v{ver})，且找不到原版备份；下次 EUI 更新后将自动套用新版 {MARK}')
        for old, new in reps:
            if text.count(old) != 1:
                return ('ANCHOR_MISMATCH', f'{fname} 锚点匹配数={text.count(old)}（EUI 可能已更新）')
            text = text.replace(old, new)
        plans.append((path, text, crlf))

    if already:
        return ('APPLIED', f'已应用 {MARK} (v{ver})')
    if check_only:
        return ('READY', f'可安全应用 {MARK} (v{ver})')

    os.makedirs(bdir, exist_ok=True)
    for path, text, crlf in plans:
        dst = os.path.join(bdir, os.path.basename(path))
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
    print(f'[eui_dm_total] {status}: {msg}')
    sys.exit(0 if status in ('APPLIED', 'READY', 'PATCHED') else 1)
