#!/usr/bin/env python3
"""Install bundled agent guides without Node or overwriting existing skills."""
import argparse, os, pathlib, re, shutil, tempfile
parser = argparse.ArgumentParser()
parser.add_argument('--dest', type=pathlib.Path, default=pathlib.Path.home()/'.agents/skills')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
dest = args.dest
if not dest.is_absolute(): parser.error('--dest must be absolute')
names = ('using-fh','author-loop')
examples = ('hello','minimal-infer-code','carry-counter','description-refinement','warm-context','decision-gate','browser-check','workspace-repair','increment-source','increment-wasm','workspace-check')
def read(relative):
    p = root / relative
    if p.is_symlink() or not p.is_file(): raise ValueError(f'Missing regular bundled file: {p}')
    return p.read_text()
def refs(text):
    return (text.replace('../../docs/loops.md','references/loops.md')
        .replace('../../docs/browser-capture.md','references/browser-capture.md')
        .replace('../../docs/workspace-loops.md','references/workspace-loops.md')
        .replace('../../docs/batch-evaluation.md','references/batch-evaluation.md')
        .replace('../../docs/packages.md','references/packages.md')
        .replace('../../docs/code-runtimes.md','references/code-runtimes.md')
        .replace('../../packages/loops-contract/loop-0.1.schema.json','references/loop-0.1.schema.json')
        .replace('../../packages/loops-contract/loop-0.2.schema.json','references/loop-0.2.schema.json')
        .replace('../../packages/loops-contract/loop-0.3.schema.json','references/loop-0.3.schema.json')
        .replace('../../packages/loops-contract/loop-0.4.schema.json','references/loop-0.4.schema.json')
        .replace('../author-loop/SKILL.md','references/author-loop.md')
        .replace('../../loops/','references/loops/'))
scratch = None
reserved = []
try:
    entries = {name: read(f'skills/{name}/SKILL.md') for name in names}
    guide = read('docs/loops.md')
    browser_guide = read('docs/browser-capture.md')
    workspace_guide = read('docs/workspace-loops.md')
    batch_guide = read('docs/batch-evaluation.md')
    decision_guide = read('skills/author-loop/references/jev-questions.md')
    contract = read('packages/loops-contract/loop-0.1.schema.json')
    decision_contract = read('packages/loops-contract/loop-0.2.schema.json')
    runtime_contract = read('packages/loops-contract/loop-0.4.schema.json')
    runtime_guide = read('docs/code-runtimes.md')
    parallel_contract = read('packages/loops-contract/loop-0.3.schema.json')
    parallel_guide = read('skills/author-loop/references/loops-0.3.md')
    driver_guide = read('skills/using-fh/references/agent-driver.md')
    packages_guide = read('docs/packages.md')
    sample_inputs = {filename: read('examples/'+filename) for filename in ('warm-context-input.json','decision-gate-input.json','browser-check-input.json','browser-capture.json','workspace-repair-input.json','decision-gate-cases.json')}
    for name in names:
        if os.path.lexists(dest/name): raise ValueError(f'Skill already exists: {dest/name}; move it aside or choose another --dest.')
    if os.path.lexists(dest) and (dest.is_symlink() or not dest.is_dir()): raise ValueError('Skill root must be a directory, not a symlink.')
    for example in examples:
        if not (root/'loops'/example/'loop.json').is_file(): raise ValueError('Use a complete fh bundle.')
    dest.mkdir(parents=True,exist_ok=True)
    scratch = pathlib.Path(tempfile.mkdtemp(prefix='.fh-skills-',dir=dest))
    for name in names:
        skill = scratch/name; reference = skill/'references'; reference.mkdir(parents=True)
        shutil.copyfile(root/'LICENSE', skill/'LICENSE')
        (skill/'NOTICE').write_text(
            'Fasthands agent guides\n\n'
            'fh-authored guides and package additions are Apache-2.0; see LICENSE.\n'
            'Included upstream material retains its own licenses and notices.\n'
            'The copied increment-source, increment-wasm and workspace-check packages\n'
            'carry their NOTICE, LICENSE and applicable complete third-party texts\n'
            'under references/loops/. These cover embedded Zig code and the\n'
            'workspace-check Unicode/Python-derived data; retain them when copying.\n'
            'Wasmtime 48.0.8 (Apache-2.0 WITH LLVM-exception) host attribution and\n'
            'complete license are in references/licenses/wasmtime/README.md and\n'
            'references/licenses/wasmtime/LICENSE. The native host is supplied separately.\n')
        (skill/'SKILL.md').write_text(refs(entries[name]))
        (reference/'loops.md').write_text(guide.replace('../packages/loops-contract/loop-0.1.schema.json','./loop-0.1.schema.json').replace('../packages/loops-contract/loop-0.2.schema.json','./loop-0.2.schema.json').replace('../packages/loops-contract/loop-0.3.schema.json','./loop-0.3.schema.json').replace('../packages/loops-contract/loop-0.4.schema.json','./loop-0.4.schema.json').replace('../loops/','./loops/').replace('../examples/','./examples/').replace('../skills/author-loop/references/jev-questions.md','./jev-questions.md'))
        (reference/'batch-evaluation.md').write_text(batch_guide)
        (reference/'packages.md').write_text(packages_guide)
        (reference/'workspace-loops.md').write_text(workspace_guide.replace('../examples/','./examples/').replace('../loops/','./loops/'))
        (reference/'browser-capture.md').write_text(browser_guide.replace('../examples/','./examples/').replace('../loops/','./loops/'))
        (reference/'jev-questions.md').write_text(decision_guide.replace('../../../docs/contracts/','contracts/'))
        (reference/'loop-0.1.schema.json').write_text(contract)
        (reference/'loop-0.2.schema.json').write_text(decision_contract)
        (reference/'loop-0.3.schema.json').write_text(parallel_contract)
        (reference/'loop-0.4.schema.json').write_text(runtime_contract)
        (reference/'code-runtimes.md').write_text(runtime_guide.replace('../loops/','./loops/').replace('../packages/loops-contract/','./'))
        (reference/'loops-0.3.md').write_text(parallel_guide.replace('../../../docs/contracts/','contracts/').replace('../../../packages/loops-contract/','./'))
        (reference/'agent-driver.md').write_text(driver_guide.replace('../../../docs/contracts/','contracts/'))
        (reference/'examples').mkdir()
        for filename, data in sample_inputs.items():
            (reference/'examples'/filename).write_text(data)
        shutil.copytree(root/'examples/browser-check',reference/'examples/browser-check')
        shutil.copytree(root/'docs/contracts',reference/'contracts')
        # The 0.3 contract links its schema and the checkout-only conformance fixtures.
        parallel = reference/'contracts/loops-0.3.md'
        parallel.write_text(re.sub(r'\[([^\]]*)\]\(\.\./\.\./packages/loops-contract/0\.3/\)',r'\1',parallel.read_text().replace('../../packages/loops-contract/loop-0.3.schema.json','../loop-0.3.schema.json')))
        runtime = reference/'contracts/loops-0.4.md'
        runtime.write_text(runtime.read_text().replace('../../packages/loops-contract/loop-0.4.schema.json','../loop-0.4.schema.json'))
        wasm = reference/'contracts/wasm32-wasi-json-1.md'
        wasm.write_text(wasm.read_text().replace('../../licenses/wasmtime/README.md','../licenses/wasmtime/README.md'))
        shutil.copytree(root/'licenses/wasmtime', reference/'licenses/wasmtime')
        for example in examples:
            shutil.copytree(root/'loops'/example,reference/'loops'/example)
        if name == 'using-fh': (reference/'author-loop.md').write_text(refs(entries['author-loop']).replace('references/','./'))
        for p in skill.rglob('*.md'):
            for link in re.findall(r'\[[^\]]*\]\(([^)]+)\)',p.read_text()):
                if re.match(r'^[a-z]+:|^#',link): continue
                target = (p.parent/link.split('#')[0]).resolve()
                if not target.is_relative_to(skill.resolve()) or not target.is_file(): raise ValueError(f'Unresolved skill reference: {link}')
    for name in names:
        p = dest/name; p.mkdir(); reserved.append((p,p.stat().st_ino))
    for name in names: os.rename(scratch/name,dest/name)
    shutil.rmtree(scratch); scratch = None; reserved.clear()
    for name in names: print(f'Installed {dest/name}')
    print('Refresh your agent host skill inventory. Copying does not prove selection.')
except Exception as error:
    for p,inode in reserved:
        if p.exists() and p.stat().st_ino == inode: p.rmdir()
    if scratch: shutil.rmtree(scratch)
    parser.exit(2,f'{error}\n')
