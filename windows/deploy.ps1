#Requires -Version 5.1
<#
.SYNOPSIS
    Ray + Isaac Sim deployment toolkit v1.1
.DESCRIPTION
    Unified control for Ray 2.40.0 cluster (A800 + 4090) and
    Isaac Sim 6.2.0 visualization via SSH tunnels + noVNC.
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('doctor', 'status', 'start', 'stop', 'restart', 'verify',
                 'logs', 'open-viewer', 'snapshot', 'configure', 'install')]
    [string]$Action = 'status',

    [Parameter(Position = 1)]
    [ValidateSet('ray', 'ray-head', 'ray-worker', 'visualization', 'isaacsim',
                 'webrtc-client', 'vnc', 'novnc', 'all')]
    [string]$Component = 'all',

    [switch]$DryRun,
    [switch]$Force,
    [string]$Profile = 'verified-20261025',
    [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

# ============================================================
# SSH Execution Layer (M1-01: safe, structured, traceable)
# ============================================================

class SshResult {
    [string]$Host
    [int]$ExitCode
    [string]$Stdout
    [string]$Stderr
    [bool]$TimedOut
    [string]$Error
    [bool]$Ok() { return $this.ExitCode -eq 0 -and -not $this.TimedOut -and -not $this.Error }
}

class SshTarget {
    [string]$Name
    [string]$HostName
    [int]$Port
    [string]$User
    [string]$KeyPath

    SshTarget([string]$name, [string]$hostName, [int]$port, [string]$user) {
        $this.Name = $name
        $this.HostName = $hostName
        $this.Port = $port
        $this.User = $user
    }

    [string] ToString() {
        return "-p $($this.Port) $($this.User)@$($this.HostName)"
    }
}

# Verified working targets (from profile)
$Target4090 = [SshTarget]::new('gpu4090', '180.97.68.228', 46602, 'zjf')
$TargetA800 = [SshTarget]::new('a800', '117.74.66.77', 46885, 'zjf')

function Invoke-SshCommand {
    <#
    .SYNOPSIS
        Safely execute a command on a remote machine via SSH.
        Returns structured SshResult with exit code, stdout, stderr.
        Never uses Invoke-Expression.
    #>
    param(
        [SshTarget]$Target,
        [string]$Command,
        [int]$TimeoutSec = 30,
        [switch]$CaptureStderr
    )

    if ($DryRun) {
        Write-Host "[DRYRUN] ssh $($Target.ToString()) '$Command'" -ForegroundColor Gray
        return [SshResult]@{ Host = $Target.Name; ExitCode = -1; Stdout = ''; Stderr = ''; TimedOut = $false; Error = 'DryRun' }
    }

    $result = [SshResult]@{ Host = $Target.Name; ExitCode = -1; Stdout = ''; Stderr = ''; TimedOut = $false; Error = '' }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh'
        $psi.Arguments = @(
            '-p', $Target.Port,
            '-o', 'ConnectTimeout=10',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'BatchMode=yes',
            '-o', 'ServerAliveInterval=15',
            "$($Target.User)@$($Target.HostName)",
            $Command
        ) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $stdoutBuilder = New-Object System.Text.StringBuilder
        $stderrBuilder = New-Object System.Text.StringBuilder

        $outEvent = Register-ObjectEvent -InputObject $proc -EventName 'OutputDataReceived' -Action {
            $Event.MessageData.AppendLine($EventArgs.Data)
        } -MessageData $stdoutBuilder

        $errEvent = Register-ObjectEvent -InputObject $proc -EventName 'ErrorDataReceived' -Action {
            $Event.MessageData.AppendLine($EventArgs.Data)
        } -MessageData $stderrBuilder

        $proc.Start() | Out-Null
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $proc.Kill()
            $result.TimedOut = $true
            $result.Error = "Command timed out after ${TimeoutSec}s"
        }

        Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue

        $result.ExitCode = $proc.ExitCode
        $result.Stdout = $stdoutBuilder.ToString().Trim()
        $result.Stderr = $stderrBuilder.ToString().Trim()
        $proc.Dispose()
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Send-SshScript {
    <#
    .SYNOPSIS
        Send a script to a remote machine via SSH stdin.
        Avoids nested quote issues for complex Python/shell scripts.
    #>
    param(
        [SshTarget]$Target,
        [string]$ScriptContent,
        [string]$Interpreter = 'bash',
        [int]$TimeoutSec = 30
    )

    if ($DryRun) {
        $preview = $ScriptContent.Substring(0, [Math]::Min(200, $ScriptContent.Length))
        Write-Host "[DRYRUN] ssh $($Target.ToString()) '$Interpreter -s' << '$preview...'" -ForegroundColor Gray
        return [SshResult]@{ Host = $Target.Name; ExitCode = -1; Stdout = ''; Stderr = ''; TimedOut = $false; Error = 'DryRun' }
    }

    $result = [SshResult]@{ Host = $Target.Name; ExitCode = -1; Stdout = ''; Stderr = ''; TimedOut = $false; Error = '' }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh'
        $psi.Arguments = @(
            '-p', $Target.Port,
            '-o', 'ConnectTimeout=10',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'BatchMode=yes',
            '-o', 'ServerAliveInterval=15',
            "$($Target.User)@$($Target.HostName)",
            "$Interpreter -s"
        ) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $stdoutBuilder = New-Object System.Text.StringBuilder
        $stderrBuilder = New-Object System.Text.StringBuilder

        $outEvent = Register-ObjectEvent -InputObject $proc -EventName 'OutputDataReceived' -Action {
            $Event.MessageData.AppendLine($EventArgs.Data)
        } -MessageData $stdoutBuilder

        $errEvent = Register-ObjectEvent -InputObject $proc -EventName 'ErrorDataReceived' -Action {
            $Event.MessageData.AppendLine($EventArgs.Data)
        } -MessageData $stderrBuilder

        $proc.Start() | Out-Null
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        # Send script via stdin
        $proc.StandardInput.WriteLine($ScriptContent)
        $proc.StandardInput.Close()

        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $proc.Kill()
            $result.TimedOut = $true
            $result.Error = "Script timed out after ${TimeoutSec}s"
        }

        Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue

        $result.ExitCode = $proc.ExitCode
        $result.Stdout = $stdoutBuilder.ToString().Trim()
        $result.Stderr = $stderrBuilder.ToString().Trim()
        $proc.Dispose()
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Invoke-SshTest {
    <#
    .SYNOPSIS
        Quick connectivity test - returns $true if SSH works.
    #>
    param([SshTarget]$Target, [int]$TimeoutSec = 10)
    $r = Invoke-SshCommand -Target $Target -Command 'echo OK' -TimeoutSec $TimeoutSec
    return ($r.Ok() -and $r.Stdout.Trim() -eq 'OK')
}

# ============================================================
# Structured Output Helpers
# ============================================================

function Write-StatusLine {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $icon = switch ($Status) {
        'PASS'    { '  [PASS]' }
        'FAIL'    { '  [FAIL]' }
        'WARN'    { '  [WARN]' }
        'UNKNOWN' { '  [????]' }
        'RUNNING' { '  [RUN ]' }
        'STOPPED' { '  [STOP]' }
        default   { '  [----]' }
    }
    $color = if ($Status -in @('PASS', 'RUNNING')) { 'Green' }
             elseif ($Status -in @('FAIL', 'STOPPED')) { 'Red' }
             elseif ($Status -eq 'WARN') { 'Yellow' }
             else { 'Gray' }
    $line = "$icon $Name"
    if ($Detail) { $line += "  ($Detail)" }
    Write-Host $line -ForegroundColor $color
}

# ============================================================
# Status Action
# ============================================================

function Invoke-StatusAction {
    Write-Host "`n=== Ray + Isaac Sim Status ===" -ForegroundColor Cyan
    Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

    # SSH connectivity
    Write-Host "`n--- SSH Connectivity ---" -ForegroundColor Yellow
    $a800Ok = Invoke-SshTest -Target $TargetA800
    $g4090Ok = Invoke-SshTest -Target $Target4090
    Write-StatusLine 'A800'  $(if ($a800Ok) { 'PASS' } else { 'FAIL' })
    Write-StatusLine '4090'  $(if ($g4090Ok) { 'PASS' } else { 'FAIL' })

    if (-not $g4090Ok) {
        Write-Host "`nCannot proceed - 4090 unreachable" -ForegroundColor Red
        exit 1
    }

    # Ray cluster
    Write-Host "`n--- Ray Cluster ---" -ForegroundColor Yellow
    $rayScript = @'
import ray, sys
try:
    ray.init(address="127.0.0.2:6379", ignore_reinit_error=True, logging_level="ERROR")
    res = ray.cluster_resources()
    alive = len([n for n in ray.nodes() if n.get("Alive")])
    gpu = res.get("GPU", 0)
    print(f"ALIVE_NODES:{alive}")
    print(f"TOTAL_GPU:{gpu}")
    for n in ray.nodes():
        if n.get("Alive"):
            name = n.get("NodeName", "?")
            rgpu = n.get("Resources", {}).get("GPU", 0)
            print(f"NODE:{name} GPU:{rgpu}")
    ray.shutdown()
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)
'@
    $rayResult = Send-SshScript -Target $Target4090 -ScriptContent $rayScript -Interpreter 'python3' -TimeoutSec 20
    if ($rayResult.Ok()) {
        $aliveNodes = 0
        foreach ($line in ($rayResult.Stdout -split "`n")) {
            if ($line -match 'ALIVE_NODES:(\d+)') { $aliveNodes = [int]$Matches[1] }
            if ($line -match 'NODE:(.*) GPU:(\d+)') { Write-StatusLine "Ray Node: $($Matches[1])" 'RUNNING' "GPU:$($Matches[2])" }
            if ($line -match 'TOTAL_GPU:(\d+)') { Write-StatusLine 'Total GPU' 'PASS' "$($Matches[1])" }
        }
        if ($aliveNodes -lt 2) { Write-StatusLine 'Cluster Health' 'WARN' "Only $aliveNodes node(s) alive" }
        else { Write-StatusLine 'Cluster Health' 'PASS' "$aliveNodes nodes" }
    } else {
        Write-StatusLine 'Ray Cluster' 'FAIL' $rayResult.Error
    }

    # GPU
    Write-Host "`n--- GPU (4090) ---" -ForegroundColor Yellow
    $gpuResult = Invoke-SshCommand -Target $Target4090 -Command 'nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader' -TimeoutSec 10
    if ($gpuResult.Ok()) {
        foreach ($line in ($gpuResult.Stdout -split "`n")) {
            Write-Host "  GPU $line"
        }
    }

    # Key ports
    Write-Host "`n--- Key Ports (4090) ---" -ForegroundColor Yellow
    $portResult = Invoke-SshCommand -Target $Target4090 -Command 'ss -tlnp 2>/dev/null | grep -E "49100|5901|6006|9222|23002|23003" | awk "{print \$4}" | sed "s/.*://" | sort -nu' -TimeoutSec 10
    if ($portResult.Ok()) {
        $expectedPorts = @(49100, 5901, 6006, 9222, 23002, 23003)
        foreach ($p in $expectedPorts) {
            $found = $portResult.Stdout -match "\b$p\b"
            Write-StatusLine "Port $p" $(if ($found) { 'PASS' } else { 'FAIL' })
        }
    }

    # WebRTC stream
    Write-Host "`n--- WebRTC Stream ---" -ForegroundColor Yellow
    $streamResult = Invoke-SshCommand -Target $Target4090 -Command 'grep "Stream started.*success" /tmp/isaacsim_logs/webrtc-client.log 2>/dev/null | tail -1; pgrep -c isaacsim-webrtc 2>/dev/null || echo 0' -TimeoutSec 10
    Write-StatusLine 'WebRTC Client' $(if ([int]($streamResult.Stdout -split "`n")[-1] -gt 0) { 'RUNNING' } else { 'STOPPED' })
    if ($streamResult.Stdout -match 'Stream started.*success') {
        Write-StatusLine 'Stream Status' 'PASS' 'Last success found'
    } else {
        Write-StatusLine 'Stream Status' 'UNKNOWN' 'No success entry in log'
    }

    exit 0
}

# ============================================================
# Verify Action
# ============================================================

function Invoke-VerifyAction {
    Write-Host "`n=== End-to-End Verification ===" -ForegroundColor Cyan
    $checks = [System.Collections.ArrayList]::new()
    $exitCode = 0

    # SSH
    $a800Ssh = Invoke-SshTest -Target $TargetA800
    $g4090Ssh = Invoke-SshTest -Target $Target4090
    [void]$checks.Add(@{ Layer = 'SSH'; Name = 'A800 reachable'; Status = $(if ($a800Ssh) { 'PASS' } else { 'FAIL' }) })
    [void]$checks.Add(@{ Layer = 'SSH'; Name = '4090 reachable'; Status = $(if ($g4090Ssh) { 'PASS' } else { 'FAIL' }) })

    if (-not $g4090Ssh) { $exitCode = 2 }

    # Ray
    if ($g4090Ssh) {
        $rayScript = @'
import ray, sys
ray.init(address="127.0.0.2:6379", ignore_reinit_error=True, logging_level="ERROR")
alive = len([n for n in ray.nodes() if n.get("Alive")])
print(f"ALIVE:{alive}")
print(f"GPU:{ray.cluster_resources().get('GPU', 0)}")
ray.shutdown()
'@
        $rayResult = Send-SshScript -Target $Target4090 -ScriptContent $rayScript -Interpreter 'python3' -TimeoutSec 20
        $aliveOk = ($rayResult.Ok() -and ($rayResult.Stdout -match 'ALIVE:2'))
        $gpuOk = ($rayResult.Ok() -and ($rayResult.Stdout -match 'GPU:9'))
        [void]$checks.Add(@{ Layer = 'Ray'; Name = '2 nodes alive'; Status = $(if ($aliveOk) { 'PASS' } else { 'FAIL' }) })
        [void]$checks.Add(@{ Layer = 'Ray'; Name = 'GPU resources (9)'; Status = $(if ($gpuOk) { 'PASS' } else { 'FAIL' }) })
        if (-not $aliveOk) { $exitCode = 3 }
    }

    # Visualization layers (4090 only)
    if ($g4090Ssh) {
        $portCheck = Invoke-SshCommand -Target $Target4090 -Command 'for p in 5901 6006 49100 9222; do ss -tlnp | grep -q ":$p " && echo "PORT_${p}:OK" || echo "PORT_${p}:MISSING"; done' -TimeoutSec 10
        $webrtcCheck = Invoke-SshCommand -Target $Target4090 -Command 'pgrep -c isaacsim-webrtc 2>/dev/null || echo 0; grep -c "Stream started.*success" /tmp/isaacsim_logs/webrtc-client.log 2>/dev/null || echo 0; ss -ulnp | grep -c ":47998 " || echo 0' -TimeoutSec 10

        $ports = @{}
        foreach ($m in ([regex]::Matches($portCheck.Stdout, 'PORT_(\d+):(\w+)'))) {
            $ports[$m.Groups[1].Value] = ($m.Groups[2].Value -eq 'OK')
        }
        [void]$checks.Add(@{ Layer = 'Viz'; Name = 'VNC :5901'; Status = $(if ($ports['5901']) { 'PASS' } else { 'FAIL' }) })
        [void]$checks.Add(@{ Layer = 'Viz'; Name = 'noVNC :6006'; Status = $(if ($ports['6006']) { 'PASS' } else { 'FAIL' }) })
        [void]$checks.Add(@{ Layer = 'Viz'; Name = 'IsaacSim :49100'; Status = $(if ($ports['49100']) { 'PASS' } else { 'FAIL' }) })

        $wrLines = $webrtcCheck.Stdout -split "`n"
        $clientRunning = [int]$wrLines[0] -gt 0
        $streamSuccess = [int]$wrLines[1] -gt 0
        $udpBound = [int]$wrLines[2] -gt 0
        [void]$checks.Add(@{ Layer = 'Viz'; Name = 'WebRTC Client'; Status = $(if ($clientRunning) { 'PASS' } else { 'FAIL' }) })
        [void]$checks.Add(@{ Layer = 'Viz'; Name = 'WebRTC Stream'; Status = $(if ($streamSuccess) { 'PASS' } else { $(if ($clientRunning) { 'UNKNOWN' } else { 'FAIL' }) }) })
        [void]$checks.Add(@{ Layer = 'Viz'; Name = 'UDP 47998'; Status = $(if ($udpBound) { 'PASS' } else { $(if ($streamSuccess) { 'WARN' } else { 'FAIL' }) }) })

        if (-not $clientRunning) { $exitCode = 4 }
    }

    # Windows tunnel
    $tunnelActive = (netstat -ano 2>$null | Select-String '16006.*LISTEN') -ne $null
    [void]$checks.Add(@{ Layer = 'Windows'; Name = 'SSH Tunnel :16006'; Status = $(if ($tunnelActive) { 'PASS' } else { 'FAIL' }) })

    # Report
    Write-Host ""
    $passCount = 0
    $failCount = 0
    foreach ($c in $checks) {
        Write-StatusLine "$($c.Layer): $($c.Name)" $c.Status
        if ($c.Status -eq 'PASS') { $passCount++ }
        elseif ($c.Status -eq 'FAIL') { $failCount++ }
    }
    Write-Host "`n  PASS: $passCount  FAIL: $failCount  UNKNOWN: $($checks.Count - $passCount - $failCount)" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })

    exit $exitCode
}

# ============================================================
# Main Dispatch
# ============================================================

switch ($Action) {
    'status'     { Invoke-StatusAction }
    'verify'     { Invoke-VerifyAction }
    'doctor'     {
        Write-Host "Doctor: Run 'status' and 'verify' for full diagnostics" -ForegroundColor Yellow
        Invoke-StatusAction
    }
    'open-viewer' {
        Write-Host "Opening Isaac Sim viewer..." -ForegroundColor Cyan
        $existing = netstat -ano 2>$null | Select-String '16006.*LISTEN'
        if (-not $existing) {
            Start-Process -FilePath 'ssh' -ArgumentList @(
                '-NT', '-p', '46602',
                '-L', '127.0.0.1:16006:127.0.0.1:6006',
                '-o', 'ExitOnForwardFailure=yes',
                '-o', 'ServerAliveInterval=30',
                'zjf@180.97.68.228'
            ) -WindowStyle Hidden
            Start-Sleep -Seconds 2
        }
        Start-Process 'http://127.0.0.1:16006/vnc.html?autoconnect=1&resize=remote'
    }
    default {
        Write-Host "Action '$Action': use status, verify, or open-viewer" -ForegroundColor Yellow
        Write-Host "Full start/stop moved to Linux modules (see linux/visualization/)" -ForegroundColor Gray
    }
}