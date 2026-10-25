#!/bin/bash
# verify-cluster.sh - Ray cluster verification (active mode: GPU tasks)
# G4-02: NodeID verification via ray.get_runtime_context().get_node_id()
# Passive mode: use 'deploy.ps1 -Action status' instead
set -euo pipefail

CLUSTER_DIR="${CLUSTER_DIR:-$HOME/workspace/ray_ws/ray_ssh_cluster}"
LOG() { echo "[$(date +%H:%M:%S)] $*"; }
PASS() { echo "  [PASS] $*"; }
FAIL() { echo "  [FAIL] $*"; exit_code=1; }
exit_code=0

{ [ -f "${CLUSTER_DIR}/cluster_env.sh" ]; } || { FAIL "cluster_env.sh not found"; exit 1; }
. "${CLUSTER_DIR}/cluster_env.sh"

LOG "=== Ray Cluster Verification (Active) ==="

# 1. SSH + GCS
ssh_worker "echo OK" 2>/dev/null | grep -q OK && PASS "Worker SSH" || FAIL "Worker SSH"
GCS_PID=$(ssh_head "pgrep -x gcs_server 2>/dev/null | head -1" 2>/dev/null || echo "")
[ -n "${GCS_PID}" ] && PASS "GCS (PID ${GCS_PID})" || FAIL "GCS not running"

# 2. Full GPU NodeID verification
LOG "--- GPU Task with NodeID ---"
python3 - "${GCS_PORT}" "${HEAD_RAY_IP}" "${WORKER_RAY_IP}" << 'PYEOF'
import ray, sys, os
gcs_port=int(sys.argv[1]); head_ip=sys.argv[2]; worker_ip=sys.argv[3]
failed=False
def ok(m): print(f"  [PASS] {m}")
def fail(m): global failed; print(f"  [FAIL] {m}"); failed=True

ray.init(address=f"{head_ip}:{gcs_port}",ignore_reinit_error=True,logging_level="ERROR")
alive=[n for n in ray.nodes() if n.get("Alive")]
ok(f"Nodes: {len(alive)} alive")

worker_node = next((n for n in alive if n.get("NodeManagerAddress")==worker_ip), None)
if not worker_node: fail("Worker not found"); sys.exit(1)
worker_nid = worker_node["NodeID"]
ok(f"Worker NodeID: {worker_nid[:12]}...")

@ray.remote(num_gpus=0.01, resources={"worker_4090":0.01})
def gpu_node_task():
    import subprocess, socket
    ctx = ray.get_runtime_context()
    nid = ctx.get_node_id().hex()
    r = subprocess.run(["nvidia-smi","--query-gpu=index,name,uuid","--format=csv,noheader"],
                       capture_output=True,text=True,timeout=10)
    return {"node_id":nid,"gpus":r.stdout.strip(),"cuda_visible":os.environ.get("CUDA_VISIBLE_DEVICES","not_set")}

result = ray.get(gpu_node_task.remote(), timeout=30)
if result["node_id"] == worker_nid:
    ok(f"NodeID verified: task runs on Worker")
else:
    fail(f"NodeID mismatch: task={result['node_id'][:12]} worker={worker_nid[:12]}")

for line in result["gpus"].split('\n')[:4]:
    ok(f"  GPU: {line}")
ok(f"CUDA_VISIBLE_DEVICES: {result['cuda_visible']}")

# Object transfer + Actor
@ray.remote def make_data(mb=5): return b"x"*(mb*1024*1024)
@ray.remote def check_data(ref): return len(ray.get(ref))
sz=ray.get(check_data.remote(make_data.remote(5)),timeout=30)
ok(f"Object transfer: {sz} bytes ({sz//1024//1024}MB)")

@ray.remote(num_gpus=0.01,resources={"worker_4090":0.01})
class WorkerActor:
    def ping(self,m):
        return {"msg":m,"nid":ray.get_runtime_context().get_node_id().hex()[:12]}

resp=ray.get(WorkerActor.remote().ping.remote("hello"),timeout=30)
resp_nid=resp.get("nid","")
if resp_nid[:8]==worker_nid[:8]: ok(f"Actor on Worker (NID:{resp_nid})")
else: fail(f"Actor NID mismatch: {resp_nid} vs {worker_nid[:12]}")
ray.shutdown()
if failed: sys.exit(1)
PYEOF

LOG "=== Verification: $([ $exit_code -eq 0 ] && echo ALL PASSED || echo FAILURES) ==="
exit $exit_code