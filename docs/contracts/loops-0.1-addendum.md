# Loops 0.1 packaging and feedback addendum

Use this addendum for JSON packaging, iteration feedback and browser abilities.
Read it with the [0.1 execution contract](loops-0.1.md). This addendum takes
precedence on the subjects below. Runners must reject unsupported execution
fields.

## JSON packages

The canonical manifest is `loop.json`, encoded as UTF-8 JSON. A directory resolves to that file; an explicit `.json` manifest is also accepted. YAML is outside this first implementation. Duplicate object keys, comments, trailing commas and non-JSON values are invalid. Schemas and code remain inline or package-local as allowed by the original draft. Credentials, resource handles, providers and installation policy do not become package fields.

## Declared iteration feedback

A repeat region may declare one carried JSON value using `repeat.carry`, with exactly two required members: `initial` and `next`. Both use the existing recursive binding syntax; this adds no expressions, mutable variables or access to historical attempts. Example fragment:

```json
{
  "repeat": {
    "from": "write",
    "through": "assess",
    "until": {"from": "/steps/assess/output/ready"},
    "max_iterations": 3,
    "carry": {
      "initial": {"value": {"draft": null, "feedback": []}},
      "next": {
        "draft": {"from": "/steps/write/output/draft"},
        "feedback": {"from": "/steps/assess/output/feedback"}
      }
    }
  }
}
```

Bind the previous draft and feedback into the writing step:

```json
{
  "subject": {"from": "/input/subject"},
  "previous_draft": {"from": "/carry/draft"},
  "feedback": {"from": "/carry/feedback"}
}
```

1. Execute the prefix once. Resolve `initial` once, immediately before entering the first pass, against validated input and completed prefix outputs. Region outputs and `/carry` are unavailable during initialization.
2. For each pass, expose the resolved value at `/carry` to region step input bindings. It is a read-only JSON snapshot for the whole pass. No step can update it in place. Without a carry declaration, `/carry` is absent and references to it fail.
3. Execute the region in order, validating each output before making it available. Evaluate `until` after the through step using current outputs, input and current carry. It must be boolean.
4. If true, continue to the suffix without evaluating `next`. If false and the iteration limit is reached, stop without evaluating `next` or running the suffix.
5. Otherwise resolve `next` against input, completed prefix/current-region outputs and the old carry. Persist this new JSON snapshot before clearing the region's current outputs. Start the next pass with the new carry. Missing pointers or invalid binding syntax fail execution before the next pass; never substitute null or reuse an earlier value silently.
6. `/carry` exists only for region step bindings, `until` and `next`. Prefix, suffix and root output bindings cannot reference it; suffix/root output can consume the final region's validated outputs. Historical attempts remain available in run records, never implicitly in binding or inference context.

Persisting a carry transition does not authorize automatic replay after a crash. Existing uncertain-effect rules still apply. Retention, transport and storage representation are runner policy; the transition semantics above are portable.

Required conformance case: first draft contains an unwanted background section. The assessor returns `ready:false` with the specific removal instruction. Pass two receives the exact previous draft and that feedback, removes the section and returns `ready:true`. Assert two passes, one prefix/suffix execution, unchanged saved code and the final output. Also test first-pass values, an absent carry declaration, missing next bindings, a true-until branch with an otherwise unresolved next binding, and exhausted repetition without next evaluation.

## Browser baseline

The existing `requires:["browser"]` name denotes all of these minimum abilities:

- Navigate within explicitly authorized destinations and report the resulting URL.
- Observe rendered content and identify actionable elements, with retrievable evidence references.
- Activate an identified element and enter text through browser interaction.
- Dispatch real keyboard actions, including Tab, Shift+Tab, Enter, Space and Escape, and observe the resulting focused element and visible state. Editing the DOM to manufacture a focus result does not satisfy this ability.

An installed adapter reports baseline support during declaration-only preflight. Missing any ability rejects a step requiring browser before model or code execution. A screenshot-only adapter is insufficient regardless of package name or instruction prose. Adapter conformance uses a controlled page with known navigation, focus order and interaction results; metadata claims alone do not establish support.

This baseline describes abilities, not permissions. Destination/resource grants remain runner-owned and are rechecked at execution. Failure to obtain sufficient evidence during an authorized inspection must remain inconclusive according to the package's output schema, rather than being reported as a pass.

## Runner conformance boundary

Contract schemas, fixtures and expected semantic traces must work independently
of fh's UI, storage and transport. fh compares shared traces for these behaviors:

- Binding resolution and step order.
- Carry transitions and output.
- Stopping rules.

Independent cross-runner compatibility is unverified. Shared fixtures and schemas
or repeated runs of one engine do not establish it.

Compare independent runners first with frozen inference responses. This isolates
execution semantics. Then check live inference in each runner.
