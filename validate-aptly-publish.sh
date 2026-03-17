#!/usr/bin/env bash
set -euo pipefail

BASE="/mnt/Ext3TB/aptly/public/ubuntu/dists"

check_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        echo "[OK] $file"
    else
        echo "[ERROR] Missing: $file"
    fi
}

echo "=== Checking published distributions ==="
echo

for DIST in noble noble-updates noble-security; do
    echo "-- Validating $DIST --"

    check_file "$BASE/$DIST/Release"
    check_file "$BASE/$DIST/main/binary-amd64/Packages.gz"

    echo
done

echo "=== Checking for universe/restricted/multiverse packages inside main ==="
echo "(If found, it confirms components were merged correctly.)"
echo

declare -a TEST_PKGS=(
    "neofetch"                 # universe
    "nvidia-driver-550"        # restricted
    "ttf-mscorefonts-installer" # multiverse
)

for pkg in "${TEST_PKGS[@]}"; do
    echo "Testing: $pkg"
    if apt-cache --no-all-versions show "$pkg" 2>/dev/null | grep -q '^Package:'; then
        echo "  [OK] present under main"
    else
        echo "  [MISSING] not found under main"
    fi
done

echo
echo "Validation complete."
