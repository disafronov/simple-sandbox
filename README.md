# simple-sandbox

**Lightweight, non-root Linux sandboxing via bubblewrap.** A single Bash script that builds a namespace-isolated environment for arbitrary commands without requiring root privileges or a dedicated daemon.

`simple-sandbox` is a thin wrapper around [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`). It assembles a minimal execution context — a read-only host filesystem, fresh `/proc` and `/dev`, private `/tmp`, and an overlay-based `$HOME` — and runs your command inside it.

---

## Features

- **Namespace isolation** — separate PID, mount, IPC, UTS and user namespaces (`--unshare-all`) with `--die-with-parent` so nothing outlives the caller.
- **Read-only host filesystem** — `/` is bound read-only; the sandbox cannot modify the host tree.
- **Fresh `/proc` and `/dev`** — clean device and process namespaces with no access to host procs or devices.
- **Private `/tmp`** — a fresh tmpfs, plus `TMPDIR=/tmp` for predictable temp behavior.
- **Writable working directory** — the current working directory remains writable inside the sandbox. When it is `$HOME` itself, writes go to the `$HOME` overlay rather than directly to the host directory.
- **Per-runtime `HOME` overlay** — overlayfs keeps the host `$HOME` read-only to the sandbox while changes accumulate in a private upper layer for as long as its `XDG_RUNTIME_DIR` instance exists.
- **Configurable path policies** — `hide`, `readonly`, `expose` and `overlay` per-path rules via a JSON config file.
- **Environment sanitization** — canonical `TMPDIR`/`XDG_RUNTIME_DIR` plus a configurable `unset` list for sensitive variables.
- **Concurrency-safe** — per-instance `flock` serializes overlay mounts so parallel invocations cannot corrupt shared upper/work layers.
- **Security hardening** — strict validation of the config and policy paths, refusal to apply policies to `/`, refusal to use a `bwrap` from the working directory, and tight `0700` permissions on all private state.
- **Zero privileges** — everything runs as the invoking user; no root, no SETUID.

---

## Requirements

`simple-sandbox` verifies each dependency at startup and aborts with a clear message if any is missing.

| Dependency   | Purpose                                                              |
|--------------|----------------------------------------------------------------------|
| `bwrap`      | The sandbox engine; **must** support `--overlay-src` (persistent overlays). |
| `envsubst`   | Expands `${VAR}` in configuration paths.                            |
| `flock`      | Serializes concurrent overlay mounts (concurrency safety).         |
| `jq`         | Parses and strictly validates the JSON config file.                |
| `realpath`   | Canonicalizes paths and resolves policy mount destinations.        |
| `sha256sum`  | Derives sandbox instance IDs and overlay IDs from paths.           |

> **Note:** `bwrap` itself needs kernel support for user namespaces (`kernel.unprivileged_userns_clone`, typically enabled by default).

---

## Installation

### From source

```bash
git clone https://github.com/disafronov/simple-sandbox.git
cd simple-sandbox
chmod +x simple-sandbox
```

The script has no build step or runtime dependencies besides those listed above. Copy the executable wherever you like, e.g.:

```bash
install -m 0755 simple-sandbox ~/.local/bin/simple-sandbox
```

## Usage

```
simple-sandbox command [args...]
```

`simple-sandbox` takes a single positional command line: everything after the script name is the command and its arguments to run inside the sandbox. The invocation directory becomes the writable working directory.

Nothing after the command is parsed by `simple-sandbox`; if the command itself has options they are passed through to the sandbox unchanged. All positional arguments are passed directly to `bwrap` as the command and its arguments. The script inserts bwrap's `--` option-separator automatically, so you do **not** need to (and should not) pass `--` yourself.

```bash
# Interactive shell
./simple-sandbox bash

# Build in the current directory
./simple-sandbox make test

# Run a Python script; the host filesystem is read-only by default
./simple-sandbox python3 ./tool.py
```

### Operating point

The sandbox is identified by a **SHA‑256 digest of the invocation working directory** (the physical `pwd -P`). Its state — the `$HOME` overlay, per-path overlays and the private runtime directory — lives under a single instance root:

```
$XDG_RUNTIME_DIR/simple-sandbox/<sha256(workdir)>/
```

| Path                        | Purpose |
|-----------------------------|---------|
| `home-upper/`               | Writable upper layer for the `$HOME` overlayfs. |
| `home-work/`                | Work directory required by the `$HOME` overlay mount. |
| `runtime/`                  | Bound onto `$XDG_RUNTIME_DIR` inside the sandbox. |
| `overlays/<id>/upper,work`  | Upper and work directories for an `overlay` policy. |
| `lock`                      | `flock` guard held for the sandbox process lifetime. |

State is reused by later invocations from the same physical working directory, but it is not durable storage: `XDG_RUNTIME_DIR` is normally cleaned up when the user session ends.

The environment variable `$SIMPLE_SANDBOX_CONFIG` points to a custom JSON configuration **file**; see [Configuration](#configuration). When unset, the config defaults to `${XDG_CONFIG_HOME:-~/.config}/simple-sandbox.json` (skipped if missing).

---

## Configuration

If a config file exists, `simple-sandbox` reads a JSON document that may contain only the `paths` object and the `unset` array; either key may be omitted. The document is strictly validated with `jq` and the launch is aborted on any violation.

```json
{
  "paths": {
    "/home/user/secret": "hide",
    "/etc/passwd": "expose",
    "/var/log": "readonly",
    "/home/user/projects": "overlay"
  },
  "unset": ["AWS_SECRET_ACCESS_KEY", "PRIVATE_TOKEN"]
}
```

### `paths` — path policies

Keys may be absolute or relative paths, may contain `${VAR}` environment expansions and `~` for the home directory, and are resolved relative to the working directory when they are not absolute. Referenced variables must exist in the launcher environment. The **final path component is preserved** while symlinks in parent components are resolved.

| Policy      | Meaning                                                            |
|-------------|--------------------------------------------------------------------|
| `hide`      | Dir → `--tmpfs`; file → read-only bind of `/dev/null` (an empty file). |
| `readonly`  | Re-mount the path read-only with `--ro-bind`.                       |
| `expose`    | RW bind-mount the host path into the sandbox.                       |
| `overlay`   | Per-runtime overlay of a host directory with a private upper layer. |

`overlay` requires the path to be a directory. Policies for the filesystem root are refused. Duplicate policies for the same resolved path are deduplicated when their actions match; conflicting actions abort the launch. A policy whose target does not exist is skipped. Parent mounts precede child mounts so deeper destinations can override shallow ones.

### `unset` — environment

Sanitize the environment by removing listed variable names with `--unsetenv`. Each value must be a valid shell/sanitized variable name (`^[A-Za-z_][A-Za-z0-9_]*$`).

---

## How it works

`simple-sandbox` builds `bwrap` arguments and `exec`s it directly, so there is no lingering wrapper process. Its base mounts are:

```
--die-with-parent
--unshare-all
--share-net
--ro-bind / /
--proc /proc
--dev /dev
--overlay-src $HOME --overlay home-upper home-work $HOME
--bind $workdir $workdir
--tmpfs /tmp
```

Lifecycle:

1. **Validate** — checks all dependencies, `HOME`, `XDG_RUNTIME_DIR` (exists/writable), command presence, and that `bwrap` supports persistent overlays and does not come from the working directory.
2. **Derive state** — `sandbox_id = sha256(workdir)`; creates and `chmod 700`s the instance under `$XDG_RUNTIME_DIR/simple-sandbox/`.
3. **Parse config** (`paths` + `unset`), resolve each policy path and sort parents before children.
4. **Build args** — a read-only root, `--proc`, `--dev`, a `$HOME` overlay, and a writable view of the working directory. The order is adjusted when the working directory is `$HOME` or an ancestor of it.
5. **Apply policies** — `hide`/`readonly`/`expose`/`overlay` and `--unsetenv` for the sanitized variables.
6. **Set env** — `TMPDIR=/tmp`, `XDG_RUNTIME_DIR` remapped to the per-instance `runtime/` dir, and `--chdir` to the working directory.
7. **Lock & exec** — take the instance `flock`, then `exec bwrap`.

---

## Limitations

- **The host filesystem is readable by default** — `--ro-bind / /` prevents writes, but does not hide host files. Use `hide` policies for secrets and other paths a command must not read.
- **No network isolation** — `--share-net` is intentional; the sandbox shares the host network namespace.
- **No syscall filtering** — nothing like seccomp is applied; isolation relies entirely on bubblewrap's namespace/mount model.
- **State is session-scoped** — overlays live in `XDG_RUNTIME_DIR` and normally disappear at session cleanup. The per-instance lock protects concurrent invocations of one user and working directory; it is not a multi-user store.
