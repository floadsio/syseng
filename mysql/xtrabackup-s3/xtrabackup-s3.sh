#!/bin/sh

# Universal MySQL/MariaDB XtraBackup S3 Script
# Supports both xtrabackup (MySQL/Percona) and mariabackup (MariaDB/Galera)

CFG_EXTRA_LSN_DIR="/var/backups/mysql_lsn"
CFG_HOSTNAME=`hostname`
CFG_DATE=`date +%Y-%m-%d_%H-%M-%S`
CFG_TIMESTAMP=`date +%s`
CFG_INCREMENTAL=""

# Backup tool detection variables
BACKUP_TOOL=""
BACKUP_CMD=""
GALERA_OPTIONS=""

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

OPT_BACKUP_TYPE="${1:-}"
OPT_DRY_RUN=0
OPT_CLEANUP=0
OPT_NO_SYNC=0
OPT_LOCAL_ONLY=0
OPT_RESTORE_DIR=""

# Function to detect database type and set backup tool
detect_backup_tool() {
    echo "Detecting database type and backup tool..."
    
    # Check if mariabackup is available
    if command -v mariabackup >/dev/null 2>&1; then
        BACKUP_TOOL="mariabackup"
        BACKUP_CMD="mariabackup"
        echo "MariaDB detected - using mariabackup"
        
        # Check if this is a Galera cluster
        if mysql --defaults-file=/root/.my.cnf -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | grep -q wsrep_cluster_size; then
            GALERA_OPTIONS="--galera-info"
            echo "Galera cluster detected - adding --galera-info option"
        else
            echo "Standalone MariaDB instance detected"
        fi
        
    # Check if xtrabackup is available  
    elif command -v xtrabackup >/dev/null 2>&1; then
        BACKUP_TOOL="xtrabackup"
        BACKUP_CMD="xtrabackup"
        echo "MySQL/Percona detected - using xtrabackup"
        GALERA_OPTIONS=""
        
    else
        echo "ERROR: No backup tool found!"
        echo "Please install either:"
        echo "  - mariabackup (for MariaDB): apt install mariadb-backup"
        echo "  - xtrabackup (for MySQL/Percona): apt install percona-xtrabackup-80"
        exit 1
    fi
    
    echo "Using backup tool: $BACKUP_CMD $GALERA_OPTIONS"
    echo ""
}

# Parse command line arguments
if [ $# -gt 0 ]; then
    shift
    while [ "$1" != "" ]; do
        case "$1" in
            --dry-run) OPT_DRY_RUN=1 ;;
            --cleanup) OPT_CLEANUP=1 ;;
            --no-sync) OPT_NO_SYNC=1 ;;
            --local-only) OPT_LOCAL_ONLY=1 ;;
            --restore-dir=*) 
                OPT_RESTORE_DIR=`echo "$1" | cut -d= -f2`
                ;;
            *) 
                BACKUP_ARGUMENTS="$BACKUP_ARGUMENTS $1"
                ;;
        esac
        shift
    done
fi

# Function to cleanup old backups
cleanup_old_backups() {
    echo "Starting chain-aware cleanup of old backups..."
    CUTOFF_DATE=`date -d "$CFG_CUTOFF_DAYS days ago" +%Y-%m-%d`
    echo "Cutoff date: $CUTOFF_DATE"
    
    # Get all backups and sort them
    TEMP_FILE=`mktemp`
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's/\/$//' | sort > "$TEMP_FILE"
    
    # Find all full backups
    FULL_BACKUPS=`grep "_full_" "$TEMP_FILE"`
    
    echo "Found full backups:"
    echo "$FULL_BACKUPS"
    echo ""
    
    # Process each full backup and its incremental chain
    echo "$FULL_BACKUPS" | while read FULL_BACKUP; do
        if [ -z "$FULL_BACKUP" ]; then
            continue
        fi
        
        FULL_DATE=`echo "$FULL_BACKUP" | cut -d_ -f1`
        FULL_TIMESTAMP=`echo "$FULL_BACKUP" | grep -o '[0-9]*$'`
        
        echo "Checking backup chain for: $FULL_BACKUP (date: $FULL_DATE)"
        
        # Find all incrementals for this full backup
        INCREMENTALS=`grep "_inc_base-${FULL_TIMESTAMP}_" "$TEMP_FILE" || true`
        
        if [ "$FULL_DATE" \< "$CUTOFF_DATE" ]; then
            echo "  Full backup $FULL_BACKUP is older than cutoff"
            
            if [ "$OPT_DRY_RUN" -eq 1 ]; then
                echo "  [DRY RUN] Would delete full backup: $FULL_BACKUP"
                if [ -n "$INCREMENTALS" ]; then
                    echo "$INCREMENTALS" | while read inc; do
                        [ -n "$inc" ] && echo "  [DRY RUN] Would delete incremental: $inc"
                    done
                fi
            else
                echo "  Deleting full backup: $FULL_BACKUP"
                mc rb --force "$CFG_MC_BUCKET_PATH/$FULL_BACKUP"
                
                if [ -n "$INCREMENTALS" ]; then
                    echo "$INCREMENTALS" | while read inc; do
                        if [ -n "$inc" ]; then
                            echo "  Deleting incremental: $inc"
                            mc rb --force "$CFG_MC_BUCKET_PATH/$inc"
                        fi
                    done
                fi
            fi
        else
            echo "  Full backup $FULL_BACKUP is within retention period"
        fi
        echo ""
    done
    
    rm -f "$TEMP_FILE"
    echo "Chain-aware cleanup completed."
}

# Function to analyze backup chains
analyze_backup_chains() {
    echo "=== BACKUP CHAIN ANALYSIS ==="
    
    TEMP_FILE=`mktemp`
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's/\/$//' | sort > "$TEMP_FILE"
    
    FULL_BACKUPS=`grep "_full_" "$TEMP_FILE"`
    
    echo "Current backup chains:"
    echo "$FULL_BACKUPS" | while read FULL_BACKUP; do
        if [ -n "$FULL_BACKUP" ]; then
            FULL_TIMESTAMP=`echo "$FULL_BACKUP" | grep -o '[0-9]*$'`
            INCREMENTALS_COUNT=`grep "_inc_base-${FULL_TIMESTAMP}_" "$TEMP_FILE" | wc -l`
            
            if [ "$INCREMENTALS_COUNT" -gt 0 ]; then
                echo "📁 $FULL_BACKUP"
                echo "   ↳ $INCREMENTALS_COUNT incrementals"
            else
                echo "📁 $FULL_BACKUP [standalone]"
            fi
        fi
    done
    
    rm -f "$TEMP_FILE"
    echo ""
    echo "=== END ANALYSIS ==="
}

# Function to list backups
list_backups() {
    echo "=== LOCAL BACKUPS ==="
    if [ -n "$CFG_LOCAL_BACKUP_DIR" ] && [ -d "$CFG_LOCAL_BACKUP_DIR" ]; then
        find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_full_*" | sort -r | while read full_backup; do
            if [ -d "$full_backup" ]; then
                backup_name=`basename "$full_backup"`
                size=`du -sh "$full_backup" 2>/dev/null | cut -f1`
                timestamp=`echo "$backup_name" | grep -o '[0-9]*$'`
                echo "$backup_name ($size) [FULL]"
                
                find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_inc_base-${timestamp}_*" | sort | while read inc_backup; do
                    if [ -d "$inc_backup" ]; then
                        inc_name=`basename "$inc_backup"`
                        inc_size=`du -sh "$inc_backup" 2>/dev/null | cut -f1`
                        echo "  -> $inc_name ($inc_size) [INC]"
                    fi
                done
            fi
        done
    else
        echo "  No local backup directory configured or found"
    fi
    
    if [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
        echo ""
        echo "=== S3 BACKUPS SKIPPED (--local-only mode) ==="
    else
        echo ""
        echo "=== REMOTE BACKUPS (S3) ==="
        if mc ls "$CFG_MC_BUCKET_PATH" >/dev/null 2>&1; then
            mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | grep "_full_" | sort -r | while read full_folder; do
                full_folder=`echo "$full_folder" | sed 's/\/$//'`
                if [ -n "$full_folder" ]; then
                    timestamp=`echo "$full_folder" | grep -o '[0-9]*$'`
                    echo "$full_folder [FULL]"
                    
                    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | grep "_inc_base-${timestamp}_" | sort | while read inc_folder; do
                        inc_folder=`echo "$inc_folder" | sed 's/\/$//'`
                        if [ -n "$inc_folder" ]; then
                            echo "  -> $inc_folder [INC]"
                        fi
                    done
                fi
            done
        else
            echo "  Could not access remote backups (check mc config)"
        fi
    fi
}

# Main logic starts here
if [ "$OPT_BACKUP_TYPE" = "full" ] || [ "$OPT_BACKUP_TYPE" = "inc" ]; then
    # Detect backup tool before running any backup operations
    detect_backup_tool
    
    if [ -z "$CFG_LOCAL_BACKUP_DIR" ]; then
        echo "ERROR: CFG_LOCAL_BACKUP_DIR must be configured for all backup operations."
        exit 1
    fi

    if [ "$OPT_BACKUP_TYPE" = "inc" ]; then
        LATEST_BACKUP=`find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort -r | head -n 1`
        if [ -z "$LATEST_BACKUP" ]; then
            echo "No previous backup found in $CFG_LOCAL_BACKUP_DIR. Please run a full backup first."
            exit 1
        fi

        LATEST_BACKUP_NAME=`basename "$LATEST_BACKUP"`
        if echo "$LATEST_BACKUP_NAME" | grep -q "_full_"; then
            BASE_TIMESTAMP=`echo "$LATEST_BACKUP_NAME" | grep -o '[0-9]*$'`
        else
            BASE_TIMESTAMP=`echo "$LATEST_BACKUP_NAME" | sed 's/.*_inc_base-\([0-9]*\)_.*/\1/'`
        fi

        CFG_INCREMENTAL="--incremental-basedir=$LATEST_BACKUP"
        LOCAL_BACKUP_DIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_base-${BASE_TIMESTAMP}_${CFG_TIMESTAMP}"

        if [ "$OPT_DRY_RUN" -eq 1 ]; then
            echo "Dry run: would run incremental backup"
            echo "Backup tool: $BACKUP_CMD $GALERA_OPTIONS"
            echo "Base backup: $LATEST_BACKUP"
            echo "Would create: $LOCAL_BACKUP_DIR"
            if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
                echo "Would skip S3 sync (local backup only)"
            else
                LOCAL_BACKUP_NAME=`basename "$LOCAL_BACKUP_DIR"`
                echo "Would mirror to: $CFG_MC_BUCKET_PATH/$LOCAL_BACKUP_NAME"
            fi
        else
            mkdir -p "$LOCAL_BACKUP_DIR"
            
            # Run backup with appropriate tool
            if [ "$BACKUP_TOOL" = "mariabackup" ]; then
                TEMP_CNF=`mktemp`
                echo "[mariabackup]" > "$TEMP_CNF"
                echo "user=root" >> "$TEMP_CNF"
                if grep -q "^password" /root/.my.cnf 2>/dev/null; then
                    grep "^password" /root/.my.cnf >> "$TEMP_CNF"
                fi
                
                $BACKUP_CMD --defaults-file="$TEMP_CNF" --backup ${CFG_INCREMENTAL} $GALERA_OPTIONS --target-dir="$LOCAL_BACKUP_DIR"
                BACKUP_RESULT=$?
                rm -f "$TEMP_CNF"
            else
                $BACKUP_CMD --backup ${CFG_INCREMENTAL} $GALERA_OPTIONS --extra-lsndir="$LOCAL_BACKUP_DIR" --target-dir="$LOCAL_BACKUP_DIR"
                BACKUP_RESULT=$?
            fi
            
            if [ $BACKUP_RESULT -ne 0 ]; then
                echo "Incremental backup failed!"
                exit 1
            fi
            
            if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
                echo "`date '+%F %T'`: Incremental backup completed (local only, S3 sync skipped)"
            else
                LOCAL_BACKUP_NAME=`basename "$LOCAL_BACKUP_DIR"`
                mc mirror --retry --overwrite "$LOCAL_BACKUP_DIR" "$CFG_MC_BUCKET_PATH/$LOCAL_BACKUP_NAME"
                echo "`date '+%F %T'`: Incremental backup completed and mirrored to S3"
            fi
        fi
    else
        # Full backup
        LOCAL_BACKUP_DIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"

        if [ "$OPT_DRY_RUN" -eq 1 ]; then
            echo "Dry run: would run full backup"
            echo "Backup tool: $BACKUP_CMD $GALERA_OPTIONS"
            echo "Would create: $LOCAL_BACKUP_DIR"
            if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
                echo "Would skip S3 sync (local backup only)"
            else
                LOCAL_BACKUP_NAME=`basename "$LOCAL_BACKUP_DIR"`
                echo "Would mirror to: $CFG_MC_BUCKET_PATH/$LOCAL_BACKUP_NAME"
            fi
        else
            mkdir -p "$LOCAL_BACKUP_DIR"
            
            # Cleanup old local backups
            KEEP_COUNT="${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}"
            BACKUP_COUNT=`find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | wc -l`
            if [ "$BACKUP_COUNT" -gt "$KEEP_COUNT" ]; then
                REMOVE_COUNT=`expr $BACKUP_COUNT - $KEEP_COUNT`
                find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort | head -n "$REMOVE_COUNT" | while read OLD; do
                    rm -rf "$OLD"
                done
            fi

            # Run backup with appropriate tool
            if [ "$BACKUP_TOOL" = "mariabackup" ]; then
                TEMP_CNF=`mktemp`
                echo "[mariabackup]" > "$TEMP_CNF"
                echo "user=root" >> "$TEMP_CNF"
                if grep -q "^password" /root/.my.cnf 2>/dev/null; then
                    grep "^password" /root/.my.cnf >> "$TEMP_CNF"
                fi
                
                $BACKUP_CMD --defaults-file="$TEMP_CNF" --backup $GALERA_OPTIONS --target-dir="$LOCAL_BACKUP_DIR"
                BACKUP_RESULT=$?
                rm -f "$TEMP_CNF"
            else
                $BACKUP_CMD --backup $GALERA_OPTIONS --extra-lsndir="$LOCAL_BACKUP_DIR" --target-dir="$LOCAL_BACKUP_DIR"
                BACKUP_RESULT=$?
            fi

            if [ $BACKUP_RESULT -ne 0 ]; then
                echo "Full backup failed!"
                exit 1
            fi

            if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
                echo "`date '+%F %T'`: Full backup completed (local only, S3 sync skipped)"
            else
                LOCAL_BACKUP_NAME=`basename "$LOCAL_BACKUP_DIR"`
                mc mirror --retry --overwrite "$LOCAL_BACKUP_DIR" "$CFG_MC_BUCKET_PATH/$LOCAL_BACKUP_NAME"
                echo "`date '+%F %T'`: Full backup completed and mirrored to S3"
            fi
        fi
    fi

    if [ "$OPT_CLEANUP" -eq 1 ]; then
        if [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
            echo "Local-only mode: skipping S3 cleanup"
        else
            cleanup_old_backups
        fi
    fi

elif [ "$OPT_BACKUP_TYPE" = "restore" ]; then
    FULL_BACKUP=`echo $BACKUP_ARGUMENTS | awk '{print $1}'`
    if [ -z "$FULL_BACKUP" ]; then
        echo "ERROR: No full backup specified for restore."
        exit 1
    fi

    detect_backup_tool

    # Check if backup exists locally first
    if [ -d "$CFG_LOCAL_BACKUP_DIR/$FULL_BACKUP" ]; then
        BACKUP_SOURCE="$CFG_LOCAL_BACKUP_DIR/$FULL_BACKUP"
        BACKUP_LOCATION="local"
        echo "Using local backup: $BACKUP_SOURCE"
    else
        BACKUP_SOURCE="${CFG_MC_BUCKET_PATH}/${FULL_BACKUP}"
        BACKUP_LOCATION="s3"
        echo "Using S3 backup: $BACKUP_SOURCE"
    fi

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: showing what would be executed"
        echo "systemctl stop mysql"
        echo "rm -rf /var/lib/mysql/*"
        if [ "$BACKUP_LOCATION" = "local" ]; then
            echo "cp -r \"$BACKUP_SOURCE\"/* /var/lib/mysql/"
        else
            echo "mc mirror --overwrite --remove \"$BACKUP_SOURCE\" /var/lib/mysql"
        fi
        echo "$BACKUP_CMD --prepare --target-dir=/var/lib/mysql"
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

    echo "Restoring full backup from $BACKUP_LOCATION: $FULL_BACKUP"
    if [ "$BACKUP_LOCATION" = "local" ]; then
        cp -r "$BACKUP_SOURCE"/* /var/lib/mysql/
    else
        mc mirror --overwrite --remove "$BACKUP_SOURCE" /var/lib/mysql
    fi

    echo "Preparing restored data..."
    if [ "$BACKUP_TOOL" = "mariabackup" ]; then
        TEMP_CNF=`mktemp`
        echo "[mariabackup]" > "$TEMP_CNF"
        echo "user=root" >> "$TEMP_CNF"
        if grep -q "^password" /root/.my.cnf 2>/dev/null; then
            grep "^password" /root/.my.cnf >> "$TEMP_CNF"
        fi
        
        $BACKUP_CMD --defaults-file="$TEMP_CNF" --prepare --target-dir=/var/lib/mysql
        rm -f "$TEMP_CNF"
    else
        $BACKUP_CMD --prepare --target-dir=/var/lib/mysql
    fi

    echo "Fixing permissions..."
    chown -R mysql:mysql /var/lib/mysql

    echo "Starting MySQL..."
    systemctl start mysql

    echo "✅ Full backup restored successfully from $BACKUP_LOCATION: $FULL_BACKUP"

elif [ "$OPT_BACKUP_TYPE" = "sync" ]; then
    BACKUP_FOLDER=`echo $BACKUP_ARGUMENTS | awk '{print $1}'`
    if [ -z "$BACKUP_FOLDER" ]; then
        echo "ERROR: No backup folder specified for sync."
        exit 1
    fi

    if [ -d "$BACKUP_FOLDER" ]; then
        LOCAL_BACKUP_PATH="$BACKUP_FOLDER"
    elif [ -d "$CFG_LOCAL_BACKUP_DIR/$BACKUP_FOLDER" ]; then
        LOCAL_BACKUP_PATH="$CFG_LOCAL_BACKUP_DIR/$BACKUP_FOLDER"
    else
        echo "ERROR: Backup folder not found: $BACKUP_FOLDER"
        exit 1
    fi

    BACKUP_NAME=`basename "$LOCAL_BACKUP_PATH"`
    
    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: would sync $BACKUP_NAME to S3"
        exit 0
    fi

    echo "Syncing backup to S3: $BACKUP_NAME"
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

    BACKUP_DIRS=`find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort`
    
    if [ -z "$BACKUP_DIRS" ]; then
        echo "No backup directories found in $CFG_LOCAL_BACKUP_DIR"
        exit 0
    fi

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: would sync all backups to S3"
        echo "$BACKUP_DIRS" | while read backup_dir; do
            if [ -d "$backup_dir" ]; then
                backup_name=`basename "$backup_dir"`
                echo "  Would sync: $backup_name"
            fi
        done
        exit 0
    fi

    echo "Syncing all local backups to S3..."
    echo "$BACKUP_DIRS" | while read backup_dir; do
        if [ -d "$backup_dir" ]; then
            backup_name=`basename "$backup_dir"`
            echo "Syncing: $backup_name"
            mc mirror --retry --overwrite "$backup_dir" "$CFG_MC_BUCKET_PATH/$backup_name"
        fi
    done
    echo "✅ All backups synced successfully!"

elif [ "$OPT_BACKUP_TYPE" = "delete-chain" ]; then
    FULL_BACKUP=`echo $BACKUP_ARGUMENTS | awk '{print $1}'`
    if [ -z "$FULL_BACKUP" ]; then
        echo "ERROR: No full backup specified for chain deletion."
        exit 1
    fi

    FULL_TIMESTAMP=`echo "$FULL_BACKUP" | grep -o '[0-9]*$'`
    if [ -z "$FULL_TIMESTAMP" ]; then
        echo "ERROR: Could not extract timestamp from backup name: $FULL_BACKUP"
        exit 1
    fi

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "# Dry run: would delete incrementals for $FULL_BACKUP"
        mc ls "$CFG_MC_BUCKET_PATH" 2>/dev/null | awk '{print $NF}' | grep "_inc_base-${FULL_TIMESTAMP}_" | while read inc_folder; do
            inc_folder=`echo "$inc_folder" | sed 's/\/$//'`
            if [ -n "$inc_folder" ]; then
                echo "  Would delete: $inc_folder"
            fi
        done
        exit 0
    fi

    echo "Deleting incremental backups for: $FULL_BACKUP"
    mc ls "$CFG_MC_BUCKET_PATH" 2>/dev/null | awk '{print $NF}' | grep "_inc_base-${FULL_TIMESTAMP}_" | while read inc_folder; do
        inc_folder=`echo "$inc_folder" | sed 's/\/$//'`
        if [ -n "$inc_folder" ]; then
            echo "Deleting: $inc_folder"
            mc rb --force "$CFG_MC_BUCKET_PATH/$inc_folder"
        fi
    done
    echo "✅ Incremental chain deletion completed"

elif [ "$OPT_BACKUP_TYPE" = "analyze-chains" ]; then
    analyze_backup_chains

elif [ "$OPT_BACKUP_TYPE" = "list" ]; then
    list_backups

else
    echo "Universal MySQL/MariaDB XtraBackup S3 Management Script"
    echo ""
    echo "Usage: $0 {full|inc|list|restore|sync|sync-all|delete-chain|analyze-chains} [OPTIONS]"
    echo ""
    echo "COMMANDS:"
    echo "  full                    Create full backup"
    echo "  inc                     Create incremental backup"  
    echo "  list                    List all backups (local and S3)"
    echo "  restore <backup>        Restore from full backup"
    echo "  sync <backup-folder>    Sync specific backup to S3"
    echo "  sync-all               Sync all local backups to S3"
    echo "  delete-chain <backup>   Delete all incrementals for a full backup"
    echo "  analyze-chains         Analyze backup chains and find orphans"
    echo ""
    echo "OPTIONS:"
    echo "  --dry-run              Show what would be done without executing"
    echo "  --cleanup              Remove old backups (for full/inc commands)"
    echo "  --no-sync              Skip S3 sync, local backup only"
    echo "  --local-only           Skip all S3 operations completely"
    echo "  --restore-dir=<path>   Custom restore directory (default: /tmp/restore)"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 full --cleanup --local-only                      # Full backup with local cleanup only"
    echo "  $0 inc --local-only                                 # Incremental backup, no S3 at all"
    echo "  $0 list --local-only                               # Show only local backups"
    echo "  $0 restore 2025-07-18_08-57-49_full_1750928269     # Restore full backup"
    echo "  $0 sync 2025-07-18_12-00-00_inc_base-1750928269_1750939200 # Sync specific backup"
    echo "  $0 sync-all --dry-run                               # Preview sync all"
    echo "  $0 delete-chain 2025-07-18_08-57-49_full_1750928269 --dry-run # Preview delete"
    echo "  $0 analyze-chains                                   # Analyze backup chains"
    echo ""
    echo "DATABASE COMPATIBILITY:"
    echo "  MySQL/Percona Server (uses xtrabackup)"
    echo "  MariaDB (uses mariabackup)"
    echo "  MariaDB Galera Cluster (uses mariabackup --galera-info)"
    echo ""
    echo "The script automatically detects your database type and uses the appropriate backup tool."
    exit 1
fi

exit 0