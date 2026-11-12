#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/agentgateway-common.sh
source "$script_dir/agentgateway-common.sh"

namespace="${AGENTGATEWAY_NAMESPACE:-agentgateway-demo}"
agentgateway_require_commands kubectl helm jq
agentgateway_validate_namespace "$namespace"

delete_owned_resource() {
  local resource="$1"
  local name="$2"
  local resource_json

  resource_json="$(kubectl get "$resource" "$name" --namespace "$namespace" \
    --ignore-not-found -o json)"
  if [[ -z "$resource_json" ]]; then
    return 0
  fi
  if [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$resource_json")" != "agentgateway-demo" ]]; then
    printf 'Refusing to delete unowned %s/%s in namespace %s.\n' \
      "$resource" "$name" "$namespace" >&2
    return 1
  fi
  kubectl delete "$resource" "$name" --namespace "$namespace" \
    --wait --timeout=120s
}

state_json="$(kubectl get configmap agentgateway-demo-state --namespace "$namespace" \
  --ignore-not-found -o json)"
if [[ -z "$state_json" ]]; then
  printf 'No tracked agentgateway demo installation in namespace %s; no resources were removed.\n' \
    "$namespace"
  exit 0
fi
controller_owned=false
if [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$state_json")" != "agentgateway-demo" ]]; then
  printf 'Refusing to use an unowned agentgateway-demo-state ConfigMap in namespace %s.\n' \
    "$namespace" >&2
  exit 1
fi
controller_owned="$(jq -r '.data["controller-owned"] // "false"' <<<"$state_json")"

delete_owned_resource gateway agentgateway-proxy
delete_owned_resource httproute agentgateway-llm
delete_owned_resource agentgatewaypolicy agentgateway-demo
delete_owned_resource agentgatewaybackend agentgateway-llm
delete_owned_resource agentgatewayparameters agentgateway-demo
delete_owned_resource configmap agentgateway-api-keys
delete_owned_resource secret agentgateway-openai-provider
delete_owned_resource deployment agentgateway-httpbun
delete_owned_resource service agentgateway-httpbun

if [[ "$controller_owned" == true ]]; then
  other_gateways="$(kubectl get gateways.gateway.networking.k8s.io --all-namespaces -o json |
    jq --arg namespace "$namespace" '[.items[] | select(.metadata.namespace != $namespace or .metadata.name != "agentgateway-proxy")] | length')"
  other_agentgateway_objects="$(kubectl get agentgatewaypolicies.agentgateway.dev,agentgatewaybackends.agentgateway.dev,agentgatewayparameters.agentgateway.dev,agentgatewaymodels.agentgateway.dev --all-namespaces -o json |
    jq --arg namespace "$namespace" '[.items[] | select(.metadata.namespace != $namespace or .metadata.labels["app.kubernetes.io/managed-by"] != "agentgateway-demo")] | length')"
  if (( other_gateways == 0 && other_agentgateway_objects == 0 )); then
    helm uninstall agentgateway --namespace "$agentgateway_system_namespace" --wait --timeout 5m
    gateway_class="$(kubectl get gatewayclass agentgateway --ignore-not-found -o json)"
    if [[ -n "$gateway_class" &&
      "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$gateway_class")" == "agentgateway-demo" &&
      "$(jq -r '.spec.controllerName // ""' <<<"$gateway_class")" == "agentgateway.dev/agentgateway" ]]; then
      kubectl delete gatewayclass agentgateway --wait --timeout=120s
    fi
    printf 'Removed the agentgateway controller release installed by this demo.\n'
  else
    printf 'Retained the demo-installed agentgateway controller because other agentgateway resources still exist in the cluster.\n'
  fi
fi

delete_owned_resource configmap agentgateway-demo-state

printf 'Removed agentgateway demo resources from namespace %s; the namespace and shared CRDs were retained.\n' \
  "$namespace"
