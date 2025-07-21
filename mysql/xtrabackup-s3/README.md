# Universal MySQL/MariaDB XtraBackup S3 Management Scripts

A pair of comprehensive POSIX-compliant shell scripts for managing MySQL and MariaDB backups with automatic tool detection. Supports both Percona XtraBackup (MySQL/Percona) and MariaBackup (MariaDB/Galera) with S3 storage integration, full and incremental backups, encryption, compression, and intelligent backup chain management.

## Architecture

The system consists of two specialized scripts:

- **`xtrabackup-s3.sh`** - Handles all backup operations (full, incremental, sync, management)
- **`xtrabackup-s3-restore.sh`** - Handles restore operations with automatic decompression/decryption

## Features

- **🔄 Universal Database Support**: Auto-detects MySQL/Percona vs MariaDB and uses appropriate backup tool
- **🎯 Galera Cluster Support**: Native MariaDB Galera cluster backup with `--galera-info`
- **📦 Full & Incremental Backups**: Automated backup chain management with clear relationships
- **☁️ S3 Integration**: Seamless sync to S3-compatible storage with MinIO client
- **🔒 Encryption & Compression**: Built-in AES256 encryption and zstd compression
- **🔗 Backup Chain Tracking**: Smart naming convention to track incremental relationships
- **🏠 Local-Only Mode**: Complete offline backup support with `--local-only`
- **🔄 Flexible Sync Options**: Local-only, S3-only, or combined backup strategies
- **🛠️ Comprehensive Management**: List, sync, delete, and analyze backup chains
- **👀 Dry-Run Support**: Preview all operations before execution
- **📊 Chain Analysis**: Analyze backup chains and find orphaned backups
- **🔧 Automatic Restore Handling**: Decryption, decompression, and preparation in one step

## Database Compatibility

| Database | Backup Tool | Galera Support | Status |
|----------|-------------|----------------|--------|
| **MySQL 8.0+** | `xtrabackup` | N/A | ✅ Fully Supported |
| **Percona Server** | `xtrabackup` | N/A | ✅ Fully Supported |
| **MariaDB 10.x** | `mariabackup` | ❌ Standalone | ✅ Fully Supported |
| **MariaDB Galera Cluster** | `mariabackup --galera-info` | ✅ Cluster-aware | ✅ Fully Supported |

The scripts automatically detect your database type and use the appropriate backup tool.

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
- **Sufficient space in `/var/tmp`** for restore operations

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

### Install Scripts

```bash
# Download both scripts
wget https://example.com/xtrabackup-s3.sh
wget https://example.com/xtrabackup-s3-restore.sh

# Make executable and move to PATH
chmod +x xtrabackup-s3*.sh
sudo mv xtrabackup-s3*.sh /usr/local/bin/

# Verify installation
xtrabackup-s3.sh --help
xtrabackup-s3-restore.sh --help
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

### Backup Operations (`xtrabackup-s3.sh`)

#### Basic Commands

```bash
# Show help and database compatibility info
xtrabackup-s3.sh

# Create full backup (auto-detects database type)
xtrabackup-s3.sh full

# Create incremental backup
xtrabackup-s3.sh inc

# List all backups (shows backup chains)
xtrabackup-s3.sh list
```

#### Local-Only Mode

Perfect for environments without S3 access or purely local backup strategies:

```bash
# Full backup with local cleanup only (no S3 operations)
xtrabackup-s3.sh full --cleanup --local-only

# Incremental backup, completely local
xtrabackup-s3.sh inc --local-only

# List only local backups (skip S3 access)
xtrabackup-s3.sh list --local-only

# Preview local-only operations
xtrabackup-s3.sh full --local-only --dry-run
```

#### Available Commands

| Command | Description | S3 Required |
|---------|-------------|-------------|
| `full` | Create full backup | Optional |
| `inc` | Create incremental backup | Optional |
| `list` | List all backups | Optional |
| `sync <folder>` | Sync specific backup to S3 | Yes |
| `sync-all` | Sync all local backups to S3 | Yes |
| `delete-chain <backup>` | Delete incrementals for a full backup | Yes |
| `analyze-chains` | Analyze backup chains and find orphans | Yes |

#### Backup Options

```bash
# Full backup with cleanup of old backups
xtrabackup-s3.sh full --cleanup

# Skip S3 sync but keep S3 cleanup functionality  
xtrabackup-s3.sh inc --no-sync

# Completely disable all S3 operations
xtrabackup-s3.sh inc --local-only

# Preview what would happen (dry run)
xtrabackup-s3.sh full --cleanup --dry-run
```

### Restore Operations (`xtrabackup-s3-restore.sh`)

The restore script handles all complexities of restoration including:
- Automatic detection of encryption/compression
- Decryption using keys from `.my.cnf`
- Decompression of zstd/qpress files
- Proper preparation of backup
- Safe restoration to MySQL data directory
- **Full backup chain restoration** with incremental support

#### Available Restore Commands

| Command | Description | Use Case |
|---------|-------------|----------|
| `restore <backup>` | Restore a single full backup | Simple full backup restoration |
| `restore-chain <full> [target_inc]` | Restore full + incrementals up to target | Point-in-time recovery with incrementals |
| `list` | List local & S3 backups | View available backups |
| `analyze-chains` | Show backup chains and orphans | Analyze backup relationships |

#### Smart Restore Logic

The restore script intelligently chooses between local and S3 backups:

1. **Checks local backups first** - if backup exists locally, uses it directly
2. **Falls back to S3** - if not found locally, downloads from S3
3. **Automatic detection** - no need to specify source location
4. **Uses `/var/tmp` by default** - for sufficient space during decompression

```bash
# Restore from local backup (if available) or S3
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269

# Restore full backup + all incrementals in chain
xtrabackup-s3-restore.sh restore-chain 2025-07-18_08-57-49_full_1750928269

# Restore up to specific incremental (point-in-time recovery)
xtrabackup-s3-restore.sh restore-chain 2025-07-18_08-57-49_full_1750928269 2025-07-18_12-00-00_inc_base-1750928269_1750939200

# Preview restore operation
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269 --dry-run

# Use custom restore directory for decompression
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269 --restore-dir=/mnt/large-disk/restore
```

#### Restore Examples

**Local-Only Environment:**
```bash
# List local backups
xtrabackup-s3.sh list --local-only

# Restore from local backup (no S3 required)
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269

# Output: "Using local backup: /mnt/backup/2025-07-18_08-57-49_full_1750928269"
```

**S3-Integrated Environment:**
```bash
# List all backups
xtrabackup-s3.sh list

# Restore - will use local if available, otherwise S3
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269

# Output: "Using S3 backup: s3://bucket/2025-07-18_08-57-49_full_1750928269"
```

**Encrypted/Compressed Backups:**
```bash
# The restore script automatically handles:
# 1. Detection of .xbcrypt encrypted files
# 2. Reading encryption key from /root/.my.cnf
# 3. Decryption with proper key
# 4. Decompression of .zst files
# 5. Preparation and restoration

xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269
# Output: 
# "Backup is encrypted, checking for encryption key..."
# "Using encryption key from .my.cnf"
# "Decrypting backup..."
# "Backup is compressed, decompressing..."
# "Running prepare phase..."
# "✅ Full backup restored successfully"
```

## Backup Chain Structure

The scripts use an intelligent naming convention to track backup relationships:

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
xtrabackup-s3.sh full --cleanup --local-only

# Incremental backups every few hours
xtrabackup-s3.sh inc --local-only

# Analyze backup chains
xtrabackup-s3.sh analyze-chains

# Restore when needed (automatic tool detection)
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269
```

### Mixed Environment Strategy

```bash
# Development (local-only)
xtrabackup-s3.sh inc --local-only

# Production (with S3 sync)
xtrabackup-s3.sh full --cleanup

# Sync development backups to S3 when needed
xtrabackup-s3.sh sync-all --dry-run
xtrabackup-s3.sh sync-all

# Restore from any source
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269
```

### Traditional S3 Strategy

```bash
# Sunday: Full backup with cleanup
xtrabackup-s3.sh full --cleanup

# Monday-Saturday: Incremental backups
xtrabackup-s3.sh inc

# Weekly: Analyze backup chains
xtrabackup-s3.sh analyze-chains

# Restore with automatic S3 download if needed
xtrabackup-s3-restore.sh restore 2025-07-19_08-57-49_full_1750928270
```

## Management Commands

### Chain Analysis

```bash
# Analyze all backup chains
xtrabackup-s3.sh analyze-chains

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
xtrabackup-s3.sh delete-chain 2025-07-18_08-57-49_full_1750928269 --dry-run
xtrabackup-s3.sh delete-chain 2025-07-18_08-57-49_full_1750928269

# Sync specific backup to S3
xtrabackup-s3.sh sync 2025-07-18_12-00-00_inc_base-1750928269_1750939200

# Sync all local backups to S3
xtrabackup-s3.sh sync-all --dry-run
xtrabackup-s3.sh sync-all
```

## Tool Detection Output

Both scripts provide clear feedback about detected database type:

```bash
$ xtrabackup-s3.sh full --local-only

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
0 2 * * 0 /usr/local/bin/xtrabackup-s3.sh full --cleanup --local-only
0 */6 * * 1-6 /usr/local/bin/xtrabackup-s3.sh inc --local-only

# MySQL Production - with S3 sync
0 2 * * 0 /usr/local/bin/xtrabackup-s3.sh full --cleanup
0 */6 * * 1-6 /usr/local/bin/xtrabackup-s3.sh inc
```

**Local-Only Strategy:**
```bash
# Full backup Sundays with local cleanup
0 2 * * 0 /usr/local/bin/xtrabackup-s3.sh full --cleanup --local-only

# Incremental backups every 4 hours
0 */4 * * * /usr/local/bin/xtrabackup-s3.sh inc --local-only

# Weekly chain analysis
0 3 * * 0 /usr/local/bin/xtrabackup-s3.sh analyze-chains
```

**S3-Integrated Strategy:**
```bash
# Full backup with S3 sync and cleanup
0 2 * * 0 /usr/local/bin/xtrabackup-s3.sh full --cleanup

# Incremental backups with S3 sync
0 */6 * * * /usr/local/bin/xtrabackup-s3.sh inc

# Daily: Sync any missed backups
0 3 * * * /usr/local/bin/xtrabackup-s3.sh sync-all

# Weekly: Analyze backup chains
0 4 * * 0 /usr/local/bin/xtrabackup-s3.sh analyze-chains
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

### Restore-Specific Issues

1. **"Failed to find valid data directory"**
   - Backup may be compressed/encrypted
   - Restore script handles this automatically
   - Check `/var/tmp` has sufficient space

2. **"Encrypted backup found but no encryption key available"**
   - Ensure encryption key is in `/root/.my.cnf`
   - Check `[xtrabackup]` section for `encrypt-key`

3. **"Decompression failed"**
   - Verify sufficient space in restore directory
   - Default uses `/var/tmp` which should have space
   - Use `--restore-dir=/path/with/space` if needed

### Common Issues

1. **"No previous full backup found"**
   - Create a full backup first: `xtrabackup-s3.sh full`

2. **Local-only mode with S3 errors**
   - Use `--local-only` to skip all S3 operations
   - No need for mc configuration in local-only mode

3. **"Configuration file not found"**
   - Create `~/.xtrabackup-s3.conf` with required settings
   - See configuration section above

4. **"Backup not found for restore"**
   - Check local backups: `xtrabackup-s3.sh list --local-only`
   - Check S3 backups: `xtrabackup-s3.sh list`
   - Verify backup name spelling

### Debugging

```bash
# Test database detection
xtrabackup-s3.sh list --local-only

# Test script syntax
sh -n xtrabackup-s3.sh
sh -n xtrabackup-s3-restore.sh

# Dry run any operation
xtrabackup-s3.sh <command> --dry-run
xtrabackup-s3-restore.sh restore <backup> --dry-run

# Check installed tools
which mariabackup xtrabackup

# Test database connectivity  
mysql -e "SELECT VERSION()"

# Check backup directory
ls -la $CFG_LOCAL_BACKUP_DIR

# Verify shellcheck compliance
shellcheck -s sh xtrabackup-s3.sh
shellcheck -s sh xtrabackup-s3-restore.sh
```

## Migration Guide

### From Single Script to Two-Script Architecture

1. **Update script names:**
   ```bash
   # Old: xtrabackup-s3.sh (handled everything)
   # New: xtrabackup-s3.sh (backup only)
   #      xtrabackup-s3-restore.sh (restore only)
   ```

2. **Update cron jobs:**
   ```bash
   # No changes needed - backup operations remain in xtrabackup-s3.sh
   ```

3. **Update restore procedures:**
   ```bash
   # Old: xtrabackup-s3.sh restore <backup>
   # New: xtrabackup-s3-restore.sh restore <backup>
   ```

### From XtraBackup-only to Universal Scripts

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
   xtrabackup-s3.sh full --local-only --dry-run
   xtrabackup-s3-restore.sh restore <backup> --dry-run
   ```

4. **Verify tool detection:**
   ```bash
   xtrabackup-s3.sh list --local-only
   ```

## Option Reference

### Backup Script Options (`xtrabackup-s3.sh`)

| Option | Description | Available Commands |
|--------|-------------|-------------------|
| `--dry-run` | Preview operations without execution | All commands |
| `--cleanup` | Remove old backups after operation | `full`, `inc` |
| `--no-sync` | Skip S3 sync, local backup only | `full`, `inc` |
| `--local-only` | Skip ALL S3 operations completely | `full`, `inc`, `list` |

### Restore Script Options (`xtrabackup-s3-restore.sh`)

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview restore operations without execution |
| `--restore-dir=<path>` | Custom directory for decompression (default: `/var/tmp/restore_$$`) |

**Note**: The restore script automatically handles MariaDB vs MySQL differences, creating appropriate temporary configuration files and using the correct backup tool parameters for each database type.

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
xtrabackup-s3.sh analyze-chains

# Clean up orphaned backups
xtrabackup-s3.sh full --cleanup --dry-run
xtrabackup-s3.sh full --cleanup
```

### Selective Sync Operations

```bash
# Sync only specific backup types
find /mnt/backup -name "*_full_*" -exec basename {} \; | while read backup; do
    xtrabackup-s3.sh sync "$backup"
done

# Sync recent backups only
find /mnt/backup -name "20*" -mtime -7 -exec basename {} \; | while read backup; do
    xtrabackup-s3.sh sync "$backup"
done
```

### Health Monitoring

```bash
# Check backup consistency
xtrabackup-s3.sh list --local-only | grep -c "full"
xtrabackup-s3.sh analyze-chains | grep -c "orphan"

# Monitor backup sizes
du -sh /mnt/backup/20*

# Verify latest backup is restorable (dry-run)
LATEST=$(xtrabackup-s3.sh list --local-only | grep full | head -1 | awk '{print $1}')
xtrabackup-s3-restore.sh restore "$LATEST" --dry-run
```

## Security Notes

- Store encryption keys securely in `/root/.my.cnf` with mode 0600
- Limit access to configuration files
- Use dedicated backup user with minimal database privileges
- Regularly test restore procedures with both scripts
- Monitor backup success/failure via exit codes
- For Galera clusters, consider node-specific backup strategies
- Rotate backup encryption keys periodically
- Ensure `/var/tmp` is secured for restore operations

## Performance Considerations

### MariaDB Galera Clusters
- Run backups on non-primary nodes when possible
- Consider `--galera-info` impact on cluster performance
- Monitor cluster state during backup operations

### Local Storage
- Ensure sufficient disk space for retention policy
- Consider backup compression for large databases
- Use fast storage for backup destinations

### Restore Operations
- Ensure `/var/tmp` has sufficient space (2-3x backup size)
- Use `--restore-dir` to specify alternate location if needed
- SSD storage recommended for faster restore operations

### Network Considerations
- S3 sync operations can be bandwidth-intensive
- Consider using `--no-sync` during peak hours
- Monitor S3 transfer costs and quotas

## Script Features

### Backup Script (`xtrabackup-s3.sh`)
- POSIX shell compliant (shellcheck clean)
- Automatic database type detection
- Intelligent incremental backup base selection
- Chain-aware cleanup operations
- Comprehensive dry-run support

### Restore Script (`xtrabackup-s3-restore.sh`)
- Automatic encryption key detection from `.my.cnf`
- Handles compressed (`.zst`) and encrypted (`.xbcrypt`) backups
- Smart source selection (local preferred over S3)
- Safe restore process with service management
- Configurable working directory for large backups

## License

These scripts are provided as-is. Test thoroughly before production use.

---

**🚀 Architecture Update**: Now using two specialized scripts for better separation of concerns - `xtrabackup-s3.sh` for all backup operations and `xtrabackup-s3-restore.sh` for restore operations with automatic handling of encryption and compression.
