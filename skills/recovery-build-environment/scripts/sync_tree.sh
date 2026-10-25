#!/bin/bash
# Copy the device tree of the repository into the OrangeFox build tree. The build uses <fox>/device/<oem>/<device>, which is a SEPARATE COPY:
# edits made in the repository do nothing until they are synced. Never run this during a build.
#   usage: sync_tree.sh REPO_DIR OEM DEVICE        (FOX = OrangeFox tree, default ~/fox_12.1)
# Files that belong to the repository but not to the tree build are left out (docs, tools, scripts, kernel recipes, patches, skills, notes).
REPO="${1:?repo dir}"; OEM="${2:?oem}"; DEV="${3:?device}"
FOX="${FOX:-$HOME/fox_12.1}"
T="$FOX/device/$OEM/$DEV"
mkdir -p "$T"
rsync -a --delete --exclude=.git --exclude=docs --exclude=tools --exclude=scripts --exclude=kernel --exclude=skills \
      --exclude='README*' --exclude='NOTICE*' --exclude=.gitignore --exclude=.gitattributes --exclude=patches --exclude=prebuilt-debug \
      "$REPO"/ "$T"/ || exit 1
echo "synced $REPO -> $T. Differences left (should only be the excluded items):"
diff -rq "$T" "$REPO" 2>&1 | grep -v -E "Only in $REPO: (\.git|docs|tools|scripts|kernel|skills|README.*|NOTICE.*|\.gitignore|\.gitattributes|patches|prebuilt-debug)" | head
