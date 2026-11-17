import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]


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
