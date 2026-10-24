@echo off
rem toco-logs.bat - collect logs from OrangeFox over adb (Windows). Read-only on the phone.
rem
rem   toco-logs.bat                   the phone is already running OrangeFox, even if it sits on the logo
rem   toco-logs.bat recovery.img      run "fastboot boot recovery.img" first, then collect twice
rem                                   (about 30 seconds and about 2 minutes after booting)
rem
rem Needs adb (and fastboot for the second form) in PATH. Easiest: copy this file into the
rem platform-tools folder and double-click it, or run it from a command prompt there.
rem Result: a folder and a .zip on the Desktop. Send the .zip (or just recovery.log from it).

setlocal EnableExtensions

where adb >nul 2>nul
if errorlevel 1 (
  echo adb was not found in PATH. Copy this file into the platform-tools folder and run it again.
  pause
  exit /b 1
)

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%i"
set "OUT=%USERPROFILE%\Desktop\toco-logs-%STAMP%"
mkdir "%OUT%"
if errorlevel 1 (
  echo Could not create %OUT%
  pause
  exit /b 1
)
echo Logs go to: %OUT%

if "%~1"=="" goto waitphone

if not exist "%~1" (
  echo File not found: %~1
  pause
  exit /b 1
)
where fastboot >nul 2>nul
if errorlevel 1 (
  echo fastboot was not found in PATH.
  pause
  exit /b 1
)
echo Booting %~1 ...
fastboot boot "%~1" > "%OUT%\fastboot-boot.txt" 2>&1
type "%OUT%\fastboot-boot.txt"

:waitphone
echo Waiting for the phone to show up in adb, up to 3 minutes ...
set /a TRIES=0
:wait
adb devices 2>nul | findstr /r /c:"recovery$" /c:"device$" >nul
if not errorlevel 1 goto found
set /a TRIES+=1
if %TRIES% GEQ 90 goto nodevice
timeout /t 2 /nobreak >nul
goto wait

:nodevice
echo.
echo The phone did not show up in adb. What adb sees:
adb devices -l
adb devices -l > "%OUT%\adb-devices.txt" 2>&1
echo.
echo If the list is empty while the phone shows the OrangeFox logo, Windows probably has no
echo driver for the phone in recovery mode. Look in Device Manager for a device with a yellow
echo mark and install the Google USB driver or the Xiaomi USB driver for it.
goto zip

:found
adb devices -l > "%OUT%\adb-devices.txt" 2>&1
if "%~1"=="" (
  call :collect "%OUT%"
) else (
  echo Phone is up. Collecting in 30 seconds ...
  timeout /t 30 /nobreak >nul
  call :collect "%OUT%\round1-30s"
  echo Collecting again in 90 seconds ...
  timeout /t 90 /nobreak >nul
  call :collect "%OUT%\round2-2min"
)

:zip
powershell -NoProfile -Command "Compress-Archive -Path '%OUT%\*' -DestinationPath '%OUT%.zip' -Force"
echo.
echo Done. Send this file: %OUT%.zip
pause
exit /b 0

:collect
set "D=%~1"
if not exist "%D%" mkdir "%D%"
echo Collecting into %D% ...
adb exec-out cat /tmp/recovery.log > "%D%\recovery.log"
adb exec-out cat /tmp/fox-decrypt-diag.log > "%D%\fox-decrypt-diag.log"
adb exec-out dmesg > "%D%\dmesg.txt"
adb exec-out logcat -d -b all -v threadtime > "%D%\logcat.txt"
adb exec-out getprop > "%D%\getprop.txt"
adb exec-out ps -A > "%D%\ps.txt"
adb exec-out cat /proc/mounts > "%D%\mounts.txt"
adb exec-out cat /proc/cmdline > "%D%\cmdline.txt"
adb exec-out "ls -l /dev/block/bootdevice/by-name/ /dev/sg* /dev/qseecom /dev/ion /dev/binderfs /vendor/firmware_mnt/image 2>&1" > "%D%\devnodes.txt"
adb exec-out "for f in /sys/fs/pstore/*; do echo ===== $f; cat $f; done 2>&1" > "%D%\pstore.txt"
goto :eof
