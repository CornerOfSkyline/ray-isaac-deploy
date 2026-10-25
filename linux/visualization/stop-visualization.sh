#!/bin/bash
# stop-visualization.sh - Gracefully stop visualization stack using PID files (M1-03)
set -euo pipefail

STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
PID_DIR="${STATE_DIR}/pids"
SCRIPT_VERSION="1.1"

mkdir -p "${PID_DIR}"
log() { echo "[$(date +%H:%M:%S)] $*"; }

pid_file() { echo "${PID_DIR}/$1.pid"; }
read_pid() { cat "$(pid_file "$1")" 2>/dev/null || echo ""; }

# ============================================================
# Stop a managed service by PID file
# ============================================================
stop_service() {
    local name="$1"
    local pid=$(read_pid "${name}")

    if [ -z "${pid}" ]; then
        log "  ${name}: not tracked (no PID file)"
        return 0
    fi

    if ! kill -0 "${pid}" 2>/dev/null; then
        log "  ${name}: PID ${pid} already stopped"
        rm -f "$(pid_file "${name}")"
        return 0
    fi

    # Verify this is our process
    local proc_name="${2:-${name}}"
    local exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "")
    local cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | cut -c1-150 || echo "")
    log "  ${name}: stopping PID ${pid} (${proc_name})"
    log "    cmdline: ${cmdline}"

    # Graceful shutdown
    kill -TERM "${pid}" 2>/dev/null || true

    # Wait up to 15s
    for i in $(seq 1 15); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            log "  ${name}: stopped gracefully after ${i}s"
            rm -f "$(pid_file "${name}")"
            return 0
        fi
        sleep 1
    done

    # Force kill
    log "  ${name}: did not stop gracefully, sending SIGKILL"
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1
    rm -f "$(pid_file "${name}")"
}

# ============================================================
# Stop in reverse dependency order
# ============================================================
log "=== Stopping Visualization Stack v${SCRIPT_VERSION} ==="

stop_service "webrtc-client" "isaacsim-webrtc-streaming-client"
sleep 1
stop_service "isaac-sim" "kit/kit"
sleep 2
stop_service "novnc" "websockify"
sleep 1
stop_service "xvnc" "Xvnc"

# Clean up X11 lock files
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

# Report any remaining unmanaged processes
log "=== Final check ==="
for proc in "isaacsim-webrtc" "kit/kit" "websockify" "Xvnc.*:1"; do
    remaining=$(pgrep -f "${proc}" 2>/dev/null || true)
    if [ -n "${remaining}" ]; then
        for rpid in ${remaining}; do
            local cmdline=$(tr '\0' ' ' < "/proc/${rpid}/cmdline" 2>/dev/null | cut -c1-120 || echo "?")
            log "  WARNING: Unmanaged ${proc} still running (PID ${rpid}): ${cmdline}"
        done
    fi
done

log "=== Stopped ==="