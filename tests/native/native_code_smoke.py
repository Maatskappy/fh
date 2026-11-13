#!/usr/bin/env python3
"""Build/run the narrow native Docker proof with explicit runtime JSON and journal.

No profile/auth discovery. Both runtime audit and counter use unique owned
containers, bounded resources, and synchronous cleanup in the native adapter.
Example: python3 tests/native/native_code_smoke.py --config /absolute/runtime.json
         --journal /private/tmp/fresh-owned-proof.json
Runtime JSON: socket_path, staging_root, image, python, runtime_handle,
             policy_digest, stdlib (array). Staging root must already be private.
Stdout is one JSON result; the supplied journal persists exact owned receipts.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--journal", required=True, type=Path)
    parser.add_argument("--zig", default="zig")
    args = parser.parse_args()
    for name in ("config", "journal"):
        path = getattr(args, name)
        if not path.is_absolute():
            parser.error(f"--{name} must be absolute")
    if args.journal.exists():
        parser.error("--journal must be a fresh path")
    repo = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="fh-native-code-proof-") as directory:
        root = Path(directory)
        for name in ("native", "vendor"):
            (root / name).symlink_to(repo / name, target_is_directory=True)
        (root / "proof.zig").symlink_to(repo / "tests/native/native_code_smoke.zig")
        (root / "main.zig").write_text('pub const main = @import("proof.zig").main;\n')
        binary = root / "proof"
        subprocess.run([args.zig, "build-exe", "-lc", f"-Mroot={root / 'main.zig'}",
                        "--cache-dir", str(root / "cache"), "--global-cache-dir",
                        str(root / "global-cache"), f"-femit-bin={binary}"], check=True)
        subprocess.run([str(binary), "--config", str(args.config), "--journal",
                        str(args.journal)], check=True)


if __name__ == "__main__":
    main()
