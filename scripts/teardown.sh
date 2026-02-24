#!/usr/bin/env bash
set -euo pipefail

OVERLAY="${1:-poc}"
NAMESPACE="noc-poc"

echo "=== Tearing down K8s NOC PoC (overlay: ${OVERLAY}) ==="

# Delete test pods first
echo "[1/5] Removing test pods..."
kubectl delete -f test/manifests/ --ignore-not-found 2>/dev/null || true

# Delete main resources
echo "[2/5] Removing main resources..."
kustomize build "overlays/${OVERLAY}" --enable-helm | kubectl delete -f - --ignore-not-found

# Delete monitoring stack
echo "[3/5] Removing monitoring stack..."
kustomize build base/monitoring --enable-helm | kubectl delete -f - --ignore-not-found

# Delete MetalLB config then controller
echo "[4/5] Removing MetalLB..."
kubectl delete -k base/metallb/config --ignore-not-found
kustomize build base/metallb --enable-helm | kubectl delete -f - --ignore-not-found

# Optionally delete namespaces
echo "[5/5] Removing namespaces..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found
kubectl delete namespace monitoring --ignore-not-found

echo ""
echo "=== Teardown Complete ==="
