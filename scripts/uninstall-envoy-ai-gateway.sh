#!/usr/bin/env bash
set -euo pipefail

app_namespace="${ENVOY_AI_GATEWAY_NAMESPACE:-envoy-ai-gateway-demo}"
gateway_namespace="${ENVOY_GATEWAY_NAMESPACE:-envoy-gateway-system}"
controller_namespace="${ENVOY_AI_GATEWAY_SYSTEM_NAMESPACE:-envoy-ai-gateway-system}"
owner="envoy-ai-gateway-demo"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command in kubectl helm sed; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  }
done

for namespace in "$app_namespace" "$gateway_namespace" "$controller_namespace"; do
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    manager="$(kubectl get namespace "$namespace" \
      -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')"
    if [[ "$manager" != "$owner" ]]; then
      printf 'Refusing to uninstall: namespace %s is not owned by this demo.\n' "$namespace" >&2
      exit 1
    fi
  fi
done

if kubectl get gatewayclass envoy-ai-gateway-demo >/dev/null 2>&1; then
  manager="$(kubectl get gatewayclass envoy-ai-gateway-demo \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')"
  if [[ "$manager" != "$owner" ]]; then
    printf 'Refusing to delete GatewayClass envoy-ai-gateway-demo; it is not owned by this demo.\n' >&2
    exit 1
  fi
fi

if kubectl get namespace "$app_namespace" >/dev/null 2>&1; then
  openai_manifest="$(mktemp)"
  sed \
    -e "s/@@ENVOY_AI_GATEWAY_NAMESPACE@@/$app_namespace/g" \
    -e 's/__OPENAI_MODEL__/gpt-4o-mini/g' \
    "$root_dir/gateways/envoy-ai-gateway/openai-route.yaml.in" > "$openai_manifest"
  kubectl delete -f "$openai_manifest" --ignore-not-found
  rm -f "$openai_manifest"
  kubectl delete aigatewayroute/envoy-ai-gateway-mock backendtrafficpolicy/envoy-ai-gateway-token-limit \
    --namespace "$app_namespace" --ignore-not-found
  kubectl delete -f <(sed "s/@@ENVOY_AI_GATEWAY_NAMESPACE@@/$app_namespace/g" \
    "$root_dir/gateways/envoy-ai-gateway/mock-backend.yaml") --ignore-not-found
  kubectl delete securitypolicy/envoy-ai-gateway-client-key \
    --namespace "$app_namespace" --ignore-not-found
  kubectl delete gateway/envoy-ai-gateway-demo envoyproxy/envoy-ai-gateway-demo \
    --namespace "$app_namespace" --ignore-not-found
  kubectl delete gatewayclass/envoy-ai-gateway-demo --ignore-not-found
  kubectl delete configmap envoy-ai-gateway-mock envoy-ai-gateway-install \
    --namespace "$app_namespace" --ignore-not-found
  kubectl delete secret envoy-ai-gateway-client-keys envoy-ai-gateway-openai-key \
    --namespace "$app_namespace" --ignore-not-found
fi

if kubectl get namespace "$gateway_namespace" >/dev/null 2>&1; then
  kubectl delete deployment/redis service/redis --namespace "$gateway_namespace" --ignore-not-found
fi

for release in "ai-gateway:$controller_namespace" "ai-gateway-crds:$controller_namespace" "eg:$gateway_namespace"; do
  name="${release%%:*}"
  namespace="${release#*:}"
  if helm status "$name" --namespace "$namespace" >/dev/null 2>&1; then
    helm uninstall "$name" --namespace "$namespace"
  fi
done

printf '\nEnvoy AI Gateway demo resources, credentials, Redis, and Helm releases were removed.\n'
printf 'Demo namespaces and cluster-scoped Gateway API / Envoy Gateway / AI Gateway CRDs were retained.\n'
