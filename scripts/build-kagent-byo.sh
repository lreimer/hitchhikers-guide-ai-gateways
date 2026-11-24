#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
repository="${KAGENT_BYO_IMAGE_REPOSITORY:-ghcr.io/lreimer/hitchhikers-guide-ai-gateways}"
tag="${KAGENT_BYO_IMAGE_TAG:-byo-quote-$(git -C "$root_dir" rev-parse --short HEAD)}"
platform="${KAGENT_BYO_PLATFORM:-linux/arm64}"

for command_name in docker git jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
done
if [[ "$repository" != ghcr.io/lreimer/hitchhikers-guide-ai-gateways ]] ||
  [[ ! "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
  [[ ! "$platform" =~ ^linux/(amd64|arm64)$ ]]; then
  printf 'Use the confirmed public GHCR repository, a valid image tag, and linux/amd64 or linux/arm64.\n' >&2
  exit 1
fi

metadata_file="$(mktemp "${TMPDIR:-/tmp}/kagent-byo-build.XXXXXX")"
trap 'rm -f "$metadata_file"' EXIT
docker buildx build \
  --platform "$platform" \
  --push \
  --tag "$repository:$tag" \
  --metadata-file "$metadata_file" \
  "$root_dir/agents/kagent/byo"
digest="$(jq -er '."containerimage.digest" | select(test("^sha256:[a-f0-9]{64}$"))' \
  "$metadata_file")"
printf "export KAGENT_BYO_IMAGE='%s@%s'\n" "$repository" "$digest"
