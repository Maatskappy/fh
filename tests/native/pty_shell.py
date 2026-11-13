#!/usr/bin/env python3
"""Real native PTY proof; no provider calls. Uses only the Python standard library."""
import argparse
import fcntl
import json
import os
import pathlib
import pty
import re
import select
import signal
import statistics
import struct
import subprocess
import tempfile
import termios
import time

ANSI = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-_])')


def plain(data):
    return ANSI.sub(b'', data).decode('utf-8', 'replace')


class Session:
    def __init__(self, binary, cols, rows, theme, home, baseline=False, wait_ready=True):
        self.master, self.slave = pty.openpty()
        self.before = termios.tcgetattr(self.slave)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        env = dict(os.environ)
        # Only this child sees a disposable HOME. The user's environment is untouched.
        env.update(HOME=str(home), TERM='xterm-256color', FX_THEME=theme,
                   FX_AUTH_MODE='host-managed', FX_PROVIDER='gateway')
        for key in ('FX_BENCH', 'FX_RECORD', 'FX_API_KEY', 'AI_GATEWAY_API_KEY', 'VERCEL_OIDC_TOKEN'):
            env.pop(key, None)
        def child_terminal():
            os.setsid()
        self.raw = bytearray()
        self.started = time.perf_counter()
        self.process = subprocess.Popen([str(binary)], stdin=self.slave,
                                        stdout=self.slave, stderr=subprocess.PIPE,
                                        cwd=str(home), env=env, preexec_fn=child_terminal)
        self.poll_pending = b''
        if wait_ready:
            self.wait_for('Run /help', timeout=5)
            self.startup_ms = (time.perf_counter() - self.started) * 1000
            self.drain(0.15)
            self.initial = bytes(self.raw)

    def drain(self, duration=0.05):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            ready, _, _ = select.select([self.master], [], [], max(0, min(.02, end-time.monotonic())))
            if not ready:
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.raw.extend(chunk)
            probes = self.poll_pending + chunk
            # Answer native cursor-position probes. No startup/theme query waits.
            queries = list(re.finditer(rb'\x1b\[(\?)?6n', probes))
            for query in queries:
                col = 2 if probes[:query.start()].endswith(b'\x1b[2G') else 1
                private = b'?' if query.group(1) else b''
                os.write(self.master, b'\x1b[' + private + b'1;' + str(col).encode() + b'R')
            self.poll_pending = probes[queries[-1].end():][-4:] if queries else probes[-4:]

    def wait_for(self, text, timeout=5, since=0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if text in plain(self.raw[since:]):
                return (time.perf_counter() - self.started) * 1000
            self.drain(.02)
            if self.process.poll() is not None:
                break
        stderr = self.process.stderr.read() if self.process.poll() is not None else b''
        raise AssertionError(f'stderr={stderr!r}; PTY did not show {text!r}; exit={self.process.poll()}; tail={plain(self.raw[-2500:])!r}')

    def send(self, data):
        os.write(self.master, data)

    def resize(self, cols, rows):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        os.kill(self.process.pid, signal.SIGWINCH)
        self.drain(.25)

    def finish(self, sigint=False):
        if sigint:
            os.kill(self.process.pid, signal.SIGINT)
        else:
            self.send(b'/quit\r')
        end = time.monotonic() + 4
        while self.process.poll() is None and time.monotonic() < end:
            self.drain(.03)
        if self.process.poll() is None:
            self.process.kill()
            raise AssertionError('native process did not exit')
        self.drain(.05)
        stderr = self.process.stderr.read()
        after = termios.tcgetattr(self.slave)
        try:
            assert self.process.returncode == 0, (self.process.returncode, stderr)
            assert not stderr, stderr.decode('utf-8', 'replace')
            assert self.before == after, 'native shell did not restore exact termios'
            assert b'\x1b[?2004l' in self.raw, 'bracketed paste mode was not restored'
            assert b'\x1b[?25h' in self.raw, 'cursor was not restored'
        finally:
            os.close(self.master)
            os.close(self.slave)


def fixture_case(binary, output, cols, rows, theme):
    with tempfile.TemporaryDirectory(prefix='fh-pty-') as directory:
        home = pathlib.Path(directory)
        (home/'.fx').mkdir()
        (home/'.fx'/'credential-sentinel').write_text('untouched')
        settings = {'auto_upgrade': False, 'prompt_history': {'enabled': False},
                    'session_titles': False, 'notifications': {'turn_end': False}}
        (home/'.fh').mkdir()
        (home/'.fh'/'settings.json').write_text(json.dumps(settings))
        session = Session(binary, cols, rows, theme, home)
        # Real native bracketed multiline paste remains in the composer.
        session.send(b'\x1b[200~alpha\nbeta\x1b[201~')
        session.wait_for('alpha')
        session.drain(.1)
        assert 'beta' in plain(session.raw), 'multiline paste did not reach inherited composer'
        session.send(b'\x03')  # Native Ctrl-C clears the draft when idle.
        session.drain(.1)
        mark = len(session.raw)
        submitted = time.perf_counter()
        session.send(b'/run\r')
        session.wait_for('Loops fixture', since=mark)
        activity_ms = (time.perf_counter()-submitted)*1000
        session.wait_for('Inspected the deterministic fixture', since=mark)
        first_output_ms = (time.perf_counter()-submitted)*1000
        if cols == 80 and theme == 'dark':
            session.resize(120, 40)
            session.resize(38, 18)
            session.resize(80, 24)
        session.wait_for('Fixture complete', timeout=6, since=mark)
        text = plain(session.raw[mark:])
        for expected in ('Inspected', 'Prepared', 'Verified'):
            assert expected in text, expected
        assert 'run_fixture' not in text, 'raw bridge JSON escaped onto renderer stdout'
        session.finish()
        assert list((home/'.fx').iterdir()) == [home/'.fx'/'credential-sentinel'], 'proof touched fx profile'
        stem = f'{cols}x{rows}-{theme}'
        (output/f'{stem}.ansi').write_bytes(session.raw)
        (output/f'{stem}.txt').write_text(plain(session.raw))
        return {'size': f'{cols}x{rows}', 'theme': theme, 'startup_ms': round(session.startup_ms, 3),
                'submit_to_activity_ms': round(activity_ms, 3),
                'submit_to_first_output_ms': round(first_output_ms, 3),
                'fixture_first_output_scheduled_ms': 700, 'restored': True}


def cancellation(binary, output, sigint=False):
    with tempfile.TemporaryDirectory(prefix='fh-cancel-') as directory:
        session = Session(binary, 80, 24, 'dark', pathlib.Path(directory))
        session.send(b'/run\r')
        session.wait_for('Inspected the deterministic fixture')
        started = time.perf_counter()
        if sigint:
            session.finish(sigint=True)
            label = 'sigint'
        else:
            mark = len(session.raw)
            session.send(b'\x03')
            session.wait_for('Fixture cancelled', since=mark, timeout=1)
            acknowledged_ms = (time.perf_counter()-started)*1000
            session.drain(.9)
            assert 'Prepared' not in plain(session.raw[mark:]), 'cancelled source kept streaming'
            session.send(b'/run\r')
            session.wait_for('Fixture complete', timeout=6, since=mark)
            session.finish()
            label = 'cancel-and-rerun'
        (output/f'{label}.ansi').write_bytes(session.raw)
        return {'case': label, 'elapsed_ms': round((time.perf_counter()-started)*1000, 3),
                'cancel_acknowledgement_ms': None if sigint else round(acknowledged_ms, 3), 'restored': True}


def startup_sigint(binary, output):
    with tempfile.TemporaryDirectory(prefix='fh-startup-sigint-') as directory:
        session = Session(binary, 80, 24, 'dark', pathlib.Path(directory), wait_ready=False)
        deadline = time.monotonic() + 3
        while termios.tcgetattr(session.slave)[3] & termios.ICANON:
            assert time.monotonic() < deadline, 'startup never enabled raw mode'
            session.drain(.001)
        session.finish(sigint=True)
        (output/'startup-sigint.ansi').write_bytes(session.raw)
        return {'case': 'sigint-during-raw-startup', 'restored': True}


def timings(binary, baseline):
    values = {}
    for arg in ('help', '--version'):
        expected = subprocess.check_output([str(baseline), arg])
        actual = subprocess.check_output([str(binary), arg])
        assert (b'Native Loops shell proof' in actual if arg == 'help' else actual == b'fh 0.1.0\n'), f'native {arg} fastpath changed'
        for name, exe in (('upstream', baseline), ('fh', binary)):
            samples = []
            for _ in range(11):
                start = time.perf_counter_ns()
                subprocess.run([str(exe), arg], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
                samples.append((time.perf_counter_ns()-start)/1_000_000)
            values[f'{name}_{arg}'] = {'median_ms': round(statistics.median(samples), 3),
                                      'min_ms': round(min(samples), 3), 'max_ms': round(max(samples), 3),
                                      'samples_ms': [round(x,3) for x in samples]}
    return values


def compare_input(binary, baseline, output):
    values = {}
    for name, exe in (('upstream', baseline), ('fh', binary)):
        starts = []
        with tempfile.TemporaryDirectory(prefix='fh-compare-') as directory:
            home = pathlib.Path(directory)
            for profile in ('.fx', '.fh'):
                (home/profile).mkdir()
                (home/profile/'settings.json').write_text(json.dumps({'auto_upgrade': False,
                    'prompt_history': {'enabled': False}, 'session_titles': False}))
            for index in range(5):
                session = Session(exe, 80, 24, 'dark', home, baseline=name=='upstream')
                starts.append(session.startup_ms)
                if index == 0:
                    session.send(b'composer-fixture')
                    session.wait_for('composer-fixture')
                    session.send(b'\x03')
                    session.drain(.15)
                    session.send(b'/help\r')
                    session.drain(.25)
                    values[name+'_capture'] = plain(session.raw)
                    (output/f'{name}-inherited-input.ansi').write_bytes(session.raw)
                session.finish()
        values[name+'_startup'] = {'median_ms': round(statistics.median(starts), 3),
                                  'samples_ms': [round(x,3) for x in starts]}
    # Shared composer, native footer hints, and slash help must retain their words.
    for token in ('composer-fixture', '/help', '/clear'):
        assert token in values['upstream_capture'] and token in values['fh_capture'], token
    return {key:value for key,value in values.items() if not key.endswith('_capture')}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    parser.add_argument('--baseline', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    binary, baseline = args.binary.resolve(), args.baseline.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    cases = [fixture_case(binary, args.output, cols, rows, theme)
             for cols,rows in ((80,24),(120,40),(38,18)) for theme in ('dark','light')]
    cases += [cancellation(binary, args.output), cancellation(binary, args.output, sigint=True),
              startup_sigint(binary, args.output)]
    result = {'cases': cases, 'fastpaths': timings(binary, baseline),
              'inherited_input': compare_input(binary, baseline, args.output),
              'timing_scope': 'Fresh processes on the same macOS machine; OS page caches were not flushed. Python spawn and PTY harness overhead included. First-launch outliers retained. Fixture pacing is intentional; no model latency measured.'}
    (args.output/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
