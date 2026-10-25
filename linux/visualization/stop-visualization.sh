#!/bin/bash
# stop-visualization.sh - Gracefully stop Isaac Sim visualization stack
set -e

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "=== Stopping Visualization Stack ==="

# Stop in reverse dependency order
for comp in "isaacsim-webrtc" "kit/kit" "websockify" "Xvnc.*:1"; do
    pids=$(pgrep -f "${comp}" 2>/dev/null || true)
    if [ -n "${pids}" ]; then
        log "Stopping ${comp}..."
        echo "${pids}" | xargs -r kill -TERM 2>/dev/null || true
        sleep 2
        # Check if still alive
        remaining=$(pgrep -f "${comp}" 2>/dev/null || true)
        if [ -n "${remaining}" ]; then
            log "  Force killing ${comp}..."
            echo "${remaining}" | xargs -r kill -9 2>/dev/null || true
        fi
    else
        log "  ${comp}: not running"
    fi
done

# Clean up X11 lock files
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

log "=== Stopped ==="