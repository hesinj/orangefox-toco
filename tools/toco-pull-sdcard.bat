@echo off
setlocal DisableDelayedExpansion
rem toco-pull-sdcard.bat <destination folder>          (run it in a Command Prompt, not in PowerShell)
rem
rem Copies the phone's internal storage (/sdcard) to the PC:
rem   1. the top-level FILES in one tar stream (names with spaces or non-Latin letters survive; Windows' own tar.exe unpacks it),
rem   2. every top-level FOLDER except Android with its own "adb pull", so that a folder Windows cannot create (a name with
rem      | ? * : " < > or ending in a dot or a space) stops only that folder; a folder that fails is retried one level down,
rem   3. Android\media (WhatsApp media and the like). Android\data and Android\obb (private folders of apps) are left out.
rem It only reads from the phone. The recovery must be up and /data decrypted ("recovery" in: adb devices).
rem
rem   example:  toco-pull-sdcard.bat E:\phone-backup
rem What worked and what did not is written to <destination>\pull-report.txt

if "%~1"=="" goto :usage
set "DEST=%~1"
if "%DEST:~-1%"=="\" if not "%DEST:~-2%"==":\" set "DEST=%DEST:~0,-1%"
if not exist "%DEST%" mkdir "%DEST%"
if not exist "%DEST%" goto :nodest
set "REPORT=%DEST%\pull-report.txt"

adb get-state >nul 2>&1
if errorlevel 1 goto :nophone

rem UTF-8 for this run, so that names with non-Latin letters pass through this script unharmed (restored at the end)
set "OLDCP=437"
for /f "tokens=2 delims=:" %%P in ('chcp') do set "OLDCP=%%P"
set "OLDCP=%OLDCP: =%"
chcp 65001 >nul

>>"%REPORT%" echo ===== %DATE% %TIME%  copy of /sdcard to %DEST%

echo.
echo === top-level files (one tar stream)
adb exec-out "cd /sdcard && find . -maxdepth 1 -type f -print0 | xargs -0 -r tar -cf -" | tar --options "hdrcharset=UTF-8,read_concatenated_archives" -xf - -C "%DEST%"
if errorlevel 1 goto :filesbad
>>"%REPORT%" echo ok: top-level files
goto :folders
:filesbad
>>"%REPORT%" echo FAILED: top-level files, see the messages on the screen
echo FAILED: top-level files. If tar complains about --options, delete that part of the command in this script.

:folders
echo.
echo === top-level folders except Android
for /f "usebackq delims=" %%I in (`adb exec-out find /sdcard/ -maxdepth 1 -mindepth 1 -type d`) do call :one "%%I"

echo.
echo === Android\media
if not exist "%DEST%\Android" mkdir "%DEST%\Android"
adb pull "/sdcard/Android/media" "%DEST%\Android"
if errorlevel 1 goto :mediabad
>>"%REPORT%" echo ok: Android/media
goto :counts
:mediabad
>>"%REPORT%" echo FAILED or missing: Android/media
echo Android\media: FAILED or not present on the phone.

:counts
echo.
set "DEVN=?"
set "LOCN=?"
for /f "usebackq delims=" %%C in (`adb exec-out "find /sdcard/ -type f ! -path '/sdcard/Android/data/*' ! -path '/sdcard/Android/obb/*' | wc -l"`) do set "DEVN=%%C"
for /f %%C in ('dir /s /b /a-d "%DEST%" ^| find /c /v ""') do set "LOCN=%%C"
echo ===== done. Skipped on purpose: Android\data, Android\obb.
echo Files on the phone (without those two): %DEVN%
echo Files in %DEST%: %LOCN%  (this includes pull-report.txt, so one more than the phone is normal)
echo A smaller number here than on the phone means files that Windows could not store or that failed: see %REPORT%
chcp %OLDCP% >nul
goto :eof

:one
set "R=%~1"
set "R=%R://=/%"
if /i "%R%"=="/sdcard/Android" goto :eof
echo.
echo === "%R%"
adb pull "%R%" "%DEST%"
if errorlevel 1 goto :bad
>>"%REPORT%" echo ok: "%R%"
goto :eof
:bad
>>"%REPORT%" echo FAILED as a whole, retrying its contents one by one: "%R%"
echo FAILED: "%R%" - retrying its contents one by one ...
for %%A in ("%R:/=\%") do set "N=%%~nxA"
if not exist "%DEST%\%N%" mkdir "%DEST%\%N%"
for /f "usebackq delims=" %%C in (`adb exec-out find "'%R%'" -maxdepth 1 -mindepth 1`) do call :child "%%C" "%N%"
goto :eof

:child
set "C=%~1"
set "P=%~2"
adb pull "%C%" "%DEST%\%P%"
if errorlevel 1 >>"%REPORT%" echo   FAILED: "%C%"
goto :eof

:usage
echo usage: %~nx0 destination-folder      (for example: %~nx0 E:\phone-backup)
exit /b 1
:nodest
echo cannot create the destination folder "%DEST%"
exit /b 1
:nophone
echo no phone found by adb. Boot the recovery, wait for the password screen / menu, check "adb devices".
exit /b 1
