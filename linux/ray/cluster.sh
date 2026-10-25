#!/bin/bash
# Ray cluster management scripts
# Adapter mode (default): wraps ~/workspace/ray_ws/ray_ssh_cluster/ (proven baseline)
# replaceable with standalone mode for fresh deployments
set -euo pipefail

LEGACY_DIR="${HOME}/workspace/ray_ws/ray_ssh_cluster"
ACTION="${1:-status}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { log "FATAL: $*" >&2; exit 1; }

# shellcheck source=/dev/null
load_env() {
    [[ -f "${LEGACY_DIR}/cluster_env.sh" ]] || die "Legacy cluster not found: ${LEGACY_DIR}"
    . "${LEGACY_DIR}/cluster_env.sh"
}

cmd_start_head() {
    load_env
    log "Starting Ray HEAD on A800 (127.0.0.2:${GCS_PORT})..."
    if head_ray_is_ours; then
        log "  Head already running (our GCS at 127.0.0.2:${GCS_PORT})"
        return 0
    fi
    [[ -x "${LEGACY_DIR}/start_head.sh" ]] || die "start_head.sh not found"
    bash "${LEGACY_DIR}/start_head.sh"
}

cmd_start_worker() {
    load_env
    log "Starting Ray WORKER on 4090 (127.0.0.3)..."
    if ssh_worker 'pid=$(pgrep -x raylet 2>/dev/null | head -1); [ -n "$pid" ] && tr "\0" " " < /proc/$pid/cmdline | grep -q "127.0.0.3"' 2>/dev/null; then
        log "  Worker already running at 127.0.0.3"
        return 0
    fi
    [[ -x "${LEGACY_DIR}/start_worker.sh" ]] || die "start_worker.sh not found"
    bash "${LEGACY_DIR}/start_worker.sh"
}

cmd_stop_cluster() {
    load_env
    log "Stopping Ray cluster (worker first, then head)..."
    [[ -x "${LEGACY_DIR}/stop_cluster.sh" ]] || die "stop_cluster.sh not found"
    bash "${LEGACY_DIR}/stop_cluster.sh"
}

cmd_status() {
    load_env
    echo "=== Ray Cluster Status ==="
    echo "Head: ${HEAD_RAY_IP} (A800 via ${HEAD_SSH_HOST}:${HEAD_SSH_PORT})"
    echo "Worker: ${WORKER_RAY_IP} (4090 via ${WORKER_SSH_HOST}:${WORKER_SSH_PORT})"
    echo ""

    # GCS
    local gcs_pid
    gcs_pid=$(pgrep -x gcs_server 2>/dev/null | head -1)
    if [[ -n "${gcs_pid}" ]]; then
        echo "  GCS: RUNNING (PID ${gcs_pid})"
    else
        echo "  GCS: STOPPED"
    fi

    # raylet on head
    local head_raylet
    head_raylet=$(pgrep -x raylet 2>/dev/null | grep -v "$(ssh_worker 'echo $PPID' 2>/dev/null)" | head -1 || echo "")
    if [[ -n "${head_raylet}" ]]; then
        echo "  Head raylet: RUNNING (PID ${head_raylet})"
    else
        echo "  Head raylet: STOPPED"
    fi

    # Worker raylet
    if ssh_worker 'pgrep -x raylet >/dev/null 2>&1' 2>/dev/null; then
        echo "  Worker raylet: RUNNING"
    else
        echo "  Worker raylet: STOPPED"
    fi

    # Tunnels
    echo ""
    [[ -x "${LEGACY_DIR}/head_tunnel.sh" ]] && "${LEGACY_DIR}/head_tunnel.sh" status 2>/dev/null | head -5 || true
    ssh_worker "bash '${LEGACY_DIR}/worker_tunnel.sh' status 2>/dev/null | head -3" 2>/dev/null || true

    # Python cluster query
    echo ""
    python3 - "${GCS_PORT}" "${HEAD_RAY_IP}" 2>/dev/null << 'PYEOF' || echo "  Cluster query: FAILED"
import ray, sys
ray.init(address=f"{sys.argv[2]}:{sys.argv[1]}", ignore_reinit_error=True, logging_level="ERROR")
alive = [n for n in ray.nodes() if n.get("Alive")]
print(f"  Nodes alive: {len(alive)}")
print(f"  Resources: {ray.cluster_resources()}")
for n in alive:
    print(f"    {n['NodeName']}: GPU={n.get('Resources',{}).get('GPU',0)}")
ray.shutdown()
PYEOF
}

cmd_recover_worker() {
    load_env
    log "Recovering Ray Worker (4090)..."
    # Stop worker side
    if ssh_worker 'pid=$(pgrep -x raylet 2>/dev/null | head -1); [ -n "$pid" ]' 2>/dev/null; then
        ssh_worker 'if [ -x "$HOME/.local/bin/ray" ]; then "$HOME/.local/bin/ray" stop; fi' 2>/dev/null || true
        sleep 5
    fi
    # Stop worker tunnels
    ssh_worker "bash '${LEGACY_DIR}/worker_tunnel.sh' stop 2>/dev/null" 2>/dev/null || true
    sleep 2
    # Restart worker tunnels
    ssh_worker "bash '${LEGACY_DIR}/worker_tunnel.sh' start" 2>/dev/null || true
    # Restart worker Ray
    [[ -x "${LEGACY_DIR}/start_worker.sh" ]] && bash "${LEGACY_DIR}/start_worker.sh"
}

case "${ACTION}" in
    start-head)     cmd_start_head ;;
    start-worker)   cmd_start_worker ;;
    start-tunnels)  bash "$(dirname "$0")/start-tunnels.sh" start ;;
    stop-head)      load_env; ray stop 2>/dev/null || true ;;
    stop-worker)    load_env; ssh_worker 'if [ -x "$HOME/.local/bin/ray" ]; then "$HOME/.local/bin/ray" stop; fi' 2>/dev/null || true ;;
    stop-tunnels)   bash "$(dirname "$0")/start-tunnels.sh" stop ;;
    stop-cluster)   cmd_stop_cluster ;;
    status)         cmd_status ;;
    recover-worker) cmd_recover_worker ;;
    *)
        echo "Usage: $0 {start-head|start-worker|start-tunnels|stop-head|stop-worker|stop-tunnels|stop-cluster|status|recover-worker}" >&2
        exit 2
        ;;
esac