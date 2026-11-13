# Check development results with a Loop

Use `loops/change-readiness` to check supplied development receipts with saved Python code. The Loop makes no inference request. You run the checks and supply their outcomes.

fh does not compile the project, authenticate receipts or verify their optional revision and diff identities.

## Prepare receipts

Keep receipts outside the package so every run can reuse identical saved bytes. Replace these sample values with captured results:

```json
{
  "revision": "REPLACE_WITH_CHECKED_REVISION",
  "diff_identity": "REPLACE_WITH_CHECKED_DIFF_HASH",
  "required_checks": ["native-check", "native-chat", "provenance"],
  "receipts": [
    {"name":"native-check","exit_code":0,"duration_ms":1200,"summary":"Actual native check passed."},
    {"name":"native-chat","exit_code":0,"duration_ms":250,"summary":"Actual focused native chat tests passed."},
    {"name":"provenance","exit_code":0,"duration_ms":90,"summary":"Actual provenance verification passed."}
  ]
}
```

Run the package with the operator's registered code runtime:

```sh
fh check /absolute/package/loops/change-readiness --json
fh run /absolute/package/loops/change-readiness --input /absolute/receipts.json --json
fh get RUN_ID --json
```

Read `output.ready` even when execution completes. CI must check this field explicitly. A valid domain failure exits zero.

| Result | Conditions |
| --- | --- |
| `ready: true` | Every required name is present, all receipt names are unique, and every supplied exit code is zero. Names are exact and case-sensitive. |
| `ready: false` | A receipt failed, a required name is missing, or a name is duplicated. Output includes lists and a next action. |

Evidence echoes the bounded receipts and optional identities. `summed_duration_ms` sums reported durations. It does not measure parallel wall time.

| Input limit | Bound |
| --- | --- |
| Receipts | 64 |
| Required names | 64 |
| Summary | 1024 characters each |

Change external receipts and rerun the unchanged package. Compare package digests to confirm reuse. Missing evidence cannot become ready through inference or automatic retry.

## Capture actual developer checks

Use the fixed developer script from the checkout after building or installing the native binary:

```sh
python3 scripts/check-change.py --evidence-dir /absolute/external/check-evidence
# Optional: --binary /absolute/installed/fh
```

The script runs `zig build check test-chat test-loops-native` once, followed by `python3 patches/fx/verify.py`. The `native-checks` receipt covers the whole compiler invocation. Failed checks still reach the readiness Loop.

The script captures actual exits, durations and bounded summaries. Each log retains at most 1 MiB in a new private evidence subdirectory.

| Recorded identity | Scope |
| --- | --- |
| Revision | HEAD before checks. |
| Diff identity | SHA256 of `git diff --binary HEAD` before checks. Includes tracked staged and unstaged changes. Excludes untracked files and generated evidence. |

Keep source stable while checks run. The script uses `dist/fh` by default to check and run unchanged `change-readiness`, then reads authoritative `get`. It uses registered `local` bindings without changing settings or permissions, and makes no model request.

The foreground script returns JSON pointing to receipts, command logs and `report.json`. It exits zero only for a completed run with `output.ready: true`. Otherwise it exits one.

## Exercise rejection cases

Change a receipt's `exit_code` to 1 and confirm `output.ready: false`. Also test a missing required name and a duplicate receipt name.

Use unchanged package bytes with each external input. Read every saved result with `get`. Timing depends on the host and runtime. Capture fresh measurements when needed.
