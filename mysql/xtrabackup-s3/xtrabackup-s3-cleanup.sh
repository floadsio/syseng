#!/bin/bash
# xtrabackup-s3-cleanup.sh - Backup retention and cleanup
# Removes old backups to maintain disk space
# Retention policy:
#   - Keep full backups: 7 days
#   - Keep incremental backups: 2 days (plus most recent full backup chain)

set -euo pipefail

BACKUP_DIR="${1:-.}"
FULL_RETENTION_DAYS="${2:-7}"
INC_RETENTION_DAYS="${3:-2}"
DRY_RUN="${4:-false}"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Error: Backup directory not found: $BACKUP_DIR"
  exit 1
fi

# Function to parse date from backup directory name
# Format: YYYY-MM-DD_HH-MM-SS_type_base-timestamp
get_backup_date() {
  local dirname="$1"
  local basename=$(basename "$dirname")
  # Extract first 10 chars (YYYY-MM-DD)
  echo "${basename:0:10}"
}

# Function to convert date to days ago
days_ago() {
  local date="$1"
  local backup_epoch=$(date -d "$date" +%s 2>/dev/null || echo 0)
  local now_epoch=$(date +%s)
  local days=$(( (now_epoch - backup_epoch) / 86400 ))
  echo "$days"
}

# Get all backup bases (extract from directory names)
declare -A backup_bases
for dir in "$BACKUP_DIR"/*; do
  if [ ! -d "$dir" ]; then
    continue
  fi

  basename_str=$(basename "$dir")

  # Extract base timestamp (e.g., "base-1766428202" from "2025-12-23_13-00-02_inc_base-1766428202_1766494802")
  if [[ $basename_str =~ _base-([0-9]+)_ ]]; then
    base="${BASH_REMATCH[1]}"
    backup_bases[$base]=1
  fi
done

# For each backup base, track full backups and their age
declare -A newest_full_per_base
for base in "${!backup_bases[@]}"; do
  newest=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "*full*base-$base*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
  if [ -n "$newest" ]; then
    newest_full_per_base[$base]="$newest"
  fi
done

echo "=== Backup Retention Cleanup ==="
echo "Directory: $BACKUP_DIR"
echo "Full retention: $FULL_RETENTION_DAYS days"
echo "Incremental retention: $INC_RETENTION_DAYS days"
echo "Dry run: $DRY_RUN"
echo ""

# Count statistics
to_delete=0
freed_bytes=0

# Check all directories
for dir in "$BACKUP_DIR"/*; do
  if [ ! -d "$dir" ]; then
    continue
  fi

  dirname=$(basename "$dir")
  backup_date=$(get_backup_date "$dir")
  days_old=$(days_ago "$backup_date")
  dir_size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')

  # Extract base timestamp
  if [[ $dirname =~ _base-([0-9]+)_ ]]; then
    base="${BASH_REMATCH[1]}"
  else
    continue
  fi

  # Check if full backup
  if [[ $dirname == *"_full_"* ]]; then
    # Keep full backups for FULL_RETENTION_DAYS
    if [ "$days_old" -gt "$FULL_RETENTION_DAYS" ]; then
      echo "DELETE (full backup too old): $dirname ($days_old days old, $(numfmt --to=iec-i --suffix=B $dir_size 2>/dev/null || echo ${dir_size}B))"
      if [ "$DRY_RUN" = "false" ]; then
        rm -rf "$dir"
      fi
      to_delete=$((to_delete + 1))
      freed_bytes=$((freed_bytes + dir_size))
    fi
  else
    # Incremental backup - keep only recent ones
    # Exception: keep all incrementals for the most recent full backup base
    most_recent_full=""
    for b in "${!newest_full_per_base[@]}"; do
      full_path="${newest_full_per_base[$b]}"
      full_date=$(get_backup_date "$full_path")
      full_days_old=$(days_ago "$full_date")

      if [ -z "$most_recent_full" ] || [ "$full_days_old" -lt "$(days_ago "$(get_backup_date "$most_recent_full")")" ]; then
        most_recent_full="$full_path"
        newest_base="$b"
      fi
    done

    # If this incremental belongs to the most recent full backup, keep it for INC_RETENTION_DAYS
    # Otherwise, delete it if it's older than 1 day (for backup chain safety)
    if [ "$base" = "${newest_base:-}" ]; then
      # Part of most recent backup chain
      if [ "$days_old" -gt "$INC_RETENTION_DAYS" ]; then
        echo "DELETE (old incremental): $dirname ($days_old days old, $(numfmt --to=iec-i --suffix=B $dir_size 2>/dev/null || echo ${dir_size}B))"
        if [ "$DRY_RUN" = "false" ]; then
          rm -rf "$dir"
        fi
        to_delete=$((to_delete + 1))
        freed_bytes=$((freed_bytes + dir_size))
      fi
    else
      # Old backup chain - delete all incrementals
      echo "DELETE (old chain): $dirname (base-$base outdated, $(numfmt --to=iec-i --suffix=B $dir_size 2>/dev/null || echo ${dir_size}B))"
      if [ "$DRY_RUN" = "false" ]; then
        rm -rf "$dir"
      fi
      to_delete=$((to_delete + 1))
      freed_bytes=$((freed_bytes + dir_size))
    fi
  fi
done

echo ""
echo "Summary:"
echo "  Backups to delete: $to_delete"
freed_mb=$((freed_bytes / 1024 / 1024))
if [ "$freed_mb" -gt 1024 ]; then
  freed_display="$((freed_mb / 1024))GB"
else
  freed_display="${freed_mb}MB"
fi
echo "  Space to free: $freed_display"

if [ "$DRY_RUN" = "true" ]; then
  echo "  (DRY RUN - no files deleted)"
fi
