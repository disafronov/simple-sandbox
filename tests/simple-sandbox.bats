#!/usr/bin/env bats
# Test suite for simple-sandbox.
#
# Category 1: pure bash logic that must fail with die() BEFORE `exec bwrap`.
#             These tests do not need a real bubblewrap.
# Category 2: real sandbox integration (requires bubblewrap).
#
# NOTE: scratch directories live under $HOME, NOT under /tmp — the sandbox
# remounts /tmp as tmpfs, which would hide a workdir placed there.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    export PATH="$REPO_ROOT:$PATH"
    scratch="$(mktemp -d "$HOME/.simple-sandbox-bats.XXXXXX")"
    # Always pass an explicit config so a real user config is never picked up.
    printf '{"paths": {}}\n' > "$scratch/config.json"
}

teardown() {
    rm -rf -- "$scratch" "${extra_cleanup[@]}"
}

# die() writes to stderr; bats >= 1.8 keeps stderr separate from $output,
# so match against either stream.
assert_die() {
    local needle="$1"
    if [[ "$output" != *"$needle"* && "$stderr" != *"$needle"* ]]; then
        fail "expected die message containing '$needle'; stdout=[$output] stderr=[$stderr]"
    fi
}

# ---------- Category 1: pre-exec validation (no real bwrap needed) ----------

@test "refuses a tool planted in the working directory" {
    mkdir -p "$scratch/fake-project"
    cp "$(command -v bash)" "$scratch/fake-project/jq"
    cd "$scratch/fake-project"
    PATH="$PWD:$PATH" run env SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox true
    [ "$status" -ne 0 ]
    assert_die "refusing to use jq from the working directory"
}

@test "refuses setuid bubblewrap" {
    command -v bwrap >/dev/null || skip "bwrap not installed"
    mkdir -p "$scratch/bin"
    cp "$(command -v bwrap)" "$scratch/bin/bwrap"
    chmod u+s "$scratch/bin/bwrap"
    PATH="$scratch/bin:$PATH" run env SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox true
    [ "$status" -ne 0 ]
    assert_die "refusing setuid bubblewrap"
}

@test "refuses unset XDG_RUNTIME_DIR" {
    run env -u XDG_RUNTIME_DIR SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox true
    [ "$status" -ne 0 ]
    assert_die "XDG_RUNTIME_DIR is not set"
}

@test "refuses nonexistent XDG_RUNTIME_DIR" {
    run env XDG_RUNTIME_DIR="$scratch/nope" SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox true
    [ "$status" -ne 0 ]
    assert_die "does not exist"
}

@test "refuses non-writable XDG_RUNTIME_DIR" {
    mkdir -p "$scratch/ro-runtime"
    chmod 0555 "$scratch/ro-runtime"
    run env XDG_RUNTIME_DIR="$scratch/ro-runtime" SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox true
    [ "$status" -ne 0 ]
    assert_die "is not writable"
}

@test "refuses symlinked XDG_RUNTIME_DIR" {
    mkdir -p "$scratch/real-runtime"
    ln -s "$scratch/real-runtime" "$scratch/runtime-link"
    run env XDG_RUNTIME_DIR="$scratch/runtime-link" SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox true
    [ "$status" -ne 0 ]
    assert_die "must not be a symlink"
}

@test "refuses XDG_RUNTIME_DIR owned by another user" {
    [[ -O /tmp ]] && skip "/tmp is owned by the current user here"
    run env XDG_RUNTIME_DIR=/tmp SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox true
    [ "$status" -ne 0 ]
    assert_die "not owned by the current user"
}

@test "refuses group- or world-writable XDG_RUNTIME_DIR" {
    mkdir -p "$scratch/shared-runtime"
    chmod 770 "$scratch/shared-runtime"
    run env XDG_RUNTIME_DIR="$scratch/shared-runtime" SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox true
    [ "$status" -ne 0 ]
    assert_die "must not be group or world writable"
}

# ---------- Category 2: real sandbox behavior (requires bwrap) ----------

integration_setup() {
    command -v bwrap >/dev/null || skip "bwrap not installed"
    # The HOME overlay uses lowerdir=$HOME, and overlayfs forbids an
    # upperdir/workdir inside a lowerdir. The state root is created under
    # XDG_RUNTIME_DIR, so it must live outside $HOME (and /tmp is world-
    # writable on CI, which the script rejects). /run/user/<uid> is the
    # standard location: owned, 0700, on tmpfs.
    local rt
    rt="/run/user/$(id -u)"
    [[ -d "$rt" && -O "$rt" ]] || skip "no suitable runtime dir outside \$HOME: $rt"
    # Probe that a $HOME overlay can actually be mounted here: some
    # environments (e.g. a $HOME that is itself an overlayfs mount) make the
    # kernel refuse nested overlays with EINVAL, which would break every
    # integration test at the first bwrap call.
    local probe_u probe_w
    probe_u="$(mktemp -d /tmp/ss-probe-u.XXXXXX)"
    probe_w="$(mktemp -d /tmp/ss-probe-w.XXXXXX)"
    if ! bwrap --unshare-all --ro-bind / / --proc /proc --dev /dev \
        --overlay-src "$HOME" --overlay "$probe_u" "$probe_w" "$HOME" \
        true 2>/dev/null; then
        rm -rf -- "$probe_u" "$probe_w"
        skip "HOME overlay unavailable in this environment (nested overlayfs?)"
    fi
    rm -rf -- "$probe_u" "$probe_w"
    export XDG_RUNTIME_DIR="$rt/simple-sandbox-bats-$$"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    export SIMPLE_SANDBOX_CONFIG="$scratch/config.json"
    extra_cleanup+=("$XDG_RUNTIME_DIR")
}

run_sandbox() {
    run env SIMPLE_SANDBOX_CONFIG="$scratch/config.json" simple-sandbox "$@"
}

@test "cwd is writable, home overlay hides real edits" {
    integration_setup
    echo before > "$HOME/.simple-sandbox-bats-marker"
    extra_cleanup+=("$HOME/.simple-sandbox-bats-marker")
    mkdir -p "$scratch/project"
    cd "$scratch/project"
    # shellcheck disable=SC2016  # $HOME must expand inside the sandbox, not here
    run_sandbox bash -c 'echo after > "$HOME/.simple-sandbox-bats-marker"; touch ./project-file'
    [ "$status" -eq 0 ]
    [ -f "$scratch/project/project-file" ]
    [ "$(cat "$HOME/.simple-sandbox-bats-marker")" = "before" ]
}

@test "hide policy blocks read of a path" {
    integration_setup
    mkdir -p "$scratch/secret-dir"
    echo secret > "$scratch/secret-dir/file"
    printf '{"paths": {"%s": "hide"}}\n' "$scratch/secret-dir" > "$scratch/config.json"
    run_sandbox cat "$scratch/secret-dir/file"
    [ "$status" -ne 0 ]
}

@test "readonly policy blocks writes" {
    integration_setup
    mkdir -p "$scratch/ro"
    echo before > "$scratch/ro/file.txt"
    printf '{"paths": {"%s": "readonly"}}\n' "$scratch/ro" > "$scratch/config.json"
    run_sandbox bash -c "echo after >> '$scratch/ro/file.txt'"
    [ "$status" -ne 0 ]
    [ "$(cat "$scratch/ro/file.txt")" = "before" ]
}

@test "expose policy binds the real dir read-write" {
    integration_setup
    mkdir -p "$scratch/expose"
    echo before > "$scratch/expose/file.txt"
    printf '{"paths": {"%s": "expose"}}\n' "$scratch/expose" > "$scratch/config.json"
    run_sandbox bash -c "echo after > '$scratch/expose/file.txt'"
    [ "$status" -eq 0 ]
    [ "$(cat "$scratch/expose/file.txt")" = "after" ]
}

@test "overlay policy gives a writable view without leaking" {
    integration_setup
    mkdir -p "$scratch/overlay"
    echo before > "$scratch/overlay/file.txt"
    printf '{"paths": {"%s": "overlay"}}\n' "$scratch/overlay" > "$scratch/config.json"
    run_sandbox bash -c "echo after > '$scratch/overlay/file.txt'; touch '$scratch/overlay/new.txt'"
    [ "$status" -eq 0 ]
    [ "$(cat "$scratch/overlay/file.txt")" = "before" ]
    [ ! -e "$scratch/overlay/new.txt" ]
}
