#!/usr/bin/env bash

agentgateway_system_namespace="agentgateway-system"
agentgateway_managed_by="app.kubernetes.io/managed-by=agentgateway-demo"

agentgateway_require_commands() {
  local command_name

  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf 'Required command not found: %s\n' "$command_name" >&2
      return 1
    fi
  done
}

agentgateway_validate_namespace() {
  local namespace="$1"

  if [[ ! "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    [[ ${#namespace} -gt 63 ]] ||
    [[ "$namespace" == "$agentgateway_system_namespace" ]]; then
    printf 'NAMESPACE must be a DNS label of at most 63 characters and must not be %s.\n' \
      "$agentgateway_system_namespace" >&2
    return 1
  fi
}

agentgateway_validate_client_key() {
  local name="$1"
  local value="$2"

  if (( ${#value} < 32 || ${#value} > 256 )) ||
    [[ ! "$value" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    printf '%s must contain 32-256 URL-safe characters. Generate one with openssl rand -hex 32.\n' \
      "$name" >&2
    return 1
  fi
}

agentgateway_validate_provider_key() {
  local value="$1"

  if [[ -z "$value" || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    printf 'OPENAI_API_KEY must be set and must not contain line breaks.\n' >&2
    return 1
  fi
}

agentgateway_hash_key() {
  local value="$1"
  local digest

  digest="$(printf '%s' "$value" | openssl dgst -sha256 | awk '{print $NF}')"
  if [[ ! "$digest" =~ ^[[:xdigit:]]{64}$ ]]; then
    printf 'Could not compute a SHA-256 client-key hash.\n' >&2
    return 1
  fi
  printf 'sha256:%s' "$digest"
}

agentgateway_assert_owned_or_absent() {
  local resource="$1"
  local name="$2"
  local namespace="$3"
  local resource_json

  resource_json="$(kubectl get "$resource" "$name" --namespace "$namespace" \
    --ignore-not-found -o json)"
  if [[ -z "$resource_json" ]]; then
    return 0
  fi

  if [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$resource_json")" != "agentgateway-demo" ]]; then
    printf 'Refusing to overwrite unowned %s/%s in namespace %s.\n' \
      "$resource" "$name" "$namespace" >&2
    return 1
  fi
}

agentgateway_apply_client_keys() {
  local namespace="$1"
  local alice_key="$2"
  local bob_key="$3"
  local alice_hash
  local bob_hash
  local alice_entry
  local bob_entry

  alice_hash="$(agentgateway_hash_key "$alice_key")"
  bob_hash="$(agentgateway_hash_key "$bob_key")"
  alice_entry="$(printf '{"keyHash":"%s","metadata":{"user_id":"alice"}}' "$alice_hash")"
  bob_entry="$(printf '{"keyHash":"%s","metadata":{"user_id":"bob"}}' "$bob_hash")"

  kubectl create configmap agentgateway-api-keys \
    --namespace "$namespace" \
    --from-literal="alice=$alice_entry" \
    --from-literal="bob=$bob_entry" \
    --dry-run=client -o yaml |
    kubectl label --local -f - "$agentgateway_managed_by" \
      'agentgateway.dev/apikey=true' --overwrite -o yaml |
    kubectl apply -f -
}

agentgateway_check_client_keys() {
  local namespace="$1"
  local alice_key="$2"
  local bob_key="$3"
  local allow_rotation="$4"
  local current
  local current_alice_hash
  local current_bob_hash
  local expected_alice_hash
  local expected_bob_hash

  current="$(kubectl get configmap agentgateway-api-keys --namespace "$namespace" \
    --ignore-not-found -o json)"
  if [[ -z "$current" ]]; then
    return 0
  fi

  current_alice_hash="$(jq -r 'try (.data.alice | fromjson | .keyHash) catch ""' <<<"$current")"
  current_bob_hash="$(jq -r 'try (.data.bob | fromjson | .keyHash) catch ""' <<<"$current")"
  expected_alice_hash="$(agentgateway_hash_key "$alice_key")"
  expected_bob_hash="$(agentgateway_hash_key "$bob_key")"
  if [[ "$current_alice_hash" == "$expected_alice_hash" &&
    "$current_bob_hash" == "$expected_bob_hash" ]]; then
    return 0
  fi

  if [[ "$allow_rotation" != true ]]; then
    printf 'Client-key hashes differ from the installed keys. Set AGENTGATEWAY_ROTATE_CLIENT_KEYS=true only for an intentional key rotation.\n' >&2
    return 1
  fi
  printf 'Explicitly replacing the installed client-key hashes.\n'
}

agentgateway_write_policy() {
  local namespace="$1"
  local model="$2"

  cat <<EOF | kubectl apply --namespace "$namespace" -f -
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: agentgateway-demo
  labels:
    app.kubernetes.io/managed-by: agentgateway-demo
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  traffic:
    apiKeyAuthentication:
      mode: Strict
      configMapSelector:
        matchLabels:
          agentgateway.dev/apikey: "true"
    authorization:
      action: Require
      policy:
        matchExpressions:
          - 'has(json(request.body).model) && json(request.body).model == "$model"'
    rateLimit:
      local:
        - requests: 120
          unit: Minutes
          burst: 120
          key: apiKey.user_id
        - tokens: 10000
          unit: Hours
          key: apiKey.user_id
EOF
}
