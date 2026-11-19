# Product quote and internal support agents

This local evaluation adds two declarative kagent agents to the existing
agentgateway demo. Both model requests go through the authenticated OpenAI
Chat Completions route. Both agents call the existing `/mcp` route; the
gateway's Bob/Alice JWT policy, not the prompts, limits access to internal
notes.

The separate Go ADK BYO compatibility spike and its remaining live gates are
documented in [BYO compatibility](BYO-compatibility.md).

| Agent | MCP identity | Tools |
| --- | --- | --- |
| Product Quote Assistant | Bob | Product lookup, add, multiply |
| Internal Product Support Assistant | Alice | Product lookup, internal note, add, multiply |

These are fixed demo roles, not identities for authenticated end users. The
shared `default-model-config` uses the Bob LLM client key and the existing
agentgateway model route. The two MCP `RemoteMCPServer` resources use separate
short-lived JWTs from Kubernetes Secrets.

Model requests use the `kagent-model-gateway` ExternalName Service in the
kagent namespace, which resolves to the existing agentgateway proxy. MCP
requests use the proxy's original Service DNS name. These distinct HTTP
origins avoid kagent v1.0.1 credential conflicts: it binds credentials by
origin and header, not by URL path. Both paths still reach the same protected
gateway.

## Runtime and cluster requirements

- A local Kubernetes cluster: Rancher Desktop by default, or Kind
- Kubernetes 1.37 or later, with the certificate APIs and feature gates
  required by the pinned kagent/Substrate runtime
- Helm 3.12+ or Helm 4.x, `kubectl`, the kagent CLI v1.0.1, `jq`, `openssl`,
  Python 3.12, and `uv`
- An installed agentgateway v1.7.0 demo and its MCP add-on in the same
  `AGENTGATEWAY_NAMESPACE`
- Docker for building the MCP image; Rancher Desktop uses its Docker Engine,
  while Kind requires loading the image into its nodes

The kagent scripts expect the `rancher-desktop` context by default. To use
another local cluster, select its context explicitly and export
`KAGENT_CONTEXT` with the same name for installation, port-forwarding,
evaluation, and cleanup. Scripts refuse context mismatches and never switch
contexts automatically. The base gateway and MCP scripts use the current
kubectl context, so keep all demo operations on the same cluster.

kagent 1.0 also installs Agent Substrate v1.0.0, its PodCertificate
controller, and a development PostgreSQL database. The CLI provisions the
substrate identities and database connection material. It installs resources
in the kagent namespace, `ate-system`, and
`podcertificate-controller-system`; these namespaces must be free before a
first install. This demo refuses to adopt unrelated namespaces, CRDs, or
matching Helm releases. Ownership-verified repeat installations reuse the
existing runtime. The kagent UI route and bundled Kubernetes tool server are
disabled.

The pinned kagent chart supplies its release-compatible, digest-pinned native
runtime image. The kagent CLI installs the matching kagent v1.0.1 charts and
Agent Substrate v1.0.0 charts.

## Prepare a local cluster

Choose one of the following local workflows. Neither requires publishing an
image or a registry account. The MCP Deployments retain
`imagePullPolicy: Never`, so the selected image must exist on every node where
they can run.

### Rancher Desktop (default)

Enable Kubernetes and the Docker (Moby) container engine in Rancher Desktop.
Ensure the `docker` command targets that engine, not another Docker daemon:

```sh
kubectl config use-context rancher-desktop
export KAGENT_CONTEXT=rancher-desktop
docker build -t agentgateway-mcp:demo gateways/agentgateway/mcp
docker image inspect agentgateway-mcp:demo >/dev/null
```

The local environment inspected during development reports Kubernetes
`v1.37.2+k3s1` and a Docker node runtime. Installation, ownership-verified repeat
installation, both MCP discoveries, and the provider-backed `gpt-4o-mini`
evaluation have been verified on this setup using Helm 4.3.1.

### Kind (alternative)

Install Kind v0.33.0 and Docker. The
[Kind v0.33.0 release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0)
publishes the Kubernetes 1.37.0 node image pinned below. The supplied
[Kind configuration](kind-config.yaml) enables the certificate feature gates
and beta API used by the
[pinned kagent configuration](https://github.com/kagent-dev/kagent/blob/v1.0.1/scripts/kind/kind-config.yaml).
The proxy ARP/NDP preparation follows
[Substrate v1.0.0's local setup](https://github.com/kagent-dev/substrate/blob/v1.0.0/hack/create-kind-cluster.sh).
This alternative is documented from upstream sources but has not been run
end to end for this demo.

Run these commands only when choosing Kind instead of Rancher Desktop:

```sh
export KIND_EXPERIMENTAL_PROVIDER=docker
kind create cluster --name ai-gateway-demo \
  --image kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5 \
  --config agents/kagent/kind-config.yaml --wait 120s
kubectl config use-context kind-ai-gateway-demo
export KAGENT_CONTEXT=kind-ai-gateway-demo
docker exec ai-gateway-demo-control-plane sysctl net.ipv4.conf.all.proxy_arp=1
docker exec ai-gateway-demo-control-plane sysctl -e net.ipv6.conf.all.proxy_ndp=1
docker build -t agentgateway-mcp:demo gateways/agentgateway/mcp
kind load docker-image agentgateway-mcp:demo --name ai-gateway-demo
```

For an existing Kind cluster, ensure it meets the same Kubernetes and
certificate requirements before using it. Adjust the cluster/context names
and prepare every node if using a multi-node cluster. A default cluster from
an older Kind release may not meet the runtime requirements.

## Prepare the existing gateway and MCP add-on

After selecting the cluster and preparing its image, set up the SDK environment:

```sh
uv sync --project gateways/agentgateway/mcp --locked
. "$PWD/gateways/agentgateway/mcp/.venv/bin/activate"
export AGENTGATEWAY_MCP_PYTHON="$PWD/gateways/agentgateway/mcp/.venv/bin/python"
export AGENTGATEWAY_MCP_KEY_DIR="$HOME/.config/agentgateway-mcp-demo"
```

Use the secure Alice/Bob LLM key setup and the JWT signing-key setup in the
[agentgateway walkthrough](../../gateways/agentgateway/README.md) and
[MCP walkthrough](../../gateways/agentgateway/mcp/README.md). Keep those
credentials outside the repository. The kagent installer renews Alice/Bob
JWTs and stores the HTTP Authorization headers in Secret-backed
`RemoteMCPServer` references; it never prints the tokens.

Install the base gateway in mock mode if it is not already present, then
install the MCP add-on. These steps do not call an LLM provider:

```sh
make agentgateway-install
make agentgateway-mcp-install
make kagent-install
```

`kagent-install` requires `AGENTGATEWAY_BOB_KEY`, `AGENTGATEWAY_MCP_KEY_DIR`,
and an existing compatible gateway/MCP installation. It requires the pinned
kagent CLI v1.0.1 and Helm 3.12+ or Helm 4.x. It waits for both MCP servers to
become Accepted and both agents to become Ready. To use a non-default agent
namespace, set `KAGENT_NAMESPACE`;
to use a non-default gateway namespace, consistently set
`AGENTGATEWAY_NAMESPACE` for all gateway, MCP, and kagent targets.

The installer passes the Bob *gateway client key* to kagent's installer as its
required OpenAI-compatible API key. The generated ModelConfig points to the
agentgateway Service and uses `chatCompletions`; no provider key is sent to
kagent or stored in its namespace. Real provider access stays behind the
agentgateway OpenAI backend.

### Reinstallation and interrupted installs

The installer creates an ownership record before runtime provisioning and
checkpoints completed steps, namespace UIDs, Helm release identities and
statuses, CRDs, and resource inventories. Repeating a successful installation
verifies those records, reuses the runtime, and refreshes the demo credentials
and manifests. Garbage-collected PodCertificateRequests may disappear from
the recorded inventory; additions, replacements, and other removals still
require manual review.

If provisioning, Secret creation, manifest application, or readiness fails,
the exit handler records the partial state. Run `make kagent-uninstall` with
the same context and namespaces, then retry installation. Cleanup accepts the
recorded subset of releases, including failed or pending releases; it still
refuses changed identities or unrelated resources. It retains a `cleaned`
ownership record and namespace marker so a later install can safely reuse
the namespace.

If the process is forcibly killed or the API is unavailable while recording
failure, the last checkpoint may not match the cluster. Review those
resources manually; do not bypass the ownership safeguards or delete the
record to force adoption.

## Live evaluation

The default mock backend does not demonstrate agent reasoning or tool
selection. Live agent calls are disabled unless `KAGENT_LIVE_EVAL=true` is set,
and the script also refuses to run unless the installed agentgateway backend
mode is `openai`. Explicitly configure OpenAI mode and its provider key only
when you intend to incur provider charges:

```sh
AGENTGATEWAY_MODE=openai OPENAI_API_KEY=... make agentgateway-install
KAGENT_LIVE_EVAL=true make kagent-demo
```

The gateway retains its 10,000-token/hour allowance per LLM identity.
Repeated evaluations and diagnostic calls consume that allowance and can
return HTTP 429; allow quota to replenish before retrying.

The bounded evaluation:

- Checks Bob's tool discovery and direct internal-note denial independently of
  model behavior.
- Checks the shared ModelConfig and both RemoteMCPServer URLs still point to
  the protected agentgateway routes.
- Invokes the quote agent for three Star Widgets, the support agent for the
  violet-batch note, and the quote agent for an unknown product and an
  impersonation request.
- Checks semantic outcomes and records tool-call names in the MCP server logs;
  it does not compare the model's exact prose. A fresh whole-second log
  boundary after authentication checks excludes their tool calls.
- Renews the JWTs before the run and deletes the temporary kagent Sessions
  afterward.

The provider-backed evaluation passed on Rancher Desktop on 2026-11-17:

| Scenario | Verified outcome |
| --- | --- |
| Bob quote | $12.50 unit price and $37.50 total for three Star Widgets |
| Alice support | Synthetic violet-batch note retrieved |
| Unknown product | Reported absent rather than estimating |
| Bob internal note | Private note not disclosed; direct tool call denied |
| Tool-call evidence | Catalog lookup, internal-note lookup, and multiplication logged |

Tool descriptions supply exact catalog IDs rather than relying on the model
to guess identifiers from product names. MCP container logs use unwrapped
single-line records so the tool-name assertions can match complete names.

The evaluation starts temporary loopback-only forwards on ports `18083`
(kagent API) and `18080` (MCP assertions). Set `KAGENT_API_LOCAL_PORT` or
`AGENTGATEWAY_MCP_LOCAL_PORT` if either port is already in use.

Inspect calls without revealing request parameters or credentials:

```sh
kubectl logs -n "$AGENTGATEWAY_NAMESPACE" deployment/agentgateway-mcp-catalog --since=10m
kubectl logs -n "$AGENTGATEWAY_NAMESPACE" deployment/agentgateway-mcp-calculator --since=10m
```

The runtime UI has no external route. To open it locally, run
`make kagent-port-forward`; it binds to `127.0.0.1:8081`. Do not expose the
gateway, runtime UI, or privileged support agent publicly without suitable
authentication and TLS. The demo uses synthetic catalog data and plain HTTP
inside a local cluster; do not use it as a production security boundary.

## Cleanup

```sh
make kagent-uninstall
make agentgateway-mcp-uninstall
make agentgateway-uninstall
```

The kagent uninstaller requires the demo's ownership record, verifies pinned
Helm release identities, the installation context, and the namespace inventory,
and refuses to remove shared CRDs or runtime namespaces when unrelated
resources exist. It removes only the runtime's dedicated `ate-system` and
`podcertificate-controller-system` namespaces and keeps the kagent namespace.
It removes the model DNS alias and demo JWT Secrets but retains the ownership
record and namespace marker for verified reinstallation.
The agentgateway and MCP targets remain independent; remove them only when no
other demo uses them.

Keep the same `KAGENT_CONTEXT` setting used during installation. Cleanup
targets never delete the local cluster itself.

## Release references

- [kagent v1.0.1 release](https://github.com/kagent-dev/kagent/releases/tag/v1.0.1)
- [kagent 1.0 installation requirements](https://kagent.dev/docs/kagent/1.x/setup/installation/)
- [Declarative agents](https://kagent.dev/docs/kagent/1.x/agents/declarative-agents/)
- [ModelConfig and OpenAI-compatible routing](https://kagent.dev/docs/kagent/1.x/setup/model-providers/openai/)
- [MCP tools and secret-backed headers](https://kagent.dev/docs/kagent/1.x/skills-and-mcp/about-tools/)
