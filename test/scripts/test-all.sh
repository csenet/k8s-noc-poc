#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "  K8s NOC PoC - Full Test Suite"
echo "========================================="
echo ""

EXIT_CODE=0

echo "--- DNS Tests ---"
if "${SCRIPT_DIR}/test-dns.sh"; then
    echo ""
else
    EXIT_CODE=1
    echo ""
fi

echo "--- DHCP Tests ---"
if "${SCRIPT_DIR}/test-dhcp.sh"; then
    echo ""
else
    EXIT_CODE=1
    echo ""
fi

echo "========================================="
if [ "${EXIT_CODE}" -eq 0 ]; then
    echo "  All tests passed!"
else
    echo "  Some tests failed."
fi
echo "========================================="

exit "${EXIT_CODE}"
