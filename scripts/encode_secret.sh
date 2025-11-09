#!/bin/bash
# encode_secret.sh <secret-file.yaml> <file-to-encode>
# Example:
#   ./encode_secret.sh alertmanager-secret.yaml alertmanager.yaml

set -eEuo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <secret-file.yaml> <file-to-encode>" >&2
  exit 1
fi

secret_file="$1"
file_to_encode="$2"

if [ ! -f "$secret_file" ]; then
  echo "Error: secret file '$secret_file' not found" >&2
  exit 1
fi
if [ ! -f "$file_to_encode" ]; then
  echo "Error: input file '$file_to_encode' not found" >&2
  exit 1
fi

# Base64 encode (no newlines)
data_key=$(basename "$file_to_encode")
encoded=$(base64 < "$file_to_encode" | tr -d '\n')

tmpfile="$(mktemp)"

awk -v key="$data_key" -v val="$encoded" '
  BEGIN { in_data=0; replaced=0 }
  /^data:/ {
    print
    in_data=1
    next
  }
  in_data && /^[[:space:]]+[A-Za-z0-9._-]+:/ {
    if ($1 == key ":") {
      print "  " key ": " val
      replaced=1
    } else {
      print
    }
    next
  }
  in_data && !/^[[:space:]]+[A-Za-z0-9._-]+:/ {
    if (!replaced) {
      print "  " key ": " val
      replaced=1
    }
    in_data=0
  }
  { print }
  END {
    if (!replaced && in_data) {
      print "  " key ": " val
    }
  }
' "$secret_file" > "$tmpfile"

mv "$tmpfile" "$secret_file"
echo "Updated $secret_file with encoded content from $file_to_encode"
