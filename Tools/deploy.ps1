# kkowoUI 部署脚本（必须先完全退出魔兽世界）
# 把仓库里的 Addon\kkowoUI 复制成游戏 AddOns 里的真实文件夹（不使用目录链接）。
# 用法：powershell -ExecutionPolicy Bypass -File Tools\deploy.ps1
#
# 绝不删除任何文件：
#   - 游戏 AddOns 里已有的 kkowoUI / KkowoUI / ForeverUI 文件夹整夹移进备份
#     （备份目录：仓库同级 backups\kkowoUI部署前_<时间>，可用环境变量 WOW_BACKUP_ROOT 改位置）
#   - 旧的目录链接只移除「链接本身」：先确认它是链接，再非递归移除，链接指向的仓库文件不受影响
#   - 改名迁移：存档 ForeverUI.lua / KkowoUI.lua(.bak) → kkowoUI.lua(.bak)，存档变量名改成 kkowoUIDB / kkowoUICharDB；
#     原文件移进备份后再写新文件。各角色 AddOns.txt 先备份，再把旧名那一行改成 kkowoUI。
param(
    [string]$AddOns = 'E:\Program Files\World of Warcraft\_forever_\Interface\AddOns'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src  = Join-Path $root 'Addon\kkowoUI'
$name = 'kkowoUI'
$oldNames = @('kkowoUI', 'KkowoUI', 'ForeverUI')   # 文件夹名 Windows 不区分大小写，KkowoUI 与 kkowoUI 是同一个

if (Get-Process -Name 'Wow*' -ErrorAction SilentlyContinue) {
    Write-Host '魔兽世界正在运行：请完全退出游戏后再部署（游戏退出时会覆盖存档与 AddOns.txt）。未做任何改动。' -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $src "$name.toc"))) { throw "找不到插件源目录：$src" }
if (-not (Test-Path -LiteralPath $AddOns)) { throw "找不到游戏 AddOns 目录：$AddOns" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupRoot = if ($env:WOW_BACKUP_ROOT) { $env:WOW_BACKUP_ROOT } else { Join-Path (Split-Path -Parent $root) 'backups' }
$bk = Join-Path $backupRoot "kkowoUI部署前_$stamp"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Ensure-Dir([string]$p) { New-Item -ItemType Directory -Force -Path $p | Out-Null }

# ---------- 1) 旧插件文件夹 / 目录链接 ----------
$old = @(Get-ChildItem -LiteralPath $AddOns -Directory -Force | Where-Object { $oldNames -contains $_.Name })
foreach ($it in $old) {
    if ($it.LinkType -in @('Junction', 'SymbolicLink')) {
        $target = ($it.Target -join ', ')
        [System.IO.Directory]::Delete($it.FullName, $false)   # 非递归：只移除链接本身
        Write-Host "已移除目录链接：$($it.FullName) -> $target（链接指向的文件未动）" -ForegroundColor Cyan
    } else {
        Ensure-Dir (Join-Path $bk 'AddOns')
        $dest = Join-Path $bk ('AddOns\' + $it.Name)
        Move-Item -LiteralPath $it.FullName -Destination $dest
        Write-Host "已把旧文件夹移进备份：$($it.Name) -> $dest" -ForegroundColor Cyan
    }
}

# ---------- 2) 复制成真实文件夹 ----------
$dst = Join-Path $AddOns $name
& robocopy $src $dst /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "复制失败（robocopy 代码 $LASTEXITCODE）：$src -> $dst" }
$nSrc = @(Get-ChildItem -LiteralPath $src -File -Recurse).Count
$nDst = @(Get-ChildItem -LiteralPath $dst -File -Recurse).Count
if ($nSrc -ne $nDst) { throw "复制校验失败：源 $nSrc 个文件，目标 $nDst 个" }
Write-Host "已复制到：$dst（$nDst 个文件）" -ForegroundColor Green

# ---------- 3) 存档与 AddOns.txt 改名迁移 ----------
$wtfAccount = Join-Path (Split-Path -Parent (Split-Path -Parent $AddOns)) 'WTF\Account'
if (Test-Path -LiteralPath $wtfAccount) {
    $accRoot = (Get-Item -LiteralPath $wtfAccount -Force).FullName.TrimEnd('\')
    $svFiles = @(Get-ChildItem -LiteralPath $accRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'SavedVariables' -and $_.Name -match '^(ForeverUI|kkowoUI)\.lua(\.bak)?$' })
    foreach ($f in $svFiles) {
        $suffix = $f.Name.Substring($f.Name.IndexOf('.'))           # .lua 或 .lua.bak
        $newName = $name + $suffix
        $isForever = $f.Name -like 'ForeverUI*'
        $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
        $newText = [regex]::Replace($text, '\b(ForeverUI|KkowoUI)(Char)?DB\b', 'kkowoUI${2}DB')   # 区分大小写，不碰已是 kkowoUIDB 的
        if (-not $isForever -and $f.Name -ceq $newName -and $newText -ceq $text) { continue }   # 已是新名字
        $newPath = Join-Path $f.DirectoryName $newName
        if ($isForever -and (Test-Path -LiteralPath $newPath)) {
            Write-Host "未迁移 $($f.FullName)：同目录已有 kkowoUI 存档，保持不动。" -ForegroundColor Yellow
            continue
        }
        $rel = $f.FullName.Substring($accRoot.Length).TrimStart('\')
        $bakPath = Join-Path $bk ('WTF\' + $rel)
        Ensure-Dir (Split-Path -Parent $bakPath)
        Move-Item -LiteralPath $f.FullName -Destination $bakPath          # 原文件移进备份
        [System.IO.File]::WriteAllText($newPath, $newText, $utf8NoBom)   # 再写新文件（文件名大小写也一并改正）
        Write-Host "已迁移存档：$rel -> $newName" -ForegroundColor Green
    }
    $txts = @(Get-ChildItem -LiteralPath $accRoot -Recurse -File -Filter 'AddOns.txt' -Force -ErrorAction SilentlyContinue)
    foreach ($t in $txts) {
        $raw = [System.IO.File]::ReadAllText($t.FullName, [System.Text.Encoding]::UTF8)
        if ($raw -cnotmatch '(?m)^(ForeverUI|KkowoUI):') { continue }
        $rel = $t.FullName.Substring($accRoot.Length).TrimStart('\')
        $bakPath = Join-Path $bk ('WTF\' + $rel)
        Ensure-Dir (Split-Path -Parent $bakPath)
        Copy-Item -LiteralPath $t.FullName -Destination $bakPath
        $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
        $hasNew = $raw -cmatch '(?m)^kkowoUI:'
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($ln in ($raw -split "`r?`n")) {
            if ($ln -cmatch '^(ForeverUI|KkowoUI):(.*)$') {
                if ($hasNew) { continue }                    # 已有 kkowoUI 一行：旧名那行不再需要
                $ln = 'kkowoUI:' + $Matches[2]
                $hasNew = $true
            }
            $out.Add($ln)
        }
        [System.IO.File]::WriteAllText($t.FullName, ($out -join $nl), $utf8NoBom)
        Write-Host "已更新插件启用列表：$rel" -ForegroundColor Green
    }
}

if (Test-Path -LiteralPath $bk) { Write-Host "备份位置：$bk" -ForegroundColor Cyan }
Write-Host ''
Write-Host '完成。进游戏输入 /kk status 查看版本与模块状态。' -ForegroundColor Cyan
