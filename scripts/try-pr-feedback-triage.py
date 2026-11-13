#!/usr/bin/env python3
"""Propose a next action for one supplied PR feedback item; never deliver it."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "loops/pr-feedback-triage"
SPEC = importlib.util.spec_from_file_location("pr_feedback_route", PACKAGE / "route.py")
ROUTE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ROUTE)


class TriageRunError(RuntimeError):
    def __init__(self, message, run_id):
        super().__init__(message)
        self.run_id = run_id


def command(argv, env_file=None, timeout=90):
    environment = None
    if env_file is not None and len(argv) > 1 and argv[1] == "run":
        if env_file.is_symlink() or not env_file.is_file() or env_file.stat().st_size > 16384:
            raise ValueError("Expected a small regular local environment file")
        keys = []
        for line in env_file.read_text().splitlines():
            name, sep, value = line.partition("=")
            if sep and name.strip() == "TYPESAFE_API_KEY":
                value = value.strip()
                if len(value) > 1 and value[0] == value[-1] and value[0] in ("'", '"'):
                    value = value[1:-1]
                keys.append(value)
        if len(keys) != 1 or not keys[0]:
            raise ValueError("Configure one TYPESAFE_API_KEY in the local environment file")
        environment = {**os.environ, "TYPESAFE_API_KEY": keys[0]}
    started = time.perf_counter_ns()
    result = subprocess.run([str(arg) for arg in argv], capture_output=True, text=True, timeout=timeout, env=environment)
    ms = (time.perf_counter_ns() - started) / 1e6
    try:
        value = json.loads(result.stdout)
    except ValueError:
        raise RuntimeError("fh did not return structured JSON; inspect local stderr, do not replay") from None
    if result.returncode and value.get("status") not in ("completed", "failed", "stopped"):
        # Avoid reflecting arbitrary provider bodies or input into an exception.
        raise RuntimeError("fh rejected or failed this invocation; no automatic replay")
    return ms, value


def triage(value, input_file, binary=ROOT / "dist/fh", package=PACKAGE, invoke=command):
    # Same saved gate as the Loop, before all fh preflight/runtime/provider activity.
    json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
    gate = ROUTE.code_gate(value)
    if gate:
        return {"execution": "code_gate", "run_id": None, "model_called": False,
                "output": ROUTE.route(value)}
    # Dispatch the exact value we gated, even if the caller's file changes meanwhile.
    with tempfile.TemporaryDirectory(prefix="fh-feedback-input-") as temporary:
        frozen = Path(temporary) / "input.json"
        frozen.write_text(json.dumps(value))
        frozen.chmod(0o600)
        ms, result = invoke([binary, "run", package, "--input", frozen, "--bindings-id", "local", "--json"])
    if not result.get("run_id"):
        raise RuntimeError("No accepted run ID; do not replay uncertain work")
    get_ms, persisted = invoke([binary, "get", result["run_id"], "--json"])
    if persisted != result:
        raise TriageRunError("Persisted result differs; inspect locally before proceeding", result["run_id"])
    if result.get("status") != "completed":
        raise TriageRunError("Run " + result["run_id"] + " is incomplete; inspect its durable record and do not replay", result["run_id"])
    return {"execution": "fh_loop", "run_id": result["run_id"], "model_called": True,
            "elapsed_ms": round(ms, 3), "get_ms": round(get_ms, 3),
            "package_digest": result["package_digest"], "used_tokens": result["used_tokens"],
            "usage_unknown": result["usage_unknown"], "output": result["output"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--binary", type=Path, default=ROOT / "dist/fh")
    parser.add_argument("--env-file", type=Path, help="Load TYPESAFE_API_KEY locally for run only; never print it")
    args = parser.parse_args()
    if args.input.stat().st_size > 16384:
        parser.error("Feedback input must be at most 16 KiB")
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("Duplicate JSON key")
            value[key] = item
        return value
    value = json.loads(args.input.read_text(), object_pairs_hook=unique)
    invoke = lambda argv: command(argv, args.env_file)
    print(json.dumps(triage(value, args.input.resolve(), args.binary.resolve(), invoke=invoke), indent=2))


if __name__ == "__main__":
    main()
