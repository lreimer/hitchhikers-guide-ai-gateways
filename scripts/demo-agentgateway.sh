#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/agentgateway-common.sh
source "$script_dir/agentgateway-common.sh"

namespace="${AGENTGATEWAY_NAMESPACE:-agentgateway-demo}"
url="${AGENTGATEWAY_URL:-http://127.0.0.1:8080}"
alice_key="${AGENTGATEWAY_ALICE_KEY:-}"
bob_key="${AGENTGATEWAY_BOB_KEY:-}"

agentgateway_require_commands kubectl curl jq openssl awk grep
agentgateway_validate_namespace "$namespace"
agentgateway_validate_client_key AGENTGATEWAY_ALICE_KEY "$alice_key"
agentgateway_validate_client_key AGENTGATEWAY_BOB_KEY "$bob_key"
if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
  printf 'AGENTGATEWAY_URL must be an http:// or https:// URL without whitespace.\n' >&2
  exit 1
fi

state_json="$(kubectl get configmap agentgateway-demo-state --namespace "$namespace" -o json)"
if [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$state_json")" != "agentgateway-demo" ]]; then
  printf 'The agentgateway demo state ConfigMap is not owned by this demo.\n' >&2
  exit 1
fi
mode="$(jq -r '.data["backend-mode"]' <<<"$state_json")"
model="$(jq -r '.data.model' <<<"$state_json")"
if [[ -n "${AGENTGATEWAY_MODE:-}" && "$AGENTGATEWAY_MODE" != "$mode" ]]; then
  printf 'Installed mode is %s; rerun agentgateway-install to switch to %s.\n' \
    "$mode" "$AGENTGATEWAY_MODE" >&2
  exit 1
fi
if [[ ! "$model" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
  printf 'The installed model setting is invalid.\n' >&2
  exit 1
fi

umask 077
temp_dir="$(mktemp -d)"
policy_patch="$temp_dir/policy-patch.json"
policy_backup="$temp_dir/policy-backup.json"
request_header="$temp_dir/request-header"
response_body="$temp_dir/response-body"
response_headers="$temp_dir/response-headers"
request_body="$temp_dir/request-body"
policy_saved=false
keys_may_be_revoked=false

cleanup() {
  local exit_status=$?
  trap - EXIT

  if [[ "$policy_saved" == true ]] &&
    ! kubectl patch agentgatewaypolicy agentgateway-demo --namespace "$namespace" \
      --type=merge --patch-file="$policy_backup" >/dev/null; then
    printf 'Failed to restore the original rate-limit policy; inspect AgentgatewayPolicy/agentgateway-demo in namespace %s.\n' \
      "$namespace" >&2
    exit_status=1
  fi
  if [[ "$keys_may_be_revoked" == true ]] &&
    ! agentgateway_apply_client_keys "$namespace" "$alice_key" "$bob_key" >/dev/null; then
    printf 'Failed to restore virtual keys; inspect ConfigMap/agentgateway-api-keys in namespace %s.\n' \
      "$namespace" >&2
    exit_status=1
  fi

  rm -f "$policy_patch" "$policy_backup" "$request_header" "$response_body" \
    "$response_headers" "$request_body"
  rmdir "$temp_dir"
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_request() {
  local key="$1"
  local request_model="$2"

  printf 'Authorization: Bearer %s\n' "$key" > "$request_header"
  printf '{"model":"%s","messages":[{"role":"user","content":"Reply in one short sentence: what is an AI gateway?"}]}' \
    "$request_model" > "$request_body"
  curl --silent --show-error --max-time 15 \
    --header "@$request_header" \
    --header 'Content-Type: application/json' \
    --data-binary "@$request_body" \
    --output "$response_body" \
    --dump-header "$response_headers" \
    --write-out '%{http_code}' \
    "$url/v1/chat/completions"
}

write_raw_request() {
  local key="$1"
  local body="$2"

  printf 'Authorization: Bearer %s\n' "$key" > "$request_header"
  printf '%s' "$body" > "$request_body"
  curl --silent --show-error --max-time 15 \
    --header "@$request_header" \
    --header 'Content-Type: application/json' \
    --data-binary "@$request_body" \
    --output "$response_body" \
    --dump-header "$response_headers" \
    --write-out '%{http_code}' \
    "$url/v1/chat/completions"
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local description="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf '%s: expected HTTP %s, got %s.\n' "$description" "$expected" "$actual" >&2
    exit 1
  fi
  printf '%s: HTTP %s.\n' "$description" "$actual"
}

assert_model_input_rejected() {
  local actual="$1"
  local description="$2"

  if [[ "$actual" != 400 && "$actual" != 403 ]]; then
    printf '%s: expected HTTP 400 or 403, got %s.\n' "$description" "$actual" >&2
    exit 1
  fi
  printf '%s: HTTP %s; request rejected.\n' "$description" "$actual"
}

assert_completion() {
  local description="$1"
  local total_tokens

  if ! jq -e '(.choices[0].message.content | type == "string" and length > 0) and (.usage.total_tokens | type == "number")' \
    "$response_body" >/dev/null; then
    printf '%s: response did not contain nonempty completion content and numeric total token usage.\n' \
      "$description" >&2
    exit 1
  fi
  total_tokens="$(jq -r '.usage.total_tokens' "$response_body")"
  printf '%s: nonempty completion; %s tokens.\n' "$description" "$total_tokens"
}

assert_gateway_rate_limit() {
  local description="$1"

  if ! grep -Eiq '^x-ratelimit-remaining:[[:space:]]*0\r?$' "$response_headers" ||
    ! grep -Eiq 'rate limit exceeded' "$response_body"; then
    printf '%s: HTTP 429 did not have the expected gateway rate-limit body and remaining-token header.\n' \
      "$description" >&2
    exit 1
  fi
  printf '%s: gateway-generated HTTP 429.\n' "$description"
}

set_rate_limit() {
  local patch_json="$1"
  printf '%s\n' "$patch_json" > "$policy_patch"
  kubectl patch agentgatewaypolicy agentgateway-demo --namespace "$namespace" \
    --type=merge --patch-file="$policy_patch" >/dev/null
}

if [[ "$mode" != "mock" && "$mode" != "openai" ]]; then
  printf 'Installed backend mode is invalid: %s\n' "$mode" >&2
  exit 1
fi

printf 'Checking %s backend at %s (model: %s).\n' "$mode" "$url" "$model"
if [[ "$mode" == "openai" ]]; then
  printf 'OpenAI mode sends real provider requests and can incur charges.\n'
else
  printf 'Mock mode makes no external inference calls.\n'
fi

status="$(curl --silent --show-error --max-time 10 --output "$response_body" \
  --write-out '%{http_code}' "$url/v1/chat/completions" \
  --header 'Content-Type: application/json' --data '{"model":"invalid","messages":[]}')"
assert_status 401 "$status" 'Unauthenticated request'

printf 'Authorization: Bearer invalid-agentgateway-client-key\n' > "$request_header"
printf '{"model":"%s","messages":[{"role":"user","content":"test"}]}' "$model" > "$request_body"
status="$(curl --silent --show-error --max-time 10 \
  --header "@$request_header" --header 'Content-Type: application/json' \
  --data-binary "@$request_body" --output "$response_body" \
  --write-out '%{http_code}' "$url/v1/chat/completions")"
assert_status 401 "$status" 'Invalid virtual key'

status="$(write_request "$alice_key" "$model")"
assert_status 200 "$status" 'Allowed-model request'
assert_completion 'Allowed-model request'

status="$(write_raw_request "$alice_key" '{"messages":[{"role":"user","content":"missing model"}]}')"
assert_model_input_rejected "$status" 'Missing-model request'

status="$(write_raw_request "$alice_key" '{"model":')"
assert_model_input_rejected "$status" 'Malformed-model request'

status="$(write_request "$bob_key" 'agentgateway-forbidden-model')"
assert_status 403 "$status" 'Forbidden-model request'

original_rate_limit="$(kubectl get agentgatewaypolicy agentgateway-demo --namespace "$namespace" \
  -o json | jq -c '.spec.traffic.rateLimit')"
if [[ "$original_rate_limit" == "null" ]]; then
  printf 'The installed policy has no rate-limit configuration to restore.\n' >&2
  exit 1
fi
printf '{"spec":{"traffic":{"rateLimit":%s}}}\n' "$original_rate_limit" > "$policy_backup"
policy_saved=true

set_rate_limit '{"spec":{"traffic":{"rateLimit":{"local":[{"requests":1,"unit":"Minutes","burst":1,"key":"apiKey.user_id"}]}}}}'
for attempt in 1 2; do
  status="$(write_request "$alice_key" "$model")"
  assert_status 200 "$status" "Request-limit scenario request $attempt"
  assert_completion "Request-limit scenario request $attempt"
done
status="$(write_request "$alice_key" "$model")"
assert_status 429 "$status" 'Request throttling'
assert_gateway_rate_limit 'Request throttling'

set_rate_limit '{"spec":{"traffic":{"rateLimit":{"local":[{"requests":120,"unit":"Minutes","burst":120,"key":"apiKey.user_id"},{"tokens":20,"unit":"Seconds","key":"apiKey.user_id"}]}}}}'
token_limited=false
for attempt in $(seq 1 20); do
  status="$(write_request "$alice_key" "$model")"
  if [[ "$status" == 429 ]]; then
    assert_gateway_rate_limit 'Token-budget exhaustion'
    token_limited=true
    break
  fi
  assert_status 200 "$status" "Token-budget scenario request $attempt"
  assert_completion "Token-budget scenario request $attempt"
done
if [[ "$token_limited" != true ]]; then
  printf 'Alice did not exhaust the token budget within 20 bounded requests.\n' >&2
  exit 1
fi

status="$(write_request "$bob_key" "$model")"
assert_status 200 "$status" 'Bob independent token budget'
assert_completion 'Bob independent token budget'

recovered=false
for attempt in $(seq 1 10); do
  sleep 3
  status="$(write_request "$alice_key" "$model")"
  if [[ "$status" == 200 ]]; then
    assert_completion 'Alice token-budget recovery'
    recovered=true
    break
  fi
  if [[ "$status" != 429 ]]; then
    assert_status 200 "$status" 'Alice token-budget recovery'
  fi
  assert_gateway_rate_limit 'Alice token-budget refill wait'
done
if [[ "$recovered" != true ]]; then
  printf 'Alice did not recover within the bounded 30-second refill wait.\n' >&2
  exit 1
fi

set_rate_limit '{"spec":{"traffic":{"rateLimit":{"local":[{"requests":120,"unit":"Minutes","burst":120,"key":"apiKey.user_id"},{"tokens":10000,"unit":"Hours","key":"apiKey.user_id"}]}}}}'
keys_may_be_revoked=true
kubectl patch configmap agentgateway-api-keys --namespace "$namespace" \
  --type=merge --patch='{"data":{"alice":null}}' >/dev/null
revoked=false
for attempt in $(seq 1 10); do
  status="$(write_request "$alice_key" "$model")"
  if [[ "$status" == 401 ]]; then
    revoked=true
    break
  fi
  if [[ "$status" != 401 ]]; then
    sleep 2
  fi
done
if [[ "$revoked" != true ]]; then
  printf "Alice's revoked key did not return HTTP 401 within 20 seconds.\n" >&2
  exit 1
fi
printf 'Revoked Alice key: HTTP 401.\n'

status="$(write_request "$bob_key" "$model")"
assert_status 200 "$status" 'Bob remains authorized after Alice revocation'
assert_completion 'Bob remains authorized after Alice revocation'

printf "Temporary limits and Alice's key will be restored before exit.\n"
