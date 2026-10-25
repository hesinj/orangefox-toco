# Reading the diagnosis archive (`android-diag-*.tgz`)

`android-boot-diagnose.sh` (v2) runs in the recovery with `/data` open and only reads. The archive holds numbered text files and a `files/` folder of raw copies. Unpack it into its own new folder and read in this order.

## Contents
1. Reading order
2. File by file
3. Time: three clocks
4. Questions the bundle answers
5. What it cannot answer

## 1. Reading order
`01-summary` (what phone, what kernel, space) -> `04-metadata` (boot reason) -> `13-pstore` (kernel console before this recovery) -> `05b-changed-since-shutdown` (did the failing boots write anything?) -> `03-cache-recovery` -> `07-root-and-modules` -> `06-crashes` -> `11/12` (partitions and the installed ROM) -> the rest.

## 2. File by file
| file | holds | read it for |
|---|---|---|
| `01-summary.txt` | time, kernel, command line, mounts, free space and inodes of `/data` | a full `/data` or full inodes (classic reason for no boot); which recovery/kernel collected this |
| `02-misc-bcb.txt`, `files/misc-bcb.bin` | the first 2048 bytes of `misc` (the bootloader control block) | a leftover command (`boot-recovery`, `--wipe_data`, `--update_package`) that sends the phone to recovery at every start; empty = no command. A `--wipe_data` in `recovery` must be understood before the phone boots into stock recovery |
| `03-cache-recovery.txt`, `files/cache-recovery/` | listing and copies of `/cache/recovery/*` (`last_log*`, `last_kmsg*`, `last_install`, `.UPDATED`, `last_updatefile`, `last_format_data`) | what the ROM's own recovery did last and when: a block OTA applied (`.UPDATED`), a data format (`last_format_data`), the install log. Note: a `last_kmsg` here is that recovery session's console, not the failing boot's |
| `04-metadata.txt`, `files/metadata/` | `/metadata` listing; `bootstat/persist.sys.boot.reason`, `bootstat/*` | **init's last recorded reboot reason**. `bootloader,...-failed` / `reboot,...` names the service that triggered it (`bootstrap-apexd-failed`: `apexd --bootstrap` failed in early init). A boot that dies before init never updates it: compare its time with the failure time |
| `05-data-layout.txt` | listing of `/data`, `/data/system`, `/data/misc/bootstat`, APEX state, persistent boot-reason properties | missing or half-written system folders; staged APEX sessions; `last-header.txt` / `shutdown-metrics.txt` (what Android wrote at its last clean shutdown) |
| `05b-changed-since-shutdown.txt` | files under `/data` and `/metadata` newer than the last Android shutdown | **the key test**: if only recovery folders appear, the failing boots never got as far as writing to `/data`: the failure is early (kernel, init before `/data` is mounted, firmware) and the data and its app state are not the cause. If Android files appear, read their names (dropbox, tombstones, a `.new` package database) |
| `06-crashes.txt`, `files/` | dropbox, tombstones, ANRs, logd persistent logs | `system_server_crash`, `SYSTEM_RESTART`, `system_server_watchdog`, an app crash loop; names carry the time in ms since 1970 (`date -d @$((ms/1000))`) |
| `07-root-and-modules.txt` | `/data/adb` (Magisk, KernelSU, APatch, LSPosed, boot scripts), root-manager packages | the most common cause of a bootloop after a change: a module folder; the fix is a `disable` file in it, not a wipe |
| `08-packages.txt` | package database state and `/data/app` names | a half-installed package, a partial update |
| `09-sizes.txt` | sizes of the directories that can fill `/data` (user media left out) | what grew |
| `10-filesystem.txt` | kernel messages about the file systems/storage, f2fs counters | I/O errors, `fsck` messages, f2fs checkpoint/orphan/dirty counters |
| `11-boot-partitions.txt`, `files/hdr-*.bin` | vbmeta flags, headers of boot/recovery/dtbo, **all partitions with sizes**, **sha256 of whole partitions** | compare sha256 of `boot`, `dtbo`, `recovery` with the release files (`sha256sum RELEASE-boot.img` is the whole-partition hash when the release image is partition-sized). Different hash = something else is on the partition |
| `12-rom-version.txt` | `build.prop` values of the installed system/vendor/product, mounted read-only under `/tmp` | ROM build id and security patch, vendor build id; a vendor much older or newer than the system |
| `13-pstore.txt`, `files/pstore-*` | `/sys/fs/pstore` content: the console of the boot **before** this recovery | a kernel panic/oops, a watchdog bite, a hang with the last kernel line. Empty = nothing kept (full power cycle, or the previous boot never started a kernel) |
| `files/` | raw copies: misc BCB, cache/recovery, shutdown files, crash files, partition headers, pstore | feed them to `avbtool info_image`, `unpack_bootimg.py`, `slub_freelist_decode.py` |

## 3. Time: three clocks
* The recovery's clock is the **raw RTC** (on the reference phone about 55 years in the past: 1971). To convert: find a file with a known real time and compute the offset (the reference phone: real = RTC + 54 y 342 d 10 h 28 m at that moment).
* `ls -l` in OrangeFox prints local time of the recovery's timezone setting (CET/CEST on the reference phone), Android's own files carry device-local stamps (+0330 for Iran in the reference case).
* Crash files carry ms since 1970 in their names: `date -u -d @SECONDS`.
Always state the clock when you compare two times.

## 4. Questions the bundle answers
* *Did the last boots reach Android's userspace?* `05b`, `04` (reason, its time), `06` (new dropbox/tombstones).
* *Is the storage full or damaged?* `01` (df, df -i), `10` (f2fs messages, counters), `09`.
* *Is a root module or a half-applied update to blame?* `07`, `05` (APEX, staged sessions), `03` (`.UPDATED`).
* *Is the boot chain what the release ships?* `11` (hashes, vbmeta flags), `12` (ROM and vendor builds).
* *Is it the kernel?* `13` (pstore) and `recovery-boot-debugging`.

## 5. What it cannot answer
It never sees the failing boot's own log (the phone shows only the logo): pstore, `last_kmsg` of a recovery that captured it, or a passive recorder in a booted diagnostic image are the only sources. It does not read the user's media or app data (CE storage needs the password and the script avoids it on purpose).
