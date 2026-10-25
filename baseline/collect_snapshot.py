#!/usr/bin/env python3
"""collect_snapshot.py - Collect current working state from 4090"""
import subprocess, json, os, sys, hashlib, time

def run(cmd):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    return result.stdout.strip()

def sha256_file(path):
    if os.path.isfile(path):
        with open(path, 'rb') as f:
            return hashlib.sha256(f.read()).hexdigest()
    return None

def read_cmdline(pid):
    try:
        with open(f'/proc/{pid}/cmdline', 'rb') as f:
            return f.read().decode().replace('\x00', ' ').strip()
    except:
        return None

snapshot = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "hostname": run("hostname"),
    "os": {},
    "hardware": {},
    "software": {},
    "processes": {},
    "ports": {},
    "files": {},
}

# OS
snapshot["os"] = {
    "pretty_name": run("cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2"),
    "version_id": run("cat /etc/os-release | grep VERSION_ID | cut -d= -f2"),
    "kernel": run("uname -r"),
}

# Hardware
gpu_lines = run("nvidia-smi --query-gpu=index,name,uuid,memory.total,driver_version --format=csv,noheader").split('\n')
snapshot["hardware"]["gpus"] = []
for line in gpu_lines:
    parts = [p.strip() for p in line.split(', ')]
    if len(parts) >= 5:
        snapshot["hardware"]["gpus"].append({
            "index": parts[0], "name": parts[1], "uuid": parts[2],
            "memory_total": parts[3], "driver_version": parts[4]
        })

snapshot["hardware"]["nvenc"] = run("ldconfig -p | grep -c nvidia-encode")
snapshot["hardware"]["vulkan"] = run("vulkaninfo --summary 2>/dev/null | grep -E 'apiVersion|driverVersion|deviceName' | head -3")

# Software
snapshot["software"]["python"] = run("python3 --version")
try: import ray; snapshot["software"]["ray"] = ray.__version__
except: snapshot["software"]["ray"] = "N/A"
snapshot["software"]["isaac_sim"] = run("cat /home/zjf/isaacsim/VERSION 2>/dev/null")

# Processes
key_procs = run("pgrep -f 'kit/kit|Xvnc|websockify|raylet|isaacsim-webrtc|dashboard.agent' 2>/dev/null")
for pid in key_procs.split('\n'):
    pid = pid.strip()
    if pid and pid.isdigit():
        cmdline = read_cmdline(pid)
        exe = os.readlink(f'/proc/{pid}/exe') if os.path.exists(f'/proc/{pid}/exe') else None
        snapshot["processes"][pid] = {
            "cmdline": cmdline[:500] if cmdline else "N/A",
            "exe": exe
        }

# Ports
snapshot["ports"] = {}
for line in run("ss -tulnp 2>/dev/null").split('\n'):
    for port in ['49100','47998','5901','6006','9222','23002','23003','23100','6379','22002','22003','22100']:
        if f':{port} ' in line:
            snapshot["ports"][port] = line.strip()[:150]

# Key files checksums
key_files = [
    "/home/zjf/isaacsim/VERSION",
    "/home/zjf/isaacsim/isaac-sim.streaming.sh",
    "/home/zjf/launch_webrtc_client.sh",
    "/home/zjf/auto_connect_webrtc.py",
    "/home/zjf/click_connect.py",
    "/home/zjf/start_isaac_tcp_stream.sh",
    "/home/zjf/tigervnc/usr/bin/Xvnc",
]
for f in key_files:
    h = sha256_file(f)
    if h:
        snapshot["files"][f] = {"sha256": h, "size": os.path.getsize(f)}

# IP addresses
snapshot["network"] = {
    "ips": run("ip -4 -o addr show | awk '{print $4, $2}'"),
}

print(json.dumps(snapshot, indent=2))