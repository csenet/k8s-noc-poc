#!/usr/bin/env bash
set -euo pipefail

OVERLAY="${1:-poc}"
NAMESPACE="noc-poc"

echo "=== Deploying K8s NOC PoC (overlay: ${OVERLAY}) ==="

# Step 1: MetalLB namespace + Helm chart (CRDs + controller + speaker)
echo "[1/8] Installing MetalLB (Helm)..."
kubectl apply -f base/metallb/namespace.yaml
kustomize build base/metallb --enable-helm | kubectl apply --server-side --force-conflicts -f -
echo "  Waiting for MetalLB controller..."
kubectl -n metallb-system wait --for=condition=available deployment/metallb-controller --timeout=120s
echo "  Waiting for MetalLB speaker..."
kubectl -n metallb-system wait --for=condition=ready pod -l app.kubernetes.io/component=speaker --timeout=120s

# Step 2: MetalLB IPAddressPool + L2Advertisement (CRDs must exist first)
echo "[2/8] Applying MetalLB address pool config..."
kubectl apply -k base/metallb/config

# Step 3: TLS certificate for dnsdist DoT
echo "[3/9] Generating TLS certificate for dnsdist DoT..."
"$(dirname "$0")/generate-tls-cert.sh"

# Step 4: Main resources
echo "[4/9] Building and applying manifests..."
kustomize build "overlays/${OVERLAY}" --enable-helm | kubectl apply -f -

# Wait for Redis + Unbound + dnsdist
echo "[5/9] Waiting for Redis, Unbound & dnsdist..."
kubectl -n "${NAMESPACE}" wait --for=condition=available deployment/redis --timeout=120s
kubectl -n "${NAMESPACE}" wait --for=condition=available deployment/unbound --timeout=120s
kubectl -n "${NAMESPACE}" wait --for=condition=available deployment/dnsdist --timeout=120s

# Step 6: Monitoring stack — two-phase apply (CRDs must be Established before CRs)
echo "[6/9] Deploying monitoring stack (phase 1: CRDs)..."
kustomize build base/monitoring --enable-helm | kubectl apply --server-side --force-conflicts -f - 2>&1 | grep -v 'ensure CRDs' || true
echo "  Waiting for CRDs to be established..."
kubectl wait --for=condition=Established crd/prometheusrules.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=Established crd/prometheuses.monitoring.coreos.com --timeout=60s

echo "[7/9] Deploying monitoring stack (phase 2: full stack)..."
kustomize build base/monitoring --enable-helm | kubectl apply --server-side --force-conflicts -f -

# Wait for monitoring components
echo "[8/9] Waiting for Prometheus Operator & Grafana..."
kubectl -n monitoring wait --for=condition=available deployment/kube-prometheus-stack-operator --timeout=180s
kubectl -n monitoring wait --for=condition=available deployment/kube-prometheus-stack-grafana --timeout=180s

# Step 9: Show dnsdist LB IP + Grafana LB IP
echo "[9/9] Fetching LoadBalancer IPs..."
DNS_IP=""
for i in $(seq 1 30); do
    DNS_IP=$(kubectl -n "${NAMESPACE}" get svc dnsdist -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "${DNS_IP}" ]; then
        break
    fi
    echo "  Waiting for dnsdist LoadBalancer IP... (${i}/30)"
    sleep 2
done

GRAFANA_IP=""
for i in $(seq 1 30); do
    GRAFANA_IP=$(kubectl -n monitoring get svc kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "${GRAFANA_IP}" ]; then
        break
    fi
    echo "  Waiting for Grafana LoadBalancer IP... (${i}/30)"
    sleep 2
done

echo ""
echo "=== Deployment Complete ==="
if [ -n "${DNS_IP}" ]; then
    echo "DNS (dnsdist) IP: ${DNS_IP}"
    echo "  NOTE: Update base/kea-dhcp/values.yaml domain-name-servers with: ${DNS_IP}"
else
    echo "DNS (dnsdist) IP: (pending) — run 'make get-dns-ip' to check later"
fi

if [ -n "${GRAFANA_IP}" ]; then
    echo "Grafana URL:    http://${GRAFANA_IP} (admin/admin)"
else
    echo "Grafana URL:    (pending) — run 'make grafana-forward' for port-forward access"
fi

echo ""
echo "Status:"
kubectl -n "${NAMESPACE}" get all
echo ""
echo "Monitoring:"
kubectl -n monitoring get pods
