OVERLAY ?= poc
NAMESPACE := noc-poc
KUSTOMIZE_FLAGS := --enable-helm

.PHONY: build deploy clean test test-dns test-dhcp test-scale bench-scale status \
	metallb metallb-config metallb-clean tls-cert \
	monitoring monitoring-status monitoring-clean grafana-forward prometheus-forward \
	get-dns-ip get-unbound-ip

## Build kustomize output (dry-run)
build:
	kustomize build overlays/$(OVERLAY) $(KUSTOMIZE_FLAGS)

## Step 1: Install MetalLB controller + speaker (Helm)
metallb:
	kubectl apply -f base/metallb/namespace.yaml
	kustomize build base/metallb $(KUSTOMIZE_FLAGS) | kubectl apply --server-side --force-conflicts -f -
	@echo "Waiting for MetalLB controller..."
	kubectl -n metallb-system wait --for=condition=available deployment/metallb-controller --timeout=120s
	@echo "Waiting for MetalLB speaker..."
	kubectl -n metallb-system wait --for=condition=ready pod -l app.kubernetes.io/component=speaker --timeout=120s

## Step 2: Apply MetalLB IPAddressPool + L2Advertisement (requires CRDs from step 1)
metallb-config:
	kubectl apply -k overlays/$(OVERLAY)/metallb-config

## Step 3: Deploy monitoring stack (kube-prometheus-stack)
## Two-phase apply: CRDs first, then full stack (CRDs must be Established before CRs can be created)
monitoring:
	@echo "Phase 1: Applying CRDs..."
	kustomize build base/monitoring $(KUSTOMIZE_FLAGS) | kubectl apply --server-side --force-conflicts -f - 2>&1 | grep -v 'ensure CRDs' || true
	@echo "Waiting for CRDs to be established..."
	kubectl wait --for=condition=Established crd/prometheusrules.monitoring.coreos.com --timeout=60s
	kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=60s
	kubectl wait --for=condition=Established crd/prometheuses.monitoring.coreos.com --timeout=60s
	@echo "Phase 2: Applying full stack..."
	kustomize build base/monitoring $(KUSTOMIZE_FLAGS) | kubectl apply --server-side --force-conflicts -f -
	@echo "Waiting for Prometheus Operator..."
	kubectl -n monitoring wait --for=condition=available deployment/kube-prometheus-stack-operator --timeout=180s
	@echo "Waiting for Grafana..."
	kubectl -n monitoring wait --for=condition=available deployment/kube-prometheus-stack-grafana --timeout=180s

## Generate self-signed TLS certificate for dnsdist DoT
tls-cert:
	./scripts/generate-tls-cert.sh

## Deploy to cluster (full)
deploy: metallb metallb-config tls-cert
	kustomize build overlays/$(OVERLAY) $(KUSTOMIZE_FLAGS) | kubectl apply -f -
	@echo "Waiting for deployments to be ready..."
	kubectl -n $(NAMESPACE) wait --for=condition=available deployment/redis --timeout=120s
	kubectl -n $(NAMESPACE) wait --for=condition=available deployment/unbound --timeout=120s
	kubectl -n $(NAMESPACE) wait --for=condition=available deployment/dnsdist --timeout=120s
	$(MAKE) monitoring

## Get DNS (dnsdist) LoadBalancer IP
get-dns-ip:
	@kubectl -n $(NAMESPACE) get svc dnsdist -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

## Alias for backward compatibility
get-unbound-ip: get-dns-ip

## Show status of all resources
status:
	kubectl -n $(NAMESPACE) get all
	@echo ""
	@echo "=== Monitoring ==="
	kubectl -n monitoring get pods

## Show monitoring stack status
monitoring-status:
	kubectl -n monitoring get all

## Run DNS tests
test-dns:
	./test/scripts/test-dns.sh

## Run DHCP tests
test-dhcp:
	./test/scripts/test-dhcp.sh

## Run all tests
test:
	./test/scripts/test-all.sh

## Run scale test (default 3 replicas)
REPLICAS ?= 3
test-scale:
	./test/scripts/test-scale.sh $(REPLICAS)

## Run dnsperf benchmark across replica counts (default: 1 2 3)
bench-scale:
	./test/scripts/bench-scale.sh $(REPLICAS_LIST)

## Apply test pods
test-pods:
	kubectl apply -f test/manifests/

## Delete test pods
test-pods-clean:
	kubectl delete -f test/manifests/ --ignore-not-found

## Port-forward Grafana to localhost:3000
grafana-forward:
	@echo "Grafana: http://localhost:3000 (admin/admin)"
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

## Port-forward Prometheus to localhost:9090
prometheus-forward:
	@echo "Prometheus: http://localhost:9090"
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

## Remove MetalLB completely
metallb-clean:
	kubectl delete -k overlays/$(OVERLAY)/metallb-config --ignore-not-found
	kustomize build base/metallb $(KUSTOMIZE_FLAGS) | kubectl delete -f - --ignore-not-found

## Remove monitoring stack
monitoring-clean:
	kustomize build base/monitoring $(KUSTOMIZE_FLAGS) | kubectl delete -f - --ignore-not-found

## Teardown everything
clean:
	kustomize build overlays/$(OVERLAY) $(KUSTOMIZE_FLAGS) | kubectl delete -f - --ignore-not-found
	$(MAKE) monitoring-clean
	$(MAKE) metallb-clean
