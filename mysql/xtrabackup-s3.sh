#!/bin/sh

#
# Usage
#
# % xtrabackup-s3.sh full       Make a full backup to S3
# % xtrabackup-s3.sh inc        Make an incremental backup to S3
#
# Restore a full + incrementals:
# % xtrabackup-s3.sh restore <full-backup> <inc-backup-1> <inc-backup-2>
#

#
# Example $HOME/.my.cnf:
#
# [client]
# user=root
#
# [xtrabackup]
# datadir=/var/lib/mysql
# parallel=4
# compress
# encrypt=AES256
# encrypt-key= # openssl rand -base64 24
# encrypt-threads=4
# # databases='foo bar'
#
# [xbcloud]
# storage=s3
# s3-endpoint=my.s3.endpoint
# s3-bucket-lookup=DNS
# s3-api-version=4
# s3-access-key=...
# s3-secret-key=..
# s3-bucket=mysql-backups
# parallel=10

CFG_EXTRA_LSN_DIR="/var/backups/mysql_lsn"
CFG_HOSTNAME=$(hostname)
CFG_DATE=$(date -I)
CFG_TIMESTAMP=$(date +%s)
CFG_INCREMENTAL=""

OPT_BACKUP_TYPE="${1:-}"
OPT_DRY_RUN="${2:-}"

if [ "${OPT_BACKUP_TYPE}" != "full" ] && [ "${OPT_BACKUP_TYPE}" != "inc" ] && [ "${OPT_BACKUP_TYPE}" != "restore" ]; then
    echo "Usage: $0 {full|inc} [--dry-run]"
    echo "       $0 restore <full-backup> <inc-backup-1> <inc-backup-2> [--dry-run]"
    exit 1
fi

# we backup, full or inc
if [ "${OPT_BACKUP_TYPE}" = "full" ] || [ "${OPT_BACKUP_TYPE}" = "inc" ]; then

    if [ ! -d "${CFG_EXTRA_LSN_DIR}" ]; then
        echo "Creating local LSN directory: ${CFG_EXTRA_LSN_DIR}"
        mkdir -p "${CFG_EXTRA_LSN_DIR}"
    fi

    if [ "${OPT_BACKUP_TYPE}" = "inc" ]; then
        if [ ! -f "${CFG_EXTRA_LSN_DIR}/xtrabackup_checkpoints" ]; then
            echo "No previous full backup found. Please run a full backup first."
            exit 1
        fi
        CFG_INCREMENTAL="--incremental-basedir=${CFG_EXTRA_LSN_DIR}"
    fi

    if [ -n "${OPT_DRY_RUN}" ]; then
        echo "Dry run: xtrabackup --backup ${CFG_INCREMENTAL} --extra-lsndir=${CFG_EXTRA_LSN_DIR} --stream=xbstream --target-dir=${CFG_EXTRA_LSN_DIR} | \
    xbcloud put ${CFG_HOSTNAME}/${CFG_DATE}-${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}"
    else
        xtrabackup --backup ${CFG_INCREMENTAL} --extra-lsndir=${CFG_EXTRA_LSN_DIR} --stream=xbstream --target-dir=${CFG_EXTRA_LSN_DIR} | \
    xbcloud put ${CFG_HOSTNAME}/${CFG_DATE}-${OPT_BACKUP_TYPE}_${CFG_TIMESTAMP}

        if [ $? -ne 0 ]; then
            echo "Backup failed!"
            exit 1
        fi

        echo "Backup completed successfully."
    fi

# we restore
elif [ "${OPT_BACKUP_TYPE}" = "restore" ]; then

    # See https://docs.percona.com/percona-xtrabackup/2.4/xbcloud/xbcloud.html#preparing-an-incremental-backup
    # restore requires:
    #   - a path to a full backup
    #   - 

    echo "Do a restore..."
fi

exit 0
