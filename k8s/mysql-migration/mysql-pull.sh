#!/bin/sh

#
# As far as we are using NodePort we can use any k8s worker node as mysql host
#

# Function to display usage information
usage() {
    echo "Usage: $0 <mysql_host> <mysql_password> <mysql_port> [options]"
    echo ""
    echo "Options:"
    echo "  --purge      Purge and reinstall Percona Server and clean up /var/lib/mysql."
    echo "  --users      Backup and restore MySQL users."
    echo "  --dump       Perform backup and restore operations using mydumper and myloader."
    echo ""
    exit 1
}

# Check for correct number of arguments
if [ $# -lt 3 ]; then
    usage
fi

MYSQL_HOST=$1
MYSQL_PORT=$2
MYSQL_PASSWORD=$3
PURGE=0
USERS=0
DUMP=0
CFG_DUMPDIR="/tmp/dbdump"

# Parse optional parameters
for arg in "$@"; do
    case $arg in
        --purge)
            PURGE=1
            shift
            ;;
        --users)
            USERS=1
            shift
            ;;
        --dump)
            DUMP=1
            shift
            ;;
    esac
done

# Purge and reinstall Percona Server
if [ $PURGE -eq 1 ]; then
    echo "Purging Percona Server and cleaning up /var/lib/mysql..."

    systemctl stop mysql

    DEBIAN_FRONTEND=noninteractive apt-get purge -y percona-server-server
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
    DEBIAN_FRONTEND=noninteractive apt-get clean

    rm -rf /var/lib/mysql

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y percona-server-server

    echo "Percona Server and /var/lib/mysql have been purged and reinstalled."

    mysql -e "CREATE FUNCTION fnv1a_64 RETURNS INTEGER SONAME 'libfnv1a_udf.so'"
    mysql -e "CREATE FUNCTION fnv_64 RETURNS INTEGER SONAME 'libfnv_udf.so'"
    mysql -e "CREATE FUNCTION murmur_hash RETURNS INTEGER SONAME 'libmurmur_udf.so'"
fi

# Perform normal operation with mydumper if --dump option is given
if [ $DUMP -eq 1 ]; then
    echo "Starting backup with mydumper..."

    mydumper \
        --threads 4 \
        --host "$MYSQL_HOST" \
        --port "$MYSQL_PORT" \
        --user root \
        --password $MYSQL_PASSWORD \
        --verbose 3 \
        --use-savepoints \
        --outputdir "$CFG_DUMPDIR" \
        --trx-consistency-only \
        --compress ZSTD \
        --regex '^(?!(mysql|test|sys|performance_schema))'
        # --clear \
        # --logfile dump/backup-all.log \
        # --no-locks \

    echo "Backup completed."

    # Import the dump with myloader
    echo "Starting import with myloader..."

    mysql -e "SET FOREIGN_KEY_CHECKS = 0;"

    myloader \
        --threads 4 \
        --host localhost \
        --user root \
        --directory "$CFG_DUMPDIR" \
        --verbose 3
        # --logfile dump/restore-all.log \
        # --overwrite-tables \

    mysql -e "SET FOREIGN_KEY_CHECKS = 1;"

    echo "Import completed."
fi

# If the --users option is provided, use mysqlpump to backup users
if [ $USERS -eq 1 ]; then
    echo "Backing up users with mysqlpump..."

    mysqlpump \
        --get-server-public-key \
        -h "$MYSQL_HOST" \
        -P "$MYSQL_PORT" \
        -uroot \
        -p$MYSQL_PASSWORD \
        --exclude-databases=% \
        --users | mysql -h localhost -uroot

    echo "Users have been backed up and restored."

    # List MySQL users and flush privileges
    echo "Listing MySQL users..."
    mysql --get-server-public-key -h localhost -u root -e "SELECT User, Host FROM mysql.user;"

    echo "Flushing privileges..."
    mysql --get-server-public-key -h localhost -u root -e "FLUSH PRIVILEGES;"
fi

# Print File and Position from metadata
echo "Printing File and Position values from metadata..."

if [ -f "$CFG_DUMPDIR/metadata" ]; then
    grep "File" "$CFG_DUMPDIR/metadata" || echo "File entry not found in metadata"
    grep "Position" "$CFG_DUMPDIR/metadata" || echo "Position entry not found in metadata"
else
    echo "Metadata file not found in $CFG_DUMPDIR"
fi

