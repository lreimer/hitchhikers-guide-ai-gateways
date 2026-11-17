import json
import os
from pathlib import Path
import subprocess
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
                    "kagent_demo_write_owner_record kagent agentgateway-demo '[]' '[]' inventory.json custom-resources.json",
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
