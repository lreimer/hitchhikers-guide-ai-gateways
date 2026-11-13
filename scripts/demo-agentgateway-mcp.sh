#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
# shellcheck source=scripts/agentgateway-common.sh
source "$script_dir/agentgateway-common.sh"
# shellcheck source=scripts/agentgateway-mcp-common.sh
source "$script_dir/agentgateway-mcp-common.sh"

namespace="${AGENTGATEWAY_NAMESPACE:-${NAMESPACE:-agentgateway-demo}}"
url="${AGENTGATEWAY_URL:-http://127.0.0.1:8080}"
url="${url%/}/mcp"
python="${AGENTGATEWAY_MCP_PYTHON:-python3}"
key_directory="${AGENTGATEWAY_MCP_KEY_DIR:-}"
agentgateway_mcp_prerequisites "$namespace"
agentgateway_require_commands "$python" openssl
if [[ -z "$key_directory" ]]; then
  printf 'Set AGENTGATEWAY_MCP_KEY_DIR to the external, private signing directory used during installation.\n' >&2
  exit 1
fi
if ! "$python" -c 'import mcp, jwt, cryptography' >/dev/null 2>&1; then
  printf 'MCP Python dependencies are missing. Install gateways/agentgateway/mcp/requirements.txt in a virtual environment and set AGENTGATEWAY_MCP_PYTHON to its Python executable.\n' >&2
  exit 1
fi
for resource in "${agentgateway_mcp_resources[@]}"; do
  read -r kind name <<<"$resource"
  agentgateway_mcp_check_ownership "$kind" "$name" "$namespace"
done
agentgateway_mcp_wait_ready "$namespace"
original="$(kubectl get agentgatewaypolicy agentgateway-mcp -n "$namespace" -o json)"
issuer="$(jq -r '.spec.traffic.jwtAuthentication.providers[0].issuer' <<<"$original")"
audience="$(jq -r '.spec.traffic.jwtAuthentication.providers[0].audiences[0]' <<<"$original")"
"$python" "$root_dir/gateways/agentgateway/mcp/jwt_tool.py" generate \
  --directory "$key_directory" --issuer "$issuer" --audience "$audience" --lifetime 900
if ! jq -e --argjson expected "$(jq \
  '.spec.traffic.jwtAuthentication.providers[0].jwks.inline | fromjson' <<<"$original")" \
  '. == $expected' "$key_directory/jwks.json" >/dev/null; then
  printf 'Local signing key differs from the installed public JWKS. Reinstall the MCP add-on with this directory before running the demo.\n' >&2
  exit 1
fi

original_spec="$(jq -c '.spec' <<<"$original")"
current_spec="$original_spec"
policy_changed=false
apply_spec() {
  local next="$1" generation
  # Never overwrite a concurrent user's policy change.
  kubectl patch agentgatewaypolicy agentgateway-mcp -n "$namespace" --type=json \
    --patch "$(jq -nc --argjson current "$current_spec" --argjson next "$next" '
      [{op:"test",path:"/spec",value:$current},
       {op:"replace",path:"/spec",value:$next}]')" >/dev/null || return 1
  current_spec="$next"
  policy_changed=true
  generation="$(kubectl get agentgatewaypolicy agentgateway-mcp -n "$namespace" -o jsonpath='{.metadata.generation}')" || return 1
  agentgateway_mcp_wait_policy "$namespace" "$generation" || return 1
}
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$policy_changed" == true ]]; then
    if ! apply_spec "$original_spec"; then
      printf 'Could not restore the original MCP policy (possibly changed concurrently). Review agentgatewaypolicy/agentgateway-mcp; no LLM or Gateway policy was modified.\n' >&2
      status=1
    else
      printf 'Restored original MCP policy settings.\n'
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

auth_spec="$(jq -c 'del(.traffic.rateLimit)' <<<"$original_spec")"
if [[ "$auth_spec" != "$current_spec" ]]; then
  apply_spec "$auth_spec"
fi
"$python" "$root_dir/gateways/agentgateway/mcp/assertion_client.py" \
  --url "$url" --token-directory "$key_directory" --phase auth

# The only quota is installed in a separate assertion phase on the SAME policy.
# A new bucket namespace avoids previous runs consuming this run's allowance.
phase="$(openssl rand -hex 12)"
rate_spec="$(jq -c --arg key "jwt.sub + \"-mcp-$phase\"" '
  .traffic.rateLimit = {local:[{requests:1,unit:"Seconds",burst:30,key:$key}]}' <<<"$auth_spec")"
apply_spec "$rate_spec"
"$python" "$root_dir/gateways/agentgateway/mcp/assertion_client.py" \
  --url "$url" --token-directory "$key_directory" --phase rate \
  --rate-capacity 30 --rate-window-seconds 30
apply_spec "$original_spec"
policy_changed=false
printf 'PASS MCP walkthrough; original policy restored. No LLM credentials or inference calls were used.\n'
