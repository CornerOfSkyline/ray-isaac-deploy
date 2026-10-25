# Ray-Isaac-Deploy Operations Manual

## Daily Operations

### Check Status
```powershell
.\deploy.ps1 -Action status
```

### Start Visualization
```bash
# On 4090 via SSH:
bash /home/zjf/ray-isaac-deploy/linux/visualization/start-visualization.sh
```

### View Isaac Sim
```powershell
.\deploy.ps1 -Action open-viewer
# Or: .\open-isaacsim.ps1
```

### Stop Visualization
```bash
# On 4090:
bash /home/zjf/ray-isaac-deploy/linux/visualization/stop-visualization.sh
```

### Full Verification
```powershell
.\deploy.ps1 -Action verify
```

## Component Dependencies

```
Ray Tunnels → Ray Head → Ray Worker
Xvnc → noVNC → Isaac Sim → WebRTC Client → CDP connect
```

## Process Management

### Managed vs Unmanaged

The toolkit tracks processes via PID files in `~/.local/state/ray-isaac-deploy/pids/`. 
Only processes registered in these files are stopped by our scripts. 
Other instances (even if matching the same binary names) are reported as warnings but never touched.

### Start Safety

The start scripts detect existing managed instances and reuse them. 
Duplicate starts do not create duplicate processes.

### Stop Safety

Stop operations use PID files to identify processes. 
`pgrep -f` is only used for reporting, never for termination.

## SSH Tunnel Architecture

Ray uses loopback alias addresses with SSH port forwarding:

- A800 (Head): 127.0.0.2, GCS :6379
- 4090 (Worker): 127.0.0.3, GPU:1

Tunnels are managed by `head_tunnel.sh` and `worker_tunnel.sh` in the existing
`~/workspace/ray_ws/ray_ssh_cluster/` project. The toolkit wraps these scripts.

## Log Locations

| Component | Log Path |
|-----------|----------|
| Isaac Sim | `~/.local/state/ray-isaac-deploy/logs/isaac-stream.log` |
| WebRTC Client | `~/.local/state/ray-isaac-deploy/logs/webrtc-client.log` |
| Xvnc | `~/.local/state/ray-isaac-deploy/logs/xvnc.log` |
| noVNC | `~/.local/state/ray-isaac-deploy/logs/novnc.log` |

## Recovery Procedures

### Isaac Sim not responding
```bash
bash /home/zjf/ray-isaac-deploy/linux/visualization/stop-visualization.sh
bash /home/zjf/ray-isaac-deploy/linux/visualization/start-visualization.sh
```

### Browser shows black screen
1. Check WebRTC client is running: `pgrep isaacsim-webrtc`
2. Check stream status: `grep 'Stream started' /home/zjf/.local/state/ray-isaac-deploy/logs/webrtc-client.log`
3. Restart visualization if needed

### Ray Worker disconnected
```bash
# On A800:
cd ~/workspace/ray_ws/ray_ssh_cluster
bash ./head_tunnel.sh status
bash ./stop_cluster.sh   # Only if needed
bash ./start_head.sh     # Restart head
# Then on 4090: restart worker
```