# KkowoUI 手动部署脚本（请在【完全退出魔兽世界】后再运行！）
# 用法：
#   powershell -ExecutionPolicy Bypass -File Tools\deploy.ps1 -Link   # 创建目录链接（开发调样式推荐，改代码直接 /reload）
#   powershell -ExecutionPolicy Bypass -File Tools\deploy.ps1 -Copy   # 独立复制进 AddOns
param(
    [switch]$Link,
    [switch]$Copy,
    [string]$AddOns = 'E:\Program Files\World of Warcraft\_forever_\Interface\AddOns'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $root 'Addon\KkowoUI'
$dst  = Join-Path $AddOns 'KkowoUI'

if (-not $Link -and -not $Copy) {
    Write-Host "请指定部署模式：-Link（创建目录链接）或 -Copy（复制文件）。未做任何改动。" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $AddOns)) {
    throw "找不到游戏 AddOns 目录：$AddOns"
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
# 备份放在仓库同级的 backups 目录（可用环境变量 WOW_BACKUP_ROOT 覆盖）
$backupRoot = if ($env:WOW_BACKUP_ROOT) { $env:WOW_BACKUP_ROOT } else { Join-Path (Split-Path -Parent $root) 'backups' }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# 旧名 ForeverUI → KkowoUI 一次性迁移：
#   WoW 按插件文件夹名读写存档（KkowoUI.lua），插件内部读不到旧的 ForeverUI.lua，只能在游戏外改名；
#   旧的 AddOns\ForeverUI 若保留，会与 KkowoUI 同时加载（两套系统栏 / 聊天栏 / 拾取钩子）。
function Invoke-ForeverUIMigration {
    # 1) 旧插件目录 / 目录链接
    $oldDst = Join-Path $AddOns 'ForeverUI'
    $oldItem = Get-Item -LiteralPath $oldDst -Force -ErrorAction SilentlyContinue
    if ($oldItem) {
        if ($oldItem.LinkType -in @('Junction', 'SymbolicLink')) {
            # 非递归删除只移除链接本身，不碰链接指向的目录
            [System.IO.Directory]::Delete($oldDst, $false)
            Write-Host "已移除旧目录链接：$oldDst" -ForegroundColor Cyan
        } else {
            $oldBak = Join-Path $backupRoot "ForeverUI_renamed_$stamp"
            New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
            Move-Item -LiteralPath $oldDst -Destination $oldBak
            Write-Host "已将旧版 ForeverUI 目录移至：$oldBak" -ForegroundColor Cyan
        }
    }

    $wtfAccount = Join-Path (Split-Path -Parent (Split-Path -Parent $AddOns)) 'WTF\Account'
    if (-not (Test-Path -LiteralPath $wtfAccount)) { return }
    $accRoot = (Get-Item -LiteralPath $wtfAccount -Force).FullName.TrimEnd('\')
    $migBak = Join-Path $backupRoot "WTF_ForeverUI_migrate_$stamp"

    # 2) 账号级 / 角色级存档 ForeverUI.lua(.bak) → KkowoUI.lua(.bak)，存档变量名同步替换
    $svFiles = Get-ChildItem -LiteralPath $accRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'SavedVariables' -and ($_.Name -eq 'ForeverUI.lua' -or $_.Name -eq 'ForeverUI.lua.bak') }
    foreach ($f in $svFiles) {
        $rel = $f.FullName.Substring($accRoot.Length).TrimStart('\')
        $newPath = Join-Path $f.DirectoryName ($f.Name -replace '^ForeverUI', 'KkowoUI')
        if (Test-Path -LiteralPath $newPath) {
            Write-Host "未迁移 $rel：同目录已有 KkowoUI 存档，未覆盖（想改用旧配置就删掉 KkowoUI 存档后重新运行本脚本）。" -ForegroundColor Yellow
            continue
        }
        $bakPath = Join-Path $migBak $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $bakPath) -Force | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $bakPath
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        $text = [regex]::Replace($text, '\bForeverUI(Char)?DB\b', 'KkowoUI${1}DB')
        [System.IO.File]::WriteAllText($newPath, $text, $utf8NoBom)
        Remove-Item -LiteralPath $f.FullName -Force
        Write-Host "已迁移存档：$rel（原文件备份在 $migBak）" -ForegroundColor Green
    }

    # 3) 各角色 AddOns.txt：沿用旧名的启用 / 停用状态
    $addonTxts = Get-ChildItem -LiteralPath $accRoot -Recurse -File -Filter 'AddOns.txt' -Force -ErrorAction SilentlyContinue
    foreach ($t in $addonTxts) {
        $text = [System.IO.File]::ReadAllText($t.FullName, [System.Text.Encoding]::UTF8)
        if ($text -notmatch '(?m)^ForeverUI:' -or $text -match '(?m)^KkowoUI:') { continue }
        $rel = $t.FullName.Substring($accRoot.Length).TrimStart('\')
        $bakPath = Join-Path $migBak $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $bakPath) -Force | Out-Null
        Copy-Item -LiteralPath $t.FullName -Destination $bakPath
        $text = [regex]::Replace($text, '(?m)^ForeverUI:', 'KkowoUI:')
        [System.IO.File]::WriteAllText($t.FullName, $text, $utf8NoBom)
        Write-Host "已更新插件启用列表：$rel" -ForegroundColor Green
    }
}

# 检查游戏进程是否在运行
$wowRunning = [bool](Get-Process -Name "Wow*" -ErrorAction SilentlyContinue)
if ($wowRunning) {
    Write-Host "警告：检测到魔兽世界客户端正在运行！建议先退出游戏再执行部署。" -ForegroundColor Yellow
    # 游戏退出时会用内存里的数据重写 KkowoUI.lua，此时迁移的存档会被覆盖
    Write-Host "已跳过旧名 ForeverUI 的存档迁移与旧目录清理，退出游戏后重新运行本脚本即可完成。" -ForegroundColor Yellow
} else {
    Invoke-ForeverUIMigration
}

if (Test-Path $dst) {
    $item = Get-Item $dst -Force
    if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
        if ($Link -and ($item.Target -contains $src)) {
            Write-Host "已链接：$dst -> $src" -ForegroundColor Green
            exit 0
        }
        # 非递归删除只移除链接本身，绝不触碰链接指向的仓库目录（路径含空格也安全）
        [System.IO.Directory]::Delete($dst, $false)
    } else {
        $bak = Join-Path $backupRoot "KkowoUI_deploybak_$stamp"
        New-Item -ItemType Directory -Path (Split-Path -Parent $bak) -Force | Out-Null
        Move-Item -Path $dst -Destination $bak
        Write-Host "已将旧版 KkowoUI 备份至：$bak" -ForegroundColor Cyan
    }
}

if ($Link) {
    New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
    Write-Host "已创建目录链接：$dst -> $src" -ForegroundColor Green
} else {
    Copy-Item -Path $src -Destination $dst -Recurse -Force
    Write-Host "已复制到：$dst" -ForegroundColor Green
}

Write-Host ""
Write-Host "下一步（进游戏人物选择界面 → 插件列表）：" -ForegroundColor Cyan
Write-Host "  1. 勾选启用 KkowoUI"
Write-Host "  2. 停用已被替代/冗余插件：EUI_Haalandtool、ForeverLootSparkles、ArcUI、BlizzMove、BlizzMove_Debug、QuestieTrace"
Write-Host "  3. （可选）如果想用 KkowoUI 内置的极简系统栏/鼠标提示，可停用 QFXSystemBar / PrettyTooltip"
Write-Host "  4. 在 Leatrix_Maps 设置里关闭「显示区域等级」（ShowZoneLevels），保留船艇/飞点/副本图标"
Write-Host "  5. 进游戏输入 /kk 打开设置，或 /kk status 查看全部模块运行状态"
