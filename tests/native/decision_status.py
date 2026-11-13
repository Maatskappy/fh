#!/usr/bin/env python3
"""Jev status proof using disposable profiles and synthetic keys; no HTTP fixtures."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from native_onboarding import Terminal


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    binary = parser.parse_args().binary.resolve()
    with tempfile.TemporaryDirectory(prefix='fh-jev-status-', dir='/private/tmp') as directory:
        home = Path(directory)
        root = home / 'profile'
        root.mkdir(mode=0o700)
        env = {k: v for k, v in os.environ.items()
               if not any(x in k.upper() for x in ('KEY', 'TOKEN', 'OAUTH', 'OIDC'))
               and not k.startswith(('FX_', 'FH_'))}
        env.update(HOME=str(home), FH_DATA_DIR=str(root), FX_DISABLE_KEYCHAIN='1')
        secrets = ['synthetic-saved-jev-secret', 'synthetic-env-jev-secret']

        def status(presence, source, overrides=None, key_env='TYPESAFE_API_KEY'):
            result = subprocess.run([str(binary), 'status', '--json'], cwd=home,
                                    env=dict(env, **(overrides or {})), capture_output=True,
                                    text=True, timeout=20)
            assert result.returncode == 0, result.stderr
            assert all(secret not in result.stdout + result.stderr for secret in secrets)
            assert result.stdout.count('\n') == 1
            value = json.loads(result.stdout)
            jev = value['jev']
            assert jev['credential_presence'] == presence, jev
            assert jev['credential_source'] == source, jev
            assert jev['access'] == 'not_checked', jev
            assert jev['api_key_env'] == key_env, jev
            assert value['kind'] == 'status' and 'auth' in value and 'model' in value
            return jev

        status('missing', 'none')
        installation = root / 'installation.json'
        policy = {'version': 1, 'bindings': {'local': {'id': 'local'}}, 'decision': None}
        installation.write_text(json.dumps(policy))
        installation.chmod(0o600)
        before = installation.read_bytes()
        keys = root / 'keys'
        keys.mkdir(mode=0o700)
        saved = keys / 'TYPESAFE_API_KEY'
        saved.write_text(secrets[0])
        saved.chmod(0o600)
        status('present', 'saved')
        status('present', 'environment', {'TYPESAFE_API_KEY': secrets[1]})
        status('unknown', 'unknown', {'TYPESAFE_API_KEY': 'invalid override'})
        saved.chmod(0o644)
        status('unknown', 'unknown')
        saved.chmod(0o600)
        assert installation.read_bytes() == before
        policy['decision'] = {'provider': 'typesafe', 'model': 'custom-jev', 'apiKeyEnv': 'CUSTOM_JEV_KEY'}
        installation.write_text(json.dumps(policy))
        custom = keys / 'CUSTOM_JEV_KEY'
        policy_before = installation.read_bytes()
        terminal = Terminal(binary, ['setup', 'jev'], home)
        terminal.answer('API key (hidden; Esc cancels):', secrets[0])
        terminal.finish()
        assert secrets[0] not in terminal.text()
        assert custom.read_text() == secrets[0]
        assert custom.stat().st_mode & 0o777 == 0o600
        assert installation.read_bytes() == policy_before
        assert status('present', 'saved', key_env='CUSTOM_JEV_KEY')['model'] == 'custom-jev'
        status('present', 'environment', {'CUSTOM_JEV_KEY': secrets[1]}, key_env='CUSTOM_JEV_KEY')
        text = subprocess.run([str(binary), 'status'], cwd=home, env=env,
                              capture_output=True, text=True, timeout=20)
        assert text.returncode == 0 and 'jev_credential=present' in text.stdout
        assert 'access=not_checked' in text.stdout and 'CUSTOM_JEV_KEY' in text.stdout
        assert all(secret not in text.stdout + text.stderr for secret in secrets)
        assert saved.read_text() == secrets[0] and custom.read_text() == secrets[0]
        installation.unlink()
        os.mkfifo(installation, mode=0o600)
        started = time.monotonic()
        fifo = subprocess.run([str(binary), 'status', '--json'], cwd=home,
                              env=dict(env, TYPESAFE_API_KEY=secrets[1]),
                              capture_output=True, text=True, timeout=2)
        assert time.monotonic() - started < 2, 'FIFO policy must not block status'
        assert fifo.returncode == 0, fifo.stderr
        fifo_value = json.loads(fifo.stdout)
        assert fifo_value['kind'] == 'status' and 'auth' in fifo_value and 'model' in fifo_value
        unknown = fifo_value['jev']
        assert unknown['credential_presence'] == 'unknown', unknown
        assert unknown['credential_source'] == 'unknown', unknown
        assert unknown['provider'] is None and unknown['api_key_env'] is None, unknown
        assert all(secret not in fifo.stdout + fifo.stderr for secret in secrets)
        assert not (root / 'native-runs').exists(), 'status must not dispatch a run'
    print('PASS: Jev missing/saved/environment/unknown/custom/null/FIFO status and masking')


if __name__ == '__main__':
    main()
