# MySQL XtraBackup S3 Management Script

A comprehensive shell script for managing MySQL backups using Percona XtraBackup with S3 storage integration. Supports full and incremental backups with automatic encryption, compression, and intelligent backup chain management.

## Features

- **Full & Incremental Backups**: Automated backup chain management with clear relationships
- **S3 Integration**: Seamless sync to S3-compatible storage with MinIO client
- **Encryption & Compression**: Built-in AES256 encryption and zstd compression
- **Backup Chain Tracking**: Smart naming convention to track incremental relationships
- **Point-in-Time Recovery**: Restore to any specific incremental backup
- **Flexible Sync Options**: Local-only, S3-only, or combined backup strategies
- **Comprehensive Management**: List, sync, delete, and restore backup chains
- **Dry-Run Support**: Preview all operations before execution

## Requirements

- **Percona XtraBackup** (8.0+)
- **MinIO Client (mc)** - configured with S3 credentials
- **MySQL/Percona Server** (8.0+)
- **zstd** - for compression
- **Shell access** with appropriate permissions

## Configuration

### 1. XtraBackup Configuration (`/root/.my.cnf`)

```ini
[client]
user=root

[xtrabackup]
datadir=/var/lib/mysql
parallel=10
compress
encrypt=AES256
encrypt-key=<your-base64-key>  # Generate with: openssl rand -base64 24
encrypt-threads=10

[xbcloud]
storage=s3
s3-endpoint=your-s3-endpoint.com
s3-bucket-lookup=DNS
s3-api-version=4
s3-access-key=<access-key>
s3-secret-key=<secret-key>
s3-bucket=mysql-backups
parallel=10
```

### 2. Script Configuration (`~/.xtrabackup-s3.conf`)

```bash
CFG_MC_BUCKET_PATH="your-mc-alias@endpoint/mysql-backups/$CFG_HOSTNAME"
CFG_CUTOFF_DAYS=7
CFG_LOCAL_BACKUP_DIR=/mnt/backup
CFG_LOCAL_BACKUP_KEEP_COUNT=4
```

### 3. MinIO Client Setup

```bash
# Configure mc alias
mc alias set your-alias https://your-s3-endpoint.com ACCESS_KEY SECRET_KEY

# Test connection
mc ls your-alias/mysql-backups/
```

## Usage

### Basic Commands

```bash
# Show help
./xtrabackup-s3.sh

# Create full backup
./xtrabackup-s3.sh full

# Create incremental backup
./xtrabackup-s3.sh inc

# List all backups (shows backup chains)
./xtrabackup-s3.sh list

# Restore full backup only
./xtrabackup-s3.sh restore 2025-06-26_08-57-49_full_1750928269

# Restore full backup + all incrementals
./xtrabackup-s3.sh restore-chain 2025-06-26_08-57-49_full_1750928269

# Point-in-time recovery (restore up to specific incremental)
./xtrabackup-s3.sh restore-chain 2025-06-26_13-11-05_inc_base-1750928269_1750943465
```

### Backup Options

```bash
# Full backup with cleanup of old backups
./xtrabackup-s3.sh full --cleanup

# Local-only backup (skip S3 sync)
./xtrabackup-s3.sh inc --no-sync

# Preview what would happen (dry run)
./xtrabackup-s3.sh full --cleanup --dry-run
```

### Sync Operations

```bash
# Sync specific backup to S3
./xtrabackup-s3.sh sync 2025-06-26_13-11-05_inc_base-1750928269_1750943465

# Sync all local backups to S3
./xtrabackup-s3.sh sync-all

# Preview sync operations
./xtrabackup-s3.sh sync-all --dry-run
```

### Chain Management

```bash
# Delete all incrementals for a full backup (keeps the full backup)
./xtrabackup-s3.sh delete-chain 2025-06-26_08-57-49_full_1750928269

# Preview what would be deleted
./xtrabackup-s3.sh delete-chain 2025-06-26_08-57-49_full_1750928269 --dry-run
```

## Backup Chain Structure

The script uses an intelligent naming convention to track backup relationships:

```
📁 2025-06-26_08-57-49_full_1750928269 (12G) [FULL]
  ↳ 2025-06-26_12-00-00_inc_base-1750928269_1750939200 (2G) [INC]
  ↳ 2025-06-26_18-00-00_inc_base-1750928269_1750960800 (1G) [INC]
📁 2025-06-27_08-57-49_full_1750928270 (12G) [FULL]
  ↳ 2025-06-27_12-00-00_inc_base-1750928270_1750968800 (3G) [INC]
```

### Naming Convention

- **Full backups**: `YYYY-MM-DD_HH-MM-SS_full_TIMESTAMP`
- **Incremental backups**: `YYYY-MM-DD_HH-MM-SS_inc_base-BASE_TIMESTAMP_INC_TIMESTAMP`

The `base-TIMESTAMP` clearly shows which full backup each incremental belongs to.

## Workflow Examples

### Daily Backup Strategy

```bash
# Sunday: Full backup with cleanup
./xtrabackup-s3.sh full --cleanup

# Monday-Saturday: Incremental backups
./xtrabackup-s3.sh inc
```

### Local + S3 Strategy

```bash
# Fast local backup during business hours
./xtrabackup-s3.sh inc --no-sync

# Sync to S3 during off-hours
./xtrabackup-s3.sh sync-all
```

### Point-in-Time Recovery

```bash
# 1. List available backups
./xtrabackup-s3.sh list

# 2. Choose target incremental for recovery point
./xtrabackup-s3.sh restore-chain 2025-06-26_15-30-00_inc_base-1750928269_1750954200 --dry-run

# 3. Execute restore
./xtrabackup-s3.sh restore-chain 2025-06-26_15-30-00_inc_base-1750928269_1750954200
```

## Storage Layout

### Local Storage (`/mnt/backup/`)
```
/mnt/backup/
├── 2025-06-26_08-57-49_full_1750928269/
├── 2025-06-26_12-00-00_inc_base-1750928269_1750939200/
├── 2025-06-26_18-00-00_inc_base-1750928269_1750960800/
└── 2025-06-27_08-57-49_full_1750928270/
```

### S3 Storage
```
mysql-backups/hostname/
├── 2025-06-26_08-57-49_full_1750928269/
├── 2025-06-26_12-00-00_inc_base-1750928269_1750939200/
├── 2025-06-26_18-00-00_inc_base-1750928269_1750960800/
└── 2025-06-27_08-57-49_full_1750928270/
```

## Automation

### Cron Examples

```bash
# Daily full backup at 2 AM with 7-day cleanup
0 2 * * 0 /root/xtrabackup-s3.sh full --cleanup

# Incremental backups every 6 hours
0 */6 * * 1-6 /root/xtrabackup-s3.sh inc

# Sync local backups to S3 at 3 AM
0 3 * * * /root/xtrabackup-s3.sh sync-all
```

## Troubleshooting

### Common Issues

1. **"shift: can't shift that many"**
   - Run script with arguments: `./xtrabackup-s3.sh list`

2. **"No previous full backup found"**
   - Create a full backup first: `./xtrabackup-s3.sh full`

3. **"Could not access remote backups"**
   - Check mc configuration: `mc ls your-alias/mysql-backups/`

4. **Encryption/decryption errors**
   - Verify encrypt-key in `/root/.my.cnf` matches the key used for backups

### Debugging

```bash
# Test configuration
./xtrabackup-s3.sh list

# Dry run any operation
./xtrabackup-s3.sh <command> --dry-run

# Check mc connectivity
mc ls $CFG_MC_BUCKET_PATH
```

## Security Notes

- Store encryption keys securely
- Limit access to configuration files (`chmod 600 /root/.my.cnf`)
- Use dedicated backup user with minimal MySQL privileges
- Regularly test restore procedures
- Monitor backup success/failure

## License

This script is provided as-is. Test thoroughly before production use.