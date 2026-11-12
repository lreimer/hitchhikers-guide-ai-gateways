#!/usr/bin/env bash
set -euo pipefail

namespace="${NAMESPACE:-ai-gateway-demo}"
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

openssl rand -base64 32 |
  kubectl create secret generic bifrost-encryption-key \
    --namespace "$namespace" \
    --from-file=encryption-key=/dev/stdin \
    --dry-run=client -o yaml |
  kubectl apply -f -

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
printf 'Run `make bifrost-port-forward NAMESPACE=%s` to access it locally.\n' "$namespace"
