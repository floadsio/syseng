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

# Function to update Bastille jails
update_jails() {
    echo "Updating packages in all Bastille jails..."
    sudo bastille list jail | while read -r jail; do
        if [ -n "$jail" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "Previewing update for jail: $jail"
                sudo bastille cmd "$jail" env PAGER=cat IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg update -n || {
                    echo "Error updating repository for jail $jail in dry-run mode. Skipping."
                    continue
                }
                sudo bastille cmd "$jail" env PAGER=cat IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg upgrade -n || {
                    echo "Error previewing package upgrade for jail $jail. Skipping."
                    continue
                }
                echo "Previewing autoremove for jail: $jail"
                sudo bastille cmd "$jail" env PAGER=cat IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg autoremove -n || {
                    echo "Error previewing autoremove for jail $jail. Skipping."
                    continue
                }
                echo "Previewing clean for jail: $jail"
                sudo bastille cmd "$jail" env PAGER=cat IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg clean -n || {
                    echo "Error previewing clean for jail $jail. Skipping."
                    continue
                }
            else
                echo "Updating packages for jail: $jail"
                sudo bastille cmd "$jail" env PAGER=cat IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg update -f || {
                    echo "Error updating repository for jail $jail. Skipping."
                    continue
                }
                sudo bastille cmd "$jail" env PAGER=cat IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg upgrade -y || {
                    echo "Error upgrading packages for jail $jail. Skipping."
                    continue
                }
                echo "Removing unnecessary packages for jail: $jail"
                sudo bastille cmd "$jail" env PAGER=cat IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg autoremove -y || {
                    echo "Error running autoremove for jail $jail. Skipping."
                    continue
                }
                echo "Cleaning up package cache for jail: $jail"
                sudo bastille cmd "$jail" env PAGER=cat IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg clean -a -y || {
                    echo "Error cleaning package cache for jail $jail. Skipping."
                    continue
                }
            fi
        else
            echo "Skipping invalid jail entry."
        fi
    done
}

# Dry-run behavior
if [ $DRY_RUN -eq 1 ]; then
    echo "Dry-run mode enabled. No changes will be made."
    echo "Fetching package updates..."
    pkg update -f
    echo "Previewing package upgrades..."
    pkg upgrade -n
    echo "Previewing FreeBSD update fetch..."
    freebsd-update fetch
    echo "Previewing package autoremove..."
    pkg autoremove -n
    echo "Previewing package clean-up..."
    pkg clean -n
    echo "Previewing Bastille jail updates..."
    update_jails
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

echo "Updating Bastille jails..."
update_jails

echo "Fetching and installing FreeBSD updates..."
freebsd-update fetch install

echo "System update completed successfully."