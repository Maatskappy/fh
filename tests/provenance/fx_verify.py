#!/usr/bin/env python3
"""Self-consistent malicious patches must not broaden the approved fork."""
import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('policy', ROOT / 'patches/fx/verify.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class ProvenanceBoundary(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fh-verify-negative-')
        self.root = pathlib.Path(self.temp.name)
        shutil.copytree(ROOT / 'vendor/fx', self.root / 'vendor/fx')
        shutil.copytree(ROOT / 'patches/fx', self.root / 'patches/fx')
        self.vendor = self.root / 'vendor/fx'
        self.original = self.root / 'original'
        self.original.mkdir()
        for path in policy.APPROVED_FILES:
            target = self.original / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.vendor / path, target)
        subprocess.run(['patch', '--batch', '--reverse', '--fuzz=0', '-p1', '-d', str(self.original)],
                       input=(self.root / 'patches/fx/0001-loops-shell-proof.patch').read_bytes(),
                       check=True, stdout=subprocess.DEVNULL)

    def tearDown(self):
        self.temp.cleanup()

    def metadata(self, change):
        path = self.vendor / 'UPSTREAM.json'
        value = json.loads(path.read_text())
        change(value)
        path.write_text(json.dumps(value))

    def regenerate(self, extra=None):
        paths = sorted(policy.APPROVED_FILES | ({extra} if extra else set()))
        patch = b''
        for path in paths:
            result = subprocess.run(['diff', '-u', '--label', f'a/{path}', '--label', f'b/{path}',
                                     str(self.original / path), str(self.vendor / path)], stdout=subprocess.PIPE)
            self.assertIn(result.returncode, (0, 1))
            patch += result.stdout
        (self.root / 'patches/fx/0001-loops-shell-proof.patch').write_bytes(patch)
        self.metadata(lambda value: value.update(patchSha256=hashlib.sha256(patch).hexdigest(), modifiedFiles=paths))

    def expect_result(self, error=None):
        for flags in ([], ['-O']):
            result = subprocess.run(['python3', *flags, str(self.root / 'patches/fx/verify.py')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0 if error is None else 1, result.stdout + result.stderr)
            if error:
                self.assertIn(error, result.stderr)
            else:
                self.assertIn('637 upstream blobs', result.stdout)

    def test_approved_original_reverse_and_roundtrip(self):
        self.expect_result()

    def test_self_consistent_welcome_algorithm_mutation(self):
        path = self.vendor / policy.RENDER
        content = path.read_text()
        self.assertIn('.{ subtitle_style, reset_style, dim_style, build_label }', content)
        path.write_text(content.replace('.{ subtitle_style, reset_style, dim_style, build_label }', '.{ subtitle_style, dim_style, reset_style, build_label }', 1))
        self.regenerate()
        self.expect_result('native UI content outside approved branding boundary')

    def test_self_consistent_footer_mutation(self):
        path = self.vendor / policy.FOOTER
        path.write_bytes(path.read_bytes() + b'\n// unauthorized render change\n')
        self.regenerate()
        self.expect_result('footer content outside approved projection boundary')

    def test_self_consistent_other_renderer_mutation(self):
        path = 'src/ui/render_engine/terminal_diff.zig'
        (self.original / path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.vendor / path, self.original / path)
        with (self.vendor / path).open('ab') as file:
            file.write(b'\n// unauthorized renderer change\n')
        self.regenerate(extra=path)
        self.expect_result('modified inventory outside approved boundary')

    def test_stale_patch_hash(self):
        path = self.root / 'patches/fx/0001-loops-shell-proof.patch'
        with path.open('ab') as file:
            file.write(b'\n')
        self.expect_result('patch hash mismatch')

    def test_inventory_does_not_follow_mutable_metadata(self):
        self.metadata(lambda value: value['modifiedFiles'].pop())
        self.expect_result('modified inventory outside approved boundary')

    def test_immutable_original_manifest(self):
        path = self.vendor / 'UPSTREAM_FILES.json'
        path.write_bytes(path.read_bytes() + b'\n')
        self.expect_result('original manifest hash mismatch')

    def test_source_change_without_patch_fails_original_hash(self):
        with (self.vendor / policy.RENDER).open('ab') as file:
            file.write(b'\n')
        self.expect_result('original SHA256 mismatch')

    def test_duplicate_header_with_self_consistent_digest(self):
        path = self.root / 'patches/fx/0001-loops-shell-proof.patch'
        patch = path.read_bytes().replace(b'--- a/src/ui/render.zig\n+++ b/src/ui/render.zig',
                                         b'--- a/src/main.zig\n+++ b/src/main.zig')
        path.write_bytes(patch)
        self.metadata(lambda value: value.update(patchSha256=hashlib.sha256(patch).hexdigest()))
        self.expect_result('duplicate patch path')


if __name__ == '__main__':
    unittest.main()
