# Installing and loading packages

Use `fh add` to copy a Loop package into your profile. You can then run it by name from any directory. A package is a folder containing `loop.json` and its companion files.

```sh
fh add ./my-loop                       # a folder on this machine
fh add acme/loops/tools/triage         # a folder in a GitHub repository
fh add acme/loops/tools/triage@v2.1.0  # at a branch, tag or full commit
fh list
fh check triage
fh run triage --input input.json
fh update triage
fh remove triage@2.1.0
```

You can also fetch, inspect, install and run a GitHub package in one command:

```sh
fh run acme/loops/tools/triage --input input.json
```

See [running from an address](#run-a-package-from-its-address) for confirmation rules.

## One rule for SOURCE and PACKAGE

fh chooses local paths, installed names and GitHub addresses from the argument's text. It never uses current-directory contents to choose a meaning.

The rule applies to SOURCE in `fh add` and PACKAGE in `check`, `run`, `batch` and `eval`. It also applies to chat `/check`, `/run`, `loop_check` and `loop_run`.

| Argument text | Meaning | Examples |
| --- | --- | --- |
| Starts with `.` or `/` | Local path | `./my-loop`, `../loops/triage`, `/Users/you/loops/triage` |
| Contains no `/` | Installed `NAME` or `NAME@VERSION`. PACKAGE only | `triage`, `triage@2.1.0` |
| Otherwise | GitHub `OWNER/REPO[/PATH][@REF]` | `acme/loops`, `acme/loops/tools/triage@v2.1.0` |

Write local folders as `./NAME` or `./loops/NAME`. `loops/NAME` instead names repository `NAME` owned by GitHub user `loops`.

If a GitHub PACKAGE address also exactly names a relative folder here, `check`, `run`, `batch` and `eval` refuse the ambiguity. They fetch and run nothing:

```text
loops/warm-context reads as a GitHub address and is also a folder in the current directory, so fh will not guess which you mean: write ./loops/warm-context to use the folder.
```

Use `./` for the local folder. To use the GitHub repository, run from another directory.

## Sources

Install with `fh add SOURCE [--yes] [--digest HEX] [--json]`.

SOURCE follows the same text rule, except it cannot be an installed name. A leading `.` or `/` selects a folder. Otherwise use a GitHub address. `acme/loops` selects GitHub even if that local folder exists.

An invalid SOURCE is refused with guidance to write `./NAME` for a local folder.

| Address part | Meaning |
| --- | --- |
| `OWNER/REPO` | GitHub repository. |
| `PATH` | Folder containing `loop.json`. Omit for the repository root. Cannot contain `@`. |
| `REF` | Branch, tag or full commit hash. Omit for the default branch. Everything after the first `@` is the ref, so `feat/next` works. Abbreviated hashes are unsupported because GitHub does not serve them. |

## What fetching does

fh uses the `git` on your PATH to fetch GitHub packages. It takes no token, offers no token option and reads no credential store. Your existing Git configuration supplies private-repository access.

Fetching proceeds as follows:

1. Fetch one commit without file contents.
2. List files under PATH.
3. Fetch their committed bytes in batches.
4. Record the exact resolved commit and remove the temporary fetch folder.

The temporary folder is private and lives at `<profile>/packages/.fetch-…`. After an interrupted fetch, the next `add` or `update` removes abandoned folders under the foreground lock. It leaves active fetches alone.

### Fetch limits

fh limits the listing before downloading file contents:

| Resource | Limit and behavior |
| --- | --- |
| Listed names under PATH | 1,024. A longer list fails before fetching contents. |
| Package files | 1,024. Larger packages are refused. |
| Package bytes | 16 MiB. Fetch batches contain one file, then two, then four, doubling each time. fh totals bytes after each batch and stops at the first overrun. |

Git cannot know unfetched file sizes, and GitHub does not serve sizes to Git. Each file or batch downloads fully before checking. Downloaded bytes can therefore exceed 16 MiB. An overrun refuses installation, deletes the fetch folder and skips remaining downloads.

### Git commands and configuration

fh reads committed bytes directly from Git's object store without checking out files. Hooks, filters, submodules and Git LFS downloads cannot run. Git is told not to ask for passwords.

Local line-ending and filter settings cannot change these bytes, so the digest is consistent across machines. Git LFS files arrive as pointer files.

These are the commands, where `$R` is the private folder. Each also carries the safety settings below:

```sh
git init --quiet --bare --template= --end-of-options $R
git --git-dir=$R remote add --end-of-options origin https://github.com/OWNER/REPO.git
git --git-dir=$R fetch --quiet --depth 1 --no-tags --no-recurse-submodules --filter=blob:none --end-of-options origin REF   # HEAD when no REF
git --git-dir=$R rev-parse --verify --quiet --end-of-options 'FETCH_HEAD^{commit}'
git --git-dir=$R ls-tree -r -z --end-of-options COMMIT:PATH                                                                  # COMMIT^{tree} when no PATH
git -c fetch.negotiationAlgorithm=noop --git-dir=$R fetch --quiet --no-tags --no-write-fetch-head --no-recurse-submodules --filter=blob:none --end-of-options origin BLOB...   # once for each batch
git --git-dir=$R cat-file --end-of-options blob BLOB                                                                          # once for each file
```

Every command names the repository with `--git-dir`. This supports `safe.bareRepository=explicit` without discovering a repository from cwd. Arguments after `--end-of-options` cannot become options.

Every command uses these settings:

| Setting | Value |
| --- | --- |
| `core.hooksPath` | `/dev/null` |
| `core.fsmonitor` | `false` |
| `core.askPass` | Empty |
| `credential.interactive` | `false` |
| `fetch.recurseSubmodules`, `submodule.recurse` | `false` |
| `filter.lfs.smudge`, `filter.lfs.process` | Empty |
| `filter.lfs.required` | `false` |
| `gc.auto` | `0` |
| `maintenance.auto` | `false` |
| `fetch.fsckObjects` | `true` |

Environment settings are `GIT_TERMINAL_PROMPT=0`, empty `GIT_ASKPASS=`, and `GIT_LFS_SKIP_SMUDGE=1`. Object checking refuses malformed trees and trees containing a `.git` entry.

fh removes these inherited variables so repository hooks or scripts cannot redirect the fetch:

| Group | Removed variables |
| --- | --- |
| Repository and worktree | `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_PREFIX`, `GIT_IMPLICIT_WORK_TREE` |
| Objects | `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES` |
| History and namespace | `GIT_NAMESPACE`, `GIT_SHALLOW_FILE`, `GIT_GRAFT_FILE`, `GIT_REPLACE_REF_BASE`, `GIT_NO_REPLACE_OBJECTS` |
| Injected configuration | `GIT_CONFIG_COUNT`, every `GIT_CONFIG_KEY_n` and `GIT_CONFIG_VALUE_n`, `GIT_CONFIG_PARAMETERS` |

Your Git configuration files remain active. URL rewrites (`insteadOf`), proxies, SSH settings and credential helpers continue to provide access.

## What is refused

`fh add` installs nothing if a package fails any of these checks:

| Check | Requirement |
| --- | --- |
| Manifest | A `loop.json` must exist. |
| Files | Regular files only. Symlinks, submodules and other types are refused. |
| Validation | Manifest, schemas and named files must pass the declaration check used before bindings in `fh check`. This runs no code, model or runtime probe. |
| Name | Starts with a letter or digit. Contains only letters, digits, `.`, `_` and `-`. |
| Version | A valid folder name using the same characters, plus `+`. |
| Case | No name or version may differ only in case from an installed one. See [storage](#where-it-goes). |
| Printable inspection | Step IDs, runtimes, filenames and capability names cannot contain control characters such as newline, tab or escape. |
| Git metadata | No `.git` file or folder at any depth, in any letter case. Applies to local and GitHub packages. |

The top-level `.git` in a local package is the exception. It belongs to the package's repository, so fh excludes it from copying and hashing. This allows `fh add ./my-loop` during development.

Installation uses the existing package bounds: 1,024 files and 16 MiB. It adds no size limits.

## Inspect before install

`fh add` shows the validated package before writing anything:

```text
Package   triage 2.1.0 (loops/0.3)
Digest    7c1d…
Source    github acme/loops, folder tools/triage at commit 4be0… (asked for v2.1.0)
Files     5
Steps
  gather  code  python3  gather.py
  judge  infer  requires workspace_read
Requires  workspace_read
Code      gather.py (python3)
```

| Mode | Behavior |
| --- | --- |
| Terminal | Ask `Install triage 2.1.0? [y/N]`, then install exactly the inspected bytes. |
| No terminal, no `--yes` | Print inspection and next command. Install nothing. Exit 2. |
| `--digest HEX` | Require the complete 64-character inspected digest after fetching again. A mismatch installs nothing and reports both digests. |
| `--yes` without digest | Install whatever the trusted source contains now. Available from the command line. |
| `--json` | Return one object, never ask. Status is `installed`, `unchanged` or `confirmation_required`. Installation requires `--yes`. Confirmation includes `next_command`. |

Without terminal confirmation, the printed next command is:

  ```text
  Nothing was installed. To install exactly what is shown above, run:
    fh add acme/loops/tools/triage@v2.1.0 --yes --digest 7c1d…
  ```

Scripts and agents must use the inspected digest to tie installation to what they reviewed.

Control characters in package-supplied display values are escaped, such as `\x0a`. They never print as literal control characters.

Installation grants no capabilities or runtimes. Those come from run bindings.

## Run a package from its address

Use `fh run ADDRESS [--input FILE|-] [--yes] [--digest HEX] [other run options]`. ADDRESS uses `OWNER/REPO[/PATH][@REF]` and the same fetching process as `add`.

| Situation | Behavior |
| --- | --- |
| Same package version and digest already installed from the same repository, folder and requested ref | Run the installed package without asking. |
| Other source at a terminal | Show inspection and ask `Install and run NAME VERSION? [y/N]`. `--yes` skips the question. |
| Other source without a terminal | Require `--yes --digest HEX`. Otherwise inspect only, exit 2 and print the next command. |
| `--json` or `--events` without `--yes` | Never ask. Return `confirmation_required` with `next_command` in the same shape as `add --json`, then exit 2. |

The noninteractive next command preserves your options:

    ```text
    Nothing was installed or run. To install and run exactly what is shown above, run:
      fh run acme/loops/tools/triage --input input.json --yes --digest 7c1d…
    ```

Once confirmed, installation uses the same lock, read-only files, digest checks, case rules and immutable versions as `add`. fh then runs the installed `NAME@VERSION` with your options.

The run record and `get` identify `<profile>/packages/NAME/VERSION/loop.json`. Retry, next and submit work as for other installed packages.

Refused installation prevents execution. This includes a moved branch with different content under the same installed version, or a name differing only in case.

Related commands handle addresses as follows:

| Command | Behavior |
| --- | --- |
| `fh check ADDRESS` | Fetch and check. Install nothing. |
| `fh batch ADDRESS --cases FILE`, `fh eval ADDRESS --cases FILE` | Fetch, inspect and install once before any case. |
| Chat `/run ADDRESS` | Never ask. Inspect and return `/run ADDRESS --yes --digest HEX`. |
| Chat `/check ADDRESS` | Fetch and check. |
| Model tools `loop_check`, `loop_run` | Refuse GitHub addresses. Only a person can fetch or install through these routes. |

If required input is missing or invalid, nothing runs. The error names the failure, prints the input schema and shows `--input FILE` or `--input -` for stdin.

## Where it goes

Installed files live at `<profile>/packages/<name>/<version>/` with mode 0400. The profile defaults to `~/.fh`, or uses `FH_DATA_DIR`. fh first writes a temporary neighboring folder, then renames it into place. Half-written packages never become visible.

Installed versions are immutable:

| New package | Result |
| --- | --- |
| Same name, version and digest | Succeed without changes. |
| Same name and version, different digest | Refuse and report both digests. Publish a new version or first remove with `fh remove NAME@VERSION`. |
| New version | Install beside existing versions. |
| Case-only name or version difference | Refuse and name the installed spelling. Remove it first to change spelling. |

Only one spelling of a name, and one spelling of each version, can be installed. This avoids collisions on case-insensitive filesystems such as default macOS. For example, `Triage` conflicts with `triage`. `1.0-RC` conflicts with `1.0-rc`.

## The lock file

`<profile>/packages.lock.json` records all installed packages. fh writes it atomically with mode 0600 under the foreground lock. The lock cannot change during a run.

```json
{
  "version": 1,
  "packages": [
    {
      "name": "triage",
      "version": "2.1.0",
      "digest": "7c1d…64 hex characters",
      "source": {
        "type": "github",
        "repo": "acme/loops",
        "path": "tools/triage",
        "ref": "v2.1.0",
        "commit": "4be0…40 hex characters"
      },
      "installed_at": "2026-11-11T09:30:00Z"
    },
    {
      "name": "my-loop",
      "version": "1",
      "digest": "…",
      "source": { "type": "local", "path": "/Users/you/loops/my-loop" },
      "installed_at": "2026-11-11T09:31:12Z"
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `digest` | SHA-256 of every package file's path and bytes, as reported by `fh check`. |
| `ref` | Requested ref, or null for the default branch. |
| `commit` | Resolved commit. |
| `path` | Package path within the repository. Empty string for the root. |
| Entry order | Oldest install first. |

## Loading by name

A PACKAGE without `/` or a leading `.` always selects an installed name. `fh run triage` uses that installation even if a local folder is named `triage`. Use `fh run ./triage` for the folder.

If the name is not installed but exists locally, fh explains:

```text
No installed package is named triage. A folder of that name is in the current directory. To use it, write ./triage. Nothing was changed. Run fh list to see what is installed, or fh add SOURCE to install one.
```

Names and versions are exact and case-sensitive. `Triage` does not select `triage`. The error identifies the installed spelling.

Chat model tools follow the same rule. Local paths must start with `.` or `/` and stay inside the workspace. GitHub addresses are refused.

A manifest's version can be any text. Bare `NAME` selects a version as follows:

| Installed versions | Selection |
| --- | --- |
| All dot-separated whole numbers, such as `2` and `1.10.0` | Numerically highest, component by component. `1.10.0` exceeds `1.9.3`. |
| Any other version text | Most recently installed. |

Every load rehashes files against the lock digest. A mismatch refuses execution and names the package and both digests. This also applies to direct installed-folder paths and loading through retry, next or submit.

After resolving links and `..`, a path inside `<profile>/packages/` must name an exact installed package folder or its `loop.json`, with a lock entry. Other paths are refused:

- Parent folders or folders inside a package.
- Other manifests beside `loop.json`.
- `.installing` or `.fetch-…` folders.
- Folders without lock entries.

## List, remove, update

Manage installations with these commands:

| Command | Behavior |
| --- | --- |
| `fh list [--json]` | Show name, version, first 12 digest characters and source for each package. |
| `fh remove NAME[@VERSION]` | Remove one version. Bare NAME works only when one is installed. Otherwise name the version. Earlier run records remain. |
| `fh update NAME [--yes] [--digest HEX] [--json]` | Fetch the recorded repository and requested ref again, or reread the local source folder. Show the same inspection as add. |

Removal deletes files first and the lock entry last. If deletion fails, the entry remains for another attempt. If files are already gone, fh removes the entry and reports it.

| Update finds | Result |
| --- | --- |
| Same version and digest | No change. |
| Same version, different digest | Refuse. The author must publish a new version. |
| New version | Install beside old versions after add-style confirmation. Without a terminal, print `fh update NAME --yes --digest HEX`. Digest checks work as for add. |
| Pinned tag or commit | Same content. Add a newer ref instead. |

Chat `/add`, `/list`, `/remove` and `/update` do the same work. Chat never asks for confirmation. `/add SOURCE` inspects and returns `/add SOURCE --yes --digest HEX`. Both `/add` and `/update` refuse `--yes` without `--digest`, which ties approval to inspected bytes.

## Exit codes

Package management uses these codes:

| Exit | Meaning |
| --- | --- |
| 0 | Installed, unchanged, listed or removed. |
| 1 | Declined confirmation or unexpected failure. |
| 2 | Refused request: invalid source, invalid package, changed installed version, missing installed name, digest mismatch, ambiguous address and local folder, or required `--yes`. |

`fh run ADDRESS` uses these codes during fetching and installation. After installation, it uses the run's exit code.
