#!/usr/bin/env bash
#
# toco-capture.sh - boot a recovery image with fastboot and record what the phone reports.
#
#   usage:  ./toco-capture.sh /path/to/recovery.img [seconds-to-watch]
#
# Why: when "fastboot boot" shows the logo and then falls back to the installed ROM, nothing says
# why. adbd comes up very early in this recovery, so this script polls the phone over adb while it
# boots and keeps the most complete copy of: the kernel log (dmesg), OrangeFox's own log
# (/tmp/recovery.log), properties, the process list and the kernel's saved log of the PREVIOUS
# boot (/sys/fs/pstore). Whatever was captured before the phone vanished is kept.
#
# It only READS from the phone. It writes nothing to it except the usual `fastboot boot`.
# Works with the macOS system bash (3.2) and with Linux. Needs adb and fastboot in PATH.
#
set -u

IMG="${1:-}"
WATCH="${2:-120}"

if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
  echo "usage: $0 /path/to/recovery.img [seconds-to-watch]" >&2
  exit 2
fi
for tool in adb fastboot; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found in PATH" >&2; exit 2; }
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${TOCO_LOG_DIR:-$HOME/toco-logs}/$STAMP"
mkdir -p "$OUT" || exit 1
CONTACT="$OUT/contact.log"
: > "$CONTACT"

say() { printf '%s\n' "$*"; }
now() { date +%s; }

# run_to SECONDS OUTFILE CMD...  - run CMD with a time limit (macOS has no `timeout`) and keep its
# output only if it is at least as complete as what is already stored in OUTFILE.
# Returns 124 (and notes it in contact.log) when CMD had to be killed, i.e. the phone stopped answering.
run_to() {
  local limit="$1" file="$2" rc=0
  shift 2
  "$@" > "$file.new" 2>/dev/null &
  local pid=$! ticks=0 max=$((limit * 5))
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    ticks=$((ticks + 1))
    if [ "$ticks" -ge "$max" ]; then
      kill "$pid" 2>/dev/null
      echo "$(now) timeout: $(basename "$file")" >> "$CONTACT"
      rc=124
      break
    fi
  done
  wait "$pid" 2>/dev/null
  if [ -s "$file.new" ]; then
    if [ ! -s "$file" ] || [ "$(wc -c < "$file.new" | tr -d ' ')" -ge "$(wc -c < "$file" | tr -d ' ')" ]; then
      mv "$file.new" "$file"
    else
      rm -f "$file.new"
    fi
  else
    rm -f "$file.new"
  fi
  return "$rc"
}

say "== toco-capture: logs go to $OUT"
{
  echo "date: $(date)"
  echo "host: $(uname -a)"
  echo "image: $IMG ($(wc -c < "$IMG") bytes)"
  adb version 2>&1 | head -2
  fastboot --version 2>&1 | head -1
} > "$OUT/host.txt"

# the phone must be in fastboot mode
if ! fastboot devices 2>/dev/null | grep -q .; then
  say "No device in fastboot mode. Put the phone in fastboot (power off, then hold Volume-down +"
  say "Power, or run:  adb reboot bootloader ) and run this again."
  exit 1
fi
fastboot getvar all > "$OUT/fastboot-getvar.txt" 2>&1

adb start-server >/dev/null 2>&1

# ---- background collector ---------------------------------------------------------------------
collector() {
  local was_up=0
  while :; do
    run_to 3 "$OUT/ping.txt" adb shell echo up
    if grep -q '^up' "$OUT/ping.txt" 2>/dev/null; then
      rm -f "$OUT/ping.txt"
      if [ "$was_up" -eq 0 ]; then echo "$(now) adb reachable" >> "$CONTACT"; was_up=1; fi
      # most valuable first; give up on the cycle at the first command that hangs
      run_to 8 "$OUT/recovery.log" adb shell cat /tmp/recovery.log &&
      run_to 8 "$OUT/fox-decrypt-diag.log" adb shell cat /tmp/fox-decrypt-diag.log &&
      run_to 4 "$OUT/sysrq.txt"    adb shell 'echo w > /proc/sysrq-trigger; echo l > /proc/sysrq-trigger; echo ok' &&
      run_to 8 "$OUT/dmesg.txt"    adb shell dmesg &&
      run_to 8 "$OUT/ps-wchan.txt" adb shell 'ps -A -o PID,PPID,STAT,WCHAN,NAME' &&
      run_to 12 "$OUT/stacks.txt"  adb shell 'grep -H . /proc/[0-9]*/task/*/stack 2>/dev/null' &&
      run_to 8 "$OUT/version.txt"  adb shell cat /proc/version &&
      run_to 8 "$OUT/pstore.txt"   adb shell 'ls -la /sys/fs/pstore; for f in /sys/fs/pstore/*; do echo "=== $f"; cat "$f"; done' &&
      run_to 8 "$OUT/getprop.txt"  adb shell getprop &&
      run_to 8 "$OUT/ps.txt"       adb shell ps -A &&
      run_to 8 "$OUT/logcat.txt"   adb logcat -d -b all -v threadtime &&
      run_to 8 "$OUT/devnodes.txt" adb shell 'ls -l /dev/block/bootdevice/by-name/ /dev/sg* /dev/qseecom /dev/ion /dev/binderfs /vendor/firmware_mnt/image 2>&1' &&
      echo "$(now) snapshot" >> "$CONTACT"
    else
      rm -f "$OUT/ping.txt"
      if [ "$was_up" -eq 1 ]; then echo "$(now) adb lost" >> "$CONTACT"; was_up=0; fi
    fi
    sleep 0.3
  done
}
collector &
COLLECTOR=$!
trap 'kill "$COLLECTOR" 2>/dev/null' EXIT INT TERM

# ---- boot --------------------------------------------------------------------------------------
T0="$(now)"
echo "$T0 fastboot boot" >> "$CONTACT"
say "== fastboot boot $IMG"
fastboot boot "$IMG" 2>&1 | tee "$OUT/fastboot-boot.txt"
say "== watching for $WATCH seconds. Look at the phone and note what it does."

i=0
while [ "$i" -lt "$WATCH" ]; do
  sleep 5
  i=$((i + 5))
  last="$(grep -E ' (snapshot|adb reachable)$' "$CONTACT" 2>/dev/null | tail -1 | cut -d' ' -f1)"
  if [ -z "$last" ]; then
    state="adb not up yet"
  else
    ago=$(( $(now) - last ))
    if [ "$ago" -le 6 ]; then state="adb answering"; else state="adb silent for ${ago}s"; fi
  fi
  printf '   t+%3ss  %s\n' "$i" "$state"
done

kill "$COLLECTOR" 2>/dev/null
wait "$COLLECTOR" 2>/dev/null
trap - EXIT INT TERM

# ---- what did the user see? --------------------------------------------------------------------
SEEN="not answered"
if [ -t 0 ]; then
  say ""
  say "What did the PHONE do? Type a number and press Enter:"
  say "  1  OrangeFox menu appeared and stayed"
  say "  2  froze on the OrangeFox logo (nothing moves, had to hold the power button)"
  say "  3  logo, then it restarted into PixelOS (the normal system, lock screen / boot animation)"
  say "  4  logo, then it restarted into the PixelOS recovery menu"
  say "  5  logo, then it went to the fastboot screen"
  say "  6  the logo kept flashing / restarting again and again"
  say "  7  black screen"
  say "  8  something else"
  printf '> '
  read -r choice
  case "$choice" in
    1) SEEN="OrangeFox menu appeared and stayed" ;;
    2) SEEN="froze on the OrangeFox logo" ;;
    3) SEEN="logo, then restarted into PixelOS system" ;;
    4) SEEN="logo, then restarted into PixelOS recovery" ;;
    5) SEEN="logo, then fastboot screen" ;;
    6) SEEN="logo kept flashing / restarting" ;;
    7) SEEN="black screen" ;;
    8) printf 'describe it: '; read -r SEEN ;;
    *) SEEN="answer '$choice'" ;;
  esac
fi

# ---- summary -----------------------------------------------------------------------------------
{
  echo "=== toco-capture summary ($STAMP) ==="
  echo "phone behaviour : $SEEN"
  echo "image           : $(basename "$IMG")  sha256 $( (shasum -a 256 "$IMG" 2>/dev/null || sha256sum "$IMG") | cut -d' ' -f1 )"
  echo
  echo "--- timeline (epoch seconds, relative to fastboot boot at t=0) ---"
  while read -r ts ev; do
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    printf 't+%ss  %s\n' "$((ts - T0))" "$ev"
  done < "$CONTACT"
  echo
  echo "--- files captured ---"
  ls -l "$OUT" | sed 's/^/  /'
  echo
  echo "--- last 60 lines of /tmp/recovery.log ---"
  [ -s "$OUT/recovery.log" ] && tail -60 "$OUT/recovery.log" || echo "(none captured - adb never came up or the phone vanished first)"
  echo
  echo "--- kernel memory errors, oopses and panics (live log and pstore) ---"
  grep -i -E 'KASAN|BUG kmalloc|BUG kmem_cache|Poison overwritten|Redzone overwritten|Freepointer corrupt|Object already free|list_add corruption|list_del corruption|Unable to handle kernel|Kernel panic|Internal error' \
      "$OUT/dmesg.txt" "$OUT/pstore.txt" 2>/dev/null | head -40 || true
  echo
  echo "--- last 60 lines of dmesg ---"
  [ -s "$OUT/dmesg.txt" ] && tail -60 "$OUT/dmesg.txt" || echo "(none captured)"
  echo
  echo "--- pstore (the kernel's saved log of the boot BEFORE this one) ---"
  if [ -s "$OUT/pstore.txt" ]; then head -c 6000 "$OUT/pstore.txt"; else echo "(none captured)"; fi
} > "$OUT/SUMMARY.txt"

( cd "$OUT/.." && tar czf "$STAMP.tgz" "$STAMP" ) 2>/dev/null

say ""
say "== done."
say "   Folder : $OUT"
say "   Archive: $OUT.tgz"
say "   Please paste the contents of  $OUT/SUMMARY.txt  (or send the .tgz)."
