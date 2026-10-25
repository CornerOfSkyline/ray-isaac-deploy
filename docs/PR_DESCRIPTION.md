# Release v1.1: Ray-Isaac deployment and visualization toolkit

## Overview

Standardized deployment toolkit for Ray 2.40.0 cluster (A800 + RTX 4090) and
Isaac Sim 6.2.0 remote visualization via SSH TCP tunnels + noVNC.

## Architecture

```
Windows (PowerShell controller)
  ├── SSH ──→ A800 (Ray Head, 127.0.0.2)
  └── SSH ──→ 4090 (Ray Worker 127.0.0.3 + Isaac Sim)
                  └── Isaac Sim → local WebRTC → Xvnc → noVNC → browser
```

## Verified Working Features

- Ray 2.40.0 two-node cluster with SSH loopback tunnels (adapter mode via legacy scripts)
- Isaac Sim 6.2.0 streaming + local WebRTC client + Xvnc + noVNC visualization
- Windows PowerShell deploy.ps1 (status/verify/start/stop/open-viewer)
- Process identity verification (5-field: PID/UID/start_time/exe/cmdline)
- Configuration via Python YAML bridge with JSON Schema validation

## Test Results

```
25 passed, 5 skipped, 0 failed
PowerShell Parser: 0 errors
bash -n: 6/6 scripts PASS on 4090
```

## Known Limitations

- **Standalone Ray deployment**: Not implemented. Existing deployment relies on legacy adapter (`~/workspace/ray_ws/ray_ssh_cluster/`).
- **Production noVNC**: Currently bound to 0.0.0.0:6006. Fix ready via `repair-novnc.sh --adopt --apply` (requires maintenance window authorization).
- **Ray Active GPU verification**: Not tested on production cluster. `tests/e2e/verify_ray_active.py` ready for authorized execution.
- **Full service stop/restart**: Not tested in production.

## NOT AUTHORIZED (pending maintenance window)

- Production `repair-novnc.sh --adopt` / `--apply`
- Ray GPU task submission
- Isaac Sim restart
- SSH tunnel changes
- `deploy.ps1 -Action install` (non-DryRun)

## Maintenance Plan

```
Step 1 (read-only): bash repair-novnc.sh
Step 2 (authorized): bash repair-novnc.sh --adopt  (registers PID 2715723, no restart)
Step 3 (authorized): bash repair-novnc.sh --apply  (~5s VNC disconnect)
```