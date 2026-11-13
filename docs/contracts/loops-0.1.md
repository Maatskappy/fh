# Loops 0.1 execution contract

Use a Loop to describe a bounded job. Define its input, ordered steps, capabilities
and output. Add repetition only when needed. The runner supplies resources and
executes the steps.

Read the [0.1 addendum](loops-0.1-addendum.md) alongside this contract. It takes
precedence for JSON packaging, carried feedback and browser requirements.
Independent cross-runner compatibility is unverified.

## 1. Package and runner responsibilities

| The portable loop specifies | The runner supplies |
| --- | --- |
| Input and output shapes | Actual input values and authenticated resource access |
| Ordered steps and optional bounded repetition | Step execution, isolation, limits, and result storage |
| Required capabilities | Its own browser, computer, search, or other adapters |
| Instructions for inference steps | Models, inference settings, context strategy, and tool orchestration |
| A low/medium/high complexity hint | Its own interpretation of those levels and spending policy |
| Exact code for code steps | A compatible declared runtime |

The runner chooses its models, browser controls and internal agents. It must not silently drop steps, weaken checks, rewrite bundled code, change return semantics or exceed permissions.

Portability lets compatible systems run an unchanged definition. Inference results can differ. Environment compatibility and migration of live runs are not guaranteed.

## 2. A file, with optional companions

Save the package manifest as UTF-8 JSON in `loop.json`, following the addendum. The YAML below illustrates the data model. Instructions and schemas can be inline. Use companion files for code, longer prompts and schemas.

```text
accessibility-check/
  loop.json
  scripts/decide.py
  schemas/input.json
  schemas/report.json
  schemas/result.json
```

This example keeps schemas in companion files. Inline schemas work too.

```yaml
format: loops/0.1
name: accessibility-check
version: 0.1.0
description: Check a page against a small, explicit accessibility checklist.

inputs:
  schema: schemas/input.json

steps:
  - id: inspect
    kind: infer
    requires: [browser]
    complexity: medium
    input:
      from: /input
    instructions: |
      Visit the supplied URL in the authorized test environment.
      Evaluate only these checks:
        keyboard-operation: Try the page's primary controls with a keyboard.
        visible-focus: Observe focus while tabbing through those controls.
        visible-labels: Check whether visible form controls have understandable labels.
      Return one record per check: pass, fail, or inconclusive, with evidence.
      Describe observations, not assumed behavior. Use inconclusive when you
      cannot establish a result, including when there is nothing applicable to test.
      Do not edit code, submit real purchases, send messages, or change stored data.
      This is a scoped preliminary check, not an accessibility certification.
    output:
      schema: schemas/report.json

  - id: decide
    kind: code
    requires: [computer]
    runtime: python3
    file: scripts/decide.py
    input:
      from: /steps/inspect/output
    output:
      schema: schemas/result.json

output:
  from: /steps/decide/output
```

Supply a reachable URL as caller input. The caller also owns triggers and input preparation.

This example checks three limited accessibility behaviors. A pass means those checks were reported as passing with evidence. It does not establish full accessibility conformance. W3C distinguishes preliminary and tool-assisted checks from complete evaluation [4]. The saved verdict script validates and combines reports. It cannot independently verify observations.

## 3. Two executable step types

### `infer`: judgment is needed

An inference step includes instructions, bound input, required capabilities, a complexity hint, and an output schema. It can involve one model request or an agent working through several tool calls. The runner chooses the implementation while preserving the step's instructions and constraints.

Complexity defaults to `medium`; allowed values are `low`, `medium`, and `high`. These are routing hints, not portable model rankings, standardized reasoning-token settings, quality guarantees, permission grants, or instructions to spend unlimited money.

Each installation maps complexity locally. One might map `high` to a premium model. Another might use a cheaper model with more effort. Both can implement the protocol, with different performance. Test actual outcomes to assess a mapping for your Loop.

### `code`: execute saved code

A code step names a bundled file and a required runtime. The runner executes that file, supplies JSON on standard input, expects one JSON output, and keeps diagnostics on standard error. Exit zero means the step executed successfully. A domain result such as `verdict: fail` is still an exit-zero result. A nonzero exit means an execution error.

For the example, `python3` denotes Python 3.10 or later in the Python 3 family, with the standard library. The bundled script uses no third-party dependencies. Other runtimes or version requirements would be separately declared and checked; an unsupported runner must not pretend to support them.

Write, test and save code during authoring. Later runs execute the saved file.

Pseudocode belongs in an inference step. Compilation of an abstract specification is outside this contract.

A code step means there is no required inference in that step. It is not automatically deterministic: a script that reads a clock, randomness, or a live service can vary. Repeatability requires controlled inputs and relevant dependencies. The supplied verdict function is deliberately pure with respect to its explicit input.

## 4. Requirements describe abilities, not brands

Start with a small vocabulary:

| Capability | Minimum intent |
| --- | --- |
| `browser` | Navigate, observe, and interact with a web page, including keyboard interaction. |
| `computer` | Use an authorized workspace, read/write permitted files, and execute permitted programs. |
| `web_search` | Search the web and return source-identifiable results. |

A browser implementation might use headless automation or computer-use interaction. It qualifies only when it can meet the requested operations. A screenshot-only service cannot claim support for a loop that requires keyboard interaction. Declare additional operation requirements when a Loop needs them.

`computer` does not imply Python, Git, Postgres, every operating system, every network destination, or unrestricted access. Actual runtime/dependency requirements must remain explicit. A specific database requirement is legitimate; do not disguise it as a generic computer capability merely to claim more portability.

Requirements are requests, not authorization. Credentials and permissions are installed or bound by the runner, not carried inside a shared loop. A loop cannot self-authorize new filesystem, repository, account, or network access. Bind only the capabilities and resources that this run needs.

## 5. Minimal execution semantics

The root fields are `format`, `name`, `version`, optional `description`, `inputs`, `steps`, optional `repeat`, and `output`.

`format` identifies the contract version. `version` identifies the loop's own revision. Each step has a unique `id`, a `kind`, `input`, and `output`; it adds either inference instructions or a code file/runtime. Requirements are declared per step; preflight checks their union. An empty requirements list is allowed for a pure inference step.

Input and step-output schemas use JSON Schema 2020-12, inline or in a bundled relative file. Relative file paths must stay inside the package. Schema files must not be fetched from arbitrary network addresses during validation. A validator can check shape and constraints, not the factual truth of an observation.

Steps run in declared order. The runner validates supplied input before beginning, resolves bindings, executes the step, and validates its output before later steps consume it. Invalid output fails the step rather than being silently accepted or guessed into shape. Product-specific schema-repair attempts, if offered, must be explicit and bounded; this contract does not require them.

A `from` binding reads a value from the run's structured data, for example `/input/url` or `/steps/inspect/output`. Paths identify values; they are not arbitrary expressions or executable templates. A missing value is an error. A substituted value is data, never recursively interpreted as another binding. Literal data can be wrapped in `value` when needed to avoid a reserved-binding shape.

The available data is the validated run input and validated outputs of already completed steps. A step can receive a selected value or a structured collection of selected values. Do not implicitly give every step the caller's entire conversation, credentials, hidden memory, or all available tools. The runner may optimize context construction without withholding explicit inputs or changing the declared task.

On completion, the root `output` selects the returned value. References, fixtures, code, and prompts belong to a versioned package; changes create a new revision. Record a digest of the resolved package in the run record so the result identifies what actually ran.

## 6. Bounded repetition

Do not require repetition for a check that should simply return a finding. The accessibility example returns its findings after one pass.

For an actual review/fix/verify loop, start with one optional repeated region:

```yaml
repeat:
  from: review
  through: verify
  until:
    from: /steps/verify/output/ready
  max_iterations: 3
```

This fragment shows only repeat control. A complete manifest would define `review`, `repair` and `verify`, plus optional later `finalize`, as ordinary steps.

Run the prefix once, then execute the region from `review` through `verify`. After `verify`, the referenced value must be a boolean. True means continue to the following step. False means repeat the region if permitted, up to three total passes including the first. Exhaustion stops the run with `iteration_limit`; it must not fall through to a later merge step. Code or inference can compute the boolean. The runner must not decide what `ready` means independently.

Fresh results replace the repeated region's results on each pass; stale outputs in that region must not satisfy a later iteration. The run's authorized working files persist as appropriate, so a review can inspect the preceding pass's fixes. Previous results remain in the execution history, not implicitly mixed with current results.

For PR work, a Loop can review → repair → verify, then finalize. Input mode can select a readiness result or an authorized merge. Stop for denied permission or unavailable dependencies.

0.1 supports ordered steps and one bounded repeated region. It has no general expression language, nested graphs, arbitrary branching or scheduling primitives.

## 7. A result other agents can use

Separate execution status from the job's substantive outcome:

```json
{
  "run_id": "run_example",
  "status": "completed",
  "output": {
    "verdict": "fail",
    "checks": [
      {
        "check": "visible-focus",
        "outcome": "fail",
        "evidence": ["The Save button had keyboard focus without a visible indicator."]
      }
    ],
    "missing_checks": ["keyboard-operation", "visible-labels"]
  }
}
```

The illustrative run completed and found a visible-focus problem. It also lists missing checks. A coding agent can act on the finding while recognizing that execution succeeded.

Accepted runs are `queued` or `running`, then terminal `completed`, `failed`, or `stopped`. `completed` contains the validated output. `failed` describes an execution error. `stopped` describes cancellation, a resource/policy limit, or iteration exhaustion. Non-completed runs may expose clearly labeled partial results, never pass them off as completed output. Unsupported definitions, capabilities, or permissions are rejected during preflight before steps run, when detectable.

Artifacts such as screenshots or patches may accompany the result. Use retrievable artifact references with media type and access rules, not a provider-local filesystem path that a remote caller cannot read. Byte-for-byte equivalence of artifact locations is not part of loop portability.

An agent, CI system, application or person can call a Loop. The caller or an explicitly authored job decides whom to notify and when to request a human decision.

## 8. A small runner interface

A runner can expose these transport-independent operations:

| Operation | Meaning |
| --- | --- |
| `check(loop, bindings)` | Validate the package and report missing capabilities, runtime requirements, or authorization. |
| `run(loop, input, bindings, limits)` | Start an execution and return its run identity. |
| `get(run_id)` | Read current status and the final result when available. |
| `cancel(run_id)` | Request that execution stop; report any already-applied side effects. |

Bindings identify the runner's authorized resources and adapters; limits are run policy. They are not part of the portable package. Effective limits use the stricter loop and runner restrictions. A synchronous CLI can combine run/get behind one command. Hosted runners can expose the same semantics through an API. Live-run migration between providers is out of scope.

An optional small event vocabulary is enough: `run.started`, `step.started`, `step.completed`, and `run.finished`, carrying run ID, step ID when relevant, iteration, and a per-run sequence number. Results are obtained from `get`; clients must not need perfect notification delivery to learn the outcome. Delivery, reconnection, authentication, and replay depend on the transport adapter.

Never assume exactly-once external side effects. A runner must not blindly replay a script that may already have merged a PR, submitted a form, or sent a message. A runner can stop on ambiguous failures. Durable resume and idempotency policies are outside this contract.

## 9. Checking runner compatibility

Use a controlled page with a known visible-focus problem to compare independent adapters.
Run the same package on both. Inspect step execution, output shape and observations.
A browser-less binding must reject the package before execution.
The same report must produce the same saved-code verdict on both adapters;
inference observations can differ.

Supply a URL both runners can reach through input and bindings. A local-only URL
may fail elsewhere. Keep the package procedure unchanged. Synthetic verdict tests
do not establish browser support, model access, independent compatibility or
accessibility coverage.

## 10. Relationship to skills, and what stays outside

Use [Agent Skills](https://agentskills.io/specification) for instructions, scripts,
resources and compatibility information. A Loop adds runner-enforced execution:
ordered steps, validated input and output, capability checks, bounded repetition
and a result contract. Skills can teach Loop creation and use. Loops can include
specialist guidance.

Triggers, schedules, account setup, hosting, model selection and registries are
outside the portable definition.

## References

[1] Agent Skills specification: `https://agentskills.io/specification`

[2] JSON Schema reference: `https://json-schema.org/understanding-json-schema/reference`

[4] W3C WAI, Evaluating Web Accessibility Overview: `https://www.w3.org/WAI/test-evaluate/`
