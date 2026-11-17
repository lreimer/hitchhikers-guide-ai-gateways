# Bifrost on Kubernetes

This demo installs the official Bifrost Helm chart with OpenAI as both the
inference provider and semantic-cache embedding provider.

## Prerequisites

- A Kubernetes cluster and a working `kubectl` context
- Helm 3
- `openssl`, `curl`, and `jq`
- An OpenAI API key in `OPENAI_API_KEY`

## Install and try it

From the repository root:

```sh
export OPENAI_API_KEY=...
make bifrost-install
make bifrost-port-forward
```

In another terminal, retrieve the generated setup token:

```sh
kubectl get secret bifrost-setup-token -n bifrost-demo \
  -o go-template='{{index .data "setup-token" | base64decode}}{{"\n"}}'
```

Open <http://127.0.0.1:8080>, enter that token on the **Finish setting up
Bifrost** screen, and create an admin account. Keep the token private; it
authorizes first-admin creation and is not an inference virtual key.

In the dashboard's Governance section, create a budget and a rate limit, then
create a virtual key that uses them. Bifrost is configured to require a virtual key for inference.
Set the returned key locally and run the demo:

```sh
export BIFROST_VIRTUAL_KEY=...
make bifrost-demo
```

Responses are pretty-printed JSON, with colours when writing to a terminal.
Set `NO_COLOR=1` to disable colours. HTTP error responses are also formatted,
and failed requests still return a nonzero exit status.

The demo sends two requests sequentially: "What is an AI gateway?" followed by
"What is an AI gateway, exactly?". Both use the same model, virtual key, and
`x-bf-cache-key: bifrost-demo` header to enable caching within the same scope.
Compare cache status in the dashboard request logs and provider usage to see
whether the second request was served from semantic cache. A hit depends on the
configured similarity threshold and the first response being cached; it is not
guaranteed. Responses include token usage.

## Configuration

[`values.yaml`](values.yaml) is passed to the official chart. It enables
governance with mandatory virtual keys, the semantic-cache plugin, and the
embedded Chromem vector store. Chromem needs no additional service; its cache
is in memory and is lost when the Bifrost process restarts. The
governance budgets, rate limits, and virtual keys are created interactively in
the dashboard so the demo does not commit credentials or reusable virtual
keys.

For an existing installation, rerun `make bifrost-install` with
`OPENAI_API_KEY` exported to apply the vector-store configuration, then wait
for `kubectl rollout status statefulset/bifrost -n bifrost-demo`. Restart
port-forwarding if needed before running `make bifrost-demo`.

Provider, encryption, and dashboard setup credentials are provisioned as
Kubernetes Secrets by
[`scripts/install-bifrost.sh`](../../scripts/install-bifrost.sh). They are not
stored in the Helm values file. The setup token is injected as
`BIFROST_SETUP_TOKEN`; the encryption key and setup token are generated only
when their Secrets do not already exist, so reinstalling preserves them.

Use `BIFROST_NAMESPACE=<namespace> make bifrost-install` and
`BIFROST_NAMESPACE=<namespace> make bifrost-port-forward` for a different
namespace, and replace `bifrost-demo` in the token retrieval command accordingly.
Keep this demo local; do not expose it publicly without authentication and TLS.

## Existing installation reports a missing setup token

With `OPENAI_API_KEY` still exported, rerun `make bifrost-install` using the
updated installer and values file. This creates the missing setup-token Secret
and updates the workload to inject it, without replacing the existing
encryption key. Wait for the updated pod:

```sh
kubectl rollout status statefulset/bifrost -n bifrost-demo
```

Restart `make bifrost-port-forward` if the old pod's connection closes, then
retrieve the token as above and reload the dashboard to create the admin account.

## Clean up

```sh
make bifrost-uninstall
```

The uninstall target removes the demo namespace, including its Secrets and
persistent resources.
