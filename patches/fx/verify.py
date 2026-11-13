#!/usr/bin/env python3
"""Audit the pinned originals and the explicitly approved presentation patch."""
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tempfile

REVISION = '4d966e272cfc4296cdf703f409480088cf2e72ba'
MANIFEST_SHA256 = '1704fa32bc31a4fb26d4638bb11ab89a03d042968414c4f7283f0a90a814a7e8'
APPROVED_FILES = frozenset({
    'src/gateway/openai_codex.zig',
    'src/gateway/client.zig',
    'src/core/shared/http_pool.zig',
    'src/core/app/provider_runtime.zig',
    'src/core/agent/stream_provider.zig',
    'src/gateway/chat_completions_protocol.zig',
    'src/core/app/app_bootstrap_runtime.zig',
    'src/core/app/app_agent_runtime.zig',
    'src/core/app/app_input_runtime.zig',
    'src/core/tooling/tool_runtime.zig',
    'src/core/app/app_entry_runtime.zig',
    'src/core/app/app_render_runtime.zig',
    'src/core/app/app_session_runtime.zig',
    'src/core/app/input_interrupt_runtime.zig',
    'src/core/app/input_submit_runtime.zig',
    'src/core/shared/profile_paths.zig',
    'src/core/config/config_runtime.zig',
    'src/core/cli/cli_surface.zig',
    'src/core/output/output_contracts.zig',
    'src/core/auth/chatgpt_session.zig',
    'src/core/auth/session_presence.zig',
    'src/core/auth/grok_session.zig',
    'src/core/auth/credentials.zig',
    'src/core/hosts/native_keychain.zig',
    'src/core/hosts/native_secret_store.zig',
    'src/core/config/settings_store.zig',
    'src/main.zig', 'src/ui/render.zig',
    'src/core/session/session_log.zig',
    'src/core/session/session_store.zig',
})
APPROVED_ADDITIONS = frozenset({'src/fh_browser_agent.zig', 'src/fh_loop_infer.zig', 'src/fh_provider_tests.zig', 'src/gateway/fh_host.zig', 'src/core/tooling/fh_loop_tools.zig', 'src/core/app/fh_startup.zig'})
RENDER = 'src/ui/render.zig'
FOOTER = 'src/core/app/app_render_runtime.zig'
# Whole-file digest freezes the audited footer projection as well as its surrounding
# render composition. Future presentation edits require an explicit policy review.
FOOTER_SHA256 = 'd12a05fa692ffd60003744b6e8e01645d69fa0145e5d5fc47bbb02122ce7e010'
MODIFICATION_NOTICE = b'// Modified for Fasthands; see patches/fx/README.md for the integration changes.\n'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def patch_paths(patch, expected=APPROVED_FILES):
    old = re.findall(rb'^--- (.+)$', patch, re.M)
    new = re.findall(rb'^\+\+\+ (.+)$', patch, re.M)
    require(len(old) == len(new) == len(expected), 'patch inventory count mismatch')
    paths = []
    for a, b in zip(old, new):
        require(a.startswith(b'a/') and b == b'b/' + a[2:], 'patch path must be same original path')
        path = a[2:].decode('utf-8')
        require(path in expected, f'patch outside approved boundary: {path}')
        paths.append(path)
    require(len(set(paths)) == len(paths), 'duplicate patch path')
    require(set(paths) == expected, 'patch inventory mismatch')
    return paths


def presentation_boundary(original, vendor):
    before = (original / RENDER).read_bytes()
    require(before.count('𝒇x'.encode()) == 3, 'welcome branding substitution count mismatch')
    require((vendor / RENDER).read_bytes() == MODIFICATION_NOTICE + before.replace('𝒇x'.encode(), '𝒇h'.encode()),
            f'native UI content outside approved branding boundary: {RENDER}')
    require(hashlib.sha256((vendor / FOOTER).read_bytes()).hexdigest() == FOOTER_SHA256,
            f'footer content outside approved projection boundary: {FOOTER}')


def verify(root):
    root = pathlib.Path(root)
    vendor = root / 'vendor/fx'
    provenance = json.loads((vendor / 'UPSTREAM.json').read_text())
    manifest_bytes = (vendor / 'UPSTREAM_FILES.json').read_bytes()
    require(hashlib.sha256(manifest_bytes).hexdigest() == MANIFEST_SHA256, 'original manifest hash mismatch')
    manifest = json.loads(manifest_bytes)
    require(manifest['revision'] == provenance['revision'] == REVISION, 'upstream revision mismatch')
    require(provenance['patch'] == 'patches/fx/0001-loops-shell-proof.patch', 'canonical patch path mismatch')
    patch = (root / provenance['patch']).read_bytes()
    require(hashlib.sha256(patch).hexdigest() == provenance['patchSha256'], 'patch hash mismatch')
    modified = provenance['modifiedFiles']
    require(len(modified) == len(APPROVED_FILES) and set(modified) == APPROVED_FILES, 'modified inventory outside approved boundary')
    for path in modified:
        require((vendor / path).read_bytes().startswith((MODIFICATION_NOTICE,
                b'// Modified for Fasthands native Loops shell proof.\n')),
                f'missing prominent modification notice: {path}')
    added = provenance.get('addedFiles', [])
    require(set(added) == APPROVED_ADDITIONS and len(added) == len(APPROVED_ADDITIONS), 'added inventory outside approved boundary')
    require(set(provenance.get('addedFileSha256', {})) == APPROVED_ADDITIONS, 'added file hash inventory mismatch')
    for path in added:
        require(hashlib.sha256((vendor / path).read_bytes()).hexdigest() == provenance['addedFileSha256'][path], f'added integration hash mismatch: {path}')
    require(set(patch_paths(patch)) == set(modified), 'patch/provenance inventory mismatch')
    expected = {entry['path'] for entry in manifest['files']}
    require(len(expected) == len(manifest['files']) == provenance['originalFiles'] == 637, 'original inventory mismatch')
    actual = {str(path.relative_to(vendor)) for path in (vendor / 'src').rglob('*') if path.is_file()}
    require(actual == {path for path in expected if path.startswith('src/')} | APPROVED_ADDITIONS, 'untracked vendor source')
    with tempfile.TemporaryDirectory(prefix='fh-provenance-') as directory:
        restored = pathlib.Path(directory)
        for path in modified:
            target = restored / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(vendor / path, target)
        subprocess.run(['patch', '--batch', '--reverse', '--fuzz=0', '-p1', '-d', str(restored)],
                       input=patch, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        for entry in manifest['files']:
            path = entry['path']
            data = ((restored if path in modified else vendor) / path).read_bytes()
            require(hashlib.sha256(data).hexdigest() == entry['sha256'], f'original SHA256 mismatch: {path}')
            header = b'blob ' + str(len(data)).encode() + b'\0'
            require(hashlib.sha1(header + data).hexdigest() == entry['gitBlobSha1'], f'original git blob mismatch: {path}')
        presentation_boundary(restored, vendor)
        subprocess.run(['patch', '--batch', '--forward', '--fuzz=0', '-p1', '-d', str(restored)],
                       input=patch, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        for path in modified:
            require((restored / path).read_bytes() == (vendor / path).read_bytes(), f'patch round trip mismatch: {path}')
    return 'Verified 637 upstream blobs; thirty audited original patches plus six separately hashed native inference, browser-agent, tool, startup and fixture additions; approved welcome/title/footer presentation changes; renderer/input algorithms retained.'


if __name__ == '__main__':
    try:
        print(verify(pathlib.Path(__file__).resolve().parents[2]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'fx provenance verification failed: {error}')
