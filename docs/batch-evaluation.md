# Batch runs, labelled evaluation and retry

Use `batch` to run one unchanged package on many inputs in a single native worker. Use `eval` to compare its output with independently labelled expectations. Both execute cases sequentially.

```sh
fh batch PACKAGE --cases /absolute/cases.json --bindings-id local --json
fh eval PACKAGE --cases /absolute/cases.json --bindings-id local --json
```

## Prepare cases

Save the suite as strict JSON outside the immutable package:

```json
{
  "cases": [
    {
      "id": "complete",
      "input": {"draft": "42 rows copied; checksum matched.", "requirements": ["State the count.", "State the checksum result."]},
      "expect": {"pointer": "/action", "value": "ready"}
    },
    {
      "id": "missing-evidence",
      "input_file": "inputs/missing-evidence.json",
      "expect": {"pointer": "/action", "value": "revise"}
    }
  ]
}
```

Each case needs a unique, nonempty ID and exactly one input source:

| Field | Rule |
| --- | --- |
| `input` | Inline JSON that validates against the package input schema. |
| `input_file` | Path relative to the suite file, within its directory. Absolute paths and any `..` component are refused with an error naming the case. |
| `expect` | Required for eval. Supplies an RFC6901 pointer into final output and an expected JSON value. An empty pointer compares the whole output. |

fh captures and validates all inputs before dispatching any model or command.

Eval uses exact JSON comparison. A missing pointer mismatches even when the expected value is null. Object key order does not matter. Array order does. Integer labels must fit signed 64-bit values. Floating labels must be finite 64-bit values. Out-of-range integer literals fail before dispatch. Use strings for larger exact identifiers. Distinct supported integers remain distinct.

Prepare ground-truth labels independently. Put thresholds or label generation in the package when needed. Eval supplies neither a model rubric nor numerical tolerance.

Choose the value your output contract promises, such as `action` rather than raw `choice`. The decision-gate example's action includes an illustrative confidence threshold that needs evaluation for your task. Shipped labels are fixtures, not measured model-quality guarantees.

## Read reports

Reports identify the source, pinned package digest, case IDs, input sources and durable run IDs. They include actual values, expected values and comparison details.

| Count | Meaning |
| --- | --- |
| Passed in batch | Execution completed. |
| Passed in eval | The expected label matched. |
| Mismatched | Execution completed but the expected label differed. |
| Failed | Execution failed. Runtime failures never count as label matches. |
| Skipped | The case did not run after a suite stop. |

`--json` returns one final object. `--events` streams attributed acceptance, progress and `case_result` objects, then a bounded summary. Use `fh get` with a durable run ID for output omitted from that summary.

Settled per-case errors let later cases run. These conditions stop the suite and skip remaining cases:

- Cancellation, uncertain effects or usage, or required recovery.
- Changed package bytes.
- Changed bindings: every case must match the first run's binding digest. The report uses `stop_reason: binding_changed`.
- Worker failure: the report uses `stop_reason: worker_error` and `stop_cause`. The current case is `run_failed` with status `unknown`, plus its run ID if accepted.

A worker failure still returns reports for cases already run, including in `--json` mode. No case retries automatically.

## Limits and exit codes

Suite limits apply before dispatch:

| Resource | Limit |
| --- | --- |
| Cases | 1,000 |
| Case ID | 256 bytes |
| Suite JSON plus captured file inputs | 16 MiB |
| Each input | Existing 1 MiB limit |
| Final report | 16 MiB |

fh reserves report space for every case's identity. If details no longer fit, the current run remains attributable and sets `details_omitted: true`. Later cases are skipped.

Each case keeps its own token, time, tool and operation limits. A batch multiplies potential work by its case count without changing those limits or creating another budget.

| Exit code | Meaning |
| --- | --- |
| 0 | Completed successful batch or eval. |
| 1 | Mismatch or settled case failure. |
| 2 | Invalid invocation, suite or preflight. |
| 3 | Stopped suite. |
| 130 | Cancellation. |

## Jev readiness

Inspect Jev's local configuration without making a provider request:

```sh
fh status
fh status --json
```

| Status field | Meaning |
| --- | --- |
| `jev.provider`, `model`, `api_key_env` | Effective configuration. |
| `credential_presence` | `present`, `missing` or `unknown`. |
| `credential_source` | `environment`, `saved`, `none` or `unknown`. |
| `access` | `not_checked`. Presence does not prove TypeSafe will accept the key. |

Status does not retrieve a stored secret. `fh setup jev` saves the key for the effective policy environment name. Setup, status and execution respect a custom `apiKeyEnv`.

An absent or null installation decision policy selects the default TypeSafe/Jev policy. It does not mean the key is missing. The key lives in the environment, scoped Keychain or private storage, outside `installation.json`.

## Diagnose failures

Run and get output identify the input and any retry:

| Field | Meaning |
| --- | --- |
| `package_path`, `bindings_id` | Package and bindings used. |
| `input_source` | File path, stdin for `--input -`, `inline`, or suite file plus case ID. |
| `input_sha256` | Hash of compact JSON with recursively sorted object keys and preserved parsed numeric representation. This is not an RFC 8785/JCS claim. |
| `case_id`, `retry_of` | Case identity and original run, where applicable. |

The durable private record retains root input. Failed and stopped results include `diagnostic.cause`, `step_id`, a bounded static recovery message and retry guidance. Unknown provider usage keeps the original `failure_cause` visible. Diagnostics exclude raw provider exception prose and credential values.

## Retry a run

Use `get` to inspect the original record before retrying:

```sh
fh get RUN_ID --json
fh retry RUN_ID --json
```

Retry starts a new whole run from retained input and links `retry_of`. It leaves the original record unchanged. It cannot resume a step. Editing the original input file does not affect the retry. Start a new run to correct input.

Admission requires all of the following:

- A failed or stopped terminal run with retained attribution and a valid input hash.
- Complete, known accounting and known replayable effects.
- Unchanged package and binding digests.
- The original provider, model, effort and tier still available.

Retry uses the original selection, regardless of current installation choices. An unavailable provider produces `retry_selection_unavailable`.

Known provider requests and proven isolated read-only code lifecycle receipts can be replayable. Retrying can repeat model requests under the same per-run limits.

Retry refuses active, completed and legacy runs. It also refuses uncertain usage or effects, applied host/browser/external mutations, unknown effect kinds and incomplete isolation proof. Inspect an uncertain effect before using `fh settle RUN --applied` or `--not-applied`.

`retry.allowed: true` describes retained evidence. Current package and binding checks still run at admission. Reconcile applied or uncertain external work before explicitly starting new work.
