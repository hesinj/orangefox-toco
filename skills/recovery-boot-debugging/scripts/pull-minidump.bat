@echo off
rem pull-minidump.bat - READ-ONLY: copies the first 4 MiB of the phone's "minidump" partition to the Desktop.
rem
rem That partition is where the phone's firmware keeps a crash dump (a copy of the kernel log of the session that crashed).
rem Nothing is written to the phone: the data is read with dd and goes straight to the PC.
rem   1. boot OrangeFox on the phone (fastboot boot ...); the password is not needed
rem   2. double-click this file (adb must be in PATH, or put this file into the platform-tools folder)
rem Result: minidump-<time>.bin on the Desktop (exactly 4194304 bytes). Send that file.

setlocal EnableExtensions

where adb >nul 2>nul
if errorlevel 1 (
  echo adb was not found in PATH. Copy this file into the platform-tools folder and run it again.
  pause
  exit /b 1
)
adb get-state >nul 2>&1
if errorlevel 1 (
  echo No phone found by adb. Boot OrangeFox first and wait for its menu, then run this again.
  pause
  exit /b 1
)
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%i"
set "OUT=%USERPROFILE%\Desktop\minidump-%STAMP%.bin"

adb exec-out "dd if=/dev/block/bootdevice/by-name/minidump bs=1048576 count=4 2>/dev/null" > "%OUT%"
for %%F in ("%OUT%") do set "SZ=%%~zF"
echo.
echo File: %OUT%
echo Size: %SZ% bytes (it must be 4194304)
if not "%SZ%"=="4194304" echo WARNING: the size is wrong. Run this file again; if it stays wrong, tell me.
echo.
echo Done. Send this file.
pause
exit /b 0
