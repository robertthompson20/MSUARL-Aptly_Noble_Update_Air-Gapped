#!/bin/bash

SRC="/mnt/Ext3TB/aptly/public/"
DST="/mnt/PSTPatches/public/"

# Reliable mount check
if ! df "$SRC" >/dev/null 2>&1 || ! df "$DST" >/dev/null 2>&1; then
    echo "Error: Source or destination not accessible (check mounts with 'df /mnt')."
    exit 1
fi

echo "Mounts confirmed. Contents:"
du -sh "$SRC" "$DST" 2>/dev/null || echo "One dir empty/missing aptly/public."

#echo -e "\n=== DRY RUN ==="
#rsync -avh --dry-run --info=progress2,stats2 "$SRC" "$DST"

echo -e "\n=== LIVE SYNC (remove --dry-run when ready) ==="
rsync -avh --partial --info=progress2,stats2 --delete "$SRC" "$DST"

echo "Sync done."
