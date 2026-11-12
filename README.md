# Hitchhiker's Guide to Cloud Native AI Gateways

A hands-on comparison of cloud-native gateways for AI workloads. Each demo is
intended to include deployment artifacts, feature configuration, and a short
scripted walkthrough.

## Demos

| Gateway | Demo | Features shown |
| --- | --- | --- |
| [Bifrost](gateways/bifrost/README.md) | [Helm-based Kubernetes demo](gateways/bifrost/README.md) | Semantic caching, governance policies, rate limits, token usage, virtual keys |
| [KrakenD Community Edition](gateways/krakend/README.md) | [Kubernetes demo](gateways/krakend/README.md) | OpenAI Chat Completions proxy using standard gateway features |
| [Agent Router (formerly Envoy AI Gateway)](gateways/envoy-ai-gateway/README.md) | [Kubernetes demo](gateways/envoy-ai-gateway/README.md) | API-key authentication, model virtualization, token-based limits and recovery |

agentgateway is covered in the [feature comparison](docs/feature-matrix.md);
additional runnable demos can be added as their configurations are validated.

## Quick start

Requirements for Bifrost: `kubectl`, Helm 3, `openssl`, `curl`, access to a
Kubernetes cluster, and an OpenAI API key.

```sh
export OPENAI_API_KEY=...
make bifrost-install
# Terminal 1:
make bifrost-port-forward
# Terminal 2:
make bifrost-demo
```

The install target creates Kubernetes Secrets for the provider and encryption
keys and installs the official Bifrost Helm chart in the `ai-gateway-demo`
namespace. The demo target checks readiness and, when `BIFROST_VIRTUAL_KEY` is
set, sends a sample chat completion.

The dashboard is available at <http://127.0.0.1:8080>. Create a budget and
rate limit in Governance, then associate them with a virtual key. Use that
virtual key as `BIFROST_VIRTUAL_KEY` to run the sample request. The response's
`usage` object demonstrates token accounting; repeat a semantically similar
prompt to explore semantic caching.

This is a local evaluation setup; do not expose the dashboard or inference
endpoint publicly without configuring authentication and TLS.

Run `make help` for all targets and `make bifrost-uninstall` to remove the
demo release.

## KrakenD Community Edition

The KrakenD demo runs a standard `no-op` proxy for OpenAI Chat Completions.
Install it with `make krakend-install`, forward the service with
`make krakend-port-forward`, and run `OPENAI_API_KEY=... make krakend-demo` in
another terminal. It uses a separate `krakend-demo` namespace by default;
override it with `KRAKEND_NAMESPACE`. See the
[KrakenD walkthrough](gateways/krakend/README.md) for details.

## Agent Router (formerly Envoy AI Gateway)

The Agent Router demo is configured for mock mode without a provider account
or API key. It checks authentication, rewrites `demo-chat` to a fixture model,
and demonstrates response-time token charging against a shared
100-token/minute allowance. Start with `make envoy-ai-gateway-install`, then use
`make envoy-ai-gateway-port-forward` and `make envoy-ai-gateway-demo`. Live
OpenAI mode is a separate, explicitly opted-in option. See the
[Agent Router walkthrough](gateways/envoy-ai-gateway/README.md) for pinned
versions, credentials, quota overshoot behavior, overrides, cleanup, and
validation status.

## Maintainer

M.-Leander Reimer (@lreimer), <mario-leander.reimer@qaware.de>

## License

This software is provided under the MIT open source license, read the `LICENSE`
file for details.