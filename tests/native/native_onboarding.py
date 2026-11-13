#!/usr/bin/env python3
"""Native onboarding, chat and infer proof using only disposable profiles/local HTTP."""
import argparse
import hashlib
import fcntl
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import termios
import threading
import time

CHILDREN = []
KEY = 'synthetic-onboarding-key-' + 'x'*180
JEV = 'synthetic-jev-key'
ANSI = re.compile(rb'\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|[@-_])')

def environment(home):
    env = {k: v for k, v in os.environ.items() if not any(x in k.upper() for x in ('API_KEY', 'OAUTH', 'OIDC', 'ACCESS_TOKEN')) and not k.startswith(('FX_', 'FH_AI_'))}
    env.update(HOME=str(home), FH_DATA_DIR=str(home/'profile'), FX_DISABLE_KEYCHAIN='1', TERM='xterm-256color')
    return env

class Terminal:
    def __init__(self, binary, args, home, overrides=None):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH',30,100,0,0))
        self.before = termios.tcgetattr(self.slave)
        self.raw = bytearray()
        self.pending = b''
        self.child = subprocess.Popen([str(binary), *args], stdin=self.slave, stdout=self.slave, stderr=self.slave, cwd=home, env=dict(environment(home), **(overrides or {})), start_new_session=True)
        CHILDREN.append(self.child)
    def drain(self, duration=.03):
        end = time.monotonic()+duration
        while time.monotonic() < end:
            if not select.select([self.master], [], [], .01)[0]: continue
            try: chunk = os.read(self.master, 65536)
            except OSError: break
            self.raw.extend(chunk)
            probe = self.pending+chunk
            for match in re.finditer(rb'\x1b\[(\?)?6n', probe):
                os.write(self.master, b'\x1b['+(b'?' if match.group(1) else b'')+b'1;1R')
            self.pending = probe[-4:]
    def text(self): return ANSI.sub(b'', self.raw).decode('utf-8', 'replace')
    def wait(self, text, since=0, timeout=15):
        end = time.monotonic()+timeout
        while time.monotonic()<end:
            if text in ANSI.sub(b'', self.raw[since:]).decode('utf-8', 'replace'): return
            self.drain()
            if self.child.poll() is not None: break
        raise AssertionError('Missing prompt '+repr(text)+'; tail='+repr(self.text()[-1800:]))
    def answer(self, prompt, value):
        self.wait(prompt)
        self.drain(.05)  # Let the masked reader enter raw mode before submitting.
        os.write(self.master, value.encode()+b'\r')
    def finish(self, expected=0):
        end=time.monotonic()+15
        while self.child.poll() is None and time.monotonic()<end: self.drain()
        if self.child.poll() is None:
            self.child.kill(); self.child.wait(); raise AssertionError('PTY process timed out')
        self.drain()
        assert self.child.returncode == expected, (self.child.returncode, self.text()[-1600:])
        assert termios.tcgetattr(self.slave) == self.before, 'TTY attributes not restored'
        assert KEY not in self.text() and JEV not in self.text(), 'masked key echoed'
        os.close(self.master); os.close(self.slave)

class Fixture(BaseHTTPRequestHandler):
    requests = []
    def log_message(self, *args): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.requests.append({'path':self.path, 'authorization':self.headers.get('Authorization'), 'body':body})
        infer = not body.get('tools')
        content = '{"answer":"fixture answer"}' if infer else 'fixture chat answer'
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        for frame in [ {'choices':[{'index':0,'delta':{'role':'assistant','content':content},'finish_reason':None}]}, {'choices':[{'index':0,'delta':{},'finish_reason':'stop'}], 'usage':{'prompt_tokens':11,'completion_tokens':7,'total_tokens':18}}, {'choices':[], 'usage':{'prompt_tokens':11,'completion_tokens':7,'total_tokens':18}} ]:
            self.wfile.write(('data: '+json.dumps(frame)+'\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('dist/fh'))
    parser.add_argument('--evidence', type=Path)
    args=parser.parse_args(); binary=args.binary.resolve()
    operator_settings=Path.home()/'.fh/settings.json'
    operator_before=hashlib.sha256(operator_settings.read_bytes()).hexdigest() if operator_settings.is_file() else None
    report={'format':'fh.native-onboarding/0.1','success':False,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'cases':[],'provider':'loopback HTTP fixture only'}
    server=ThreadingHTTPServer(('127.0.0.1',0),Fixture)
    thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='fh-onboarding-',dir='/private/tmp') as directory:
            owned=Path(directory); owned.chmod(0o700)
            def home(name):
                p=owned/name; p.mkdir(mode=0o700); (p/'profile').mkdir(mode=0o700); return p
            def command(h,*argv,overrides=None):
                return subprocess.run([str(binary),*map(str,argv)],env=dict(environment(h),**(overrides or {})),cwd=h,capture_output=True,text=True,timeout=30)
            h=home('connected')
            terminal=Terminal(binary,['setup'],h)
            for prompt,value in [('Choose [1]:','3'),('Connection name [api]:',''),('API base URL [https://api.openai.com/v1]:',f'http://127.0.0.1:{server.server_port}/v1'),('Model ID:','fixture-model'),('API key (hidden; Esc cancels):',KEY),('Add a Jev key','n')]: terminal.answer(prompt,value)
            terminal.finish()
            settings=(h/'profile/settings.json').read_bytes()
            assert KEY.encode() not in settings
            keys=list((h/'profile/keys').iterdir()); assert len(keys)==1
            assert keys[0].read_text()==KEY and keys[0].stat().st_mode & 0o777 == 0o600
            report['cases'].append('setup route and private masked key')
            terminal=Terminal(binary,[],h); terminal.wait('Run /help'); terminal.answer('Run /help','hi')
            terminal.wait('fixture chat answer'); os.write(terminal.master,b'/quit\r'); terminal.finish()
            assert len(Fixture.requests)==1 and Fixture.requests[0]['body'].get('tools')
            report['cases'].append('configured native chat advertises tools')
            terminal=Terminal(binary,['setup','jev'],h); terminal.answer('API key (hidden; Esc cancels):',JEV); terminal.finish()
            assert (h/'profile/keys/TYPESAFE_API_KEY').read_text()==JEV and (h/'profile/settings.json').read_bytes()==settings
            terminal=Terminal(binary,['setup','jev'],h); terminal.answer('Replace this key? [y/N]','n'); terminal.finish()
            assert (h/'profile/keys/TYPESAFE_API_KEY').read_text()==JEV and len(Fixture.requests)==1
            report['cases'].append('Jev standalone and replacement declined preserve AI route')
            gateway_env=home('gateway-env')
            terminal=Terminal(binary,['setup','ai'],gateway_env,{'AI_GATEWAY_API_KEY':KEY})
            terminal.answer('Choose [1]:','4'); terminal.finish()
            env_settings=json.loads((gateway_env/'profile/settings.json').read_text())
            assert env_settings.get('provider')=='gateway' and env_settings.get('credential_source')=='ai_gateway_api_key',env_settings
            assert len(Fixture.requests)==1
            report['cases'].append('environment Gateway credential-only Keep current')
            gateway_home=home('gateway-store')
            root_a=gateway_home/'profile'; root_b=gateway_home/'profile-b'; root_b.mkdir(mode=0o700)
            # macOS Keychain belongs to the OS home. FH_DATA_DIR still isolates
            # all fh settings, history and uniquely scoped synthetic items.
            native_overrides={'HOME':os.environ['HOME'] if os.uname().sysname=='Darwin' else str(gateway_home),'FX_DISABLE_KEYCHAIN':'0' if os.uname().sysname=='Darwin' else '1'}
            service='FH_API_KEY_V1_'+hashlib.sha256(str(root_a).encode()).hexdigest()+'_AI_GATEWAY_API_KEY'
            try:
                terminal=Terminal(binary,['setup','ai'],gateway_home,native_overrides)
                terminal.answer('Choose [1]:','2')
                terminal.answer('Vercel AI Gateway key (hidden; Esc cancels):',KEY)
                terminal.answer('Gateway model ID [','fixture-gateway-model'); terminal.finish()
                assert not (gateway_home/'.fh').exists()
                terminal=Terminal(binary,['setup','ai'],gateway_home,dict(native_overrides,AI_GATEWAY_API_KEY=''))
                terminal.answer('Choose [1]:','2'); terminal.answer('Gateway model ID [','fixture-gateway-model'); terminal.finish()
                assert json.loads((root_a/'settings.json').read_text())['credential_source']=='stored_key'
                terminal=Terminal(binary,['setup','ai'],gateway_home,dict(native_overrides,FH_DATA_DIR=str(root_b)))
                terminal.answer('Choose [1]:','2'); terminal.wait('Vercel AI Gateway key (hidden; Esc cancels):'); terminal.drain(.05)
                os.write(terminal.master,b'\x1b'); terminal.finish(130)
                assert not list(root_b.iterdir()) and not (gateway_home/'.fh').exists()
                assert len(Fixture.requests)==1
                report['cases'].append('native Gateway stored key isolated across profiles; empty environment preserves saved source')
            finally:
                if os.uname().sysname=='Darwin':
                    cleanup=subprocess.run(['/usr/bin/security','delete-generic-password','-s',service,'-a',os.environ['USER']],capture_output=True)
                    assert cleanup.returncode in (0,44), 'Owned scoped Gateway service cleanup failed'

            fresh=home('fresh'); terminal=Terminal(binary,[],fresh)
            terminal.answer('Choose [1]:','5'); terminal.answer('Add a Jev key','n'); terminal.wait('Run /help'); os.write(terminal.master,b'/quit\r'); terminal.finish()
            terminal=Terminal(binary,[],fresh); terminal.wait('Run /help'); assert 'Choose [1]:' not in terminal.text(); os.write(terminal.master,b'/quit\r'); terminal.finish()
            report['cases'].append('fresh launch offers setup; skip and repeat launch reach welcome')
            nonterminal=home('nonterminal'); rejected=command(nonterminal,'setup'); assert rejected.returncode!=0 and not list((nonterminal/'profile').iterdir())
            cancel=home('cancel'); terminal=Terminal(binary,['setup','jev'],cancel); terminal.wait('API key (hidden; Esc cancels):'); terminal.drain(.05); os.write(terminal.master,b'\x1b'); terminal.finish(130)
            assert not list((cancel/'profile').rglob('*'))
            report['cases'].append('nonterminal refuses without writes; Esc restores TTY without key')
            package=owned/'package'; package.mkdir()
            schema=lambda field:{'type':'object','required':[field],'properties':{field:{'type':'string'}},'additionalProperties':False}
            manifest={'format':'loops/0.1','name':'onboarding-proof','version':'1.0.0','inputs':{'schema':schema('task')},'steps':[{'id':'answer','kind':'infer','requires':[],'input':{'from':'/input'},'instructions':'Answer the supplied task as JSON.','output':{'schema':schema('answer')}}],'output':{'from':'/steps/answer/output'}}
            (package/'loop.json').write_text(json.dumps(manifest))
            inputfile=owned/'input.json'; inputfile.write_text('{"task":"unique_loop_task"}')
            checked=command(h,'check',package,'--bindings-id','local','--json'); assert checked.returncode==0,checked.stderr
            assert len(Fixture.requests)==1
            bad=owned/'bad.json'; bad.write_text('{"task":12}')
            invalid=command(h,'run',package,'--input',bad,'--bindings-id','local','--json'); assert invalid.returncode!=0
            assert len(Fixture.requests)==1
            run=command(h,'run',package,'--input',inputfile,'--bindings-id','local','--json'); assert run.returncode==0,(run.stdout,run.stderr)
            result=json.loads(run.stdout); assert result['status']=='completed' and result['output']=={'answer':'fixture answer'},result
            assert result['used_tokens']==18 and result['used_tool_calls']==0 and not result['usage_unknown'],result
            fetched=command(h,'get',result['run_id'],'--json'); assert json.loads(fetched.stdout)==result
            assert len(Fixture.requests)==2
            request=Fixture.requests[-1]['body']; assert not request.get('tools')
            messages=request['messages']; assert 'unique_loop_task' in json.dumps(messages) and 'fixture chat answer' not in json.dumps(messages) and 'hi' not in [m.get('content') for m in messages]
            assert 'answer' in messages[0]['content'] and 'schema' in messages[0]['content'].lower(),messages
            assert all(r['authorization']=='Bearer '+KEY and r['path']=='/v1/chat/completions' for r in Fixture.requests)
            report['cases'].append('single infer, schema, direct input, exact usage, durable get, preflight rejection')
            native_route='FH_API_KEY_V1_'+hashlib.sha256(str(root_a).encode()).hexdigest()+'_FH_AI_'+hashlib.sha256(b'api').hexdigest().upper()+'_KEY'
            try:
                terminal=Terminal(binary,['setup','ai'],gateway_home,native_overrides)
                for prompt,value in [('Choose [1]:','3'),('Connection name [api]:',''),('API base URL [https://api.openai.com/v1]:',f'http://127.0.0.1:{server.server_port}/v1'),('Model ID:','fixture-model'),('API key (hidden; Esc cancels):',KEY)]: terminal.answer(prompt,value)
                terminal.finish()
                native_run=command(gateway_home,'run',package,'--input',inputfile,'--bindings-id','local','--json',overrides=native_overrides)
                assert native_run.returncode==0,(native_run.stdout,native_run.stderr)
                assert json.loads(native_run.stdout)['output']=={'answer':'fixture answer'}
                assert len(Fixture.requests)==3 and Fixture.requests[-1]['authorization']=='Bearer '+KEY
                report['cases'].append('native stored compatible key longer than 128 bytes resolves for infer')
            finally:
                if os.uname().sysname=='Darwin':
                    cleanup=subprocess.run(['/usr/bin/security','delete-generic-password','-s',native_route,'-a',os.environ['USER']],capture_output=True)
                    assert cleanup.returncode in (0,44), 'Owned compatible service cleanup failed'
            report['http_requests']=len(Fixture.requests); report['success']=not report.get('limitations')
    except Exception as error:
        report['failure']=str(error).replace(KEY,'[synthetic key]').replace(JEV,'[synthetic key]')
    finally:
        for child in CHILDREN:
            if child.poll() is None: child.kill(); child.wait()
        server.shutdown(); server.server_close()
        operator_after=hashlib.sha256(operator_settings.read_bytes()).hexdigest() if operator_settings.is_file() else None
        report['operator_preferences_unchanged']=operator_before==operator_after
        report['binary_unchanged']=hashlib.sha256(binary.read_bytes()).hexdigest()==report['binary_sha256']
        report['success']=report['success'] and report['operator_preferences_unchanged'] and report['binary_unchanged']
    if args.evidence: args.evidence.write_text(json.dumps(report,indent=2)+'\n')
    Path('/private/tmp/fh-onboarding-journey-report.md').write_text('Native onboarding journey: '+('PASS' if report['success'] else 'FAIL')+'\n\n'+ '\n'.join('- '+case for case in report['cases'])+'\n\n'+'\n'.join(report.get('limitations',[]))+'\n'+report.get('failure','All calls used the loopback fixture and disposable profiles.')+'\n')
    print(json.dumps(report,indent=2)); return 0 if report['success'] else 1

if __name__=='__main__': raise SystemExit(main())
