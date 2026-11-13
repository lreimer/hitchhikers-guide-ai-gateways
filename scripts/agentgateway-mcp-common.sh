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
  "service agentgateway-mcp-staging"
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
  local namespace="$1" state release gateway policies base_policy model current_route route_labels shared_routes
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
      .name == "http" and .protocol == "HTTP" and .port == 80 and
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
  if ! kubectl get service agentgateway-proxy -n "$namespace" -o json |
    jq -e '.spec.type == "ClusterIP" and
      any(.spec.ports[]?; .port == 80) and
      ((.spec.externalIPs // []) | length == 0) and
      ((.status.loadBalancer.ingress // []) | length == 0)' >/dev/null; then
    printf 'The existing proxy Service must remain internal ClusterIP without external addresses.\n' >&2
    return 1
  fi
  model="$(jq -r '.data.model' <<<"$state")"
  base_policy="$(kubectl get agentgatewaypolicy agentgateway-demo -n "$namespace" -o json)"
  if ! jq -e --arg model "$model" '
    .metadata.labels["app.kubernetes.io/managed-by"] == "agentgateway-demo" and
    (.spec.targetRefs | length == 2) and
    all(.spec.targetRefs[];
      .group == "gateway.networking.k8s.io" and .kind == "HTTPRoute" and
      (.name == "agentgateway-llm" or .name == "agentgateway-readiness")) and
    any(.spec.targetRefs[]; .name == "agentgateway-llm") and
    any(.spec.targetRefs[]; .name == "agentgateway-readiness") and
    .spec.traffic.apiKeyAuthentication.mode == "Strict" and
    .spec.traffic.apiKeyAuthentication.configMapSelector.matchLabels["agentgateway.dev/apikey"] == "true" and
    .spec.traffic.authorization.action == "Require" and
    any(.spec.traffic.authorization.policy.matchExpressions[]?;
      contains("request.path == \"/v1/chat/completions\"") and
      contains("json(request.body).model == \"" + $model + "\"")) and
    any(.spec.traffic.rateLimit.local[]?;
      .requests > 0 and (.key | contains("apiKey.user_id"))) and
    any(.spec.traffic.rateLimit.local[]?;
      .tokens > 0 and (.key | contains("apiKey.user_id")))' <<<"$base_policy" >/dev/null; then
    printf 'Base LLM/readiness security is missing or weakened. Restore its strict API-key policy, model restriction, per-user request limits, and token budget before installing MCP.\n' >&2
    return 1
  fi
  shared_routes="$(kubectl get httproutes -n "$namespace" -o json)"
  if ! jq -e --arg namespace "$namespace" '
    [.items[] | select(.metadata.name != "agentgateway-mcp") |
      select(any(.spec.parentRefs[]?;
        .name == "agentgateway-proxy" and
        (.namespace == null or .namespace == $namespace))) |
      select(any(.spec.rules[]?;
        ((.matches // []) | length == 0) or
        any(.matches[]?;
          (.path.type // "PathPrefix") as $type |
          (.path.value // "/") as $path |
          ($type == "Exact" and $path == "/mcp") or
          ($type == "PathPrefix" and
            ($path | test("^/*$|^/mcp/*$"))) or
          $type == "RegularExpression")))] |
    length == 0' <<<"$shared_routes" >/dev/null; then
    printf 'Another route on agentgateway-proxy can match /mcp. Reserve this path for the MCP add-on; ambiguous regex routes must use a separate Gateway.\n' >&2
    return 1
  fi
  # Gateway/GatewayClass authentication and quotas would also apply to /mcp.
  policies="$(kubectl get agentgatewaypolicies --all-namespaces -o json)"
  current_route="$(kubectl get httproute agentgateway-mcp -n "$namespace" --ignore-not-found -o json)"
  route_labels='{"app.kubernetes.io/managed-by":"agentgateway-mcp-demo"}'
  if [[ -n "$current_route" ]]; then
    route_labels="$(jq -c '
      (.metadata.labels // {}) + {"app.kubernetes.io/managed-by":"agentgateway-mcp-demo"}' <<<"$current_route")"
  fi
  if ! jq -e --arg namespace "$namespace" --argjson routeLabels "$route_labels" '
    [.items[] | select(.metadata.namespace == $namespace and
      .metadata.name != "agentgateway-mcp") |
      select(any(.spec.targetRefs[]?;
        .kind == "HTTPRoute" and .name == "agentgateway-mcp") or
        any(.spec.targetSelectors[]?;
          .kind == "HTTPRoute" and
          all((.matchLabels // {}) | to_entries[];
            $routeLabels[.key] == .value)))] |
    length == 0' <<<"$policies" >/dev/null; then
    printf 'Another policy targets the MCP HTTPRoute. Remove competing equal-specificity policies before running this add-on.\n' >&2
    return 1
  fi
  if ! jq -e --arg namespace "$namespace" \
    --argjson gatewayLabels "$(jq -c '.metadata.labels // {}' <<<"$gateway")" '
    [.items[] | select(any(.spec.targetRefs[]?;
      (.kind == "Gateway" and .name == "agentgateway-proxy" and
        ($namespace == .namespace or .namespace == null)) or
      (.kind == "GatewayClass" and .name == "agentgateway")) or
      any(.spec.targetSelectors[]?;
        .kind == "Gateway" and
        all((.matchLabels // {}) | to_entries[];
          $gatewayLabels[.key] == .value))) |
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
          any(.conditions[]?; .type == "Accepted" and .status == "True" and .reason == "Valid" and .observedGeneration == $generation) and
          any(.conditions[]?; .type == "Attached" and .status == "True" and .observedGeneration == $generation))' >/dev/null; then
      return 0
    fi
    sleep 2
  done
  printf 'Timed out waiting for MCP policy generation %s to be fully Valid, accepted, and attached.\n' "$generation" >&2
  return 1
}

agentgateway_mcp_wait_ready() {
  local namespace="$1" generation
  kubectl rollout status deployment/agentgateway-mcp-calculator -n "$namespace" --timeout=120s
  kubectl rollout status deployment/agentgateway-mcp-catalog -n "$namespace" --timeout=120s
  kubectl wait --for=condition=Accepted --timeout=120s agentgatewaybackend/agentgateway-mcp -n "$namespace"
  generation="$(kubectl get agentgatewaypolicy agentgateway-mcp -n "$namespace" -o jsonpath='{.metadata.generation}')"
  agentgateway_mcp_wait_policy "$namespace" "$generation"
  agentgateway_mcp_wait_route "$namespace"
}

agentgateway_mcp_wait_route() {
  local namespace="$1" attempt route
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
