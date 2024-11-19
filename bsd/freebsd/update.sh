#!/bin/sh

PAGER=cat
IGNORE_OSVERSION=yes
DRY_RUN=0

# Function to display usage information
usage() {
    echo "Usage: $0 [--dry-run]"
    echo "  --dry-run   Simulate updates without applying them"
    exit 1
}

# Parse command-line arguments
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=1
            ;;
        *)
            usage
            ;;
    esac
done

# Dry-run behavior
if [ $DRY_RUN -eq 1 ]; then
    echo "Dry-run mode enabled. No changes will be made."
    echo "Fetching package updates..."
    yes | pkg update -f
    echo "Previewing package upgrades..."
    pkg upgrade -n
    echo "Previewing FreeBSD update fetch..."
    freebsd-update fetch
    echo "Dry-run completed."
    exit 0
fi

# Actual update process
echo "Updating package repository..."
yes | pkg update -f

echo "Upgrading packages..."
pkg upgrade -y

echo "Fetching and installing FreeBSD updates..."
freebsd-update fetch install

echo "System update completed successfully."