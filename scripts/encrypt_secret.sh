#!/bin/bash
# macOS-compatible (Bash 3.2) SOPS encryption helper.
# Encrypts a Kubernetes Secret YAML file in place, unless it's already encrypted.

set -eEuo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <secret-file.yaml>" >&2
  exit 1
fi

SECRET_FILE="$1"

if [ ! -f "$SECRET_FILE" ]; then
  echo "Error: File '$SECRET_FILE' not found." >&2
  exit 1
fi

if ! command -v sops >/dev/null 2>&1; then
  echo "Error: 'sops' command not found in PATH." >&2
  exit 1
fi

# Detect if already encrypted (has a sops: block)
if grep -q '^sops:' "$SECRET_FILE"; then
  echo "Skipping: $SECRET_FILE already encrypted."
  exit 0
fi

echo "Encrypting file with SOPS: $SECRET_FILE"
sops --encrypt --in-place "$SECRET_FILE"

if grep -q '^sops:' "$SECRET_FILE"; then
  echo "Successfully encrypted: $SECRET_FILE"
else
  echo "️Warning: Encryption may have failed (no 'sops:' block found)." >&2
  exit 1
fi
