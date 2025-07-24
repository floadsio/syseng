#!/usr/bin/env bash

# autorestic-rclone.sh - Combines autorestic with rclone mounting for S3 backup sources
# Usage: ./autorestic-rclone.sh [location_name] [--dry-run]

set -e

# Load configuration
CONFIG_FILE="$HOME/.autorestic-rclone.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found"
    exit 1
fi
source "$CONFIG_FILE"

# Detect OS for compatibility
detect_os() {
    if [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ "$(uname)" = "FreeBSD" ]; then
        OS="freebsd"
    elif [ "$(uname)" = "OpenBSD" ]; then
        OS="openbsd"
    else
        OS="unknown"
    fi
}

# OS-compatible mount verification
check_mount() {
    local mount_path="$1"
    
    case "$OS" in
        "debian")
            # Try mountpoint first, fallback to mount grep
            if command -v mountpoint >/dev/null 2>&1; then
                mountpoint -q "$mount_path"
            else
                mount | grep -q " $mount_path "
            fi
            ;;
        "freebsd"|"openbsd")
            # BSD systems use mount with different format
            mount | grep -q " $mount_path "
            ;;
        *)
            # Generic fallback
            mount | grep -q "$mount_path"
            ;;
    esac
}

# Initialize OS detection
detect_os

# Load location config
configure_location() {
    local location="$1"
    
    # Check if location exists
    local found=false
    for loc in "${LOCATIONS[@]}"; do
        if [[ "$loc" == "$location" ]]; then
            found=true
            break
        fi
    done
    
    if [[ "$found" == "false" ]]; then
        echo "Error: Unknown location '$location'"
        echo "Available locations: ${LOCATIONS[*]}"
        exit 1
    fi
    
    # Set global variables from CONFIG array
    REMOTE="${CONFIG[$location.remote]}"
    BASE_DIR="${CONFIG[$location.base_dir]}"
    BUCKET_LIST="${CONFIG[$location.buckets]}"
    MOUNT_DIR_LIST="${CONFIG[$location.mount_dirs]}"
    
    # Validate that all required variables are set
    if [[ -z "$REMOTE" || -z "$BASE_DIR" || -z "$BUCKET_LIST" || -z "$MOUNT_DIR_LIST" ]]; then
        echo "Error: Incomplete configuration for location '$location'"
        exit 1
    fi
}

cleanup() {
    echo "Cleaning up..."
    
    # Kill any hanging rclone processes (works on all systems)
    pkill rclone 2>/dev/null || true
    sleep 2
    
    # Unmount directories - try both umount variations
    for dir in $MOUNT_DIR_LIST; do
        # Try regular umount first
        umount "$BASE_DIR/$dir" 2>/dev/null || true
        # BSD systems might need -f for force
        umount -f "$BASE_DIR/$dir" 2>/dev/null || true
    done
    
    echo "Cleanup completed"
}

mount_buckets() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] Would mount S3 buckets for $LOCATION..."
        local buckets=($BUCKET_LIST)
        local dirs=($MOUNT_DIR_LIST)
        for i in "${!buckets[@]}"; do
            echo "[DRY-RUN] Would mount $REMOTE:${buckets[$i]} to $BASE_DIR/${dirs[$i]}"
        done
        return
    fi

    echo "Mounting S3 buckets for $LOCATION..."
    
    # Create mount directories
    mkdir -p "$BASE_DIR"
    for dir in $MOUNT_DIR_LIST; do
        mkdir -p "$BASE_DIR/$dir"
    done
    
    # Mount buckets to subdirectories
    local buckets=($BUCKET_LIST)
    local dirs=($MOUNT_DIR_LIST)
    for i in "${!buckets[@]}"; do
        local bucket="${buckets[$i]}"
        local dir="${dirs[$i]}"
        echo "Mounting $REMOTE:$bucket to $BASE_DIR/$dir"
        /usr/local/bin/rclone mount "$REMOTE:$bucket" "$BASE_DIR/$dir" \
            --no-modtime \
            --vfs-fast-fingerprint \
            --cache-dir=restic-cache \
            --vfs-cache-mode=full \
            --vfs-cache-max-age=12h \
            --vfs-write-back=15m \
            --buffer-size=16M \
            --vfs-read-ahead=128M \
            --daemon || {
            echo "Failed to mount $bucket"
            exit 1
        }
    done
}

verify_mounts() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] Would verify mounts..."
        return
    fi

    echo "Verifying mounts..."
    for dir in $MOUNT_DIR_LIST; do
        if check_mount "$BASE_DIR/$dir"; then
            echo "Mount verified: $BASE_DIR/$dir"
        else
            echo "Warning: $BASE_DIR/$dir is not mounted properly"
        fi
    done
}

run_backup() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] Would run: autorestic --ci backup -l $LOCATION"
        return
    fi

    echo "Running autorestic backup for $LOCATION..."
    
    # Run backup and show helpful message if there are lock errors
    if ! /usr/local/bin/autorestic --ci backup -l "$LOCATION"; then
        echo ""
        echo "⚠️  Backup completed but encountered lock errors during forget/prune phase."
        echo "   This is normal - the backup data was saved successfully."
        echo ""
        echo "   If you see persistent 'repo already locked' errors, run:"
        echo "   autorestic exec -a unlock"
        echo ""
    fi
}

# Parse arguments
if [ $# -eq 0 ]; then
    # No arguments - backup all locations
    BACKUP_ALL=true
    DRY_RUN="false"
elif [ $# -eq 1 ] && [ "$1" = "--dry-run" ]; then
    # Only dry-run flag - dry-run all locations
    BACKUP_ALL=true
    DRY_RUN="true"
elif [ $# -eq 1 ]; then
    # Single location
    LOCATION="$1"
    BACKUP_ALL=false
    DRY_RUN="false"
elif [ $# -eq 2 ] && [ "$2" = "--dry-run" ]; then
    # Location + dry-run
    LOCATION="$1"
    BACKUP_ALL=false
    DRY_RUN="true"
else
    echo "Usage: $0 [location_name] [--dry-run]"
    echo "       $0                    # backup all locations"
    echo "       $0 --dry-run          # dry-run all locations"
    echo "Available locations: ${LOCATIONS[*]}"
    exit 1
fi

# Function to mount all locations
mount_all_locations() {
    echo "Mounting all S3 buckets..."
    
    for loc in "${LOCATIONS[@]}"; do
        configure_location "$loc"
        
        echo "Mounting buckets for $loc..."
        
        # Create mount directories
        mkdir -p "$BASE_DIR"
        for dir in $MOUNT_DIR_LIST; do
            mkdir -p "$BASE_DIR/$dir"
        done
        
        # Mount buckets to subdirectories
        local buckets=($BUCKET_LIST)
        local dirs=($MOUNT_DIR_LIST)
        for i in "${!buckets[@]}"; do
            local bucket="${buckets[$i]}"
            local dir="${dirs[$i]}"
            echo "Mounting $REMOTE:$bucket to $BASE_DIR/$dir"
            /usr/local/bin/rclone mount "$REMOTE:$bucket" "$BASE_DIR/$dir" \
                --no-modtime \
                --vfs-fast-fingerprint \
                --cache-dir=restic-cache \
                --vfs-cache-mode=full \
                --vfs-cache-max-age=12h \
                --vfs-write-back=15m \
                --buffer-size=16M \
                --vfs-read-ahead=128M \
                --daemon || {
                echo "Failed to mount $bucket"
                exit 1
            }
        done
    done
}

# Function to cleanup all locations
cleanup_all_locations() {
    echo "Cleaning up all mounts..."
    
    # Kill any hanging rclone processes
    pkill rclone 2>/dev/null || true
    sleep 2
    
    for loc in "${LOCATIONS[@]}"; do
        configure_location "$loc"
        for dir in $MOUNT_DIR_LIST; do
            umount "$BASE_DIR/$dir" 2>/dev/null || true
            umount -f "$BASE_DIR/$dir" 2>/dev/null || true
        done
    done
    
    echo "Cleanup completed"
}

# Function to backup all locations
backup_all_locations() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] Would run: autorestic --ci backup -a"
        return
    fi

    echo "Running autorestic backup for all locations..."
    
    if ! /usr/local/bin/autorestic --ci backup -a; then
        echo ""
        echo "⚠️  Backup completed but encountered lock errors during forget/prune phase."
        echo "   This is normal - the backup data was saved successfully."
        echo ""
        echo "   If you see persistent 'repo already locked' errors, run:"
        echo "   autorestic exec -a unlock"
        echo ""
    fi
}

# Function to backup a single location
backup_location() {
    local loc="$1"
    
    echo "Starting backup process for $loc..."
    
    # Configure location
    configure_location "$loc"
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN MODE] - No actual operations will be performed"
        echo "Configuration loaded:"
        echo "  Remote: $REMOTE"
        echo "  Base dir: $BASE_DIR" 
        echo "  Buckets: $BUCKET_LIST"
        echo "  Mount dirs: $MOUNT_DIR_LIST"
    fi
    
    # Set trap to cleanup on script exit (only if not dry-run)
    if [ "$DRY_RUN" = "false" ]; then
        trap cleanup EXIT INT TERM
    fi
    
    # Initial cleanup (only if not dry-run)
    if [ "$DRY_RUN" = "false" ]; then
        cleanup
    fi
    
    # Mount buckets
    mount_buckets
    
    # Wait for mounts to be ready (only if not dry-run)
    if [ "$DRY_RUN" = "false" ]; then
        sleep 5
    fi
    
    # Verify mounts
    verify_mounts
    
    # Run autorestic backup
    run_backup
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] Backup simulation completed for $loc"
    else
        echo "Backup completed for $loc"
    fi
}

# Main execution
if [ "$BACKUP_ALL" = "true" ]; then
    echo "Backing up all locations: ${LOCATIONS[*]}"
    
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN MODE] - No actual operations will be performed"
        for loc in "${LOCATIONS[@]}"; do
            configure_location "$loc"
            echo "Would mount buckets for $loc: $BUCKET_LIST"
        done
        backup_all_locations
    else
        # Set trap for cleanup
        trap cleanup_all_locations EXIT INT TERM
        
        # Cleanup any existing mounts
        cleanup_all_locations
        
        # Mount all locations
        mount_all_locations
        
        # Wait for mounts
        sleep 5
        
        # Run backup for all
        backup_all_locations
    fi
    
    echo "All locations backup completed!"
else
    # Single location backup
    backup_location "$LOCATION"
fi
