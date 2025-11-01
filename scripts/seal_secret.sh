#!/bin/bash
# Generate SealedSecret encryptedData entries for given key=value pairs.
# macOS Bash 3.2 compatible (no arrays, no process substitution)

set -eEuo pipefail

# --- Usage check ---
if [ $# -lt 2 ]; then
  echo "Usage: $0 <namespace> key1=value1 [key2=value2 ...]" >&2
  echo "Example: $0 monitoring admin-user=admin admin-password='S3cr3t!'" >&2
  exit 1
fi

NAMESPACE="$1"
shift

# --- Detect sealed-secrets controller ---
CTRL_NS=$(kubectl get pods -A 2>/dev/null | awk '/sealed-secrets/{print $1; exit}')
CTRL_NAME=$(kubectl get deployment -A 2>/dev/null | awk '/sealed-secrets/{print $2; exit}')

if [ -z "$CTRL_NS" ] || [ -z "$CTRL_NAME" ]; then
  echo "Error: sealed-secrets controller not found in cluster." >&2
  exit 1
fi

# --- Temporary working secret file ---
TMP_SECRET=$(mktemp /tmp/tmpsecret.XXXXXX.yaml)
trap 'rm -f "$TMP_SECRET"' EXIT

# Build base secret YAML
cat >"$TMP_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: temp-seal
  namespace: ${NAMESPACE}
type: Opaque
stringData:
EOF

# Append all key=value pairs
while [ $# -gt 0 ]; do
  KEY=$(printf '%s' "$1" | cut -d= -f1)
  VALUE=$(printf '%s' "$1" | cut -d= -f2-)
  echo "  ${KEY}: \"${VALUE}\"" >>"$TMP_SECRET"
  shift
done

# --- Run kubeseal once for all keys ---
SEALED=$(kubeseal \
  --controller-name="${CTRL_NAME}" \
  --controller-namespace="${CTRL_NS}" \
  --format yaml \
  --namespace "${NAMESPACE}" \
  -f "$TMP_SECRET")

echo "# Copy the below lines into your SealedSecret under spec.encryptedData"
echo

# --- Extract encryptedData block cleanly ---
echo "$SEALED" | awk '/encryptedData:/,/template:/ {
  if ($1 != "encryptedData:" && $1 != "template:") print
}' | sed '/^$/d' | sed 's/^/    /'

