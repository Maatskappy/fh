# fh agent guide

## PR reviews

Dassie PR reviews are off for Maatskappy repositories (CFO cost decision, November 20, 2026). Never request, re-enable, or wait for one. A missing Dassie review never blocks a PR.
Follow this repository’s local review requirements for the final PR head. The installed Inby review loop covers only `Maatskappy/Inby`, on `pr.opened` and `pr.updated`, using Codex (`gpt-6.2-sol`). For every other Maatskappy repo, run the loop only on request. Keep any second local Claude or Codex CLI review required by this repository.

See [running the review on request](https://github.com/Maatskappy/Inby/tree/master/loops/inby-review-collector#run-on-request). To set up Inby for the first time, run the [installer](https://github.com/Maatskappy/Inby/blob/master/loops/inby-review-collector/install.sh) from the target repo checkout. It stages the package and a trigger for PR opens and new heads. Approve them in Loops. With the package and collector already installed, add an open-only trigger and approve it in Loops.

```sh
inby loop trigger add "Inby review" --on pr.opened --repo . --input-from "command:$HOME/.local/share/inby-review/collect.py" --workspace collector --deliver pr --inference codex --model gpt-6.2-sol --max-tokens 8000000 --max-minutes 90
```

Use `--on pr.updated` to include head updates as well as opens.
Without Inby, use [fh with the portable review package](https://github.com/Maatskappy/Inby/tree/master/loops/inby-review-collector#run-with-fh).
Use your own Claude or Codex subscription for inference. Never use Dassie platform keys.
