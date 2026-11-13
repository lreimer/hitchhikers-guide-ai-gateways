#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

agentgateway_mcp_managed_by="agentgateway-mcp-demo"
agentgateway_mcp_resources=(
  "httproute agentgateway-mcp"
  "agentgatewaypolicy agentgateway-mcp"
  "agentgatewaybackend agentgateway-mcp"
  "deployment agentgateway-mcp-calculator"
  "deployment agentgateway-mcp-catalog"
  "service agentgateway-mcp-calculator"
  "service agentgateway-mcp-catalog"
)

agentgateway_mcp_check_ownership() {
  local kind="$1" name="$2" namespace="$3" resource
  resource="$(kubectl get "$kind" "$name" -n "$namespace" --ignore-not-found -o json)"
  if [[ -n "$resource" ]] &&
    [[ "$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$resource")" != "$agentgateway_mcp_managed_by" ]]; then
    printf 'Refusing to change unowned %s/%s in %s.\n' "$kind" "$name" "$namespace" >&2
    return 1
  fi
}

agentgateway_mcp_prerequisites() {
  local namespace="$1" state release gateway policies
  agentgateway_require_commands kubectl helm jq
  agentgateway_validate_namespace "$namespace"
  state="$(kubectl get configmap agentgateway-demo-state -n "$namespace" --ignore-not-found -o json)"
  if [[ -z "$state" ]] || ! jq -e '
    .metadata.labels["app.kubernetes.io/managed-by"] == "agentgateway-demo" and
    .data["agentgateway-version"] == "v1.7.0"' <<<"$state" >/dev/null; then
    printf 'Install the base agentgateway v1.7.0 demo in %s first (make agentgateway-install).\n' "$namespace" >&2
    return 1
  fi
  for release in agentgateway agentgateway-crds; do
    if ! helm list --namespace "$agentgateway_system_namespace" --output json |
      jq -e --arg name "$release" 'any(.[];
        .name == $name and .chart == ($name + "-v1.7.0") and .status == "deployed")' >/dev/null; then
      printf 'Missing/incompatible %s v1.7.0 Helm release in %s; repair the base demo. This add-on never installs controllers or CRDs.\n' \
        "$release" "$agentgateway_system_namespace" >&2
      return 1
    fi
  done
  for kind in agentgatewaybackends agentgatewaypolicies agentgatewayparameters; do
    kubectl wait --for=condition=Established --timeout=30s "crd/$kind.agentgateway.dev"
  done
  gateway="$(kubectl get gateway agentgateway-proxy -n "$namespace" -o json)"
  if ! jq -e '
    .metadata.labels["app.kubernetes.io/managed-by"] == "agentgateway-demo" and
    .spec.gatewayClassName == "agentgateway" and
    any(.spec.listeners[];
      .name == "http" and .protocol == "HTTP" and
      .allowedRoutes.namespaces.from == "Same")' <<<"$gateway" >/dev/null; then
    printf 'The base Gateway must retain its owned, same-namespace http listener.\n' >&2
    return 1
  fi
  if ! kubectl get deployment agentgateway-proxy -n "$namespace" -o json |
    jq -e '(.spec.replicas // 1) == 1 and
      any(.spec.template.spec.containers[]; .image | test("(^|[:/])v1\\.7\\.0($|@)"))' >/dev/null; then
    printf 'The existing proxy must be agentgateway v1.7.0 with exactly one replica.\n' >&2
    return 1
  fi
  # Gateway/GatewayClass authentication and quotas would also apply to /mcp.
  policies="$(kubectl get agentgatewaypolicies --all-namespaces -o json)"
  if ! jq -e --arg namespace "$namespace" '
    [.items[] | select(any(.spec.targetRefs[]?;
      (.kind == "Gateway" and .name == "agentgateway-proxy" and
        ($namespace == .namespace or .namespace == null)) or
      (.kind == "GatewayClass" and .name == "agentgateway"))) |
      select(.metadata.namespace == $namespace or
        any(.spec.targetRefs[]?; .kind == "GatewayClass")) |
      select(.spec.traffic.apiKeyAuthentication != null or
        .spec.traffic.jwtAuthentication != null or
        .spec.traffic.authorization != null or
        .spec.traffic.rateLimit != null or .spec.backend.ai != null)] |
    length == 0' <<<"$policies" >/dev/null; then
    printf 'Inherited Gateway policies conflict with MCP. Update the base demo to scope LLM security and budgets to its HTTPRoutes first.\n' >&2
    return 1
  fi
  kubectl wait --for=condition=Programmed --timeout=120s gateway/agentgateway-proxy -n "$namespace"
  kubectl rollout status deployment/agentgateway-proxy -n "$namespace" --timeout=120s
}

agentgateway_mcp_wait_policy() {
  local namespace="$1" generation="$2" attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    if kubectl get agentgatewaypolicy agentgateway-mcp -n "$namespace" -o json |
      jq -e --argjson generation "$generation" '
        .metadata.generation == $generation and
        any(.status.ancestors[]?;
          any(.conditions[]?; .type == "Accepted" and .status == "True" and .observedGeneration == $generation) and
          any(.conditions[]?; .type == "Attached" and .status == "True" and .observedGeneration == $generation))' >/dev/null; then
      return 0
    fi
    sleep 2
  done
  printf 'Timed out waiting for MCP policy generation %s to be accepted and attached.\n' "$generation" >&2
  return 1
}

agentgateway_mcp_wait_ready() {
  local namespace="$1" generation attempt route
  kubectl rollout status deployment/agentgateway-mcp-calculator -n "$namespace" --timeout=120s
  kubectl rollout status deployment/agentgateway-mcp-catalog -n "$namespace" --timeout=120s
  kubectl wait --for=condition=Accepted --timeout=120s agentgatewaybackend/agentgateway-mcp -n "$namespace"
  generation="$(kubectl get agentgatewaypolicy agentgateway-mcp -n "$namespace" -o jsonpath='{.metadata.generation}')"
  agentgateway_mcp_wait_policy "$namespace" "$generation"
  for ((attempt = 0; attempt < 60; attempt++)); do
    route="$(kubectl get httproute agentgateway-mcp -n "$namespace" -o json)"
    if jq -e '
      .metadata.generation as $generation |
      any(.status.parents[]?;
        .parentRef.name == "agentgateway-proxy" and
        any(.conditions[]?; .type == "Accepted" and .status == "True" and .observedGeneration == $generation) and
        any(.conditions[]?; .type == "ResolvedRefs" and .status == "True" and .observedGeneration == $generation))' <<<"$route" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  printf 'Timed out waiting for MCP HTTPRoute acceptance and resolved references.\n' >&2
  return 1
}
