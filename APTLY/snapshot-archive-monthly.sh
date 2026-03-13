#!/usr/bin/env bash
################################################################################
# Name: snapshot-archive-monthly.sh
# Version: 2.0
# Usage: ./snapshot-archive-monthly.sh
# Created by: Robert Thompson
# Date: March 2026
#
# Description:
#   Creates monthly archive snapshots from Ubuntu Noble mirrors,
#   excludes cloud-specific packages, and publishes to external filesystem
#   endpoint for air-gapped deployment. Processes each component separately
#   to maintain proper multi-component repository structure.
#
# Features:
#   - Automatic monthly tagging (YYYYMM)
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
#   Snapshot name format: noble-archive-YYYYMM-{component}
#   Example: noble-archive-202603-main, noble-archive-202603-universe, etc.
################################################################################
set -euo pipefail

APTLY_BIN=(aptly -config=/etc/aptly/aptly.conf)

# Persist noteworthy aptly/runtime issues for later triage
ISSUE_LOG="${HOME}/snapshot_issues.txt"
mkdir -p "$(dirname "${ISSUE_LOG}")"
touch "${ISSUE_LOG}"

# Capture all stderr output (including aptly [!] errors) in issue log while
# still showing it in terminal during execution.
exec 2> >(tee -a "${ISSUE_LOG}" >&2)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [RUN-START] snapshot-archive-monthly.sh" >> "${ISSUE_LOG}"
trap 'echo "[$(date "+%Y-%m-%d %H:%M:%S")] [ERROR] line ${LINENO}: ${BASH_COMMAND}" >> "${ISSUE_LOG}"' ERR

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

# Monthly tag: YYYYMM
TAG="$(date +%Y%m)"

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
    "${APTLY_BIN[@]}" mirror update -ignore-checksums "$mirror_name" && touch "${TIMESTAMP_FILE}"
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

# Build publish target; empty prefix means publish at endpoint root.
if [[ -n "${PUBLISH_PREFIX}" ]]; then
  APTLY_TARGET="filesystem:ubuntu:${PUBLISH_PREFIX}"
else
  APTLY_TARGET="filesystem:ubuntu:"
fi

# Check whether an existing publish for this endpoint/distribution already exists.
# publish switch requires a pre-existing publication; if none exists, do the
# initial publish snapshot instead.
if "${APTLY_BIN[@]}" publish list 2>/dev/null | grep -qF "${APTLY_TARGET}"; then
  # publish switch performs an incremental update: aptly only writes new/changed
  # package files to the filesystem endpoint and removes packages no longer
  # referenced. This avoids copying unchanged files on every run.
  echo "[INFO] Switching publish to new snapshots (incremental update)"
  "${APTLY_BIN[@]}" publish switch \
    -component="${COMPONENTS}" \
    -skip-signing \
    -force-overwrite \
    "${PUBLISH_DISTRIBUTION}" \
    "${APTLY_TARGET}" \
    "${COMPONENT_SNAPSHOTS[@]}"
else
  echo "[INFO] No existing publish found, creating initial publish"
  "${APTLY_BIN[@]}" publish snapshot \
    -component="${COMPONENTS}" \
    -distribution="${PUBLISH_DISTRIBUTION}" \
    -skip-signing \
    -force-overwrite \
    "${COMPONENT_SNAPSHOTS[@]}" \
    "${APTLY_TARGET}"
fi

echo "[INFO] Done."
echo "[INFO] Filesystem output: ${PUBLISH_ROOT}/"
echo "[INFO] Component snapshots: ${COMPONENT_SNAPSHOTS[*]}"
echo "[INFO] Client URL: http://<server-ip>/"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [RUN-END] snapshot-archive-monthly.sh" >> "${ISSUE_LOG}"
