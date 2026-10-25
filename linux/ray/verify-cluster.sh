#!/bin/bash
# verify-cluster.sh - Comprehensive Ray cluster health verification
# Sources the existing ray_ssh_cluster environment (golden baseline).
set -euo pipefail

CLUSTER_DIR="${CLUSTER_DIR:-$HOME/workspace/ray_ws/ray_ssh_cluster}"
if [ ! -f "${CLUSTER_DIR}/cluster_env.sh" ]; then
    echo "ERROR: Ray cluster scripts not found at ${CLUSTER_DIR}" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "${CLUSTER_DIR}/cluster_env.sh"

echo "=== Ray Cluster Verification ==="
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# 1. SSH connectivity
echo "--- SSH Connectivity ---"
if ssh_worker "echo OK" 2>/dev/null | grep -q OK; then
    echo "  [PASS] Worker SSH (${WORKER_SSH_HOST}:${WORKER_SSH_PORT})"
else
    echo "  [FAIL] Worker SSH unreachable"
fi
if ssh_head "echo OK" 2>/dev/null | grep -q OK; then
    echo "  [PASS] Head SSH (${HEAD_SSH_HOST}:${HEAD_SSH_PORT})"
else
    echo "  [FAIL] Head SSH unreachable"
fi

# 2. Tunnel status
echo ""
echo "--- SSH Tunnels ---"
TUNNEL_OK=true
if [ -x "${CLUSTER_DIR}/head_tunnel.sh" ]; then
    HEAD_TUNNEL_OUT=$("${CLUSTER_DIR}/head_tunnel.sh" status 2>&1) || TUNNEL_OK=false
    echo "${HEAD_TUNNEL_OUT}" | head -3
else
    echo "  [FAIL] head_tunnel.sh not found"
    TUNNEL_OK=false
fi
if [ -x "${CLUSTER_DIR}/worker_tunnel.sh" ]; then
    WORKER_TUNNEL_OUT=$(ssh_worker "bash '${CLUSTER_DIR}/worker_tunnel.sh' status" 2>/dev/null) || true
    echo "${WORKER_TUNNEL_OUT}" | head -3
fi

# 3. Ray processes
echo ""
echo "--- Ray Processes ---"

# Check head GCS
HEAD_GCS_PID=$(ssh_head "pgrep -x gcs_server 2>/dev/null | head -1" 2>/dev/null || echo "")
if [ -n "${HEAD_GCS_PID}" ]; then
    GCS_CMDLINE=$(ssh_head "tr '\0' ' ' < /proc/${HEAD_GCS_PID}/cmdline" 2>/dev/null)
    if echo "${GCS_CMDLINE}" | grep -q "127.0.0.2"; then
        echo "  [PASS] GCS server (PID ${HEAD_GCS_PID}, 127.0.0.2:${GCS_PORT})"
    else
        echo "  [WARN] GCS running but IP mismatch: ${GCS_CMDLINE}" | head -c120
    fi
else
    echo "  [FAIL] GCS server not running"
fi

# Check worker raylet
WORKER_RAYLET=$(ssh_worker "pgrep -x raylet 2>/dev/null | head -1" 2>/dev/null || echo "")
if [ -n "${WORKER_RAYLET}" ]; then
    RAYLET_CMDLINE=$(ssh_worker "tr '\0' ' ' < /proc/${WORKER_RAYLET}/cmdline 2>/dev/null" 2>/dev/null)
    if echo "${RAYLET_CMDLINE}" | grep -q "127.0.0.3"; then
        GPU=$(echo "${RAYLET_CMDLINE}" | grep -oP 'GPU,\K\d+' || echo "?")
        echo "  [PASS] Worker raylet (PID ${WORKER_RAYLET}, 127.0.0.3, GPU:${GPU})"
    else
        echo "  [WARN] raylet running but IP mismatch"
    fi
else
    echo "  [FAIL] Worker raylet not running"
fi

# 4. Ray cluster health (via Python)
echo ""
echo "--- Ray Cluster ---"
python3 - "${GCS_PORT}" "${HEAD_RAY_IP}" 2>/dev/null << 'PYEOF' || echo "  [FAIL] Ray cluster query failed"
import ray, sys
try:
    gcs_port = int(sys.argv[1])
    head_ip = sys.argv[2]
    addr = f"{head_ip}:{gcs_port}"
    ray.init(address=addr, ignore_reinit_error=True, logging_level="ERROR")

    alive_nodes = [n for n in ray.nodes() if n.get("Alive")]
    resources = ray.cluster_resources()

    print(f"  Nodes alive: {len(alive_nodes)}")
    print(f"  Total GPU: {resources.get('GPU', 0)}")
    print(f"  Total CPU: {resources.get('CPU', 0)}")

    for n in alive_nodes:
        name = n.get("NodeName", "?")
        res = n.get("Resources", {})
        gpu = res.get("GPU", 0)
        mem_gb = res.get("memory", 0) / (1024**3)
        custom = {k: v for k, v in res.items() if not k.startswith("node:")
                   and k not in ("CPU", "GPU", "memory", "object_store_memory")}
        print(f"    {name}: GPU={gpu}, Mem={mem_gb:.0f}GB {custom}")

    # Quick GPU task test
    @ray.remote(num_gpus=0.01)
    def gpu_test():
        import subprocess
        r = subprocess.run(["nvidia-smi", "-L"], capture_output=True, text=True)
        return r.stdout.strip().split('\n')[0][:80]

    try:
        result = ray.get(gpu_test.remote(), timeout=15)
        print(f"  GPU task test: {result}")
    except Exception as e:
        print(f"  GPU task test: FAILED - {e}")

    ray.shutdown()
except Exception as e:
    print(f"  Cluster query error: {e}")
PYEOF

echo ""
echo "=== Verification Complete ==="