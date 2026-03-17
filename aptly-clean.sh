#!/usr/bin/env bash
set -euo pipefail

CONFIG="${APTLY_CONFIG:-/etc/aptly/aptly.conf}"

echo "=== Dropping published repositories ==="

for DIST in noble noble-updates noble-security; do
    if aptly -config="$CONFIG" publish list 2>/dev/null | grep -q "$DIST"; then
        echo "Dropping publish: $DIST"
        aptly -config="$CONFIG" publish drop -force-drop "$DIST" ubuntu
    else
        echo "Publish for $DIST not found"
    fi
done

echo
echo "=== Dropping snapshots ==="

for SNAP in $(aptly -config="$CONFIG" snapshot list | awk -F'[][]' '/\[ubuntu-noble/ {print $2}'); do
    echo "Dropping snapshot: $SNAP"
    aptly -config="$CONFIG" snapshot drop -force "$SNAP"
done

echo "Cleanup complete."
