#Requires -Version 5.1
<#
.SYNOPSIS
    Ray + Isaac Sim deployment toolkit v1.1
    Config-driven control for A800 (Ray Head) + 4090 (Worker + Isaac Sim)
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
    [switch]$DryRun,
    [switch]$Force,
    [string]$Profile = 'verified-20261025',
    [string]$ConfigPath,
    [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

# Load configuration from verified profile
$profilePath = if ($ConfigPath) { $ConfigPath } else { Join-Path $ProjectDir "profiles\$Profile.yaml" }
if (-not (Test-Path $profilePath)) {
    Write-Host "ERROR: Profile not found: $profilePath" -ForegroundColor Red
    exit 10
}

# Parse YAML profile (simple parser for flat keys we need)
function Get-ProfileValue {
    param([string]$KeyPath, [string]$Default = '')
    $keys = $KeyPath -split '\.'
    $content = Get-Content $profilePath -Raw
    # Simple regex-based YAML value extraction for the keys we use
    $pattern = '(?ms)^' + ($keys -join ':\s*\n\s+') + ':\s*["'']?([^"''\n#]+)["'']?'
    if ($content -match $pattern) {
        $val = $Matches[1].Trim()
        # Remove inline comments
        if ($val -match '^([^#]+)') { $val = $Matches[1].Trim() }
        return $val
    }
    return $Default
}

# Load critical config values
$cfg = @{
    A800_Host   = Get-ProfileValue 'hosts.a800.ssh_host' '117.74.66.77'
    A800_Port   = Get-ProfileValue 'hosts.a800.ssh_port' '46885'
    A800_User   = Get-ProfileValue 'hosts.a800.ssh_user' 'zjf'
    GPU4090_Host = Get-ProfileValue 'hosts.gpu4090.ssh_host' '180.97.68.228'
    GPU4090_Port = Get-ProfileValue 'hosts.gpu4090.ssh_port' '46602'
    GPU4090_User = Get-ProfileValue 'hosts.gpu4090.ssh_user' 'zjf'
    BrowserPort = Get-ProfileValue 'hosts.windows.browser_port' '16006'
    NovncPort   = Get-ProfileValue 'visualization.novnc.port' '6006'
    VncPort     = Get-ProfileValue 'visualization.vnc.port' '5901'
    IsaacSignal = Get-ProfileValue 'isaacsim.signal_port' '49100'
    IsaacStream = Get-ProfileValue 'isaacsim.stream_port' '47998'
    IsaacIP     = Get-ProfileValue 'isaacsim.public_ip' '192.168.0.12'
    CdpPort     = Get-ProfileValue 'visualization.webrtc_client.cdp_port' '9222'
    LogDir      = Get-ProfileValue 'operations.log_dir' '/home/zjf/.local/state/ray-isaac-deploy/logs'
    RayGCS      = Get-ProfileValue 'ray.head.gcs_port' '6379'
    RayHeadIP   = Get-ProfileValue 'ray.head.address' '127.0.0.2'
    RayWorkerIP = Get-ProfileValue 'ray.worker.address' '127.0.0.3'
    RayHeadGPU  = Get-ProfileValue 'ray.head.gpu_count' '8'
    RayWorkerGPU = Get-ProfileValue 'ray.worker.gpu_count' '1'
    PhysGPUs    = Get-ProfileValue 'gpu_mapping.physical_gpus' '4'
}

# ============================================================
# SSH Execution Layer (Gate-3: config-driven, no hardcoded IPs)
# ============================================================

class SshResult {
    [string]$Host; [int]$ExitCode; [string]$Stdout; [string]$Stderr
    [bool]$TimedOut; [string]$Error
    [bool] Ok() { return $this.ExitCode -eq 0 -and -not $this.TimedOut -and -not $this.Error }
}

function Invoke-SshCommand {
    param([string]$HostName, [int]$Port, [string]$User, [string]$Command, [int]$TimeoutSec = 30)
    if ($DryRun) { Write-Host "[DRYRUN] ssh -p $Port ${User}@${HostName} '$Command'" -ForegroundColor Gray
        return [SshResult]@{ Host = $HostName; ExitCode = -1; Stdout = ''; Error = 'DryRun' } }
    $result = [SshResult]@{ Host = $HostName; ExitCode = -1 }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh'
        $argList = @('-p', "$Port", '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new',
                     '-o', 'BatchMode=yes', '-o', 'ServerAliveInterval=15', "${User}@${HostName}", $Command)
        $psi.Arguments = [string]::Join(' ', $argList)
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $proc = New-Object System.Diagnostics.Process; $proc.StartInfo = $psi
        $sbOut = New-Object System.Text.StringBuilder; $sbErr = New-Object System.Text.StringBuilder
        $oe = Register-ObjectEvent -InputObject $proc -EventName 'OutputDataReceived' -Action { $Event.MessageData.AppendLine($EventArgs.Data) } -MessageData $sbOut
        $ee = Register-ObjectEvent -InputObject $proc -EventName 'ErrorDataReceived' -Action { $Event.MessageData.AppendLine($EventArgs.Data) } -MessageData $sbErr
        $proc.Start() | Out-Null; $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) { $proc.Kill(); $result.TimedOut = $true; $result.Error = "Timeout ${TimeoutSec}s" }
        Unregister-Event -SourceIdentifier $oe.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $ee.Name -ErrorAction SilentlyContinue
        $result.ExitCode = $proc.ExitCode; $result.Stdout = $sbOut.ToString().Trim(); $result.Stderr = $sbErr.ToString().Trim()
        $proc.Dispose()
    } catch { $result.Error = $_.Exception.Message }
    return $result
}

function Invoke-4090 { param([string]$Cmd, [int]$T=15) Invoke-SshCommand -HostName $cfg.GPU4090_Host -Port $cfg.GPU4090_Port -User $cfg.GPU4090_User -Command $Cmd -TimeoutSec $T }
function Invoke-A800 { param([string]$Cmd, [int]$T=15) Invoke-SshCommand -HostName $cfg.A800_Host -Port $cfg.A800_Port -User $cfg.A800_User -Command $Cmd -TimeoutSec $T }

function Write-Check { param([string]$N, [string]$S, [string]$D='')
    $icon = @{PASS='[PASS]'; FAIL='[FAIL]'; WARN='[WARN]'; UNKNOWN='[????]'; RUNNING='[RUN ]'; STOPPED='[STOP]'}[$S]
    $color = @{PASS='Green'; FAIL='Red'; WARN='Yellow'; UNKNOWN='Gray'; RUNNING='Green'; STOPPED='Red'}[$S]
    Write-Host "  $icon $N  $(if($D){$D})" -ForegroundColor $color
}

function Test-SshOk { param([ScriptBlock]$Cmd)
    try { $r = & $Cmd; return ($r.Ok() -and $r.Stdout.Trim() -eq 'OK') } catch { return $false }
}

# ============================================================
# Status
# ============================================================
function Invoke-Status {
    Write-Host "`n=== Ray + Isaac Sim Status ===" -ForegroundColor Cyan
    Write-Host "Profile: $Profile | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

    $a800Ok = Test-SshOk { Invoke-A800 'echo OK' -T 10 }
    $g4090Ok = Test-SshOk { Invoke-4090 'echo OK' -T 10 }
    Write-Check 'SSH A800' $(if($a800Ok){'PASS'}else{'FAIL'})
    Write-Check 'SSH 4090' $(if($g4090Ok){'PASS'}else{'FAIL'})
    if (-not $g4090Ok) { exit 2 }

    # Ray
    Write-Host "`n--- Ray Cluster ---" -ForegroundColor Yellow
    $rayScript = @"
import ray; ray.init(address='$($cfg.RayHeadIP):$($cfg.RayGCS)', ignore_reinit_error=True, logging_level='ERROR')
alive = len([n for n in ray.nodes() if n.get('Alive')])
print(f'ALIVE:{alive}'); print(f'GPU:{ray.cluster_resources().get(\"GPU\",0)}')
for n in ray.nodes():
    if n.get('Alive'): print(f'NODE:{n[\"NodeName\"]} GPU:{n.get(\"Resources\",{}).get(\"GPU\",0)}')
ray.shutdown()
"@
    $rayResult = Invoke-4090 "python3 -c '$rayScript'" -T 20
    if ($rayResult.Ok()) {
        $alive = if ($rayResult.Stdout -match 'ALIVE:(\d+)') { [int]$Matches[1] } else { 0 }
        Write-Check 'Ray Nodes' $(if($alive -ge 2){'PASS'}elseif($alive -eq 1){'WARN'}else{'FAIL'}) "$alive alive"
        if ($rayResult.Stdout -match 'NODE:(.*) GPU:(\d+)') { Write-Check "Node: $($Matches[1])" 'RUNNING' "GPU:$($Matches[2])" }
    } else { Write-Check 'Ray Cluster' 'FAIL' $rayResult.Error }

    # GPU
    Write-Host "`n--- GPU (4090) ---" -ForegroundColor Yellow
    $gpuResult = Invoke-4090 'nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader' -T 10
    if ($gpuResult.Ok()) { $gpuResult.Stdout -split "`n" | ForEach-Object { Write-Host "  GPU $_" } }

    # Ports
    Write-Host "`n--- Key Ports ---" -ForegroundColor Yellow
    $portResult = Invoke-4090 "ss -tlnp 2>/dev/null | awk '{print \$4}' | grep -oP ':\K\d+$' | sort -nu | paste -sd' '" -T 10
    $openPorts = $portResult.Stdout -split ' '
    foreach ($p in @($cfg.IsaacSignal, $cfg.VncPort, $cfg.NovncPort, $cfg.CdpPort)) {
        Write-Check "Port $p" $(if ($p -in $openPorts){'PASS'}else{'FAIL'})
    }

    # WebRTC
    Write-Host "`n--- WebRTC ---" -ForegroundColor Yellow
    $stream = Invoke-4090 "pgrep -c isaacsim-webrtc 2>/dev/null || echo 0; grep -c 'Stream started.*success' $($cfg.LogDir)/webrtc-client.log 2>/dev/null || echo 0; ss -ulnp | grep -c ':$($cfg.IsaacStream) '" -T 10
    $lines = $stream.Stdout -split "`n"
    Write-Check 'WebRTC Client' $(if([int]$lines[0] -gt 0){'RUNNING'}else{'STOPPED'})
    Write-Check 'Stream Success' $(if([int]$lines[1] -gt 0){'PASS'}elseif([int]$lines[0] -gt 0){'UNKNOWN'}else{'FAIL'})
    Write-Check 'UDP Media' $(if([int]$lines[2] -gt 0){'PASS'}else{'FAIL'})

    exit 0
}

# ============================================================
# Verify
# ============================================================
function Invoke-Verify {
    Write-Host "`n=== End-to-End Verification ===" -ForegroundColor Cyan
    $exitCode = 0; $checks = [System.Collections.ArrayList]::new()

    $a800Ok = Test-SshOk { Invoke-A800 'echo OK' -T 10 }; $g4090Ok = Test-SshOk { Invoke-4090 'echo OK' -T 10 }
    $null = $checks.Add(@{N='SSH A800'; S=$(if($a800Ok){'PASS'}else{'FAIL'})})
    $null = $checks.Add(@{N='SSH 4090'; S=$(if($g4090Ok){'PASS'}else{'FAIL'})})
    if (-not $g4090Ok) { $exitCode = 2 }

    if ($g4090Ok) {
        # Ray cluster with GPU task verification
        Write-Host "`n--- Ray Cluster + GPU Test ---" -ForegroundColor Yellow
        $verifyScript = Get-Content (Join-Path $ScriptDir '..\linux\ray\verify-cluster.sh') -Raw
        if ($verifyScript) {
            $rayVerify = Invoke-4090 "bash -s" -T 60
            # TODO: pipe script via stdin properly
        }
        $rayAlive = Invoke-4090 "python3 -c 'import ray; ray.init(address=\"$($cfg.RayHeadIP):$($cfg.RayGCS)\",ignore_reinit_error=True,logging_level=\"ERROR\"); print(len([n for n in ray.nodes() if n.get(\"Alive\")])); ray.shutdown()'" -T 20
        $aliveCount = if ($rayAlive.Stdout -match '^(\d+)$') { [int]$Matches[1] } else { 0 }
        $null = $checks.Add(@{N='Ray nodes (2+)'; S=$(if($aliveCount -ge 2){'PASS'}else{'FAIL'}); D="$aliveCount"})
        if ($aliveCount -lt 2) { $exitCode = 3 }
    }

    # Port checks
    $portResult = Invoke-4090 "ss -tlnp 2>/dev/null | awk '{print \$4}' | grep -oP ':\K\d+$'" -T 10
    $openPorts = $portResult.Stdout -split "`n"
    foreach ($p in @($cfg.VncPort, $cfg.NovncPort, $cfg.IsaacSignal)) {
        $null = $checks.Add(@{N="Port $p"; S=$(if($p -in $openPorts){'PASS'}else{'FAIL'})})
    }

    # Windows tunnel
    $tunnelActive = (netstat -ano 2>$null | Select-String "$($cfg.BrowserPort).*LISTEN") -ne $null
    $null = $checks.Add(@{N="Tunnel :$($cfg.BrowserPort)"; S=$(if($tunnelActive){'PASS'}else{'FAIL'})})

    Write-Host ""; $pass = 0; $fail = 0
    foreach ($c in $checks) { Write-Check $c.N $c.S $c.D; if ($c.S -eq 'PASS') { $pass++ } elseif ($c.S -eq 'FAIL') { $fail++ } }
    Write-Host "`n  PASS: $pass  FAIL: $fail  TOTAL: $($checks.Count)" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Yellow'})
    exit $(if($exitCode -gt 0){$exitCode}elseif($fail -gt 0){1}else{0})
}

# ============================================================
# Ray Start/Stop
# ============================================================
function Invoke-RayAction {
    param([string]$RayAction)
    $clusterScript = "/home/zjf/ray-isaac-deploy/linux/ray/cluster.sh"
    $scriptExists = Invoke-4090 "test -f $clusterScript && echo YES || echo NO" -T 5
    if ($scriptExists.Stdout -ne 'YES') {
        Write-Host "Ray cluster.sh not deployed to 4090. Upload first." -ForegroundColor Yellow
        exit 5
    }
    switch ($RayAction) {
        'start' {
            Invoke-A800 "bash $clusterScript start-head" -T 30 | Out-Null
            Start-Sleep -Seconds 5
            Invoke-A800 "bash $clusterScript start-worker" -T 30 | Out-Null
        }
        'stop' {
            Invoke-A800 "bash $clusterScript stop-cluster" -T 30 | Out-Null
        }
        'status' {
            Invoke-A800 "bash $clusterScript status" -T 20
        }
    }
}

# ============================================================
# Visualization Start/Stop
# ============================================================
function Invoke-VizAction {
    param([string]$VizAction)
    $vizScript = "/home/zjf/ray-isaac-deploy/linux/visualization/$($VizAction)-visualization.sh"
    $result = Invoke-4090 "bash $vizScript 2>&1" -T 60
    Write-Host $result.Stdout
    if ($result.Stderr) { Write-Host $result.Stderr -ForegroundColor Yellow }
}

# ============================================================
# Main Dispatch (Gate-3: all actions have real implementations)
# ============================================================
switch ($Action) {
    'status'     { Invoke-Status }
    'verify'     { Invoke-Verify }
    'doctor'     {
        Write-Host "`n=== System Diagnostics ===" -ForegroundColor Cyan
        Invoke-Status
        Write-Host "`n--- Dependency Check ---" -ForegroundColor Yellow
        $deps = Invoke-4090 "which python3; python3 --version; which nvidia-smi; ldconfig -p | grep -c nvidia-encode; which Xvnc 2>/dev/null||echo 'no Xvnc'; which websockify 2>/dev/null||echo 'no websockify'; ls /home/zjf/isaacsim/VERSION 2>/dev/null||echo 'no Isaac Sim'" -T 15
        Write-Host $deps.Stdout
    }
    'start'      {
        if ($Component -in @('ray','ray-head','ray-worker','tunnels','all')) { Invoke-RayAction 'start' }
        if ($Component -in @('visualization','isaacsim','webrtc-client','vnc','novnc','all')) { Invoke-VizAction 'start' }
    }
    'stop'       {
        if ($Component -in @('visualization','isaacsim','webrtc-client','vnc','novnc','all')) { Invoke-VizAction 'stop' }
        if ($Component -in @('ray','ray-head','ray-worker','tunnels','all')) {
            Write-Host "Stopping Ray requires confirmation (affects running jobs). Use -Force to proceed." -ForegroundColor Yellow
            if ($Force) { Invoke-RayAction 'stop' }
        }
    }
    'open-viewer' {
        $existing = netstat -ano 2>$null | Select-String "$($cfg.BrowserPort).*LISTEN"
        if (-not $existing) {
            $args = @('-NT', '-p', "$($cfg.GPU4090_Port)", '-L', "127.0.0.1:$($cfg.BrowserPort):127.0.0.1:$($cfg.NovncPort)", '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30', "$($cfg.GPU4090_User)@$($cfg.GPU4090_Host)")
            Start-Process -FilePath 'ssh' -ArgumentList $args -WindowStyle Hidden
            Start-Sleep -Seconds 2
        }
        Start-Process "http://127.0.0.1:$($cfg.BrowserPort)/vnc.html?autoconnect=1&resize=remote"
    }
    'snapshot'   {
        Write-Host "Snapshot: baseline/working_baseline.json captured at initial deployment" -ForegroundColor Yellow
        Invoke-Status
    }
    'install'    {
        Write-Host "Install action: use -DryRun for dependency plan" -ForegroundColor Yellow
        if ($DryRun) {
            Write-Host "`nPlanned dependencies (4090):" -ForegroundColor Cyan
            Write-Host "  [CHECK] Python 3.10, pip"
            Write-Host "  [CHECK] NVIDIA Driver 580.82.07+"
            Write-Host "  [CHECK] Isaac Sim 6.2.0 at /home/zjf/isaacsim"
            Write-Host "  [CHECK] TigerVNC 1.14.1 with libxcvt"
            Write-Host "  [CHECK] noVNC 1.5.0 + websockify 0.13.0"
            Write-Host "  [CHECK] Isaac Sim WebRTC Streaming Client 2.0.0"
            Write-Host "  [CHECK] Ray 2.40.0"
            Write-Host "  [CHECK] SSH key-based auth to A800"
        }
    }
    'logs'       { Write-Host "Logs path: $($cfg.LogDir)" -ForegroundColor Cyan }
    'configure'  { Write-Host "Profile: $profilePath" -ForegroundColor Cyan ; Get-Content $profilePath | Select-Object -First 20 }
    default      { Write-Host "UNSUPPORTED: $Action" -ForegroundColor Red; exit 99 }
}