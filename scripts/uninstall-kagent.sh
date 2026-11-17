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
if [[ -z "$record" ]] ||
  [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$record")" != "kagent-demo" ]]; then
  printf 'No kagent-demo ownership record found in %s; refusing to remove runtime resources.\n' \
    "$namespace" >&2
  exit 1
fi
if [[ "$(jq -r '.data["kagent-version"]' <<<"$record")" != 1.0.1 ]]; then
  printf 'The kagent ownership record does not match the pinned v1.0.1 installation.\n' >&2
  exit 1
fi
kagent_demo_verify_recorded_context "$record"

releases="$(jq -r '.data.releases' <<<"$record")"
crds="$(jq -r '.data.crds' <<<"$record")"
inventory="$(jq -r '.data.inventory // empty' <<<"$record")"
custom_resources="$(jq -r '.data["custom-resources"] // empty' <<<"$record")"
kagent_demo_verify_recorded_releases "$namespace" "$releases"
kagent_demo_verify_recorded_crds "$crds"
kagent_demo_verify_inventory "$namespace" "$inventory"
kagent_demo_check_pod_ownership "$namespace"
kagent_demo_verify_custom_resources "$custom_resources"

if [[ "$(kagent version | jq -r '.kagent_version')" != "1.0.1" ]]; then
  printf 'Use the pinned kagent CLI v1.0.1 to uninstall this runtime.\n' >&2
  exit 1
fi
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
kubectl delete configmap kagent-demo-ownership -n "$namespace"
printf 'PASS removed the owned kagent v1.0.1 and Substrate v1.0.0 runtime. The %s namespace remains.\n' \
  "$namespace"
