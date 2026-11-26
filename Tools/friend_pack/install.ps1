# KkowoUI 整合包 安装器
# 合并规则：你已有的插件设置/布局一律保留，只补你没有的；同名插件换成整合包版本（原文件夹先移进备份）。
# 用法：双击「安装.bat」。高级：powershell -ExecutionPolicy Bypass -File install.ps1 -WowPath "D:\World of Warcraft\_forever_" [-Yes]
param(
    [string]$WowPath = "",
    [switch]$Yes,
    [switch]$NoGameCheck   # 仅供测试：装到另一个目录时不检查游戏是否在运行
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$payload = Join-Path $here 'payload'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Fail([string]$m) { Say ""; Say "安装中止：$m" 'Red'; exit 1 }

function Resolve-Forever([string]$p) {
    if (-not $p) { return $null }
    $p = $p.Trim().Trim('"').TrimEnd('\', '/')
    if (-not $p) { return $null }
    $cands = @($p, (Join-Path $p '_forever_'))
    $parent = Split-Path -Parent $p
    if ($parent) { $cands += (Join-Path $parent '_forever_') }
    foreach ($c in $cands) {
        if ((Split-Path -Leaf $c) -eq '_forever_' -and (Test-Path -LiteralPath (Join-Path $c 'Wow.exe'))) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

function Find-ForeverCandidates {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($base in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment', 'HKLM:\SOFTWARE\Blizzard Entertainment') {
        if (Test-Path $base) {
            Get-ChildItem $base -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $v = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).InstallPath
                if ($v) { $roots.Add([string]$v) }
            }
        }
    }
    $db = Join-Path $env:ProgramData 'Battle.net\Agent\product.db'
    if (Test-Path -LiteralPath $db) {
        try {
            $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($db))
            foreach ($m in [regex]::Matches($text, '[A-Za-z]:[\\/][^\x00-\x1f"<>|*?]{0,200}?World of Warcraft')) { $roots.Add($m.Value) }
        } catch {}
    }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($sub in 'World of Warcraft', 'Program Files\World of Warcraft', 'Program Files (x86)\World of Warcraft',
                         'Games\World of Warcraft', 'Game\World of Warcraft', 'Battle.net\World of Warcraft',
                         'Blizzard\World of Warcraft', '游戏\World of Warcraft') {
            $roots.Add((Join-Path $d.Root $sub))
        }
    }
    $found = @{}
    foreach ($r in $roots) {
        try { $f = Resolve-Forever $r } catch { $f = $null }
        if ($f) { $found[$f.ToLower()] = $f }
    }
    return @($found.Values)
}

function Pick-Folder {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '请选择魔兽世界的安装目录（World of Warcraft 或其中的 _forever_ 文件夹）'
        if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
    } catch {}
    return (Read-Host '请输入 World of Warcraft 目录路径')
}

function Ask-YesNo([string]$q) {
    if ($Yes) { return $true }
    $a = Read-Host "$q (Y/N)"
    return ($a -match '^[YyＹｙ是]')
}

# robocopy：/XC /XN /XO = 目标已有的文件一律不动，只复制目标没有的
function Robo([string]$src, [string]$dst, [switch]$MissingOnly) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $opt = @('/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($MissingOnly) { $opt += @('/XC', '/XN', '/XO') }
    & robocopy $src $dst @opt | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "复制文件失败（robocopy 代码 $LASTEXITCODE）：$src -> $dst" }
}

function Count-Files([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue).Count
}

# 极速导航改名：你原来的 VamoosesSlipstream 存档复制一份给新名字（新名字的存档已存在则不动）
function Copy-VssSV([string]$svDir) {
    $o = Join-Path $svDir 'VamoosesSlipstream.lua'
    $n = Join-Path $svDir 'VamoosesSlipstream_kkowo.lua'
    if ((Test-Path -LiteralPath $o) -and -not (Test-Path -LiteralPath $n)) {
        Copy-Item -LiteralPath $o -Destination $n
        return 1
    }
    return 0
}

# 角色的启用插件列表：你已经列出的插件保持你的设置，只补上你列表里没有的整合包插件
function Merge-AddOnsTxt([string]$path, [string]$tpl) {
    $theirs = [System.IO.File]::ReadAllText($path, $utf8)
    $nl = "`n"
    if ($theirs.Contains("`r`n")) { $nl = "`r`n" }
    $have = @{}
    $vssState = $null
    foreach ($ln in ($theirs -split "`r?`n")) {
        $i = $ln.IndexOf(':')
        if ($i -gt 0) {
            $n = $ln.Substring(0, $i).Trim()
            $have[$n.ToLower()] = $true
            if ($n -eq 'VamoosesSlipstream') { $vssState = $ln.Substring($i + 1).Trim() }
        }
    }
    $add = New-Object System.Collections.Generic.List[string]
    if ($vssState -and -not $have.ContainsKey('vamoosesslipstream_kkowo')) {
        $add.Add("VamoosesSlipstream_kkowo: $vssState")
        $have['vamoosesslipstream_kkowo'] = $true
    }
    foreach ($ln in [System.IO.File]::ReadAllLines($tpl, $utf8)) {
        $i = $ln.IndexOf(':')
        if ($i -gt 0) {
            $n = $ln.Substring(0, $i).Trim()
            if (-not $have.ContainsKey($n.ToLower())) {
                $add.Add($ln.Trim())
                $have[$n.ToLower()] = $true
            }
        }
    }
    if ($add.Count -gt 0) {
        $text = $theirs.TrimEnd("`r", "`n") + $nl + ($add -join $nl) + $nl
        [System.IO.File]::WriteAllText($path, $text, $utf8)
    }
    return $add.Count
}

Say '================ KkowoUI 整合包 安装器 ================' 'Cyan'
if (-not (Test-Path -LiteralPath (Join-Path $payload 'Interface\AddOns'))) { Fail '找不到 payload 文件夹。请先把压缩包完整解压，再运行「安装.bat」。' }

# ---------- 游戏不能开着 ----------
if (-not $NoGameCheck -and (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Wow*' })) { Fail '魔兽世界正在运行。请完全退出游戏后再安装。' }

# ---------- 找游戏目录 ----------
$forever = $null
if ($WowPath) {
    $forever = Resolve-Forever $WowPath
    if (-not $forever) { Fail "这个目录里找不到 _forever_\Wow.exe：$WowPath" }
} else {
    $list = Find-ForeverCandidates
    if ($list.Count -eq 1) {
        Say "找到魔兽世界「无限」目录：$($list[0])" 'Green'
        if (Ask-YesNo '装到这里吗？') { $forever = $list[0] }
    } elseif ($list.Count -gt 1) {
        Say '找到多个「无限」目录：' 'Yellow'
        for ($i = 0; $i -lt $list.Count; $i++) { Say ("  [{0}] {1}" -f ($i + 1), $list[$i]) }
        $n = Read-Host '输入编号选择（直接回车 = 手动选择）'
        if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $list.Count) { $forever = $list[[int]$n - 1] }
    }
    if (-not $forever) {
        Say '请手动选择魔兽世界目录……' 'Yellow'
        $forever = Resolve-Forever (Pick-Folder)
        if (-not $forever) { Fail '选择的目录里找不到 _forever_\Wow.exe。' }
    }
}
Say "目标目录：$forever" 'Cyan'

# ---------- 账号与角色（需要先登录过一次） ----------
$wtfAccount = Join-Path $forever 'WTF\Account'
$accounts = @()
if (Test-Path -LiteralPath $wtfAccount) {
    $accounts = @(Get-ChildItem -LiteralPath $wtfAccount -Directory | Where-Object { $_.Name -ne 'SavedVariables' })
}
if ($accounts.Count -eq 0) { Fail '还没有游戏账号配置。请先启动一次游戏，进入任意角色后再完全退出，然后重新运行安装。' }
$chars = @()
foreach ($a in $accounts) {
    foreach ($realm in (Get-ChildItem -LiteralPath $a.FullName -Directory | Where-Object { $_.Name -ne 'SavedVariables' })) {
        $chars += @(Get-ChildItem -LiteralPath $realm.FullName -Directory)
    }
}
Say ("账号 {0} 个，角色 {1} 个" -f $accounts.Count, $chars.Count)

Say ''
Say '即将进行：' 'Cyan'
Say '  1. 备份你的 WTF 配置；同名插件的原文件夹移进备份（World of Warcraft\KkowoUI安装备份_日期）'
Say '  2. 装上整合包插件、字体和图标（你已有的字体和图标不覆盖）'
Say '  3. 合并配置：你已经配置过的插件保留你的设置，没配置过的插件使用整合包布局'
if (-not (Ask-YesNo '确定开始安装吗？')) { Fail '已取消。' }

# ---------- 备份 ----------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$bk = Join-Path (Split-Path -Parent $forever) ("KkowoUI安装备份_" + $stamp)
New-Item -ItemType Directory -Force -Path $bk | Out-Null
Say "备份到：$bk" 'Cyan'
Robo (Join-Path $forever 'WTF') (Join-Path $bk 'WTF')

# ---------- 插件：同名的先移进备份，再装整合包版本 ----------
Say '安装插件（文件较多，请稍等）……' 'Cyan'
$addDst = Join-Path $forever 'Interface\AddOns'
New-Item -ItemType Directory -Force -Path $addDst | Out-Null
$packAddons = @(Get-ChildItem -LiteralPath (Join-Path $payload 'Interface\AddOns') -Directory | ForEach-Object { $_.Name })
$replaced = 0
foreach ($name in (@($packAddons) + @('VamoosesSlipstream'))) {
    $p = Join-Path $addDst $name
    if (Test-Path -LiteralPath $p) {
        $b = Join-Path $bk ('Interface\AddOns\' + $name)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $b) | Out-Null
        Move-Item -LiteralPath $p -Destination $b
        $replaced++
    }
}
Robo (Join-Path $payload 'Interface\AddOns') $addDst

# ---------- 字体与图标：只补你没有的 ----------
foreach ($rel in 'Fonts', 'Interface\Icons') {
    $src = Join-Path $payload $rel
    if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $forever $rel
        $before = Count-Files $dst
        Robo $src $dst -MissingOnly
        $added = (Count-Files $dst) - $before
        Say "  $rel：新增 $added 个文件（已有的保持不变）"
    }
}

# ---------- 配置合并 ----------
Say '合并配置……' 'Cyan'
$accTpl = Join-Path $payload 'WTF\Account'
$chrTpl = Join-Path $payload 'WTF\Character'
$svAdded = 0
foreach ($a in $accounts) {
    $sv = Join-Path $a.FullName 'SavedVariables'
    New-Item -ItemType Directory -Force -Path $sv | Out-Null
    $null = Copy-VssSV $sv
    $before = Count-Files $sv
    Robo $accTpl $a.FullName -MissingOnly
    $svAdded += (Count-Files $sv) - $before
}
$txtAdded = 0
foreach ($c in $chars) {
    $csv = Join-Path $c.FullName 'SavedVariables'
    if (Test-Path -LiteralPath $csv) { $null = Copy-VssSV $csv }
    $txt = Join-Path $c.FullName 'AddOns.txt'
    $hadTxt = Test-Path -LiteralPath $txt
    Robo $chrTpl $c.FullName -MissingOnly
    if ($hadTxt) { $txtAdded += Merge-AddOnsTxt $txt (Join-Path $chrTpl 'AddOns.txt') }
}

Say ''
Say '================ 安装完成 ================' 'Green'
Say "  替换同名插件 $replaced 个（原文件夹已备份）"
Say "  使用整合包布局的插件配置 $svAdded 份（你原有的配置全部保留）"
Say "  角色插件列表补充 $txtAdded 项"
Say "备份位置：$bk"
Say '进游戏后输入 /kk 打开 KkowoUI 设置。'
Say '还原：把备份里的 WTF 文件夹和 Interface\AddOns 下的插件复制回 _forever_ 覆盖即可。'
