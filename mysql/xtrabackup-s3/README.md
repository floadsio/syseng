# Universal MySQL/MariaDB XtraBackup S3 Management Script

A comprehensive shell script for managing MySQL and MariaDB backups with automatic tool detection. Supports both Percona XtraBackup (MySQL/Percona) and MariaBackup (MariaDB/Galera) with S3 storage integration, full and incremental backups, encryption, compression, and intelligent backup chain management.

## Features

- **🔄 Universal Database Support**: Auto-detects MySQL/Percona vs MariaDB and uses appropriate backup tool
- **🎯 Galera Cluster Support**: Native MariaDB Galera cluster backup with `--galera-info`
- **📦 Full & Incremental Backups**: Automated backup chain management with clear relationships
- **☁️ S3 Integration**: Seamless sync to S3-compatible storage with MinIO client
- **🔒 Encryption & Compression**: Built-in AES256 encryption and zstd compression
- **🔗 Backup Chain Tracking**: Smart naming convention to track incremental relationships
- **🏠 Local-Only Mode**: Complete offline backup support with `--local-only`
- **🔄 Flexible Sync Options**: Local-only, S3-only, or combined backup strategies
- **🛠️ Comprehensive Management**: List, sync, delete, and restore backup chains
- **👀 Dry-Run Support**: Preview all operations before execution
- **📊 Chain Analysis**: Analyze backup chains and find orphaned backups

## Database Compatibility

| Database | Backup Tool | Galera Support | Status |
|----------|-------------|----------------|--------|
| **MySQL 8.0+** | `xtrabackup` | N/A | ✅ Fully Supported |
| **Percona Server** | `xtrabackup` | N/A | ✅ Fully Supported |
| **MariaDB 10.x** | `mariabackup` | ❌ Standalone | ✅ Fully Supported |
| **MariaDB Galera Cluster** | `mariabackup --galera-info` | ✅ Cluster-aware | ✅ Fully Supported |

The script automatically detects your database type and uses the appropriate backup tool.

## Requirements

Choose based on your database:

### For MySQL/Percona Server
- **Percona XtraBackup** (8.0+)
- **MySQL/Percona Server** (8.0+)

### For MariaDB
- **MariaDB Backup** (`mariadb-backup` package)
- **MariaDB Server** (10.x+)

### Common Requirements
- **MinIO Client (mc)** - configured with S3 credentials (optional with `--local-only`)
- **zstd** - for compression (optional)
- **Shell access** with appropriate permissions

## Installation

### Install Backup Tools

**For MariaDB:**
```bash
# Ubuntu/Debian
sudo apt install mariadb-backup

# RHEL/CentOS
sudo yum install MariaDB-backup
```

**For MySQL/Percona:**
```bash
# Ubuntu/Debian
sudo apt install percona-xtrabackup-80

# RHEL/CentOS
sudo yum install percona-xtrabackup-80
```

**Install Supporting Tools:**
```bash
# Ubuntu/Debian
sudo apt install zstd mc

# RHEL/CentOS
sudo yum install zstd mc
```

## Configuration

### 1. Database-Specific Configuration

#### For MySQL/Percona (`/root/.my.cnf`)
```ini
[client]
user=root
password=your_password

[xtrabackup]
datadir=/var/lib/mysql
parallel=10
compress
encrypt=AES256
encrypt-key=<your-base64-key>  # Generate with: openssl rand -base64 24
encrypt-threads=10
```

#### For MariaDB (`/root/.my.cnf`)
```ini
[client]
user=root
password=your_password

[mariabackup]
user=root
password=your_password
```

**Important**: MariaDB users should avoid XtraBackup-specific encryption variables in the config file, as the script handles tool differences automatically.

### 2. Script Configuration (`~/.xtrabackup-s3.conf`)

```bash
# S3 Configuration (optional with --local-only)
CFG_MC_BUCKET_PATH="your-mc-alias/mysql-backups/$CFG_HOSTNAME"

# Backup Retention
CFG_CUTOFF_DAYS=7
CFG_LOCAL_BACKUP_KEEP_COUNT=4

# Local Storage
CFG_LOCAL_BACKUP_DIR=/mnt/backup
```

### 3. MinIO Client Setup (Optional)

```bash
# Configure mc alias (skip if using --local-only)
mc alias set your-alias https://your-s3-endpoint.com ACCESS_KEY SECRET_KEY

# Test connection
mc ls your-alias/mysql-backups/
```

## Usage

### Basic Commands

```bash
# Show help and database compatibility info
./xtrabackup-s3.sh

# Create full backup (auto-detects database type)
./xtrabackup-s3.sh full

# Create incremental backup
./xtrabackup-s3.sh inc

# List all backups (shows backup chains)
./xtrabackup-s3.sh list
```

### Local-Only Mode

Perfect for environments without S3 access or purely local backup strategies:

```bash
# Full backup with local cleanup only (no S3 operations)
./xtrabackup-s3.sh full --cleanup --local-only

# Incremental backup, completely local
./xtrabackup-s3.sh inc --local-only

# List only local backups (skip S3 access)
./xtrabackup-s3.sh list --local-only

# Preview local-only operations
./xtrabackup-s3.sh full --local-only --dry-run
```

### Available Commands

| Command | Description | S3 Required |
|---------|-------------|-------------|
| `full` | Create full backup | Optional |
| `inc` | Create incremental backup | Optional |
| `list` | List all backups | Optional |
| `restore <backup>` | Restore from full backup | **No** (prefers local) |
| `sync <folder>` | Sync specific backup to S3 | Yes |
| `sync-all` | Sync all local backups to S3 | Yes |
| `delete-chain <backup>` | Delete incrementals for a full backup | Yes |
| `analyze-chains` | Analyze backup chains and find orphans | Yes |

### Backup Options

```bash
# Full backup with cleanup of old backups
./xtrabackup-s3.sh full --cleanup

# Skip S3 sync but keep S3 cleanup functionality  
./xtrabackup-s3.sh inc --no-sync

# Completely disable all S3 operations
./xtrabackup-s3.sh inc --local-only

# Preview what would happen (dry run)
./xtrabackup-s3.sh full --cleanup --dry-run
```

## Restore Operations

### Smart Restore Logic

The `restore` command intelligently chooses between local and S3 backups:

1. **Checks local backups first** - if backup exists locally, uses it directly
2. **Falls back to S3** - if not found locally, downloads from S3
3. **Automatic detection** - no need to specify source location

```bash
# Restore from local backup (if available) or S3
./xtrabackup-s3.sh restore 2025-07-18_08-57-49_full_1750928269

# Preview restore operation
./xtrabackup-s3.sh restore 2025-07-18_08-57-49_full_1750928269 --dry-run
```

### Restore Examples

**Local-Only Environment:**
```bash
# List local backups
./xtrabackup-s3.sh list --local-only

# Restore from local backup (no S3 required)
./xtrabackup-s3.sh restore 2025-07-18_08-57-49_full_1750928269

# Output: "Using local backup: /mnt/backup/2025-07-18_08-57-49_full_1750928269"
```

**S3-Integrated Environment:**
```bash
# List all backups
./xtrabackup-s3.sh list

# Restore - will use local if available, otherwise S3
./xtrabackup-s3.sh restore 2025-07-18_08-57-49_full_1750928269

# Output: "Using S3 backup: s3://bucket/2025-07-18_08-57-49_full_1750928269"
```

## Backup Chain Structure

The script uses an intelligent naming convention to track backup relationships:

```
📁 2025-07-18_08-57-49_full_1750928269 (12G) [FULL]
  ↳ 2025-07-18_12-00-00_inc_base-1750928269_1750939200 (2G) [INC]
  ↳ 2025-07-18_18-00-00_inc_base-1750928269_1750960800 (1G) [INC]
📁 2025-07-19_08-57-49_full_1750928270 (12G) [FULL]
  ↳ 2025-07-19_12-00-00_inc_base-1750928270_1750968800 (3G) [INC]
```

### Naming Convention

- **Full backups**: `YYYY-MM-DD_HH-MM-SS_full_TIMESTAMP`
- **Incremental backups**: `YYYY-MM-DD_HH-MM-SS_inc_base-BASE_TIMESTAMP_INC_TIMESTAMP`

The `base-TIMESTAMP` clearly shows which full backup each incremental belongs to.

## Workflow Examples

### MariaDB Galera Cluster Strategy

```bash
# Local-only backups for fast recovery
./xtrabackup-s3.sh full --cleanup --local-only

# Incremental backups every few hours
./xtrabackup-s3.sh inc --local-only

# Analyze backup chains
./xtrabackup-s3.sh analyze-chains
```

### Mixed Environment Strategy

```bash
# Development (local-only)
./xtrabackup-s3.sh inc --local-only

# Production (with S3 sync)
./xtrabackup-s3.sh full --cleanup

# Sync development backups to S3 when needed
./xtrabackup-s3.sh sync-all --dry-run
./xtrabackup-s3.sh sync-all
```

### Traditional S3 Strategy

```bash
# Sunday: Full backup with cleanup
./xtrabackup-s3.sh full --cleanup

# Monday-Saturday: Incremental backups
./xtrabackup-s3.sh inc

# Weekly: Analyze backup chains
./xtrabackup-s3.sh analyze-chains
```

## Management Commands

### Chain Analysis

```bash
# Analyze all backup chains
./xtrabackup-s3.sh analyze-chains

# Example output:
# === BACKUP CHAIN ANALYSIS ===
# Current backup chains:
# 📁 2025-07-18_08-57-49_full_1750928269
#    ↳ 3 incrementals
# 📁 2025-07-19_08-57-49_full_1750928270 [standalone]
# === END ANALYSIS ===
```

### Chain Management

```bash
# Delete all incrementals for a full backup (keeps full backup)
./xtrabackup-s3.sh delete-chain 2025-07-18_08-57-49_full_1750928269 --dry-run
./xtrabackup-s3.sh delete-chain 2025-07-18_08-57-49_full_1750928269

# Sync specific backup to S3
./xtrabackup-s3.sh sync 2025-07-18_12-00-00_inc_base-1750928269_1750939200

# Sync all local backups to S3
./xtrabackup-s3.sh sync-all --dry-run
./xtrabackup-s3.sh sync-all
```

## Tool Detection Output

The script provides clear feedback about detected database type:

```bash
$ ./xtrabackup-s3.sh full --local-only

Detecting database type and backup tool...
MariaDB detected - using mariabackup
Galera cluster detected - adding --galera-info option
Using backup tool: mariabackup --galera-info
```

## Storage Layout

### Local Storage (`/mnt/backup/`)
```
/mnt/backup/
├── 2025-07-18_08-57-49_full_1750928269/
├── 2025-07-18_12-00-00_inc_base-1750928269_1750939200/
├── 2025-07-18_18-00-00_inc_base-1750928269_1750960800/
└── 2025-07-19_08-57-49_full_1750928270/
```

### S3 Storage (Optional)
```
mysql-backups/hostname/
├── 2025-07-18_08-57-49_full_1750928269/
├── 2025-07-18_12-00-00_inc_base-1750928269_1750939200/
├── 2025-07-18_18-00-00_inc_base-1750928269_1750960800/
└── 2025-07-19_08-57-49_full_1750928270/
```

## Automation Examples

### Cron Examples

**Mixed Environment:**
```bash
# MariaDB Galera - local-only backups
0 2 * * 0 /root/xtrabackup-s3.sh full --cleanup --local-only
0 */6 * * 1-6 /root/xtrabackup-s3.sh inc --local-only

# MySQL Production - with S3 sync
0 2 * * 0 /root/xtrabackup-s3.sh full --cleanup
0 */6 * * 1-6 /root/xtrabackup-s3.sh inc
```

**Local-Only Strategy:**
```bash
# Full backup Sundays with local cleanup
0 2 * * 0 /root/xtrabackup-s3.sh full --cleanup --local-only

# Incremental backups every 4 hours
0 */4 * * * /root/xtrabackup-s3.sh inc --local-only

# Weekly chain analysis
0 3 * * 0 /root/xtrabackup-s3.sh analyze-chains
```

**S3-Integrated Strategy:**
```bash
# Full backup with S3 sync and cleanup
0 2 * * 0 /root/xtrabackup-s3.sh full --cleanup

# Incremental backups with S3 sync
0 */6 * * * /root/xtrabackup-s3.sh inc

# Daily: Sync any missed backups
0 3 * * * /root/xtrabackup-s3.sh sync-all

# Weekly: Analyze backup chains
0 4 * * 0 /root/xtrabackup-s3.sh analyze-chains
```

## Troubleshooting

### Database Detection Issues

1. **"No backup tool found"**
   ```bash
   # Install appropriate tool
   sudo apt install mariadb-backup    # For MariaDB
   sudo apt install percona-xtrabackup-80  # For MySQL/Percona
   ```

2. **Tool detection incorrect**
   - Ensure only one backup tool is installed per server
   - Check `which mariabackup` and `which xtrabackup`

### MariaDB-Specific Issues

1. **"unknown variable 'encrypt=AES256'"**
   - Remove XtraBackup encryption variables from `/root/.my.cnf`
   - The script creates clean config files automatically

2. **"--defaults-file must be specified first"**
   - Fixed in current version - the script handles argument order correctly

3. **Galera cluster backup issues**
   - Ensure the script detects Galera correctly
   - Check `mysql -e "SHOW STATUS LIKE 'wsrep%'"`

### Common Issues

1. **"No previous full backup found"**
   - Create a full backup first: `./xtrabackup-s3.sh full`

2. **Local-only mode with S3 errors**
   - Use `--local-only` to skip all S3 operations
   - No need for mc configuration in local-only mode

3. **"Configuration file not found"**
   - Create `~/.xtrabackup-s3.conf` with required settings
   - See configuration section above

4. **"Backup not found for restore"**
   - Check local backups: `./xtrabackup-s3.sh list --local-only`
   - Check S3 backups: `./xtrabackup-s3.sh list`
   - Verify backup name spelling

### Debugging

```bash
# Test database detection
./xtrabackup-s3.sh list --local-only

# Test script syntax
sh -n ./xtrabackup-s3.sh

# Dry run any operation
./xtrabackup-s3.sh <command> --dry-run

# Check installed tools
which mariabackup xtrabackup

# Test database connectivity  
mysql -e "SELECT VERSION()"

# Check backup directory
ls -la $CFG_LOCAL_BACKUP_DIR
```

## Migration Guide

### From XtraBackup-only to Universal Script

1. **Backup existing config:**
   ```bash
   cp /root/.my.cnf /root/.my.cnf.backup
   ```

2. **For MariaDB users - clean config:**
   ```bash
   # Remove XtraBackup-specific variables from [client] section
   # Keep only: user, password in [mariabackup] section
   ```

3. **Test with dry-run:**
   ```bash
   ./xtrabackup-s3.sh full --local-only --dry-run
   ```

4. **Verify tool detection:**
   ```bash
   ./xtrabackup-s3.sh list --local-only
   ```

## Option Reference

| Option | Description | Available Commands |
|--------|-------------|-------------------|
| `--dry-run` | Preview operations without execution | All commands |
| `--cleanup` | Remove old backups after operation | `full`, `inc` |
| `--no-sync` | Skip S3 sync, local backup only | `full`, `inc` |
| `--local-only` | Skip ALL S3 operations completely | `full`, `inc`, `list` |
| `--restore-dir=<path>` | Custom restore directory | `restore-chain` |

### Option Comparison

| Scenario | Use Option | S3 Sync | S3 Cleanup | S3 List |
|----------|------------|---------|------------|---------|
| **Full S3 integration** | _(none)_ | ✅ | ✅ | ✅ |
| **Local backup + manual S3** | `--no-sync` | ❌ | ✅ | ✅ |
| **Completely offline** | `--local-only` | ❌ | ❌ | ❌ |

## Advanced Usage

### Backup Chain Analysis

```bash
# Analyze backup chains for issues
./xtrabackup-s3.sh analyze-chains

# Clean up orphaned backups
./xtrabackup-s3.sh full --cleanup --dry-run
./xtrabackup-s3.sh full --cleanup
```

### Selective Sync Operations

```bash
# Sync only specific backup types
find /mnt/backup -name "*_full_*" -exec basename {} \; | while read backup; do
    ./xtrabackup-s3.sh sync "$backup"
done

# Sync recent backups only
find /mnt/backup -name "20*" -mtime -7 -exec basename {} \; | while read backup; do
    ./xtrabackup-s3.sh sync "$backup"
done
```

### Health Monitoring

```bash
# Check backup consistency
./xtrabackup-s3.sh list --local-only | grep -c "FULL"
./xtrabackup-s3.sh analyze-chains | grep -c "ORPHANED"

# Monitor backup sizes
du -sh /mnt/backup/20*
```

## Security Notes

- Store encryption keys securely
- Limit access to configuration files (`chmod 600 /root/.my.cnf`)
- Use dedicated backup user with minimal database privileges
- Regularly test restore procedures with both tools
- Monitor backup success/failure
- For Galera clusters, consider node-specific backup strategies
- Rotate backup encryption keys periodically

## Performance Considerations

### MariaDB Galera Clusters
- Run backups on non-primary nodes when possible
- Consider `--galera-info` impact on cluster performance
- Monitor cluster state during backup operations

### Local Storage
- Ensure sufficient disk space for retention policy
- Consider backup compression for large databases
- Use fast storage for backup destinations

### Network Considerations
- S3 sync operations can be bandwidth-intensive
- Consider using `--no-sync` during peak hours
- Monitor S3 transfer costs and quotas

## License

This script is provided as-is. Test thoroughly before production use.

---

**🚀 New in this version**: Universal database support with automatic MariaDB/MySQL detection, Galera cluster support, local-only backup mode for offline environments, and comprehensive chain management tools.-only mode

### Debugging

```bash
# Test database detection
./xtrabackup-s3.sh list --local-only

# Dry run any operation
./xtrabackup-s3.sh <command> --dry-run

# Check installed tools
which mariabackup xtrabackup

# Test database connectivity  
mysql -e "SELECT VERSION()"
```

## Migration Guide

### From XtraBackup-only to Universal Script

1. **Backup existing config:**
   ```bash
   cp /root/.my.cnf /root/.my.cnf.backup
   ```

2. **For MariaDB users - clean config:**
   ```bash
   # Remove XtraBackup-specific variables from [client] section
   # Keep only: user, password
   ```

3. **Test with dry-run:**
   ```bash
   ./xtrabackup-s3.sh full --local-only --dry-run
   ```

## Option Reference

| Option | Description | Available Commands |
|--------|-------------|-------------------|
| `--dry-run` | Preview operations without execution | All commands |
| `--cleanup` | Remove old backups after operation | `full`, `inc` |
| `--no-sync` | Skip S3 sync, local backup only | `full`, `inc` |
| `--local-only` | Skip ALL S3 operations completely | `full`, `inc`, `list` |

### Option Comparison

| Scenario | Use Option | S3 Sync | S3 Cleanup | S3 List |
|----------|------------|---------|------------|---------|
| **Full S3 integration** | _(none)_ | ✅ | ✅ | ✅ |
| **Local backup + manual S3** | `--no-sync` | ❌ | ✅ | ✅ |
| **Completely offline** | `--local-only` | ❌ | ❌ | ❌ |

## Security Notes

- Store encryption keys securely
- Limit access to configuration files (`chmod 600 /root/.my.cnf`)
- Use dedicated backup user with minimal database privileges
- Regularly test restore procedures with both tools
- Monitor backup success/failure
- For Galera clusters, consider node-specific backup strategies

## License

This script is provided as-is. Test thoroughly before production use.