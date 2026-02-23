#!/usr/bin/env bash
################################################################################
# Name: ubuntu-security-monthly.sh
# Version: 2.0
# Usage: ./ubuntu-security-monthly.sh
# Created by: Robert Thompson
# Date: February 2026
#
# Description:
#   Creates monthly security snapshots from Ubuntu Noble Security mirror,
#   excludes cloud-specific packages, and publishes to external filesystem
#   endpoint for air-gapped deployment. Processes each component separately
#   to maintain proper multi-component repository structure.
#
# Features:
#   - Automatic monthly tagging (YYYY-MM format)
#   - Smart mirror update caching (skips updates within 24 hours)
#   - Cloud package filtering (AWS, Azure, GCP, Oracle, IBM, etc.)
#   - Component-based processing (main, universe, multiverse, restricted)
#   - Multi-component publish with proper directory structure
#   - Direct publish to external drive at /mnt/PSTPatches/apt-mirror/security
#
# Requirements:
#   - aptly with /etc/aptly/aptly.conf configured
#   - FileSystemPublishEndpoints: security configured in aptly.conf
#   - External drive mounted at /mnt/PSTPatches
#   - Sufficient disk space for snapshot creation and publishing
#
# Output:
#   Published repository at /mnt/PSTPatches/apt-mirror/security/
#   Client URL: http://<server-ip>/apt-mirror/security
#   Snapshot name format: noble-security-YYYY-MM-{component}
#   Example: noble-security-2026-02-main, noble-security-2026-02-universe, etc.
################################################################################
set -euo pipefail

APTLY_BIN=(aptly -config=/etc/aptly/aptly.conf)

# Publish root on removable media / air-gap staging (matches aptly.conf)
PUBLISH_ROOT="/mnt/PSTPatches/apt-mirror/security"
PUBLISH_PREFIX=""                        # <-- no prefix, publishes at root
PUBLISH_DISTRIBUTION="noble-security"
COMPONENTS="main,restricted,universe,multiverse"

# Ensure target directory exists
mkdir -p "${PUBLISH_ROOT}"

DIST="noble"

# Component structure: noble-security per component
COMPONENTS_LIST=("main" "restricted" "universe" "multiverse")

# Filter excluding cloud-specific packages
EXCLUDE_CLOUD_FILTER='!(Name (~ "azure|aws|amazon|ec2|gcp|google|oci|oracle|cloud-|cloudinit|cloud-init|cloud-utils|walinuxagent|google-compute-engine|oem-cloud|oem-|ubuntu-advantage|ubuntu-pro|ua-tools|pro-apt|pro-client|linux-oracle|linux-gcp|linux-aws|linux-azure|raspi|raspberrypi"))'

# Monthly tag: YYYY-MM
YEAR_MONTH="$(date +%Y-%m)"
TAG="${YEAR_MONTH}"

echo "[INFO] Creating security snapshots for: ${TAG}"

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
  MIRROR_NAME="ubuntu-noble-security-${comp}"
  FINAL_SNAP="${DIST}-security-${TAG}-${comp}"

  echo "[INFO] Processing component: ${comp}"

  # Update mirror for this component
  update_mirror_if_needed "${MIRROR_NAME}"

  # Check if final snapshot already exists
  if "${APTLY_BIN[@]}" snapshot show "${FINAL_SNAP}" >/dev/null 2>&1; then
    echo "[INFO] Snapshot exists, skipping create: ${FINAL_SNAP}"
  else
    # Create temporary snapshots
    TEMP_SNAP="${FINAL_SNAP}-temp"
    FILTERED_SNAP="${FINAL_SNAP}-filtered"

    # Clean up any leftover snapshots
    "${APTLY_BIN[@]}" snapshot drop "${TEMP_SNAP}" 2>/dev/null || true
    "${APTLY_BIN[@]}" snapshot drop "${FILTERED_SNAP}" 2>/dev/null || true

    # Create snapshot from mirror
    echo "[INFO] Creating temporary snapshot: ${TEMP_SNAP}"
    "${APTLY_BIN[@]}" snapshot create "${TEMP_SNAP}" from mirror "${MIRROR_NAME}"

    # Filter out cloud packages
    echo "[INFO] Filtering snapshot: ${FILTERED_SNAP}"
    "${APTLY_BIN[@]}" snapshot filter "${TEMP_SNAP}" "${FILTERED_SNAP}" \
      "${EXCLUDE_CLOUD_FILTER}" -with-deps

    # Rename filtered snapshot to final name
    echo "[INFO] Creating final snapshot: ${FINAL_SNAP}"
    "${APTLY_BIN[@]}" snapshot rename "${FILTERED_SNAP}" "${FINAL_SNAP}"
  fi

  COMPONENT_SNAPSHOTS+=("${FINAL_SNAP}")
done

echo "[INFO] Publishing multi-component repository to root path"

# Use . for root prefix when PUBLISH_PREFIX is empty
APTLY_PREFIX="${PUBLISH_PREFIX:-.}"

# Check if there's an existing publish at this location
EXISTING_PUBLISH=$("${APTLY_BIN[@]}" publish list 2>/dev/null | grep "filesystem:security:${APTLY_PREFIX}" || true)

if [[ -n "${EXISTING_PUBLISH}" ]]; then
  # Check if it's a multi-component publish with 4 components (the new format)
  if echo "${EXISTING_PUBLISH}" | grep -q "\[${PUBLISH_DISTRIBUTION}\]" && \
     echo "${EXISTING_PUBLISH}" | grep -Eq "(main|restricted|universe|multiverse).*:.*\[.*\]"; then
    echo "[INFO] Existing multi-component publish found; switching to new snapshots"
    "${APTLY_BIN[@]}" publish switch \
      -component="${COMPONENTS}" \
      -skip-signing \
      "${PUBLISH_DISTRIBUTION}" \
      "filesystem:security:${APTLY_PREFIX}" \
      "${COMPONENT_SNAPSHOTS[@]}"
  else
    # Old format (merged single component) - drop and recreate
    echo "[INFO] Existing publish found in old format; dropping and recreating"
    "${APTLY_BIN[@]}" publish drop "${PUBLISH_DISTRIBUTION}" "filesystem:security:${APTLY_PREFIX}"
    
    echo "[INFO] Creating new multi-component publish"
    "${APTLY_BIN[@]}" publish snapshot \
      -distribution="${PUBLISH_DISTRIBUTION}" \
      -component="${COMPONENTS}" \
      -skip-signing \
      "${COMPONENT_SNAPSHOTS[@]}" \
      "filesystem:security:${APTLY_PREFIX}"
  fi
else
  echo "[INFO] No existing publish; creating new multi-component publish"
  "${APTLY_BIN[@]}" publish snapshot \
    -distribution="${PUBLISH_DISTRIBUTION}" \
    -component="${COMPONENTS}" \
    -skip-signing \
    "${COMPONENT_SNAPSHOTS[@]}" \
    "filesystem:security:${APTLY_PREFIX}"
fi

echo "[INFO] Done."
echo "[INFO] Filesystem output: ${PUBLISH_ROOT}/"
echo "[INFO] Component snapshots: ${COMPONENT_SNAPSHOTS[*]}"
echo "[INFO] Client URL: http://<server-ip>/apt-mirror/security"
