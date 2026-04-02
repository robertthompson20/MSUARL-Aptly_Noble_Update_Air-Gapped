#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Script: Monthly-aptly-update-publish.sh
# Version: 1.0
# Purpose: Update Aptly mirrors, create/reuse daily snapshots, and publish/switch snapshots
# Usage: Run as a privileged user with access to Aptly config and publish repo
# Logs: stdout/stderr streamed to console and /var/log/aptly via tee
# Changes: Idempotent snapshot handling and fast no-op exit when already up to date
# Updated: 2026-04-02
# ============================================

CONFIG="${APTLY_CONFIG:-/etc/aptly/aptly.conf}"
DATE="$(date +%Y%m%d)"
MAX_AGE_SECONDS=$((24 * 60 * 60))
LOG_DIR="${APTLY_LOG_DIR:-/var/log/aptly}"
LOG_FILE="${LOG_DIR}/monthly-aptly-update-publish-$(date +%Y%m%d-%H%M%S).log"

# Set up unified logging so all script output is visible and persisted.
setup_logging() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "Logging to $LOG_FILE"
}

setup_logging

# -------------------------------
# Check if mirror needs update
# -------------------------------
mirror_needs_update() {
  local mirror="$1"
  local last_line last_epoch now_epoch age

  last_line="$(aptly -config="$CONFIG" mirror show "$mirror" | awk -F': ' '/Last update/ {print $2}')"
  if [[ -z "$last_line" || "$last_line" == "never" ]]; then
    return 0
  fi

  if ! last_epoch="$(date -ud "$last_line" +%s 2>/dev/null)"; then
    return 0
  fi

  now_epoch="$(date -u +%s)"
  age=$(( now_epoch - last_epoch ))
  (( age >= MAX_AGE_SECONDS ))
}

# -------------------------------
# Update mirror with retries
# -------------------------------
mirror_update_with_retry() {
  local mirror="$1"
  local attempt=1

  until aptly -config="$CONFIG" mirror update "$mirror"; do
    echo "Retry $attempt for $mirror..."
    attempt=$(( attempt + 1 ))
    sleep 30
    if (( attempt > 5 )); then
      echo "Mirror update failed for $mirror."
      exit 1
    fi
  done
}

# -------------------------------
# Snapshot helpers
# -------------------------------
snapshot_exists() {
  local snap="$1"
  aptly -config="$CONFIG" snapshot show "$snap" >/dev/null 2>&1
}

create_snapshot_if_missing() {
  local snap="$1"
  local mirror="$2"

  if snapshot_exists "$snap"; then
    echo "Snapshot $snap already exists; reusing."
    return 0
  fi

  aptly -config="$CONFIG" snapshot create "$snap" from mirror "$mirror"
}

# -------------------------------
# Perform initial publish?
# -------------------------------
needs_initial_publish() {
  ! aptly -config="$CONFIG" publish list >/dev/null 2>&1
}

publish_uses_snapshot() {
  local distribution="$1"
  local snap="$2"

  aptly -config="$CONFIG" publish list 2>/dev/null |
    grep -F "ubuntu/${distribution}" |
    grep -F "[${snap}]"
}

# -------------------------------
# Update mirrors (conditional)
# -------------------------------
MIRRORS_UPDATED=false

for MIRROR in ubuntu-noble ubuntu-noble-updates ubuntu-noble-security; do
  if mirror_needs_update "$MIRROR"; then
    echo "Updating mirror $MIRROR..."
    mirror_update_with_retry "$MIRROR"
    MIRRORS_UPDATED=true
  else
    echo "Mirror $MIRROR updated <24h ago; skipping."
  fi
done

# -------------------------------
# Snapshot names
# -------------------------------
SNAP_MAIN="ubuntu-noble-${DATE}"
SNAP_UPDATES="ubuntu-noble-${DATE}-updates"
SNAP_SECURITY="ubuntu-noble-${DATE}-security"

# -------------------------------
# Create snapshots (idempotent)
# -------------------------------
create_snapshot_if_missing "$SNAP_MAIN" ubuntu-noble
create_snapshot_if_missing "$SNAP_UPDATES" ubuntu-noble-updates
create_snapshot_if_missing "$SNAP_SECURITY" ubuntu-noble-security

# -------------------------------
# INITIAL PUBLISH
# (runs only if publish list is empty)
# -------------------------------
if ! aptly -config="$CONFIG" publish list >/dev/null 2>&1; then
  echo "Performing **initial publish** of all distributions..."

  # noble
  aptly -config="$CONFIG" publish snapshot \
    -component=main \
    -architectures=amd64 \
    -distribution=noble \
    "$SNAP_MAIN" \
    ubuntu

  # noble-updates
  aptly -config="$CONFIG" publish snapshot \
    -component=main \
    -architectures=amd64 \
    -distribution=noble-updates \
    "$SNAP_UPDATES" \
    ubuntu

  # noble-security
  aptly -config="$CONFIG" publish snapshot \
    -component=main \
    -architectures=amd64 \
    -distribution=noble-security \
    "$SNAP_SECURITY" \
    ubuntu

  echo "Initial publish complete."
  exit 0
fi

if [[ "$MIRRORS_UPDATED" == "false" ]] &&
  publish_uses_snapshot noble "$SNAP_MAIN" &&
  publish_uses_snapshot noble-updates "$SNAP_UPDATES" &&
  publish_uses_snapshot noble-security "$SNAP_SECURITY"; then
  echo "All publishes already point to today's snapshots and mirrors were unchanged; no switch needed."
  exit 0
fi

# -------------------------------
# SWITCH PUBLISHES (for subsequent runs)
# -------------------------------
echo "Switching published repos to new snapshots..."

aptly -config="$CONFIG" publish switch \
  -component=main \
  -architectures=amd64 \
  noble \
  ubuntu \
  "$SNAP_MAIN"

aptly -config="$CONFIG" publish switch \
  -component=main \
  -architectures=amd64 \
  noble-updates \
  ubuntu \
  "$SNAP_UPDATES"

aptly -config="$CONFIG" publish switch \
  -component=main \
  -architectures=amd64 \
  noble-security \
  ubuntu \
  "$SNAP_SECURITY"

echo "Publish switch complete."
echo "Published snapshots:"
echo "  $SNAP_MAIN"
echo "  $SNAP_UPDATES"
echo "  $SNAP_SECURITY"
