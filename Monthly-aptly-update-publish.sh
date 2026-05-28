#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Script: Monthly-aptly-update-publish.sh
# Purpose: Update Aptly mirrors, create snapshots, and publish/switch snapshots
# Usage: Run as a privileged user with access to Aptly config and publish repo
# Logs: stdout/stderr streamed to console and /var/log/aptly
# Updated: 2026-05-28
# Change Summary:
# - Fixed initial publish detection to check for real published entries,
#   preventing publish switch from running when nothing is published yet.
# - Initial publish flow now correctly uses needs_initial_publish().
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
mirror_exists() {
  local mirror="$1"
  aptly -config="$CONFIG" mirror show "$mirror" >/dev/null 2>&1
}

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
  ! aptly -config="$CONFIG" publish list 2>/dev/null | grep -qE '^\s*\* '
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

TARGETS=(
  "ubuntu-noble|noble|"
  "ubuntu-noble-updates|noble-updates|-updates"
  "ubuntu-noble-security|noble-security|-security"
)

ACTIVE_MIRRORS=()
ACTIVE_DISTS=()
ACTIVE_SNAPS=()

for TARGET in "${TARGETS[@]}"; do
  IFS='|' read -r MIRROR DIST SUFFIX <<< "$TARGET"

  if ! mirror_exists "$MIRROR"; then
    echo "Mirror $MIRROR not found; skipping this target."
    continue
  fi

  if mirror_needs_update "$MIRROR"; then
    echo "Updating mirror $MIRROR..."
    mirror_update_with_retry "$MIRROR"
    MIRRORS_UPDATED=true
  else
    echo "Mirror $MIRROR updated <24h ago; skipping."
  fi

  ACTIVE_MIRRORS+=("$MIRROR")
  ACTIVE_DISTS+=("$DIST")
  ACTIVE_SNAPS+=("ubuntu-noble-${DATE}${SUFFIX}")
done

if (( ${#ACTIVE_MIRRORS[@]} == 0 )); then
  echo "No expected mirrors were found. Nothing to publish."
  exit 1
fi

# -------------------------------
# Snapshot names
# -------------------------------
SNAP_MAIN="ubuntu-noble-${DATE}"
SNAP_UPDATES="ubuntu-noble-${DATE}-updates"
SNAP_SECURITY="ubuntu-noble-${DATE}-security"

# -------------------------------
# Create snapshots (idempotent)
# -------------------------------
for i in "${!ACTIVE_MIRRORS[@]}"; do
  create_snapshot_if_missing "${ACTIVE_SNAPS[$i]}" "${ACTIVE_MIRRORS[$i]}"
done

# -------------------------------
# INITIAL PUBLISH
# (runs only if publish list is empty)
# -------------------------------
if needs_initial_publish; then
  echo "Performing **initial publish** of all distributions..."

  for i in "${!ACTIVE_DISTS[@]}"; do
    aptly -config="$CONFIG" publish snapshot \
      -component=main \
      -architectures=amd64 \
      -distribution="${ACTIVE_DISTS[$i]}" \
      "${ACTIVE_SNAPS[$i]}" \
      ubuntu
  done

  echo "Initial publish complete."
  exit 0
fi

if [[ "$MIRRORS_UPDATED" == "false" ]]; then
  ALL_CURRENT=true
  for i in "${!ACTIVE_DISTS[@]}"; do
    if ! publish_uses_snapshot "${ACTIVE_DISTS[$i]}" "${ACTIVE_SNAPS[$i]}"; then
      ALL_CURRENT=false
      break
    fi
  done

  if [[ "$ALL_CURRENT" == "true" ]]; then
    echo "All publishes already point to today's snapshots and mirrors were unchanged; no switch needed."
    exit 0
  fi
fi

# -------------------------------
# SWITCH PUBLISHES (for subsequent runs)
# -------------------------------
echo "Switching published repos to new snapshots..."

for i in "${!ACTIVE_DISTS[@]}"; do
  aptly -config="$CONFIG" publish switch \
    -component=main \
    -architectures=amd64 \
    "${ACTIVE_DISTS[$i]}" \
    ubuntu \
    "${ACTIVE_SNAPS[$i]}"
done

echo "Publish switch complete."
echo "Published snapshots:"
for SNAP in "${ACTIVE_SNAPS[@]}"; do
  echo "  $SNAP"
done
