# Bifrost on Kubernetes

This demo installs the official Bifrost Helm chart with OpenAI as both the
inference provider and semantic-cache embedding provider.

## Prerequisites

- A Kubernetes cluster and a working `kubectl` context
- Helm 3
- `openssl` and `curl`
- An OpenAI API key in `OPENAI_API_KEY`

## Install and try it

From the repository root:

```sh
export OPENAI_API_KEY=...
make bifrost-install
make bifrost-port-forward
```

In another terminal, open <http://127.0.0.1:8080>. In the dashboard's
Governance section, create a budget and a rate limit, then create a virtual key
that uses them. Bifrost is configured to require a virtual key for inference.
Set the returned key locally and run the demo:

```sh
export BIFROST_VIRTUAL_KEY=...
make bifrost-demo
```

The response includes token usage. To explore semantic caching, send the same
question again with slightly different wording and compare request logs and
provider usage in the dashboard.

## Configuration

[`values.yaml`](values.yaml) is passed to the official chart. It enables
governance with mandatory virtual keys and the semantic-cache plugin. The
governance budgets, rate limits, and virtual keys are created interactively in
the dashboard so the demo does not commit credentials or reusable virtual
keys.

Provider and encryption credentials are provisioned as Kubernetes Secrets by
[`scripts/install-bifrost.sh`](../../scripts/install-bifrost.sh). They are not
stored in the Helm values file.

## Clean up

```sh
make bifrost-uninstall
```

The uninstall target removes the demo namespace, including its Secrets and
persistent resources.
