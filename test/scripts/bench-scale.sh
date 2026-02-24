#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="noc-poc"
DNS_IP="${DNS_IP:-${UNBOUND_IP:-$(kubectl -n "${NAMESPACE}" get svc dnsdist -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")}}"
QUERYFILE="${QUERYFILE:-test/queryfile.txt}"
DURATION="${DURATION:-30}"
CLIENTS="${CLIENTS:-10}"
THREADS="${THREADS:-10}"
REPLICA_COUNTS="${*:-1 2 3}"

if [ -z "${DNS_IP}" ]; then
    echo "ERROR: Could not determine dnsdist LoadBalancer IP."
    exit 1
fi

if ! command -v dnsperf &>/dev/null; then
    echo "ERROR: dnsperf not found. Install with: brew install dnsperf"
    exit 1
fi

echo "============================================"
echo " DNS Scale Benchmark (via dnsdist)"
echo "============================================"
echo "  Server:    ${DNS_IP}:53"
echo "  Query file: ${QUERYFILE}"
echo "  Duration:  ${DURATION}s per run"
echo "  Clients:   ${CLIENTS}"
echo "  Threads:   ${THREADS}"
echo "  Replicas:  ${REPLICA_COUNTS}"
echo "============================================"
echo ""

declare -a RESULTS=()

for REPLICAS in ${REPLICA_COUNTS}; do
    echo ">>> Scaling Unbound to ${REPLICAS} replica(s)..."
    kubectl -n "${NAMESPACE}" scale deployment/unbound --replicas="${REPLICAS}"
    kubectl -n "${NAMESPACE}" rollout status deployment/unbound --timeout=120s
    echo ">>> Waiting for dnsdist to sync backends..."
    sleep 12
    echo ""

    # Show pod distribution
    kubectl -n "${NAMESPACE}" get pods -l app=unbound -o wide
    echo ""

    # Flush Redis cache so each run starts clean
    echo ">>> Flushing Redis cache..."
    kubectl -n "${NAMESPACE}" exec deploy/redis -- redis-cli flushall
    echo ""

    # Warm up (short run to populate cache)
    echo ">>> Warming up (5s)..."
    dnsperf -s "${DNS_IP}" -d "${QUERYFILE}" -c "${CLIENTS}" -T "${THREADS}" -l 5 > /dev/null 2>&1 || true
    echo ""

    # Actual benchmark
    echo ">>> Running benchmark (${DURATION}s) with ${REPLICAS} replica(s)..."
    OUTPUT=$(dnsperf -s "${DNS_IP}" -d "${QUERYFILE}" -c "${CLIENTS}" -T "${THREADS}" -l "${DURATION}" 2>&1)

    # Extract metrics
    QPS=$(echo "${OUTPUT}" | grep "Queries per second" | awk '{print $NF}')
    AVG_LATENCY=$(echo "${OUTPUT}" | grep "Average Latency" | awk '{print $4}')
    MIN_LATENCY=$(echo "${OUTPUT}" | grep "Average Latency" | sed 's/.*min \([^,]*\),.*/\1/')
    MAX_LATENCY=$(echo "${OUTPUT}" | grep "Average Latency" | sed 's/.*max \([^)]*\)).*/\1/')
    LOST=$(echo "${OUTPUT}" | grep "Queries lost" | awk '{print $3}')
    TOTAL=$(echo "${OUTPUT}" | grep "Queries sent" | awk '{print $3}')

    RESULTS+=("${REPLICAS}|${QPS}|${AVG_LATENCY}|${MIN_LATENCY}|${MAX_LATENCY}|${LOST}|${TOTAL}")

    echo "${OUTPUT}" | tail -15
    echo ""
    echo "--------------------------------------------"
    echo ""
done

# Scale back to 1
echo ">>> Scaling back to 1 replica..."
kubectl -n "${NAMESPACE}" scale deployment/unbound --replicas=1
kubectl -n "${NAMESPACE}" rollout status deployment/unbound --timeout=120s

# Summary table
echo ""
echo "============================================"
echo " RESULTS SUMMARY"
echo "============================================"
printf "%-10s %-15s %-15s %-12s %-12s %-10s\n" "Replicas" "QPS" "Avg Lat(s)" "Min Lat(s)" "Max Lat(s)" "Lost"
printf "%-10s %-15s %-15s %-12s %-12s %-10s\n" "--------" "----------" "----------" "---------" "---------" "------"
for entry in "${RESULTS[@]}"; do
    IFS='|' read -r rep qps avg mn mx lost total <<< "${entry}"
    printf "%-10s %-15s %-15s %-12s %-12s %-10s\n" "${rep}" "${qps}" "${avg}" "${mn}" "${mx}" "${lost}/${total}"
done
echo "============================================"
