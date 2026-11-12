#!/usr/bin/env bash
set -euo pipefail

namespace="${ENVOY_AI_GATEWAY_NAMESPACE:-envoy-ai-gateway-demo}"
gateway_name="envoy-ai-gateway-demo"

command -v kubectl >/dev/null 2>&1 || {
  printf 'Required command not found: kubectl\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'Required command not found: python3\n' >&2
  exit 1
}

service=""
deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
  service="$(kubectl get services --namespace "$namespace" -o json |
    python3 -c '
import json,sys
items=json.load(sys.stdin)["items"]
matches=[]
for item in items:
    labels=item["metadata"].get("labels", {})
    if labels.get("gateway.envoyproxy.io/owning-gateway-name") != sys.argv[1]:
        continue
    if labels.get("gateway.envoyproxy.io/owning-gateway-namespace") != sys.argv[2]:
        continue
    if item["spec"].get("type") != "ClusterIP":
        raise SystemExit(f"Data-plane Service {item['metadata']['name']} is not ClusterIP-only")
    if any(port.get("port") == 80 for port in item["spec"].get("ports", [])):
        matches.append(item["metadata"]["name"])
if len(matches) > 1:
    raise SystemExit(f"Expected one data-plane Service for Gateway, found: {matches}")
print(matches[0] if matches else "")
' "$gateway_name" "$namespace")"
  [[ -n "$service" ]] && break
  sleep 2
done

if [[ -z "$service" ]]; then
  printf 'Could not discover the data-plane Service for Gateway %s/%s within 120 seconds.\n' \
    "$namespace" "$gateway_name" >&2
  kubectl get gateway "$gateway_name" --namespace "$namespace" -o yaml >&2 || true
  kubectl get services --namespace "$namespace" --show-labels >&2 || true
  exit 1
fi

printf 'Forwarding Gateway %s/%s through Service %s to 127.0.0.1:8080.\n' \
  "$namespace" "$gateway_name" "$service"
exec kubectl port-forward --address 127.0.0.1 \
  --namespace "$namespace" "service/$service" 8080:80
