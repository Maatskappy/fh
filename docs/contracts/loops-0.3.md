# Loops 0.3: parallel work, agent steps and agent drivers

Use 0.3 for parallel work, workspace reads, Node modules and external agent drivers. It extends [0.1](loops-0.1.md), the [addendum](loops-0.1-addendum.md) and [0.2](loops-0.2.md), preserving their meanings.

A package opts in with `"format": "loops/0.3"`; a runner that does not implement 0.3 rejects it. Use the [manifest schema](../../packages/loops-contract/loop-0.3.schema.json) for validation and [shared fixtures](../../packages/loops-contract/0.3/) for conformance checks.

fh implements 0.3 in its native runner.

## 1. `parallel`

```json
{"id": "lenses", "kind": "parallel",
 "branches": {
   "security":    [{"id": "security_review", "kind": "infer", "...": "..."}],
   "correctness": [{"id": "correctness_review", "kind": "infer", "...": "..."}]
 }}
```

- `branches` is a nonempty object. Each branch is a nonempty ordered list of steps of any kind, including nested `parallel` and `map`.
- Every branch starts when the parallel step starts. Within a branch, steps run in order.
- A branch's result is its last step's output.

## 2. `map`

```json
{"id": "lenses", "kind": "map",
 "over": {"from": "/steps/select/output/roster"},
 "steps": [{"id": "lens", "kind": "infer", "input": {"brief": {"from": "/item/brief"}}, "...": "..."}]}
```

- `over` is a binding. It must resolve to an array; anything else fails the map step with `invalid_map_input`, which fails the run at top level and the enclosing branch or element when nested, like any other step failure.
- The ordered `steps` run once per element. An element's result is its last step's output.
- Inside the steps, `/item` is the element and `/index` its zero-based position.
- How many elements run at once is runner policy, not a package field.

## 3. Settled results

A parallel or map step completes once every branch or element has settled. It never fails because a branch failed. Its output is runner-shaped (the step declares no output schema):

- parallel: `{"<branch>": <result>, ...}` in declared branch order;
- map: `[<result>, ...]` in element order; `[]` for an empty array;
- `<result>` is `{"status": "completed", "output": <value>}` or `{"status": "failed", "error": {"reason": "<reason>"}}`.

`reason` uses the run vocabulary: `invalid_output`, `missing_binding`, `invalid_binding`, `code_exit`, `execution_failed`, and so on. A branch fails at its first failed step and runs no further steps. Later steps read results with ordinary bindings, for example `/steps/lenses/output/security/output` or `/steps/lenses/output/0/status`, and saved code decides what a partial result means.

Run-level stops are not branch failures. Cancellation, the deadline, the token budget and an uncertain effect stop the whole run with their usual `stopped` reason, and the composite step does not complete.

## 4. Scope and identity

- Step ids are unique across the whole package, at every depth. Step ids and branch names never contain `/`, `[` or `]`, so every path names exactly one position.
- A step inside a branch or element sees the validated input, the outputs of steps that completed before the composite step, and the outputs of earlier steps in its own branch or element. It never sees a sibling branch or another element, however fast that sibling ran. A binding to one fails that branch with `missing_binding`.
- Inside a map element, `/steps/<id>/output` names that element's own instance of the step.
- Once the composite completes, later steps see only the composite's output, never the inner step outputs.
- `/item` and `/index` exist only inside map steps; `/carry` keeps its addendum scope (region steps, `until`, `next`), which includes steps nested inside a region step.

## 5. Repetition

The one bounded repeat region stays at top level: `from` and `through` name top-level steps. A parallel or map step can be inside the region. Region semantics, carry and history are unchanged; on a new pass the composite and everything inside it runs fresh.

## 6. Paths

A path names a position in a run, for traces, events, history and the agent driver:

- a top-level step: `<id>`;
- a step in a branch: `<parallel id>/<branch>/<id>`;
- a step in an element: `<map id>[<index>]/<id>`;
- nesting composes: `review/lenses/security/scan[2]/check`.

## 7. Agent steps: `workspace_read`

Use `workspace_read` for read-only agent access to registered files. This extends 0.1 inference, which already allows an agent to work through several tool calls:

| Capability | Minimum ability |
| --- | --- |
| `workspace_read` | List, search and read files of a workspace the runner binds to the run, read only. |

The runner supplies the tools, turns, model and budget. The package declares the need, never tool names. The runner returns the step's output through a terminal action of its own choosing (for example a tool whose input schema is the step's output schema); either way the output is validated against the step's schema like any other. A runner without a workspace binding rejects the package during preflight.

## 8. `runtime: "node"`

`file` is an ES module whose default export is a function. It receives the validated, bound input and returns or resolves the output. A thrown error is `code_exit`; a returned domain verdict is success. A runner may call it in process or through a shim over stdin and stdout; the module cannot tell the difference. The module may import only package-local files and Node's built-in modules. A runner that checks this is making a contract check on imports, not a sandbox: built-in modules can still reach files and processes. Whatever isolates code steps is the security boundary; in fh that is the container.

## 9. Instructions from a file

An `infer` step's `instructions` may be `{"file": "<package-local path>"}`. The runner reads the file as UTF-8 and uses its exact text. The file is part of the package digest.

## 10. Drivers

A run has a driver, chosen at `run` time and never stored in the package:

- `runner` (default): the runner performs every step.
- `agent`: the runner makes no model calls. The driving agent performs every `infer` and `decision` step with its own model, so it owns the inference cost and model choice. `code` steps always execute in the runner, under either driver.

Two operations join `check`, `run`, `get` and `cancel`:

| Operation | Meaning |
| --- | --- |
| `next(run_id)` | Every step ready now that the driver must perform, in path order: path, kind, pass, resolved input, output schema, and instructions or questions. Under the agent driver, a parallel or map step's ready branches appear together. Empty when the run is terminal. |
| `submit(run_id, path, pass, output)` | `path` and `pass` are the ones `next` gave; together they name one attempt of one step, so a retried submission from an earlier pass of a repeat region never settles a later one. Validate against the step's output schema. Invalid: `rejected` with the schema errors; the step stays open. Valid: `accepted`, then advance (bindings, `until`, carry) and execute any code steps that became ready. A path and pass that are not ready: `not_ready`. A path and pass that already settled: the same output returns `accepted` again; a different output returns `conflict` with the committed output. |

`cancel` ends the run `stopped` with reason `cancelled`, never `completed`. A run under the agent driver is `completed` only after its last step.

## 11. Retained semantics

Bindings, carry, the single repeat region, step validation, status vocabulary, uncertain-effect rules and run records keep their 0.1/0.2 meanings. There is still no expression language, no arbitrary branching and no scheduling primitive. A branch is not a condition.

## Conformance fixtures

Use [`packages/loops-contract/0.3/`](../../packages/loops-contract/0.3/) for 0.3 fixtures and expected traces. They remain separate from earlier suites so older runners are unaffected. The fixture format follows 0.1 with these differences:

- Frozen inference responses are keyed by `path` and `pass`, not by a global ordinal, because concurrent order is not defined. A response may carry `error` instead of `output` to fail that step with the given reason, and `instructions` to assert the exact text the runner resolved.
- Expected `steps` entries carry `path` and list every executed step in canonical order: depth first in declaration order, branches in declared order, elements by index, and each composite step after its children. A map entry's `input` is the resolved `over` array; a parallel entry has no `input`; as in the 0.1 suite, a step that ran and failed has its `input` and no `output`, and a step whose binding failed has no entry. Runners sort their trace into that order before comparing.
- An agent-driver fixture has `scenario.driver: "agent"` and `scenario.ops`: `next` with the expected paths, `submit` with path, pass, output and expected answer, or `cancel`.
