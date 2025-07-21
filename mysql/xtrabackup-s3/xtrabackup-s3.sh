#!/bin/sh
# shellcheck shell=sh

##############################################################################
# Universal MySQL / MariaDB XtraBackup → S3 Script  (pure POSIX /bin/sh)
# BACKUP OPERATIONS ONLY - Based on working version with sync improvements
# Maintainer : you            Last update : 20 Jul 2025
##############################################################################

set -e

# ---------------------------------------------------------------------------
# Static placeholders (kept for compatibility / hooks)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
CFG_EXTRA_LSN_DIR="/var/backups/mysql_lsn"
# shellcheck disable=SC2034
CFG_HOSTNAME=$(hostname)
CFG_DATE=$(date +%Y-%m-%d_%H-%M-%S)
CFG_TIMESTAMP=$(date +%s)
# shellcheck disable=SC2034
CFG_INCREMENTAL=""

BACKUP_TOOL="" BACKUP_CMD="" GALERA_OPTIONS=""

# ---------------------------------------------------------------------------
# Load user configuration (~/.xtrabackup-s3.conf)
# ---------------------------------------------------------------------------
CONFIG_FILE="$HOME/.xtrabackup-s3.conf"
[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"

# mandatory settings
if [ -z "$CFG_MC_BUCKET_PATH" ] || [ -z "$CFG_CUTOFF_DAYS" ] || \
   [ -z "$CFG_LOCAL_BACKUP_DIR" ]; then
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
      --dry-run)       OPT_DRY_RUN=1 ;;
      --cleanup)       OPT_CLEANUP=1 ;;
      --no-sync)       OPT_NO_SYNC=1 ;;
      --local-only)    OPT_LOCAL_ONLY=1 ;;
      *)               BACKUP_ARGUMENTS="$BACKUP_ARGUMENTS $1" ;;
    esac
    shift
  done
fi

##############################################################################
detect_backup_tool() {
  echo "Detecting database type and backup tool..."
  
  if command -v mariabackup >/dev/null 2>&1; then
    BACKUP_TOOL=mariabackup BACKUP_CMD=mariabackup
    echo "MariaDB detected - using mariabackup"
    
    if mysql --defaults-file=/root/.my.cnf \
         -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null |
         grep -q wsrep_cluster_size; then
      CLUSTER_SIZE=$(mysql --defaults-file=/root/.my.cnf \
        -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null |
        awk '/wsrep_cluster_size/ {print $2}')
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
    BACKUP_TOOL=xtrabackup BACKUP_CMD=xtrabackup
    echo "MySQL/Percona detected - using xtrabackup"
  else
    echo "ERROR: install xtrabackup or mariabackup." >&2
    exit 1
  fi
  
  echo "Using backup tool: $BACKUP_CMD $GALERA_OPTIONS"
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
  
  # Ensure all data is written to disk
  sync
  sleep 2
  
  echo "Syncing to S3: $(basename "$LOCAL_PATH")"
  
  # Use md5 for content verification
  if mc mirror --retry --overwrite --md5 "$LOCAL_PATH" "$S3_PATH"; then
    echo "Sync completed successfully"
  else
    echo "ERROR: Sync failed for $(basename "$LOCAL_PATH")"
    return 1
  fi
}

##############################################################################
cleanup_old_backups() {
  echo "Pruning old chains in S3 with chain integrity protection…"
  CUTOFF_DATE=$(date -d "$CFG_CUTOFF_DAYS days ago" +%Y-%m-%d)
  CUTOFF_NUM=$(echo "$CUTOFF_DATE" | tr -d '-')

  TMP=$(mktemp)
  TMP_CHAINS=$(mktemp)
  mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's:/$::' | sort >"$TMP"

  # Build chain analysis: full_backup -> newest_incremental_date
  grep "_full_" "$TMP" | while read -r FULL; do
    [ -z "$FULL" ] && continue
    FULL_TS=$(echo "$FULL" | grep -o '[0-9]*$')
    FULL_DATE=$(echo "$FULL" | cut -d_ -f1)
    
    # Find newest incremental in this chain
    NEWEST_INC_DATE="$FULL_DATE"
    
    # Create a temporary file for incrementals in this chain
    TMP_INCS=$(mktemp)
    grep "_inc_base-${FULL_TS}_" "$TMP" > "$TMP_INCS"
    
    # Process each incremental backup without a pipeline
    if [ -s "$TMP_INCS" ]; then
      while read -r INC; do
        [ -z "$INC" ] && continue
        INC_DATE=$(echo "$INC" | cut -d_ -f1)
        # POSIX-compliant string comparison
        if [ "$INC_DATE" != "$NEWEST_INC_DATE" ] && [ "$(printf '%s\n%s' "$NEWEST_INC_DATE" "$INC_DATE" | sort | tail -n1)" = "$INC_DATE" ]; then
          NEWEST_INC_DATE="$INC_DATE"
        fi
      done < "$TMP_INCS"
    fi
    rm -f "$TMP_INCS"
    
    echo "$FULL|$NEWEST_INC_DATE|$FULL_TS" >> "$TMP_CHAINS"
  done

  # Only delete chains where NEWEST backup (full or incremental) is older than cutoff
  while IFS='|' read -r FULL NEWEST_DATE FULL_TS; do
    [ -z "$FULL" ] && continue
    NEWEST_NUM=$(echo "$NEWEST_DATE" | tr -d '-')
    
    if [ "$NEWEST_NUM" -lt "$CUTOFF_NUM" ]; then
      echo "  ✅ Removing chain rooted at $FULL (newest backup: $NEWEST_DATE)"
      
      # Delete all incrementals in chain
      grep "_inc_base-${FULL_TS}_" "$TMP" | while read -r INC; do
        [ -z "$INC" ] && continue
        if [ "$OPT_DRY_RUN" -eq 1 ]; then
          echo "    [DRY-RUN] mc rb --force \"$CFG_MC_BUCKET_PATH/$INC\""
        else
          mc rb --force "$CFG_MC_BUCKET_PATH/$INC"
        fi
      done
      
      # Delete full backup
      if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "    [DRY-RUN] mc rb --force \"$CFG_MC_BUCKET_PATH/$FULL\""
      else
        mc rb --force "$CFG_MC_BUCKET_PATH/$FULL"
      fi
    else
      echo "  🔒 Preserving chain rooted at $FULL (newest backup: $NEWEST_DATE, within retention)"
    fi
  done < "$TMP_CHAINS"
  
  rm -f "$TMP" "$TMP_CHAINS"
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
  detect_backup_tool
  mkdir -p "$CFG_LOCAL_BACKUP_DIR"

  ########################################################################
  # ---------------------- Incremental backup ---------------------------
  ########################################################################
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
        if [ "$BACKUP_TOOL" = "mariabackup" ]; then
            echo "Command: mariabackup --backup ${CFG_INCREMENTAL} $GALERA_OPTIONS --target-dir=\"$LOCAL_BACKUP_DIR\""
        else
            echo "Command: xtrabackup --backup ${CFG_INCREMENTAL} $GALERA_OPTIONS --extra-lsndir=\"$LOCAL_BACKUP_DIR\" --target-dir=\"$LOCAL_BACKUP_DIR\""
        fi
        if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
            echo "Would skip S3 sync"
        else
            echo "Would sync to: $CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
        fi
        exit 0
    fi

    mkdir -p "$LOCAL_BACKUP_DIR"
    
    if [ "$BACKUP_TOOL" = "mariabackup" ]; then
        if mariabackup --backup "${CFG_INCREMENTAL}" \
            $GALERA_OPTIONS \
            --target-dir="$LOCAL_BACKUP_DIR"; then
            echo "Incremental backup completed locally"
        else
            echo "Incremental backup failed!"
            exit 1
        fi
    else
        if xtrabackup --backup "${CFG_INCREMENTAL}" \
            $GALERA_OPTIONS \
            --extra-lsndir="$LOCAL_BACKUP_DIR" \
            --target-dir="$LOCAL_BACKUP_DIR"; then
            echo "Incremental backup completed locally"
        else
            echo "Incremental backup failed!"
            exit 1
        fi
    fi
    
    if [ "$OPT_NO_SYNC" -eq 0 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
        sync_to_s3 "$LOCAL_BACKUP_DIR" "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
    fi

  ########################################################################
  # ------------------------- Full backup -------------------------------
  ########################################################################
  else
    LOCAL_BACKUP_DIR="${CFG_LOCAL_BACKUP_DIR}/${CFG_DATE}_${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
        echo "Dry run: would run full backup"
        echo "Would create: $LOCAL_BACKUP_DIR"
        echo "Would cleanup old local backups (keeping ${CFG_LOCAL_BACKUP_KEEP_COUNT:-4})"
        if [ "$BACKUP_TOOL" = "mariabackup" ]; then
            echo "Command: mariabackup --backup $GALERA_OPTIONS --target-dir=\"$LOCAL_BACKUP_DIR\""
        else
            echo "Command: xtrabackup --backup $GALERA_OPTIONS --extra-lsndir=\"$LOCAL_BACKUP_DIR\" --target-dir=\"$LOCAL_BACKUP_DIR\""
        fi
        if [ "$OPT_NO_SYNC" -eq 1 ] || [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
            echo "Would skip S3 sync"
        else
            echo "Would sync to: $CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
        fi
        if [ "$OPT_CLEANUP" -eq 1 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
            echo "Would also prune old chains in S3"
        fi
        exit 0
    fi

    mkdir -p "$LOCAL_BACKUP_DIR"

    # Clean up old local backups
    KEEP_COUNT="${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}"
    COUNT=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | wc -l)
    if [ "$COUNT" -gt "$KEEP_COUNT" ]; then
      find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | sort |
      head -n $((COUNT - KEEP_COUNT)) | while read -r OLD; do rm -rf "$OLD"; done
    fi

    if [ "$BACKUP_TOOL" = "mariabackup" ]; then
        if mariabackup --backup $GALERA_OPTIONS \
            --target-dir="$LOCAL_BACKUP_DIR"; then
            echo "Full backup completed locally"
        else
            echo "Full backup failed!"
            exit 1
        fi
    else
        if xtrabackup --backup $GALERA_OPTIONS \
            --extra-lsndir="$LOCAL_BACKUP_DIR" \
            --target-dir="$LOCAL_BACKUP_DIR"; then
            echo "Full backup completed locally"
        else
            echo "Full backup failed!"
            exit 1
        fi
    fi

    if [ "$OPT_NO_SYNC" -eq 0 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
        sync_to_s3 "$LOCAL_BACKUP_DIR" "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_BACKUP_DIR")"
    fi
  fi

  [ "$OPT_CLEANUP" -eq 1 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ] && cleanup_old_backups
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
##############################################################################
cleanup)
  if [ "$OPT_LOCAL_ONLY" -eq 1 ]; then
    echo "ERROR: --local-only cannot be used with cleanup operation" >&2
    exit 1
  fi
  
  echo "Running standalone cleanup operation..."
  cleanup_old_backups
  ;;
*)
  cat <<'EOF'
Usage: xtrabackup-s3.sh {full|inc|list|sync|sync-all|delete-chain|analyze-chains|cleanup} [OPTIONS]

BACKUP OPERATIONS:
  full                Create a full backup
  inc                 Create an incremental backup
  
MANAGEMENT:  
  list                List local & S3 backups
  sync <folder>       Sync one local backup folder to S3
  sync-all            Sync every local backup to S3
  delete-chain <full> Delete every incremental for <full>
  analyze-chains      Show backup chains / orphans
  cleanup             Prune old backup chains in S3 based on retention settings

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
