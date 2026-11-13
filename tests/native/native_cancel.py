#!/usr/bin/env python3
"""Actual cross-process cancellation of one owned native Docker code run.

Only explicit installation runtime metadata is copied into a private disposable
profile. No operator records, credentials, model, Docker CLI, or discovered Loop
are used. Docker HTTP is read-only and targets only IDs from this proof journal.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time
from urllib.parse import quote


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def docker_get(socket_path, container):
    path = '/v1.45/containers/' + quote(container, safe='') + '/json'
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(2)
        peer.connect(socket_path)
        peer.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: localhost\r\n'
                      'Connection: close\r\n\r\n').encode('ascii'))
        data = bytearray()
        while True:
            chunk = peer.recv(8192)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > 278528:
                raise AssertionError('owned Docker inspection exceeded bound')
    header, body = bytes(data).split(b'\r\n\r\n', 1)
    status = int(header.split(b' ', 2)[1])
    fields = dict(line.lower().split(b':', 1) for line in header.split(b'\r\n')[1:])
    if b'chunked' in fields.get(b'transfer-encoding', b''):
        decoded = bytearray()
        while True:
            line, body = body.split(b'\r\n', 1)
            size = int(line.split(b';', 1)[0], 16)
            if not size:
                break
            assert len(body) >= size + 2 and body[size:size + 2] == b'\r\n'
            decoded.extend(body[:size]); body = body[size + 2:]
        body = bytes(decoded)
    return status, json.loads(body) if body else None


def runtime_metadata(original):
    profile = original['runtimeProfiles']['python3']
    binding = original['bindings']['local']
    candidates = [(name, binding['resources'][name]) for name in profile['resources']
                  if original['resources'][binding['resources'][name]]['kind'] == 'runtime']
    assert len(candidates) == 1, 'one explicitly bound runtime is required'
    logical, handle = candidates[0]
    runtime = dict(profile, resources=[logical])
    assert not runtime.get('writableResources'), 'proof cannot acquire writable resources'
    limits = dict(original.get('limits', {}))
    limits['maxSeconds'] = min(10, limits.get('maxSeconds', 600))
    limits['maxOutputBytes'] = min(65536, limits.get('maxOutputBytes', 1048576))
    limits['maxDiagnosticBytes'] = min(4096, limits.get('maxDiagnosticBytes', 65536))
    docker = {'socketPath': original['docker']['socketPath']}
    if 'stagingRoot' in original['docker']:
        docker['stagingRoot'] = original['docker']['stagingRoot']
    return {'version': 1, 'limits': limits, 'docker': docker,
            'bindings': {'local': {'id': 'local', 'policyDigest': binding['policyDigest'],
                                   'capabilities': {}, 'resources': {logical: handle}}},
            'resources': {handle: original['resources'][handle]},
            'runtimeProfiles': {'python3': runtime}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    original_path = args.profile / 'installation.json'
    original_bytes = original_path.read_bytes()
    assert len(original_bytes) <= 1048576
    metadata = runtime_metadata(json.loads(original_bytes))
    report = {'format': 'fh.native-cancel-evidence/0.1', 'binary_sha256': digest(binary),
              'source_sha256': digest(Path(__file__)), 'model_calls': 0, 'auth_calls': 0,
              'docker_cli_calls': 0, 'operator_policy_sha256': hashlib.sha256(original_bytes).hexdigest(),
              'limits': metadata['limits'], 'image': metadata['runtimeProfiles']['python3']['image']}
    source = "import json,sys,time\njson.load(sys.stdin)\ntime.sleep(30)\nprint(json.dumps({'finished':True}))\n"
    with tempfile.TemporaryDirectory(prefix='fh-native-cancel-', dir='/private/tmp') as temporary:
        root = Path(temporary); profile = root / 'profile'; profile.mkdir(mode=0o700)
        home = root / 'home'; home.mkdir(mode=0o700)
        config = profile / 'installation.json'; config.write_text(json.dumps(metadata)); config.chmod(0o600)
        copied_hash = digest(config)
        package = root / 'package'; package.mkdir()
        manifest = {'format': 'loops/0.1', 'name': 'native-cancel-proof', 'version': '0.1.0',
                    'inputs': {'schema': {'type': 'object'}}, 'steps': [
                        {'id': 'hold', 'kind': 'code', 'runtime': 'python3', 'requires': [],
                         'file': 'hold.py', 'input': {'from': '/input'},
                         'output': {'schema': {'type': 'object', 'required': ['finished'],
                                               'properties': {'finished': {'type': 'boolean'}}}}}],
                    'output': {'from': '/steps/hold/output'}}
        (package / 'loop.json').write_text(json.dumps(manifest, separators=(',', ':')) + '\n')
        (package / 'hold.py').write_text(source)
        report['saved_code_sha256'] = hashlib.sha256(source.encode()).hexdigest()
        env = dict(os.environ, FH_DATA_DIR=str(profile), HOME=str(home))
        for key in ('FX_PROVIDER', 'FX_AUTH_MODE', 'FX_API_KEY', 'AI_GATEWAY_API_KEY', 'VERCEL_OIDC_TOKEN'):
            env.pop(key, None)
        command = [str(binary), 'run', str(package), '--events']
        started = time.perf_counter()
        run = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        run_id = None; lines = []; pending = bytearray()
        try:
            deadline = time.monotonic() + 5
            while run_id is None and time.monotonic() < deadline:
                readable, _, _ = select.select([run.stdout], [], [], .05)
                if not readable:
                    assert run.poll() is None, 'native run ended before acceptance'
                    continue
                chunk = os.read(run.stdout.fileno(), 65536)
                assert chunk, 'missing accepted frame'
                pending.extend(chunk)
                assert len(pending) <= 1048576
                while b'\n' in pending:
                    line, _, pending = pending.partition(b'\n')
                    value = json.loads(line); lines.append(value)
                    if 'run_id' in value and 'presentation' in value:
                        run_id = value['run_id']; break
            assert run_id is not None, 'no accepted run ID'
            report['run_id'] = run_id
            report['accepted_ms'] = round((time.perf_counter() - started) * 1000, 2)
            record_path = profile / 'native-runs' / (run_id + '.json')
            active = None
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                record = json.loads(record_path.read_text())
                effects = record.get('effects', [])
                if any(row['kind'] == 'code_invocation' and row['state'] == 'applied' for row in effects):
                    locator = next(row['details']['container'] for row in effects if row['kind'] == 'code_container')
                    status, info = docker_get(metadata['docker']['socketPath'], locator)
                    if status == 200 and info['State']['Running']:
                        active = info; break
                time.sleep(.01)
            assert active is not None, 'proof must cancel an actually running isolated code step'
            cancel_started = time.perf_counter()
            cancel = subprocess.run([str(binary), 'cancel', run_id, '--json'], cwd=root, env=env,
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=4)
            assert cancel.returncode == 0, (cancel.returncode, cancel.stderr.decode())
            cancelled = json.loads(cancel.stdout)
            assert cancelled == {'run_id': run_id, 'cancelled': True}, cancelled
            tail, stderr = run.communicate(timeout=5)
            assert run.returncode == 130, (run.returncode, tail.decode(), stderr.decode())
            assert not stderr, stderr.decode()
            frames = lines + [json.loads(line) for line in (bytes(pending) + tail).splitlines() if line]
            final = frames[-1]['result']
            assert final['status'] == 'stopped' and final['stop']['reason'] == 'cancelled', final
            assert 'output' not in final and not final['uncertain_effects'], final
            report['cancel_to_joined_terminal_ms'] = round((time.perf_counter() - cancel_started) * 1000, 2)
            get = subprocess.run([str(binary), 'get', run_id, '--json'], cwd=root, env=env,
                                 stdin=subprocess.DEVNULL, capture_output=True, timeout=4)
            assert get.returncode == 130, (get.returncode, get.stderr.decode())
            stored_public = json.loads(get.stdout)
            assert stored_public['status'] == 'stopped' and stored_public['stop']['reason'] == 'cancelled'
            record = json.loads(record_path.read_text())
            owned = record['effects']
            assert all(row['state'] != 'unknown' for row in owned), owned
            invocation = [row for row in owned if row['kind'] == 'code_invocation']
            assert len(invocation) == 1 and invocation[0]['state'] == 'applied'
            resource_rows = [row for row in owned if row['kind'] in ('code_container', 'code_staging')]
            assert len(resource_rows) == 2 and all(row['state'] == 'not_applied' for row in resource_rows)
            status, _ = docker_get(metadata['docker']['socketPath'], active['Id'])
            assert status == 404, 'owned container remains after terminal'
            staging = Path(next(row['details']['staging'] for row in owned if row['kind'] == 'code_staging'))
            assert not staging.exists() and not staging.is_symlink(), 'owned staging remains after terminal'
            # Include the runtime probe's resources: it shares this proof-only profile.
            all_records = [json.loads(path.read_text()) for path in (profile / 'native-runs').glob('*.json')]
            for entry in all_records:
                for row in entry.get('effects', []):
                    assert row['state'] != 'unknown', 'an owned probe resource is unsettled'
                    if row['kind'] == 'code_container':
                        assert docker_get(metadata['docker']['socketPath'], row['details']['container'])[0] == 404
                    if row['kind'] == 'code_staging':
                        assert not Path(row['details']['staging']).exists()
            assert digest(config) == copied_hash, 'disposable policy changed'
            report.update({'package_digest': record['package_digest'], 'status': final['status'],
                           'stop': final['stop'], 'run_exit': run.returncode, 'get_exit': get.returncode,
                           'cancel_cli_exit': cancel.returncode, 'running_before_cancel': True,
                           'owned_container_absent': True, 'owned_staging_absent': True,
                           'owned_record_count': len(all_records), 'all_owned_receipts_settled': True,
                           'effects': [{'id': row['id'], 'kind': row['kind'], 'state': row['state']} for row in owned],
                           'cleanup_joined_before_terminal': True, 'output_suppressed': True})
        finally:
            if run.poll() is None:
                if run_id:
                    subprocess.run([str(binary), 'cancel', run_id, '--json'], cwd=root, env=env,
                                   stdin=subprocess.DEVNULL, capture_output=True, timeout=4)
                try:
                    run.communicate(timeout=15)
                except subprocess.TimeoutExpired:
                    # Retain exact owned locators for an explicit recovery, never broad Docker cleanup.
                    if run_id and record_path.exists():
                        report['failed_owned_record'] = json.loads(record_path.read_text())
                    run.terminate(); run.wait(timeout=3)
            assert original_path.read_bytes() == original_bytes, 'operator policy changed'
    report['operator_policy_unchanged'] = True
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ('run_id', 'status', 'stop', 'cancel_to_joined_terminal_ms',
                                                'owned_container_absent', 'owned_staging_absent')}))


if __name__ == '__main__':
    main()
