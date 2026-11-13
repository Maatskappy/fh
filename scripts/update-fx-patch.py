#!/usr/bin/env python3
"""Regenerate cumulative application patch from the last audited revision."""
import pathlib, tempfile, subprocess, json, hashlib, sys
import importlib.util
spec = importlib.util.spec_from_file_location("fx_verify", pathlib.Path(__file__).resolve().parents[1] / "patches/fx/verify.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
root=pathlib.Path(__file__).resolve().parents[1]
base=sys.argv[1] if len(sys.argv)>1 else 'HEAD'
provenance=json.loads(subprocess.check_output(['git','show',f'{base}:vendor/fx/UPSTREAM.json'],cwd=root))
patch=subprocess.check_output(['git','show',f'{base}:{provenance["patch"]}'],cwd=root)
policy.require(hashlib.sha256(patch).hexdigest()==provenance['patchSha256'], 'audited patch hash mismatch')
policy.require(hashlib.sha256(subprocess.check_output(['git','show',f'{base}:vendor/fx/UPSTREAM_FILES.json'],cwd=root)).hexdigest() == policy.MANIFEST_SHA256, 'original manifest hash mismatch')
policy.patch_paths(patch, set(provenance["modifiedFiles"]))
manifest=json.loads(subprocess.check_output(['git','show',f'{base}:vendor/fx/UPSTREAM_FILES.json'],cwd=root))
original_hashes={item['path']:item['sha256'] for item in manifest['files']}
policy.require(hashlib.sha256((root/'vendor/fx/UPSTREAM_FILES.json').read_bytes()).hexdigest() == policy.MANIFEST_SHA256, 'current original manifest hash mismatch')
actual={str(path.relative_to(root/'vendor/fx')) for path in (root/'vendor/fx/src').rglob('*') if path.is_file()}
policy.require(actual == {path for path in original_hashes if path.startswith('src/')} | policy.APPROVED_ADDITIONS, 'untracked vendor source')
changed=subprocess.check_output(['git','diff','--name-only',base,'--','vendor/fx'],cwd=root).decode().splitlines()
modified=sorted(set(provenance['modifiedFiles']) | {name.removeprefix('vendor/fx/') for name in changed if name.removeprefix('vendor/fx/') in original_hashes})
policy.require(set(modified) == policy.APPROVED_FILES, 'modified files outside approved boundary')
with tempfile.TemporaryDirectory(prefix='fh-upstream-') as temp:
    original=pathlib.Path(temp)
    for name in modified:
        path=original/name;path.parent.mkdir(parents=True,exist_ok=True)
        path.write_bytes(subprocess.check_output(['git','show',f'{base}:vendor/fx/{name}'],cwd=root))
    subprocess.run(['patch','--batch','--reverse','--fuzz=0','-p1','-d',str(original)],input=patch,check=True,stdout=subprocess.DEVNULL)
    for name in modified:
        policy.require(hashlib.sha256((original/name).read_bytes()).hexdigest()==original_hashes[name], f'upstream baseline mismatch: {name}')
    policy.presentation_boundary(original, root/'vendor/fx')
    parts=[]
    for name in modified:
        result=subprocess.run(['diff','-u','--label',f'a/{name}','--label',f'b/{name}',str(original/name),str(root/'vendor/fx'/name)],stdout=subprocess.PIPE)
        if result.returncode not in (0,1):raise RuntimeError('diff failed')
        parts.append(result.stdout)
    updated=b''.join(parts)
policy.patch_paths(updated)
(root/provenance['patch']).write_bytes(updated)
provenance['modifiedFiles']=modified
provenance['addedFiles']=sorted(policy.APPROVED_ADDITIONS)
provenance['addedFileSha256']={name:hashlib.sha256((root/'vendor/fx'/name).read_bytes()).hexdigest() for name in sorted(policy.APPROVED_ADDITIONS)}
provenance['patchSha256']=hashlib.sha256(updated).hexdigest()
provenance['scope']='Native fx terminal, Agent, conversation worker, sessions, login and provider reused; fh conversation prompt through native prompt policy; bounded warm chat context using the original validated skill loader and complete built-in guidance; fh branding/default selection and isolated profile roots; curated native filesystem and Loop tools; in-process native Loop bridge and inference adapter sharing fx credentials/providers; first-paint code-only startup Loop/context, cached inert early-chat inventory and decoded-input preemption; shared native session/run HTTP pooling with credential/endpoint isolation, post-frame bounded connection-only warmup and truthful optional cache evidence; restricted browser Loop host using the unchanged fx agent kernel and foreground process supervisor with original capture CDP transport; renderer/input algorithms retained.'
(root/'vendor/fx/UPSTREAM.json').write_text(json.dumps(provenance,indent=2)+'\n')
