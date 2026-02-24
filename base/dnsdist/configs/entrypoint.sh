#!/bin/sh
set -e

HEADLESS_SVC="unbound-headless.noc-poc.svc.cluster.local"

# Wait for at least one Unbound pod to be available
echo "Waiting for Unbound pods via ${HEADLESS_SVC}..."
for i in $(seq 1 30); do
    if getent ahostsv4 "${HEADLESS_SVC}" >/dev/null 2>&1; then
        echo "  Unbound pods found."
        break
    fi
    echo "  Waiting... (${i}/30)"
    sleep 2
done

exec dnsdist --supervised --disable-syslog -C /etc/dnsdist/dnsdist.conf
