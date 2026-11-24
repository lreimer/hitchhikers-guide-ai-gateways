import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class KagentContextTests(unittest.TestCase):
    def run_shell(
        self, script, context="rancher-desktop", expected="",
        version="v1.37.2+k3s1", record=None,
    ):
        return subprocess.run(
            [
                "bash", "-c",
                'source scripts/kagent-common.sh\n'
                'kubectl() {\n'
                '  case "$1" in\n'
                '    config) printf "%s" "$TEST_CONTEXT" ;;\n'
                '    version) printf \'{"serverVersion":{"gitVersion":"%s"}}\' "$TEST_VERSION" ;;\n'
                '    create) printf "%s\\n" "$@" ;;\n'
                '    label|apply) cat ;;\n'
                '    *) return 1 ;;\n'
                '  esac\n'
                '}\n' + script,
            ],
            cwd=ROOT,
            env={
                **os.environ,
                "KAGENT_CONTEXT": expected,
                "TEST_CONTEXT": context,
                "TEST_VERSION": version,
                "TEST_RECORD": json.dumps({"data": {"context": record}} if record else {}),
            },
            text=True,
            capture_output=True,
        )

    def test_accepts_default_and_explicit_kind_contexts(self):
        for context, expected in (
            ("rancher-desktop", ""),
            ("kind-ai-gateway-demo", "kind-ai-gateway-demo"),
        ):
            with self.subTest(context=context):
                result = self.run_shell("kagent_demo_require_context", context, expected)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_context_mismatches(self):
        for context, expected in (
            ("kind-ai-gateway-demo", ""),
            ("production", "kind-ai-gateway-demo"),
        ):
            with self.subTest(context=context, expected=expected):
                result = self.run_shell("kagent_demo_require_context", context, expected)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Expected kubectl context", result.stderr)
                self.assertIn("scripts do not switch contexts", result.stderr)

    def test_kind_context_still_requires_compatible_kubernetes(self):
        result = self.run_shell(
            "kagent_demo_require_context",
            context="kind-ai-gateway-demo",
            expected="kind-ai-gateway-demo",
            version="v1.36.4",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Kubernetes 1.37 or later", result.stderr)

    def test_records_actual_installation_context(self):
        for context in ("rancher-desktop", "kind-ai-gateway-demo"):
            with self.subTest(context=context):
                result = self.run_shell(
                    "kagent_demo_write_owner_record kagent agentgateway-demo '[]' '[]' '[]' '[]' ready agents-ready '[]'",
                    context=context,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"--from-literal=context={context}\n", result.stdout)

    def test_verifies_recorded_context_for_both_local_clusters(self):
        for context in ("rancher-desktop", "kind-ai-gateway-demo"):
            with self.subTest(context=context):
                result = self.run_shell(
                    'kagent_demo_verify_recorded_context "$TEST_RECORD"',
                    context=context,
                    record=context,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_or_mismatched_recorded_context(self):
        for record in (None, "rancher-desktop"):
            with self.subTest(record=record):
                result = self.run_shell(
                    'kagent_demo_verify_recorded_context "$TEST_RECORD"',
                    context="kind-ai-gateway-demo",
                    record=record,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ownership record context", result.stderr)

    def test_make_forwards_context_override_to_all_kagent_targets(self):
        for target in ("install", "port-forward", "demo", "uninstall"):
            with self.subTest(target=target):
                result = subprocess.run(
                    ["make", "--dry-run", f"kagent-{target}", "KAGENT_CONTEXT=kind-ai-gateway-demo"],
                    cwd=ROOT, text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('KAGENT_CONTEXT="kind-ai-gateway-demo"', result.stdout)


class KagentEvaluationTests(unittest.TestCase):
    def test_plain_text_response_assertions(self):
        script = (ROOT / "scripts/demo-kagent.sh").read_text()
        checks = re.findall(r"jq (-[A-Za-z]+) '(test\([^\n]+)'", script)
        self.assertEqual(len(checks), 3)
        for (flags, expression), valid, invalid in zip(checks, (
            "Star Widget: $12.50 each.\nTotal: $37.50.",
            "The next batch is painted VIOLET.",
            "The product was not found.",
        ), (
            "Star Widget: $12.50 each, total $25.00.",
            "No support note is available.",
            "The price is probably $10.",
        )):
            for text, expected in ((valid, 0), (invalid, 1)):
                with self.subTest(expression=expression, text=text):
                    result = subprocess.run(
                        ["jq", flags, expression], input=text, text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)

    def test_invoke_retries_only_the_specific_session_not_ready_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            for mode, expected_status, expected_count in (
                ("ready-after-two", 0, 3),
                ("unrelated", 1, 1),
                ("never-ready", 1, 6),
            ):
                with self.subTest(mode=mode):
                    counter = path / "counter"
                    counter.write_text("0")
                    result = subprocess.run(
                        ["bash", "-c", """
set -euo pipefail
source scripts/kagent-common.sh
sleep() { :; }
kagent() {
  local count
  count="$(cat "$TEST_COUNTER")"
  count="$((count + 1))"
  printf '%s' "$count" > "$TEST_COUNTER"
  case "$TEST_MODE" in
    ready-after-two)
      if (( count < 3 )); then
        printf 'Error: input was not accepted; retry after the session becomes available\\n' >&2
        return 1
      fi ;;
    never-ready)
      printf 'Error: input was not accepted; retry after the session becomes available\\n' >&2
      return 1 ;;
    unrelated)
      printf 'Error: model request failed\\n' >&2
      return 1 ;;
  esac
  printf '{"status":"accepted"}'
}
kagent_demo_invoke_with_retry "$TEST_OUTPUT" "$TEST_ERROR" kagent invoke
cat "$TEST_OUTPUT"
"""],
                        cwd=ROOT,
                        env={
                            **os.environ,
                            "TEST_COUNTER": str(counter),
                            "TEST_OUTPUT": str(path / "response.json"),
                            "TEST_ERROR": str(path / "invoke-error.log"),
                            "TEST_MODE": mode,
                        },
                        text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode, expected_status, result.stderr)
                    self.assertEqual(int(counter.read_text()), expected_count)
                    if mode == "ready-after-two":
                        self.assertEqual(result.stdout, '{"status":"accepted"}')
                    if mode == "unrelated":
                        self.assertIn("model request failed", result.stderr)
                    if mode == "never-ready":
                        self.assertIn("six bounded invoke attempts", result.stderr)

    def test_log_boundary_waits_past_authentication_second(self):
        with tempfile.TemporaryDirectory() as directory:
            counter = Path(directory) / "counter"
            counter.write_text("0")
            result = subprocess.run(
                ["bash", "-c", """
source scripts/kagent-common.sh
date() {
  local count
  count="$(cat "$TEST_COUNTER")"
  printf '%s' "$((count + 1))" > "$TEST_COUNTER"
  if (( count < 2 )); then
    printf '2026-11-17T10:00:00Z'
  else
    printf '2026-11-17T10:00:01Z'
  fi
}
sleep() { :; }
kagent_demo_log_boundary
"""],
                cwd=ROOT, env={**os.environ, "TEST_COUNTER": str(counter)},
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "2026-11-17T10:00:01Z")
            self.assertEqual(counter.read_text(), "3")

    def test_routing_guard_checks_active_fields_and_dns_alias(self):
        endpoint = "http://kagent-model-gateway.custom.svc.cluster.local/v1"
        spec = {
            "provider": "OpenAI", "model": "demo-model",
            "openAI": {"baseUrl": endpoint, "apiFormat": "chatCompletions"},
        }
        service = {
            "metadata": {"labels": {"app.kubernetes.io/managed-by": "kagent-demo"}},
            "spec": {
                "type": "ExternalName",
                "externalName": "agentgateway-proxy.gateway.svc.cluster.local",
                "ports": [{"port": 80}],
            },
        }
        mutations = (
            None,
            ("provider", "Anthropic"),
            ("model", "different-model"),
            ("baseUrl", "https://api.example.invalid/v1"),
            ("apiFormat", "responses"),
            ("externalName", "different-gateway.gateway.svc.cluster.local"),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                config = {
                    "spec": json.loads(json.dumps(spec)),
                    "metadata": {"annotations": {"stale": json.dumps(spec)}},
                }
                alias = json.loads(json.dumps(service))
                if mutation:
                    field, value = mutation
                    if field in ("baseUrl", "apiFormat"):
                        config["spec"]["openAI"][field] = value
                    elif field == "externalName":
                        alias["spec"][field] = value
                    else:
                        config["spec"][field] = value
                result = subprocess.run(
                    ["bash", "-c", """
source scripts/kagent-common.sh
kubectl() {
  if [[ "$2" == modelconfig ]]; then printf '%s' "$TEST_CONFIG";
  else printf '%s' "$TEST_ALIAS"; fi
}
kagent_demo_verify_model_config custom gateway demo-model
"""],
                    cwd=ROOT,
                    env={**os.environ, "TEST_CONFIG": json.dumps(config), "TEST_ALIAS": json.dumps(alias)},
                    text=True, capture_output=True,
                )
                self.assertEqual(result.returncode == 0, mutation is None, result.stderr)


class KagentOwnershipTests(unittest.TestCase):
    def run_shell(self, script, releases=None, namespaces=None, extra_env=None):
        releases = releases or []
        namespaces = namespaces or {}
        return subprocess.run(
            ["bash", "-c", """
set -euo pipefail
source scripts/kagent-common.sh
helm() {
  local namespace
  while (( $# )); do
    if [[ "$1" == --namespace ]]; then namespace="$2"; shift; fi
    shift
  done
  jq -c --arg namespace "$namespace" '[.[] | select(.namespace == $namespace)]' <<<"$TEST_RELEASES"
}
kubectl() {
  case "$1 $2" in
    "config current-context") printf rancher-desktop ;;
    "get secret") printf '{"metadata":{"uid":"%s"}}' "${TEST_SECRET_UID:-release-uid}" ;;
    "get namespace")
      jq -c --arg name "$3" '.[$name] // empty' <<<"$TEST_NAMESPACES" ;;
    "get crds") printf '{"items":[]}' ;;
    "get pods") printf '{"items":[]}' ;;
    "get configmaps")
      jq -c '{items:.}' <<<"$TEST_INVENTORY" ;;
    "api-resources --namespaced")
      if [[ "$TEST_INVENTORY" != '[]' ]]; then printf configmaps; fi ;;
    "api-resources "*) : ;;
    "create configmap") printf '%s\\n' "$@" ;;
    "label --local"|"apply -f") cat ;;
    *) printf 'Unexpected kubectl: %s\\n' "$*" >&2; return 1 ;;
  esac
}
""" + script],
            cwd=ROOT,
            env={
                **os.environ,
                "TEST_RELEASES": json.dumps(releases),
                "TEST_NAMESPACES": json.dumps(namespaces),
                "TEST_INVENTORY": "[]",
                **(extra_env or {}),
            },
            text=True, capture_output=True,
        )

    def namespace(self, name, uid="namespace-uid", owned=True):
        return {"metadata": {
            "name": name, "uid": uid,
            "labels": {"demo.kagent.dev/owned": "true"} if owned else {},
        }}

    def release(self, name="kagent", namespace="custom", status="deployed"):
        version = "1.0.1" if name.startswith("kagent") else "1.0.0"
        return {"name": name, "namespace": namespace, "status": status, "revision": 1, "chart": f"{name}-{version}"}

    def test_captures_and_verifies_custom_namespace_releases(self):
        releases = [
            self.release(name, namespace) for name, namespace in (
                ("kagent", "custom"), ("kagent-crds", "custom"),
                ("substrate", "ate-system"), ("substrate-crds", "ate-system"),
                ("substrate-atelet", "ate-system"),
                ("substrate-podcert", "podcertificate-controller-system"),
            )
        ]
        result = self.run_shell("""
captured="$(kagent_demo_capture_releases custom)"
kagent_demo_verify_recorded_releases custom "$captured"
printf '%s' "$captured"
""", releases=releases)
        self.assertEqual(result.returncode, 0, result.stderr)
        captured = json.loads(result.stdout)
        self.assertEqual(len(captured), 6)
        self.assertEqual({r["namespace"] for r in captured if r["name"].startswith("kagent")}, {"custom"})

    def test_partial_release_capture_supports_failed_install_cleanup(self):
        result = self.run_shell("""
captured="$(kagent_demo_capture_releases custom partial)"
kagent_demo_verify_recorded_releases custom "$captured"
printf '%s' "$captured"
""", releases=[self.release("kagent-crds", status="failed")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]["status"], "failed")

    def test_rejects_replaced_release_secret(self):
        result = self.run_shell("""
captured="$(kagent_demo_capture_releases custom partial)"
TEST_SECRET_UID=replacement-uid
kagent_demo_verify_recorded_releases custom "$captured"
""", releases=[self.release()])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Helm release identities", result.stderr)

    def test_cleaned_namespace_marker_supports_verified_reinstall(self):
        namespaces = {"custom": self.namespace("custom")}
        result = self.run_shell("""
kagent_demo_write_owner_record() {
  jq -cn --arg releases "$3" --arg crds "$4" --arg inventory "$5" \
    --arg custom "$6" --arg phase "$7" --arg namespaces "$9" '{
      metadata:{labels:{"app.kubernetes.io/managed-by":"kagent-demo"}},
      data:{context:"rancher-desktop","kagent-version":"1.0.1",
        releases:$releases,crds:$crds,inventory:$inventory,
        "custom-resources":$custom,phase:$phase,namespaces:$namespaces}}'
}
record="$(kagent_demo_checkpoint custom gateway cleaned runtime-removed)"
kagent_demo_verify_installation custom "$record"
printf '%s' "$record"
""", namespaces=namespaces)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["data"]["phase"], "cleaned")

    def test_rejects_unowned_and_replaced_namespaces(self):
        for owned in (True, False):
            with self.subTest(owned=owned):
                result = self.run_shell("""
record='{"metadata":{"labels":{"app.kubernetes.io/managed-by":"kagent-demo"}},
  "data":{"context":"rancher-desktop","kagent-version":"1.0.1","phase":"cleaned",
    "namespaces":"[{\\"name\\":\\"custom\\",\\"uid\\":\\"original-uid\\"}]"}}'
kagent_demo_verify_installation custom "$record"
""", namespaces={"custom": self.namespace("custom", uid="replacement-uid", owned=owned)})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Namespace" if not owned else "namespace identities", result.stderr)

    def test_provisional_checkpoint_tracks_partial_resources_and_step(self):
        result = self.run_shell(
            "kagent_demo_checkpoint custom gateway failed runtime",
            releases=[self.release("kagent-crds", status="failed")],
            namespaces={"custom": self.namespace("custom")},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--from-literal=phase=failed\n", result.stdout)
        self.assertIn("--from-literal=completed-step=runtime\n", result.stdout)
        self.assertIn('"status":"failed"', result.stdout)
        self.assertIn('"uid":"namespace-uid"', result.stdout)

    def test_inventory_captures_resources_and_rejects_later_additions(self):
        fixture = {"kind": "ConfigMap", "metadata": {
            "name": "runtime-config", "namespace": "custom", "uid": "config-uid",
        }}
        result = self.run_shell("""
captured="$(kagent_demo_capture_inventory custom)"
jq -e 'length == 1 and .[0].name == "runtime-config"' <<<"$captured" >/dev/null
TEST_INVENTORY="$(jq '. + [{kind:"ConfigMap",metadata:{
  name:"unrelated",namespace:"custom",uid:"unrelated-uid"}}]' <<<"$TEST_INVENTORY")"
kagent_demo_verify_inventory custom "$captured"
""", namespaces={"custom": self.namespace("custom")},
            extra_env={"TEST_INVENTORY": json.dumps([fixture])})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Resources in the kagent runtime namespaces changed", result.stderr)

    def test_inventory_excludes_only_byo_addon_owned_resources(self):
        inventory = [
            {"kind": "ConfigMap", "metadata": {
                "name": "runtime-config", "namespace": "custom", "uid": "runtime-uid",
                "labels": {"app.kubernetes.io/managed-by": "kagent-demo"},
            }},
            {"kind": "Agent", "metadata": {
                "name": "product-quote-byo-assistant", "namespace": "custom", "uid": "byo-uid",
                "labels": {"app.kubernetes.io/managed-by": "kagent-byo-addon"},
            }},
            {"kind": "ConfigMap", "metadata": {
                "name": "unrelated-addon-labelled", "namespace": "custom", "uid": "other-uid",
                "labels": {"app.kubernetes.io/managed-by": "kagent-byo-addon"},
            }},
        ]
        result = self.run_shell("""
captured="$(kagent_demo_capture_inventory custom)"
printf '%s' "$captured"
""", namespaces={"custom": self.namespace("custom")},
            extra_env={"TEST_INVENTORY": json.dumps(inventory)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [entry["name"] for entry in json.loads(result.stdout)],
            ["runtime-config", "unrelated-addon-labelled"],
        )

    def test_only_garbage_collected_certificate_requests_may_disappear(self):
        config = {
            "resource": "configmaps", "namespace": "custom",
            "name": "runtime-config", "uid": "config-uid",
        }
        request = {
            "resource": "podcertificaterequests.certificates.k8s.io",
            "namespace": "custom", "name": "issued-request", "uid": "request-uid",
        }
        for scenario, actual, accepted in (
            ("garbage collection", [config], True),
            ("removed config", [], False),
            ("replaced request", [config, {**request, "uid": "replacement"}], False),
            ("new request", [config, request, {
                **request, "name": "unrelated", "uid": "new-uid",
            }], False),
        ):
            with self.subTest(scenario=scenario):
                result = self.run_shell("""
kagent_demo_capture_inventory() { printf '%s' "$TEST_ACTUAL"; }
kagent_demo_verify_inventory custom "$TEST_EXPECTED"
""", extra_env={
                    "TEST_EXPECTED": json.dumps([config, request]),
                    "TEST_ACTUAL": json.dumps(actual),
                })
                self.assertEqual(result.returncode == 0, accepted, result.stderr)


class KagentInstallRecoveryTests(unittest.TestCase):
    def run_install_steps(self, failure="", reuse=False):
        script = (ROOT / "scripts/install-kagent.sh").read_text()
        steps = script[script.index('install_dir="$(mktemp'):]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            for identity in ("bob", "alice"):
                (path / f"{identity}.jwt").write_text("test-only-token")
            result = subprocess.run(
                ["bash", "-c", """
set -euo pipefail
source scripts/kagent-common.sh
root_dir="$PWD"
namespace=custom
gateway_namespace=gateway
model=demo-model
backend_mode=mock
key_directory="$TEST_DIRECTORY"
reuse_runtime="$TEST_REUSE"
kagent_demo_prepare_namespace() { printf 'namespace:%s\\n' "$1" >> "$TEST_LOG"; }
kagent_demo_checkpoint() { printf 'checkpoint:%s:%s\\n' "$3" "$4" >> "$TEST_LOG"; }
kagent_demo_capture_releases() { printf '[]'; }
kagent() {
  printf 'runtime-install\\n' >> "$TEST_LOG"
  [[ "$TEST_FAILURE" != runtime ]]
}
kubectl() {
  local content
  case "$1" in
    config) printf rancher-desktop ;;
    create)
      cat >/dev/null
      [[ "$TEST_FAILURE" != credentials ]] || return 1
      printf 'kind: Secret\\n' ;;
    label) cat ;;
    apply)
      content="$(cat)"
      if [[ "$TEST_FAILURE" == manifest && "$content" == *"kind: AgentTemplate"* ]]; then
        return 1
      fi ;;
    rollout) : ;;
    wait) [[ "$TEST_FAILURE" != readiness ]] ;;
    *) return 1 ;;
  esac
}
""" + steps],
                cwd=ROOT,
                env={
                    **os.environ, "TEST_DIRECTORY": directory,
                    "TEST_LOG": str(path / "actions"),
                    "TEST_FAILURE": failure, "TEST_REUSE": str(reuse).lower(),
                    "AGENTGATEWAY_BOB_KEY": "test-only-client-key",
                },
                text=True, capture_output=True,
            )
            return result, (path / "actions").read_text().splitlines()

    def test_records_ownership_before_runtime_and_checkpoints_failures(self):
        for failure, completed in (
            ("runtime", "namespaces"),
            ("credentials", "runtime"),
            ("manifest", "credentials"),
            ("readiness", "agents"),
        ):
            with self.subTest(failure=failure):
                result, actions = self.run_install_steps(failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertLess(
                    actions.index("checkpoint:installing:namespace"),
                    actions.index("runtime-install"),
                )
                self.assertEqual(actions[-1], f"checkpoint:failed:{completed}")

    def test_verified_reinstall_reuses_runtime_and_finishes_ready(self):
        result, actions = self.run_install_steps(reuse=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("runtime-install", actions)
        self.assertEqual(actions[-1], "checkpoint:ready:agents-ready")


class KagentHelmTests(unittest.TestCase):
    def check_version(self, version, status=0):
        return subprocess.run(
            [
                "bash", "-c",
                'source scripts/kagent-common.sh\n'
                'helm() { printf "%s" "$TEST_HELM_VERSION"; '
                'return "$TEST_HELM_STATUS"; }\n'
                'kagent_demo_require_helm\n',
            ],
            cwd=ROOT,
            env={
                **os.environ,
                "TEST_HELM_VERSION": version,
                "TEST_HELM_STATUS": str(status),
            },
            text=True,
            capture_output=True,
        )

    def test_accepts_helm3_minimum_and_helm4(self):
        for version in ("v3.12.0+build", "v3.19.0", "v4.0.0", "v4.3.1+gc0d08d0"):
            with self.subTest(version=version):
                result = self.check_version(version)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_old_unknown_and_unrecognized_major_versions(self):
        for version in ("v2.17.0", "v3.11.3", "v5.0.0", "unknown", ""):
            with self.subTest(version=version):
                result = self.check_version(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("requires Helm 3.12+ or Helm 4.x", result.stderr)

    def test_reports_failed_version_command(self):
        result = self.check_version("v4.3.1", status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not determine the Helm version", result.stderr)


class KagentByoTests(unittest.TestCase):
    def run_shell(self, script, extra_env=None):
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\nsource scripts/kagent-byo-common.sh\n" + script],
            cwd=ROOT,
            env={**os.environ, **(extra_env or {})},
            text=True,
            capture_output=True,
        )

    def test_make_targets_integrate_build_install_demo_and_cleanup(self):
        expected = {
            "kagent-byo-build": "build-kagent-byo.sh",
            "kagent-byo-install": "install-kagent-byo.sh",
            "kagent-byo-uninstall": "uninstall-kagent-byo.sh",
        }
        for target, script in expected.items():
            with self.subTest(target=target):
                result = subprocess.run(
                    ["make", "--dry-run", target],
                    cwd=ROOT, text=True, capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(script, result.stdout)
        demo = subprocess.run(
            ["make", "--dry-run", "kagent-byo-demo"],
            cwd=ROOT, text=True, capture_output=True,
        )
        self.assertEqual(demo.returncode, 0, demo.stderr)
        self.assertIn("product-quote-byo-assistant", demo.stdout)
        self.assertIn("KAGENT_BYO_SESSION_TRACKING=true", demo.stdout)

    def test_only_accepts_confirmed_registry_digest(self):
        valid = "ghcr.io/lreimer/hitchhikers-guide-ai-gateways@sha256:" + "a" * 64
        result = self.run_shell('kagent_byo_validate_image "$TEST_IMAGE"', {"TEST_IMAGE": valid})
        self.assertEqual(result.returncode, 0, result.stderr)
        for image in (
            "ghcr.io/lreimer/hitchhikers-guide-ai-gateways:latest",
            "ghcr.io/other/image@sha256:" + "a" * 64,
            "ghcr.io/lreimer/hitchhikers-guide-ai-gateways@sha256:abc",
        ):
            with self.subTest(image=image):
                result = self.run_shell(
                    'kagent_byo_validate_image "$TEST_IMAGE"', {"TEST_IMAGE": image},
                )
                self.assertNotEqual(result.returncode, 0)

    def test_cleaned_ownership_record_allows_safe_reinstall(self):
        for phase in ("ready", "installing", "failed", "cleaned"):
            with self.subTest(phase=phase):
                result = self.run_shell(
                    'kagent_byo_validate_install_phase "$TEST_PHASE"',
                    {"TEST_PHASE": phase},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_shell(
            'kagent_byo_validate_install_phase "$TEST_PHASE"',
            {"TEST_PHASE": "cleanup-failed"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("finish make kagent-byo-uninstall", result.stderr)

    def test_build_pushes_to_the_confirmed_registry_and_returns_its_digest(self):
        digest = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            docker = path / "docker"
            args_file = path / "docker-args"
            docker.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" > \"$TEST_DOCKER_ARGS\"\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "  if [ \"$1\" = --metadata-file ]; then\n"
                "    shift\n"
                f"    printf '{{\"containerimage.digest\":\"{digest}\"}}' > \"$1\"\n"
                "  fi\n"
                "  shift\n"
                "done\n",
            )
            docker.chmod(0o755)
            result = subprocess.run(
                [str(ROOT / "scripts/build-kagent-byo.sh")],
                cwd=ROOT,
                env={
                    **os.environ,
                    "PATH": f"{directory}:{os.environ['PATH']}",
                    "TEST_DOCKER_ARGS": str(args_file),
                },
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                result.stdout.strip(),
                "export KAGENT_BYO_IMAGE='ghcr.io/lreimer/hitchhikers-guide-ai-gateways@"
                + digest + "'",
            )
            self.assertIn("--platform linux/arm64 --push", args_file.read_text())

    def test_owned_resource_record_detects_replacement_and_foreign_objects(self):
        objects = {
            f"{kind}/{name}": {
                "metadata": {
                    "name": name, "uid": kind + "-" + name + "-uid",
                    "labels": {"app.kubernetes.io/managed-by": "kagent-byo-addon"},
                },
            }
            for kind, name in (
                ("harness", "kagent-byo-harness"),
                ("agenttemplate", "product-quote-byo-assistant"),
                ("agent", "product-quote-byo-assistant"),
            )
        }
        mock = """
kubectl() {
  case "$1 $2" in
    "config current-context") printf rancher-desktop ;;
    "get "*)
      jq -c --arg resource "$2/$3" '.[$resource] // empty' <<<"$TEST_OBJECTS" ;;
    *) return 1 ;;
  esac
}
"""
        expected = [
            {"kind": kind, "name": name, "uid": kind + "-" + name + "-uid"}
            for kind, name in (
                ("harness", "kagent-byo-harness"),
                ("agenttemplate", "product-quote-byo-assistant"),
                ("agent", "product-quote-byo-assistant"),
            )
        ]
        setup = """
record="$(jq -cn --arg resources "$TEST_EXPECTED" '{
  metadata:{labels:{"app.kubernetes.io/managed-by":"kagent-byo-addon"}},
  data:{context:"rancher-desktop",phase:"ready",resources:$resources,sessions:"[]"}}')"
kagent_byo_verify_record custom "$record"
"""
        result = self.run_shell(
            mock + setup, {
                "TEST_OBJECTS": json.dumps(objects),
                "TEST_EXPECTED": json.dumps(expected),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        replaced = json.loads(json.dumps(objects))
        replaced["harness/kagent-byo-harness"]["metadata"]["uid"] = "replacement-uid"
        result = self.run_shell(
            mock + setup, {
                "TEST_OBJECTS": json.dumps(replaced),
                "TEST_EXPECTED": json.dumps(expected),
            },
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("identities changed", result.stderr)
        unowned = json.loads(json.dumps(objects))
        unowned["harness/kagent-byo-harness"]["metadata"]["labels"] = {}
        result = self.run_shell(
            mock + setup, {
                "TEST_OBJECTS": json.dumps(unowned),
                "TEST_EXPECTED": json.dumps(expected),
            },
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to adopt unowned", result.stderr)

    def test_cleanup_can_resume_only_by_removing_recorded_resources(self):
        expected = [
            {"kind": "harness", "name": "kagent-byo-harness", "uid": "harness-uid"},
            {"kind": "agenttemplate", "name": "product-quote-byo-assistant", "uid": "template-uid"},
            {"kind": "agent", "name": "product-quote-byo-assistant", "uid": "agent-uid"},
        ]
        actual = expected[:2]
        result = self.run_shell("""
kubectl() {
  case "$1 $2" in
    "config current-context") printf rancher-desktop ;;
    "get "*)
      jq -c --arg resource "$2/$3" '.[$resource] // empty' <<<"$TEST_OBJECTS" ;;
    *) return 1 ;;
  esac
}
record="$(jq -cn --arg resources "$TEST_EXPECTED" '{
  metadata:{labels:{"app.kubernetes.io/managed-by":"kagent-byo-addon"}},
  data:{context:"rancher-desktop",phase:"cleanup-failed",resources:$resources,sessions:"[]"}}')"
kagent_byo_verify_record custom "$record"
""", {
            "TEST_EXPECTED": json.dumps(expected),
            "TEST_OBJECTS": json.dumps({
                f'{resource["kind"]}/{resource["name"]}': {
                    "metadata": {
                        "name": resource["name"],
                        "uid": resource["uid"],
                        "labels": {"app.kubernetes.io/managed-by": "kagent-byo-addon"},
                    },
                }
                for resource in actual
            }),
        })
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_substrate_snapshot_assertion_requires_same_suspended_actor_and_new_volume_snapshot(self):
        complete = {
            "actors": [{
                "metadata": {"uid": "actor-uid"},
                "status": {
                    "state": "ACTOR_STATE_SUSPENDED",
                    "snapshots": [{
                        "generation": 4,
                        "fidelity": "SNAPSHOT_FIDELITY_VOLUMES",
                        "durableSnapshot": {"state": "SNAPSHOT_STORAGE_STATE_COMPLETED"},
                    }],
                },
            }],
        }
        result = self.run_shell("""
kagent_byo_actor_has_completed_snapshot "$TEST_ACTORS" actor-uid 3
kagent_byo_actor_snapshot_generation "$TEST_ACTORS" actor-uid
""", {"TEST_ACTORS": json.dumps(complete)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "4")

        for mutation in (
            lambda value: value["actors"][0]["status"].update(state="ACTOR_STATE_RUNNING"),
            lambda value: value["actors"][0]["status"]["snapshots"][0].update(generation=3),
            lambda value: value["actors"][0]["status"]["snapshots"][0].update(
                durableSnapshot={"state": "SNAPSHOT_STORAGE_STATE_PENDING"},
            ),
        ):
            altered = json.loads(json.dumps(complete))
            mutation(altered)
            with self.subTest(actor=altered):
                result = self.run_shell(
                    'kagent_byo_actor_has_completed_snapshot "$TEST_ACTORS" actor-uid 3',
                    {"TEST_ACTORS": json.dumps(altered)},
                )
                self.assertNotEqual(result.returncode, 0)

    def test_new_actor_detection_excludes_the_preexisting_actor_set(self):
        actors = {
            "actors": [
                {"metadata": {"uid": "old-actor", "name": "old"}},
                {"metadata": {"uid": "new-actor", "name": "current"}},
            ],
        }
        result = self.run_shell(
            'kagent_byo_find_new_actor "$TEST_ACTORS" \'["old-actor"]\' | jq -r \'.metadata.uid\'',
            {"TEST_ACTORS": json.dumps(actors)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "new-actor")

    def test_unknown_byo_response_rejects_prices_and_successful_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            response_file = Path(directory) / "unknown.txt"
            for response, accepted in (
                ("I could not find that product in the catalog.", True),
                ("The product is unknown.", True),
                ("The unknown product costs $99.00.", False),
                ("Total: $85.50. Over budget by $5.50.", False),
                ("It is unavailable.", True),
            ):
                with self.subTest(response=response):
                    response_file.write_text(response)
                    result = self.run_shell(
                        'kagent_byo_validate_unknown_response "$TEST_RESPONSE"',
                        {"TEST_RESPONSE": str(response_file)},
                    )
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_byo_demo_has_expected_quote_turns_and_fresh_session_assertion(self):
        script = (ROOT / "scripts/demo-kagent.sh").read_text()
        self.assertIn("Create an offer for three Star Widgets and two Moon Gadgets.", script)
        self.assertIn("Then just one Moon Gadget; everything else stays the same.", script)
        self.assertIn("Total: $85.50", script)
        self.assertIn("Over budget by $5.50", script)
        self.assertIn("Total: $61.50", script)
        self.assertIn("Within budget; $18.50 remains", script)
        self.assertIn("wait_for_byo_actor_snapshot", script)
        self.assertIn("A fresh BYO Session disclosed quote state", script)
        self.assertIn("unexpectedly delegated deterministic arithmetic to MCP", script)

    def test_session_tracking_deduplicates_and_removes_only_the_target(self):
        with tempfile.TemporaryDirectory() as directory:
            record_path = Path(directory) / "record.json"
            record_path.write_text(json.dumps({
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "kagent-byo-ownership",
                    "namespace": "custom",
                    "labels": {"app.kubernetes.io/managed-by": "kagent-byo-addon"},
                },
                "data": {"phase": "ready", "sessions": "[]"},
            }))
            result = subprocess.run(
                ["bash", "-c", """
set -euo pipefail
source scripts/kagent-byo-common.sh
kubectl() {
  case "$1 $2" in
    "get configmap") cat "$TEST_RECORD" ;;
    "apply -f") cat > "$TEST_RECORD" ;;
    *) return 1 ;;
  esac
}
kagent_byo_track_session custom first-session add
kagent_byo_track_session custom second-session add
kagent_byo_track_session custom first-session add
kagent_byo_track_session custom first-session remove
jq -r '.data.sessions' "$TEST_RECORD"
"""],
                cwd=ROOT,
                env={**os.environ, "TEST_RECORD": str(record_path)},
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), ["second-session"])
