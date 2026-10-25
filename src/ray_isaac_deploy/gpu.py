"""GPU resource management and diagnostics."""
import subprocess
import json


def get_gpu_info(ssh_target: str = None) -> dict:
    """Collect GPU information from nvidia-smi."""
    cmd = "nvidia-smi --query-gpu=index,name,uuid,memory.total,memory.used,memory.free,utilization.gpu,driver_version --format=csv,noheader"
    result = _run(cmd, ssh_target)

    gpus = []
    for line in result.strip().split('\n'):
        parts = [p.strip() for p in line.split(', ')]
        if len(parts) >= 8:
            gpus.append({
                "index": parts[0],
                "name": parts[1],
                "uuid": parts[2],
                "memory_total_mb": parts[3],
                "memory_used_mb": parts[4],
                "memory_free_mb": parts[5],
                "utilization_pct": parts[6],
                "driver_version": parts[7],
            })

    return {"count": len(gpus), "gpus": gpus}


def get_gpu_compute_processes(ssh_target: str = None) -> list:
    """Get list of processes using GPU compute."""
    cmd = "nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null"
    result = _run(cmd, ssh_target)

    procs = []
    for line in result.strip().split('\n'):
        if line.strip():
            parts = [p.strip() for p in line.split(', ')]
            if len(parts) >= 2:
                procs.append({
                    "pid": parts[0],
                    "name": parts[1],
                    "gpu_memory_mb": parts[2] if len(parts) > 2 else "N/A",
                })
    return procs


def check_vulkan(ssh_target: str = None) -> dict:
    """Check Vulkan availability."""
    cmd = "vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|apiVersion|driverVersion' | head -3"
    result = _run(cmd, ssh_target)
    return {"available": len(result) > 10, "info": result.strip().split('\n')}


def check_nvenc(ssh_target: str = None) -> dict:
    """Check NVENC availability."""
    cmd = "ldconfig -p | grep -c nvidia-encode 2>/dev/null"
    result = _run(cmd, ssh_target)
    return {"available": int(result.strip() or 0) > 0, "count": int(result.strip() or 0)}


def check_gpu_conflict(isaac_sim_gpu_index: int, ray_gpu_count: int, ssh_target: str = None) -> dict:
    """Check for potential GPU resource conflict between Ray and Isaac Sim."""
    gpu_info = get_gpu_info(ssh_target)
    issues = []

    if isaac_sim_gpu_index >= gpu_info["count"]:
        issues.append(f"Isaac Sim GPU index {isaac_sim_gpu_index} exceeds physical GPU count {gpu_info['count']}")

    if ray_gpu_count >= gpu_info["count"]:
        issues.append(f"Ray declares {ray_gpu_count} GPUs but only {gpu_info['count']} physical GPUs")

    return {
        "conflict_possible": len(issues) > 0,
        "issues": issues,
        "physical_gpu_count": gpu_info["count"],
        "ray_declared_gpus": ray_gpu_count,
        "isaac_sim_gpu_index": isaac_sim_gpu_index,
    }


def _run(cmd: str, ssh_target: str = None) -> str:
    if ssh_target:
        full_cmd = f"{ssh_target} '{cmd}'"
    else:
        full_cmd = cmd
    try:
        result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True, timeout=15)
        return result.stdout.strip()
    except:
        return ""