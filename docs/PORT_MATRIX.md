# Port Matrix - Ray + Isaac Sim Deployment

## Loopback Aliases

| Alias | Machine | Role |
|-------|---------|------|
| 127.0.0.2 | A800 | Ray Head advertised address |
| 127.0.0.3 | 4090 | Ray Worker advertised address |
| 192.168.0.12 | 4090 | Container eth0 (Isaac Sim WebRTC) |

## Ray Cluster Ports

### Head (A800, bind to 0.0.0.0, advertise 127.0.0.2)

| Port | Service | Direction |
|------|---------|-----------|
| 6379 | GCS Server | Worker → Head (SSH -L) |
| 22002 | Node Manager | Worker → Head (SSH -L) |
| 22003 | Object Manager | Bidirectional (SSH -L) |
| 22004 | Runtime Env Agent | Worker → Head (SSH -L) |
| 22005 | Dashboard Agent gRPC | Worker → Head (SSH -L) |
| 22006 | Dashboard Agent HTTP | Worker → Head (SSH -L) |
| 22007 | Metrics Export | Worker → Head (SSH -L) |
| 22008 | Dashboard gRPC | Worker → Head (SSH -L) |
| 22100-22131 | Worker/Driver RPC | Bidirectional (SSH -L) |

### Worker (4090, bind to 0.0.0.0, advertise 127.0.0.3)

| Port | Service | Direction |
|------|---------|-----------|
| 23002 | Node Manager | Head → Worker (SSH -L) |
| 23003 | Object Manager | Bidirectional (SSH -L) |
| 23004 | Runtime Env Agent | Head → Worker (SSH -L) |
| 23005 | Dashboard Agent gRPC | Head → Worker (SSH -L) |
| 23006 | Dashboard Agent HTTP | Head → Worker (SSH -L) |
| 23007 | Metrics Export | Head → Worker (SSH -L) |
| 23100-23131 | Worker/Driver RPC | Bidirectional (SSH -L) |

## Isaac Sim Visualization Ports

| Port | Protocol | Service | Bind | Access |
|------|----------|---------|------|--------|
| 49100 | TCP | WebRTC Signaling | 0.0.0.0 | Container-internal only |
| 47998 | UDP | WebRTC Media | 0.0.0.0 | Container-internal only |
| 5901 | TCP | VNC (TigerVNC) | 127.0.0.1 | localhost only |
| 6006 | TCP | noVNC (websockify) | 127.0.0.1 | localhost only |
| 9222 | TCP | CDP (Chrome DevTools) | 127.0.0.1 | localhost only |

## Windows SSH Tunnels

| Local Port | Remote | Purpose |
|------------|--------|---------|
| 16006 | 4090:6006 | noVNC browser access |

## Security Notes

- VNC has NO authentication (SecurityTypes=None) - protected by `-localhost=1` and SSH tunnel only
- CDP port 9222 has NO authentication - bound to 127.0.0.1 only
- All remote ports use SSH -L with ExitOnForwardFailure=yes and StrictHostKeyChecking=accept-new
- No ports are exposed to the public internet