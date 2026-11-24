# ForeverUI 手动部署脚本（请在【完全退出魔兽世界】后再运行！）
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
$src  = Join-Path $root 'Addon\ForeverUI'
$dst  = Join-Path $AddOns 'ForeverUI'

if (-not $Link -and -not $Copy) {
    Write-Host "请指定部署模式：-Link（创建目录链接）或 -Copy（复制文件）。未做任何改动。" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $AddOns)) {
    throw "找不到游戏 AddOns 目录：$AddOns"
}

# 检查游戏进程是否在运行
if (Get-Process -Name "Wow*" -ErrorAction SilentlyContinue) {
    Write-Host "警告：检测到魔兽世界客户端正在运行！建议先退出游戏再执行部署。" -ForegroundColor Yellow
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
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        # 备份放在仓库同级的 backups 目录（可用环境变量 WOW_BACKUP_ROOT 覆盖）
        $backupRoot = if ($env:WOW_BACKUP_ROOT) { $env:WOW_BACKUP_ROOT } else { Join-Path (Split-Path -Parent $root) 'backups' }
        $bak = Join-Path $backupRoot "ForeverUI_deploybak_$stamp"
        New-Item -ItemType Directory -Path (Split-Path -Parent $bak) -Force | Out-Null
        Move-Item -Path $dst -Destination $bak
        Write-Host "已将旧版 ForeverUI 备份至：$bak" -ForegroundColor Cyan
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
Write-Host "  1. 勾选启用 ForeverUI"
Write-Host "  2. 停用已被替代/冗余插件：EUI_Haalandtool、ForeverLootSparkles、ArcUI、BlizzMove、BlizzMove_Debug、QuestieTrace"
Write-Host "  3. （可选）如果想用 ForeverUI 内置的极简系统栏/鼠标提示，可停用 QFXSystemBar / PrettyTooltip"
Write-Host "  4. 在 Leatrix_Maps 设置里关闭「显示区域等级」（ShowZoneLevels），保留船艇/飞点/副本图标"
Write-Host "  5. 进游戏输入 /fui 打开设置，或 /fui status 查看全部模块运行状态"
