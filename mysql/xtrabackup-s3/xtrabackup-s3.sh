#!/bin/sh
# shellcheck shell=sh

##############################################################################
# Universal MySQL / MariaDB XtraBackup → S3 Script  (pure POSIX /bin/sh)
# Maintainer : you            Last update : 19 Jul 2025
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
OPT_RESTORE_DIR=""
BACKUP_ARGUMENTS=""

if [ $# -gt 0 ]; then
  shift
  while [ "$1" ]; do
    case "$1" in
      --dry-run)       OPT_DRY_RUN=1 ;;
      --cleanup)       OPT_CLEANUP=1 ;;
      --no-sync)       OPT_NO_SYNC=1 ;;
      --local-only)    OPT_LOCAL_ONLY=1 ;;
      --restore-dir=*) OPT_RESTORE_DIR=${1#*=} ;;
      *)               BACKUP_ARGUMENTS="$BACKUP_ARGUMENTS $1" ;;
    esac
    shift
  done
fi

##############################################################################
detect_backup_tool() {
  if command -v mariabackup >/dev/null 2>&1; then
    BACKUP_TOOL=mariabackup BACKUP_CMD=mariabackup
    if mysql --defaults-file=/root/.my.cnf \
         -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null |
         grep -q wsrep_cluster_size; then
      CLUSTER_SIZE=$(mysql --defaults-file=/root/.my.cnf \
        -e "SHOW STATUS LIKE 'wsrep_cluster_size'" 2>/dev/null |
        awk '/wsrep_cluster_size/ {print $2}')
      if [ -n "$CLUSTER_SIZE" ] && [ "$CLUSTER_SIZE" -gt 0 ]; then
        GALERA_OPTIONS="--galera-info"
      fi
    fi
  elif command -v xtrabackup >/dev/null 2>&1; then
    BACKUP_TOOL=xtrabackup BACKUP_CMD=xtrabackup
  else
    echo "ERROR: install xtrabackup or mariabackup." >&2
    exit 1
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
    INC_COUNT=$(grep -c "_inc_base-${TS}_" "$TMP")
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
  echo "=== REMOTE BACKUPS ==="
  if mc ls "$CFG_MC_BUCKET_PATH" >/dev/null 2>&1; then
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sort -r |
    while read -r F; do
      F=$(echo "$F" | sed 's:/$::')
      SIZE=$(mc du "$CFG_MC_BUCKET_PATH/$F" | awk '{print $1}')
      echo "  $F ($SIZE)"
    done
  else
    echo "  [cannot access bucket]"
  fi
}

##############################################################################
prepare_backup() {
  BACKUP_DIR=$1
  # shellcheck disable=SC2034
  IS_FULL=${2:-1}

  DECRYPT_OPTIONS=""
  ENCRYPT_KEY=""

  # decrypt
  if find "$BACKUP_DIR" -name '*.xbcrypt' | grep -q .; then
    if [ -f /root/.my.cnf ]; then
      ENCRYPT_KEY=$(grep -A10 '^\[xtrabackup\]' /root/.my.cnf |
        grep '^encrypt-key' | cut -d= -f2 | tr -d ' ')
    fi
    [ -z "$ENCRYPT_KEY" ] && [ -n "$CFG_ENCRYPT_KEY" ] && ENCRYPT_KEY=$CFG_ENCRYPT_KEY
    if [ -n "$ENCRYPT_KEY" ]; then
      DECRYPT_OPTIONS="--encrypt-key=$ENCRYPT_KEY"
    elif [ -n "$CFG_ENCRYPT_KEY_FILE" ]; then
      DECRYPT_OPTIONS="--encrypt-key-file=$CFG_ENCRYPT_KEY_FILE"
    else
      echo "ERROR: encrypted backup but no key." >&2
      return 1
    fi

    if [ "$BACKUP_TOOL" != "mariabackup" ]; then
      $BACKUP_CMD --decrypt=AES256 "$DECRYPT_OPTIONS" --target-dir="$BACKUP_DIR"
    fi
  fi

  # decompress
  if find "$BACKUP_DIR" \( -name '*.zst' -o -name '*.qp' \) | grep -q .; then
    if [ "$BACKUP_TOOL" != "mariabackup" ]; then
      $BACKUP_CMD --decompress --target-dir="$BACKUP_DIR"
      find "$BACKUP_DIR" \( -name '*.zst' -o -name '*.qp' \) -exec rm -f {} +
    fi
  fi

  # prepare
  if [ "$BACKUP_TOOL" = "mariabackup" ]; then
    TMP_CNF=$(mktemp)
    {
      echo "[mariabackup]"
      echo "user=root"
      grep '^password' /root/.my.cnf 2>/dev/null
      [ -n "$ENCRYPT_KEY" ] && echo "encrypt-key=$ENCRYPT_KEY"
    } >"$TMP_CNF"
    $BACKUP_CMD --defaults-file="$TMP_CNF" --prepare --target-dir="$BACKUP_DIR"
    rm -f "$TMP_CNF"
  else
    $BACKUP_CMD --defaults-file=/root/.my.cnf --prepare --target-dir="$BACKUP_DIR"
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
    LATEST=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' |
             sort -r | head -n1)
    [ -n "$LATEST" ] || { echo "No base backup. Run full first." >&2; exit 1; }

    LATEST_NAME=$(basename "$LATEST")
    if echo "$LATEST_NAME" | grep -q '_full_'; then
      BASE_TS=$(echo "$LATEST_NAME" | grep -o '[0-9]*$')
    else
      BASE_TS=$(echo "$LATEST_NAME" | sed 's/.*_inc_base-\([0-9]*\)_.*/\1/')
    fi

    LOCAL_DIR="$CFG_LOCAL_BACKUP_DIR/${CFG_DATE}_inc_base-${BASE_TS}_${CFG_TIMESTAMP}"
    INC_OPT="--incremental-basedir=$LATEST"

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
      echo "# DRY-RUN incremental backup"
      echo "mkdir -p \"$LOCAL_DIR\""
      if [ "$BACKUP_TOOL" = "mariabackup" ]; then
        echo "mariabackup --backup $INC_OPT $GALERA_OPTIONS --target-dir=\"$LOCAL_DIR\" \\"
        echo "            --defaults-file=/root/.my.cnf"
      else
        echo "xtrabackup --backup $INC_OPT $GALERA_OPTIONS --extra-lsndir=\"$LOCAL_DIR\" \\"
        echo "           --target-dir=\"$LOCAL_DIR\""
      fi
      if [ "$OPT_NO_SYNC" -eq 0 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
        echo "mc mirror --retry --overwrite \"$LOCAL_DIR\" \\"
        echo "          \"$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_DIR")\""
      fi
      exit 0
    fi

    mkdir -p "$LOCAL_DIR"
    if [ "$BACKUP_TOOL" = "mariabackup" ]; then
      TMP_CNF=$(mktemp)
      {
        echo "[mariabackup]"
        echo "user=root"
        grep '^password' /root/.my.cnf 2>/dev/null
      } >"$TMP_CNF"
      $BACKUP_CMD --defaults-file="$TMP_CNF" --backup "$INC_OPT" \
                  $GALERA_OPTIONS --target-dir="$LOCAL_DIR"
      rm -f "$TMP_CNF"
    else
      $BACKUP_CMD --backup "$INC_OPT" $GALERA_OPTIONS \
                  --extra-lsndir="$LOCAL_DIR" --target-dir="$LOCAL_DIR"
    fi

    if [ "$OPT_NO_SYNC" -eq 0 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
      mc mirror --retry --overwrite "$LOCAL_DIR" \
                "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_DIR")"
    fi

  ########################################################################
  # ------------------------- Full backup -------------------------------
  ########################################################################
  else
    LOCAL_DIR="$CFG_LOCAL_BACKUP_DIR/${CFG_DATE}_full_${CFG_TIMESTAMP}"

    if [ "$OPT_DRY_RUN" -eq 1 ]; then
      echo "# DRY-RUN full backup"
      echo "mkdir -p \"$LOCAL_DIR\""
      if [ "$BACKUP_TOOL" = "mariabackup" ]; then
        echo "mariabackup --backup $GALERA_OPTIONS --target-dir=\"$LOCAL_DIR\" \\"
        echo "            --defaults-file=/root/.my.cnf"
      else
        echo "xtrabackup --backup $GALERA_OPTIONS --extra-lsndir=\"$LOCAL_DIR\" \\"
        echo "           --target-dir=\"$LOCAL_DIR\""
      fi
      if [ "$OPT_NO_SYNC" -eq 0 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
        echo "mc mirror --retry --overwrite \"$LOCAL_DIR\" \\"
        echo "          \"$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_DIR")\""
      fi
      if [ "$OPT_CLEANUP" -eq 1 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
        echo "# would also prune old chains in S3 (cleanup_old_backups)"
      fi
      exit 0
    fi

    mkdir -p "$LOCAL_DIR"

    KEEP=${CFG_LOCAL_BACKUP_KEEP_COUNT:-4}
    COUNT=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | wc -l)
    if [ "$COUNT" -gt "$KEEP" ]; then
      find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | sort |
      head -n $(( COUNT - KEEP )) | while read -r OLD; do rm -rf "$OLD"; done
    fi

    if [ "$BACKUP_TOOL" = "mariabackup" ]; then
      TMP_CNF=$(mktemp)
      {
        echo "[mariabackup]"
        echo "user=root"
        grep '^password' /root/.my.cnf 2>/dev/null
      } >"$TMP_CNF"
      $BACKUP_CMD --defaults-file="$TMP_CNF" --backup $GALERA_OPTIONS \
                  --target-dir="$LOCAL_DIR"
      rm -f "$TMP_CNF"
    else
      $BACKUP_CMD --backup $GALERA_OPTIONS \
                  --extra-lsndir="$LOCAL_DIR" --target-dir="$LOCAL_DIR"
    fi

    if [ "$OPT_NO_SYNC" -eq 0 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ]; then
      mc mirror --retry --overwrite "$LOCAL_DIR" \
                "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL_DIR")"
    fi
  fi

  [ "$OPT_CLEANUP" -eq 1 ] && [ "$OPT_LOCAL_ONLY" -eq 0 ] && cleanup_old_backups
  ;;

##############################################################################
restore)
  FULL_BACKUP=$(echo "$BACKUP_ARGUMENTS" | awk '{print $1}')
  [ -n "$FULL_BACKUP" ] || { echo "Need backup name." >&2; exit 1; }
  detect_backup_tool

  RESTORE_DIR=${OPT_RESTORE_DIR:-/var/tmp/restore_$$}

  if [ -d "$CFG_LOCAL_BACKUP_DIR/$FULL_BACKUP" ]; then
    SRC="$CFG_LOCAL_BACKUP_DIR/$FULL_BACKUP"; SRC_TYPE=local
  else
    SRC="$CFG_MC_BUCKET_PATH/$FULL_BACKUP"; SRC_TYPE=s3
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "# DRY-RUN: full restore procedure"
    echo "mkdir -p \"$RESTORE_DIR\""
    if [ "$SRC_TYPE" = local ]; then
      echo "cp -r \"$SRC\"/. \"$RESTORE_DIR\""
    else
      echo "mc mirror --overwrite --remove \"$SRC\" \"$RESTORE_DIR\""
    fi
    echo "# decrypt (if *.xbcrypt present)"
    echo "$BACKUP_CMD --decrypt=AES256 <key-opts> --target-dir=\"$RESTORE_DIR\"    # auto-skipped if not encrypted"
    echo "# decompress (if *.zst / *.qp present)"
    echo "$BACKUP_CMD --decompress --target-dir=\"$RESTORE_DIR\"                   # auto-skipped if not compressed"
    echo "# prepare backup"
    echo "$BACKUP_CMD --prepare --target-dir=\"$RESTORE_DIR\""
    echo "systemctl stop mysql"
    echo "rm -rf /var/lib/mysql/*"
    echo "$BACKUP_CMD --copy-back --target-dir=\"$RESTORE_DIR\""
    echo "chown -R mysql:mysql /var/lib/mysql"
    echo "systemctl start mysql"
    echo "rm -rf \"$RESTORE_DIR\""
    exit 0
  fi

  mkdir -p "$RESTORE_DIR"
  if [ "$SRC_TYPE" = local ]; then
    cp -r "$SRC"/. "$RESTORE_DIR"
  else
    mc mirror --overwrite --remove "$SRC" "$RESTORE_DIR"
  fi

  prepare_backup "$RESTORE_DIR" 1

  systemctl stop mysql
  rm -rf /var/lib/mysql/* && mkdir -p /var/lib/mysql &&
    chown mysql:mysql /var/lib/mysql && chmod 0750 /var/lib/mysql

  if [ "$BACKUP_TOOL" = "mariabackup" ]; then
    TMP_CNF=$(mktemp)
    {
      echo "[mariabackup]"
      echo "user=root"
      grep '^password' /root/.my.cnf 2>/dev/null
    } >"$TMP_CNF"
    $BACKUP_CMD --defaults-file="$TMP_CNF" --copy-back --target-dir="$RESTORE_DIR"
    rm -f "$TMP_CNF"
  else
    $BACKUP_CMD --copy-back --target-dir="$RESTORE_DIR"
  fi

  chown -R mysql:mysql /var/lib/mysql
  rm -rf "$RESTORE_DIR"

  systemctl start mysql
  sleep 2
  if systemctl is-active mysql >/dev/null 2>&1; then
    echo "✅ Restore complete."
  else
    echo "❌ MySQL failed. Check logs." >&2
    exit 1
  fi
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
    echo "mc mirror --retry --overwrite \"$LOCAL\" \\"
    echo "          \"$CFG_MC_BUCKET_PATH/$(basename "$LOCAL")\""
    exit 0
  fi

  mc mirror --retry --overwrite "$LOCAL" \
            "$CFG_MC_BUCKET_PATH/$(basename "$LOCAL")"
  ;;

##############################################################################
sync-all)
  [ -d "$CFG_LOCAL_BACKUP_DIR" ] || { echo "No local backups." >&2; exit 0; }

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "# DRY-RUN sync-all"
    find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | sort |
    while read -r D; do
      echo "mc mirror --retry --overwrite \"$D\" \\"
      echo "          \"$CFG_MC_BUCKET_PATH/$(basename "$D")\""
    done
    exit 0
  fi

  find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | sort |
  while read -r D; do
    mc mirror --retry --overwrite "$D" \
      "$CFG_MC_BUCKET_PATH/$(basename "$D")"
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
Usage: script.sh {full|inc|list|restore|sync|sync-all|delete-chain|analyze-chains} [OPTIONS]

  full                Create a full backup
  inc                 Create an incremental backup
  list                List local & S3 backups
  restore <backup>    Restore a full backup
  sync <folder>       Sync one local backup folder to S3
  sync-all            Sync every local backup to S3
  delete-chain <full> Delete every incremental for <full>
  analyze-chains      Show backup chains / orphans

Common options
  --dry-run           Print every command, do nothing
  --cleanup           After backup, prune old chains in S3
  --no-sync           Skip S3 mirror step
  --local-only        Ignore S3 entirely (skip mirror / cleanup)
  --restore-dir=<p>   Custom restore dir (default /var/tmp/restore_PID)
EOF
  exit 1
  ;;
esac

exit 0