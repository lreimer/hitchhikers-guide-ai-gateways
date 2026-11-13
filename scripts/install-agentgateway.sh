#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
# shellcheck source=scripts/agentgateway-common.sh
source "$script_dir/agentgateway-common.sh"

namespace="${AGENTGATEWAY_NAMESPACE:-agentgateway-demo}"
mode="${AGENTGATEWAY_MODE:-mock}"
model="${AGENTGATEWAY_MODEL:-gpt-4o-mini}"
gateway_api_version="1.6.3"
agentgateway_version="v1.7.0"
alice_key="${AGENTGATEWAY_ALICE_KEY:-}"
bob_key="${AGENTGATEWAY_BOB_KEY:-}"
rotate_client_keys="${AGENTGATEWAY_ROTATE_CLIENT_KEYS:-false}"

agentgateway_require_commands kubectl helm jq openssl awk curl
agentgateway_validate_namespace "$namespace"
agentgateway_validate_client_key AGENTGATEWAY_ALICE_KEY "$alice_key"
agentgateway_validate_client_key AGENTGATEWAY_BOB_KEY "$bob_key"
if [[ "$rotate_client_keys" != true && "$rotate_client_keys" != false ]]; then
  printf 'AGENTGATEWAY_ROTATE_CLIENT_KEYS must be either true or false.\n' >&2
  exit 1
fi

if [[ "$mode" != "mock" && "$mode" != "openai" ]]; then
  printf 'AGENTGATEWAY_MODE must be either mock or openai.\n' >&2
  exit 1
fi

if [[ ! "$model" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
  printf 'AGENTGATEWAY_MODEL must contain only letters, digits, dot, underscore, or hyphen.\n' >&2
  exit 1
fi

if [[ "$mode" == "openai" ]]; then
  agentgateway_validate_provider_key "${OPENAI_API_KEY:-}"
fi

server_version="$(kubectl version -o json | jq -r '.serverVersion.gitVersion')"
if [[ ! "$server_version" =~ ^v1\.([0-9]+)\. ]]; then
  printf 'Could not determine Kubernetes server version: %s\n' "$server_version" >&2
  exit 1
fi
kubernetes_minor="${BASH_REMATCH[1]}"
if (( kubernetes_minor < 32 || kubernetes_minor > 37 )); then
  printf 'agentgateway %s supports Kubernetes 1.32-1.37; this cluster is %s.\n' \
    "$agentgateway_version" "$server_version" >&2
  exit 1
fi

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
state_json="$(kubectl get configmap agentgateway-demo-state --namespace "$namespace" \
  --ignore-not-found -o json)"
controller_owned=false
if [[ -n "$state_json" ]]; then
  if [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$state_json")" != "agentgateway-demo" ]]; then
    printf 'Refusing to overwrite an unowned agentgateway-demo-state ConfigMap in namespace %s.\n' \
      "$namespace" >&2
    exit 1
  fi
fi

agentgateway_assert_owned_or_absent configmap agentgateway-api-keys "$namespace"
agentgateway_check_client_keys "$namespace" "$alice_key" "$bob_key" "$rotate_client_keys"

gateway_api_crds=(
  gatewayclasses.gateway.networking.k8s.io
  gateways.gateway.networking.k8s.io
  httproutes.gateway.networking.k8s.io
  referencegrants.gateway.networking.k8s.io
)
gateway_api_present=0
gateway_api_bundle=""
for crd in "${gateway_api_crds[@]}"; do
  crd_json="$(kubectl get crd "$crd" --ignore-not-found -o json)"
  if [[ -n "$crd_json" ]]; then
    ((gateway_api_present += 1))
    bundle="$(jq -r '.metadata.annotations["gateway.networking.k8s.io/bundle-version"] // ""' <<<"$crd_json")"
    channel="$(jq -r '.metadata.annotations["gateway.networking.k8s.io/channel"] // ""' <<<"$crd_json")"
    if [[ -z "$bundle" || "$channel" != "standard" ]]; then
      printf 'Existing Gateway API CRD %s has no recognized standard bundle version; refusing to modify it.\n' \
        "$crd" >&2
      exit 1
    fi
    if [[ -n "$gateway_api_bundle" && "$gateway_api_bundle" != "$bundle" ]]; then
      printf 'Gateway API CRDs have mixed bundle versions (%s and %s).\n' \
        "$gateway_api_bundle" "$bundle" >&2
      exit 1
    fi
    gateway_api_bundle="$bundle"
  fi
done

if (( gateway_api_present != 0 && gateway_api_present != ${#gateway_api_crds[@]} )); then
  printf 'Gateway API CRDs are only partially installed; repair them before installing this demo.\n' >&2
  exit 1
fi
if (( gateway_api_present == ${#gateway_api_crds[@]} )); then
  case "$gateway_api_bundle" in
    v1.4.*|v1.5.*|v1.6.*) ;;
    *)
      printf 'Gateway API %s is outside agentgateway %s support (1.4-1.6); refusing to replace shared CRDs.\n' \
        "$gateway_api_bundle" "$agentgateway_version" >&2
      exit 1
      ;;
  esac
  printf 'Reusing compatible Gateway API %s standard CRDs.\n' "$gateway_api_bundle"
else
  kubectl apply --server-side --request-timeout=30s \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${gateway_api_version}/standard-install.yaml"
  gateway_api_bundle="v$gateway_api_version"
fi

for crd in "${gateway_api_crds[@]}"; do
  kubectl wait --for=condition=Established --timeout=120s "crd/$crd"
done

agentgateway_crd_release="$(helm list --all-namespaces --filter '^agentgateway-crds$' --output json |
  jq -c '[.[] | select(.name == "agentgateway-crds")] | first // empty')"
if [[ -n "$agentgateway_crd_release" ]]; then
  crd_chart="$(jq -r '.chart' <<<"$agentgateway_crd_release")"
  crd_namespace="$(jq -r '.namespace' <<<"$agentgateway_crd_release")"
  crd_status="$(jq -r '.status' <<<"$agentgateway_crd_release")"
  if [[ "$crd_chart" != "agentgateway-crds-v1.7.0" ||
    "$crd_namespace" != "$agentgateway_system_namespace" ||
    "$crd_status" != "deployed" ]]; then
    printf 'Found incompatible agentgateway-crds Helm release (%s in %s, status %s); refusing to upgrade or adopt it.\n' \
      "$crd_chart" "$crd_namespace" "$crd_status" >&2
    exit 1
  fi
else
  existing_agentgateway_crds="$(kubectl get crd -o json |
    jq -r '[.items[].metadata.name | select(endswith(".agentgateway.dev"))] | length')"
  if (( existing_agentgateway_crds > 0 )); then
    printf 'Found agentgateway CRDs without the compatible v1.7.0 Helm release; refusing to adopt or upgrade them.\n' >&2
    exit 1
  fi
  helm upgrade --install agentgateway-crds \
    oci://cr.agentgateway.dev/charts/agentgateway-crds \
    --namespace "$agentgateway_system_namespace" \
    --create-namespace \
    --version "$agentgateway_version" \
    --wait --timeout 5m
fi

for crd in \
  agentgatewaybackends.agentgateway.dev \
  agentgatewayparameters.agentgateway.dev \
  agentgatewaypolicies.agentgateway.dev \
  agentgatewaymodels.agentgateway.dev; do
  kubectl wait --for=condition=Established --timeout=120s "crd/$crd"
done

for resource in \
  "agentgatewayparameters agentgateway-demo" \
  "gateway agentgateway-proxy" \
  "httproute agentgateway-llm" \
  "httproute agentgateway-readiness" \
  "agentgatewaypolicy agentgateway-demo" \
  "agentgatewaybackend agentgateway-llm" \
  "secret agentgateway-openai-provider" \
  "deployment agentgateway-httpbun" \
  "service agentgateway-httpbun"; do
  read -r kind name <<<"$resource"
  agentgateway_assert_owned_or_absent "$kind" "$name" "$namespace"
done

umask 077
work_dir="$root_dir/.agentgateway-install-$(openssl rand -hex 12)"
mkdir "$work_dir"
forward_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$forward_pid" ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    kubectl delete gateway agentgateway-proxy --namespace "$namespace" \
      --ignore-not-found --wait --timeout=120s >&2 || true
    kubectl delete httproute agentgateway-llm --namespace "$namespace" \
      --ignore-not-found >&2 || true
  fi
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Shut down any previous data plane before changing credentials or policies.
kubectl delete gateway agentgateway-proxy --namespace "$namespace" \
  --ignore-not-found --cascade=foreground --wait --timeout=120s
if [[ -n "$(kubectl get deployment agentgateway-proxy --namespace "$namespace" --ignore-not-found -o name)" ]]; then
  kubectl wait --for=delete deployment/agentgateway-proxy --namespace "$namespace" --timeout=120s
fi
kubectl delete httproute agentgateway-llm --namespace "$namespace" --ignore-not-found

agentgateway_release="$(helm list --all-namespaces --filter '^agentgateway$' --output json |
  jq -c '[.[] | select(.name == "agentgateway")] | first // empty')"
agentgateway_assert_owned_or_absent configmap agentgateway-demo-controller "$agentgateway_system_namespace"
if [[ -n "$agentgateway_release" ]]; then
  release_chart="$(jq -r '.chart' <<<"$agentgateway_release")"
  release_namespace="$(jq -r '.namespace' <<<"$agentgateway_release")"
  release_status="$(jq -r '.status' <<<"$agentgateway_release")"
  if [[ "$release_chart" != "agentgateway-v1.7.0" ||
    "$release_namespace" != "$agentgateway_system_namespace" ||
    "$release_status" != "deployed" ]]; then
    printf 'Found incompatible agentgateway Helm release (%s in %s, status %s); refusing to upgrade or adopt it.\n' \
      "$release_chart" "$release_namespace" "$release_status" >&2
    exit 1
  fi
  controller_state="$(kubectl get configmap agentgateway-demo-controller \
    --namespace "$agentgateway_system_namespace" --ignore-not-found -o json)"
  if [[ -n "$controller_state" &&
    "$(jq -r '.data.chart' <<<"$controller_state")" == "$release_chart" &&
    "$(jq -r '.data["release-uid"]' <<<"$controller_state")" == "$(agentgateway_release_uid "$agentgateway_release")" ]]; then
    controller_owned=true
  fi
  printf 'Reusing the compatible agentgateway %s controller release.\n' "$agentgateway_version"
else
  gateway_class="$(kubectl get gatewayclass agentgateway --ignore-not-found -o json)"
  if [[ -n "$gateway_class" ]]; then
    printf 'GatewayClass/agentgateway exists without the expected Helm release; refusing to adopt it.\n' >&2
    exit 1
  fi
  helm upgrade --install agentgateway \
    oci://cr.agentgateway.dev/charts/agentgateway \
    --namespace "$agentgateway_system_namespace" \
    --version "$agentgateway_version" \
    --values "$root_dir/gateways/agentgateway/values.yaml" \
    --wait --timeout 5m
  controller_owned=true
  agentgateway_release="$(helm list --namespace "$agentgateway_system_namespace" --filter '^agentgateway$' --output json |
    jq -c '.[] | select(.name == "agentgateway")')"
  kubectl create configmap agentgateway-demo-controller --namespace "$agentgateway_system_namespace" \
    --from-literal="release-uid=$(agentgateway_release_uid "$agentgateway_release")" \
    --from-literal="chart=agentgateway-v1.7.0" --dry-run=client -o json |
    jq '.metadata.labels = {"app.kubernetes.io/managed-by":"agentgateway-demo"}' |
    kubectl apply -f -
fi

gateway_class=""
for ((attempt = 0; attempt < 60; attempt++)); do
  gateway_class="$(kubectl get gatewayclass agentgateway --ignore-not-found -o json)"
  if [[ -n "$gateway_class" ]]; then
    break
  fi
  sleep 2
done
if [[ -z "$gateway_class" ]]; then
  printf 'Timed out waiting for the agentgateway controller to create GatewayClass/agentgateway.\n' >&2
  exit 1
fi
if [[ "$(jq -r '.spec.controllerName' <<<"$gateway_class")" != "agentgateway.dev/agentgateway" ]]; then
  printf 'GatewayClass/agentgateway is not controlled by agentgateway.dev/agentgateway.\n' >&2
  exit 1
fi

kubectl create configmap agentgateway-demo-state \
  --namespace "$namespace" \
  --from-literal="backend-mode=$mode" \
  --from-literal="model=$model" \
  --from-literal="gateway-api-version=$gateway_api_bundle" \
  --from-literal="agentgateway-version=$agentgateway_version" \
  --dry-run=client -o json |
  jq --arg managed_by "${agentgateway_managed_by#*=}" \
    '.metadata.labels = ((.metadata.labels // {}) + {"app.kubernetes.io/managed-by": $managed_by})' |
  kubectl apply -f -

kubectl wait --for=condition=Accepted --timeout=120s gatewayclass/agentgateway
if [[ "$controller_owned" == true ]]; then
  kubectl label gatewayclass agentgateway app.kubernetes.io/managed-by=agentgateway-demo --overwrite
fi
kubectl apply --namespace "$namespace" -f "$root_dir/gateways/agentgateway/httpbun.yaml"
kubectl rollout status deployment/agentgateway-httpbun --namespace "$namespace" --timeout=120s
# Stage only the local mock until the inference route's security is verified.
cat <<EOF | kubectl apply --namespace "$namespace" -f -
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agentgateway-llm
  labels:
    app.kubernetes.io/managed-by: agentgateway-demo
spec:
  ai:
    provider:
      openai:
        model: $model
      host: agentgateway-httpbun.$namespace.svc.cluster.local
      port: 3090
      path: /llm/chat/completions
EOF
if [[ "$mode" == "mock" ]]; then
  kubectl delete secret agentgateway-openai-provider --namespace "$namespace" --ignore-not-found
else
  printf '%s' "$OPENAI_API_KEY" |
    kubectl create secret generic agentgateway-openai-provider \
      --namespace "$namespace" \
      --from-file=Authorization=/dev/stdin \
      --dry-run=client -o json |
    jq --arg managed_by "${agentgateway_managed_by#*=}" \
      '.metadata.labels = ((.metadata.labels // {}) + {"app.kubernetes.io/managed-by": $managed_by})' |
    kubectl apply -f -
  cat <<EOF > "$work_dir/openai-backend.yaml"
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agentgateway-llm
  labels:
    app.kubernetes.io/managed-by: agentgateway-demo
spec:
  ai:
    provider:
      openai:
        model: $model
  policies:
    auth:
      secretRef:
        name: agentgateway-openai-provider
    ai:
      routes:
        /v1/chat/completions: Completions
EOF
fi

agentgateway_apply_client_keys "$namespace" "$alice_key" "$bob_key"
phase="install-$(openssl rand -hex 16)"
agentgateway_write_policy "$namespace" "$model" "$phase"
generation="$(kubectl get agentgatewaypolicy agentgateway-demo --namespace "$namespace" -o json | jq '.metadata.generation')"
kubectl apply --namespace "$namespace" -f "$root_dir/gateways/agentgateway/parameters.yaml"
kubectl apply --namespace "$namespace" -f "$root_dir/gateways/agentgateway/gateway.yaml"
kubectl apply --namespace "$namespace" -f "$root_dir/gateways/agentgateway/readiness-route.yaml"

kubectl wait --for=condition=Programmed --timeout=180s "gateway/agentgateway-proxy" \
  --namespace "$namespace"
kubectl rollout status deployment/agentgateway-proxy --namespace "$namespace" --timeout=180s
if [[ "$(kubectl get service agentgateway-proxy --namespace "$namespace" -o json |
  jq -r '.spec.type')" != "ClusterIP" ]]; then
  printf 'The generated proxy Service is not ClusterIP; refusing to leave a public endpoint.\n' >&2
  exit 1
fi
if [[ "$(kubectl get deployment agentgateway-proxy --namespace "$namespace" -o json |
  jq -r '.spec.replicas')" != "1" ]]; then
  printf 'The generated proxy Deployment is not configured for exactly one replica.\n' >&2
  exit 1
fi

agentgateway_wait_policy "$namespace" "$generation"
kubectl port-forward --namespace "$namespace" --address 127.0.0.1 \
  service/agentgateway-proxy :80 > "$work_dir/port-forward" 2>&1 &
forward_pid=$!
local_port=""
for ((attempt = 0; attempt < 60; attempt++)); do
  local_port="$(awk '/Forwarding from 127.0.0.1:/ {split($3, address, ":"); print address[2]; exit}' "$work_dir/port-forward")"
  if [[ -n "$local_port" ]]; then break; fi
  if ! kill -0 "$forward_pid" 2>/dev/null; then
    cat "$work_dir/port-forward" >&2
    exit 1
  fi
  sleep 1
done
if [[ -z "$local_port" ]]; then
  printf 'Timed out starting the private readiness port-forward.\n' >&2
  exit 1
fi
agentgateway_wait_dataplane "http://127.0.0.1:$local_port" "$alice_key" "$phase" "$work_dir"
printf 'Authorization: Bearer %s\n' "$alice_key" > "$work_dir/readiness-header"
status="$(curl --silent --show-error --max-time 5 \
  --header "@$work_dir/readiness-header" --header 'Content-Type: application/json' \
  --data '{"model":"agentgateway-forbidden-model"}' --output /dev/null \
  --write-out '%{http_code}' "http://127.0.0.1:$local_port/anything")"
if [[ "$status" != 403 ]]; then
  printf 'Readiness authorization check expected 403, got %s.\n' "$status" >&2
  exit 1
fi
printf 'Current-generation policy verified in the data plane without inference calls.\n'
kubectl apply --namespace "$namespace" -f "$root_dir/gateways/agentgateway/route.yaml"

route_ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
  if kubectl get httproute agentgateway-llm --namespace "$namespace" -o json |
    jq -e 'any(.status.parents[]?.conditions[]?; .type == "Accepted" and .status == "True") and any(.status.parents[]?.conditions[]?; .type == "ResolvedRefs" and .status == "True")' >/dev/null; then
    route_ready=true
    break
  fi
  sleep 2
done
if [[ "$route_ready" != true ]]; then
  kubectl describe httproute agentgateway-llm --namespace "$namespace" >&2
  printf 'Timed out waiting for the HTTPRoute to be accepted with resolved references.\n' >&2
  exit 1
fi

for key in "" invalid-agentgateway-client-key "$alice_key"; do
  expected=401
  if [[ "$key" == "$alice_key" ]]; then expected=403; fi
  printf 'Authorization: Bearer %s\n' "$key" > "$work_dir/readiness-header"
  verified=false
  for ((attempt = 0; attempt < 60; attempt++)); do
    status="$(curl --silent --show-error --max-time 5 \
      --header "@$work_dir/readiness-header" --header 'Content-Type: application/json' \
      --data '{"model":"agentgateway-forbidden-model","messages":[]}' --output /dev/null \
      --write-out '%{http_code}' "http://127.0.0.1:$local_port/v1/chat/completions")"
    if [[ "$status" == "$expected" ]]; then verified=true; break; fi
    if [[ "$status" != 404 && "$status" != 503 ]]; then break; fi
    sleep 1
  done
  if [[ "$verified" != true ]]; then
    printf 'Inference-route security check expected %s, got %s; real backend remains disabled.\n' "$expected" "$status" >&2
    exit 1
  fi
done
printf 'Inference route rejects missing/invalid keys (401) and forbidden models (403).\n'
if [[ "$mode" == openai ]]; then
  kubectl apply --namespace "$namespace" -f "$work_dir/openai-backend.yaml"
fi
backend_generation="$(kubectl get agentgatewaybackend agentgateway-llm --namespace "$namespace" -o json | jq '.metadata.generation')"
backend_ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
  if kubectl get agentgatewaybackend agentgateway-llm --namespace "$namespace" -o json |
    jq -e --argjson generation "$backend_generation" 'any(.status.conditions[]?; .type == "Accepted" and .status == "True" and .observedGeneration == $generation)' >/dev/null; then
    backend_ready=true
    break
  fi
  sleep 2
done
if [[ "$backend_ready" != true ]]; then
  kubectl describe agentgatewaybackend agentgateway-llm --namespace "$namespace" >&2
  printf 'Timed out waiting for the LLM backend to be accepted.\n' >&2
  exit 1
fi

printf '\nagentgateway installed in namespace %s (mode: %s, model: %s).\n' \
  "$namespace" "$mode" "$model"
printf 'Run `make agentgateway-port-forward AGENTGATEWAY_NAMESPACE=%s` and then `make agentgateway-demo AGENTGATEWAY_NAMESPACE=%s`.\n' \
  "$namespace" "$namespace"
