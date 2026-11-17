# Product quote and internal support agents

This local evaluation adds two declarative kagent agents to the existing
agentgateway demo. Both model requests go through the authenticated OpenAI
Chat Completions route. Both agents call the existing `/mcp` route; the
gateway's Bob/Alice JWT policy, not the prompts, limits access to internal
notes.

| Agent | MCP identity | Tools |
| --- | --- | --- |
| Product Quote Assistant | Bob | Product lookup, add, multiply |
| Internal Product Support Assistant | Alice | Product lookup, internal note, add, multiply |

These are fixed demo roles, not identities for authenticated end users. The
shared `default-model-config` uses the Bob LLM client key and the existing
agentgateway model route. The two MCP `RemoteMCPServer` resources use separate
short-lived JWTs from Kubernetes Secrets.

## Runtime and cluster requirements

- Rancher Desktop Kubernetes, selected as the `rancher-desktop` kubectl context
- Kubernetes 1.37 or later; the local Rancher Desktop cluster used for this
  implementation reports server version `v1.37.2+k3s1`
- Helm 3.12+ or Helm 4.x, `kubectl`, the kagent CLI v1.0.1, `jq`, `openssl`,
  Python 3.12, and `uv`
- An installed agentgateway v1.7.0 demo and its MCP add-on in the same
  `AGENTGATEWAY_NAMESPACE`
- Docker Engine enabled in Rancher Desktop so the existing MCP image can be
  built locally without Kind

kagent 1.0 also installs Agent Substrate v1.0.0, its PodCertificate
controller, and a development PostgreSQL database. The CLI provisions the
substrate identities and database connection material. It installs resources
in the kagent namespace, `ate-system`, and
`podcertificate-controller-system`; these namespaces must be free before a
first install. This demo refuses to adopt existing namespaces, CRDs, or
matching Helm releases. The kagent UI route and bundled Kubernetes tool server
are disabled.

The pinned kagent chart supplies its release-compatible, digest-pinned native
runtime image. The kagent CLI installs the matching kagent v1.0.1 charts and
Agent Substrate v1.0.0 charts.

## Prepare the existing gateway and MCP add-on

Select Rancher Desktop and prepare the local MCP image and SDK environment:

```sh
kubectl config use-context rancher-desktop
docker build -t agentgateway-mcp:demo gateways/agentgateway/mcp
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
kagent CLI v1.0.1 and Helm 3.12+ or Helm 4.x. It waits for both agents to
become Ready.
To use a non-default agent namespace, set `KAGENT_NAMESPACE`; to use a
non-default gateway namespace, consistently set `AGENTGATEWAY_NAMESPACE` for
all gateway, MCP, and kagent targets.

The installer passes the Bob *gateway client key* to kagent's installer as its
required OpenAI-compatible API key. The generated ModelConfig points to the
agentgateway Service and uses `chatCompletions`; no provider key is sent to
kagent or stored in its namespace. Real provider access stays behind the
agentgateway OpenAI backend.

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

The bounded evaluation:

- Checks Bob's tool discovery and direct internal-note denial independently of
  model behavior.
- Checks the shared ModelConfig and both RemoteMCPServer URLs still point to
  the protected agentgateway routes.
- Invokes the quote agent for three Star Widgets, the support agent for the
  violet-batch note, and the quote agent for an unknown product and an
  impersonation request.
- Checks semantic outcomes and records tool-call names in the MCP server logs;
  it does not compare the model's exact prose.
- Renews the JWTs before the run and deletes the temporary kagent Sessions
  afterward.

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
Helm release identities and the namespace inventory, and refuses to remove
shared CRDs or runtime namespaces when unrelated resources exist. It removes
only the runtime's dedicated `ate-system` and
`podcertificate-controller-system` namespaces and keeps the kagent namespace.
The agentgateway and MCP targets remain independent; remove them only when no
other demo uses them.

## Release references

- [kagent v1.0.1 release](https://github.com/kagent-dev/kagent/releases/tag/v1.0.1)
- [kagent 1.0 installation requirements](https://kagent.dev/docs/kagent/1.x/setup/installation/)
- [Declarative agents](https://kagent.dev/docs/kagent/1.x/agents/declarative-agents/)
- [ModelConfig and OpenAI-compatible routing](https://kagent.dev/docs/kagent/1.x/setup/model-providers/openai/)
- [MCP tools and secret-backed headers](https://kagent.dev/docs/kagent/1.x/skills-and-mcp/about-tools/)
