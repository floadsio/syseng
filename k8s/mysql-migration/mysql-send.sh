#!/bin/sh

# Example:
# /tmp/mysql-send.sh dcx-test-flow-alp1-k8s deltaconx-dev deltaconx-dev-mysql-68866f4f5-26ctn 10.43.184.54 u73rFs9DHthZQ2jBBXx9gHfEhJZQUz6q 172.19.0.171 "api_svc asic_svc deltaconx emir_refit_svc mas_svc mmsr_connector_dk mmsr_svc recon_svc report_designer_svc unavista_emir_svc"

if [ "$#" -ne 7 ]; then
    echo "Usage: $0 <kube_context> <namespace> <pod_name> <mysql_host> <mysql_password> <nc_destination_ip> <databases>"
    exit 1
fi

KUBE_CONTEXT=$1
NAMESPACE=$2
POD_NAME=$3
MYSQL_HOST=$4
MYSQL_PASSWORD=$5
NC_DEST_IP=$6
DATABASES=$7

kubectl --context "$KUBE_CONTEXT" exec -ti -n"$NAMESPACE" "$POD_NAME" -- \
  sh -c "command -v /tmp/nc || curl -o /tmp/nc https://raw.githubusercontent.com/andrew-d/static-binaries/master/binaries/linux/x86_64/ncat && chmod +x /tmp/nc"

kubectl --context "$KUBE_CONTEXT" exec -ti -n"$NAMESPACE" "$POD_NAME" -- \
  sh -c "mysqldump --get-server-public-key -h $MYSQL_HOST -uroot -p$MYSQL_PASSWORD --single-transaction --quick --add-drop-database --databases $DATABASES | /tmp/nc $NC_DEST_IP 55555"
  # sh -c "mysqlpump --get-server-public-key -h $MYSQL_HOST -uroot -p$MYSQL_PASSWORD --default-parallelism=4 --all-databases | /tmp/nc $NC_DEST_IP 55555"
  # sh -c "mysqlpump --get-server-public-key -h $MYSQL_HOST -uroot -p$MYSQL_PASSWORD --default-parallelism=4 --add-drop-database --add-drop-table --all-databases --users | /tmp/nc $NC_DEST_IP 55555"

kubectl --context "$KUBE_CONTEXT" exec -ti -n"$NAMESPACE" "$POD_NAME" -- \
  sh -c "mysqlpump --get-server-public-key -h $MYSQL_HOST -uroot -p$MYSQL_PASSWORD --exclude-databases=% --users | /tmp/nc $NC_DEST_IP 55555"
