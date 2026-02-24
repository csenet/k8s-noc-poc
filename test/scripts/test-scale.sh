#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="noc-poc"
REPLICAS="${1:-3}"
UNBOUND_IP="${UNBOUND_IP:-$(kubectl -n "${NAMESPACE}" get svc unbound -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")}"

if [ -z "${UNBOUND_IP}" ]; then
    echo "ERROR: Could not determine Unbound LoadBalancer IP."
    exit 1
fi

echo "=== Scale Test (Unbound @ ${UNBOUND_IP}, replicas: ${REPLICAS}) ==="

# Scale up
echo "[1/5] Scaling Unbound to ${REPLICAS} replicas..."
kubectl -n "${NAMESPACE}" scale deployment/unbound --replicas="${REPLICAS}"
kubectl -n "${NAMESPACE}" wait --for=condition=available deployment/unbound --timeout=120s
echo "  All ${REPLICAS} replicas ready."

# Show pods
echo ""
echo "[2/5] Pod distribution:"
kubectl -n "${NAMESPACE}" get pods -l app=unbound -o wide

# Flush Redis cache for clean test
echo ""
echo "[3/5] Flushing Redis cache..."
kubectl -n "${NAMESPACE}" exec deploy/redis -- redis-cli flushall

# Send queries and verify load distribution
echo ""
echo "[4/5] Sending DNS queries..."
DOMAINS=(
    google.com github.com example.com example.org amazon.com
    cloudflare.com microsoft.com apple.com wikipedia.org mozilla.org
    reddit.com stackoverflow.com docker.com kubernetes.io golang.org
    python.org nodejs.org rust-lang.org ubuntu.com debian.org
    archlinux.org
)
PASS=0
FAIL=0
for domain in "${DOMAINS[@]}"; do
    if dig @"${UNBOUND_IP}" "${domain}" +short +time=3 > /dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
done
echo "  Queries: ${PASS} succeeded, ${FAIL} failed out of ${#DOMAINS[@]}"

# Check Redis populated
echo ""
echo "[5/5] Redis cache status:"
kubectl -n "${NAMESPACE}" exec deploy/redis -- redis-cli dbsize

# Scale back down
echo ""
echo "Scaling back to 1 replica..."
kubectl -n "${NAMESPACE}" scale deployment/unbound --replicas=1
kubectl -n "${NAMESPACE}" wait --for=condition=available deployment/unbound --timeout=120s

echo ""
echo "=== Scale Test Complete ==="
[ "${FAIL}" -eq 0 ] || exit 1
