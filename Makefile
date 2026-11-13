NAMESPACE ?= ai-gateway-demo
KRAKEND_NAMESPACE ?= krakend-demo
AGENTGATEWAY_NAMESPACE ?= agentgateway-demo

.PHONY: help validate bifrost-install bifrost-port-forward bifrost-demo bifrost-uninstall krakend-install krakend-port-forward krakend-demo krakend-uninstall agentgateway-install agentgateway-port-forward agentgateway-demo agentgateway-uninstall

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
	  'validate              Check shell script syntax'

validate:
	@for script in scripts/*.sh; do bash -n "$$script" || exit $$?; done
	@python3 -m json.tool gateways/krakend/krakend.json >/dev/null

bifrost-install:
	@NAMESPACE="$(NAMESPACE)" ./scripts/install-bifrost.sh

bifrost-port-forward:
	kubectl port-forward -n "$(NAMESPACE)" svc/bifrost 8080:8080

bifrost-demo:
	@./scripts/demo-bifrost.sh

bifrost-uninstall:
	helm uninstall bifrost --namespace "$(NAMESPACE)"
	kubectl delete namespace "$(NAMESPACE)"

krakend-install:
	@KRAKEND_NAMESPACE="$(KRAKEND_NAMESPACE)" ./scripts/install-krakend.sh

krakend-port-forward:
	kubectl port-forward -n "$(KRAKEND_NAMESPACE)" svc/krakend 8080:8080

krakend-demo:
	@./scripts/demo-krakend.sh

krakend-uninstall:
	kubectl delete namespace "$(KRAKEND_NAMESPACE)"

agentgateway-install:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/install-agentgateway.sh

agentgateway-port-forward:
	kubectl port-forward -n "$(AGENTGATEWAY_NAMESPACE)" svc/agentgateway-proxy 8080:80

agentgateway-demo:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/demo-agentgateway.sh

agentgateway-uninstall:
	@AGENTGATEWAY_NAMESPACE="$(AGENTGATEWAY_NAMESPACE)" ./scripts/uninstall-agentgateway.sh
