import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BifrostInstallerTests(unittest.TestCase):
    def test_install_creates_setup_secret_and_preserves_credentials_on_upgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            kubectl = path / "kubectl"
            kubectl.write_text("""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$TEST_STATE/calls"
if [[ "$1 $2" == "get secret" ]]; then
  if [[ -f "$TEST_STATE/$3" ]]; then
    printf 'secret/%s\\n' "$3"
  fi
elif [[ "$1 $2 $3" == "create secret generic" ]]; then
  cat > "$TEST_STATE/$4"
  printf 'mock-secret\\n'
elif [[ "$1" == apply ]]; then
  cat >/dev/null
fi
""")
            kubectl.chmod(0o755)
            helm = path / "helm"
            helm.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$TEST_STATE/calls"\n')
            helm.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{path}{os.pathsep}{os.environ['PATH']}",
                "TEST_STATE": directory,
                "OPENAI_API_KEY": "test-provider-key",
                "BIFROST_NAMESPACE": "test-bifrost",
            }

            def install():
                return subprocess.run(
                    ["bash", "scripts/install-bifrost.sh"],
                    cwd=ROOT, env=env, text=True, capture_output=True,
                )

            result = install()
            self.assertEqual(result.returncode, 0, result.stderr)
            credentials = {}
            for name in ("bifrost-setup-token", "bifrost-encryption-key"):
                credentials[name] = (path / name).read_text()
                self.assertRegex(credentials[name], r"\A[0-9a-f]{64}\Z")
                self.assertNotIn(credentials[name], result.stdout + result.stderr)
            self.assertNotEqual(*credentials.values())
            calls = (path / "calls").read_text()
            self.assertIn(
                "create secret generic bifrost-setup-token --namespace test-bifrost "
                "--from-file=setup-token=/dev/stdin", calls,
            )
            self.assertIn("--values " + str(ROOT / "gateways/bifrost/values.yaml"), calls)
            (path / "calls").write_text("")

            result = install()
            self.assertEqual(result.returncode, 0, result.stderr)
            for name, value in credentials.items():
                self.assertEqual((path / name).read_text(), value)
                self.assertNotIn(
                    f"create secret generic {name}", (path / "calls").read_text()
                )

            (path / "bifrost-setup-token").unlink()
            result = install()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex((path / "bifrost-setup-token").read_text(), r"\A[0-9a-f]{64}\Z")
            self.assertEqual(
                (path / "bifrost-encryption-key").read_text(),
                credentials["bifrost-encryption-key"],
            )


if __name__ == "__main__":
    unittest.main()
