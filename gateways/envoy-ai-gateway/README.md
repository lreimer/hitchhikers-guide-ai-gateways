# Agent Router (formerly Envoy AI Gateway) on Kubernetes

This local evaluation demo uses the `aigateway.envoyproxy.io` APIs and the
official Envoy Gateway and Agent Router Helm charts. It demonstrates
Secret-backed API-key authentication, OpenAI-compatible chat completions,
model-name virtualization, response token accounting, and a shared
model-scoped token allowance.

The demo is intentionally limited to localhost access and a disposable,
isolated cluster. It is not a production reference architecture.

The manifests and scripts pass static validation; an end-to-end Kubernetes
installation and request walkthrough have not yet been verified.

## Requirements and pinned versions

- Kubernetes 1.32 or newer, on a disposable cluster
- `kubectl`, Helm 3, `curl`, `openssl`, and Python 3
- A local cluster that can pull OCI images; the fixture images include
  `linux/amd64` and `linux/arm64` variants for Apple Silicon developers
- Optional OpenAI mode: an OpenAI API key in `OPENAI_API_KEY`

The deployment pins these releases and image digests:

| Component | Pin |
| --- | --- |
| Envoy Gateway Helm chart and controller | `v1.9.2` |
| Agent Router controller and CRD charts | `v1.2.1` |
| Gateway API CRDs on a clean cluster | `v1.6.1` |
| Redis | `8.2.4-alpine3.22`, pinned by OCI digest |
| Rate-limit service | `envoyproxy/ratelimit:0482748e`, pinned by OCI digest |
| Local OpenAI-compatible fixture | Python `3.13.5-alpine3.22`, pinned by OCI digest |

If Gateway API CRDs already exist, the installer checks that the required CRDs
and stable `v1` APIs are present, reports their bundle labels, and leaves them
untouched. A partial set is rejected. Envoy Gateway CRDs are installed
create-only from its pinned Helm chart; pre-existing Envoy Gateway CRDs are
rejected rather than adopted. Agent Router CRDs are installed from the pinned
official CRD chart.

## Install and run the mock demo

From the repository root:

```sh
make envoy-ai-gateway-install
make envoy-ai-gateway-port-forward
```

In another terminal:

```sh
make envoy-ai-gateway-demo
```

The installer creates a random client API key once and reuses the Secret on
subsequent installs. It does not print the value. Export it with the command
shown by the installer, or let the demo script read it from Kubernetes:

```sh
export ENVOY_AI_GATEWAY_CLIENT_KEY="$(kubectl get secret envoy-ai-gateway-client-keys \
  -n envoy-ai-gateway-demo -o jsonpath='{.data.demo}' |
  python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.buffer.read()).decode())')"
```

The script checks that missing and invalid keys receive HTTP 401, then sends
non-streaming requests to the fixed local fixture. The fixture accepts only the
rewritten upstream model `fixture-model`, rejects leaked client credential
headers, and returns a deterministic response with 40 prompt, 20 completion,
and 60 total tokens.

The model-scoped global allowance is 100 total tokens per minute. Requests
have a request cost of zero; the gateway charges the response's `TotalToken`
usage after it completes. Thus two 60-token completions can succeed and the
next request is rejected with a gateway-generated HTTP 429. An admitted request
can exceed the remaining allowance: this is response-time accounting, not
preflight reservation or a hard spending cap. The demo polls for charge
propagation and for the one-minute window to recover; it does not flush Redis
or disable the policy. A successful recovery request charges the bucket again.

## Optional OpenAI mode

Live provider requests are an explicit opt-in. The installer stores
`OPENAI_API_KEY` in a separate Kubernetes Secret and adds an OpenAI backend
with `BackendSecurityPolicy` and system-CA TLS verification. The deterministic
mock quota walkthrough remains separate from one live request, capped at
`max_tokens: 16`; provider usage is reported separately and may be billable.

```sh
export OPENAI_API_KEY=...
ENVOY_AI_GATEWAY_MODE=openai make envoy-ai-gateway-install
make envoy-ai-gateway-port-forward
```

Then in another terminal, with the client key exported:

```sh
ENVOY_AI_GATEWAY_MODE=openai make envoy-ai-gateway-demo
```

The live alias `live-chat` defaults to `gpt-4o-mini`. To select a model enabled
for the OpenAI account, set `ENVOY_AI_GATEWAY_OPENAI_MODEL` to an identifier
containing only letters, digits, dot, underscore, or hyphen before installing.
The installer does not overwrite an existing provider Secret; explicitly
rotate it using your normal secret-management procedure.

The OpenAI provider path has not been exercised; it requires a valid account
credential and may incur charges.

## Namespaces, reruns, and cleanup

The default namespaces are `envoy-ai-gateway-demo` for application resources,
`envoy-gateway-system` for Envoy Gateway and Redis, and
`envoy-ai-gateway-system` for Agent Router. Override them with
`ENVOY_AI_GATEWAY_NAMESPACE`, `ENVOY_GATEWAY_NAMESPACE`, and
`ENVOY_AI_GATEWAY_SYSTEM_NAMESPACE`, respectively. They must be distinct.
`ENVOY_AI_GATEWAY_URL` changes the demo request URL; the port-forward target
binds to `127.0.0.1:8080`.

The installer refuses namespaces without its ownership label, pre-existing
Helm releases in other namespaces, and a pre-existing demo `GatewayClass` it
does not own. Reinstalling reuses the client key. The generated data-plane
Service is discovered by its owning-Gateway labels. The rate-limit state
expires with its one-minute window; rerun the demo after recovery rather than
resetting shared Redis state.

```sh
make envoy-ai-gateway-uninstall
```

Uninstall removes the demo's namespaced resources and Secrets, Redis, and the
three Helm releases. It retains the empty demo namespaces and cluster-scoped
Gateway API, Envoy Gateway, and Agent Router CRDs. This avoids deleting CRDs
that may be used by other software. Remove retained CRDs only when you have
verified that the cluster is dedicated to this demo and no other workloads
depend on them.

## Troubleshooting

- Check `kubectl get gatewayclass,gateway,httproute,aigatewayroute -A` for
  attachment and route status.
- Check deployments and pods in the three demo namespaces for readiness.
- If installation fails, the installer prints resource metadata and statuses
  without dumping Secret values or container logs.
- If the demo cannot connect, keep the port-forward process running and confirm
  `ENVOY_AI_GATEWAY_URL` matches the forwarded address.
- After token exhaustion, wait for the bounded recovery check to succeed
  before retrying; quota is shared by all authenticated clients using
  `demo-chat`.

## Upstream references

- [Agent Router v1.2.1 release](https://github.com/theagentrouter/agent-router/releases/tag/v1.2.1)
- [Agent Router and Envoy Gateway compatibility](https://github.com/theagentrouter/agent-router/blob/v1.2.1/site/docs/compatibility.md)
- [Pinned Agent Router Envoy Gateway integration values](https://github.com/theagentrouter/agent-router/blob/v1.2.1/manifests/envoy-gateway-values.yaml)
- [Model-name virtualization](https://github.com/theagentrouter/agent-router/blob/v1.2.1/site/docs/capabilities/traffic/model-virtualization.md)
- [Usage-based token rate limiting](https://github.com/theagentrouter/agent-router/blob/v1.2.1/site/docs/capabilities/traffic/usage-based-ratelimiting.md)
- [Envoy Gateway v1.9.2 API-key authentication](https://github.com/envoyproxy/gateway/blob/v1.9.2/site/content/en/v1.9/tasks/security/apikey-auth.md)
