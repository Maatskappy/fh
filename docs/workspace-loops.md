# Native workspace Loops

Use `runtime:"fh-workspace/1"` to run checkout commands and apply guarded edits. This native Zig runtime needs no Python or Docker.

Saved JSON selects a named command from the operator's installation. Its installed executable and fixed argv can invoke Node, npm, Zig or Git. Native code gathers source and diagnostics. Inference proposes structured edits. Native code applies them.

## Register a workspace

Create grant JSON outside the package. Replace the example paths with the real checkout and executable:

```json
{
  "workspace": "/absolute/project",
  "files": ["src/example.ts"],
  "commands": {"typecheck": ["/absolute/path/to/npm", "run", "typecheck"]}
}
```

| Grant field | Authority |
| --- | --- |
| `workspace` | Canonical checkout identity and command working directory. The directory is not a sandbox. |
| `files` | Exact allowlist for source collection and native replacements. |
| `commands` | Named trusted host programs with fixed argv. They inherit your environment, filesystem, network and credentials, and can write beyond the file allowlist. |

Register only caller-authorized commands, source transmission and edits:

```sh
fh setup workspace /absolute/grant.json --trust-host
fh check ./loops/workspace-repair --bindings-id workspace --json
fh run ./loops/workspace-repair --input examples/workspace-repair-input.json --bindings-id workspace --json
fh get RUN_ID --json
```

A grant with commands requires `--trust-host`. A grant with only `files`, omitted `commands` or `"commands": {}` needs no trust flag. It registers read-only access for `infer` steps requiring `workspace_read`. Those steps can list, search and read granted files.

Read-only bindings contain no host commands. Checking or running `fh-workspace/1` against one fails with `workspace_read_only`.

Setup is native and noninteractive. It preserves existing credentials, limits and bindings. The default new binding is `workspace`. Choose another with `--bindings-id NAME`. Existing names are never overwritten. The ordinary `local` binding gains no workspace authority.

`check` inspects saved operations, executable metadata and listed file metadata. It launches no workspace command or model.

## Declare an operation

Save exactly `operation` and `command` in the operation file:

```json
{"operation":"check","command":"typecheck"}
```

| Operation | Action |
| --- | --- |
| `check` | Run the registered checker. A nonzero exit is valid domain failure that inference can repair. |
| `apply_check` | Apply structured edits, then run the checker. |
| `command` | Run an authorized action. A nonzero exit fails execution and skips later steps, so a failed commit cannot continue to push. |

Use a `kind:"code"` step with the saved file, `runtime:"fh-workspace/1"`, `requires:[]`, explicit input and an output schema. The file contributes to the package digest. It contains no executable path or account credentials.

This runtime is an fh extension. Other installations need compatible support. Independent runner portability is unverified.

## Read checker results

Every result contains `{passed,command,exit_code,stdout,stderr,diagnostic_truncated,files}`. A file snapshot contains `{path,sha256,content}`.

`passed` means exit zero. Judge CI, review and deployment readiness separately. fh retains applied invocation receipts and bounded exit diagnostics.

Source snapshots before and after a checker must match. A mismatch fails with `WorkspaceChanged`, preventing a pass about concurrently changed source.

## Apply edits

`apply_check` accepts `{"edits":[{"path":"src/example.ts","sha256":"ORIGINAL_64_HEX_HASH","content":"complete replacement"}]}`.

fh verifies every path and original hash before making the first edit. It rechecks each file immediately before atomic replacement. It refuses:

- Ungranted paths and duplicate edits.
- Missing files and symlinks.
- Stale original hashes.

These checks guard observed changes, but cannot cover every simultaneous-writer race. Coordinate checkout ownership with other actors.

## Recover uncertain effects

fh writes a durable `unknown` effect receipt before each edit and command. Receipt IDs follow step paths. A mapped step has one receipt per element.

| Observed outcome | Receipt |
| --- | --- |
| Stop, changed file or replaced workspace detected before replacement or command spawn | `not_applied` |
| Finished action | `applied` |
| Process died between action start and recording, or command was killed by cancellation or deadline | May remain `unknown` because partial work is possible. |

Any unknown workspace receipt blocks `check`, `run` and `submit` for every package on the installation. The `recovery_required` error names the run, step and effect and explains what to inspect.

Inspect the actual checkout, then record the outcome:

```sh
fh get RUN_ID --json                  # records an interrupted run as stopped
fh settle RUN_ID --applied            # the edit or command did take effect
fh settle RUN_ID --not-applied        # it did not
```

`settle` changes only that receipt and marks it `settled_by: operator`. With several uncertain effects, choose one with `--effect ID`. A run with no uncertain effect refuses settlement.

fh never resumes or replays this run. Start another when the checkout is in the intended state.

## Use the repair example

The shipped [workspace-repair](../loops/workspace-repair/loop.json) checks the checkout, binds actual source and diagnostics to inference, applies replacements and checks again. Its [external input](../examples/workspace-repair-input.json) supplies the goal.

Up to three repair passes carry fresh evidence. Success returns `output.check.passed:true`. Exhaustion stops with `iteration_limit`, no final output and saved partial evidence.

For an authorized commit or push, register each fixed Git argv under a distinct name. Add its `command` step after the repeat region. It runs once after the passing condition. Alternatively, inspect returned edits and checks, then commit or push yourself.

Setup enables only listed Git commands. Autonomous PR review and CI integration are unsupported.

## Limits

Workspace work stays within these policy bounds and the whole-run limits:

| Resource | Bound |
| --- | --- |
| Granted files | 16 |
| Commands | 16 |
| argv entries | 32 per command |
| File content | 65,536 UTF-8 bytes per file |
| Captured stdout | Smaller of half `maxOutputBytes` or 65,536 bytes |
| Retained stderr | Smaller of half `maxDiagnosticBytes` or 16,384 bytes. Truncation is reported |

A command exceeding stdout capacity finishes. Its invocation receipt becomes `applied`. A second `workspace_command_output_limit` receipt records the exit code, observed bytes and limit. The step fails with `output_limit` instead of returning cut output.

Larger contexts fail existing input, output or history limits. File replacements and command invocations consume the operation budget.
