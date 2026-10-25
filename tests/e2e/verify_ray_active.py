#!/usr/bin/env python3
"""verify_ray_active.py - Active Ray cluster verification with GPU tasks.
GCS address and worker IP passed as arguments.
Ray 2.40.0 compatible. Uses ray.get_runtime_context().get_node_id() for verification.
"""
import ray
import sys
import os
import subprocess
import socket
import time

if len(sys.argv) < 3:
    print("Usage: verify_ray_active.py <head_ip> <gcs_port> <worker_ip>", file=sys.stderr)
    sys.exit(1)

head_ip = sys.argv[1]
gcs_port = int(sys.argv[2])
worker_ip = sys.argv[3]
address = f"{head_ip}:{gcs_port}"

failed = False
def ok(msg): print(f"  [PASS] {msg}")
def fail(msg):
    global failed
    print(f"  [FAIL] {msg}")
    failed = True

try:
    ray.init(address=address, ignore_reinit_error=True, logging_level="ERROR")

    # 1. Node discovery
    alive = [n for n in ray.nodes() if n.get("Alive")]
    ok(f"Nodes alive: {len(alive)}")

    worker_node = next((n for n in alive if n.get("NodeManagerAddress") == worker_ip), None)
    if not worker_node:
        fail(f"Worker at {worker_ip} not found in {[n['NodeManagerAddress'] for n in alive]}")
        sys.exit(1)

    worker_nid = worker_node["NodeID"]
    ok(f"Worker NodeID: {worker_nid[:16]}...")
    head_node = next((n for n in alive if n.get("NodeManagerAddress") == head_ip), None)
    if head_node:
        ok(f"Head NodeID: {head_node['NodeID'][:16]}...")

    # 2. GPU task with NodeID verification
    @ray.remote(num_gpus=0.01, resources={"worker_4090": 0.01})
    def gpu_node_task():
        ctx = ray.get_runtime_context()
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,name,uuid", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=10
        )
        return {
            "node_id": ctx.get_node_id().hex(),
            "gpus": r.stdout.strip(),
            "cuda_visible": os.environ.get("CUDA_VISIBLE_DEVICES", "not_set"),
            "hostname": socket.gethostname(),
        }

    result = ray.get(gpu_node_task.remote(), timeout=30)
    task_nid = result["node_id"]
    if task_nid == worker_nid:
        ok(f"GPU task NodeID verified: {task_nid[:16]} matches Worker")
    else:
        fail(f"NodeID mismatch: task={task_nid[:16]} worker={worker_nid[:16]}")

    gpu_lines = [l for l in result["gpus"].split('\n') if l.strip()]
    ok(f"GPUs visible: {len(gpu_lines)} device(s)")
    for line in gpu_lines[:4]:
        ok(f"  GPU: {line}")
    ok(f"CUDA_VISIBLE_DEVICES: {result['cuda_visible']}")

    # 3. Object transfer A800 -> 4090
    @ray.remote(num_cpus=0.01)
    def producer(size_mb=5):
        return b"x" * (size_mb * 1024 * 1024)

    @ray.remote(num_gpus=0.01, resources={"worker_4090": 0.01})
    def consumer(data_ref):
        data = data_ref  # Ray auto-resolves ObjectRef arguments
        ctx = ray.get_runtime_context()
        return {"size": len(data), "node_id": ctx.get_node_id().hex()}

    ref = producer.remote(5)
    cons_result = ray.get(consumer.remote(ref), timeout=60)
    if cons_result["size"] == 5 * 1024 * 1024:
        ok(f"A800->4090 transfer: {cons_result['size']} bytes")
    else:
        fail(f"Transfer size mismatch: {cons_result['size']}")
    if cons_result["node_id"] == worker_nid:
        ok(f"Consumer confirmed on Worker ({cons_result['node_id'][:16]})")
    else:
        fail(f"Consumer NodeID mismatch: {cons_result['node_id'][:16]}")

    # 4. Object transfer 4090 -> A800
    @ray.remote(num_gpus=0.01, resources={"worker_4090": 0.01})
    def worker_producer(size_mb=3):
        ctx = ray.get_runtime_context()
        data = b"y" * (size_mb * 1024 * 1024)
        return {"data": data, "node_id": ctx.get_node_id().hex()}

    @ray.remote(num_cpus=0.01)
    def head_consumer(wrapped):
        recv_data = wrapped["data"]
        return {"size": len(recv_data), "producer_nid": wrapped["node_id"]}

    wref = worker_producer.remote(3)
    hresult = ray.get(head_consumer.remote(wref), timeout=60)
    if hresult["size"] == 3 * 1024 * 1024:
        ok(f"4090->A800 transfer: {hresult['size']} bytes")
    else:
        fail(f"Transfer size mismatch: {hresult['size']}")
    if hresult["producer_nid"] == worker_nid:
        ok(f"Producer confirmed on Worker ({hresult['producer_nid'][:16]})")
    else:
        fail(f"Producer NodeID mismatch: {hresult['producer_nid'][:16]}")

    # 5. Cross-node Actor
    @ray.remote(num_gpus=0.01, resources={"worker_4090": 0.01})
    class WorkerActor:
        def ping(self, msg):
            ctx = ray.get_runtime_context()
            return {"msg": msg, "nid": ctx.get_node_id().hex()}

    actor = WorkerActor.remote()
    aresult = ray.get(actor.ping.remote("hello"), timeout=30)
    actor_nid = aresult.get("nid", "")
    if actor_nid[:16] == worker_nid[:16]:
        ok(f"Actor NodeID verified: {actor_nid[:16]}")
    else:
        fail(f"Actor NodeID mismatch: {actor_nid[:16]} vs {worker_nid[:16]}")

    ray.shutdown()

except Exception as e:
    fail(f"Exception: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

if failed:
    print("\n  VERIFICATION FAILED")
    sys.exit(1)
else:
    print("\n  VERIFICATION PASSED")
    sys.exit(0)