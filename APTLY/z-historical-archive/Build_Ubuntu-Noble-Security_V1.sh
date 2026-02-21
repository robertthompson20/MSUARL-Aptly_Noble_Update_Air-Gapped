#!/bin/bash
set -euo pipefail

# Version: 1.0
# Script: Build_Ubuntu-Noble-Security_V1.sh
# Purpose: Create Ubuntu Noble security repository (all four components: main, restricted, universe, multiverse)
#          for air-gapped environments, using separate mirrors per component and robust network handling.
# Required: aptly, wget, gpg, msmtp (optional, for email notifications)
# Usage: Build_Ubuntu-Noble-Security_V1.sh
#
# Changelog:
# v1.0 (2026-02-10)
#   - Initial version for Ubuntu Noble security repository mirroring
#   - Separate mirrors for each component (main, restricted, universe, multiverse)
#   - 4 mirrors total for noble-security suite
#   - Mirror naming: ubuntu-noble-security-{component}
#   - Component order: main, restricted, universe, multiverse (matching ubuntu.sources exactly)
#   - Publishes single distribution: noble-security (merged with existing ubuntu distribution if present)
#   - Published to aptly_root/public/security/ubuntu with clients accessing via security/ubuntu prefix
#   - Deployment instructions support both DEB822 (ubuntu.sources) and traditional apt formats
#   - Includes robust error handling, email notifications, and network resilience
#   - Can integrate with Build_Ubuntu-Noble-Repo_V2.5.sh output
#
# Environment variables (optional overrides):
#   export APTLY_ROOT_DIR=/some/path        # Default: parsed from /etc/aptly/aptly.conf
#   export PUBLISH_ROOT=/some/path/public   # Default: $APTLY_ROOT_DIR/public
#   export PUBLISH_PREFIX=security/ubuntu   # Default: security/ubuntu
#   export LOG_DIR=/path/to/logs            # Default: /var/log/aptly (fallback: ~/aptly_logs)
#   export ENABLE_EMAIL=true                # Enable email notifications (default: false)
#   export EMAIL_RECIPIENT=admin@domain.com # Email address for notifications
#   export EMAIL_SENDER=noreply@hostname    # Email sender address
#
# Note: Script uses /etc/aptly/aptly.conf for aptly configuration.
#       Set APTLY_ROOT_DIR to match your aptly.conf rootDir if different from default.
#
# Security Notes:
#   --ignore-signatures is used due to air-gapped environment limitations.
#   In production, verify packages using Ubuntu's GPG keys before deployment.
#   Ubuntu archive keyring: /usr/share/keyrings/ubuntu-archive-keyring.gpg

# ─────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────
readonly MAX_RETRY_ATTEMPTS=5
readonly NETWORK_CHECK_ATTEMPTS=3
readonly RETRY_BASE_TIMEOUT=5
readonly LOG_RETENTION_COUNT=2
readonly MIN_DISK_SPACE_GB=20
readonly DB_CLEANUP_TIMEOUT=300
readonly SNAPSHOT_DROP_TIMEOUT=30

# ─────────────────────────────────────────────────────────────
# Color output
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────────────────────
# Email configuration (msmtp)
# ─────────────────────────────────────────────────────────────
ENABLE_EMAIL="${ENABLE_EMAIL:-false}"
EMAIL_RECIPIENT="${EMAIL_RECIPIENT:-}"
EMAIL_SENDER="${EMAIL_SENDER:-noreply@$(hostname)}"
SCRIPT_NAME="$(basename "$0")"
HOSTNAME_STR="$(hostname)"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

# ─────────────────────────────────────────────────────────────
# Input validation
# ─────────────────────────────────────────────────────────────
if [[ -n "$EMAIL_RECIPIENT" ]] && [[ ! "$EMAIL_RECIPIENT" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
  echo "ERROR: Invalid email address format: $EMAIL_RECIPIENT" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# Logging configuration
# ─────────────────────────────────────────────────────────────
LOG_DIR="${LOG_DIR:-/var/log/aptly}"
LOG_FILE="$LOG_DIR/ubuntu_noble_security_$(date +%Y%m%d_%H%M%S).log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR" 2>/dev/null || {
  # If /var/log/aptly is not writable, fall back to home directory
  LOG_DIR="$HOME/aptly_logs"
  LOG_FILE="$LOG_DIR/ubuntu_noble_security_$(date +%Y%m%d_%H%M%S).log"
  mkdir -p "$LOG_DIR"
}

# Start logging - redirect both stdout and stderr to log file while also displaying on terminal
# Check if unbuffer is available (from expect package) to preserve progress bars
if command -v unbuffer &>/dev/null; then
  # Use unbuffer with tee to preserve terminal characteristics and show progress bars
  exec > >(unbuffer -p tee -a "$LOG_FILE")
  exec 2>&1
  PROGRESS_NOTE=""
else
  # Fallback to regular tee (progress bars won't display)
  exec > >(tee -a "$LOG_FILE")
  exec 2>&1
  PROGRESS_NOTE=" (install 'expect' package to see progress bars)"
fi

echo "================================================================================"
echo "Script: $SCRIPT_NAME"
echo "Started: $START_TIME"
echo "Hostname: $HOSTNAME_STR"
echo "Log file: $LOG_FILE$PROGRESS_NOTE"
echo "================================================================================"
echo
echo -e "${BLUE}=== Security Repository Build Estimates ===${NC}"
echo "Estimated total download size: 5-15GB"
echo "Estimated completion time: 30 minutes - 2 hours (depending on network speed)"
echo "Network speed required: ~5-10 Mbps minimum recommended"
echo

# ─────────────────────────────────────────────────────────────
# Log rotation - keep only newest logs per LOG_RETENTION_COUNT
# ─────────────────────────────────────────────────────────────
LOG_COUNT=$(ls -1t "$LOG_DIR"/ubuntu_noble_security_*.log 2>/dev/null | wc -l)
if [[ $LOG_COUNT -gt $LOG_RETENTION_COUNT ]]; then
  echo "=== Cleaning up old log files ==="
  echo " Found $LOG_COUNT log files, keeping $LOG_RETENTION_COUNT newest..."
  ls -1t "$LOG_DIR"/ubuntu_noble_security_*.log 2>/dev/null | tail -n +$((LOG_RETENTION_COUNT + 1)) | while IFS= read -r old_log; do
    echo " Removing old log: $(basename "$old_log")"
    rm -f "$old_log"
  done
fi

# ─────────────────────────────────────────────────────────────
# Email function
# ─────────────────────────────────────────────────────────────
send_email() {
  local subject="$1"
  local body="$2"
  local status="$3"

  if [[ "$ENABLE_EMAIL" != "true" ]] || [[ -z "$EMAIL_RECIPIENT" ]]; then
    return 0
  fi

  local email_body=$(echo -e "$body")
  if command -v msmtp &>/dev/null; then
    echo -e "Subject: $subject\nFrom: $EMAIL_SENDER\nTo: $EMAIL_RECIPIENT\n\n$email_body" | msmtp -a default "$EMAIL_RECIPIENT" 2>/dev/null || return 0
  fi
}

# ─────────────────────────────────────────────────────────────
# Error handler (must be defined before trap)
# ─────────────────────────────────────────────────────────────
error_exit() {
  local error_msg="$1"
  local end_time="$(date '+%Y-%m-%d %H:%M:%S')"

  echo -e "${RED}ERROR: $error_msg${NC}" >&2
  echo "Log file: $LOG_FILE" >&2

  # Send failure email
  send_email "[$HOSTNAME_STR] Ubuntu Noble Security Repository Build FAILED" \
    "The aptly repository build script encountered an error:\n\nError: $error_msg\n\nLog File: $LOG_FILE\n\nPlease review the logs and retry if necessary." \
    "FAILURE"

  exit 1
}

# Set trap after error_exit is defined
trap 'error_exit "Script failed at line $LINENO"' ERR

# ─────────────────────────────────────────────────────────────
# Retry logic with exponential backoff
# ─────────────────────────────────────────────────────────────
retry_with_backoff() {
  local max_attempts="$MAX_RETRY_ATTEMPTS"
  local timeout_base="$RETRY_BASE_TIMEOUT"
  local attempt=1
  local exit_code=0

  while [[ $attempt -le $max_attempts ]]; do
    echo -e "${BLUE}[Attempt $attempt/$max_attempts]${NC} $*"
    "$@"
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      echo -e "${GREEN}✓ Operation succeeded${NC}"
      return 0
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      local wait_time=$((timeout_base * (2 ** (attempt - 1))))
      echo -e "${YELLOW}⚠ Operation failed (exit code: $exit_code). Retrying in ${wait_time}s...${NC}"
      sleep "$wait_time"
    fi

    ((attempt++))
  done

  echo -e "${RED}✗ All retry attempts failed (exit code: $exit_code)${NC}"
  return "$exit_code"
}

# ─────────────────────────────────────────────────────────────
# Network connectivity check with retry
# ─────────────────────────────────────────────────────────────
check_network_connectivity() {
  local url="$1"
  local max_attempts="$NETWORK_CHECK_ATTEMPTS"
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    echo -e "${BLUE}[Network check $attempt/$max_attempts]${NC} Testing: $url"
    if timeout 15 wget -q --spider "$url" 2>/dev/null; then
      echo -e "${GREEN}✓ Network connectivity confirmed${NC}"
      return 0
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      echo -e "${YELLOW}⚠ Network check failed. Retrying in 5s...${NC}"
      sleep 5
    fi

    ((attempt++))
  done

  error_exit "Network connectivity check failed after $max_attempts attempts"
}

# ─────────────────────────────────────────────────────────────
# Aptly mirror update with retry
# ─────────────────────────────────────────────────────────────
update_mirror_resilient() {
  local mirror_name="$1"
  local max_attempts="$MAX_RETRY_ATTEMPTS"
  local attempt=1

  # Extract component suffix for separate log file (main, restricted, universe, multiverse)
  local log_suffix="${mirror_name##*-}"
  local mirror_log="$LOG_DIR/mirror_${log_suffix}_$(date +%Y%m%d_%H%M%S).log"

  # Redirect this mirror's output to its own file
  {
    # Estimate download size for user awareness
    case "$mirror_name" in
      *universe*)
        echo -e "${BLUE}Note: Universe component security updates are ~7-10GB${NC}"
        ;;
      *main*)
        echo -e "${BLUE}Note: Main component security updates are ~1-3GB${NC}"
        ;;
      *restricted*)
        echo -e "${BLUE}Note: Restricted component security updates are ~0.5-1GB${NC}"
        ;;
      *multiverse*)
        echo -e "${BLUE}Note: Multiverse component security updates are ~0.2-0.5GB${NC}"
        ;;
    esac

    while [[ $attempt -le $max_attempts ]]; do
      echo -e "${BLUE}[Mirror update $attempt/$max_attempts]${NC} Downloading packages for mirror: ${mirror_name}..."
      echo -e "${YELLOW}Note: Downloads are resumable – partial packages will not be re-downloaded${NC}"

      if $APTLY_CMD mirror update --skip-existing-packages --ignore-signatures "$mirror_name" </dev/null 2>/dev/null; then
        # Verify package count after update
        local pkg_count=$($APTLY_CMD mirror show "$mirror_name" | grep 'Number of packages' | awk '{print $4}')
        if [[ "$pkg_count" -eq 0 ]]; then
          echo -e "${YELLOW}⚠ Warning: Mirror update reported success but contains 0 packages${NC}"
        fi
        echo -e "${GREEN}✓ Mirror update succeeded for ${mirror_name} ($pkg_count packages)${NC}"
        return 0
      fi

      if [[ $attempt -lt $max_attempts ]]; then
        local wait_time=$((5 * (2 ** (attempt - 1))))
        echo -e "${YELLOW}⚠ Mirror update failed. Retrying in ${wait_time}s...${NC}"
        sleep "$wait_time"
      fi

      ((attempt++))
    done

    error_exit "Mirror update failed for $mirror_name after $max_attempts attempts"
  } 2>&1 | tee -a "$mirror_log"
}

# ─────────────────────────────────────────────────────────────
# Sanity checks (required binaries and files)
# ─────────────────────────────────────────────────────────────
echo "=== Sanity checks ==="
for BINARY in aptly wget gpg; do
  if ! command -v "$BINARY" &>/dev/null; then
    error_exit "Required binary not found: $BINARY"
  fi
  echo -e " ${GREEN}✓${NC} Found: $BINARY"
done

if [[ ! -f /etc/aptly/aptly.conf ]]; then
  error_exit "Aptly configuration not found: /etc/aptly/aptly.conf"
fi
echo -e " ${GREEN}✓${NC} Found: /etc/aptly/aptly.conf"

echo -e "${GREEN}✓ All sanity checks passed${NC}"
echo

# ─────────────────────────────────────────────────────────────
# Pre-flight network connectivity check
# ─────────────────────────────────────────────────────────────
echo "=== Pre-flight network connectivity check ==="
check_network_connectivity "http://security.ubuntu.com/ubuntu/dists/noble-security/Release"
check_network_connectivity "http://security.ubuntu.com/ubuntu/pool/"
echo

# ─────────────────────────────────────────────────────────────
# Parse aptly configuration
# ─────────────────────────────────────────────────────────────
echo "=== Parsing aptly configuration ==="
APTLY_CONFIG="/etc/aptly/aptly.conf"

if [[ ! -f "$APTLY_CONFIG" ]]; then
  error_exit "Aptly configuration not found: $APTLY_CONFIG"
fi

# Parse rootDir from aptly.conf JSON
APTLY_ROOT_DIR=$(grep -oP '(?<="rootDir":\s")[^"]+' "$APTLY_CONFIG" 2>/dev/null | tr -d '\r\n' || true)
if [[ -z "$APTLY_ROOT_DIR" ]]; then
  error_exit "Failed to parse rootDir from $APTLY_CONFIG. Ensure the file contains valid JSON with a rootDir field."
else
  if [[ "$APTLY_ROOT_DIR" == /mnt/aptly/mnt/aptly/* ]]; then
    APTLY_ROOT_DIR="/mnt/aptly/${APTLY_ROOT_DIR#/mnt/aptly/mnt/aptly/}"
    echo -e " ${YELLOW}⚠${NC} Normalized duplicated /mnt/aptly prefix in rootDir"
  elif [[ "$APTLY_ROOT_DIR" == /mnt/aptly/mnt/aptly ]]; then
    APTLY_ROOT_DIR="/mnt/aptly"
    echo -e " ${YELLOW}⚠${NC} Normalized duplicated /mnt/aptly prefix in rootDir"
  fi
  echo -e " ${GREEN}✓${NC} Parsed rootDir: $APTLY_ROOT_DIR"
fi

# Default publish root to aptly_root/public; use prefix security/ubuntu for requested layout.
if [[ -z "${PUBLISH_ROOT:-}" ]]; then
  if [[ "$APTLY_ROOT_DIR" =~ /public/?$ ]]; then
    PUBLISH_ROOT="$APTLY_ROOT_DIR"
  else
    PUBLISH_ROOT="$APTLY_ROOT_DIR/public"
  fi
fi
PUBLISH_PREFIX="${PUBLISH_PREFIX:-security/ubuntu}"
PUBLISH_DIR="$PUBLISH_ROOT/$PUBLISH_PREFIX"

# Validate paths don't contain dangerous characters
if [[ "$APTLY_ROOT_DIR" =~ [';$`'] ]]; then
  error_exit "APTLY_ROOT_DIR contains potentially dangerous characters"
fi
if [[ "$PUBLISH_ROOT" =~ [';$`'] ]]; then
  error_exit "PUBLISH_ROOT contains potentially dangerous characters"
fi

echo " PUBLISH_ROOT: $PUBLISH_ROOT"
echo " PUBLISH_PREFIX: $PUBLISH_PREFIX"
echo " PUBLISH_DIR: $PUBLISH_DIR"
echo

APTLY_CMD="aptly -config=$APTLY_CONFIG"

# ─────────────────────────────────────────────────────────────
# GPG setup (import Ubuntu archive keys)
# ─────────────────────────────────────────────────────────────
echo "=== GPG setup ==="
if [[ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
  error_exit "Ubuntu archive keyring not found: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
fi
echo -e " ${GREEN}✓${NC} Ubuntu archive keyring found"

$APTLY_CMD gpg configure >/dev/null 2>&1 || true
echo -e " ${GREEN}✓${NC} GPG configured for aptly"
echo

# ─────────────────────────────────────────────────────────────
# Disk space check
# ─────────────────────────────────────────────────────────────
echo "=== Checking available disk space ==="
REQUIRED_SPACE_GB="$MIN_DISK_SPACE_GB"
AVAILABLE_SPACE=$(df -BG "$APTLY_ROOT_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')
echo " Required: ${REQUIRED_SPACE_GB}GB"
echo " Available: ${AVAILABLE_SPACE}GB"

if [[ $AVAILABLE_SPACE -lt $REQUIRED_SPACE_GB ]]; then
  echo -e " ${YELLOW}⚠ Warning: Less than ${REQUIRED_SPACE_GB}GB available${NC}"
  read -p "Continue anyway? (y/n): " -r
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted by user"
    exit 1
  fi
else
  echo -e " ${GREEN}✓${NC} Sufficient disk space available"
fi
echo

# ─────────────────────────────────────────────────────────────
# Mirror setup (separate mirror per component)
# ─────────────────────────────────────────────────────────────
echo "=== Removing old mirrors if present ==="

for MIRROR in ubuntu-noble-security-main ubuntu-noble-security-restricted ubuntu-noble-security-universe ubuntu-noble-security-multiverse; do
  if $APTLY_CMD mirror show "$MIRROR" &>/dev/null; then
    echo " Found existing mirror: $MIRROR – dropping it"
    if ! $APTLY_CMD mirror drop -force "$MIRROR" >/dev/null 2>&1; then
      echo -e "${YELLOW}⚠ Warning: failed to drop mirror $MIRROR (continuing)${NC}"
    else
      echo -e "${GREEN}✓ Old mirror removed: $MIRROR${NC}"
    fi
  else
    echo " No existing mirror to remove for: $MIRROR"
  fi
done

echo "=== Creating Ubuntu Noble Security mirrors (separate mirror per component) ==="
echo " Note: NO FILTERS APPLIED - Full security repository mirror"
echo " Suite: noble-security"
echo " Components: main, restricted, universe, multiverse (separate mirrors)"
echo

# Noble-security suite mirrors
if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-security-main \
  http://security.ubuntu.com/ubuntu \
  noble-security main </dev/null; then
  error_exit "Failed to create noble-security main mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-security-restricted \
  http://security.ubuntu.com/ubuntu \
  noble-security restricted </dev/null; then
  error_exit "Failed to create noble-security restricted mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-security-universe \
  http://security.ubuntu.com/ubuntu \
  noble-security universe </dev/null; then
  error_exit "Failed to create noble-security universe mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-security-multiverse \
  http://security.ubuntu.com/ubuntu \
  noble-security multiverse </dev/null; then
  error_exit "Failed to create noble-security multiverse mirror"
fi

for MIRROR in ubuntu-noble-security-main ubuntu-noble-security-restricted ubuntu-noble-security-universe ubuntu-noble-security-multiverse; do
  if ! $APTLY_CMD mirror show "$MIRROR" &>/dev/null; then
    error_exit "Mirror creation succeeded but mirror not found in aptly list: $MIRROR"
  fi
done

echo -e "${GREEN}✓ Mirrors created: noble-security suite (main, restricted, universe, multiverse)${NC}"

# ─────────────────────────────────────────────────────────────
# Check for existing mirrors (resume support)
# ─────────────────────────────────────────────────────────────
echo "=== Checking for existing mirrors (resume support) ==="
MIRRORS_TO_UPDATE=()
for MIRROR in ubuntu-noble-security-main ubuntu-noble-security-restricted ubuntu-noble-security-universe ubuntu-noble-security-multiverse; do
  if $APTLY_CMD mirror show "$MIRROR" &>/dev/null; then
    PKG_COUNT=$($APTLY_CMD mirror show "$MIRROR" 2>/dev/null | awk -F': ' '/Number of packages/ {print $2; exit}')
    if [[ ! "$PKG_COUNT" =~ ^[0-9]+$ ]]; then
      PKG_COUNT=0
    fi
    if [[ "$PKG_COUNT" -gt 0 ]]; then
      echo -e " ${GREEN}✓${NC} Found existing mirror with $PKG_COUNT packages: $MIRROR (will update)"
    else
      echo " Found empty mirror: $MIRROR (will download)"
    fi
  fi
  MIRRORS_TO_UPDATE+=("$MIRROR")
done
echo

# ─────────────────────────────────────────────────────────────
# Update mirrors (download packages) - PARALLEL execution
# ─────────────────────────────────────────────────────────────
echo "=== Updating mirrors (downloading packages in parallel) ==="
echo -e "${BLUE}Network Drop Recovery Enabled:${NC}"
echo " • Interrupted downloads will automatically resume from where they stopped"
echo " • If connection fails, the script will retry up to $MAX_RETRY_ATTEMPTS times with exponential backoff"
echo " • Already-downloaded packages will not be re-downloaded"
echo " • All 4 components downloading simultaneously for faster completion"
echo

# Start parallel updates
update_mirror_resilient ubuntu-noble-security-main &
PID_MAIN=$!
update_mirror_resilient ubuntu-noble-security-restricted &
PID_RESTRICTED=$!
update_mirror_resilient ubuntu-noble-security-universe &
PID_UNIVERSE=$!
update_mirror_resilient ubuntu-noble-security-multiverse &
PID_MULTIVERSE=$!

# Wait for all mirrors to complete
echo "Waiting for all mirror updates to complete..."
wait $PID_MAIN || error_exit "Main mirror update failed"
wait $PID_RESTRICTED || error_exit "Restricted mirror update failed"
wait $PID_UNIVERSE || error_exit "Universe mirror update failed"
wait $PID_MULTIVERSE || error_exit "Multiverse mirror update failed"

echo -e "${GREEN}✓ All parallel mirror updates completed successfully${NC}"

MIRROR_SIZE_MAIN=$($APTLY_CMD mirror show ubuntu-noble-security-main 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_RESTRICTED=$($APTLY_CMD mirror show ubuntu-noble-security-restricted 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_UNIVERSE=$($APTLY_CMD mirror show ubuntu-noble-security-universe 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_MULTIVERSE=$($APTLY_CMD mirror show ubuntu-noble-security-multiverse 2>/dev/null | grep 'Number of packages' | awk '{print $4}')

if [[ -z "$MIRROR_SIZE_MAIN" || -z "$MIRROR_SIZE_RESTRICTED" || -z "$MIRROR_SIZE_UNIVERSE" || -z "$MIRROR_SIZE_MULTIVERSE" ]]; then
  error_exit "Could not determine mirror sizes"
fi

if [[ "$MIRROR_SIZE_MAIN" -lt 10 || "$MIRROR_SIZE_RESTRICTED" -lt 0 || "$MIRROR_SIZE_UNIVERSE" -lt 10 || "$MIRROR_SIZE_MULTIVERSE" -lt 0 ]]; then
  error_exit "Mirrors appear empty or have very few packages. Update may have failed."
fi

echo -e "${GREEN}✓ Noble-security suite mirrors updated:${NC}"
echo -e "  ${GREEN}✓ Main: $MIRROR_SIZE_MAIN packages${NC}"
echo -e "  ${GREEN}✓ Restricted: $MIRROR_SIZE_RESTRICTED packages${NC}"
echo -e "  ${GREEN}✓ Universe: $MIRROR_SIZE_UNIVERSE packages${NC}"
echo -e "  ${GREEN}✓ Multiverse: $MIRROR_SIZE_MULTIVERSE packages${NC}"

# ─────────────────────────────────────────────────────────────
# Mirror summary
# ─────────────────────────────────────────────────────────────
TOTAL_PACKAGES=$((MIRROR_SIZE_MAIN + MIRROR_SIZE_RESTRICTED + MIRROR_SIZE_UNIVERSE + MIRROR_SIZE_MULTIVERSE))

echo "=== Mirror Summary ==="
echo " Total security packages mirrored: $TOTAL_PACKAGES"
echo " Distribution: main ($MIRROR_SIZE_MAIN) / restricted ($MIRROR_SIZE_RESTRICTED) / universe ($MIRROR_SIZE_UNIVERSE) / multiverse ($MIRROR_SIZE_MULTIVERSE)"
echo

# ─────────────────────────────────────────────────────────────
# Snapshot creation (one per component)
# ─────────────────────────────────────────────────────────────
SNAP_MAIN="ubuntu-noble-security-main-$(date +%Y%m%d)"
SNAP_RESTRICTED="ubuntu-noble-security-restricted-$(date +%Y%m%d)"
SNAP_UNIVERSE="ubuntu-noble-security-universe-$(date +%Y%m%d)"
SNAP_MULTIVERSE="ubuntu-noble-security-multiverse-$(date +%Y%m%d)"

echo "=== Removing old snapshots if present ==="

# First, drop any publications that might reference today's snapshots
if $APTLY_CMD publish list 2>/dev/null | grep -q "^  \* $PUBLISH_PREFIX/noble-security"; then
  echo " Found existing publication at $PUBLISH_PREFIX/noble-security – dropping it first"
  if ! $APTLY_CMD publish drop noble-security "$PUBLISH_PREFIX" 2>/dev/null; then
    echo -e "${YELLOW}⚠ Warning: failed to drop publication (continuing)${NC}"
  else
    echo -e "${GREEN}✓ Publication (noble-security) removed${NC}"
  fi
fi

# Now remove snapshots - just attempt to drop them, suppress error if they don't exist
for SNAP in "$SNAP_MAIN" "$SNAP_RESTRICTED" "$SNAP_UNIVERSE" "$SNAP_MULTIVERSE"; do
  echo " Attempting to remove snapshot: $SNAP"
  # Use timeout to prevent hanging, redirect stdin to prevent prompts
  if DROP_OUTPUT=$(timeout "$SNAPSHOT_DROP_TIMEOUT" $APTLY_CMD snapshot drop -force "$SNAP" </dev/null 2>&1); then
    echo -e "${GREEN}✓ Old snapshot removed: $SNAP${NC}"
  else
    DROP_STATUS=$?
    if [[ $DROP_STATUS -eq 124 ]]; then
      echo -e "${YELLOW}⚠ Warning: snapshot drop timed out for $SNAP (may be locked)${NC}"
    elif echo "$DROP_OUTPUT" | grep -qi "not found\|doesn't exist\|ERROR: snapshot.*not found"; then
      echo " No existing snapshot to remove for: $SNAP"
    else
      echo -e "${YELLOW}⚠ Warning: failed to drop snapshot $SNAP (exit: $DROP_STATUS): $DROP_OUTPUT${NC}"
    fi
  fi
done

echo "=== Creating snapshots: noble-security suite ==="

if ! $APTLY_CMD snapshot create "$SNAP_MAIN" from mirror ubuntu-noble-security-main; then
  error_exit "Failed to create snapshot $SNAP_MAIN"
fi

if ! $APTLY_CMD snapshot create "$SNAP_RESTRICTED" from mirror ubuntu-noble-security-restricted; then
  error_exit "Failed to create snapshot $SNAP_RESTRICTED"
fi

if ! $APTLY_CMD snapshot create "$SNAP_UNIVERSE" from mirror ubuntu-noble-security-universe; then
  error_exit "Failed to create snapshot $SNAP_UNIVERSE"
fi

if ! $APTLY_CMD snapshot create "$SNAP_MULTIVERSE" from mirror ubuntu-noble-security-multiverse; then
  error_exit "Failed to create snapshot $SNAP_MULTIVERSE"
fi

for SNAP in "$SNAP_MAIN" "$SNAP_RESTRICTED" "$SNAP_UNIVERSE" "$SNAP_MULTIVERSE"; do
  if ! $APTLY_CMD snapshot show "$SNAP" &>/dev/null; then
    error_exit "Snapshot creation succeeded but snapshot not found in aptly list: $SNAP"
  fi
done

echo -e "${GREEN}✓ Snapshots created: noble-security suite (main, restricted, universe, multiverse)${NC}"

# ─────────────────────────────────────────────────────────────
# Clean up orphaned packages from pool
# ─────────────────────────────────────────────────────────────
echo "=== Cleaning up orphaned packages from package pool ==="
echo " Removing unreferenced packages to reclaim disk space..."
echo " Timeout: ${DB_CLEANUP_TIMEOUT}s"

# Use timeout to prevent hanging, redirect stdin to prevent prompts
if timeout "$DB_CLEANUP_TIMEOUT" $APTLY_CMD db cleanup </dev/null 2>&1; then
  echo -e "${GREEN}✓ Package pool cleanup completed${NC}"
else
  CLEANUP_STATUS=$?
  if [[ $CLEANUP_STATUS -eq 124 ]]; then
    echo -e "${YELLOW}⚠ Warning: db cleanup timed out after ${DB_CLEANUP_TIMEOUT}s (continuing anyway)${NC}"
  else
    echo -e "${YELLOW}⚠ Warning: db cleanup failed (exit: $CLEANUP_STATUS) (continuing anyway)${NC}"
  fi
fi

# ─────────────────────────────────────────────────────────────
# Publishing snapshots (unsigned, for use with [trusted=yes])
# ─────────────────────────────────────────────────────────────
echo "=== Publishing noble-security distribution with main,restricted,universe,multiverse ==="

if ! $APTLY_CMD publish snapshot \
  -distribution=noble-security \
  -component=main,restricted,universe,multiverse \
  -skip-signing \
  "$SNAP_MAIN" \
  "$SNAP_RESTRICTED" \
  "$SNAP_UNIVERSE" \
  "$SNAP_MULTIVERSE" \
  "$PUBLISH_PREFIX"; then
  error_exit "Failed to publish noble-security snapshots"
fi

echo -e "${GREEN}✓ Noble-security distribution published${NC}"

# ─────────────────────────────────────────────────────────────
# Summary and deployment instructions
# ─────────────────────────────────────────────────────────────
echo
echo "================================================================================"
echo "✓ BUILD COMPLETE"
echo "================================================================================"
echo
echo "=== Repository Details ==="
echo "Repository: Ubuntu Noble Security (noble-security)"
echo "Location: $PUBLISH_DIR"
echo "Suites: noble-security"
echo "Components: main,restricted,universe,multiverse"
echo "Total packages: $TOTAL_PACKAGES"
echo

echo "=== Snapshot Information ==="
echo "noble-security:"
echo "  main -> $SNAP_MAIN (packages: $MIRROR_SIZE_MAIN)"
echo "  restricted -> $SNAP_RESTRICTED (packages: $MIRROR_SIZE_RESTRICTED)"
echo "  universe -> $SNAP_UNIVERSE (packages: $MIRROR_SIZE_UNIVERSE)"
echo "  multiverse -> $SNAP_MULTIVERSE (packages: $MIRROR_SIZE_MULTIVERSE)"
echo

echo "=== Integration with Ubuntu Repository ==="
echo "Note: This script publishes to a separate 'noble-security' distribution."
echo "To integrate with the main ubuntu distribution from Build_Ubuntu-Noble-Repo_V2.5.sh:"
echo "  1. Either re-publish the ubuntu distribution to include these snapshots as an additional suite"
echo "  2. Or keep them separate and add noble-security to APT sources"
echo "  3. Or use Build_Ubuntu-Noble-Repo_V2.5.sh first, then re-publish with security snapshots"
echo

echo "=== Deployment Instructions ==="
echo
echo "Add to APT (DEB822 format in /etc/apt/sources.d/ubuntu.sources):"
echo "  Types: deb"
echo "       URIs: http://<server-ip>/security/ubuntu"
echo "       Suites: noble noble-updates noble-security"
echo "       Components: main restricted universe multiverse"
echo "       Trusted: yes"
echo
echo "Or use traditional format in /etc/apt/sources.list:"
echo "  deb [trusted=yes] http://<server-ip>/security/ubuntu noble-security main restricted universe multiverse"
echo

echo "================================================================================"
echo "=== Published Directory Structure ==="
echo "================================================================================"
tree -L 3 -d "$PUBLISH_DIR" 2>/dev/null || {
  echo "Directory structure:"
  ls -lh "$PUBLISH_DIR/dists/" 2>/dev/null
  echo
  echo "Pool size:"
  du -sh "$PUBLISH_DIR/pool/" 2>/dev/null
}
echo

# Send success email
send_email "[$HOSTNAME_STR] Ubuntu Noble Security Repository Build SUCCESS" \
  "The aptly security repository build script completed successfully.\n\nRepository Location: $PUBLISH_DIR\n\nSnapshots Created:\n\nNoble-Security Suite:\n  main: $SNAP_MAIN ($MIRROR_SIZE_MAIN packages)\n  restricted: $SNAP_RESTRICTED ($MIRROR_SIZE_RESTRICTED packages)\n  universe: $SNAP_UNIVERSE ($MIRROR_SIZE_UNIVERSE packages)\n  multiverse: $SNAP_MULTIVERSE ($MIRROR_SIZE_MULTIVERSE packages)\n\nTotal Security Packages: $TOTAL_PACKAGES\n\nLog File: $LOG_FILE\n\nThe security repository is ready for deployment. You can integrate it with the main repository or serve it separately.\n\nIntegration: Add 'noble-security' to the Suites line in your ubuntu.sources configuration." \
  "SUCCESS"

END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Script completed at: $END_TIME"
echo "Log file: $LOG_FILE"
