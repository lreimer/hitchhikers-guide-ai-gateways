#!/usr/bin/env bash
set -euo pipefail

namespace="${KRAKEND_NAMESPACE:-krakend-demo}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'Required command not found: kubectl\n' >&2
  exit 1
fi

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap krakend-config \
  --namespace "$namespace" \
  --from-file=krakend.json="$root_dir/gateways/krakend/krakend.json" \
  --dry-run=client -o yaml |
  kubectl apply -f -
kubectl apply --namespace "$namespace" -f "$root_dir/gateways/krakend/deployment.yaml"

printf '\nKrakenD Community Edition installed in namespace %s.\n' "$namespace"
printf 'Run `make krakend-port-forward KRAKEND_NAMESPACE=%s` to access it locally.\n' "$namespace"
