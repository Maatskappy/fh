#!/usr/bin/env python3
"""Native code-only check/run/get/reuse and actual terminal startup proof.

Uses a disposable empty profile by default. An optional explicit profile copies
only installation metadata; never reads credentials or uses a model. Executes
ordinary retained Wasm workspace-check and increment packages.
"""
import argparse, fcntl, hashlib, json, os, pathlib, pty, re, select, struct, subprocess, tempfile, termios, time
p=argparse.ArgumentParser()
p.add_argument('--binary',type=pathlib.Path,required=True)
p.add_argument('--profile',type=pathlib.Path)
p.add_argument('--evidence',type=pathlib.Path,required=True)
a=p.parse_args();binary=a.binary.resolve();bundle=binary.parent
original=(a.profile/'installation.json').read_bytes() if a.profile else None; original_hash=hashlib.sha256(original).hexdigest() if original else None
report={'format':'fh.native-product-evidence/0.1','binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'model_calls':0,'auth_calls':0,'runtime':'actual retained wasm32-wasi-json/1 artifact','runs':[]}
ansi=re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)')
with tempfile.TemporaryDirectory(prefix='fh-native-product-',dir='/private/tmp') as temporary:
 root=pathlib.Path(temporary); profile=root/'profile';profile.mkdir(mode=0o700)
 if original:
  (profile/'installation.json').write_bytes(original);os.chmod(profile/'installation.json',0o600)
 (profile/'settings.json').write_text(json.dumps({'auto_upgrade':False,'prompt_history':{'enabled':False},'session_titles':False,'notifications':{'turn_end':False}}));os.chmod(profile/'settings.json',0o600)
 env=dict(os.environ,FH_DATA_DIR=str(profile),TERM='xterm-256color')
 for key in ('FX_PROVIDER','FX_AUTH_MODE','FX_API_KEY','AI_GATEWAY_API_KEY','VERCEL_OIDC_TOKEN'):env.pop(key,None)
 def command(*args):
  start=time.perf_counter();result=subprocess.run([str(binary),*args],env=env,cwd=root,stdin=subprocess.DEVNULL,capture_output=True,timeout=15)
  if result.returncode:raise AssertionError((args,result.returncode,result.stdout.decode(),result.stderr.decode()))
  return json.loads(result.stdout),round((time.perf_counter()-start)*1000,2)
 package=bundle/'loops/increment-wasm'
 checked,ms=command('check',str(package),'--bindings-id','local','--json');assert checked.get('ok') is True,checked
 report['check_ms']=ms
 for number,target in ((2,3),(8,9)):
  input_file=root/f'input-{number}.json';input_file.write_text(json.dumps({'number':number}))
  result,ms=command('run',str(package),'--input',str(input_file),'--bindings-id','local','--json')
  assert result['status']=='completed',result
  assert result['output']=={'answer':target},result
  stored,get_ms=command('get',result['run_id'],'--json');assert stored['output']==result['output'] and stored['status']=='completed',stored
  report['runs'].append({'run_id':result['run_id'],'output':result['output'],'package':result.get('package'),'package_digest':result.get('package_digest'),'run_ms':ms,'get_ms':get_ms,'effects':result.get('effects',[])})
 first,second=report['runs'];assert (first['package_digest'] or first['package']['digest'])==(second['package_digest'] or second['package']['digest'])
 workspace=root/'workspace';(workspace/'loops/broken').mkdir(parents=True);(workspace/'loops/broken/loop.json').write_text('{broken')
 master,slave=pty.openpty();before=termios.tcgetattr(slave);fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,100,0,0))
 started=time.perf_counter();child=subprocess.Popen([str(binary)],stdin=slave,stdout=slave,stderr=subprocess.PIPE,cwd=workspace,env=env,start_new_session=True)
 raw=bytearray();pending=b'';paint=working=hint=None;focus_sent=False
 def drain(duration=.02):
  global pending,paint,working,hint,focus_sent
  until=time.monotonic()+duration
  while time.monotonic()<until:
   ready,_,_=select.select([master],[],[],min(.01,max(0,until-time.monotonic())))
   if not ready:continue
   try:chunk=os.read(master,65536)
   except OSError:return
   if not chunk:return
   raw.extend(chunk);probe=pending+chunk
   for q in re.finditer(rb'\x1b\[(\?)?6n',probe):os.write(master,b'\x1b['+(b'?' if q.group(1) else b'')+b'1;1R')
   pending=probe[-4:];text=ansi.sub(b'',bytes(raw)).decode('utf8','replace');elapsed=round((time.perf_counter()-started)*1000,2)
   if paint is None and 'Run /help' in text:
    paint=elapsed;os.write(master,b'\x1b[I\x1b[O\x1b[1;1R');focus_sent=True
   if working is None and 'Checking workspace' in text:working=elapsed
   if hint is None and 'A nearby Loop has an obvious issue' in text:hint=elapsed
 try:
  deadline=time.monotonic()+5
  while hint is None and child.poll() is None and time.monotonic()<deadline:drain()
  text=ansi.sub(b'',bytes(raw)).decode('utf8','replace')
  assert hint is not None,(child.poll(),text[-4000:])
  assert 'paused while we chat' not in text and 'unavailable' not in text,text
  os.write(master,b'/quit\r')
  deadline=time.monotonic()+4
  while child.poll() is None and time.monotonic()<deadline:drain()
  assert child.poll()==0,child.poll();assert termios.tcgetattr(slave)==before,'terminal not restored'
  assert not child.stderr.read(),'unexpected stderr'
  report['startup']={'first_paint_ms':paint,'working_ms':working,'hint_ms':hint,'cursor_focus_reports_ignored':focus_sent,'human_chat_inputs':0,'termios_restored':True}
  report['startup_records']=[]
  for file in (profile/'native-runs').glob('*.json'):
   record=json.loads(file.read_text())
   if record.get('output',{}).get('suggestion')=='A nearby Loop has an obvious issue. Use /check to inspect it.':
    assert record['status']=='completed' and record['output']['issues'][0]['code']=='malformed_json',record
    assert record['model_request_dispatches']==0 and record['model_request_dispatches_complete'] is True,record
    assert record.get('effects',[])==[],record
    assert record['attempts'][0]['code_execution']['profile']=='wasm32-wasi-json/1',record
    report['startup_records'].append({'run_id':record['run_id'],'status':record['status'],'package_digest':record['package_digest'],'output':record['output'],'effects':record.get('effects',[])})
  assert len(report['startup_records'])==1,'ordinary workspace Loop durable result missing'
 finally:
  if child.poll() is None:child.kill();child.wait()
  os.close(master);os.close(slave)
 if original: assert (profile/'installation.json').read_bytes()==original,'copied policy changed'
 else: assert not (profile/'installation.json').exists(),'unexpected runtime registration'
if original: assert (a.profile/'installation.json').read_bytes()==original,'operator policy changed'
report['operator_policy_unchanged']=original_hash
report['limitations']='No live inference/login/authoring or independent runner claim. Code-only journey uses retained Wasm with no source runtime.'
a.evidence.parent.mkdir(parents=True,exist_ok=True);a.evidence.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ('check_ms','startup','operator_policy_unchanged')}))
