#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
# shellcheck source=scripts/agentgateway-common.sh
source "$script_dir/agentgateway-common.sh"
# shellcheck source=scripts/agentgateway-mcp-common.sh
source "$script_dir/agentgateway-mcp-common.sh"
# shellcheck source=scripts/kagent-common.sh
source "$script_dir/kagent-common.sh"

namespace="${KAGENT_NAMESPACE:-kagent}"
gateway_namespace="${AGENTGATEWAY_NAMESPACE:-${NAMESPACE:-agentgateway-demo}}"
python="${AGENTGATEWAY_MCP_PYTHON:-python3}"
key_directory="${AGENTGATEWAY_MCP_KEY_DIR:-}"

kagent_demo_require_commands kubectl helm jq openssl kagent "$python"
kagent_demo_require_context
kagent_demo_require_helm
kagent_demo_validate_namespace "$namespace"
agentgateway_validate_namespace "$gateway_namespace"
if [[ "$(kagent version | jq -r '.kagent_version')" != "1.0.1" ]]; then
  printf 'This demo requires the pinned kagent CLI v1.0.1.\n' >&2
  exit 1
fi

if [[ -z "${AGENTGATEWAY_BOB_KEY:-}" ]]; then
  printf 'Set AGENTGATEWAY_BOB_KEY to the stable Bob gateway client key from the existing agentgateway demo.\n' >&2
  exit 1
fi
agentgateway_validate_client_key AGENTGATEWAY_BOB_KEY "$AGENTGATEWAY_BOB_KEY"
if [[ -z "$key_directory" ]]; then
  printf 'Set AGENTGATEWAY_MCP_KEY_DIR to the external private signing directory used by the MCP add-on.\n' >&2
  exit 1
fi
if ! "$python" -c 'import cryptography, jwt; from mcp import Client' >/dev/null 2>&1; then
  printf 'MCP Python dependencies are missing. Run "uv sync --project gateways/agentgateway/mcp --locked" and set AGENTGATEWAY_MCP_PYTHON.\n' >&2
  exit 1
fi

agentgateway_mcp_prerequisites "$gateway_namespace"
kagent_demo_verify_mcp_policy "$root_dir" "$gateway_namespace"
reuse_runtime=false
record="$(kubectl get configmap kagent-demo-ownership -n "$namespace" --ignore-not-found -o json)"
if [[ -n "$record" ]]; then
  kagent_demo_verify_installation "$namespace" "$record"
  if [[ "$(jq -r '.data["gateway-namespace"]' <<<"$record")" != "$gateway_namespace" ]]; then
    printf 'The recorded gateway namespace differs; use the original AGENTGATEWAY_NAMESPACE.\n' >&2
    exit 1
  fi
  case "$(jq -r '.data.phase' <<<"$record")" in
    ready) reuse_runtime=true ;;
    cleaned) ;;
    *)
      printf 'An incomplete installation is recorded. Run make kagent-uninstall with the same context and namespace, then retry installation.\n' >&2
      exit 1
      ;;
  esac
else
  kagent_demo_check_fresh_install "$namespace"
fi

gateway_state="$(kubectl get configmap agentgateway-demo-state -n "$gateway_namespace" -o json)"
if [[ "$(jq -r '.data["agentgateway-version"]' <<<"$gateway_state")" != "v1.7.0" ]]; then
  printf 'The kagent demo requires the pinned agentgateway v1.7.0 base demo.\n' >&2
  exit 1
fi
model="$(jq -r '.data.model' <<<"$gateway_state")"
backend_mode="$(jq -r '.data["backend-mode"]' <<<"$gateway_state")"
if [[ "$backend_mode" != mock && "$backend_mode" != openai ]]; then
  printf 'The installed agentgateway backend mode is invalid; expected mock or openai.\n' >&2
  exit 1
fi
if [[ ! "$model" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'The installed agentgateway model name is not safe for the kagent ModelConfig.\n' >&2
  exit 1
fi
if [[ "$(kubectl get configmap agentgateway-api-keys -n "$gateway_namespace" -o json |
  jq -r 'try (.data.bob | fromjson | .keyHash) catch ""')" != "$(agentgateway_hash_key "$AGENTGATEWAY_BOB_KEY")" ]]; then
  printf 'AGENTGATEWAY_BOB_KEY does not match the installed Bob client-key hash.\n' >&2
  exit 1
fi

policy="$(kubectl get agentgatewaypolicy agentgateway-mcp -n "$gateway_namespace" -o json)"
issuer="$(jq -r '.spec.traffic.jwtAuthentication.providers[0].issuer' <<<"$policy")"
audience="$(jq -r '.spec.traffic.jwtAuthentication.providers[0].audiences[0]' <<<"$policy")"
"$python" "$root_dir/gateways/agentgateway/mcp/jwt_tool.py" generate \
  --directory "$key_directory" --issuer "$issuer" --audience "$audience" --lifetime 900
if ! jq -e --argjson expected "$(jq \
  '.spec.traffic.jwtAuthentication.providers[0].jwks.inline | fromjson' <<<"$policy")" \
  '. == $expected' "$key_directory/jwks.json" >/dev/null; then
  printf 'The local JWT signing key differs from the JWKS installed in the MCP policy.\n' >&2
  exit 1
fi

for resource in \
  "secret kagent-mcp-bob $namespace" \
  "secret kagent-mcp-alice $namespace" \
  "service kagent-model-gateway $namespace"; do
  read -r kind name resource_namespace <<<"$resource"
  kagent_demo_owner_check "$kind" "$name" "$resource_namespace"
done

install_dir="$(mktemp -d "${TMPDIR:-/tmp}/kagent-demo-install.XXXXXX")"
checkpoint_enabled=false
completed_step=preflight
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$checkpoint_enabled" == true && "$status" -ne 0 ]]; then
    if ! kagent_demo_checkpoint "$namespace" "$gateway_namespace" failed "$completed_step"; then
      printf 'Could not checkpoint the partial installation; ownership checks will require manual review before cleanup.\n' >&2
    fi
  fi
  rm -f "$install_dir/install-config.yaml" "$install_dir/install-values.yaml"
  rmdir "$install_dir" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sed \
  -e "s/__MODEL__/$model/g" \
  -e "s/__KAGENT_NAMESPACE__/$namespace/g" \
  -e "s/__AGENTGATEWAY_NAMESPACE__/$gateway_namespace/g" \
  "$root_dir/agents/kagent/install-values.yaml" > "$install_dir/install-values.yaml"
printf 'install:\n  kagent:\n    valuesFiles:\n      - %s\n' \
  "$install_dir/install-values.yaml" > "$install_dir/install-config.yaml"

kagent_demo_prepare_namespace "$namespace"
kagent_demo_checkpoint "$namespace" "$gateway_namespace" installing namespace
checkpoint_enabled=true
completed_step=namespace
for runtime_namespace in ate-system podcertificate-controller-system; do
  kagent_demo_prepare_namespace "$runtime_namespace"
done
kagent_demo_checkpoint "$namespace" "$gateway_namespace" installing namespaces
completed_step=namespaces

if [[ "$reuse_runtime" != true ]]; then
  OPENAI_API_KEY="$AGENTGATEWAY_BOB_KEY" \
    kagent install --config "$install_dir/install-config.yaml" \
    --provider OpenAI --namespace "$namespace"
fi

kagent_demo_capture_releases "$namespace" >/dev/null
completed_step=runtime
kagent_demo_checkpoint "$namespace" "$gateway_namespace" installing "$completed_step"

sed "s/__AGENTGATEWAY_NAMESPACE__/$gateway_namespace/g" \
  "$root_dir/agents/kagent/model-gateway.yaml" |
  kubectl apply --namespace "$namespace" -f -

for identity in bob alice; do
  printf 'Bearer %s' "$(cat "$key_directory/$identity.jwt")" |
    kubectl create secret generic "kagent-mcp-$identity" \
      -n "$namespace" --from-file=authorization=/dev/stdin \
      --dry-run=client -o yaml |
    kubectl label --local -f - "$kagent_demo_managed_by" --overwrite -o yaml |
    kubectl apply -f -
done
completed_step=credentials
kagent_demo_checkpoint "$namespace" "$gateway_namespace" installing "$completed_step"

for manifest in \
  "$root_dir/agents/kagent/harness.yaml" \
  "$root_dir/agents/kagent/remote-mcp-servers.yaml" \
  "$root_dir/agents/kagent/agent-templates.yaml" \
  "$root_dir/agents/kagent/agents.yaml"; do
  sed "s/__AGENTGATEWAY_NAMESPACE__/$gateway_namespace/g" "$manifest" |
    kubectl apply --namespace "$namespace" -f -
done
completed_step=agents
kagent_demo_checkpoint "$namespace" "$gateway_namespace" installing "$completed_step"

kubectl rollout status deployment/kagent-controller -n "$namespace" --timeout=5m
kubectl wait --for=condition=Accepted --timeout=2m \
  "remotemcpservers.api.kagent.dev/product-catalog-bob" \
  "remotemcpservers.api.kagent.dev/product-support-alice" \
  -n "$namespace"
kubectl wait --for=condition=Ready --timeout=10m \
  "agents.api.kagent.dev/product-quote-assistant" \
  "agents.api.kagent.dev/internal-product-support-assistant" \
  -n "$namespace"
kagent_demo_checkpoint "$namespace" "$gateway_namespace" ready agents-ready
checkpoint_enabled=false
printf 'PASS kagent v1.0.1 and declarative agents installed in namespace %s on context %s. Agentgateway backend mode: %s.\n' \
  "$namespace" "$(kubectl config current-context)" "$backend_mode"
