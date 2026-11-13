# Writing and running Loops with fh

Use `fh` to author in chat. Direct commands run `loops/0.1`–`loops/0.4` JSON without chat history. fh derives from native fx. See [model setup](model-setup.md).

## A package

Create a dedicated directory containing `loop.json` and optional code and schema files. Keep caller inputs, bindings, outputs and evidence outside it. Every regular file contributes to the immutable SHA256 digest.

fh rejects symlinks, traversal, duplicate JSON keys, comments and unsupported execution fields.

Start with [increment-wasm](../loops/increment-wasm/loop.json): `{"number":2}` returns `{"answer":3}` from a retained binary without a language runtime. [increment-source](../loops/increment-source/loop.json) does the same in editable Node with explicit dependencies.

Read [runtime recipes](code-runtimes.md) (`docs_read document:"runtime_guide"`) for manifests, setup, Zig 0.16.0 rebuilds, hashes and remixing. `runtime` and `file` select exactly one implementation. There is no fallback or automatic compilation.

Use the [0.1 schema](../packages/loops-contract/loop-0.1.schema.json) and [carry contract](contracts/loops-0.1-addendum.md) for basic packages. [carry-counter](../loops/carry-counter/loop.json) and [description-refinement](../loops/description-refinement/loop.json) remain supported. Use [0.4](contracts/loops-0.4.md) for explicit source dependencies. `docs_read document:"runtime_schema"` returns its schema.

fh validates JSON output. A valid exit-zero domain failure is successful execution.

## Bindings and carry

Bind only the data a step needs:

| Binding | Meaning |
| --- | --- |
| Exact singleton `{"from":"/input/number"}` | Select with an RFC6901 pointer. Missing pointers fail instead of becoming null. |
| Structured object or array | Bind members recursively. |
| Exact singleton `{"value":...}` | Literal data, never interpreted again. |
| `{"from":123}` | Ordinary data. |

Steps can read validated `input` and current validated `steps/ID/output`. Earlier attempts remain history. Direct inference receives no caller chat, credentials or hidden memory. Registered workspace commands inherit the launching host environment.

A package can repeat one inclusive region. Declare `from`, `through`, `until` and positive `max_iterations`. Prefix and suffix run once. Boolean `until:true` continues to the suffix. Exhaustion stops with `iteration_limit` and skips it.

Use `repeat.carry.initial` and `next` for feedback:

1. Resolve `initial` once after the prefix.
2. Give every step in a pass the same read-only `/carry` snapshot.
3. If `until` is false and another pass is allowed, resolve and persist `next` before clearing region outputs.

True-until and exhaustion never evaluate `next`. Prefix, suffix and root output cannot use carry. Bind previous drafts and assessment feedback explicitly. Inference does not remember them.

## Warm inference steps

Prepare complete context before the first request. Saved code can prepare rules and evidence. Bind its validated output into inference input. The runner adds instructions and the retained output schema. Inference has no setup tools, ambient chat or implicit workspace discovery.

The [warm-context example](../loops/warm-context/loop.json) prepares supplied check evidence. Keep its [input](../examples/warm-context-input.json) outside the package. Run `fh run ./loops/warm-context --input examples/warm-context-input.json --bindings-id local --json`, then `fh get RUN_ID --json`.

## Native workspace steps

Use `runtime:"fh-workspace/1"` for native Zig checkout checks and guarded repairs without Python or Docker. Saved JSON selects fixed registered host argv, such as npm, tsc, Zig or Git. Native code collects source and diagnostics, then checks original SHA256 values before applying inference-proposed replacements.

Register an external grant with `fh setup workspace GRANT.json --trust-host`. It names an absolute `workspace`, allowed relative `files` and named fixed `commands`. Use `--bindings-id workspace` to check and run. Host commands inherit filesystem access, environment, network and credentials. cwd provides no sandbox. Preflight runs no command or model.

Read [workspace fields, results and limits](workspace-loops.md), also available as `docs_read document:"workspace_guide"`.

[workspace-repair](../loops/workspace-repair/loop.json) uses an [external goal](../examples/workspace-repair-input.json) for check → inference edits → native apply and recheck. It allows three repair passes with fresh carry. Success returns `output.check.passed:true`. Exhaustion leaves partial evidence. Authorized Git suffix steps run once. Inspect and reconcile uncertain effects before replay.

## Decision steps (loops/0.2)

Use `kind:"decision"` with the [0.2 schema](../packages/loops-contract/loop-0.2.schema.json) and [contract](contracts/loops-0.2.md). Bind complete state through input and declare a static questions map.

| Question | Answer |
| --- | --- |
| `choice` | Labelled option. |
| `score` | Position among ordered levels. |
| `noul` | Yes/no probability. |

One request can ask these together. Output is `{model,answers}`, retaining typed values, probabilities and confidence where supplied. Saved code owns thresholds and repeat-until booleans.

```json
{"id":"gate","kind":"decision","requires":[],"input":{"from":"/input"},"questions":{"ready":{"type":"noul","instructions":"Does the supplied evidence satisfy every requirement?"}},"output":{"schema":{"type":"object","required":["model","answers"]}}}
```

Native decisions use TypeSafe's official Jev endpoint and default pinned model `jev-1.13.0`. Use `fh setup jev` for a hidden local key, or launch with `TYPESAFE_API_KEY`. Codex login supplies no TypeSafe access.

Optional `installation.json` policy is `"decision":{"provider":"typesafe","model":"jev-1.13.0","apiKeyEnv":"TYPESAFE_API_KEY"}`. Keep it outside portable packages.

Check validates declarations without secrets or network requests. An actual decision makes one bounded POST with no retries or setup tools. It shares the remaining token budget, deadline and cancellation. Usage is recorded even when validation fails. Uncertain delivery or usage stops without replay.

[decision-gate](../loops/decision-gate/loop.json) applies a saved-code confidence threshold to a draft. Use its [external sample](../examples/decision-gate-input.json): `fh run ./loops/decision-gate --input examples/decision-gate-input.json --bindings-id local --json`. Low confidence or insufficient evidence returns review. Evaluate the example threshold for your task.

## Parallel work and agent drivers (loops/0.3)

Use `format:"loops/0.3"` for these additions. See the [schema](../packages/loops-contract/loop-0.3.schema.json) and [contract](contracts/loops-0.3.md).

| Field or kind | Behavior |
| --- | --- |
| `parallel` | Named `branches`, each an ordered step list. Siblings cannot read one another. |
| `map` | Bind an array with `over`. Inner `steps` read `/item` and `/index`. |
| `instructions:{"file":"prompt.md"}` | Retained prompt file. |
| `runtime:"node"` | ES module default export receives input and returns output. |
| `requires:["workspace_read"]` on infer | Read-only files in the binding's registered workspace. |

A failed branch or element does not fail the composite. Each result is `{status,output}` or `{status:"failed",error:{reason}}`. Saved code judges partial results.

Use `fh run PACKAGE --driver agent` to supply inference outside fh without model calls from fh. Read ready steps with `fh next RUN`. Submit each using `fh submit RUN --path PATH --pass N --output FILE`.

| Answer | Next action |
| --- | --- |
| `accepted` | fh advances and runs ready code. |
| `rejected` | Fix schema issues and resubmit. |
| `not_ready` | Read current ready steps. |
| `conflict` | Inspect the committed output. |

Agent-driven runs wait durably between calls, even after shell loss. `fh cancel RUN` stops one.

## Browser inference

Declare `requires:["browser"]` on infer. Bind the URL and expected behavior as input. Register installed Moli with `fh setup browser`. Use `--bindings-id local` for check and run.

Check starts no browser or model. Run starts Moli lazily, shares it across steps and iterations, then reaps it before terminal publication. Keep binary, CDP and provider details outside the package. Do not start Moli manually.

Read [browser actions and limits](browser-capture.md#run-a-browser-loop). The grant allows broad HTTP(S) destinations. Default policy allows two tool calls for the whole run: inspect controls, then batch known keys.

[browser-check](../loops/browser-check/loop.json) has [external input](../examples/browser-check-input.json) and a [fixture](../examples/browser-check/fixture.html). Require actual observations. Report domain rejection separately from execution error. Browser inference needs no code runtime. Browser bindings on code, computer bindings, web-search bindings and cloud bindings are unsupported.

## Noninteractive CLI

Check a package, run it and read the authoritative result:

```sh
fh check PACKAGE --bindings-id local --json
fh run PACKAGE --input /absolute/input.json --bindings-id local --json
fh get RUN_ID --json
```

Input validation precedes preflight, model access and probes. Declaration-only checks write no run storage. Isolated runtime probes record effects. Checks validate declarations and may audit isolated runtimes, but never execute package code.

Tool-free inference (`requires:[]`) uses native fx Codex, Grok, Gateway or configured OpenAI-compatible providers. `fh setup` configures login or API-key access. Chat and Loops share credentials and native transport.

| Provider detail | Behavior |
| --- | --- |
| Configured endpoints | Receive JSON schema in instructions. Native validation checks returned output. Their original codec has no structured-format, reasoning or Fast controls. |
| Native defaults | `gpt-6-luna`, medium effort, Fast. Inherited from native model settings. |
| Inspect or change | `fh status`, `fh models`, or `/model` to change. Keep model IDs from old receipts out of packages. |
| Inference schema `$ref` | Explicit adapter preflight failure. Native validation still supports package-local references. |

Workspace bindings can register authorized Git commands. Autonomous PR completion is unsupported.

`--json` returns one result. `--events` emits the accepted ID and final result. Capture stderr and exit status. Stopped results are partial. `get` is authoritative.

New work and `get` stop abandoned runs under leases without replay. Live owners stay busy. Waiting agents keep waiting. Declaration-only checks report interruption read-only.

Unknown provider outcomes or accounting bar retry. Inspect unknown local effects and use `fh settle`. Runner-driven runs stay foreground-owned. Caller closure requests cancellation. Detached execution and resume are unsupported.

## Readiness checks

Define the evidence contract before collecting input:

- Target revision, included objects and collection time.
- Required sources and complete-snapshot meaning.
- Each source's revision and collection time.

Missing reviews, unavailable checks or partial snapshots leave readiness unverified. They do not establish an observed defect. Outstanding required edits mean not ready. Resolve findings using fresh evidence for the changed revision.

Completed execution can return rejection or an unverified result. Distinguish successful empty collection, collection failure and uncertain effects. An empty array alone cannot do this.

Before changing questions or thresholds, evaluate independently labelled cases:

- Complete pass and observed defect.
- Stale or wrong-revision evidence and missing sources.
- Successful empty collection and collection failure.
- Outstanding edits.

Derive labels from the caller's contract. Live model evaluation needs separate authorization. Schema checks and deterministic fixtures do not measure model judgment.

File inputs must be strict JSON within 1,048,576 bytes. Oversize input returns `invalid_input` before provider selection, preflight or run creation. The error includes observed bytes, the unchanged limit and a bounded-snapshot hint.

fh never truncates or splits input automatically. Smaller snapshots must retain scope, freshness, identity and completeness metadata. Chunking changes the evidence. A global readiness verdict requires an explicit aggregation contract covering all chunks and missing or failed chunks.

Run and get retain configured `selection` for compatibility. Dispatch accounting has these meanings:

| Field | Meaning |
| --- | --- |
| `model_request_dispatches` | Recorded infer-provider and decision-transport calls, including failures. Excludes tokens, authentication and provider-internal retries. Does not prove network delivery. |
| `model_request_dispatches_complete:true` | Foreground runner settled and saved the count. Pure code terminal results have a complete zero. |
| Incomplete count | Active, crashed or recovery record. Zero cannot establish absence of requests. |
| `failure_cause` | Original cause retained when available under unknown usage. Inspect before retrying. |

## Authoring decision questions

Read [Jev question design](../skills/author-loop/references/jev-questions.md) before writing declarations. Follow TypeSafe guidance: one semantic judgment per question, relevant state, backticked paths and explicit criteria.

Ask independent questions together. Combine answers in saved code. IDs are not model context. Score levels need self-contained descriptions. Code owns counts, dates and exact rules. Test labelled cases, missing evidence and Choice option permutations. `fh check` validates declarations only.

## Installed policy

Installation owns credentials, providers, resource handles and spending policy. Packages define the procedure. Never invent accounts, weaken limits or pull images during checks.

| Setting or record | Location or bound |
| --- | --- |
| Profile | `~/.fh`. Override with an absolute private `FH_DATA_DIR`. |
| `installation.json` | Runtime, resource and binding registrations. Native authentication is separate. |
| `limits.maxTokens` | Default 100,000 input plus output tokens per run. |
| Native records | Private durable `native-runs/` under the profile. |
| Storage admission | 10,000 records and 1 GiB. Reserve 64 MiB before admitting a run. Existing records remain intact. Capacity fails admission. |

For disposable code-only tests, copy installation metadata only, never credential files.

Isolated Python and Node use pinned images without network, with read-only root and package, bounded resources and explicit filesystem grants. Containers receive no host credentials, home or Docker socket. Writable grants require tracking and reconciliation. Unsupported grants fail.

Effects are journaled before dispatch. Uncertain records stay preserved without automatic replay. Package, schema and code snapshots plus actual usage identify what ran. Processes sharing a profile honor a foreground lock.

Use `fh login codex` and `fh status` for native fx authentication. Loop inference receives only instructions, bound input, retained response schema and supported tools. It shares the run's budget and deadline.

fx records conversation usage and bounds agent steps. A shared token allowance across conversation and delegated Loop work is not implemented.

Native schema support is bounded:

| Supported | Unsupported at check time |
| --- | --- |
| Type, enum, const. Numeric, string, object and array constraints. Bounded Unicode patterns. AllOf, anyOf, oneOf, not, if. Retained package-local references | Unsupported keywords and vocabularies. Dynamic references. Nested `$id`. Unevaluated-property and unevaluated-item rules |

Format is annotation only. Schemas never fetch network resources.

## Reuse a package

Run unchanged bytes on two independent inputs. Read `get`, compare digests and expected outputs. Report run IDs, verdicts and uncertain effects.

Fixtures, live integration tests and independent runner checks cover different behavior. See [case workflows](batch-evaluation.md) for batch, eval, retry and Jev status.

## Code runtime selection

Source `python3` and `node` need registered isolated images. Native workspace and `wasm32-wasi-json/1` need no language runtime.

[0.4 dependencies](contracts/loops-0.4.md) declare source minimum versions and standard-library or builtin modules. Earlier formats still work. Read [runtime recipes](code-runtimes.md) before authoring. Checks never install dependencies.
