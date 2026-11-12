# KrakenD Community Edition on Kubernetes

This demo runs KrakenD Community Edition as a transparent proxy for OpenAI's
Chat Completions API. It uses KrakenD's standard proxy features; it does not
include the AI Gateway modules available in KrakenD Enterprise Edition.

## Prerequisites

- A Kubernetes cluster and a working `kubectl` context
- `curl`
- An OpenAI API key in `OPENAI_API_KEY` when running the sample request

## Install and try it

From the repository root:

```sh
make krakend-install
make krakend-port-forward
```

In another terminal:

```sh
export OPENAI_API_KEY=...
make krakend-demo
```

The demo checks KrakenD's `/__health` endpoint and, when `OPENAI_API_KEY` is
set, sends a sample Chat Completions request through KrakenD. The configuration
uses `no-op` encoding to preserve the upstream request and response, and an
explicit header allowlist to forward the OpenAI authorization and content-type
headers. The key is sent with the sample request and is not stored in
Kubernetes.

The service is a ClusterIP and the Make targets expose it only through a local
port-forward at <http://127.0.0.1:8080>. Do not expose this unauthenticated demo
publicly.

## Configuration

[`krakend.json`](krakend.json) configures a single `POST /v1/chat/completions`
endpoint backed by `https://api.openai.com/v1/chat/completions`.
[`deployment.yaml`](deployment.yaml) defines the Kubernetes Deployment and
ClusterIP Service. The installer creates a ConfigMap from `krakend.json` and
applies the workload manifest.

## Clean up

```sh
make krakend-uninstall
```

This removes the KrakenD demo namespace. Override it with
`KRAKEND_NAMESPACE` when running any `krakend-*` Make target.
