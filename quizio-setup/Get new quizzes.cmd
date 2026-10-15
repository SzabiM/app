@echo off
rem Double-click: saves new quizzes + photos from GitHub into D:\CLAUDE_PROJECTS\QUIZIO (and uploads your Studio changes).
rem Safe to put anywhere, e.g. on the Desktop. Same sync the hidden 10-minute task runs.
set "Q=D:\CLAUDE_PROJECTS\QUIZIO"
title Quizio - get new quizzes
if not exist "%Q%\tools\git-sync\sync.ps1" (
  echo Quizio sync is not installed in %Q%. Run quizio-setup.ps1 first.
  pause & exit /b 1
)
echo Syncing with GitHub...
powershell -NoProfile -ExecutionPolicy Bypass -File "%Q%\tools\git-sync\sync.ps1"
echo.
echo Result:
powershell -NoProfile -Command "Get-Content '%Q%\tools\git-sync\state\sync.log' -Tail 1"
echo.
echo Newest quizzes in data\:
powershell -NoProfile -Command "Get-ChildItem '%Q%\data\*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object { '  ' + $_.Name + '   ' + $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }"
echo.
echo "ok" or "new quiz" = done. Tick the quiz in Quizio Studio and press Make.
echo "render running - skipped" = wait for the render to finish, then run this again.
pause
