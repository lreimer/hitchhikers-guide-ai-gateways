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
