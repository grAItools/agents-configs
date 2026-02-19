#!/usr/bin/env bash
#
# verify-sandbox.sh — Verify that the bubblewrap sandbox is working correctly
#
# Run this INSIDE the sandbox to confirm isolation:
#   ./bwrap-agent.sh --workdir /tmp/test-project --shell
#   # then run: bash /path/to/verify-sandbox.sh
#
# Or run it automatically:
#   ./bwrap-agent.sh --workdir /tmp/test-project -- bash verify-sandbox.sh
#
# Each test prints PASS (sandbox is working) or FAIL (sandbox is leaking).
#

set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
warn() { echo "  WARN: $1"; ((WARN++)); }

section() { echo ""; echo "=== $1 ==="; }

# ─── Sensitive files should be inaccessible ─────────────────────────────

section "Credential / secret file isolation"

SENSITIVE_PATHS=(
    "$HOME/.ssh/id_rsa"
    "$HOME/.ssh/id_ed25519"
    "$HOME/.ssh/config"
    "$HOME/.gnupg/private-keys-v1.d"
    "$HOME/.aws/credentials"
    "$HOME/.aws/config"
    "$HOME/.config/gh/hosts.yml"
    "$HOME/.kube/config"
    "$HOME/.docker/config.json"
    "$HOME/.netrc"
    "$HOME/.bash_history"
    "$HOME/.zsh_history"
    "$HOME/.local/share/keyrings"
    "$HOME/.password-store"
    "$HOME/.config/gcloud/credentials.db"
    "$HOME/.azure/accessTokens.json"
)

for p in "${SENSITIVE_PATHS[@]}"; do
    if [[ -e "$p" ]]; then
        fail "$p is accessible (should not exist in sandbox)"
    else
        pass "$p is not accessible"
    fi
done

# ─── System directories should be read-only ─────────────────────────────

section "System directory write protection"

for d in /usr/bin /usr/lib /bin /etc; do
    if touch "${d}/.sandbox-write-test" 2>/dev/null; then
        rm -f "${d}/.sandbox-write-test" 2>/dev/null
        fail "${d} is writable (should be read-only)"
    else
        pass "${d} is read-only"
    fi
done

# ─── Working directory should be writable ───────────────────────────────

section "Working directory access"

WORKDIR="$(pwd)"
TEST_FILE="${WORKDIR}/.sandbox-write-test-$$"

if touch "$TEST_FILE" 2>/dev/null; then
    rm -f "$TEST_FILE"
    pass "Working directory is writable"
else
    fail "Working directory is NOT writable (should be writable)"
fi

# ─── PID namespace isolation ────────────────────────────────────────────

section "PID namespace isolation"

# In a PID namespace, the sandbox's init process is PID 1 (the bwrap child).
# We should NOT see the host's full process list.
PROC_COUNT=$(ls /proc | grep -cE '^[0-9]+$')

if [[ "$PROC_COUNT" -lt 20 ]]; then
    pass "PID namespace active (only ${PROC_COUNT} processes visible)"
else
    warn "Seeing ${PROC_COUNT} processes — PID namespace may not be active"
fi

# Check that we can't see common host daemons
if ps aux 2>/dev/null | grep -q "systemd\|sshd\|cron\|NetworkManager" 2>/dev/null; then
    fail "Host system daemons are visible (PID isolation not working)"
else
    pass "Host system daemons are not visible"
fi

# ─── Toolchain availability ────────────────────────────────────────────

section "Toolchain availability"

EXPECTED_TOOLS=(git bash sh)
OPTIONAL_TOOLS=(gcc g++ make cmake python3 pip3 node npm rustc cargo)

for tool in "${EXPECTED_TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "${tool} is available ($(command -v "$tool"))"
    else
        fail "${tool} is NOT available (expected)"
    fi
done

for tool in "${OPTIONAL_TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        pass "${tool} is available ($(command -v "$tool"))"
    else
        warn "${tool} is not available (install on host if needed)"
    fi
done

# ─── /dev sanity ────────────────────────────────────────────────────────

section "Device node restrictions"

for dev in /dev/null /dev/zero /dev/urandom; do
    if [[ -e "$dev" ]]; then
        pass "${dev} exists"
    else
        fail "${dev} missing (required)"
    fi
done

# These should NOT exist in the sandbox
for dev in /dev/sda /dev/sdb /dev/nvme0n1 /dev/mem /dev/kmem; do
    if [[ -e "$dev" ]]; then
        fail "${dev} is accessible (should not be in sandbox)"
    else
        pass "${dev} is not accessible"
    fi
done

# ─── Tmp directory ──────────────────────────────────────────────────────

section "Temporary directory"

if [[ -d /tmp ]] && touch /tmp/.sandbox-test-$$ 2>/dev/null; then
    rm -f /tmp/.sandbox-test-$$
    pass "/tmp is writable"
else
    fail "/tmp is not writable"
fi

# Check that host /tmp contents are not visible
HOST_TMP_COUNT=$(ls -A /tmp 2>/dev/null | wc -l)
if [[ "$HOST_TMP_COUNT" -eq 0 ]]; then
    pass "/tmp is empty (isolated from host)"
else
    warn "/tmp has ${HOST_TMP_COUNT} entries (may be from sandbox setup)"
fi

# ─── Network (basic check) ─────────────────────────────────────────────

section "Network access"

if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    warn "Network is reachable (expected if --no-net was NOT used)"
elif curl -s --max-time 3 https://example.com >/dev/null 2>&1; then
    warn "HTTPS is reachable (expected if --no-net was NOT used)"
else
    pass "Network appears isolated (or no connectivity tools available)"
fi

# ─── Summary ────────────────────────────────────────────────────────────

section "Summary"
echo ""
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo "  Warnings: ${WARN}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo "  RESULT: Some isolation checks FAILED — review the output above."
    exit 1
else
    echo "  RESULT: All isolation checks passed."
    exit 0
fi
