# KkowoUI 整合包 安装器
# 合并规则：你已有的插件设置/布局一律保留，只补你没有的；同名插件换成整合包版本。
# 安装前把你原来的整套插件（Interface\AddOns）和全部 WTF 配置（账号与各角色）备份到 World of Warcraft\KkowoUI安装备份_日期。
# 用法：双击「安装.bat」，在弹出的窗口里选择 World of Warcraft 文件夹（例如 E:\Program Files\World of Warcraft）。
# 高级：powershell -ExecutionPolicy Bypass -File install.ps1 -WowPath "E:\Program Files\World of Warcraft" [-Yes]
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

# 选中的应是 World of Warcraft 这一层（里面有 _forever_\Wow.exe）；误选了 _forever_ 本身也认，自动退到上一层
function Resolve-WowRoot([string]$p) {
    if (-not $p) { return $null }
    $p = $p.Trim().Trim('"').TrimEnd('\', '/')
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
    if (Test-Path -LiteralPath (Join-Path $p '_forever_\Wow.exe')) {
        return (Resolve-Path -LiteralPath $p).Path
    }
    if ((Split-Path -Leaf $p) -eq '_forever_' -and (Test-Path -LiteralPath (Join-Path $p 'Wow.exe'))) {
        return (Resolve-Path -LiteralPath (Split-Path -Parent $p)).Path
    }
    return $null
}

function Pick-WowFolder {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '请选择魔兽世界的 World of Warcraft 文件夹（例如 E:\Program Files\World of Warcraft）'
        $dlg.ShowNewFolderButton = $false
        $ok = $dlg.ShowDialog($owner)
        $owner.Dispose()
        if ($ok -eq 'OK') { return $dlg.SelectedPath }
        return $null
    } catch {
        return (Read-Host '请输入 World of Warcraft 文件夹路径（例如 E:\Program Files\World of Warcraft）')
    }
}

function Ask-YesNo([string]$q) {
    if ($Yes) { return $true }
    $a = Read-Host "$q (Y/N)"
    return ($a -match '^[YyＹｙ是]')
}

# robocopy：/XC /XN /XO = 目标已有的文件一律不动，只复制目标没有的
function Robo([string]$src, [string]$dst, [switch]$MissingOnly, [string[]]$Extra = @()) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $opt = @('/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') + $Extra
    if ($MissingOnly) { $opt += @('/XC', '/XN', '/XO') }
    & robocopy $src $dst @opt | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "复制文件失败（robocopy 代码 $LASTEXITCODE）：$src -> $dst" }
}

function Count-Files([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue).Count
}

# 整合包里有、但你这里还没有的文件（相对路径），用于写「新增文件清单」方便还原
function Missing-Files([string]$src, [string]$dst) {
    $list = @()
    if (-not (Test-Path -LiteralPath $src)) { return $list }
    $base = (Resolve-Path -LiteralPath $src).Path.TrimEnd('\') + '\'
    foreach ($f in (Get-ChildItem -LiteralPath $src -File -Recurse)) {
        $rel = $f.FullName.Substring($base.Length)
        if (-not (Test-Path -LiteralPath (Join-Path $dst $rel))) { $list += $rel }
    }
    return $list
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

# ---------- 由你选择游戏目录（World of Warcraft 这一层） ----------
$wowRoot = $null
if ($WowPath) {
    $wowRoot = Resolve-WowRoot $WowPath
    if (-not $wowRoot) { Fail "这个文件夹里没有 _forever_\Wow.exe：$WowPath（请选 World of Warcraft 文件夹）" }
} else {
    Say '请在弹出的窗口里选择 World of Warcraft 文件夹（例如 E:\Program Files\World of Warcraft）……' 'Yellow'
    while (-not $wowRoot) {
        $picked = Pick-WowFolder
        if (-not $picked) { Fail '没有选择文件夹，已取消。' }
        $wowRoot = Resolve-WowRoot $picked
        if (-not $wowRoot) {
            Say "「$picked」里没有 _forever_\Wow.exe，不是魔兽世界无限服的 World of Warcraft 文件夹，请重新选择。" 'Red'
        }
    }
}
$forever = Join-Path $wowRoot '_forever_'
Say "游戏目录：$wowRoot" 'Cyan'

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

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$bk = Join-Path $wowRoot ("KkowoUI安装备份_" + $stamp)
Say ''
Say '即将进行：' 'Cyan'
Say "  1. 备份你原来的整套插件和全部 WTF 配置（账号与各角色）到：$bk"
Say '  2. 装上整合包插件（同名插件换成整合包版本），补上你没有的字体和图标'
Say '  3. 合并配置：你已经配置过的插件保留你的设置，没配置过的插件使用整合包布局'
if (-not (Ask-YesNo '确定开始安装吗？')) { Fail '已取消。' }

# ---------- 备份：整套插件 + 全部 WTF ----------
New-Item -ItemType Directory -Force -Path $bk | Out-Null
Say '备份原来的配置与插件（文件较多，请稍等）……' 'Cyan'
Robo (Join-Path $forever 'WTF') (Join-Path $bk 'WTF')
$addDst = Join-Path $forever 'Interface\AddOns'
$bkAdd = Join-Path $bk 'Interface\AddOns'
New-Item -ItemType Directory -Force -Path $addDst, $bkAdd | Out-Null
$packAddons = @(Get-ChildItem -LiteralPath (Join-Path $payload 'Interface\AddOns') -Directory | ForEach-Object { $_.Name })
$origCount = @(Get-ChildItem -LiteralPath $addDst -Directory).Count
# 1) 会被整合包替换的同名插件：整夹移进备份（是目录链接时只移动链接本身，不碰链接指向的文件）
$replaced = 0
foreach ($name in (@($packAddons) + @('VamoosesSlipstream'))) {
    $p = Join-Path $addDst $name
    if (Test-Path -LiteralPath $p) {
        Move-Item -LiteralPath $p -Destination (Join-Path $bkAdd $name)
        $replaced++
    }
}
# 2) 其余插件原地保留，另外完整复制一份进备份；这样备份里就是你原来的整套插件
Robo $addDst $bkAdd
$bkCount = @(Get-ChildItem -LiteralPath $bkAdd -Directory).Count
if ($bkCount -lt $origCount) { Fail "插件备份不完整（原有 $origCount 个，备份 $bkCount 个），已停止。被替换的插件在：$bkAdd" }
Say "  已备份：WTF（账号与角色配置）、插件 $origCount 个"

# ---------- 安装插件 ----------
Say '安装插件（文件较多，请稍等）……' 'Cyan'
Robo (Join-Path $payload 'Interface\AddOns') $addDst

# ---------- 字体与图标：只补你没有的，并记下新增了哪些 ----------
$addedList = @()
foreach ($rel in 'Fonts', 'Interface\Icons') {
    $src = Join-Path $payload $rel
    if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $forever $rel
        $new = @(Missing-Files $src $dst)
        Robo $src $dst -MissingOnly
        foreach ($f in $new) { $addedList += ($rel + '\' + $f) }
        Say "  $rel：新增 $($new.Count) 个文件（已有的保持不变）"
    }
}
if ($addedList.Count -gt 0) {
    [System.IO.File]::WriteAllLines((Join-Path $bk '新增字体与图标清单.txt'), [string[]]$addedList, $utf8)
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
Say "  替换同名插件 $replaced 个"
Say "  使用整合包布局的插件配置 $svAdded 份（你原有的配置全部保留）"
Say "  角色插件列表补充 $txtAdded 项"
Say "备份位置：$bk"
Say '进游戏后输入 /kk 打开 KkowoUI 设置。'
Say '还原：删掉 _forever_\Interface\AddOns 和 _forever_\WTF，把备份里的 Interface\AddOns、WTF 复制回 _forever_；'
Say '      新增的字体和图标见备份里的「新增字体与图标清单.txt」，不想要可以按清单删除。'
