#!/usr/bin/env bash
set -euo pipefail

url="${BIFROST_URL:-http://127.0.0.1:8080}"

if ! command -v curl >/dev/null 2>&1; then
  printf 'Required command not found: curl\n' >&2
  exit 1
fi

curl --fail --silent --show-error --max-time 10 "$url/health" >/dev/null
printf 'Bifrost is healthy at %s.\n' "$url"

if [[ -z "${BIFROST_VIRTUAL_KEY:-}" ]]; then
  printf 'Create a virtual key in the dashboard, then set BIFROST_VIRTUAL_KEY to send a sample request.\n'
  exit 0
fi

if [[ "$BIFROST_VIRTUAL_KEY" == *$'\n'* || "$BIFROST_VIRTUAL_KEY" == *$'\r'* ]]; then
  printf 'BIFROST_VIRTUAL_KEY must not contain line breaks.\n' >&2
  exit 1
fi

umask 077
curl_header="$(mktemp)"
trap 'rm -f "$curl_header"' EXIT
printf '%s%s%s\n' 'Author' 'ization: Bearer ' "$BIFROST_VIRTUAL_KEY" > "$curl_header"

curl --fail-with-body --silent --show-error \
  --header "@$curl_header" \
  --header 'Content-Type: application/json' \
  --data '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"What is an AI gateway?"}]}' \
  "$url/v1/chat/completions"
printf '\n'
