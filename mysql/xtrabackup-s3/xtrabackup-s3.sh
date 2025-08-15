#!/bin/sh
# shellcheck shell=sh

##############################################################################
# Universal MySQL / MariaDB XtraBackup → S3 Script (pure POSIX /bin/sh)
# BACKUP OPERATIONS ONLY - Based on working version with sync improvements
# Maintainer : you            Last update : 20 Jul 2025
##############################################################################

set -e

# ---------------------------------------------------------------------------
# Static placeholders
# ---------------------------------------------------------------------------
CFG_EXTRA_LSN_DIR="/var/backups/mysql_lsn"
CFG_HOSTNAME=$(hostname)
CFG_DATE=$(date +%Y-%m-%d_%H-%M-%S)
CFG_TIMESTAMP=$(date +%s)
BACKUP_TOOL="" GALERA_OPTIONS=""

# Lock file for preventing concurrent backups
LOCK_FILE="/var/run/xtrabackup-s3.lock"
LOCK_ACQUIRED=0

# Cleanup function to remove lock on exit
cleanup_on_exit() {
  if [ "$LOCK_ACQUIRED" -eq 1 ]; then
    rm -f "$LOCK_FILE"
  fi
}
trap cleanup_on_exit EXIT INT TERM

# Function to acquire lock
acquire_lock() {
  if [ -f "$LOCK_FILE" ]; then
    if [ "$OPT_DRY_RUN" -eq 0 ] && [ -r "$LOCK_FILE" ]; then
      LOCK_PID=$(cat "$LOCK_FILE" | head -1 | awk '{print $2}')
      if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: Another backup is already running (PID: $LOCK_PID)"
        echo "Lock file: $LOCK_FILE"
        exit 1
      else
        echo "WARNING: Stale lock file found, removing..."
        rm -f "$LOCK_FILE"
      fi
    elif [ "$OPT_DRY_RUN" -eq 1 ]; then
      echo "WARNING: Lock file exists - another backup may be running"
      echo "Lock file: $LOCK_FILE"
    fi
  fi
  
  if [ "$OPT_DRY_RUN" -eq 0 ]; then
    echo "PID: $$ DATE: $(date) TYPE: $OPT_BACKUP_TYPE" > "$LOCK_FILE"
    LOCK_ACQUIRED=1
  fi
}

# ---------------------------------------------------------------------------
# Load user configuration (~/.xtrabackup-s3.conf)
# ---------------------------------------------------------------------------
CONFIG_FILE="$HOME/.xtrabackup-s3.conf"
[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"

# mandatory settings
if [ -z "$CFG_MC_BUCKET_PATH" ] || [ -z "$CFG_CUTOFF_DAYS" ] || [ -z "$CFG_LOCAL_BACKUP_DIR" ]; then
  echo "ERROR: CFG_MC_BUCKET_PATH, CFG_CUTOFF_DAYS and CFG_LOCAL_BACKUP_DIR are mandatory." >&2
  exit 1
fi

##############################################################################
# CLI parsing
##############################################################################
OPT_BACKUP_TYPE=${1:-}
OPT_DRY_RUN=0 OPT_CLEANUP=0 OPT_NO_SYNC=0 OPT_LOCAL_ONLY=0
BACKUP_ARGUMENTS=""

if [ $# -gt 0 ]; then
  shift
  while [ "$1" ]; do
    case "$1" in
      --dry-run)    OPT_DRY_RUN=1 ;;
      --cleanup)    OPT_CLEANUP=1 ;;
      --no-sync)    OPT_NO_SYNC=1 ;;
      --local-only) OPT_LOCAL_ONLY=1 ;;
      *)            BACKUP_ARGUMENTS="$BACKUP_ARGUMENTS $1" ;;
    esac
    shift
  done
fi

##############################################################################
detect_backup_tool() {
  echo "Detecting database type and backup tool..."
  
  if command -v mariabackup >/dev/null 2>&1; then
    BACKUP_TOOL=mariabackup
    echo "MariaDB detected - using mariabackup"
    
    if mysql --defaults-file=/root/.my.cnf -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | grep -q wsrep_cluster_size; then
      CLUSTER_SIZE=$(mysql --defaults-file=/root/.my.cnf -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null | awk '/wsrep_cluster_size/ {print $2}')
      if [ -n "$CLUSTER_SIZE" ] && [ "$CLUSTER_SIZE" != "NULL" ] && [ "$CLUSTER_SIZE" -gt 0 ]; then
        GALERA_OPTIONS="--galera-info"
        echo "Galera cluster detected (cluster size: $CLUSTER_SIZE) - adding --galera-info option"
      else
        echo "Standalone MariaDB instance detected"
      fi
    else
      echo "Standalone MariaDB instance detected"
    fi
  elif command -v xtrabackup >/dev/null 2>&1; then
    BACKUP_TOOL=xtrabackup
    echo "MySQL/Percona detected - using xtrabackup"
  else
    echo "ERROR: install xtrabackup or mariabackup." >&2
    exit 1
  fi
  
  echo "Using backup tool: $BACKUP_TOOL $GALERA_OPTIONS"
  echo ""
}

##############################################################################
# Enhanced sync function with MD5 verification
sync_to_s3() {
  LOCAL_PATH="$1"
  S3_PATH="$2"
  
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "Would sync to S3: mc mirror --retry --overwrite --md5 \"$LOCAL_PATH\" \"$S3_PATH\""
    return 0
  fi
  
  sync
  sleep 2
  
  echo "Syncing to S3: $(basename "$LOCAL_PATH")"
  
  if mc mirror --retry --overwrite --md5 "$LOCAL_PATH" "$S3_PATH"; then
    echo "Sync completed successfully"
  else
    echo "ERROR: Sync failed for $(basename "$LOCAL_PATH")"
    return 1
  fi
}

##############################################################################
cleanup_old_backups() {
  echo "Pruning old chains in S3 …"
  CUTOFF_DATE=$(date -d "$CFG_CUTOFF_DAYS days ago" +%Y-%m-%d)
  CUTOFF_NUM=$(echo "$CUTOFF_DATE" | tr -d '-')

  TMP=$(mktemp)
  mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's:/$::' | sort >"$TMP"

  grep "_full_" "$TMP" | while read -r FULL; do
    [ -z "$FULL" ] && continue
    FULL_DATE=$(echo "$FULL" | cut -d_ -f1)
    FULL_NUM=$(echo "$FULL_DATE" | tr -d '-')
    FULL_TS=$(echo "$FULL" | grep -o '[0-9]*$')

    if [ "$FULL_NUM" -lt "$CUTOFF_NUM" ]; then
      echo "  Removing chain rooted at $FULL"
      grep "_inc_base-${FULL_TS}_" "$TMP" |
      while read -r INC; do
        [ -z "$INC" ] && continue
        if [ "$OPT_DRY_RUN" -eq 1 ]; then
          echo "    [DRY-RUN] mc rb --force \"$CFG_MC_BUCKET_PATH/$INC\""
        else
          mc rb --force "$CFG_MC_BUCKET_PATH/$INC"
        fi
      done
      if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "    [DRY-RUN] mc rb --force \"$CFG_MC_BUCKET_PATH/$FULL\""
      else
        mc rb --force "$CFG_MC_BUCKET_PATH/$FULL"
      fi
    fi
  done
  rm -f "$TMP"
}

##############################################################################
analyze_backup_chains() {
  echo "=== BACKUP CHAIN ANALYSIS ==="
  TMP=$(mktemp)
  mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's:/$::' | sort >"$TMP"

  grep "_full_" "$TMP" | while read -r FULL; do
    [ -z "$FULL" ] && continue
    TS=$(echo "$FULL" | grep -o '[0-9]*$')
    INC_COUNT=$(grep -c "_inc_base-${TS}_" "$TMP" || true)
    if [ "$INC_COUNT" -gt 0 ]; then
      echo "📁 $FULL  ↳ $INC_COUNT incrementals"
    else
      echo "📁 $FULL  [stand-alone]"
    fi
  done
  rm -f "$TMP"
  echo "=== END ANALYSIS ==="
}

##############################################################################
list_backups() {
  echo "=== LOCAL BACKUPS ==="
  if [ -d "$CFG_LOCAL_BACKUP_DIR" ]; then
    find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | sort -r |
    while read -r D; do
      echo "  $(basename "$D") ($(du -sh "$D" | cut -f1))"
    done
  else
    echo "  [none]"
  fi
  echo
  if [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
    echo "=== REMOTE BACKUPS ==="
    if mc ls "$CFG_MC_BUCKET_PATH" >/dev/null 2>&1; then
      mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sort -r |
      while read -r F; do
        F=$(echo "$F" | sed 's:/$::')
        SIZE=$(mc du --depth=1 "$CFG_MC_BUCKET_PATH/$F" 2>/dev/null | tail -1 | awk '{print $1}')
        echo "  $F ($SIZE)"
      done
    else
      echo "  [cannot access bucket]"
    fi
  fi
}

##############################################################################
# ---------------------------------------------------------------------------
# MAIN DISPATCH
# ---------------------------------------------------------------------------
case "$OPT_BACKUP_TYPE" in
##############################################################################
full|inc)
  
  # --- PRE-BACKUP CLEANUP (Full Backups Only) ---
  if [ "$OPT_BACKUP_TYPE" = "full" ]; then
    echo "Checking disk space and performing pre-backup cleanup if needed..."

    LATEST_FULL_BACKUP_DIR=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '*_full_*' | sort -r | head -1)
    if [ -n "$LATEST_FULL_BACKUP_DIR" ] && [ -d "$LATEST_FULL_BACKUP_DIR" ]; then
        LAST_FULL_SIZE_MB=$(du -sm "$LATEST_FULL_BACKUP_DIR" | awk '{print $1}')
        REQUIRED_SPACE_MB=$((LAST_FULL_SIZE_MB * 120 / 100))
        echo "Last full backup size: ${LAST_FULL_SIZE_MB}MB. Required space for new full backup: ${REQUIRED_SPACE_MB}MB."
    else
        REQUIRED_SPACE_MB=5000
        echo "No previous full backup found. Using a default required space of 5000MB."
    fi

    OS_TYPE=$(uname -s)
    if [ "$OS_TYPE" = "Linux" ]; then
        AVAILABLE_SPACE_MB=$(df -m "$CFG_LOCAL_BACKUP_DIR" | tail -1 | awk '{print $4}')
    elif [ "$OS_TYPE" = "FreeBSD" ]; then
        AVAILABLE_SPACE_MB=$(df -k "$CFG_LOCAL_BACKUP_DIR" | tail -1 | awk '{print int($4/1024)}')
    else
        echo "Unsupported OS: $OS_TYPE. Cannot perform disk space check."
        AVAILABLE_SPACE_MB=0
    fi
    
    if [ "$AVAILABLE_SPACE_MB" -lt "$REQUIRED_SPACE_MB" ]; then
        echo "WARNING: Insufficient free space (${AVAILABLE_SPACE_MB}MB < ${REQUIRED_SPACE_MB}MB). Performing pre-backup cleanup."
        
        ALL_FULL_BACKUPS=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '*_full_*' | sort)
        
        if [ "$(echo "$ALL_FULL_BACKUPS" | wc -l)" -gt 1 ]; then
            OLD_FULL_BACKUP_DIR=$(echo "$ALL_FULL_BACKUPS" | head -1)
            
            echo "Removing oldest local backup: $OLD_FULL_BACKUP_DIR"
            
            FULL_TS=$(basename "$OLD_FULL_BACKUP_DIR" | grep -o '[0-9]*$')
            
            find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_inc_base-${FULL_TS}_*" | while read -r INC_BACKUP_DIR; do
                echo "  - Deleting incremental: $INC_BACKUP_DIR"
                rm -rf "$INC_BACKUP_DIR"
            done
            
            rm -rf "$OLD_FULL_BACKUP_DIR"
            echo "Cleanup complete."
        else
            echo "Only one full backup chain exists. Cannot clean up without losing local restore capability."
            exit 1
        fi
    else
        echo "Sufficient disk space available. Skipping pre-backup cleanup."
    fi
  fi
  
  # --- Main backup logic starts here ---
  acquire_lock
  detect_backup_tool
  mkdir -p "$CFG_LOCAL_BACKUP_DIR"

  # Determine backup type and parameters
  BACKUP_OPTIONS=""
  LOCAL_BACKUP_DIR=""
  
  if [ "$OPT_BACKUP_TYPE" = "inc" ]; then
    LATEST_BACKUP=""
    for backup in $(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort -r); do
        if [ -f "$backup/xtrabackup_checkpoints" ]; then
            LATEST_BACKUP="$backup"
            break
        fi
    done
    
    if [ -z "$LATEST_BACKUP" ]; then
        echo "No valid backup found in $CFG_LOCAL_BACKUP_DIR with xtrabackup_check-points file."
        echo "Please run a full backup first or sync from S3."
        exit 1
    fi
    
    LATEST_BACKUP_NAME=$(basename "$LATEST_BACKUP")
    if echo "$LATEST_BACKUP_NAME" | grep -q "_full_"; then
        BASE_TIMESTAMP=$(echo "$LATEST_BACKUP_NAME" | grep -o '[0-9]*$')
    else
        BASE_TIMESTAMP=$(echo "$LATEST_BACKUP_NAME" | sed 's/.*_inc_base-\([0-9]*\)_.*/\1/')
    fi
    
    BACKUP_OPTIONS="--incremental-basedir=$LATEST_BACKUP"
    LOCAL_BACKUP_DIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_base-${BASE_TIMESTAMP}_${CFG_TIMESTAMP}"
    
  else # Full backup
    LOCAL_BACKUP_DIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"
  fi
  
  # --- Dry-run or actual execution logic, now consolidated ---
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "Dry run: would run $OPT_BACKUP_TYPE backup"
    echo "Would create: $LOCAL_BACKUP_DIR"
    echo "Command: $BACKUP_TOOL --backup $BACKUP_OPTIONS $GALERA_OPTIONS --target-dir=\"$LOCAL_BACKUP_DIR\""
    if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
      echo "Would skip S3 sync"
    else
      echo "Would sync to: $CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
    fi
    [ "$OPT_CLEANUP" -eq 1 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ] && echo "Would also prune old chains in S3"
    exit 0
  fi
  
  # Actual execution
  mkdir -p "$LOCAL_BACKUP_DIR"
  
  if [ "$BACKUP_TOOL" = "mariabackup" ]; then
    if ! mariabackup --backup $BACKUP_OPTIONS $GALERA_OPTIONS --target-dir="$LOCAL_BACKUP_DIR"; then
      echo "$OPT_BACKUP_TYPE backup failed!"
      exit 1
    fi
  else # xtrabackup
    if ! xtrabackup --backup $BACKUP_OPTIONS $GALERA_OPTIONS --extra-lsndir="$LOCAL_BACKUP_DIR" --target-dir="$LOCAL_BACKUP_DIR"; then
      echo "$OPT_BACKUP_TYPE backup failed!"
      exit 1
    fi
  fi
  echo "$OPT_BACKUP_TYPE backup completed locally"

  if [ "$OPT_NO_SYNC" -eq 0 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
    sync_to_s3 "$LOCAL_BACKUP_DIR" "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
  fi

  [ "$OPT_CLEANUP" -eq 1 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ] && cleanup_old_backups
  ;;
  
##############################################################################
cleanup)
  echo "Starting manual cleanup..."
  
  if [ "$OPT_DRY_RUN" -eq 1 ]; then
      echo "[DRY-RUN] Would perform cleanup."
  fi
  
  # Local cleanup
  KEEP_COUNT="${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}"
  echo "Pruning local backups (keeping ${KEEP_COUNT})..."
  ALL_FULL_BACKUPS=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '*_full_*' | sort)
  COUNT=$(echo "$ALL_FULL_BACKUPS" | wc -l)
  
  if [ "$COUNT" -gt "$KEEP_COUNT" ]; then
      echo "$((COUNT - KEEP_COUNT)) old full backup chain(s) to be removed."
      echo "$ALL_FULL_BACKUPS" | head -n $((COUNT - KEEP_COUNT)) | while read -r OLD_FULL_BACKUP_DIR; do
          if [ "$OPT_DRY_RUN" -eq 1 ]; then
              echo "  [DRY-RUN] Removing local chain rooted at: $OLD_FULL_BACKUP_DIR"
          else
              echo "  Removing local chain rooted at: $OLD_FULL_BACKUP_DIR"
              FULL_TS=$(basename "$OLD_FULL_BACKUP_DIR" | grep -o '[0-9]*$')
              find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_inc_base-${FULL_TS}_*" | while read -r INC_BACKUP_DIR; do
                  rm -rf "$INC_BACKUP_DIR"
              done
              rm -rf "$OLD_FULL_BACKUP_DIR"
          fi
      done
  else
      echo "No old local backup chains to remove."
  fi
  
  # S3 cleanup
  if [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
      cleanup_old_backups
  else
      echo "Skipping S3 cleanup (--local-only specified)."
  fi
  
  echo "Manual cleanup finished."
  ;;

##############################################################################
sync)
  FOLDER=$(echo "$BACKUP_ARGUMENTS" | awk '{print $1}')
  [ -n "$FOLDER" ] || { echo "Need folder to sync." >&2; exit 1; }

  if [ -d "$FOLDER" ]; then
    LOCAL="$FOLDER"
  elif [ -d "$CFG_LOCAL_BACKUP_DIR/$FOLDER" ]; then
    LOCAL="$CFG_LOCAL_BACKUP_DIR/$FOLDER"
  else
    echo "Folder not found: $FOLDER" >&2; exit 1
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "# DRY-RUN sync"
    echo "Would sync: $LOCAL -> $CFG_MC_BUCKET_PATH/$(basename "$LOCAL")"
    exit 0
  fi

  sync_to_s3 "$LOCAL" "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL")"
  ;;

##############################################################################
sync-all)
  [ -d "$CFG_LOCAL_BACKUP_DIR" ] || { echo "No local backups." >&2; exit 0; }

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "# DRY-RUN sync-all"
    find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | sort |
    while read -r D; do
      echo "Would sync: $D -> $CFG_MC_BUCKET_PATH/$(basename "$D")"
    done
    exit 0
  fi

  find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | sort |
  while read -r D; do
    sync_to_s3 "$D" "$CFG_MC_BUCKET_PATH/$(basename "$D")"
  done
  ;;

##############################################################################
delete-chain)
  FULL_BACKUP=$(echo "$BACKUP_ARGUMENTS" | awk '{print $1}')
  [ -n "$FULL_BACKUP" ] || { echo "Need full backup name." >&2; exit 1; }

  TS=$(echo "$FULL_BACKUP" | grep -o '[0-9]*$')
  [ -n "$TS" ] || { echo "Timestamp missing in name." >&2; exit 1; }

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "# DRY-RUN delete-chain for $FULL_BACKUP"
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' |
      grep "_inc_base-${TS}_" | sed 's:/$::' |
      while read -r INC; do
        echo "mc rb --force \"$CFG_MC_BUCKET_PATH/$INC\""
      done
    exit 0
  fi

  mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' |
  grep "_inc_base-${TS}_" | sed 's:/$::' |
  while read -r INC; do
    mc rb --force "$CFG_MC_BUCKET_PATH/$INC"
  done
  ;;

##############################################################################
analyze-chains) analyze_backup_chains ;;
list)           list_backups ;;
*)
  cat <<'EOF'
Usage: xtrabackup-s3.sh {full|inc|cleanup|list|sync|sync-all|delete-chain|analyze-chains} [OPTIONS]

BACKUP OPERATIONS:
  full                Create a full backup
  inc                 Create an incremental backup
  
MANAGEMENT:  
  cleanup             Delete old backups (local and S3)
  list                List local & S3 backups
  sync <folder>       Sync one local backup folder to S3
  sync-all            Sync every local backup to S3
  delete-chain <full> Delete every incremental for <full>
  analyze-chains      Show backup chains / orphans

Common options:
  --dry-run           Print every command, do nothing
  --cleanup           After backup, prune old chains in S3
  --no-sync           Skip S3 mirror step
  --local-only        Ignore S3 entirely (skip mirror / cleanup)

For restore operations, use: xtrabackup-s3-restore.sh
EOF
  exit 1
  ;;
esac

exit 0