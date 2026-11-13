#!/usr/bin/env python3
"""Real npm/tsc and native workspace operations; deterministic local inference."""
import argparse, hashlib, json, os, shlex, shutil, statistics, subprocess, tempfile, threading, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
BAD='export const answer: string = 42;\n'
GOOD='export const answer: string = "42";\n'
def private_json(p,v): p.write_text(json.dumps(v)); p.chmod(0o600)
class Provider(BaseHTTPRequestHandler):
    mode='repair'; requests=[]; workspace=None; profile=None
    def log_message(self,*args): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        state=json.loads(next(m['content'] for m in body['messages'] if m['role']=='user'))
        self.requests.append(state); assert not body.get('tools'), body
        f=state['check']['files'][0]
        edits=[] if state['check']['passed'] or self.mode=='no_edits' else [{'path':f['path'],'sha256':f['sha256'],'content':GOOD}]
        if self.mode=='stale': edits[0]['sha256']='0'*64
        if self.mode=='outside': edits[0]['path']='untouched.ts'
        if self.mode=='changed': (self.workspace/'source.ts').write_text('// concurrent human edit\n'+BAD)
        if self.mode=='revoke':
            p=self.profile/'installation.json'; v=json.loads(p.read_text()); v['bindings']['workspace']['resources'].clear(); private_json(p,v)
        result={'edits':edits,'reason':'deterministic fixture'}
        if self.mode=='invalid': result={'edits':'invalid shape','reason':'fixture'}
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        for frame in [{'choices':[{'index':0,'delta':{'role':'assistant','content':json.dumps(result)},'finish_reason':None}]},
                      {'choices':[{'index':0,'delta':{},'finish_reason':'stop'}],'usage':{'prompt_tokens':10,'completion_tokens':5,'total_tokens':15}}]:
            self.wfile.write(('data: '+json.dumps(frame)+'\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()
def main():
    ap=argparse.ArgumentParser(description=__doc__); ap.add_argument('--binary',type=Path,default=Path('dist/fh')); ap.add_argument('--tsc',type=Path,required=True); ap.add_argument('--out',type=Path); args=ap.parse_args()
    binary,tsc=args.binary.resolve(),args.tsc.resolve(); assert tsc.is_file()
    checkout=Path(__file__).resolve().parents[2]; repair=checkout/'loops/workspace-repair'
    node=str(Path(shutil.which('node')).resolve()); npm=str(Path(shutil.which('npm')).resolve())
    server=ThreadingHTTPServer(('127.0.0.1',0),Provider); threading.Thread(target=server.serve_forever,daemon=True).start()
    report={'success':False,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'compiler':str(tsc),'provider':'deterministic localhost; no live model or operator credentials','cases':[],'runs':{}}
    try:
      with tempfile.TemporaryDirectory(prefix='fh-workspace-proof-',dir='/private/tmp') as tmp:
        root=Path(tmp)
        env_base={k:v for k,v in os.environ.items() if not k.startswith(('FX_','FH_')) and not any(t in k.upper() for t in ('KEY','TOKEN'))}
        env_base.update(HOME=str(root),FX_DISABLE_KEYCHAIN='1',FH_WORKSPACE_FIXTURE_KEY='synthetic-fixture')
        settings={'provider':'fixture','models':{'fixture':'fixture-model'},'effort':'none','fast_mode':False,
                  'providers':{'fixture':{'protocol':'openai-chat-completions','base_url':f'http://127.0.0.1:{server.server_port}/v1','auth':{'type':'bearer','env':'FH_WORKSPACE_FIXTURE_KEY'},'tool_choice_mode':'send','model_metadata':{'fixture-model':{'supports_tool_use':True}}}}}
        def context(name,command=None,limits=None,extra_commands=None):
            path=root/name; path.mkdir(); profile,workspace=path/'profile',path/'workspace'; profile.mkdir(mode=0o700); workspace.mkdir()
            (workspace/'source.ts').write_text(BAD); (workspace/'untouched.ts').write_text('human work\n')
            private_json(workspace/'package.json',{'scripts':{'typecheck':shlex.join([node,str(tsc),'--noEmit','--strict','--skipLibCheck','source.ts'])}})
            private_json(profile/'settings.json',settings)
            initial={'version':1,'bindings':{'local':{'id':'local','resources':{},'capabilities':{}}},'resources':{},'runtimeProfiles':{},'limits':limits or {'maxSeconds':30}}
            private_json(profile/'installation.json',initial)
            commands={'typecheck':command or [npm,'run','typecheck']}; commands.update(extra_commands or {})
            private_json(path/'grant.json',{'workspace':str(workspace),'files':['source.ts'],'commands':commands})
            env=dict(env_base,FH_DATA_DIR=str(profile))
            def setup(*extra,expect=0):
                p=subprocess.run([str(binary),'setup','workspace',str(path/'grant.json'),*extra],env=env,capture_output=True,text=True,timeout=10)
                assert p.returncode==expect,(p.returncode,p.stderr)
            def cli(*words,expect=0):
                start=time.perf_counter(); p=subprocess.run([str(binary),*map(str,words),'--json'],env=env,cwd=workspace,capture_output=True,text=True,timeout=40)
                v=json.loads(p.stdout); assert p.returncode==expect,(p.returncode,v,p.stderr); return v,(time.perf_counter()-start)*1000
            setup(expect=2); assert json.loads((profile/'installation.json').read_text())==initial
            before_requests=len(Provider.requests)
            unavailable,_=cli('check',repair,'--bindings-id','local',expect=2)
            assert unavailable['issues'][0]['code']=='workspace_setup_required' and len(Provider.requests)==before_requests,unavailable
            setup('--trust-host'); before=(profile/'installation.json').read_bytes(); setup('--trust-host',expect=1); assert (profile/'installation.json').read_bytes()==before
            unavailable,_=cli('check',repair,'--bindings-id','local',expect=2)
            assert unavailable['issues'][0]['code']=='workspace_setup_required',unavailable
            Provider.requests=[]; Provider.workspace,Provider.profile=workspace,profile
            private_json(path/'input.json',{'goal':'Repair the type error without touching other files.'})
            return path,profile,workspace,cli,env
        Provider.mode='repair'; path,profile,workspace,cli,env=context('repair')
        checked,_=cli('check',repair,'--bindings-id','workspace'); assert checked['ok'] and not Provider.requests and not (root/'.npm').exists()
        run,elapsed=cli('run',repair,'--input',path/'input.json','--bindings-id','workspace')
        assert run['status']=='completed' and run['output']['check']['passed'],run
        assert (workspace/'source.ts').read_text()==GOOD and (workspace/'untouched.ts').read_text()=='human work\n'
        assert cli('get',run['run_id'])[0]==run
        record=json.loads((profile/'native-runs'/(run['run_id']+'.json')).read_text())
        assert len(record['attempts'])==3 and not record['attempts'][0]['output']['passed']
        assert 'TS2322' in record['attempts'][0]['output']['stdout'],record
        assert record['attempts'][1]['input']['check']==record['attempts'][0]['output']
        assert run['model_request_dispatches']==1 and not run['uncertain_effects']
        assert [e['kind'] for e in record['effects']]==['workspace_command','workspace_edit','workspace_command'] and all(e['state']=='applied' for e in record['effects'])
        report['runs']['repair']={'result':run,'record':record,'elapsed_ms':elapsed}
        (workspace/'source.ts').write_text(BAD)
        reused,_=cli('run',repair,'--input',path/'input.json','--bindings-id','workspace')
        assert reused['package_digest']==checked['package_digest']==run['package_digest'] and reused['output']['check']['passed']
        report['cases'].append('real npm/tsc failure -> bound diagnostics/source -> inference JSON -> native guarded edit -> real passing tsc; unchanged package reuse and get')
        # Authorized suffix commands can commit and push once to a disposable local remote.
        git=str(Path(shutil.which('git')).resolve())
        path,profile,workspace,cli,env=context('git',extra_commands={
            'commit':[git,'-c','user.name=fh fixture','-c','user.email=fixture@example.invalid','commit','-am','repair'],
            'push':[git,'push','origin','HEAD:refs/heads/main']})
        remote=root/'fixture-remote.git'
        def git_cmd(*argv,cwd=workspace):
            return subprocess.run([git,*argv],cwd=cwd,env=dict(env,GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null'),capture_output=True,text=True,check=True)
        git_cmd('init','--bare',str(remote),cwd=root)
        git_cmd('init'); git_cmd('add','source.ts','package.json')
        git_cmd('-c','user.name=fh fixture','-c','user.email=fixture@example.invalid','commit','-m','baseline')
        git_cmd('remote','add','origin',str(remote))
        publishing=path/'package'; shutil.copytree(repair,publishing)
        manifest=json.loads((publishing/'loop.json').read_text())
        for name in ('commit','push'):
            private_json(publishing/(name+'.json'),{'operation':'command','command':name})
            manifest['steps'].append({'id':name,'kind':'code','runtime':'fh-workspace/1','file':name+'.json','requires':[],'input':{'value':{}},'output':{'schema':True}})
        private_json(publishing/'loop.json',manifest)
        published,_=cli('run',publishing,'--input',path/'input.json','--bindings-id','workspace')
        assert published['status']=='completed' and git_cmd('--git-dir',str(remote),'show','main:source.ts',cwd=root).stdout==GOOD
        old_head=git_cmd('rev-parse','HEAD').stdout
        Provider.mode='no_edits'; (workspace/'source.ts').write_text(BAD)
        exhausted,_=cli('run',publishing,'--input',path/'input.json','--bindings-id','workspace',expect=3)
        assert exhausted['stop']['reason']=='iteration_limit' and git_cmd('rev-parse','HEAD').stdout==old_head
        assert git_cmd('--git-dir',str(remote),'show','main:source.ts',cwd=root).stdout==GOOD
        report['runs']['git_suffix']={'result':published,'exhausted_result':exhausted,'local_remote_only':True}
        report['cases'].append('separately registered native suffix commands commit and push to local bare remote after success; exhaustion never publishes')
        Provider.mode='repair'
        path,profile,workspace,cli,env=context('failed-commit',extra_commands={
            'commit':['/usr/bin/false'],'push':[node,'-e','require("fs").writeFileSync("PUSH_WAS_RUN","unexpected")']})
        failed_commit,_=cli('run',publishing,'--input',path/'input.json','--bindings-id','workspace',expect=1)
        assert failed_commit['status']=='failed' and failed_commit['error']['cause']=='WorkspaceCommandFailed',failed_commit
        assert not (workspace/'PUSH_WAS_RUN').exists() and (workspace/'source.ts').read_text()==GOOD
        report['runs']['failed_commit']={'result':failed_commit,'push_skipped':True}
        report['cases'].append('nonzero authorized action retains failure receipt and skips all later commands; failed commit never pushes')
        Provider.mode='repair'
        path,profile,workspace,cli,env=context('performance',['/usr/bin/true'])
        package=path/'package'; package.mkdir()
        private_json(package/'loop.json',{'format':'loops/0.1','name':'native-noop','version':'1','inputs':{'schema':True},
            'steps':[{'id':'check','kind':'code','runtime':'fh-workspace/1','file':'check.json','input':{'from':'/input'},'output':{'schema':True}}],
            'output':{'from':'/steps/check/output'}})
        private_json(package/'check.json',{'operation':'check','command':'typecheck'})
        samples=[]
        for _ in range(10):
            result,ms=cli('run',package,'--input',path/'input.json','--bindings-id','workspace')
            assert result['output']['passed'] and result['model_request_dispatches']==0
            samples.append(ms)
        report['native_noop_cli_ms']={'median':statistics.median(samples),'min':min(samples),'max':max(samples),'samples':samples,
            'includes':'CLI startup, profile/package validation, source collection, native command supervision and durable run/effect writes'}
        for mode,cause in [('no_edits','iteration_limit'),('stale','WorkspaceChanged'),('outside','PermissionDenied'),('changed','WorkspaceChanged'),('revoke','PermissionDenied'),('invalid',None)]:
            Provider.mode=mode; path,profile,workspace,cli,env=context(mode)
            failed,_=cli('run',repair,'--input',path/'input.json','--bindings-id','workspace',expect=3 if mode=='no_edits' else 1)
            record=json.loads((profile/'native-runs'/(failed['run_id']+'.json')).read_text())
            if mode=='no_edits':
                assert failed['status']=='stopped' and failed['stop']['reason']==cause and len(Provider.requests)==3,failed
                assert len(record['attempts'])==7 and not record['current']['apply']['output']['passed']
                assert all(r['check']['files'][0]['content']==BAD for r in Provider.requests)
            else:
                assert failed['status']=='failed' and len(Provider.requests)==1,failed
                if cause: assert failed['error']['cause']==cause,failed
                assert not any(e['kind']=='workspace_edit' for e in record['effects'])
            expected='// concurrent human edit\n'+BAD if mode=='changed' else BAD
            assert (workspace/'source.ts').read_text()==expected and (workspace/'untouched.ts').read_text()=='human work\n'
            report['runs'][mode]={'result':failed}
        report['cases'].append('bounded exhaustion/carry; stale hashes, ungranted paths, concurrent edits, revoked grants and invalid inference cannot mutate files')
        Provider.mode='repair'
        path,profile,workspace,cli,env=context('operation-limit',limits={'maxSeconds':30,'maxOperations':3})
        limited,_=cli('run',repair,'--input',path/'input.json','--bindings-id','workspace',expect=3)
        assert limited['stop']['reason']=='operation_limit' and (workspace/'source.ts').read_text()==BAD
        assert not any(e['kind']=='workspace_edit' for e in limited['effects'])
        report['runs']['operation_limit']={'result':limited,'source_unchanged':True}
        report['cases'].append('insufficient remaining operation budget stops before any file replacement')
        Provider.mode='repair'; path,profile,workspace,cli,env=context('literal',[node,'-e','console.log(JSON.stringify(process.argv.slice(1)))','literal $(touch SHOULD_NOT_EXIST) '+chr(96)+'touch ALSO_NOT_EXIST'+chr(96)])
        package=path/'package'; package.mkdir()
        manifest={'format':'loops/0.1','name':'check-only','version':'1','inputs':{'schema':True},'steps':[{'id':'saved','kind':'code','runtime':'fh-workspace/1','file':'saved.json','requires':[],'input':{'from':'/input'},'output':{'schema':True}}],'output':{'from':'/steps/saved/output'}}
        private_json(package/'loop.json',manifest); private_json(package/'saved.json',{'operation':'check','command':'typecheck'})
        literal,_=cli('run',package,'--input',path/'input.json','--bindings-id','workspace')
        assert '$(touch' in literal['output']['stdout'] and not (workspace/'SHOULD_NOT_EXIST').exists() and not (workspace/'ALSO_NOT_EXIST').exists()
        private_json(package/'saved.json',{'operation':'check','command':'push'})
        denied,_=cli('check',package,'--bindings-id','workspace',expect=2); assert denied['issues'][0]['cause']=='PermissionDenied',denied
        private_json(package/'saved.json',{'operation':'check','command':'typecheck'})
        (workspace/'source.ts').unlink(); (workspace/'source.ts').symlink_to(workspace/'untouched.ts')
        denied,_=cli('check',package,'--bindings-id','workspace',expect=2); assert not denied['ok']
        (workspace/'source.ts').unlink(); (workspace/'source.ts').write_text(BAD)
        workspace.rename(path/'old-workspace'); workspace.mkdir()
        changed,_=cli('check',package,'--bindings-id','workspace',expect=2); assert changed['issues'][0]['cause']=='WorkspaceChanged',changed
        report['cases'].append('literal argv; unregistered commands, symlink sources and replaced workspace denied before execution')
        sleeper='const fs=require("fs"),cp=require("child_process"); const child=cp.spawn(process.execPath,["-e","setInterval(()=>{},1000)"],{stdio:"ignore"}); fs.writeFileSync("child.pid",String(child.pid)); setInterval(()=>{},1000)'
        path,profile,workspace,cli,env=context('timeout',[node,'-e',sleeper],{'maxSeconds':1})
        timed,_=cli('run',package,'--input',path/'input.json','--bindings-id','workspace',expect=3)
        assert timed['status']=='stopped' and timed['stop']['reason']=='time_limit' and timed['uncertain_effects'],timed
        child=int((workspace/'child.pid').read_text())
        try: os.kill(child,0)
        except ProcessLookupError: pass
        else: raise AssertionError(f'child {child} survived timeout')
        again,_=cli('check',package,'--bindings-id','workspace',expect=2); assert again.get('error',{}).get('code')=='recovery_required',again
        report['runs']['timeout']={'result':timed,'owned_child_reaped':True}
        report['cases'].append('deadline stops and reaps command/descendant; uncertain invocation prevents replay')
        report['success']=True
    finally:
        server.shutdown(); server.server_close()
        if args.out: args.out.parent.mkdir(parents=True,exist_ok=True); args.out.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='runs'},indent=2))
if __name__=='__main__': main()
