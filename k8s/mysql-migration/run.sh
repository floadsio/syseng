#/bin/sh

mysqldump --get-server-public-key -h 10.43.184.54 -uroot -pu73rFs9DHthZQ2jBBXx9gHfEhJZQUz6q --single-transaction --quick --add-drop-database  --databases api_svc asic_svc deltaconx emir_refit_svc mas_svc mmsr_connector_dk mmsr_svc recon_svc report_designer_svc unavista_emir_svc |/tmp/nc 172.19.0.171 55555


# https://gist.github.com/vanjos/6053606

#################
# cat mysql-recv.sh
# #!/bin/sh
#
# mysql -uroot -e "drop database deltaconx;"
# mysql -uroot -e "create database deltaconx;"
#
# # nc -l 55555 | gzip -d -c | mysql deltaconx -uroot
# nc -l 55555 | mysql deltaconx -uroot
#################

# Run this in tmux on controller-01.floads:

# kubectl exec -ti -ndeltaconx-dev deltaconx-dev-mysql-68866f4f5-26ctn -- \
#  sh -c "/usr/bin/curl -o /tmp/nc https://raw.githubusercontent.com/andrew-d/static-binaries/master/binaries/linux/x86_64/ncat ; chmod +x /tmp/nc"

kubectl exec -ti -ndeltaconx-dev deltaconx-dev-mysql-68866f4f5-26ctn -- \
  sh -c "mysqldump -h 10.43.184.54 -uroot -pu73rFs9DHthZQ2jBBXx9gHfEhJZQUz6q --single-transaction --quick --all-databases --add-drop-database |/tmp/nc 172.19.0.171 55555"
  # sh -c "mysqldump -h 10.43.184.54 -uroot -pu73rFs9DHthZQ2jBBXx9gHfEhJZQUz6q --single-transaction --quick --no-tablespaces deltaconx |/tmp/nc 172.19.0.171 55555"
  # sh -c "mysqldump -udeltaconx -pDBpjj3qQVfPTV82kJVidPjLiRwc3WePM --single-transaction --quick --no-tablespaces deltaconx |/tmp/nc 172.19.0.171 55555"
  # sh -c "mysqldump -udeltaconx -pDBpjj3qQVfPTV82kJVidPjLiRwc3WePM deltaconx |gzip |/tmp/nc 172.19.0.171 55555"

  mysqldump -h 10.43.184.54 -uroot -pu73rFs9DHthZQ2jBBXx9gHfEhJZQUz6q --single-transaction --quick --add-drop-database  --databases api_svc asic_svc deltaconx emir_refit_svc mas_svc mmsr_connector_dk mmsr_svc recon_svc report_designer_svc unavista_emir_svc |/tmp/nc 172.19.0.171 55555
