#!/usr/bin/env bash

read -p "This action is irreversible. Do you want to continue? (Y/N): " answer
if [ "$answer" == "Y" ] || [ "$answer" == "y" ]; then
  echo "Continuing with the action..."
else
  echo "Action aborted."
  exit 1
fi

# List
kubectl get pods -nvelero
kubectl -n velero get datauploads -nvelero
kubectl get crd | grep velero
kubectl get volumesnapshots.snapshot.storage.k8s.io -A |grep velero

# Delete
kubectl delete all --all -nvelero
kubectl get crd | grep velero | awk '{print $1}' | xargs kubectl delete crd
kubectl delete volumesnapshot --all -nvelero
mc -C ~/.mc/floads rb --force dcx@os.zrh1.flow.swiss/dcx-test-velero/

# Create
mc -C ~/.mc/floads mb dcx@os.zrh1.flow.swiss/dcx-test-velero
mc -C ~/.mc/floads mb dcx@os.zrh1.flow.swiss/dcx-test-velero/dcx-test-flow-alp1-k8s

# List
kubectl get pods -nvelero
kubectl -n velero get datauploads -nvelero
kubectl get crd | grep velero
kubectl get volumesnapshots.snapshot.storage.k8s.io -A |grep velero

# kubectl get datauploads | grep velero | awk '{print $1}' | xargs kubectl delete dataupload\n
# kubectl get datauploads -nvelero | awk '{print $1}' | xargs kubectl delete dataupload\n
# kubectl get datauploads -nvelero | awk '{print $1}' | xargs kubectl delete -nvelero dataupload\n
# kubectl delete -nvelero dataupload dcx-stage-velero-monitoring-20231013040031-qznw5

# sh /tmp/patch.sh
# kubectl get crd | grep velero
# kubectl -n velero get datauploads -nvelero
# cat /tmp/patch.sh
# mc -C ~/.mc/floads mb dcx@os.zrh1.flow.swiss/dcx-test-velero
# mc -C ~/.mc/floads mb dcx@os.zrh1.flow.swiss/dcx-test-velero/dcx-test-flow-alp1-k8s

# cat /tmp/patch.sh
# resources=("dcx-stage-velero-monitoring-20231013040031-qznw5" "dcx-stage-velero-monitoring-20231013080031-x85fh" "dcx-stage-velero-monitoring-20231013000031-crgn5" "dcx-stage-velero-monitoring-20231012164340-cvzwn" "dcx-stage-velero-monitoring-20231013020031-9j6sk" "dcx-stage-velero-monitoring-20231012200031-tw4bb" "dcx-stage-velero-monitoring-20231012220031-wr4rt" "dcx-stage-velero-monitoring-20231012180031-g22x2" "dcx-stage-velero-monitoring-20231013060031-bnklr" "dcx-stage-velero-monitoring-20231013101819-b99wr" "dcx-stage-velero-deltaconx-dev-20231013103233-9tjhm" "dcx-stage-velero-monitoring-20231013120032-j2k6n" "dcx-stage-velero-monitoring-20231013140032-xndlv" "dcx-stage-velero-monitoring-20231013160032-bd9nf")

# for resource in "${resources[@]}"; do
#  kubectl -nvelero patch dataupload "$resource" -p '{"metadata":{"finalizers":[]}}' --type=merge
# done
