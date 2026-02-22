#!/usr/bin/env bash
################################################################################
# Name: ubuntu-security-monthly.sh
# Version: 1.0
# Usage: ./ubuntu-security-monthly.sh
# Created by: Robert Thompson
# Date: February 2026
#
# Description:
#   Creates monthly security snapshots from Ubuntu Noble Security mirror,
#   excludes cloud-specific packages, and publishes to external filesystem
#   endpoint for air-gapped deployment.
#
# Features:
#   - Automatic monthly tagging (YYYY-MM format)
#   - Smart mirror update caching (skips updates within 24 hours)
#   - Cloud package filtering (AWS, Azure, GCP, Oracle, IBM, etc.)
#   - Uses Ubuntu-Noble-Security mirror
#   - Direct publish to external drive at /mnt/PSTPatches
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
#   Snapshot name format: noble-security-YYYY-MM
################################################################################
set -euo pipefail

APTLY_BIN=(aptly -config=/etc/aptly/aptly.conf)

# Publish root on removable media / air-gap staging
PUBLISH_ROOT="/mnt/PSTPatches"
PUBLISH_PREFIX="apt-mirror/security"     # <-- yields http://server-ip/apt-mirror/security
PUBLISH_DISTRIBUTION="noble-security"
COMPONENTS="main,universe,multiverse,restricted"

# Ensure target directory exists
mkdir -p "${PUBLISH_ROOT}"

DIST="noble"

# Mirrors to include: noble-security (all components)
MIRRORS=(
  "ubuntu-noble-security-main"
  "ubuntu-noble-security-restricted"
  "ubuntu-noble-security-universe"
  "ubuntu-noble-security-multiverse"
)

# Filter excluding cloud-specific packages
EXCLUDE_CLOUD_FILTER='!(Name (~ "azure|aws|amazon|ec2|gcp|google|oci|oracle|cloud-|cloudinit|cloud-init|cloud-utils|walinuxagent|google-compute-engine|oem-cloud|oem-|ubuntu-advantage|ubuntu-pro|ua-tools|pro-apt|pro-client|linux-oracle|linux-gcp|linux-aws|linux-azure|raspi|raspberrypi"))'

# Monthly tag: YYYY-MM
YEAR_MONTH="$(date +%Y-%m)"
TAG="${YEAR_MONTH}"

SNAPSHOT_NAME="${DIST}-security-${TAG}"

echo "[INFO] Creating security snapshot: ${SNAPSHOT_NAME}"

# Track mirror update timestamps to avoid redundant updates
MIRROR_TIMESTAMP_DIR="/var/cache/aptly-mirror-timestamps"
mkdir -p "${MIRROR_TIMESTAMP_DIR}"

# Update mirrors before creating snapshots (skip if updated within 24 hours)
for m in "${MIRRORS[@]}"; do
  TIMESTAMP_FILE="${MIRROR_TIMESTAMP_DIR}/${m}.timestamp"
  NOW=$(date +%s)
  LAST_UPDATE=0

  if [[ -f "${TIMESTAMP_FILE}" ]]; then
    LAST_UPDATE=$(stat -c %Y "${TIMESTAMP_FILE}" 2>/dev/null || echo 0)
  fi

  HOURS_SINCE_UPDATE=$(( ($NOW - $LAST_UPDATE) / 3600 ))

  if [[ $LAST_UPDATE -eq 0 ]] || [[ $HOURS_SINCE_UPDATE -ge 24 ]]; then
    echo "[INFO] Updating mirror: $m (last updated: $HOURS_SINCE_UPDATE hours ago)"
    "${APTLY_BIN[@]}" mirror update "$m" && touch "${TIMESTAMP_FILE}"
  else
    echo "[INFO] Skipping mirror update: $m (updated $HOURS_SINCE_UPDATE hours ago, within 24h window)"
  fi
done

if "${APTLY_BIN[@]}" snapshot show "${SNAPSHOT_NAME}" >/dev/null 2>&1; then
  echo "[INFO] Snapshot exists, skipping create: ${SNAPSHOT_NAME}"
else
  # Clean up any leftover temporary snapshots from previous runs
  echo "[INFO] Cleaning up temporary snapshots from previous runs"
  for m in "${MIRRORS[@]}"; do
    temp_snap="${SNAPSHOT_NAME}-${m}"
    filtered_snap="${SNAPSHOT_NAME}-${m}-filtered"
    "${APTLY_BIN[@]}" snapshot drop "${temp_snap}" 2>/dev/null || true
    "${APTLY_BIN[@]}" snapshot drop "${filtered_snap}" 2>/dev/null || true
  done

  # Create temporary snapshots from each mirror, then merge them
  temp_snapshots=()
  for m in "${MIRRORS[@]}"; do
    temp_snap="${SNAPSHOT_NAME}-${m}"
    filtered_snap="${SNAPSHOT_NAME}-${m}-filtered"
    echo "[INFO] Creating temporary snapshot: ${temp_snap}"
    "${APTLY_BIN[@]}" snapshot create "${temp_snap}" from mirror "${m}"

    echo "[INFO] Filtering snapshot: ${filtered_snap}"
    "${APTLY_BIN[@]}" snapshot filter "${temp_snap}" "${filtered_snap}" \
      "${EXCLUDE_CLOUD_FILTER}" \
      -with-deps

    temp_snapshots+=("${filtered_snap}")
  done

  # Merge all filtered temporary snapshots into final snapshot
  echo "[INFO] Merging filtered snapshots into: ${SNAPSHOT_NAME}"
  "${APTLY_BIN[@]}" snapshot merge "${SNAPSHOT_NAME}" "${temp_snapshots[@]}"
fi

echo "[INFO] Publishing to fixed URL path /${PUBLISH_PREFIX} (switch if already published)"

# If not published yet, publish; otherwise switch in-place (URL stays /security)
if "${APTLY_BIN[@]}" publish list 2>/dev/null | grep -q "filesystem:security:${PUBLISH_PREFIX}"; then
  echo "[INFO] Existing publish found; switching /${PUBLISH_PREFIX} to snapshot ${SNAPSHOT_NAME}"
  "${APTLY_BIN[@]}" publish switch \
    -skip-signing \
    "${PUBLISH_DISTRIBUTION}" \
    "filesystem:security:${PUBLISH_PREFIX}" \
    "${SNAPSHOT_NAME}"
else
  echo "[INFO] No existing publish; publishing /${PUBLISH_PREFIX} from snapshot ${SNAPSHOT_NAME}"
  "${APTLY_BIN[@]}" publish snapshot \
    -distribution="${PUBLISH_DISTRIBUTION}" \
    -skip-signing \
    "${SNAPSHOT_NAME}" \
    "filesystem:security:${PUBLISH_PREFIX}"
fi

echo "[INFO] Done."
echo "[INFO] Filesystem output: ${PUBLISH_ROOT}/${PUBLISH_PREFIX}/"
echo "[INFO] Client URL: http://<server-ip>/${PUBLISH_PREFIX}"
