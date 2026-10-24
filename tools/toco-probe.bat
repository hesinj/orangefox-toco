@echo off
rem toco-probe.bat - start the decryption services one by one on the phone and watch what happens.
rem
rem The -nocrypt OrangeFox must be running on the phone: fastboot boot OrangeFox-R12.0_nocrypt-Unofficial-toco-r3.img
rem Keep this file, toco-probe.sh and the probe-libs folder together. adb must be in PATH (or put the folder next to adb.exe).
rem Nothing is written to the phone's storage: the files go to /tmp, which lives in RAM.
rem If the phone freezes or restarts while this runs, copy the last lines shown in this window.

setlocal EnableExtensions

where adb >nul 2>nul
if errorlevel 1 (
  echo adb was not found in PATH. Put this folder next to adb.exe and run it again.
  pause
  exit /b 1
)
if not exist "%~dp0toco-probe.sh" (
  echo toco-probe.sh must be in the same folder as this file.
  pause
  exit /b 1
)
if not exist "%~dp0probe-libs\" (
  echo The probe-libs folder must be in the same folder as this file.
  pause
  exit /b 1
)

adb shell mkdir -p /tmp/probe-libs
if errorlevel 1 (
  echo Could not reach the phone over adb. Is the nocrypt OrangeFox running?
  pause
  exit /b 1
)
echo Pushing the four libraries the nocrypt image lacks to /tmp/probe-libs ...
for %%f in ("%~dp0probe-libs\*.so") do adb push "%%f" /tmp/probe-libs/
adb push "%~dp0toco-probe.sh" /tmp/toco-probe.sh
echo.
echo Running the probe. This takes about 40 seconds. If the phone freezes, copy the last lines of this window.
echo.
adb shell sh /tmp/toco-probe.sh
echo.
adb pull /tmp/toco-probe.log "%USERPROFILE%\Desktop\toco-probe.log"
adb exec-out cat /tmp/recovery.log > "%USERPROFILE%\Desktop\toco-probe-recovery.log"
echo.
echo Done. Send the file %USERPROFILE%\Desktop\toco-probe.log
pause
