# Model access and chat

Run `fh` to set up model access and start a chat. Use `fh setup ai` to change access later.

## Model setup

Choose a provider that matches your access:

| Option | Requirements |
| --- | --- |
| ChatGPT/Codex | Native login. |
| Vercel AI Gateway | A Gateway key. |
| OpenAI-compatible endpoint | An endpoint, key and model supporting the existing Chat Completions protocol and tool calls. Use Gateway if the model requires another protocol. |

Setup saves API-key configuration without requesting a model or catalog. The first actual request verifies access. The provider controls model availability and account access.

Use `fh setup jev` for typed decisions. Runner-driven decision steps require Jev. The credential-free Wasm example does not. Chat, inference-only Loops and decision-only Loops need no source code runtime.

Read [credential storage and precedence](privacy.md#local-storage) before supplying private content. Read [security boundaries](../SECURITY.md) before granting execution authority.

## Chat commands

Use these commands inside chat:

| Command | Action |
| --- | --- |
| `/check` | Inspect and check a Loop. The agent can help author it. |
| `/run` | Run a Loop. |
| `/resume` | Reopen a native conversation session. |

Direct Loop commands use explicit inputs independently of chat history. At startup, fh checks the workspace using a bounded snapshot without a model call. Discovery does not execute nearby packages.
