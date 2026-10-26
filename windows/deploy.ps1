#Requires -Version 5.1
<#
.SYNOPSIS Ray + Isaac Sim deployment toolkit v1.1.1
.DESCRIPTION Config-driven control via Python YAML bridge. All values from verified profile.
#>
param(
    [ValidateSet('doctor','status','start','stop','restart','verify','logs','open-viewer','snapshot','configure','install')]
    [string]$Action = 'status',
    [ValidateSet('ray','ray-head','ray-worker','visualization','isaacsim','webrtc-client','vnc','novnc','tunnels','all')]
    [string]$Component = 'all',
    [ValidateSet('passive','active')][string]$Mode = 'passive',
    [switch]$DryRun, [switch]$Force, [string]$Profile = 'verified-20261025', [string]$ConfigPath, [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

# === Config Bridge (v1.1.1: Find-Python returns full exe path) ===
function Find-Python {
    foreach ($candidate in @('python','python3','py')) {
        try {
            $exe = @(& $candidate -c "import sys; print(sys.executable)" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $exe.Count -gt 0) {
                $pythonPath = $exe[0].Trim()
                if (Test-Path $pythonPath) {
                    Write-Host "Python: $pythonPath" -ForegroundColor DarkGray
                    return $pythonPath
                }
            }
        } catch { continue }
    }
    Write-Host "FATAL: No working Python interpreter found" -ForegroundColor Red
    exit 99
}
$Py = Find-Python
$BridgeScript = Join-Path $ProjectDir 'linux\common\config_bridge.py'
if (-not (Test-Path $BridgeScript)) { Write-Host "FATAL: Bridge not found: $BridgeScript" -ForegroundColor Red; exit 99 }

function Get-ConfigJson {
    $args = "`"$BridgeScript`""
    if ($ConfigPath) { $args += " --config `"$ConfigPath`"" } else { $args += " $Profile" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Py; $psi.Arguments = $args; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(15000) | Out-Null
    if ($proc.ExitCode -ne 0) { Write-Host "FATAL: Bridge failed:`n$err" -ForegroundColor Red; exit 99 }
    try { $data = $out | ConvertFrom-Json } catch { Write-Host "FATAL: Bridge JSON parse: $_" -ForegroundColor Red; exit 99 }
    if (-not $data.valid) { Write-Host "FATAL: Invalid config: $($data.error)" -ForegroundColor Red; exit 99 }
    return $data
}
$C = Get-ConfigJson

# Extract values (v1.1.1: _Port suffix to avoid PS case-insensitive collision)
$H = @{}
$H.A800_Host = $C.hosts.a800.ssh_host; $H.A800_Port = [int]$C.hosts.a800.ssh_port; $H.A800_User = $C.hosts.a800.ssh_user
$H.GPU_Host  = $C.hosts.gpu4090.ssh_host; $H.GPU_Port = [int]$C.hosts.gpu4090.ssh_port; $H.GPU_User = $C.hosts.gpu4090.ssh_user
$H.BPort  = [int]$C.hosts.windows.browser_port; $H.NPort = [int]$C.visualization.novnc.port
$H.VPort  = [int]$C.visualization.vnc.port; $H.SigP = [int]$C.isaacsim.signal_port
$H.StrP   = [int]$C.isaacsim.stream_port; $H.IIP = $C.isaacsim.public_ip
$H.CDP    = [int]$C.visualization.webrtc_client.cdp_port; $H.LogD = $C.operations.log_dir
$H.GCS    = [int]$C.ray.head.gcs_port; $H.HIP = $C.ray.head.address; $H.WIP = $C.ray.worker.address
$H.PhysG  = [int]$C.gpu_mapping.physical_gpus
foreach ($k in $H.Keys) { if (-not $H[$k]) { Write-Host "FATAL: Config missing: $k" -ForegroundColor Red; exit 99 } }

# === SSH Execution (v1.1.1: no events, -n -T, async stream reads, case-safe params) ===
class SshResult { [string]$N; [int]$EC; [string]$Out; [string]$Err; [bool]$TO; [string]$Error
    [bool] Ok() { return $this.EC -eq 0 -and -not $this.TO -and -not $this.Error } }

$sshOpts = "-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ServerAliveInterval=15"

function Invoke-SSH {
    param([string]$HostName,[int]$Port,[string]$User,[string]$Command,[int]$Timeout=30)
    if ($DryRun) { Write-Host "[DRYRUN] ssh -n -T -p $Port ${User}@${HostName} $Command" -ForegroundColor Gray; return [SshResult]@{N=$HostName;EC=-1;Error='DryRun'} }
    $result = [SshResult]@{N=$HostName;EC=-1}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh'
        $psi.Arguments = "-n -T -p $Port $sshOpts ${User}@${HostName} $Command"
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($Timeout * 1000)) {
            $proc.Kill(); $result.TO = $true
            $result.Error = "Timeout ${Timeout}s ($($sw.Elapsed.TotalSeconds.ToString('0.0'))s elapsed) host=$HostName"
        } else {
            $result.EC = $proc.ExitCode
            $result.Out = $outTask.GetAwaiter().GetResult().Trim()
            $result.Err = $errTask.GetAwaiter().GetResult().Trim()
        }
        $proc.Dispose()
    } catch { $result.Error = $_.Exception.Message }
    $sw.Stop()
    return $result
}

function Send-SSH {
    param([string]$HostName,[int]$Port,[string]$User,[string]$ScriptContent,[string]$Interpreter='python3',[int]$Timeout=30)
    if ($DryRun) { Write-Host "[DRYRUN] ssh ${User}@${HostName} python3 - << SCRIPT" -ForegroundColor Gray; return [SshResult]@{N=$HostName;EC=-1;Error='DryRun'} }
    $result = [SshResult]@{N=$HostName;EC=-1}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh'
        # NO -n: stdin needed for script; python3 - reads from stdin (no -s, no quoting)
        $psi.Arguments = "-T -p $Port $sshOpts ${User}@${HostName} python3 -"
        $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.WriteLine($ScriptContent); $proc.StandardInput.Close()
        if (-not $proc.WaitForExit($Timeout * 1000)) {
            $proc.Kill(); $result.TO = $true
            $result.Error = "Timeout ${Timeout}s ($($sw.Elapsed.TotalSeconds.ToString('0.0'))s elapsed) host=$HostName stdin=$Interpreter"
        } else {
            $result.EC = $proc.ExitCode
            $result.Out = $outTask.GetAwaiter().GetResult().Trim()
            $result.Err = $errTask.GetAwaiter().GetResult().Trim()
        }
        $proc.Dispose()
    } catch { $result.Error = $_.Exception.Message }
    $sw.Stop()
    return $result
}

function S4090 { param([string]$Cmd,[int]$T=15) Invoke-SSH -HostName $H.GPU_Host -Port $H.GPU_Port -User $H.GPU_User -Command $Cmd -Timeout $T }
function SA800  { param([string]$Cmd,[int]$T=15) Invoke-SSH -HostName $H.A800_Host -Port $H.A800_Port -User $H.A800_User -Command $Cmd -Timeout $T }

function SshOk { param([ScriptBlock]$B)
    try {
        $r = & $B
        if (-not $r.Ok()) {
            Write-Host "SSH failed: EC=$($r.EC) TO=$($r.TO) Err=$($r.Error)" -ForegroundColor Red
            return $false
        }
        if ($r.Out.Trim() -ne "OK") {
            Write-Host "SSH unexpected: [$($r.Out)]" -ForegroundColor Yellow
            return $false
        }
        return $true
    } catch {
        Write-Host "SSH exception: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function WC { param([string]$N,[string]$S,[string]$D='')
    $icon=@{PASS='[PASS]';FAIL='[FAIL]';WARN='[WARN]';UNKNOWN='[????]';RUNNING='[RUN ]';STOPPED='[STOP]'}
    $col=@{PASS='Green';FAIL='Red';WARN='Yellow';UNKNOWN='Gray';RUNNING='Green';STOPPED='Red'}
    Write-Host "  $($icon[$S]) $N  $(if($D){$D})" -ForegroundColor $col[$S]
}
$ExitCode=0

# === Status (v1.1.1: Ray query via stdin python3, no nested quotes) ===
function Invoke-Status {
    Write-Host "`n=== Status ===" -ForegroundColor Cyan
    $aO=SshOk{SA800 'echo OK' -T 10};$gO=SshOk{S4090 'echo OK' -T 10}
    WC 'SSH A800' $(if($aO){'PASS'}else{'FAIL'}); WC 'SSH 4090' $(if($gO){'PASS'}else{'FAIL'})
    if(-not$gO){$script:ExitCode=2;return}

    # Ray query via stdin (no inline -c quoting issues)
    Write-Host "`n--- Ray ---" -ForegroundColor Yellow
    $rayScript = @"
import ray
ray.init(address='$($H.HIP):$($H.GCS)', ignore_reinit_error=True, logging_level='ERROR')
alive = len([n for n in ray.nodes() if n.get('Alive')])
gpu = ray.cluster_resources().get('GPU', 0)
print('ALIVE:' + str(alive))
print('GPU:' + str(gpu))
for n in ray.nodes():
    if n.get('Alive'):
        nm = n.get('NodeName', '?')
        rg = n.get('Resources', {}).get('GPU', 0)
        print('NODE:' + nm + ' GPU:' + str(rg))
ray.shutdown()
"@
    $rr = Send-SSH -HostName $H.GPU_Host -Port $H.GPU_Port -User $H.GPU_User -ScriptContent $rayScript -Interpreter 'python3' -Timeout 30
    if($rr.Ok()){
        if($rr.Out -match 'ALIVE:(\d+)'){$al=[int]$Matches[1];WC 'Nodes' $(if($al-ge2){'PASS'}elseif($al-eq1){'WARN'}else{'FAIL'}) "$al"}
        foreach($m in [regex]::Matches($rr.Out,'NODE:([^ ]+) GPU:(\d+)')){WC "Node $($m.Groups[1])" 'RUNNING' "GPU:$($m.Groups[2])"}
    }else{WC 'Ray' 'FAIL' "$($rr.Error) $($rr.Err)";$script:ExitCode=3}

    # GPU
    Write-Host "`n--- GPU ---" -ForegroundColor Yellow
    $gr=S4090 'nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader' -T 10
    if($gr.Ok()){$gr.Out -split "`n"|%{Write-Host "  $_"}}

    # Ports
    Write-Host "`n--- Ports ---" -ForegroundColor Yellow
    $pr=S4090 "for p in $($H.SigP) $($H.VPort) $($H.NPort) $($H.CDP);do ss -tlnp 2>/dev/null|grep -q `":`$p `"&&echo `$p:OK||echo `$p:MISSING;done" -T 10
    $pr.Out -split "`n"|%{if($_ -match '^(\d+):(\w+)'){WC "Port $($Matches[1])" $(if($Matches[2]-eq'OK'){'PASS'}else{'FAIL'})}}

    # WebRTC
    Write-Host "`n--- WebRTC ---" -ForegroundColor Yellow
    $sr=S4090 "pgrep -c isaacsim-webrtc 2>/dev/null||echo 0;grep -c 'Stream started.*success' $($H.LogD)/webrtc-client.log 2>/dev/null||echo 0;ss -ulnp 2>/dev/null|grep -c ':$($H.StrP) '" -T 10
    $sl=$sr.Out -split "`n"
    WC 'Client' $(if([int]$sl[0]-gt0){'RUNNING'}else{'STOPPED'})
    $streamOk=[int]$sl[1]-gt0; $udpOk=[int]$sl[2]-gt0
    if($streamOk-and$udpOk){WC 'Stream' 'PASS'}elseif([int]$sl[0]-gt0){WC 'Stream' 'UNKNOWN' 'no frame stats'}else{WC 'Stream' 'FAIL'}
}

# === Verify (v1.1.1: Ray query via stdin) ===
function Invoke-Verify {
    Write-Host "`n=== Verify ($Mode) ===" -ForegroundColor Cyan
    $fail=0; $total=0
    function V { param([string]$N,[bool]$C) $script:total++; if($C){WC $N 'PASS'}else{WC $N 'FAIL';$script:fail++;$script:ExitCode=1} }
    if($Mode -eq 'active' -and -not $Force){Write-Host "Active verify requires -Force" -ForegroundColor Red;exit 10}

    V 'SSH A800' (SshOk{SA800 'echo OK' -T 10})
    V 'SSH 4090' (SshOk{S4090 'echo OK' -T 10})
    if(-not(SshOk{S4090 'echo OK' -T 10})){$script:ExitCode=2;return}

    # Ray node count via stdin
    $rayScript = @"
import ray
ray.init(address='$($H.HIP):$($H.GCS)', ignore_reinit_error=True, logging_level='ERROR')
print(len([n for n in ray.nodes() if n.get('Alive')]))
ray.shutdown()
"@
    $rr = Send-SSH -HostName $H.GPU_Host -Port $H.GPU_Port -User $H.GPU_User -ScriptContent $rayScript -Interpreter 'python3' -Timeout 30
    $alive=if($rr.Ok() -and $rr.Out -match '^\d+$'){[int]$rr.Out.Trim()}else{0}
    V "Ray nodes >=2" ($alive -ge 2)
    if($alive -lt 2){$script:ExitCode=3}

    if($Mode -eq 'active' -and $Force){
        $scrPath = Join-Path $ProjectDir 'tests\e2e\verify_ray_active.py'
        if(Test-Path $scrPath){
            $scr = Get-Content $scrPath -Raw
            $scrWithArgs = "import sys; sys.argv = ['verify_ray_active.py', '$($H.HIP)', '$($H.GCS)', '$($H.WIP)']`n" + $scr
            $ar2 = Send-SSH -HostName $H.GPU_Host -Port $H.GPU_Port -User $H.GPU_User -ScriptContent $scrWithArgs -Interpreter 'python3' -Timeout 120
            if($ar2.Ok()){WC 'Ray GPU verify' 'PASS'}else{WC 'Ray GPU verify' 'FAIL' "$($ar2.Err)"}
        } else { WC 'Ray verify script' 'FAIL' 'script not found' }
    }

    $pr=S4090 "ss -tlnp 2>/dev/null" -T 10
    $open=$pr.Out -split "`n"
    foreach($p in @($H.VPort,$H.NPort,$H.SigP)){V "Port $p" ($open-match":$p ")}
    V "Tunnel :$($H.BPort)" (!!(netstat -ano 2>$null|Select-String "$($H.BPort).*LISTEN"))
    Write-Host "`n  Verified: $($total-$fail)/$total passed" -ForegroundColor $(if($fail-eq0){'Green'}else{'Yellow'})
}

# === Dispatch ===
switch ($Action) {
    'status'     { Invoke-Status }
    'verify'     { Invoke-Verify }
    'doctor'     { Invoke-Status; if($Mode -eq 'active'){Invoke-Verify} }
    'open-viewer' {
        if (-not (netstat -ano 2>$null | Select-String "$($H.BPort).*LISTEN")) {
            $a = @('-NT','-p',"$($H.GPU_Port)",'-L',"127.0.0.1:$($H.BPort):127.0.0.1:$($H.NPort)",'-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=30',"$($H.GPU_User)@$($H.GPU_Host)")
            Start-Process -FilePath 'ssh' -ArgumentList $a -WindowStyle Hidden; Start-Sleep -Seconds 2
        }
        Start-Process "http://127.0.0.1:$($H.BPort)/vnc.html?autoconnect=1&resize=remote"
    }
    'start' {
        if ($Component -in @('visualization','all')) { S4090 "bash /home/zjf/ray-isaac-deploy/linux/visualization/start-visualization.sh 2>&1" -T 120|%{Write-Host $_} }
        if ($Component -in @('ray','ray-head')) { SA800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-head" -T 60 | Out-Null }
        if ($Component -in @('ray','ray-worker')) { SA800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-worker" -T 60 | Out-Null }
        if ($Component -in @('tunnels','ray')) { SA800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh start-tunnels" -T 30 | Out-Null }
    }
    'stop' {
        if ($Component -in @('visualization','all')) { S4090 "bash /home/zjf/ray-isaac-deploy/linux/visualization/stop-visualization.sh 2>&1" -T 60|%{Write-Host $_} }
        if ($Component -in @('ray','ray-head','ray-worker','all')) {
            if ($Force) { SA800 "bash /home/zjf/ray-isaac-deploy/linux/ray/cluster.sh stop-cluster" -T 60 | Out-Null }
            else { Write-Host "Ray stop requires -Force" -ForegroundColor Yellow; exit 10 }
        }
    }
    'install' {
        if ($DryRun) {
            Write-Host "`n=== Install Plan ===" -ForegroundColor Cyan
            $chk = S4090 "echo ---;python3 --version 2>&1;ldconfig -p|grep -c nvidia-encode;ls /home/zjf/isaacsim/VERSION 2>/dev/null||echo ISAAC_MISSING;ls /home/zjf/noVNC-1.5.0/vnc.html 2>/dev/null||echo NOVNC_MISSING;which websockify 2>/dev/null||echo WS_MISSING;python3 -c 'import ray;print(ray.__version__)' 2>/dev/null||echo RAY_MISSING" -T 15
            Write-Host $chk.Out
        } else { Write-Host "Use -DryRun first" -ForegroundColor Yellow }
    }
    'configure' { Write-Host "Profile: $Profile"; $C | ConvertTo-Json -Depth 2 }
    'logs' { Write-Host "Logs: $($H.LogD)" -ForegroundColor Cyan }
    'snapshot' { Write-Host "Baseline: baseline/working_baseline.json"; Invoke-Status }
    default { Write-Host "UNSUPPORTED: $Action" -ForegroundColor Red; exit 99 }
}
exit $ExitCode