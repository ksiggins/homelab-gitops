#!/bin/bash
# macOS-compatible (Bash 3.2) Compose-to-Kubernetes renderer using YAML spec file.
#
# Usage:
#   ./render_compose_file.sh <path-to-spec-file>
#
# Example spec file:
#   name: uptime-kuma
#   repo: https://github.com/louislam/uptime-kuma
#   composeFile: compose.yaml
#   namespace: uptime-kuma
#   version: 2.0.2
#
# Behavior:
#   - Downloads the specified compose file from GitHub (refs/tags/<version>/compose.yaml)
#   - Runs 'kompose convert' to generate Kubernetes manifests.
#   - Adds namespace and standard Helm-style labels to all resources.
#   - Writes the combined manifest to <name>.yaml in the same folder as the spec file.

set -eEuo pipefail

print_example() {
  echo "Example spec file format:"
  echo "  name: uptime-kuma"
  echo "  repo: https://github.com/louislam/uptime-kuma"
  echo "  composeFile: compose.yaml"
  echo "  namespace: uptime-kuma"
  echo "  version: 2.0.2"
}

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-spec-file>" >&2
  echo ""
  print_example
  exit 1
fi

DEF_FILE="$1"
if [ ! -f "$DEF_FILE" ]; then
  echo "Error: File '$DEF_FILE' not found." >&2
  echo ""
  print_example
  exit 1
fi

SPEC_DIR="$(cd "$(dirname "$DEF_FILE")" && pwd)"

# --- Basic key:value parser (simple YAML subset) ---
parse_yaml_value() {
  local key="$1"
  awk -v k="$key" '
    $1 == k ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "$DEF_FILE" | tr -d '"' | tr -d "'"
}

# --- Extract fields ---
APP_NAME="$(parse_yaml_value name)"
REPO_URL="$(parse_yaml_value repo)"
COMPOSE_FILE_NAME="$(parse_yaml_value composeFile)"
NAMESPACE="$(parse_yaml_value namespace)"
VERSION="$(parse_yaml_value version)"

# --- Validate required fields ---
if [ -z "$APP_NAME" ] || [ -z "$REPO_URL" ] || [ -z "$COMPOSE_FILE_NAME" ] || [ -z "$VERSION" ]; then
  echo "Error: 'name', 'repo', 'composeFile', and 'version' are required fields." >&2
  echo ""
  print_example
  exit 1
fi

NAMESPACE="${NAMESPACE:-default}"
OUT_FILE="$SPEC_DIR/${APP_NAME}.yaml"
TMP_DIR="$(mktemp -d)"
TMP_COMPOSE="$TMP_DIR/${APP_NAME}-compose.yaml"
TMP_RENDERED="$TMP_DIR/${APP_NAME}-rendered.yaml"

# --- Download compose file ---
COMPOSE_URL="${REPO_URL%/}/raw/refs/tags/${VERSION}/${COMPOSE_FILE_NAME}"
echo "Fetching compose file from: ${COMPOSE_URL}"
curl -fsSL "$COMPOSE_URL" -o "$TMP_COMPOSE" || {
  echo "Error: Failed to download compose file from $COMPOSE_URL" >&2
  exit 1
}

echo "Converting Compose file → Kubernetes manifests with kompose..."
kompose convert -f "$TMP_COMPOSE" -o "$TMP_RENDERED"

# --- Patch namespace and labels using yq ---
if ! command -v yq >/dev/null 2>&1; then
  echo "Error: 'yq' is required (brew install yq)" >&2
  exit 1
fi

echo "Removing Kompose annotations (kompose.cmd and kompose.version)..."

yq -i '
  del(.metadata.annotations["kompose.cmd"]) |
  del(.metadata.annotations["kompose.version"]) |
  del(.spec.template.metadata.annotations["kompose.cmd"]) |
  del(.spec.template.metadata.annotations["kompose.version"])
' "$TMP_RENDERED"

echo "Adding namespace and standardized labels..."

export VERSION
yq -i "
  .metadata.namespace = \"$NAMESPACE\" |
  .metadata.labels.\"app.kubernetes.io/name\" = \"$APP_NAME\" |
  .metadata.labels.\"app.kubernetes.io/instance\" = \"$APP_NAME\" |
  .metadata.labels.\"app.kubernetes.io/managed-by\" = \"kompose\" |
  .metadata.labels.\"app.kubernetes.io/version\" = \"$VERSION\"
" "$TMP_RENDERED"

# --- Post-process to force double quotes for version label ---
sed -i '' -E "s/(app\.kubernetes\.io\/version:)[[:space:]]*${VERSION}/\1 \"${VERSION}\"/" "$TMP_RENDERED"

echo "Injecting liveness/readiness probes..."

APP_NAME_YQ="$APP_NAME"

yq -i "$TMP_RENDERED" <<'YQ_SCRIPT'
select(.kind == "Deployment") |
.spec.template.spec.containers[] |=
  if .name == strenv(APP_NAME_YQ) then
    . + {
      "livenessProbe": {"httpGet": {"path": "/", "port": 3001}},
      "readinessProbe": {"httpGet": {"path": "/", "port": 3001}}
    }
  else .
  end
YQ_SCRIPT

# --- Write to output file ---
mv "$TMP_RENDERED" "$OUT_FILE"
rm -rf "$TMP_DIR"

echo ""
echo "Render complete:"
echo "  App:        $APP_NAME"
echo "  Version:    $VERSION"
echo "  Namespace:  $NAMESPACE"
echo "  Output:     $OUT_FILE"
echo ""
echo "Kubernetes manifests generated successfully."
