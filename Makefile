BIFROST_NAMESPACE ?= bifrost-demo
KRAKEND_NAMESPACE ?= krakend-demo
AGENTGATEWAY_NAMESPACE ?= $(if $(NAMESPACE),$(NAMESPACE),agentgateway-demo)
ENVOY_AI_GATEWAY_NAMESPACE ?= envoy-ai-gateway-demo
ENVOY_GATEWAY_NAMESPACE ?= envoy-gateway-system
ENVOY_AI_GATEWAY_SYSTEM_NAMESPACE ?= envoy-ai-gateway-system
KAGENT_NAMESPACE ?= kagent
KAGENT_CONTEXT ?= rancher-desktop

.PHONY: help validate bifrost-install bifrost-port-forward bifrost-demo bifrost-uninstall krakend-install krakend-port-forward krakend-demo krakend-uninstall agentgateway-install agentgateway-port-forward agentgateway-demo agentgateway-uninstall envoy-ai-gateway-install envoy-ai-gateway-port-forward envoy-ai-gateway-demo envoy-ai-gateway-uninstall kagent-install kagent-port-forward kagent-demo kagent-uninstall kagent-byo-build kagent-byo-install kagent-byo-demo kagent-byo-uninstall
.PHONY: agentgateway-mcp-install agentgateway-mcp-demo agentgateway-mcp-uninstall

help:
	@printf '%s\n' \
	  'bifrost-install       Install the Bifrost demo in Kubernetes' \
	  'bifrost-port-forward  Forward the Bifrost service to localhost:8080' \
	  'bifrost-demo          Check health and optionally send a sample request' \
	  'bifrost-uninstall     Remove the Bifrost Helm release and namespace' \
	  'krakend-install       Install the KrakenD Community Edition demo' \
	  'krakend-port-forward  Forward the KrakenD service to localhost:8080' \
	  'krakend-demo          Check health and optionally send a sample request' \
	  'krakend-uninstall     Remove the KrakenD demo namespace' \
	  'agentgateway-install  Install the governed agentgateway demo' \
	  'agentgateway-port-forward Forward the agentgateway service to localhost:8080' \
	  'agentgateway-demo     Exercise agentgateway authentication, limits, and revocation' \
	  'agentgateway-uninstall Remove the agentgateway demo resources' \
	  'agentgateway-mcp-install Install the MCP federation add-on (base demo required)' \
	  'agentgateway-mcp-demo  Assert JWT authentication, tool access, and per-user limits' \
	  'agentgateway-mcp-uninstall Remove only MCP add-on resources' \
	  'envoy-ai-gateway-install      Install the Agent Router (formerly Envoy AI Gateway) demo' \
	  'envoy-ai-gateway-port-forward Forward the generated Gateway to localhost:8080' \
	  'envoy-ai-gateway-demo         Run the authenticated token-limit walkthrough' \
	  'envoy-ai-gateway-uninstall    Remove demo resources and Helm releases' \
	  'kagent-install        Install the declarative kagent demo agents' \
	  'kagent-port-forward   Forward the kagent UI to localhost:8081' \
	  'kagent-demo           Run the explicitly opted-in live agent evaluation' \
	  'kagent-uninstall      Remove the kagent demo and its owned runtime' \
	  'kagent-byo-build      Build and push the digest-pinned Go BYO image' \
	  'kagent-byo-install    Install the optional Go BYO quote agent' \
	  'kagent-byo-demo       Run the explicitly opted-in BYO agent evaluation' \
	  'kagent-byo-uninstall  Remove only BYO resources and its tracked sessions' \
	  'validate              Check shell/Python syntax, gateway JSON, and kagent YAML'

validate:
	@for script in scripts/*.sh; do bash -n "$$script" || exit $$?; done
	@python3 -m json.tool gateways/krakend/krakend.json >/dev/null
	@python3 -c 'import ast; ast.parse(open("gateways/envoy-ai-gateway/mock-backend.py", encoding="utf-8").read())'
	@python3 -c 'import ast, pathlib; [ast.parse(p.read_text(encoding="utf-8"), filename=str(p)) for p in pathlib.Path("gateways/agentgateway/mcp").glob("*.py")]'
	@uv run --with pyyaml python -c 'import pathlib, yaml; [list(yaml.parse(p.read_text(encoding="utf-8"))) for p in pathlib.Path("agents/kagent").rglob("*.yaml")]'

bifrost-install:
	@BIFROST_NAMESPACE="$(BIFROST_NAMESPACE)" ./scripts/install-bifrost.sh

bifrost-port-forward:
	kubectl port-forward -n "$(BIFROST_NAMESPACE)" svc/bifrost 8080:8080

bifrost-demo:
	@./scripts/demo-bifrost.sh

bifrost-uninstall:
	helm uninstall bifrost --namespace "$(BIFROST_NAMESPACE)"
	kubectl delete namespace "$(BIFROST_NAMESPACE)"

krakend-install:
	@KRAKEND_NAMESPACE="$(KRAKEND_NAMESPACE)" ./scripts/install-krakend.sh

krakend-port-forward:
	kubectl port-forward -n "$(KRAKEND_NAMESPACE)" svc/krakend 8080:8080

krakend-demo:
	@./scripts/demo-krakend.sh

krakend-uninstall:
	kubectl delete namespace "$(KRAKEND_NAMESPACE)"

envoy-ai-gateway-install:
	@ENVOY_AI_GATEWAY_NAMESPACE="$(ENVOY_AI_GATEWAY_NAMESPACE)" \
	  ENVOY_GATEWAY_NAMESPACE="$(ENVOY_GATEWAY_NAMESPACE)" \
	  ENVOY_AI_GATEWAY_SYSTEM_NAMESPACE="$(ENVOY_AI_GATEWAY_SYSTEM_NAMESPACE)" \
	  ./scripts/install-envoy-ai-gateway.sh

envoy-ai-gateway-port-forward:
	@ENVOY_AI_GATEWAY_NAMESPACE="$(ENVOY_AI_GATEWAY_NAMESPACE)" \
	  ./scripts/port-forward-envoy-ai-gateway.sh

envoy-ai-gateway-demo:
	@ENVOY_AI_GATEWAY_NAMESPACE="$(ENVOY_AI_GATEWAY_NAMESPACE)" \
	  ./scripts/demo-envoy-ai-gateway.sh

envoy-ai-gateway-uninstall:
	@ENVOY_AI_GATEWAY_NAMESPACE="$(ENVOY_AI_GATEWAY_NAMESPACE)" \
	  ENVOY_GATEWAY_NAMESPACE="$(ENVOY_GATEWAY_NAMESPACE)" \
	  ENVOY_AI_GATEWAY_SYSTEM_NAMESPACE="$(ENVOY_AI_GATEWAY_SYSTEM_NAMESPACE)" \
	  ./scripts/uninstall-envoy-ai-gateway.sh

agentgateway-install:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/install-agentgateway.sh

agentgateway-port-forward:
	kubectl port-forward --address 127.0.0.1 -n "$(AGENTGATEWAY_NAMESPACE)" svc/agentgateway-proxy 8080:80

agentgateway-demo:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/demo-agentgateway.sh

agentgateway-uninstall:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/uninstall-agentgateway.sh

agentgateway-mcp-install:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/install-agentgateway-mcp.sh

agentgateway-mcp-demo:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/demo-agentgateway-mcp.sh

agentgateway-mcp-uninstall:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/uninstall-agentgateway-mcp.sh

kagent-install:
	@KAGENT_CONTEXT="$(KAGENT_CONTEXT)" KAGENT_NAMESPACE="$(KAGENT_NAMESPACE)" \
	  AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/install-kagent.sh

kagent-port-forward:
	@KAGENT_CONTEXT="$(KAGENT_CONTEXT)" KAGENT_NAMESPACE="$(KAGENT_NAMESPACE)" \
	  ./scripts/port-forward-kagent.sh

kagent-demo:
	@KAGENT_CONTEXT="$(KAGENT_CONTEXT)" KAGENT_NAMESPACE="$(KAGENT_NAMESPACE)" \
	  AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/demo-kagent.sh

kagent-uninstall:
	@KAGENT_CONTEXT="$(KAGENT_CONTEXT)" KAGENT_NAMESPACE="$(KAGENT_NAMESPACE)" \
	  ./scripts/uninstall-kagent.sh

kagent-byo-build:
	@./scripts/build-kagent-byo.sh

kagent-byo-install:
	@KAGENT_CONTEXT="$(KAGENT_CONTEXT)" KAGENT_NAMESPACE="$(KAGENT_NAMESPACE)" \
	  AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/install-kagent-byo.sh

kagent-byo-demo:
	@KAGENT_CONTEXT="$(KAGENT_CONTEXT)" KAGENT_NAMESPACE="$(KAGENT_NAMESPACE)" \
	  AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" \
	  KAGENT_QUOTE_AGENT="product-quote-byo-assistant" \
	  KAGENT_BYO_SESSION_TRACKING=true ./scripts/demo-kagent.sh

kagent-byo-uninstall:
	@KAGENT_CONTEXT="$(KAGENT_CONTEXT)" KAGENT_NAMESPACE="$(KAGENT_NAMESPACE)" \
	  ./scripts/uninstall-kagent-byo.sh
