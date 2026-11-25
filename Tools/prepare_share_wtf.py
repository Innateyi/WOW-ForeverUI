# -*- coding: utf-8 -*-
r"""
分享前整理 WTF（供网易DD「配置分享」上传你的界面布局与功能设置）

做什么（--apply，须退出游戏）：
  1. 把整个 WTF\Account\<账号目录> 完整备份到 <备份目录>\WTF_分享前_<时间>\（WOW_BACKUP_ROOT 可覆盖）
  2. 账号级 SavedVariables：只保留「当前已安装插件」的配置，删除已卸载插件残留、暴雪自带面板配置与 .bak 备份；
     在保留的配置里清掉个人信息：本人及小号的角色名/服务器、角色 GUID、AceDB profileKeys（让别人的角色自动用 Default 方案）、
     金币账本/离线背包快照、KkowoUI 快捷收件人（好友名）等
  3. 角色级 SavedVariables（任务进度、指南进度、聊天记录等）全部移走，只留 AddOns.txt、按键、宏、频道等角色设置；
     只保留设置最全/最近游玩的那个角色，文件夹改名为中性的 Kkowo-Share，其余角色文件夹整夹移走（分享包路径里不再有角色名）；
     config-cache.wtf 里的社群 ID（lastSelectedClubId）一并删掉
  4. 删除 character-list-order.txt（角色列表）
  5. 最后复查一遍，报告仍残留的可疑内容

分享完成后务必运行 --restore 把你自己的完整 WTF 原样换回来（进游戏前！）。

用法：
  python -I Tools/prepare_share_wtf.py --names 角色名 服务器名 [其它小号名...]            # 只预览，不改文件
  python -I Tools/prepare_share_wtf.py --names 角色名 服务器名 --apply                    # 备份并整理
  python -I Tools/prepare_share_wtf.py --restore                                          # 用最近一次备份还原
环境变量：WOW_ACCOUNT_DIR（WTF\Account\<账号目录>，必填）、WOW_FOREVER_DIR、WOW_BACKUP_ROOT
"""
import argparse
import datetime
import glob
import os
import re
import shutil
import subprocess
import sys

GAME = os.environ.get('WOW_FOREVER_DIR', r'E:\Program Files\World of Warcraft\_forever_')
ACCOUNT = os.environ.get('WOW_ACCOUNT_DIR', '')
BACKUP_ROOT = os.environ.get(
    'WOW_BACKUP_ROOT',
    os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'backups')),
)
BACKUP_PREFIX = 'WTF_分享前_'

# 这些容器整个清空（路径用 / 分隔，从 SavedVariables 顶层变量开始）
CLEAR_PATHS = {
    'KkowoUIDB/modules/socialTools/favorites',
    'KkowoUIDB/modules/socialTools/alts',
    'KkowoUIDB/modules/modernChrome/cdmConflictKeep',
    'KkowoUIDB/modules/modernChrome/euiConflictKeep',
    'PolestarDB/update/probed',  # Polestar 版本探测记下的其他玩家「名 姓」（数百个，与你同服的社交痕迹）
    'EllesmereUIDB/goldLedger',
    'EllesmereUIDB/warband',
    'EllesmereUIBagsInventoryDB',
}
GUID_RE = re.compile(r'^(Player|Pet|Creature|BNet)-\d+-[0-9A-Fa-f-]+$')
GUID_IN_TEXT_RE = re.compile(r'Player-\d+-[0-9A-Fa-f]{8}')
SHARE_CHAR_DIR = 'Kkowo-Share'  # 分享包里唯一保留的角色文件夹的中性名字
ADDON_NAME_RE = re.compile(r'KkowoUI|migratedFromHaaland|Haalandtool', re.I)


# ---------------------------------------------------------------- Lua SavedVariables 解析 / 写回
class Table:
    __slots__ = ('entries',)

    def __init__(self):
        self.entries = []  # [(key or None, value)]; key = ('s', raw) | ('n', raw)


class Raw:
    __slots__ = ('kind', 'raw')

    def __init__(self, kind, raw):
        self.kind = kind  # 's' string (raw escaped body), 'n' number, 'b' bool/nil
        self.raw = raw

    def text(self):
        if self.kind != 's':
            return None
        return self.raw.replace('\\"', '"').replace('\\\\', '\\')


TOKEN_RE = re.compile(r'''
    (?P<ws>\s+)
  | (?P<comment>--[^\n]*)
  | (?P<str>"(?:[^"\\]|\\.)*")
  | (?P<num>-?(?:\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+|0[xX][0-9a-fA-F]+)|-?inf|nan)
  | (?P<name>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<sym>[{}\[\]=,;])
''', re.X | re.S)


def tokenize(text):
    pos, n = 0, len(text)
    out = []
    while pos < n:
        m = TOKEN_RE.match(text, pos)
        if not m:
            raise ValueError(f'无法解析的字符 @{pos}: {text[pos:pos + 30]!r}')
        pos = m.end()
        kind = m.lastgroup
        if kind in ('ws', 'comment'):
            continue
        out.append((kind, m.group()))
    return out


def parse_sv(text):
    toks = tokenize(text)
    i = 0

    def value():
        nonlocal i
        kind, tok = toks[i]
        if tok == '{':
            i += 1
            return table()
        i += 1
        if kind == 'str':
            return Raw('s', tok[1:-1])
        if kind == 'num':
            return Raw('n', tok)
        if kind == 'name' and tok in ('true', 'false', 'nil'):
            return Raw('b', tok)
        raise ValueError(f'意外的值 {tok!r}')

    def table():
        nonlocal i
        t = Table()
        while toks[i][1] != '}':
            key = None
            if toks[i][1] == '[':
                kk, kt = toks[i + 1]
                key = ('s', kt[1:-1]) if kk == 'str' else ('n', kt)
                if toks[i + 2][1] != ']' or toks[i + 3][1] != '=':
                    raise ValueError('表键格式错误')
                i += 4
            elif toks[i][0] == 'name' and i + 1 < len(toks) and toks[i + 1][1] == '=':
                key = ('s', toks[i][1])
                i += 2
            v = value()
            t.entries.append((key, v))
            if toks[i][1] in (',', ';'):
                i += 1
        i += 1
        return t

    tops = []
    while i < len(toks):
        kind, tok = toks[i]
        if kind != 'name' or toks[i + 1][1] != '=':
            raise ValueError(f'顶层格式错误: {tok!r}')
        i += 2
        tops.append((tok, value()))
    return tops


def write_value(v, out):
    if isinstance(v, Table):
        out.append('{\n')
        for key, val in v.entries:
            if key is not None:
                out.append(f'["{key[1]}"] = ' if key[0] == 's' else f'[{key[1]}] = ')
            write_value(val, out)
            out.append(',\n')
        out.append('}')
    elif v.kind == 's':
        out.append(f'"{v.raw}"')
    else:
        out.append(v.raw)


def write_sv(tops):
    out = ['\n']
    for name, v in tops:
        out.append(f'{name} = ')
        write_value(v, out)
        out.append('\n')
    return ''.join(out)


def read_raw(path):
    # SavedVariables 里可能有非 UTF-8 的原始字节（如拍卖行数据）：surrogateescape 让写回时逐字节不变
    with open(path, 'rb') as f:
        return f.read().decode('utf-8', 'surrogateescape')


def write_raw(path, text):
    with open(path, 'wb') as f:
        f.write(text.encode('utf-8', 'surrogateescape'))


# ---------------------------------------------------------------- 个人信息规则
class Scrubber:
    def __init__(self, names):
        self.exact = set()
        self.contains = set()
        for n in names:
            n = n.strip()
            if not n:
                continue
            self.exact.add(n)
            # 两个字以内的短名（含中文，如「风暴」）只做「整词」匹配，避免误伤普通键名和技能名（如 ArcAuras 的「风暴打击」）
            if len(n) >= 3:
                self.contains.add(n)
        self.removed = []

    def is_personal(self, s):
        if s is None:
            return False
        if GUID_RE.match(s):
            return True
        # 先去掉插件名本身再比对，免得把字体路径、框体名当成个人信息误删
        s = ADDON_NAME_RE.sub('', s)
        if not s:
            return False
        if s in self.exact:
            return True
        for n in self.exact:
            if s.startswith(n + '-') or s.startswith(n + ' ') or s.endswith('-' + n) or s.endswith(' ' + n):
                return True
        return any(n in s for n in self.contains)

    def holds_personal_string(self, t):
        # 只把「小记录」（如 {char="某某", t=时间}）整条删掉；大表（整套设置）里只删命中的那几项
        if len(t.entries) > 12:
            return False
        for _, v in t.entries:
            if isinstance(v, Raw) and v.kind == 's' and self.is_personal(v.text()):
                return True
        return False

    def scrub(self, t, path):
        kept = []
        for key, v in t.entries:
            kname = key[1] if key else None
            ktext = kname.replace('\\"', '"') if (key and key[0] == 's') else None
            sub = f'{path}/{ktext if ktext is not None else (kname or "#")}'
            if ktext is not None and self.is_personal(ktext):
                self.removed.append(sub)
                continue
            if isinstance(v, Raw) and v.kind == 's' and self.is_personal(v.text()):
                self.removed.append(sub)
                continue
            if isinstance(v, Table):
                if ktext == 'profileKeys' or sub in CLEAR_PATHS:
                    if v.entries:
                        self.removed.append(sub + ' (清空)')
                    v.entries = []
                elif self.holds_personal_string(v):
                    self.removed.append(sub)
                    continue
                else:
                    self.scrub(v, sub)
            kept.append((key, v))
        t.entries = kept


def collect_profile_names(sv_dir):
    """从所有 profileKeys 里收集本账号全部角色名（「名 - 服」或「名-服」）。"""
    names = set()
    key_re = re.compile(r'\["profileKeys"\] = \{(.*?)\n\}', re.S)
    for p in glob.glob(os.path.join(sv_dir, '*.lua')):
        try:
            text = open(p, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for block in key_re.findall(text):
            for k in re.findall(r'\["([^"]+)"\] =', block):
                head = re.split(r' - |-', k, maxsplit=1)[0].strip()
                if head:
                    names.add(head)
                    # 「名 姓」式角色名（无限服允许姓氏）在别的插件里常以「名-服务器」出现：名也要单独算
                    first = head.split(' ')[0]
                    if first != head and (len(first) >= 3 or any(ord(c) > 0x2E80 for c in first)):
                        names.add(first)
    return names


# ---------------------------------------------------------------- 文件范围
def installed_addons():
    adir = os.path.join(GAME, 'Interface', 'AddOns')
    names = set()
    for d in os.listdir(adir):
        if os.path.isdir(os.path.join(adir, d)):
            names.add(d.lower())
    return names


def sv_owner(fn):
    return fn[:-4].lower() if fn.endswith('.lua') else None


def wow_running():
    try:
        out = subprocess.check_output(['tasklist', '/FO', 'CSV', '/NH'], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return False
    return any(line.lower().startswith('"wow') for line in out.splitlines())


def plan_account(acc, names, apply):
    sv_dir = os.path.join(acc, 'SavedVariables')
    addons = installed_addons()
    scrub = Scrubber(names)
    drop, keep, failed = [], [], []
    for fn in sorted(os.listdir(sv_dir)):
        p = os.path.join(sv_dir, fn)
        if not os.path.isfile(p):
            continue
        owner = sv_owner(fn)
        if owner is None or owner.startswith('blizzard_') or owner not in addons:
            drop.append(fn)
            continue
        text = read_raw(p)
        try:
            tops = parse_sv(text)
        except Exception as e:  # 解析不了的文件不冒险改写，整份移走
            failed.append(f'{fn}: {e}')
            drop.append(fn)
            continue
        before = len(scrub.removed)
        for name, v in tops:
            if isinstance(v, Table):
                if name in CLEAR_PATHS:
                    if v.entries:
                        scrub.removed.append(f'{name} (清空)')
                    v.entries = []
                else:
                    scrub.scrub(v, name)
        changed = len(scrub.removed) != before
        keep.append((fn, changed))
        if apply and changed:
            write_raw(p, write_sv(tops))
    if apply:
        for fn in drop:
            os.remove(os.path.join(sv_dir, fn))
    return drop, keep, failed, scrub.removed


CHAR_KEEP_FILES = {'addons.txt', 'bindings-cache.wtf', 'macros-cache.txt', 'chat-cache.txt', 'config-cache.wtf',
                   'layout-local.txt', 'edit-mode-cache-character.txt', 'click-bindings-cache.txt'}


def plan_characters(acc, apply):
    """角色级：移走进度/聊天等文件；只保留最近游玩角色的设置文件，并把它的文件夹改成中性名字，
    其余角色文件夹整夹移走——分享包里的路径（Account/<账号>/<服务器>/<名-姓>）不再出现任何角色名。"""
    moved = []
    chars = []  # (最近修改时间, realm, ch)
    for realm in os.listdir(acc):
        rp = os.path.join(acc, realm)
        if realm == 'SavedVariables' or not os.path.isdir(rp):
            continue
        for ch in os.listdir(rp):
            cp = os.path.join(rp, ch)
            if not os.path.isdir(cp):
                continue
            files = os.listdir(cp)
            newest = max((os.path.getmtime(os.path.join(cp, f)) for f in files), default=0)
            kept = sum(1 for f in files if f.lower() in CHAR_KEEP_FILES)
            # 设置文件最全（有 config-cache.wtf / 宏 / 聊天窗口）的角色优先，其次看最近修改时间
            chars.append(((('config-cache.wtf' in (f.lower() for f in files)), kept, newest), realm, ch))
    chars.sort(reverse=True)
    for idx, (_, realm, ch) in enumerate(chars):
        cp = os.path.join(acc, realm, ch)
        if idx > 0:  # 非最近游玩的角色：整夹移走（其设置不是分享的布局来源）
            moved.append(f'{realm}/{ch}/')
            if apply:
                shutil.rmtree(cp)
            continue
        for fn in os.listdir(cp):
            fp = os.path.join(cp, fn)
            if os.path.isdir(fp):  # 角色级 SavedVariables：进度/聊天记录，整夹移走
                moved.append(f'{realm}/{ch}/{fn}/')
                if apply:
                    shutil.rmtree(fp)
            elif fn.lower() not in CHAR_KEEP_FILES:
                moved.append(f'{realm}/{ch}/{fn}')
                if apply:
                    os.remove(fp)
        if ch != SHARE_CHAR_DIR:
            moved.append(f'{realm}/{ch}/ -> {realm}/{SHARE_CHAR_DIR}/（改名）')
            if apply:
                os.rename(cp, os.path.join(acc, realm, SHARE_CHAR_DIR))
    for fn in ('character-list-order.txt', 'character-list-order.old'):
        if os.path.exists(os.path.join(acc, fn)):
            moved.append(fn)
            if apply:
                os.remove(os.path.join(acc, fn))
    # config-cache.wtf 里的社群/公会 ID（lastSelectedClubId）能反查你所在的社群：删掉这一行
    for p in glob.glob(os.path.join(acc, '**', 'config-cache.wtf'), recursive=True):
        text = read_raw(p)
        cleaned = re.sub(r'^SET lastSelectedClubId "[^"]*"\r?\n?', '', text, flags=re.M)
        if cleaned != text:
            moved.append(f'{os.path.relpath(p, acc)}: lastSelectedClubId')
            if apply:
                write_raw(p, cleaned)
    return moved


def residual_scan(acc, names):
    scrub = Scrubber(names)
    hits = []
    exact_only = sorted(n for n in scrub.exact if n not in scrub.contains and len(n) >= 2)
    short_res = [re.compile(r'(?:^|["\s/\\])' + re.escape(n) + r'(?:["\s\-/\\]|$)') for n in exact_only]
    for p in glob.glob(os.path.join(acc, '**', '*'), recursive=True):
        rel = os.path.relpath(p, acc)
        rel_dirs = rel.split(os.sep)[1:]  # 账号目录本身不算
        for n in sorted(scrub.contains):
            if any(n in part for part in rel_dirs):
                hits.append(f'{rel}: 路径含「{n}」')
        if not os.path.isfile(p):
            continue
        text = ADDON_NAME_RE.sub('', read_raw(p))
        for n in sorted(scrub.contains):
            if n in text:
                i = text.index(n)
                hits.append(f'{rel}: …{text[max(0, i - 40):i + 30]}…'.replace('\n', ' '))
                break
        else:
            for n, rx in zip(exact_only, short_res):
                mm = rx.search(text)
                if mm:
                    i = mm.start()
                    hits.append(f'{rel}: …{text[max(0, i - 40):i + 30]}…'.replace('\n', ' '))
                    break
        if GUID_IN_TEXT_RE.search(text):
            hits.append(f'{rel}: 含角色 GUID')
        if re.search(r'\|Hplayer:|CHAT_MSG_', text):
            hits.append(f'{rel}: 含聊天记录痕迹')
    return hits


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser()
    ap.add_argument('--names', nargs='*', default=[], help='本人角色名、服务器名、小号名（会自动补上 profileKeys 里的全部角色名）')
    ap.add_argument('--apply', action='store_true')
    ap.add_argument('--restore', action='store_true')
    args = ap.parse_args()

    if not ACCOUNT or not os.path.isdir(ACCOUNT):
        sys.exit('请先设置环境变量 WOW_ACCOUNT_DIR 指向 WTF\\Account\\<你的账号目录>。')
    acc = os.path.normpath(ACCOUNT)
    if (args.apply or args.restore) and wow_running():
        sys.exit('检测到魔兽客户端正在运行：请先完全退出游戏。')

    if args.restore:
        baks = sorted(glob.glob(os.path.join(BACKUP_ROOT, BACKUP_PREFIX + '*')))
        if not baks:
            sys.exit(f'在 {BACKUP_ROOT} 没有找到 {BACKUP_PREFIX}* 备份。')
        src = baks[-1]
        shutil.rmtree(acc)
        shutil.copytree(src, acc)
        print(f'[已还原] {acc}  <-  {src}')
        return 0

    sv_dir = os.path.join(acc, 'SavedVariables')
    names = set(args.names) | collect_profile_names(sv_dir)
    print('将视为个人信息的名字：' + '、'.join(sorted(names)))

    if args.apply:
        stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
        dst = os.path.join(BACKUP_ROOT, BACKUP_PREFIX + stamp)
        shutil.copytree(acc, dst)
        print(f'[已备份] {acc}  ->  {dst}')

    drop, keep, failed, removed = plan_account(acc, names, args.apply)
    moved = plan_characters(acc, args.apply)

    print(f'\n账号级配置：保留 {len(keep)} 份（其中 {sum(1 for _, c in keep if c)} 份做了脱敏），移走 {len(drop)} 份')
    print('  保留：' + '、'.join(f + ('*' if c else '') for f, c in keep))
    print('  移走：' + '、'.join(drop))
    if failed:
        print('  无法解析（已整份移走）：' + '；'.join(failed))
    print(f'\n脱敏条目 {len(removed)} 处：')
    for r in removed[:80]:
        print('  - ' + r)
    if len(removed) > 80:
        print(f'  ……另有 {len(removed) - 80} 处')
    print(f'\n角色级移走 {len(moved)} 项：' + '、'.join(moved))

    if args.apply:
        hits = residual_scan(acc, names)
        print('\n复查：' + ('未发现残留个人信息。' if not hits else ''))
        for h in hits:
            print('  ! ' + h)
        print('\n现在可以在网易DD里上传配置分享。分享完成后、进游戏之前，运行：python -I Tools/prepare_share_wtf.py --restore')
    else:
        print('\n（预览模式，未修改任何文件；确认无误后加 --apply）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
