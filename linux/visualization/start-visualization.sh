#!/bin/bash
# start-visualization.sh - Start Isaac Sim visualization with PID-based process tracking
# Gate-1: Fixed shell correctness, process identity, network listening, PID safety
set -euo pipefail

STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
LOG_DIR="${STATE_DIR}/logs"
PID_DIR="${STATE_DIR}/pids"
SCRIPT_VERSION="1.1.1"

mkdir -p "${LOG_DIR}" "${PID_DIR}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "FATAL: $*" >&2; exit 1; }
warn() { log "WARN: $*" >&2; }

# --- PID file operations (atomic) ---
pid_file() { echo "${PID_DIR}/$1.pid"; }
write_pid() {
    local tmpfile
    tmpfile="$(pid_file "$2").tmp.$$"
    echo "$1" > "${tmpfile}"
    mv "${tmpfile}" "$(pid_file "$2")"
}
read_pid() { cat "$(pid_file "$1")" 2>/dev/null || echo ""; }

# --- Process identity persistence (R3: PID reuse protection) ---
identity_file() { echo "${PID_DIR}/$1.identity.json"; }
save_identity() {
    local name="$1" pid="$2"
    local uid exe start_time cmdline
    uid=$(awk '/^Uid:/{print $2}' "/proc/${pid}/status" 2>/dev/null || echo "0")
    start_time=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null || echo "0")
    exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "")
    cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | cut -c1-300 || echo "")
    local tmpfile
    tmpfile="$(identity_file "${name}").tmp.$$"
    printf '{"pid":%s,"uid":%s,"start_time":%s,"exe":"%s","cmdline":"%s"}\n' \
        "${pid}" "${uid}" "${start_time}" "${exe}" "${cmdline}" > "${tmpfile}"
    mv "${tmpfile}" "$(identity_file "${name}")"
}
read_identity() {
    cat "$(identity_file "$1")" 2>/dev/null || echo "{}"
}

# --- Process identity verification ---
verify_process() {
    local name="$1" expected_pid="$2" expected_exe="$3"
    local pid actual_exe
    pid=$(read_pid "${name}")
    [[ -n "${pid}" ]] || return 1
    [[ "${pid}" == "${expected_pid}" ]] || return 1
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    kill -0 "${pid}" 2>/dev/null || return 1
    if [[ -n "${expected_exe}" ]]; then
        actual_exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "")
        [[ "${actual_exe}" == *"${expected_exe}"* ]] || return 1
    fi
    return 0
}

is_running() {
    local name="$1" pid
    pid=$(read_pid "${name}")
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

# --- Process fingerprint (for unmanaged detection) ---
fingerprint_process() {
    local upid="$1"
    local exe cmdline start_time uid
    exe=$(readlink -f "/proc/${upid}/exe" 2>/dev/null || echo "?")
    cmdline=$(tr '\0' ' ' < "/proc/${upid}/cmdline" 2>/dev/null | cut -c1-200 || echo "?")
    start_time=$(awk '{print $22}' "/proc/${upid}/stat" 2>/dev/null || echo "?")
    uid=$(awk '/^Uid:/{print $2}' "/proc/${upid}/status" 2>/dev/null || echo "?")
    echo "pid=${upid} uid=${uid} start=${start_time} exe=${exe} cmd=${cmdline}"
}

# --- X11 lock safety ---
clean_x11_locks() {
    # Only remove X11 lock if we have a managed Xvnc PID and it's not running
    local xvnc_pid
    xvnc_pid=$(read_pid "xvnc")
    if [[ -n "${xvnc_pid}" ]] && ! kill -0 "${xvnc_pid}" 2>/dev/null; then
        log "  Managed Xvnc (PID ${xvnc_pid}) is stopped, cleaning lock files"
        rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
    elif ! pgrep -x Xvnc >/dev/null 2>&1; then
        log "  No Xvnc processes running, cleaning lock files"
        rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
    else
        # Xvnc is running but not managed by us - don't touch locks
        warn "  Unmanaged Xvnc detected - leaving X11 locks untouched"
    fi
}

# --- Detect unmanaged instances (read-only, never kills) ---
audit_unmanaged() {
    local proc_pattern="$1" svc_name="$2"
    local managed_pid unmanaged_pids upid fingerprint

    managed_pid=$(read_pid "${svc_name}")
    unmanaged_pids=$(pgrep -f "${proc_pattern}" 2>/dev/null || true)

    for upid in ${unmanaged_pids}; do
        [[ "${upid}" == "${managed_pid}" ]] && continue
        [[ "${upid}" =~ ^[0-9]+$ ]] || continue
        fingerprint=$(fingerprint_process "${upid}")
        warn "  UNMANAGED ${svc_name} (${proc_pattern}): ${fingerprint}"
    done
}

# ============================================================
# 0. Pre-flight
# ============================================================
log "=== Visualization Startup v${SCRIPT_VERSION} ==="
log "State dir: ${STATE_DIR}"

# Report managed instances
for svc in xvnc novnc isaac-sim webrtc-client; do
    if is_running "${svc}"; then
        log "  ${svc}: RUNNING (managed PID $(read_pid ${svc}))"
    else
        log "  ${svc}: STOPPED"
    fi
done

# Audit unmanaged (read-only report)
audit_unmanaged "Xvnc.*:1" "xvnc"
audit_unmanaged "websockify.*6006" "novnc"
audit_unmanaged "kit/kit" "isaac-sim"
audit_unmanaged "isaacsim-webrtc" "webrtc-client"

# ============================================================
# 1. Xvnc
# ============================================================
if is_running "xvnc"; then
    log "[1/5] Xvnc already running (managed PID $(read_pid xvnc))"
    # Verify VNC port is bound to loopback only
    vnc_bind=$(ss -tlnp 2>/dev/null | grep ':5901 ' | awk '{print $4}' | head -1)
    if [[ "${vnc_bind}" != "127.0.0.1:5901" ]] && [[ "${vnc_bind}" != "[::1]:5901" ]]; then
        warn "  VNC binding: ${vnc_bind} (expected 127.0.0.1:5901)"
    fi
else
    log "[1/5] Starting Xvnc :1..."
    clean_x11_locks
    export LD_LIBRARY_PATH="/home/zjf/tigervnc/usr/lib:${LD_LIBRARY_PATH:-}"

    nohup /home/zjf/tigervnc/usr/bin/Xvnc :1 \
        -geometry 1920x1080 -depth 24 \
        -SecurityTypes None -AlwaysShared -localhost=1 -ac \
        > "${LOG_DIR}/xvnc.log" 2>&1 &
    XVNC_PID=$!
    write_pid "${XVNC_PID}" "xvnc"
    save_identity "xvnc" "${XVNC_PID}"
    sleep 3

    if verify_process "xvnc" "${XVNC_PID}" "Xvnc"; then
        vnc_bind=$(ss -tlnp 2>/dev/null | grep ':5901 ' | awk '{print $4}' | head -1)
        if [[ "${vnc_bind}" =~ ^127\.0\.0\.1:5901$ ]]; then
            log "  Xvnc OK (PID ${XVNC_PID}, bound to 127.0.0.1:5901)"
        else
            die "  Xvnc binding check failed: ${vnc_bind}"
        fi
    else
        die "Xvnc failed to start (PID ${XVNC_PID})"
    fi
fi

# ============================================================
# 2. noVNC (websockify on 127.0.0.1:6006 only)
# ============================================================
if is_running "novnc"; then
    log "[2/5] noVNC already running (managed PID $(read_pid novnc))"
    novnc_bind=$(ss -tlnp 2>/dev/null | grep ':6006 ' | awk '{print $4}' | head -1)
    if [[ "${novnc_bind}" != "127.0.0.1:6006" ]]; then
        warn "  noVNC binding: ${novnc_bind} (expected 127.0.0.1:6006) - restarting with correct bind"
        # Restart with correct binding
        old_novnc_pid
        old_novnc_pid=$(read_pid "novnc")
        kill -TERM "${old_novnc_pid}" 2>/dev/null || true
        sleep 2
        if kill -0 "${old_novnc_pid}" 2>/dev/null; then
            kill -9 "${old_novnc_pid}" 2>/dev/null || true
        fi
        rm -f "$(pid_file novnc)"
    fi
fi

if ! is_running "novnc"; then
    log "[2/5] Starting noVNC on 127.0.0.1:6006..."
    nohup /home/zjf/.local/bin/websockify --web=/home/zjf/noVNC-1.5.0 \
        127.0.0.1:6006 127.0.0.1:5901 > "${LOG_DIR}/novnc.log" 2>&1 &
    NOVNC_PID=$!
    write_pid "${NOVNC_PID}" "novnc"
    sleep 2

    if verify_process "novnc" "${NOVNC_PID}" ""; then
        novnc_bind=$(ss -tlnp 2>/dev/null | grep ':6006 ' | awk '{print $4}' | head -1)
        if [[ "${novnc_bind}" == "127.0.0.1:6006" ]]; then
            log "  noVNC OK (PID ${NOVNC_PID}, 127.0.0.1:6006)"
        else
            die "  noVNC bound to ${novnc_bind} instead of 127.0.0.1:6006"
        fi
    else
        die "noVNC failed to start"
    fi
fi

# ============================================================
# 3. Isaac Sim
# ============================================================
if is_running "isaac-sim"; then
    log "[3/5] Isaac Sim already running (managed PID $(read_pid isaac-sim))"
else
    log "[3/5] Starting Isaac Sim 6.2.0..."
    cd /home/zjf/isaacsim
    nohup ./isaac-sim.streaming.sh --allow-root \
        --/exts/omni.kit.livestream.app/primaryStream/signalPort=49100 \
        --/exts/omni.kit.livestream.app/primaryStream/streamPort=47998 \
        --/exts/omni.kit.livestream.app/primaryStream/publicIp=192.168.0.12 \
        > "${LOG_DIR}/isaac-stream.log" 2>&1 &
    ISAAC_PID=$!
    write_pid "${ISAAC_PID}" "isaac-sim"

    # Wait for app to fully load (not just port listening)
    loaded=false
    for i in $(seq 1 60); do
        sleep 2
        if grep -qi "app loaded\|Full Streaming App is loaded" "${LOG_DIR}/isaac-stream.log" 2>/dev/null; then
            log "  Isaac Sim loaded (${i}x2s)"
            loaded=true
            break
        fi
    done
    if ! ${loaded}; then
        warn "  Isaac Sim started but app loaded indicator not found"
    fi
fi

# ============================================================
# 4. WebRTC Client
# ============================================================
if is_running "webrtc-client"; then
    log "[4/5] WebRTC Client already running (managed PID $(read_pid webrtc-client))"
    # Verify CDP is loopback-only
    cdp_bind=$(ss -tlnp 2>/dev/null | grep ':9222 ' | awk '{print $4}' | head -1)
    if [[ -n "${cdp_bind}" ]] && [[ "${cdp_bind}" != "127.0.0.1:9222" ]]; then
        warn "  CDP binding: ${cdp_bind} (expected 127.0.0.1:9222)"
    fi
else
    log "[4/5] Starting WebRTC Streaming Client..."
    CLIENT_DIR="/home/zjf/isaacsim-webrtc-streaming-client/opt/Isaac Sim WebRTC Streaming Client"
    CLIENT_BIN="${CLIENT_DIR}/isaacsim-webrtc-streaming-client"

    cd "${CLIENT_DIR}"
    nohup env DISPLAY=:1 "${CLIENT_BIN}" \
        --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --ozone-platform=x11 --remote-debugging-port=9222 \
        > "${LOG_DIR}/webrtc-client.log" 2>&1 &
    CLIENT_PID=$!
    write_pid "${CLIENT_PID}" "webrtc-client"

    sleep 8
    cdp_ready=false
    for i in $(seq 1 10); do
        if curl -s --connect-timeout 2 "http://127.0.0.1:9222/json" >/dev/null 2>&1; then
            cdp_ready=true
            break
        fi
        sleep 2
    done

    if verify_process "webrtc-client" "${CLIENT_PID}" "isaacsim-webrtc-streaming-client"; then
        if ${cdp_ready}; then
            cdp_bind=$(ss -tlnp 2>/dev/null | grep ':9222 ' | awk '{print $4}' | head -1)
            log "  WebRTC Client OK (PID ${CLIENT_PID}, CDP ${cdp_bind})"
        else
            warn "  Client running but CDP not ready"
        fi
    else
        die "WebRTC Client failed to start"
    fi
fi

# ============================================================
# 5. CDP Auto-connect
# ============================================================
log "[5/5] Auto-connecting WebRTC Client to Isaac Sim..."
if [[ -f /home/zjf/auto_connect_webrtc.py ]]; then
    python3 /home/zjf/auto_connect_webrtc.py 192.168.0.12 49100 47998 1920 1080 2>&1 || \
        warn "  CDP connect returned non-zero (may need manual connect in browser)"
else
    warn "  auto_connect_webrtc.py not found - connect manually"
fi

# ============================================================
# Summary
# ============================================================
echo ""
log "=== Visualization Stack Status ==="
for svc in xvnc novnc isaac-sim webrtc-client; do
    if is_running "${svc}"; then
        echo "  ${svc}: RUNNING (PID $(read_pid ${svc}))"
    else
        echo "  ${svc}: STOPPED"
    fi
done

echo ""
echo "  noVNC URL:  http://127.0.0.1:6006/vnc.html"
echo "  Windows:    ssh -NT -p 46602 -L 127.0.0.1:16006:127.0.0.1:6006 zjf@180.97.68.228"
echo "  Browser:    http://127.0.0.1:16006/vnc.html?autoconnect=1&resize=remote"