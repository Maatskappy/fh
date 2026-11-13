# Authoring loops/0.3 packages

Set `"format": "loops/0.3"` when you need the additions below. Bindings, carry, one repeat region, decisions, validation and run records keep their earlier meanings.

Read the [contract](../../../docs/contracts/loops-0.3.md) for authority and the [schema](../../../packages/loops-contract/loop-0.3.schema.json) for declarations enforced by check. In a checkout, the schema is `packages/loops-contract/loop-0.3.schema.json`.

## `parallel`: named branches that start together

Use `parallel` for named branches that begin together:

```json
{"id": "lenses", "kind": "parallel",
 "branches": {
   "security":    [{"id": "security_review", "kind": "infer", "requires": [], "instructions": {"file": "prompts/security.md"}, "input": {"from": "/input"}, "output": {"schema": {"type": "object", "required": ["findings"]}}}],
   "correctness": [{"id": "correctness_review", "kind": "infer", "requires": [], "instructions": {"file": "prompts/correctness.md"}, "input": {"from": "/input"}, "output": {"schema": {"type": "object", "required": ["findings"]}}}]
 }}
```

`branches` must be a nonempty object. Each branch is a nonempty ordered step list, including any nested parallel or map steps. Steps within a branch run in order. Its result is the last output.

The parallel step declares neither input nor an output schema.

## `map`: the same steps once per array element

Use `map` to apply ordered steps to each bound element:

```json
{"id": "each", "kind": "map",
 "over": {"from": "/steps/roster/output/items"},
 "steps": [{"id": "judge", "kind": "infer", "requires": [], "instructions": "Judge the bound item.",
            "input": {"item": {"from": "/item"}, "position": {"from": "/index"}},
            "output": {"schema": {"type": "object", "required": ["verdict"], "properties": {"verdict": {"type": "string"}}, "additionalProperties": false}}}]}
```

| Field or binding | Rule |
| --- | --- |
| `over` | Must resolve to an array. Otherwise the step fails with `invalid_map_input`. |
| `/item` | Current element. Available only inside the steps. |
| `/index` | Zero-based position. Available only inside the steps. |
| Empty array | Valid. Returns `[]`. |
| Concurrency | Runner policy. Packages cannot set it. |

## Settled results

Inspect every branch or element status when a composite completes. It waits for all results, and does not fail merely because a child failed.

| Composite | Output |
| --- | --- |
| `parallel` | `{"<branch>": <result>, ...}` in declared order. |
| `map` | `[<result>, ...]` in element order. |
| Successful result | `{"status": "completed", "output": <value>}` |
| Failed result | `{"status": "failed", "error": {"reason": "<reason>"}}` |

Reasons use run vocabulary such as `invalid_output`, `missing_binding`, `invalid_binding`, `code_exit` and `execution_failed`.

A branch stops at its first failed step. Read results with ordinary bindings, such as `/steps/lenses/output/security/output` or `/steps/each/output/0/status`.

Always follow a composite with saved code that judges partial results. Decide whether a failed lens blocks the verdict, reduces confidence or remains an evidence gap. Bind the whole composite output, including statuses. Reading only output members can hide failure as “nothing found”.

Cancellation, deadline, token budget and uncertain effects stop the entire run. The composite does not complete in these cases.

## What a step can see

Keep each branch independent of siblings:

| Scope | Available data |
| --- | --- |
| Inside branch or element | Validated input, outputs completed before the composite, and earlier outputs in the same branch or element. |
| Sibling branch or other element | Unavailable. A binding fails the branch with `missing_binding`. |
| After composite completion | Composite output only. Inner outputs are unavailable. |
| Nested in a repeat-region step | `/carry` is available. |

Step IDs must be unique at every depth. Neither IDs nor branch names may contain `/`, `[` or `]`.

The single repeat region stays at top level. Its `from` and `through` name top-level steps. A composite can be in that region. Each pass reruns all its children fresh.

## Paths

Use paths to identify run positions in traces, events, effect receipts and agent-driver calls:

| Position | Path |
| --- | --- |
| Top-level step | `review` |
| Branch step | `lenses/security/security_review` |
| Element step | `each[2]/judge` |
| Nested step | `review/lenses/security/scan[2]/check` |

## Instructions from a file

Use `instructions: {"file": "prompts/review.md"}` for long infer instructions. The runner reads exact UTF-8 text from a package-local path. The file contributes to the digest. Keep one prompt per file for reviewable changes.

## `runtime: "node"`

Save an ES module whose default export receives validated bound input and returns or resolves output:

```js
export default function (input) {
  return { said: input.word.toUpperCase() }
}
```

| Requirement | Rule |
| --- | --- |
| Errors | Thrown errors become `code_exit`. Returned domain verdicts, such as `{ok: false}`, succeed. |
| Imports | Package-local files and Node builtins only. No npm dependencies. |
| Isolation | Same container as `python3`, with no network and read-only package. Import checking enforces the contract. The container provides isolation. |
| Capabilities | Use `requires: []`. |

## `workspace_read` on an infer step

Declare `"requires": ["workspace_read"]` to list, search and read registered workspace files. Access is read-only. The package names no tools, paths or workspace.

The operator registers a grant with `fh setup workspace GRANT.json`. A files-only grant needs no `--trust-host` and registers a read-only binding.

Use that binding for run and check, such as `--bindings-id workspace`. Missing workspace bindings fail preflight. Output still must validate against the step schema.

## Drivers are chosen at run time

Keep drivers outside the package. Any package supports `--driver agent`: the caller performs infer and decision steps while fh executes code.

Prepare the package for that driver:

- Bind everything needed into input. The agent receives resolved input, instructions or questions, and output schema.
- Make schemas strict enough to reject wrong answers. Rejection returns issues and leaves the step open.
- Keep agent-facing output schemas self-contained. Outside references refuse the run.
- Keep ready branches and elements independent of execution order. They appear together.

## Check and test

Run `fh check PACKAGE --bindings-id ID --json` to validate without executing steps or models. Then use labelled cases with `fh eval`.

Include a failed branch or element, an empty map and non-array `over`. Checkout fixtures in `packages/loops-contract/0.3/` demonstrate each rule.
