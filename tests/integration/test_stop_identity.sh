#!/bin/bash
# test_stop_identity.sh - Isolated identity verification tests for stop-visualization.sh
# Tests normal stop, identity mismatch, missing identity, PID reuse, cleanup
# Uses correct path: ~/.local/state/ray-isaac-deploy/pids/ (matching stop script internals)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use uploaded stop script path; fall back to repo path for local testing
if [[ -f "/tmp/stop-visualization.sh" ]]; then
    STOP_SCRIPT="/tmp/stop-visualization.sh"
else
    STOP_SCRIPT="${SCRIPT_DIR}/../../linux/visualization/stop-visualization.sh"
fi
TMPDIR=$(mktemp -d)

passed=0; failed=0
pass() { echo "  PASS: $*"; passed=$((passed+1)); }
fail() { echo "  FAIL: $*"; failed=$((failed+1)); }

build_identity() {
    local pid="$1"
    [[ -d "/proc/${pid}" ]] || { echo '{}'; return; }
    python3 << EOF
import json, os
pid = ${pid}
try:
    with open(f'/proc/{pid}/status') as f:
        uid_line = [l for l in f if l.startswith('Uid:')][0]
    uid = int(uid_line.split()[1])
    with open(f'/proc/{pid}/stat') as f:
        start_time = int(f.read().split()[21])
    exe = os.readlink(f'/proc/{pid}/exe')
    with open(f'/proc/{pid}/cmdline', 'rb') as f:
        raw = f.read().decode().replace(chr(0), ' ').strip()[:500]
    print(json.dumps({'pid':pid, 'uid':uid, 'start_time':start_time, 'exe':exe, 'cmdline':raw}))
except Exception:
    print('{}')
EOF
}

# Stop script uses: STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
#                    PID_DIR="${STATE_DIR}/pids"
pd_for() { echo "${1}/.local/state/ray-isaac-deploy/pids"; }
setup_pid()  { local pd; pd=$(pd_for "$1"); mkdir -p "${pd}"; echo "$3" > "${pd}/$2.pid"; }
setup_id()   { local pd; pd=$(pd_for "$1"); mkdir -p "${pd}"; build_identity "$3" > "${pd}/$2.identity.json"; }
is_cleaned() { local pd; pd=$(pd_for "$1"); [[ ! -f "${pd}/$2.pid" ]]; }
run_stop()   { HOME="$1" bash "${STOP_SCRIPT}" 2>&1; }

# ============================================================
# Test 1: Normal stop — valid identity, process killed
# ============================================================
echo "=== Test 1: Normal Stop (valid identity) ==="
T1=$(mktemp -d)
sleep 86400 & M1=$!
setup_pid "${T1}" xvnc "${M1}"
setup_id  "${T1}" xvnc "${M1}"
run_stop "${T1}" || true
if kill -0 "${M1}" 2>/dev/null; then
    fail "Process still alive"; kill -9 "${M1}" 2>/dev/null || true
else
    pass "Process stopped"
fi
rm -rf "${T1}"

# ============================================================
# Test 2: Identity mismatch — refuse to kill
# ============================================================
echo "=== Test 2: Identity Mismatch ==="
T2=$(mktemp -d)
sleep 86400 & M2=$!
setup_pid "${T2}" xvnc "${M2}"
pd=$(pd_for "${T2}"); mkdir -p "${pd}"
echo '{"pid":99999,"uid":0,"start_time":0,"exe":"/fake","cmdline":"f"}' > "${pd}/xvnc.identity.json"
run_stop "${T2}" || true
if kill -0 "${M2}" 2>/dev/null; then
    pass "NOT killed (mismatch)"
else
    fail "Killed despite mismatch"
fi
kill -9 "${M2}" 2>/dev/null || true
rm -rf "${T2}"

# ============================================================
# Test 3: Missing identity — refuse to kill
# ============================================================
echo "=== Test 3: Missing Identity ==="
T3=$(mktemp -d)
sleep 86400 & M3=$!
setup_pid "${T3}" xvnc "${M3}"
# No identity.json
run_stop "${T3}" || true
if kill -0 "${M3}" 2>/dev/null; then
    pass "NOT killed (no identity)"
else
    fail "Killed without identity"
fi
kill -9 "${M3}" 2>/dev/null || true
rm -rf "${T3}"

# ============================================================
# Test 4: PID reuse — refuse to kill
# ============================================================
echo "=== Test 4: PID Reuse ==="
T4=$(mktemp -d)
sleep 86400 & M4_OLD=$!
setup_pid "${T4}" xvnc "${M4_OLD}"
setup_id  "${T4}" xvnc "${M4_OLD}"
kill -9 "${M4_OLD}" 2>/dev/null || true; wait "${M4_OLD}" 2>/dev/null || true
sleep 86400 & M4_NEW=$!
setup_pid "${T4}" xvnc "${M4_NEW}"
run_stop "${T4}" || true
if kill -0 "${M4_NEW}" 2>/dev/null; then
    pass "NOT killed (PID reuse)"
else
    fail "Killed despite PID reuse"
fi
kill -9 "${M4_NEW}" 2>/dev/null || true
rm -rf "${T4}"

# ============================================================
# Test 5: Already stopped — cleanup
# ============================================================
echo "=== Test 5: Already Stopped (cleanup) ==="
T5=$(mktemp -d)
sleep 86400 & M5=$!
setup_pid "${T5}" xvnc "${M5}"
setup_id  "${T5}" xvnc "${M5}"
kill -9 "${M5}" 2>/dev/null || true; wait "${M5}" 2>/dev/null || true
run_stop "${T5}" || true
if is_cleaned "${T5}" xvnc; then
    pass "PID file cleaned up"
else
    fail "PID file not cleaned"
fi
rm -rf "${T5}"

# ============================================================
# Test 6: SIGTERM timeout → SIGKILL with re-verification
# ============================================================
echo "=== Test 6: SIGTERM Ignored → SIGKILL ==="
T6=$(mktemp -d)
# Start process that ignores SIGTERM
bash -c 'trap "" TERM; sleep 86400' &
M6=$!
setup_pid "${T6}" xvnc "${M6}"
setup_id  "${T6}" xvnc "${M6}"

# Run stop — should timeout on SIGTERM after 15s, re-verify, then SIGKILL
run_stop "${T6}" || true

if kill -0 "${M6}" 2>/dev/null; then
    fail "Process still alive after SIGKILL"
    kill -9 "${M6}" 2>/dev/null || true
else
    pass "SIGKILL succeeded after SIGTERM ignored"
fi
if is_cleaned "${T6}" xvnc; then
    pass "Identity cleaned after successful SIGKILL"
else
    fail "Identity not cleaned after SIGKILL"
fi
rm -rf "${T6}"

# ============================================================
echo ""
echo "=== Results: ${passed} passed, ${failed} failed ==="
[[ ${failed} -eq 0 ]] && exit 0 || exit 1