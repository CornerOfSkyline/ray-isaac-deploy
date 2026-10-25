# Recovery Procedures

## Visualization Stack

### Symptom: Browser shows black screen
1. Check WebRTC client: `pgrep isaacsim-webrtc`
2. Check stream status: `grep 'Stream started' ~/.local/state/ray-isaac-deploy/logs/webrtc-client.log`
3. Restart visualization: `bash ~/ray-isaac-deploy/linux/visualization/start-visualization.sh`

### Symptom: Isaac Sim not responding
1. Check kit process: `pgrep -f 'kit/kit'`
2. Check log: `tail -50 ~/.local/state/ray-isaac-deploy/logs/isaac-stream.log`
3. Stop and restart: `bash ~/ray-isaac-deploy/linux/visualization/stop-visualization.sh && bash ~/ray-isaac-deploy/linux/visualization/start-visualization.sh`

## Ray Cluster

### Symptom: Worker disconnected
1. Check tunnels: `bash ~/ray-isaac-deploy/linux/ray/cluster.sh status`
2. Check worker raylet: `ssh -p 46602 zjf@180.97.68.228 'pgrep raylet'`
3. Recover worker: `bash ~/ray-isaac-deploy/linux/ray/cluster.sh recover-worker`

### Symptom: GCS unreachable
1. Check SSH tunnels (both directions)
2. Verify A800: `ssh -p 46885 zjf@117.74.66.77 'pgrep gcs_server'`
3. Restart head tunnel: `bash ~/ray-isaac-deploy/linux/ray/cluster.sh start-tunnels`

## SSH Tunnels

### Symptom: Port forwarding dropped
1. Check tunnel status: `bash ~/ray-isaac-deploy/linux/ray/start-tunnels.sh status`
2. Restart: `bash ~/ray-isaac-deploy/linux/ray/start-tunnels.sh start`
3. If persistent, check SSH connectivity and server alive settings

## Complete Service Restart

Only in maintenance window, with all jobs drained:
```bash
# Stop visualization
bash ~/ray-isaac-deploy/linux/visualization/stop-visualization.sh
# Stop Ray worker, head, tunnels
bash ~/ray-isaac-deploy/linux/ray/cluster.sh stop-cluster
# Restart in order: tunnels -> head -> worker -> visualization
bash ~/ray-isaac-deploy/linux/ray/cluster.sh start-tunnels
bash ~/ray-isaac-deploy/linux/ray/cluster.sh start-head
bash ~/ray-isaac-deploy/linux/ray/cluster.sh start-worker
bash ~/ray-isaac-deploy/linux/visualization/start-visualization.sh
```