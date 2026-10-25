# Installation Guide

## Prerequisites

### Windows Controller
- Windows 10/11 with PowerShell 5.1+
- OpenSSH client (`ssh` in PATH)
- Python 3.10+ (for config bridge)
- `pip install pyyaml jsonschema websockets`

### A800 (Ray Head)
- Ubuntu 22.04, Python 3.10
- Ray 2.40.0 (exact version, pinned)
- GPU driver (pre-installed by provider)
- SSH server with key-based auth

### RTX 4090 (Ray Worker + Isaac Sim)
- Ubuntu 22.04, Python 3.10
- Ray 2.40.0 (exact version)
- NVIDIA Driver 580+ (pre-installed)
- SSH server with key-based auth

## Quick Install (Existing Environment)

```powershell
# Clone the toolkit
git clone https://github.com/CornerOfSkyline/ray-isaac-deploy.git
cd ray-isaac-deploy

# Check current state (read-only)
.\deploy.ps1 -Action status

# Dry-run install plan
.\deploy.ps1 -Action install -DryRun
```

## Component Installation (Manual Steps)

### Isaac Sim 6.2.0
1. Download standalone from NVIDIA: `isaac-sim-standalone-6.2.0-linux-x86_64.zip`
2. Extract to installation path
3. Run `post_install.sh`
4. Accept EULA: `export OMNI_KIT_ACCEPT_EULA=Y`

### TigerVNC 1.14.1 (user-level)
```bash
cd /tmp
wget https://sourceforge.net/projects/tigervnc/files/stable/1.14.1/tigervnc-1.14.1.x86_64.tar.gz
tar xzf tigervnc-1.14.1.x86_64.tar.gz
# Install libxcvt dependency:
apt-get download libxcvt0 && dpkg-deb -x libxcvt0*.deb libxcvt && cp libxcvt/usr/lib/x86_64-linux-gnu/libxcvt.so.0* ~/tigervnc-1.14.1.x86_64/usr/lib/
```

### noVNC + websockify
```bash
pip install --user websockify
cd /tmp && wget https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz
tar xzf v1.5.0.tar.gz && mv noVNC-1.5.0 ~/
```

### WebRTC Streaming Client 2.0.0
```bash
mkdir -p ~/isaacsim-webrtc-streaming-client && cd ~/isaacsim-webrtc-streaming-client
wget https://downloads.isaacsim.nvidia.com/isaacsim-webrtc-streaming-client-2.0.0-linux-x86_64.deb
ar x *.deb && tar xf data.tar.xz
```

## Post-Install Verification
```powershell
.\deploy.ps1 -Action verify -Mode passive
```