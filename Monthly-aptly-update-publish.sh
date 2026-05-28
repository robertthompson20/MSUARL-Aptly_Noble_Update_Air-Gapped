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
# - Added coarse percentage progress reporting across script phases.
# - Added auto-bootstrap for missing mirrors during monthly runs.
# ============================================

CONFIG="${APTLY_CONFIG:-/etc/aptly/aptly.conf}"
DATE="$(date +%Y%m%d)"
MAX_AGE_SECONDS=$((24 * 60 * 60))
LOG_DIR="${APTLY_LOG_DIR:-/var/log/aptly}"
LOG_FILE="${LOG_DIR}/monthly-aptly-update-publish-$(date +%Y%m%d-%H%M%S).log"

PROGRESS_TOTAL=0
PROGRESS_DONE=0

# Set up unified logging so all script output is visible and persisted.
setup_logging() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "Logging to $LOG_FILE"
}

setup_logging

# -------------------------------
# Progress helpers
# -------------------------------
progress_init() {
  PROGRESS_TOTAL="$1"
  PROGRESS_DONE=0
}

progress_tick() {
  local message="$1"

  PROGRESS_DONE=$(( PROGRESS_DONE + 1 ))
  if (( PROGRESS_TOTAL > 0 )); then
    local percent
    percent=$(( (PROGRESS_DONE * 100) / PROGRESS_TOTAL ))
    echo "[${percent}%] (${PROGRESS_DONE}/${PROGRESS_TOTAL}) ${message}"
  else
    echo "[0%] (0/0) ${message}"
  fi
}

progress_note_long_step() {
  local message="$1"
  echo "[....] ${message} (long-running aptly step; internal percentage not exposed by aptly)"
}

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
  "ubuntu-noble|noble||http://archive.ubuntu.com/ubuntu|main,restricted,universe,multiverse"
  "ubuntu-noble-updates|noble-updates|-updates|http://archive.ubuntu.com/ubuntu|main,restricted"
  "ubuntu-noble-security|noble-security|-security|http://security.ubuntu.com/ubuntu|main,restricted"
)

ACTIVE_MIRRORS=()
ACTIVE_DISTS=()
ACTIVE_SNAPS=()

# We track mirror handling per configured target. Snapshot + publish steps are
# added later once we know which mirrors actually exist.
progress_init "${#TARGETS[@]}"

for TARGET in "${TARGETS[@]}"; do
  IFS='|' read -r MIRROR DIST SUFFIX MIRROR_URL MIRROR_COMPONENTS <<< "$TARGET"

  if ! mirror_exists "$MIRROR"; then
    echo "Mirror $MIRROR not found; auto-bootstrapping..."
    IFS=',' read -r -a COMPONENTS <<< "$MIRROR_COMPONENTS"
    aptly -config="$CONFIG" \
      -architectures=amd64 \
      mirror create "$MIRROR" \
      "$MIRROR_URL" \
      "$DIST" \
      "${COMPONENTS[@]}"
    MIRRORS_UPDATED=true
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

  progress_tick "Mirror stage complete for ${MIRROR}"
done

if (( ${#ACTIVE_MIRRORS[@]} == 0 )); then
  echo "No expected mirrors were found. Nothing to publish."
  exit 1
fi

# Reset and track only actionable work from this point onward.
# Stages per active distribution: snapshot + publish/switch.
progress_init "$(( ${#ACTIVE_MIRRORS[@]} + ${#ACTIVE_DISTS[@]} ))"

# -------------------------------
# Create snapshots (idempotent)
# -------------------------------
for i in "${!ACTIVE_MIRRORS[@]}"; do
  create_snapshot_if_missing "${ACTIVE_SNAPS[$i]}" "${ACTIVE_MIRRORS[$i]}"
  progress_tick "Snapshot stage complete for ${ACTIVE_SNAPS[$i]}"
done

# -------------------------------
# INITIAL PUBLISH
# (runs only if publish list is empty)
# -------------------------------
if needs_initial_publish; then
  echo "Performing **initial publish** of all distributions..."

  for i in "${!ACTIVE_DISTS[@]}"; do
    progress_note_long_step "Starting initial publish for ${ACTIVE_DISTS[$i]} using ${ACTIVE_SNAPS[$i]}"
    aptly -config="$CONFIG" publish snapshot \
      -component=main \
      -architectures=amd64 \
      -distribution="${ACTIVE_DISTS[$i]}" \
      "${ACTIVE_SNAPS[$i]}" \
      ubuntu
    progress_tick "Initial publish complete for ${ACTIVE_DISTS[$i]}"
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
    echo "[100%] (no switch needed)"
    echo "All publishes already point to today's snapshots and mirrors were unchanged; no switch needed."
    exit 0
  fi
fi

# -------------------------------
# SWITCH PUBLISHES (for subsequent runs)
# -------------------------------
echo "Switching published repos to new snapshots..."

for i in "${!ACTIVE_DISTS[@]}"; do
  progress_note_long_step "Starting publish switch for ${ACTIVE_DISTS[$i]} to ${ACTIVE_SNAPS[$i]}"
  aptly -config="$CONFIG" publish switch \
    -component=main \
    -architectures=amd64 \
    "${ACTIVE_DISTS[$i]}" \
    ubuntu \
    "${ACTIVE_SNAPS[$i]}"
  progress_tick "Publish switch complete for ${ACTIVE_DISTS[$i]}"
done

echo "Publish switch complete."
echo "Published snapshots:"
for SNAP in "${ACTIVE_SNAPS[@]}"; do
  echo "  $SNAP"
done
