#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
# shellcheck source=scripts/kagent-common.sh
source "$script_dir/kagent-common.sh"
# shellcheck source=scripts/kagent-byo-common.sh
source "$script_dir/kagent-byo-common.sh"

namespace="${KAGENT_NAMESPACE:-kagent}"
image="${KAGENT_BYO_IMAGE:-}"
kagent_demo_require_commands kubectl jq kagent sed
kagent_demo_require_context
kagent_demo_validate_namespace "$namespace"
kagent_byo_validate_image "$image"
if [[ "$(kagent version | jq -r '.kagent_version')" != "1.0.1" ]]; then
  printf 'This add-on requires the pinned kagent CLI v1.0.1.\n' >&2
  exit 1
fi

base_record="$(kubectl get configmap kagent-demo-ownership -n "$namespace" -o json)"
kagent_demo_verify_installation "$namespace" "$base_record"
if [[ "$(jq -r '.data.phase' <<<"$base_record")" != ready ]]; then
  printf 'Install the complete kagent base demo before the BYO add-on.\n' >&2
  exit 1
fi
gateway_namespace="$(jq -r '.data["gateway-namespace"]' <<<"$base_record")"
gateway_state="$(kubectl get configmap agentgateway-demo-state -n "$gateway_namespace" -o json)"
if [[ "$(jq -r '.data["agentgateway-version"]' <<<"$gateway_state")" != "v1.7.0" ]]; then
  printf 'The BYO add-on requires the pinned agentgateway v1.7.0 demo.\n' >&2
  exit 1
fi
model="$(jq -r '.data.model' <<<"$gateway_state")"
kagent_demo_verify_model_config "$namespace" "$gateway_namespace" "$model"
kagent_demo_verify_mcp_policy "$root_dir" "$gateway_namespace"
remote="$(kubectl get remotemcpserver product-catalog-bob -n "$namespace" -o json)"
if ! jq -e --arg gateway \
  "http://agentgateway-proxy.$gateway_namespace.svc.cluster.local/mcp" '
    .spec.url == $gateway and
    any(.spec.headersFrom[]?;
      .name == "Authorization" and .valueFrom.type == "Secret")' \
  <<<"$remote" >/dev/null; then
  printf 'The BYO catalog binding must use the protected, Secret-authenticated agentgateway MCP route.\n' >&2
  exit 1
fi

record="$(kubectl get configmap kagent-byo-ownership -n "$namespace" --ignore-not-found -o json)"
if [[ -n "$record" ]]; then
  kagent_byo_verify_record "$namespace" "$record"
  case "$(jq -r '.data.phase' <<<"$record")" in
    ready|installing|failed) ;;
    *)
      printf 'The BYO add-on is being cleaned up; finish make kagent-byo-uninstall before reinstalling.\n' >&2
      exit 1
      ;;
  esac
else
  for resource in \
    "harness kagent-byo-harness" \
    "agenttemplate product-quote-byo-assistant" \
    "agent product-quote-byo-assistant"; do
    read -r kind name <<<"$resource"
    object="$(kubectl get "$kind" "$name" -n "$namespace" --ignore-not-found -o json)"
    if [[ -n "$object" ]]; then
      printf 'Refusing to adopt existing %s/%s without a BYO ownership record.\n' "$kind" "$name" >&2
      exit 1
    fi
  done
  record="$(kubectl get configmap kagent-byo-ownership -n "$namespace" --ignore-not-found -o json)"
  if [[ -n "$record" ]]; then
    printf 'Refusing to adopt an existing kagent-byo-ownership ConfigMap.\n' >&2
    exit 1
  fi
fi

sessions='[]'
if [[ -n "$record" ]]; then
  sessions="$(jq -r '.data.sessions' <<<"$record")"
fi
resources='[]'
if [[ -n "$record" ]]; then
  resources="$(jq -r '.data.resources' <<<"$record")"
fi
kagent_byo_write_record "$namespace" "$image" installing preflight "$resources" "$sessions"
checkpoint() {
  local step="$1" captured
  captured="$(kagent_byo_capture_resources "$namespace")" || return 1
  kagent_byo_write_record "$namespace" "$image" installing "$step" "$captured" "$sessions"
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    local captured
    if captured="$(kagent_byo_capture_resources "$namespace")"; then
      if ! kagent_byo_write_record "$namespace" "$image" failed "${completed_step:-preflight}" \
        "$captured" "$sessions" >/dev/null; then
        printf 'Could not checkpoint the partial BYO installation; review resource ownership before retrying.\n' >&2
      fi
    fi
  fi
  rm -f "$manifest_dir/harness.yaml" "$manifest_dir/agent-template.yaml" "$manifest_dir/agent.yaml"
  rmdir "$manifest_dir" 2>/dev/null || true
  exit "$status"
}
manifest_dir="$(mktemp -d "${TMPDIR:-/tmp}/kagent-byo-install.XXXXXX")"
completed_step=preflight
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for manifest in harness agent-template agent; do
  sed "s|__KAGENT_BYO_IMAGE__|$image|g" \
    "$root_dir/agents/kagent/byo/$manifest.yaml" > "$manifest_dir/$manifest.yaml"
  kubectl apply --namespace "$namespace" -f "$manifest_dir/$manifest.yaml"
  completed_step="$manifest"
  checkpoint "$completed_step"
done

kubectl wait --for=condition=Ready --timeout=10m \
  agent/product-quote-byo-assistant -n "$namespace"
resources="$(kagent_byo_capture_resources "$namespace")"
kagent_byo_write_record "$namespace" "$image" ready ready "$resources" "$sessions"
trap - EXIT
rm -f "$manifest_dir/harness.yaml" "$manifest_dir/agent-template.yaml" "$manifest_dir/agent.yaml"
rmdir "$manifest_dir"
printf 'PASS installed the digest-pinned BYO quote agent in namespace %s on context %s.\n' \
  "$namespace" "$(kubectl config current-context)"
