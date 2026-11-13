#!/usr/bin/env python3
"""Verify runtime setup recovery against an explicit native fh, using private profiles only."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def write_private(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    checked = 0
    with tempfile.TemporaryDirectory(prefix="fh-runtime-setup-recovery-") as temp:
        root = Path(temp)
        cases = [("queued", "model_request", True), ("running", "decision_request", True)]
        cases += [("running", kind, False) for kind in (
            "workspace_command", "workspace_edit", "code_container", "code_staging", "browser_cleanup")]
        for index, (status, kind, allowed) in enumerate(cases):
            profile = root / str(index)
            profile.mkdir(mode=0o700)
            installation = profile / "installation.json"
            write_private(installation, {"version": 1, "bindings": {"local": {
                "id": "local", "resources": {}, "capabilities": {}}},
                "resources": {}, "runtimeProfiles": {}, "operator": "preserved"})
            before = installation.read_bytes()
            runs = profile / "native-runs"
            runs.mkdir(mode=0o700)
            record_path = runs / "orphan.json"
            record = {"format": "fh.native-run/0.1", "run_id": "orphan", "status": status,
                "used_tokens": 7, "usage_unknown": True, "model_request_dispatches": 1,
                "model_request_dispatches_complete": False, "attempts": [{"status": "running"}],
                "effects": [{"id": "uncertain", "kind": kind, "state": "unknown"}]}
            for key in ("package_path", "bindings_id", "input_source", "input_sha256",
                        "package_digest", "binding_digest"):
                record[key] = "retained"
            record["root_input"] = None
            write_private(record_path, record)
            marker = runs / "orphan.pending"
            marker.write_text("fh.pending/1\n")
            marker.chmod(0o600)
            result = subprocess.run([str(binary), "setup", "runtime", "node", "--socket",
                "/tmp/not-contacted.sock", "--image", "node@sha256:" + "a" * 64,
                "--version", "24.18.0"], env=dict(os.environ, FH_DATA_DIR=str(profile)),
                text=True, capture_output=True)
            assert result.returncode == (0 if allowed else 2), (
                status, kind, result.returncode, result.stderr)
            recovered = json.loads(record_path.read_text())
            assert recovered["status"] == "stopped", recovered
            assert recovered["attempts"] == [{"status": "uncertain"}], recovered
            assert recovered["recovery_required"] is True
            for key in ("used_tokens", "usage_unknown", "model_request_dispatches",
                        "model_request_dispatches_complete", "effects"):
                assert recovered[key] == record[key], (key, recovered)
            if allowed:
                configured = json.loads(installation.read_text())
                assert configured["runtimeProfiles"]["node"]["available"] is True
                assert configured["operator"] == "preserved"
                assert not marker.exists()
                retry = subprocess.run([str(binary), "retry", "orphan", "--json"],
                    env=dict(os.environ, FH_DATA_DIR=str(profile)), text=True, capture_output=True)
                assert retry.returncode == 2 and "retry_unknown_usage" in retry.stdout, retry
            else:
                assert "RecoveryRequired" in result.stderr, result.stderr
                assert installation.read_bytes() == before
                assert marker.exists()
            checked += 1
            print(f"PASS {status} {kind}: {'registered' if allowed else 'installation unchanged'}")
    print(f"{checked}/{checked} runtime setup recovery cases passed; no runtime/provider contact")


if __name__ == "__main__":
    main()
