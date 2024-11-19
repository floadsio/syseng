#!/bin/sh

export PAGER=cat
export IGNORE_OSVERSION=yes

DRY_RUN=0

# Function to display usage information
usage() {
    echo "Usage: $0 [--dry-run | -n]"
    echo "  --dry-run, -n   Simulate updates without applying them"
    exit 1
}

# Parse command-line arguments
for arg in "$@"; do
    case $arg in
        --dry-run|-n)
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
    pkg update -n -f
    echo "Previewing package upgrades..."
    pkg upgrade -n
    echo "Previewing FreeBSD update fetch..."
    freebsd-update fetch
    echo "Previewing package autoremove..."
    pkg autoremove -n
    echo "Previewing package clean-up..."
    pkg clean -n
    echo "Dry-run completed."
    exit 0
fi

# Actual update process
echo "Updating package repository..."
pkg update -f

echo "Upgrading packages..."
pkg upgrade -y

echo "Removing unnecessary packages..."
pkg autoremove -y

echo "Cleaning up package cache..."
pkg clean -a -y

echo "Fetching and installing FreeBSD updates..."
freebsd-update fetch install

echo "System update completed successfully."
