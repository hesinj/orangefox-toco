@echo off
rem toco-probe.bat - run toco-probe.sh on the phone. The -nocrypt OrangeFox must be running on the phone.
rem Put this file and toco-probe.sh in the same folder as adb.exe (or anywhere, with adb in PATH).
rem If the phone freezes or restarts while it runs, copy the last lines shown in this window.

setlocal EnableExtensions

where adb >nul 2>nul
if errorlevel 1 (
  echo adb was not found in PATH. Put this file next to adb.exe and run it again.
  pause
  exit /b 1
)
if not exist "%~dp0toco-probe.sh" (
  echo toco-probe.sh must be in the same folder as this file.
  pause
  exit /b 1
)

adb push "%~dp0toco-probe.sh" /tmp/toco-probe.sh
if errorlevel 1 (
  echo Could not reach the phone over adb.
  pause
  exit /b 1
)
echo.
echo Running the probe. This takes about 30 seconds.
echo.
adb shell sh /tmp/toco-probe.sh
echo.
adb pull /tmp/toco-probe.log "%USERPROFILE%\Desktop\toco-probe.log"
adb exec-out cat /tmp/recovery.log > "%USERPROFILE%\Desktop\toco-probe-recovery.log"
echo.
echo Done. Send the file %USERPROFILE%\Desktop\toco-probe.log
pause
