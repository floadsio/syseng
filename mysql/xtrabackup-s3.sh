#!/bin/sh

#
# Usage
#
# % xtrabackup-s3.sh full [--dry-run] [--cleanup]       Make a full backup to S3
# % xtrabackup-s3.sh inc [--dry-run] [--cleanup]       Make an incremental backup to S3
# % xtrabackup-s3.sh restore <full-backup> [--dry-run] Restore a full backup from S3
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
if [ -z "$CFG_MC_BUCKET_PATH" ]; then
    echo "ERROR: CFG_MC_BUCKET_PATH is not set in $CONFIG_FILE."
    exit 1
fi

if [ -z "$CFG_BUCKET_PATH" ]; then
    echo "ERROR: CFG_BUCKET_PATH is not set in $CONFIG_FILE."
    exit 1
fi

if [ -z "$CFG_CUTOFF_DAYS" ]; then
    echo "ERROR: CFG_CUTOFF_DAYS is not set in $CONFIG_FILE."
    exit 1
fi

# Extract S3 endpoint and encryption key from the configuration
S3_ENDPOINT=$(awk -F'=' '/^s3-endpoint/ {print $2; exit}' /root/.my.cnf | xargs)
DECRYPT_KEY=$(awk -F'=' '/^encrypt-key/ {print $2; exit}' /root/.my.cnf | xargs)

OPT_BACKUP_TYPE="${1:-}"
OPT_DRY_RUN=0
OPT_CLEANUP=0

# Parse arguments
shift
while [ "$1" != "" ]; do
    case "$1" in
        --dry-run) OPT_DRY_RUN=1 ;;
        --cleanup) OPT_CLEANUP=1 ;;
        *) BACKUP_ARGUMENTS="$BACKUP_ARGUMENTS $1" ;;
    esac
    shift
done

if [ "${OPT_BACKUP_TYPE}" != "full" ] && [ "${OPT_BACKUP_TYPE}" != "inc" ] && [ "${OPT_BACKUP_TYPE}" != "restore" ]; then
    echo "Usage: $0 {full|inc} [--dry-run] [--cleanup]"
    echo "       $0 restore <full-backup> [--dry-run]"
    exit 1
fi

cleanup_old_backups() {
    echo "Starting cleanup of old backups..."

    # Check if the backup path exists
    if ! mc ls "$CFG_MC_BUCKET_PATH" >/dev/null 2>&1; then
        echo "ERROR: Path not found: $CFG_MC_BUCKET_PATH"
        exit 1
    fi

    # Calculate the cutoff date dynamically based on CFG_CUTOFF_DAYS
    if [ -z "$CFG_CUTOFF_DAYS" ]; then
        echo "ERROR: CFG_CUTOFF_DAYS is not set."
        exit 1
    fi
    CUTOFF_DATE=$(date -d "$CFG_CUTOFF_DAYS days ago" +%Y-%m-%d)
    echo "Cutoff date for cleanup: $CUTOFF_DATE"

    # Find and process folders
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | while read -r FOLDER; do
        # Trim whitespace
        FOLDER=$(echo "$FOLDER" | xargs)

        # Extract folder date
        FOLDER_DATE=$(echo "$FOLDER" | cut -d_ -f1)

        # Validate folder date format (YYYY-MM-DD)
        if ! echo "$FOLDER_DATE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            echo "Skipping folder with invalid date format: $FOLDER"
            continue
        fi

        # Compare folder date with cutoff date
        if [ "$FOLDER_DATE" \< "$CUTOFF_DATE" ]; then
            if [ "$OPT_DRY_RUN" -eq 1 ]; then
                echo "Would delete: $FOLDER"
            else
                echo "Deleting: $FOLDER"
                # mc rm -r --force "$CFG_MC_BUCKET_PATH/$FOLDER"
                mc rb --force "$CFG_MC_BUCKET_PATH/$FOLDER"
            fi
        else
            DAYS_NEWER=$(( ( $(date -d "$FOLDER_DATE" +%s) - $(date -d "$CUTOFF_DATE" +%s) ) / 86400 ))
            echo "Folder $FOLDER is $DAYS_NEWER days newer than the cutoff date."
        fi
    done

    echo "Cleanup completed."
}

generate_report() {
    echo "Generating backup report..."
    mc du "$CFG_MC_BUCKET_PATH" | awk '{print "Total Size: " $1 "\nTotal Objects: " $2 "\nPath: " $3}'
}

# Backup (full or incremental)
if [ "${OPT_BACKUP_TYPE}" = "full" ] || [ "${OPT_BACKUP_TYPE}" = "inc" ]; then
    if [ "${OPT_BACKUP_TYPE}" = "inc" ]; then
        if [ ! -d "${CFG_EXTRA_LSN_DIR}" ]; then
            echo "Creating local LSN directory: ${CFG_EXTRA_LSN_DIR}"
            mkdir -p "${CFG_EXTRA_LSN_DIR}"
        fi

        if [ ! -f "${CFG_EXTRA_LSN_DIR}/xtrabackup_checkpoints" ]; then
            echo "No previous full backup found. Please run a full backup first."
            exit 1
        fi
        CFG_INCREMENTAL="--incremental-basedir=${CFG_EXTRA_LSN_DIR}"

        if [ "$OPT_DRY_RUN" -eq 1 ]; then
            echo "Dry run: xtrabackup --backup ${CFG_INCREMENTAL} --extra-lsndir=${CFG_EXTRA_LSN_DIR} --stream=xbstream --target-dir=${CFG_EXTRA_LSN_DIR} | \
    xbcloud put ${CFG_BUCKET_PATH}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"
        else
            xtrabackup --backup ${CFG_INCREMENTAL} --extra-lsndir="${CFG_EXTRA_LSN_DIR}" --stream=xbstream --target-dir="${CFG_EXTRA_LSN_DIR}" | \
        xbcloud put "${CFG_BUCKET_PATH}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"

            if [ $? -ne 0 ]; then
                echo "Incremental backup failed!"
                exit 1
            fi

            echo "$(date '+%Y-%m-%d %H:%M:%S:%s'): Incremental backup completed successfully"
        fi
    else
        # Full backup logic (adapted)
        if [ -n "$CFG_LOCAL_BACKUP_DIR" ]; then
            LOCAL_BACKUP_SUBDIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"
            echo "Starting full backup to local directory: $LOCAL_BACKUP_SUBDIR"

            if [ "$OPT_DRY_RUN" -eq 1 ]; then
                echo "Dry run: Would run xtrabackup --backup --extra-lsndir=$LOCAL_BACKUP_SUBDIR --target-dir=$LOCAL_BACKUP_SUBDIR"
                echo "Dry run: Would sync $LOCAL_BACKUP_SUBDIR to $CFG_MC_BUCKET_PATH/"
                echo "Dry run: Would prune old backups in $CFG_LOCAL_BACKUP_DIR"
            else
                mkdir -p "$LOCAL_BACKUP_SUBDIR"

                KEEP_COUNT="${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}"
                echo "Pruning old local backups in $CFG_LOCAL_BACKUP_DIR (keeping latest $KEEP_COUNT)..."
                find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort | head -n -"$KEEP_COUNT" | while read -r OLD; do
                    echo "Removing old backup: $OLD"
                    rm -rf "$OLD"
                done

                xtrabackup --backup \
                    --extra-lsndir="$LOCAL_BACKUP_SUBDIR" \
                    --target-dir="$LOCAL_BACKUP_SUBDIR"

                if [ $? -ne 0 ]; then
                    echo "Full backup failed!"
                    exit 1
                fi

                echo "$(date '+%Y-%m-%d %H:%M:%S:%s'): Local full backup completed successfully"

                echo "Syncing local backup to S3..."
                mc mirror --retry --overwrite "$LOCAL_BACKUP_SUBDIR" "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_SUBDIR")"
            fi
        else
            echo "CFG_LOCAL_BACKUP_DIR not set. Streaming full backup directly to S3."

            if [ ! -d "${CFG_EXTRA_LSN_DIR}" ]; then
                echo "Creating local LSN directory: ${CFG_EXTRA_LSN_DIR}"
                mkdir -p "${CFG_EXTRA_LSN_DIR}"
            fi

            if [ "$OPT_DRY_RUN" -eq 1 ]; then
                echo "Dry run: xtrabackup --backup --extra-lsndir=${CFG_EXTRA_LSN_DIR} --stream=xbstream --target-dir=${CFG_EXTRA_LSN_DIR} | \
    xbcloud put ${CFG_BUCKET_PATH}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"
            else
                xtrabackup --backup --extra-lsndir="${CFG_EXTRA_LSN_DIR}" --stream=xbstream --target-dir="${CFG_EXTRA_LSN_DIR}" | \
            xbcloud put "${CFG_BUCKET_PATH}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"

                if [ $? -ne 0 ]; then
                    echo "Full backup failed!"
                    exit 1
                fi

                echo "$(date '+%Y-%m-%d %H:%M:%S:%s'): Full backup completed and streamed to S3 successfully"
            fi
        fi
    fi

    # Cleanup old backups in S3 if requested
    if [ "$OPT_CLEANUP" -eq 1 ]; then
        cleanup_old_backups
    fi

    # Generate report (disabled by default)
    # generate_report

# Restore backups
elif [ "${OPT_BACKUP_TYPE}" = "restore" ]; then
    FULL_BACKUP=$(echo $BACKUP_ARGUMENTS | awk '{print $1}')

    if [ -z "$FULL_BACKUP" ]; then
        echo "ERROR: No full backup specified for restore."
        exit 1
    fi

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "Dry run: xbcloud get ${CFG_BUCKET_PATH}/${FULL_BACKUP} --parallel=10 | xbstream -x -C /var/lib/mysql --parallel=8 --decrypt=AES256 --encrypt-key=$DECRYPT_KEY --decompress --decompress-threads=4"
        exit 0
    fi

    echo "Stopping MySQL..."
    systemctl stop mysql

    echo "Clearing /var/lib/mysql..."
    rm -rf /var/lib/mysql/*
    mkdir -p /var/lib/mysql
    chown mysql:mysql /var/lib/mysql
    chmod 0750 /var/lib/mysql

    echo "Restoring full backup: $FULL_BACKUP"
    xbcloud get "${CFG_BUCKET_PATH}/${FULL_BACKUP}" --parallel=10 2>download.log | \
    xbstream -x -C /var/lib/mysql --parallel=8 --decrypt=AES256 --encrypt-key="$DECRYPT_KEY" --decompress --decompress-threads=4

    echo "Preparing restored data..."
    xtrabackup --prepare --target-dir=/var/lib/mysql

    echo "Fixing permissions..."
    chown -R mysql:mysql /var/lib/mysql

    echo "Starting MySQL..."
    systemctl start mysql

    echo "Full backup has been restored successfully."
fi

exit 0