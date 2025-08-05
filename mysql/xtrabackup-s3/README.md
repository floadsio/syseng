# Universal MySQL/MariaDB XtraBackup S3 Management Scripts

A comprehensive set of POSIX-compliant shell scripts for managing MySQL and MariaDB backups with automatic tool detection. Supports both Percona XtraBackup (MySQL/Percona) and MariaBackup (MariaDB/Galera) with S3 storage integration, full and incremental backups, encryption, compression, intelligent backup chain management, and MD5-verified sync operations.

## Architecture

The system consists of three specialized scripts:

- **`xtrabackup-s3.sh`** - Handles all backup operations (full, incremental, sync, management)
- **`xtrabackup-s3-restore.sh`** - Handles restore operations with automatic decompression/decryption
- **`xtrabackup-s3-check.sh`** - Analysis and integrity checking operations

## Features

- **🔄 Universal Database Support**: Auto-detects MySQL/Percona vs MariaDB and uses appropriate backup tool
- **🎯 Galera Cluster Support**: Native MariaDB Galera cluster backup with `--galera-info`
- **📦 Full & Incremental Backups**: Automated backup chain management with clear relationships
- **☁️ S3 Integration**: Seamless sync to S3-compatible storage with MinIO client and MD5 verification
- **🔒 Encryption & Compression**: Built-in AES256 encryption and zstd compression
- **🔗 Backup Chain Tracking**: Smart naming convention to track incremental relationships
- **🏠 Local-Only Mode**: Complete offline backup support with `--local-only`
- **🔄 Flexible Sync Options**: Local-only, S3-only, or combined backup strategies
- **📊 Chain Analysis**: Analyze backup chains, find orphaned backups, and storage summaries
- **🔧 Automatic Restore Handling**: Decryption, decompression, and preparation in one step
- **🔍 Integrity Checking**: Verify backup completeness and metadata

## Database Compatibility

| Database | Backup Tool | Galera Support | Status |
|----------|-------------|----------------|--------|
| **MySQL 8.0+** | `xtrabackup` | N/A | ✅ Fully Supported |
| **Percona Server** | `xtrabackup` | N/A | ✅ Fully Supported |
| **MariaDB 10.x** | `mariabackup` | ❌ Standalone | ✅ Fully Supported |
| **MariaDB Galera Cluster** | `mariabackup --galera-info` | ✅ Cluster-aware | ✅ Fully Supported |

The scripts automatically detect your database type and use the appropriate backup tool.

## Installation

### Install Backup Tools

**For MariaDB:**
```bash
sudo apt install mariadb-backup    # Ubuntu/Debian
sudo yum install MariaDB-backup    # RHEL/CentOS
```

**For MySQL/Percona:**
```bash
sudo apt install percona-xtrabackup-80    # Ubuntu/Debian
sudo yum install percona-xtrabackup-80    # RHEL/CentOS
```

**Supporting Tools:**
```bash
sudo apt install zstd mc    # Ubuntu/Debian
sudo yum install zstd mc    # RHEL/CentOS
```

### Install Scripts

```bash
# Download all three scripts
wget https://example.com/xtrabackup-s3{,-restore,-check}.sh

# Make executable and move to PATH
chmod +x xtrabackup-s3*.sh
sudo mv xtrabackup-s3*.sh /usr/local/bin/
```

## Configuration

### Database Configuration (`/root/.my.cnf`)

**For MySQL/Percona:**
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

**For MariaDB:**
```ini
[client]
user=root
password=your_password

[mariabackup]
user=root
password=your_password
```

### Script Configuration (`~/.xtrabackup-s3.conf`)

```bash
# S3 Configuration (optional with --local-only)
CFG_MC_BUCKET_PATH="your-mc-alias/mysql-backups/$CFG_HOSTNAME"

# Backup Retention
CFG_CUTOFF_DAYS=7
CFG_LOCAL_BACKUP_KEEP_COUNT=4

# Local Storage
CFG_LOCAL_BACKUP_DIR=/mnt/backup
```

### MinIO Client Setup (Optional)

```bash
# Configure mc alias (skip if using --local-only)
mc alias set your-alias https://your-s3-endpoint.com ACCESS_KEY SECRET_KEY
```

## Usage Examples

### Basic Backup Operations

```bash
# Create full backup (auto-detects database type)
xtrabackup-s3.sh full

# Create incremental backup
xtrabackup-s3.sh inc

# Full backup with cleanup of old backups
xtrabackup-s3.sh full --cleanup

# Local-only backup (no S3 operations)
xtrabackup-s3.sh full --cleanup --local-only

# Preview operations without execution
xtrabackup-s3.sh full --cleanup --dry-run
```

### Analysis Operations

```bash
# Analyze all backup chains with storage summary
xtrabackup-s3-check.sh analyze-chains

# Example output:
# === BACKUP CHAIN ANALYSIS ===
# 📁 2025-07-29_21-00-02_full_1753822802 [LOCAL]
#    ├─ Date: 2025:07:29 21:00:02
#    ├─ Chain: 3 incrementals
#    ├─ Inc 1: 2025:07:30 08:00:02 (2025-07-30_08-00-02_inc_base-1753822802_1753891202)
#    └─ Inc 3: 2025:07:31 00:00:02 (2025-07-31_00-00-02_inc_base-1753822802_1753948802)
#    💡 Restore with: xtrabackup-s3-restore.sh restore-chain 2025-07-29_21-00-02_full_1753822802 [incremental-backup-name]
#
# === BACKUP SUMMARY ===
# 📊 Total Full Backups: 5
# 📊 Total Incremental Backups: 23
# 📊 Total Backups: 28
# 💾 Local Storage Used: 15GB
# ☁️  S3 Storage Used: 142GB
# 📈 Total Storage Used: 157GB

# Check integrity of specific backup and its entire chain
xtrabackup-s3-check.sh check 2025-07-29_21-00-02_full_1753822802

# List all backups with sizes
xtrabackup-s3-check.sh list
```

### Restore Operations

```bash
# Restore from local backup (if available) or S3
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269

# Restore full backup + all incrementals in chain
xtrabackup-s3-restore.sh restore-chain 2025-07-18_08-57-49_full_1750928269

# Restore up to specific incremental (point-in-time recovery)
xtrabackup-s3-restore.sh restore-chain 2025-07-18_08-57-49_full_1750928269 2025-07-18_12-00-00_inc_base-1750928269_1750939200

# Preview restore operation
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269 --dry-run
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

## Workflow Examples

### MariaDB Galera Cluster Strategy

```bash
# Local-only backups for fast recovery
xtrabackup-s3.sh full --cleanup --local-only
xtrabackup-s3.sh inc --local-only

# Analyze backup chains
xtrabackup-s3-check.sh analyze-chains

# Restore when needed (automatic tool detection)
xtrabackup-s3-restore.sh restore 2025-07-18_08-57-49_full_1750928269
```

### Traditional S3 Strategy

```bash
# Sunday: Full backup with cleanup
xtrabackup-s3.sh full --cleanup

# Monday-Saturday: Incremental backups
xtrabackup-s3.sh inc

# Weekly: Analyze backup chains
xtrabackup-s3-check.sh analyze-chains

# Monthly: Check integrity of recent backups
xtrabackup-s3-check.sh check $(xtrabackup-s3-check.sh list | grep full | head -1 | awk '{print $1}')

# Restore with automatic S3 download if needed
xtrabackup-s3-restore.sh restore 2025-07-19_08-57-49_full_1750928270
```

## Automation Examples

### Cron Jobs

**Local-Only Strategy:**
```bash
# Full backup Sundays with local cleanup
0 2 * * 0 /usr/local/bin/xtrabackup-s3.sh full --cleanup --local-only

# Incremental backups every 4 hours
0 */4 * * * /usr/local/bin/xtrabackup-s3.sh inc --local-only

# Weekly chain analysis
0 3 * * 0 /usr/local/bin/xtrabackup-s3-check.sh analyze-chains
```

**S3-Integrated Strategy:**
```bash
# Full backup with S3 sync and cleanup
0 2 * * 0 /usr/local/bin/xtrabackup-s3.sh full --cleanup

# Incremental backups with S3 sync
0 */6 * * * /usr/local/bin/xtrabackup-s3.sh inc

# Weekly: Analyze backup chains
0 4 * * 0 /usr/local/bin/xtrabackup-s3-check.sh analyze-chains

# Monthly: Integrity check of recent backups
0 5 1 * * /usr/local/bin/xtrabackup-s3-check.sh check $(/usr/local/bin/xtrabackup-s3-check.sh list | grep full | head -1 | awk '{print $1}')
```

## Available Commands

### Backup Script (`xtrabackup-s3.sh`)

| Command | Description | Options |
|---------|-------------|---------|
| `full` | Create full backup | `--cleanup`, `--dry-run`, `--local-only` |
| `inc` | Create incremental backup | `--cleanup`, `--dry-run`, `--local-only` |
| `list` | List all backups | `--local-only` |
| `sync <folder>` | Sync specific backup to S3 | `--dry-run` |
| `sync-all` | Sync all local backups to S3 | `--dry-run` |
| `cleanup` | Standalone cleanup of old chains | `--dry-run` |

### Analysis Script (`xtrabackup-s3-check.sh`)

| Command | Description |
|---------|-------------|
| `analyze-chains` (default) | Show backup chains with storage summary |
| `list` | List local & S3 backups with sizes |
| `check <backup-name>` | Check integrity of specific backup and its chain |

### Restore Script (`xtrabackup-s3-restore.sh`)

| Command | Description | Options |
|---------|-------------|---------|
| `restore <backup>` | Restore a single full backup | `--dry-run`, `--restore-dir=<path>` |
| `restore-chain <full> [target_inc]` | Restore full + incrementals up to target | `--dry-run`, `--restore-dir=<path>` |

## Key Features

### Chain-Aware Retention Logic
- **Analyzes entire chains** - not just individual backup dates
- **Preserves chains with recent incrementals** - even if the full backup is old
- **Only deletes complete chains** - where ALL backups are older than retention period
- **Prevents orphaned incrementals** - that would be unrestorable without their base

### Smart Restore Logic
- **Checks local backups first** - if backup exists locally, uses it directly
- **Falls back to S3** - if not found locally, downloads from S3
- **Automatic detection** - handles encryption/compression automatically
- **Uses `/var/tmp` by default** - for sufficient space during decompression

### Tool Detection
All scripts automatically detect your database type and use the appropriate backup tool:

```bash
$ xtrabackup-s3.sh full --local-only

Detecting database type and backup tool...
MariaDB detected - using mariabackup
Galera cluster detected - adding --galera-info option
Using backup tool: mariabackup --galera-info
```

## License

These scripts are provided as-is. Test thoroughly before production use.

---

**🚀 Architecture**: Three specialized scripts for backup operations, restore operations, and analysis/integrity checking with automatic handling of encryption, compression, and database type detection.