# Local browser Loops and native capture

Use a Loop with `requires:["browser"]` for model-driven checks. Use `fh capture` to run a saved capture plan against an existing endpoint.

## Run a browser Loop

Register installed Moli 1.1.13 from the complete fh bundle. Setup downloads nothing. Use the default home-relative location shown under [Local Moli](#local-moli), or pass `fh setup browser --binary /absolute/path/to/moli`.

```bash
fh setup browser
fh check ./loops/browser-check --bindings-id local --json
```

Serve the anonymous example in another terminal. Python is only a development fixture server:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory examples/browser-check
```

Run the keyboard check with configured native model credentials:

```bash
fh run ./loops/browser-check --input examples/browser-check-input.json --bindings-id local --json
fh get RUN_ID --json
```

Stop the fixture server with Ctrl-C afterwards. fh starts and cleans up its own Moli. Keep CDP addresses outside the Loop.

Reuse the same package with another external input, then compare digests in `get`. Read `output.passed` for the domain verdict. `completed` means execution was valid.

Local browser Loops support only the local Moli binding, without Kitesurf. See [authoring](loops.md#browser-inference) for authority and policy.

## Browser tool reference

Call the restricted model tool as `browser({"actions":[...]})`. Each call accepts 1–32 sequential actions:

| Action | Fields and behavior |
| --- | --- |
| `navigate` | `url`: absolute HTTP(S) URL. |
| `observe` | Bounded DOM text, controls, values, checked state and focus. |
| `activate` | `handle`: integer from the latest observation. Uses real mouse activation. |
| `type` | `text`: insert into the currently focused editable input. |
| `key` | `key`: `Tab`, `Shift+Tab`, `Enter`, `Space` or `Escape`. |
| `capture` | Private PNG reference, SHA256 and byte count. |

Every action returns an observation. Inspect the initial page before batching a known keyboard sequence. Default policy allows two tool calls for the entire run. Actions and provider turns also consume shared operation, token and time budgets. Do not silently raise limits.

Require actual observations in instructions. Distinguish domain failure from execution error. The [package](../loops/browser-check/loop.json), [input](../examples/browser-check-input.json) and [fixture](../examples/browser-check/fixture.html) demonstrate this contract.

DOM observations say `render_freshness:not_established`. A PNG does not identify the served build.

| Boundary | Support |
| --- | --- |
| Established test coverage | Simple top-level macOS/Moli page. |
| Unestablished interactions | Frames, shadow DOM, scrolling, dragging and dropping, IME, text replacement. |
| Unavailable tools | JavaScript evaluation, filesystem or code broker, computer tools, web-search tools, cloud browser binding. |

## Explicit capture

Run `fh capture` with a saved procedure and explicit CDP WebSocket endpoint. The native executable uses the same transport for local Moli and experimental Cloudflare Kitesurf. It does not install, start or select an engine.

```sh
fh capture examples/browser-capture.json \
  --cdp ws://127.0.0.1:9222/devtools/browser/moli-browser \
  --out capture-example --json
```

Choose a new or empty output directory. fh exclusively creates private `capture.json` and requested `<checkpoint-id>.png` files. `--json` returns one final receipt. Diagnostics go to stderr.

| Exit | Meaning |
| --- | --- |
| 0 | Procedure completed. |
| 1 | Capture or transport failure. |
| 2 | Invalid input or invocation. |
| 130 | Cancellation. |

An application HTTP error is evidence. It does not itself fail the capture procedure.

## Local Moli

Install the pinned [Moli 1.1.13 release](https://github.com/lexmount/moli/releases/tag/v1.1.13) for your platform. Verify its SHA256 against the publisher's release digest first. The tested macOS location is `~/.local/share/fh/browsers/moli-1.1.13/moli`. Linux runtime behavior is unverified.

For explicit capture, start a foreground localhost server separately:

```sh
~/.local/share/fh/browsers/moli-1.1.13/moli --version
~/.local/share/fh/browsers/moli-1.1.13/moli serve \
  --host 127.0.0.1 --port 9222 --layout --resource
```

Keep it running while capturing from another terminal. Stop it with Ctrl-C afterwards. fh closes its own target and connection, leaving the rest of your browser open. See [Moli server options](https://github.com/lexmount/moli).

For a local app, put its localhost URL in the plan and use local Moli. Do not tunnel this server. Cloud endpoints cannot reach your localhost app. Use cloud capture only for public URLs suitable for transmission.

## Experimental Kitesurf

Set up Cloudflare account access before capture:

1. Obtain your account ID.
2. Create an API token with `Browser Rendering - Edit`, scoped to that account.
3. Put it in an environment variable through your normal secret setup.

fh reads the token only after validating input, output and sources. Keep it out of the plan and command URL.

```sh
fh capture examples/browser-capture.json \
  --cdp "wss://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/browser-run/devtools/browser?browser=kitesurf" \
  --token-env CLOUDFLARE_API_TOKEN --out capture-kitesurf --json
```

`--token-env` sends an Authorization bearer header. TLS certificates are verified. Authenticated upgrades never redirect. Receipts omit endpoint queries and redact the token.

There is no automatic engine fallback. A protocol error names the unsupported method. fh connects directly to CDP without a Node worker or browser framework.

Check Cloudflare's [pricing](https://developers.cloudflare.com/browser-run/pricing/), [Kitesurf documentation](https://developers.cloudflare.com/browser-run/kitesurf/) and [account setup](https://developers.cloudflare.com/browser-run/get-started/) for current beta terms and limits.

## Saved procedure

Save a `fh.capture/0.1` plan with an HTTP(S) URL, viewport, deadline and ordered checkpoints. The viewport defaults to 1280×720. Timeout defaults to 10,000 ms.

Each checkpoint needs a unique ID of 1–64 ASCII letters, digits, `_` or `-`. Optional fields are:

| Field | Behavior |
| --- | --- |
| `action` | Evaluate unchanged JavaScript with `awaitPromise`. Return values are ignored. Synthetic DOM events are not trusted browser input. |
| `wait` | Evaluate a boolean expression immediately. If false, use an observer and animation-frame checks within the remaining deadline. |
| `evaluate` | Collect a JSON-serializable expression by value. Exceptions and non-JSON results fail explicitly. |
| `screenshot` | Boolean, default false. Requested PNGs are validated before writing. |

Navigation acknowledgement does not establish readiness. Wait uses the declared expression, without fixed sleeps or network-idle detection.

For asynchronous actions, use a promise such as `fetch('/empty').then(r => r.text()).then(text => { window.readResult = text; })`. Navigation can destroy an awaited context. Use separate action and readiness checkpoints when needed.

Before connecting, fh rejects unknown keys, duplicate IDs, invalid UTF-8, URL credentials or control characters, and out-of-range limits. Page fragments are allowed. Endpoint fragments are rejected.

## Source consistency and limits

Use optional `sources` to name explicit regular files relative to the plan. fh hashes each before and after capture. It scans no other source and uploads no source contents.

Equal hashes establish source consistency only. `freshness` stays `not_established`. Judge the served build from observed response URLs, headers, bodies and build identifiers.

| Resource | Bound |
| --- | --- |
| Sources | 16 files, 4 MiB each |
| Procedure | 1 MiB |
| Checkpoints | 32 |
| Deadline | 1–60,000 ms |
| Incoming WebSocket message | 16 MiB |
| Screenshot | 8 MiB |
| Records | 512 |
| Decoded retained bodies | 64 KiB each. 1 MiB total |
| Network event retention | 64 KiB per event. 4 MiB aggregate |
| Target cleanup | Separate bounded best-effort allowance of 500 ms |

Reached bounds produce omissions or gaps, rather than claiming complete evidence. DNS, connect, TLS, upgrade and CDP execution share one monotonic deadline. Ctrl-C cancels in-flight I/O. If target creation is interrupted before its ID arrives, the receipt records uncertain ownership.

## Interpreting evidence and latency

Read the receipt for the exact plan SHA256, sanitized endpoint and observed `Browser.getVersion`. It also records viewport, checkpoints, network lifecycle, source consistency, gaps and timings. Start and end timestamps are monotonic milliseconds on this machine, rather than wall-clock time.

Each network identity includes session ID, request ID and redirect hop. Request start, headers, loading completion or failure, and body retrieval are separate facts.

An empty successful body is a valid `retrieved` body. Failed and pending requests never become successful reads. `network_receipts_complete` describes retained lifecycle events separately from body completeness. Inspect `headers_complete` and body omissions or errors per request.

`evidence_complete=false` can mean an observed failed response had no available body. It does not erase that observed failure or imply that the capture procedure failed.

Warm checkpoints share one connection and target within an invocation. Compare timings with their scopes in mind:

| Timing | Scope |
| --- | --- |
| Connection, setup, navigation | Initial work. |
| Action, wait, DOM, screenshot | Per checkpoint. Screenshot includes capture, validation and writing. |
| `export_ms` | PNG writes and initial receipt serialization and write. Excludes the final timing-field correction. |

These measurements overlap. Do not sum them as independent stages. Persistent warmth across invocations and concurrency capacity are unestablished. Report local and remote latency separately, with sample counts for percentiles.

A screenshot records the chosen engine's rendering. Moli and Kitesurf do not establish Chromium, Safari or Firefox fidelity.

Test authentication, cookies, form login, passkeys and application features separately. Method acknowledgements do not establish persistent cookies or reusable accounts. The interface promises no generic authenticated-session support.

Receipts are ordinary reusable JSON. A compatible Loop can read them with `fh run PACKAGE --input capture-example/capture.json --json`. Adapt them to its schema when needed. Reuse the plan with a new output directory for fresh evidence without rewriting actions.

## Development checks

Run these checks from the checkout:

```sh
zig build test
zig build check
zig build test-chat
python3 patches/fx/verify.py
zig build dev
python3 tests/native/browser_capture_test.py zig-out/bin/fh
```

The Python test supplies controlled HTTP and WebSocket fixtures. It checks framing, protocol errors, lifecycle records, outputs, deadlines and cancellation, and reports fixture timings. Synthetic PNG and CDP responses do not establish rendering behavior. Use a real browser for rendering tests.
