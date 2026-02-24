#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="noc-poc"
UNBOUND_IP="${UNBOUND_IP:-$(kubectl -n "${NAMESPACE}" get svc unbound -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")}"

if [ -z "${UNBOUND_IP}" ]; then
    echo "ERROR: Could not determine Unbound LoadBalancer IP."
    echo "Set UNBOUND_IP env var or ensure the service has an external IP."
    exit 1
fi

echo "=== DNS Tests (Unbound @ ${UNBOUND_IP}) ==="
PASS=0
FAIL=0

run_test() {
    local name="$1"
    local cmd="$2"
    local expect="$3"

    echo -n "  [TEST] ${name}... "
    if output=$(eval "${cmd}" 2>&1); then
        if echo "${output}" | grep -qi "${expect}"; then
            echo "PASS"
            PASS=$((PASS + 1))
            return
        fi
    fi
    echo "FAIL"
    echo "    Command: ${cmd}"
    echo "    Expected: ${expect}"
    echo "    Output: ${output:-<empty>}"
    FAIL=$((FAIL + 1))
}

# Test 1: Recursive resolution
run_test "Recursive resolution (google.com)" \
    "dig @${UNBOUND_IP} google.com +short +time=5" \
    "[0-9]"

# Test 2: NXDOMAIN
run_test "NXDOMAIN (nonexistent.invalid)" \
    "dig @${UNBOUND_IP} nonexistent.invalid +time=5" \
    "NXDOMAIN"

# Test 3: TCP query
run_test "TCP query (google.com)" \
    "dig @${UNBOUND_IP} +tcp google.com +short +time=5" \
    "[0-9]"

# Test 4: Redis cache check (run a query first to ensure cache is populated)
dig @${UNBOUND_IP} example.com +short +time=5 > /dev/null 2>&1
sleep 1
run_test "Redis cache populated" \
    "kubectl -n ${NAMESPACE} exec deploy/redis -- redis-cli dbsize" \
    "[1-9]"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ] || exit 1
