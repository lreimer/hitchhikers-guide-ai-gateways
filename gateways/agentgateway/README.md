# Governed LLM access with agentgateway

This local Kubernetes demo exposes a single OpenAI-compatible Chat Completions
route through agentgateway. It demonstrates hashed client API keys, model
authorization, request throttling, per-client token budgets, response usage,
and individual key revocation. Mock mode is the default and does not require
provider credentials or make external inference calls.

## Tested versions and prerequisites

The pinned implementation baseline is:

| Component | Version |
| --- | --- |
| Kubernetes | 1.36.5 (minikube 1.39.0, Docker driver) |
| Kubernetes Gateway API | 1.6.3 standard CRDs when installation is required; compatible existing 1.4.x–1.6.x standard CRDs are reused |
| agentgateway CRD chart, controller, and proxy | `v1.7.0` |
| Helm | 4.2.3 |
| httpbun | `sharat87/httpbun:4ec9d2e361c5bc1ca5b1ac8b90837883abfac12e`, pinned by OCI digest `sha256:6730442b216f3a8f580a37a0a9dd496f2e7d11419f226274509a9ea29a2d3169` |

agentgateway `v1.7.x` supports Kubernetes 1.32–1.37 and Gateway API 1.4–1.6.
The installer checks these supported ranges. It reuses existing standard
Gateway API CRDs only when all required core CRDs report a compatible,
consistent bundle version; otherwise it installs the pinned `v1.6.3`
standard bundle without force-adopting resources.

Prerequisites:

- A Kubernetes 1.32–1.37 cluster and a working `kubectl` context
- Helm 3.12 or later
- `curl`, `jq`, `openssl`, and standard shell utilities
- Cluster permissions to install Gateway API and agentgateway CRDs, create a
  GatewayClass, and install the controller
- Stable local client keys for Alice and Bob (instructions below)
- `OPENAI_API_KEY` only when explicitly installing and running OpenAI mode

The agentgateway controller release is shared at the cluster level in the
`agentgateway-system` namespace. Demo resources are installed in the dedicated
`agentgateway-demo` namespace by default, separate from Bifrost. Set
`AGENTGATEWAY_NAMESPACE` to override it. The generated proxy Service is
`ClusterIP` only, and routes are restricted to the Gateway's namespace.

## Prepare client keys

Generate and retain local keys once; the installer hashes them with SHA-256
before storing them in a Kubernetes ConfigMap. The ConfigMap contains only
hashes and stable `user_id` metadata. Do not rotate or regenerate these keys
unless you intend to revoke the previous ones. Keep this local file private:

```sh
key_file="$HOME/.config/agentgateway-demo/keys.env"
if [ ! -e "$key_file" ]; then
  (umask 077
   mkdir -p "$(dirname "$key_file")"
   chmod 700 "$(dirname "$key_file")"
   printf 'export AGENTGATEWAY_ALICE_KEY=%s\n' "$(openssl rand -hex 32)" > "$key_file"
   printf 'export AGENTGATEWAY_BOB_KEY=%s\n' "$(openssl rand -hex 32)" >> "$key_file")
fi
source "$key_file"
```

Source the same file in each terminal that runs a demo command. The keys are
not printed by the scripts and are not written to repository files, Kubernetes
Secrets, or request logs. The key file is user-managed local credential
storage, not a temporary demo artifact.

## Install and run the mock walkthrough

From the repository root, install in the default mock mode:

```sh
make agentgateway-install
```

In another terminal, source the local key file and start a localhost-only
port-forward:

```sh
source "$HOME/.config/agentgateway-demo/keys.env"
make agentgateway-port-forward
```

In a third terminal, source the key file and run the bounded walkthrough:

```sh
source "$HOME/.config/agentgateway-demo/keys.env"
make agentgateway-demo
```

The walkthrough checks, in order:

1. Missing and invalid keys return `401`.
2. Alice can request the allowed model, and the response has nonempty content
   and numeric token usage.
3. Missing or malformed model input is rejected, and a forbidden model returns
   `403`.
4. A per-client request limit returns a gateway-generated `429`.
5. Alice's independent token budget returns a gateway-generated `429`, while
   Bob's budget still allows a request.
6. Alice recovers after quota refill, then her revoked key returns `401` while
   Bob remains authorized.

The request-limit phase uses one request per minute plus a burst of one. The
token-budget phase uses 20 tokens per second and a nonbinding request limit.
The phases change only the rate-limit section of the same policy.
Authentication and model authorization remain enabled. The script uses
bounded request counts and waits up to 30 seconds for token refill; on success,
failure, or interruption it restores the initial policy and both client keys.
A transport error, unexpected response, timeout, or provider-side `429` fails
the demo.

The mock uses the upstream-supported OpenAI-compatible `httpbun` endpoint and
validates its response usage rather than assuming a fixed token count. This
proves gateway request handling and policy behavior, not provider-key
substitution.

## OpenAI mode

OpenAI mode is opt-in. It sends real requests and can incur provider charges.
Set the provider key only when intentionally switching to this mode:

```sh
export OPENAI_API_KEY=...
AGENTGATEWAY_MODE=openai make agentgateway-install
unset OPENAI_API_KEY
```

The installer writes the provider key to a namespaced Kubernetes Secret
referenced by the OpenAI backend. Client virtual keys remain distinct from
that provider key. The mock backend and its Deployment are removed when
switching to OpenAI mode; no provider Secret is created in mock mode.

The default model is `gpt-4o-mini`. To choose another provider model, set
`AGENTGATEWAY_MODEL` during installation. The same value is used by the
backend and the CEL model allowlist. Model names are constrained to letters,
digits, dot, underscore, and hyphen.

The walkthrough uses several bounded inference calls to demonstrate limits and
recovery. Do not run OpenAI mode without explicitly accepting the resulting
cost and quota usage. Real-provider key substitution is supported by the
configuration but is not part of unattended validation.

## Configuration and limits

| Setting | Default | Description |
| --- | --- | --- |
| `AGENTGATEWAY_NAMESPACE` | `agentgateway-demo` | Dedicated namespace for the Gateway, routes, backend, policies, client hashes, and mock workload |
| `AGENTGATEWAY_MODE` | `mock` | `mock` or `openai`; choose during install. Reinstall to switch modes |
| `AGENTGATEWAY_MODEL` | `gpt-4o-mini` | Model pinned in the backend and policy during install |
| `AGENTGATEWAY_ALICE_KEY` | Required | Alice's stable client key |
| `AGENTGATEWAY_BOB_KEY` | Required | Bob's stable client key |
| `AGENTGATEWAY_ROTATE_CLIENT_KEYS` | `false` | Set to `true` only when intentionally replacing stored client keys |
| `OPENAI_API_KEY` | Required only for OpenAI install | Provider key stored in a Kubernetes Secret |
| `AGENTGATEWAY_URL` | `http://127.0.0.1:8080` | URL used by the demo script |

The default port `8080` conflicts with a concurrently running Bifrost or
KrakenD port-forward. Stop the other forward or use a different local port and
set `AGENTGATEWAY_URL` accordingly.

The demo has one proxy replica and uses local, in-memory limits keyed by
`apiKey.user_id`; its request and token counters are per replica, not durable
or fleet-wide. Token usage is settled from the provider response after a
request completes. A request can overshoot its token budget, and the gateway
does not interrupt an ongoing response when a budget is crossed. These are
soft evaluation limits, not hard financial caps. Semantic caching is not
covered by this demo.

## Cleanup

Remove the demo-owned resources with:

```sh
make agentgateway-uninstall
```

The uninstaller removes only resources labeled as owned by this demo and never
deletes `AGENTGATEWAY_NAMESPACE`. It removes the controller Helm release only
when this demo installed it and no other agentgateway Gateways, policies,
backends, or parameters remain. It removes the GatewayClass only when it was
labeled as demo-owned. The Gateway API CRDs and the `agentgateway-crds` Helm
release are intentionally retained as shared cluster prerequisites. If the
controller is retained because other resources use it, it remains in
`agentgateway-system`.

## Troubleshooting

- Check `kubectl get gatewayclass agentgateway` and the controller Pods in
  `agentgateway-system`.
- Inspect `kubectl describe gateway agentgateway-proxy`, `kubectl describe
  httproute agentgateway-llm`, and `kubectl describe agentgatewaypolicy
  agentgateway-demo` in `AGENTGATEWAY_NAMESPACE` for rejected configuration or
  unresolved references.
- If installation reports an unknown GatewayClass, conflicting release, or
  partial/incompatible CRDs, resolve the existing cluster ownership/version
  conflict rather than forcing adoption.
- Confirm the port-forward is running and uses the same
  `AGENTGATEWAY_NAMESPACE` as install. `AGENTGATEWAY_URL` must point to the
  forwarded port.
- In OpenAI mode, confirm `OPENAI_API_KEY` was set during installation and
  that the selected model is available to the provider.

## Upstream references

- [agentgateway v1.7 release support](https://agentgateway.dev/docs/kubernetes/1.7.x/release-notes/versions/)
- [Helm installation and Gateway API prerequisites](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/install/helm/)
- [Gateway setup and same-namespace route attachment](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/setup/gateway/)
- [ClusterIP proxy Service customization](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/setup/customize/configs/#clusterip-service)
- [OpenAI provider Secrets](https://agentgateway.dev/docs/kubernetes/1.7.x/integrations/llm/providers/openai/)
- [Hashed API-key authentication](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/security/apikey/)
- [Virtual keys and model authorization](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/llm/cost-controls/virtual-keys/)
- [Local request and token rate limiting](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/llm/rate-limit/)
- [OpenAI-compatible httpbun mock](https://agentgateway.dev/docs/kubernetes/1.7.x/integrations/llm/providers/httpbun/)
