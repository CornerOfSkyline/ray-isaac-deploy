#!/bin/bash
# repair-novnc.sh - Fix noVNC binding to 127.0.0.1:6006 without touching other services
# Only affects websockify. Does NOT restart Isaac Sim, Xvnc, WebRTC Client, or Ray.
set -euo pipefail

STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
PID_DIR="${STATE_DIR}/pids"
LOG_DIR="${STATE_DIR}/logs"
mkdir -p "${LOG_DIR}" "${PID_DIR}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
warn() { log "WARN: $*" >&2; }

pid_file() { echo "${PID_DIR}/$1.pid"; }
read_pid() { cat "$(pid_file "$1")" 2>/dev/null || echo ""; }

# ============================================================
# 1. Audit current state (read-only)
# ============================================================
log "=== noVNC Repair Audit ==="

# Find all processes listening on port 6006
log "Processes on port 6006:"
ss -tlnp 2>/dev/null | grep ':6006 ' | while read -r line; do
    log "  ${line}"
done

# Check managed PID
MANAGED_PID=$(read_pid "novnc")
if [[ -n "${MANAGED_PID}" ]] && kill -0 "${MANAGED_PID}" 2>/dev/null; then
    M_UID=$(awk '/^Uid:/{print $2}' "/proc/${MANAGED_PID}/status" 2>/dev/null || echo "?")
    M_EXE=$(readlink -f "/proc/${MANAGED_PID}/exe" 2>/dev/null || echo "?")
    M_START=$(awk '{print $22}' "/proc/${MANAGED_PID}/stat" 2>/dev/null || echo "?")
    M_CMD=$(tr '\0' ' ' < "/proc/${MANAGED_PID}/cmdline" 2>/dev/null | cut -c1-200 || echo "?")
    log "Managed noVNC: PID=${MANAGED_PID} UID=${M_UID} START=${M_START}"
    log "  EXE=${M_EXE}"
    log "  CMD=${M_CMD}"
else
    log "No managed noVNC PID found"
fi

# Check all websockify processes
UNMANAGED=()
for wspid in $(pgrep -x websockify 2>/dev/null || true); do
    [[ "${wspid}" == "${MANAGED_PID}" ]] && continue
    W_UID=$(awk '/^Uid:/{print $2}' "/proc/${wspid}/status" 2>/dev/null || echo "?")
    W_EXE=$(readlink -f "/proc/${wspid}/exe" 2>/dev/null || echo "?")
    W_CMD=$(tr '\0' ' ' < "/proc/${wspid}/cmdline" 2>/dev/null | cut -c1-200 || echo "?")
    warn "Unmanaged websockify PID=${wspid} UID=${W_UID} EXE=${W_EXE}"
    warn "  CMD=${W_CMD}"
    UNMANAGED+=("${wspid}")
done

# Current binding
BIND=$(ss -tlnp 2>/dev/null | grep ':6006 ' | awk '{print $4}' | head -1)
log "Current bind: ${BIND}"
EXPECTED="127.0.0.1:6006"

if [[ "${BIND}" == "${EXPECTED}" ]]; then
    log "Binding is already correct (${EXPECTED}). No repair needed."
    exit 0
fi

# ============================================================
# 2. Impact assessment
# ============================================================
log ""
log "=== Impact Assessment ==="
log "Current binding: ${BIND}"
log "Expected binding: ${EXPECTED}"
log ""
log "Repair plan:"
log "  1. Stop managed noVNC websockify (PID ${MANAGED_PID:-NONE})"
log "  2. Stop any unmanaged websockify on port 6006"
log "  3. Start new websockify on 127.0.0.1:6006"
log "  4. Verify binding"
log ""
log "Services NOT affected:"
log "  - Isaac Sim (port 49100)"
log "  - Xvnc (DISPLAY=:1, port 5901)"
log "  - WebRTC Client (CDP 9222)"
log "  - Ray Worker/Head"
log "  - GPU training jobs"
log ""
log "Temporary impact:"
log "  - Windows VNC viewer will disconnect during restart (~5 seconds)"
log "  - Reconnect after repair completes"
log ""

# ============================================================
# 3. Execute repair
# ============================================================

# Stop managed instance
if [[ -n "${MANAGED_PID}" ]] && kill -0 "${MANAGED_PID}" 2>/dev/null; then
    # Verify identity before killing
    V_UID=$(awk '/^Uid:/{print $2}' "/proc/${MANAGED_PID}/status" 2>/dev/null || echo "")
    V_CMD=$(tr '\0' ' ' < "/proc/${MANAGED_PID}/cmdline" 2>/dev/null || echo "")

    if [[ "${V_CMD}" == *"websockify"* ]] || [[ "${V_CMD}" == *"6006"* ]]; then
        log "Stopping managed noVNC PID=${MANAGED_PID} (UID=${V_UID})..."
        kill -TERM "${MANAGED_PID}" 2>/dev/null || true
        for i in $(seq 1 10); do
            if ! kill -0 "${MANAGED_PID}" 2>/dev/null; then
                log "  Stopped after ${i}s"
                break
            fi
            sleep 1
        done
        if kill -0 "${MANAGED_PID}" 2>/dev/null; then
            warn "  Force killing..."
            kill -9 "${MANAGED_PID}" 2>/dev/null || true
        fi
    else
        warn "  PID ${MANAGED_PID} does not look like websockify - refusing to kill"
    fi
fi

# Clean up any remaining websockify on port 6006
sleep 1
REMAINING=$(ss -tlnp 2>/dev/null | grep ':6006 ' | grep -oP 'pid=\d+' | cut -d= -f2 || true)
for rpid in ${REMAINING}; do
    R_CMD=$(tr '\0' ' ' < "/proc/${rpid}/cmdline" 2>/dev/null || echo "")
    if [[ "${R_CMD}" == *"websockify"* ]]; then
        log "Stopping remaining websockify PID=${rpid}..."
        kill -TERM "${rpid}" 2>/dev/null || true
        sleep 2
        kill -9 "${rpid}" 2>/dev/null || true
    else
        warn "PID ${rpid} on port 6006 is NOT websockify - refusing to kill"
    fi
done

sleep 2

# ============================================================
# 4. Start new noVNC on 127.0.0.1:6006
# ============================================================
log "Starting noVNC on 127.0.0.1:6006..."
nohup /home/zjf/.local/bin/websockify --web=/home/zjf/noVNC-1.5.0 \
    127.0.0.1:6006 127.0.0.1:5901 > "${LOG_DIR}/novnc.log" 2>&1 &
NEW_PID=$!
echo "${NEW_PID}" > "$(pid_file novnc)"
sleep 2

# Verify
NEW_BIND=$(ss -tlnp 2>/dev/null | grep ':6006 ' | awk '{print $4}' | head -1)
if [[ "${NEW_BIND}" == "${EXPECTED}" ]]; then
    log "Repair SUCCESS: noVNC bound to ${EXPECTED} (PID ${NEW_PID})"
else
    warn "Repair WARNING: binding is ${NEW_BIND} (expected ${EXPECTED})"
fi

# ============================================================
# 5. Post-repair verification
# ============================================================
log ""
log "=== Post-Repair Status ==="
log "noVNC: $(ss -tlnp 2>/dev/null | grep ':6006 ' | awk '{print $4}' | head -1)"
log "VNC:   $(ss -tlnp 2>/dev/null | grep ':5901 ' | awk '{print $4}' | head -1)"
log "Isaac: $(ss -tlnp 2>/dev/null | grep ':49100 ' | awk '{print $4}' | head -1)"
log "CDP:   $(ss -tlnp 2>/dev/null | grep ':9222 ' | awk '{print $4}' | head -1)"

# Quick noVNC HTTP check
if curl -s --connect-timeout 3 http://127.0.0.1:6006/vnc.html >/dev/null 2>&1; then
    log "noVNC HTTP: accessible"
else
    warn "noVNC HTTP: check failed"
fi

log "=== Repair Complete ==="
log "Windows: reconnect browser at http://127.0.0.1:16006/vnc.html"