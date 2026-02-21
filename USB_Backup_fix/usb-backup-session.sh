#!/usr/bin/env bash
# usb-backup-session.sh — time-boxed USB mass-storage enablement for a specific user
# Restores STIG-compliant state on exit.
# Requires sudo; checks /etc/usb-backup-allow.list for authorization.
#Path: /usr/local/sbin/usb-backup-session.sh
#Owner/Perms: root:root 0755
set -euo pipefail
ALLOW_LIST="/etc/usb-backup-allow.list"
LOGTAG="usb-backup-session"
UDEV_WAIT_SECS=5

err() { echo "[$LOGTAG] ERROR: $*" >&2; }
msg() { echo "[$LOGTAG] $*"; }

# Identify the real operator (not root)
REAL_USER="${SUDO_USER:-${USER}}"
if [[ -z "${REAL_USER}" || "${EUID}" -ne 0 ]]; then
  err "Run with sudo. Example: sudo $(basename "$0") [DEVICE]"
  exit 1
fi

# Authorization gate: must be in allow-list AND in group usbbackup
if [[ ! -r "$ALLOW_LIST" ]] || ! grep -Fxq "${REAL_USER}" "$ALLOW_LIST"; then
  err "User '${REAL_USER}' is not in $ALLOW_LIST (authorization failed)."
  exit 2
fi
if ! id -nG "$REAL_USER" | tr ' ' '\n' | grep -Fxq 'usbbackup'; then
  err "User '${REAL_USER}' is not a member of group 'usbbackup'."
  exit 2
fi

MODULES_LOADED=0
MOUNTPOINT=""
DEVICE_ARG="${1:-}"
UDISKS_MNT=""

cleanup() {
  # Unmount if still mounted (try mountpoint/findmnt when available)
  if [[ -n "$MOUNTPOINT" ]]; then
    if command -v mountpoint >/dev/null 2>&1; then
      if mountpoint -q "$MOUNTPOINT"; then
        msg "Unmounting $MOUNTPOINT ..."
        umount "$MOUNTPOINT" || true
      fi
    else
      umount "$MOUNTPOINT" 2>/dev/null || true
    fi
  fi
  # If we used udisks to mount the underlying target, unmount it too
  if [[ -n "$UDISKS_MNT" ]]; then
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$UDISKS_MNT"; then
      msg "Unmounting udisks-managed mount $UDISKS_MNT ..."
      umount "$UDISKS_MNT" || udisksctl unmount -b "$DEVICE" >/dev/null 2>&1 || true
    else
      umount "$UDISKS_MNT" 2>/dev/null || true
    fi
  fi
  # Remove mountpoint if created
  if [[ -n "$MOUNTPOINT" && -d "$MOUNTPOINT" ]]; then
    rmdir "$MOUNTPOINT" 2>/dev/null || true
  fi
  # Remove modules to restore hardened state
  if [[ "$MODULES_LOADED" -eq 1 ]]; then
    msg "Removing usb-storage/uas modules (restoring hardened state) ..."
    modprobe -r uas 2>/dev/null || true
    modprobe -r usb-storage 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'msg "Signal received, exiting."; exit 130' INT TERM

# Load modules for this session (ignore STIG 'install' directive)
msg "Loading usb-storage (and uas if available) for this session ..."
if modinfo usb-storage >/dev/null 2>&1; then
  modprobe -i usb-storage || { err "Failed to load usb-storage"; exit 3; }
  MODULES_LOADED=1
else
  err "usb-storage module not available on this kernel."
  exit 3
fi
if modinfo uas >/dev/null 2>&1; then
  modprobe -i uas || true
fi
sleep "$UDEV_WAIT_SECS"

# Helper to list USB removable block devices
choose_device() {
  lsblk -o NAME,PATH,TRAN,RM,SIZE,MODEL,MOUNTPOINT | awk '$3=="usb" && $4==1 {print}'
}

DEVICE=""
if [[ -n "$DEVICE_ARG" ]]; then
  [[ -b "$DEVICE_ARG" ]] || { err "Specified device '$DEVICE_ARG' is not a block device."; exit 4; }
  DEVICE="$DEVICE_ARG"
else
  msg "Detecting USB removable devices ..."
  LIST=$(choose_device || true)
  if [[ -z "$LIST" ]]; then
    msg "No USB devices detected. Plug in the drive, wait a moment, then press Enter."
    read -r
    LIST=$(choose_device || true)
  fi
  [[ -n "$LIST" ]] || { err "Still no USB devices detected."; exit 5; }
  echo "Available USB devices:"
  echo "$LIST"
  echo
  read -rp "Enter full device path to mount (e.g., /dev/sdb1): " DEVICE
fi

[[ -b "$DEVICE" ]] || { err "Block device not found: $DEVICE"; exit 6; }

# If the chosen device does not end with a digit, warn (likely whole-disk)
if [[ ! $(basename "$DEVICE") =~ [0-9]$ ]]; then
  msg "Device '$DEVICE' appears to be a whole-disk rather than a partition."
  read -rp "Are you sure you want to mount the whole device? [y/N]: " CONF
  if [[ ! "$CONF" =~ ^[Yy]$ ]]; then
    err "Aborting — choose a partition (e.g., /dev/sdb1)."
    exit 6
  fi
fi

# Detect read-only devices and prefer read-only mounts
READ_ONLY=0
if command -v blockdev >/dev/null 2>&1; then
  if [[ "$(blockdev --getro "$DEVICE")" -ne 0 ]]; then
    READ_ONLY=1
    msg "Device $DEVICE is read-only; will mount read-only."
  fi
fi

MOUNTPOINT="/media/${REAL_USER}/backup-$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 -o "$REAL_USER" -g "$(id -gn "$REAL_USER")" "$MOUNTPOINT"

# Mount using udisksctl if available; otherwise plain mount
if command -v udisksctl >/dev/null 2>&1; then
  msg "Mounting $DEVICE for $REAL_USER ..."
  if [[ "$READ_ONLY" -eq 1 ]]; then
    if command -v udisksctl >/dev/null 2>&1; then
      MNT_LINE=$(udisksctl mount -b "$DEVICE" --options ro 2>&1) || MNT_LINE=""
    else
      MNT_LINE=""
    fi
  else
    MNT_LINE=$(udisksctl mount -b "$DEVICE" 2>&1) || MNT_LINE=""
  fi
  if [[ -n "$MNT_LINE" ]]; then
    TMP_MNT=$(printf '%s' "$MNT_LINE" | sed -n 's/.*\( at \| on \)\(\/[^ ]*\).*/\2/p')
    if [[ -z "$TMP_MNT" || ! -d "$TMP_MNT" ]]; then
      err "Could not determine udisks mount point. Raw output: $MNT_LINE"
      msg "Falling back to direct mount of $DEVICE to $MOUNTPOINT ..."
      if [[ "$READ_ONLY" -eq 1 ]]; then
        if mount -o ro "$DEVICE" "$MOUNTPOINT"; then
          chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$MOUNTPOINT" || true
        else
          err "Direct mount also failed for $DEVICE"
          exit 7
        fi
      else
        if mount "$DEVICE" "$MOUNTPOINT"; then
        chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$MOUNTPOINT" || true
        else
          err "Direct mount also failed for $DEVICE"
          exit 7
        fi
      fi
    else
      UDISKS_MNT="$TMP_MNT"
      mount --bind "$TMP_MNT" "$MOUNTPOINT"
      chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$MOUNTPOINT" || true
    fi
  else
    err "udisksctl failed to mount $DEVICE. Output: $MNT_LINE"
    msg "Attempting direct mount of $DEVICE to $MOUNTPOINT ..."
    if [[ "$READ_ONLY" -eq 1 ]]; then
      if mount -o ro "$DEVICE" "$MOUNTPOINT"; then
        chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$MOUNTPOINT" || true
      else
        err "Direct read-only mount failed for $DEVICE"
        exit 8
      fi
    else
      if mount "$DEVICE" "$MOUNTPOINT"; then
        chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$MOUNTPOINT" || true
      else
        err "Direct mount failed for $DEVICE"
        exit 8
      fi
    fi
  fi
else
  msg "Mounting via mount(8) to $MOUNTPOINT ..."
  mount "$DEVICE" "$MOUNTPOINT"
  chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$MOUNTPOINT" || true
fi

echo
msg "Mounted $DEVICE at $MOUNTPOINT"
msg ">>> $REAL_USER, perform your backup now. <<<"
msg "When finished, press Enter to unmount and restore the hardened state."
read -r

msg "Backup session closing…"
exit 0