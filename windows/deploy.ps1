#Requires -Version 5.1
<#
.SYNOPSIS Ray + Isaac Sim deployment toolkit v1.1 RC2
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

# === Config Bridge ===
function Find-Python {
    foreach ($py in @('python3','python','py')) { try { $null = & $py --version 2>&1; return $py } catch {} }
    Write-Host "FATAL: No Python found" -ForegroundColor Red; exit 99
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

# Extract values
$H = @{}
$H.A800_H = $C.hosts.a800.ssh_host; $H.A800_P = [int]$C.hosts.a800.ssh_port; $H.A800_U = $C.hosts.a800.ssh_user
$H.GPU_H = $C.hosts.gpu4090.ssh_host; $H.GPU_P = [int]$C.hosts.gpu4090.ssh_port; $H.GPU_U = $C.hosts.gpu4090.ssh_user
$H.BPort = [int]$C.hosts.windows.browser_port; $H.NPort = [int]$C.visualization.novnc.port
$H.VPort = [int]$C.visualization.vnc.port; $H.SigP = [int]$C.isaacsim.signal_port
$H.StrP = [int]$C.isaacsim.stream_port; $H.IIP = $C.isaacsim.public_ip
$H.CDP = [int]$C.visualization.webrtc_client.cdp_port; $H.LogD = $C.operations.log_dir
$H.GCS = [int]$C.ray.head.gcs_port; $H.HIP = $C.ray.head.address; $H.WIP = $C.ray.worker.address
$H.PhysG = [int]$C.gpu_mapping.physical_gpus
foreach ($k in $H.Keys) { if (-not $H[$k]) { Write-Host "FATAL: Config missing: $k" -ForegroundColor Red; exit 99 } }

# === SSH ===
class SshResult { [string]$N; [int]$EC; [string]$Out; [string]$Err; [bool]$TO; [string]$Error
    [bool] Ok() { return $this.EC -eq 0 -and -not $this.TO -and -not $this.Error } }

function Invoke-SSH {
    param([string]$Hn,[int]$P,[string]$U,[string]$Cmd,[int]$T=30)
    if ($DryRun) { Write-Host "[DRYRUN] ssh -p $P ${U}@${Hn} $Cmd" -ForegroundColor Gray; return [SshResult]@{N=$Hn;EC=-1;Error='DryRun'} }
    $r=[SshResult]@{N=$Hn;EC=-1}
    try {
        $psi=New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName='ssh'
        $psi.Arguments="-p $P -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ServerAliveInterval=15 ${U}@${Hn} $Cmd"
        $psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
        $p=[System.Diagnostics.Process]::Start($psi)
        $sbOut=New-Object System.Text.StringBuilder;$sbErr=New-Object System.Text.StringBuilder
        $oe=Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action {$Event.MessageData.AppendLine($EventArgs.Data)} -MessageData $sbOut
        $ee=Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action {$Event.MessageData.AppendLine($EventArgs.Data)} -MessageData $sbErr
        $p.BeginOutputReadLine();$p.BeginErrorReadLine()
        if(-not $p.WaitForExit($T*1000)){$p.Kill();$r.TO=$true;$r.Error="Timeout ${T}s"}
        Unregister-Event -SourceIdentifier $oe.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $ee.Name -ErrorAction SilentlyContinue
        $p.WaitForExit(2000)|Out-Null  # flush async buffers
        $r.EC=$p.ExitCode;$r.Out=$sbOut.ToString().Trim();$r.Err=$sbErr.ToString().Trim();$p.Dispose()
    }catch{$r.Error=$_.Exception.Message}
    return $r
}

function Send-SSH {
    param([string]$Hn,[int]$P,[string]$U,[string]$Script,[string]$Interpreter='bash',[int]$T=30)
    if ($DryRun) { Write-Host "[DRYRUN] ssh ${U}@${Hn} $Interpreter -s << SCRIPT" -ForegroundColor Gray; return [SshResult]@{N=$Hn;EC=-1;Error='DryRun'} }
    $r=[SshResult]@{N=$Hn;EC=-1}
    try {
        $psi=New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName='ssh'
        $psi.Arguments="-p $P -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ServerAliveInterval=15 ${U}@${Hn} '$Interpreter -s'"
        $psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true
        $p=[System.Diagnostics.Process]::Start($psi)
        $sbOut=New-Object System.Text.StringBuilder;$sbErr=New-Object System.Text.StringBuilder
        $oe=Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action {$Event.MessageData.AppendLine($EventArgs.Data)} -MessageData $sbOut
        $ee=Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action {$Event.MessageData.AppendLine($EventArgs.Data)} -MessageData $sbErr
        $p.BeginOutputReadLine();$p.BeginErrorReadLine()
        $p.StandardInput.WriteLine($Script);$p.StandardInput.Close()
        if(-not $p.WaitForExit($T*1000)){$p.Kill();$r.TO=$true;$r.Error="Timeout ${T}s"}
        Unregister-Event -SourceIdentifier $oe.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $ee.Name -ErrorAction SilentlyContinue
        $p.WaitForExit(2000)|Out-Null
        $r.EC=$p.ExitCode;$r.Out=$sbOut.ToString().Trim();$r.Err=$sbErr.ToString().Trim();$p.Dispose()
    }catch{$r.Error=$_.Exception.Message}
    return $r
}
function S4090 { param([string]$C,[int]$T=15) Invoke-SSH -Hn $H.GPU_H -P $H.GPU_P -U $H.GPU_U -Cmd $C -T $T }
function SA800 { param([string]$C,[int]$T=15) Invoke-SSH -Hn $H.A800_H -P $H.A800_P -U $H.A800_U -Cmd $C -T $T }
function SshOk { param([ScriptBlock]$B) try{$r=&$B;return($r.Ok()-and$r.Out.Trim()-eq'OK')}catch{return $false} }
function WC { param([string]$N,[string]$S,[string]$D='')
    $icon=@{PASS='[PASS]';FAIL='[FAIL]';WARN='[WARN]';UNKNOWN='[????]';RUNNING='[RUN ]';STOPPED='[STOP]'}
    $col=@{PASS='Green';FAIL='Red';WARN='Yellow';UNKNOWN='Gray';RUNNING='Green';STOPPED='Red'}
    Write-Host "  $($icon[$S]) $N  $(if($D){$D})" -ForegroundColor $col[$S]
}
$ExitCode=0

# === Status ===
function Invoke-Status {
    Write-Host "`n=== Status ===" -ForegroundColor Cyan
    $aO=SshOk{SA800 'echo OK' -T 10};$gO=SshOk{S4090 'echo OK' -T 10}
    WC 'SSH A800' $(if($aO){'PASS'}else{'FAIL'}); WC 'SSH 4090' $(if($gO){'PASS'}else{'FAIL'})
    if(-not$gO){$script:ExitCode=2;return}

    # Ray
    Write-Host "`n--- Ray ---" -ForegroundColor Yellow
    $pyCmd = "import ray; ray.init(address='$($H.HIP):$($H.GCS)',ignore_reinit_error=True,logging_level='ERROR');alive=len([n for n in ray.nodes() if n.get('Alive')]);gpu=ray.cluster_resources().get('GPU',0);print('ALIVE:'+str(alive));print('GPU:'+str(gpu));[print('NODE:'+n.get('NodeName','')+' GPU:'+str(n.get('Resources',{}).get('GPU',0))) for n in ray.nodes() if n.get('Alive')];ray.shutdown()"
    $rr=S4090 "python3 -c '$pyCmd'" -T 20
    if($rr.Ok()){
        if($rr.Out -match 'ALIVE:(\d+)'){$al=[int]$Matches[1];WC 'Nodes' $(if($al-ge2){'PASS'}elseif($al-eq1){'WARN'}else{'FAIL'}) "$al"}
        if($rr.Out -match 'NODE:([^ ]+) GPU:(\d+)'){WC "Node $($Matches[1])" 'RUNNING' "GPU:$($Matches[2])"}
    }else{WC 'Ray' 'FAIL' $rr.Error;$script:ExitCode=3}

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

# === Verify ===
function Invoke-Verify {
    Write-Host "`n=== Verify ($Mode) ===" -ForegroundColor Cyan
    $fail=0; $total=0
    function V { param([string]$N,[bool]$C) $script:total++; if($C){WC $N 'PASS'}else{WC $N 'FAIL';$script:fail++;$script:ExitCode=1} }
    if($Mode -eq 'active' -and -not $Force){Write-Host "Active verify requires -Force" -ForegroundColor Red;exit 10}

    V 'SSH A800' (SshOk{SA800 'echo OK' -T 10})
    V 'SSH 4090' (SshOk{S4090 'echo OK' -T 10})
    if(-not(SshOk{S4090 'echo OK' -T 10})){$script:ExitCode=2;return}

    $rr=S4090 "python3 -c 'import ray;ray.init(address=`"$($H.HIP):$($H.GCS)`",ignore_reinit_error=True,logging_level=`"ERROR`");print(len([n for n in ray.nodes() if n.get(`"Alive`")]));ray.shutdown()'" -T 20
    $alive=if($rr.Out-match'^\d+$'){[int]$rr.Out.Trim()}else{0}
    V "Ray nodes >=2" ($alive -ge 2)
    if($alive -lt 2){$script:ExitCode=3}

    if($Mode -eq 'active' -and $Force){
        $scr=Get-Content(Join-Path $ProjectDir 'linux\ray\verify-cluster.sh')-Raw
        $ar=Invoke-SSH -Hn $H.GPU_H -P $H.GPU_P -U $H.GPU_U -Cmd "bash -s" -T 90
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
            $a = @('-NT','-p',"$($H.GPU_P)",'-L',"127.0.0.1:$($H.BPort):127.0.0.1:$($H.NPort)",'-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=30',"$($H.GPU_U)@$($H.GPU_H)")
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
            if ($chk.Out -match 'ISAAC_MISSING'){Write-Host "  [NEED] Isaac Sim 6.2.0" -ForegroundColor Yellow}
            if ($chk.Out -match 'NOVNC_MISSING'){Write-Host "  [NEED] noVNC 1.5.0" -ForegroundColor Yellow}
        } else { Write-Host "Use -DryRun first" -ForegroundColor Yellow }
    }
    'configure' { Write-Host "Profile: $Profile"; $C | ConvertTo-Json -Depth 2 }
    'logs' { Write-Host "Logs: $($H.LogD)" -ForegroundColor Cyan }
    'snapshot' { Write-Host "Baseline: baseline/working_baseline.json"; Invoke-Status }
    default { Write-Host "UNSUPPORTED: $Action" -ForegroundColor Red; exit 99 }
}
exit $ExitCode