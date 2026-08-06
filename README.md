# simple-sandbox

**Lightweight, non-root, filesystem-focused Linux sandboxing via bubblewrap.**

`simple-sandbox` is a thin wrapper around [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`). It builds a minimal execution environment with a read-only host filesystem, fresh `/proc` and `/dev`, a private `/tmp`, and an overlay-based `$HOME`, then runs an arbitrary command inside it.

## Default contract

Without any configuration, `simple-sandbox` provides:

- A **read-only** view of the host filesystem.
- A **writable invocation working directory**.
- A **private writable overlay for `$HOME`**.
- Fresh `/proc` and `/dev`.
- A private `/tmp`.
- The **host network unchanged**.

Configuration is optional and exists only to extend this baseline with path-specific policies and environment filtering.

---

## Features

- **Namespace isolation** — separate PID, mount, IPC, UTS and user namespaces (`--unshare-all`) with `--die-with-parent` so nothing outlives the caller.
- **Read-only host filesystem** — `/` is mounted read-only by default. Only the working directory and paths explicitly exposed by policy may modify the host filesystem.
- **Fresh `/proc` and minimal `/dev`** — the sandbox gets its own procfs and a newly created minimal device tree instead of the host mounts.
- **Private `/tmp`** — a fresh tmpfs, plus `TMPDIR=/tmp` for predictable temporary-file behavior.
- **Writable working directory** — the invocation working directory is bind-mounted read-write from the host. When it is `$HOME` itself, writes are redirected into the `$HOME` overlay instead of the host directory.
- **Per-runtime `$HOME` overlay** — overlayfs keeps the host `$HOME` read-only while sandbox changes accumulate in a private upper layer for the lifetime of the corresponding `XDG_RUNTIME_DIR` instance.
- **Configurable path policies** — optional `hide`, `readonly`, `expose` and `overlay` rules for individual paths.
- **Hierarchical path policies** — parent paths are applied before child paths, allowing narrow exceptions inside broader rules without depending on configuration order.
- **Environment sanitization** — canonical `TMPDIR`, `XDG_RUNTIME_DIR` and `HOME`, plus an optional `unset` list for sensitive environment variables.
- **Concurrency-safe** — per-instance `flock` serializes overlay mounts so concurrent invocations cannot corrupt shared overlay state.
- **Trusted launcher** — every external tool the wrapper invokes is resolved to a canonical absolute path and rejected if it resides inside the writable working directory. `bash` is pinned via the fixed `#!/bin/bash` shebang and is never resolved through `PATH`.
- **Runtime validation** — refuses a setuid `bwrap`; verifies persistent overlay support; validates `XDG_RUNTIME_DIR` ownership and permissions; refuses symlinked state paths; creates private runtime state with `0700` permissions.
- **Strict policy validation** — configuration is strictly validated; invalid paths, conflicting rules, attempts to apply policies to `/`, and malformed environment variable names abort startup.
- **Zero privileges** — everything runs as the invoking user. No root privileges and no setuid `bwrap`.

---

## Requirements

`simple-sandbox` resolves every external tool it invokes to a canonical absolute path during startup and aborts if any required dependency is missing or resides inside the writable working directory.

`bash` itself is pinned through the fixed `#!/bin/bash` shebang rather than `#!/usr/bin/env bash`, so it is never resolved through a launcher `PATH`.

| Dependency | Purpose |
|------------|---------|
| `bash` | The interpreter; pinned via `#!/bin/bash`. |
| `bwrap` | Sandbox engine; **must** support `--overlay-src` and **must not** be setuid. |
| `envsubst` | Expands `${VAR}` in configuration paths. |
| `flock` | Serializes concurrent overlay mounts. |
| `jq` | Parses and strictly validates the JSON configuration. |
| `realpath` | Canonicalizes paths and resolves policy destinations. |
| `sha256sum` | Derives sandbox instance and overlay identifiers. |
| `grep`, `cut`, `sort` | Detect features, split hashes and order policy mounts. |
| `mkdir`, `chmod` | Creates private runtime state with `0700` permissions. |
| `stat` | Verifies `XDG_RUNTIME_DIR` permissions. |

> **Note:** `bwrap` requires Linux user namespaces (typically enabled by default via `kernel.unprivileged_userns_clone`).

---

## Installation

### From source

```bash
git clone https://github.com/disafronov/simple-sandbox.git
cd simple-sandbox
chmod +x simple-sandbox
```

Install anywhere in your `PATH`, for example:

```bash
install -m 0755 simple-sandbox ~/.local/bin/simple-sandbox
```

No build step is required.

---

## Usage

```text
simple-sandbox command [args...]
```

`simple-sandbox` accepts a command followed by its arguments.

The current working directory becomes the writable project directory inside the sandbox.

The wrapper does **not** interpret the command's arguments as its own options. They are forwarded unchanged to the executed command after Bubblewrap's `--` separator.

Examples:

```bash
# Interactive shell
simple-sandbox bash

# Build in the current directory
simple-sandbox make test

# Run a Python script
simple-sandbox python3 ./tool.py
```

---

## Operating point

Persistent runtime state is keyed by the **SHA-256 digest of the physical invocation working directory** (`pwd -P`).

Each working directory receives its own runtime instance under:

```text
$XDG_RUNTIME_DIR/simple-sandbox/<sha256(workdir)>/
```

| Path | Purpose |
|------|---------|
| `home-upper/` | Writable upper layer for the `$HOME` overlay. |
| `home-work/` | Overlay work directory. |
| `runtime/` | Bound onto `XDG_RUNTIME_DIR` inside the sandbox. |
| `overlays/<id>/upper,work` | Runtime state for `overlay` path policies. |
| `lock` | Lifetime `flock` protecting concurrent access. |

State is reused by later invocations from the same physical working directory.

It is **not durable storage**. Runtime state normally disappears when `XDG_RUNTIME_DIR` is cleaned up at session end.

The optional configuration file is specified via:

```text
SIMPLE_SANDBOX_CONFIG
```

When unset, the default path is:

```text
${XDG_CONFIG_HOME:-~/.config}/simple-sandbox.json
```

Missing configuration files are silently ignored.

---

## Configuration

Configuration is entirely optional.

If present, the JSON document may contain:

- `paths`
- `unset`

No other top-level keys are accepted.

Example:

```json
{
  "paths": {
    "~/.ssh": "hide",
    "~/.config/my-tool": "readonly",
    "/var/tmp/project-cache": "expose",
    "~/.cache/build": "overlay"
  },
  "unset": [
    "AWS_SECRET_ACCESS_KEY",
    "PRIVATE_TOKEN"
  ]
}
```

### `paths`

Each key may be:

- absolute;
- relative to the working directory;
- contain `${VAR}`;
- use `~` for the user's home directory.

The final path component is preserved while symlinked parent directories are canonicalized.

| Policy | Meaning |
|--------|---------|
| `hide` | Directory → `tmpfs`; file → read-only bind of `/dev/null`. |
| `readonly` | Rebind read-only. |
| `expose` | Read-write bind from the host. |
| `overlay` | Runtime overlay with a private upper layer. |

`overlay` applies only to directories.

Policies targeting `/` are rejected.

Missing filesystem paths are skipped.

If a `${VAR}` reference expands an unset environment variable, the corresponding policy is skipped and a warning is written to standard error.

Duplicate identical policies are merged.

Conflicting policies abort startup.

Parent paths are mounted before children so deeper paths can intentionally override broader ones. Configuration order is therefore irrelevant.

Example:

```json
{
  "paths": {
    "~/.local/share": "hide",
    "~/.local/share/uv": "expose"
  }
}
```

The broader directory remains hidden while the `uv` subdirectory is explicitly exposed.

## Limitations

- **The host filesystem is readable by default.** Only writes are restricted. Use `hide` policies for paths that must not be visible.
- **Policies are explicit.** Paths remain readable unless hidden by policy.
- **The host network is shared.** No network namespace isolation is performed.
- **No syscall filtering.** No seccomp or similar syscall restrictions are applied.
- **Runtime state is ephemeral.** Overlay state is intended for temporary execution state, not persistent storage.
