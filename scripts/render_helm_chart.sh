#!/bin/bash
# macOS-compatible (Bash 3.2) Helm chart renderer using YAML spec file.
#
# Usage:
#   ./render_helm_chart.sh <path-to-spec-file>
#
# Example spec file:
#   name: cert-manager
#   repo: https://charts.jetstack.io
#   version: 1.19.1
#   valuesFile: values.yaml
#
# Notes:
#   - 'name' and 'repo' are required.
#   - If 'version' is omitted, latest chart version is used.
#   - Output is written to <chart-name>.yaml in the same folder as the spec file.

set -eEuo pipefail

print_example() {
  echo "Example spec file format:"
  echo "  name: cert-manager"
  echo "  repo: https://charts.jetstack.io"
  echo "  version: 1.19.1"
  echo "  valuesFile: values.yaml"
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

BASENAME="$(basename "$DEF_FILE")"
SPEC_DIR="$(cd "$(dirname "$DEF_FILE")" && pwd)"

# Simple YAML parser for "key: value" pairs
parse_yaml_value() {
  local key="$1"
  awk -v k="$key" '
    $1 == k ":" {
      sub(/^[^:]+:[[:space:]]*/, "", $0);
      print $0;
      exit;
    }
  ' "$DEF_FILE" | tr -d '"' | tr -d "'"
}

# Extract fields
CHART_NAME="$(parse_yaml_value name)"
REPO_URL="$(parse_yaml_value repo)"
CHART_VERSION="$(parse_yaml_value version)"
VALUES_FILE="$(parse_yaml_value valuesFile)"
CHART_PATH="$(parse_yaml_value chart)"

# Validate required fields
if [ -z "$CHART_NAME" ] || [ -z "$REPO_URL" ]; then
  echo "Error: Missing required fields in $DEF_FILE" >&2
  echo ""
  print_example
  exit 1
fi

# Defaults
CHART_PATH="${CHART_PATH:-$CHART_NAME}"
OUT_FILE="$SPEC_DIR/${CHART_NAME}.yaml"

# Optional values flag
if [ -n "$VALUES_FILE" ]; then
  if [ ! -f "$SPEC_DIR/$VALUES_FILE" ]; then
    echo "Error: values file '$VALUES_FILE' not found in '$SPEC_DIR'." >&2
    exit 1
  fi
  USE_VALUES="--values $SPEC_DIR/$VALUES_FILE"
  echo "Using values file: $VALUES_FILE"
else
  USE_VALUES=""
  echo "No values file provided; using chart defaults."
fi

# Add / update repo
echo "Ensuring Helm repo for $CHART_NAME exists ($REPO_URL)"
helm repo add "$CHART_NAME" "$REPO_URL" >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# Render
echo "Rendering Helm chart:"
echo "  Chart: $CHART_PATH"
echo "  Repo:  $REPO_URL"
[ -n "$CHART_VERSION" ] && echo "  Version: $CHART_VERSION"
echo "  Output: $OUT_FILE"

helm template "$CHART_NAME" "$CHART_NAME/$CHART_PATH" \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  $USE_VALUES \
  > "$OUT_FILE"

echo "Render complete: $OUT_FILE"
