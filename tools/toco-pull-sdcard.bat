@echo off
setlocal DisableDelayedExpansion
rem toco-pull-sdcard.bat <destination folder>
rem
rem Copies the phone's internal storage (/sdcard) to the PC one top-level item at a time, so that a folder Windows cannot
rem create (a name with | ? * : " < > or ending in a dot or a space) stops only that item and not the whole copy.
rem Android\data and Android\obb (private folders of apps) are left out; Android\media (WhatsApp media and the like) is copied.
rem It only reads from the phone. The recovery must be up and /data decrypted (the phone shows "recovery" in: adb devices).
rem
rem   example:  toco-pull-sdcard.bat E:\phone-backup
rem A list of what worked and what did not is written to <destination>\pull-report.txt. If a whole top-level folder fails, its
rem contents are retried one by one, so that only the item Windows cannot store is lost.

if "%~1"=="" goto :usage
set "DEST=%~1"
if "%DEST:~-1%"=="\" if not "%DEST:~-2%"==":\" set "DEST=%DEST:~0,-1%"
if not exist "%DEST%" mkdir "%DEST%"
if not exist "%DEST%" goto :nodest
set "REPORT=%DEST%\pull-report.txt"

adb get-state >nul 2>&1
if errorlevel 1 goto :nophone

>>"%REPORT%" echo ===== %DATE% %TIME%  copy of /sdcard to %DEST%
echo Copying every top-level item of /sdcard except Android ...
for /f "usebackq delims=" %%I in (`adb exec-out ls -1A /sdcard/`) do call :one "%%I"

echo.
echo === Android\media
if not exist "%DEST%\Android" mkdir "%DEST%\Android"
adb pull "/sdcard/Android/media" "%DEST%\Android"

echo.
echo ===== done. Skipped on purpose: Android\data, Android\obb.
echo See %REPORT% for the items that failed (FAILED lines).
echo Compare the sizes with the phone: adb shell du -sh /sdcard/DCIM   and the folder's properties on the PC.
goto :eof

:one
set "N=%~1"
if /i "%N%"=="Android" goto :eof
echo.
echo === %N%
adb pull "/sdcard/%N%" "%DEST%"
if errorlevel 1 goto :bad
>>"%REPORT%" echo ok: %N%
goto :eof
:bad
>>"%REPORT%" echo FAILED as a whole, retrying its contents one by one: %N%
echo FAILED: %N%  - retrying its contents one by one ...
if not exist "%DEST%\%N%" mkdir "%DEST%\%N%"
for /f "usebackq delims=" %%C in (`adb exec-out ls -1A "/sdcard/%N%/"`) do call :child "%N%" "%%C"
goto :eof

:child
set "P=%~1"
set "C=%~2"
adb pull "/sdcard/%P%/%C%" "%DEST%\%P%"
if errorlevel 1 >>"%REPORT%" echo   FAILED: %P%/%C%
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
