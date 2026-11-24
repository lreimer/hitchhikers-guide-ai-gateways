#!/usr/bin/env bash

kagent_byo_managed_by="app.kubernetes.io/managed-by=kagent-byo-addon"
kagent_byo_resource_kinds=("harness" "agenttemplate" "agent")
kagent_byo_resource_names=("kagent-byo-harness" "product-quote-byo-assistant" "product-quote-byo-assistant")

kagent_byo_validate_image() {
  local image="$1"
  if [[ ! "$image" =~ ^ghcr\.io/lreimer/hitchhikers-guide-ai-gateways@sha256:[a-f0-9]{64}$ ]]; then
    printf 'KAGENT_BYO_IMAGE must be the confirmed public GHCR repository pinned by SHA-256 digest.\n' >&2
    return 1
  fi
}

kagent_byo_validate_install_phase() {
  case "$1" in
    ready|installing|failed|cleaned) ;;
    *)
      printf 'The BYO add-on is being cleaned up; finish make kagent-byo-uninstall before reinstalling.\n' >&2
      return 1
      ;;
  esac
}

kagent_byo_capture_resources() {
  local namespace="$1" kind name object uid rows="[]"
  local index
  for index in "${!kagent_byo_resource_kinds[@]}"; do
    kind="${kagent_byo_resource_kinds[$index]}"
    name="${kagent_byo_resource_names[$index]}"
    object="$(kubectl get "$kind" "$name" -n "$namespace" --ignore-not-found -o json)" || return 1
    if [[ -z "$object" ]]; then
      continue
    fi
    if ! jq -e --arg owner "kagent-byo-addon" '
      .metadata.labels["app.kubernetes.io/managed-by"] == $owner' <<<"$object" >/dev/null; then
      printf 'Refusing to adopt unowned %s/%s in namespace %s.\n' "$kind" "$name" "$namespace" >&2
      return 1
    fi
    uid="$(jq -r '.metadata.uid // empty' <<<"$object")" || return 1
    if [[ -z "$uid" ]]; then
      printf 'Owned %s/%s has no Kubernetes UID.\n' "$kind" "$name" >&2
      return 1
    fi
    rows="$(jq -cn --argjson rows "$rows" --arg kind "$kind" --arg name "$name" \
      --arg uid "$uid" '$rows + [{kind:$kind,name:$name,uid:$uid}]')" || return 1
  done
  jq -c 'sort_by(.kind,.name)' <<<"$rows"
}

kagent_byo_verify_recorded_resources() {
  local namespace="$1" expected="$2" phase="$3" actual
  actual="$(kagent_byo_capture_resources "$namespace")" || return 1
  expected="$(jq -c 'sort_by(.kind,.name)' <<<"$expected")" || return 1
  if ! jq -en --argjson actual "$actual" --argjson expected "$expected" \
    --arg phase "$phase" '
    all($actual[]; . as $resource |
      any($expected[]; .kind == $resource.kind and .name == $resource.name and .uid == $resource.uid)) and
    (if $phase == "cleanup-failed" then true else
      all($expected[]; . as $resource |
        any($actual[]; .kind == $resource.kind and .name == $resource.name and .uid == $resource.uid))
    end)' \
    >/dev/null; then
    printf 'BYO resource identities changed since the ownership record; refusing to continue.\n' >&2
    return 1
  fi
}

kagent_byo_verify_record() {
  local namespace="$1" record="$2" context phase
  if ! jq -e '
    .metadata.labels["app.kubernetes.io/managed-by"] == "kagent-byo-addon" and
    (.data.phase | IN("installing", "failed", "ready", "cleanup-failed", "cleaned")) and
    (.data.resources | fromjson | type == "array") and
    (.data.sessions | fromjson | type == "array")' <<<"$record" >/dev/null; then
    printf 'Missing or invalid BYO add-on ownership record; refusing to adopt resources.\n' >&2
    return 1
  fi
  context="$(kubectl config current-context)"
  phase="$(jq -r '.data.phase' <<<"$record")"
  if [[ "$(jq -r '.data.context // ""' <<<"$record")" != "$context" ]]; then
    printf 'The BYO ownership record context does not match the current kubectl context; refusing to continue.\n' >&2
    return 1
  fi
  kagent_byo_verify_recorded_resources "$namespace" \
    "$(jq -r '.data.resources' <<<"$record")" "$phase"
}

kagent_byo_write_record() {
  local namespace="$1" image="$2" phase="$3" step="$4" resources="$5" sessions="$6"
  local context
  context="$(kubectl config current-context)" || return 1
  kubectl create configmap kagent-byo-ownership -n "$namespace" \
    --from-literal=context="$context" \
    --from-literal=image="$image" \
    --from-literal=phase="$phase" \
    --from-literal=completed-step="$step" \
    --from-literal=resources="$resources" \
    --from-literal=sessions="$sessions" \
    --dry-run=client -o yaml |
    kubectl label --local -f - "$kagent_byo_managed_by" --overwrite -o yaml |
    kubectl apply -f -
}

kagent_byo_track_session() {
  local namespace="$1" session="$2" operation="$3" record sessions
  record="$(kubectl get configmap kagent-byo-ownership -n "$namespace" -o json)" || return 1
  if ! jq -e --arg operation "$operation" '
    .metadata.labels["app.kubernetes.io/managed-by"] == "kagent-byo-addon" and
    (.data.phase == "ready" or ($operation == "remove" and .data.phase == "cleanup-failed"))' \
    <<<"$record" >/dev/null; then
    printf 'Cannot track a Session without the ready BYO ownership record.\n' >&2
    return 1
  fi
  case "$operation" in
    add)
      sessions="$(jq -c --arg session "$session" '
        (.data.sessions | fromjson) as $sessions |
        if $sessions | index($session) then $sessions else $sessions + [$session] end' \
        <<<"$record")" || return 1
      ;;
    remove)
      sessions="$(jq -c --arg session "$session" \
        '(.data.sessions | fromjson) | map(select(. != $session))' <<<"$record")" || return 1
      ;;
    *)
      printf 'Unknown BYO Session tracking operation: %s\n' "$operation" >&2
      return 1
      ;;
  esac
  jq -c --arg sessions "$sessions" '
    .data.sessions = $sessions |
    {apiVersion,kind,metadata:{name:.metadata.name,namespace:.metadata.namespace,
      labels:.metadata.labels},data}' <<<"$record" | kubectl apply -f -
}

kagent_byo_actor_uids() {
  jq -c '[.actors[]?.metadata.uid | select(type == "string")] | unique' <<<"$1"
}

kagent_byo_find_new_actor() {
  jq -ce --argjson previous "$2" '
    [.actors[]? |
      select((.metadata.uid // "") as $uid | ($previous | index($uid)) == null)] |
    if length == 1 then .[0] else error("expected exactly one new Substrate actor") end' \
    <<<"$1"
}

kagent_byo_actor_snapshot_generation() {
  jq -er --arg uid "$2" '
    [.actors[]? | select(.metadata.uid == $uid) |
      .status.snapshots[]?.generation] | max // 0' <<<"$1"
}

kagent_byo_actor_has_completed_snapshot() {
  jq -e --arg uid "$2" --argjson minimum_generation "$3" '
    [.actors[]? | select(.metadata.uid == $uid)] as $actors |
    ($actors | length) == 1 and
    $actors[0].status.state == "ACTOR_STATE_SUSPENDED" and
    any($actors[0].status.snapshots[]?;
      .generation > $minimum_generation and
      .fidelity == "SNAPSHOT_FIDELITY_VOLUMES" and
      .durableSnapshot.state == "SNAPSHOT_STORAGE_STATE_COMPLETED")' <<<"$1" >/dev/null
}

kagent_byo_validate_unknown_response() {
  local response_file="$1"
  if ! grep -Eiq 'unknown|not found|couldn.t find|could not find|does not exist|not in (the )?catalog|cannot|can.t|unable|error|unavailable|don.t know|do not know|no such product' \
    "$response_file" ||
    grep -Eq 'Total:|\$[0-9]' "$response_file"; then
    printf 'BYO quote agent did not identify the unknown product without producing a price or total.\n' >&2
    cat "$response_file" >&2
    return 1
  fi
}
