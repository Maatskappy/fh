import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("feedback_driver", ROOT / "scripts/try-pr-feedback-triage.py")
DRIVER = importlib.util.module_from_spec(spec)
spec.loader.exec_module(DRIVER)
EXAMPLES = ROOT / "examples/pr-feedback-triage"


class FeedbackTriage(unittest.TestCase):
    def fixture(self, name):
        return json.loads((EXAMPLES / (name + ".json")).read_text())

    def forbidden(self, _):
        self.fail("Deterministic or malformed input invoked fh/preflight/model")

    def test_exact_facts_never_invoke_fh(self):
        expected = {"stale": "ignore_stale", "unbound": "gather_context", "pending": "wait_for_ci",
                    "passed": "no_action", "quota": "restore_review"}
        for name, action in expected.items():
            with self.subTest(name=name):
                result = DRIVER.triage(self.fixture(name), Path("unused"), invoke=self.forbidden)
                self.assertFalse(result["model_called"])
                self.assertIsNone(result["run_id"])
                self.assertEqual(result["output"]["action"], action)

    def test_malformed_input_never_invokes_fh(self):
        for mutate in [lambda v: v.update(head_sha="abc"), lambda v: v.update(unexpected=True),
                       lambda v: v["feedback"].update(line=True), lambda v: v["feedback"].update(text="x" * 6001),
                       lambda v: v["feedback"].update(text="\ud800")]:
            value = self.fixture("code-repair")
            mutate(value)
            with self.assertRaises(ValueError):
                DRIVER.triage(value, Path("unused"), invoke=self.forbidden)

    def test_saved_code_cannot_route_stale_input_as_repair(self):
        value = self.fixture("stale")
        decision = {"model": "fixture", "answers": {"feedback": {"choice": "code_issue"}}}
        result = DRIVER.ROUTE.route(value, decision)
        self.assertEqual(result["action"], "ignore_stale")
        self.assertEqual(result["gated_by"], "code")
        self.assertIsNone(result["decision"])

    def test_proposal_keeps_evidence_and_raw_distribution(self):
        value = self.fixture("code-repair")
        answer = {"type": "choice", "choice": "code_issue", "confidence": .55,
                  "probabilities": {"code_issue": .55, "clarification": .2, "infrastructure": .1,
                                    "informational": .05, "insufficient": .1}}
        decision = {"model": "fixture", "answers": {"feedback": answer}}
        result = DRIVER.ROUTE.route(value, decision)
        self.assertEqual(result["action"], "repair_code")
        self.assertTrue(result["proposal_only"])
        self.assertEqual(result["evidence"]["location"], "src/users.py:42")
        self.assertEqual(result["decision"], decision)
        self.assertIn("if confirmed", result["next_step"])

    def test_eligible_input_is_frozen_and_persisted_result_verified(self):
        value = self.fixture("code-repair")
        calls = []
        final = {"status": "completed", "run_id": "run_fixture", "package_digest": "digest",
                 "used_tokens": 123, "usage_unknown": False, "output": {"action": "repair_code"}}
        def invoke(argv):
            calls.append(argv)
            if "run" in argv:
                supplied = Path(argv[argv.index("--input") + 1])
                self.assertEqual(json.loads(supplied.read_text()), value)
                self.assertEqual(supplied.stat().st_mode & 0o777, 0o600)
            return 10.0, copy.deepcopy(final)
        result = DRIVER.triage(value, Path("caller-file-is-not-used"), invoke=invoke)
        self.assertEqual(len(calls), 2)
        self.assertTrue(result["model_called"])
        self.assertFalse(Path(calls[0][calls[0].index("--input") + 1]).exists())

    def test_failed_or_uncertain_run_never_replays_or_routes(self):
        calls = []
        def invoke(argv):
            calls.append(argv)
            return 10.0, {"status": "stopped", "run_id": "run_fixture", "stop": {"reason": "usage_unavailable"}}
        with self.assertRaises(RuntimeError):
            DRIVER.triage(self.fixture("ambiguous"), Path("unused"), invoke=invoke)
        self.assertEqual(len(calls), 2)
        self.assertEqual(sum("run" in call for call in calls), 1)


if __name__ == "__main__":
    unittest.main()
