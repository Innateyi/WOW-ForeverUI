@echo off
chcp 65001 >nul
title KkowoUI DD更新后重打补丁
echo 网易DD 更新 EllesmereUI / Polestar / 极速导航 后，会覆盖 KkowoUI 的本地补丁。
echo 本工具一键重新打上全部补丁（自动备份原文件到 backups），并把 DD 装回来的原版极速导航改名为 kkowo优化版。
echo 运行前请先完全退出魔兽世界。
echo.
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 -I "%~dp0apply_patches.py" --apply
) else (
    python -I "%~dp0apply_patches.py" --apply
)
echo.
pause
