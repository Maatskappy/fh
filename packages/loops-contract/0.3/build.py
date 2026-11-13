"""Writes the loops/0.3 fixtures and their hand-derived expected traces.

Expected traces are written out literally below from the contract text, never
computed by a runner. Run from the repository root:
    python3 packages/loops-contract/0.3/build.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).parent
ECHO = "import json, sys\nprint(json.dumps(json.load(sys.stdin), ensure_ascii=False))\n"
OBJ = {"type": "object"}


def manifest(steps, output, repeat=None, inputs=True):
    m = {"format": "loops/0.3", "name": "conformance-0-3", "version": "1.0.0",
         "inputs": {"schema": inputs}, "steps": steps, "output": output}
    if repeat:
        m["repeat"] = repeat
    return m


def infer(id, input, schema=OBJ, instructions="Return JSON."):
    return {"id": id, "kind": "infer", "requires": [], "instructions": instructions,
            "input": input, "output": {"schema": schema}}


def code(id, input, file="echo.py", runtime="python3", schema=True):
    return {"id": id, "kind": "code", "runtime": runtime, "file": file, "requires": [],
            "input": input, "output": {"schema": schema}}


def frm(pointer):
    return {"from": pointer}


def ok(output):
    return {"status": "completed", "output": output}


def failed(reason):
    return {"status": "failed", "error": {"reason": reason}}


def resp(path, output=None, pass_=0, error=None, instructions=None):
    r = {"path": path, "pass": pass_, "usage": {"input_tokens": 2, "output_tokens": 3}}
    if error:
        r["error"] = {"reason": error}
    else:
        r["output"] = output
    if instructions is not None:
        r["instructions"] = instructions
    return r


def step(path, input=None, output=None, pass_=0, error=None):
    s = {"path": path, "pass": pass_}
    if input is not None:
        s["input"] = input
    if not error:  # A step that ran and failed records its input only, as in the 0.1 suite.
        s["output"] = output
    return s


FIXTURES = {}

# 1. Every branch completes; a branch's result is its last step's output.
pair = {"id": "pair", "kind": "parallel", "branches": {
    "a": [infer("a1", frm("/input"))],
    "b": [infer("b1", frm("/input")), code("b2", frm("/steps/b1/output"))]}}
FIXTURES["parallel-all-complete"] = (
    {"loop.json": manifest([pair, code("join", {"pair": frm("/steps/pair/output")})], frm("/steps/join/output")), "echo.py": ECHO},
    {"x": 1},
    {"responses": [resp("pair/a/a1", {"a": 1}), resp("pair/b/b1", {"b": 2})]},
    {"steps": [
        step("pair/a/a1", {"x": 1}, {"a": 1}),
        step("pair/b/b1", {"x": 1}, {"b": 2}),
        step("pair/b/b2", {"b": 2}, {"b": 2}),
        step("pair", output={"a": ok({"a": 1}), "b": ok({"b": 2})}),
        step("join", {"pair": {"a": ok({"a": 1}), "b": ok({"b": 2})}}, {"pair": {"a": ok({"a": 1}), "b": ok({"b": 2})}}),
    ], "carry": [], "terminal": {"status": "completed", "output": {"pair": {"a": ok({"a": 1}), "b": ok({"b": 2})}}}},
)

# 2. A failed branch stops at its first failed step; siblings finish; the run completes.
FIXTURES["parallel-branch-fails"] = (
    FIXTURES["parallel-all-complete"][0],
    {"x": 1},
    {"responses": [resp("pair/a/a1", {"a": 1}), resp("pair/b/b1", error="execution_failed")]},
    {"steps": [
        step("pair/a/a1", {"x": 1}, {"a": 1}),
        step("pair/b/b1", {"x": 1}, error="execution_failed"),
        step("pair", output={"a": ok({"a": 1}), "b": failed("execution_failed")}),
        step("join", {"pair": {"a": ok({"a": 1}), "b": failed("execution_failed")}}, {"pair": {"a": ok({"a": 1}), "b": failed("execution_failed")}}),
    ], "carry": [], "terminal": {"status": "completed", "output": {"pair": {"a": ok({"a": 1}), "b": failed("execution_failed")}}}},
)

# 3. Map output keeps element order; an invalid element output fails only that element.
judged = {"type": "object", "required": ["verdict"], "properties": {"verdict": {"type": "string"}}, "additionalProperties": False}
roster = [{"n": "p"}, {"n": "q"}, {"n": "r"}]
each = {"id": "each", "kind": "map", "over": frm("/steps/roster/output/items"),
        "steps": [infer("judge", {"item": frm("/item"), "index": frm("/index")}, judged)]}
FIXTURES["map-mixed"] = (
    {"loop.json": manifest([code("roster", frm("/input")), each], frm("/steps/each/output")), "echo.py": ECHO},
    {"items": roster},
    {"responses": [
        resp("each[2]/judge", {"verdict": "fine"}),
        resp("each[0]/judge", {"verdict": "good"}),
        resp("each[1]/judge", {"verdict": 7}),
    ]},
    {"steps": [
        step("roster", {"items": roster}, {"items": roster}),
        step("each[0]/judge", {"item": {"n": "p"}, "index": 0}, {"verdict": "good"}),
        step("each[1]/judge", {"item": {"n": "q"}, "index": 1}, error="invalid_output"),
        step("each[2]/judge", {"item": {"n": "r"}, "index": 2}, {"verdict": "fine"}),
        step("each", roster, [ok({"verdict": "good"}), failed("invalid_output"), ok({"verdict": "fine"})]),
    ], "carry": [], "terminal": {"status": "completed", "output": [ok({"verdict": "good"}), failed("invalid_output"), ok({"verdict": "fine"})]}},
)

# 4. Mapping an empty array completes with [] and dispatches nothing.
FIXTURES["map-empty"] = (
    FIXTURES["map-mixed"][0],
    {"items": []},
    {"responses": []},
    {"steps": [
        step("roster", {"items": []}, {"items": []}),
        step("each", [], []),
    ], "carry": [], "terminal": {"status": "completed", "output": []}},
)

# 5. A map over something that is not an array fails the run.
FIXTURES["map-invalid-over"] = (
    FIXTURES["map-mixed"][0],
    {"items": {"n": "p"}},
    {"responses": []},
    {"steps": [step("roster", {"items": {"n": "p"}}, {"items": {"n": "p"}})],
     "carry": [], "terminal": {"status": "failed", "reason": "invalid_map_input"}},
)

# 6. A branch cannot see a sibling branch, even one that finished first (a1 settles before b0, so b1 starts after it).
isolated = {"id": "pair", "kind": "parallel", "branches": {
    "a": [infer("a1", frm("/input"))],
    "b": [infer("b0", frm("/input")), code("b1", frm("/steps/a1/output"))]}}
FIXTURES["branch-isolation"] = (
    {"loop.json": manifest([isolated], frm("/steps/pair/output")), "echo.py": ECHO},
    {"x": 1},
    {"responses": [resp("pair/a/a1", {"a": 1}), resp("pair/b/b0", {"b": 0})]},
    {"steps": [
        step("pair/a/a1", {"x": 1}, {"a": 1}),
        step("pair/b/b0", {"x": 1}, {"b": 0}),
        step("pair", output={"a": ok({"a": 1}), "b": failed("missing_binding")}),
    ], "carry": [], "terminal": {"status": "completed", "output": {"a": ok({"a": 1}), "b": failed("missing_binding")}}},
)

# 7. A parallel step inside the repeat region runs fresh on every pass.
CHECK = ("import json, sys\nx = json.load(sys.stdin)\n"
         "l = x['fan']['left']['output']['v']\nr = x['fan']['right']['output']['v']\n"
         "print(json.dumps({'ready': l == r, 'seen': [l, r]}))\n")
fan = {"id": "fan", "kind": "parallel", "branches": {
    "left": [infer("l", frm("/carry"))],
    "right": [infer("r", frm("/carry"))]}}
FIXTURES["parallel-in-repeat"] = (
    {"loop.json": manifest(
        [fan, code("check", {"fan": frm("/steps/fan/output")}, file="check.py")],
        frm("/steps/check/output"),
        repeat={"from": "fan", "through": "check", "max_iterations": 3,
                "until": frm("/steps/check/output/ready"),
                "carry": {"initial": {"value": {"seen": None}}, "next": {"seen": frm("/steps/check/output/seen")}}}),
     "echo.py": ECHO, "check.py": CHECK},
    {},
    {"responses": [
        resp("fan/left/l", {"v": 1}, 1), resp("fan/right/r", {"v": 2}, 1),
        resp("fan/left/l", {"v": 2}, 2), resp("fan/right/r", {"v": 2}, 2),
    ]},
    {"steps": [
        step("fan/left/l", {"seen": None}, {"v": 1}, 1),
        step("fan/right/r", {"seen": None}, {"v": 2}, 1),
        step("fan", output={"left": ok({"v": 1}), "right": ok({"v": 2})}, pass_=1),
        step("check", {"fan": {"left": ok({"v": 1}), "right": ok({"v": 2})}}, {"ready": False, "seen": [1, 2]}, 1),
        step("fan/left/l", {"seen": [1, 2]}, {"v": 2}, 2),
        step("fan/right/r", {"seen": [1, 2]}, {"v": 2}, 2),
        step("fan", output={"left": ok({"v": 2}), "right": ok({"v": 2})}, pass_=2),
        step("check", {"fan": {"left": ok({"v": 2}), "right": ok({"v": 2})}}, {"ready": True, "seen": [2, 2]}, 2),
    ], "carry": [{"forPass": 1, "value": {"seen": None}}, {"forPass": 2, "value": {"seen": [1, 2]}}],
     "terminal": {"status": "completed", "output": {"ready": True, "seen": [2, 2]}}},
)

# 8. runtime "node": a default-exported function, in process or through a shim.
FIXTURES["node-runtime"] = (
    {"loop.json": manifest([code("shout", frm("/input"), file="shout.mjs", runtime="node")], frm("/steps/shout/output")),
     "shout.mjs": "export default function (input) {\n  return { said: input.word.toUpperCase() }\n}\n"},
    {"word": "hi"},
    {"responses": []},
    {"steps": [step("shout", {"word": "hi"}, {"said": "HI"})], "carry": [],
     "terminal": {"status": "completed", "output": {"said": "HI"}}},
)

# 9. Instructions from a package file are used verbatim.
PROMPT = "Say hello to the bound name.\nReturn {\"greeting\": string}.\n"
FIXTURES["instructions-file"] = (
    {"loop.json": manifest([infer("greet", frm("/input"), instructions={"file": "prompts/greet.md"})], frm("/steps/greet/output")),
     "prompts/greet.md": PROMPT},
    {"name": "Ada"},
    {"responses": [resp("greet", {"greeting": "Hello Ada"}, instructions=PROMPT)]},
    {"steps": [step("greet", {"name": "Ada"}, {"greeting": "Hello Ada"})], "carry": [],
     "terminal": {"status": "completed", "output": {"greeting": "Hello Ada"}}},
)

# 10. Agent driver: rejected, accepted, idempotent resubmit, conflict; code runs in the runner.
drafted = {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}, "additionalProperties": False}
VERIFY = "import json, sys\nx = json.load(sys.stdin)\nprint(json.dumps({'ready': x['text'] == 'ok'}))\n"
agent_pkg = {"loop.json": manifest([infer("draft", frm("/input"), drafted), code("verify", frm("/steps/draft/output"), file="verify.py")], frm("/steps/verify/output")),
             "verify.py": VERIFY}
FIXTURES["agent-driver"] = (
    agent_pkg,
    {"topic": "t"},
    {"driver": "agent", "ops": [
        {"op": "next", "expect": ["draft"]},
        {"op": "submit", "path": "draft", "pass": 0, "output": {"text": 5}, "expect": "rejected"},
        {"op": "next", "expect": ["draft"]},
        {"op": "submit", "path": "verify", "pass": 0, "output": {"ready": True}, "expect": "not_ready"},
        {"op": "submit", "path": "draft", "pass": 0, "output": {"text": "ok"}, "expect": "accepted"},
        {"op": "submit", "path": "draft", "pass": 0, "output": {"text": "ok"}, "expect": "accepted"},
        {"op": "submit", "path": "draft", "pass": 0, "output": {"text": "no"}, "expect": "conflict"},
        {"op": "next", "expect": []},
    ]},
    {"steps": [
        step("draft", {"topic": "t"}, {"text": "ok"}),
        step("verify", {"text": "ok"}, {"ready": True}),
    ], "carry": [], "terminal": {"status": "completed", "output": {"ready": True}}},
)

# 11. Agent driver: a parallel step's ready branches appear together.
FIXTURES["agent-driver-parallel"] = (
    FIXTURES["parallel-all-complete"][0],
    {"x": 1},
    {"driver": "agent", "ops": [
        {"op": "next", "expect": ["pair/a/a1", "pair/b/b1"]},
        {"op": "submit", "path": "pair/b/b1", "pass": 0, "output": {"b": 2}, "expect": "accepted"},
        {"op": "next", "expect": ["pair/a/a1"]},
        {"op": "submit", "path": "pair/a/a1", "pass": 0, "output": {"a": 1}, "expect": "accepted"},
        {"op": "next", "expect": []},
    ]},
    FIXTURES["parallel-all-complete"][3],
)

# 12. Agent driver: cancel stops the run, never completes it.
FIXTURES["agent-driver-cancel"] = (
    agent_pkg,
    {"topic": "t"},
    {"driver": "agent", "ops": [
        {"op": "next", "expect": ["draft"]},
        {"op": "cancel"},
        {"op": "next", "expect": []},
    ]},
    {"steps": [], "carry": [], "terminal": {"status": "stopped", "reason": "cancelled"}},
)


# 13. Agent driver in a repeat region: a retried pass-1 submission never settles pass 2.
JUDGE = "import json, sys\nx = json.load(sys.stdin)\nprint(json.dumps({'ready': x['text'] == 'good'}))\n"
FIXTURES["agent-driver-repeat"] = (
    {"loop.json": manifest(
        [infer("draft", {"topic": frm("/input/topic"), "previous": frm("/carry")}, drafted), code("judge", frm("/steps/draft/output"), file="judge.py")],
        frm("/steps/judge/output"),
        repeat={"from": "draft", "through": "judge", "max_iterations": 3, "until": frm("/steps/judge/output/ready"),
                "carry": {"initial": {"value": None}, "next": frm("/steps/draft/output/text")}}),
     "judge.py": JUDGE},
    {"topic": "t"},
    {"driver": "agent", "ops": [
        {"op": "next", "expect": ["draft"]},
        {"op": "submit", "path": "draft", "pass": 1, "output": {"text": "rough"}, "expect": "accepted"},
        {"op": "next", "expect": ["draft"]},
        {"op": "submit", "path": "draft", "pass": 1, "output": {"text": "rough"}, "expect": "accepted"},
        {"op": "next", "expect": ["draft"]},
        {"op": "submit", "path": "draft", "pass": 1, "output": {"text": "good"}, "expect": "conflict"},
        {"op": "submit", "path": "draft", "pass": 2, "output": {"text": "good"}, "expect": "accepted"},
        {"op": "next", "expect": []},
    ]},
    {"steps": [
        step("draft", {"topic": "t", "previous": None}, {"text": "rough"}, 1),
        step("judge", {"text": "rough"}, {"ready": False}, 1),
        step("draft", {"topic": "t", "previous": "rough"}, {"text": "good"}, 2),
        step("judge", {"text": "good"}, {"ready": True}, 2),
    ], "carry": [{"forPass": 1, "value": None}, {"forPass": 2, "value": "rough"}],
     "terminal": {"status": "completed", "output": {"ready": True}}},
)

# 14. Step ids are data keys: "__proto__" is an ordinary id.
FIXTURES["proto-step-id"] = (
    {"loop.json": manifest([code("__proto__", frm("/input")), code("after", frm("/steps/__proto__/output"))], frm("/steps/after/output")), "echo.py": ECHO},
    {"x": 1},
    {"responses": []},
    {"steps": [step("__proto__", {"x": 1}, {"x": 1}), step("after", {"x": 1}, {"x": 1})], "carry": [],
     "terminal": {"status": "completed", "output": {"x": 1}}},
)


def main():
    for folder in ("fixtures", "expected"):
        (ROOT / folder).mkdir(exist_ok=True)
        for old in (ROOT / folder).glob("*.json"):
            old.unlink()
    for name, (files, input, scenario, expected) in FIXTURES.items():
        package_files = {path: json.dumps(body, indent=2) + "\n" if path == "loop.json" else body for path, body in files.items()}
        fixture = {"packageFiles": package_files, "manifestPath": "loop.json", "input": input, "scenario": scenario}
        (ROOT / "fixtures" / f"{name}.json").write_text(json.dumps(fixture, indent=2) + "\n")
        (ROOT / "expected" / f"{name}.json").write_text(json.dumps(expected, indent=2) + "\n")
    print(f"wrote {len(FIXTURES)} fixtures")


if __name__ == "__main__":
    main()
