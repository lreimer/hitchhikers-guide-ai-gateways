#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kagent-common.sh
source "$script_dir/kagent-common.sh"

namespace="${KAGENT_NAMESPACE:-kagent}"
kagent_demo_require_commands kubectl jq
kagent_demo_require_context
kagent_demo_validate_namespace "$namespace"

services="$(kubectl get services -n "$namespace" -o json)"
service="$(jq -r '[.items[] | select(any(.spec.ports[]?; .port == 8080)) |
  .metadata.name] | if length == 1 then .[0] else empty end' <<<"$services")"
if [[ -z "$service" ]]; then
  printf 'Expected exactly one kagent UI Service exposing port 8080 in %s.\n' "$namespace" >&2
  exit 1
fi
kubectl port-forward --address 127.0.0.1 -n "$namespace" "service/$service" 8081:8080
