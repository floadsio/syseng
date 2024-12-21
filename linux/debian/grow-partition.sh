#!/bin/sh

# Script to grow a partition and resize its filesystem
# Usage: grow-partition.sh <disk> <partition_number> [--dry-run]

# Functions
log() {
    echo "[INFO] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

check_requirements() {
    command -v growpart >/dev/null 2>&1 || error "growpart is not installed. Install it with 'apt-get install cloud-guest-utils'."
    command -v resize2fs >/dev/null 2>&1 || error "resize2fs is not installed. Install it with 'apt-get install e2fsprogs'."
    command -v lsblk >/dev/null 2>&1 || error "lsblk is not installed. Install it with 'apt-get install util-linux'."
}

# Parse arguments
if [ "$#" -lt 2 ]; then
    error "Usage: $0 <disk> <partition_number> [--dry-run]"
fi

disk=$1
partition=$2
dry_run=false

if [ "$#" -eq 3 ] && [ "$3" = "--dry-run" ]; then
    dry_run=true
fi

partition_path="/dev/${disk}${partition}"

# Validate inputs
if [ ! -b "/dev/$disk" ]; then
    error "Disk /dev/$disk does not exist."
fi

if [ ! -b "$partition_path" ]; then
    error "Partition $partition_path does not exist."
fi

check_requirements

# Check sizes
current_size=$(lsblk -dn -b -o SIZE "/dev/$disk")
partition_size=$(lsblk -dn -b -o SIZE "$partition_path")

if [ "$current_size" -gt "$partition_size" ]; then
    log "Disk /dev/$disk has grown. Partition $partition_path needs resizing."

    if [ "$dry_run" = true ]; then
        log "[Dry-Run] Running: growpart --dry-run /dev/$disk $partition"
        growpart --dry-run "/dev/$disk" "$partition" || error "Dry-run of growpart failed for partition $partition_path."
        log "[Dry-Run] Filesystem resizing would be done with: resize2fs $partition_path"
    else
        log "Resizing partition $partition_path with growpart..."
        growpart "/dev/$disk" "$partition" || error "Failed to resize partition $partition_path."

        log "Resizing filesystem on $partition_path with resize2fs..."
        resize2fs "$partition_path" || error "Failed to resize filesystem on $partition_path."
    fi
else
    log "No resizing needed for $partition_path."
fi

log "Operation completed."
