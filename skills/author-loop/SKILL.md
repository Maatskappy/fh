---
name: author-loop
description: Use when creating, correcting, checking or reusing portable loops/0.1–0.4 JSON packages, including parallel and map steps, Jev decision questions, saved code and explicit iteration feedback.
---

# Author a reusable loop

Read the [authoring guide](../../docs/loops.md). Choose the lowest format that fits:

| Format | Adds |
| --- | --- |
| [0.1](../../packages/loops-contract/loop-0.1.schema.json) | Inference and code. |
| [0.2](../../packages/loops-contract/loop-0.2.schema.json) | Decisions. |
| [0.3](../../packages/loops-contract/loop-0.3.schema.json) | Composites, Node, instruction files and workspace reads. |
| [0.4](../../packages/loops-contract/loop-0.4.schema.json) | Source dependencies. |

Checkout schemas are in `packages/loops-contract/`. Read [runtime recipes](../../docs/code-runtimes.md), [0.3 authoring](references/loops-0.3.md) and [Jev question design](references/jev-questions.md) as needed. Schema validity does not establish judgment quality.

## Define evidence and outcomes

Declare the caller's input and output contract. Include target identity and revision, collection time, scope, required sources and the meaning of a complete snapshot.

Missing evidence leaves the result unverified. Defects or outstanding required edits mean not ready. Distinguish successful empty collection, collection failure and uncertain effects.

Test with `fh eval` using independently labelled cases:

- Positive and defect cases.
- Stale or wrong identity and missing sources.
- Successful empty collection and collection failure.
- Outstanding required edits.

Code fixtures verify deterministic behavior. Authorized model evaluation verifies judgment. Vary choice order in decision tests.

## Choose an example

| Need | Example |
| --- | --- |
| Native checker and source repair | [workspace-repair](../../loops/workspace-repair/loop.json), [workspace runtime](../../docs/workspace-loops.md) |
| Editable Node or portable Wasm | [source](../../loops/increment-source/loop.json), [Wasm](../../loops/increment-wasm/loop.json), [rebuild recipe](../../docs/code-runtimes.md) |
| Inference then isolated Python | [minimal-infer-code](../../loops/minimal-infer-code/loop.json) |
| Explicit feedback with prefix and suffix | [carry-counter](../../loops/carry-counter/loop.json) |
| Revise from saved assessment | [description-refinement](../../loops/description-refinement/loop.json) |
| Typed decisions | [decision-gate](../../loops/decision-gate/loop.json) |
| Browser keyboard checks | [browser-check](../../loops/browser-check/loop.json), [browser guide](../../docs/browser-capture.md#run-a-browser-loop) |
| Parallel lenses, per-element work, Node or workspace reads | [0.3 authoring](references/loops-0.3.md) |

## Save the procedure

Save strict UTF-8 `loop.json`, exact code and schemas in a dedicated directory. Keep caller inputs, grants and results outside it to preserve the digest. A domain failure remains valid exit-zero JSON.

Select code using explicit `runtime` and `file` fields. Use optional isolated `python3` or `node`, or built-in `wasm32-wasi-json/1`. Format 0.4 requires `dependencies.runtimes`. Use an empty map for pure Wasm.

Retain editable Wasm source and its binary. Rebuild explicitly after source edits. Execution has no fallback or build hook. Rebuild and compare bytes to check source correspondence.

For native checkout repair, use `fh-workspace/1` with an external workspace binding. Read the workspace contract. Packages cannot grant authority. Host commands inherit filesystem access, environment, network and credentials beyond edit allowlists.

Use one bounded repeat region with explicit `repeat.carry.initial` and `next`. Prefix and suffix run once. `/carry` exists only in the region. Root output selects the final validated result. Missing bindings fail.

Composites retain each result as `{status:"completed",output}` or `{status:"failed",error:{reason}}`. Saved code judges partial results. Siblings cannot read one another.

A package never names a driver. With `fh run --driver agent`, the caller performs inference and decisions. Make each step's instructions, input and output schema complete without chat context.

## Check and reuse

Check runs no package step or model. Authoring alone does not authorize live inference or effects. Once authorized, run and inspect `get`.

Report domain output separately from status, run ID, digest and effects. Reuse unchanged bytes with new inputs and compare digests. Settle uncertain effects with `fh settle` before replay. Do not invent limit overrides or resume automatically.
