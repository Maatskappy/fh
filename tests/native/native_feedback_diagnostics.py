#!/usr/bin/env python3
"""Isolated native CLI regressions; no provider requests or installed state writes."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

LIMIT = 1048576


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--code-profile-template', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix='fh-feedback-cli-') as directory:
        root = Path(directory).resolve()
        profile = root / 'profile'
        profile.mkdir(mode=0o700)
        env = dict(os.environ, FH_DATA_DIR=str(profile), FX_PROVIDER='invalid-provider-no-dispatch')
        package = root / 'infer'
        package.mkdir()
        manifest = {'format': 'loops/0.1', 'name': 'size', 'version': '1',
                    'inputs': {'schema': True}, 'steps': [{'id': 'infer', 'kind': 'infer',
                    'instructions': 'Use bound input', 'input': {'from': '/input'},
                    'output': {'schema': True}}], 'output': {'from': '/steps/infer/output'}}
        (package / 'loop.json').write_text(json.dumps(manifest))
        oversized = root / 'oversized.json'
        with oversized.open('wb') as file:
            file.truncate(LIMIT + 19)

        def run(*arguments):
            return subprocess.run([str(binary), *map(str, arguments)], env=env,
                                  capture_output=True, text=True, timeout=12)

        result = run('run', package, '--input', oversized, '--json')
        assert result.returncode == 2, result
        error = json.loads(result.stdout)['error']
        assert error['code'] == 'invalid_input', error
        assert error['observed_bytes'] == LIMIT + 19 and error['limit_bytes'] == LIMIT, error
        assert error['model_request_dispatches'] == 0 and error['model_request_dispatches_complete'], error
        assert 'smaller JSON input' in error['message'], error
        human = run('run', package, '--input', oversized)
        assert human.returncode == 2 and str(LIMIT + 19) in human.stderr and str(LIMIT) in human.stderr, human
        assert 'smaller JSON input' in human.stderr, human
        fifo = root / 'fifo'
        os.mkfifo(fifo)
        pipe_result = run('run', package, '--input', fifo, '--json')
        assert pipe_result.returncode == 2 and json.loads(pipe_result.stdout)['error']['code'] == 'invalid_input', pipe_result
        malformed = root / 'malformed.json'
        malformed.write_text('{bad')
        invalid = run('run', package, '--input', malformed, '--json')
        assert invalid.returncode == 2 and 'invalid_provider' not in invalid.stdout, invalid
        malformed_error = json.loads(invalid.stdout)['error']
        assert malformed_error['model_request_dispatches'] == 0 and malformed_error['model_request_dispatches_complete'], malformed_error
        exact = root / 'at-limit.json'
        exact.write_bytes(b'null' + b' ' * (LIMIT - 4))
        boundary = run('run', package, '--input', exact, '--json')
        assert boundary.returncode == 2 and json.loads(boundary.stdout)['error']['code'] != 'invalid_input', boundary
        assert not (profile / 'native-runs').exists(), 'Input rejection created durable storage'

        code_result = None
        if args.code_profile_template:
            for name in ('installation.json', 'local.json'):
                source = args.code_profile_template / name
                if source.exists():
                    shutil.copyfile(source, profile / name)
                    (profile / name).chmod(0o600)
            code = root / 'code'
            code.mkdir()
            manifest['name'] = 'code'
            manifest['steps'] = [{'id': 'saved', 'kind': 'code', 'runtime': 'python3',
                                  'file': 'saved.py', 'requires': [], 'input': {'value': {}},
                                  'output': {'schema': True}}]
            manifest['output'] = {'from': '/steps/saved/output'}
            (code / 'loop.json').write_text(json.dumps(manifest))
            (code / 'saved.py').write_text('print("{\\"ready\\":false}")\n')
            output = run('run', code, '--json')
            assert output.returncode == 0, output
            code_result = json.loads(output.stdout)
            assert code_result['status'] == 'completed' and code_result['output'] == {'ready': False}, code_result
            assert code_result['model_request_dispatches'] == 0 and code_result['model_request_dispatches_complete'], code_result
            stored = run('get', code_result['run_id'], '--json')
            stored_result = json.loads(stored.stdout)
            assert stored.returncode == 0 and stored_result['model_request_dispatches'] == 0 and stored_result['model_request_dispatches_complete'], stored
            human_code = run('get', code_result['run_id'])
            assert 'No model requests dispatched.' in human_code.stdout, human_code
            # Seed only this disposable profile with an interrupted fixture.
            orphan = profile / 'native-runs' / 'run_crash.json'
            orphan.write_text(json.dumps({'format': 'fh.native-run/0.1', 'run_id': 'run_crash',
                              'status': 'running', 'model_request_dispatches': 0,
                              'model_request_dispatches_complete': False,
                              'attempts': [{'status': 'running'}]}))
            orphan.chmod(0o600)
            recovered = run('get', 'run_crash')
            assert recovered.returncode == 3 and 'Model request count incomplete.' in recovered.stdout, recovered
            assert 'No model requests dispatched.' not in recovered.stdout, recovered
        print(json.dumps({'oversize_json_human': True, 'fifo_bounded': True,
                          'malformed_no_selection': True, 'no_input_run_created': True,
                          'code_run_get': code_result is not None, 'model_requests': 0}))


if __name__ == '__main__':
    main()
