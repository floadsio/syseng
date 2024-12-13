#!/bin/sh

#
# Usage
#
# % xtrabackup-s3.sh full [--dry-run] [--cleanup]       Make a full backup to S3
# % xtrabackup-s3.sh inc [--dry-run] [--cleanup]       Make an incremental backup to S3
# % xtrabackup-s3.sh restore <full-backup> <inc-backup-1> <inc-backup-2>
#

CFG_EXTRA_LSN_DIR="/var/backups/mysql_lsn"
CFG_HOSTNAME=$(hostname)
CFG_DATE=$(date +%Y-%m-%d_%H-%M-%S)
CFG_TIMESTAMP=$(date +%s)
CFG_INCREMENTAL=""

# Load the configuration file
CONFIG_FILE="$HOME/.xtrabackup-s3.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file $CONFIG_FILE not found."
    exit 1
fi

# Source the config file
# shellcheck source=/dev/null
. "$CONFIG_FILE"

# Validate mandatory configuration
if [ -z "$CFG_BUCKET_PATH" ]; then
    echo "ERROR: CFG_BUCKET_PATH is not set in $CONFIG_FILE."
    exit 1
fi

if [ -z "$CFG_CUTOFF_DAYS" ]; then
    echo "ERROR: CFG_CUTOFF_DAYS is not set in $CONFIG_FILE."
    exit 1
fi

# Calculate the cutoff date
CUTOFF_DATE=$(date -d "$CFG_CUTOFF_DAYS days ago" +%Y-%m-%d)

OPT_BACKUP_TYPE="${1:-}"
OPT_DRY_RUN=0
OPT_CLEANUP=0

# Parse arguments
shift
while [ "$1" != "" ]; do
    case "$1" in
        --dry-run) OPT_DRY_RUN=1 ;;
        --cleanup) OPT_CLEANUP=1 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [ "${OPT_BACKUP_TYPE}" != "full" ] && [ "${OPT_BACKUP_TYPE}" != "inc" ] && [ "${OPT_BACKUP_TYPE}" != "restore" ]; then
    echo "Usage: $0 {full|inc} [--dry-run] [--cleanup]"
    echo "       $0 restore <full-backup> <inc-backup-1> <inc-backup-2>"
    exit 1
fi

cleanup_old_backups() {
    echo "Starting cleanup of old backups..."

    # Check if the backup path exists
    if ! mc ls "$CFG_BUCKET_PATH" >/dev/null 2>&1; then
        echo "ERROR: Path not found: $CFG_BUCKET_PATH"
        exit 1
    fi

    # Find and process folders
    mc ls "$CFG_BUCKET_PATH" | awk '{print $NF}' | while read -r FOLDER; do
        FOLDER_DATE=$(echo "$FOLDER" | cut -d_ -f1)

        if [ "$FOLDER_DATE" \< "$CUTOFF_DATE" ]; then
            if [ "$OPT_DRY_RUN" -eq 1 ]; then
                echo "Would delete: $FOLDER"
            else
                echo "Deleting: $FOLDER"
                mc rm -r --force "$CFG_BUCKET_PATH/$FOLDER"
            fi
        else
            echo "$FOLDER is newer"
        fi
    done

    echo "Cleanup completed."
}

# Backup (full or incremental)
if [ "${OPT_BACKUP_TYPE}" = "full" ] || [ "${OPT_BACKUP_TYPE}" = "inc" ]; then
    if [ ! -d "${CFG_EXTRA_LSN_DIR}" ]; then
        echo "Creating local LSN directory: ${CFG_EXTRA_LSN_DIR}"
        mkdir -p "${CFG_EXTRA_LSN_DIR}"
    fi

    if [ "${OPT_BACKUP_TYPE}" = "inc" ]; then
        if [ ! -f "${CFG_EXTRA_LSN_DIR}/xtrabackup_checkpoints" ]; then
            echo "No previous full backup found. Please run a full backup first."
            exit 1
        fi
        CFG_INCREMENTAL="--incremental-basedir=${CFG_EXTRA_LSN_DIR}"
    fi

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "Dry run: xtrabackup --backup ${CFG_INCREMENTAL} --extra-lsndir=${CFG_EXTRA_LSN_DIR} --stream=xbstream --target-dir=${CFG_EXTRA_LSN_DIR} | \
    xbcloud put ${CFG_BUCKET_PATH}${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"
    else
        xtrabackup --backup ${CFG_INCREMENTAL} --extra-lsndir=${CFG_EXTRA_LSN_DIR} --stream=xbstream --target-dir=${CFG_EXTRA_LSN_DIR} | \
    xbcloud put ${CFG_BUCKET_PATH}${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}

        if [ $? -ne 0 ]; then
            echo "Backup failed!"
            exit 1
        fi

        echo "$(date '+%Y-%m-%d %H:%M:%S:%s'): Backup completed successfully"
    fi

    # Cleanup old backups if the --cleanup option is provided
    if [ "$OPT_CLEANUP" -eq 1 ]; then
        cleanup_old_backups
    fi

# Restore backups
elif [ "${OPT_BACKUP_TYPE}" = "restore" ]; then
    echo "Do a restore..."
fi

exit 0