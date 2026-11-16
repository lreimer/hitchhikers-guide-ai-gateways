#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/agentgateway-common.sh
source "$script_dir/agentgateway-common.sh"
# shellcheck source=scripts/agentgateway-mcp-common.sh
source "$script_dir/agentgateway-mcp-common.sh"

namespace="${AGENTGATEWAY_NAMESPACE:-${NAMESPACE:-agentgateway-demo}}"
agentgateway_require_commands kubectl jq
agentgateway_validate_namespace "$namespace"
if [[ -z "$(kubectl get namespace "$namespace" --ignore-not-found -o name)" ]]; then
  printf 'Namespace %s does not exist; nothing to remove.\n' "$namespace"
  exit 0
fi
# Check the whole set before deleting anything; never adopt another workload.
for resource in "${agentgateway_mcp_resources[@]}"; do
  read -r kind name <<<"$resource"
  agentgateway_mcp_check_ownership "$kind" "$name" "$namespace"
done
for resource in "${agentgateway_mcp_resources[@]}"; do
  read -r kind name <<<"$resource"
  kubectl delete "$kind" "$name" -n "$namespace" --ignore-not-found \
    --wait --timeout=120s
done
printf 'Removed only MCP-owned resources from %s. Controller, CRDs, base Gateway, LLM demo, namespace and local signing files were retained.\n' "$namespace"
