#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Script: create-aptly-mirror.sh
# Purpose: Create and update Aptly mirrors for Ubuntu Noble channels
# Usage: Run as a privileged user with access to Aptly config
# Updated: 2026-05-28
# Change Summary:
# - Added idempotent mirror creation logic.
# - Existing mirrors are skipped for create and always updated.
# ============================================

CONFIG="${APTLY_CONFIG:-/etc/aptly/aptly.conf}"

mirror_exists() {
  local mirror="$1"
  aptly -config="$CONFIG" mirror show "$mirror" >/dev/null 2>&1
}

ensure_mirror() {
  local mirror="$1"
  local url="$2"
  local dist="$3"
  shift 3
  local components=("$@")

  if mirror_exists "$mirror"; then
    echo "Mirror $mirror already exists; skipping create."
  else
    echo "Creating mirror $mirror..."
    aptly -config="$CONFIG" \
      -architectures=amd64 \
      mirror create "$mirror" \
      "$url" \
      "$dist" \
      "${components[@]}"
  fi

  echo "Updating mirror $mirror..."
  aptly -config="$CONFIG" mirror update "$mirror"
}

# Noble base: full components for install-time packages
ensure_mirror \
  ubuntu-noble \
  http://archive.ubuntu.com/ubuntu \
  noble \
  main restricted universe multiverse

# Noble-updates: Canonical-supported only (main + restricted)
ensure_mirror \
  ubuntu-noble-updates \
  http://archive.ubuntu.com/ubuntu \
  noble-updates \
  main restricted

# Noble-security: Canonical-supported only (main + restricted)
ensure_mirror \
  ubuntu-noble-security \
  http://security.ubuntu.com/ubuntu \
  noble-security \
  main restricted
