#!/usr/bin/env bash
set -euo pipefail

app_namespace="${ENVOY_AI_GATEWAY_NAMESPACE:-envoy-ai-gateway-demo}"
gateway_namespace="${ENVOY_GATEWAY_NAMESPACE:-envoy-gateway-system}"
controller_namespace="${ENVOY_AI_GATEWAY_SYSTEM_NAMESPACE:-envoy-ai-gateway-system}"
mode="${ENVOY_AI_GATEWAY_MODE:-mock}"
openai_model="${ENVOY_AI_GATEWAY_OPENAI_MODEL:-gpt-4o-mini}"
owner_label="app.kubernetes.io/managed-by=envoy-ai-gateway-demo"
crd_owner_label="envoy-ai-gateway.demo/owner=issue-3"
gateway_api_url="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gateway_values="$root_dir/gateways/envoy-ai-gateway/envoy-gateway-values.yaml"
ratelimit_values="$root_dir/gateways/envoy-ai-gateway/envoy-gateway-ratelimit-values.yaml"
existing_envoy_crds=""

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

for command in kubectl helm curl openssl python3 sed; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
done

for namespace in "$app_namespace" "$gateway_namespace" "$controller_namespace"; do
  [[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    fail "Invalid Kubernetes namespace: $namespace"
done

[[ "$app_namespace" != "$gateway_namespace" && "$app_namespace" != "$controller_namespace" &&
  "$gateway_namespace" != "$controller_namespace" ]] ||
  fail "Application, Envoy Gateway, and AI Gateway controller namespaces must be distinct."
[[ "$mode" == mock || "$mode" == openai ]] ||
  fail "ENVOY_AI_GATEWAY_MODE must be 'mock' or 'openai'."
[[ "$openai_model" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "ENVOY_AI_GATEWAY_OPENAI_MODEL may contain only letters, digits, dot, underscore, and hyphen."
if [[ "$mode" == openai && -z "${OPENAI_API_KEY:-}" ]]; then
  fail "Set OPENAI_API_KEY to install the explicitly selected OpenAI mode."
fi
openai_key="${OPENAI_API_KEY:-}"
unset OPENAI_API_KEY

cluster_version="$(kubectl version --output=json | python3 -c \
  'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
server_minor="$(kubectl version --output=json | python3 -c \
  'import json,sys; print(int(json.load(sys.stdin)["serverVersion"]["minor"].rstrip("+")))')"
(( server_minor >= 32 )) ||
  fail "Kubernetes 1.32 or newer is required; this cluster is $cluster_version."

ensure_namespace() {
  local namespace="$1"
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    local owner
    owner="$(kubectl get namespace "$namespace" -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')"
    [[ "$owner" == envoy-ai-gateway-demo ]] ||
      fail "Namespace $namespace already exists and is not owned by this demo; refusing to modify it."
  else
    kubectl create namespace "$namespace" >/dev/null
    kubectl label namespace "$namespace" "$owner_label" >/dev/null
  fi
}

check_namespace() {
  local namespace="$1"
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    local owner
    owner="$(kubectl get namespace "$namespace" -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')"
    [[ "$owner" == envoy-ai-gateway-demo ]] ||
      fail "Namespace $namespace already exists and is not owned by this demo; refusing to modify it."
  fi
}

check_release() {
  local release="$1"
  local namespace="$2"
  local expected_chart="$3"
  local release_info
  release_info="$(helm list --all-namespaces --output json |
    python3 -c 'import json,sys; name=sys.argv[1]; r=next((r for r in json.load(sys.stdin) if r["name"] == name), None); print("" if r is None else chr(9).join((r["namespace"],r["chart"],r["app_version"])))' "$release")"
  if [[ -n "$release_info" ]]; then
    IFS=$'\t' read -r release_namespace chart app_version <<< "$release_info"
    [[ "$release_namespace" == "$namespace" ]] ||
      fail "Helm release $release already exists in namespace $release_namespace."
    [[ "$chart" == "$expected_chart" ]] ||
      fail "Helm release $release in $namespace is $chart, not the pinned $expected_chart."
    [[ "$app_version" == "${expected_chart##*-}" || "$app_version" == "v${expected_chart##*-}" ]] ||
      fail "Helm release $release has unexpected app version $app_version."
  fi
}

check_controller() {
  local selector="$1"
  local expected_namespace="$2"
  local deployment_name="$3"
  local description="$4"
  local found
  found="$(kubectl get deployments --all-namespaces -o json |
    python3 -c '
import json,sys
selector,name=sys.argv[1:]
key,value=selector.split("=",1)
for deployment in json.load(sys.stdin)["items"]:
    labels=deployment["metadata"].get("labels", {})
    if deployment["metadata"]["name"] == name or labels.get(key) == value:
        print(deployment["metadata"]["namespace"])
' "$selector" "$deployment_name")"
  while IFS= read -r namespace; do
    [[ -z "$namespace" || "$namespace" == "$expected_namespace" ]] ||
      fail "Found an existing $description deployment in namespace $namespace; use a clean cluster."
  done <<< "$found"
}

check_envoy_crds() {
  existing_envoy_crds="$(kubectl get crd -o json |
    python3 -c 'import json,sys; print(chr(10).join(c["metadata"]["name"] for c in json.load(sys.stdin)["items"] if c["spec"]["group"] == "gateway.envoyproxy.io"))')"
  while IFS= read -r crd; do
    [[ -z "$crd" ]] && continue
    owner="$(kubectl get crd "$crd" -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')"
    [[ "$owner" == envoy-ai-gateway-demo ]] ||
      fail "Envoy Gateway CRD $crd already exists and is not owned by this demo."
  done <<< "$existing_envoy_crds"
}

check_agent_router_crds() {
  local crds
  crds="$(kubectl get crd -o json |
    python3 -c 'import json,sys; print(chr(10).join(c["metadata"]["name"] for c in json.load(sys.stdin)["items"] if c["spec"]["group"] == "aigateway.envoyproxy.io"))')"
  while IFS= read -r crd; do
    [[ -z "$crd" ]] && continue
    owner="$(kubectl get crd "$crd" -o json |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"].get("labels",{}).get("envoy-ai-gateway.demo/owner",""))')"
    [[ "$owner" == issue-3 ]] ||
      fail "Agent Router CRD $crd already exists and is not owned by this demo."
  done <<< "$crds"
}

install_envoy_crds() {
  if [[ -z "$existing_envoy_crds" ]]; then
    local gateway_crds
    gateway_crds="$(helm show crds oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 |
      python3 -c 'import re,sys; docs=re.split(r"(?m)^--- *$",sys.stdin.read()); selected=[d for d in docs if "  group: gateway.envoyproxy.io" in d]; print("---".join(selected))')"
    [[ -n "$gateway_crds" ]] || fail "Could not read the pinned Envoy Gateway CRDs."
    printf '%s\n' "$gateway_crds" | kubectl create -f -
    while IFS= read -r crd; do
      [[ -n "$crd" ]] && kubectl label crd "$crd" "$owner_label" >/dev/null
    done < <(kubectl get crd -o json |
      python3 -c 'import json,sys; print(chr(10).join(c["metadata"]["name"] for c in json.load(sys.stdin)["items"] if c["spec"]["group"] == "gateway.envoyproxy.io"))')
  fi
}

check_owned_resource() {
  local resource="$1"
  local name="$2"
  local namespace="$3"
  local object
  if object="$(kubectl get "$resource" "$name" --namespace "$namespace" -o json 2>/dev/null)"; then
    local owner
    owner="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["metadata"].get("labels",{}).get("app.kubernetes.io/managed-by",""))' <<< "$object")"
    [[ "$owner" == envoy-ai-gateway-demo ]] ||
      fail "Resource $resource/$name in namespace $namespace already exists and is not owned by this demo."
  fi
}

ensure_gateway_api() {
  local existing=0
  local crd
  local required_crds=(
    gateways.gateway.networking.k8s.io
    httproutes.gateway.networking.k8s.io
    referencegrants.gateway.networking.k8s.io
  )

  for crd in "${required_crds[@]}"; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      ((existing += 1))
    fi
  done

  if (( existing == 0 )); then
    printf 'Installing Gateway API CRDs v1.6.1 (none are present).\n'
    kubectl apply --server-side=true -f "$gateway_api_url"
  elif (( existing != ${#required_crds[@]} )); then
    fail "Only some Gateway API CRDs are installed; refusing to add or replace CRDs in this cluster."
  else
    kubectl get crd "${required_crds[@]}" -o json | python3 -c '
import json,sys
items=json.load(sys.stdin)["items"]
required={"gateways.gateway.networking.k8s.io":"v1","httproutes.gateway.networking.k8s.io":"v1"}
for crd in items:
    name=crd["metadata"]["name"]
    served={v["name"] for v in crd["spec"]["versions"] if v.get("served")}
    if name in required and required[name] not in served:
        raise SystemExit(f"Error: existing {name} does not serve {required[name]}; refusing to modify it.")
    labels=crd["metadata"].get("labels", {})
    version=labels.get("gateway.networking.k8s.io/bundle-version", "unlabeled")
    print(f"Using existing {name}; bundle label: {version} (not modified).")
'
  fi
}

check_gateway_class() {
  if kubectl get gatewayclass envoy-ai-gateway-demo >/dev/null 2>&1; then
    local owner
    owner="$(kubectl get gatewayclass envoy-ai-gateway-demo -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')"
    [[ "$owner" == envoy-ai-gateway-demo ]] ||
      fail "GatewayClass envoy-ai-gateway-demo already exists and is not owned by this demo."
  fi
}

wait_for_release_deployments() {
  local namespace="$1"
  local release="$2"
  local timeout="${3:-5m}"
  kubectl wait --for=condition=Available deployment \
    --selector="app.kubernetes.io/instance=$release" \
    --namespace "$namespace" \
    --timeout="$timeout"
}

wait_for_policy_accepted() {
  local resource="$1"
  local name="$2"
  local namespace="$3"
  local ancestor_name="$4"
  local deadline=$((SECONDS + 180))
  local accepted

  while (( SECONDS < deadline )); do
    accepted="$(kubectl get "$resource" "$name" --namespace "$namespace" -o json |
      python3 -c '
import json,sys
policy=json.load(sys.stdin)
for ancestor in policy.get("status", {}).get("ancestors", []):
    if ancestor.get("ancestorRef", {}).get("name") == sys.argv[1] and any(
           condition.get("type") == "Accepted" and condition.get("status") == "True"
           for condition in ancestor.get("conditions", [])):
        print("true")
        break
' "$ancestor_name")"
    [[ "$accepted" == true ]] && return 0
    sleep 2
  done

  kubectl get "$resource" "$name" --namespace "$namespace" -o yaml >&2 || true
  fail "$resource/$name did not report an Accepted ancestor within 180 seconds."
}

diagnostics() {
  printf '\nDeployment diagnostics (resource metadata only):\n' >&2
  kubectl get deployments,pods -n "$app_namespace" -o wide >&2 || true
  kubectl get gatewayclass envoy-ai-gateway-demo -o yaml >&2 || true
  kubectl get gateway,httproute,aigatewayroute,backendtrafficpolicy,securitypolicy \
    -n "$app_namespace" -o wide >&2 || true
  kubectl get deployments,pods -n "$gateway_namespace" -o wide >&2 || true
  kubectl get deployments,pods -n "$controller_namespace" -o wide >&2 || true
}
trap 'status=$?; if (( status != 0 )); then diagnostics; fi' EXIT

check_namespace "$app_namespace"
check_namespace "$gateway_namespace"
check_namespace "$controller_namespace"
check_release eg "$gateway_namespace" "gateway-helm-v1.9.2"
check_release ai-gateway-crds "$controller_namespace" "ai-gateway-crds-helm-v1.2.1"
check_release ai-gateway "$controller_namespace" "ai-gateway-helm-v1.2.1"
check_controller "app.kubernetes.io/instance=eg" "$gateway_namespace" "envoy-gateway" "Envoy Gateway"
check_controller "app.kubernetes.io/instance=ai-gateway" "$controller_namespace" "ai-gateway-controller" "Agent Router"
check_gateway_class
check_envoy_crds
check_agent_router_crds
ensure_gateway_api
ensure_namespace "$app_namespace"
ensure_namespace "$gateway_namespace"
ensure_namespace "$controller_namespace"
install_envoy_crds

check_owned_resource deployment redis "$gateway_namespace"
check_owned_resource service redis "$gateway_namespace"
kubectl apply -f <(sed "s/@@ENVOY_GATEWAY_NAMESPACE@@/$gateway_namespace/g" \
  "$root_dir/gateways/envoy-ai-gateway/redis.yaml")
kubectl rollout status deployment/redis --namespace "$gateway_namespace" --timeout=2m

helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.2 \
  --namespace "$gateway_namespace" \
  --values "$gateway_values" \
  --values "$ratelimit_values" \
  --set "config.envoyGateway.extensionManager.service.fqdn.hostname=ai-gateway-controller.$controller_namespace.svc.cluster.local" \
  --set "config.envoyGateway.rateLimit.backend.redis.url=redis.$gateway_namespace.svc.cluster.local:6379" \
  --wait --timeout 5m
wait_for_release_deployments "$gateway_namespace" eg
kubectl rollout status deployment/envoy-ratelimit --namespace "$gateway_namespace" --timeout=3m

helm upgrade --install ai-gateway-crds oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v1.2.1 \
  --namespace "$controller_namespace" \
  --wait --timeout 5m
while IFS= read -r crd; do
  [[ -n "$crd" ]] && kubectl label crd "$crd" "$crd_owner_label" --overwrite >/dev/null
done < <(kubectl get crd -o json |
  python3 -c 'import json,sys; print(chr(10).join(c["metadata"]["name"] for c in json.load(sys.stdin)["items"] if c["spec"]["group"] == "aigateway.envoyproxy.io"))')
helm upgrade --install ai-gateway oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v1.2.1 \
  --namespace "$controller_namespace" \
  --wait --timeout 5m
wait_for_release_deployments "$controller_namespace" ai-gateway

for resource_name in \
  "gateway envoy-ai-gateway-demo" \
  "envoyproxy envoy-ai-gateway-demo" \
  "securitypolicy envoy-ai-gateway-client-key" \
  "deployment envoy-ai-gateway-mock" \
  "service envoy-ai-gateway-mock" \
  "aiservicebackend envoy-ai-gateway-mock" \
  "backend envoy-ai-gateway-mock" \
  "aigatewayroute envoy-ai-gateway-mock" \
  "backendtrafficpolicy envoy-ai-gateway-token-limit" \
  "secret envoy-ai-gateway-client-keys" \
  "configmap envoy-ai-gateway-mock" \
  "configmap envoy-ai-gateway-install" \
  "aiservicebackend envoy-ai-gateway-openai" \
  "backend envoy-ai-gateway-openai" \
  "backendsecuritypolicy envoy-ai-gateway-openai-key" \
  "backendtlspolicy envoy-ai-gateway-openai-tls" \
  "aigatewayroute envoy-ai-gateway-openai" \
  "secret envoy-ai-gateway-openai-key"; do
  read -r resource name <<< "$resource_name"
  check_owned_resource "$resource" "$name" "$app_namespace"
done

if ! kubectl get secret envoy-ai-gateway-client-keys -n "$app_namespace" >/dev/null 2>&1; then
  client_key="$(openssl rand -hex 32)"
  printf '%s' "$client_key" |
    kubectl create secret generic envoy-ai-gateway-client-keys \
      --namespace "$app_namespace" \
      --from-file=demo=/dev/stdin
  kubectl label secret envoy-ai-gateway-client-keys -n "$app_namespace" "$owner_label" >/dev/null
  unset client_key
else
  owner="$(kubectl get secret envoy-ai-gateway-client-keys -n "$app_namespace" \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')"
  [[ "$owner" == envoy-ai-gateway-demo ]] ||
    fail "Client key Secret already exists and is not owned by this demo."
fi

kubectl create configmap envoy-ai-gateway-mock \
  --namespace "$app_namespace" \
  --from-file=mock_backend.py="$root_dir/gateways/envoy-ai-gateway/mock-backend.py" \
  --dry-run=client -o yaml |
  kubectl apply -f -
kubectl label configmap envoy-ai-gateway-mock -n "$app_namespace" "$owner_label" --overwrite >/dev/null

kubectl apply -f <(sed "s/@@ENVOY_AI_GATEWAY_NAMESPACE@@/$app_namespace/g" \
  "$root_dir/gateways/envoy-ai-gateway/gateway.yaml")
kubectl apply -f <(sed "s/@@ENVOY_AI_GATEWAY_NAMESPACE@@/$app_namespace/g" \
  "$root_dir/gateways/envoy-ai-gateway/mock-backend.yaml")

if [[ "$mode" == openai ]]; then
  if ! kubectl get secret envoy-ai-gateway-openai-key -n "$app_namespace" >/dev/null 2>&1; then
    printf '%s' "$openai_key" |
      kubectl create secret generic envoy-ai-gateway-openai-key \
        --namespace "$app_namespace" \
        --from-file=apiKey=/dev/stdin
    kubectl label secret envoy-ai-gateway-openai-key -n "$app_namespace" "$owner_label" >/dev/null
  else
    owner="$(kubectl get secret envoy-ai-gateway-openai-key -n "$app_namespace" \
      -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}')"
    [[ "$owner" == envoy-ai-gateway-demo ]] ||
      fail "OpenAI credential Secret already exists and is not owned by this demo."
  fi
  openai_manifest="$(mktemp)"
  trap 'rm -f "$openai_manifest"; status=$?; if (( status != 0 )); then diagnostics; fi' EXIT
  sed \
    -e "s/@@ENVOY_AI_GATEWAY_NAMESPACE@@/$app_namespace/g" \
    -e "s/__OPENAI_MODEL__/$openai_model/g" \
    "$root_dir/gateways/envoy-ai-gateway/openai-route.yaml.in" > "$openai_manifest"
  kubectl apply -f "$openai_manifest"
else
  openai_manifest="$(mktemp)"
  sed \
    -e "s/@@ENVOY_AI_GATEWAY_NAMESPACE@@/$app_namespace/g" \
    -e "s/__OPENAI_MODEL__/$openai_model/g" \
    "$root_dir/gateways/envoy-ai-gateway/openai-route.yaml.in" > "$openai_manifest"
  kubectl delete -f "$openai_manifest" --ignore-not-found
  rm -f "$openai_manifest"
fi
unset openai_key

kubectl create configmap envoy-ai-gateway-install \
  --namespace "$app_namespace" \
  --from-literal=mode="$mode" \
  --dry-run=client -o yaml |
  kubectl apply -f -
kubectl label configmap envoy-ai-gateway-install -n "$app_namespace" "$owner_label" --overwrite >/dev/null

kubectl rollout status deployment/envoy-ai-gateway-mock --namespace "$app_namespace" --timeout=3m
kubectl wait --for=condition=Accepted gatewayclass/envoy-ai-gateway-demo --timeout=2m
kubectl wait --for=condition=Programmed gateway/envoy-ai-gateway-demo \
  --namespace "$app_namespace" --timeout=3m
kubectl wait --for=condition=Accepted aigatewayroute/envoy-ai-gateway-mock \
  --namespace "$app_namespace" --timeout=3m
wait_for_policy_accepted securitypolicy envoy-ai-gateway-client-key "$app_namespace" envoy-ai-gateway-demo
wait_for_policy_accepted backendtrafficpolicy envoy-ai-gateway-token-limit "$app_namespace" envoy-ai-gateway-demo
if [[ "$mode" == openai ]]; then
  kubectl wait --for=condition=Accepted aigatewayroute/envoy-ai-gateway-openai \
    --namespace "$app_namespace" --timeout=3m
  wait_for_policy_accepted backendsecuritypolicy envoy-ai-gateway-openai-key "$app_namespace" envoy-ai-gateway-demo
  wait_for_policy_accepted backendtlspolicy envoy-ai-gateway-openai-tls "$app_namespace" envoy-ai-gateway-demo
fi

printf '\nEnvoy AI Gateway demo installed in namespace %s (%s mode).\n' "$app_namespace" "$mode"
printf 'Export the client key without displaying it:\n'
printf "  export ENVOY_AI_GATEWAY_CLIENT_KEY=\"\$(kubectl get secret envoy-ai-gateway-client-keys -n %s -o jsonpath='{.data.demo}' | python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.buffer.read()).decode())')\"\n" "$app_namespace"
printf 'Run `make envoy-ai-gateway-port-forward` and then `make envoy-ai-gateway-demo`.\n'
