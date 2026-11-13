# Decision gate

Use this Loop to classify a draft against supplied requirements. Jev makes one native request, then saved code applies the example threshold.

| Condition | Result |
| --- | --- |
| Confidence below 0.8 | Review. |
| Insufficient evidence | Review. |

The threshold is illustrative. Evaluate it for your task. A decision grants no action permission.

## Run the example

Configure `TYPESAFE_API_KEY` in your local shell, outside the package. Then run from the checkout or installed bundle:

```sh
fh check ./loops/decision-gate --bindings-id local --json
fh run ./loops/decision-gate --input examples/decision-gate-input.json --bindings-id local --json
fh get RUN_ID --json
```

The default pinned model is `jev-1.13.0`. TypeSafe access is separate from Codex sign-in. The threshold step needs the installed isolated Python runtime.

`check` validates declarations locally without reading the key or requesting Jev. Keep inputs and results outside the unchanged package.

## Read the result

Inspect `action` to decide what to do next. A completed run means execution and validation succeeded. The saved `classify` output preserves Jev probabilities and confidence. `get` returns the final threshold output.
