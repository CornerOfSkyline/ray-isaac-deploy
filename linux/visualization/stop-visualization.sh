#!/bin/bash
# stop-visualization.sh - Gracefully stop visualization stack using PID files (Gate-1)
# Never uses pgrep -f for termination. PID identity verified before any kill.
set -euo pipefail

STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
PID_DIR="${STATE_DIR}/pids"
SCRIPT_VERSION="1.1.1"

mkdir -p "${PID_DIR}"
log() { echo "[$(date +%H:%M:%S)] $*"; }
warn() { log "WARN: $*" >&2; }

pid_file() { echo "${PID_DIR}/$1.pid"; }
read_pid() { cat "$(pid_file "$1")" 2>/dev/null || echo ""; }

# --- Safe process termination ---
stop_service() {
    local name="$1" proc_pattern="${2:-${name}}"
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
        rm -f "$(pid_file "${name}")"
        return 0
    fi

    # Identity verification
    local exe uid start_time cmdline
    exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "")
    uid=$(awk '/^Uid:/{print $2}' "/proc/${pid}/status" 2>/dev/null || echo "")
    start_time=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || echo "")
    cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | cut -c1-200 || echo "")

    log "  ${name}: PID=${pid} uid=${uid} start=${start_time}"
    log "    exe=${exe}"
    log "    cmd=${cmdline}"

    # Check command fingerprint matches expected
    if [[ "${name}" == "xvnc" ]] && [[ "${exe}" != *"Xvnc"* ]]; then
        warn "  ${name}: PID ${pid} at ${exe} doesn't look like Xvnc - refusing to kill"
        return 1
    fi
    if [[ "${name}" == "isaac-sim" ]] && [[ "${cmdline}" != *"isaacsim"* ]]; then
        warn "  ${name}: PID ${pid} cmdline doesn't match Isaac Sim - refusing to kill"
        return 1
    fi

    # Graceful shutdown
    kill -TERM "${pid}" 2>/dev/null || true

    for i in $(seq 1 15); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            log "  ${name}: stopped gracefully after ${i}s"
            rm -f "$(pid_file "${name}")"
            return 0
        fi
        sleep 1
    done

    # Force kill
    warn "  ${name}: did not stop gracefully, sending SIGKILL"
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1
    rm -f "$(pid_file "${name}")"
    return 0
}

# ============================================================
# Stop in reverse dependency order
# ============================================================
log "=== Stopping Visualization Stack v${SCRIPT_VERSION} ==="

stop_service "webrtc-client" "isaacsim-webrtc-streaming"
sleep 1
stop_service "isaac-sim" "kit/kit"
sleep 2
stop_service "novnc" "websockify"
sleep 1
stop_service "xvnc" "Xvnc"

# Clean X11 locks ONLY if no Xvnc processes remain
if ! pgrep -x Xvnc >/dev/null 2>&1; then
    log "  No Xvnc processes remain - cleaning X11 lock files"
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
else
    warn "  Xvnc processes still running - leaving X11 locks untouched"
fi

# ============================================================
# Final audit (read-only report of any remaining processes)
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
if ! ${found_any}; then
    log "  All clear - no remaining visualization processes"
fi

log "=== Stopped ==="