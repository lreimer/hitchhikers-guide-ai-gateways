NAMESPACE ?= ai-gateway-demo

.PHONY: help validate bifrost-install bifrost-port-forward bifrost-demo bifrost-uninstall

help:
	@printf '%s\n' \
	  'bifrost-install       Install the Bifrost demo in Kubernetes' \
	  'bifrost-port-forward  Forward the Bifrost service to localhost:8080' \
	  'bifrost-demo          Check health and optionally send a sample request' \
	  'bifrost-uninstall     Remove the Bifrost Helm release and namespace' \
	  'validate              Check shell script syntax'

validate:
	@bash -n scripts/install-bifrost.sh scripts/demo-bifrost.sh

bifrost-install:
	@NAMESPACE="$(NAMESPACE)" ./scripts/install-bifrost.sh

bifrost-port-forward:
	kubectl port-forward -n "$(NAMESPACE)" svc/bifrost 8080:8080

bifrost-demo:
	@./scripts/demo-bifrost.sh

bifrost-uninstall:
	helm uninstall bifrost --namespace "$(NAMESPACE)"
	kubectl delete namespace "$(NAMESPACE)"
