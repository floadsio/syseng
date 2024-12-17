#!/bin/sh

PURGE=false

# ip addr add 10.43.184.54/24 dev ens4

if [ "$1" = "purge" ]; then
    PURGE=true
fi

if [ "$PURGE" = true ]; then
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

echo "Waiting to receive database dump..."
nc -l -p 55555 |mysql -uroot
echo "Database restore complete."

echo "Waiting to receive users dump..."
nc -l -p 55555 |mysql -uroot
echo "Users restore complete."

mysql -e "SELECT User, Host FROM mysql.user;"
mysql -e "FLUSH PRIVILEGES;"

