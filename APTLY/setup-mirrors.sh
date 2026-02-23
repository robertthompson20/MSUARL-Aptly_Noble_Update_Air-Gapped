#!/usr/bin/env bash
################################################################################
# Name: setup-mirrors.sh
# Version: 1.0
# Usage: sudo ./setup-mirrors.sh
# Created by: Robert Thompson
# Date: February 2026
#
# Description:
#   One-time setup script to create all aptly mirrors required by:
#   - ubuntu-security-monthly.sh (security mirrors)
#   - snapshot-archive-semiannual.sh (ubuntu + ubuntu-updates mirrors)
#
# This script creates 12 mirrors:
#   Ubuntu Archive (8 mirrors):
#     - Ubuntu-Noble-Main, Ubuntu-Noble-Restricted,
#       Ubuntu-Noble-Universe, Ubuntu-Noble-Multiverse
#     - Ubuntu-Noble-Updates-Main, Ubuntu-Noble-Updates-Restricted,
#       Ubuntu-Noble-Updates-Universe, Ubuntu-Noble-Updates-Multiverse
#
#   Ubuntu Security (4 mirrors):
#     - ubuntu-noble-security-main, ubuntu-noble-security-restricted,
#       ubuntu-noble-security-universe, ubuntu-noble-security-multiverse
#
# Requirements:
#   - aptly installed
#   - /etc/aptly/aptly.conf configured
#   - Internet connection to Ubuntu repositories
#   - Run with sudo (for creating mirrors)
#
# Note:
#   This script only CREATES the mirrors, it does not download packages.
#   After creating mirrors, run ubuntu-security-monthly.sh or
#   snapshot-archive-semiannual.sh to update and populate them.
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

APTLY_BIN=(aptly -config=/etc/aptly/aptly.conf)

echo "========================================================================"
echo "  Ubuntu Noble Aptly Mirrors Setup Script"
echo "========================================================================"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Check if aptly is installed
if ! command -v aptly &> /dev/null; then
    echo -e "${RED}ERROR: aptly is not installed${NC}"
    echo "Install it with: sudo apt-get install aptly"
    exit 1
fi

# Check if aptly.conf exists
if [[ ! -f /etc/aptly/aptly.conf ]]; then
    echo -e "${RED}ERROR: /etc/aptly/aptly.conf not found${NC}"
    echo "Please create and configure aptly.conf first"
    exit 1
fi

echo -e "${BLUE}Checking for existing mirrors...${NC}"
echo ""

# Function to create a mirror if it doesn't exist
create_mirror_if_needed() {
    local mirror_name="$1"
    local repo_url="$2"
    local distribution="$3"
    local component="$4"
    
    if "${APTLY_BIN[@]}" mirror show "$mirror_name" &>/dev/null; then
        echo -e "${YELLOW}  ⊙ Mirror already exists: ${mirror_name}${NC}"
        return 0
    fi
    
    echo -e "${BLUE}  + Creating mirror: ${mirror_name}${NC}"
    if "${APTLY_BIN[@]}" mirror create \
        --architectures=amd64 \
        --ignore-signatures \
        "$mirror_name" \
        "$repo_url" \
        "$distribution" \
        "$component" </dev/null; then
        echo -e "${GREEN}  ✓ Created: ${mirror_name}${NC}"
    else
        echo -e "${RED}  ✗ Failed to create: ${mirror_name}${NC}"
        return 1
    fi
}

# Track success/failure
CREATED=0
ALREADY_EXISTS=0
FAILED=0

echo "========================================================================"
echo "  Creating Ubuntu Archive Mirrors (for snapshot-archive-semiannual.sh)"
echo "========================================================================"
echo ""

# Ubuntu Noble Base mirrors (capitalized names for semiannual script)
COMPONENTS=("Main" "Restricted" "Universe" "Multiverse")
ARCHIVE_URL="http://archive.ubuntu.com/ubuntu"

for comp in "${COMPONENTS[@]}"; do
    mirror_name="Ubuntu-Noble-${comp}"
    component_lower=$(echo "$comp" | tr '[:upper:]' '[:lower:]')
    
    if create_mirror_if_needed "$mirror_name" "$ARCHIVE_URL" "noble" "$component_lower"; then
        if "${APTLY_BIN[@]}" mirror show "$mirror_name" &>/dev/null; then
            pkg_count=$("${APTLY_BIN[@]}" mirror show "$mirror_name" 2>/dev/null | grep 'Number of packages' | awk '{print $4}' || echo 0)
            if [[ "$pkg_count" -eq 0 ]]; then
                ((CREATED++))
            else
                ((ALREADY_EXISTS++))
            fi
        fi
    else
        ((FAILED++))
    fi
done

echo ""

# Ubuntu Noble Updates mirrors
for comp in "${COMPONENTS[@]}"; do
    mirror_name="Ubuntu-Noble-Updates-${comp}"
    component_lower=$(echo "$comp" | tr '[:upper:]' '[:lower:]')
    
    if create_mirror_if_needed "$mirror_name" "$ARCHIVE_URL" "noble-updates" "$component_lower"; then
        if "${APTLY_BIN[@]}" mirror show "$mirror_name" &>/dev/null; then
            pkg_count=$("${APTLY_BIN[@]}" mirror show "$mirror_name" 2>/dev/null | grep 'Number of packages' | awk '{print $4}' || echo 0)
            if [[ "$pkg_count" -eq 0 ]]; then
                ((CREATED++))
            else
                ((ALREADY_EXISTS++))
            fi
        fi
    else
        ((FAILED++))
    fi
done

echo ""
echo "========================================================================"
echo "  Creating Ubuntu Security Mirrors (for ubuntu-security-monthly.sh)"
echo "========================================================================"
echo ""

# Ubuntu Noble Security mirrors (lowercase names for security script)
SECURITY_COMPONENTS=("main" "restricted" "universe" "multiverse")
SECURITY_URL="http://security.ubuntu.com/ubuntu"

for comp in "${SECURITY_COMPONENTS[@]}"; do
    mirror_name="ubuntu-noble-security-${comp}"
    
    if create_mirror_if_needed "$mirror_name" "$SECURITY_URL" "noble-security" "$comp"; then
        if "${APTLY_BIN[@]}" mirror show "$mirror_name" &>/dev/null; then
            pkg_count=$("${APTLY_BIN[@]}" mirror show "$mirror_name" 2>/dev/null | grep 'Number of packages' | awk '{print $4}' || echo 0)
            if [[ "$pkg_count" -eq 0 ]]; then
                ((CREATED++))
            else
                ((ALREADY_EXISTS++))
            fi
        fi
    else
        ((FAILED++))
    fi
done

echo ""
echo "========================================================================"
echo "  Setup Summary"
echo "========================================================================"
echo -e "${GREEN}  Mirrors created:        ${CREATED}${NC}"
echo -e "${YELLOW}  Mirrors already exist:  ${ALREADY_EXISTS}${NC}"
if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}  Mirrors failed:         ${FAILED}${NC}"
fi
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}WARNING: Some mirrors failed to create. Check the errors above.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All mirrors are ready!${NC}"
echo ""
echo "Next Steps:"
echo "  1. Mount external drive to /mnt/PSTPatches"
echo "  2. Run: sudo ./ubuntu-security-monthly.sh"
echo "  3. Run: sudo ./snapshot-archive-semiannual.sh"
echo ""
echo "Note: Initial mirror updates will download packages and may take"
echo "      several hours depending on your connection speed."
echo ""
