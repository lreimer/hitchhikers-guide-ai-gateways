#!/usr/bin/env bash
set -euo pipefail

namespace="${BIFROST_NAMESPACE:-bifrost-demo}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for command in kubectl helm openssl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  printf 'Set OPENAI_API_KEY before installing the demo.\n' >&2
  exit 1
fi

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

for credential in encryption-key setup-token; do
  existing_secret="$(kubectl get secret "bifrost-$credential" \
    --namespace "$namespace" --ignore-not-found -o name)"
  if [[ -z "$existing_secret" ]]; then
    openssl rand -hex 32 | tr -d '\n' |
      kubectl create secret generic "bifrost-$credential" \
        --namespace "$namespace" \
        --from-file="$credential=/dev/stdin" \
        --dry-run=client -o yaml |
      kubectl apply -f -
  fi
done

printf '%s' "$OPENAI_API_KEY" |
  kubectl create secret generic bifrost-provider-keys \
    --namespace "$namespace" \
    --from-file=openai-api-key=/dev/stdin \
    --dry-run=client -o yaml |
  kubectl apply -f -

helm repo add bifrost https://maximhq.github.io/bifrost/helm-charts --force-update
helm repo update bifrost
helm upgrade --install bifrost bifrost/bifrost \
  --namespace "$namespace" \
  --values "$root_dir/gateways/bifrost/values.yaml"

printf '\nBifrost installed in namespace %s.\n' "$namespace"
printf 'Retrieve the dashboard setup token as described in gateways/bifrost/README.md.\n'
printf 'Run `make bifrost-port-forward BIFROST_NAMESPACE=%s` to access it locally.\n' "$namespace"
