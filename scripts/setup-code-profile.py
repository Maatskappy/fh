#!/usr/bin/env python3
"""Create an explicit isolated runtime profile. Never pulls an image or overwrites."""
import argparse, hashlib, json, os, pathlib, re
p=argparse.ArgumentParser()
p.add_argument('directory',type=pathlib.Path);p.add_argument('socket',type=pathlib.Path);p.add_argument('image')
p.add_argument('--node-image',help='also register the node runtime: an installed immutable official Node image, 22.15 or later')
p.add_argument('--node-version',default='22.15.0',help='the Node version in that image')
a=p.parse_args()
if not a.directory.is_absolute() or not a.socket.is_absolute() or not re.fullmatch(r'[a-zA-Z0-9./_-]+@sha256:[a-f0-9]{64}',a.image):p.error('Supply absolute private profile/socket paths and an immutable IMAGE@sha256:DIGEST')
if a.node_image and not re.fullmatch(r'[a-zA-Z0-9./_-]+@sha256:[a-f0-9]{64}',a.node_image):p.error('Supply the node image as an immutable IMAGE@sha256:DIGEST')
a.directory.mkdir(parents=True,exist_ok=True,mode=0o700)
s=a.directory.lstat()
if a.directory.is_symlink() or not a.directory.is_dir() or s.st_uid!=os.getuid() or s.st_mode&0o077:p.error('Profile must be a private owned directory')
for name in ('installation.json','local.json'):
 if os.path.lexists(a.directory/name):p.error(f'{name} already exists; nothing overwritten')
# The digest names the whole runtime policy. A node image joins it only when one is configured,
# so a python-only profile keeps the digest it always had.
policy=hashlib.sha256(json.dumps([str(a.socket),a.image,'stdlib','network-none']+([a.node_image,'builtin'] if a.node_image else []),separators=(',',':')).encode()).hexdigest()
binding={'id':'local','policyDigest':policy,'capabilities':{},'resources':{'runtime':'local-python'}}
config={'version':1,'docker':{'socketPath':str(a.socket)},'bindings':{'local':binding},'resources':{'local-python':{'kind':'runtime'}},'runtimeProfiles':{'python3':{'available':True,'version':'3.12.3','profile':'stdlib','python':'/usr/bin/python3','image':a.image,'stdlib':['json'],'resources':['runtime']}},'limits':{'maxTokens':100000,'maxSeconds':600,'maxToolCalls':2,'maxIterations':16,'maxOutputBytes':1048576,'maxDiagnosticBytes':65536}}
if a.node_image:
 binding['resources']['node-runtime']='local-node';config['resources']['local-node']={'kind':'runtime'}
 config['runtimeProfiles']['node']={'available':True,'version':a.node_version,'profile':'builtin','node':'/usr/local/bin/node','image':a.node_image,'builtins':['fs'],'resources':['node-runtime']}
for name,value in (('installation.json',config),('local.json',binding)):
 fd=os.open(a.directory/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:json.dump(value,f,indent=2);f.write('\n')
print(f'Created isolated code profile in {a.directory}; no image pulled or provider contacted.')
