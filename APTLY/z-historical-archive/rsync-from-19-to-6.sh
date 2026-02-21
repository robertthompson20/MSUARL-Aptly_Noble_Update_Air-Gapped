#!/bin/bash

# Rsync script to sync Aptly packages from ARL19 to ARL6 when PSTPatches ExtHD has been mounted by msuarladmin.
# Syncs /mnt/aptly/public/ to the remote PSTPatches directory
# Uses SSH key authentication for fully automated execution

REMOTE_USER="msuarladmin"
REMOTE_HOST="192.168.200.222"
REMOTE_PATH="/media/msuarladmin/PSTPatches/apt-mirror/"
LOCAL_PATH="/mnt/aptly/public/"
LOG_FILE="$HOME/rsync.log"
SSH_KEY="$HOME/.ssh/id_ed25519"

rsync -rlDvh --info=progress2 -e "ssh -i $SSH_KEY" \
  "$LOCAL_PATH" \
  "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PATH" \
  | tee "$LOG_FILE"
