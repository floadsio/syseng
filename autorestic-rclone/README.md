# autorestic-rclone

A bash script that combines [autorestic](https://autorestic.vercel.app/) with [rclone](https://rclone.org/) to automatically mount S3 buckets as local filesystems before running backups.

## Overview

This script solves the problem of backing up S3 buckets with autorestic by:

1. **Mounting S3 buckets** locally using rclone FUSE mounts
2. **Running autorestic backups** on the mounted filesystems  
3. **Cleaning up mounts** automatically when done

Perfect for backing up multiple S3 buckets to restic repositories in an automated way.

## Features

- ✅ **Multi-OS support**: Works on FreeBSD, OpenBSD, and Debian/Ubuntu
- ✅ **Flexible configuration**: Easy-to-edit config file with structured arrays
- ✅ **Dry-run mode**: Test your configuration without actual operations
- ✅ **Single or bulk operations**: Backup one location or all locations at once
- ✅ **Robust error handling**: Handles rclone daemon issues and repository locks
- ✅ **Clean separation**: Code in script, configuration in separate file

## Installation

1. **Download the script:**
   ```bash
   curl -o autorestic-rclone.sh https://raw.githubusercontent.com/floadsio/syseng/refs/heads/main/autorestic-rclone/autorestic-rclone.sh
   chmod +x autorestic-rclone.sh
   ```

2. **Create the configuration file** at `~/.autorestic-rclone.conf` (see Configuration section below)

## Configuration

### ~/.autorestic-rclone.conf

Create this file in your home directory with your backup location definitions:

```bash
#!/usr/bin/env bash

# ~/.autorestic-rclone.conf - Configuration for autorestic-rclone backup script

# Location list
LOCATIONS=("web-app-dev" "web-app-prod" "database-backups")

# Configuration using associative arrays with structured keys
declare -A CONFIG

# Development environment
CONFIG["web-app-dev.remote"]="aws-s3-remote"
CONFIG["web-app-dev.base_dir"]="$HOME/mnt-s3/web-app-dev"
CONFIG["web-app-dev.buckets"]="app-uploads-dev app-logs-dev"
CONFIG["web-app-dev.mount_dirs"]="uploads logs"

# Production environment
CONFIG["web-app-prod.remote"]="aws-s3-remote"
CONFIG["web-app-prod.base_dir"]="$HOME/mnt-s3/web-app-prod"
CONFIG["web-app-prod.buckets"]="app-uploads-prod app-logs-prod app-assets-prod"
CONFIG["web-app-prod.mount_dirs"]="uploads logs assets"

# Database backups
CONFIG["database-backups.remote"]="backup-storage"
CONFIG["database-backups.base_dir"]="$HOME/mnt-s3/database-backups"
CONFIG["database-backups.buckets"]="mysql-dumps postgres-dumps"
CONFIG["database-backups.mount_dirs"]="mysql postgres"
```

**Configuration fields:**
- `remote`: Your rclone remote name (as configured in `rclone config`)
- `base_dir`: Local directory where buckets will be mounted
- `buckets`: Space-separated list of S3 bucket names
- `mount_dirs`: Space-separated list of local directory names (must match bucket count)

### autorestic configuration

Your `~/.autorestic.yml` should have simple location definitions without hooks:

```yaml
locations:
  web-app-dev:
    from: ~/mnt-s3/web-app-dev
    to: backup-repo
    forget: prune
  web-app-prod:
    from: ~/mnt-s3/web-app-prod
    to: backup-repo
    forget: prune
  database-backups:
    from: ~/mnt-s3/database-backups
    to: backup-repo
    forget: prune

backends:
  backup-repo:
    type: s3
    path: s3.amazonaws.com/my-backup-repository
    key: my-encryption-key
```

**Important**: Remove any `hooks` sections from your autorestic config - this script handles all mounting/unmounting.

## Usage

### Basic Commands

```bash
# Backup all locations
./autorestic-rclone.sh

# Backup specific location
./autorestic-rclone.sh web-app-prod

# Dry-run all locations (see what would happen)
./autorestic-rclone.sh --dry-run

# Dry-run specific location
./autorestic-rclone.sh database-backups --dry-run
```

### Cron Usage

Add to your crontab for automated backups:

```bash
# Backup all locations daily at 2 AM
0 2 * * * /path/to/autorestic-rclone.sh

# Backup specific location at different time
30 3 * * * /path/to/autorestic-rclone.sh web-app-prod
```

## How It Works

1. **Mount Phase**: Script mounts all required S3 buckets using rclone with optimized FUSE settings
2. **Backup Phase**: Runs `autorestic backup` on the mounted filesystems
3. **Cleanup Phase**: Unmounts all filesystems and kills rclone processes

### Single Location Flow
```
cleanup → mount buckets → verify mounts → run backup → cleanup
```

### All Locations Flow  
```
cleanup → mount all buckets → run autorestic -a → cleanup all
```

## Troubleshooting

### Repository Lock Errors

If you see "repo already locked" errors:

```bash
# Unlock all backends
autorestic exec -a unlock
```

This is normal during the forget/prune phase and doesn't affect backup data integrity.

### Mount Issues

```bash
# Check what's mounted
mount | grep mnt-s3

# Kill hanging rclone processes  
pkill rclone

# Check rclone processes
ps aux | grep rclone
```

### Common rclone Mount Options

The script uses these optimized rclone settings:
- `--vfs-cache-mode=full`: Full VFS caching for better performance
- `--vfs-cache-max-age=12h`: Cache files for 12 hours
- `--buffer-size=16M`: 16MB buffer for transfers
- `--daemon`: Run in background

## Adding New Locations

1. **Add to LOCATIONS array:**
   ```bash
   LOCATIONS=("web-app-dev" "web-app-prod" "new-service")
   ```

2. **Add configuration:**
   ```bash
   CONFIG["new-service.remote"]="aws-s3-remote"
   CONFIG["new-service.base_dir"]="$HOME/mnt-s3/new-service"  
   CONFIG["new-service.buckets"]="service-data service-logs"
   CONFIG["new-service.mount_dirs"]="data logs"
   ```

3. **Add to autorestic config:**
   ```yaml
   locations:
     new-service:
       from: ~/mnt-s3/new-service
       to: backup-repo
       forget: prune
   ```

4. **Create mount directories:**
   ```bash
   mkdir -p ~/mnt-s3/new-service/{data,logs}
   ```

## Requirements

- **bash** 4.0+
- **autorestic** (configured with backends)
- **rclone** (configured with remotes)  
- **FUSE** support on the system

## OS Compatibility

- ✅ **FreeBSD**: Full support
- ✅ **OpenBSD**: Full support  
- ✅ **Debian/Ubuntu**: Full support
- ⚠️  **Other Linux**: Should work but untested

## License

MIT License - feel free to modify and distribute.

## Contributing

1. Fork the repository
2. Make your changes
3. Test on multiple operating systems
4. Submit a pull request

---

**Note**: This script is designed for test/stage environments. For production use, consider additional monitoring and alerting mechanisms.
