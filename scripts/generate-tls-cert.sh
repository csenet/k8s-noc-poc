#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-noc-poc}"
SECRET_NAME="dnsdist-tls"
CERT_DIR=$(mktemp -d)
DAYS=365
CN="dns.noc-poc.local"

trap 'rm -rf "${CERT_DIR}"' EXIT

echo "=== Generating self-signed TLS certificate ==="
echo "  CN: ${CN}"
echo "  Valid: ${DAYS} days"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${CERT_DIR}/tls.key" \
  -out "${CERT_DIR}/tls.crt" \
  -days "${DAYS}" \
  -subj "/CN=${CN}" \
  -addext "subjectAltName=DNS:${CN},DNS:dnsdist.${NAMESPACE}.svc.cluster.local"

echo "=== Creating Kubernetes Secret '${SECRET_NAME}' in namespace '${NAMESPACE}' ==="

# Ensure namespace exists
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

# Delete existing secret if present
kubectl -n "${NAMESPACE}" delete secret "${SECRET_NAME}" --ignore-not-found

kubectl -n "${NAMESPACE}" create secret tls "${SECRET_NAME}" \
  --cert="${CERT_DIR}/tls.crt" \
  --key="${CERT_DIR}/tls.key"

echo "=== Done: Secret '${SECRET_NAME}' created ==="
