#!/usr/bin/env bash
set -euo pipefail

# Must run as root
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This installer must be run as root." >&2
  exit 1
fi

# Resolve this installer's directory and install the session script from the same dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [[ ! -f "$SCRIPT_DIR/usb-backup-session.sh" ]]; then
  echo "Cannot find usb-backup-session.sh in $SCRIPT_DIR" >&2
  exit 1
fi

# 1) Install session script
install -o root -g root -m 0755 "$SCRIPT_DIR/usb-backup-session.sh" /usr/local/sbin/usb-backup-session.sh

# 2) Create group used to gate sudo access (if missing)
if ! getent group usbbackup >/dev/null; then
  groupadd -r usbbackup
fi

# 3) Create allow-list (final per-user authorization)
if [[ ! -f /etc/usb-backup-allow.list ]]; then
  install -o root -g root -m 0640 /dev/null /etc/usb-backup-allow.list
fi

# 4) Sudoers drop-in: allow the group to run the session tool
SUDOERS=/etc/sudoers.d/usb-backup-session
cat >"$SUDOERS" <<'EOF'
%usbbackup ALL=(root) NOPASSWD: /usr/local/sbin/usb-backup-session.sh
EOF
chmod 0440 "$SUDOERS"

# 5) Validate sudoers
if command -v visudo >/dev/null 2>&1; then
  if ! visudo -cf "$SUDOERS"; then
    echo "visudo reported a syntax error in $SUDOERS; aborting." >&2
    rm -f "$SUDOERS"
    exit 1
  fi
fi

cat <<'MSG'
Installation complete.

Next steps:
  - Add operator(s) to group 'usbbackup':
    sudo usermod -aG usbbackup <user>
  - Add operator(s) to allow-list:
    echo <user> | sudo tee -a /etc/usb-backup-allow.list
  - Operator usage:
    sudo /usr/local/sbin/usb-backup-session.sh
MSG

exit 0