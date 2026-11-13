# Security

Review a package's source, capabilities and grants before running it. fh is experimental software that can send content to configured services and execute work with configured authority.

Schemas, hashes and approval prompts constrain declared behavior. They cannot make an untrusted package, prompt, provider or host command safe.

## Report privately

Report vulnerabilities through this repository's Security → Report a vulnerability route. If unavailable, open an issue requesting a private contact route. Include no vulnerability details or credentials in that issue.

A private report should include:

- Affected revision and platform.
- Prerequisites and a minimal reproduction.
- Observed impact and a suggested fix, if known.

Use synthetic inputs. Remove credentials, account identifiers, private paths and unrelated records. See [diagnostic handling](docs/privacy.md#sharing-diagnostics).

## Trust boundaries

### Packages

Installation inspects and copies package data without running its code. GitHub fetching uses your Git configuration, including authentication helpers, proxies and URL rewrites.

Immutable versions and load-time hashes detect changed bytes. Review the author, source and resolved commit separately to judge trust and safety. See [packages](docs/packages.md).

### Inference and decisions

Model providers receive chat context or explicitly bound Loop inputs and instructions. Jev receives decision state and questions. Provider and account policies apply.

Prompts, packages, workspace text and browser content can contain hostile instructions. Structured validation checks the answer's format. It cannot establish correctness or safety.

### Native chat and workspace grants

Chat retains fx's native tools and authority behavior. Workspace grants name the checkout, commands and allowed files. Host commands inherit the environment and credentials.

`--trust-host` explicitly trusts the host. It provides no OS isolation. A read-only grant does not authorize commands or edits. Inspect uncertain effects before settling them. fh does not replay them automatically. See [workspace Loops](docs/workspace-loops.md).

### Source code runtimes

Optional Node and Python adapters use a registered Docker socket and an already installed immutable image. fh requests a non-root user, no container network, a read-only root, constrained mounts and constrained capabilities.

You must trust the Docker daemon, image and host configuration. Docker socket access itself is powerful. fh does not pull images or install dependencies. See [runtime setup](docs/code-runtimes.md).

### Wasm

Wasm guests have no ambient filesystem, network or host environment. The embedded engine accepts only the restricted [wasm32-wasi-json/1 profile](docs/contracts/wasm32-wasi-json-1.md).

This restriction applies to Wasm steps. The native process and other granted capabilities keep their own authority. Engine and host implementation bugs remain possible.

### Browser grants

Browser Loops can start a real browser, navigate, type, click and save screenshots. Their network access and page contents are separate from Docker's network restriction.

Grant only intended access. Review what the browser may submit or capture. See the [browser guide](docs/browser-capture.md).

### Local records and credentials

Protect the profile, environment and diagnostics. The profile can contain sensitive sessions, run inputs, outputs, effects, logs and captures.

Named API keys may use Keychain or private files. OAuth and other mechanisms have separate storage. See [privacy](docs/privacy.md) for storage and network destinations.

## What a check establishes

A successful `check` verifies supported declarations and configured prerequisites. Optional source checks run a fixed runtime probe. Checks do not execute package code or prove a later run harmless. Grant only the authority and provider inputs the task needs.
