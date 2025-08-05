#!/bin/sh
# shellcheck shell=sh

##############################################################################
# Universal MySQL / MariaDB XtraBackup → S3 Backup Analysis Script
# ANALYSIS OPERATIONS ONLY
# Maintainer : floads            Last update : 20 Jul 2025
##############################################################################

set -e

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
# Helper functions for cross-platform compatibility
##############################################################################
human_readable() {
  local bytes=$1
  if [ "$bytes" -lt 1024 ]; then
    echo "${bytes}B"
  elif [ "$bytes" -lt 1048576 ]; then
    echo "$((bytes / 1024))KB"
  elif [ "$bytes" -lt 1073741824 ]; then
    echo "$((bytes / 1048576))MB"
  else
    echo "$((bytes / 1073741824))GB"
  fi
}

# Convert mc du output to bytes (works on both Linux and FreeBSD)
mc_size_to_bytes() {
  local size_str=$1
  local number unit
  
  # Extract number and unit
  number=$(echo "$size_str" | sed 's/[^0-9.]*$//')
  unit=$(echo "$size_str" | sed 's/^[0-9.]*//')
  
  # Convert to integer bytes using awk for floating point math
  case "$unit" in
    KiB) awk "BEGIN {printf \"%.0f\", $number * 1024}" ;;
    MiB) awk "BEGIN {printf \"%.0f\", $number * 1048576}" ;;
    GiB) awk "BEGIN {printf \"%.0f\", $number * 1073741824}" ;;
    TiB) awk "BEGIN {printf \"%.0f\", $number * 1099511627776}" ;;
    KB) awk "BEGIN {printf \"%.0f\", $number * 1000}" ;;
    MB) awk "BEGIN {printf \"%.0f\", $number * 1000000}" ;;
    GB) awk "BEGIN {printf \"%.0f\", $number * 1000000000}" ;;
    TB) awk "BEGIN {printf \"%.0f\", $number * 1000000000000}" ;;
    B) echo "${number%.*}" ;;  # Remove decimal if present
    *) echo "0" ;;
  esac
}

# Get directory size in bytes (cross-platform)
get_dir_size() {
  local dir=$1
  if [ -d "$dir" ]; then
    # Try GNU du first (Linux), fall back to BSD du (FreeBSD)
    if du --version >/dev/null 2>&1; then
      # GNU du (Linux)
      du -sb "$dir" | cut -f1
    else
      # BSD du (FreeBSD/macOS)
      du -s -k "$dir" | awk '{print $1 * 1024}'
    fi
  else
    echo "0"
  fi
}

##############################################################################
# CLI parsing
##############################################################################
OPT_OPERATION=${1:-analyze-chains}

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
  echo "Config: CFG_MC_BUCKET_PATH='$CFG_MC_BUCKET_PATH'"
  echo "Config: CFG_LOCAL_BACKUP_DIR='$CFG_LOCAL_BACKUP_DIR'"
  echo ""
  
  TMP=$(mktemp)
  TMP_INCS=$(mktemp)
  
  # Initialize counters for summary
  TOTAL_FULL=0
  TOTAL_INC=0
  TOTAL_LOCAL_SIZE=0
  TOTAL_S3_SIZE=0
  TOTAL_S3_BYTES=0
  
  # Debug: Check if mc command works
  echo "Checking S3 bucket: $CFG_MC_BUCKET_PATH"
  if ! mc ls "$CFG_MC_BUCKET_PATH" >/dev/null 2>&1; then
    echo "⚠️  Cannot access S3 bucket (check mc config)"
    echo "   Try: mc ls $CFG_MC_BUCKET_PATH"
  else
    echo "✅ S3 bucket accessible"
    # Get all backups from S3
    mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's:/$::' | sort >"$TMP"
    S3_COUNT=$(wc -l < "$TMP")
    echo "   Found $S3_COUNT items in S3"
    
    # Calculate S3 sizes (works on both Linux and FreeBSD)
    while read -r backup; do
      [ -z "$backup" ] && continue
      SIZE_RAW=$(mc du "$CFG_MC_BUCKET_PATH/$backup" 2>/dev/null | awk '{print $1}' | head -1)
      if [ -n "$SIZE_RAW" ]; then
        SIZE_BYTES=$(mc_size_to_bytes "$SIZE_RAW")
        TOTAL_S3_BYTES=$((TOTAL_S3_BYTES + SIZE_BYTES))
      fi
    done < "$TMP"
  fi
  
  # Also check local backups
  echo "Checking local directory: $CFG_LOCAL_BACKUP_DIR"
  if [ -d "$CFG_LOCAL_BACKUP_DIR" ]; then
    LOCAL_COUNT=$(find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | wc -l)
    echo "✅ Found $LOCAL_COUNT local backups"
    find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | while read -r D; do
      basename "$D" 
    done | sort >> "$TMP"
    
    # Calculate local sizes (cross-platform)
    if [ "$LOCAL_COUNT" -gt 0 ]; then
      TOTAL_LOCAL_SIZE=0
      find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | while read -r D; do
        DIR_SIZE=$(get_dir_size "$D")
        TOTAL_LOCAL_SIZE=$((TOTAL_LOCAL_SIZE + DIR_SIZE))
        # Use a temp file to pass the value out of the subshell
        echo "$TOTAL_LOCAL_SIZE" > /tmp/local_size_$
      done
      [ -f "/tmp/local_size_$" ] && TOTAL_LOCAL_SIZE=$(cat "/tmp/local_size_$" 2>/dev/null || echo "0")
      rm -f "/tmp/local_size_$"
    fi
  else
    echo "⚠️  Local backup directory not found"
  fi
  
  # Debug: Show what we found
  TOTAL_BACKUPS=$(sort "$TMP" | uniq | wc -l)
  echo "Total unique backups found: $TOTAL_BACKUPS"
  echo ""

  # Process each full backup (adjusted pattern for your naming)
  FULL_BACKUPS=$(grep "_full_" "$TMP" | sort -r | uniq)
  if [ -n "$FULL_BACKUPS" ]; then
    echo "$FULL_BACKUPS" | while read -r FULL; do
      [ -z "$FULL" ] && continue
      
      # Extract timestamp from your naming pattern: 2025-07-29_21-00-02_full_1753822802
      TS=$(echo "$FULL" | sed 's/.*_full_\([0-9]*\).*/\1/')
      
      # Find incrementals for this chain
      grep "_inc_base-${TS}_" "$TMP" | sort | uniq > "$TMP_INCS"
      INC_COUNT=$(wc -l < "$TMP_INCS")
      
      # Check if backup exists locally or only remote
      LOCATION="S3"
      if [ -d "$CFG_LOCAL_BACKUP_DIR/$FULL" ]; then
        LOCATION="LOCAL"
      fi
      
      # Extract readable date from backup name: 2025-07-29_21-00-02
      READABLE_DATE=$(echo "$FULL" | sed 's/_full_.*//' | tr '_' ' ' | tr '-' ':')
      
      if [ "$INC_COUNT" -gt 0 ]; then
        echo "📁 $FULL [$LOCATION]"
        echo "   ├─ Date: $READABLE_DATE"
        echo "   ├─ Chain: $INC_COUNT incrementals"
        
        # Show incremental details
        INC_NUM=1
        while read -r INC; do
          [ -z "$INC" ] && continue
          INC_READABLE=$(echo "$INC" | sed 's/_inc_base-.*//' | tr '_' ' ' | tr '-' ':')
          
          if [ "$INC_NUM" -eq "$INC_COUNT" ]; then
            echo "   └─ Inc $INC_NUM: $INC_READABLE ($INC)"
          else
            echo "   ├─ Inc $INC_NUM: $INC_READABLE ($INC)"
          fi
          INC_NUM=$((INC_NUM + 1))
        done < "$TMP_INCS"
        
        echo "   💡 Restore with: xtrabackup-s3-restore.sh restore-chain $FULL [incremental-backup-name]"
      else
        echo "📁 $FULL [$LOCATION] [stand-alone]"
        echo "   ├─ Date: $READABLE_DATE"
        echo "   └─ 💡 Restore with: xtrabackup-s3-restore.sh restore $FULL"
      fi
      echo ""
    done
  fi
  
  # Check for orphaned incrementals
  echo "=== ORPHANED INCREMENTALS ==="
  ORPHANS_FOUND=0
  ORPHAN_INCS=$(grep "_inc_" "$TMP" | sort | uniq)
  if [ -n "$ORPHAN_INCS" ]; then
    echo "$ORPHAN_INCS" | while read -r INC; do
      [ -z "$INC" ] && continue
      BASE_TS=$(echo "$INC" | sed 's/.*_inc_base-\([0-9]*\)_.*/\1/')
      if ! grep -q "_full_${BASE_TS}" "$TMP"; then
        echo "⚠️  $INC (base backup missing)"
        ORPHANS_FOUND=1
      fi
    done
  fi
  
  if [ "$ORPHANS_FOUND" -eq 0 ]; then
    echo "✅ No orphaned incrementals found"
  fi
  
  # Count backup types for summary
  TOTAL_FULL=$(grep "_full_" "$TMP" | sort | uniq | wc -l)
  TOTAL_INC=$(grep "_inc_" "$TMP" | sort | uniq | wc -l)
  
  echo ""
  echo "=== BACKUP SUMMARY ==="
  echo "📊 Total Full Backups: $TOTAL_FULL"
  echo "📊 Total Incremental Backups: $TOTAL_INC"
  echo "📊 Total Backups: $((TOTAL_FULL + TOTAL_INC))"
  echo ""
  
  # Size summary
  if [ "$TOTAL_LOCAL_SIZE" -gt 0 ]; then
    echo "💾 Local Storage Used: $(human_readable $TOTAL_LOCAL_SIZE)"
  fi
  
  if [ "$TOTAL_S3_BYTES" -gt 0 ]; then
    echo "☁️  S3 Storage Used: $(human_readable $TOTAL_S3_BYTES)"
  fi
  
  TOTAL_SIZE=$((TOTAL_LOCAL_SIZE + TOTAL_S3_BYTES))
  if [ "$TOTAL_SIZE" -gt 0 ]; then
    echo "📈 Total Storage Used: $(human_readable $TOTAL_SIZE)"
  fi
  
  rm -f "$TMP" "$TMP_INCS"
  echo "=== END ANALYSIS ==="
}

##############################################################################
check_backup_integrity() {
  BACKUP_NAME=$1
  [ -n "$BACKUP_NAME" ] || { echo "Need backup name to check." >&2; exit 1; }
  
  echo "=== CHECKING BACKUP INTEGRITY: $BACKUP_NAME ==="
  
  # Check if it's a full backup and find its chain
  IS_FULL_BACKUP=0
  if echo "$BACKUP_NAME" | grep -q "_full_"; then
    IS_FULL_BACKUP=1
    TS=$(echo "$BACKUP_NAME" | sed 's/.*_full_\([0-9]*\).*/\1/')
    echo "🔍 Detected full backup - will check entire chain"
  fi
  
  check_single_backup() {
    local backup=$1
    local backup_type=$2
    
    echo ""
    echo "--- Checking $backup_type: $backup ---"
    
    # Check if backup exists locally or remotely
    if [ -d "$CFG_LOCAL_BACKUP_DIR/$backup" ]; then
      BACKUP_PATH="$CFG_LOCAL_BACKUP_DIR/$backup"
      echo "📍 Found locally: $BACKUP_PATH"
      
      # Check for xtrabackup_checkpoints file
      if [ -f "$BACKUP_PATH/xtrabackup_checkpoints" ]; then
        echo "✅ xtrabackup_checkpoints found"
        echo "📄 Checkpoint info:"
        cat "$BACKUP_PATH/xtrabackup_checkpoints" | sed 's/^/   /'
      else
        echo "❌ Missing xtrabackup_checkpoints file"
      fi
      
      # Check for xtrabackup_info
      if [ -f "$BACKUP_PATH/xtrabackup_info" ]; then
        echo "✅ xtrabackup_info found"
        echo "📄 Backup info summary:"
        grep -E "(tool_name|tool_version|backup_type|server_version)" "$BACKUP_PATH/xtrabackup_info" | sed 's/^/   /' || true
      else
        echo "❌ Missing xtrabackup_info file"
      fi
      
      # Check if it's encrypted
      if find "$BACKUP_PATH" -name '*.xbcrypt' | grep -q .; then
        echo "🔒 Backup is encrypted"
      fi
      
      # Check if it's compressed
      if find "$BACKUP_PATH" \( -name '*.zst' -o -name '*.qp' \) | grep -q .; then
        echo "📦 Backup is compressed"
      fi
      
    else
      echo "📡 Checking S3 for backup: $CFG_MC_BUCKET_PATH/$backup"
      if mc ls "$CFG_MC_BUCKET_PATH/$backup/" >/dev/null 2>&1; then
        echo "✅ Found in S3"
        
        # Download and check key files
        TMP_CHECK=$(mktemp -d)
        echo "📥 Downloading metadata files..."
        
        if mc cp "$CFG_MC_BUCKET_PATH/$backup/xtrabackup_checkpoints" "$TMP_CHECK/" 2>/dev/null; then
          echo "✅ xtrabackup_checkpoints found"
          echo "📄 Checkpoint info:"
          cat "$TMP_CHECK/xtrabackup_checkpoints" | sed 's/^/   /'
        else
          echo "❌ Missing xtrabackup_checkpoints file"
        fi
        
        if mc cp "$CFG_MC_BUCKET_PATH/$backup/xtrabackup_info" "$TMP_CHECK/" 2>/dev/null; then
          echo "✅ xtrabackup_info found"
          echo "📄 Backup info summary:"
          grep -E "(tool_name|tool_version|backup_type|server_version)" "$TMP_CHECK/xtrabackup_info" | sed 's/^/   /' || true
        else
          echo "❌ Missing xtrabackup_info file"
        fi
        
        rm -rf "$TMP_CHECK"
      else
        echo "❌ Backup not found in S3"
        return 1
      fi
    fi
  }
  
  # Check the requested backup
  check_single_backup "$BACKUP_NAME" "PRIMARY BACKUP"
  
  # If it's a full backup, also check its incrementals
  if [ "$IS_FULL_BACKUP" -eq 1 ]; then
    echo ""
    echo "🔗 CHECKING INCREMENTAL CHAIN..."
    
    # Get list of all backups to find incrementals
    TMP_ALL=$(mktemp)
    
    # Get S3 backups
    if mc ls "$CFG_MC_BUCKET_PATH" >/dev/null 2>&1; then
      mc ls "$CFG_MC_BUCKET_PATH" | awk '{print $NF}' | sed 's:/$::' | sort >> "$TMP_ALL"
    fi
    
    # Get local backups
    if [ -d "$CFG_LOCAL_BACKUP_DIR" ]; then
      find "$CFG_LOCAL_BACKUP_DIR" -maxdepth 1 -type d -name '20*' | while read -r D; do
        basename "$D"
      done | sort >> "$TMP_ALL"
    fi
    
    # Find incrementals for this chain
    INCREMENTALS=$(grep "_inc_base-${TS}_" "$TMP_ALL" | sort | uniq)
    
    if [ -n "$INCREMENTALS" ]; then
      INC_COUNT=$(echo "$INCREMENTALS" | wc -l)
      echo "📊 Found $INC_COUNT incrementals in chain"
      
      echo "$INCREMENTALS" | while read -r INC; do
        [ -z "$INC" ] && continue
        check_single_backup "$INC" "INCREMENTAL"
      done
    else
      echo "ℹ️  No incrementals found for this full backup"
    fi
    
    rm -f "$TMP_ALL"
  fi
  
  echo ""
  echo "=== END INTEGRITY CHECK ==="
}

##############################################################################
# ---------------------------------------------------------------------------
# MAIN DISPATCH
# ---------------------------------------------------------------------------
case "$OPT_OPERATION" in
##############################################################################
analyze-chains|analyze) 
  analyze_backup_chains 
  ;;

list) 
  list_backups 
  ;;

check) 
  BACKUP_NAME=$(echo "$*" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
  check_backup_integrity "$BACKUP_NAME"
  ;;

*)
  cat <<'EOF'
Usage: xtrabackup-s3-check.sh {analyze-chains|list|check} [OPTIONS]

ANALYSIS OPERATIONS:
  analyze-chains (or analyze)  Show backup chains, orphans, and restore commands
  list                         List local & S3 backups with sizes
  check <backup-name>          Check integrity of specific backup

Examples:
  ./xtrabackup-s3-check.sh analyze-chains
  ./xtrabackup-s3-check.sh list
  ./xtrabackup-s3-check.sh check 2025-07-29_21-00-02_full_1753822802

For backup operations, use: xtrabackup-s3.sh
For restore operations, use: xtrabackup-s3-restore.sh
EOF
  exit 1
  ;;
esac

exit 0