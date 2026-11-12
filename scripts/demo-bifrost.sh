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

umask 077
curl_config="$(mktemp)"
trap 'rm -f "$curl_config"' EXIT
printf 'header = "Authorization: ******"\n' "$BIFROST_VIRTUAL_KEY" > "$curl_config"

curl --fail-with-body --silent --show-error \
  --config "$curl_config" \
  --header 'Content-Type: application/json' \
  --data '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"What is an AI gateway?"}]}' \
  "$url/v1/chat/completions"
printf '\n'
