#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kagent-common.sh
source "$script_dir/kagent-common.sh"
# shellcheck source=scripts/kagent-byo-common.sh
source "$script_dir/kagent-byo-common.sh"

namespace="${KAGENT_NAMESPACE:-kagent}"
api_local_port="${KAGENT_BYO_API_LOCAL_PORT:-18084}"
api_url="http://127.0.0.1:$api_local_port"
kagent_demo_require_commands kubectl jq kagent curl
kagent_demo_require_context
kagent_demo_validate_namespace "$namespace"
if [[ ! "$api_local_port" =~ ^[0-9]+$ ]] ||
  (( api_local_port < 1024 || api_local_port > 65535 )); then
  printf 'KAGENT_BYO_API_LOCAL_PORT must be a port from 1024 to 65535.\n' >&2
  exit 1
fi

record="$(kubectl get configmap kagent-byo-ownership -n "$namespace" \
  --ignore-not-found -o json)"
if [[ -z "$record" ]]; then
  printf 'No BYO add-on ownership record found in %s; refusing to remove resources.\n' "$namespace" >&2
  exit 1
fi
kagent_byo_verify_record "$namespace" "$record"
phase="$(jq -r '.data.phase' <<<"$record")"
if [[ "$phase" == cleaned ]]; then
  printf 'PASS BYO add-on already removed; its ownership record is retained.\n'
  exit 0
fi
base_record="$(kubectl get configmap kagent-demo-ownership -n "$namespace" -o json)"
kagent_demo_verify_installation "$namespace" "$base_record"
if [[ "$(jq -r '.data.phase' <<<"$base_record")" != ready ]]; then
  printf 'The kagent base runtime must be ready while BYO resources and Sessions are removed.\n' >&2
  exit 1
fi

forward_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$forward_pid" ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sessions="$(jq -r '.data.sessions' <<<"$record")"
image="$(jq -r '.data.image' <<<"$record")"
if [[ "$(jq 'length' <<<"$sessions")" -gt 0 ]] &&
  [[ "$(kagent version | jq -r '.kagent_version')" != "1.0.1" ]]; then
  printf 'Use the pinned kagent CLI v1.0.1 to remove the tracked BYO Sessions.\n' >&2
  exit 1
fi
kagent_byo_write_record "$namespace" "$image" cleanup-failed cleanup-started \
  "$(jq -r '.data.resources' <<<"$record")" "$sessions" >/dev/null
if [[ "$(jq 'length' <<<"$sessions")" -gt 0 ]]; then
  kubectl port-forward --address 127.0.0.1 -n "$namespace" \
    service/kagent-controller "$api_local_port:8083" >/dev/null 2>&1 &
  forward_pid=$!
  ready=false
  for ((attempt = 0; attempt < 30; attempt++)); do
    if ! kill -0 "$forward_pid" 2>/dev/null; then
      printf 'kagent API port-forward exited before becoming ready.\n' >&2
      exit 1
    fi
    if kagent --api-url "$api_url" --gateway-url "$api_url" --namespace "$namespace" \
      --timeout 5s agent list --page-size 1 -o json >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    printf 'Timed out waiting for the kagent API to remove tracked BYO Sessions.\n' >&2
    exit 1
  fi
  while IFS= read -r session; do
    [[ -z "$session" ]] && continue
    kagent --api-url "$api_url" --gateway-url "$api_url" --namespace "$namespace" \
      --timeout 30s agent session delete "$session" --force
    kagent_byo_track_session "$namespace" "$session" remove
  done < <(jq -r '.[]' <<<"$sessions")
fi

for resource in \
  "agent product-quote-byo-assistant" \
  "agenttemplate product-quote-byo-assistant" \
  "harness kagent-byo-harness"; do
  read -r kind name <<<"$resource"
  kubectl delete "$kind" "$name" -n "$namespace" --ignore-not-found \
    --wait=true --timeout=120s
  resources="$(kagent_byo_capture_resources "$namespace")"
  sessions="$(kubectl get configmap kagent-byo-ownership -n "$namespace" -o json |
    jq -r '.data.sessions')"
  kagent_byo_write_record "$namespace" "$image" cleanup-failed "$kind-removed" \
    "$resources" "$sessions" >/dev/null
done
resources="$(kagent_byo_capture_resources "$namespace")"
if [[ "$(jq 'length' <<<"$resources")" -ne 0 ]]; then
  printf 'BYO resources remain after cleanup; ownership record retained for investigation.\n' >&2
  exit 1
fi
context="$(kubectl config current-context)"
kubectl create configmap kagent-byo-ownership -n "$namespace" \
  --from-literal=context="$context" \
  --from-literal=image="$image" \
  --from-literal=phase=cleaned \
  --from-literal=completed-step=resources-removed \
  --from-literal=resources='[]' \
  --from-literal=sessions='[]' \
  --dry-run=client -o yaml |
  kubectl label --local -f - "$kagent_byo_managed_by" --overwrite -o yaml |
  kubectl apply -f -
printf 'PASS removed the owned BYO agent, template, harness, and tracked Sessions. The base kagent runtime remains.\n'
