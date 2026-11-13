# Native fx application patch

Run `python3 patches/fx/verify.py` to verify the vendored fx integration.
`0001-loops-shell-proof.patch` records the cumulative changes from revision
`4d966e272cfc4296cdf703f409480088cf2e72ba`, fx 0.0.13 under Apache-2.0.

fh retains fx's terminal, Agent, conversation worker, history, login and providers.
The Loop engine lives in `native/loops/`, outside the vendor tree, and uses the
same native inference provider. fh adds no custom OAuth client, second
conversation engine or Node application worker.

## Modified upstream files

The patch changes these 30 original files:

| File | Integration change |
| --- | --- |
| `src/main.zig` | fh entry points, native CLI and first-run setup composition, selection of the fh conversation prompt and warm context, native environment and threaded I/O initialization for direct Loops, Codex pool binding and post-frame connection-only warmup, and repository-relative imports. The existing foreground process supervisor bootstrap bypasses direct Loop command dispatch so run-owned Moli uses its established owner-pipe, deadline and process-tree cleanup. |
| `src/ui/render.zig` | exactly three welcome `𝒇x` → `𝒇h` substitutions. |
| `src/core/app/app_bootstrap_runtime.zig` | native provider and Loop-tool composition. |
| `src/core/app/app_agent_runtime.zig` | current native authority and workspace context. |
| `src/core/app/app_entry_runtime.zig` | fh startup and foreground Loop polling. |
| `src/core/app/app_input_runtime.zig` | startup preemption at decoded input ingress. |
| `src/core/app/app_render_runtime.zig` | audited fh title and model, effort and Fast footer projection. |
| `src/core/app/app_session_runtime.zig` | existing conversation-session composition. |
| `src/gateway/openai_codex.zig` | identity-scoped reuse of the original HTTP pool, bounded terminal-tail draining, stable instructions and tools before input, and optional cache counters in debug output. |
| `src/gateway/client.zig` | explicit opt-in keep-alive for the original bounded POST opener. The default remains a local client. |
| `src/core/shared/http_pool.zig` | one session or run ownership scope keyed by endpoint and private credential, account and session identity. Concurrent mismatches use a local client. Connection-only warmup owns its URL, is cancellable and joined within its 500ms I/O budget. |
| `src/core/app/provider_runtime.zig` | stable heap ownership for the Codex chat pool beside the original gateway pool. |
| `src/core/agent/stream_provider.zig` | optional validated final token counts, separate from billing attribution. |
| `src/gateway/chat_completions_protocol.zig` | expose only validated final input and output counters for Loop budgets. Retain original billing status and stream validation. |
| `src/core/output/output_contracts.zig` | optional Jev status metadata. Omitted without a callback. |
| `src/core/app/input_interrupt_runtime.zig` | native foreground cancellation. |
| `src/core/app/input_submit_runtime.zig` | explicit Loop commands beside original chat submission. |
| `src/core/config/config_runtime.zig` | native Codex, Luna, medium effort and Fast defaults, including an activated Codex provider without a saved model. |
| `src/core/cli/cli_surface.zig` | prefer the fh default when activating Codex without a saved model. Retain explicit saved choices and original provider login and catalog code. Expose the existing masked key reader to native onboarding. |
| `src/core/auth/credentials.zig` | configured-provider credential slots resolve environment first, then the named native store in fh. Original OAuth resolution stays intact. |
| `src/core/hosts/native_secret_store.zig` | Gateway keys use the same profile-scoped slots. Legacy reads apply only to the default profile, and writes never escape an isolated profile. |
| `src/core/hosts/native_keychain.zig` | small named-service wrappers reuse the original Keychain implementation for profile-scoped AI and Jev keys. |
| `src/core/config/settings_store.zig` | one validated, non-secret configured-provider definition committed through the original settings lock and durable transaction. |
| `src/core/auth/chatgpt_session.zig` | existing Codex OAuth with fh profile isolation. |
| `src/core/auth/session_presence.zig` | matching native credential root. |
| `src/core/auth/grok_session.zig` | matching native credential root for Grok. |
| `src/core/shared/profile_paths.zig` | `.fh` / `FH_DATA_DIR` profile paths. |
| `src/core/session/session_log.zig` | matching private session root. |
| `src/core/session/session_store.zig` | matching private session root. |
| `src/core/tooling/tool_runtime.zig` | curated native tools using original authority and prepared mutation behavior. |

## Added files

Six additions have separate inventory entries and hashes:

| File | Integration change |
| --- | --- |
| `src/core/app/fh_startup.zig` | visible first-paint workspace-check Loop, fh prompt policy, cached inert inventory and bounded warm guidance for chat. |
| `src/core/tooling/fh_loop_tools.zig` | native Loop and documentation descriptors. |
| `src/fh_provider_tests.zig` | focused native composition fixtures. |
| `src/gateway/fh_host.zig` | trusted native tool bridge. Provider and model selection stays outside model arguments. |
| `src/fh_loop_infer.zig` | isolated step context using original fx credentials and providers, cancellation and measured usage. Browser declarations select the restricted kernel host while tool-free requests keep their original path. |
| `src/fh_browser_agent.zig` | direct Loop dependency adapter for the unchanged fx `Agent` and `processAgentPrompt` kernel. Its sole registry entry is `browser`. Serial operations use the run capability port. The provider wrapper preserves native credentials, transport identity and reasoning and Fast policy, records every dispatch, aggregates measured token counts and stops on unknown usage or exhausted shared budgets. No ambient session or workspace context, extra model engine, retry stack or worker is introduced. |

## Startup and warm guidance

Startup runs the bundled code-only workspace-check after the first committed
frame. It uses the ordinary native runner and an inert bounded workspace
snapshot. It does not execute discovered code.

The existing activity display shows progress. Decoded keys and paste pause
startup. Ignored focus and cursor-position reports do not. One retry is allowed
after foreground work reaches an empty-draft idle frame.

Results use fx DomainNotice. Conversation context marks them untrusted. Direct
Loop inputs remain independent of conversation history.

fh selects `native/conversation_prompt.md` through fx's original prompt-policy
interface. The upstream prompt remains unchanged.

If typing preempts the Loop, the existing 20ms inventory capture supplies cached
metadata through the normal queued context lane. It omits manifest bodies and
makes no claim that validation or execution completed.

The first chat request receives complete built-in Loop documentation and bounded
session-start skill content. Skills use the retained fx catalog and validated
whole-document loader. The loader tracks exact sources, cache invalidation and
explicit omissions.

Complete warm guidance precedes changing project context and untrusted workspace
observations. Preparation makes no model call. Stable serialization alone does
not establish a provider cache hit.

## Connection reuse and accounting

Codex chat and each actual Loop run reuse the retained native HTTP pool.
Run-scoped Codex inference and Jev pools are released after all synchronous
bounded calls return. Injected and configured provider contexts keep their types.

These changes invalidate the relevant transport identity:

- Endpoint or credential value or source.
- Account or tenant.
- Chat session.

Headers, payloads, effects, deadlines and cancellation remain request-local.
After an accepted Codex terminal response, tail draining takes at most 100ms,
further bounded by the absolute deadline. An unfinished body closes the socket
without changing the accepted model result into a failure.

Cancelled, inconsistent, missing-terminal and send-failure responses cannot return
connections to the pool. A stale-socket failure preserves possibly-sent delivery
evidence.

The subscription route remains POST/SSE. It adds no unsupported prompt-cache,
server-side warmup or guessed WebSocket request fields.

| Counter | Meaning |
| --- | --- |
| `native_cache_usage` debug event | Validated optional numeric counters. Null means unknown. A present zero stays zero. |
| Token accounting | Separate from dispatch counts and billing attribution. |
| `model_request_dispatches` | Each isolated infer provider invocation after local validation and authentication setup. Calls failing after dispatch still count. |
| Count completeness | Exposed in terminal run and get results. Interrupted and recovery records cannot establish absence of model use. |

Loopback fixtures in `test-chat` and `test-loops-native` count accepted sockets
and capture headers. They test reuse, rotation, fallback, tails, cancellation,
deadlines, errors and bounded warm cleanup.

## Managed browser resource

The browser resource lives outside the vendor tree in `native/loops/browser.zig`.
It uses the original foreground command supervisor and existing capture
WebSocket/CDP transport. A foreground run lazily creates one fresh Moli and page,
shared across repeat iterations.

Generic capability and finalization ports keep browser workflow rules outside
the portable runner. Finalization runs while the durable journal and record
allocator remain alive.

Actions use real CDP mouse, text and key events. Bounded DOM observations do not
claim render freshness. Capture saves real PNGs locally.

Browser setup merges a private grant without changing AI, runtime, resource or
limit policy. No kernel or upstream process-supervisor file changed.

## Chat tools and package selection

Use these tools through the existing approval and path boundaries:

| Tool | Behavior |
| --- | --- |
| `loop_next` | Read ready steps. |
| `loop_run` | Request approval. Accept optional `runner` or `agent` driver. |
| `loop_submit` | Request approval because acceptance may execute code. Accept only `runId`, `path`, `pass` and object `output`. Cannot read an output file. |
| `docs_read` | Select a fixed document name, including `parallel_schema` for bundled 0.3. Cannot accept arbitrary document paths. |

Operators settle uncertain effects with `fh settle`.

`loop_check` and `loop_run` classify `packagePath` from its text:

| Argument | Behavior |
| --- | --- |
| Plain segment | Installed `NAME` or `NAME@VERSION`, regardless of workspace files, folders or links. Load from profile and verify the lock digest. |
| Leading `.` or `/` | Local path, such as `./loops/hello`. Canonical resolution rejects paths outside the workspace. |
| Other argument containing `/` | GitHub address. Tools reject it with `FhGithubAddressNeedsThePerson`. The engine rejects tool calls with `package_address`. A person can use `/run ADDRESS`. |

Names start with a letter or digit and use letters, digits, `.`, `_` and `-`.
Versions can also use `+`. File tools retain their existing path rules.

## Modification notices and verification

All 30 changed originals carry prominent fh notices. Six use the original
two-line notice. The other 24 use this prefix:

```zig
// Modified for Fasthands; see patches/fx/README.md for the integration changes.
```

The welcome guard requires that prefix and upstream bytes with exactly three
branding substitutions. The footer guard freezes a whole-file digest. Both remain
active under `python3 -O`. Renderer and input algorithms are retained.

Verification checks the pinned revision, original manifest hash, 30-file patch
inventory and six-file addition inventory. It rejects unknown vendor source and:

1. Reverses the patch with zero fuzz.
2. Checks all 637 original SHA256 and Git blob SHA1 values.
3. Applies the patch forward.
4. Compares reconstructed files byte for byte.

The pinned upstream manifest SHA256 is
`1704fa32bc31a4fb26d4638bb11ab89a03d042968414c4f7283f0a90a814a7e8`.

Regenerate an explicitly audited change with
`python3 scripts/update-fx-patch.py BASE`, using the last audited commit and this
manifest. Then verify. A base pinned to an older manifest is rejected.

New paths need explicit policy and inventory changes. Regeneration preserves
this boundary. The patch filename stays unchanged for attribution links.
