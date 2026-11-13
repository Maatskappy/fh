#!/usr/bin/env python3
"""Run the native socket regressions from a real, deeply staged source tree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    source = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="fh-socket-check-") as temporary:
        # Exceed both macOS's 104-byte and Linux's 108-byte sun_path fields.
        checkout = Path(temporary) / ("long-checkout-" * 12) / "src"
        shutil.copytree(
            source,
            checkout,
            ignore=shutil.ignore_patterns(
                ".*", "zig-out", "dist", "release", "zig-pkg", "__pycache__"
            ),
        )
        print(f"Running socket tests in {checkout} ({len(os.fsencode(checkout))} bytes)", flush=True)
        subprocess.run(
            ["zig", "build", "test-sockets", "--summary", "all"],
            cwd=checkout,
            check=True,
        )


if __name__ == "__main__":
    main()
