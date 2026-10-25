#!/bin/bash
# start-tunnels.sh - Start Ray SSH tunnels via legacy adapter or standalone mode
# Adapter mode: Uses existing ~/workspace/ray_ws/ray_ssh_cluster/ (proven)
# Standalone mode: Generates tunnel commands from verified profile (new deployments)
set -euo pipefail

LEGACY_CLUSTER_DIR="${HOME}/workspace/ray_ws/ray_ssh_cluster"
MODE="adapter"  # or "standalone"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { log "FATAL: $*" >&2; exit 1; }
warn() { log "WARN: $*" >&2; }

# ============================================================
# Adapter mode: use proven legacy scripts
# ============================================================
run_adapter() {
    local action="${1:-start}"

    if [[ ! -d "${LEGACY_CLUSTER_DIR}" ]]; then
        die "Legacy cluster dir not found: ${LEGACY_CLUSTER_DIR}"
    fi
    if [[ ! -f "${LEGACY_CLUSTER_DIR}/cluster_env.sh" ]]; then
        die "cluster_env.sh not found in ${LEGACY_CLUSTER_DIR}"
    fi

    # shellcheck source=/dev/null
    . "${LEGACY_CLUSTER_DIR}/cluster_env.sh"

    case "${action}" in
        start)
            log "Starting head-side tunnels (A800 -> 4090 worker ports on 127.0.0.3)..."
            if [[ -x "${LEGACY_CLUSTER_DIR}/head_tunnel.sh" ]]; then
                bash "${LEGACY_CLUSTER_DIR}/head_tunnel.sh" start || die "head_tunnel.sh start failed"
            fi

            log "Starting worker-side tunnels (4090 -> A800 head ports on 127.0.0.2)..."
            if ssh_worker "test -x '${LEGACY_CLUSTER_DIR}/worker_tunnel.sh'" 2>/dev/null; then
                ssh_worker "bash '${LEGACY_CLUSTER_DIR}/worker_tunnel.sh' start" || warn "worker_tunnel.sh start failed (may be already running)"
            else
                # Tunnel script not on worker - start from head
                log "  worker_tunnel.sh not found on 4090, starting from A800 head..."
                local worker_tunnel="${LEGACY_CLUSTER_DIR}/worker_tunnel.sh"
                if [[ -f "${worker_tunnel}" ]]; then
                    # Execute tunnel that binds head ports on 127.0.0.2 from worker's perspective
                    # This is done by running ssh from head to worker with the tunnel script
                    ssh_worker "mkdir -p ${LEGACY_CLUSTER_DIR}" 2>/dev/null || true
                    scp -P "${WORKER_SSH_PORT}" "${worker_tunnel}" "${LEGACY_CLUSTER_DIR}/cluster_env.sh" \
                        "${LEGACY_CLUSTER_DIR}/tunnel_common.sh" \
                        "${WORKER_SSH_USER}@${WORKER_SSH_HOST}:${LEGACY_CLUSTER_DIR}/" 2>/dev/null || true
                    ssh_worker "bash '${LEGACY_CLUSTER_DIR}/worker_tunnel.sh' start" || warn "worker_tunnel.sh start failed"
                fi
            fi

            log "Tunnels started (adapter mode)"
            "${LEGACY_CLUSTER_DIR}/head_tunnel.sh" status 2>/dev/null || true
            ;;
        stop)
            log "Stopping all tunnels..."
            [[ -x "${LEGACY_CLUSTER_DIR}/head_tunnel.sh" ]] && bash "${LEGACY_CLUSTER_DIR}/head_tunnel.sh" stop || true
            ssh_worker "bash '${LEGACY_CLUSTER_DIR}/worker_tunnel.sh' stop 2>/dev/null" || true
            log "Tunnels stopped"
            ;;
        status)
            echo "=== SSH Tunnels (adapter mode) ==="
            [[ -x "${LEGACY_CLUSTER_DIR}/head_tunnel.sh" ]] && bash "${LEGACY_CLUSTER_DIR}/head_tunnel.sh" status || echo "  head_tunnel.sh not found"
            ssh_worker "bash '${LEGACY_CLUSTER_DIR}/worker_tunnel.sh' status 2>/dev/null" || echo "  worker_tunnel.sh query failed"
            ;;
    esac
}

# ============================================================
# Standalone mode: generate from profile (for new deployments)
# ============================================================
run_standalone() {
    local action="${1:-start}"
    warn "Standalone mode: tunnel generation from profile is under development"
    warn "Using adapter mode as fallback"
    run_adapter "${action}"
}

# ============================================================
# Main
# ============================================================
ACTION="${1:-start}"

case "${ACTION}" in
    start|stop|status)
        if [[ -d "${LEGACY_CLUSTER_DIR}" ]] && [[ "${MODE}" == "adapter" ]]; then
            run_adapter "${ACTION}"
        else
            run_standalone "${ACTION}"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|status}" >&2
        exit 2
        ;;
esac