#!/usr/bin/env bash
set -euo pipefail

url="${ENVOY_AI_GATEWAY_URL:-http://127.0.0.1:8080}"
namespace="${ENVOY_AI_GATEWAY_NAMESPACE:-envoy-ai-gateway-demo}"
mode="${ENVOY_AI_GATEWAY_MODE:-mock}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
response_file="$(mktemp)"
headers_file="$(mktemp)"
key_file="$(mktemp)"
invalid_key_file="$(mktemp)"
trap 'rm -f "$response_file" "$headers_file" "$key_file" "$invalid_key_file"' EXIT

fail() {
  printf 'Error: %s\n' "$*" >&2
  if [[ -s "$response_file" ]]; then
    printf 'Response body:\n' >&2
    cat "$response_file" >&2
    printf '\n' >&2
  fi
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "Required command not found: curl"
command -v python3 >/dev/null 2>&1 || fail "Required command not found: python3"
[[ "$mode" == mock || "$mode" == openai ]] || fail "ENVOY_AI_GATEWAY_MODE must be 'mock' or 'openai'."

client_key="${ENVOY_AI_GATEWAY_CLIENT_KEY:-}"
if [[ -z "$client_key" ]]; then
  command -v kubectl >/dev/null 2>&1 || fail "Set ENVOY_AI_GATEWAY_CLIENT_KEY or install kubectl to read the demo Secret."
  client_key="$(kubectl get secret envoy-ai-gateway-client-keys \
    --namespace "$namespace" \
    -o 'jsonpath={.data.demo}' |
    python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.buffer.read()).decode())')" ||
    fail "Could not read the demo client key Secret."
fi
[[ -n "$client_key" && "$client_key" != *$'\n'* && "$client_key" != *$'\r'* ]] ||
  fail "The client key must be non-empty and contain no line breaks."

umask 077
printf 'x-api-key: %s\n' "$client_key" > "$key_file"
printf 'x-api-key: invalid-demo-key\n' > "$invalid_key_file"
unset client_key

mock_body='{"model":"demo-chat","messages":[{"role":"user","content":"Return the deterministic demo response."}],"stream":false,"max_tokens":32}'
live_body='{"model":"live-chat","messages":[{"role":"user","content":"In one short sentence, define an AI gateway."}],"stream":false,"max_tokens":16}'

request() {
  local headers="$1"
  local body="$2"
  shift 2
  : > "$response_file"
  : > "$headers_file"
  if [[ -n "$headers" ]]; then
    curl --silent --show-error --max-time 30 \
      --dump-header "$headers_file" --output "$response_file" --write-out '%{http_code}' \
      --header "@$headers" --header 'Content-Type: application/json' \
      --data "$body" "$url/v1/chat/completions"
  else
    curl --silent --show-error --max-time 30 \
      --dump-header "$headers_file" --output "$response_file" --write-out '%{http_code}' \
      --header 'Content-Type: application/json' \
      --data "$body" "$url/v1/chat/completions"
  fi
}

expect_status() {
  local expected="$1"
  local description="$2"
  local headers="$3"
  local body="$4"
  local status
  if ! status="$(request "$headers" "$body")"; then
    fail "$description failed before receiving an HTTP response."
  fi
  [[ "$status" == "$expected" ]] || fail "$description returned HTTP $status; expected $expected."
  printf '%s: HTTP %s\n' "$description" "$status"
}

check_mock_response() {
  python3 - "$response_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as response:
    data = json.load(response)
usage = data.get("usage", {})
expected = {"prompt_tokens": 40, "completion_tokens": 20, "total_tokens": 60}
if data.get("model") != "fixture-model" or any(usage.get(key) != value for key, value in expected.items()):
    raise SystemExit(f"Unexpected fixture response model/usage: {data.get('model')!r}, {usage!r}")
PY
}

expect_status 401 "Missing client key is rejected" "" "$mock_body"
expect_status 401 "Invalid client key is rejected" "$invalid_key_file" "$mock_body"

for attempt in 1 2; do
  expect_status 200 "Authenticated mock completion $attempt" "$key_file" "$mock_body"
  check_mock_response || fail "The fixture model mapping or fixed 40+20=60 token usage did not match."
  printf 'Model rewrite verified at mock upstream; usage: 40 prompt + 20 completion = 60 total tokens.\n'
done

printf 'Waiting for post-response token charges to produce the expected gateway 429...\n'
deadline=$((SECONDS + 30))
attempt=0
while (( SECONDS < deadline && attempt < 30 )); do
  ((attempt += 1))
  if ! status="$(request "$key_file" "$mock_body")"; then
    fail "Could not reach the gateway while checking token exhaustion."
  fi
  if [[ "$status" == 429 ]]; then
    printf 'Token allowance exhausted: gateway-generated HTTP 429 after %d additional admission check(s).\n' "$((attempt - 1))"
    break
  fi
  [[ "$status" == 200 ]] || fail "Token exhaustion check returned unexpected HTTP $status."
  check_mock_response || fail "An admitted request returned unexpected fixture usage."
  sleep 1
done
[[ "${status:-}" == 429 ]] || fail "No gateway-generated 429 was observed within the bounded 30-second charge window."

printf 'Waiting for the one-minute token window to recover...\n'
deadline=$((SECONDS + 85))
while (( SECONDS < deadline )); do
  if ! status="$(request "$key_file" "$mock_body")"; then
    fail "Could not reach the gateway while waiting for token-window recovery."
  fi
  if [[ "$status" == 200 ]]; then
    check_mock_response || fail "The recovered request returned unexpected fixture usage."
    printf 'Token window recovered: HTTP 200; usage: 40 prompt + 20 completion = 60 total tokens.\n'
    break
  fi
  [[ "$status" == 429 ]] || fail "Token recovery check returned unexpected HTTP $status."
  sleep 2
done
[[ "${status:-}" == 200 ]] || fail "The token window did not recover within 85 seconds."

if [[ "$mode" == openai ]]; then
  expect_status 200 "Opt-in OpenAI completion (one request, max_tokens=16)" "$key_file" "$live_body"
  python3 - "$response_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as response:
    data = json.load(response)
usage = data.get("usage", {})
if not isinstance(usage.get("total_tokens"), int) or usage["total_tokens"] <= 0:
    raise SystemExit(f"OpenAI response did not contain genuine token usage: {usage!r}")
print(f"OpenAI usage (not part of deterministic quota checks): {usage}")
PY
fi

printf '\nDemo complete. Client credentials were supplied from a mode-0600 temporary header file.\n'
