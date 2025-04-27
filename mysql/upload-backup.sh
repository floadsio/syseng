#!/bin/sh

# Usage:
# ./upload-backup.sh <backup-folder> [--dry-run|-n]

BACKUP_DIR=""
OPT_DRY_RUN=0

# Set hostname early
CFG_HOSTNAME=$(hostname)

# Parse arguments
while [ "$1" != "" ]; do
    case "$1" in
        -n|--dry-run) OPT_DRY_RUN=1 ;;
        -h|--help)
            echo "Usage: $0 <backup-folder> [--dry-run|-n]"
            echo ""
            echo "Arguments:"
            echo "  <backup-folder>    Path to the local backup directory to upload"
            echo ""
            echo "Options:"
            echo "  -n, --dry-run      Show what would be uploaded, but do not perform upload"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
        *)
            if [ -z "$BACKUP_DIR" ]; then
                BACKUP_DIR="$1"
            else
                echo "ERROR: Unexpected argument: $1"
                exit 1
            fi
            ;;
    esac
    shift
done

# Validate arguments
if [ -z "$BACKUP_DIR" ]; then
    echo "ERROR: No backup folder specified."
    echo "Use --help for usage instructions."
    exit 2
fi

if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Backup directory does not exist: $BACKUP_DIR"
    exit 3
fi

# Load config
CONFIG_FILE="$HOME/.xtrabackup-s3.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file $CONFIG_FILE not found."
    exit 4
fi

# shellcheck source=/dev/null
. "$CONFIG_FILE"

if [ -z "$CFG_MC_BUCKET_PATH" ]; then
    echo "ERROR: CFG_MC_BUCKET_PATH is not set in $CONFIG_FILE."
    exit 5
fi

# Prepare
BACKUP_NAME=$(basename "$BACKUP_DIR")

echo "Preparing to upload backup:"
echo "  Local: $BACKUP_DIR"
echo "  Remote: s3://${CFG_MC_BUCKET_PATH}/${BACKUP_NAME}"

# Action
if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo ""
    echo "[DRY RUN] Would execute:"
    echo "mc mirror --overwrite \"$BACKUP_DIR\" \"${CFG_MC_BUCKET_PATH}/${BACKUP_NAME}\""
else
    mc mirror --overwrite "$BACKUP_DIR" "${CFG_MC_BUCKET_PATH}/${BACKUP_NAME}"

    if [ $? -eq 0 ]; then
        echo "✅ Backup uploaded successfully."
    else
        echo "❌ Backup upload failed."
        exit 6
    fi
fi

exit 0
