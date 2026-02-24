#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="noc-poc"

echo "=== DHCP Tests (Kea DHCP) ==="
PASS=0
FAIL=0

run_test() {
    local name="$1"
    local cmd="$2"
    local expect="$3"

    echo -n "  [TEST] ${name}... "
    if output=$(eval "${cmd}" 2>&1); then
        if echo "${output}" | grep -qiE "${expect}"; then
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

# Test 1: Kea pod is running
run_test "Kea DHCP pod running" \
    "kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=kea-dhcp -o jsonpath='{.items[0].status.phase}'" \
    "Running"

# Test 2: Kea DHCP service exists
run_test "Kea DHCP service exists" \
    "kubectl -n ${NAMESPACE} get svc kea-dhcp -o jsonpath='{.spec.type}'" \
    "LoadBalancer"

# Test 3: Kea config loaded (check logs from statefulset)
run_test "Kea DHCP config loaded" \
    "kubectl -n ${NAMESPACE} logs statefulset/kea-dhcp -c kea-dhcp --tail=50" \
    "DHCP4_CONFIG_COMPLETE|DHCP4_STARTED|DHCP4_STARTING"

# Test 4: DHCP test from test pod (if exists)
if kubectl -n "${NAMESPACE}" get pod dhcp-test-pod &>/dev/null; then
    run_test "DHCP discover from test pod" \
        "kubectl -n ${NAMESPACE} exec dhcp-test-pod -- nmap --script broadcast-dhcp-discover -e eth0 2>/dev/null" \
        "DHCPOFFER"
else
    echo "  [SKIP] DHCP discover test - dhcp-test-pod not found (run: make test-pods)"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ] || exit 1
