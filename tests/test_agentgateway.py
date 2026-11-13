import json
import shutil
import subprocess
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'source scripts/agentgateway-common.sh\nsleep() { :; }\n'


class AgentgatewayReadinessTests(unittest.TestCase):
    def run_shell(self, script):
        return subprocess.run(
            ["bash", "-c", SOURCE + script],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

    def test_rate_limit_header_accepts_lf_and_crlf_but_not_nonzero(self):
        script = (ROOT / "scripts/demo-agentgateway.sh").read_text()
        expression = next(
            line.split("'")[1]
            for line in script.splitlines()
            if "grep -Eiq '^x-ratelimit-remaining:" in line
        )
        for header, expected in [
            ("x-ratelimit-remaining: 0\n", 0),
            ("X-RateLimit-Remaining: 0\r\n", 0),
            ("x-ratelimit-remaining: 0 \t\r\n", 0),
            ("x-ratelimit-remaining: 10\r\n", 1),
            ("x-ratelimit-remaining: 0r\n", 1),
        ]:
            with self.subTest(header=header):
                result = subprocess.run(
                    ["grep", "-Eiq", expression], input=header, text=True
                )
                self.assertEqual(result.returncode, expected)

    def test_validate_rejects_syntax_error_in_later_script(self):
        broken = ROOT / "scripts" / f"zz-regression-{uuid.uuid4().hex}.sh"
        try:
            broken.write_text("if then\n")
            result = subprocess.run(
                ["make", "validate"], cwd=ROOT, text=True, capture_output=True
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(broken.name, result.stderr)
        finally:
            broken.unlink()

    def test_policy_ignores_stale_conditions_until_current_generation(self):
        result = self.run_shell("""
set -o pipefail
kubectl() {
  count_file="$directory/count"
  count=0
  if [[ -f "$count_file" ]]; then read -r count < "$count_file"; fi
  count=$((count + 1))
  printf '%s\\n' "$count" > "$count_file"
  generation=6
  if (( count > 1 )); then generation=7; fi
  printf '{"metadata":{"generation":7},"status":{"ancestors":[{"conditions":[{"type":"Accepted","status":"True","observedGeneration":%s},{"type":"Attached","status":"True","observedGeneration":%s}]}]}}' "$generation" "$generation"
}
agentgateway_wait_policy test 7 && [[ "$(cat "$directory/count")" == 2 ]]
""".replace(
            "set -o pipefail",
            'directory=".agentgateway-test-' + uuid.uuid4().hex
            + '"; mkdir "$directory"; trap \'rm -rf "$directory"\' EXIT\nset -o pipefail',
            1,
        ))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_policy_rejects_wrong_generation_and_split_ancestors(self):
        for status in [
            {"metadata": {"generation": 6}, "status": {"ancestors": [
                {"conditions": [
                    {"type": "Accepted", "status": "True", "observedGeneration": 7},
                    {"type": "Attached", "status": "True", "observedGeneration": 7},
                ]}
            ]}},
            {"metadata": {"generation": 7}, "status": {"ancestors": [
                {"conditions": [{"type": "Accepted", "status": "True", "observedGeneration": 7}]},
                {"conditions": [{"type": "Attached", "status": "True", "observedGeneration": 7}]},
            ]}},
        ]:
            result = self.run_shell(
                "kubectl() { printf '%s' '" + json.dumps(status) + "'; }\n"
                "agentgateway_wait_policy test 7"
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Timed out", result.stderr)

    def run_probe(self, authenticated_status, marker_arrives=True):
        directory = ROOT / f".agentgateway-test-{uuid.uuid4().hex}"
        directory.mkdir(mode=0o700)
        try:
            result = self.run_shell("""
curl() {
  local output="" header="" previous="" argument
  for argument in "$@"; do
    if [[ "$previous" == --output ]]; then output="$argument"; fi
    if [[ "$previous" == --header && "$argument" == @* ]]; then header="${argument#@}"; fi
    previous="$argument"
  done
  if grep -q 'Bearer valid-key' "$header"; then
    count=0
    if [[ -f "$directory/count" ]]; then read -r count < "$directory/count"; fi
    count=$((count + 1))
    printf '%s\\n' "$count" > "$directory/count"
    # Even HTTP 200 with an old echo marker must not synchronize the phase.
    phase=old
    if (( count > 1 && marker_arrives )); then phase=new; fi
    printf '{"json":{"model":"%s"}}' "$phase" > "$output"
    printf 200
  else
    printf '%s' "$authenticated_status"
  fi
}
agentgateway_wait_dataplane http://example.invalid valid-key new "$directory"
""".replace(
                "curl() {",
                f"directory='{directory}'\nauthenticated_status={authenticated_status}\nmarker_arrives={int(marker_arrives)}\ncurl() {{",
                1,
            ))
            attempts = int((directory / "count").read_text())
            return result, attempts
        finally:
            shutil.rmtree(directory)

    def test_dataplane_waits_for_phase_and_verifies_strict_auth(self):
        result, attempts = self.run_probe(401)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(attempts, 2)

    def test_dataplane_fails_if_authentication_is_disabled(self):
        result, attempts = self.run_probe(200)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(attempts, 2)
        self.assertIn("authentication check expected 401", result.stderr)

    def test_dataplane_fails_boundedly_when_the_phase_never_arrives(self):
        result, attempts = self.run_probe(401, marker_arrives=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(attempts, 60)
        self.assertIn("Timed out waiting for data-plane policy phase new", result.stderr)

    def test_scenario_patch_preserves_inference_and_additional_authorization(self):
        directory = ROOT / f".agentgateway-test-{uuid.uuid4().hex}"
        directory.mkdir(mode=0o700)
        script = (ROOT / "scripts/demo-agentgateway.sh").read_text()
        function = script[
            script.index("set_rate_limit() {"):
            script.index('\nif [[ "$mode" != "mock"')
        ]
        inference = 'request.path == "/v1/chat/completions" && json(request.body).model == "install-abcd"'
        readiness = 'request.path == "/anything" && json(request.body).model == "install-bbbb"'
        additional = 'apiKey.user_id in ["alice", "bob"]'
        authorization = {
            "action": "Require",
            "policy": {"matchExpressions": [f"({inference}) || ({readiness})", additional]},
        }
        try:
            result = self.run_shell(
                f"directory='{directory}'\n"
                f"original_traffic='{json.dumps({'authorization': authorization})}'\n"
                'policy_patch="$directory/patch.json"\nnamespace=test\nurl=http://unused\nalice_key=unused\n'
                'agentgateway_wait_policy() { :; }\nagentgateway_wait_dataplane() { :; }\n'
                'kubectl() { if [[ "$1" == get ]]; then printf \'{"metadata":{"generation":7}}\'; fi; }\n'
                + function
                + '\nset_rate_limit \'{"spec":{"traffic":{"rateLimit":{"local":[{"requests":1,"unit":"Minutes","burst":1}]}}}}\''
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            traffic = json.loads((directory / "patch.json").read_text())["spec"]["traffic"]
            expressions = traffic["authorization"]["policy"]["matchExpressions"]
            self.assertEqual(traffic["authorization"]["action"], "Require")
            self.assertIn(inference, expressions[0])
            self.assertIn('model == "scenario-', expressions[0])
            self.assertNotIn('model == "install-bbbb"', expressions[0])
            self.assertEqual(expressions[1], additional)
            self.assertIn('apiKey.user_id + "-scenario-', traffic["rateLimit"]["local"][0]["key"])
        finally:
            shutil.rmtree(directory)

    def test_uninstall_retains_controller_for_remaining_owned_model(self):
        result = self.run_shell("""
kubectl() {
  if [[ "$1" == delete ]]; then return 0; fi
  if [[ "$2" == gateways.gateway.networking.k8s.io ]]; then
    printf '{"items":[]}'
  elif [[ "$2" == agentgatewaypolicies.agentgateway.dev,* ]]; then
    printf '{"items":[{"metadata":{"name":"extra-model","namespace":"agentgateway-demo","labels":{"app.kubernetes.io/managed-by":"agentgateway-demo"}}}]}'
  elif [[ "$2" == configmaps ]]; then
    printf '{"items":[]}'
  else
    printf '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"agentgateway-demo"}},"data":{"chart":"agentgateway-v1.7.0","release-uid":"owned-uid"}}'
  fi
}
helm() { printf 'UNEXPECTED_HELM_CALL\\n'; return 1; }
export -f kubectl helm
AGENTGATEWAY_NAMESPACE=agentgateway-demo bash scripts/uninstall-agentgateway.sh
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Retained the demo-installed agentgateway controller", result.stdout)
        self.assertNotIn("UNEXPECTED_HELM_CALL", result.stdout)


if __name__ == "__main__":
    unittest.main()
