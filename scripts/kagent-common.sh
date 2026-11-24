#!/usr/bin/env bash

kagent_demo_managed_by="app.kubernetes.io/managed-by=kagent-demo"
kagent_demo_namespace_label="demo.kagent.dev/owned=true"
kagent_demo_api_groups=("api.kagent.dev" "ate.dev")

kagent_demo_release_namespaces() {
  printf '%s\n' \
    "kagent-crds $1" "kagent $1" \
    "substrate-crds ate-system" "substrate ate-system" \
    "substrate-atelet ate-system" \
    "substrate-podcert podcertificate-controller-system"
}

kagent_demo_require_commands() {
  local command_name

  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf 'Required command not found: %s\n' "$command_name" >&2
      return 1
    fi
  done
}

kagent_demo_require_context() {
  local context version major minor expected_context="${KAGENT_CONTEXT:-rancher-desktop}"
  context="$(kubectl config current-context)"
  if [[ "$context" != "$expected_context" ]]; then
    printf 'Expected kubectl context %s; current context is %s. Select the intended local cluster and set KAGENT_CONTEXT consistently; scripts do not switch contexts.\n' \
      "$expected_context" "$context" >&2
    return 1
  fi

  version="$(kubectl version -o json | jq -r '.serverVersion.gitVersion')"
  version="${version#v}"
  version="${version%%+*}"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]] ||
    (( major != 1 || minor < 37 )); then
    printf 'kagent v1.0.1 requires Kubernetes 1.37 or later; context %s reports %s.\n' \
      "$context" "$version" >&2
    return 1
  fi
}

kagent_demo_verify_recorded_context() {
  local record="$1" context recorded_context
  context="$(kubectl config current-context)"
  recorded_context="$(jq -r '.data.context // ""' <<<"$record")"
  if [[ "$recorded_context" != "$context" ]]; then
    printf 'The kagent ownership record context (%s) does not match the current context (%s); refusing to continue.\n' \
      "$recorded_context" "$context" >&2
    return 1
  fi
}

kagent_demo_require_helm() {
  local version major minor
  version="$(helm version --template '{{ .Version }}' 2>/dev/null)" || {
    printf 'Could not determine the Helm version; use Helm 3.12+ or Helm 4.x.\n' >&2
    return 1
  }
  version="${version#v}"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]] ||
    (( (major != 3 || minor < 12) && major != 4 )); then
    printf 'The kagent demo requires Helm 3.12+ or Helm 4.x; PATH selected %s. Put a compatible Helm binary named helm first on PATH.\n' \
      "$version" >&2
    return 1
  fi
}

kagent_demo_validate_namespace() {
  local namespace="$1"
  if [[ ! "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    [[ ${#namespace} -gt 63 ]] ||
    [[ "$namespace" == "kube-system" || "$namespace" == "ate-system" ||
      "$namespace" == "podcertificate-controller-system" ]]; then
    printf 'KAGENT_NAMESPACE must be a DNS label of at most 63 characters and must not be a kagent runtime namespace.\n' >&2
    return 1
  fi
}

kagent_demo_owner_check() {
  local kind="$1" name="$2" namespace="$3" object owner
  object="$(kubectl get "$kind" "$name" -n "$namespace" --ignore-not-found -o json)"
  if [[ -z "$object" ]]; then
    return 0
  fi
  owner="$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""' <<<"$object")"
  if [[ "$owner" != "kagent-demo" ]]; then
    printf 'Refusing to overwrite unowned %s/%s in namespace %s.\n' \
      "$kind" "$name" "$namespace" >&2
    return 1
  fi
}

kagent_demo_verify_mcp_policy() {
  local root_dir="$1" namespace="$2" expected actual
  expected="$(kubectl create --dry-run=client -n "$namespace" \
    -f "$root_dir/gateways/agentgateway/mcp/policy.yaml" -o json)"
  actual="$(kubectl get agentgatewaypolicy agentgateway-mcp -n "$namespace" -o json)"
  if ! jq -e --argjson expected "$expected" '
    .metadata.labels["app.kubernetes.io/managed-by"] == "agentgateway-mcp-demo" and
    .spec.targetRefs == $expected.spec.targetRefs and
    .spec.traffic.jwtAuthentication.mode == "Strict" and
    (.spec.traffic.jwtAuthentication.providers | length == 1) and
    .spec.traffic.jwtAuthentication.providers[0].issuer ==
      $expected.spec.traffic.jwtAuthentication.providers[0].issuer and
    .spec.traffic.jwtAuthentication.providers[0].audiences ==
      $expected.spec.traffic.jwtAuthentication.providers[0].audiences and
    .spec.traffic.jwtAuthentication.providers[0].validation.requiredClaims ==
      $expected.spec.traffic.jwtAuthentication.providers[0].validation.requiredClaims and
    .spec.backend.mcp.authorization == $expected.spec.backend.mcp.authorization and
    (.spec.traffic.jwtAuthentication.providers[0].jwks.inline |
      fromjson | .keys | type == "array" and length > 0)' \
    <<<"$actual" >/dev/null; then
    printf 'The MCP route policy is not the expected strict Bob/Alice authorization policy; refusing to install or run kagent agents.\n' >&2
    return 1
  fi
}

kagent_demo_verify_model_config() {
  local namespace="$1" gateway_namespace="$2" model="$3" config service
  config="$(kubectl get modelconfig default-model-config -n "$namespace" -o json)"
  service="$(kubectl get service kagent-model-gateway -n "$namespace" -o json)"
  if ! jq -e --arg endpoint \
    "http://kagent-model-gateway.$namespace.svc.cluster.local/v1" --arg model "$model" '
      .spec.provider == "OpenAI" and .spec.model == $model and
      .spec.openAI.baseUrl == $endpoint and
      .spec.openAI.apiFormat == "chatCompletions"' <<<"$config" >/dev/null ||
    ! jq -e --arg target "agentgateway-proxy.$gateway_namespace.svc.cluster.local" '
      .metadata.labels["app.kubernetes.io/managed-by"] == "kagent-demo" and
      .spec.type == "ExternalName" and .spec.externalName == $target and
      any(.spec.ports[]?; .port == 80)' <<<"$service" >/dev/null; then
    printf 'default-model-config or its DNS alias no longer targets the installed agentgateway model route.\n' >&2
    return 1
  fi
}

kagent_demo_log_boundary() {
  local previous current attempt
  previous="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  for ((attempt = 0; attempt < 30; attempt++)); do
    sleep 0.1
    current="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ "$current" != "$previous" ]]; then
      printf '%s' "$current"
      return 0
    fi
  done
  printf 'Timed out waiting for a new second to exclude MCP authentication calls from agent logs.\n' >&2
  return 1
}

kagent_demo_check_fresh_install() {
  local namespace="$1" name release_namespace release_json crd_json groups
  for name in "$namespace" ate-system podcertificate-controller-system; do
    if kubectl get namespace "$name" --ignore-not-found -o name | grep -q .; then
      printf 'Refusing to adopt existing namespace %s; kagent install requires all three runtime namespaces to be new.\n' \
        "$name" >&2
      return 1
    fi
  done

  release_json="$(helm list --all-namespaces --deployed --failed --pending --uninstalling --output json)"
  while read -r name release_namespace; do
    if jq -e --arg name "$name" --arg namespace "$release_namespace" \
      'any(.[]; .name == $name and .namespace == $namespace)' \
      <<<"$release_json" >/dev/null; then
      printf 'Refusing to adopt existing Helm release %s in %s.\n' \
        "$name" "$release_namespace" >&2
      return 1
    fi
  done < <(kagent_demo_release_namespaces "$namespace")

  crd_json="$(kubectl get crds -o json)"
  groups="$(printf '%s\n' "${kagent_demo_api_groups[@]}" | jq -R . | jq -s .)"
  if jq -e --argjson groups "$groups" '
    any(.items[]; .spec.group as $group | $groups | index($group) != null)' \
    <<<"$crd_json" >/dev/null; then
    printf 'Refusing to adopt existing kagent or Substrate CRDs; resolve the cluster ownership before installation.\n' >&2
    return 1
  fi
}

kagent_demo_capture_releases() {
  local namespace="$1" mode="${2:-complete}" release_namespace name revision chart uid
  local rows="[]" entry expected_version
  while read -r name release_namespace; do
    entry="$(helm list --namespace "$release_namespace" \
      --deployed --failed --pending --uninstalling --output json |
      jq -c --arg name "$name" '[.[] | select(.name == $name)] |
        if length == 1 then .[0] else empty end')" || return 1
    if [[ -z "$entry" ]]; then
      if [[ "$mode" == partial ]]; then continue; fi
      printf 'Could not record Helm release %s in %s.\n' \
        "$name" "$release_namespace" >&2
      return 1
    fi
    revision="$(jq -r '.revision' <<<"$entry")"
    chart="$(jq -r '.chart' <<<"$entry")"
    expected_version=1.0.0
    if [[ "$name" == kagent || "$name" == kagent-crds ]]; then expected_version=1.0.1; fi
    if [[ "$chart" != "$name-$expected_version" ]] ||
      [[ "$mode" != partial && "$(jq -r '.status' <<<"$entry")" != deployed ]]; then
      printf 'Helm release %s in %s has an unexpected chart or status.\n' \
        "$name" "$release_namespace" >&2
      return 1
    fi
    uid="$(kubectl get secret "sh.helm.release.v1.$name.v$revision" \
      -n "$release_namespace" -o json | jq -r '.metadata.uid')" || return 1
    if [[ -z "$uid" || "$uid" == null ]]; then
      printf 'Helm release %s has no release Secret UID.\n' "$name" >&2
      return 1
    fi
    rows="$(jq -c --arg name "$name" --arg namespace "$release_namespace" \
      --arg chart "$chart" --arg uid "$uid" --arg revision "$revision" \
      --arg status "$(jq -r '.status' <<<"$entry")" \
      '. + [{name:$name,namespace:$namespace,chart:$chart,uid:$uid,revision:$revision,status:$status}]' \
      <<<"$rows")"
  done < <(kagent_demo_release_namespaces "$namespace")
  jq -c 'sort_by(.namespace,.name)' <<<"$rows"
}

kagent_demo_capture_crds() {
  local groups crds
  groups="$(printf '%s\n' "${kagent_demo_api_groups[@]}" | jq -R . | jq -s .)"
  crds="$(kubectl get crds -o json | jq -c --argjson groups "$groups" '
    [.items[] | .spec.group as $group | select($groups | index($group) != null) |
      {name:.metadata.name,uid:.metadata.uid}] | sort_by(.name)')" || return 1
  printf '%s' "$crds"
}

kagent_demo_write_owner_record() {
  local namespace="$1" gateway_namespace="$2" releases="$3" crds="$4"
  local inventory="$5" custom_resources="$6" phase="$7" completed_step="$8" namespaces="$9"
  local context
  context="$(kubectl config current-context)"
  kubectl create configmap kagent-demo-ownership \
    -n "$namespace" \
    --from-literal=context="$context" \
    --from-literal=gateway-namespace="$gateway_namespace" \
    --from-literal=kagent-version=1.0.1 \
    --from-literal=releases="$releases" \
    --from-literal=crds="$crds" \
    --from-literal=inventory="$inventory" \
    --from-literal=custom-resources="$custom_resources" \
    --from-literal=phase="$phase" \
    --from-literal=completed-step="$completed_step" \
    --from-literal=namespaces="$namespaces" \
    --dry-run=client -o yaml |
    kubectl label --local -f - "$kagent_demo_managed_by" --overwrite -o yaml |
    kubectl apply -f -
}

kagent_demo_capture_namespaces() {
  local namespace="$1" name object entries="[]"
  for name in "$namespace" ate-system podcertificate-controller-system; do
    object="$(kubectl get namespace "$name" --ignore-not-found -o json)" || return 1
    if [[ -n "$object" ]]; then
      if ! jq -e '.metadata.labels["demo.kagent.dev/owned"] == "true"' \
        <<<"$object" >/dev/null; then
        printf 'Namespace %s is not owned by kagent-demo.\n' "$name" >&2
        return 1
      fi
      entries="$(jq -c --argjson object "$object" \
        '. + [{name:$object.metadata.name,uid:$object.metadata.uid}]' <<<"$entries")"
    fi
  done
  jq -c 'sort_by(.name)' <<<"$entries"
}

kagent_demo_prepare_namespace() {
  local namespace="$1" object
  object="$(kubectl get namespace "$namespace" --ignore-not-found -o json)"
  if [[ -n "$object" ]]; then
    if ! jq -e '.metadata.labels["demo.kagent.dev/owned"] == "true"' \
      <<<"$object" >/dev/null; then
      printf 'Refusing to adopt namespace %s.\n' "$namespace" >&2
      return 1
    fi
    return 0
  fi
  kubectl create namespace "$namespace" --dry-run=client -o yaml |
    kubectl label --local -f - "$kagent_demo_namespace_label" --overwrite -o yaml |
    kubectl create -f -
}

kagent_demo_checkpoint() {
  local namespace="$1" gateway_namespace="$2" phase="$3" completed_step="$4"
  local releases crds inventory custom_resources namespaces
  releases="$(kagent_demo_capture_releases "$namespace" partial)" || return 1
  crds="$(kagent_demo_capture_crds)" || return 1
  inventory="$(kagent_demo_capture_inventory "$namespace")" || return 1
  custom_resources="$(kagent_demo_capture_custom_resources)" || return 1
  namespaces="$(kagent_demo_capture_namespaces "$namespace")" || return 1
  kagent_demo_write_owner_record "$namespace" "$gateway_namespace" "$releases" "$crds" \
    "$inventory" "$custom_resources" "$phase" "$completed_step" "$namespaces"
}

kagent_demo_verify_installation() {
  local namespace="$1" record="$2" namespaces expected
  if ! jq -e '.metadata.labels["app.kubernetes.io/managed-by"] == "kagent-demo" and
    .data["kagent-version"] == "1.0.1" and
    (.data.phase | IN("installing", "failed", "ready", "cleaned", "cleanup-failed"))' \
    <<<"$record" >/dev/null; then
    printf 'Missing or invalid kagent-demo ownership record; refusing to adopt resources.\n' >&2
    return 1
  fi
  kagent_demo_verify_recorded_context "$record" || return 1
  namespaces="$(kagent_demo_capture_namespaces "$namespace")" || return 1
  expected="$(jq -cr '.data.namespaces | fromjson | sort_by(.name)' <<<"$record")" || return 1
  if [[ "$namespaces" != "$expected" ]]; then
    printf 'Runtime namespace identities changed; refusing to continue.\n' >&2
    return 1
  fi
  kagent_demo_verify_recorded_releases "$namespace" "$(jq -r '.data.releases' <<<"$record")" || return 1
  kagent_demo_verify_recorded_crds "$(jq -r '.data.crds' <<<"$record")" || return 1
  kagent_demo_verify_inventory "$namespace" "$(jq -r '.data.inventory' <<<"$record")" || return 1
  kagent_demo_check_pod_ownership "$namespace" || return 1
  kagent_demo_verify_custom_resources "$(jq -r '.data["custom-resources"]' <<<"$record")"
}

kagent_demo_capture_custom_resources() {
  local group resource resources objects entries custom_resources="[]"
  for group in "${kagent_demo_api_groups[@]}"; do
    resources="$(kubectl api-resources --api-group="$group" --output=name)" || return 1
    while IFS= read -r resource; do
      [[ -z "$resource" ]] && continue
      objects="$(kubectl get "$resource" --all-namespaces -o json)" || return 1
      entries="$(jq -c --arg resource "$resource" '
        [.items[] |
          select(.metadata.labels["app.kubernetes.io/managed-by"] != "kagent-byo-addon" or
            (.metadata.name != "kagent-byo-harness" and
             .metadata.name != "product-quote-byo-assistant")) | {
          resource:$resource,
          namespace:(.metadata.namespace // ""),
          name:.metadata.name,
          uid:.metadata.uid
        }]' <<<"$objects")" || return 1
      custom_resources="$(jq -cn --argjson existing "$custom_resources" \
        --argjson next "$entries" '$existing + $next')" || return 1
    done <<<"$resources"
  done
  jq -c 'sort_by(.namespace,.resource,.name)' <<<"$custom_resources"
}

kagent_demo_verify_custom_resources() {
  local expected="$1" actual
  if [[ -z "$expected" || "$expected" == null ]]; then
    printf 'Ownership record has no custom-resource inventory; refusing cleanup.\n' >&2
    return 1
  fi
  actual="$(kagent_demo_capture_custom_resources)" || return 1
  expected="$(jq -c 'sort_by(.namespace,.resource,.name)' <<<"$expected")" || return 1
  if [[ "$actual" != "$expected" ]]; then
    printf 'The kagent or Substrate custom-resource set changed since installation; refusing cleanup of shared CRDs.\n' >&2
    return 1
  fi
}

kagent_demo_capture_inventory() {
  local namespace="$1" resource resources objects entries inventory="[]" target_namespace object
  local target_namespaces=()
  for target_namespace in "$namespace" ate-system podcertificate-controller-system; do
    object="$(kubectl get namespace "$target_namespace" --ignore-not-found -o name)" || return 1
    if [[ -n "$object" ]]; then target_namespaces+=("$target_namespace"); fi
  done
  resources="$(kubectl api-resources --namespaced --verbs=list --output=name)" || return 1
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    for target_namespace in "${target_namespaces[@]}"; do
      objects="$(kubectl get "$resource" -n "$target_namespace" -o json)" || return 1
      entries="$(jq -c --arg resource "$resource" --arg namespace "$namespace" '
        [.items[] |
          select(.kind != "Event" and .kind != "Pod" and
            .kind != "Endpoint" and .kind != "EndpointSlice") |
          select(.metadata.labels["app.kubernetes.io/managed-by"] != "kagent-byo-addon" or
            (.metadata.name != "kagent-byo-ownership" and
             .metadata.name != "kagent-byo-harness" and
             .metadata.name != "product-quote-byo-assistant")) |
          select(.kind != "ConfigMap" or
            .metadata.name != "kagent-demo-ownership" or
            .metadata.namespace != $namespace) | {
          resource:$resource,
          namespace:.metadata.namespace,
          name:.metadata.name,
          uid:.metadata.uid
        }]' <<<"$objects")" || return 1
      inventory="$(jq -cn --argjson existing "$inventory" --argjson next "$entries" \
        '$existing + $next')" || return 1
    done
  done <<<"$resources"
  jq -c 'sort_by(.namespace,.resource,.name)' <<<"$inventory"
}

kagent_demo_check_pod_ownership() {
  local namespace="$1" target_namespace pods
  for target_namespace in "$namespace" ate-system podcertificate-controller-system; do
    if [[ -z "$(kubectl get namespace "$target_namespace" --ignore-not-found -o name)" ]]; then
      continue
    fi
    pods="$(kubectl get pods -n "$target_namespace" -o json)" || return 1
    if ! jq -e 'all(.items[];
      any(.metadata.ownerReferences[]?; .controller == true))' \
      <<<"$pods" >/dev/null; then
      printf 'Refusing cleanup while an unowned Pod exists in %s.\n' \
        "$target_namespace" >&2
      jq -r '.items[] | select(
        ([.metadata.ownerReferences[]? | select(.controller == true)] | length) == 0) |
        "  Pod/" + .metadata.name' <<<"$pods" >&2
      return 1
    fi
  done
}

kagent_demo_verify_inventory() {
  local namespace="$1" expected="$2" actual
  if [[ -z "$expected" || "$expected" == null ]]; then
    printf 'Ownership record has no complete namespace inventory; refusing cleanup of a partial installation.\n' >&2
    return 1
  fi
  actual="$(kagent_demo_capture_inventory "$namespace")" || return 1
  expected="$(jq -c 'sort_by(.namespace,.resource,.name)' <<<"$expected")" || return 1
  # Issued certificate requests are garbage-collected; never accept additions.
  if ! jq -en --argjson actual "$actual" --argjson expected "$expected" '
    ($actual - $expected | length) == 0 and
    all(($expected - $actual)[];
      .resource == "podcertificaterequests.certificates.k8s.io")' >/dev/null; then
    printf 'Resources in the kagent runtime namespaces changed since installation; refusing cleanup.\n' >&2
    printf 'Review new, removed, or replaced resources in %s, ate-system, and podcertificate-controller-system.\n' \
      "$namespace" >&2
    return 1
  fi
}

kagent_demo_verify_recorded_releases() {
  local namespace="$1" expected="$2" actual
  actual="$(kagent_demo_capture_releases "$namespace" partial)" || return 1
  expected="$(jq -c 'sort_by(.namespace,.name)' <<<"$expected")" || return 1
  if [[ "$actual" != "$expected" ]]; then
    printf 'Helm release identities, revisions, or statuses changed; refusing cleanup.\n' >&2
    return 1
  fi
}

kagent_demo_verify_recorded_crds() {
  local expected="$1" actual groups
  groups="$(printf '%s\n' "${kagent_demo_api_groups[@]}" | jq -R . | jq -s .)"
  actual="$(kubectl get crds -o json | jq -c --argjson groups "$groups" '
    [.items[] | .spec.group as $group | select($groups | index($group) != null) |
      {name:.metadata.name,uid:.metadata.uid}] | sort_by(.name)')" || return 1
  expected="$(jq -c 'sort_by(.name)' <<<"$expected")" || return 1
  if [[ "$actual" != "$expected" ]]; then
    printf 'kagent/Substrate CRD set changed since installation; refusing cleanup.\n' >&2
    return 1
  fi
}
