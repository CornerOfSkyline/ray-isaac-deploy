#!/bin/bash
# start-visualization.sh - Start Isaac Sim visualization stack on 4090
# Dependencies: Xvnc -> noVNC -> Isaac Sim -> WebRTC Client -> CDP auto-connect
set -e

STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
LOG_DIR="${STATE_DIR}/logs"
mkdir -p "${LOG_DIR}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# === 0. Check existing instances ===
log "=== Checking existing instances ==="
for comp in "Xvnc.*:1" "websockify.*6006" "kit/kit" "isaacsim-webrtc"; do
    count=$(pgrep -c -f "${comp}" 2>/dev/null || echo 0)
    log "  ${comp}: ${count}"
done

# === 1. Xvnc ===
if ! pgrep -f 'Xvnc.*:1' > /dev/null 2>&1; then
    log "[1/5] Starting Xvnc :1..."
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
    export LD_LIBRARY_PATH="/home/zjf/tigervnc/usr/lib:${LD_LIBRARY_PATH:-}"
    nohup /home/zjf/tigervnc/usr/bin/Xvnc :1 \
        -geometry 1920x1080 -depth 24 \
        -SecurityTypes None -AlwaysShared -localhost=1 -ac \
        > "${LOG_DIR}/xvnc.log" 2>&1 &
    sleep 3
    ss -tlnp | grep -q ':5901 ' && log "  Xvnc OK" || log "  Xvnc FAILED"
else
    log "[1/5] Xvnc already running"
fi

# === 2. noVNC ===
WS_COUNT=$(pgrep -c websockify 2>/dev/null || echo 0)
if [ "${WS_COUNT}" -gt 1 ]; then
    log "  Cleaning up duplicate websockify instances..."
    pgrep websockify | tail -n +2 | xargs -r kill 2>/dev/null || true
    sleep 1
fi
if ! pgrep -f 'websockify.*6006' > /dev/null 2>&1; then
    log "[2/5] Starting noVNC..."
    nohup /home/zjf/.local/bin/websockify --web=/home/zjf/noVNC-1.5.0 \
        6006 127.0.0.1:5901 > "${LOG_DIR}/novnc.log" 2>&1 &
    sleep 2
    ss -tlnp | grep -q ':6006 ' && log "  noVNC OK" || log "  noVNC FAILED"
else
    log "[2/5] noVNC already running"
fi

# === 3. Isaac Sim ===
if ! pgrep -f 'kit/kit' > /dev/null 2>&1; then
    log "[3/5] Starting Isaac Sim 6.2.0..."
    cd /home/zjf/isaacsim
    nohup ./isaac-sim.streaming.sh --allow-root \
        --/exts/omni.kit.livestream.app/primaryStream/signalPort=49100 \
        --/exts/omni.kit.livestream.app/primaryStream/streamPort=47998 \
        --/exts/omni.kit.livestream.app/primaryStream/publicIp=192.168.0.12 \
        > "${LOG_DIR}/isaac-stream.log" 2>&1 &

    # Wait for app to load
    for i in $(seq 1 60); do
        sleep 2
        if grep -qi "app loaded\|Full Streaming App is loaded" "${LOG_DIR}/isaac-stream.log" 2>/dev/null; then
            log "  Isaac Sim loaded (${i}x2s)"
            break
        fi
        if [ $i -eq 60 ]; then
            log "  WARNING: Isaac Sim may still be loading"
        fi
    done
else
    log "[3/5] Isaac Sim already running"
fi

# === 4. WebRTC Client ===
if ! pgrep -f isaacsim-webrtc > /dev/null 2>&1; then
    log "[4/5] Starting WebRTC Streaming Client..."
    CLIENT_DIR="/home/zjf/isaacsim-webrtc-streaming-client/opt/Isaac Sim WebRTC Streaming Client"
    cd "${CLIENT_DIR}"
    nohup env DISPLAY=:1 "${CLIENT_DIR}/isaacsim-webrtc-streaming-client" \
        --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --ozone-platform=x11 --remote-debugging-port=9222 \
        > "${LOG_DIR}/webrtc-client.log" 2>&1 &
    sleep 10
    pgrep -c isaacsim-webrtc >/dev/null && log "  Client OK" || log "  Client FAILED"
else
    log "[4/5] WebRTC Client already running"
fi

# === 5. CDP auto-connect ===
log "[5/5] Auto-connecting to Isaac Sim..."
python3 /home/zjf/auto_connect_webrtc.py 192.168.0.12 49100 47998 1920 1080 2>&1 || \
    log "  CDP connect failed (may need manual connect in browser)"

echo ""
log "=== Visualization Stack Status ==="
for comp in "Xvnc.*:1" "websockify.*6006" "kit/kit" "isaacsim-webrtc"; do
    count=$(pgrep -c -f "${comp}" 2>/dev/null || echo 0)
    echo "  ${comp}: ${count} process(es)"
done
echo ""
echo "  noVNC URL: http://127.0.0.1:6006/vnc.html"
echo "  Windows SSH: ssh -NT -p 46602 -L 127.0.0.1:16006:127.0.0.1:6006 zjf@180.97.68.228"
echo "  Browser: http://127.0.0.1:16006/vnc.html?autoconnect=1&resize=remote"