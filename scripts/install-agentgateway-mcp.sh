#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
# shellcheck source=scripts/agentgateway-common.sh
source "$script_dir/agentgateway-common.sh"
# shellcheck source=scripts/agentgateway-mcp-common.sh
source "$script_dir/agentgateway-mcp-common.sh"

namespace="${AGENTGATEWAY_NAMESPACE:-${NAMESPACE:-agentgateway-demo}}"
image="${AGENTGATEWAY_MCP_IMAGE:-agentgateway-mcp:demo}"
jwks_file="${AGENTGATEWAY_MCP_JWKS_FILE:-}"
if [[ -z "$jwks_file" && -n "${AGENTGATEWAY_MCP_KEY_DIR:-}" ]]; then
  jwks_file="$AGENTGATEWAY_MCP_KEY_DIR/jwks.json"
fi
agentgateway_mcp_prerequisites "$namespace"
if [[ -z "$image" || "$image" == *[[:space:]]* ]]; then
  printf 'AGENTGATEWAY_MCP_IMAGE must be a nonempty container image reference.\n' >&2
  exit 1
fi
if [[ ! -f "$jwks_file" ]] || ! jq -e '
  .keys | type == "array" and length > 0 and
  all(.[];
    .kty == "RSA" and .alg == "RS256" and .use == "sig" and
    (.kid | type == "string" and length > 0) and
    (.n | type == "string" and length > 0) and
    (.e | type == "string" and length > 0) and
    (has("d") or has("p") or has("q") or has("dp") or has("dq") or has("qi") | not))' "$jwks_file" >/dev/null; then
  printf 'Provide a public-only RSA/RS256 JWKS through AGENTGATEWAY_MCP_KEY_DIR/jwks.json or AGENTGATEWAY_MCP_JWKS_FILE. Generate local signing material using the JWT helper first.\n' >&2
  exit 1
fi
for resource in "${agentgateway_mcp_resources[@]}"; do
  read -r kind name <<<"$resource"
  agentgateway_mcp_check_ownership "$kind" "$name" "$namespace"
done

# Build JSON with the installed APIs, then validate all specs before mutating.
backends="$(kubectl create --dry-run=client -n "$namespace" \
  -f "$root_dir/gateways/agentgateway/mcp/backends.yaml" -o json |
  jq -s --arg image "$image" '
    {apiVersion:"v1",kind:"List",items:map(
      if .kind == "Deployment" then
        .spec.template.spec.containers[0].image = $image else . end)}')"
backend="$(kubectl create --dry-run=client -n "$namespace" \
  -f "$root_dir/gateways/agentgateway/mcp/backend.yaml" -o json)"
policy="$(kubectl create --dry-run=client -n "$namespace" \
  -f "$root_dir/gateways/agentgateway/mcp/policy.yaml" -o json |
  jq --arg jwks "$(jq -c . "$jwks_file")" \
    '.spec.traffic.jwtAuthentication.providers[0].jwks.inline = $jwks')"
route="$(kubectl create --dry-run=client -n "$namespace" \
  -f "$root_dir/gateways/agentgateway/mcp/route.yaml" -o json)"
for manifest in "$backends" "$backend" "$policy" "$route"; do
  kubectl apply --dry-run=server -n "$namespace" -f - <<<"$manifest" >/dev/null
done

# Remove only the owned MCP route during credential/policy changes: fail closed.
kubectl delete httproute agentgateway-mcp -n "$namespace" --ignore-not-found --timeout=30s
installation_complete=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$installation_complete" != true ]]; then
    kubectl delete httproute agentgateway-mcp -n "$namespace" \
      --ignore-not-found --timeout=30s >&2 || true
    printf 'MCP installation did not complete; its route is detached. Fix the error and rerun installation or uninstall the add-on.\n' >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kubectl apply -n "$namespace" -f - <<<"$backends"
kubectl apply -n "$namespace" -f - <<<"$backend"
kubectl apply -n "$namespace" -f - <<<"$policy"
kubectl apply -n "$namespace" -f - <<<"$route"
agentgateway_mcp_wait_ready "$namespace"
installation_complete=true
printf 'MCP add-on ready in %s. Loaded local image: %s. Reuse make agentgateway-port-forward, then make agentgateway-mcp-demo; client endpoint is /mcp.\n' "$namespace" "$image"
