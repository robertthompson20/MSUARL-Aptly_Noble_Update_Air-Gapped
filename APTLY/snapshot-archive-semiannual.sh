#!/usr/bin/env bash
################################################################################
# Name: snapshot-archive-semiannual.sh
# Version: 2.0
# Usage: ./snapshot-archive-semiannual.sh
# Created by: Robert Thompson
# Date: February 2026
#
# Description:
#   Creates semiannual archive snapshots (H1/H2) from Ubuntu Noble mirrors,
#   excludes cloud-specific packages, and publishes to external filesystem
#   endpoint for air-gapped deployment. Processes each component separately
#   to maintain proper multi-component repository structure.
#
# Features:
#   - Automatic semiannual tagging (YYYYH1 for Jan-Jun, YYYYH2 for Jul-Dec)
#   - Smart mirror update caching (skips updates within 24 hours)
#   - Cloud package filtering (AWS, Azure, GCP, Oracle, IBM, etc.)
#   - Component-based processing (main, universe, multiverse, restricted)
#   - Merges noble + noble-updates separately for each component
#   - Multi-component publish with proper directory structure
#   - Direct publish to external drive at /mnt/PSTPatches/apt-mirror/ubuntu
#
# Requirements:
#   - aptly with /etc/aptly/aptly.conf configured
#   - FileSystemPublishEndpoints: ubuntu configured in aptly.conf
#   - External drive mounted at /mnt/PSTPatches/apt-mirror
#   - Sufficient disk space for snapshot creation and publishing
#
# Output:
#   Published repository at /mnt/PSTPatches/apt-mirror/ubuntu/
#   Snapshot name format: noble-archive-YYYYH1-{component}
#   Example: noble-archive-2026H1-main, noble-archive-2026H1-universe, etc.
################################################################################
set -euo pipefail

APTLY_BIN=(aptly -config=/etc/aptly/aptly.conf)

# Publish root on removable media / air-gap staging (matches aptly.conf)
PUBLISH_ROOT="/mnt/PSTPatches/apt-mirror/ubuntu"
PUBLISH_PREFIX=""                        # <-- no prefix, publishes at root
PUBLISH_DISTRIBUTION="noble"
COMPONENTS="main,universe,multiverse,restricted"

# Ensure target directory exists
mkdir -p "${PUBLISH_ROOT}"

DIST="noble"

# Component structure: noble + noble-updates per component
COMPONENTS_LIST=("main" "universe" "multiverse" "restricted")

# Filter excluding cloud-specific packages
EXCLUDE_CLOUD_FILTER='!(Name (~ "azure|aws|amazon|ec2|gcp|google|oci|oracle|cloud-|cloudinit|cloud-init|cloud-utils|walinuxagent|google-compute-engine|oem-cloud|oem-|ubuntu-advantage|ubuntu-pro|ua-tools|pro-apt|pro-client|linux-oracle|linux-gcp|linux-aws|linux-azure|raspi|raspberrypi"))'

# Semiannual tag: YYYYH1 / YYYYH2
MONTH="$(date +%m)"; YEAR="$(date +%Y)"
if [[ "${MONTH#0}" -le 6 ]]; then HALF="H1"; else HALF="H2"; fi
TAG="${YEAR}${HALF}"

echo "[INFO] Creating archive snapshots for: ${TAG}"

# Track mirror update timestamps to avoid redundant updates
MIRROR_TIMESTAMP_DIR="/var/cache/aptly-mirror-timestamps"
mkdir -p "${MIRROR_TIMESTAMP_DIR}"

# Function to update a mirror if needed
update_mirror_if_needed() {
  local mirror_name="$1"
  TIMESTAMP_FILE="${MIRROR_TIMESTAMP_DIR}/${mirror_name}.timestamp"
  NOW=$(date +%s)
  LAST_UPDATE=0

  if [[ -f "${TIMESTAMP_FILE}" ]]; then
    LAST_UPDATE=$(stat -c %Y "${TIMESTAMP_FILE}" 2>/dev/null || echo 0)
  fi

  HOURS_SINCE_UPDATE=$(( ($NOW - $LAST_UPDATE) / 3600 ))

  if [[ $LAST_UPDATE -eq 0 ]] || [[ $HOURS_SINCE_UPDATE -ge 24 ]]; then
    echo "[INFO] Updating mirror: $mirror_name (last updated: $HOURS_SINCE_UPDATE hours ago)"
    "${APTLY_BIN[@]}" mirror update "$mirror_name" && touch "${TIMESTAMP_FILE}"
  else
    echo "[INFO] Skipping mirror update: $mirror_name (updated $HOURS_SINCE_UPDATE hours ago, within 24h window)"
  fi
}

# Arrays to hold final component snapshots
COMPONENT_SNAPSHOTS=()

# Process each component separately
for comp in "${COMPONENTS_LIST[@]}"; do
  # Capitalize first letter for mirror name
  COMP_CAP="$(tr '[:lower:]' '[:upper:]' <<< ${comp:0:1})${comp:1}"

  BASE_MIRROR="Ubuntu-Noble-${COMP_CAP}"
  UPDATES_MIRROR="Ubuntu-Noble-Updates-${COMP_CAP}"

  FINAL_SNAP="${DIST}-archive-${TAG}-${comp}"

  echo "[INFO] Processing component: ${comp}"

  # Update mirrors for this component
  update_mirror_if_needed "${BASE_MIRROR}"
  update_mirror_if_needed "${UPDATES_MIRROR}"

  # Check if final snapshot already exists
  if "${APTLY_BIN[@]}" snapshot show "${FINAL_SNAP}" >/dev/null 2>&1; then
    echo "[INFO] Snapshot exists, skipping create: ${FINAL_SNAP}"
  else
    # Create temporary snapshots
    BASE_TEMP="${FINAL_SNAP}-base-temp"
    UPDATES_TEMP="${FINAL_SNAP}-updates-temp"
    BASE_FILTERED="${FINAL_SNAP}-base-filtered"
    UPDATES_FILTERED="${FINAL_SNAP}-updates-filtered"

    # Clean up any leftover snapshots
    "${APTLY_BIN[@]}" snapshot drop "${BASE_TEMP}" 2>/dev/null || true
    "${APTLY_BIN[@]}" snapshot drop "${UPDATES_TEMP}" 2>/dev/null || true
    "${APTLY_BIN[@]}" snapshot drop "${BASE_FILTERED}" 2>/dev/null || true
    "${APTLY_BIN[@]}" snapshot drop "${UPDATES_FILTERED}" 2>/dev/null || true

    # Create and filter base snapshot
    echo "[INFO] Creating snapshot from ${BASE_MIRROR}"
    "${APTLY_BIN[@]}" snapshot create "${BASE_TEMP}" from mirror "${BASE_MIRROR}"
    echo "[INFO] Filtering ${BASE_TEMP}"
    "${APTLY_BIN[@]}" snapshot filter "${BASE_TEMP}" "${BASE_FILTERED}" \
      "${EXCLUDE_CLOUD_FILTER}" -with-deps

    # Create and filter updates snapshot
    echo "[INFO] Creating snapshot from ${UPDATES_MIRROR}"
    "${APTLY_BIN[@]}" snapshot create "${UPDATES_TEMP}" from mirror "${UPDATES_MIRROR}"
    echo "[INFO] Filtering ${UPDATES_TEMP}"
    "${APTLY_BIN[@]}" snapshot filter "${UPDATES_TEMP}" "${UPDATES_FILTERED}" \
      "${EXCLUDE_CLOUD_FILTER}" -with-deps

    # Merge base + updates for this component
    echo "[INFO] Merging into final snapshot: ${FINAL_SNAP}"
    "${APTLY_BIN[@]}" snapshot merge "${FINAL_SNAP}" "${BASE_FILTERED}" "${UPDATES_FILTERED}"
  fi

  COMPONENT_SNAPSHOTS+=("${FINAL_SNAP}")
done

echo "[INFO] Publishing multi-component repository to root path"

# Use . for root prefix when PUBLISH_PREFIX is empty
APTLY_PREFIX="${PUBLISH_PREFIX:-.}"

# Check if already published
if "${APTLY_BIN[@]}" publish list 2>/dev/null | grep -q "filesystem:ubuntu:${APTLY_PREFIX}"; then
  echo "[INFO] Existing publish found; switching to new snapshots"
  "${APTLY_BIN[@]}" publish switch \
    -component="${COMPONENTS}" \
    -skip-signing \
    "${PUBLISH_DISTRIBUTION}" \
    "filesystem:ubuntu:${APTLY_PREFIX}" \
    "${COMPONENT_SNAPSHOTS[@]}"
else
  echo "[INFO] No existing publish; creating new multi-component publish"
  "${APTLY_BIN[@]}" publish snapshot \
    -distribution="${PUBLISH_DISTRIBUTION}" \
    -component="${COMPONENTS}" \
    -skip-signing \
    "${COMPONENT_SNAPSHOTS[@]}" \
    "filesystem:ubuntu:${APTLY_PREFIX}"
fi

echo "[INFO] Done."
echo "[INFO] Filesystem output: ${PUBLISH_ROOT}/"
echo "[INFO] Component snapshots: ${COMPONENT_SNAPSHOTS[*]}"
echo "[INFO] Client URL: http://<server-ip>/"
