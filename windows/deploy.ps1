#Requires -Version 5.1
<#
.SYNOPSIS
    Ray + Isaac Sim deployment toolkit v1.1 RC
    All config from Python YAML bridge - no hardcoded production IPs.
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('doctor', 'status', 'start', 'stop', 'restart', 'verify',
                 'logs', 'open-viewer', 'snapshot', 'configure', 'install')]
    [string]$Action = 'status',
    [Parameter(Position = 1)]
    [ValidateSet('ray', 'ray-head', 'ray-worker', 'visualization', 'isaacsim',
                 'webrtc-client', 'vnc', 'novnc', 'tunnels', 'all')]
    [string]$Component = 'all',
    [ValidateSet('passive', 'active')]
    [string]$Mode = 'passive',
    [switch]$DryRun,
    [switch]$Force,
    [string]$Profile = 'verified-20261025',
    [string]$ConfigPath,
    [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

# ============================================================
# Config loading via Python bridge (G4-01: fail-closed, no hardcoded fallbacks)
# ============================================================
$bridgeScript = Join-Path $ProjectDir 'linux\common\config_bridge.py'
if (-not (Test-Path $bridgeScript)) {
    Write-Host "FATAL: Config bridge not found: $bridgeScript" -ForegroundColor Red; exit 99
}

function Get-ConfigJson {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'python3'; $psi.Arguments = "`"$bridgeScript`" $Profile"
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(10000) | Out-Null
    if ($proc.ExitCode -ne 0) {
        Write-Host "FATAL: Config bridge failed (exit $($proc.ExitCode)): $stderr" -ForegroundColor Red
        exit 99
    }
    try { return $stdout | ConvertFrom-Json } catch {
        Write-Host "FATAL: Config JSON parse failed: $_" -ForegroundColor Red; exit 99 }
}

$config = Get-ConfigJson
if (-not $config.valid) { Write-Host "FATAL: Invalid config: $($config.error)" -ForegroundColor Red; exit 99 }

# Extract config values (all from validated YAML, no defaults)
$cfg = @{
    A800_Host   = $config.hosts.a800.ssh_host
    A800_Port   = [int]$config.hosts.a800.ssh_port
    A800_User   = $config.hosts.a800.ssh_user
    GPU4090_Host = $config.hosts.gpu4090.ssh_host
    GPU4090_Port = [int]$config.hosts.gpu4090.ssh_port
    GPU4090_User = $config.hosts.gpu4090.ssh_user
    BrowserPort = [int]$config.hosts.windows.browser_port
    NovncPort   = [int]$config.visualization.novnc.port
    VncPort     = [int]$config.visualization.vnc.port
    IsaacSignal = [int]$config.isaacsim.signal_port
    IsaacStream = [int]$config.isaacsim.stream_port
    IsaacIP     = $config.isaacsim.public_ip
    CdpPort     = [int]$config.visualization.webrtc_client.cdp_port
    LogDir      = $config.operations.log_dir
    RayGCS      = [int]$config.ray.head.gcs_port
    RayHeadIP   = $config.ray.head.address
    RayWorkerIP = $config.ray.worker.address
    PhysGPUs    = [int]$config.gpu_mapping.physical_gpus
}

# Validate all critical values are non-empty
foreach ($k in $cfg.Keys) {
    if (-not $cfg[$k]) { Write-Host "FATAL: Config missing: $k" -ForegroundColor Red; exit 99 }
}

# ============================================================
# SSH (G4-01: stdin-based, proper exit codes)
# ============================================================
class SshResult { [string]$Host; [int]$ExitCode; [string]$Stdout; [string]$Stderr; [bool]$TimedOut; [string]$Error
    [bool] Ok() { return $this.ExitCode -eq 0 -and -not $this.TimedOut -and -not $this.Error } }

function Invoke-SshCommand {
    param([string]$HostName, [int]$Port, [string]$User, [string]$Command, [int]$TimeoutSec = 30)
    if ($DryRun) { Write-Host "[DRYRUN] ssh -p $Port ${User}@${HostName} '$Command'" -ForegroundColor Gray
        return [SshResult]@{ Host = $HostName; ExitCode = -1; Stdout = ''; Error = 'DryRun' } }
    $r = [SshResult]@{ Host = $HostName; ExitCode = -1 }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh'
        $psi.Arguments = "-p $Port -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ServerAliveInterval=15 ${User}@${HostName} $Command"
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $sbOut = $proc.StandardOutput.ReadToEnd(); $sbErr = $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) { $proc.Kill(); $r.TimedOut = $true; $r.Error = "Timeout ${TimeoutSec}s" }
        $r.ExitCode = $proc.ExitCode; $r.Stdout = $sbOut.Trim(); $r.Stderr = $sbErr.Trim(); $proc.Dispose()
    } catch { $r.Error = $_.Exception.Message }
    return $r
}

function Send-SshScript {
    param([string]$HostName, [int]$Port, [string]$User, [string]$Script, [string]$Interpreter = 'bash', [int]$TimeoutSec = 30)
    if ($DryRun) { Write-Host "[DRYRUN] ssh ${User}@${HostName} $Interpreter -s << SCRIPT" -ForegroundColor Gray
        return [SshResult]@{ Host = $HostName; ExitCode = -1; Error = 'DryRun' } }
    $r = [SshResult]@{ Host = $HostName; ExitCode = -1 }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh'
        $psi.Arguments = "-p $Port -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ServerAliveInterval=15 ${User}@${HostName} '$Interpreter -s'"
        $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.WriteLine($Script); $proc.StandardInput.Close()
        $sbOut = $proc.StandardOutput.ReadToEnd(); $sbErr = $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) { $proc.Kill(); $r.TimedOut = $true; $r.Error = "Timeout ${TimeoutSec}s" }
        $r.ExitCode = $proc.ExitCode; $r.Stdout = $sbOut.Trim(); $r.Stderr = $sbErr.Trim(); $proc.Dispose()
    } catch { $r.Error = $_.Exception.Message }
    return $r
}

function Invoke-4090 { param([string]$C, [int]$T = 15) Invoke-SshCommand -HostName $cfg.GPU4090_Host -Port $cfg.GPU4090_Port -User $cfg.GPU4090_User -Command $C -TimeoutSec $T }
function Invoke-A800 { param([string]$C, [int]$T = 15) Invoke-SshCommand -HostName $cfg.A800_Host -Port $cfg.A800_Port -User $cfg.A800_User -Command $C -TimeoutSec $T }
function Send-4090Script { param([string]$S, [string]$I = 'bash', [int]$T = 30) Send-SshScript -HostName $cfg.GPU4090_Host -Port $cfg.GPU4090_Port -User $cfg.GPU4090_User -Script $S -Interpreter $I -TimeoutSec $T }
function Test-SshOk { param([ScriptBlock]$C) try { $r = & $C; return ($r.Ok() -and $r.Stdout.Trim() -eq 'OK') } catch { return $false } }

function Write-Check { param([string]$N, [string]$S, [string]$D = '')
    $icons = @{ PASS = '[PASS]'; FAIL = '[FAIL]'; WARN = '[WARN]'; UNKNOWN = '[????]'; RUNNING = '[RUN ]'; STOPPED = '[STOP]' }
    $colors = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; UNKNOWN = 'Gray'; RUNNING = 'Green'; STOPPED = 'Red' }
    Write-Host "  $($icons[$S]) $N  $(if($D){$D})" -ForegroundColor $colors[$S]
}

# ============================================================
# Status (read-only, always safe)
# ============================================================
function Invoke-Status {
    Write-Host "`n=== Ray + Isaac Sim Status ===" -ForegroundColor Cyan
    Write-Host "Profile: $Profile | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    $exitCode = 0

    $a800Ok = Test-SshOk { Invoke-A800 'echo OK' -T 10 }
    $g4090Ok = Test-SshOk { Invoke-4090 'echo OK' -T 10 }
    Write-Check 'SSH A800' $(if ($a800Ok) { 'PASS' } else { 'FAIL' })
    Write-Check 'SSH 4090' $(if ($g4090Ok) { 'PASS' } else { 'FAIL' })
    if (-not $g4090Ok) { exit 2 }

    # Ray cluster (passive read-only)
    Write-Host "`n--- Ray Cluster ---" -ForegroundColor Yellow
    $rayScript = "import ray; ray.init(address='$($cfg.RayHeadIP):$($cfg.RayGCS)',ignore_reinit_error=True,logging_level='ERROR'); alive=len([n for n in ray.nodes() if n.get('Alive')]); print(f'ALIVE:{alive} GPU:{ray.cluster_resources().get(\"GPU\",0)}'); [print(f'NODE:{n[\"NodeName\"]} GPU:{n.get(\"Resources\",{}).get(\"GPU\",0)}') for n in ray.nodes() if n.get('Alive')]; ray.shutdown()"
    $rayResult = Invoke-4090 "python3 -c '$rayScript'" -T 20
    if ($rayResult.Ok()) {
        if ($rayResult.Stdout -match 'ALIVE:(\d+)') {
            [int]$alive = $Matches[1]; Write-Check 'Alive Nodes' $(if ($alive -ge 2) { 'PASS' } elseif ($alive -eq 1) { 'WARN' } else { 'FAIL' }) "$alive"
            if ($alive -lt 2) { $exitCode = 3 }
        }
    } else { Write-Check 'Ray' 'FAIL' $rayResult.Error; $exitCode = 3 }

    # GPU
    Write-Host "`n--- GPU (4090) ---" -ForegroundColor Yellow
    $gpu = Invoke-4090 'nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader' -T 10
    if ($gpu.Ok()) { $gpu.Stdout -split "`n" | ForEach-Object { Write-Host "  $_" } }

    # Ports
    Write-Host "`n--- Ports ---" -ForegroundColor Yellow
    $ports = Invoke-4090 "for p in $($cfg.IsaacSignal) $($cfg.VncPort) $($cfg.NovncPort) $($cfg.CdpPort); do ss -tlnp 2>/dev/null | grep -q \":`$p \" && echo \"`$p:OK\" || echo \"`$p:MISSING\"; done" -T 10
    foreach ($line in ($ports.Stdout -split "`n")) {
        if ($line -match '^(\d+):(\w+)') { Write-Check "Port $($Matches[1])" $(if ($Matches[2] -eq 'OK') { 'PASS' } else { 'FAIL' }) }
    }

    # WebRTC
    Write-Host "`n--- WebRTC ---" -ForegroundColor Yellow
    $stream = Invoke-4090 "pgrep -c isaacsim-webrtc 2>/dev/null||echo 0; grep -c 'Stream started.*success' $($cfg.LogDir)/webrtc-client.log 2>/dev/null||echo 0; ss -ulnp 2>/dev/null|grep -c ':$($cfg.IsaacStream) '" -T 10
    $sl = $stream.Stdout -split "`n"
    Write-Check 'Client' $(if ([int]$sl[0] -gt 0) { 'RUNNING' } else { 'STOPPED' })
    Write-Check 'Stream' $(if ([int]$sl[1] -gt 0) { 'PASS' } elseif ([int]$sl[0] -gt 0) { 'UNKNOWN' } else { 'FAIL' })
    Write-Check 'UDP' $(if ([int]$sl[2] -gt 0) { 'PASS' } else { $(if ([int]$sl[0] -gt 0) { 'WARN' } else { 'FAIL' }) })

    exit $exitCode
}

# ============================================================
# Verify (G4-02: passive by default, active only with --Mode active)
# ============================================================
function Invoke-Verify {
    Write-Host "`n=== Verification ($Mode) ===" -ForegroundColor Cyan
    $exitCode = 0

    if ($Mode -eq 'active') {
        Write-Host "ACTIVE MODE: Will run GPU tasks. Ensure no training is in progress." -ForegroundColor Yellow
        if (-not $Force) {
            Write-Host "Use -Force to confirm active verification." -ForegroundColor Red; exit 10
        }
    }

    # SSH
    $a800Ok = Test-SshOk { Invoke-A800 'echo OK' -T 10 }; $g4090Ok = Test-SshOk { Invoke-4090 'echo OK' -T 10 }
    Write-Check 'SSH A800' $(if ($a800Ok) { 'PASS' } else { 'FAIL' }); Write-Check 'SSH 4090' $(if ($g4090Ok) { 'PASS' } else { 'FAIL' })
    if (-not $g4090Ok) { exit 2 }

    # Passive: Ray cluster read-only + current state
    $rayAlive = Invoke-4090 "python3 -c 'import ray; ray.init(address=\"$($cfg.RayHeadIP):$($cfg.RayGCS)\",ignore_reinit_error=True,logging_level=\"ERROR\"); print(len([n for n in ray.nodes() if n.get(\"Alive\")])); ray.shutdown()'" -T 20
    $count = if ($rayAlive.Stdout -match '^\d+$') { [int]$rayAlive.Stdout.Trim() } else { 0 }
    Write-Check 'Ray nodes (2+)' $(if ($count -ge 2) { 'PASS' } else { 'FAIL' }) "$count"

    if ($Mode -eq 'active') {
        $verifyScript = Get-Content (Join-Path $ProjectDir 'linux\ray\verify-cluster.sh') -Raw
        $rayVerify = Send-4090Script -Script $verifyScript -Interpreter 'bash' -T 90
        if ($rayVerify.Ok()) { Write-Host $rayVerify.Stdout } else { Write-Check 'Ray GPU test' 'FAIL' $rayVerify.Error }
    }

    # Ports + WebRTC
    $portCheck = Invoke-4090 "ss -tlnp 2>/dev/null | awk '{print \$4}' | grep -oP ':\K\d+$'" -T 10
    $open = $portCheck.Stdout -split "`n"
    foreach ($p in @($cfg.VncPort, $cfg.NovncPort, $cfg.IsaacSignal)) { Write-Check "Port $p" $(if ($p -in $open) { 'PASS' } else { 'FAIL' }) }

    $tunnelActive = (netstat -ano 2>$null | Select-String "$($cfg.BrowserPort).*LISTEN") -ne $null
    Write-Check "Tunnel :$($cfg.BrowserPort)" $(if ($tunnelActive) { 'PASS' } else { 'FAIL' })

    exit $exitCode
}

# ============================================================
# Dispatch (G4-02: component-specific, not all-ray-or-nothing)
# ============================================================
$rayCmds = @{ start = 'start'; stop = 'stop'; status = 'status' }

switch ($Action) {
    'status' { Invoke-Status }
    'verify' { Invoke-Verify }
    'doctor' { Write-Host "Doctor: running combined status + verify"; Invoke-Status; if ($Mode -eq 'active') { Invoke-Verify } }
    'open-viewer' {
        $existing = netstat -ano 2>$null | Select-String "$($cfg.BrowserPort).*LISTEN"
        if (-not $existing) {
            Start-Process -FilePath 'ssh' -ArgumentList @('-NT', '-p', "$($cfg.GPU4090_Port)", '-L', "127.0.0.1:$($cfg.BrowserPort):127.0.0.1:$($cfg.NovncPort)", '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30', "$($cfg.GPU4090_User)@$($cfg.GPU4090_Host)") -WindowStyle Hidden
            Start-Sleep -Seconds 2
        }
        Start-Process "http://127.0.0.1:$($cfg.BrowserPort)/vnc.html?autoconnect=1&resize=remote"
    }
    'start' {
        switch ($Component) {
            'ray-head' { Invoke-A800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-head" -T 60 | Out-Null; Write-Host "Head start dispatched" }
            'ray-worker' { Invoke-A800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-worker" -T 60 | Out-Null; Write-Host "Worker start dispatched" }
            'tunnels' { Invoke-A800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-tunnels" -T 30 | Out-Null; Write-Host "Tunnels start dispatched" }
            'ray' { Invoke-A800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-head" -T 30 | Out-Null; Invoke-A800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-tunnels" -T 30 | Out-Null; Invoke-A800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-worker" -T 30 | Out-Null }
            'visualization' { Invoke-4090 "bash /home/zjf/ray-isaac-deploy/linux/visualization/start-visualization.sh 2>&1" -T 120 | ForEach-Object { Write-Host $_ } }
            'all' { Write-Host "Ray: use -Component ray/ray-head/ray-worker/tunnels separately"; Write-Host "Viz: use -Component visualization" }
        }
    }
    'stop' {
        switch ($Component) {
            'visualization' { Invoke-4090 "bash /home/zjf/ray-isaac-deploy/linux/visualization/stop-visualization.sh 2>&1" -T 60 | ForEach-Object { Write-Host $_ } }
            'ray' { if ($Force) { Invoke-A800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh stop-cluster" -T 60 | Out-Null } else { Write-Host "Ray stop requires -Force (affects running jobs)" -ForegroundColor Yellow; exit 10 } }
            default { Write-Host "Stop $Component: use -Component visualization or ray (with -Force)" -ForegroundColor Yellow }
        }
    }
    'install' {
        if ($DryRun) {
            Write-Host "`n=== Install Plan ($Profile) ===" -ForegroundColor Cyan
            Write-Host "Target: $($cfg.GPU4090_User)@$($cfg.GPU4090_Host):$($cfg.GPU4090_Port)" -ForegroundColor Gray
            Write-Host ""
            $checks = Invoke-4090 "echo '---SOFTWARE---'; python3 --version 2>&1; which nvidia-smi; ldconfig -p|grep -c nvidia-encode; ls /home/zjf/isaacsim/VERSION 2>/dev/null||echo ISAAC_MISSING; which Xvnc 2>/dev/null||echo XVNC_MISSING; /home/zjf/tigervnc/usr/bin/Xvnc -version 2>&1|head -1||echo TIGERVNC_MISSING; ls /home/zjf/noVNC-1.5.0/vnc.html 2>/dev/null||echo NOVNC_MISSING; which websockify 2>/dev/null||echo WS_MISSING; ls '/home/zjf/isaacsim-webrtc-streaming-client/opt/Isaac Sim WebRTC Streaming Client/isaacsim-webrtc-streaming-client' 2>/dev/null||echo CLIENT_MISSING; python3 -c 'import ray; print(ray.__version__)' 2>/dev/null||echo RAY_MISSING" -T 15
            Write-Host "Current state:"
            Write-Host $checks.Stdout
            Write-Host "`nActions needed:"
            if ($checks.Stdout -match 'ISAAC_MISSING') { Write-Host "  [NEED] Isaac Sim 6.2.0 (manual download + license)" -ForegroundColor Yellow }
            if ($checks.Stdout -match 'CLIENT_MISSING') { Write-Host "  [NEED] WebRTC Streaming Client 2.0.0 (NVIDIA download)" -ForegroundColor Yellow }
            if ($checks.Stdout -match 'TIGERVNC_MISSING') { Write-Host "  [NEED] TigerVNC 1.14.1 (user install)" -ForegroundColor Yellow }
            if ($checks.Stdout -match 'NOVNC_MISSING') { Write-Host "  [NEED] noVNC 1.5.0 (wget + extract)" -ForegroundColor Yellow }
            if ($checks.Stdout -match 'WS_MISSING') { Write-Host "  [NEED] websockify (pip install --user)" -ForegroundColor Yellow }
            Write-Host "`n  SSH keys must be configured for passwordless access."
            Write-Host "  GPU drivers must be pre-installed by container provider."
        } else { Write-Host "Install: use -DryRun first for dependency plan" -ForegroundColor Yellow }
    }
    'logs' { Write-Host "Logs: $($cfg.LogDir)" -ForegroundColor Cyan }
    'snapshot' { Write-Host "Baseline: baseline/working_baseline.json"; Invoke-Status }
    'configure' { Write-Host "Profile: $Profile" -ForegroundColor Cyan; $config | ConvertTo-Json -Depth 3 }
    default { Write-Host "UNSUPPORTED: $Action" -ForegroundColor Red; exit 99 }
}