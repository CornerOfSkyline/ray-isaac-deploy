<#
.SYNOPSIS
    Ray + Isaac Sim deployment toolkit - unified control from Windows
.DESCRIPTION
    Manages Ray 2.40.0 cluster (A800 + 4090) and Isaac Sim 6.2.0 visualization
    across SSH tunnels with noVNC browser access.
.PARAMETER Action
    Action to perform: doctor, status, start, stop, restart, verify, logs, open-viewer, snapshot
.PARAMETER Component
    Target component: ray, visualization, isaacsim, webrtc-client, vnc, novnc, all
.EXAMPLE
    .\deploy.ps1 -Action status
    .\deploy.ps1 -Action start -Component visualization
    .\deploy.ps1 -Action verify
#>

param(
    [Parameter(Position=0)]
    [ValidateSet("doctor","status","start","stop","restart","verify","logs","open-viewer","snapshot","configure")]
    [string]$Action = "status",

    [Parameter(Position=1)]
    [ValidateSet("ray","ray-head","ray-worker","visualization","isaacsim","webrtc-client","vnc","novnc","all")]
    [string]$Component = "all",

    [switch]$DryRun,
    [switch]$Force,
    [string]$Profile = "verified-20261025"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

# SSH connection strings (from verified profile)
$A800_SSH = "ssh -p 46885 zjf@117.74.66.77"
$GPU4090_SSH = "ssh -p 46602 zjf@180.97.68.228"
$NOVNC_LOCAL_PORT = 16006
$NOVNC_REMOTE_PORT = 6006

function Invoke-Remote4090 {
    param([string]$Command, [int]$TimeoutSec = 15)
    $fullCmd = "$GPU4090_SSH '$Command'"
    if ($DryRun) { Write-Host "[DRY RUN] $fullCmd" -ForegroundColor Gray; return "" }
    try {
        $result = Invoke-Expression $fullCmd 2>&1 | Out-String
        return $result.Trim()
    } catch {
        Write-Host "SSH Error: $_" -ForegroundColor Red
        return ""
    }
}

function Invoke-RemoteA800 {
    param([string]$Command, [int]$TimeoutSec = 15)
    $fullCmd = "$A800_SSH '$Command'"
    if ($DryRun) { Write-Host "[DRY RUN] $fullCmd" -ForegroundColor Gray; return "" }
    try {
        $result = Invoke-Expression $fullCmd 2>&1 | Out-String
        return $result.Trim()
    } catch {
        Write-Host "SSH Error: $_" -ForegroundColor Red
        return ""
    }
}

# === Action Implementations ===

function Invoke-Status {
    Write-Host "`n=== Ray + Isaac Sim Status ===" -ForegroundColor Cyan
    Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

    # SSH connectivity
    Write-Host "`n--- SSH Connectivity ---" -ForegroundColor Yellow
    $a800 = Invoke-RemoteA800 "echo OK"
    $g4090 = Invoke-Remote4090 "echo OK"
    Write-Host "  A800:  $(if($a800 -eq 'OK'){'[ONLINE]'}else{'[OFFLINE]'})"
    Write-Host "  4090:  $(if($g4090 -eq 'OK'){'[ONLINE]'}else{'[OFFLINE]'})"

    # Ray cluster
    Write-Host "`n--- Ray Cluster (from 4090) ---" -ForegroundColor Yellow
    $rayStatus = Invoke-Remote4090 "python3 -c 'import ray; ray.init(address=\"127.0.0.2:6379\",ignore_reinit_error=True,logging_level=\"ERROR\"); print(f\"GPU:{ray.cluster_resources().get(\"GPU\",0)} Nodes:{len([n for n in ray.nodes() if n[\"Alive\"]])}\"); ray.shutdown()' 2>/dev/null"
    Write-Host "  $rayStatus"

    # GPU
    Write-Host "`n--- GPU (4090) ---" -ForegroundColor Yellow
    $gpu = Invoke-Remote4090 "nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader"
    Write-Host $gpu

    # Key ports
    Write-Host "`n--- Key Ports (4090) ---" -ForegroundColor Yellow
    $ports = Invoke-Remote4090 "ss -tlnp 2>/dev/null | grep -E '49100|5901|6006|9222|23002' | awk '{print \$4}' | sort -u"
    Write-Host $ports

    # Visualization processes
    Write-Host "`n--- Visualization Processes (4090) ---" -ForegroundColor Yellow
    $procs = Invoke-Remote4090 "for p in kit/kit 'Xvnc' websockify isaacsim-webrtc; do c=`$(pgrep -c -f \"`$p\" 2>/dev/null || echo 0); echo \"  `$p: `$c\"; done"
    Write-Host $procs

    # Stream status
    Write-Host "`n--- WebRTC Stream ---" -ForegroundColor Yellow
    $stream = Invoke-Remote4090 "grep 'Stream started.*success' /tmp/isaacsim_logs/webrtc-client.log 2>/dev/null | tail -1 || echo '  No success entry'"
    Write-Host "  $stream"

    # Windows tunnel
    Write-Host "`n--- Windows SSH Tunnel ---" -ForegroundColor Yellow
    $tunnel = netstat -ano 2>$null | Select-String "16006"
    if ($tunnel) { Write-Host "  Tunnel active on :16006" } else { Write-Host "  Tunnel NOT active" }
}

function Invoke-Doctor {
    Write-Host "`n=== Full System Diagnostic ===" -ForegroundColor Cyan

    # Run the Python diagnostics module on 4090
    $diag = Invoke-Remote4090 "python3 -c '
import json
d = {}
d[\"ssh\"] = \"OK\"
d[\"gpu\"] = \"$(nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader | tr '\''\n'\'' ';')\""
d[\"ports\"] = \"$(ss -tlnp | grep -E '49100|5901|6006|9222|23002|23003' | awk '{print \$4}' | tr '\''\n'\'' ';')\""
d[\"raylet\"] = $(pgrep -c raylet)
d[\"kit\"] = $(pgrep -c 'kit/kit')
d[\"vnc\"] = $(pgrep -c Xvnc)
d[\"webrtc\"] = $(pgrep -c isaacsim-webrtc)
d[\"stream\"] = \"$(grep -c 'Stream started.*success' /tmp/isaacsim_logs/webrtc-client.log 2>/dev/null || echo 0)\""
d[\"nvenc\"] = $(ldconfig -p | grep -c nvidia-encode)
print(json.dumps(d))
' 2>/dev/null"
    Write-Host $diag
}

function Invoke-StartVisualization {
    Write-Host "`n=== Starting Visualization Stack ===" -ForegroundColor Cyan

    # 1. Xvnc
    Write-Host "[1/5] Xvnc..." -ForegroundColor Yellow
    $vncRunning = Invoke-Remote4090 "pgrep -c Xvnc"
    if ($vncRunning -eq "0") {
        Write-Host "  Starting Xvnc..."
        Invoke-Remote4090 "export LD_LIBRARY_PATH=/home/zjf/tigervnc/usr/lib:`$LD_LIBRARY_PATH; nohup /home/zjf/tigervnc/usr/bin/Xvnc :1 -geometry 1920x1080 -depth 24 -SecurityTypes None -AlwaysShared -localhost=1 -ac > /home/zjf/.local/state/ray-isaac-deploy/logs/xvnc.log 2>&1 &"
    } else {
        Write-Host "  Already running ($vncRunning instances)"
    }

    # 2. noVNC
    Write-Host "[2/5] noVNC..." -ForegroundColor Yellow
    $novncRunning = Invoke-Remote4090 "pgrep -c websockify"
    if ($novncRunning -gt "1") {
        # Clean up dupes first
        Invoke-Remote4090 "pgrep websockify | tail -n +2 | xargs -r kill 2>/dev/null"
    }
    if ($novncRunning -eq "0") {
        Invoke-Remote4090 "nohup /home/zjf/.local/bin/websockify --web=/home/zjf/noVNC-1.5.0 6006 127.0.0.1:5901 > /home/zjf/.local/state/ray-isaac-deploy/logs/novnc.log 2>&1 &"
    }

    # 3. Isaac Sim
    Write-Host "[3/5] Isaac Sim..." -ForegroundColor Yellow
    $isaacRunning = Invoke-Remote4090 "pgrep -c 'kit/kit'"
    if ($isaacRunning -eq "0") {
        Invoke-Remote4090 "cd /home/zjf/isaacsim; nohup ./isaac-sim.streaming.sh --allow-root --/exts/omni.kit.livestream.app/primaryStream/signalPort=49100 --/exts/omni.kit.livestream.app/primaryStream/streamPort=47998 --/exts/omni.kit.livestream.app/primaryStream/publicIp=192.168.0.12 > /home/zjf/.local/state/ray-isaac-deploy/logs/isaac-stream.log 2>&1 &"
        Write-Host "  Started (waiting ~30s for load)"
        Start-Sleep -Seconds 30
    } else {
        Write-Host "  Already running"
    }

    # 4. WebRTC Client
    Write-Host "[4/5] WebRTC Client..." -ForegroundColor Yellow
    $clientRunning = Invoke-Remote4090 "pgrep -c isaacsim-webrtc"
    if ($clientRunning -eq "0") {
        $clientDir = "/home/zjf/isaacsim-webrtc-streaming-client/opt/Isaac Sim WebRTC Streaming Client"
        Invoke-Remote4090 "cd `'$clientDir`'; nohup env DISPLAY=:1 `'$clientDir/isaacsim-webrtc-streaming-client`' --no-sandbox --disable-gpu --disable-dev-shm-usage --ozone-platform=x11 --remote-debugging-port=9222 > /home/zjf/.local/state/ray-isaac-deploy/logs/webrtc-client.log 2>&1 &"
        Start-Sleep -Seconds 10
    } else {
        Write-Host "  Already running"
    }

    # 5. CDP Auto-connect
    Write-Host "[5/5] CDP Auto-connect..." -ForegroundColor Yellow
    Invoke-Remote4090 "sleep 5; python3 /home/zjf/auto_connect_webrtc.py 192.168.0.12 49100 47998 1920 1080 2>&1"

    Write-Host "`nVisualization started." -ForegroundColor Green
}

function Invoke-StopVisualization {
    Write-Host "`n=== Stopping Visualization Stack ===" -ForegroundColor Cyan
    # Stop in reverse order: client -> isaac -> novnc -> vnc
    foreach ($comp in @("isaacsim-webrtc", "kit/kit", "websockify", "Xvnc")) {
        $pids = Invoke-Remote4090 "pgrep -f '$comp' 2>/dev/null"
        if ($pids) {
            Write-Host "Stopping $comp..." -ForegroundColor Yellow
            Invoke-Remote4090 "pgrep -f '$comp' | xargs -r kill -TERM 2>/dev/null; sleep 2; pgrep -f '$comp' | xargs -r kill -9 2>/dev/null"
        }
    }
    Write-Host "Visualization stopped." -ForegroundColor Green
}

function Invoke-OpenViewer {
    Write-Host "`n=== Opening Isaac Sim Viewer ===" -ForegroundColor Cyan

    # Check for existing tunnel
    $existing = netstat -ano 2>$null | Select-String "16006.*LISTEN"
    if (-not $existing) {
        Write-Host "Establishing SSH tunnel..."
        Start-Process -FilePath "ssh" -ArgumentList "-NT", "-p", "46602", "-L", "127.0.0.1:16006:127.0.0.1:6006", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "zjf@180.97.68.228" -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }

    # Verify
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:16006/vnc.html" -UseBasicParsing -TimeoutSec 5
        Write-Host "noVNC accessible (HTTP $($response.StatusCode))" -ForegroundColor Green
    } catch {
        Write-Host "noVNC not reachable - check tunnel" -ForegroundColor Red
        return
    }

    # Open browser
    $url = "http://127.0.0.1:16006/vnc.html?autoconnect=1&resize=remote"
    Write-Host "Opening: $url" -ForegroundColor Cyan
    Start-Process $url
}

function Invoke-Verify {
    Write-Host "`n=== End-to-End Verification ===" -ForegroundColor Cyan

    $checks = @()

    # 1. SSH
    $a800 = Invoke-RemoteA800 "echo OK"
    $g4090 = Invoke-Remote4090 "echo OK"
    $checks += @{Name="SSH A800"; Pass=($a800 -eq "OK")}
    $checks += @{Name="SSH 4090"; Pass=($g4090 -eq "OK")}

    # 2. Ray
    $rayOk = Invoke-Remote4090 "python3 -c 'import ray; ray.init(address=\"127.0.0.2:6379\",ignore_reinit_error=True,logging_level=\"ERROR\"); alive=len([n for n in ray.nodes() if n[\"Alive\"]]); print(alive); ray.shutdown()' 2>/dev/null"
    $checks += @{Name="Ray Nodes ($rayOk alive)"; Pass=([int]$rayOk -ge 2)}

    # 3. GPU
    $gpuCount = Invoke-Remote4090 "nvidia-smi -L 2>/dev/null | wc -l"
    $checks += @{Name="GPUs detected"; Pass=([int]$gpuCount -eq 4)}

    # 4. Visualization layers
    $vnc = Invoke-Remote4090 "ss -tlnp | grep -c ':5901 '"
    $checks += @{Name="VNC :5901"; Pass=([int]$vnc -gt 0)}

    $novnc = Invoke-Remote4090 "ss -tlnp | grep -c ':6006 '"
    $checks += @{Name="noVNC :6006"; Pass=([int]$novnc -gt 0)}

    $sig = Invoke-Remote4090 "ss -tlnp | grep -c ':49100 '"
    $checks += @{Name="Isaac Sim :49100"; Pass=([int]$sig -gt 0)}

    $stream = Invoke-Remote4090 "grep -c 'Stream started.*success' /tmp/isaacsim_logs/webrtc-client.log 2>/dev/null || echo 0"
    $checks += @{Name="WebRTC Stream"; Pass=([int]$stream -gt 0)}

    # 5. Windows tunnel
    $tunnel = netstat -ano 2>$null | Select-String "16006.*LISTEN"
    $checks += @{Name="Windows Tunnel :16006"; Pass=($tunnel -ne $null)}

    # Report
    Write-Host ""
    $passCount = 0
    foreach ($c in $checks) {
        $icon = if($c.Pass){"[PASS]"}else{"[FAIL]"}
        $color = if($c.Pass){"Green"}else{"Red"}
        Write-Host "  $icon $($c.Name)" -ForegroundColor $color
        if ($c.Pass) { $passCount++ }
    }
    Write-Host "`n  Result: $passCount/$($checks.Count) checks passed" -ForegroundColor $(if($passCount -eq $checks.Count){"Green"}else{"Yellow"})
}

# === Main Dispatch ===

switch ($Action) {
    "status"     { Invoke-Status }
    "doctor"     { Invoke-Doctor }
    "snapshot"   { Write-Host "Snapshot: baseline/working_baseline.json already captured"; Invoke-Status }
    "start"      {
        if ($Component -in @("visualization","vnc","novnc","isaacsim","webrtc-client","all")) {
            Invoke-StartVisualization
        }
        if ($Component -in @("ray","ray-head","ray-worker","all")) {
            Write-Host "Ray component: Use A800/4090 specific scripts" -ForegroundColor Yellow
        }
    }
    "stop"       {
        if ($Component -in @("visualization","vnc","novnc","isaacsim","webrtc-client","all")) {
            Invoke-StopVisualization
        }
    }
    "verify"     { Invoke-Verify }
    "open-viewer" { Invoke-OpenViewer }
    "logs"       { Write-Host "Logs on 4090: /home/zjf/.local/state/ray-isaac-deploy/logs/" -ForegroundColor Cyan }
    default      { Write-Host "Unknown action: $Action" -ForegroundColor Red }
}