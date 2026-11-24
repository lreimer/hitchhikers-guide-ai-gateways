#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kagent-common.sh
source "$script_dir/kagent-common.sh"

namespace="${KAGENT_NAMESPACE:-kagent}"
kagent_demo_require_commands kubectl helm jq kagent
kagent_demo_require_context
kagent_demo_require_helm
kagent_demo_validate_namespace "$namespace"

record="$(kubectl get configmap kagent-demo-ownership -n "$namespace" \
  --ignore-not-found -o json)"
if [[ -z "$record" ]]; then
  printf 'No kagent-demo ownership record found in %s; refusing to remove runtime resources.\n' \
    "$namespace" >&2
  exit 1
fi
kagent_demo_verify_installation "$namespace" "$record"
if [[ "$(jq -r '.data.phase' <<<"$record")" == cleaned ]]; then
  printf 'PASS kagent runtime already removed; retained namespace ownership verified.\n'
  exit 0
fi

if [[ "$(kagent version | jq -r '.kagent_version')" != "1.0.1" ]]; then
  printf 'Use the pinned kagent CLI v1.0.1 to uninstall this runtime.\n' >&2
  exit 1
fi
byo_record="$(kubectl get configmap kagent-byo-ownership -n "$namespace" \
  --ignore-not-found -o json)"
if [[ -n "$byo_record" ]]; then
  printf 'Removing the owned BYO add-on and tracked Sessions before uninstalling the shared runtime.\n'
  "$script_dir/uninstall-kagent-byo.sh"
fi
gateway_namespace="$(jq -r '.data["gateway-namespace"]' <<<"$record")"
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    if ! kagent_demo_checkpoint "$namespace" "$gateway_namespace" cleanup-failed cleanup; then
      printf 'Could not checkpoint interrupted cleanup; review ownership before retrying.\n' >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
kagent uninstall --namespace "$namespace" --delete-worker-pools

for namespace_to_remove in ate-system podcertificate-controller-system; do
  if kubectl get namespace "$namespace_to_remove" --ignore-not-found -o name |
    grep -q .; then
    printf 'kagent uninstall left runtime namespace %s; refusing to delete it implicitly.\n' \
      "$namespace_to_remove" >&2
    exit 1
  fi
done
if kubectl get crds -o json | jq -e --argjson groups \
  "$(printf '%s\n' "${kagent_demo_api_groups[@]}" | jq -R . | jq -s .)" '
    any(.items[]; .spec.group as $group | $groups | index($group) != null)' >/dev/null; then
  printf 'kagent uninstall left kagent/Substrate CRDs; ownership record retained for investigation.\n' >&2
  exit 1
fi

for secret in kagent-mcp-bob kagent-mcp-alice; do
  kagent_demo_owner_check secret "$secret" "$namespace"
  kubectl delete secret "$secret" -n "$namespace" --ignore-not-found
done
kagent_demo_owner_check service kagent-model-gateway "$namespace"
kubectl delete service kagent-model-gateway -n "$namespace" --ignore-not-found
kagent_demo_checkpoint "$namespace" "$gateway_namespace" cleaned runtime-removed
printf 'PASS removed the owned kagent v1.0.1 and Substrate v1.0.0 runtime. The %s namespace remains.\n' \
  "$namespace"
