# kkowoUI 整合包 安装器
# 1) 先把你原来的全部插件、图标（Interface）、字体（Fonts）整夹移进备份，并完整复制一份 WTF 配置（账号与各角色）进备份；
# 2) 再装上本整合包：插件只保留整合包里的这一套（干净，不会有其他插件和本整合包冲突），字体和图标用整合包的；
# 3) 配置合并：你已经配置过的插件保留你的设置和布局，没配置过的插件使用整合包布局；各角色启用的插件按整合包设置。
# 全程只移动和复制，不删除任何文件。备份位置：World of Warcraft\kkowoUI安装备份_日期。
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

# robocopy 只复制、从不删除目标里的文件；-MissingOnly（/XC /XN /XO）= 目标已有的文件一律不动，只复制目标没有的
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

# 角色的启用插件列表：整合包里的插件按整合包的启用 / 停用设置（插件集保持干净一致），其他行原样保留
function Merge-AddOnsTxt([string]$path, [string]$tpl) {
    $theirs = [System.IO.File]::ReadAllText($path, $utf8)
    $nl = "`n"
    if ($theirs.Contains("`r`n")) { $nl = "`r`n" }
    $pack = [ordered]@{}
    foreach ($ln in [System.IO.File]::ReadAllLines($tpl, $utf8)) {
        $i = $ln.IndexOf(':')
        if ($i -gt 0) { $pack[$ln.Substring(0, $i).Trim().ToLower()] = $ln.Trim() }
    }
    $used = @{}
    $changed = 0
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($ln in ($theirs.TrimEnd("`r", "`n") -split "`r?`n")) {
        $i = $ln.IndexOf(':')
        if ($i -gt 0) {
            $k = $ln.Substring(0, $i).Trim().ToLower()
            if ($pack.Contains($k)) {
                if ($used.ContainsKey($k)) { $changed++; continue }   # 重复的行只留一行
                $used[$k] = $true
                if ($ln.Trim() -cne $pack[$k]) { $changed++ }
                $out.Add($pack[$k])
                continue
            }
        }
        $out.Add($ln)
    }
    foreach ($k in $pack.Keys) {
        if (-not $used.ContainsKey($k)) { $out.Add($pack[$k]); $changed++ }
    }
    if ($changed -gt 0) { [System.IO.File]::WriteAllText($path, (($out -join $nl) + $nl), $utf8) }
    return $changed
}

Say '================ kkowoUI 整合包 安装器 ================' 'Cyan'
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
$origAddons = @()
$addDir = Join-Path $forever 'Interface\AddOns'
if (Test-Path -LiteralPath $addDir) { $origAddons = @(Get-ChildItem -LiteralPath $addDir -Directory | ForEach-Object { $_.Name }) }
Say ("账号 {0} 个，角色 {1} 个，现有插件 {2} 个" -f $accounts.Count, $chars.Count, $origAddons.Count)

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$bk = Join-Path $wowRoot ("kkowoUI安装备份_" + $stamp)
Say ''
Say '即将进行：' 'Cyan'
Say "  1. 备份到 $bk ："
Say '     你原来的全部插件和图标（Interface）、字体（Fonts）整夹移进备份，WTF 配置（账号与各角色）完整复制一份'
Say '  2. 装上整合包：插件只保留整合包这一套（其他插件不再加载，避免冲突），字体和图标用整合包的'
Say '  3. 合并配置：你配置过的插件保留你的设置和布局，没配置过的插件使用整合包布局'
if (-not (Ask-YesNo '确定开始安装吗？')) { Fail '已取消。' }

# ---------- 备份（只移动、复制，不删除） ----------
New-Item -ItemType Directory -Force -Path $bk | Out-Null
Say '备份 WTF 配置……' 'Cyan'
Robo (Join-Path $forever 'WTF') (Join-Path $bk 'WTF')
if ((Count-Files (Join-Path $bk 'WTF')) -lt (Count-Files (Join-Path $forever 'WTF'))) { Fail "WTF 备份不完整，已停止（未改动任何插件）。备份位置：$bk" }
foreach ($rel in 'Interface', 'Fonts') {
    $p = Join-Path $forever $rel
    if (Test-Path -LiteralPath $p) {
        Move-Item -LiteralPath $p -Destination (Join-Path $bk $rel)
        Say "  已移进备份：$rel"
    }
}
Say "  已备份：WTF、全部插件 $($origAddons.Count) 个、图标与字体"

# ---------- 安装整合包 ----------
Say '安装插件、图标和字体（文件较多，请稍等）……' 'Cyan'
Robo (Join-Path $payload 'Interface') (Join-Path $forever 'Interface')
if (Test-Path -LiteralPath (Join-Path $payload 'Fonts')) { Robo (Join-Path $payload 'Fonts') (Join-Path $forever 'Fonts') }

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
$txtChanged = 0
foreach ($c in $chars) {
    $csv = Join-Path $c.FullName 'SavedVariables'
    if (Test-Path -LiteralPath $csv) { $null = Copy-VssSV $csv }
    $txt = Join-Path $c.FullName 'AddOns.txt'
    $hadTxt = Test-Path -LiteralPath $txt
    Robo $chrTpl $c.FullName -MissingOnly
    if ($hadTxt) { $txtChanged += Merge-AddOnsTxt $txt (Join-Path $chrTpl 'AddOns.txt') }
}

$packAddons = @(Get-ChildItem -LiteralPath (Join-Path $forever 'Interface\AddOns') -Directory).Count
Say ''
Say '================ 安装完成 ================' 'Green'
Say "  现在的插件：整合包 $packAddons 个（原来的 $($origAddons.Count) 个已全部备份）"
Say "  使用整合包布局的插件配置 $svAdded 份（你原有的配置全部保留）"
Say "  角色插件列表调整 $txtChanged 项"
Say "备份位置：$bk"
Say '进游戏后输入 /kk 打开 kkowoUI 设置。'
Say '还原：先把 _forever_ 里现在的 Interface、Fonts、WTF 改名或移走，再把备份里的同名文件夹复制回 _forever_。'
