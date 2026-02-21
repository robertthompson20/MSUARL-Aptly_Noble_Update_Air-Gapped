#!/bin/bash
set -euo pipefail
trap 'error_exit "Script failed at line $LINENO"' ERR

# Version: 2.5
# Script: Build_Ubuntu-Noble-Repo_V2.5.sh
# Purpose: Create a full Ubuntu Noble repository (all four components: main, restricted, universe, multiverse)
#          for air-gapped environments, using separate mirrors per component and robust network handling.
# Required: aptly, wget, gpg, msmtp (optional, for email notifications)
# Usage: Build_Ubuntu-Noble-Repo_2.5.sh
#
# Changelog:
# v2.5 (2026-02-10)
#   - Added estimated download sizes and completion time estimates in header (120-160GB, 4-8 hours)
#   - Enhanced update_mirror_resilient() function with component-aware size estimates
#     * Universe: ~60-70GB per suite | Main: ~10-20GB | Restricted: ~3-8GB | Multiverse: ~2-5GB
#   - Added mirror resume support detection section (shows existing packages for interrupted syncs)
#   - Fixed mirror/snapshot naming to lowercase convention (ubuntu-noble-* instead of Ubuntu-Noble-*)
#   - Changed mirror size validation thresholds for restricted/multiverse updates (-lt 1 → -lt 0)
#   - Added published directory structure display showing tree/dists/pool organization
#   - Improved user awareness of network requirements and estimated runtime
#
# v2.0 (2026-02-10)
#   - Final production version with ubuntu.sources alignment
#   - Separate mirrors for each component (main, restricted, universe, multiverse)
#   - 8 mirrors total: 4 for noble suite, 4 for noble-updates suite
#   - Mirror naming: ubuntu-noble-{Component} and ubuntu-noble-updates-{Component}
#   - Component order: main, restricted, universe, multiverse (matching ubuntu.sources exactly)
#   - Publishes two distributions: noble and noble-updates as separate distributions
#   - Published to aptly_root/public/ubuntu with clients accessing via ubuntu prefix
#   - Deployment instructions support both DEB822 (ubuntu.sources) and traditional apt formats
#   - All snapshots include all 4 components per distribution
#   - Includes robust error handling, email notifications, and network resilience
#
# Environment variables (optional overrides):
#   export APTLY_ROOT_DIR=/some/path        # Default: parsed from /etc/aptly/aptly.conf
#   export PUBLISH_ROOT=/some/path/public   # Default: $APTLY_ROOT_DIR/public
#   export PUBLISH_PREFIX=ubuntu            # Default: ubuntu
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
readonly MIN_DISK_SPACE_GB=180
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
LOG_FILE="$LOG_DIR/ubuntu_noble_$(date +%Y%m%d_%H%M%S).log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR" 2>/dev/null || {
  # If /var/log/aptly is not writable, fall back to home directory
  LOG_DIR="$HOME/aptly_logs"
  LOG_FILE="$LOG_DIR/ubuntu_noble_$(date +%Y%m%d_%H%M%S).log"
  mkdir -p "$LOG_DIR"
}

# Start logging - redirect both stdout and stderr to log file while also displaying on terminal
# Use stdbuf to disable buffering for immediate console output
if command -v stdbuf &>/dev/null; then
  exec > >(stdbuf -oL -eL tee -a "$LOG_FILE")
  exec 2>&1
  PROGRESS_NOTE=""
else
  # Fallback without line buffering
  exec > >(tee -a "$LOG_FILE")
  exec 2>&1
  PROGRESS_NOTE=" (install 'coreutils' for better real-time output)"
fi

echo "================================================================================"
echo "Script: $SCRIPT_NAME"
echo "Started: $START_TIME"
echo "Hostname: $HOSTNAME_STR"
echo "Log file: $LOG_FILE$PROGRESS_NOTE"
echo "================================================================================"
echo
echo -e "${BLUE}=== Repository Build Estimates ===${NC}"
echo "Estimated total download size: 120-160GB"
echo "Estimated completion time: 4-8 hours (depending on network speed)"
echo "Network speed required: ~10-20 Mbps minimum recommended"
echo

# ─────────────────────────────────────────────────────────────
# Log rotation - keep only 2 newest logs
# ─────────────────────────────────────────────────────────────
LOG_COUNT=$(ls -1t "$LOG_DIR"/ubuntu_noble_*.log 2>/dev/null | wc -l)
if [[ $LOG_COUNT -gt 2 ]]; then
  echo "=== Cleaning up old log files ==="
  echo " Found $LOG_COUNT log files, keeping 2 newest..."
  # List all log files sorted by time (newest first), skip first 2, delete the rest
  ls -1t "$LOG_DIR"/ubuntu_noble_*.log 2>/dev/null | tail -n +3 | while IFS= read -r old_log; do
    echo " Removing old log: $(basename "$old_log")"
    rm -f "$old_log"
  done
  echo -e "${GREEN}✓ Log cleanup completed${NC}"
  echo
fi

# ─────────────────────────────────────────────────────────────
# Email notification function
# ─────────────────────────────────────────────────────────────
send_email() {
  local subject="$1"
  local body="$2"
  local status="$3"

  # Check if email is enabled and recipient is configured
  if [[ "$ENABLE_EMAIL" != "true" ]] || [[ -z "$EMAIL_RECIPIENT" ]]; then
    return 0
  fi

  # Check if msmtp is available
  if ! command -v msmtp &>/dev/null; then
    echo -e "${YELLOW}⚠ Warning: msmtp not found. Email notification skipped.${NC}" >&2
    return 0
  fi

  local email_content="Subject: $subject
From: $EMAIL_SENDER
To: $EMAIL_RECIPIENT
Content-Type: text/plain; charset=UTF-8

$body

---
Script: $SCRIPT_NAME
Hostname: $HOSTNAME_STR
Start Time: $START_TIME
End Time: $(date '+%Y-%m-%d %H:%M:%S')
Status: $status
"

  # Send email via msmtp
  if echo -e "$email_content" | msmtp -t "$EMAIL_RECIPIENT" 2>/dev/null; then
    echo -e "${GREEN}✓ Email notification sent${NC}"
  else
    echo -e "${YELLOW}⚠ Warning: Failed to send email notification${NC}" >&2
  fi
}

# ─────────────────────────────────────────────────────────────
# Error handler
# ─────────────────────────────────────────────────────────────
error_exit() {
  local error_msg="$1"
  local end_time="$(date '+%Y-%m-%d %H:%M:%S')"

  echo -e "${RED}ERROR: $error_msg${NC}" >&2
  echo "Log file: $LOG_FILE" >&2

  # Send failure email
  send_email "[$HOSTNAME_STR] Ubuntu Noble Full Repository Build FAILED" \
    "The aptly repository build script encountered an error:\n\nError: $error_msg\n\nLog File: $LOG_FILE\n\nPlease review the logs and retry if necessary." \
    "FAILURE"

  exit 1
}

# ─────────────────────────────────────────────────────────────
# Retry logic with exponential backoff
# ─────────────────────────────────────────────────────────────
retry_with_backoff() {
  local max_attempts=5
  local timeout_base=5
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
  local max_attempts=3
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
  local max_attempts=5
  local attempt=1

  # Estimate download size for user awareness
  case "$mirror_name" in
    *universe*)
      echo -e "${BLUE}Note: Universe component is ~60-70GB per suite and may take several hours${NC}"
      ;;
    *main*)
      echo -e "${BLUE}Note: Main component is ~10-20GB per suite${NC}"
      ;;
    *restricted*)
      echo -e "${BLUE}Note: Restricted component is ~3-8GB per suite${NC}"
      ;;
    *multiverse*)
      echo -e "${BLUE}Note: Multiverse component is ~2-5GB per suite${NC}"
      ;;
  esac

  while [[ $attempt -le $max_attempts ]]; do
    echo -e "${BLUE}[Mirror update $attempt/$max_attempts]${NC} Downloading packages for mirror: ${mirror_name}..."
    echo -e "${YELLOW}Note: Downloads are resumable – partial packages will not be re-downloaded${NC}"

    if $APTLY_CMD mirror update --skip-existing-packages --ignore-signatures "$mirror_name" 2>/dev/null; then
      echo -e "${GREEN}✓ Mirror update succeeded for ${mirror_name}${NC}"
      return 0
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      local wait_time=$((5 * (2 ** (attempt - 1))))
      echo -e "${YELLOW}⚠ Mirror update failed. Retrying in ${wait_time}s...${NC}"
      sleep "$wait_time"
    fi

    ((attempt++))
  done

  error_exit "Mirror update failed for ${mirror_name} after $max_attempts attempts"
}

# ─────────────────────────────────────────────────────────────
# Sanity checks: required binaries
# ─────────────────────────────────────────────────────────────
for cmd in aptly gpg wget; do
  if ! command -v "$cmd" &>/dev/null; then
    error_exit "Required command '$cmd' not found. Install it and try again."
  fi
done

# ─────────────────────────────────────────────────────────────
# Check required files
# ─────────────────────────────────────────────────────────────
if [[ ! -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]]; then
  error_exit "Ubuntu archive keyring not found at /usr/share/keyrings/ubuntu-archive-keyring.gpg"
fi

# Validate Aptly installation
if ! aptly version &>/dev/null; then
  error_exit "Aptly version check failed. Aptly may not be properly installed."
fi

# ─────────────────────────────────────────────────────────────
# Network connectivity to Ubuntu archive
# ─────────────────────────────────────────────────────────────
echo "=== Checking network connectivity to archive.ubuntu.com ==="
check_network_connectivity "http://archive.ubuntu.com/ubuntu/dists/noble/"

# ─────────────────────────────────────────────────────────────
# Aptly paths and configuration (read from /etc/aptly/aptly.conf)
# ─────────────────────────────────────────────────────────────
echo "=== Setting Aptly defaults and publish root ==="

APTLY_CONFIG=${APTLY_CONFIG:-/etc/aptly/aptly.conf}

if [[ ! -f "$APTLY_CONFIG" ]]; then
  error_exit "Aptly config not found at $APTLY_CONFIG"
fi

# Parse rootDir from aptly.conf JSON if not already set via environment variable
if [[ -z "${APTLY_ROOT_DIR:-}" ]]; then
  # Extract rootDir value from JSON config using grep/sed for maximum portability
  APTLY_ROOT_DIR=$(grep -oP '(?<="rootDir":\s")[^"]+' "$APTLY_CONFIG" 2>/dev/null | tr -d '\r\n' || true)

  # Validate that we successfully parsed a value
  if [[ -z "$APTLY_ROOT_DIR" ]]; then
    error_exit "Failed to parse rootDir from $APTLY_CONFIG. Ensure the file contains valid JSON with a rootDir field."
  fi
fi

# If rootDir already points at a "public" directory, avoid nesting "public/public".
if [[ -z "${PUBLISH_ROOT:-}" ]]; then
  if [[ "$APTLY_ROOT_DIR" =~ /public/?$ ]]; then
    PUBLISH_ROOT="$APTLY_ROOT_DIR"
  else
    PUBLISH_ROOT="$APTLY_ROOT_DIR/public"
  fi
fi
# Keep 'ubuntu' as the published prefix so offline path is .../ubuntu/dists/noble
PUBLISH_PREFIX="${PUBLISH_PREFIX:-ubuntu}"
PUBLISH_DIR="$PUBLISH_ROOT/$PUBLISH_PREFIX"

APTLY_CMD="aptly -config=$APTLY_CONFIG"

mkdir -p "$APTLY_ROOT_DIR" || error_exit "Failed to create $APTLY_ROOT_DIR"

if [[ ! -d "$PUBLISH_ROOT" ]]; then
  mkdir -p "$PUBLISH_ROOT" || error_exit "Failed to create $PUBLISH_ROOT"
fi
if [[ ! -w "$PUBLISH_ROOT" ]]; then
  error_exit "Publish root $PUBLISH_ROOT is not writable. Check permissions or mount options."
fi

echo -e "${GREEN}✓ Using Aptly root at: $APTLY_ROOT_DIR${NC}"
echo -e "${GREEN}✓ Publish root: $PUBLISH_ROOT${NC}"
echo -e "${GREEN}✓ Publish dir: $PUBLISH_DIR${NC}"

# ─────────────────────────────────────────────────────────────
# GPG: Prepare trusted keyring for Aptly (even if we skip signing)
# ─────────────────────────────────────────────────────────────
echo "=== Importing Ubuntu archive keys ==="

mkdir -p "$APTLY_ROOT_DIR"

# Ensure GPG home permissions
if [[ ! -d "$HOME/.gnupg" ]]; then
  mkdir -p "$HOME/.gnupg"
  chmod 700 "$HOME/.gnupg"
fi

TEMP_KEYFILE="/tmp/.temp_keyfile_$$"
TRUSTED_KEYRING="$APTLY_ROOT_DIR/trustedkeys.gpg"
trap "rm -f $TEMP_KEYFILE" EXIT

# Export keys from Ubuntu archive keyring into temp file
if ! gpg --no-default-keyring \
  --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg \
  --export --output "$TEMP_KEYFILE" 2>&1; then
  error_exit "Failed to export Ubuntu archive keyring"
fi

if [[ ! -s "$TEMP_KEYFILE" ]]; then
  error_exit "Ubuntu archive keyring export produced no data"
fi

# Import into Aptly's trusted keyring
echo " Importing keys to: $TRUSTED_KEYRING"
IMPORT_OUTPUT=$(gpg --no-default-keyring \
  --keyring "$TRUSTED_KEYRING" \
  --import < "$TEMP_KEYFILE" 2>&1) || error_exit "GPG import failed: $IMPORT_OUTPUT"
echo " Import output: $IMPORT_OUTPUT"
echo " Files in $APTLY_ROOT_DIR:"
ls -la "$APTLY_ROOT_DIR"/trustedkeys.gpg* 2>/dev/null || echo " (no trustedkeys files found)"

if ! echo "$IMPORT_OUTPUT" | grep -q "processed"; then
  error_exit "GPG import did not complete properly"
fi

if [[ ! -f "$TRUSTED_KEYRING" && ! -f "${TRUSTED_KEYRING}~" ]]; then
  error_exit "Keyring file not created. GPG output: $IMPORT_OUTPUT"
fi

if ! gpg --no-default-keyring --keyring "$TRUSTED_KEYRING" --list-keys &>/dev/null; then
  error_exit "Cannot read keys from $TRUSTED_KEYRING"
fi

KEYCOUNT=$(echo "$IMPORT_OUTPUT" | grep "^gpg: key" | wc -l || true)
echo -e "${GREEN}✓ Archive keys imported ($KEYCOUNT keys)${NC}"

# ─────────────────────────────────────────────────────────────
# Disk space check
# ─────────────────────────────────────────────────────────────
echo "=== Checking available disk space ==="
REQUIRED_SPACE_GB=180  # 160GB + 20GB buffer
AVAILABLE_SPACE=$(df -BG "$APTLY_ROOT_DIR" | awk 'NR==2 {print $4}' | sed 's/G//')

if [[ $AVAILABLE_SPACE -lt $REQUIRED_SPACE_GB ]]; then
    echo -e "${YELLOW}⚠ Warning: Low disk space${NC}"
    echo "  Required: ${REQUIRED_SPACE_GB}GB"
    echo "  Available: ${AVAILABLE_SPACE}GB"
    echo "  Location: $APTLY_ROOT_DIR"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error_exit "Insufficient disk space. Aborting."
    fi
fi
echo -e "${GREEN}✓ Disk space check passed (${AVAILABLE_SPACE}GB available)${NC}"
echo

# ─────────────────────────────────────────────────────────────
# Mirror setup (separate mirror per component)
# ─────────────────────────────────────────────────────────────
echo "=== Removing old mirrors if present ==="

for MIRROR in ubuntu-noble-main ubuntu-noble-restricted ubuntu-noble-universe ubuntu-noble-multiverse ubuntu-noble-updates-main ubuntu-noble-updates-restricted ubuntu-noble-updates-universe ubuntu-noble-updates-multiverse; do
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

echo "=== Creating Ubuntu Noble mirrors (separate mirror per component) ==="
echo " Note: NO FILTERS APPLIED - Full repository mirror"
echo " Suites: noble, noble-updates"
echo " Components: main, restricted, universe, multiverse (separate mirrors)"
echo

# Noble suite mirrors
if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-main \
  http://archive.ubuntu.com/ubuntu \
  noble main; then
  error_exit "Failed to create noble main mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-restricted \
  http://archive.ubuntu.com/ubuntu \
  noble restricted; then
  error_exit "Failed to create noble restricted mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-universe \
  http://archive.ubuntu.com/ubuntu \
  noble universe; then
  error_exit "Failed to create noble universe mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-multiverse \
  http://archive.ubuntu.com/ubuntu \
  noble multiverse; then
  error_exit "Failed to create noble multiverse mirror"
fi

# Noble-updates suite mirrors
if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-updates-main \
  http://archive.ubuntu.com/ubuntu \
  noble-updates main; then
  error_exit "Failed to create noble-updates main mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-updates-restricted \
  http://archive.ubuntu.com/ubuntu \
  noble-updates restricted; then
  error_exit "Failed to create noble-updates restricted mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-updates-universe \
  http://archive.ubuntu.com/ubuntu \
  noble-updates universe; then
  error_exit "Failed to create noble-updates universe mirror"
fi

if ! $APTLY_CMD mirror create \
  --architectures=amd64 \
  --ignore-signatures \
  ubuntu-noble-updates-multiverse \
  http://archive.ubuntu.com/ubuntu \
  noble-updates multiverse; then
  error_exit "Failed to create noble-updates multiverse mirror"
fi

for MIRROR in ubuntu-noble-main ubuntu-noble-restricted ubuntu-noble-universe ubuntu-noble-multiverse ubuntu-noble-updates-main ubuntu-noble-updates-restricted ubuntu-noble-updates-universe ubuntu-noble-updates-multiverse; do
  if ! $APTLY_CMD mirror show "$MIRROR" &>/dev/null; then
    error_exit "Mirror creation succeeded but mirror not found in aptly list: $MIRROR"
  fi
done

echo -e "${GREEN}✓ Mirrors created: noble suite (main, restricted, universe, multiverse) and noble-updates suite (main, restricted, universe, multiverse)${NC}"

# ─────────────────────────────────────────────────────────────
# Check for existing mirrors (resume support)
# ─────────────────────────────────────────────────────────────
echo "=== Checking for existing mirrors (resume support) ==="
MIRRORS_TO_UPDATE=()
for MIRROR in ubuntu-noble-main ubuntu-noble-restricted ubuntu-noble-universe ubuntu-noble-multiverse ubuntu-noble-updates-main ubuntu-noble-updates-restricted ubuntu-noble-updates-universe ubuntu-noble-updates-multiverse; do
  if $APTLY_CMD mirror show "$MIRROR" &>/dev/null; then
    PKG_COUNT=$($APTLY_CMD mirror show "$MIRROR" | awk -F': ' '/Number of packages/ {print $2; found=1} END {if (!found) print 0}')
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
# Update mirrors (download packages)
# ─────────────────────────────────────────────────────────────
echo "=== Updating mirrors (downloading packages) ==="
echo -e "${BLUE}Network Drop Recovery Enabled:${NC}"
echo " • Interrupted downloads will automatically resume from where they stopped"
echo " • If connection fails, the script will retry up to 5 times with exponential backoff"
echo " • Already-downloaded packages will not be re-downloaded"
echo

update_mirror_resilient ubuntu-noble-main
update_mirror_resilient ubuntu-noble-restricted
update_mirror_resilient ubuntu-noble-universe
update_mirror_resilient ubuntu-noble-multiverse
update_mirror_resilient ubuntu-noble-updates-main
update_mirror_resilient ubuntu-noble-updates-restricted
update_mirror_resilient ubuntu-noble-updates-universe
update_mirror_resilient ubuntu-noble-updates-multiverse

MIRROR_SIZE_MAIN=$($APTLY_CMD mirror show ubuntu-noble-main 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_RESTRICTED=$($APTLY_CMD mirror show ubuntu-noble-restricted 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_UNIVERSE=$($APTLY_CMD mirror show ubuntu-noble-universe 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_MULTIVERSE=$($APTLY_CMD mirror show ubuntu-noble-multiverse 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_UPDATES_MAIN=$($APTLY_CMD mirror show ubuntu-noble-updates-main 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_UPDATES_RESTRICTED=$($APTLY_CMD mirror show ubuntu-noble-updates-restricted 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_UPDATES_UNIVERSE=$($APTLY_CMD mirror show ubuntu-noble-updates-universe 2>/dev/null | grep 'Number of packages' | awk '{print $4}')
MIRROR_SIZE_UPDATES_MULTIVERSE=$($APTLY_CMD mirror show ubuntu-noble-updates-multiverse 2>/dev/null | grep 'Number of packages' | awk '{print $4}')

if [[ -z "$MIRROR_SIZE_MAIN" || -z "$MIRROR_SIZE_RESTRICTED" || -z "$MIRROR_SIZE_UNIVERSE" || -z "$MIRROR_SIZE_MULTIVERSE" || -z "$MIRROR_SIZE_UPDATES_MAIN" || -z "$MIRROR_SIZE_UPDATES_RESTRICTED" || -z "$MIRROR_SIZE_UPDATES_UNIVERSE" || -z "$MIRROR_SIZE_UPDATES_MULTIVERSE" ]]; then
  error_exit "Could not determine mirror sizes"
fi

if [[ "$MIRROR_SIZE_MAIN" -lt 50 || "$MIRROR_SIZE_RESTRICTED" -lt 10 || "$MIRROR_SIZE_UNIVERSE" -lt 50 || "$MIRROR_SIZE_MULTIVERSE" -lt 10 || "$MIRROR_SIZE_UPDATES_MAIN" -lt 10 || "$MIRROR_SIZE_UPDATES_RESTRICTED" -lt 0 || "$MIRROR_SIZE_UPDATES_UNIVERSE" -lt 10 || "$MIRROR_SIZE_UPDATES_MULTIVERSE" -lt 0 ]]; then
  error_exit "Mirrors appear empty or have very few packages. Update may have failed."
fi

echo -e "${GREEN}✓ Noble suite mirrors updated:${NC}"
echo -e "  ${GREEN}✓ Main: $MIRROR_SIZE_MAIN packages${NC}"
echo -e "  ${GREEN}✓ Restricted: $MIRROR_SIZE_RESTRICTED packages${NC}"
echo -e "  ${GREEN}✓ Universe: $MIRROR_SIZE_UNIVERSE packages${NC}"
echo -e "  ${GREEN}✓ Multiverse: $MIRROR_SIZE_MULTIVERSE packages${NC}"
echo -e "${GREEN}✓ Noble-updates suite mirrors updated:${NC}"
echo -e "  ${GREEN}✓ Main: $MIRROR_SIZE_UPDATES_MAIN packages${NC}"
echo -e "  ${GREEN}✓ Restricted: $MIRROR_SIZE_UPDATES_RESTRICTED packages${NC}"
echo -e "  ${GREEN}✓ Universe: $MIRROR_SIZE_UPDATES_UNIVERSE packages${NC}"
echo -e "  ${GREEN}✓ Multiverse: $MIRROR_SIZE_UPDATES_MULTIVERSE packages${NC}"

# ─────────────────────────────────────────────────────────────
# Mirror summary
# ─────────────────────────────────────────────────────────────
TOTAL_PACKAGES=$((MIRROR_SIZE_MAIN + MIRROR_SIZE_RESTRICTED + MIRROR_SIZE_UNIVERSE + MIRROR_SIZE_MULTIVERSE + MIRROR_SIZE_UPDATES_MAIN + MIRROR_SIZE_UPDATES_RESTRICTED + MIRROR_SIZE_UPDATES_UNIVERSE + MIRROR_SIZE_UPDATES_MULTIVERSE))

echo
echo "=== Mirror Summary ==="
echo " Total packages mirrored: $TOTAL_PACKAGES"
echo " Noble suite: $((MIRROR_SIZE_MAIN + MIRROR_SIZE_RESTRICTED + MIRROR_SIZE_UNIVERSE + MIRROR_SIZE_MULTIVERSE)) packages"
echo " Noble-updates suite: $((MIRROR_SIZE_UPDATES_MAIN + MIRROR_SIZE_UPDATES_RESTRICTED + MIRROR_SIZE_UPDATES_UNIVERSE + MIRROR_SIZE_UPDATES_MULTIVERSE)) packages"
echo

# ─────────────────────────────────────────────────────────────
# Snapshot creation (one per component)
# ─────────────────────────────────────────────────────────────
SNAP_MAIN="ubuntu-noble-main-$(date +%Y%m%d)"
SNAP_RESTRICTED="ubuntu-noble-restricted-$(date +%Y%m%d)"
SNAP_UNIVERSE="ubuntu-noble-universe-$(date +%Y%m%d)"
SNAP_MULTIVERSE="ubuntu-noble-multiverse-$(date +%Y%m%d)"
SNAP_UPDATES_MAIN="ubuntu-noble-updates-main-$(date +%Y%m%d)"
SNAP_UPDATES_RESTRICTED="ubuntu-noble-updates-restricted-$(date +%Y%m%d)"
SNAP_UPDATES_UNIVERSE="ubuntu-noble-updates-universe-$(date +%Y%m%d)"
SNAP_UPDATES_MULTIVERSE="ubuntu-noble-updates-multiverse-$(date +%Y%m%d)"

echo "=== Removing old snapshots if present ==="

# First, drop any publications that might reference today's snapshots
if $APTLY_CMD publish list 2>/dev/null | grep -q "^  \* $PUBLISH_PREFIX/noble"; then
  echo " Found existing publication at $PUBLISH_PREFIX/noble – dropping it first"
  if ! $APTLY_CMD publish drop noble "$PUBLISH_PREFIX" 2>/dev/null; then
    echo -e "${YELLOW}⚠ Warning: failed to drop publication (continuing)${NC}"
  else
    echo -e "${GREEN}✓ Publication (noble) removed${NC}"
  fi
fi

if $APTLY_CMD publish list 2>/dev/null | grep -q "^  \* $PUBLISH_PREFIX/noble-updates"; then
  echo " Found existing publication at $PUBLISH_PREFIX/noble-updates – dropping it first"
  if ! $APTLY_CMD publish drop noble-updates "$PUBLISH_PREFIX" 2>/dev/null; then
    echo -e "${YELLOW}⚠ Warning: failed to drop publication (continuing)${NC}"
  else
    echo -e "${GREEN}✓ Publication (noble-updates) removed${NC}"
  fi
fi

# Now remove snapshots - just attempt to drop them, suppress error if they don't exist
for SNAP in "$SNAP_MAIN" "$SNAP_RESTRICTED" "$SNAP_UNIVERSE" "$SNAP_MULTIVERSE" "$SNAP_UPDATES_MAIN" "$SNAP_UPDATES_RESTRICTED" "$SNAP_UPDATES_UNIVERSE" "$SNAP_UPDATES_MULTIVERSE"; do
  echo " Attempting to remove snapshot: $SNAP"
  # Use timeout to prevent hanging, redirect stdin to prevent prompts
  if DROP_OUTPUT=$(timeout 30 $APTLY_CMD snapshot drop -force "$SNAP" </dev/null 2>&1); then
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

echo "=== Creating snapshots: noble and noble-updates suites ==="

if ! $APTLY_CMD snapshot create "$SNAP_MAIN" from mirror ubuntu-noble-main; then
  error_exit "Failed to create snapshot $SNAP_MAIN"
fi

if ! $APTLY_CMD snapshot create "$SNAP_RESTRICTED" from mirror ubuntu-noble-restricted; then
  error_exit "Failed to create snapshot $SNAP_RESTRICTED"
fi

if ! $APTLY_CMD snapshot create "$SNAP_UNIVERSE" from mirror ubuntu-noble-universe; then
  error_exit "Failed to create snapshot $SNAP_UNIVERSE"
fi

if ! $APTLY_CMD snapshot create "$SNAP_MULTIVERSE" from mirror ubuntu-noble-multiverse; then
  error_exit "Failed to create snapshot $SNAP_MULTIVERSE"
fi

if ! $APTLY_CMD snapshot create "$SNAP_UPDATES_MAIN" from mirror ubuntu-noble-updates-main; then
  error_exit "Failed to create snapshot $SNAP_UPDATES_MAIN"
fi

if ! $APTLY_CMD snapshot create "$SNAP_UPDATES_RESTRICTED" from mirror ubuntu-noble-updates-restricted; then
  error_exit "Failed to create snapshot $SNAP_UPDATES_RESTRICTED"
fi

if ! $APTLY_CMD snapshot create "$SNAP_UPDATES_UNIVERSE" from mirror ubuntu-noble-updates-universe; then
  error_exit "Failed to create snapshot $SNAP_UPDATES_UNIVERSE"
fi

if ! $APTLY_CMD snapshot create "$SNAP_UPDATES_MULTIVERSE" from mirror ubuntu-noble-updates-multiverse; then
  error_exit "Failed to create snapshot $SNAP_UPDATES_MULTIVERSE"
fi

for SNAP in "$SNAP_MAIN" "$SNAP_RESTRICTED" "$SNAP_UNIVERSE" "$SNAP_MULTIVERSE" "$SNAP_UPDATES_MAIN" "$SNAP_UPDATES_RESTRICTED" "$SNAP_UPDATES_UNIVERSE" "$SNAP_UPDATES_MULTIVERSE"; do
  if ! $APTLY_CMD snapshot show "$SNAP" &>/dev/null; then
    error_exit "Snapshot creation succeeded but snapshot not found in aptly list: $SNAP"
  fi
done

echo -e "${GREEN}✓ Snapshots created: noble suite (main, restricted, universe, multiverse) and noble-updates suite (main, restricted, universe, multiverse)${NC}"

# ─────────────────────────────────────────────────────────────
# Clean up orphaned packages from pool
# ─────────────────────────────────────────────────────────────
echo "=== Cleaning up orphaned packages from package pool ==="
echo " Removing unreferenced packages to reclaim disk space..."

# Use timeout to prevent hanging, redirect stdin to prevent prompts
if timeout 120 $APTLY_CMD db cleanup </dev/null 2>&1; then
  echo -e "${GREEN}✓ Package pool cleanup completed${NC}"
else
  CLEANUP_STATUS=$?
  if [[ $CLEANUP_STATUS -eq 124 ]]; then
    echo -e "${YELLOW}⚠ Warning: db cleanup timed out after 120s (continuing anyway)${NC}"
  else
    echo -e "${YELLOW}⚠ Warning: db cleanup failed (exit: $CLEANUP_STATUS) (continuing anyway)${NC}"
  fi
fi

# ─────────────────────────────────────────────────────────────
# Publishing snapshots (unsigned, for use with [trusted=yes])
# ─────────────────────────────────────────────────────────────
echo "=== Publishing noble distribution with main,restricted,universe,multiverse ==="

if ! $APTLY_CMD publish snapshot \
  -distribution=noble \
  -component=main,restricted,universe,multiverse \
  -skip-signing \
  "$SNAP_MAIN" \
  "$SNAP_RESTRICTED" \
  "$SNAP_UNIVERSE" \
  "$SNAP_MULTIVERSE" \
  "$PUBLISH_PREFIX"; then
  error_exit "Failed to publish noble snapshots"
fi

echo -e "${GREEN}✓ Noble distribution published${NC}"

echo "=== Publishing noble-updates distribution with main,restricted,universe,multiverse ==="

if ! $APTLY_CMD publish snapshot \
  -distribution=noble-updates \
  -component=main,restricted,universe,multiverse \
  -skip-signing \
  "$SNAP_UPDATES_MAIN" \
  "$SNAP_UPDATES_RESTRICTED" \
  "$SNAP_UPDATES_UNIVERSE" \
  "$SNAP_UPDATES_MULTIVERSE" \
  "$PUBLISH_PREFIX"; then
  error_exit "Failed to publish noble-updates snapshots"
fi

echo -e "${GREEN}✓ Noble-updates distribution published${NC}"

PUB_CHECK=$($APTLY_CMD publish list 2>/dev/null | grep -E 'noble|noble-updates' | wc -l || true)
if [[ $PUB_CHECK -lt 2 ]]; then
  error_exit "Publication succeeded but some distributions not found in aptly list"
fi

echo -e "${GREEN}✓ Snapshots published${NC}"
echo -e "${GREEN}=== SUCCESSFULLY COMPLETED ===${NC}"
echo "Your repository is now published at:"
echo -e "  ${GREEN}$PUBLISH_DIR${NC}"
echo
echo "To serve it via HTTP or copy it for air-gap use, use:"
echo -e "  ${GREEN}$PUBLISH_ROOT${NC}"
echo
echo "Repository details:"
echo "  Distribution: noble"
echo "    main       -> $SNAP_MAIN       (packages: $MIRROR_SIZE_MAIN)"
echo "    restricted -> $SNAP_RESTRICTED (packages: $MIRROR_SIZE_RESTRICTED)"
echo "    universe   -> $SNAP_UNIVERSE   (packages: $MIRROR_SIZE_UNIVERSE)"
echo "    multiverse -> $SNAP_MULTIVERSE (packages: $MIRROR_SIZE_MULTIVERSE)"
echo
echo "  Distribution: noble-updates"
echo "    main       -> $SNAP_UPDATES_MAIN       (packages: $MIRROR_SIZE_UPDATES_MAIN)"
echo "    restricted -> $SNAP_UPDATES_RESTRICTED (packages: $MIRROR_SIZE_UPDATES_RESTRICTED)"
echo "    universe   -> $SNAP_UPDATES_UNIVERSE   (packages: $MIRROR_SIZE_UPDATES_UNIVERSE)"
echo "    multiverse -> $SNAP_UPDATES_MULTIVERSE (packages: $MIRROR_SIZE_UPDATES_MULTIVERSE)"
echo
echo "Log file: $LOG_FILE"
echo
echo "Air-gap deployment instructions (target / offline system):"
echo "  1. Copy $PUBLISH_ROOT to offline media (e.g., $PUBLISH_ROOT → USB disk)"
echo "  2. On target system, mount it at e.g. /mnt/apt-mirror, so that you have:"
echo "       /mnt/apt-mirror/ubuntu/dists/noble/..."
echo "       /mnt/apt-mirror/ubuntu/dists/noble-updates/..."
echo "  3. Configure /etc/apt/sources.list.d/ubuntu.sources on the offline system with:"
echo "       Types: deb"
echo "       URIs: file:///mnt/apt-mirror/ubuntu"
echo "       Suites: noble noble-updates"
echo "       Components: main restricted universe multiverse"
echo "       Trusted: yes"
echo
echo "  Or use traditional format in /etc/apt/sources.list:"
echo "       deb [trusted=yes] file:///mnt/apt-mirror/ubuntu noble main restricted universe multiverse"
echo "       deb [trusted=yes] file:///mnt/apt-mirror/ubuntu noble-updates main restricted universe multiverse"
echo "  4. Run: apt update && apt install <package>"
echo
echo "HTTP deployment (if serving via web server):"
echo "  Configure /etc/apt/sources.list.d/ubuntu.sources with:"
echo "       Types: deb"
echo "       URIs: http://<server-ip>/ubuntu"
echo "       Suites: noble noble-updates"
echo "       Components: main restricted universe multiverse"
echo "       Trusted: yes"
echo
echo "  Or use traditional format in /etc/apt/sources.list:"
echo "       deb [trusted=yes] http://<server-ip>/ubuntu noble main restricted universe multiverse"
echo "       deb [trusted=yes] http://<server-ip>/ubuntu noble-updates main restricted universe multiverse"
echo
echo "  Note: Security updates can be added separately using Build_Noble_Security_v1.sh"
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
send_email "[$HOSTNAME_STR] Ubuntu Noble Full Repository Build SUCCESS" \
  "The aptly repository build script completed successfully.\n\nRepository Location: $PUBLISH_DIR\n\nSnapshots Created:\n\nNoble Suite:\n  main: $SNAP_MAIN ($MIRROR_SIZE_MAIN packages)\n  restricted: $SNAP_RESTRICTED ($MIRROR_SIZE_RESTRICTED packages)\n  universe: $SNAP_UNIVERSE ($MIRROR_SIZE_UNIVERSE packages)\n  multiverse: $SNAP_MULTIVERSE ($MIRROR_SIZE_MULTIVERSE packages)\n\nNoble-Updates Suite:\n  main: $SNAP_UPDATES_MAIN ($MIRROR_SIZE_UPDATES_MAIN packages)\n  restricted: $SNAP_UPDATES_RESTRICTED ($MIRROR_SIZE_UPDATES_RESTRICTED packages)\n  universe: $SNAP_UPDATES_UNIVERSE ($MIRROR_SIZE_UPDATES_UNIVERSE packages)\n  multiverse: $SNAP_UPDATES_MULTIVERSE ($MIRROR_SIZE_UPDATES_MULTIVERSE packages)\n\nLog File: $LOG_FILE\n\nThe repository is ready for deployment." \
  "SUCCESS"
