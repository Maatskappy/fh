#!/usr/bin/env python3
"""Real Moli, native foreground ownership, deterministic localhost provider only."""
import argparse, hashlib, json, os, pathlib, shlex, signal, socket, subprocess, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = b'''<!doctype html><title>Native browser conformance</title><button id="first" onclick="status.textContent='First activated'">First</button><input id="text" placeholder="Name" oninput="status.textContent='Typed: '+this.value"><a id="link" href="/next">Next</a><input id="check" type="checkbox" onchange="status.textContent='Checked: '+this.checked"><button id="last" onclick="status.textContent='Last activated'">Last</button><p id="status">Ready</p><script>const status=document.getElementById('status');document.addEventListener('keydown',e=>{if(e.key==='Escape')status.textContent='Escape received; trusted='+e.isTrusted})</script>'''
class Server(BaseHTTPRequestHandler):
    requests=[]; results=[]; batches=[]; mode='normal'; profile=None; url=''; pids=set(); owner_pid=None; entered=threading.Event(); release=threading.Event();
    def log_message(self,*a): pass
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Length',str(len(PAGE))); self.end_headers(); self.wfile.write(PAGE)
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length']))); self.requests.append(body)
        assert [t['function']['name'] for t in body.get('tools',[])]==['browser'], body
        tools=[m for m in body['messages'] if m['role']=='tool']
        if self.mode=='no_tools':
            delta={'role':'assistant','content':'{"ok":true}'};finish='stop'
        elif tools:
            results=json.loads(tools[-1]['content']); self.results.append(results)
            rows=[line.strip().split(None,2) for line in subprocess.check_output(['ps','-axo','pid,ppid,args'],text=True).splitlines()[1:]]
            descendants={self.owner_pid}
            for _ in range(5):
                descendants.update(int(row[0]) for row in rows if len(row)==3 and int(row[1]) in descendants)
            self.pids.update(int(row[0]) for row in rows if len(row)==3 and int(row[0]) in descendants and row[2].split()[0].endswith('/moli') and ' serve ' in row[2])
            if self.mode in ('deadline','cancel','crash'): self.entered.set(); self.release.wait(20)
            content=json.dumps({'ok':'wrong schema' if self.mode=='invalid_output' else self.mode!='repeat' or len(self.results)>=2}); delta={'role':'assistant','content':content}; finish='stop'
        else:
            n=len(self.batches)
            actions=([{'action':'navigate','url':self.url}, {'action':'key','key':'Tab'}, {'action':'key','key':'Tab'}, {'action':'key','key':'Shift+Tab'}, {'action':'key','key':'Enter'}, {'action':'key','key':'Tab'}, {'action':'type','text':'Native text'}, {'action':'key','key':'Tab'}, {'action':'key','key':'Tab'}, {'action':'key','key':'Space'}, {'action':'key','key':'Escape'}, {'action':'capture'}] if n==0 else [{'action':'observe'}, {'action':'activate','handle':4}, {'action':'capture'}])
            if self.mode=='refused_navigation' and n==1: actions=[{'action':'navigate','url':self.refused_url},{'action':'activate','handle':1},{'action':'type','text':'Must not run'}]
            self.batches.append(actions)
            if self.mode=='revoke':
                p=self.profile/'installation.json'; v=json.loads(p.read_text()); v['bindings']['local']['capabilities'].pop('browser'); private_json(p,v)
            if self.mode=='unadvertised': name='shell'; arguments={}
            else: name='browser'; arguments={'actions':actions}
            delta={'role':'assistant','tool_calls':[{'index':0,'id':f'call_{len(self.requests)}','type':'function','function':{'name':name,'arguments':json.dumps(arguments)}}]}; finish='tool_calls'
        if tools and self.mode in ('deadline','cancel','crash'): return
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        for frame in [{'choices':[{'index':0,'delta':delta,'finish_reason':None}]},{'choices':[{'index':0,'delta':{},'finish_reason':finish}],'usage':{'prompt_tokens':10,'completion_tokens':5,'total_tokens':15}}]: self.wfile.write(('data: '+json.dumps(frame)+'\n\n').encode())
        try: self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass

def private_json(path,value): path.write_text(json.dumps(value)); path.chmod(0o600)
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--binary',type=pathlib.Path,default=pathlib.Path('zig-out/bin/fh')); ap.add_argument('--moli',type=pathlib.Path,default=pathlib.Path.home()/'.local/share/fh/browsers/moli-1.1.13/moli'); ap.add_argument('--out',type=pathlib.Path,required=True); args=ap.parse_args(); binary=args.binary.resolve(); moli=args.moli.resolve(); args.out.mkdir(parents=True,exist_ok=True)
    server=ThreadingHTTPServer(('127.0.0.1',0),Server); thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start(); Server.url=f'http://127.0.0.1:{server.server_port}/'
    prior=json.loads((args.out/'report.json').read_text()) if (args.out/'report.json').exists() else {}
    report={'prior_samples':prior.get('prior_samples',[])+prior.get('samples',[]),'provider':'deterministic localhost fixture; no live model','binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'samples':[],'cases':[]}
    try:
      with tempfile.TemporaryDirectory(prefix='fh-local-browser-',dir='/private/tmp') as temp:
        root=pathlib.Path(temp); profile=root/'profile'; profile.mkdir(mode=0o700); Server.profile=profile
        env={k:v for k,v in os.environ.items() if not k.startswith(('FX_','FH_')) and not any(x in k.upper() for x in ('API_KEY','TOKEN'))}; env.update(HOME=str(root),FH_DATA_DIR=str(profile),FH_BROWSER_TEST_KEY='fixture-only',FX_DISABLE_KEYCHAIN='1')
        settings={'provider':'fixture','models':{'fixture':'fixture-model'},'effort':'none','fast_mode':False,'providers':{'fixture':{'protocol':'openai-chat-completions','base_url':Server.url+'v1','auth':{'type':'bearer','env':'FH_BROWSER_TEST_KEY'},'tool_choice_mode':'send','model_metadata':{'fixture-model':{'supports_tool_use':True}}}}};private_json(profile/'settings.json',settings)
        launch_log=root/"launches";wrapper=root/"moli-fixture";wrapper.write_text("#!/bin/sh\necho launch >> "+shlex.quote(str(launch_log))+"\nexec "+shlex.quote(str(moli))+' "$@"\n');wrapper.chmod(0o700)
        def launches():return len(launch_log.read_text().splitlines()) if launch_log.exists() else 0
        original={'version':1,'limits':{'maxToolCalls':2,'maxSeconds':20},'bindings':{'local':{'id':'local','capabilities':{},'resources':{'kept':'opaque'}}},'resources':{'opaque':{'kind':'directory','path':'/fixture','mode':'ro'}},'runtimeProfiles':{'kept':{'untouched':True}}}; private_json(profile/'installation.json',original)
        def command(*arguments,expect=0):
            proc=subprocess.Popen([str(binary),*arguments],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            Server.owner_pid=proc.pid
            out,err=proc.communicate(timeout=35)
            p=subprocess.CompletedProcess(proc.args,proc.returncode,out,err)
            assert p.returncode==expect,(arguments,p.returncode,p.stdout,p.stderr)
            return p
        setup=command('setup','browser','--binary',str(wrapper)); configured=json.loads((profile/'installation.json').read_text()); assert configured['limits']==original['limits'] and configured['runtimeProfiles']==original['runtimeProfiles']; assert configured['bindings']['local']['resources']==original['bindings']['local']['resources']; assert json.loads((profile/'settings.json').read_text())==settings
        saved=(profile/'installation.json').read_bytes(); command('setup','browser','--binary',str(wrapper)); assert (profile/'installation.json').read_bytes()==saved
        assert not (root/'.local/share/fh/browsers/moli-1.1.13/moli').exists()
        command('setup','browser');assert (profile/'installation.json').read_bytes()==saved
        mismatch=command('setup','browser','--binary','/usr/bin/false',expect=1);assert 'BrowserResourceAlreadyExists' in mismatch.stderr and (profile/'installation.json').read_bytes()==saved
        invalid_explicit=command('setup','browser','--binary',str(root/'missing'),expect=1);assert 'BrowserSetupRequired' in invalid_explicit.stderr and (profile/'installation.json').read_bytes()==saved
        report['cases'].append('setup preserves limits/resources/runtime/AI; custom grant is idempotent without default and rejects conflicting explicit binary')
        package=root/'loop'; package.mkdir(); manifest={'format':'loops/0.1','name':'local-browser-test','version':'1','inputs':{'schema':{'type':'object','required':['url'],'properties':{'url':{'type':'string'}},'additionalProperties':False}},'steps':[{'id':name,'kind':'infer','requires':['browser'],'instructions':'Follow the deterministic browser conformance fixture and return JSON.','input':{'from':'/input'},'output':{'schema':{'type':'object','properties':{'ok':{'type':'boolean'}},'required':['ok'],'additionalProperties':False}}} for name in ['first','second']],'output':{'from':'/steps/second/output'}}; private_json(package/'loop.json',manifest)
        def run_input(value): p=root/'input.json';private_json(p,value);return str(p)
        checked=command('check',str(package),'--json');assert json.loads(checked.stdout)['ok'];assert not Server.requests and launches()==0
        invalid=command('run',str(package),'--input',run_input({}),'--json',expect=2);assert not Server.requests and launches()==0; report['cases'].append('check and malformed input make zero provider calls')
        started=time.perf_counter(); result=command('run',str(package),'--input',run_input({'url':Server.url}),'--json'); elapsed=(time.perf_counter()-started)*1000; record=json.loads(result.stdout); (args.out/'run.json').write_text(json.dumps(record,indent=2)); assert record['status']=='completed',record
        run=json.loads((profile/'native-runs'/f"{record['run_id']}.json").read_text()); (args.out/'record.json').write_text(json.dumps(run,indent=2)); assert run['used_tool_calls']==2 and run['model_request_dispatches']==4 and run['used_tokens']==60,run
        assert sum(e['id']=='browser-process' for e in run['effects'])==1; assert all(run['effects'][-1]['details'][key] for key in ('launch_attempted','launched','reaped')); assert len(Server.results)==2,Server.results
        report['requests']=Server.requests;report['observations']=Server.results
        obs=Server.results[0]; assert obs[1]['focus']['id']=='first';assert obs[2]['focus']['id']=='text';assert obs[3]['focus']['id']=='first';assert 'First activated' in obs[4]['text'];assert obs[6]['elements'][1]['value']=='Native text';assert obs[9]['elements'][3]['checked'];assert 'trusted=true' in obs[10]['text'];assert Server.results[1][0]['elements'][1]['value']=='Native text';assert 'Last activated' in Server.results[1][1]['text']
        assert sum(e.get('details',{}).get('file','').endswith('.png') for e in run['effects'])==2
        for path in (profile/'native-runs').glob('*.png'):
            data=path.read_bytes();assert data[:8]==b'\x89PNG\r\n\x1a\n';(args.out/path.name).write_bytes(data)
        report['cases'].append('two steps reuse one automatically launched browser; real keys/input/mouse/PNG; owned cleanup');report['samples'].append({'run_ms':elapsed,'dispatches':4})
        report['requests']=Server.requests;report['observations']=Server.results
        report['samples'][0].update(cold_start_ms=Server.results[0][0]['cold_start_ms'],operations_ms=[o['operation_ms'] for batch in Server.results for o in batch])
        timings=run['effects'][-1]['details']['operations']
        assert [t['operation_ms'] for t in timings]==report['samples'][0]['operations_ms'],timings
        assert run['effects'][-1]['details']['cold_start_ms']==report['samples'][0]['cold_start_ms'],timings
        assert not any(e['kind']=='browser_timing' for e in run['effects']),run['effects']
        assert [t['operation_id'] for t in timings]==[e['id'] for e in run['effects'] if e['kind']=='browser_operation'],timings
        assert len(Server.pids)==1 and launches()==1,(Server.pids,launches())
        def assert_reaped(pids):
            end=time.monotonic()+3
            while time.monotonic()<end:
                live=[]
                for pid in pids:
                    try: os.kill(pid,0);live.append(pid)
                    except ProcessLookupError: pass
                if not live:return
                time.sleep(.01)
            raise AssertionError(('owned Moli not reaped',live))
        assert_reaped(Server.pids);report['owned_pids']=list(Server.pids)
        def reset(mode='normal'):
            Server.requests=[];Server.results=[];Server.batches=[];Server.pids=set();Server.mode=mode;Server.entered.clear();Server.release.clear()
        def final_record(p):
            value=json.loads(p.stdout)
            return json.loads((profile/'native-runs'/f"{value['run_id']}.json").read_text())
        reset('refused_navigation');before=launches()
        # Reserve a local TCP port without listening: deterministic connection refusal.
        with socket.socket() as refused:
            refused.bind(('127.0.0.1',0));Server.refused_url=f'http://127.0.0.1:{refused.getsockname()[1]}/'
            result=command('run',str(package),'--input',run_input({'url':Server.url}),'--json',expect=1)
        failed_navigation=final_record(result);report['refused_navigation']=failed_navigation
        operations=[e for e in failed_navigation['effects'] if e['kind']=='browser_operation']
        assert failed_navigation['error']['cause']=='NavigationFailed',failed_navigation
        assert operations[-1]['details']['action']=='navigate' and operations[-1]['state']=='unknown',operations
        assert len(operations)==13 and not any(e['details']['action']=='activate' for e in operations),operations
        assert sum(e['details']['action']=='type' for e in operations)==1,operations
        assert len(Server.results)==1 and launches()==before+1 and len(Server.pids)==1
        assert failed_navigation['effects'][-1]['kind']=='browser_cleanup' and failed_navigation['effects'][-1]['state']=='applied' and failed_navigation['effects'][-1]['details']['reaped'];assert_reaped(Server.pids)
        report['cases'].append('refused navigation stays unknown, aborts following activate/type, and reaps owned Moli')
        reset('no_tools');before=launches()
        no_tools=final_record(command('run',str(package),'--input',run_input({'url':Server.url}),'--json'));assert no_tools['status']=='completed' and no_tools['used_tool_calls']==0 and launches()==before
        report['cases'].append('declared browser remains lazy when kernel needs no tool')
        reset('repeat')
        repeated=dict(manifest,steps=manifest['steps'][:1],repeat={'from':'first','through':'first','until':{'from':'/steps/first/output/ok'},'max_iterations':2,'carry':{'initial':{'value':{}},'next':{'value':{}}}},output={'from':'/steps/first/output'})
        private_json(package/'loop.json',repeated)
        repeat=final_record(command('run',str(package),'--input',run_input({'url':Server.url}),'--json'));assert repeat['status']=='completed' and repeat['used_tool_calls']==2 and len(repeat['attempts'])==2;assert len(Server.pids)==1;assert_reaped(Server.pids)
        report['cases'].append('repeat iterations share one run-owned browser');report['repeat_record']=repeat;report['repeat_observations']=Server.results;assert launches()==3
        report['samples'].append({'repeat_cold_start_ms':Server.results[0][0]['cold_start_ms'],'operations_ms':[o['operation_ms'] for batch in Server.results for o in batch]})
        private_json(package/'loop.json',manifest)
        for capability in ['computer','web_search']:
            reset();before=launches();bad=json.loads(json.dumps(manifest));bad['steps'][0]['requires']=[capability];private_json(package/'loop.json',bad)
            p=command('run',str(package),'--input',run_input({'url':Server.url}),'--json',expect=2);assert not Server.requests and launches()==before
        code_browser=json.loads(json.dumps(manifest));code_browser['steps'][0].update(kind='code',runtime='python3',file='code.py');code_browser['steps'][0].pop('instructions');(package/'code.py').write_text('pass\n');private_json(package/'loop.json',code_browser)
        p=command('run',str(package),'--input',run_input({'url':Server.url}),'--json',expect=2);assert not Server.requests and launches()==before
        report['cases'].append('computer web_search and code/browser fail before provider/browser')
        private_json(package/'loop.json',manifest)
        for mode,cause in [('unadvertised','UnadvertisedInferenceTool'),('revoke','PermissionDenied')]:
            reset(mode);before=launches();private_json(profile/'installation.json',configured)
            record=final_record(command('run',str(package),'--input',run_input({'url':Server.url}),'--json',expect=3 if mode=='unadvertised' else 1));assert (record['stop']['cause']=='UsageUnavailable' if mode=='unadvertised' else record['error']['cause']==cause);assert not Server.results;assert not record['effects'][-1]['details']['launched'] and launches()==before
            report['cases'].append(mode+' rejects before browser startup')
        reset('invalid_output');private_json(profile/'installation.json',configured)
        invalid_output=final_record(command('run',str(package),'--input',run_input({'url':Server.url}),'--json',expect=1));assert invalid_output['error']['cause']=='InvalidOutput' and invalid_output['used_tokens']==30;assert_reaped(Server.pids)
        report['cases'].append('explicit output schema rejects wrong type after retaining usage and cleanup')
        reset();before=launches();missing=json.loads(json.dumps(configured));missing['resources']['local-moli-browser']['binary']=str(root/'missing-moli');private_json(profile/'installation.json',missing)
        unavailable=command('run',str(package),'--input',run_input({'url':Server.url}),'--json',expect=2);assert 'browser_setup_required' in unavailable.stdout and not Server.requests and launches()==before
        report['cases'].append('missing installed binary gives setup guidance before provider/launch')
        reset();broken=json.loads(json.dumps(configured));broken['resources']['local-moli-browser']['binary']='/usr/bin/false';private_json(profile/'installation.json',broken)
        failed=final_record(command('run',str(package),'--input',run_input({'url':Server.url}),'--json',expect=1));assert failed['effects'][-1]['kind']=='browser_cleanup' and failed['effects'][-1]['state']=='applied';report['cases'].append('partial setup failure releases owned process')
        private_json(profile/'installation.json',configured)
        for mode in ['deadline','cancel','crash']:
            reset(mode)
            bounded=json.loads(json.dumps(configured));bounded['limits']['maxSeconds']=1 if mode=='deadline' else 20;private_json(profile/'installation.json',bounded)
            proc=subprocess.Popen([str(binary),'run',str(package),'--input',run_input({'url':Server.url}),'--json'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);Server.owner_pid=proc.pid
            try:
                assert Server.entered.wait(10),mode;assert len(Server.pids)==1,Server.pids
                if mode!='deadline':proc.send_signal(signal.SIGINT if mode=='cancel' else signal.SIGKILL)
                out,err=proc.communicate(timeout=10);assert_reaped(Server.pids)
                report[mode]={'exit_code':proc.returncode,'owned_pids':list(Server.pids),'stdout':out,'stderr':err}
                if mode!='crash':assert json.loads(out)['status']=='stopped'
                if mode=='deadline':assert json.loads(out)['stop']['cause']=='TimeLimit'
            finally:
                Server.release.set()
                if proc.poll() is None:proc.kill();proc.wait()
            report['cases'].append(mode+' cleans owned Moli without manual browser launch')
        for path in (profile/'native-runs').glob('*.png'):(args.out/path.name).write_bytes(path.read_bytes())
        report['success']=True
    finally:
        server.shutdown();server.server_close();thread.join();(args.out/'report.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({'success':report.get('success'), 'cases':report['cases'],'samples':report['samples']}))
if __name__=='__main__':main()
