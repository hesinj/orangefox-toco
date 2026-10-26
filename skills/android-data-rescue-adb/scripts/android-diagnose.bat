@echo off
rem android-diagnose.bat - READ-ONLY: collects evidence about why Android (the installed ROM) does not boot, from OrangeFox (Windows).
rem
rem   1. boot OrangeFox on the phone (fastboot boot ...) and type the password on the phone so that /data is unlocked
rem   2. double-click this file, or run it from a Command Prompt (keep android-boot-diagnose.sh next to it;
rem      adb must be in PATH, or put both files into the platform-tools folder)
rem   android-diagnose.bat quick    runs only the 20-second part (no full read of the files and partitions)
rem Result: android-diag-<time>.tgz on the Desktop. Nothing on the phone is changed: the script only reads, and everything it
rem produces is written to /tmp, which lives in RAM.

setlocal EnableExtensions
set "DEEP=1"
if /i "%~1"=="quick" set "DEEP=0"

where adb >nul 2>nul
if errorlevel 1 (
  echo adb was not found in PATH. Copy this file and android-boot-diagnose.sh into the platform-tools folder and run it again.
  pause
  exit /b 1
)
if not exist "%~dp0android-boot-diagnose.sh" (
  echo android-boot-diagnose.sh must be in the same folder as this file.
  pause
  exit /b 1
)
adb get-state >nul 2>&1
if errorlevel 1 (
  echo No phone found by adb. Boot OrangeFox first and wait for its menu or password screen, then run this again.
  pause
  exit /b 1
)

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%i"
set "OUT=%USERPROFILE%\Desktop\android-diag-%STAMP%.tgz"

adb push "%~dp0android-boot-diagnose.sh" /tmp/android-boot-diagnose.sh
if errorlevel 1 (
  echo Could not copy the script to the phone.
  pause
  exit /b 1
)
echo.
if "%DEEP%"=="0" (
  echo Running the quick read-only diagnosis, about 20 seconds ...
) else (
  echo Running the read-only diagnosis on the phone. It reads every file and every partition once: about 3 to 6 minutes.
  echo A line is printed for every step; do not unplug the phone and do not touch it until it says Done.
)
rem the tr strips Windows line endings in case the file was converted to CRLF on the way
adb shell "tr -d '\015' < /tmp/android-boot-diagnose.sh > /tmp/abd.sh && DIAG_DEEP=%DEEP% sh /tmp/abd.sh"
echo.
adb pull /tmp/android-diag.tgz "%OUT%"
if errorlevel 1 (
  echo Could not copy the result from the phone.
  pause
  exit /b 1
)
echo.
echo Done. Send this file: %OUT%
pause
exit /b 0
