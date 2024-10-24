# make CLUSTER=my-k8s-cluster apply

# Prometheus query:
# ( sum without(instance, node) (topk(1, (kubelet_volume_stats_capacity_bytes{cluster="", job="kubelet", metrics_path="/metrics", namespace="debug", persistentvolumeclaim="debug-pod-01-pvc"}))) - sum without(instance, node) (topk(1, (kubelet_volume_stats_available_bytes{cluster="", job="kubelet", metrics_path="/metrics", namespace="debug", persistentvolumeclaim="debug-pod-01-pvc"}))) )

apply:
	kubectx $(CLUSTER)
	kubectl apply -f debug-pod.yaml

destroy:
	kubectx $(CLUSTER)
	kubectl delete -f debug-pod.yaml

shell:
	kubectl exec -ndebug debug-pod-01 -it -- bash

fillup:
	kubectl exec -ndebug debug-pod-01 -it -- dd if=/dev/zero of=/data/empty_file bs=1M count=930

cleanup:
	kubectl exec -ti -ndebug pod/debug-pod-01 -- rm -v /data/empty_file

df:
	kubectl exec -ti -ndebug pod/debug-pod-01 -- df -h /data

ssh:
	# Example: make TARGET=freebsd@172.19.0.171 ssh
	kubectl exec -ti -ndebug pod/debug-pod-01 -- ssh -tt $(TARGET)
