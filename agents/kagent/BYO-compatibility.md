# Go ADK BYO compatibility spike

## Result

The kagent v1.0.1 source and installed Harness API agree on the BYO contract.
The source/API gate passes. A runnable probe now exists under
`agents/kagent/byo-spike/`; `go test ./...`, an ARM64 container build, and
server-side dry runs of its Agent, AgentTemplate, and Harness all pass. The
corrected SQLite image passes the actual Substrate pull, readiness, A2A/gRPC,
model, Bob MCP, restored conversation, and fresh-session isolation checks.
The original in-memory image lost history because Substrate preserves durable
volumes, not process memory. Using kagent's actor-local SQLite helper fixes
that failure without a runtime upgrade or an additional database service.
The compatibility gate is Go for the corrected image documented below.

## Pins and runtime contract

The v1.0.1 Go module declares Go 1.27.3, `github.com/a2aproject/a2a-go/v2`
v2.7.0, and `google.golang.org/adk/v2` v2.6.0. The kagent helper module is
`github.com/kagent-dev/kagent/go`; it has no `go/v1.0.1` tag. Pin it to the
v1.0.1 release commit using the Go pseudo-version
`v0.0.0-20261111150159-558e3d761d8e`.

The [pinned BYO A2A example](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/core/test/byoa2a/main.go)
loads the Substrate bootstrap bundle from `/config`, materializes the runtime
configuration, and creates the server through kagent's `app.New` helper with
an `a2asrv.AgentExecutor`. The helper's server supports gRPC and HTTP on the
runtime port. The BYO example defaults that port to 80; the separate readiness
server answers `GET /readyz` on port 8081. Readiness alone therefore does not
prove that gRPC works.

The v1.0.1 Harness schema requires `byo: {}`, a non-empty
`workload.command`, and a `workload.image` pinned by SHA-256 digest. Exactly
one runtime selector must be set. A server-side dry run of a BYO Harness with
these fields succeeded against the installed v1.0.1 API:

```yaml
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata:
  name: byo-spike-15
  namespace: kagent
spec:
  byo: {}
  workload:
    image: ghcr.io/kagent-dev/kagent/golang-adk@sha256:d3b1151d39c529a6f921a58a995ff699963012001d2e5075f69bf613abebc24d
    command: ["/bin/true"]
  substrate:
    workerPoolRef:
      name: kagent-default
    snapshotPolicy:
      location: s3://ate-snapshots/kagent/
```

The image above is an existing pinned runtime image used only to validate the
API schema; it is not a BYO application image and was not pulled as a BYO
workload.

The generic [Go ADK BYO example](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/adk/examples/byo/main.go)
is not a substitute for this contract check: it configures port 8082 and
JSON-RPC, while the kagent BYO runtime contract requires the gRPC path on port
80.

## Registry access and runtime evidence

This run observed Kubernetes v1.37.2, kagent v1.0.1, and a ready Substrate
v1.0.0 worker pool. The installed model configuration targets the existing
agentgateway route. The explicitly opted-in, provider-backed evaluation of the
existing declarative agents passed for Bob's quote, Alice's support note,
unknown-product refusal, Bob's internal-note denial, and MCP tool-call logs.
It renewed the short-lived MCP credentials; both existing MCP servers now
report `Accepted=True`. This confirms the existing gateway paths, not the BYO
workload.

Substrate v1.0.0's `atelet` pulls BYO workload images itself. It pulls
anonymously unless a node image credential provider is configured; the local
`atelet` has no such provider configured. Kubernetes image pull secrets for
worker pods do not supply credentials to this separate image-pull path.
Consequently, a GHCR image must be public for this local setup, or the node
credential-provider configuration must be added and verified.

### Published image and initial registry failure

On 2026-11-19, the probe was rebuilt from the committed Dockerfile and pushed
for `linux/arm64` to `ghcr.io/lreimer/kagent-byo-spike:issue-15`. The published
OCI index digest is
`sha256:7a07748164013c841942e07d4e49dade78b61cbd334a58ff3630108e3e76cad5`;
the ARM64 image manifest digest is
`sha256:33391b0a180ef409504909529e3fdb0a72095df33924570852e24b844e97cf46`.
The same image was subsequently copied without rebuilding to the requested
repository-named package,
`ghcr.io/lreimer/hitchhikers-guide-ai-gateways:byo-spike-15-runtime`, with the
same index digest. The adjacent `byo-spike/harness.yaml` uses that package
with the newer SQLite image digest documented below, and explicitly starts
`/usr/local/bin/byo-spike`.
Initially, the repository-named package also reported `private`, and its
anonymous pull-token request returned HTTP 401. The owner subsequently made
that package public.

The Harness, AgentTemplate, and Agent were applied to namespace `kagent`.
The Agent reported `Accepted=True`, `ResolvedRefs=True`, and `Compatible=True`,
but `Ready=False` with `ActorTemplateRetrying`: the golden actor could not
pull its image. The `atelet` log at `2026-11-19T15:58:04Z` recorded:

```text
in remote.Image: GET https://ghcr.io/token?scope=repository%3Alreimer%2Fkagent-byo-spike%3Apull&service=ghcr.io: UNAUTHORIZED: authentication required
```

An independent anonymous request to the same GHCR token endpoint returned
HTTP 401. The authenticated package API confirmed `visibility: private`.
The image upload succeeded; the actual Substrate pull did not. The failed
probe resources were removed to stop golden-actor retries; existing demo
agents and node credential configuration were left unchanged.

### Public-image runtime retry

After the visibility change, anonymous GHCR access returned HTTP 200. The
first retry deployed the original image digest without rebuilding it.
These commands now deploy the corrected SQLite digest from the Harness:

```sh
kubectl apply -n kagent \
  -f agents/kagent/byo-spike/harness.yaml \
  -f agents/kagent/byo-spike/agent-template.yaml \
  -f agents/kagent/byo-spike/agent.yaml
kubectl wait -n kagent --for=condition=Ready \
  agent/byo-compatibility-probe --timeout=180s
```

The `atelet` recorded an image cache miss at `2026-11-19T16:04:43Z` and a
successful `Run` at `16:04:47Z`, including the `/readyz` wakeup probe on port
8081. The Agent reached `Ready=True` with its golden snapshot ready. Bob's
short-lived JWT was refreshed using the existing signing key and Kubernetes
Secret before the model/MCP requests; no provider credentials were added to
the image.

The original in-memory image produced these results:

| Runtime check | Observed result |
| --- | --- |
| Digest-pinned Substrate registry pull | Pass: public GHCR pull and golden actor startup succeeded. |
| Readiness on 8081 | Pass: `Run` completed with the `/readyz` wakeup probe and Agent became Ready. |
| A2A gateway to BYO gRPC service on port 80 | Pass: `kagent agent invoke` completed real tasks against the probe's gRPC interface. |
| Model through the existing gateway | Pass: `gpt-4o-mini` produced completed tasks with model token usage; the existing ModelConfig points to `kagent-model-gateway`, not OpenAI directly. |
| Bob catalog MCP through protected agentgateway | Pass: `catalog_lookup_product` returned `Star Widget`, price `12.5`, for `star-widget`. An earlier `HHG-42` lookup returned the expected unknown-product tool error. |
| Two-turn session continuity | Fail: the next turn in the same session did not remember `cobalt-otter-7319`. |
| New-session isolation | A separate session replied `I do not know.` and disclosed no marker. This does not establish durable isolation independently of the continuity failure. |
| Actual suspend/resume | Runtime lifecycle passes; conversation restoration fails. Successful `Checkpoint` and `Restore` calls occurred between turns, and the actor reached `ACTOR_STATE_SUSPENDED` with a completed `SNAPSHOT_FIDELITY_VOLUMES` snapshot in S3. |

The continuity session was `01a1f48d-f4f6-7514-ad7b-bb4464986f99`; the
separate session was `01a1f48f-1c96-7cef-9907-99d5f7bd0c7c`.
The first turn completed at `16:05:17Z`, followed by a successful checkpoint.
The next restore completed at `16:05:35Z`; the second turn completed at
`16:05:37Z` with `I do not know.` instead of the marker. SystemService actor
inspection confirmed a completed durable volume snapshot, not an assumed
idle delay or mere Session `READY` status.

To reproduce the conversational requests after deployment, refresh the Bob
credential with the existing demo JWT helper first, then expose the controller:

```sh
kubectl port-forward --address 127.0.0.1 -n kagent \
  svc/kagent-controller 18083:8083
```

In another terminal:

```sh
kg() {
  kagent --api-url http://127.0.0.1:18083 \
    --gateway-url http://127.0.0.1:18083 -n kagent -o json "$@"
}
session="$(kg agent session create --agent byo-compatibility-probe |
  jq -r '.session.id')"
kg agent invoke --session "$session" --task \
  'Remember this private session marker: cobalt-otter-7319. Use the catalog tool to look up product HHG-42 and report its name and price.'
kg agent invoke --session "$session" --task \
  'What private session marker did I give you in the previous turn? Reply with that exact marker if you remember, or say you do not know.'
kg agent invoke --session "$session" --task \
  'Use catalog_lookup_product to look up star-widget. Report the exact product name and price returned by the tool.'
grpcurl -plaintext -H 'x-user-id: admin@kagent.dev' \
  -d '{"atespace":"kagent","page":{"limit":100}}' \
  127.0.0.1:18083 kagent.api.v1.SystemService/ListSubstrateActors
kg agent session delete "$session" --force
```

### Actor-local conversation-store fix

The original `byo-spike/cmd/byo-spike/main.go` unconditionally created
`adksession.InMemoryService()`. A volume-only restore started the process
without that history. This was a probe implementation issue, not evidence
that the pinned runtime cannot support durable conversations.

The pinned kagent BYO compiler supplies
`session_db_url: sqlite+aiosqlite:////data/sessions.db`. The existing helper
`adk/pkg/session.NewService` accepts this URL and provides an actor-local
SQLite store on the snapshotted `/data` volume.
The pinned official runtime uses this helper. It normalizes conversation
storage keys within each actor's private database and closes idle SQLite
connections so restored files do not retain stale handles.

The probe now initializes this helper using
`agentConfig.GetAgent().GetSessionDbUrl()` (the loader returns the outer
`ADKConfig`, not its nested `AgentConfig`). Missing database configuration or
an initialization failure stops startup rather than silently reverting to
in-memory state. The same service is supplied to both the runner and executor.
`go mod tidy` records the helper's SQLite/GORM dependency closure without
changing the pinned kagent, ADK, or A2A versions. No additional database
service, volume, or runtime upgrade was introduced.

The corrected ARM64 image is published as
`ghcr.io/lreimer/hitchhikers-guide-ai-gateways:byo-spike-15-sqlite`.
Its OCI index digest is
`sha256:534a937798280039c65a3af7bf8bd57c4a991e0bee0c4dbedf5269cb50773ea0`,
and its ARM64 manifest digest is
`sha256:5dbe11e67406001831383cc7cedbf6858e48271f9f558c7f21fd7abd8a6fb89c`.
The Harness pins the corrected index. The Agent reached `Ready=True` on
revision `8e6f6212197c6cdd142b5cb7180048bfb868e0066f821e0c7cd5295ad8da9c13`.

### Corrected-image regression results

The corrected-image run completed catalog calls in two separate sessions,
then hit the existing gateway's 10,000-token/hour limit on the recall
request. The gateway logged HTTP 429 with `reason=RateLimit`; this was not
a SQLite error. After waiting for quota, the recall request succeeded.
Rate-limit configuration was not changed for the retry.

| Check | Before: in-memory image | After: SQLite image |
| --- | --- | --- |
| Prior-session marker after volume restore | Fail: `I do not know.` | Pass: recalled `cobalt-otter-8624`. |
| Prior product and price after volume restore | Not demonstrated | Pass: recalled `Star Widget` and `$12.50` without another catalog call. |
| Actor suspension and durable snapshot | Pass | Pass: `ACTOR_STATE_SUSPENDED`, `SNAPSHOT_FIDELITY_VOLUMES`, and completed S3 snapshot. |
| Fresh-session isolation | Inconclusive because history was lost | Pass: a fresh session reported no prior marker or product and disclosed neither test marker. |
| Protected model/catalog integration | Pass | Pass: completed `star-widget` and `moon-gadget` catalog calls in separate sessions, with prices `12.5` and `24`. |

The corrected continuity session was
`01a1f498-ac20-74f5-8e57-2f90227dfcd3`. Its first catalog turn completed at
`2026-11-19T16:16:51Z`, followed by a successful checkpoint. Another session,
`01a1f498-ba41-727b-ab32-c4f50f93f43c`, used the distinct marker
`amber-kestrel-5931` and queried `moon-gadget`. After the rate-limited attempts,
the original session restored at `16:27:48Z` and completed its recall at
`16:29:36Z`:

```text
Your private session marker is "cobalt-otter-8624." We looked up the product "Star Widget," which has a price of $12.50.
```

The following checkpoint completed successfully, and SystemService reported
the actor suspended with snapshot generation 5 and a completed durable
`VOLUMES` snapshot. This verifies restoration of the original history after
actual suspension, including across intervening failed model requests.

Fresh session `01a1f4a4-a650-7a20-aba4-c78bb4cc0d89` was then asked for its
prior marker and product without being given either. It completed with:

```text
You did not provide a private session marker or a product in this session.
```

All three corrected-image test sessions were deleted. The initial cleanup
of the continuity session briefly conflicted with an active checkpoint;
retrying after suspension succeeded, and the final session listing was
empty. The probe resources were subsequently removed with the cleanup
procedure below so they do not block the base demo's ownership checks.
`go test ./...`, `go vet ./...`, `go mod verify`, the ARM64 container build,
and `make validate` passed.

The earlier declarative live evaluation also printed three
`Session termination failed: 202` messages despite exiting successfully. A
follow-up session listing for the demo's default user returned no sessions, so
no temporary sessions remain; the messages still need explanation before
treating the output as a clean lifecycle trace.

**Decision:** Go for the pinned v1.0.1 BYO integration path using the corrected
SQLite image: registry pull, bootstrap/readiness, real A2A/gRPC, protected
model/MCP integration, conversation restoration after actual suspend/resume,
and fresh-session isolation were observed. This is a local compatibility
spike, not production lifecycle certification. No runtime upgrade was
performed.

## Manual probe cleanup

The spike resources are deliberately outside the base demo's ownership
inventory. Leaving them deployed makes `make kagent-install` and
`make kagent-uninstall` refuse to continue, even when no test sessions remain.
Remove the probe before running either target; do not extend or rewrite the
base ownership record to adopt these resources.

First delete only the test sessions you created, using their recorded IDs
with `kg agent session delete "$session" --force` as shown above. If deletion
conflicts with a pending checkpoint, wait for that lifecycle operation to
finish and retry. Stop the temporary controller port-forward afterward.

From the repository root, on the same local cluster used for installation:

```sh
source scripts/kagent-common.sh
kagent_demo_require_context &&
  kubectl delete -n kagent --ignore-not-found \
    --cascade=foreground --wait=true --timeout=120s \
    -f agents/kagent/byo-spike/agent.yaml \
    -f agents/kagent/byo-spike/agent-template.yaml \
    -f agents/kagent/byo-spike/harness.yaml
```

Foreground deletion waits for these objects and their Kubernetes
controller-owned dependents to disappear. It does not uninstall the base
agents, gateway, shared runtime, model configuration, or MCP credentials.
Verify that asynchronous cleanup has returned the recorded namespace and
custom-resource inventories to their original state with the same read-only
checks used by the base install/uninstall scripts:

```sh
record="$(kubectl get configmap kagent-demo-ownership -n kagent -o json)" &&
  kagent_demo_verify_installation kagent "$record"
```

If the check still reports inventory differences, allow controller cleanup
to finish and rerun it. Investigate any remaining differences rather than
deleting shared resources or bypassing the ownership checks.

## References

- [kagent v1.0.1 BYO contract test](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/core/test/byoa2a/main.go)
- [kagent v1.0.1 Go ADK BYO example](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/adk/examples/byo/main.go)
- [kagent v1.0.1 A2A server](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/adk/pkg/a2a/server/server.go)
- [kagent v1.0.1 Harness API types](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/api/v1alpha3/harness_types.go)
