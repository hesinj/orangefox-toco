# Copying a phone's storage to Windows with adb: what fails and why

## Contents
1. The failures seen
2. What the scripts do about them
3. Fixes outside the scripts
4. Checking afterwards

## 1. The failures seen (reference phone, Windows 10/11)
| symptom | cause |
|---|---|
| `adb pull /sdcard E:\...` stops part-way and the rest of the storage is not copied | the phone has a file or folder whose **name Windows cannot create**: it contains one of the characters `? * : " < >` or a pipe sign (or a control character), ends with a dot or a space, or is a reserved device name (`CON`, `NUL`, `AUX`, `PRN`, `COM1`...). Android allows all of these. **Verified on the reference phone:** the pull of `/sdcard` stopped at an *empty directory* whose name contained `|` (a LuckyPatcher folder under `Android/data`), leaving the copy incomplete. Skipping `Android/data` and pulling folder by folder avoids it |
| a few files fewer on the PC than on the phone (2-3 of thousands) | the same names, or two files whose names differ only by case in one folder (Windows folders are case-insensitive: the second overwrites the first or fails), or a path of 260+ characters |
| file names show as `?????` or mojibake, or are rejected | a Windows console code page other than UTF-8 and a tool that goes through it; use tar with `hdrcharset=UTF-8` or `chcp 65001` |
| a tar/zip made with a pipe in **PowerShell** is corrupt | Windows PowerShell 5 pipes text, not bytes, through `|` and `>`: run these commands in `cmd.exe` (Command Prompt) |
| `adb shell ls` shows `Photo\ 1.jpg` or octal escapes | toybox `ls` escapes unusual names in its output; do not parse `ls` output, use `find` (`find ... -print0 | xargs -0 ...`) |
| carriage returns in parsed output | older adb versions, or an `adb shell` attached to a terminal, convert LF to CRLF; `adb exec-out` is a clean byte stream (no pty). Scripts use `exec-out` for anything that is parsed or piped, and the Unix script strips a trailing CR anyway |

## 2. What the scripts do about them
`pull-sdcard.bat` (and `.sh`):
* Top-level **files** go through one tar stream: `adb exec-out "cd /sdcard && find . -maxdepth 1 -type f -print0 | xargs -0 -r tar -cf -" | tar --options "hdrcharset=UTF-8,read_concatenated_archives" -xf - -C DEST`. Windows 10/11's own `tar.exe` (bsdtar) unpacks it; names with spaces and non-Latin letters survive.
* Every top-level **folder** except `Android` is pulled separately, so a folder that fails does not stop the others; a failed folder is retried **one level down** (each child on its own), which isolates the one bad name.
* `Android/media` is pulled on its own. `Android/data` and `Android/obb` are skipped.
* `chcp 65001` is set for the run and restored at the end.
* The report (`pull-report.txt`) says which parts worked, which failed, which were retried; `phone-files.txt` and `local-files.txt` allow `compare_listing.py` to explain each difference.

## 3. Fixes outside the scripts
* **Files whose names Windows cannot hold**: copy them as a tar stream into a Linux/WSL folder or a macOS machine, or onto a disk formatted ext4/exFAT-with-care (exFAT also forbids the same characters), or keep them inside a `.tar` that is never unpacked on Windows: `adb exec-out "cd /sdcard && tar -cf - 'Folder/with:colon'" > folder.tar`.
* **Long paths**: enable Windows long paths, or copy to a short destination (`E:\b`), or tar the folder.
* **Case collisions**: unpack on a case-sensitive filesystem (WSL ext4, Linux, macOS case-sensitive volume), or rename one of the two inside a tar on the PC side.
* **Huge media folders** (tens of GB): pull them separately and let the report tell what failed; do not retry the whole storage because of one folder.
* **No Windows `tar`** (old Windows 10): use `adb pull` for folders and 7-Zip for the tar of the top-level files.

## 4. Checking afterwards
`python3 -I compare_listing.py DEST/phone-files.txt DEST --root /sdcard --windows` (counts, each missing file, the reason). For a stronger check of a few important folders compare hashes on both sides:
`adb exec-out "cd /sdcard/DCIM && find . -type f -exec sha256sum {} +" > phone-hash.txt` and on the PC `certutil -hashfile file SHA256` or `Get-FileHash`, or just compare sizes with `find -printf` where available.
A copy is complete when the missing list is empty **or** each missing file has a reason and a separate plan.
