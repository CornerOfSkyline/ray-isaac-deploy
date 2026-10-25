#!/bin/bash
# verify-cluster.sh - Active Ray cluster verification
# Calls standalone tests/e2e/verify_ray_active.py
# Requires: Ray cluster running, legacy env for IP discovery
set -euo pipefail

CLUSTER_DIR="${CLUSTER_DIR:-$HOME/workspace/ray_ws/ray_ssh_cluster}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="${SCRIPT_DIR}/../../tests/e2e/verify_ray_active.py"

LOG() { echo "[$(date +%H:%M:%S)] $*"; }
exit_code=0

# 1. SSH + GCS quick check
LOG "=== Ray Active Verification ==="
if [ -f "${CLUSTER_DIR}/cluster_env.sh" ]; then
    . "${CLUSTER_DIR}/cluster_env.sh"
    ssh_worker "echo OK" 2>/dev/null | grep -q OK && LOG "Worker SSH OK" || { LOG "FAIL: Worker SSH"; exit 1; }
    GCS_PID=$(ssh_head "pgrep -x gcs_server 2>/dev/null | head -1" 2>/dev/null || echo "")
    [ -n "${GCS_PID}" ] && LOG "GCS OK (PID ${GCS_PID})" || { LOG "FAIL: GCS not running"; exit 1; }
    HEAD_IP="${HEAD_RAY_IP}"
    GCS_PORT="${GCS_PORT}"
    WORKER_IP="${WORKER_RAY_IP}"
else
    # Standalone: require explicit config
    HEAD_IP="${RAY_HEAD_IP:-127.0.0.2}"
    GCS_PORT="${RAY_GCS_PORT:-6379}"
    WORKER_IP="${RAY_WORKER_IP:-127.0.0.3}"
    LOG "No legacy env; using HEAD=${HEAD_IP}:${GCS_PORT} WORKER=${WORKER_IP}"
fi

# 2. Run standalone Python verification
if [ -f "${PY_SCRIPT}" ]; then
    LOG "Running: python3 ${PY_SCRIPT} ${HEAD_IP} ${GCS_PORT} ${WORKER_IP}"
    python3 "${PY_SCRIPT}" "${HEAD_IP}" "${GCS_PORT}" "${WORKER_IP}" || exit_code=$?
else
    LOG "FATAL: verify_ray_active.py not found at ${PY_SCRIPT}"
    exit_code=2
fi

LOG "=== Verification exit: ${exit_code} ==="
exit ${exit_code}