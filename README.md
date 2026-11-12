# Hitchhiker's Guide to Cloud Native AI Gateways

A hands-on comparison of cloud-native gateways for AI workloads. Each demo is
intended to include deployment artifacts, feature configuration, and a short
scripted walkthrough.

## Demos

| Gateway | Demo | Features shown |
| --- | --- | --- |
| [Bifrost](gateways/bifrost/README.md) | [Helm-based Kubernetes demo](gateways/bifrost/README.md) | Semantic caching, governance policies, rate limits, token usage, virtual keys |

The Bifrost demo is the first runnable example. KrakenD, Envoy AI Gateway, and
agentgateway are covered in the [feature comparison](docs/feature-matrix.md);
additional runnable demos can be added as their configurations are validated.

## Quick start

Requirements: `kubectl`, Helm 3, `openssl`, `curl`, access to a Kubernetes
cluster, and an OpenAI API key.

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
