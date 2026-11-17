#!/usr/bin/env bash
set -euo pipefail

url="${BIFROST_URL:-http://127.0.0.1:8080}"

for command in curl jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

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

jq_options=(--monochrome-output)
if [[ -t 1 && -z "${NO_COLOR+x}" ]]; then
  jq_options=(--color-output)
fi

for prompt in \
  'What is an AI gateway?' \
  'What is an AI gateway, exactly?'; do
  printf '\nPrompt: %s\n' "$prompt"
  payload="$(jq -cn --arg prompt "$prompt" \
    '{model:"openai/gpt-5.4-mini",messages:[{role:"user",content:$prompt}]}')"
  curl --fail-with-body --silent --show-error \
    --header "@$curl_header" \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "$url/v1/chat/completions" |
    jq "${jq_options[@]}" .
done

printf '\nCompare cache status in the dashboard request logs; semantic cache hits depend on similarity and cache readiness.\n'
