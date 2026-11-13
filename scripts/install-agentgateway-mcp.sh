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
python="${AGENTGATEWAY_MCP_PYTHON:-python3}"
key_directory="${AGENTGATEWAY_MCP_KEY_DIR:-}"
jwks_file="${AGENTGATEWAY_MCP_JWKS_FILE:-}"
if [[ -z "$jwks_file" && -n "${AGENTGATEWAY_MCP_KEY_DIR:-}" ]]; then
  jwks_file="$AGENTGATEWAY_MCP_KEY_DIR/jwks.json"
fi
agentgateway_mcp_prerequisites "$namespace"
agentgateway_require_commands "$python"
if [[ -z "$key_directory" ]]; then
  printf 'Set AGENTGATEWAY_MCP_KEY_DIR to an external private directory for signing credentials and bounded SDK readiness checks.\n' >&2
  exit 1
fi
if ! "$python" -c 'import mcp, jwt, cryptography' >/dev/null 2>&1; then
  printf 'Install gateways/agentgateway/mcp/requirements.txt in a virtual environment and set AGENTGATEWAY_MCP_PYTHON to its Python executable.\n' >&2
  exit 1
fi
if [[ -z "$image" || "$image" == *[[:space:]]* ]]; then
  printf 'AGENTGATEWAY_MCP_IMAGE must be a nonempty container image reference.\n' >&2
  exit 1
fi
policy_template="$(kubectl create --dry-run=client -n "$namespace" \
  -f "$root_dir/gateways/agentgateway/mcp/policy.yaml" -o json)"
"$python" "$root_dir/gateways/agentgateway/mcp/jwt_tool.py" generate \
  --directory "$key_directory" --lifetime 900 \
  --issuer "$(jq -r '.spec.traffic.jwtAuthentication.providers[0].issuer' <<<"$policy_template")" \
  --audience "$(jq -r '.spec.traffic.jwtAuthentication.providers[0].audiences[0]' <<<"$policy_template")"
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
if ! jq -e --argjson generated "$(jq . "$key_directory/jwks.json")" \
  '. == $generated' "$jwks_file" >/dev/null; then
  printf 'The supplied public JWKS must match the local signing directory used for readiness checks.\n' >&2
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
policy="$(jq --arg jwks "$(jq -c . "$jwks_file")" \
  '.spec.traffic.jwtAuthentication.providers[0].jwks.inline = $jwks' <<<"$policy_template")"
route="$(kubectl create --dry-run=client -n "$namespace" \
  -f "$root_dir/gateways/agentgateway/mcp/route.yaml" -o json)"
staging="$(kubectl create --dry-run=client -n "$namespace" \
  -f "$root_dir/gateways/agentgateway/mcp/staging.yaml" -o json)"
staged_route="$(jq -c '
  .spec.rules[0].backendRefs = [{name:"agentgateway-mcp-staging",port:8000}]' <<<"$route")"
for manifest in "$backends" "$backend" "$policy" "$route" "$staging" "$staged_route"; do
  kubectl apply --dry-run=server -n "$namespace" -f - <<<"$manifest" >/dev/null
done

installation_complete=false
route_changed=false
forward_pid=""
local_port=""
detach_route() {
  agentgateway_mcp_check_ownership httproute agentgateway-mcp "$namespace" || return 1
  kubectl delete httproute agentgateway-mcp -n "$namespace" \
    --ignore-not-found --timeout=30s >&2 || return 1
  "$python" "$root_dir/gateways/agentgateway/mcp/assertion_client.py" \
    --url "http://127.0.0.1:$local_port/mcp" --token-directory "$key_directory" \
    --phase detached --timeout-seconds 120 || return 1
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$installation_complete" != true && "$route_changed" == true ]]; then
    if ! detach_route; then
      printf 'MCP installation failed and live route detachment could not be verified. Review the MCP route before proceeding.\n' >&2
      status=1
    else
      printf 'MCP installation failed; route removal is verified by live HTTP 404. Fix the error and rerun installation or uninstall the add-on.\n' >&2
    fi
  fi
  if [[ -n "$forward_pid" ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep readiness local and avoid on-disk logs or bearer credentials.
coproc MCP_FORWARD {
  exec kubectl port-forward -n "$namespace" --address 127.0.0.1 \
    service/agentgateway-proxy :80 2>&1
}
forward_pid="${MCP_FORWARD_PID:-}"
forward_fd="${MCP_FORWARD[0]:-}"
if [[ -z "$forward_pid" || -z "$forward_fd" ]]; then
  printf 'The private MCP readiness port-forward could not be started.\n' >&2
  exit 1
fi
for ((attempt = 0; attempt < 30; attempt++)); do
  if IFS= read -r -t 2 -u "$forward_fd" line; then
    if [[ "$line" =~ ^Forwarding\ from\ 127\.0\.0\.1:([0-9]+) ]]; then
      local_port="${BASH_REMATCH[1]}"
      break
    fi
  fi
  if ! kill -0 "$forward_pid" 2>/dev/null; then
    printf 'The private MCP readiness port-forward exited before becoming ready.\n' >&2
    exit 1
  fi
done
if [[ -z "$local_port" ]]; then
  printf 'Timed out starting the private MCP readiness port-forward.\n' >&2
  exit 1
fi

# API deletion alone cannot rule out a stale route in the running proxy.
route_changed=true
detach_route
kubectl apply -n "$namespace" -f - <<<"$staging"
if ! kubectl get endpointslices -n "$namespace" \
  -l kubernetes.io/service-name=agentgateway-mcp-staging -o json |
  jq -e 'all(.items[]; (.endpoints | length) == 0)' >/dev/null; then
  printf 'Staging Service unexpectedly has endpoints; refusing to expose MCP.\n' >&2
  exit 1
fi
kubectl apply -n "$namespace" -f - <<<"$policy"
kubectl apply -n "$namespace" -f - <<<"$staged_route"
generation="$(kubectl get agentgatewaypolicy agentgateway-mcp -n "$namespace" -o jsonpath='{.metadata.generation}')"
agentgateway_mcp_wait_policy "$namespace" "$generation"
agentgateway_mcp_wait_route "$namespace"
"$python" "$root_dir/gateways/agentgateway/mcp/assertion_client.py" \
  --url "http://127.0.0.1:$local_port/mcp" --token-directory "$key_directory" \
  --phase staged --timeout-seconds 120

# Only promote the route once the live proxy demonstrably authenticates it.
kubectl apply -n "$namespace" -f - <<<"$backends"
kubectl apply -n "$namespace" -f - <<<"$backend"
kubectl apply -n "$namespace" -f - <<<"$route"
agentgateway_mcp_wait_ready "$namespace"
"$python" "$root_dir/gateways/agentgateway/mcp/assertion_client.py" \
  --url "http://127.0.0.1:$local_port/mcp" --token-directory "$key_directory" \
  --phase ready --timeout-seconds 120
"$python" "$root_dir/gateways/agentgateway/mcp/assertion_client.py" \
  --url "http://127.0.0.1:$local_port/mcp" --token-directory "$key_directory" \
  --phase auth --timeout-seconds 120
installation_complete=true
printf 'MCP add-on ready in %s. Loaded local image: %s. Reuse make agentgateway-port-forward, then make agentgateway-mcp-demo; client endpoint is /mcp.\n' "$namespace" "$image"
