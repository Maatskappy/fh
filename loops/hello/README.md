# Hello

Run this Loop to draft and check a plain sentence explaining a loop. It needs no input, browser or code runtime.

| Step | Action |
| --- | --- |
| `draft` | Write one plain sentence. |
| `check` | Check whether it is plain and under 25 words. Supply a tighter version if needed. |

A binding passes the draft to the check. fh validates each output against its schema before passing it on.

## Use fh's model

Run `fh setup ai` once, then use the checkout or installed fh directory:

```sh
fh check ./loops/hello
fh run ./loops/hello
```

## Use an outside agent

Have your agent supply the answers without setup or a model call from fh:

```sh
fh run ./loops/hello --driver agent --json
fh next RUN_ID --json
fh submit RUN_ID --path draft --pass 0 --output draft.json
fh submit RUN_ID --path check --pass 0 --output check.json
fh get RUN_ID --json
```

`fh next` returns the ready step's instructions, input and output schema. Write its answer as JSON in a file, then submit it.

| File | Answer shape |
| --- | --- |
| `draft.json` | `{"sentence": "..."}` |
| `check.json` | `{"ok": true, "sentence": "..."}` |

After submitting the draft, `fh next` returns `check` with that sentence as input.

## Choose a topic

Save `{"topic": "baking bread"}` to a file and add `--input FILE` to write about that topic. Without a topic, the sentence is general.

Read the final sentence to judge it. A completed run establishes that both steps ran and their outputs matched the schemas.
