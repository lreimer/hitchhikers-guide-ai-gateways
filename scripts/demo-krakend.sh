#!/usr/bin/env bash
set -euo pipefail

url="${KRAKEND_URL:-http://127.0.0.1:8080}"

if ! command -v curl >/dev/null 2>&1; then
  printf 'Required command not found: curl\n' >&2
  exit 1
fi

curl --fail --silent --show-error --max-time 10 "$url/__health" >/dev/null
printf 'KrakenD is healthy at %s.\n' "$url"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  printf 'Set OPENAI_API_KEY to send a sample request through KrakenD.\n'
  exit 0
fi

if [[ "$OPENAI_API_KEY" == *$'\n'* || "$OPENAI_API_KEY" == *$'\r'* ]]; then
  printf 'OPENAI_API_KEY must not contain line breaks.\n' >&2
  exit 1
fi

umask 077
curl_header="$(mktemp)"
trap 'rm -f "$curl_header"' EXIT
printf 'Authorization: Bearer %s\n' "$OPENAI_API_KEY" > "$curl_header"

curl --fail-with-body --silent --show-error \
  --header "@$curl_header" \
  --header 'Content-Type: application/json' \
  --data '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"What is an AI gateway?"}]}' \
  "$url/v1/chat/completions"
printf '\n'
