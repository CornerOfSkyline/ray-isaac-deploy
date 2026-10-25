#!/bin/bash
# stop-visualization.sh - Gracefully stop visualization stack
# Full 5-field identity verification from saved identity.json before any signal.
# Never uses pgrep -f for termination.
set -euo pipefail

STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
PID_DIR="${STATE_DIR}/pids"
SCRIPT_VERSION="1.1.2"

mkdir -p "${PID_DIR}"
log()  { echo "[$(date +%H:%M:%S)] $*"; }
warn() { log "WARN: $*" >&2; }

pid_file()      { echo "${PID_DIR}/$1.pid"; }
identity_file() { echo "${PID_DIR}/$1.identity.json"; }
read_pid()      { cat "$(pid_file "$1")" 2>/dev/null || echo ""; }

read_identity() {
    local f
    f="$(identity_file "$1")"
    [[ -f "${f}" ]] && cat "${f}" || echo "{}"
}

build_identity() {
    local pid="$1"
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

# Compare saved identity.json with current /proc state (all 5 fields)
identity_verified() {
    local name="$1" pid="$2"
    local saved current
    saved=$(read_identity "${name}")
    current=$(build_identity "${pid}")

    # If no saved identity, cannot verify
    if [[ "${saved}" == "{}" ]] || [[ -z "${saved}" ]]; then
        warn "  ${name}: no saved identity.json - refusing to kill"
        return 1
    fi

    python3 -c "
import json, sys
s = json.loads(sys.argv[1])
c = json.loads(sys.argv[2])
for field in ('pid','uid','start_time','exe','cmdline'):
    sv = str(s.get(field,''))
    cv = str(c.get(field,''))
    if sv != cv:
        print(f'MISMATCH {field}: saved={sv[:80]} current={cv[:80]}', file=sys.stderr)
        sys.exit(1)
sys.exit(0)
" "${saved}" "${current}" 2>/dev/null
}

# --- Safe process termination with full identity verification ---
stop_service() {
    local name="$1"
    local pid
    pid=$(read_pid "${name}")

    if [[ -z "${pid}" ]]; then
        log "  ${name}: not tracked (no PID file)"
        return 0
    fi

    if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
        warn "  ${name}: invalid PID '${pid}' in file - cleaning up"
        rm -f "$(pid_file "${name}")"
        return 0
    fi

    if ! kill -0 "${pid}" 2>/dev/null; then
        log "  ${name}: PID ${pid} already stopped"
        rm -f "$(pid_file "${name}")" "$(identity_file "${name}")"
        return 0
    fi

    # ---- Identity verification before SIGTERM ----
    local current
    current=$(build_identity "${pid}")
    local c_uid c_exe c_start c_cmd
    c_uid=$(echo "${current}"   | python3 -c "import json,sys;print(json.load(sys.stdin).get('uid',''))" 2>/dev/null||echo "")
    c_exe=$(echo "${current}"   | python3 -c "import json,sys;print(json.load(sys.stdin).get('exe',''))" 2>/dev/null||echo "")
    c_start=$(echo "${current}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('start_time',''))" 2>/dev/null||echo "")
    c_cmd=$(echo "${current}"   | python3 -c "import json,sys;print(json.load(sys.stdin).get('cmdline',''))" 2>/dev/null||echo "")

    log "  ${name}: PID=${pid} UID=${c_uid} START=${c_start}"
    log "    EXE=${c_exe}"
    log "    CMD=${c_cmd}"

    if ! identity_verified "${name}" "${pid}"; then
        warn "  ${name}: identity mismatch - REFUSING to kill"
        return 1
    fi
    log "  ${name}: identity verified against saved record"

    # ---- SIGTERM ----
    kill -TERM "${pid}" 2>/dev/null || true

    local stopped=false
    for i in $(seq 1 15); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            log "  ${name}: stopped gracefully after ${i}s"
            rm -f "$(pid_file "${name}")" "$(identity_file "${name}")"
            stopped=true
            break
        fi
        sleep 1
    done

    if ${stopped}; then return 0; fi

    # ---- SIGKILL: re-verify identity first ----
    warn "  ${name}: did not stop gracefully, re-checking identity before SIGKILL"
    if ! identity_verified "${name}" "${pid}"; then
        warn "  ${name}: identity changed during shutdown - REFUSING SIGKILL"
        return 1
    fi
    log "  ${name}: identity re-verified, sending SIGKILL"
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1
    rm -f "$(pid_file "${name}")" "$(identity_file "${name}")"
    return 0
}

# ============================================================
# Stop in reverse dependency order
# ============================================================
log "=== Stopping Visualization Stack v${SCRIPT_VERSION} ==="

stop_service "webrtc-client"
sleep 1
stop_service "isaac-sim"
sleep 2
stop_service "novnc"
sleep 1
stop_service "xvnc"

# Clean X11 locks ONLY if our managed xvnc is stopped AND no Xvnc remains
MANAGED_STOPPED=true
xvnc_pid=$(read_pid "xvnc")
if [[ -n "${xvnc_pid}" ]] && kill -0 "${xvnc_pid}" 2>/dev/null; then
    MANAGED_STOPPED=false
fi
if ${MANAGED_STOPPED} && ! pgrep -x Xvnc >/dev/null 2>&1; then
    log "  No Xvnc processes - cleaning X11 lock files"
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
elif ! ${MANAGED_STOPPED}; then
    warn "  Managed Xvnc still running (PID ${xvnc_pid}) - leaving X11 locks"
else
    warn "  Unmanaged Xvnc detected - leaving X11 locks untouched"
fi

# ============================================================
# Final audit (read-only)
# ============================================================
log "=== Final audit ==="
found_any=false
for proc_pat in "isaacsim-webrtc" "kit/kit" "websockify" "Xvnc"; do
    remaining_pids=$(pgrep -x "${proc_pat}" 2>/dev/null || true)
    for rpid in ${remaining_pids}; do
        [[ "${rpid}" =~ ^[0-9]+$ ]] || continue
        r_exe=$(readlink -f "/proc/${rpid}/exe" 2>/dev/null || echo "?")
        r_cmd=$(tr '\0' ' ' < "/proc/${rpid}/cmdline" 2>/dev/null | cut -c1-150 || echo "?")
        warn "  REMAINING ${proc_pat} PID=${rpid} exe=${r_exe} cmd=${r_cmd}"
        found_any=true
    done
done
${found_any} || log "  All clear - no remaining visualization processes"

log "=== Stopped ==="