@echo off
rem ram-test.bat [minutes] [percent]      Stress-tests the phone's RAM from the recovery. Writes nothing to the phone's storage.
rem
rem   1. boot OrangeFox on the phone (fastboot boot ...); the password is not needed
rem   2. keep memstress-aarch64 next to this file; adb must be in PATH (or put both files into the platform-tools folder)
rem   3. double-click this file, or run it from a Command Prompt:    ram-test.bat 8 50
rem        minutes  how long to test (default 8)       percent  share of the free RAM to test (default 50, at most 75)
rem Everything runs in the phone's RAM: the program is copied to /tmp (RAM) and uses anonymous memory only.
rem The result is shown here and saved as memstress-<time>.txt on the Desktop. If the phone freezes or restarts during the test, that is
rem a result too: copy what the window shows, boot the recovery again, run android-diagnose.bat quick, and send both.

setlocal EnableExtensions
set "MIN=%~1"
if "%MIN%"=="" set "MIN=8"
set "PCT=%~2"
if "%PCT%"=="" set "PCT=50"

where adb >nul 2>nul
if errorlevel 1 (
  echo adb was not found in PATH. Copy this file and memstress-aarch64 into the platform-tools folder and run it again.
  pause
  exit /b 1
)
if not exist "%~dp0memstress-aarch64" (
  echo memstress-aarch64 must be in the same folder as this file.
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
set "OUT=%USERPROFILE%\Desktop\memstress-%STAMP%.txt"

adb push "%~dp0memstress-aarch64" /tmp/memstress
if errorlevel 1 (
  echo Could not copy the program to the phone.
  pause
  exit /b 1
)
adb shell chmod 755 /tmp/memstress
echo.
echo Testing the RAM for %MIN% minutes using %PCT% percent of the free memory. A line appears every 15 seconds.
echo The phone gets warm and the screen may stay on; do not unplug it and do not touch it until the result is shown.
echo.
adb shell "echo ===== UFS health attributes, hex > /tmp/memstress.out; for f in $(find /sys/devices -maxdepth 7 -path '*ufshc*/health_descriptor/*' -type f); do echo $f >> /tmp/memstress.out; od -An -tx1 $f >> /tmp/memstress.out; done; cat /tmp/memstress.out"
echo.
adb shell "/tmp/memstress %MIN% %PCT% 2>&1 | tee -a /tmp/memstress.out"
echo.
adb shell "echo ===== temperatures reported by the charger driver, last lines >> /tmp/memstress.out; dmesg | grep -E 'DIE_TEMP|BATT_TEMP' | tail -n 6 >> /tmp/memstress.out; echo ===== kernel messages that may belong to the test >> /tmp/memstress.out; dmesg | tail -n 600 | grep -i -E 'oom|killed process|edac|ecc|bark|bite|panic|oops|bug:|i/o error|ufshcd.*(err|fail)' >> /tmp/memstress.out"
adb pull /tmp/memstress.out "%OUT%"
adb shell rm -f /tmp/memstress /tmp/memstress.out
echo.
echo Done. Send this file: %OUT%
pause
exit /b 0
