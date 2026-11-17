#!/usr/bin/env bash

kagent_demo_managed_by="app.kubernetes.io/managed-by=kagent-demo"
kagent_demo_releases=(
  "kagent-crds kagent"
  "kagent kagent"
  "substrate-crds ate-system"
  "substrate ate-system"
  "substrate-atelet ate-system"
  "substrate-podcert podcertificate-controller-system"
)
kagent_demo_api_groups=("api.kagent.dev" "ate.dev")

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
  local context version major minor
  context="$(kubectl config current-context)"
  if [[ "$context" != rancher-desktop ]]; then
    printf 'This demo requires the rancher-desktop kubectl context; current context is %s. Kind is not supported.\n' \
      "$context" >&2
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
    printf 'kagent v1.0.1 requires Kubernetes 1.37 or later; Rancher Desktop reports %s.\n' \
      "$version" >&2
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

kagent_demo_check_fresh_install() {
  local namespace="$1" name release_namespace release_json crd_json groups
  for name in "$namespace" ate-system podcertificate-controller-system; do
    if kubectl get namespace "$name" --ignore-not-found -o name | grep -q .; then
      printf 'Refusing to adopt existing namespace %s; kagent install requires all three runtime namespaces to be new.\n' \
        "$name" >&2
      return 1
    fi
  done

  release_json="$(helm list --all-namespaces --output json)"
  for release in "${kagent_demo_releases[@]}"; do
    read -r name release_namespace <<<"$release"
    if jq -e --arg name "$name" --arg namespace "$release_namespace" \
      'any(.[]; .name == $name and .namespace == $namespace)' \
      <<<"$release_json" >/dev/null; then
      printf 'Refusing to adopt existing Helm release %s in %s.\n' \
        "$name" "$release_namespace" >&2
      return 1
    fi
  done

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
  local namespace="$1" release release_namespace name revision chart uid rows="[]"
  for release in "${kagent_demo_releases[@]}"; do
    read -r name release_namespace <<<"$release"
    local entry
    entry="$(helm list --namespace "$release_namespace" --output json |
      jq -c --arg name "$name" '[.[] | select(.name == $name and .status == "deployed")] |
        if length == 1 then .[0] else empty end')"
    if [[ -z "$entry" ]]; then
      printf 'Could not record exactly one deployed Helm release %s in %s.\n' \
        "$name" "$release_namespace" >&2
      return 1
    fi
    revision="$(jq -r '.revision' <<<"$entry")"
    chart="$(jq -r '.chart' <<<"$entry")"
    uid="$(kubectl get secret "sh.helm.release.v1.$name.v$revision" \
      -n "$release_namespace" -o json | jq -r '.metadata.uid')"
    rows="$(jq -c --arg name "$name" --arg namespace "$release_namespace" \
      --arg chart "$chart" --arg uid "$uid" '. + [{name:$name,namespace:$namespace,chart:$chart,uid:$uid}]' \
      <<<"$rows")"
  done

  jq -e --arg namespace "$namespace" '
    length == 6 and
    all(.[];
      .uid | type == "string" and length > 0) and
    any(.[]; .name == "kagent" and .namespace == $namespace and .chart == "kagent-1.0.1") and
    any(.[]; .name == "kagent-crds" and .namespace == $namespace and .chart == "kagent-crds-1.0.1") and
    any(.[]; .name == "substrate" and .namespace == "ate-system" and .chart == "substrate-1.0.0") and
    any(.[]; .name == "substrate-crds" and .namespace == "ate-system" and .chart == "substrate-crds-1.0.0") and
    any(.[]; .name == "substrate-atelet" and .namespace == "ate-system" and .chart == "substrate-atelet-1.0.0") and
    any(.[]; .name == "substrate-podcert" and .namespace == "podcertificate-controller-system" and .chart == "substrate-podcert-1.0.0")' \
    <<<"$rows" >/dev/null || {
    printf 'Installed Helm releases do not match the pinned kagent v1.0.1/Substrate v1.0.0 set.\n' >&2
    return 1
  }
  printf '%s' "$rows"
}

kagent_demo_capture_crds() {
  local groups crds
  groups="$(printf '%s\n' "${kagent_demo_api_groups[@]}" | jq -R . | jq -s .)"
  crds="$(kubectl get crds -o json | jq -c --argjson groups "$groups" '
    [.items[] | .spec.group as $group | select($groups | index($group) != null) |
      {name:.metadata.name,uid:.metadata.uid}] | sort_by(.name)')"
  if [[ "$(jq 'length' <<<"$crds")" -eq 0 ]]; then
    printf 'No kagent or Substrate CRDs were installed.\n' >&2
    return 1
  fi
  printf '%s' "$crds"
}

kagent_demo_write_owner_record() {
  local namespace="$1" gateway_namespace="$2" releases="$3" crds="$4"
  local inventory_file="$5" custom_resources_file="$6"
  kubectl create configmap kagent-demo-ownership \
    -n "$namespace" \
    --from-literal=context=rancher-desktop \
    --from-literal=gateway-namespace="$gateway_namespace" \
    --from-literal=kagent-version=1.0.1 \
    --from-literal=releases="$releases" \
    --from-literal=crds="$crds" \
    --from-file=inventory="$inventory_file" \
    --from-file=custom-resources="$custom_resources_file" \
    --dry-run=client -o yaml |
    kubectl label --local -f - "$kagent_demo_managed_by" --overwrite -o yaml |
    kubectl apply -f -
}

kagent_demo_capture_custom_resources() {
  local group resource objects entries custom_resources="[]"
  for group in "${kagent_demo_api_groups[@]}"; do
    while IFS= read -r resource; do
      [[ -z "$resource" ]] && continue
      objects="$(kubectl get "$resource" --all-namespaces -o json)"
      entries="$(jq -c --arg resource "$resource" '
        [.items[] | {
          resource:$resource,
          namespace:(.metadata.namespace // ""),
          name:.metadata.name,
          uid:.metadata.uid
        }]' <<<"$objects")"
      custom_resources="$(jq -cn --argjson existing "$custom_resources" \
        --argjson next "$entries" '$existing + $next')"
    done < <(kubectl api-resources --api-group="$group" --output=name)
  done
  jq -c 'sort_by(.namespace,.resource,.name)' <<<"$custom_resources"
}

kagent_demo_verify_custom_resources() {
  local expected="$1" actual
  if [[ -z "$expected" || "$expected" == null ]]; then
    printf 'Ownership record has no custom-resource inventory; refusing cleanup.\n' >&2
    return 1
  fi
  actual="$(kagent_demo_capture_custom_resources)"
  expected="$(jq -c 'sort_by(.namespace,.resource,.name)' <<<"$expected")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'The kagent or Substrate custom-resource set changed since installation; refusing cleanup of shared CRDs.\n' >&2
    return 1
  fi
}

kagent_demo_capture_inventory() {
  local namespace="$1" resource objects entries inventory="[]" target_namespace
  for resource in $(kubectl api-resources --namespaced --verbs=list --output=name); do
    for target_namespace in "$namespace" ate-system podcertificate-controller-system; do
      objects="$(kubectl get "$resource" -n "$target_namespace" -o json)"
      entries="$(jq -c --arg resource "$resource" --arg namespace "$namespace" '
        [.items[] |
          select(.kind != "Event" and .kind != "Pod" and
            .kind != "Endpoint" and .kind != "EndpointSlice") |
          select(.kind != "ConfigMap" or
            .metadata.name != "kagent-demo-ownership" or
            .metadata.namespace != $namespace) | {
          resource:$resource,
          namespace:.metadata.namespace,
          name:.metadata.name,
          uid:.metadata.uid
        }]' <<<"$objects")"
      inventory="$(jq -cn --argjson existing "$inventory" --argjson next "$entries" \
        '$existing + $next')"
    done
  done
  jq -c 'sort_by(.namespace,.resource,.name)' <<<"$inventory"
}

kagent_demo_check_pod_ownership() {
  local namespace="$1" target_namespace pods
  for target_namespace in "$namespace" ate-system podcertificate-controller-system; do
    pods="$(kubectl get pods -n "$target_namespace" -o json)"
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
  actual="$(kagent_demo_capture_inventory "$namespace")"
  expected="$(jq -c 'sort_by(.namespace,.resource,.name)' <<<"$expected")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Resources in the kagent runtime namespaces changed since installation; refusing cleanup.\n' >&2
    printf 'Review new, removed, or replaced resources in %s, ate-system, and podcertificate-controller-system.\n' \
      "$namespace" >&2
    return 1
  fi
}

kagent_demo_verify_recorded_releases() {
  local namespace="$1" expected="$2" release name release_namespace revision secret_uid current expected_release
  for release in "${kagent_demo_releases[@]}"; do
    read -r name release_namespace <<<"$release"
    expected_release="$(jq -c --arg name "$name" --arg namespace "$release_namespace" \
      '.[] | select(.name == $name and .namespace == $namespace)' <<<"$expected")"
    if [[ -z "$expected_release" ]]; then
      printf 'Ownership record is missing Helm release %s in %s.\n' "$name" "$release_namespace" >&2
      return 1
    fi
    current="$(helm list --namespace "$release_namespace" --output json |
      jq -c --arg name "$name" '[.[] | select(.name == $name)] | if length == 1 then .[0] else empty end')"
    if [[ -z "$current" || "$(jq -r '.status' <<<"$current")" != deployed ||
      "$(jq -r '.chart' <<<"$current")" != "$(jq -r '.chart' <<<"$expected_release")" ]]; then
      printf 'Helm release %s in %s is missing, changed, or not deployed; refusing cleanup.\n' \
        "$name" "$release_namespace" >&2
      return 1
    fi
    revision="$(jq -r '.revision' <<<"$current")"
    secret_uid="$(kubectl get secret "sh.helm.release.v1.$name.v$revision" \
      -n "$release_namespace" -o json | jq -r '.metadata.uid')"
    if [[ "$secret_uid" != "$(jq -r '.uid' <<<"$expected_release")" ]]; then
      printf 'Helm release %s in %s has a different release identity; refusing cleanup.\n' \
        "$name" "$release_namespace" >&2
      return 1
    fi
  done
}

kagent_demo_verify_recorded_crds() {
  local expected="$1" actual groups
  groups="$(printf '%s\n' "${kagent_demo_api_groups[@]}" | jq -R . | jq -s .)"
  actual="$(kubectl get crds -o json | jq -c --argjson groups "$groups" '
    [.items[] | .spec.group as $group | select($groups | index($group) != null) |
      {name:.metadata.name,uid:.metadata.uid}] | sort_by(.name)')"
  expected="$(jq -c 'sort_by(.name)' <<<"$expected")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'kagent/Substrate CRD set changed since installation; refusing cleanup.\n' >&2
    return 1
  fi
}
