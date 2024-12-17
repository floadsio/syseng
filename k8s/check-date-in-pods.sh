#!/bin/bash

# Get a list of all pod names in the specified namespace or all namespaces
if [ -n "$1" ]; then
  namespace="$1"
  pod_names=$(kubectl get pods -n "$namespace" -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name" --no-headers | awk '{print $1 ":" $2}')
else
  pod_names=$(kubectl get pods --all-namespaces -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name" --no-headers | awk '{print $1 ":" $2}')
fi

# Loop through each pod and execute "date -R" using kubectl exec
for pod_info in $pod_names; do
  namespace=$(echo "$pod_info" | cut -d ":" -f 1)
  pod_name=$(echo "$pod_info" | cut -d ":" -f 2)

  echo "Running 'date -R' on pod $pod_name in namespace $namespace:"
  if kubectl exec -n "$namespace" "$pod_name" -- date -R 2>/dev/null; then
    echo "----------------------------------------"
  else
    echo "Error executing 'date -R' on pod $pod_name in namespace $namespace"
    echo "----------------------------------------"
  fi
done
