#!/usr/bin/env python3
"""Capture fixed developer checks, then assess their receipts with saved fh code."""
import argparse
import contextlib
import datetime
import hashlib
import json
import os
import selectors
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "loops/change-readiness"
MAX_LOG = 1024 * 1024


def save(path, value):
    with open(path, "x", encoding="utf-8", opener=lambda p, f: os.open(p, f, 0o600)) as file:
        json.dump(value, file, indent=2, ensure_ascii=True, allow_nan=False)
        file.write("\n")


def identity():
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    digest = hashlib.sha256()
    with subprocess.Popen(["git", "diff", "--binary", "--no-ext-diff", "HEAD", "--", "."],
                          cwd=ROOT, stdout=subprocess.PIPE) as process:
        for chunk in iter(lambda: process.stdout.read(65536), b""):
            digest.update(chunk)
        if process.wait() != 0:
            raise RuntimeError("Could not identify tracked changes.")
    return revision, "tracked staged+unstaged diff vs HEAD sha256:" + digest.hexdigest()


def capture(name, command, evidence, separate_stderr=False):
    started = time.monotonic()
    retained = {"stdout": bytearray(), "stderr": bytearray()}
    totals = {"stdout": 0, "stderr": 0}
    paths = {"stdout": evidence / (name + ".log")}
    if separate_stderr:
        paths["stderr"] = evidence / (name + ".stderr.log")
    with contextlib.ExitStack() as stack:
        files = {stream: stack.enter_context(open(path, "xb", opener=lambda p, f: os.open(p, f, 0o600)))
                 for stream, path in paths.items()}
        try:
            process = stack.enter_context(subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE if separate_stderr else subprocess.STDOUT))
            poll = stack.enter_context(selectors.DefaultSelector())
            poll.register(process.stdout, selectors.EVENT_READ, "stdout")
            if separate_stderr:
                poll.register(process.stderr, selectors.EVENT_READ, "stderr")
            while poll.get_map():
                for key, _ in poll.select():
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        poll.unregister(key.fileobj)
                        continue
                    stream = key.data
                    totals[stream] += len(chunk)
                    saved = chunk[:max(0, MAX_LOG - len(retained[stream]))]
                    files[stream].write(saved)
                    retained[stream].extend(saved)
            code = process.wait()
        except OSError as error:
            code = 127
            stream = "stderr" if separate_stderr else "stdout"
            saved = str(error).encode()[:max(0, MAX_LOG - len(retained[stream]))]
            retained[stream].extend(saved)
            files[stream].write(saved)
    duration = round((time.monotonic() - started) * 1000, 3)
    text = retained["stdout"].decode("utf-8", errors="replace")
    summary_text = text + retained["stderr"].decode("utf-8", errors="replace")
    clean = "".join(char if char.isprintable() or char == "\n" else " " for char in summary_text)
    summary = (" | ".join(clean.splitlines()[-3:]) or f"{name} exited {code}.")[:1024]
    truncated = any(total > MAX_LOG for total in totals.values())
    if truncated:
        summary = ("Log truncated at 1 MiB per stream. " + summary)[:1024]
    receipt = {"name": name, "exit_code": code, "duration_ms": duration, "summary": summary}
    detail = {"command": [str(part) for part in command], "log": str(paths["stdout"]),
              "log_truncated": truncated, **receipt}
    if separate_stderr:
        detail["stderr_log"] = str(paths["stderr"])
    return receipt, detail, text


def native(name, command, evidence):
    receipt, detail, text = capture(name, command, evidence, separate_stderr=True)
    try:
        value = json.loads(text)
    except (ValueError, RecursionError):
        value = None
    return receipt, detail, value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--binary", type=Path, default=ROOT / "dist/fh")
    args = parser.parse_args()
    base = args.evidence_dir.resolve()
    if base == PACKAGE or PACKAGE in base.parents:
        parser.error("Evidence must stay outside the immutable change-readiness package.")
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    evidence = Path(tempfile.mkdtemp(prefix=stamp, dir=base))
    revision, diff_identity = identity()
    checks = [
        ("native-checks", ["zig", "build", "check", "test-chat", "test-loops-native"]),
        ("provenance", ["python3", "patches/fx/verify.py"]),
    ]
    receipts, commands = [], []
    for name, command in checks:
        receipt, detail, _ = capture(name, command, evidence)
        receipts.append(receipt)
        commands.append(detail)
    supplied = {"revision": revision, "diff_identity": diff_identity,
                "required_checks": [name for name, _ in checks], "receipts": receipts}
    input_path = evidence / "receipts.json"
    save(input_path, supplied)
    binary = str(args.binary.resolve())
    _, checked, check_result = native("fh-check", [binary, "check", str(PACKAGE),
                                     "--bindings-id", "local", "--json"], evidence)
    commands.append(checked)
    # Failed developer checks still reach the assessor as explicit receipts.
    _, ran, run_result = native("fh-run", [binary, "run", str(PACKAGE), "--input", str(input_path),
                               "--bindings-id", "local", "--json"], evidence)
    commands.append(ran)
    final = None
    got = None
    if isinstance(run_result, dict) and isinstance(run_result.get("run_id"), str):
        _, got, final = native("fh-get", [binary, "get", run_result["run_id"], "--json"], evidence)
        commands.append(got)
    output = final.get("output") if isinstance(final, dict) else None
    ready = (checked["exit_code"] == 0 and isinstance(check_result, dict) and check_result.get("ok") is True
             and ran["exit_code"] == 0 and got is not None and got["exit_code"] == 0
             and isinstance(final, dict) and final.get("status") == "completed" and isinstance(output, dict) and output.get("ready") is True)
    report = {"ready": ready, "evidence_dir": str(evidence), "revision": revision,
              "diff_identity": diff_identity, "commands": commands,
              "check": check_result, "run": run_result, "authoritative_get": final}
    save(evidence / "report.json", report)
    print(json.dumps({"ready": ready, "evidence_dir": str(evidence), "run_id": final.get("run_id") if isinstance(final, dict) else None,
                      "next_action": output.get("next_action") if isinstance(output, dict) else "Inspect the captured fh logs."}))
    return 0 if ready else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
