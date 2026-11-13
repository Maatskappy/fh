"""Exercise release orchestration with a synthetic compiler, never a target build."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseTooling(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="fh-release-tooling-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for directory in ("scripts", "patches/fx", "bin", "native"):
            (self.root / directory).mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/release.sh", self.root / "scripts/release.sh")
        (self.root / "build.zig.zon").write_text('.{\n    .version = "9.8.7",\n}\n')
        # No legacy version declaration: the package manifest is the sole source.
        (self.root / "native/loops_client.zig").write_text("// version comes from build options\n")
        (self.root / "build.zig").write_text("// version comes from the package manifest\n")
        (self.root / "patches/fx/verify.py").write_text('print("synthetic provenance fixture")\n')
        compiler = self.root / "bin/zig"
        compiler.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
with open("zig-calls.jsonl", "a") as log:
    log.write(json.dumps({"args": sys.argv[1:], "cache": os.environ.get("ZIG_GLOBAL_CACHE_DIR")}) + "\\n")
if sys.argv[1:3] == ["build", "bundle"]:
    prefix = pathlib.Path(sys.argv[sys.argv.index("--prefix") + 1])
    prefix.mkdir(parents=True)
    binary = prefix / "fh"
    binary.write_text("#!/bin/sh\\nprintf 'fh %s\\\\n' '" + os.environ.get("FIXTURE_BINARY_VERSION", "9.8.7") + "'\\n")
    binary.chmod(0o755)
''')
        compiler.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                        SOURCE_DATE_EPOCH="1", ZIG_GLOBAL_CACHE_DIR=str(self.root / "chosen-cache"))
        self.target = {("Darwin", "arm64"): "aarch64-macos", ("Darwin", "x86_64"): "x86_64-macos",
                       ("Linux", "x86_64"): "x86_64-linux", ("Linux", "aarch64"): "aarch64-linux"}[
                           (platform.system(), platform.machine())]

    def release(self, *args):
        return subprocess.run(["sh", str(self.root / "scripts/release.sh"), *args,
                               "--targets", self.target, "--out", str(self.root / "out")],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def test_canonical_version_builds_archives_and_respects_cache_environment(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((self.root / "out/manifest.json").read_text())
        self.assertEqual(manifest["version"], "9.8.7")
        archive = self.root / "out" / manifest["targets"][self.target]["file"]
        self.assertTrue(archive.is_file())
        calls = [json.loads(line) for line in (self.root / "zig-calls.jsonl").read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertNotIn("--global-cache-dir", call["args"])
            self.assertEqual(call["cache"], self.env["ZIG_GLOBAL_CACHE_DIR"])

    def test_explicit_matching_version(self):
        result = self.release("9.8.7")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_requested_version_mismatch_stops_before_compiler(self):
        result = self.release("9.8.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("asked for 9.8.6 but this source builds fh 9.8.7", result.stderr)
        self.assertFalse((self.root / "zig-calls.jsonl").exists())
        self.assertFalse((self.root / "out").exists())

    def test_built_executable_version_must_match(self):
        self.env["FIXTURE_BINARY_VERSION"] = "0.0.0"
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 'fh 9.8.7'", result.stderr)
        self.assertFalse((self.root / "out").exists())

    def test_missing_or_duplicate_canonical_version_stops_before_compiler(self):
        for manifest in ('.{}\n', '.{\n.version = "9.8.7",\n.version = "9.8.6",\n}\n'):
            with self.subTest(manifest=manifest):
                (self.root / "build.zig.zon").write_text(manifest)
                result = self.release()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("expected one .version in build.zig.zon", result.stderr)
                self.assertFalse((self.root / "zig-calls.jsonl").exists())

    def installer_env(self):
        # These fixtures contain shell executables, so exercise the published
        # platform independently of the machine running source checks.
        tools = self.root / "installer-bin"
        tools.mkdir(exist_ok=True)
        uname = tools / "uname"
        uname.write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n')
        uname.chmod(0o755)
        return dict(self.env, PATH=str(tools) + os.pathsep + self.env["PATH"])

    def test_default_installer_uses_pinned_github_release_url(self):
        client = self.root / "bin/curl"
        called = self.root / "network-called"
        client.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "' + str(called) + '"\nexit 1\n')
        client.chmod(0o755)
        env = dict(self.installer_env(), FH_VERSION="4.5.6", FH_INSTALL_DIR=str(self.root / "app"),
                   FH_BIN_DIR=str(self.root / "links"))
        env.pop("FH_INSTALL_BASE", None)
        result = subprocess.run(["sh", str(ROOT / "scripts/install.sh")], env=env,
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("https://github.com/Maatskappy/fh/releases/download/v4.5.6/SHA256SUMS", called.read_text())
        self.assertFalse((self.root / "app").exists())

    def test_explicit_base_local_installer_fixture(self):
        # Exercise the real HTTP/install harness with a deliberately synthetic
        # executable and bundle; native binary validation is a separate check.
        import hashlib
        import tarfile

        version = "9.8.7"
        name = f"fh-{version}-macos-aarch64"
        bundle = self.root / name
        bundle.mkdir()
        binary = bundle / "fh"
        binary.write_text('#!/bin/sh\ncase "$1" in\n--version) echo "fh 9.8.7";;\n--help) echo "Usage: fh";;\n*) exit 1;;\nesac\n')
        binary.chmod(0o755)
        for relative in ("docs/loops.md", "lib/packages/loops-contract/loop-0.1.schema.json",
                         "skills/author-loop/SKILL.md", "loops/fixture.txt", "licenses/fx/LICENSE",
                         "licenses/wasmtime/inventory-aarch64-macos.json",
                         "licenses/wasmtime/rust-1.97.0/COPYRIGHT-library.html",
                         "licenses/wasmtime/rust-1.97.0/compiler-builtins-LICENSE.txt"):
            file = bundle / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("synthetic installer fixture\n")
        release = self.root / "fixture-release"
        release.mkdir()
        archive = release / (name + ".tar.gz")
        with tarfile.open(archive, "w:gz") as output:
            output.add(bundle, arcname=name)
        (release / "SHA256SUMS").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
        (release / "manifest.json").write_text(json.dumps({"version": version}))
        result = subprocess.run(["sh", str(ROOT / "scripts/test-install.sh"), str(release)],
                                cwd=self.root, env=self.installer_env(), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("test-install: all passed for fh 9.8.7", result.stdout)


if __name__ == "__main__":
    unittest.main()
