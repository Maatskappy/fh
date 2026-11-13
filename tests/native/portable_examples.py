#!/usr/bin/env python3
"""Real CLI artifact/compatibility/diagnostic checks; no compiler or source runtime.

The Python interpreter is only the test harness and independent compatibility oracle.
The child fh gets an empty PATH and a private fresh profile.
"""
import argparse, copy, importlib.util, json, os, pathlib, shutil, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--binary', type=pathlib.Path, required=True)
args = p.parse_args()
binary = args.binary.resolve()
spec = importlib.util.spec_from_file_location('old', ROOT/'tests/native/fixtures/workspace-check/suggest-v0.1.py')
old = importlib.util.module_from_spec(spec)
spec.loader.exec_module(old)
old_manifest = json.loads((ROOT/'tests/native/fixtures/workspace-check/loop-v0.1.json').read_text())
# The reference manifest shape is retained independently of the new 0.4 package.
old_manifest['steps'][0]['file'] = 'suggest.py'

def snapshot(packages=(), complete=True, gaps=()):
    return dict(format='fh.workspace-snapshot/0.1', workspace='fixture', markers=[],
                packages=list(packages), complete=complete, gaps=list(gaps))

def package(manifest=old_manifest, **changes):
    result = dict(path='./example', manifest=json.dumps(manifest) if not isinstance(manifest, str) else manifest,
                  state='captured', files=[], inventoryComplete=True)
    result.update(changes)
    return result

fixtures = {
    'empty': snapshot(), 'partial': snapshot(complete=False, gaps=['Permission denied.']),
    'one': snapshot([package()]), 'malformed': snapshot([package('{broken')]),
    'duplicate': snapshot([package('{"format":"loops/0.1","format":"loops/0.1"}')]),
    'nonfinite': snapshot([package('{"x":1e999}')]), 'nan': snapshot([package('{"x":NaN}')]),
    'shape': snapshot([package({})]), 'null': snapshot([package(manifest='null')]),
    'missing': snapshot([package(files=[dict(path='suggest.py', state='missing')])]),
    'unsafe': snapshot([package(files=[dict(path='other', state='unsafe')])]),
    'unreadable': snapshot([package(state='unreadable', manifest=None)]),
    'inventory_partial': snapshot([package(inventoryComplete=False)]),
    'nearby_bound': snapshot([package(path=f'./p{i}') for i in range(12)]),
    'issues_bound': snapshot([package('{broken', path=f'./p{i}') for i in range(12)]),
    'unicode': snapshot([package(dict(old_manifest, name='Café🙂\u00a0\u200b\u202e\x1b\n'), path='./é\x1b[2J')], gaps=['é🙂\t\u2028']),
    'unicode_blank': snapshot([package(dict(old_manifest, name='\u2003\u3000'))]),
    'unicode_length': snapshot([package(dict(old_manifest, name='🙂'*180))]),
    'large_integer': snapshot([package(dict(old_manifest, unused=10**400))]),
    'all_gaps': snapshot([package('{bad') for _ in range(12)], gaps=['x']*32),
}

with tempfile.TemporaryDirectory(prefix='fh-portable-examples-') as temp:
    root = pathlib.Path(temp).resolve()
    (root/'profile').mkdir(mode=0o700)
    env = dict(os.environ, FH_DATA_DIR=str(root/'profile'), PATH='')
    def call(*argv, expected=0):
        r = subprocess.run([str(binary), *map(str, argv)], env=env, capture_output=True, timeout=15)
        assert r.returncode == expected, (argv, r.returncode, r.stdout, r.stderr)
        assert not r.stderr, r.stderr
        return json.loads(r.stdout)
    def run(path, input):
        f = root/'input.json'; f.write_text(json.dumps(input))
        result = call('run', path, '--input', f, '--json')
        assert result['status'] == 'completed', result
        record = call('get', result['run_id'], '--json')
        assert record['output'] == result['output']
        assert record['model_request_dispatches'] == 0 and record['model_request_dispatches_complete'] is True
        assert record['effects'] == []
        assert record['code_executions'][0]['execution']['profile'] == 'wasm32-wasi-json/1'
        return record
    for n in (-1000000, 2, 1000000):
        assert run(ROOT/'loops/increment-wasm', {'number':n})['output'] == {'answer':n+1}
    for name, fixture in fixtures.items():
        actual = run(ROOT/'loops/workspace-check', fixture)['output']
        expected = old.suggest(fixture)
        assert actual == expected, (name, actual, expected)
    # Explicit synthetic expectations for the startup suggestions. These are independent
    # of both the current Wasm implementation and the retained Python oracle.
    startup_cases = [
        (snapshot(), dict(suggestion='Describe a repeatable task and I can help you create a Loop here.',
                          nearbyLoops=[], issues=[], complete=True, gaps=[])),
        (snapshot([package('{broken', path='.')]),
         dict(suggestion='A nearby Loop has an obvious issue. Use /check to inspect it.', nearbyLoops=[],
              issues=[dict(path='.', code='malformed_json', message='loop.json is not strict JSON; use /check for the exact diagnostic.')],
              complete=True, gaps=[])),
    ]
    for fixture, expected in startup_cases:
        assert run(ROOT/'loops/workspace-check', fixture)['output'] == old.suggest(fixture) == expected
    for version in ('0.2', '0.3', '0.4'):
        m = dict(old_manifest, format='loops/'+version)
        actual = run(ROOT/'loops/workspace-check', snapshot([package(m)]))['output']
        assert actual == dict(suggestion='Found nearby Loops. Use /check on a package, then /run when ready.',
                              nearbyLoops=[dict(path='./example', name='workspace-check')], issues=[], complete=True, gaps=[])
    for step in (
        dict(id='parallel', kind='parallel', branches={'one':[old_manifest['steps'][0]]}),
        dict(id='map', kind='map', over=[], steps=[old_manifest['steps'][0]]),
        dict(id='infer', kind='infer', instructions={'file':'prompt.md'}, input=None, output={'schema':True}),
        dict(id='decision', kind='decision', questions={}, input=None, output={'schema':True}),
    ):
        m = dict(old_manifest, format='loops/0.3', steps=[step])
        actual = run(ROOT/'loops/workspace-check', snapshot([package(m)]))['output']
        assert len(actual['nearbyLoops']) == 1 and actual['issues'] == [], actual
    unicode_fixture = json.loads((ROOT/'tests/native/fixtures/workspace-check/unicode-15.json').read_text())
    assert run(ROOT/'loops/workspace-check', unicode_fixture['snapshot'])['output'] == unicode_fixture['expected']
    # The actual new valid package was the independently observed RED regression.
    m = json.loads((ROOT/'loops/workspace-check/loop.json').read_text())
    result = run(ROOT/'loops/workspace-check', snapshot([package(m)]))['output']
    assert result['nearbyLoops'] == [dict(path='./example', name='workspace-check')] and result['issues'] == []
    surrogate = dict(old_manifest, name='\ud800')
    output = run(ROOT/'loops/workspace-check', snapshot([package(surrogate)]))['output']
    assert output['nearbyLoops'] == [] and output['issues'][0]['code'] == 'malformed_json', output
    source = call('check', ROOT/'loops/increment-source', '--json', expected=2)
    assert source['ok'] is False and source['issues'][0]['path'] == 'runtimeProfiles.node', source
    assert 'fh setup runtime node' in source['issues'][0]['message']
    invalid = root/'invalid'; invalid.mkdir()
    m = json.loads((ROOT/'loops/increment-wasm/loop.json').read_text())
    m['steps'][0].update(id='later', file='artifact.wasm')
    m['steps'].insert(0, dict(id='first', kind='infer', instructions='Never called', input=None, output={'schema':True}))
    m['output'] = {'from':'/steps/later/output'}
    (invalid/'loop.json').write_text(json.dumps(m))
    cases = [('random','WasmImport','random_get'), ('bad-signature','WasmImport','signature'),
             ('bad-start','WasmEntrypoint','_start'), ('memory-too-large','WasmMemory','128 MiB'),
             ('table-too-large','WasmTable','table'), ('shared-memory','InvalidWasm','unsupported feature'),
             ('missing-start','WasmEntrypoint','missing _start'), ('missing-memory','WasmMemory','missing memory'),
             ('garbage','InvalidWasm','invalid module'), ('escaped','WasmImport','\\u001b')]
    for fixture, code, reason in cases:
        base_fixture = 'transform' if fixture in ('missing-start', 'missing-memory') else 'wrong-module' if fixture == 'escaped' else fixture
        data = b'garbage' if fixture == 'garbage' else (ROOT/f'native/loops/fixtures/wasm/{base_fixture}.wasm').read_bytes()
        if fixture == 'missing-start': data = data.replace(b'_start', b'absent')
        if fixture == 'missing-memory': data = data.replace(b'memory', b'absent')
        if fixture == 'escaped': data = data.replace(b'host', b'\x1b[2J')
        (invalid/'artifact.wasm').write_bytes(data)
        for command in ('check','run'):
            (root/'input.json').write_text('{"number":2}')
            extra = ('--input', root/'input.json') if command == 'run' else ()
            result = call(command, invalid, *extra, '--json', expected=2)
            issue = result['issues'][0] if command == 'check' else result['error']
            assert issue['code'] == 'execution_failed' and issue['cause'] == code, result
            assert issue['path'] == 'steps.later.file', result
            assert reason in issue['message'] and 'artifact.wasm' in issue['message'] and 'wasm32-wasi-json/1' in issue['message'], result
            assert '\x1b' not in issue['message'], result
    print(json.dumps(dict(compatibility_fixtures=len(fixtures), synthetic_startup_cases=len(startup_cases), unicode15_reference_cases=1, additive_format_cases=8, strict_surrogate_case=1,
                         increment_cases=3, cli_diagnostic_cases=len(cases)*2,
                         missing_source_prerequisite=True, model_dispatches=0, consumer_PATH='empty')))
