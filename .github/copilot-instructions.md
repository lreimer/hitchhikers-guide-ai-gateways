# Repository guide

## Build, test, and lint

There is no application build or automated test suite. Run `make validate` to
check shell script syntax and the KrakenD JSON configuration. To check one
script, use `bash -n scripts/install-bifrost.sh` or
`bash -n scripts/demo-bifrost.sh`.

Run `make help` to list the Kubernetes demo targets. The Bifrost flow is:

```sh
export OPENAI_API_KEY=...
make bifrost-install
make bifrost-port-forward
# In another terminal, after creating a virtual key in the dashboard:
export BIFROST_VIRTUAL_KEY=...
make bifrost-demo
```

The KrakenD Community Edition demo can be installed with
`make krakend-install`, exposed locally with `make krakend-port-forward`, and
tried with `OPENAI_API_KEY=... make krakend-demo`. Its namespace defaults to
`krakend-demo` and can be overridden with `KRAKEND_NAMESPACE`.

`NAMESPACE` can override the default `ai-gateway-demo` namespace for the
install, port-forward, and uninstall targets. `BIFROST_URL` can override the
demo script's default `http://127.0.0.1:8080`.
`KRAKEND_NAMESPACE` can override the KrakenD demo namespace, and `KRAKEND_URL`
can override the demo script's default `http://127.0.0.1:8080`.

## Architecture

This repository compares cloud-native AI gateways and adds runnable examples as
their deployment configurations are validated. `docs/feature-matrix.md` is a
high-level, version-sensitive comparison, not a feature certification.

Each runnable demo is organized under `gateways/<gateway>/` with gateway
configuration and usage documentation. The root `Makefile` exposes common demo
operations, while `scripts/` contains the operational shell scripts. Bifrost's
values file configures the official Helm chart, and
`scripts/install-bifrost.sh` creates the Kubernetes namespace and credential
Secrets before installing that chart. The provider and encryption credentials
are supplied through Secrets rather than committed to Helm values. The
KrakenD CE demo uses `gateways/krakend/krakend.json` and a Kubernetes ConfigMap
to run a standard OpenAI proxy; its sample request forwards the API key without
storing it in Kubernetes.

## Repository-specific conventions

- Keep gateway-specific configuration and walkthroughs together under that
  gateway's directory; use root Make targets and shared scripts for repeatable
  demo operations.
- Keep comparison claims qualified by product edition, release, and
  configuration, and link upstream documentation for capability details.
- Treat the Bifrost setup as a local evaluation demo. Do not expose its
  dashboard or inference endpoint publicly without authentication and TLS.
- Do not commit provider credentials or reusable virtual keys. The installer
  reads `OPENAI_API_KEY` from the environment and creates Kubernetes Secrets;
  virtual keys are created interactively in the dashboard.
