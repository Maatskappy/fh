#!/usr/bin/env python3
"""Controlled transport integration (not browser rendering evidence)."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
import zlib


def png():
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\x00\x18\x63\xb0')) + chunk(b'IEND', b'')


def frame(data, opcode=1, final=True):
    data = data.encode() if isinstance(data, str) else data
    first = opcode | (128 if final else 0)
    if len(data) < 126:
        return bytes([first, len(data)]) + data
    if len(data) < 65536:
        return bytes([first, 126]) + struct.pack('!H', len(data)) + data
    return bytes([first, 127]) + struct.pack('!Q', len(data)) + data


def exact(conn, size):
    data = b''
    while len(data) < size:
        part = conn.recv(size - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def receive(conn):
    first, second = exact(conn, 2)
    assert second & 128, 'client must mask every frame'
    length = second & 127
    if length == 126:
        length = struct.unpack('!H', exact(conn, 2))[0]
    if length == 127:
        length = struct.unpack('!Q', exact(conn, 8))[0]
    assert length <= 16 * 1048576
    mask = exact(conn, 4)
    body = exact(conn, length)
    return first & 15, bytes(c ^ mask[i % 4] for i, c in enumerate(body))


class Fixture:
    def __init__(self):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen()
        self.port = self.listener.getsockname()[1]
        self.count = 0
        self.methods = []
        self.connections = []
        self.stop = threading.Event()
        self.errors = []
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            self.count += 1
            self.connections.append(conn)
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        try:
            conn.settimeout(4)
            head = b''
            while b'\r\n\r\n' not in head:
                head += conn.recv(4096)
                # TLS ClientHello deliberately receives no response.
                if head.startswith(b'\x16'):
                    self.stop.wait(4)
                    return
            path = head.split(b' ')[1].decode()
            if path.startswith('/reject'):
                conn.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
                return
            if path.startswith('/badaccept'):
                accept = 'incorrect'
            else:
                headers = dict(line.split(b':', 1) for line in head.split(b'\r\n')[1:] if b':' in line)
                key = headers[b'Sec-WebSocket-Key'].strip()
                accept = base64.b64encode(hashlib.sha1(key + b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest()).decode()
            conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
            if path.startswith('/oversize'):
                conn.sendall(b'\x81\x7f' + struct.pack('!Q', 16 * 1048576 + 1))
                return
            if path.startswith('/protocol'):
                conn.sendall(b'\xc1\x00')
                return
            if path.startswith('/close'):
                conn.sendall(frame(struct.pack('!H', 1000), opcode=8))
                return
            while not self.stop.is_set():
                opcode, body = receive(conn)
                if opcode in (8, 10):
                    if opcode == 8:
                        return
                    continue
                request = json.loads(body)
                method = request['method']
                self.methods.append((path, method, request.get('sessionId')))
                if path.startswith('/hang') and method != 'Target.closeTarget':
                    self.stop.wait(4)
                    return
                if path.startswith('/command') and method == 'Page.enable':
                    self.reply(conn, request, error={'code': -32601, 'message': 'unsupported secret-fixture-token'})
                    continue
                if path.startswith('/command-cleanup') and method == 'Target.closeTarget':
                    self.reply(conn, request, error={'code': -1, 'message': 'CLEANUP_ERROR_' + 'X' * 1000})
                    continue
                result = {}
                if method == 'Browser.getVersion':
                    result = {'product': 'controlled-fixture', 'protocolVersion': '1.3'}
                elif method == 'Target.createTarget':
                    result = {'targetId': 'owned-target'}
                elif method == 'Target.attachToTarget':
                    result = {'sessionId': 'owned-session'}
                elif method == 'Page.navigate':
                    events = [
                        ('Network.requestWillBeSent', {'requestId': 'redirect', 'request': {'url': 'http://fixture/a', 'method': 'GET'}}),
                        ('Network.requestWillBeSent', {'requestId': 'redirect', 'redirectResponse': {'status': 302, 'headers': {}}, 'request': {'url': 'http://fixture/b', 'method': 'GET'}}),
                        ('Network.responseReceived', {'requestId': 'redirect', 'response': {'status': 200, 'headers': {'content-type': 'text/plain'}}}),
                        ('Network.loadingFinished', {'requestId': 'redirect', 'encodedDataLength': 4}),
                        ('Network.requestWillBeSent', {'requestId': 'empty', 'request': {'url': 'http://fixture/empty', 'method': 'GET'}}),
                        ('Network.responseReceived', {'requestId': 'empty', 'response': {'status': 204, 'headers': {}}}),
                        ('Network.loadingFinished', {'requestId': 'empty', 'encodedDataLength': 0}),
                        ('Network.requestWillBeSent', {'requestId': 'failed', 'request': {'url': 'http://fixture/fail', 'method': 'GET'}}),
                        ('Network.loadingFailed', {'requestId': 'failed', 'errorText': 'socket disconnected'}),
                        ('Network.requestWillBeSent', {'requestId': 'pending', 'request': {'url': 'http://fixture/pending', 'method': 'GET'}}),
                    ]
                    for event, params in events:
                        self.message(conn, {'method': event, 'params': params, 'sessionId': 'owned-session'})
                    result = {'frameId': 'frame', 'loaderId': 'loader'}
                elif method == 'Runtime.evaluate':
                    expr = request['params']['expression']
                    if expr == 'void 0':
                        result = {'result': {'type': 'undefined'}}
                    elif expr == 'null':
                        result = {'result': {'type': 'object', 'subtype': 'null', 'value': None}}
                    elif expr == 'fixture-dom-object':
                        result = {'result': {'type': 'object', 'subtype': 'node', 'objectId': 'node'}}
                    elif expr == 'throw-fixture':
                        result = {'exceptionDetails': {'text': 'explicit evaluation failure'}}
                    else:
                        value = {'title': 'Fixture'} if 'title' in expr else True
                        result = {'result': {'type': 'object' if isinstance(value, dict) else 'boolean', 'value': value}}
                elif method == 'Page.captureScreenshot':
                    result = {'data': base64.b64encode(png()).decode()}
                    if path.startswith('/badpng'):
                        result = {'data': 'not base64!!'}
                elif method == 'Network.getResponseBody':
                    result = {'body': '' if request['params']['requestId'] == 'empty' else ('x' * 100000 if path.startswith('/longbody') else 'body'), 'base64Encoded': False}
                elif method == 'Target.closeTarget':
                    assert request['params']['targetId'] == 'owned-target'
                    result = {'success': not path.startswith('/cleanup-false')}
                self.reply(conn, request, result=result)
        except (EOFError, ConnectionError, socket.timeout, OSError):
            pass
        except Exception as exc:
            self.errors.append(repr(exc))
        finally:
            conn.close()

    def reply(self, conn, request, **payload):
        reply = dict(id=request['id'], **payload)
        if 'sessionId' in request:
            reply['sessionId'] = request['sessionId']
        self.message(conn, reply)

    def message(self, conn, payload):
        body = json.dumps(payload).encode()
        midpoint = len(body) // 2
        wire = frame(body[:midpoint], final=False) + frame(b'ping', opcode=9) + frame(body[midpoint:], opcode=0)
        conn.sendall(wire[:3])
        conn.sendall(wire[3:])

    def close(self):
        self.stop.set()
        self.listener.close()
        for conn in self.connections:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', nargs='?', default='zig-out/bin/fh')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    fixture = Fixture()
    cases = []
    with tempfile.TemporaryDirectory(prefix='fh-capture-test-') as tmp:
        root = Path(tmp).resolve()
        canonical = {'version': 'fh.capture/0.1', 'url': 'http://fixture/', 'timeout_ms': 1000, 'checkpoints': [{'id': 'loaded', 'wait': 'true', 'evaluate': '({title: document.title})', 'screenshot': True}]}
        plan = root / 'plan.json'
        plan.write_text(json.dumps(canonical))
        def run(name, route='/ok', document=None, extra=(), env=None, expected=0):
            source = plan
            if document is not None:
                source = root / (name + '.json')
                source.write_text(json.dumps(document))
            dest = root / name
            started = time.monotonic()
            cp = subprocess.run([binary, 'capture', str(source), '--cdp', f'ws://127.0.0.1:{fixture.port}{route}?private-query=secret', '--out', str(dest), '--json', *extra], capture_output=True, text=True, timeout=5, env=env)
            elapsed = time.monotonic() - started
            assert cp.returncode == expected, (name, cp.returncode, cp.stdout, cp.stderr, fixture.methods, fixture.errors)
            receipt = json.loads(cp.stdout)
            assert 'private-query' not in cp.stdout and '?private' not in cp.stdout
            if cp.returncode != 2 and (dest / 'capture.json').exists():
                assert json.loads((dest / 'capture.json').read_text()) == receipt
                assert (dest / 'capture.json').stat().st_mode & 0o077 == 0
            cases.append({'case': name, 'seconds': round(elapsed, 4), 'exit': cp.returncode, 'timings': receipt.get('timings')})
            return receipt, dest
        before = fixture.count
        for name, changes in [('bad-id', {'checkpoints': [{'id': '../escape'}]}), ('bad-key', {'unknown': 1}), ('bad-time', {'timeout_ms': 60001}), ('no-checkpoint', {'checkpoints': []}), ('bad-url', {'url': 'http://user:secret@localhost/'})]:
            run(name, document=dict(canonical, **changes), expected=2)
        assert fixture.count == before, 'invalid plans must create zero connections'
        good, dest = run('success')
        assert good['status'] == 'completed' and good['browser']['product'] == 'controlled-fixture'
        assert good['plan_sha256'] == hashlib.sha256(plan.read_bytes()).hexdigest()
        assert good['target_cleanup'] == 'closed'
        assert (dest / 'loaded.png').read_bytes() == png()
        assert not good['evidence_complete'] and good['network_receipts_complete']
        network = good['network']
        assert len(network) == 5 and [r['redirect_hop'] for r in network[:2]] == [0, 1]
        empty = next(r for r in network if r['request_id'] == 'empty')
        assert empty['body'] == '' and empty['body_state'] == 'retrieved' and empty['state'] == 'finished'
        assert next(r for r in network if r['request_id'] == 'failed')['body_state'] == 'failed'
        assert next(r for r in network if r['request_id'] == 'pending')['body_state'] == 'pending'
        sessions = [session for path, method, session in fixture.methods if path.startswith('/ok') and method.startswith(('Page.', 'Runtime.', 'Network.', 'Emulation.'))]
        assert set(sessions) == {'owned-session'}
        count = fixture.count
        run('success', expected=2)
        assert fixture.count == count, 'collision must precede connection'
        for name, route, code in [('rejected', '/reject', 'UpgradeRejected'), ('badaccept', '/badaccept', 'WebSocketProtocol'), ('oversize', '/oversize', 'MessageLimit'), ('protocol', '/protocol', 'WebSocketProtocol'), ('close', '/close', 'Disconnected'), ('badpng', '/badpng', 'InvalidScreenshot')]:
            receipt, _ = run(name, route=route, expected=1)
            assert receipt['error'] == code, (name, receipt)
        receipt, _ = run('cleanup-false', route='/cleanup-false', expected=1)
        assert receipt['error'] == 'TargetCleanupRejected' and receipt['target_cleanup'] == 'failed'
        env = dict(os.environ, CAPTURE_FIXTURE_TOKEN='secret-fixture-token')
        receipt, _ = run('command', route='/command', expected=1, extra=('--token-env', 'CAPTURE_FIXTURE_TOKEN'), env=env)
        assert receipt['error'] == 'CdpCommand' and '[REDACTED]' in receipt['command_error']
        assert 'secret-fixture-token' not in json.dumps(receipt)
        receipt, _ = run('double-failure', route='/command-cleanup', expected=1, extra=('--token-env', 'CAPTURE_FIXTURE_TOKEN'), env=env)
        expected_detail = 'Page.enable: {"code":-32601,"message":"unsupported [REDACTED]"}'
        assert receipt['command_error'] == expected_detail, repr(receipt['command_error'])
        assert receipt['error'] == 'CdpCommand' and receipt['error_stage'] == 'setup'
        assert receipt['cleanup_error'] == 'CdpCommand' and receipt['target_cleanup'] == 'failed'
        assert 'secret-fixture-token' not in json.dumps(receipt)
        receipt, _ = run('undefined-evaluation', document=dict(canonical, checkpoints=[{'id': 'undefined', 'evaluate': 'void 0'}]), expected=1)
        assert receipt['error'] == 'EvaluationNotJson' and receipt['checkpoints'][0]['error'] == 'EvaluationNotJson'
        receipt, _ = run('null-evaluation', document=dict(canonical, checkpoints=[{'id': 'null', 'evaluate': 'null'}]))
        assert receipt['status'] == 'completed' and receipt['checkpoints'][0]['result'] is None
        assert 'error' not in receipt['checkpoints'][0]
        receipt, _ = run('longbody', route='/longbody')
        retained = next(r for r in receipt['network'] if r['request_id'] == 'redirect' and r['redirect_hop'] == 1)
        assert retained['body_state'] == 'truncated' and len(retained['body']) == 65536 and retained['body_bytes'] == 100000
        receipt, _ = run('action-object', document=dict(canonical, checkpoints=[{'id': 'action', 'action': 'fixture-dom-object'}]))
        assert receipt['checkpoints'][0]['action_kind'] == 'page_evaluation'
        receipt, _ = run('evaluation', document=dict(canonical, checkpoints=[{'id': 'bad', 'evaluate': 'throw-fixture'}]), expected=1)
        assert receipt['checkpoints'][0]['error'] == 'PageEvaluation' and receipt['target_cleanup'] == 'closed'
        receipt, _ = run('deadline', route='/hang', document=dict(canonical, timeout_ms=100), expected=1)
        assert receipt['error'] == 'CaptureDeadline' and receipt['timings']['setup_ms'] >= 50
        source = root / 'source.txt'
        source.write_text('bounded local source')
        receipt, _ = run('sources', document=dict(canonical, sources=['source.txt']))
        assert receipt['sources'][0]['changed'] is False and receipt['freshness'] == 'not_established'
        cancel_dest = root / 'cancel'
        proc = subprocess.Popen([binary, 'capture', str(plan), '--cdp', f'ws://127.0.0.1:{fixture.port}/hang', '--out', str(cancel_dest), '--json'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(.15)
        proc.send_signal(signal.SIGINT)
        stdout, stderr = proc.communicate(timeout=2)
        assert proc.returncode == 130 and json.loads(stdout)['status'] == 'cancelled', (stdout, stderr)
        cases.append({'case': 'SIGINT hanging CDP', 'exit': 130})
        tls_plan = root / 'tls.json'
        tls_plan.write_text(json.dumps(dict(canonical, timeout_ms=100)))
        cp = subprocess.run([binary, 'capture', str(tls_plan), '--cdp', f'wss://127.0.0.1:{fixture.port}/', '--out', str(root / 'tls'), '--json'], capture_output=True, text=True, timeout=2)
        assert cp.returncode == 1 and json.loads(cp.stdout)['error'] == 'CaptureDeadline', (cp.stdout, cp.stderr)
        cases.append({'case': 'hanging TLS deadline', 'exit': 1})
        assert not fixture.errors, fixture.errors
    fixture.close()
    print(json.dumps({'fixture_only': True, 'passed': len(cases), 'cases': cases}, indent=2))


if __name__ == '__main__':
    main()
