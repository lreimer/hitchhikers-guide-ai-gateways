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
| [Envoy AI Gateway](https://aigateway.envoyproxy.io/) | Not covered by this demo | Envoy Gateway policies and filters | Includes token-based rate limiting | LLM response usage can drive quotas | Usually provided by authn / policy integrations | Not yet included |
| [agentgateway](https://agentgateway.dev/docs/kubernetes/latest/) | Not covered by this demo | API-key authentication and authorization policies | Request and token limits | Supports token-based limits | API-key authentication | Not yet included |

## References

- [Bifrost Helm deployment](https://docs.getbifrost.ai/deployment-guides/helm)
- [Bifrost Helm governance](https://docs.getbifrost.ai/deployment-guides/helm/governance)
- [Bifrost Helm plugins](https://docs.getbifrost.ai/deployment-guides/helm/plugins)
- [KrakenD Enterprise AI Gateway semantic cache](https://www.krakend.io/docs/enterprise/ai-gateway/semantic-cache/)
- [KrakenD Community Edition no-op proxy](https://www.krakend.io/docs/endpoints/no-op/)
- [Envoy AI Gateway usage-based rate limiting](https://aigateway.envoyproxy.io/docs/capabilities/traffic/usage-based-ratelimiting/)
- [agentgateway API-key authentication](https://agentgateway.dev/docs/kubernetes/latest/documentation/security/apikey/)
- [agentgateway LLM rate limiting](https://agentgateway.dev/docs/kubernetes/latest/documentation/llm/rate-limit/)
