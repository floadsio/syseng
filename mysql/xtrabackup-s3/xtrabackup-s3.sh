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
                    size=`mc du "$CFG_MC_BUCKET_PATH/$full_folder" 2>/dev/null | awk '{print $1}' || echo "unknown"`
                    timestamp=`echo "$full_folder" | grep -o '[0-9]*$'`
                    echo "$full_folder ($size) [FULL]"
                    
                    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | grep "_inc_base-${timestamp}_" | sort | while read inc_folder; do
                        inc_folder=`echo "$inc_folder" | sed 's/\/$//'`
                        if [ -n "$inc_folder" ]; then
                            inc_size=`mc du "$CFG_MC_BUCKET_PATH/$inc_folder" 2>/dev/null | awk '{print $1}' || echo "unknown"`
                            echo "  -> $inc_folder ($inc_size) [INC]"
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
            echo "Original full backup timestamp: $BASE_TIMESTAMP"
            echo "Would create: $LOCAL_BACKUP_DIR"
            echo "Command: $BACKUP_CMD --defaults-file=<temp_config> --backup ${CFG_INCREMENTAL} $GALERA_OPTIONS --target-dir=\"$LOCAL_BACKUP_DIR\""
            if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
                echo "Would skip S3 sync (local backup only)"
            else
                LOCAL_BACKUP_NAME=`basename "$LOCAL_BACKUP_DIR"`
                echo "Would mirror to: $CFG_MC_BUCKET_PATH/$LOCAL_BACKUP_NAME"
            fi
        else
            mkdir -p "$LOCAL_BACKUP_DIR"
            
            # Run backup with appropriate tool and options
            if [ "$BACKUP_TOOL" = "mariabackup" ]; then
                # MariaBackup incremental backup - create temporary config without XtraBackup-specific options
                TEMP_CNF=`mktemp`
                echo "[mariabackup]" > "$TEMP_CNF"
                echo "user=root" >> "$TEMP_CNF"
                # Copy password if it exists in original config
                if grep -q "^password" /root/.my.cnf 2>/dev/null; then
                    grep "^password" /root/.my.cnf >> "$TEMP_CNF"
                fi
                
                $BACKUP_CMD --defaults-file="$TEMP_CNF" \
                    --backup ${CFG_INCREMENTAL} $GALERA_OPTIONS \
                    --target-dir="$LOCAL_BACKUP_DIR"
                
                rm -f "$TEMP_CNF"
            else
                # XtraBackup supports --extra-lsndir
                $BACKUP_CMD --backup ${CFG_INCREMENTAL} $GALERA_OPTIONS \
                    --extra-lsndir="$LOCAL_BACKUP_DIR" \
                    --target-dir="$LOCAL_BACKUP_DIR"
            fi

            if [ $? -ne 0 ]; then
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
            echo "Would cleanup old local backups (keeping ${CFG_LOCAL_BACKUP_KEEP_COUNT:-4})"
            echo "Command: $BACKUP_CMD --defaults-file=<temp_config> --backup $GALERA_OPTIONS --target-dir=\"$LOCAL_BACKUP_DIR\""
            if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
                echo "Would skip S3 sync (local backup only)"
            else
                LOCAL_BACKUP_NAME=`basename "$LOCAL_BACKUP_DIR"`
                echo "Would mirror to: $CFG_MC_BUCKET_PATH/$LOCAL_BACKUP_NAME"
            fi
        else
            mkdir -p "$LOCAL_BACKUP_DIR"
            
            KEEP_COUNT="${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}"
            BACKUP_COUNT=`find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | wc -l`
            if [ "$BACKUP_COUNT" -gt "$KEEP_COUNT" ]; then
                REMOVE_COUNT=`expr $BACKUP_COUNT - $KEEP_COUNT`
                find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort | head -n "$REMOVE_COUNT" | while read OLD; do
                    rm -rf "$OLD"
                done
            fi

            # Run backup with appropriate tool and options
            if [ "$BACKUP_TOOL" = "mariabackup" ]; then
                # MariaBackup - create temporary config without XtraBackup-specific options
                TEMP_CNF=`mktemp`
                echo "[mariabackup]" > "$TEMP_CNF"
                echo "user=root" >> "$TEMP_CNF"
                # Copy password if it exists in original config
                if grep -q "^password" /root/.my.cnf 2>/dev/null; then
                    grep "^password" /root/.my.cnf >> "$TEMP_CNF"
                fi
                
                $BACKUP_CMD --defaults-file="$TEMP_CNF" \
                    --backup $GALERA_OPTIONS \
                    --target-dir="$LOCAL_BACKUP_DIR"
                
                rm -f "$TEMP_CNF"
            else
                # XtraBackup supports --extra-lsndir
                $BACKUP_CMD --backup $GALERA_OPTIONS \
                    --extra-lsndir="$LOCAL_BACKUP_DIR" \
                    --target-dir="$LOCAL_BACKUP_DIR"
            fi

            if [ $? -ne 0 ]; then
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
            echo "Local-only mode: skipping S3 cleanup, performing local cleanup only..."
            KEEP_COUNT="${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}"
            BACKUP_COUNT=`find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | wc -l`
            if [ "$BACKUP_COUNT" -gt "$KEEP_COUNT" ]; then
                REMOVE_COUNT=`expr $BACKUP_COUNT - $KEEP_COUNT`
                find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort | head -n "$REMOVE_COUNT" | while read OLD; do
                    OLD_NAME=`basename "$OLD"`
                    echo "Removing old local backup: $OLD_NAME"
                    rm -rf "$OLD"
                done
            fi
            echo "Local cleanup completed."
        else
            echo "S3 cleanup not implemented in this simplified version"
        fi
    fi

elif [ "$OPT_BACKUP_TYPE" = "list" ]; then
    list_backups

else
    echo "MySQL XtraBackup S3 Management Script"
    echo ""
    echo "Usage: $0 {full|inc|list} [OPTIONS]"
    echo ""
    echo "COMMANDS:"
    echo "  full                    Create full backup"
    echo "  inc                     Create incremental backup"  
    echo "  list                    List all backups (local and S3)"
    echo ""
    echo "OPTIONS:"
    echo "  --dry-run              Show what would be done without executing"
    echo "  --cleanup              Remove old backups (for full/inc commands)"
    echo "  --no-sync              Skip S3 sync, local backup only"
    echo "  --local-only           Skip all S3 operations (backup, cleanup, list)"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 full --cleanup --local-only                      # Full backup with local cleanup only"
    echo "  $0 inc --local-only                                 # Incremental backup, no S3 at all"
    echo "  $0 list --local-only                               # Show only local backups"
    echo "  $0 full --cleanup                                    # Full backup with cleanup"
    echo "  $0 inc --no-sync                                     # Incremental backup, no S3 sync"
    echo "  $0 list                                              # Show backup chains"
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