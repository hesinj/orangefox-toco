#!/bin/sh
# Keep the copies of shared files identical to their single source (see SHARED.txt).
#   ./sync_shared.sh           copy every source over its copies (modes are preserved)
#   ./sync_shared.sh --check   only compare; prints each difference, exit status 1 when any
cd "$(dirname "$0")" || exit 2
mode=copy; [ "$1" = "--check" ] && mode=check
bad=0; n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  src="${line%% ->*}"; dsts="${line#*-> }"
  [ -f "$src" ] || { echo "missing source: $src"; bad=$((bad+1)); continue; }
  for d in $dsts; do
    n=$((n+1))
    if cmp -s "$src" "$d"; then continue; fi
    if [ "$mode" = check ]; then echo "differs: $d  (source $src)"; bad=$((bad+1))
    else mkdir -p "$(dirname "$d")" && cp -p "$src" "$d" && echo "updated: $d"; fi
  done
done < SHARED.txt
if [ "$mode" = check ]; then
  [ "$bad" = 0 ] && echo "shared files: $n copies, all identical to their sources" || echo "shared files: $bad problem(s); run ./sync_shared.sh"
  [ "$bad" = 0 ]
else
  [ "$bad" = 0 ]
fi
