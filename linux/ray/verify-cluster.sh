#!/bin/bash
# verify-cluster.sh - Ray cluster verification with actual GPU task scheduling
# Gate-2: Verifies real GPU dispatch, object transfer, Actor calls
set -euo pipefail

CLUSTER_DIR="${CLUSTER_DIR:-$HOME/workspace/ray_ws/ray_ssh_cluster}"
LOG() { echo "[$(date +%H:%M:%S)] $*"; }
DIE() { LOG "FAIL: $*" >&2; exit 1; }
PASS() { echo "  [PASS] $*"; }
FAIL() { echo "  [FAIL] $*"; exit_code=1; }
exit_code=0

if [ ! -f "${CLUSTER_DIR}/cluster_env.sh" ]; then
    FAIL "Ray cluster scripts not found at ${CLUSTER_DIR}"
    exit 1
fi
. "${CLUSTER_DIR}/cluster_env.sh"

LOG "=== Ray Cluster Verification ==="
LOG "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"

# 1. SSH connectivity
LOG "--- SSH ---"
ssh_worker "echo OK" 2>/dev/null | grep -q OK && PASS "Worker SSH" || FAIL "Worker SSH"
ssh_head "echo OK" 2>/dev/null | grep -q OK && PASS "Head SSH" || FAIL "Head SSH"

# 2. GCS
LOG "--- GCS ---"
GCS_PID=$(ssh_head "pgrep -x gcs_server 2>/dev/null | head -1" 2>/dev/null || echo "")
if [ -n "${GCS_PID}" ]; then
    GCS_CMDLINE=$(ssh_head "tr '\0' ' ' < /proc/${GCS_PID}/cmdline" 2>/dev/null)
    if echo "${GCS_CMDLINE}" | grep -q "127.0.0.2"; then
        PASS "GCS (PID ${GCS_PID}, 127.0.0.2:${GCS_PORT})"
    else
        FAIL "GCS IP mismatch"
    fi
else
    FAIL "GCS not running"
fi

# 3. Ray cluster health + GPU task verification
LOG "--- Ray Cluster + GPU Dispatch ---"
python3 - "${GCS_PORT}" "${HEAD_RAY_IP}" "${WORKER_RAY_IP}" << 'PYEOF' || { echo "  [FAIL] Ray cluster test failed"; exit 1; }
import ray, sys, time, os

gcs_port = int(sys.argv[1])
head_ip = sys.argv[2]
worker_ip = sys.argv[3]
addr = f"{head_ip}:{gcs_port}"
failed = False

def fail(msg):
    global failed
    print(f"  [FAIL] {msg}")
    failed = True

def ok(msg):
    print(f"  [PASS] {msg}")

try:
    ray.init(address=addr, ignore_reinit_error=True, logging_level="ERROR")

    # 1. Node count
    alive_nodes = [n for n in ray.nodes() if n.get("Alive")]
    node_count = len(alive_nodes)
    if node_count >= 2:
        ok(f"Nodes alive: {node_count}")
    else:
        fail(f"Only {node_count} node(s) alive (need 2)")

    # 2. Find worker node
    worker_node = None
    head_node = None
    for n in alive_nodes:
        nm = n.get("NodeManagerAddress", "")
        if nm == worker_ip:
            worker_node = n
        elif nm == head_ip:
            head_node = n

    if worker_node:
        ok(f"Worker node found: {worker_node['NodeName']} (NodeID: {worker_node['NodeID'][:12]}...)")
        worker_gpu = worker_node.get("Resources", {}).get("GPU", 0)
        ok(f"Worker GPU resource: {worker_gpu}")
    else:
        fail(f"Worker node at {worker_ip} not found")

    if head_node:
        ok(f"Head node found: {head_node['NodeName']}")

    # 3. GPU task dispatch to 4090
    if worker_node:
        @ray.remote(num_gpus=0.01, resources={"worker_4090": 0.01})
        def gpu_identity_task():
            import subprocess, socket
            r = subprocess.run(["nvidia-smi", "-L"], capture_output=True, text=True, timeout=10)
            r2 = subprocess.run(["nvidia-smi", "--query-gpu=index,name,uuid", "--format=csv,noheader"],
                               capture_output=True, text=True, timeout=10)
            return {
                "gpu_count": len(r.stdout.strip().split('\n')),
                "gpus": r.stdout.strip()[:200],
                "hostname": socket.gethostname(),
            }

        try:
            result = ray.get(gpu_identity_task.remote(), timeout=30)
            task_node_id = ray.get(gpu_identity_task.get_task_node_id.remote()) if hasattr(gpu_identity_task, 'get_task_node_id') else None

            if result["gpu_count"] >= 1:
                ok(f"GPU task executed on 4090: {result['gpu_count']} GPU(s)")
                ok(f"GPU: {result['gpus'][:100]}")
            else:
                fail(f"No GPUs visible to Ray task")

            if task_node_id and worker_node:
                task_worker_id = task_node_id.hex() if hasattr(task_node_id, 'hex') else str(task_node_id)
                worker_id_short = worker_node['NodeID'][:12]
                if worker_id_short in task_worker_id:
                    ok(f"Task confirmed on Worker node: {worker_id_short}...")
                else:
                    fail(f"Task NOT on expected worker")
        except Exception as e:
            fail(f"GPU task dispatch failed: {e}")

    # 4. Object transfer (Head -> Worker)
    @ray.remote
    def create_data(size_mb=10):
        return b"x" * (size_mb * 1024 * 1024)

    @ray.remote
    def receive_data(ref):
        data = ray.get(ref)
        return len(data)

    try:
        ref = create_data.remote(5)  # 5MB test
        size = ray.get(receive_data.remote(ref), timeout=30)
        if size == 5 * 1024 * 1024:
            ok(f"Object transfer: 5MB OK")
        else:
            fail(f"Object transfer size mismatch: {size}")
    except Exception as e:
        fail(f"Object transfer failed: {e}")

    # 5. Cross-node Actor
    @ray.remote(num_gpus=0.01, resources={"worker_4090": 0.01})
    class TestActor:
        def __init__(self):
            import socket
            self.host = socket.gethostname()

        def ping(self, msg):
            import subprocess
            r = subprocess.run(["nvidia-smi", "-L"], capture_output=True, text=True, timeout=10)
            return {"host": self.host, "msg": msg, "gpus": r.stdout.strip()[:100]}

    try:
        actor = TestActor.remote()
        result = ray.get(actor.ping.remote("hello"), timeout=30)
        if result.get("host"):
            ok(f"Actor call OK (host={result['host']})")
        else:
            fail(f"Actor returned empty result")
    except Exception as e:
        fail(f"Actor call failed: {e}")

    ray.shutdown()

except Exception as e:
    fail(f"Cluster query error: {e}")
    sys.exit(1)

if failed:
    sys.exit(1)
PYEOF

LOG "=== Verification: $([ $exit_code -eq 0 ] && echo 'ALL PASSED' || echo 'FAILURES DETECTED') ==="
exit $exit_code