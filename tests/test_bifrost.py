import errno
import json
import os
import pty
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BifrostDemoTests(unittest.TestCase):
    def run_demo(self, *, terminal=False, status=0, no_color=False, calls_path=""):
        env = {
            **os.environ,
            "BIFROST_VIRTUAL_KEY": "test-key",
            "TEST_CURL_STATUS": str(status),
            "TEST_REQUESTS": str(calls_path),
            "TERM": "xterm",
        }
        env.pop("NO_COLOR", None)
        if no_color:
            env["NO_COLOR"] = "1"
        script = """
curl() {
  if [[ "$*" == *"/health"* ]]; then return 0; fi
  if [[ -n "$TEST_REQUESTS" ]]; then
    while (( $# )); do
      if [[ "$1" == --data ]]; then printf '%s\\n' "$2" >> "$TEST_REQUESTS"; fi
      if [[ "$1" == --header ]]; then printf '%s\\n' "$2" >> "$TEST_REQUESTS.headers"; fi
      shift
    done
  fi
  printf '%s' '{"message":"demo response","usage":{"total_tokens":42}}'
  return "$TEST_CURL_STATUS"
}
source scripts/demo-bifrost.sh
"""
        if not terminal:
            result = subprocess.run(
                ["bash", "-c", script], cwd=ROOT, env=env,
                text=True, capture_output=True,
            )
            return result.returncode, result.stdout
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(
                ["bash", "-c", script], cwd=ROOT, env=env,
                stdout=slave, stderr=subprocess.STDOUT,
            )
            os.close(slave)
            slave = None
            chunks = []
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                chunks.append(chunk)
            return process.wait(), b"".join(chunks).decode()
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_redirected_response_is_pretty_json_without_colours(self):
        status, output = self.run_demo()
        self.assertEqual(status, 0)
        self.assertNotIn("\x1b[", output)
        payload = output[output.index("{"):]
        self.assertIn('\n  "message":', payload)
        response, _ = json.JSONDecoder().raw_decode(payload)
        self.assertEqual(response["usage"]["total_tokens"], 42)
        self.assertEqual(output.count('"message":'), 2)

    def test_sends_two_similar_prompts_with_the_same_model_and_cache_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = Path(directory) / "requests"
            status, output = self.run_demo(calls_path=calls)
            self.assertEqual(status, 0)
            requests = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(len(requests), 2)
            self.assertEqual(requests[0]["model"], requests[1]["model"])
            self.assertTrue(requests[0]["model"].startswith("openai/"))
            headers = Path(str(calls) + ".headers").read_text().splitlines()
            self.assertEqual(headers.count("x-bf-cache-key: bifrost-demo"), 2)
            prompts = [request["messages"][0]["content"] for request in requests]
            self.assertEqual(prompts, [
                "What is an AI gateway?",
                "What is an AI gateway, exactly?",
            ])
            for prompt in prompts:
                self.assertIn(f"Prompt: {prompt}", output)

    def test_terminal_response_is_coloured(self):
        status, output = self.run_demo(terminal=True)
        self.assertEqual(status, 0)
        self.assertIn("\x1b[", output)

    def test_no_color_disables_terminal_colours(self):
        status, output = self.run_demo(terminal=True, no_color=True)
        self.assertEqual(status, 0)
        self.assertNotIn("\x1b[", output)

    def test_http_failure_preserves_curl_status_and_formats_body(self):
        status, output = self.run_demo(status=22)
        self.assertEqual(status, 22)
        self.assertIn('\n  "message":', output)
        self.assertNotIn("What is an AI gateway, exactly?", output)


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
