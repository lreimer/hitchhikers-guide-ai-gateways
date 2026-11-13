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
| [agentgateway](gateways/agentgateway/README.md) | [Governed LLM access demo](gateways/agentgateway/README.md) | Client API keys, model authorization, request throttling, per-client token budgets, token usage |
| [agentgateway MCP add-on](gateways/agentgateway/mcp/README.md) | [MCP federation and tool authorization](gateways/agentgateway/mcp/README.md) | Two SDK-backed servers, JWT identities, tool discovery/call authorization, per-user local request limits |

Agent Router and agentgateway are covered in the
[feature comparison](docs/feature-matrix.md); additional runnable demos can be
added as their configurations are validated.

### Bifrost

The Bifrost demo installs the official Helm chart with OpenAI. Install it with
`OPENAI_API_KEY=... make bifrost-install`, forward the service with
`make bifrost-port-forward`, create a virtual key in the dashboard, and run
`BIFROST_VIRTUAL_KEY=... make bifrost-demo` in another terminal. It uses the
`bifrost-demo` namespace by default; override it with `BIFROST_NAMESPACE`. See
the [Bifrost walkthrough](gateways/bifrost/README.md) for setup and cleanup.
This is a local evaluation setup; do not expose the dashboard or inference
endpoint publicly without authentication and TLS.

### agentgateway

The agentgateway demo runs a locally port-forwarded, authenticated OpenAI
Chat Completions route. It defaults to a pinned in-cluster httpbun mock and
does not need a provider key. See the
[agentgateway walkthrough](gateways/agentgateway/README.md) for secure client
key setup, OpenAI mode, quota caveats, and cleanup.

The [MCP add-on](gateways/agentgateway/mcp/README.md) extends that installation
with a local SDK-backed calculator and fictional product catalog, without
provider keys or inference calls. Its MCP coverage is separate from the
LLM-focused feature comparison.

### KrakenD Community Edition

The KrakenD demo runs a standard `no-op` proxy for OpenAI Chat Completions.
Install it with `make krakend-install`, forward the service with
`make krakend-port-forward`, and run `OPENAI_API_KEY=... make krakend-demo` in
another terminal. It uses a separate `krakend-demo` namespace by default;
override it with `KRAKEND_NAMESPACE`. See the
[KrakenD walkthrough](gateways/krakend/README.md) for details.

### Agent Router (formerly Envoy AI Gateway)

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