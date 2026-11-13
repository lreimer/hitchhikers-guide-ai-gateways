# MCP federation and tool authorization

This add-on extends the [governed LLM demo](../README.md) from issue #2.
It installs neither another controller nor CRDs. Two official Python SDK
Streamable HTTP servers expose deterministic calculator and fictional catalog
tools through the existing single-replica agentgateway proxy.
No provider key, inference call, external account, database, or runtime data
source is required.

```text
SDK assertion client / optional MCP Inspector
                 |
        localhost:8080/mcp
                 |
       existing agentgateway
            /          \
      calculator      catalog
```

## Versions and validation status

| Component | Pinned version |
| --- | --- |
| agentgateway controller, proxy, CRD chart | `v1.7.0` (reuse the base installation) |
| Gateway API | Base demo's compatible standard bundle; local attempt used `1.6.3` |
| Backend Python image | `3.12.12-slim-bookworm`, digest pinned in `Dockerfile` |
| Official MCP Python SDK | `1.28.1` |
| MCP protocol in direct backend SDK/container checks | `2025-11-25` (gateway negotiation pending) |
| Python dependencies | Exact versions and hashes in `requirements.txt` |
| Optional MCP Inspector | `2.15.0` (not runtime-tested here) |

**End-to-end validation is pending.** On 2026-11-13, Kind `0.33.0`
successfully created a disposable Kubernetes `1.35.0` cluster, but base
installation failed resolving `cr.agentgateway.dev` while fetching the official
`agentgateway-crds:v1.7.0` chart. Consequently no claim is made that the gateway
walkthrough, alternate-namespace rerun, or before/after LLM regressions passed.
The release-specific schema and assertion expectations must be confirmed by
the runtime procedure below before calling this demo fully validated.
The assertion client prints the actual negotiated MCP protocol version; do not
infer it from the SDK version or assume every transport uses a session ID.

The implementation agent passed focused backend/client/JWT unit checks,
built the shared image, and exercised both read-only, capability-dropped
containers using the official SDK. Direct `/mcp` negotiation, `/readyz`,
deterministic outputs, invalid numeric inputs, and unknown products passed.
These checks do not prove gateway authentication, federation, or policy behavior.

Installation stages the MCP route without exposing the fixture tools, checks
authentication through a temporary localhost-only proxy port-forward, and only
then enables the real backend. It requires the external key directory and an
SDK-enabled Python (`AGENTGATEWAY_MCP_PYTHON`, default `python3`); only the public
JWKS enters Kubernetes. Reinstallation briefly detaches only the MCP route.

## Local build and setup

Prerequisites are the base demo's tools and credentials, Docker, Kind, and
Python 3.12 with `venv`/`pip`. Backend and assertion-client dependencies share
one hash-locked requirements file. From the repository root:

```sh
kind create cluster --name agentgateway-mcp --image kindest/node:v1.35.0 --wait 120s
docker build -t agentgateway-mcp:demo gateways/agentgateway/mcp
kind load docker-image agentgateway-mcp:demo --name agentgateway-mcp
python3 -m venv /tmp/agentgateway-mcp-venv
. /tmp/agentgateway-mcp-venv/bin/activate
python -m pip install --require-hashes -r gateways/agentgateway/mcp/requirements.txt
```

`requirements.in` declares the direct dependencies; the checked-in hash lock
was generated with `uv 0.13.8`. Dependency changes require regenerating the lock,
checking advisories, and rerunning the focused SDK checks.

Deployments use `imagePullPolicy: Never`: load the image onto every cluster
node first. Override `AGENTGATEWAY_MCP_IMAGE` only with another locally loaded
image. Neither publishing nor a registry account is needed.

Prepare stable Alice/Bob **LLM virtual keys** as described in the base README.
These remain independent of MCP JWTs. Install and verify mock mode first:

```sh
make agentgateway-install
# Separate terminal:
make agentgateway-port-forward
# Original terminal, with the same LLM key environment:
make agentgateway-demo
```

Keep the port-forward running. It binds only to `127.0.0.1`, exposes the existing
ClusterIP proxy's port 80 on local port 8080, and is shared by both demos.
Stop conflicting Bifrost/KrakenD forwards first. No backend is port-forwarded.

## Signing keys and short-lived JWTs

Manage signing material explicitly outside the repository:

```sh
export AGENTGATEWAY_MCP_KEY_DIR="$HOME/.config/agentgateway-mcp-demo"
python gateways/agentgateway/mcp/jwt_tool.py generate \
  --directory "$AGENTGATEWAY_MCP_KEY_DIR" --lifetime 900
make agentgateway-mcp-install
make agentgateway-mcp-demo
```

The helper creates an owned mode-0700 directory, mode-0600 private signing key,
public JWKS, and Alice/Bob tokens plus invalid-signature and expired negative
fixtures. It prints no tokens or keys. Existing signing material is preserved;
rerun the helper to renew tokens, not to silently rotate the key. Default
lifetime is 15 minutes (allowed range 60–3600 seconds). Do not enable shell
tracing, print token files, put tokens into command-line arguments, or commit
credential files. Provision the installer only with the public JWKS, either
through this directory or `AGENTGATEWAY_MCP_JWKS_FILE`.

Only the public verification key is embedded in the route policy. JWT validation
is strict and checks signature, issuer, audience, and required expiration and
subject claims. Authorization uses verified `jwt.sub`, not LLM virtual-key
metadata. The issuer is `https://agentgateway.demo.invalid` and audience is
`agentgateway-mcp-demo`. Use these defaults for the Make installation flow;
issuer and audience in `jwt_tool.py` and `policy.yaml` must remain consistent.

The pinned gateway uses `jsonwebtoken 11.1.0`'s built-in 60-second expiration
leeway; its Kubernetes schema has no skew override. This is not zero-skew
expiration enforcement. The expired negative fixture is signed with an
expiration 120 seconds in the past, beyond that allowance.

Renew tokens before running again:

```sh
python gateways/agentgateway/mcp/jwt_tool.py generate \
  --directory "$AGENTGATEWAY_MCP_KEY_DIR" --lifetime 900
make agentgateway-mcp-demo
```

Renewal reuses the public key and does not require reinstalling. Intentional key
rotation requires reprovisioning the public JWKS with the installer.

## Routing and access assertions

The client-facing URL is `http://127.0.0.1:8080/mcp`, not `/mcp/mcp`.
The route preserves `/mcp`; each internal Service advertises that endpoint
and the MCP app protocol. Explicit target names and `prefixMode: Always`
produce these expected release-specific names:

| Tool | Alice | Bob | Example result |
| --- | --- | --- | --- |
| `calculator_add` | Discover/call | Discover/call | `{"result": 5.0}` for 2 + 3 |
| `calculator_multiply` | Discover/call | Discover/call | `{"result": 42.0}` for 6 × 7 |
| `catalog_lookup_product` | Discover/call | Discover/call | Star Widget, price 12.5 |
| `catalog_lookup_internal_note` | Discover/call | Hidden/denied | Synthetic violet-batch note |

Backends implement no Alice/Bob authorization. The gateway checks original tool
and target context; the client uses the federated names. Discovery must match
the exact expected set, and Bob's direct call by the known internal-tool name
must independently fail. A transport error, arbitrary JSON-RPC error, fabricated
result, or HTTP success alone is not evidence of intended enforcement.

The bounded SDK client checks:

1. Missing, invalid-signature, and expired JWTs yield HTTP 401.
2. Alice discovers all four tools and receives exact fixed results.
3. Invalid calculator inputs, booleans, strings, and unknown products produce
   specific tool/input errors.
4. Bob discovers only permitted tools and successfully calls permitted tools.
5. Bob's direct internal-note call yields the expected authorization error.
6. Alice's request bucket throttles, Bob remains usable, and Alice recovers.

Expected gateway errors are asserted in `assertion_client.py`, including
authorization HTTP 400 with `-32602` / `unknown resource` and rate limiting `-32003` /
`rate limit exceeded`, or a tool result with `isError: true` and the specific
rate-limit message. These are pinned-source expectations, not yet a record
of observed gateway runtime responses.

For another local port, manually forward the same proxy and set
`AGENTGATEWAY_URL=http://127.0.0.1:18080`. The wrapper appends `/mcp`;
the direct client takes the **full** endpoint:

```sh
python gateways/agentgateway/mcp/assertion_client.py \
  --url http://127.0.0.1:18080/mcp \
  --token-directory "$AGENTGATEWAY_MCP_KEY_DIR" --phase auth
```

The direct command checks authentication and tool access. Use the Make wrapper
for the isolated throttling phase and policy restoration.

Use `NAMESPACE=mcp-alternate` consistently for base install, add-on install,
port-forward, both walkthroughs, and removal. `AGENTGATEWAY_NAMESPACE` remains
supported and takes precedence. Targets select only labeled Services in the
backend's namespace; no cross-namespace route attachment is introduced.

## Policies, limits, and repeatability

LLM API-key authentication, model authorization, and token budgets target only
the LLM/readiness HTTPRoutes. MCP JWT authentication and tool authorization
target only the MCP route; equal-specificity competing policies are rejected
rather than stacked. Do not weaken LLM controls, supply both credential types
in one Authorization header, or add an unauthenticated bypass route.

Local MCP request limits are keyed by verified JWT subject. Limits count HTTP
requests, including initialization and discovery, **not just tool executions**.
The installed interactive policy allows 120 requests/minute plus burst 120
(initial capacity 240), independently for each subject.
The walkthrough gives connection setup adequate headroom, separates policy
checks from throttling, uses bounded requests and short refill periods, and
checks MCP response content rather than assuming HTTP 429. A throttled tool
call may return HTTP 200 with `result.isError: true`; other methods can return
JSON-RPC `-32003`. Sessions are closed using the SDK where supported.

The throttling phase uses capacity 30 (`requests: 1`, `burst: 29`) and refills
one request each second (`unit: Seconds`). Fully refilling an exhausted bucket
takes 30 seconds; this is not a fixed 30-request/30-second window. New
per-scenario bucket suffixes isolate previous runs. Authorization checks run
with request limits temporarily removed, without changing authentication or
tool authorization.

Counters are in memory and per proxy replica, not durable or fleet-wide.
Restarting the proxy resets them. No Redis or external limit service is used.
The wrapper restores temporary MCP policy settings on success, failure, and
interruption and checks data-plane quota-header convergence; restoration failure
is itself a nonzero failure.

Run the complete acceptance sequence twice, once in an alternate namespace:

```sh
make agentgateway-demo
make agentgateway-mcp-install
make agentgateway-mcp-demo
make agentgateway-mcp-demo
make agentgateway-demo
make agentgateway-mcp-uninstall
make agentgateway-demo
```

Record actual gateway/protocol versions, full endpoint, exposed tool names,
MCP error semantics, recovery, and LLM checks before/after install/removal.
Do not run these LLM checks in OpenAI mode unintentionally: that mode incurs
inference charges. Static checks retain the repository's existing coverage:

```sh
make validate
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

## Optional Inspector

The SDK client is the deterministic acceptance tool. For exploration, use the
optional Inspector `@modelcontextprotocol/inspector@2.15.0` following the
[official Inspector guide](https://modelcontextprotocol.io/docs/tools/inspector).
Keep its UI/proxy local, retain Inspector authentication, choose Streamable
HTTP, enter the complete gateway `/mcp` URL, and provision an Authorization
****** from the private Alice or Bob token file in the UI. Do not put a
token in a URL or terminal command. Compare discovery and calls as both users;
leave throttling to the SDK client. Inspector compatibility is not certified
by this implementation.

## Cleanup, security limitations, and troubleshooting

```sh
make agentgateway-mcp-uninstall
# Explicitly remove user-managed credentials when no longer needed:
: "${AGENTGATEWAY_MCP_KEY_DIR:?Set the external credential directory first}"
rm -f "$AGENTGATEWAY_MCP_KEY_DIR"/{private.pem,jwks.json,alice.jwt,bob.jwt,invalid.jwt,expired.jwt}
rmdir "$AGENTGATEWAY_MCP_KEY_DIR"
unset AGENTGATEWAY_MCP_KEY_DIR
# After all other demonstrations finish:
kind delete cluster --name agentgateway-mcp
```

Add-on uninstall checks ownership before deleting its fixed resource set.
It preserves controller, CRDs, base Gateway, LLM demo, shared namespace, Bifrost,
unrelated workloads, and local signing files. Stop the shared port-forward
yourself when finished.

Backend Services remain ClusterIP-only, but **gateway authorization does not
prevent another cluster workload from calling a backend Service directly**.
Production network isolation is outside this demo's guarantees. Use only
synthetic fixtures; do not expose gateway, backend, or Inspector publicly.
Public deployment requires additional authentication/TLS and network controls.

- Missing or incompatible prerequisites: install/repair the pinned base demo
  rather than adding another controller or adopting someone else's resources.
- Pods not ready: verify the image is loaded into the correct Kind cluster,
  then inspect Deployment events and `/readyz` probes.
- Rejected policy/backend/route: inspect `kubectl describe` in the selected
  namespace; the installer performs server-side schema validation first.
- HTTP 401: renew tokens, confirm issuer/audience and public JWKS, and verify
  the selected key directory is owned and private.
- Unexpected tool names or denial errors: fail the assertions and inspect
  pinned-release behavior; do not relax checks to accept arbitrary failures.
- Transport timeout: verify the shared localhost forward and full `/mcp` URL.
- Registry DNS failure: restore access to the official registry before attempting
  Kubernetes validation; do not substitute an independent controller lifecycle.

## References

- [agentgateway v1.7 MCP federation](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/mcp/virtual/)
- [Tool authorization](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/mcp/tool-access/)
- [MCP request limits](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/mcp/rate-limit/)
- [Policy inheritance and merging](https://agentgateway.dev/docs/kubernetes/1.7.x/documentation/about/policies/target-merge/)
- [Official MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)
- [Pinned agentgateway source used for schema/error verification](https://github.com/agentgateway/agentgateway/tree/26f5aebe99a36a037fe54f8080a608aca5547e15)
