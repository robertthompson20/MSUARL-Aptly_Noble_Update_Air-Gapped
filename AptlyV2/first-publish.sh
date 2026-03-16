#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/aptly/aptly.conf"
DATE="$(date +%Y%m%d)"

mirror_update() {
  local mirror=$1
  local attempt=1
  until aptly -config="$CONFIG" mirror update "$mirror"; do
    echo "Retry $attempt/5 for $mirror in 30 seconds..."
    (( attempt++ ))
    sleep 30
  done
}

mirror_update ubuntu-noble
mirror_update ubuntu-noble-updates
mirror_update ubuntu-noble-security

SNAPSHOT_BASE="ubuntu-noble-${DATE}"

aptly -config="$CONFIG" snapshot create "${SNAPSHOT_BASE}" from mirror ubuntu-noble
aptly -config="$CONFIG" snapshot create "${SNAPSHOT_BASE}-updates" from mirror ubuntu-noble-updates
aptly -config="$CONFIG" snapshot create "${SNAPSHOT_BASE}-security" from mirror ubuntu-noble-security

echo "First-time publish..."
aptly -config="$CONFIG" publish snapshot \
  -distribution=noble \
  -architectures=amd64 \
  "${SNAPSHOT_BASE}" \
  ubuntu

aptly -config="$CONFIG" publish snapshot \
  -distribution=noble-updates \
  -architectures=amd64 \
  "${SNAPSHOT_BASE}-updates" \
  ubuntu

aptly -config="$CONFIG" publish snapshot \
  -distribution=noble-security \
  -architectures=amd64 \
  "${SNAPSHOT_BASE}-security" \
  ubuntu
