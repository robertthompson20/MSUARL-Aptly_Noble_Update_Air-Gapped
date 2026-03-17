#!/usr/bin/env bash
set -euo pipefail

CONFIG="${APTLY_CONFIG:-/etc/aptly/aptly.conf}"
DATE="$(date +%Y%m%d)"
MAX_AGE_SECONDS=$((24 * 60 * 60))

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
# Drop snapshot if exists
# -------------------------------
drop_snapshot_if_exists() {
  local snap="$1"
  if aptly -config="$CONFIG" snapshot show "$snap" >/dev/null 2>&1; then
    echo "Dropping existing snapshot $snap..."
    aptly -config="$CONFIG" snapshot drop -force "$snap"
  fi
}

# -------------------------------
# Perform initial publish?
# -------------------------------
needs_initial_publish() {
  ! aptly -config="$CONFIG" publish list >/dev/null 2>&1
}

# -------------------------------
# Update mirrors (conditional)
# -------------------------------
for MIRROR in ubuntu-noble ubuntu-noble-updates ubuntu-noble-security; do
  if mirror_needs_update "$MIRROR"; then
    echo "Updating mirror $MIRROR..."
    mirror_update_with_retry "$MIRROR"
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
# Drop today's snapshots
# -------------------------------
drop_snapshot_if_exists "$SNAP_MAIN"
drop_snapshot_if_exists "$SNAP_UPDATES"
drop_snapshot_if_exists "$SNAP_SECURITY"

# -------------------------------
# Create new snapshots
# -------------------------------
aptly -config="$CONFIG" snapshot create "$SNAP_MAIN" from mirror ubuntu-noble
aptly -config="$CONFIG" snapshot create "$SNAP_UPDATES" from mirror ubuntu-noble-updates
aptly -config="$CONFIG" snapshot create "$SNAP_SECURITY" from mirror ubuntu-noble-security

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
