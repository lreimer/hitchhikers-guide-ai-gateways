# Go ADK BYO compatibility spike

## Result

The kagent v1.0.1 source and installed Harness API agree on the BYO contract.
The source/API gate passes, but the end-to-end compatibility gate is not yet
complete: this run did not execute a BYO image in Substrate, call the model or
MCP server from that image, or verify suspend/resume state.

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

## Local checks and remaining gate

This run observed Kubernetes v1.37.2, kagent v1.0.1, and a ready Substrate
v1.0.0 worker pool. The installed model configuration targets the existing
agentgateway route. However, the existing Bob MCP server reports
`DiscoveryFailed` with `Unauthorized`. No model call was made: the repository's
provider-backed evaluation requires an explicit `KAGENT_LIVE_EVAL=true`
opt-in, which was not set.

The custom image pull through a Substrate-reachable registry, a real A2A gRPC
request, model and MCP calls from the BYO workload, two-turn behavior, and
session restoration across suspend/resume remain unverified. In particular,
the registry reference and image digest for a locally built BYO application
have not yet been established.

**Decision:** Go for the pinned source/API contract; not yet Go for the
end-to-end integration gate. Keep #15 open until the remaining runtime checks
are demonstrated. Do not treat a successful `/readyz` request or this schema
dry run as an A2A success.

## References

- [kagent v1.0.1 BYO contract test](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/core/test/byoa2a/main.go)
- [kagent v1.0.1 Go ADK BYO example](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/adk/examples/byo/main.go)
- [kagent v1.0.1 A2A server](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/adk/pkg/a2a/server/server.go)
- [kagent v1.0.1 Harness API types](https://github.com/kagent-dev/kagent/blob/v1.0.1/go/api/v1alpha3/harness_types.go)
