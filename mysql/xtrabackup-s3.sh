#!/bin/sh

# Usage:
#   xtrabackup-s3.sh full [--dry-run] [--cleanup]
#   xtrabackup-s3.sh inc [--dry-run] [--cleanup]
#   xtrabackup-s3.sh restore <full-backup> [--dry-run]
#   xtrabackup-s3.sh list

CFG_EXTRA_LSN_DIR="/var/backups/mysql_lsn"
CFG_HOSTNAME=$(hostname)
CFG_DATE=$(date +%Y-%m-%d_%H-%M-%S)
CFG_TIMESTAMP=$(date +%s)
CFG_INCREMENTAL=""

CONFIG_FILE="$HOME/.xtrabackup-s3.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file $CONFIG_FILE not found."
    exit 1
fi

. "$CONFIG_FILE"

if [ -z "$CFG_MC_BUCKET_PATH" ] || [ -z "$CFG_BUCKET_PATH" ] || [ -z "$CFG_CUTOFF_DAYS" ]; then
    echo "ERROR: Required configuration (CFG_MC_BUCKET_PATH, CFG_BUCKET_PATH, CFG_CUTOFF_DAYS) is missing."
    exit 1
fi

S3_ENDPOINT=$(awk -F'=' '/^s3-endpoint/ {print $2; exit}' /root/.my.cnf | xargs)
DECRYPT_KEY=$(awk -F'=' '/^encrypt-key/ {print $2; exit}' /root/.my.cnf | xargs)
DECRYPT_ALGO=$(awk -F'=' '/^encrypt/ {print $2; exit}' /root/.my.cnf | xargs)

OPT_BACKUP_TYPE="${1:-}"
OPT_DRY_RUN=0
OPT_CLEANUP=0

shift
while [ "$1" != "" ]; do
    case "$1" in
        --dry-run) OPT_DRY_RUN=1 ;;
        --cleanup) OPT_CLEANUP=1 ;;
        *) BACKUP_ARGUMENTS="$BACKUP_ARGUMENTS $1" ;;
    esac
    shift
done

cleanup_old_backups() {
    echo "Starting cleanup of old backups..."
    CUTOFF_DATE=$(date -d "$CFG_CUTOFF_DAYS days ago" +%Y-%m-%d)

    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | while read -r FOLDER; do
        FOLDER=$(echo "$FOLDER" | xargs)
        FOLDER_DATE=$(echo "$FOLDER" | cut -d_ -f1)

        if ! echo "$FOLDER_DATE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            echo "Skipping invalid folder: $FOLDER"
            continue
        fi

        if [ "$FOLDER_DATE" \< "$CUTOFF_DATE" ]; then
            if [ "$OPT_DRY_RUN" -eq 1 ]; then
                echo "Would delete: $FOLDER"
            else
                echo "Deleting: $FOLDER"
                mc rb --force "$CFG_MC_BUCKET_PATH/$FOLDER"
            fi
        fi
    done
}

generate_report() {
    echo "Backup report:"
    mc du "$CFG_MC_BUCKET_PATH" | awk '{print "Total Size: " $1 "\nTotal Objects: " $2 "\nPath: " $3}'
}

list_backups() {
    echo "=== LOCAL BACKUPS ==="
    if [ -n "$CFG_LOCAL_BACKUP_DIR" ] && [ -d "$CFG_LOCAL_BACKUP_DIR" ]; then
        find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort -r | while read -r backup; do
            backup_name=$(basename "$backup")
            size=$(du -sh "$backup" 2>/dev/null | cut -f1)
            echo "  $backup_name ($size)"
        done
    else
        echo "  No local backup directory configured or found"
    fi
    
    echo ""
    echo "=== REMOTE BACKUPS (S3) ==="
    if mc ls "$CFG_MC_BUCKET_PATH" >/dev/null 2>&1; then
        mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sort -r | while read -r folder; do
            folder=$(echo "$folder" | xargs)
            # get rough size if possible
            size=$(mc du "$CFG_MC_BUCKET_PATH/$folder" 2>/dev/null | awk '{print $1}' || echo "unknown")
            echo "  $folder ($size)"
        done
    else
        echo "  Could not access remote backups (check mc config)"
    fi
}

if [ "$OPT_BACKUP_TYPE" = "full" ] || [ "$OPT_BACKUP_TYPE" = "inc" ]; then
    if [ "$OPT_BACKUP_TYPE" = "inc" ]; then
        if [ ! -f "${CFG_EXTRA_LSN_DIR}/xtrabackup_checkpoints" ]; then
            echo "No previous full backup found. Please run a full backup first."
            exit 1
        fi
        CFG_INCREMENTAL="--incremental-basedir=${CFG_EXTRA_LSN_DIR}"

        if [ "$OPT_DRY_RUN" -eq 1 ]; then
            echo "Dry run: incremental backup command shown here"
        else
            xtrabackup --backup ${CFG_INCREMENTAL} --extra-lsndir="${CFG_EXTRA_LSN_DIR}" --stream=xbstream --target-dir="${CFG_EXTRA_LSN_DIR}" | \
            xbcloud put "${CFG_BUCKET_PATH}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"
            [ $? -eq 0 ] || { echo "Incremental backup failed!"; exit 1; }
            echo "$(date '+%F %T'): Incremental backup completed"
        fi
    else
        if [ -n "$CFG_LOCAL_BACKUP_DIR" ]; then
            LOCAL_BACKUP_SUBDIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"
            mkdir -p "$LOCAL_BACKUP_SUBDIR"
            KEEP_COUNT="${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}"
            find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort | head -n -"$KEEP_COUNT" | while read -r OLD; do
                rm -rf "$OLD"
            done

            xtrabackup --backup \
                --extra-lsndir="$LOCAL_BACKUP_SUBDIR" \
                --target-dir="$LOCAL_BACKUP_SUBDIR"

            [ $? -eq 0 ] || { echo "Full backup failed!"; exit 1; }

            mc mirror --retry --overwrite "$LOCAL_BACKUP_SUBDIR" "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_SUBDIR")"
        else
            xtrabackup --backup --extra-lsndir="${CFG_EXTRA_LSN_DIR}" --stream=xbstream --target-dir="${CFG_EXTRA_LSN_DIR}" | \
            xbcloud put "${CFG_BUCKET_PATH}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"

            [ $? -eq 0 ] || { echo "Full backup failed!"; exit 1; }

            echo "$(date '+%F %T'): Full backup streamed to S3"
        fi
    fi

    [ "$OPT_CLEANUP" -eq 1 ] && cleanup_old_backups

elif [ "$OPT_BACKUP_TYPE" = "restore" ]; then
    FULL_BACKUP=$(echo $BACKUP_ARGUMENTS | awk '{print $1}')
    [ -z "$FULL_BACKUP" ] && { echo "ERROR: No full backup specified for restore."; exit 1; }

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: showing what would be executed"
        echo "systemctl stop mysql"
        echo "rm -rf /var/lib/mysql/* && mkdir -p /var/lib/mysql && chown mysql:mysql /var/lib/mysql && chmod 0750 /var/lib/mysql"
        echo "mc mirror --overwrite --remove \"${CFG_MC_BUCKET_PATH}/${FULL_BACKUP}\" /var/lib/mysql"
        echo "# Decrypt and decompress"
        echo "find /var/lib/mysql -name '*.zst.xbcrypt' | while read -r f; do"
        echo "  out=\"\${f%.zst.xbcrypt}\""
        echo "  echo \"xbcrypt --decrypt --encrypt-key=\"$DECRYPT_KEY\" --encrypt-algo=\"$DECRYPT_ALGO\" --input=\"\$f\" --output=\"\$out.zst\" && zstd -d \"\$out.zst\" -o \"\$out\" && rm \"\$out.zst\"\""
        echo "done"
        echo "xtrabackup --prepare --target-dir=/var/lib/mysql"
        echo "chown -R mysql:mysql /var/lib/mysql"
        echo "systemctl start mysql"
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
    mc mirror --overwrite --remove "${CFG_MC_BUCKET_PATH}/${FULL_BACKUP}" /var/lib/mysql

    echo "Decrypting and decompressing all .zst.xbcrypt files..."
    find /var/lib/mysql -name '*.zst.xbcrypt' | while read -r f; do
      out="${f%.zst.xbcrypt}"
      if [ -f "$out" ]; then
        echo "✅ Already exists: $out"
        continue
      fi
      echo "🔄 Decrypting and decompressing: $f → $out"
      xbcrypt --decrypt --encrypt-key="$DECRYPT_KEY" --encrypt-algo="$DECRYPT_ALGO" --input="$f" --output="$out.zst" && \
      zstd -d "$out.zst" -o "$out" && rm -f "$out.zst"
    done

    echo "Preparing restored data..."
    xtrabackup --prepare --target-dir=/var/lib/mysql

    echo "Fixing permissions..."
    chown -R mysql:mysql /var/lib/mysql

    echo "Starting MySQL..."
    systemctl start mysql

    echo "✅ Full backup restored successfully from: $FULL_BACKUP"

elif [ "$OPT_BACKUP_TYPE" = "list" ]; then
    list_backups

else
    echo "Usage: $0 {full|inc|list} [--dry-run] [--cleanup]"
    echo "       $0 restore <full-backup> [--dry-run]"
    exit 1
fi

exit 0