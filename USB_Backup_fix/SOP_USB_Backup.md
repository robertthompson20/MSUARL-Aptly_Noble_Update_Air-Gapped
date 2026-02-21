# Standard Operating Procedure: USB Backup on STIG-Compliant Systems

## Purpose
These scripts provide temporary, controlled access to USB mass storage devices on STIG-hardened Ubuntu systems where USB storage is normally disabled for security compliance.

## Overview
The USB backup system consists of two scripts:
- **install_usb_backup.sh** - One-time installation script (run by system administrator)
- **usb-backup-session.sh** - Session script for authorized operators to temporarily mount USB devices

---

## Installation (Administrator)

### Prerequisites
- Root/sudo access
- STIG-compliant Ubuntu system with USB storage disabled

### Installation Steps

1. **Run the installer as root:**
   ```bash
   sudo ./install_usb_backup.sh
   ```

2. **The installer will:**
   - Install session script to `/usr/local/sbin/usb-backup-session.sh`
   - Create `usbbackup` security group
   - Create authorization allow-list at `/etc/usb-backup-allow.list`
   - Configure sudoers to permit group access

3. **Authorize users (required for each operator):**
   ```bash
   # Add user to usbbackup group
   sudo usermod -aG usbbackup <username>
   
   # Add user to allow-list
   echo <username> | sudo tee -a /etc/usb-backup-allow.list
   ```

4. **User must log out and back in** for group membership to take effect

---

## Usage (Authorized Operators)

### Prerequisites
- User must be in both `usbbackup` group AND `/etc/usb-backup-allow.list`
- USB device to mount

### Backup Session Steps

1. **Start the backup session:**
   ```bash
   sudo /usr/local/sbin/usb-backup-session.sh
   ```
   
   *Optional: Specify device directly:*
   ```bash
   sudo /usr/local/sbin/usb-backup-session.sh /dev/sdb1
   ```

2. **The script will:**
   - Verify your authorization
   - Temporarily load USB storage kernel modules
   - Detect available USB devices
   - Prompt you to select a device if not specified

3. **Device Selection:**
   - If auto-detected devices are shown, enter the full device path (e.g., `/dev/sdb1`)
   - **Important:** Use a partition (e.g., `/dev/sdb1`), not the whole disk (`/dev/sdb`)
   - Read-only devices will be mounted read-only automatically

4. **Perform Your Backup:**
   - Device will be mounted at `/media/<username>/backup-YYYYMMDD-HHMMSS`
   - Copy files to/from the USB device as needed
   - **Do not close the terminal** during the backup

5. **Complete the Session:**
   - When finished, press `Enter` in the terminal
   - Script will automatically:
     - Unmount the USB device
     - Remove USB storage modules
     - Restore STIG-compliant hardened state

---

## Security Features

### Dual Authorization
Both conditions must be met for access:
- User is member of `usbbackup` group (via `usermod`)
- User is listed in `/etc/usb-backup-allow.list` file

### Automatic Cleanup
The session script ensures security restoration even if interrupted:
- Trap handlers for EXIT, INT, and TERM signals
- Automatic unmounting of devices
- Automatic removal of USB storage modules
- Restore hardened state on any exit condition

### Session Isolation
- Each session is time-boxed (manual termination required)
- USB modules only loaded for active session duration
- Unique timestamped mount points per session

---

## Troubleshooting

### "User not in allow-list" Error
**Solution:** Administrator must add user to allow-list:
```bash
echo <username> | sudo tee -a /etc/usb-backup-allow.list
```

### "User not member of group usbbackup" Error
**Solution:** Administrator must add user to group and user must re-login:
```bash
sudo usermod -aG usbbackup <username>
```

### "No USB devices detected" Error
**Solutions:**
1. Ensure USB device is fully inserted
2. Wait 5-10 seconds for device recognition
3. Press Enter when prompted to re-scan
4. Check device with `lsusb` command

### "Failed to load usb-storage" Error
**Possible Causes:**
- Kernel module is blacklisted beyond what script can override
- Kernel doesn't include USB storage support
- Contact system administrator

### Device Won't Mount
**Solutions:**
1. Verify device path is correct (use `/dev/sdb1` not `/dev/sdb`)
2. Ensure filesystem is supported (ext4, FAT32, NTFS, etc.)
3. Check if device is already mounted elsewhere
4. Verify device is not corrupted

---

## Administrative Tasks

### View Authorized Users
```bash
sudo cat /etc/usb-backup-allow.list
sudo getent group usbbackup
```

### Add User Authorization
```bash
sudo usermod -aG usbbackup <username>
echo <username> | sudo tee -a /etc/usb-backup-allow.list
```

### Remove User Authorization
```bash
# Remove from group
sudo gpasswd -d <username> usbbackup

# Remove from allow-list
sudo sed -i '/^<username>$/d' /etc/usb-backup-allow.list
```

### Uninstall
```bash
sudo rm /usr/local/sbin/usb-backup-session.sh
sudo rm /etc/sudoers.d/usb-backup-session
sudo rm /etc/usb-backup-allow.list
sudo groupdel usbbackup
```

---

## Important Notes

- **Security:** Never leave a backup session running unattended
- **Compliance:** System returns to STIG-compliant state after each session
- **Logging:** Session activities are logged with tag `usb-backup-session`
- **Permissions:** Mount points are owned by the operator, not root
- **Read-Only:** Devices detected as read-only will be mounted read-only
- **No Background Sessions:** Each session must be completed before starting another

---

## Exit Codes Reference

| Code | Meaning |
|------|---------|
| 0 | Success - normal completion |
| 1 | Must run with sudo |
| 2 | Authorization failed (not in group or allow-list) |
| 3 | Failed to load USB storage module |
| 4 | Specified device is not a block device |
| 5 | No USB devices detected |
| 6 | Invalid device selection |
| 7-8 | Mount operation failed |
| 130 | Interrupted by signal (Ctrl+C) |

---

**Document Version:** 1.0  
**Last Updated:** February 2026  
**Maintainer:** System Administrator
