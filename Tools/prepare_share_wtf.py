# -*- coding: utf-8 -*-
r"""
分享前整理 WTF（供网易DD「配置分享」上传你的界面布局与功能设置）

做什么（--apply，须退出游戏）：
  1. 把整个 WTF\Account\<账号目录> 完整备份到 <备份目录>\WTF_分享前_<时间>\（WOW_BACKUP_ROOT 可覆盖）
  2. 账号级 SavedVariables：只保留「当前已安装插件」的配置，删除已卸载插件残留、暴雪自带面板配置与 .bak 备份；
     在保留的配置里清掉个人信息：本人及小号的角色名/服务器、角色 GUID、AceDB profileKeys（让别人的角色自动用 Default 方案）、
     金币账本/离线背包快照、kkowoUI 快捷收件人（好友名）等
  3. 角色级 SavedVariables（任务进度、指南进度、聊天记录等）全部移走，只留 AddOns.txt、按键、宏、频道等角色设置；
     只保留设置最全/最近游玩的那个角色，文件夹改名为中性的 Kkowo-Share，其余角色文件夹整夹移走（分享包路径里不再有角色名）；
     config-cache.wtf 里的社群 ID（lastSelectedClubId）一并删掉
  4. 删除 character-list-order.txt（角色列表）
  5. 最后复查一遍，报告仍残留的可疑内容

分享完成后务必运行 --restore 把你自己的完整 WTF 原样换回来（进游戏前！）。

推荐流程（专用分享副本，真实配置不做任何修改）：
  双击 Tools\\网易DD分享上传.bat（= python -I Tools/prepare_share_wtf.py --upload）：
    1. 在 <仓库同级>\\share-kkowo\\Account\\<账号目录> 生成脱敏副本（WOW_SHARE_DIR 可覆盖），复查无残留才继续
    2. 把游戏里的真实账号目录整个挪到 <备份目录>\\WTF_上传期间_<时间>\\（这份就是完整备份，不会删）
       ——网易DD 会把整个 WTF\\Account 打包，所以真实目录必须离开 WTF\\Account
    3. 换入脱敏副本，等你在网易DD上传完按回车，再把真实目录原样换回（逐文件数/大小校验）
  若窗口被意外关掉，下次运行会先自动换回。也可分步：--stage（只生成副本，游戏开着也行）/ --swap-in / --swap-out。
  账号目录与角色名自动识别（角色文件夹名 + profileKeys），一般不用 --names 和 WOW_ACCOUNT_DIR。

旧用法（原地脱敏）：
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
    'kkowoUIDB/modules/socialTools/favorites',
    'kkowoUIDB/modules/socialTools/alts',
    'kkowoUIDB/modules/modernChrome/cdmConflictKeep',
    'kkowoUIDB/modules/modernChrome/euiConflictKeep',
    # 插件改名为 kkowoUI 前的旧存档变量名
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
ADDON_NAME_RE = re.compile(r'kkowoUI|migratedFromHaaland|Haalandtool', re.I)


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


# ---------------------------------------------------------------- 专用分享副本（share-kkowo）+ 上传期间换入/换出
# 网易DD 把整个 WTF\Account 打进 Account.zip，所以上传期间你自己的账号目录必须整个离开 WTF\Account：
# 先在 share-kkowo 里生成脱敏副本（你的真实配置一个字节都不改），上传时把真实目录挪到备份目录、换入副本，
# 上传完再原样换回。挪出去的那份就是完整备份，一直留着。
SHARE_DIR = os.environ.get(
    'WOW_SHARE_DIR',
    os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'share-kkowo')),
)
PARK_PREFIX = 'WTF_上传期间_'
STATE_FILE = os.path.join(SHARE_DIR, '上传换入状态.txt')


def detect_account():
    if ACCOUNT:
        return os.path.normpath(ACCOUNT) if os.path.isdir(ACCOUNT) else None
    root = os.path.join(GAME, 'WTF', 'Account')
    if not os.path.isdir(root):
        return None
    cands = [d for d in os.listdir(root) if d != 'SavedVariables' and os.path.isdir(os.path.join(root, d))]
    return os.path.join(root, cands[0]) if len(cands) == 1 else None


def char_folder_names(acc):
    """WTF 里的角色文件夹名（无限服是「名-姓」）：名、姓、「名 姓」都算个人信息。"""
    names = set()
    for realm in os.listdir(acc):
        rp = os.path.join(acc, realm)
        if realm == 'SavedVariables' or not os.path.isdir(rp):
            continue
        for ch in os.listdir(rp):
            if not os.path.isdir(os.path.join(rp, ch)) or ch == SHARE_CHAR_DIR:
                continue
            parts = [p for p in ch.split('-') if p]
            names.update(p for p in parts if len(p) >= 2)
            if len(parts) >= 2:
                names.add(' '.join(parts))
    return names


def tree_stats(path):
    n = size = 0
    for root, _, files in os.walk(path):
        for f in files:
            n += 1
            size += os.path.getsize(os.path.join(root, f))
    return n, size


def copy_verified(src, dst):
    shutil.copytree(src, dst)
    if tree_stats(src) != tree_stats(dst):
        sys.exit(f'复制校验失败：{src} -> {dst}（文件数或大小不一致），已停止，未做其它改动。')


def read_state():
    if not os.path.exists(STATE_FILE):
        return None
    state = {}
    for line in open(STATE_FILE, encoding='utf-8'):
        if '=' in line:
            k, v = line.rstrip('\n').split('=', 1)
            state[k] = v
    return state if state.get('acc') and state.get('park') else None


def stage_share_copy(acc, names, quiet=False):
    """把当前真实配置复制到 share-kkowo 并脱敏；返回 (副本路径, 复查残留列表)。不碰游戏目录。"""
    dst = os.path.join(SHARE_DIR, 'Account', os.path.basename(acc))
    if os.path.exists(dst):
        shutil.rmtree(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copytree(acc, dst)
    drop, keep, failed, removed = plan_account(dst, names, True)
    moved = plan_characters(dst, True)
    hits = residual_scan(dst, names)
    if not quiet:
        print(f'[分享副本] {dst}')
        print(f'  账号级配置保留 {len(keep)} 份（{sum(1 for _, c in keep if c)} 份脱敏），移走 {len(drop)} 份；脱敏 {len(removed)} 处；角色级处理 {len(moved)} 项')
        if failed:
            print('  无法解析（已整份移走）：' + '；'.join(failed))
        print('  复查：' + ('未发现残留个人信息。' if not hits else f'发现 {len(hits)} 处可疑内容'))
        for h in hits:
            print('    ! ' + h)
    return dst, hits


def swap_in(acc, names):
    if read_state():
        sys.exit('上一次上传的换入还没换回：先运行 --swap-out（或直接用 --upload，会先自动换回）。')
    staged, hits = stage_share_copy(acc, names)
    if hits:
        sys.exit('分享副本里还有可疑内容，已停止，游戏目录没有任何改动。请把上面的提示发给我处理。')
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    park = os.path.join(BACKUP_ROOT, PARK_PREFIX + stamp, os.path.basename(acc))
    os.makedirs(os.path.dirname(park), exist_ok=True)
    copy_verified(acc, park)
    with open(STATE_FILE, 'w', encoding='utf-8') as f:
        f.write(f'acc={acc}\npark={park}\nstaged={staged}\ntime={stamp}\n')
    shutil.rmtree(acc)
    copy_verified(staged, acc)
    print(f'[已换入] 你的真实配置已整个挪到 {park}（这份就是完整备份）')
    print(f'         游戏目录里现在是脱敏的分享副本，可以在网易DD上传了。')


def swap_out():
    state = read_state()
    if not state:
        print('[换回] 当前没有处于上传换入状态，无需还原。')
        return False
    acc, park = state['acc'], state['park']
    if not os.path.isdir(os.path.join(park, 'SavedVariables')):
        sys.exit(f'备份目录不完整，未做任何改动：{park}')
    if os.path.exists(acc):
        shutil.rmtree(acc)
    copy_verified(park, acc)
    os.remove(STATE_FILE)
    print(f'[已换回] {acc}  <-  {park}（备份仍保留在原处）')
    return True


def main():
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser()
    ap.add_argument('--names', nargs='*', default=[], help='本人角色名、服务器名、小号名（会自动补上 profileKeys 里的全部角色名和角色文件夹名）')
    ap.add_argument('--apply', action='store_true', help='旧流程：原地脱敏（会先备份）')
    ap.add_argument('--restore', action='store_true', help='旧流程：用最近一次 WTF_分享前_* 备份还原')
    ap.add_argument('--stage', action='store_true', help='只在 share-kkowo 生成/刷新脱敏副本，不碰游戏目录（游戏开着也行）')
    ap.add_argument('--swap-in', action='store_true', help='换入分享副本（真实配置挪到备份目录）')
    ap.add_argument('--swap-out', action='store_true', help='换回真实配置')
    ap.add_argument('--upload', action='store_true', help='一条龙：换入 → 等你在网易DD上传完按回车 → 换回')
    args = ap.parse_args()

    if args.swap_out or args.upload:
        if wow_running():
            sys.exit('检测到魔兽客户端正在运行：请先完全退出游戏。')
        if args.swap_out:
            swap_out()
            return 0
        if read_state():
            print('发现上一次上传还没换回，先换回……')
            swap_out()

    acc = detect_account()
    if not acc:
        sys.exit('找不到唯一的 WTF\\Account\\<账号目录>：请设置环境变量 WOW_ACCOUNT_DIR。')
    if (args.apply or args.restore or args.swap_in or args.upload) and wow_running():
        sys.exit('检测到魔兽客户端正在运行：请先完全退出游戏。')

    if args.stage or args.swap_in or args.upload:
        names = set(args.names) | collect_profile_names(os.path.join(acc, 'SavedVariables')) | char_folder_names(acc)
        if args.stage:
            stage_share_copy(acc, names)
            return 0
        swap_in(acc, names)
        if args.swap_in:
            print('\n上传完成后、进游戏之前，运行：python -I Tools/prepare_share_wtf.py --swap-out')
            return 0
        print('\n>>> 现在去网易DD上传配置分享。上传完成后回到这个窗口按回车，自动换回你的配置。')
        print('>>> （上传期间不要启动游戏；万一关掉了这个窗口，再运行一次就会先自动换回。）')
        try:
            input()
        except EOFError:
            pass
        if wow_running():
            sys.exit('检测到游戏正在运行：退出游戏后再运行一次本工具即可换回（你的真实配置在备份目录里，安全）。')
        swap_out()
        return 0

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
    names = set(args.names) | collect_profile_names(sv_dir) | char_folder_names(acc)
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
