# Privacy and local data

fh sends data to the providers and capabilities you configure. Review a package's bindings, prompts and grants before giving it private content. fh uses native fx authentication and providers alongside the native Loop runner.

## Local storage

fh stores its profile in `~/.fh`. Set `FH_DATA_DIR` to another absolute, private directory to use a separate profile.

The profile holds:

- Settings, installed packages and locks.
- Runtime grants and resource grants.
- Conversation sessions, history and usage records.
- Saved run inputs, outputs, effect records and recovery records.

These records can contain source code, prompts, model responses and private workspace data. Browser captures and exported reports can also contain screenshots. They may be saved to explicit locations outside the profile.

Credentials use several storage mechanisms:

| Credential | Storage | Which source is used |
| --- | --- | --- |
| OpenAI-compatible provider keys and Jev keys | Profile-scoped macOS Keychain items when available. Otherwise private profile files | Environment credentials override saved named keys. `FX_DISABLE_KEYCHAIN=1` selects private files. |
| Gateway key | The source selected during setup | `AI_GATEWAY_API_KEY` does not override a selected stored key. `FX_DISABLE_KEYCHAIN=1` makes that stored source unavailable. It does not select files instead. |
| Codex OAuth and other native authentication | Their own local session and credential files | Each native authentication mechanism controls its own credentials. Not every secret is in Keychain. |

Direct API keys stay out of non-secret settings. User content and service responses can still put secrets in sessions, tool results, run records or traces.

The optional `FX_TRACE`, `FX_TRACE_LOG` and `FX_TRACE_STDERR` diagnostics can expose sensitive requests and session details. Protect traces and recordings as carefully as the profile.

After a disposable example, unset `FH_DATA_DIR` to return to `~/.fh`. Stop fh before removing an unwanted profile or its separate capture and report outputs. Removing the profile does not remove separate Keychain entries, backups or external service data, and does not delete an account.

## Network destinations

Each configured capability determines what can leave your machine:

| Capability | Data and destination |
| --- | --- |
| Chat | Instructions, conversation context and tool results go to the selected inference provider. Context can include workspace observations and loaded guidance. |
| Loop inference | Declared instructions, resolved input and output-schema guidance go to the inference provider. Granted agent and browser tools can obtain more content. |
| Jev decisions | Resolved state, model and questions go to the configured TypeSafe/Jev service. |
| Provider authentication | The provider receives the credentials or OAuth exchanges its flow requires. Codex uses native fx OpenAI OAuth and local callback handling. It does not import a global Codex login. |
| GitHub packages | Your Git executable uses its configured credentials, helpers, URL rewrites and proxies. |
| Browser grants | The browser contacts target sites. Review submitted forms, cookies and screenshots separately. |
| Build | The build can fetch the pinned Wasmtime dependency. |
| Host commands | Commands can use the network and credentials inherited from your environment. Docker source-runtime restrictions do not constrain host commands or browsers. |

A pure retained Wasm example needs no provider request or external source runtime. Provider, Git host and target-site policies govern the data they receive. Local deletion does not ask those services to delete data.

## Sharing diagnostics

Create a small reproduction with synthetic inputs and an isolated profile before sharing diagnostics.

Remove these details from reports, sessions, run JSON, screenshots and traces:

- API tokens, OAuth tokens, authorization headers and cookies.
- Account identifiers, private URLs and personal paths.
- Unrelated source code and conversation content.

Check free-text fields and image pixels as well as fields named `secret`. Keep original evidence private when needed. Label redacted or derived copies accurately. Do not upload an entire profile as a bug report.

Use the reporting route or fallback in [SECURITY](../SECURITY.md) for vulnerabilities.
