#!/bin/bash
# start-visualization.sh - Start Isaac Sim visualization with PID-based process tracking
# M1-03: PID file management, identity verification, no pgrep -f kills
set -euo pipefail

STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
LOG_DIR="${STATE_DIR}/logs"
PID_DIR="${STATE_DIR}/pids"
SCRIPT_VERSION="1.1"

mkdir -p "${LOG_DIR}" "${PID_DIR}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "FATAL: $*" >&2; exit 1; }

# PID file operations (atomic)
pid_file() { echo "${PID_DIR}/$1.pid"; }
write_pid() { echo "$1" > "$(pid_file "$2")"; }
read_pid() { cat "$(pid_file "$1")" 2>/dev/null || echo ""; }

# Process identity verification
verify_process() {
    local name="$1" expected_pid="$2" expected_exe="$3"
    local pid=$(read_pid "${name}")
    if [ -z "${pid}" ]; then return 1; fi
    if [ "${pid}" != "${expected_pid}" ]; then return 1; fi
    if [ -n "${expected_exe}" ]; then
        local actual_exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "")
        if [ "${actual_exe}" != "${expected_exe}" ] && [[ "${actual_exe}" != *"${expected_exe}"* ]]; then
            return 1
        fi
    fi
    kill -0 "${pid}" 2>/dev/null || return 1
    return 0
}

is_running() {
    local name="$1"
    local pid=$(read_pid "${name}")
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null
}

# ============================================================
# 0. Pre-flight check
# ============================================================
log "=== Visualization Startup v${SCRIPT_VERSION} ==="
log "State dir: ${STATE_DIR}"

# Report existing instances
for svc in xvnc novnc isaac-sim webrtc-client; do
    if is_running "${svc}"; then
        local pid=$(read_pid "${svc}")
        log "  ${svc}: RUNNING (PID ${pid}, managed by us)"
    else
        log "  ${svc}: STOPPED"
    fi
done

# Detect unmanaged instances (report only, don't touch)
for proc in "Xvnc.*:1" "websockify.*6006" "kit/kit" "isaacsim-webrtc"; do
    unmanaged=$(pgrep -f "${proc}" 2>/dev/null || true)
    if [ -n "${unmanaged}" ]; then
        for upid in ${unmanaged}; do
            local managed=false
            for svc in xvnc novnc isaac-sim webrtc-client; do
                [ "$(read_pid "${svc}")" = "${upid}" ] && managed=true
            done
            if ! ${managed}; then
                local cmdline=$(tr '\0' ' ' < "/proc/${upid}/cmdline" 2>/dev/null | cut -c1-120)
                log "  WARNING: Unmanaged ${proc} found (PID ${upid}): ${cmdline}"
            fi
        fi
    fi
done

# ============================================================
# 1. Xvnc
# ============================================================
if is_running "xvnc"; then
    log "[1/5] Xvnc already running (PID $(read_pid xvnc))"
else
    log "[1/5] Starting Xvnc :1..."
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
    export LD_LIBRARY_PATH="/home/zjf/tigervnc/usr/lib:${LD_LIBRARY_PATH:-}"

    nohup /home/zjf/tigervnc/usr/bin/Xvnc :1 \
        -geometry 1920x1080 -depth 24 \
        -SecurityTypes None -AlwaysShared -localhost=1 -ac \
        > "${LOG_DIR}/xvnc.log" 2>&1 &
    XVNC_PID=$!
    write_pid "${XVNC_PID}" "xvnc"
    sleep 3

    if verify_process "xvnc" "${XVNC_PID}" "/home/zjf/tigervnc/usr/bin/Xvnc"; then
        ss -tlnp | grep -q ':5901 ' && log "  Xvnc OK (PID ${XVNC_PID}, port 5901)" || log "  WARNING: Xvnc running but port 5901 not detected"
    else
        die "Xvnc failed to start"
    fi
fi

# ============================================================
# 2. noVNC (websockify)
# ============================================================
if is_running "novnc"; then
    log "[2/5] noVNC already running (PID $(read_pid novnc))"
else
    # Clean up duplicate websockify if not managed by us
    WS_COUNT=$(pgrep -c websockify 2>/dev/null || echo 0)
    if [ "${WS_COUNT}" -gt 1 ]; then
        log "  Found ${WS_COUNT} websockify instances, keeping only managed ones..."
        for wspid in $(pgrep websockify 2>/dev/null); do
            if [ "${wspid}" != "$(read_pid novnc)" ]; then
                managed_cmdline=$(tr '\0' ' ' < "/proc/$(read_pid novnc)/cmdline" 2>/dev/null || echo "")
                this_cmdline=$(tr '\0' ' ' < "/proc/${wspid}/cmdline" 2>/dev/null || echo "")
                if [ "${this_cmdline}" != "${managed_cmdline}" ]; then
                    log "    Stopping unmanaged websockify PID ${wspid}"
                    kill -TERM "${wspid}" 2>/dev/null || true
                fi
            fi
        done
        sleep 2
        pgrep websockify | grep -v "$(read_pid novnc)" | xargs -r kill -9 2>/dev/null || true
    fi

    log "[2/5] Starting noVNC..."
    nohup /home/zjf/.local/bin/websockify --web=/home/zjf/noVNC-1.5.0 \
        6006 127.0.0.1:5901 > "${LOG_DIR}/novnc.log" 2>&1 &
    NOVNC_PID=$!
    write_pid "${NOVNC_PID}" "novnc"
    sleep 2

    if verify_process "novnc" "${NOVNC_PID}" "python3"; then
        ss -tlnp | grep -q ':6006 ' && log "  noVNC OK (PID ${NOVNC_PID}, port 6006)" || log "  WARNING: noVNC running but port 6006 not detected"
    else
        die "noVNC failed to start"
    fi
fi

# ============================================================
# 3. Isaac Sim
# ============================================================
if is_running "isaac-sim"; then
    log "[3/5] Isaac Sim already running (PID $(read_pid isaac-sim))"
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
    LOADED=false
    for i in $(seq 1 60); do
        sleep 2
        if grep -qi "app loaded\|Full Streaming App is loaded" "${LOG_DIR}/isaac-stream.log" 2>/dev/null; then
            log "  Isaac Sim loaded (${i}x2s)"
            LOADED=true
            break
        fi
    done
    if ! ${LOADED}; then
        log "  WARNING: Isaac Sim started but app loaded indicator not found (may still be initializing)"
    fi
fi

# ============================================================
# 4. WebRTC Client
# ============================================================
if is_running "webrtc-client"; then
    log "[4/5] WebRTC Client already running (PID $(read_pid webrtc-client))"
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

    # Wait for CDP to be ready
    sleep 8
    CDP_READY=false
    for i in $(seq 1 10); do
        if curl -s --connect-timeout 2 "http://127.0.0.1:9222/json" >/dev/null 2>&1; then
            CDP_READY=true
            break
        fi
        sleep 2
    done

    if verify_process "webrtc-client" "${CLIENT_PID}" "isaacsim-webrtc-streaming-client"; then
        if ${CDP_READY}; then
            log "  WebRTC Client OK (PID ${CLIENT_PID}, CDP :9222 ready)"
        else
            log "  WARNING: Client process running but CDP not ready"
        fi
    else
        die "WebRTC Client failed to start"
    fi
fi

# ============================================================
# 5. CDP Auto-connect
# ============================================================
log "[5/5] Auto-connecting WebRTC Client to Isaac Sim..."
if [ -f /home/zjf/auto_connect_webrtc.py ]; then
    python3 /home/zjf/auto_connect_webrtc.py 192.168.0.12 49100 47998 1920 1080 2>&1 || \
        log "  CDP connect returned non-zero (may need manual connect in browser)"
else
    log "  auto_connect_webrtc.py not found - connect manually in VNC desktop"
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