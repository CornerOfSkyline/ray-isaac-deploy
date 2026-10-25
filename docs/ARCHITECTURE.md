# Ray-Isaac-Deploy Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Windows Controller                              │
│  PowerShell: deploy.ps1 (start/stop/status/verify/open-viewer)     │
│  Browser: http://127.0.0.1:16006/vnc.html                          │
└──────────┬──────────────────────────────────────┬──────────────────┘
           │ SSH -L :16006→:6006                  │ SSH control
           ▼                                      ▼
┌──────────────────────┐              ┌──────────────────────────────┐
│   A800 (Ray Head)    │              │    RTX 4090 (Worker+Isaac)   │
│                      │   SSH tunnel │                              │
│  GCS :6379           │◄─────────────│  Raylet (GPU:1)              │
│  NodeMgr :22002      │   (bidir)    │  NodeMgr :23002              │
│  ObjMgr :22003       │              │  ObjMgr :23003               │
│  8× A800 GPU         │              │  4× RTX 4090 GPU             │
└──────────────────────┘              │                              │
                                      │  ┌───────────────────────┐  │
                                      │  │ Isaac Sim 6.2.0       │  │
                                      │  │  Streaming :49100     │  │
                                      │  │  UDP :47998 (local)   │  │
                                      │  └───────────┬───────────┘  │
                                      │              │ WebRTC UDP   │
                                      │  ┌───────────▼───────────┐  │
                                      │  │ WebRTC Client         │  │
                                      │  │  Electron --disable-  │  │
                                      │  │  gpu, CDP :9222       │  │
                                      │  └───────────┬───────────┘  │
                                      │              │ X11          │
                                      │  ┌───────────▼───────────┐  │
                                      │  │ Xvnc :1 (5901)        │  │
                                      │  │  TigerVNC 1.14.1      │  │
                                      │  │  1920×1080, -ac       │  │
                                      │  └───────────┬───────────┘  │
                                      │              │ VNC RFB      │
                                      │  ┌───────────▼───────────┐  │
                                      │  │ websockify + noVNC    │  │
                                      │  │  :6006 → :5901        │  │
                                      │  └───────────────────────┘  │
                                      └──────────────────────────────┘
```

## Key Design Decisions

### 1. WebRTC Media Stays Local
UDP port 47998 never leaves the 4090 container. The WebRTC client connects to Isaac Sim at 192.168.0.12 (container IP), and only the rendered desktop is tunneled out via noVNC over TCP.

### 2. Electron --disable-gpu
SwiftShader/ANGLE GPU flags break the Electron WebRTC client's UI rendering on Xvnc. Using `--disable-gpu` forces software rendering which works reliably on virtual X11 displays.

### 3. Ray Loopback Tunneling
Both machines use 127.0.0.x loopback addresses with SSH -L port forwards, avoiding any need for VPN, Tailscale, or direct network access between containers.

### 4. Single-Instance Management
The ProcessRegistry prevents duplicate process launches. Start operations detect existing instances and reuse them rather than creating duplicates.

## Component Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Ray | 2.40.0 | Pinned - do not upgrade |
| Isaac Sim | 6.2.0-rc.14 | Standalone at /home/zjf/isaacsim |
| TigerVNC | 1.14.1 | User-installed at /home/zjf/tigervnc |
| noVNC | 1.5.0 | Static HTML/JS at /home/zjf/noVNC-1.5.0 |
| websockify | 0.13.0 | pip install --user |
| WebRTC Client | 2.0.0 | NVIDIA official, extracted from .deb |
| NVIDIA Driver | 580.82.07 | System-installed |
| CUDA | 13.0 | Driver-bundled |

## Known Fixes

| Issue | Fix |
|-------|-----|
| Electron UI blank on VNC | Use `--disable-gpu` instead of SwiftShader/ANGLE |
| TigerVNC libxcvt missing | LD_LIBRARY_PATH=/home/zjf/tigervnc/usr/lib |
| xkbcomp not found | TigerVNC works with libxcvt present; xkbcomp not needed |
| Duplicate websockify | Clean up before starting new instance |
| SSH timeout during Isaac Sim | Isaac Sim at 99% CPU degrades SSH; use nohup + short commands |