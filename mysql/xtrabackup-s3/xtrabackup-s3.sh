#!/bin/sh

# Usage:
#   xtrabackup-s3.sh full [--dry-run] [--cleanup] [--no-sync]
#   xtrabackup-s3.sh inc [--dry-run] [--cleanup] [--no-sync]
#   xtrabackup-s3.sh restore <full-backup> [--dry-run]
#   xtrabackup-s3.sh restore-chain <backup> [--dry-run] [--restore-dir=<path>]
#   xtrabackup-s3.sh list
#   xtrabackup-s3.sh delete-chain <full-backup> [--dry-run]
#   xtrabackup-s3.sh sync <backup-folder> [--dry-run]
#   xtrabackup-s3.sh sync-all [--dry-run]
#   xtrabackup-s3.sh analyze-chains

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

if [ -z "$CFG_MC_BUCKET_PATH" ] || [ -z "$CFG_CUTOFF_DAYS" ] || [ -z "$CFG_LOCAL_BACKUP_DIR" ]; then
    echo "ERROR: Required configuration (CFG_MC_BUCKET_PATH, CFG_CUTOFF_DAYS, CFG_LOCAL_BACKUP_DIR) is missing."
    exit 1
fi

S3_ENDPOINT=$(awk -F'=' '/^s3-endpoint/ {print $2; exit}' /root/.my.cnf | xargs)
DECRYPT_KEY=$(awk -F'=' '/^encrypt-key/ {print $2; exit}' /root/.my.cnf | xargs)
DECRYPT_ALGO=$(awk -F'=' '/^encrypt/ {print $2; exit}' /root/.my.cnf | xargs)

OPT_BACKUP_TYPE="${1:-}"
OPT_DRY_RUN=0
OPT_CLEANUP=0
OPT_NO_SYNC=0
OPT_RESTORE_DIR=""

# Only shift if there are arguments
if [ $# -gt 0 ]; then
    shift
    while [ "$1" != "" ]; do
        case "$1" in
            --dry-run) OPT_DRY_RUN=1 ;;
            --cleanup) OPT_CLEANUP=1 ;;
            --no-sync) OPT_NO_SYNC=1 ;;
            --restore-dir=*) OPT_RESTORE_DIR="${1#*=}" ;;
            *) BACKUP_ARGUMENTS="$BACKUP_ARGUMENTS $1" ;;
        esac
        shift
    done
fi

cleanup_old_backups() {
    echo "Starting chain-aware cleanup of old backups..."
    CUTOFF_DATE=$(date -d "$CFG_CUTOFF_DAYS days ago" +%Y-%m-%d)
    echo "Cutoff date: $CUTOFF_DATE"
    
    # Get all backups and sort them
    TEMP_FILE=$(mktemp)
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's/\/$//' | sort > "$TEMP_FILE"
    
    # Find all full backups
    FULL_BACKUPS=$(grep "_full_" "$TEMP_FILE")
    
    echo "Found full backups:"
    echo "$FULL_BACKUPS"
    echo ""
    
    # Process each full backup and its incremental chain
    echo "$FULL_BACKUPS" | while read -r FULL_BACKUP; do
        if [ -z "$FULL_BACKUP" ]; then
            continue
        fi
        
        FULL_DATE=$(echo "$FULL_BACKUP" | cut -d_ -f1)
        FULL_TIMESTAMP=$(echo "$FULL_BACKUP" | grep -o '[0-9]*$')
        
        # Skip if date format is invalid
        if ! echo "$FULL_DATE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
            echo "Skipping invalid folder: $FULL_BACKUP"
            continue
        fi
        
        echo "Checking backup chain for: $FULL_BACKUP (date: $FULL_DATE)"
        
        # Find all incrementals for this full backup
        INCREMENTALS=$(grep "_inc_base-${FULL_TIMESTAMP}_" "$TEMP_FILE" || true)
        INCREMENTAL_COUNT=$(echo "$INCREMENTALS" | grep -c . || echo "0")
        
        echo "  Found $INCREMENTAL_COUNT incrementals for this full backup"
        
        # Check if this full backup is older than cutoff
        if [ "$FULL_DATE" \< "$CUTOFF_DATE" ]; then
            echo "  📅 Full backup $FULL_BACKUP is older than cutoff ($FULL_DATE < $CUTOFF_DATE)"
            
            # Check if any incrementals are newer than cutoff (should be preserved)
            NEWER_INCREMENTALS=""
            if [ -n "$INCREMENTALS" ]; then
                NEWER_INCREMENTALS=$(echo "$INCREMENTALS" | while read -r inc; do
                    if [ -n "$inc" ]; then
                        INC_DATE=$(echo "$inc" | cut -d_ -f1)
                        if [ "$INC_DATE" \> "$CUTOFF_DATE" ] || [ "$INC_DATE" = "$CUTOFF_DATE" ]; then
                            echo "$inc"
                        fi
                    fi
                done)
            fi
            
            if [ -n "$NEWER_INCREMENTALS" ]; then
                echo "  ⚠️  WARNING: Found incrementals newer than cutoff date:"
                echo "$NEWER_INCREMENTALS" | while read -r newer_inc; do
                    [ -n "$newer_inc" ] && echo "    - $newer_inc"
                done
                echo "  🔒 PRESERVING entire chain to avoid orphaning incrementals"
            else
                echo "  🗑️  Safe to delete: all incrementals are also older than cutoff"
                
                if [ "$OPT_DRY_RUN" -eq 1 ]; then
                    echo "  [DRY RUN] Would delete full backup: $FULL_BACKUP"
                    if [ -n "$INCREMENTALS" ]; then
                        echo "$INCREMENTALS" | while read -r inc; do
                            [ -n "$inc" ] && echo "  [DRY RUN] Would delete incremental: $inc"
                        done
                    fi
                else
                    echo "  Deleting full backup: $FULL_BACKUP"
                    mc rb --force "$CFG_MC_BUCKET_PATH/$FULL_BACKUP"
                    
                    # Delete all incrementals for this full backup
                    if [ -n "$INCREMENTALS" ]; then
                        echo "$INCREMENTALS" | while read -r inc; do
                            if [ -n "$inc" ]; then
                                echo "  Deleting incremental: $inc"
                                mc rb --force "$CFG_MC_BUCKET_PATH/$inc"
                            fi
                        done
                    fi
                fi
            fi
        else
            echo "  ✅ Full backup $FULL_BACKUP is within retention period ($FULL_DATE >= $CUTOFF_DATE)"
        fi
        echo ""
    done
    
    # Clean up orphaned incrementals (incrementals without a corresponding full backup)
    echo "Checking for orphaned incrementals..."
    ALL_INCREMENTALS=$(grep "_inc_base-" "$TEMP_FILE" || true)
    
    if [ -n "$ALL_INCREMENTALS" ]; then
        echo "$ALL_INCREMENTALS" | while read -r inc; do
            if [ -n "$inc" ]; then
                # Extract the base timestamp
                BASE_TIMESTAMP=$(echo "$inc" | sed 's/.*_inc_base-\([0-9]*\)_.*/\1/')
                
                # Check if corresponding full backup exists
                CORRESPONDING_FULL=$(grep "_full_${BASE_TIMESTAMP}" "$TEMP_FILE" || true)
                
                if [ -z "$CORRESPONDING_FULL" ]; then
                    INC_DATE=$(echo "$inc" | cut -d_ -f1)
                    echo "  🚨 ORPHANED incremental found: $inc (base timestamp: $BASE_TIMESTAMP)"
                    
                    if [ "$OPT_DRY_RUN" -eq 1 ]; then
                        echo "  [DRY RUN] Would delete orphaned incremental: $inc"
                    else
                        echo "  Deleting orphaned incremental: $inc"
                        mc rb --force "$CFG_MC_BUCKET_PATH/$inc"
                    fi
                fi
            fi
        done
    else
        echo "✅ No orphaned incrementals found"
    fi
    
    rm -f "$TEMP_FILE"
    echo "Chain-aware cleanup completed."
}

analyze_backup_chains() {
    echo "=== BACKUP CHAIN ANALYSIS ==="
    
    # Show current backup chains
    TEMP_FILE=$(mktemp)
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's/\/$//' | sort > "$TEMP_FILE"
    
    FULL_BACKUPS=$(grep "_full_" "$TEMP_FILE")
    
    echo "Current backup chains:"
    echo "$FULL_BACKUPS" | while read -r FULL_BACKUP; do
        if [ -n "$FULL_BACKUP" ]; then
            FULL_TIMESTAMP=$(echo "$FULL_BACKUP" | grep -o '[0-9]*$')
            INCREMENTALS=$(grep "_inc_base-${FULL_TIMESTAMP}_" "$TEMP_FILE" | wc -l)
            CHAIN_SIZE=$(mc du "$CFG_MC_BUCKET_PATH/$FULL_BACKUP" 2>/dev/null | awk '{print $1}' || echo "unknown")
            
            if [ "$INCREMENTALS" -gt 0 ]; then
                OLDEST_INC=$(grep "_inc_base-${FULL_TIMESTAMP}_" "$TEMP_FILE" | head -1 | cut -d_ -f1)
                NEWEST_INC=$(grep "_inc_base-${FULL_TIMESTAMP}_" "$TEMP_FILE" | tail -1 | cut -d_ -f1)
                echo "📁 $FULL_BACKUP ($CHAIN_SIZE)"
                echo "   ↳ $INCREMENTALS incrementals (${OLDEST_INC} → ${NEWEST_INC})"
            else
                echo "📁 $FULL_BACKUP ($CHAIN_SIZE) [standalone]"
            fi
        fi
    done
    
    # Find orphaned incrementals
    echo ""
    echo "Checking for orphaned incrementals..."
    ALL_INCREMENTALS=$(grep "_inc_base-" "$TEMP_FILE" || true)
    ORPHAN_COUNT=0
    
    if [ -n "$ALL_INCREMENTALS" ]; then
        echo "$ALL_INCREMENTALS" | while read -r inc; do
            if [ -n "$inc" ]; then
                BASE_TIMESTAMP=$(echo "$inc" | sed 's/.*_inc_base-\([0-9]*\)_.*/\1/')
                CORRESPONDING_FULL=$(grep "_full_${BASE_TIMESTAMP}" "$TEMP_FILE" || true)
                
                if [ -z "$CORRESPONDING_FULL" ]; then
                    echo "🚨 ORPHANED: $inc (missing full backup with timestamp $BASE_TIMESTAMP)"
                    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
                fi
            fi
        done
    fi
    
    if [ "$ORPHAN_COUNT" -eq 0 ]; then
        echo "✅ No orphaned incrementals found"
    fi
    
    rm -f "$TEMP_FILE"
    echo ""
    echo "=== END ANALYSIS ==="
    echo ""
}

generate_report() {
    echo "Backup report:"
    mc du "$CFG_MC_BUCKET_PATH" | awk '{print "Total Size: " $1 "\nTotal Objects: " $2 "\nPath: " $3}'
}

list_backups() {
    echo "=== LOCAL BACKUPS ==="
    if [ -n "$CFG_LOCAL_BACKUP_DIR" ] && [ -d "$CFG_LOCAL_BACKUP_DIR" ]; then
        find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_full_*" | sort -r | while read -r full_backup; do
            if [ -d "$full_backup" ]; then
                backup_name=$(basename "$full_backup")
                size=$(du -sh "$full_backup" 2>/dev/null | cut -f1)
                timestamp=$(echo "$backup_name" | grep -o '[0-9]*$')
                echo "📁 $backup_name ($size) [FULL]"
                
                find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_inc_base-${timestamp}_*" | sort | while read -r inc_backup; do
                    if [ -d "$inc_backup" ]; then
                        inc_name=$(basename "$inc_backup")
                        inc_size=$(du -sh "$inc_backup" 2>/dev/null | cut -f1)
                        echo "  ↳ $inc_name ($inc_size) [INC]"
                    fi
                done
            fi
        done
    else
        echo "  No local backup directory configured or found"
    fi
    
    echo ""
    echo "=== REMOTE BACKUPS (S3) ==="
    if mc ls "$CFG_MC_BUCKET_PATH" >/dev/null 2>&1; then
        mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | grep "_full_" | sort -r | while read -r full_folder; do
            full_folder=$(echo "$full_folder" | xargs | sed 's/\/$//')
            if [ -n "$full_folder" ]; then
                size=$(mc du "$CFG_MC_BUCKET_PATH/$full_folder" 2>/dev/null | awk '{print $1}' || echo "unknown")
                timestamp=$(echo "$full_folder" | grep -o '[0-9]*$')
                echo "📁 $full_folder ($size) [FULL]"
                
                mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | grep "_inc_base-${timestamp}_" | sort | while read -r inc_folder; do
                    inc_folder=$(echo "$inc_folder" | xargs | sed 's/\/$//')
                    if [ -n "$inc_folder" ]; then
                        inc_size=$(mc du "$CFG_MC_BUCKET_PATH/$inc_folder" 2>/dev/null | awk '{print $1}' || echo "unknown")
                        echo "  ↳ $inc_folder ($inc_size) [INC]"
                    fi
                done
            fi
        done
    else
        echo "  Could not access remote backups (check mc config)"
    fi
}

if [ "$OPT_BACKUP_TYPE" = "full" ] || [ "$OPT_BACKUP_TYPE" = "inc" ]; then
    if [ -z "$CFG_LOCAL_BACKUP_DIR" ]; then
        echo "ERROR: CFG_LOCAL_BACKUP_DIR must be configured for all backup operations."
        exit 1
    fi

    if [ "$OPT_BACKUP_TYPE" = "inc" ]; then
        LATEST_BACKUP=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort -r | head -n 1)
        if [ -z "$LATEST_BACKUP" ]; then
            echo "No previous backup found in $CFG_LOCAL_BACKUP_DIR. Please run a full backup first."
            exit 1
        fi

        LATEST_BACKUP_NAME=$(basename "$LATEST_BACKUP")
        if echo "$LATEST_BACKUP_NAME" | grep -q "_full_"; then
            BASE_TIMESTAMP=$(echo "$LATEST_BACKUP_NAME" | grep -o '[0-9]*$')
        else
            BASE_TIMESTAMP=$(echo "$LATEST_BACKUP_NAME" | sed 's/.*_inc_base-\([0-9]*\)_.*/\1/')
        fi

        CFG_INCREMENTAL="--incremental-basedir=$LATEST_BACKUP"
        LOCAL_BACKUP_DIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_base-${BASE_TIMESTAMP}_${CFG_TIMESTAMP}"

        if [ "$OPT_DRY_RUN" -eq 1 ]; then
            echo "Dry run: would run incremental backup"
            echo "Base backup: $LATEST_BACKUP"
            echo "Original full backup timestamp: $BASE_TIMESTAMP"
            echo "Would create: $LOCAL_BACKUP_DIR"
            echo "Command: xtrabackup --backup ${CFG_INCREMENTAL} --extra-lsndir=\"$LOCAL_BACKUP_DIR\" --target-dir=\"$LOCAL_BACKUP_DIR\""
            if [ "$OPT_NO_SYNC" -eq 1 ]; then
                echo "Would skip S3 sync (--no-sync specified)"
            else
                echo "Would mirror to: $CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
            fi
        else
            mkdir -p "$LOCAL_BACKUP_DIR"
            
            xtrabackup --backup ${CFG_INCREMENTAL} \
                --extra-lsndir="$LOCAL_BACKUP_DIR" \
                --target-dir="$LOCAL_BACKUP_DIR"
                
            [ $? -eq 0 ] || { echo "Incremental backup failed!"; exit 1; }
            
            if [ "$OPT_NO_SYNC" -eq 1 ]; then
                echo "$(date '+%F %T'): Incremental backup completed (local only, S3 sync skipped)"
            else
                mc mirror --retry --overwrite "$LOCAL_BACKUP_DIR" "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
                echo "$(date '+%F %T'): Incremental backup completed and mirrored to S3"
            fi
        fi
    else
        LOCAL_BACKUP_DIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"

        if [ "$OPT_DRY_RUN" -eq 1 ]; then
            echo "Dry run: would run full backup"
            echo "Would create: $LOCAL_BACKUP_DIR"
            echo "Would cleanup old local backups (keeping ${CFG_LOCAL_BACKUP_KEEP_COUNT:-4})"
            echo "Command: xtrabackup --backup --extra-lsndir=\"$LOCAL_BACKUP_DIR\" --target-dir=\"$LOCAL_BACKUP_DIR\""
            if [ "$OPT_NO_SYNC" -eq 1 ]; then
                echo "Would skip S3 sync (--no-sync specified)"
            else
                echo "Would mirror to: $CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
            fi
        else
            mkdir -p "$LOCAL_BACKUP_DIR"
            
            KEEP_COUNT="${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}"
            find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort | head -n -"$KEEP_COUNT" | while read -r OLD; do
                rm -rf "$OLD"
            done

            xtrabackup --backup \
                --extra-lsndir="$LOCAL_BACKUP_DIR" \
                --target-dir="$LOCAL_BACKUP_DIR"

            [ $? -eq 0 ] || { echo "Full backup failed!"; exit 1; }

            if [ "$OPT_NO_SYNC" -eq 1 ]; then
                echo "$(date '+%F %T'): Full backup completed (local only, S3 sync skipped)"
            else
                mc mirror --retry --overwrite "$LOCAL_BACKUP_DIR" "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
                echo "$(date '+%F %T'): Full backup completed and mirrored to S3"
            fi
        fi
    fi

    if [ "$OPT_CLEANUP" -eq 1 ]; then
        cleanup_old_backups
    fi

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

elif [ "$OPT_BACKUP_TYPE" = "restore-chain" ]; then
    BACKUP_TARGET=$(echo $BACKUP_ARGUMENTS | awk '{print $1}')
    [ -z "$BACKUP_TARGET" ] && { echo "ERROR: No backup specified for chain restore."; exit 1; }

    if echo "$BACKUP_TARGET" | grep -q "_full_"; then
        FULL_BACKUP="$BACKUP_TARGET"
        FULL_TIMESTAMP=$(echo "$FULL_BACKUP" | grep -o '[0-9]*$')
        RESTORE_MODE="full_with_incrementals"
    elif echo "$BACKUP_TARGET" | grep -q "_inc_base-"; then
        FULL_TIMESTAMP=$(echo "$BACKUP_TARGET" | sed 's/.*_inc_base-\([0-9]*\)_.*/\1/')
        TARGET_TIMESTAMP=$(echo "$BACKUP_TARGET" | grep -o '[0-9]*$')
        RESTORE_MODE="up_to_incremental"
        
        FULL_BACKUP=$(mc ls "$CFG_MC_BUCKET_PATH" 2>/dev/null | awk '{print $NF}' | grep "_full_${FULL_TIMESTAMP}" | head -n 1 | sed 's/\/$//')
        [ -z "$FULL_BACKUP" ] && { echo "ERROR: Could not find full backup for timestamp: $FULL_TIMESTAMP"; exit 1; }
    else
        echo "ERROR: Invalid backup name. Must be either a full backup or incremental backup."
        exit 1
    fi

    if [ "$RESTORE_MODE" = "full_with_incrementals" ]; then
        INCREMENTALS=$(mc ls "$CFG_MC_BUCKET_PATH" 2>/dev/null | awk '{print $NF}' | grep "_inc_base-${FULL_TIMESTAMP}_" | sed 's/\/$//' | sort)
    else
        INCREMENTALS=$(mc ls "$CFG_MC_BUCKET_PATH" 2>/dev/null | awk '{print $NF}' | grep "_inc_base-${FULL_TIMESTAMP}_" | sed 's/\/$//' | sort | awk -v target="$TARGET_TIMESTAMP" '{
            inc_ts = $0; gsub(/.*_/, "", inc_ts)
            if (inc_ts <= target) print $0
        }')
    fi

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: showing incremental chain restore plan"
        echo "Full backup: $FULL_BACKUP"
        echo "Restore mode: $RESTORE_MODE"
        if [ "$RESTORE_MODE" = "up_to_incremental" ]; then
            echo "Target incremental: $BACKUP_TARGET"
        fi
        echo ""
        echo "RESTORE SEQUENCE:"
        echo "1. systemctl stop mysql"
        echo "2. rm -rf /var/lib/mysql/* && mkdir -p /var/lib/mysql"
        echo "3. Download and restore full backup: $FULL_BACKUP"
        echo "4. mc mirror \"${CFG_MC_BUCKET_PATH}/${FULL_BACKUP}\" /var/lib/mysql"
        echo "5. Decrypt and decompress full backup files"
        echo "6. xtrabackup --prepare --apply-log-only --target-dir=/var/lib/mysql"
        
        if [ -n "$INCREMENTALS" ]; then
            echo ""
            echo "INCREMENTAL SEQUENCE:"
            echo "$INCREMENTALS" | while read -r inc; do
                echo "7. Download incremental: $inc"
                echo "8. mc mirror \"${CFG_MC_BUCKET_PATH}/${inc}\" ${OPT_RESTORE_DIR:-/tmp/restore}/$inc"
                echo "9. Decrypt and decompress incremental files"
                echo "10. xtrabackup --prepare --apply-log-only --target-dir=/var/lib/mysql --incremental-dir=${OPT_RESTORE_DIR:-/tmp/restore}/$inc"
            done
            echo ""
            echo "FINAL STEPS:"
            echo "11. xtrabackup --prepare --target-dir=/var/lib/mysql (final prepare without --apply-log-only)"
        else
            echo ""
            echo "No incrementals found - will restore full backup only"
            echo "7. xtrabackup --prepare --target-dir=/var/lib/mysql (final prepare)"
        fi
        
        echo "12. chown -R mysql:mysql /var/lib/mysql"
        echo "13. systemctl start mysql"
        echo ""
        echo "Temporary files will be stored in: ${OPT_RESTORE_DIR:-/tmp/restore}/"
        exit 0
    fi

    RESTORE_TMP="${OPT_RESTORE_DIR:-/tmp/restore}"
    rm -rf "$RESTORE_TMP"
    mkdir -p "$RESTORE_TMP"

    echo "Starting incremental chain restore..."
    echo "Full backup: $FULL_BACKUP"
    if [ -n "$INCREMENTALS" ]; then
        echo "Incrementals to apply: $(echo "$INCREMENTALS" | wc -l)"
    else
        echo "No incrementals to apply"
    fi

    echo "Stopping MySQL..."
    systemctl stop mysql

    echo "Clearing /var/lib/mysql..."
    rm -rf /var/lib/mysql/*
    mkdir -p /var/lib/mysql
    chown mysql:mysql /var/lib/mysql
    chmod 0750 /var/lib/mysql

    echo "Downloading and restoring full backup: $FULL_BACKUP"
    mc mirror --overwrite --remove "${CFG_MC_BUCKET_PATH}/${FULL_BACKUP}" /var/lib/mysql

    echo "Decrypting and decompressing full backup files..."
    find /var/lib/mysql -name '*.zst.xbcrypt' | while read -r f; do
        out="${f%.zst.xbcrypt}"
        if [ ! -f "$out" ]; then
            echo "🔄 Processing: $(basename "$f")"
            xbcrypt --decrypt --encrypt-key="$DECRYPT_KEY" --encrypt-algo="$DECRYPT_ALGO" --input="$f" --output="$out.zst" && \
            zstd -d "$out.zst" -o "$out" && rm -f "$out.zst"
        fi
    done

    echo "Preparing full backup (with --apply-log-only)..."
    xtrabackup --prepare --apply-log-only --target-dir=/var/lib/mysql

    # Check if the initial prepare succeeded before proceeding with incrementals
    if [ $? -ne 0 ]; then
        echo "❌ Full backup prepare failed! Aborting restore."
        exit 1
    fi

    if [ -n "$INCREMENTALS" ]; then
        RESTORE_SUCCESS=1
        echo "$INCREMENTALS" | while read -r inc; do
            echo ""
            echo "Processing incremental: $inc"
            
            echo "Downloading incremental backup..."
            mc mirror --overwrite --remove "${CFG_MC_BUCKET_PATH}/${inc}" "$RESTORE_TMP/$inc"
            
            echo "Decrypting and decompressing incremental files..."
            find "$RESTORE_TMP/$inc" -name '*.zst.xbcrypt' | while read -r f; do
                out="${f%.zst.xbcrypt}"
                if [ ! -f "$out" ]; then
                    echo "🔄 Processing: $(basename "$f")"
                    xbcrypt --decrypt --encrypt-key="$DECRYPT_KEY" --encrypt-algo="$DECRYPT_ALGO" --input="$f" --output="$out.zst" && \
                    zstd -d "$out.zst" -o "$out" && rm -f "$out.zst"
                fi
            done
            
            echo "Applying incremental backup..."
            xtrabackup --prepare --apply-log-only --target-dir=/var/lib/mysql --incremental-dir="$RESTORE_TMP/$inc"
            
            # Check if the incremental apply succeeded
            if [ $? -ne 0 ]; then
                echo "❌ Failed to apply incremental backup: $inc"
                echo "🔍 Check LSN compatibility between full backup and this incremental"
                echo "💡 You may need to use a different full backup or incremental chain"
                exit 1
            fi
            
            echo "✅ Successfully applied incremental: $inc"
        done
        
        # Check if we reached here successfully
        if [ $? -ne 0 ]; then
            echo "❌ Incremental chain restore failed!"
            exit 1
        fi
    fi

    echo ""
    echo "Final prepare (without --apply-log-only)..."
    xtrabackup --prepare --target-dir=/var/lib/mysql

    if [ $? -ne 0 ]; then
        echo "❌ Final prepare failed!"
        exit 1
    fi

    echo "Fixing permissions..."
    chown -R mysql:mysql /var/lib/mysql

    echo "Cleaning up temporary files..."
    rm -rf "$RESTORE_TMP"

    echo "Starting MySQL..."
    systemctl start mysql

    echo "✅ Incremental chain restore completed successfully!"
    if [ "$RESTORE_MODE" = "up_to_incremental" ]; then
        echo "Restored up to: $BACKUP_TARGET"
    else
        echo "Restored full backup with all incrementals: $FULL_BACKUP"
    fi

elif [ "$OPT_BACKUP_TYPE" = "delete-chain" ]; then
    FULL_BACKUP=$(echo $BACKUP_ARGUMENTS | awk '{print $1}')
    [ -z "$FULL_BACKUP" ] && { echo "ERROR: No full backup specified for chain deletion."; exit 1; }

    FULL_TIMESTAMP=$(echo "$FULL_BACKUP" | grep -o '[0-9]*)
    [ -z "$FULL_TIMESTAMP" ] && { echo "ERROR: Could not extract timestamp from backup name: $FULL_BACKUP"; exit 1; }

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: showing what would be deleted"
        echo "Full backup: $FULL_BACKUP"
        echo ""
        echo "LOCAL INCREMENTALS TO DELETE:"
        find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_inc_base-${FULL_TIMESTAMP}_*" 2>/dev/null | sort | while read -r inc_backup; do
            if [ -d "$inc_backup" ]; then
                inc_name=$(basename "$inc_backup")
                size=$(du -sh "$inc_backup" 2>/dev/null | cut -f1)
                echo "  Would delete: $inc_name ($size)"
            fi
        done
        
        echo ""
        echo "REMOTE INCREMENTALS TO DELETE:"
        mc ls "$CFG_MC_BUCKET_PATH" 2>/dev/null | awk '{print $NF}' | grep "_inc_base-${FULL_TIMESTAMP}_" | sort | while read -r inc_folder; do
            inc_folder=$(echo "$inc_folder" | xargs | sed 's/\/$//')
            if [ -n "$inc_folder" ]; then
                size=$(mc du "$CFG_MC_BUCKET_PATH/$inc_folder" 2>/dev/null | awk '{print $1}' || echo "unknown")
                echo "  Would delete: $inc_folder ($size)"
            fi
        done
        
        echo ""
        echo "NOTE: The full backup itself will NOT be deleted"
        exit 0
    fi

    echo "Deleting local incremental backups for full backup: $FULL_BACKUP"
    find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_inc_base-${FULL_TIMESTAMP}_*" 2>/dev/null | while read -r inc_backup; do
        if [ -d "$inc_backup" ]; then
            inc_name=$(basename "$inc_backup")
            echo "Deleting local: $inc_name"
            rm -rf "$inc_backup"
        fi
    done

    echo "Deleting remote incremental backups for full backup: $FULL_BACKUP"
    mc ls "$CFG_MC_BUCKET_PATH" 2>/dev/null | awk '{print $NF}' | grep "_inc_base-${FULL_TIMESTAMP}_" | while read -r inc_folder; do
        inc_folder=$(echo "$inc_folder" | xargs | sed 's/\/$//')
        if [ -n "$inc_folder" ]; then
            echo "Deleting remote: $inc_folder"
            mc rb --force "$CFG_MC_BUCKET_PATH/$inc_folder"
        fi
    done

    echo "✅ Incremental backup chain deletion completed for: $FULL_BACKUP"

elif [ "$OPT_BACKUP_TYPE" = "sync" ]; then
    BACKUP_FOLDER=$(echo $BACKUP_ARGUMENTS | awk '{print $1}')
    [ -z "$BACKUP_FOLDER" ] && { echo "ERROR: No backup folder specified for sync."; exit 1; }

    if [ -d "$BACKUP_FOLDER" ]; then
        LOCAL_BACKUP_PATH="$BACKUP_FOLDER"
    elif [ -d "$CFG_LOCAL_BACKUP_DIR/$BACKUP_FOLDER" ]; then
        LOCAL_BACKUP_PATH="$CFG_LOCAL_BACKUP_DIR/$BACKUP_FOLDER"
    else
        echo "ERROR: Backup folder not found: $BACKUP_FOLDER"
        echo "Checked paths:"
        echo "  - $BACKUP_FOLDER"
        echo "  - $CFG_LOCAL_BACKUP_DIR/$BACKUP_FOLDER"
        exit 1
    fi

    BACKUP_NAME=$(basename "$LOCAL_BACKUP_PATH")
    
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: showing what would be synced"
        echo "Local backup: $LOCAL_BACKUP_PATH"
        echo "Would sync to: $CFG_MC_BUCKET_PATH/$BACKUP_NAME"
        echo "Command: mc mirror --retry --overwrite \"$LOCAL_BACKUP_PATH\" \"$CFG_MC_BUCKET_PATH/$BACKUP_NAME\""
        exit 0
    fi

    echo "Syncing backup to S3..."
    echo "Local: $LOCAL_BACKUP_PATH"
    echo "Remote: $CFG_MC_BUCKET_PATH/$BACKUP_NAME"
    
    if [ ! -d "$LOCAL_BACKUP_PATH" ]; then
        echo "ERROR: Local backup directory does not exist: $LOCAL_BACKUP_PATH"
        exit 1
    fi

    mc mirror --retry --overwrite "$LOCAL_BACKUP_PATH" "$CFG_MC_BUCKET_PATH/$BACKUP_NAME"
    
    if [ $? -eq 0 ]; then
        echo "✅ Backup synced successfully to S3: $BACKUP_NAME"
    else
        echo "❌ Sync failed!"
        exit 1
    fi

elif [ "$OPT_BACKUP_TYPE" = "sync-all" ]; then
    if [ ! -d "$CFG_LOCAL_BACKUP_DIR" ]; then
        echo "ERROR: Local backup directory does not exist: $CFG_LOCAL_BACKUP_DIR"
        exit 1
    fi

    BACKUP_DIRS=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort)
    
    if [ -z "$BACKUP_DIRS" ]; then
        echo "No backup directories found in $CFG_LOCAL_BACKUP_DIR"
        exit 0
    fi

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: showing what would be synced"
        echo "Local backup directory: $CFG_LOCAL_BACKUP_DIR"
        echo ""
        echo "BACKUPS TO SYNC:"
        echo "$BACKUP_DIRS" | while read -r backup_dir; do
            if [ -d "$backup_dir" ]; then
                backup_name=$(basename "$backup_dir")
                size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
                echo "  Would sync: $backup_name ($size) -> $CFG_MC_BUCKET_PATH/$backup_name"
            fi
        done
        exit 0
    fi

    echo "Syncing all local backups to S3..."
    echo "Local backup directory: $CFG_LOCAL_BACKUP_DIR"
    echo ""

    SUCCESS_COUNT=0
    FAILURE_COUNT=0

    echo "$BACKUP_DIRS" | while read -r backup_dir; do
        if [ -d "$backup_dir" ]; then
            backup_name=$(basename "$backup_dir")
            echo "🔄 Syncing: $backup_name"
            
            mc mirror --retry --overwrite "$backup_dir" "$CFG_MC_BUCKET_PATH/$backup_name"
            
            if [ $? -eq 0 ]; then
                echo "✅ Synced: $backup_name"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                echo "❌ Failed: $backup_name"
                FAILURE_COUNT=$((FAILURE_COUNT + 1))
            fi
            echo ""
        fi
    done

    echo "=== SYNC SUMMARY ==="
    echo "Successful: $SUCCESS_COUNT"
    echo "Failed: $FAILURE_COUNT"
    
    if [ "$FAILURE_COUNT" -gt 0 ]; then
        echo "Some backups failed to sync. Check the output above for details."
        exit 1
    else
        echo "✅ All backups synced successfully!"
    fi

elif [ "$OPT_BACKUP_TYPE" = "list" ]; then
    list_backups

elif [ "$OPT_BACKUP_TYPE" = "analyze-chains" ]; then
    if [ -z "$BACKUP_ARGUMENTS" ]; then
        echo "Error: No backup chain specified"
        exit 1
    fi
    analyze_backup_chains "$BACKUP_ARGUMENTS"

else
    echo "MySQL XtraBackup S3 Management Script"
    echo ""
    echo "Usage: $0 {full|inc|list|delete-chain|sync|sync-all|restore-chain|analyze-chains} [OPTIONS]"
    echo ""
    echo "COMMANDS:"
    echo "  full                    Create full backup"
    echo "  inc                     Create incremental backup"  
    echo "  list                    List all backups (local and S3)"
    echo "  restore <backup>        Restore from full backup only"
    echo "  restore-chain <backup>  Restore full backup + incrementals"
    echo "  delete-chain <backup>   Delete all incrementals for a full backup"
    echo "  sync <backup-folder>    Sync specific backup to S3"
    echo "  sync-all               Sync all local backups to S3"
    echo "  analyze-chains         Analyze backup chains and find orphans"
    echo ""
    echo "OPTIONS:"
    echo "  --dry-run              Show what would be done without executing"
    echo "  --cleanup              Remove old backups (for full/inc commands)"
    echo "  --no-sync              Skip S3 sync, local backup only"
    echo "  --restore-dir=<path>   Custom restore directory (default: /tmp/restore)"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 full --cleanup                                    # Full backup with cleanup"
    echo "  $0 inc --no-sync                                     # Incremental backup, no S3 sync"
    echo "  $0 list                                              # Show backup chains"
    echo "  $0 analyze-chains <backup-pattern>               # Analyze backup chain"
    echo "  $0 restore 2025-07-06_06-00-03_full_1751781603      # Restore full backup only"
    echo "  $0 restore-chain 2025-07-06_06-00-03_full_1751781603 # Restore full + all incrementals"
    echo "  $0 restore-chain 2025-07-03_23-00-03_inc_base-*     # Restore up to specific incremental"
    echo "  $0 restore-chain 2025-07-03_23-00-03_inc_base-* --restore-dir=/mnt/restore # Custom restore dir"
    echo "  $0 sync 2025-07-03_23-00-03_inc_base-1751482801_*   # Sync specific backup"
    echo "  $0 sync-all --dry-run                               # Preview sync all"
    echo "  $0 delete-chain 2025-07-06_06-00-03_full_* --dry-run # Preview delete incrementals"
    echo "  $0 full --cleanup --dry-run                         # Preview cleanup with chain analysis"
    exit 1
fi

exit 0