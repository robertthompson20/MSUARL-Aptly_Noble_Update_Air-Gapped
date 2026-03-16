#!/bin/bash

# Script to mount a selected device to /mnt/PSTPatches

echo "Available block devices:"
echo "========================"
lsblk

echo ""
echo "Please enter the device to mount (e.g., sdb1, sdc1, etc.):"
read -p "Device (without /dev/): " device

# Validate input
if [ -z "$device" ]; then
    echo "Error: No device specified"
    exit 1
fi

# Check if device exists
if [ ! -b "/dev/$device" ]; then
    echo "Error: Device /dev/$device does not exist"
    exit 1
fi

# Check if mount point exists, create if it doesn't
if [ ! -d "/mnt/PSTPatches" ]; then
    echo "Creating mount point /mnt/PSTPatches..."
    sudo mkdir -p /mnt/PSTPatches
fi

# Check if mount point is already mounted
if mountpoint -q /mnt/PSTPatches; then
    echo "Warning: /mnt/PSTPatches is already mounted"
    read -p "Do you want to unmount it first? (y/n): " unmount
    if [ "$unmount" = "y" ] || [ "$unmount" = "Y" ]; then
        echo "Unmounting /mnt/PSTPatches..."
        sudo umount /mnt/PSTPatches
    else
        echo "Aborted"
        exit 1
    fi
fi

# Confirm before mounting
echo ""
echo "About to mount /dev/$device to /mnt/PSTPatches with read-write (rw) permissions"
read -p "Proceed? (y/n): " confirm

if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    echo "Mounting /dev/$device to /mnt/PSTPatches (rw)..."
    sudo mount -o rw /dev/$device /mnt/PSTPatches

    if [ $? -eq 0 ]; then
        echo "Successfully mounted /dev/$device to /mnt/PSTPatches"
        echo ""
        echo "Mount details:"
        mount | grep /mnt/PSTPatches
        echo ""
        df -h /mnt/PSTPatches
    else
        echo "Error: Failed to mount /dev/$device"
        exit 1
    fi
else
    echo "Mount cancelled"
    exit 0
fi
