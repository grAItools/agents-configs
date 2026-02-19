#!/usr/bin/env bash
#
# bwrap-agent.sh — Bubblewrap sandbox for safely invoking coding agents
#
# Isolates a coding agent so it can work on a specific project directory
# with full access to system toolchains (Node.js, Python, C++, Rust, Git)
# while preventing access to secrets, credentials, and other sensitive
# data in your home directory.
#
# Usage:
#   ./bwrap-agent.sh [OPTIONS] --workdir /path/to/project -- agent-command [args...]
#   ./bwrap-agent.sh --workdir ~/projects/myapp -- claude --dangerously-skip-permissions
#   ./bwrap-agent.sh --no-net --workdir ./myproject -- aider
#   ./bwrap-agent.sh --workdir ./myproject --shell
#
# Options:
#   --workdir DIR         Project directory to mount read-write (required)
#   --no-net              Disable all network access
#   --allow-sys           Mount /sys read-only (needed by some build tools)
#   --extra-ro PATH       Additional path to bind read-only (repeatable)
#   --extra-rw PATH       Additional path to bind read-write (repeatable)
#   --keep-session        Don't create a new terminal session (less secure,
#                         but fixes rare TTY issues with some agents)
#   --shell               Drop into an interactive shell inside the sandbox
#   --verbose             Print the final bwrap command before executing
#   -h, --help            Show this help message
#
# ═══════════════════════════════════════════════════════════════════════
# SECURITY MODEL
# ═══════════════════════════════════════════════════════════════════════
#
# WHAT THE AGENT CAN DO:
#   - Read/write files in the project working directory
#   - Read/execute system toolchains: gcc, g++, make, cmake, rustc, cargo,
#     node, npm, python3, pip, git, and all of /usr/bin
#   - Use the network (unless --no-net is passed)
#   - Fork/exec processes (compilers, linters, test runners, etc.)
#   - Write to its own tmp and cache directories
#
# WHAT THE AGENT CANNOT DO:
#   - Read ~/.ssh, ~/.gnupg, ~/.aws, ~/.config/gh, ~/.kube, ~/.docker,
#     or any other credentials/secrets in your real home directory
#   - Read ~/.bash_history, ~/.zsh_history, browser profiles, keyrings
#   - See or signal processes outside the sandbox (PID namespace)
#   - Access host IPC (shared memory, semaphores, message queues)
#   - Write to system directories (/usr, /bin, /lib, /etc)
#   - Access raw devices beyond /dev/null, /dev/zero, /dev/urandom
#   - Inject keystrokes into the parent terminal (new session)
#   - Survive the parent process exiting (die-with-parent)
#   - Access or enumerate other users' files or project directories
#   - Access host cgroup hierarchy
#
# ═══════════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────

REAL_HOME="${HOME}"
REAL_USER="${USER:-$(id -un)}"
SANDBOX_NET="yes"
MOUNT_SYS="no"
NEW_SESSION="yes"
WORKDIR=""
SHELL_MODE="no"
VERBOSE="no"
AGENT_CMD=()
EXTRA_RO_BINDS=()
EXTRA_RW_BINDS=()

# ─── Usage ──────────────────────────────────────────────────────────────

usage() {
    # Print the header comment block as usage text
    sed -n '/^# Usage:/,/^# ═/{ /^# ═/d; s/^# \{0,1\}//; p; }' "$0"
    exit "${1:-0}"
}

# ─── Color helpers (only when stderr is a terminal) ─────────────────────

if [[ -t 2 ]]; then
    _red()    { printf '\033[1;31m%s\033[0m' "$*"; }
    _yellow() { printf '\033[1;33m%s\033[0m' "$*"; }
    _green()  { printf '\033[1;32m%s\033[0m' "$*"; }
    _dim()    { printf '\033[2m%s\033[0m' "$*"; }
else
    _red()    { printf '%s' "$*"; }
    _yellow() { printf '%s' "$*"; }
    _green()  { printf '%s' "$*"; }
    _dim()    { printf '%s' "$*"; }
fi

info()  { echo "[$(_green sandbox)] $*" >&2; }
warn()  { echo "[$(_yellow sandbox)] $*" >&2; }
die()   { echo "[$(_red sandbox)] $*" >&2; exit 1; }

# ─── Parse arguments ───────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-net)        SANDBOX_NET="no";  shift ;;
        --allow-sys)     MOUNT_SYS="yes";   shift ;;
        --keep-session)  NEW_SESSION="no";  shift ;;
        --verbose)       VERBOSE="yes";     shift ;;
        --shell)         SHELL_MODE="yes";  shift ;;
        --workdir)
            [[ -n "${2:-}" ]] || die "--workdir requires a path"
            WORKDIR="$2"; shift 2 ;;
        --extra-ro)
            [[ -n "${2:-}" ]] || die "--extra-ro requires a path"
            EXTRA_RO_BINDS+=("$(realpath "$2")"); shift 2 ;;
        --extra-rw)
            [[ -n "${2:-}" ]] || die "--extra-rw requires a path"
            EXTRA_RW_BINDS+=("$(realpath "$2")"); shift 2 ;;
        -h|--help) usage 0 ;;
        --)        shift; AGENT_CMD=("$@"); break ;;
        *)         die "Unknown option: $1 (use -h for help)" ;;
    esac
done

# ─── Validate ───────────────────────────────────────────────────────────

command -v bwrap >/dev/null 2>&1 || \
    die "bubblewrap (bwrap) is not installed. Install it with: sudo apt install bubblewrap"

[[ -n "$WORKDIR" ]] || die "--workdir is required"
WORKDIR="$(realpath "$WORKDIR")"
[[ -d "$WORKDIR" ]] || die "workdir '${WORKDIR}' does not exist or is not a directory"

if [[ "$SHELL_MODE" == "yes" ]]; then
    AGENT_CMD=("${SHELL:-/bin/bash}" "-l")
elif [[ ${#AGENT_CMD[@]} -eq 0 ]]; then
    die "No command specified. Use '-- <command>' or '--shell'"
fi

# ─── Create synthetic home directory ────────────────────────────────────

SANDBOX_HOME="$(mktemp -d "${TMPDIR:-/tmp}/agent-sandbox-home.XXXXXX")"
cleanup() { rm -rf "$SANDBOX_HOME" 2>/dev/null || true; }
trap cleanup EXIT

info "Synthetic home: ${SANDBOX_HOME}"

# Populate minimal directory structure expected by toolchains
mkdir -p "${SANDBOX_HOME}"/{.config,.cache,.local/bin,.local/share,.local/lib,.cargo}

# Copy SAFE, non-secret dotfiles from the real home.
# These contain preferences, not credentials.
SAFE_DOTFILES=(
    .gitconfig
    .gitignore_global
    .editorconfig
    .vimrc
    .bashrc
    .bash_profile
    .profile
    .inputrc
    .tmux.conf
)

for f in "${SAFE_DOTFILES[@]}"; do
    [[ -f "${REAL_HOME}/${f}" ]] && cp "${REAL_HOME}/${f}" "${SANDBOX_HOME}/${f}"
done

# Copy cargo config (registry mirrors, build settings — no auth tokens)
if [[ -f "${REAL_HOME}/.cargo/config.toml" ]]; then
    cp "${REAL_HOME}/.cargo/config.toml" "${SANDBOX_HOME}/.cargo/config.toml"
elif [[ -f "${REAL_HOME}/.cargo/config" ]]; then
    cp "${REAL_HOME}/.cargo/config" "${SANDBOX_HOME}/.cargo/config"
fi

# Copy npm/yarn config WITHOUT auth tokens
if [[ -f "${REAL_HOME}/.npmrc" ]]; then
    # Strip any lines containing auth tokens
    grep -v -iE '(authToken|_auth|_password|//.*:)' "${REAL_HOME}/.npmrc" \
        > "${SANDBOX_HOME}/.npmrc" 2>/dev/null || true
fi

# ─── Helper: bind a path as read-only, respecting symlinks ─────────────

# On merged-usr distros (Fedora, Arch, newer Ubuntu), /bin, /lib, /sbin
# are symlinks into /usr. We must replicate symlinks, not bind over them.
bind_ro_or_symlink() {
    local src="$1" dest="${2:-$1}"
    if [[ -L "$src" ]]; then
        BWRAP_ARGS+=(--symlink "$(readlink "$src")" "$dest")
    elif [[ -d "$src" ]]; then
        BWRAP_ARGS+=(--ro-bind "$src" "$dest")
    elif [[ -f "$src" ]]; then
        BWRAP_ARGS+=(--ro-bind "$src" "$dest")
    fi
}

# ─── Build bwrap argument list ──────────────────────────────────────────

BWRAP_ARGS=()

# ── 1. Namespace isolation ──────────────────────────────────────────────

BWRAP_ARGS+=(
    --unshare-pid          # Agent gets its own PID namespace; can't see/signal host processes
    --unshare-ipc          # Isolated SysV IPC and POSIX message queues
    --unshare-cgroup       # Can't inspect or manipulate host cgroup hierarchy
)

if [[ "$SANDBOX_NET" == "no" ]]; then
    BWRAP_ARGS+=(--unshare-net)
    warn "Network access DISABLED"
else
    info "Network access enabled (use --no-net to disable)"
fi

# ── 2. Root filesystem (empty tmpfs base layer) ─────────────────────────
#
# Start with an empty root. Everything the agent can see is explicitly
# mounted below. This is deny-by-default for the filesystem.

BWRAP_ARGS+=(--tmpfs /)

# ── 3. System directories (read-only) ──────────────────────────────────
#
# /usr contains compilers, interpreters, libraries, headers, and most
# system binaries on modern Linux. Mounted read-only.

BWRAP_ARGS+=(--ro-bind /usr /usr)

# /bin, /lib, /lib64, /sbin — real directories on older distros,
# symlinks into /usr on merged-usr distros. Handle both cases.
for d in /bin /lib /lib64 /sbin; do
    bind_ro_or_symlink "$d"
done

# /usr/local — locally compiled software, additional toolchains
[[ -d /usr/local ]] && BWRAP_ARGS+=(--ro-bind /usr/local /usr/local)

# /opt — some third-party tools install here
[[ -d /opt ]] && BWRAP_ARGS+=(--ro-bind /opt /opt)

# ── 4. /etc (selective — secrets excluded) ──────────────────────────────
#
# We do NOT mount all of /etc. Instead, we start with an empty tmpfs
# and bind only the specific files/dirs needed for system functionality.

BWRAP_ARGS+=(--tmpfs /etc)

# Files needed for basic system operation
ETC_ENTRIES=(
    # DNS and networking
    resolv.conf
    hosts
    host.conf
    nsswitch.conf
    protocols
    services
    gai.conf

    # Dynamic linker
    ld.so.cache
    ld.so.conf
    ld.so.conf.d

    # TLS certificates
    ssl
    ca-certificates
    pki

    # Debian/Ubuntu alternatives system (language toolchain selection)
    alternatives

    # Identity (needed for username lookups by ls, git, cargo, etc.)
    passwd
    group

    # Locale and timezone
    localtime
    timezone

    # MIME types (some tools query this)
    mime.types
    mailcap

    # System-wide shell and tool configuration
    gitconfig
    bash.bashrc
    profile
    profile.d
    environment
    inputrc
)

for entry in "${ETC_ENTRIES[@]}"; do
    [[ -e "/etc/${entry}" ]] && bind_ro_or_symlink "/etc/${entry}" "/etc/${entry}"
done

# ── 5. Device nodes (minimal safe set) ──────────────────────────────────
#
# bwrap --dev creates a minimal devtmpfs with only:
#   /dev/null, /dev/zero, /dev/full, /dev/random, /dev/urandom,
#   /dev/tty, /dev/fd, /dev/stdin, /dev/stdout, /dev/stderr
# No access to raw disks, USB, GPU, or other hardware.

BWRAP_ARGS+=(--dev /dev)

# ── 6. /proc (new instance for the PID namespace) ──────────────────────

BWRAP_ARGS+=(--proc /proc)

# ── 7. /sys (optional — disabled by default) ───────────────────────────
#
# /sys exposes kernel and hardware information. Most coding agents don't
# need it, but some build tools query /sys/devices/system/cpu for the
# CPU count (nproc usually works without it via sysconf).

if [[ "$MOUNT_SYS" == "yes" ]]; then
    [[ -d /sys ]] && BWRAP_ARGS+=(--ro-bind /sys /sys)
fi

# ── 8. Temporary directories ───────────────────────────────────────────

BWRAP_ARGS+=(
    --tmpfs /tmp
    --tmpfs /var
    --tmpfs /run
)

# XDG_RUNTIME_DIR — some tools expect this to exist
BWRAP_ARGS+=(--tmpfs "/run/user/$(id -u)")

# ── 9. Synthetic home directory ─────────────────────────────────────────
#
# Mount our prepared synthetic home in place of the real one.
# The agent sees $HOME but it contains only safe dotfiles and
# writable scratch dirs — no SSH keys, no cloud credentials, no
# browser profiles, no shell history.

BWRAP_ARGS+=(--bind "$SANDBOX_HOME" "$REAL_HOME")

# ── 10. Toolchains installed under $HOME (read-only) ───────────────────
#
# Rust, nvm, and pyenv install toolchain binaries under $HOME.
# We mount these read-only so the agent can USE the tools but not
# modify the installations. The agent's own writable ~/.cargo,
# ~/.cache etc. come from the synthetic home.

# Rust toolchain (rustup manages installations here)
if [[ -d "${REAL_HOME}/.rustup" ]]; then
    BWRAP_ARGS+=(--ro-bind "${REAL_HOME}/.rustup" "${REAL_HOME}/.rustup")
    info "Rust toolchain: mounted read-only from ~/.rustup"
fi

# Cargo binaries (rustc, cargo, rustfmt, clippy, etc.)
if [[ -d "${REAL_HOME}/.cargo/bin" ]]; then
    BWRAP_ARGS+=(--ro-bind "${REAL_HOME}/.cargo/bin" "${REAL_HOME}/.cargo/bin")
    info "Cargo binaries: mounted read-only from ~/.cargo/bin"
fi

# Node.js via nvm
if [[ -d "${REAL_HOME}/.nvm" ]]; then
    BWRAP_ARGS+=(--ro-bind "${REAL_HOME}/.nvm" "${REAL_HOME}/.nvm")
    info "nvm: mounted read-only from ~/.nvm"
fi

# Python via pyenv
if [[ -d "${REAL_HOME}/.pyenv" ]]; then
    BWRAP_ARGS+=(--ro-bind "${REAL_HOME}/.pyenv" "${REAL_HOME}/.pyenv")
    info "pyenv: mounted read-only from ~/.pyenv"
fi

# ── 11. Project working directory (read-write) ─────────────────────────
#
# This is the directory the agent is actually working on. It gets
# full read-write access. This mount comes AFTER the home mount
# so it overlays correctly if the workdir is inside $HOME.

BWRAP_ARGS+=(--bind "$WORKDIR" "$WORKDIR")

# ── 12. Extra user-specified bind mounts ────────────────────────────────

for p in "${EXTRA_RO_BINDS[@]}"; do
    [[ -e "$p" ]] && BWRAP_ARGS+=(--ro-bind "$p" "$p")
done

for p in "${EXTRA_RW_BINDS[@]}"; do
    [[ -e "$p" ]] && BWRAP_ARGS+=(--bind "$p" "$p")
done

# ── 13. Environment variables ──────────────────────────────────────────

BWRAP_ARGS+=(
    --setenv HOME "$REAL_HOME"
    --setenv USER "$REAL_USER"
    --setenv LOGNAME "$REAL_USER"
    --setenv TMPDIR /tmp
    --setenv TERM "${TERM:-xterm-256color}"
    --setenv LANG "${LANG:-en_US.UTF-8}"
    --setenv SHELL "${SHELL:-/bin/bash}"
    --setenv XDG_CONFIG_HOME "${REAL_HOME}/.config"
    --setenv XDG_CACHE_HOME "${REAL_HOME}/.cache"
    --setenv XDG_DATA_HOME "${REAL_HOME}/.local/share"
    --setenv XDG_RUNTIME_DIR "/run/user/$(id -u)"
)

# Build a PATH that includes all relevant toolchain locations
SANDBOX_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SANDBOX_PATH+=":${REAL_HOME}/.local/bin"
SANDBOX_PATH+=":${REAL_HOME}/.cargo/bin"
[[ -d "${REAL_HOME}/.nvm" ]] && \
    SANDBOX_PATH+=":${REAL_HOME}/.nvm/versions/node/$(ls -1 "${REAL_HOME}/.nvm/versions/node/" 2>/dev/null | sort -V | tail -1)/bin" 2>/dev/null || true
[[ -d "${REAL_HOME}/.pyenv/shims" ]] && \
    SANDBOX_PATH+=":${REAL_HOME}/.pyenv/shims:${REAL_HOME}/.pyenv/bin"
BWRAP_ARGS+=(--setenv PATH "$SANDBOX_PATH")

# Pass through Rust environment variables if set
[[ -n "${RUSTUP_HOME:-}" ]] && BWRAP_ARGS+=(--setenv RUSTUP_HOME "$RUSTUP_HOME")
[[ -n "${CARGO_HOME:-}" ]] && BWRAP_ARGS+=(--setenv CARGO_HOME "$CARGO_HOME")

# ── 14. Sandbox behavior flags ─────────────────────────────────────────

BWRAP_ARGS+=(
    --chdir "$WORKDIR"      # Start in the project directory
    --die-with-parent       # Tear down sandbox if the invoking process exits
)

# --new-session prevents TIOCSTI attacks (a sandboxed process injecting
# keystrokes into the parent terminal). Disable with --keep-session if
# the agent has TTY compatibility issues.
if [[ "$NEW_SESSION" == "yes" ]]; then
    BWRAP_ARGS+=(--new-session)
fi

# ── 15. Verbose output ─────────────────────────────────────────────────

if [[ "$VERBOSE" == "yes" ]]; then
    info "Working directory: ${WORKDIR}"
    info "Agent command: ${AGENT_CMD[*]}"
    info ""
    info "Full bwrap invocation:"
    # Pretty-print the command
    echo -n "  bwrap" >&2
    for arg in "${BWRAP_ARGS[@]}"; do
        if [[ "$arg" == --* ]]; then
            echo " \\" >&2
            echo -n "    $arg" >&2
        else
            echo -n " $arg" >&2
        fi
    done
    echo " \\" >&2
    echo "    -- ${AGENT_CMD[*]}" >&2
    echo "" >&2
fi

# ── 16. Launch ──────────────────────────────────────────────────────────

info "Launching agent in sandbox..."
exec bwrap "${BWRAP_ARGS[@]}" -- "${AGENT_CMD[@]}"
