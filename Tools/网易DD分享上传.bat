@echo off
chcp 65001 >nul
title kkowoUI 网易DD 分享上传
echo 网易DD 配置分享上传助手：生成脱敏副本 -^> 换入 -^> 你上传 -^> 换回
echo 运行前请先完全退出魔兽世界。
echo.
where py >nul 2>nul
if %errorlevel%==0 (
    py -3 -I "%~dp0prepare_share_wtf.py" --upload
) else (
    python -I "%~dp0prepare_share_wtf.py" --upload
)
echo.
pause
