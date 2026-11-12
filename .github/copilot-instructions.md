# Repository guide

## Build, test, and lint

There is no application build or automated test suite. Run `make validate` to
check the syntax of both shell scripts. To check one script, use
`bash -n scripts/install-bifrost.sh` or `bash -n scripts/demo-bifrost.sh`.

Run `make help` to list the Kubernetes demo targets. The Bifrost flow is:

```sh
export OPENAI_API_KEY=...
make bifrost-install
make bifrost-port-forward
# In another terminal, after creating a virtual key in the dashboard:
export BIFROST_VIRTUAL_KEY=...
make bifrost-demo
```

`NAMESPACE` can override the default `ai-gateway-demo` namespace for the
install, port-forward, and uninstall targets. `BIFROST_URL` can override the
demo script's default `http://127.0.0.1:8080`.

## Architecture

This repository compares cloud-native AI gateways and adds runnable examples as
their deployment configurations are validated. `docs/feature-matrix.md` is a
high-level, version-sensitive comparison, not a feature certification.

Each runnable demo is organized under `gateways/<gateway>/` with gateway
configuration and usage documentation. The root `Makefile` exposes common demo
operations, while `scripts/` contains the operational shell scripts. Bifrost
is currently the runnable demo: its values file configures the official Helm
chart, and `scripts/install-bifrost.sh` creates the Kubernetes namespace and
credential Secrets before installing that chart. The provider and encryption
credentials are supplied through Secrets rather than committed to Helm
values. The demo script checks health and sends a sample completion only when
`BIFROST_VIRTUAL_KEY` is set.

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
