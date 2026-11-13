# Driving a run as an agent

Use `--driver agent` to perform every infer and decision step with your own model. Your agent supplies the inference and its cost. fh makes no model call.

fh validates outputs, resolves bindings and carry, executes code steps and stores the durable record. Choose the driver per run. Any format supports it without package changes. See [contract section 10](../../../docs/contracts/loops-0.3.md).

## Commands

Check the package, start the run, then submit ready outputs:

```sh
fh check PACKAGE --bindings-id ID --json
fh run PACKAGE --input INPUT_FILE --bindings-id ID --driver agent --json
fh next RUN_ID --json
fh submit RUN_ID --path PATH --pass N --output FILE --json
fh get RUN_ID --json
fh cancel RUN_ID --json
```

`--output -` reads step output from stdin. `--input -` reads run input from stdin.

## What `run`, `next` and `submit` return

Each command returns public run state and a `next` array. Run returns when the first steps are ready, so another initial next call is usually unnecessary.

```json
{
  "run_id": "run_...",
  "status": "running",
  "driver": "agent",
  "awaiting_driver": true,
  "next": [
    {
      "path": "lenses/security/security_review",
      "kind": "infer",
      "pass": 0,
      "input": {"diff": "..."},
      "output_schema": {"type": "object", "required": ["findings"]},
      "instructions": "Review the bound diff for security defects.",
      "requires": []
    }
  ]
}
```

Read each ready item as follows:

| Field | Meaning and action |
| --- | --- |
| `path`, `pass` | Identify one step attempt. Return both unchanged. Passes start at zero for repetition. |
| `input` | Resolved package data. Add no chat history or outside facts unless instructed. |
| `output_schema` | Required output shape. |
| `instructions` | Infer task. |
| `questions` | Decision task. Answer every question using the schema's `{model, answers}` shape. |
| `requires` | Capabilities you must supply with your tools, such as `workspace_read` or `browser`. Cancel and explain if unavailable. Never guess. |
| `complexity` | Optional `low`, `medium` or `high` effort hint from the package. |

A terminal run has empty `next`. Read `status`, `output`, `stop` or `error` then.

All ready parallel branches and map elements appear together in path order. Perform them in any order or concurrently. Later branch steps appear after earlier submissions.

## Answers from `submit`

Read the added `answer` field before continuing:

| Answer | Meaning | Action | Exit |
| --- | --- | --- | --- |
| `accepted` | Valid output. fh advanced and executed ready code. | Read new `next`. | 0 |
| `rejected` | Schema failure, oversized output or unreadable output. `issues` contains `{path, message}`. Step stays open. | Fix and resubmit the same path and pass. | 4 |
| `not_ready` | Attempt is not open, perhaps because the run advanced or ended. | Read `fh next`. | 4 |
| `conflict` | Attempt settled with different output, returned as `committed`. | Keep committed output. Never overwrite it. | 4 |

Resubmitting identical output to a settled attempt returns `accepted`. This makes retry safe after a lost response.

After acceptance, the exit follows run status: 0 for running or completed, 1 for failed, 3 for stopped, or 130 for cancelled.

## Errors

An error exits 2 and returns `error.code`. It is separate from a submission answer.

| Error | Action |
| --- | --- |
| `owner_busy` | Another operation holds the installation. Nothing changed. Wait briefly and resend. Concurrent submissions commonly cause this. Submit sequentially or retry. |
| `recovery_required` | A prior uncertain effect needs operator inspection. The error names run, step and effect. A person records the result with `fh settle RUN --applied` or `--not-applied`. Do not guess. |
| `unsupported_package` | A shown output schema references outside itself. Make it self-contained. |
| Changed package | Keep package bytes unchanged throughout the run. |

## Ending a run

Read the final authoritative record with `fh get RUN_ID --json`. Completion requires the last step to finish. Code failure ends the run as `failed`, as under the runner driver.

`fh cancel RUN_ID` ends it as `stopped` with reason `cancelled`.

Agent-driven runs wait between calls and have no foreground process owner. Losing your shell does not cancel them. Cancel work you will not finish.

## A minimal loop

Use the returned state to process each ready attempt:

```sh
fh run PACKAGE --input input.json --bindings-id local --driver agent --json > state.json
# while state.json has a nonempty "next":
#   for each step: write your output JSON to out.json, then
fh submit RUN_ID --path "each[0]/judge" --pass 0 --output out.json --json > state.json
#   exit 4: read "answer" and "issues"; exit 2 with owner_busy: send it again
fh get RUN_ID --json
```

Quote shell paths such as `each[0]/judge` because they contain brackets.

## Report

Report the run ID, package digest and final status. Include domain output or the stop or error, plus available effect receipts. State that your agent supplied inference and decision outputs under the agent driver.
