# loops/0.4

loops/0.4 retains all loops/0.3 step, composite, instruction-file, decision,
workspace_read, repetition and agent-driver semantics. Earlier formats remain
unchanged. Its only manifest addition is the required root `dependencies` object:

```json
"dependencies": {
  "runtimes": {
    "node": { "min_version": "22.15.0", "modules": ["fs"] }
  }
}
```

`runtimes` is a map with nonempty runtime names. Each entry has exactly
`min_version` (three numeric components MAJOR.MINOR.PATCH) and `modules` (a unique
array of nonempty module names). The map may be empty. Every source code runtime
used by any step, including parallel branches and map bodies, needs an entry.
Unused declared requirements are checked too. `fh-workspace/1` and
`wasm32-wasi-json/1` name execution contracts and must not appear in this map.

Before any package step or model dispatch, the runner checks the configured
runtime profile and minimum version, then its fixed retained interpreter probe
checks actual availability, modules and minimum version. A claimed profile
version cannot substitute for the actual probed or cached version. Requirements
are compared numerically. Missing or unsupported runtime profiles may be refused.

For `python3`, modules mean Python standard-library modules; for `node`, they mean
Node built-ins, such as `fs` or `fs/promises`. These are availability requirements,
not package-registry installation instructions or additional host grants. Local
library source stays among the retained package bytes. fh never installs npm or
pip dependencies, pulls runtime images, or falls back to a host interpreter.

## Set up a runtime

Native fh is Zig and needs no Node or Python interpreter. Register an optional
isolated source runtime with the [runtime setup guide](../loops.md).

Validate declarations with [loop-0.4.schema.json](../../packages/loops-contract/loop-0.4.schema.json),
found in `packages/loops-contract/` in a checkout. The native loader also checks
that declarations cover every source runtime used across steps.
