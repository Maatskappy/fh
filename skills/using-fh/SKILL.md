---
name: using-fh
description: Use when a person or agent describes recurring follow-through, a repeatable check-and-revise task, or work that should stop at a verifiable outcome, even if the requester does not know Fasthands or fh.
---

# Use fh for repeatable work

Help the person identify a repeatable procedure before discussing CLI setup. A loop turns supplied input into a checkable outcome through portable steps and explicit limits. The definition describes the work and checks. The runner supplies accounts, tools, permissions, budgets and storage.

[workspace-repair](../../loops/workspace-repair/loop.json) checks a checkout, generates repairs from source and diagnostics, applies hash-guarded edits and rechecks. It allows three repair attempts.

The `fh-workspace/1` runner and operations are Zig, without Python or Docker. Registered fixed host argv can invoke npm, tsc, Zig, Git or another installed checker. Read the [workspace recipe](../../docs/loops.md#native-workspace-steps) for grants, setup and saved operations.

The caller can commit and push, or separately authorize registered Git suffix commands. Check available abilities and authority before promising execution.

Other possible uses may need more integrations:

| Work | Bounded outcome |
| --- | --- |
| PR follow-through | Check one review and CI cycle, attempt bounded repairs, then return `ready`, `blocked` or `needs_human` with evidence links. The procedure can repeat even for unique changes. |
| Release candidate | Run named checks, inspect artifact and changelog, fix finite mechanical issues, then return a verdict and unresolved items. Publishing requires separate authorization. |
| Research briefing | Revise against a saved rubric and sources for a small number of passes. Return a pass or the draft and remaining failures. |
| Expense claim | Check fields and receipts, ask once for missing data, then return complete or precise gaps. Sending and approval require the proper account and permission. |

## Shape the opportunity

Ask only what is needed to define one useful unit of work:

1. Identify the trigger and changing inputs: files, links or structured fields.
2. Identify observations and actions. Separate deterministic checks from inference. State what feedback later passes need.
3. Define a checkable outcome, including valid `not_ready` or `needs_human` results with reasons and evidence.
4. Set attempts or time bounds, required permissions and human decisions. Define what happens at exhaustion or uncertain effects.

Suggest a loop when multiple inputs share one procedure and output contract. It needs a finite stopping rule and explicit evidence flow. Leave one-off judgments and open-ended relationships as ordinary agent or human work.

Narrow indefinite monitoring, many triggers or complex business rules to one bounded outcome first. A loop can hand off its result without owning the entire process.

Before authoring, describe the idea in a few lines: input → steps and checks → output. Include maximum attempts, authority and work left to the person or another agent. Call it an idea until abilities and policy exist. Describing a process does not authorize effects.

## What the current fh can execute

Choose among four additive JSON formats:

| Format | Behavior |
| --- | --- |
| `loops/0.1` | Ordered infer and exact saved-code steps, isolated Python or native workspace operations, validated inputs and outputs, explicit bindings, one bounded repeat region with carry. |
| `loops/0.2` | Typed Jev decisions. |
| `loops/0.3` | Named `parallel` branches, per-element `map`, instruction files, `runtime:"node"`, and read-only workspace access through `requires:["workspace_read"]`. |
| `loops/0.4` | Explicit source minimum versions and standard-library or builtin modules. |

Composite branches and elements settle as `{status:"completed",output}` or `{status:"failed",error:{reason}}`. One failure does not fail the composite. Saved code judges partial results. Inner steps have paths such as `lenses/security/review` and `each[2]/judge`.

Native `wasm32-wasi-json/1` runs saved binaries without Docker, Node or Python. Retain source for remixing and rebuild explicitly. `runtime` and `file` select execution without fallback. See [runtime recipes](../../docs/code-runtimes.md).

fh keeps durable run records. Manifest, schemas and code define the procedure. Accounts, models, runtimes, permissions and limits belong to installation. Browser inference uses a registered local Moli grant.

These abilities are unsupported:

- Computer use, web search and browser bindings on code.
- Autonomous GitHub PR completion.
- Detached runner-driven work and automatic run resume.

Interactive chat and conversation `/resume` use native fx. Before authoring, check live `fh --help`, the [guide](../../docs/loops.md) and [author-loop](../author-loop/SKILL.md).

## Choose who does the thinking

Choose a driver per run, outside the package:

| Situation | Driver |
| --- | --- |
| You are the agent making the judgment | Prefer `--driver agent`. You supply your model and perform infer and decision steps. fh makes no model call, validates output, runs code and stores results. |
| No agent is available, or the operator wants fh's model | Use default `runner`. fh performs every step using installation settings. Its separate requests do not receive caller context. |

Read the [agent reference](references/agent-driver.md) for return shapes and answers:

~~~sh
fh run PACKAGE --input INPUT_FILE --bindings-id ID --driver agent --json   # returns run_id and the first ready steps
fh next RUN_ID --json                                                      # every step ready now, in path order
fh submit RUN_ID --path PATH --pass N --output FILE --json                 # FILE holds your output JSON; - reads stdin
fh get RUN_ID --json                                                       # the durable result
~~~

1. Read `next`: each ready step has `path`, `pass`, `kind`, resolved `input`, `output_schema` and either `instructions` or `questions`. Empty means terminal.
2. Perform the step from that input and its instructions alone. Ready composite branches and elements appear together, in path order, and can run in any order.
3. Submit the unchanged path and pass. Handle the answer below.
4. Continue until `completed`, `failed` or `stopped`. Agent-driven runs wait durably between calls. Losing the shell does not cancel them. Use `fh cancel RUN_ID` to stop one.

| Answer | Action |
| --- | --- |
| `accepted` | Read new ready steps. fh advanced and executed ready code. |
| `rejected` | Fix output using `issues`. Resubmit the same attempt. |
| `not_ready` | Call `next` for open attempts. |
| `conflict` | Keep the settled output returned as `committed`. |

`submit` exits 0 when accepted, 4 for other answers, or 2 for an error. `owner_busy` means another operation holds the installation. The requested operation did not start, though orphan bookkeeping may have occurred. Wait briefly and resend the command. This does not reject your output.

## Run a package with fh's own model

Inspect the manifest, code, schemas, input and possible effects first. Keep inputs, bindings, evidence and results outside the package. Every regular file contributes to the digest.

Use registered operator bindings and native fx model settings. `fh login codex` and `fh status` use native authentication.

`fh check` validates declarations and may probe an isolated runtime. It performs no inference, catalog request or package step. Run only after permissions and installation are ready:

~~~sh
fh check PACKAGE --bindings-id ID --json
fh run PACKAGE --input INPUT_FILE --bindings-id ID --json
fh get RUN_ID --json
~~~

PACKAGE uses its text alone:

| Argument | Meaning |
| --- | --- |
| Starts with `.` or `/` | Local path. Write `./NAME` or `./loops/NAME`. |
| No `/` | Installed name. |
| Otherwise | GitHub `OWNER/REPO[/PATH][@REF]`. |

If `loops/NAME` is both an address and a local folder, fh refuses and requests `./loops/NAME` for the folder.

`--json` returns one final result. Save stderr and exit status separately. `get` is authoritative.

| Status | Meaning |
| --- | --- |
| `completed` | Execution and output validation succeeded. Domain output can still be `ready:false`. |
| `failed` | Execution error. |
| `stopped` | Stop reason and partial evidence, without final output. |

Report run ID, digest, status, domain outcome, stop reason or error, and available effect receipts. Rejected checks and invocations may return only structured issues or an error.

If a foreground response is lost, inspect the accepted run ID with `fh get RUN_ID --json`. Closing a runner-driven foreground caller requests cancellation. A limit stop requires an operator decision. Do not invent override flags.

## Install a package and run it by name

Use `fh add SOURCE` to install into the profile. SOURCE is a local path beginning `./`, `../` or `/`, or GitHub `OWNER/REPO[/PATH][@REF]`. Read the [package guide](../../docs/packages.md) for source handling, refusals, locks and exit codes.

~~~sh
fh add SOURCE --json                        # inspects only: status confirmation_required, exit 2, nothing installed
fh add SOURCE --yes --digest DIGEST --json  # installs only the package that was inspected: status installed or unchanged
fh list --json
fh check NAME@VERSION --bindings-id ID --json
fh run NAME@VERSION --input INPUT_FILE --bindings-id ID --json
fh update NAME --json                       # inspects the new version the same way
fh update NAME --yes --digest DIGEST --json
fh remove NAME@VERSION
~~~

Follow this inspection procedure:

1. Run without `--yes`. Read name, version, digest, source, exact commit, steps and kinds, code files and runtimes, and required capabilities.
2. Confirm the package meets the task and the person has agreed to it. Otherwise stop and explain.
3. Use the returned `next_command` with `--yes --digest DIGEST`. Always pair those flags.

Without a terminal, add installs only with `--yes`. It fetches again before installing. `--digest` requires exactly the inspected bytes. A mismatch installs nothing and reports both digests. Inspect again. Never remove the digest to retry. Update follows the same rule. Chat `/add SOURCE --yes` requires `--digest`.

`fh run OWNER/REPO/PATH[@REF] --input INPUT_FILE --json` inspects first when away from a terminal. It returns `confirmation_required`, exits 2 and runs nothing. Review it as for add, then use its `next_command` with both confirmation flags.

An accepted address installs and runs as `NAME@VERSION`. Get, retry, next and submit use that installation. A source already installed with the same content runs without another question. Check fetches without installation. Batch and eval fetch and inspect once before cases. Chat `/run ADDRESS` follows the same rule. Model tools refuse addresses. Only the person can fetch and install.

Installation runs no package code and grants no capabilities or runtimes. Bindings still control execution.

Bare `NAME` always selects an installation, regardless of local folders. It chooses the highest all-numeric version or the newest install. `NAME@VERSION` selects exactly. Use the spelling reported by add or list, including case. Use `./NAME` for a folder.

Installed versions never change. Each load hashes files against their installed digest and refuses changed bytes. `fh remove NAME` works when one version is installed. Earlier run records remain.

## Many inputs, failures and recovery

Choose a command for repeated cases or recovery:

| Command | Behavior |
| --- | --- |
| `fh batch PACKAGE --cases FILE` | Run unchanged bytes on sequential inputs under one digest and binding. |
| `fh eval PACKAGE --cases FILE` | Also compare with independent labels. See [case workflows](../../docs/batch-evaluation.md) for syntax, budgets, results and exits. |
| `fh retry RUN_ID` | New linked whole run from retained input of a failed or stopped run, using its recorded provider and model. Never resume a step. Refuse uncertain usage or effects and changed packages or bindings. |
| `fh status` | Local Jev credential presence, without access verification. |

Failures expose the step, cause and retry guidance, plus input source and hash.

Use `fh settle RUN_ID --applied` or `--not-applied` after inspecting an uncertain effect. External, code, workspace or browser uncertainty blocks independent operations with `recovery_required`, naming run, step and effect. Model-only uncertainty prevents unsafe retry but leaves independent work available.

With multiple effects, add `--effect ID`. Settlement is the operator's decision. Inspect actual state or ask the person. Never guess. fh does not replay the run.

## Work on a real checkout

Register checkout authority outside the package:

~~~sh
fh setup workspace /absolute/grant.json --trust-host   # grant: workspace, files, named commands
fh check ./loops/workspace-repair --bindings-id workspace --json
~~~

A files-only grant needs no `--trust-host` and permits read-only `workspace_read`. Commands are trusted host programs inheriting environment, network and credentials. The workspace directory provides no sandbox.

Read [operations, receipts and limits](../../docs/workspace-loops.md). Autonomous review and CI follow-through are unsupported.

## Author a package

Read the [guide](../../docs/loops.md), [schema](../../packages/loops-contract/loop-0.1.schema.json) and [author-loop](../author-loop/SKILL.md) for exact syntax.

Put the checkable outcome in the output schema. Save deterministic assessment in code and pass feedback explicitly through bindings and carry. Check before an authorized run. Keep providers, credentials, budgets and installation handles outside the package.

For browser checks, declare an infer step with `requires:["browser"]`. Register installed Moli using `fh setup browser`, then use `--bindings-id local`. fh owns startup and cleanup.

The grant permits broad HTTP(S) navigation and real input without origin restrictions. Read [browser commands](../../docs/browser-capture.md#run-a-browser-loop) and [browser-check](../../loops/browser-check/loop.json). Bind URL and expected behavior externally. Require actual observations. Report `output.passed` separately from execution status. Browser inference needs no saved-code runtime.
