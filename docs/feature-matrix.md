# Gateway feature comparison

This is a guide to what the repository currently demonstrates, not a feature
certification. Gateway capabilities vary by edition, release, and deployment
configuration; verify the linked upstream documentation before comparing
versions or planning production use.

| Project | Semantic cache | Policy / authorization | Rate limiting | Token usage | Virtual API keys | Demo status |
| --- | --- | --- | --- | --- | --- | --- |
| [Bifrost](https://docs.getbifrost.ai/) | Built-in plugin | Governance | Governance limits | Usage analytics and response usage | Governance | Runnable Kubernetes demo in this repository |
| [KrakenD Community Edition](https://www.krakend.io/docs/) | Not included in this demo | Core gateway features | Core request rate limits | No LLM-specific accounting in this demo | Not included in this demo | Runnable OpenAI proxy demo in this repository |
| [KrakenD Enterprise Edition](https://www.krakend.io/docs/enterprise/) | AI Gateway feature | Gateway policies and plugins | Gateway throttling | AI Gateway configuration or integration | Edition-dependent | Not included |
| [Agent Router (formerly Envoy AI Gateway)](https://theagentrouter.ai/docs/) | Not covered by this demo | Envoy Gateway API-key policy | Model-scoped token-based limits | OpenAI-compatible response usage drives the demo quota | Secret-backed API-key authentication (not virtual-key lifecycle management) | Implementation added; end-to-end Kubernetes validation pending |
| [agentgateway](https://agentgateway.dev/docs/kubernetes/latest/) | Not covered by this demo | API-key authentication and authorization policies | Request and token limits | Supports token-based limits | API-key authentication | Not yet included |

## References

- [Bifrost Helm deployment](https://docs.getbifrost.ai/deployment-guides/helm)
- [Bifrost Helm governance](https://docs.getbifrost.ai/deployment-guides/helm/governance)
- [Bifrost Helm plugins](https://docs.getbifrost.ai/deployment-guides/helm/plugins)
- [KrakenD Enterprise AI Gateway semantic cache](https://www.krakend.io/docs/enterprise/ai-gateway/semantic-cache/)
- [KrakenD Community Edition no-op proxy](https://www.krakend.io/docs/endpoints/no-op/)
- [Agent Router v1.2.1 usage-based rate limiting](https://github.com/theagentrouter/agent-router/blob/v1.2.1/site/docs/capabilities/traffic/usage-based-ratelimiting.md)
- [Envoy Gateway v1.9.2 API-key authentication](https://github.com/envoyproxy/gateway/blob/v1.9.2/site/content/en/v1.9/tasks/security/apikey-auth.md)
- [Agent Router Kubernetes demo in this repository](../gateways/envoy-ai-gateway/README.md)
- [agentgateway API-key authentication](https://agentgateway.dev/docs/kubernetes/latest/documentation/security/apikey/)
- [agentgateway LLM rate limiting](https://agentgateway.dev/docs/kubernetes/latest/documentation/llm/rate-limit/)
