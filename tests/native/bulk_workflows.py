#!/usr/bin/env python3
"""Native batch/eval/retry proof with a deterministic loopback provider."""
import argparse, hashlib, json, os, signal, subprocess, tempfile, threading, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Server(BaseHTTPRequestHandler):
    mode='normal'; calls=[]; mutate=None; entered=threading.Event(); release=threading.Event()
    def log_message(self,*args): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        value=json.loads(next(m['content'] for m in body['messages'] if m['role']=='user'))
        self.calls.append(value)
        if self.mutate and len(self.calls)==1:
            manifest=json.loads(self.mutate.read_text()); manifest['version']='changed'; self.mutate.write_text(json.dumps(manifest))
        if self.mode=='hold': self.entered.set(); self.release.wait(10)
        result={'ready':value['label']=='pass'}
        if self.mode=='invalid': result={'ready':'invalid boolean'}
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        frame={'choices':[{'index':0,'delta':{'role':'assistant','content':json.dumps(result)},'finish_reason':None}]}
        try: self.wfile.write(('data: '+json.dumps(frame)+'\n\n').encode())
        except (BrokenPipeError,ConnectionResetError): return
        frame={'choices':[{'index':0,'delta':{},'finish_reason':'stop'}]}
        if self.mode!='unknown_usage': frame['usage']={'prompt_tokens':1,'completion_tokens':1,'total_tokens':2}
        try: self.wfile.write(('data: '+json.dumps(frame)+'\n\ndata: [DONE]\n\n').encode()); self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): pass
def private_json(p,v): p.write_text(json.dumps(v)); p.chmod(0o600)
def main():
    ap=argparse.ArgumentParser(description=__doc__); ap.add_argument('--binary',type=Path,required=True); ap.add_argument('--out',type=Path); args=ap.parse_args()
    binary=args.binary.resolve()
    server=ThreadingHTTPServer(('127.0.0.1',0),Server); threading.Thread(target=server.serve_forever,daemon=True).start()
    report={'success':False,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'provider':'deterministic loopback fixture only','cases':[]}
    try:
      with tempfile.TemporaryDirectory(prefix='fh-bulk-proof-',dir='/private/tmp') as tmp:
        root=Path(tmp); profile=root/'profile'; profile.mkdir(mode=0o700); package=root/'package'; package.mkdir()
        manifest={'format':'loops/0.1','name':'label-fixture','version':'1','inputs':{'schema':{'type':'object','required':['label'],'properties':{'label':{'type':'string'}}}},
                  'steps':[{'id':'judge','kind':'infer','instructions':'Classify the supplied label.','requires':[],'input':{'from':'/input'},
                            'output':{'schema':{'type':'object','required':['ready'],'properties':{'ready':{'type':'boolean'}}}}}],
                  'output':{'from':'/steps/judge/output'}}
        private_json(package/'loop.json',manifest)
        settings={'provider':'fixture','models':{'fixture':'fixture-model'},'effort':'none','fast_mode':False,
                  'providers':{'fixture':{'protocol':'openai-chat-completions','base_url':f'http://127.0.0.1:{server.server_port}/v1',
                  'auth':{'type':'bearer','env':'FH_BULK_TEST_KEY'},'tool_choice_mode':'send','model_metadata':{'fixture-model':{'supports_tool_use':True}}}}}
        private_json(profile/'settings.json',settings)
        env={k:v for k,v in os.environ.items() if not k.startswith(('FH_','FX_')) and not any(s in k.upper() for s in ('KEY','TOKEN','OAUTH'))}
        env.update(HOME=str(root),FH_DATA_DIR=str(profile),FX_DISABLE_KEYCHAIN='1',FH_BULK_TEST_KEY='synthetic-fixture')
        def cli(*argv,expect=0,stdin=None,events=False,timeout=90):
            start=time.perf_counter()
            p=subprocess.run([str(binary),*map(str,argv),'--events' if events else '--json'],env=env,cwd=root,input=stdin,capture_output=True,text=True,timeout=timeout)
            values=[json.loads(line) for line in p.stdout.splitlines()]
            assert p.returncode==expect,(p.returncode,values,p.stderr)
            assert 'synthetic-fixture' not in p.stdout+p.stderr
            return (values if events else values[0]),(time.perf_counter()-start)*1000
        cases=root/'cases.json'
        positive={'id':'positive','input':{'label':'pass'},'expect':{'pointer':'/ready','value':True}}
        negative={'id':'negative','input':{'label':'fail'},'expect':{'pointer':'/ready','value':False}}
        private_json(root/'negative.json',{'label':'fail'})
        file_case={'id':'file','input_file':'negative.json','expect':{'pointer':'/ready','value':False}}
        private_json(cases,{'cases':[positive,negative,file_case]})
        result,_=cli('eval',package,'--cases',cases)
        assert result['passed']==3 and result['mismatched']==0 and result['failed']==0
        assert [c['id'] for c in result['cases']]==['positive','negative','file']
        for row in result['cases']:
            record,_=cli('get',row['run_id']); assert record==row['result']
            assert record['case_id']==row['id'] and record['input_source']==row['input_source']
            assert len(record['input_sha256'])==64
        assert result['cases'][2]['input_source']==str(root/'negative.json')
        report['cases'].append('labelled eval matches positive/negative/file cases; durable get preserves case, source and canonical hash')
        mismatch=dict(positive,id='wrong',expect={'pointer':'/ready','value':False})
        missing=dict(positive,id='missing',expect={'pointer':'/missing','value':None})
        private_json(cases,{'cases':[positive,mismatch,missing]})
        result,_=cli('eval',package,'--cases',cases,expect=1)
        assert result['passed']==1 and result['mismatched']==2 and result['cases'][2]['actual_present'] is False
        before=len(Server.calls); private_json(cases,{'cases':[positive,dict(negative,id='positive')]})
        bad,_=cli('eval',package,'--cases',cases,expect=2); assert len(Server.calls)==before and bad['error']['code']=='invalid_cases'
        before=len(Server.calls)
        private_json(cases,{'cases':[dict(positive,expect={'pointer':'/ready','value':9223372036854775808})]})
        rejected,_=cli('eval',package,'--cases',cases,expect=2); assert len(Server.calls)==before
        cases.write_text(' '* (16*1048576+1))
        rejected,_=cli('batch',package,'--cases',cases,expect=2); assert rejected['error']['code']=='cases_limit' and len(Server.calls)==before
        private_json(cases,{'cases':[dict(positive,id=str(i)) for i in range(1001)]})
        rejected,_=cli('batch',package,'--cases',cases,expect=2); assert len(Server.calls)==before
        report['cases'].append('independent mismatched labels and missing pointer/null remain distinct; duplicate IDs, unsupported integer labels and oversized suites/counts rejected before any request')
        private_json(cases,{'cases':[positive,negative]}); Server.calls=[]
        events,_=cli('eval',package,'--cases',cases,events=True)
        accepted=[e for e in events if e.get('event')=='run_accepted']; completed=[e for e in events if e.get('event')=='case_result']
        assert len(accepted)==len(completed)==2 and accepted[0]['case_id']=='positive' and accepted[0]['input_source'].endswith('#positive')
        assert events[-1]['result']['passed']==2 and 'result' not in events[-1]['result']['cases'][0]
        report['cases'].append('one native worker emits attributed run acceptance/case results and bounded final event summary')
        # Required scale proof: 500 cases, one top-level process, no parallel dispatch.
        data=[]
        for i in range(500):
            base=positive if i%2==0 else negative
            data.append(dict(base,id=f'case-{i}'))
        private_json(cases,{'cases':data}); Server.calls=[]
        result,ms=cli('eval',package,'--cases',cases,timeout=180)
        assert result['passed']==500 and len(Server.calls)==500 and len({c['run_id'] for c in result['cases']})==500
        report['scale']={'cases':500,'fh_process_launches':1,'elapsed_ms':ms,'run_ids':[c['run_id'] for c in result['cases']]}
        report['cases'].append('500 labelled runs sequentially within a single fh invocation; unique durable run IDs and zero comparison errors')
        # Failed model output gives visible static cause; explicit retry retains original input.
        input_path=root/'input.json'; private_json(input_path,{'label':'pass'})
        Server.mode='invalid'
        failed,_=cli('run',package,'--input',input_path,expect=1)
        assert failed['diagnostic']['cause'] and failed['diagnostic']['step_id']=='judge' and failed['diagnostic']['retry']['allowed'],failed
        saved=(profile/'native-runs'/(failed['run_id']+'.json')).read_bytes()
        private_json(input_path,{'label':'fail'}); Server.mode='normal'
        retried,_=cli('retry',failed['run_id'])
        assert retried['retry_of']==failed['run_id'] and retried['output']['ready'] is True and retried['input_sha256']==failed['input_sha256']
        assert (profile/'native-runs'/(failed['run_id']+'.json')).read_bytes()==saved
        refused,_=cli('retry',retried['run_id'],expect=2); assert refused['error']['code']=='retry_completed_run'
        stdin,_=cli('run',package,'--input','-',stdin='{"label":"pass"}')
        assert stdin['input_source']=='stdin'
        report['cases'].append('failed cause/step/retry guidance visible; explicit retry uses retained input, creates linked run, preserves original; completed retry refused; stdin attributed')
        # A missing-input rejection is per case and must not hide a later successful case.
        private_json(cases,{'cases':[{'id':'invalid','input':{}},positive]}); Server.calls=[]
        mixed,_=cli('batch',package,'--cases',cases,expect=1)
        assert mixed['failed']==1 and mixed['passed']==1 and len(Server.calls)==1
        # Unknown usage stops the suite and forbids replay.
        Server.mode='unknown_usage'; private_json(cases,{'cases':[positive,negative]}); Server.calls=[]
        uncertain,_=cli('batch',package,'--cases',cases,expect=3)
        assert uncertain['failed']==1 and uncertain['skipped']==1 and len(Server.calls)==1
        refused,_=cli('retry',uncertain['cases'][0]['run_id'],expect=2); assert refused['error']['code']=='retry_unknown_usage'
        report['cases'].append('settled per-case rejection permits later work; unknown usage stops/skips remaining cases and denies retry')
        Server.mode='hold'; Server.entered.clear(); Server.release.clear()
        private_json(cases,{'cases':[positive]})
        proc=subprocess.Popen([str(binary),'eval',str(package),'--cases',str(cases),'--json'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            assert Server.entered.wait(5), 'provider request never entered'
            proc.send_signal(signal.SIGINT)
            out,err=proc.communicate(timeout=10)
            cancelled=json.loads(out)
            assert proc.returncode==130 and cancelled['status']=='stopped' and cancelled['skipped']==0,(proc.returncode,cancelled,err)
        finally:
            Server.release.set()
            if proc.poll() is None: proc.kill(); proc.communicate()
        report['cases'].append('one-case foreground cancellation retains accepted result and exits 130')
        Server.mode='normal'; Server.calls=[]; Server.mutate=package/'loop.json'
        private_json(cases,{'cases':[positive,negative,dict(positive,id='later')]})
        changed,_=cli('eval',package,'--cases',cases,expect=3)
        assert changed['passed']==1 and changed['failed']==1 and changed['skipped']==1 and len(Server.calls)==1
        assert changed['cases'][1]['result']['code']=='package_changed'
        report['cases'].append('suite digest pinned before dispatch; changed package rejected before next request and later cases skipped')
        report['success']=True
    finally:
        server.shutdown(); server.server_close()
        if args.out: args.out.parent.mkdir(parents=True,exist_ok=True); args.out.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='scale'},indent=2))
    if 'scale' in report: print(json.dumps({k:v for k,v in report['scale'].items() if k!='run_ids'},indent=2))
if __name__=='__main__': main()
