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
| [agentgateway](https://agentgateway.dev/docs/kubernetes/1.7.x/) | Not covered by this demo | API-key authentication and model authorization | Local per-client request and token limits | OpenAI-compatible response usage and token accounting | API-key auth with provider-key substitution | Runnable governed LLM Kubernetes demo in this repository |

## References

- [Bifrost Helm deployment](https://docs.getbifrost.ai/deployment-guides/helm)
- [Bifrost Helm governance](https://docs.getbifrost.ai/deployment-guides/helm/governance)
- [Bifrost Helm plugins](https://docs.getbifrost.ai/deployment-guides/helm/plugins)
- [KrakenD Enterprise AI Gateway semantic cache](https://www.krakend.io/docs/enterprise/ai-gateway/semantic-cache/)
- [KrakenD Community Edition no-op proxy](https://www.krakend.io/docs/endpoints/no-op/)
- [Envoy AI Gateway usage-based rate limiting](https://aigateway.envoyproxy.io/docs/capabilities/traffic/usage-based-ratelimiting/)
- [agentgateway v1.7 API-key authentication](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/security/apikey/)
- [agentgateway v1.7 virtual keys and model authorization](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/llm/cost-controls/virtual-keys/)
- [agentgateway v1.7 LLM rate limiting](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/llm/rate-limit/)
- [agentgateway v1.7 httpbun mock LLM](https://agentgateway.dev/docs/kubernetes/1.7.x/integrations/llm/providers/httpbun/)
