#!/bin/sh
# shellcheck shell=sh

##############################################################################
# Universal MySQL / MariaDB XtraBackup → S3 Script  (pure POSIX /bin/sh)
# RESTORE OPERATIONS ONLY
# Maintainer : floads            Last update : 20 Jul 2025
##############################################################################

set -e

BACKUP_TOOL="" BACKUP_CMD=""

# ---------------------------------------------------------------------------
# Load user configuration (~/.xtrabackup-s3.conf)
# ---------------------------------------------------------------------------
CONFIG_FILE="$HOME/.xtrabackup-s3.conf"
[ -f "$CONFIG_FILE" ] || { echo "ERROR: $CONFIG_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"

# mandatory settings
if [ -z "$CFG_MC_BUCKET_PATH" ] || [ -z "$CFG_LOCAL_BACKUP_DIR" ]; then
  echo "ERROR: CFG_MC_BUCKET_PATH and CFG_LOCAL_BACKUP_DIR are mandatory." >&2
  exit 1
fi

##############################################################################
# CLI parsing
##############################################################################
OPT_RESTORE_TYPE=${1:-}
OPT_DRY_RUN=0
OPT_RESTORE_DIR=""
RESTORE_ARGUMENTS=""

if [ $# -gt 0 ]; then
  shift
  while [ "$1" ]; do
    case "$1" in
      --dry-run)       OPT_DRY_RUN=1 ;;
      --restore-dir=*) OPT_RESTORE_DIR=${1#*=} ;;
      *)               RESTORE_ARGUMENTS="$RESTORE_ARGUMENTS $1" ;;
    esac
    shift
  done
fi

##############################################################################
detect_backup_tool() {
  if command -v mariabackup >/dev/null 2>&1; then
    BACKUP_TOOL=mariabackup BACKUP_CMD=mariabackup
  elif command -v xtrabackup >/dev/null 2>&1; then
    BACKUP_TOOL=xtrabackup BACKUP_CMD=xtrabackup
  else
    echo "ERROR: install xtrabackup or mariabackup." >&2
    exit 1
  fi
}

##############################################################################
detect_os() {
  if [ "$(uname)" = "FreeBSD" ]; then
    OS_TYPE="freebsd"
    MYSQL_DATADIR="/var/db/mysql"
  else
    OS_TYPE="linux"
    MYSQL_DATADIR="/var/lib/mysql"
  fi
}

##############################################################################
mysql_service_control() {
  ACTION=$1
  
  if [ "$OS_TYPE" = "freebsd" ]; then
    case "$ACTION" in
      stop)  service mysql-server stop ;;
      start) service mysql-server start ;;
      status) service mysql-server status >/dev/null 2>&1 ;;
    esac
  else
    case "$ACTION" in
      stop)  systemctl stop mysql ;;
      start) systemctl start mysql ;;
      status) systemctl is-active mysql >/dev/null 2>&1 ;;
    esac
  fi
}

##############################################################################
check_galera_cluster() {
  # Check if this is a Galera cluster by looking for wsrep settings
  GALERA_DETECTED=0
  
  # Check my.cnf files for wsrep settings
  for CNF in /etc/mysql/my.cnf /etc/my.cnf /root/.my.cnf "$MYSQL_DATADIR"/my.cnf; do
    if [ -f "$CNF" ] && grep -q "wsrep_" "$CNF" 2>/dev/null; then
      GALERA_DETECTED=1
      break
    fi
  done
  
  # Also check if grastate.dat exists (Galera state file)
  if [ -f "$MYSQL_DATADIR/grastate.dat" ]; then
    GALERA_DETECTED=1
  fi
  
  if [ "$GALERA_DETECTED" -eq 1 ]; then
    echo "⚠️  GALERA CLUSTER DETECTED ⚠️"
    echo ""
    echo "This appears to be a Galera cluster node. For a proper restore:"
    echo ""
    echo "1. STOP MariaDB/MySQL on ALL cluster nodes first:"
    if [ "$OS_TYPE" = "freebsd" ]; then
      echo "   sudo service mysql-server stop"
    else
      echo "   sudo systemctl stop mysql"
    fi
    echo ""
    echo "2. Clear data directories on ALL nodes (if doing full cluster restore)"
    echo "3. Restore backup on ONE node (this node)"
    echo "4. Bootstrap cluster from this node"
    echo "5. Start other nodes normally (they'll sync via SST)"
    echo ""
    echo "Have you stopped MariaDB on ALL cluster nodes? [Y/n]"
    
    if [ -t 0 ]; then  # Only prompt if running interactively
      read -r CONFIRM
      case "$CONFIRM" in
        [nN]|[nN][oO])
          echo "❌ Please stop MariaDB on all cluster nodes first."
          echo "   Then run this restore command again."
          exit 1
          ;;
        ""|[yY]|[yY][eE][sS])
          echo "✅ Proceeding with cluster restore..."
          ;;
        *)
          echo "❌ Invalid response. Please answer Y or N."
          exit 1
          ;;
      esac
    else
      echo "⚠️  Running non-interactively - assuming cluster is properly stopped."
    fi
    echo ""
  fi
}

##############################################################################
prepare_backup() {
  BACKUP_DIR=$1
  APPLY_LOGS=${2:-1}

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

  # prepare with appropriate options
  if [ "$BACKUP_TOOL" = "mariabackup" ]; then
    TMP_CNF=$(mktemp)
    {
      echo "[mariabackup]"
      echo "user=root"
      grep '^password' /root/.my.cnf 2>/dev/null || true || true
      [ -n "$ENCRYPT_KEY" ] && echo "encrypt-key=$ENCRYPT_KEY"
    } >"$TMP_CNF"
    
    if [ "$APPLY_LOGS" -eq 0 ]; then
      $BACKUP_CMD --defaults-file="$TMP_CNF" --prepare --apply-log-only --target-dir="$BACKUP_DIR"
    else
      $BACKUP_CMD --defaults-file="$TMP_CNF" --prepare --target-dir="$BACKUP_DIR"
    fi
    rm -f "$TMP_CNF"
  else
    if [ "$APPLY_LOGS" -eq 0 ]; then
      $BACKUP_CMD --defaults-file=/root/.my.cnf --prepare --apply-log-only --target-dir="$BACKUP_DIR"
    else
      $BACKUP_CMD --defaults-file=/root/.my.cnf --prepare --target-dir="$BACKUP_DIR"
    fi
  fi
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
# ---------------------------------------------------------------------------
# MAIN DISPATCH
# ---------------------------------------------------------------------------
case "$OPT_RESTORE_TYPE" in
##############################################################################
restore)
  FULL_BACKUP=$(echo "$RESTORE_ARGUMENTS" | awk '{print $1}')
  [ -n "$FULL_BACKUP" ] || { echo "Need backup name." >&2; exit 1; }
  detect_backup_tool
  detect_os

  # Check for Galera cluster and warn user
  check_galera_cluster

  RESTORE_DIR=${OPT_RESTORE_DIR:-/var/tmp/restore_$}

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
    echo "$BACKUP_CMD --prepare --target-dir=\"$RESTORE_DIR\""
    
    if [ "$OS_TYPE" = "freebsd" ]; then
      echo "service mysql-server stop"
    else
      echo "systemctl stop mysql"
    fi
    
    echo "rm -rf $MYSQL_DATADIR/*"
    echo "$BACKUP_CMD --copy-back --target-dir=\"$RESTORE_DIR\""
    echo "chown -R mysql:mysql $MYSQL_DATADIR"
    
    if [ "$OS_TYPE" = "freebsd" ]; then
      echo "service mysql-server start"
    else
      echo "systemctl start mysql"
    fi
    
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

  # Check if MySQL is running before trying to stop it
  if mysql_service_control status; then
    echo "Stopping MySQL service..."
    mysql_service_control stop
  else
    echo "MySQL service already stopped."
  fi
  
  rm -rf $MYSQL_DATADIR/* && mkdir -p $MYSQL_DATADIR &&
    chown mysql:mysql $MYSQL_DATADIR && chmod 0750 $MYSQL_DATADIR

  if [ "$BACKUP_TOOL" = "mariabackup" ]; then
    TMP_CNF=$(mktemp)
    {
      echo "[mariabackup]"
      echo "user=root"
      grep '^password' /root/.my.cnf 2>/dev/null || true
    } >"$TMP_CNF"
    $BACKUP_CMD --defaults-file="$TMP_CNF" --copy-back --target-dir="$RESTORE_DIR"
    rm -f "$TMP_CNF"
  else
    $BACKUP_CMD --copy-back --target-dir="$RESTORE_DIR"
  fi

  chown -R mysql:mysql $MYSQL_DATADIR
  rm -rf "$RESTORE_DIR"

  mysql_service_control start
  sleep 2
  if mysql_service_control status; then
    echo "✅ Restore complete."
  else
    echo "❌ MySQL failed. Check logs." >&2
    exit 1
  fi
  ;;

##############################################################################
restore-chain)
  FULL_BACKUP=$(echo "$RESTORE_ARGUMENTS" | awk '{print $1}')
  TARGET_INC=$(echo "$RESTORE_ARGUMENTS" | awk '{print $2}')
  [ -n "$FULL_BACKUP" ] || { echo "Need full backup name." >&2; exit 1; }
  detect_backup_tool
  detect_os

  # Check for Galera cluster and warn user
  check_galera_cluster

  TS=$(echo "$FULL_BACKUP" | grep -o '[0-9]*$')
  [ -n "$TS" ] || { echo "Cannot extract timestamp from backup name." >&2; exit 1; }

  RESTORE_DIR=${OPT_RESTORE_DIR:-/var/tmp/restore_$$}

  # Find full backup source
  if [ -d "$CFG_LOCAL_BACKUP_DIR/$FULL_BACKUP" ]; then
    FULL_SRC="$CFG_LOCAL_BACKUP_DIR/$FULL_BACKUP"; FULL_SRC_TYPE=local
  else
    FULL_SRC="$CFG_MC_BUCKET_PATH/$FULL_BACKUP"; FULL_SRC_TYPE=s3
  fi

  # Get list of incrementals for this chain
  TMP_INCS=$(mktemp)
  if [ "$FULL_SRC_TYPE" = "local" ]; then
    find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name "*_inc_base-${TS}_*" | sort > "$TMP_INCS"
  else
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's:/$::' | grep "_inc_base-${TS}_" | sort > "$TMP_INCS"
  fi

  INC_COUNT=$(wc -l < "$TMP_INCS")
  echo "Found full backup: $FULL_BACKUP"
  echo "Found $INC_COUNT incrementals in chain"

  # If target incremental specified, validate and filter the list
  if [ -n "$TARGET_INC" ]; then
    if ! grep -q "^$TARGET_INC$" "$TMP_INCS"; then
      echo "ERROR: Target incremental '$TARGET_INC' not found in chain." >&2
      echo "Available incrementals:"
      while read -r INC; do
        [ -n "$INC" ] && echo "  $INC"
      done < "$TMP_INCS"
      rm -f "$TMP_INCS"
      exit 1
    fi
    
    # Create new temp file with only incrementals up to target
    TMP_FILTERED=$(mktemp)
    while read -r INC; do
      [ -z "$INC" ] && continue
      echo "$INC"
      [ "$INC" = "$TARGET_INC" ] && break
    done < "$TMP_INCS" > "$TMP_FILTERED"
    
    mv "$TMP_FILTERED" "$TMP_INCS"
    FILTERED_COUNT=$(wc -l < "$TMP_INCS")
    echo "Restoring up to: $TARGET_INC ($FILTERED_COUNT incrementals)"
  fi

  if [ "$OPT_DRY_RUN" -eq 1 ]; then
    echo "# DRY-RUN: restore chain procedure"
    echo "mkdir -p \"$RESTORE_DIR\""
    
    if [ -n "$TARGET_INC" ]; then
      echo "# Restore chain up to: $TARGET_INC"
    fi
    
    if [ "$FULL_SRC_TYPE" = "local" ]; then
      echo "cp -r \"$FULL_SRC\"/. \"$RESTORE_DIR\""
    else
      echo "mc mirror --overwrite --remove \"$FULL_SRC\" \"$RESTORE_DIR\""
    fi
    
    while read -r INC_NAME; do
      [ -z "$INC_NAME" ] && continue
      if [ "$FULL_SRC_TYPE" = "local" ]; then
        echo "# Apply incremental: $INC_NAME"
      else
        echo "mc mirror --overwrite --remove \"$CFG_MC_BUCKET_PATH/$INC_NAME\" \"$RESTORE_DIR.inc\""
        echo "# Apply incremental: $INC_NAME"
      fi
    done < "$TMP_INCS"
    
    echo "$BACKUP_CMD --prepare --target-dir=\"$RESTORE_DIR\""
    
    if [ "$OS_TYPE" = "freebsd" ]; then
      echo "service mysql-server stop"
    else
      echo "systemctl stop mysql"
    fi
    
    echo "rm -rf $MYSQL_DATADIR/*"
    echo "$BACKUP_CMD --copy-back --target-dir=\"$RESTORE_DIR\""
    echo "chown -R mysql:mysql $MYSQL_DATADIR"
    
    if [ "$OS_TYPE" = "freebsd" ]; then
      echo "service mysql-server start"
    else
      echo "systemctl start mysql"
    fi
    echo "rm -rf \"$RESTORE_DIR\"*"
    rm -f "$TMP_INCS"
    exit 0
  fi

  # Create restore directory
  mkdir -p "$RESTORE_DIR"

  # Download/copy full backup
  echo "Downloading full backup..."
  if [ "$FULL_SRC_TYPE" = "local" ]; then
    cp -r "$FULL_SRC"/. "$RESTORE_DIR"
  else
    mc mirror --overwrite --remove "$FULL_SRC" "$RESTORE_DIR"
  fi

  # Prepare full backup first without applying logs
  echo "Preparing full backup without applying logs..."
  prepare_backup "$RESTORE_DIR" 0

  # Apply incrementals in order
  INC_NUM=1
  while IFS= read -r INC_NAME || [ -n "$INC_NAME" ]; do
    [ -z "$INC_NAME" ] && continue
    
    echo "Applying incremental $INC_NUM: $INC_NAME"
    INC_DIR="$RESTORE_DIR.inc$INC_NUM"
    mkdir -p "$INC_DIR"
    
    # Download/copy incremental
    if [ "$FULL_SRC_TYPE" = "local" ]; then
      if ! cp -r "$CFG_LOCAL_BACKUP_DIR/$INC_NAME"/. "$INC_DIR"; then
        echo "ERROR: Failed to copy incremental $INC_NAME" >&2
        exit 1
      fi
    else
      if ! mc mirror --overwrite --remove "$CFG_MC_BUCKET_PATH/$INC_NAME" "$INC_DIR"; then
        echo "ERROR: Failed to download incremental $INC_NAME" >&2
        exit 1
      fi
    fi
    
    # Prepare incremental (decrypt/decompress only, no --prepare)
    echo "Decrypting/decompressing incremental $INC_NUM..."
    # Only decrypt and decompress, don't prepare standalone
    if find "$INC_DIR" -name '*.xbcrypt' | grep -q .; then
      echo "Found encrypted files, decrypting..."
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
        exit 1
      fi

      if [ "$BACKUP_TOOL" != "mariabackup" ]; then
        if ! $BACKUP_CMD --decrypt=AES256 "$DECRYPT_OPTIONS" --target-dir="$INC_DIR"; then
          echo "ERROR: Failed to decrypt incremental $INC_NAME" >&2
          exit 1
        fi
        find "$INC_DIR" -name '*.xbcrypt' -type f -delete
      fi
    fi

    # decompress
    if find "$INC_DIR" \( -name '*.zst' -o -name '*.qp' \) | grep -q .; then
      if [ "$BACKUP_TOOL" != "mariabackup" ]; then
        if ! $BACKUP_CMD --decompress --target-dir="$INC_DIR"; then
          echo "ERROR: Failed to decompress incremental $INC_NAME" >&2
          exit 1
        fi
        find "$INC_DIR" \( -name '*.zst' -o -name '*.qp' \) -type f -delete
      fi
    fi
    
    # Apply incremental to full backup
    echo "Applying incremental $INC_NUM to restore..."
    if [ "$BACKUP_TOOL" = "mariabackup" ]; then
      TMP_CNF=$(mktemp)
      {
        echo "[mariabackup]"
        echo "user=root"
        grep '^password' /root/.my.cnf 2>/dev/null
      } >"$TMP_CNF"
      
      if ! $BACKUP_CMD --defaults-file="$TMP_CNF" --prepare --apply-log-only --target-dir="$RESTORE_DIR" --incremental-dir="$INC_DIR"; then
        echo "ERROR: Failed to apply incremental $INC_NAME" >&2
        rm -f "$TMP_CNF"
        exit 1
      fi
      rm -f "$TMP_CNF"
    else
      if ! $BACKUP_CMD --prepare --apply-log-only --target-dir="$RESTORE_DIR" --incremental-dir="$INC_DIR"; then
        echo "ERROR: Failed to apply incremental $INC_NAME" >&2
        exit 1
      fi
    fi
    
    # Clean up incremental directory
    rm -rf "$INC_DIR"
    INC_NUM=$((INC_NUM + 1))
  done < "$TMP_INCS"

  # Final prepare with redo logs
  echo "Final preparation with redo logs..."
  if [ "$BACKUP_TOOL" = "mariabackup" ]; then
    TMP_CNF=$(mktemp)
    {
      echo "[mariabackup]"
      echo "user=root"
      grep '^password' /root/.my.cnf 2>/dev/null
    } >"$TMP_CNF"
    $BACKUP_CMD --defaults-file="$TMP_CNF" --prepare --target-dir="$RESTORE_DIR"
    rm -f "$TMP_CNF"
  else
    $BACKUP_CMD --prepare --target-dir="$RESTORE_DIR"
  fi

  # Stop MySQL and restore
  echo "Stopping MySQL and restoring data..."
  if mysql_service_control status; then
    echo "Stopping MySQL service..."
    mysql_service_control stop
  else
    echo "MySQL service already stopped."
  fi
  
  rm -rf $MYSQL_DATADIR/* && mkdir -p $MYSQL_DATADIR &&
    chown mysql:mysql $MYSQL_DATADIR && chmod 0750 $MYSQL_DATADIR

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

  chown -R mysql:mysql $MYSQL_DATADIR
  rm -rf "$RESTORE_DIR"
  rm -f "$TMP_INCS"

  mysql_service_control start
  sleep 2
  if mysql_service_control status; then
    echo "✅ Chain restore complete."
  else
    echo "❌ MySQL failed. Check logs." >&2
    exit 1
  fi
  ;;

##############################################################################
analyze-chains) analyze_backup_chains ;;
list)           list_backups ;;
*)
  cat <<'EOF'
Usage: xtrabackup-restore.sh {restore|restore-chain|list|analyze-chains} [OPTIONS]

RESTORE OPERATIONS:
  restore <backup>             Restore a single full backup
  restore-chain <full> [target_inc] Restore full backup + incrementals up to target

ANALYSIS:  
  list                         List local & S3 backups
  analyze-chains               Show backup chains / orphans

Common options:
  --dry-run                    Print every command, do nothing
  --restore-dir=<p>            Custom restore dir (default /var/tmp/restore_PID)

For backup operations, use: xtrabackup-s3.sh
EOF
  exit 1
  ;;
esac

exit 0