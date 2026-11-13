#!/usr/bin/env python3
"""Focused real CLI regressions for bounded diagnostics and partial recovery.

No provider or source runtime is configured. The five-second subprocess bound is
the retained hang reproduction's test-harness bound, not a product runtime limit.
"""
import argparse
import copy
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--binary', type=Path, required=True)
args = parser.parse_args()
binary = args.binary.resolve()


def call(profile, *argv):
    result = subprocess.run([str(binary), *map(str, argv), '--json'],
                            env=dict(os.environ, FH_DATA_DIR=str(profile), PATH=''),
                            capture_output=True, timeout=5)
    assert result.returncode == 2, (argv, result.returncode, result.stdout, result.stderr)
    assert not result.stderr, result.stderr
    return json.loads(result.stdout)


with tempfile.TemporaryDirectory(prefix='fh-runtime-diagnostic-bounds-', dir='/private/tmp') as temp:
    root = Path(temp)
    input_file = root/'input.json'
    input_file.write_text('{"number":2}')
    manifest = json.loads((ROOT/'loops/increment-wasm/loop.json').read_text())
    artifact = (ROOT/'native/loops/fixtures/wasm/random.wasm').read_bytes()
    for case in ('multibyte-id', 'long-artifact'):
        package = root/case
        package.mkdir()
        m = copy.deepcopy(manifest)
        m['output'] = None
        step = m['steps'][0]
        if case == 'multibyte-id':
            step['id'] = '🙂'*300
            step['file'] = 'bad.wasm'
        else:
            # The retained artifact-path repro: legal components, large JSON escaping.
            step['file'] = '/'.join(['🙂'*55]*3 + ['a.wasm'])
        file = package/step['file']
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(artifact)
        (package/'loop.json').write_text(json.dumps(m))
        for command in ('check', 'run'):
            profile = root/f'{case}-{command}-profile'
            profile.mkdir(mode=0o700)
            extra = ('--input', input_file) if command == 'run' else ()
            result = call(profile, command, package, *extra)
            issue = result['issues'][0] if command == 'check' else result['error']
            assert issue['code'] == 'execution_failed' and issue['cause'] == 'WasmImport', result
            assert isinstance(issue['path'], str) and isinstance(issue['message'], str), result
            assert 'random_get' in issue['message'] and 'wasm32-wasi-json/1' in issue['message'], result
            if case == 'multibyte-id':
                assert issue['path'].startswith('steps.🙂') and issue['path'].endswith('...'), result
            else:
                assert issue['path'] == 'steps.increment.file', result
                assert 'artifact "a.wasm"' in issue['message'] and issue['message'].endswith('...'), result
            # No accepted run, record, guest execution or model dispatch can precede refusal.
            assert 'run_id' not in result, result
            runs = profile/'native-runs'
            assert not runs.exists() or all(p.name == 'foreground.lock' for p in runs.iterdir()), list(runs.iterdir())
            print(f'PASS {case} {command}: error 2 before accepted run; JSON string fields and cause retained')

    # Read actual directory order so the first orphan is visited before a held later lease.
    profile = root/'mixed-owner-profile'
    profile.mkdir(mode=0o700)
    runs = profile/'native-runs'
    runs.mkdir(mode=0o700)
    original = dict(format='fh.native-run/0.1', status='running', used_tokens=7,
                    usage_unknown=True, model_request_dispatches=1,
                    model_request_dispatches_complete=False,
                    attempts=[dict(status='running')],
                    effects=[dict(id='request', kind='model_request', state='unknown')])
    for id in ('run_first', 'run_second'):
        file = runs/f'{id}.json'
        file.write_text(json.dumps(dict(original, run_id=id)))
        file.chmod(0o600)
    first, later = [Path(e.path) for e in os.scandir(runs) if e.name.endswith('.json')]
    before = later.read_bytes()
    with (runs/f'{later.stem}.lock').open('w') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = call(profile, 'run', ROOT/'loops/increment-wasm', '--input', input_file)
    issue = result['error']
    assert issue['code'] == 'owner_busy' and issue['cause'] == 'RunBusy', result
    assert 'requested operation was not started' in issue['message'], result
    assert 'orphan bookkeeping may have occurred' in issue['message'], result
    assert 'Nothing was changed' not in issue['message'], result
    recovered = json.loads(first.read_bytes())
    assert recovered['status'] == 'stopped' and recovered['recovery_required'] is True, recovered
    assert recovered['attempts'] == [dict(status='uncertain')], recovered
    for key in ('effects', 'used_tokens', 'usage_unknown', 'model_request_dispatches', 'model_request_dispatches_complete'):
        assert recovered[key] == original[key], (key, recovered)
    assert later.read_bytes() == before
    assert sorted(p.name for p in runs.glob('*.json')) == sorted([first.name, later.name])
    print('PASS mixed orphan/live-owner: earlier recovery preserved unknown outcomes; busy response accurately describes partial bookkeeping')
