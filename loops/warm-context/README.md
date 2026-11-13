# Warm context

Use this Loop to give inference all supplied project rules and check evidence in its first request. Saved code prepares that context. Inference returns `ready` or `hold`, blocking check names and a short reason.

## Run the example

Run from the checkout or installed fh directory:

```sh
fh check ./loops/warm-context --bindings-id local --json
fh run ./loops/warm-context --input examples/warm-context-input.json --bindings-id local --json
fh get RUN_ID --json
```

The sample should return `hold` because `unit-tests` failed. Judge the decision separately from execution status. A completed run means execution and schema validation succeeded.

Keep inputs and receipts outside the package. For repetition, use explicit carry to bind previous results and feedback into the next inference input.
