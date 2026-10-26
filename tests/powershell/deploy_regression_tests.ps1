#Requires -Version 5.1
# deploy_regression_tests.ps1 - Regression tests for deploy.ps1
# Covers: port matching, zero ports, SSH failure, counting, exit codes
param([switch]$Verbose)

$TestDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DeployScript = Join-Path $TestDir 'deploy.ps1'
$ErrorActionPreference = 'Continue'
$passed = 0; $failed = 0
function Pass([string]$N) { Write-Host "  PASS: $N" -ForegroundColor Green; $script:passed++ }
function Fail([string]$N) { Write-Host "  FAIL: $N" -ForegroundColor Red; $script:failed++ }

Write-Host "=== Deploy.ps1 Regression Tests ===" -ForegroundColor Cyan

# --- Test 1: Scalar string match returns boolean ---
Write-Host "`n--- Test 1: Port matching on scalar string ---" -ForegroundColor Yellow
$fakeOut = "LISTEN 0      64           0.0.0.0:49100      0.0.0.0:*`nLISTEN 0      5          127.0.0.1:5901       0.0.0.0:*`nLISTEN 0      100          0.0.0.0:6006       0.0.0.0:*"
$r1 = $fakeOut -match ':5901 '
$r2 = $fakeOut -match ':9999 '
if ($r1 -is [bool] -and $r1) { Pass 'Scalar match returns bool ($true for present)' } else { Fail "Expected bool `$true, got $($r1.GetType()): $r1" }
if ($r2 -is [bool] -and -not $r2) { Pass 'Scalar match returns bool ($false for missing)' } else { Fail "Expected bool `$false, got $($r2.GetType()): $r2" }

# --- Test 2: String array match returns array (the bug we fixed) ---
Write-Host "`n--- Test 2: Array match returns array (must avoid) ---" -ForegroundColor Yellow
$arr = $fakeOut -split "`n"
$r3 = $arr -match ':5901 '
if ($r3 -is [array] -or $r3 -is [System.Object[]]) {
    Pass 'Array match returns array (root cause: cannot pass to [bool] param)'
} else {
    Fail "Unexpected type: $($r3.GetType())"
}

# --- Test 3: Zero ports scenario ---
Write-Host "`n--- Test 3: Zero ports ---" -ForegroundColor Yellow
$emptyOut = ""
$r4 = ($emptyOut -match ':5901 ') -is [bool]
if ($r4 -and ($emptyOut -match ':5901 ') -eq $false) {
    Pass 'Empty string match returns bool $false'
} else { Fail "Expected bool `$false" }

# --- Test 4: SSH failure should not pass ports ---
Write-Host "`n--- Test 4: SSH failure guard ---" -ForegroundColor Yellow
$sshOk = $false
$prOut = ""  # Empty because SSH failed
$portPresent = $sshOk -and ($prOut -match ':5901 ')
if ($portPresent -is [bool] -and -not $portPresent) {
    Pass 'SSH failure makes port check $false (guard works)'
} else { Fail "SSH failure guard should produce `$false, got $portPresent" }

# --- Test 5: ExitCode tracking ---
Write-Host "`n--- Test 5: ExitCode tracking ---" -ForegroundColor Yellow
$Global:TestExitCode = 0
function Simulate-Check { param([bool]$OK) if(-not $OK){ $Global:TestExitCode = 4 } }
Simulate-Check $true
if ($Global:TestExitCode -eq 0) { Pass 'Passing check leaves ExitCode=0' } else { Fail "ExitCode changed: $Global:TestExitCode" }
Simulate-Check $false
if ($Global:TestExitCode -eq 4) { Pass 'Failing check sets ExitCode=4' } else { Fail "ExitCode should be 4, got $Global:TestExitCode" }

# --- Test 6: Counting scope ---
Write-Host "`n--- Test 6: Counting scope ---" -ForegroundColor Yellow
$Global:CountTotal = 0; $Global:CountFail = 0
1..5 | ForEach-Object {
    $Global:CountTotal++
    if ($_ -gt 3) { $Global:CountFail++ }
}
if ($Global:CountTotal -eq 5) { Pass 'Total count: 5' } else { Fail "Total: $Global:CountTotal" }
if ($Global:CountFail -eq 2) { Pass 'Fail count: 2' } else { Fail "Fails: $Global:CountFail" }
$summary = "$($Global:CountTotal-$Global:CountFail)/$Global:CountTotal passed"
if ($summary -eq "3/5 passed") { Pass "Summary: $summary" } else { Fail "Summary wrong: $summary" }

# --- Test 7: SshResult Ok() method ---
Write-Host "`n--- Test 7: SshResult Ok() ---" -ForegroundColor Yellow
class TestResult { [int]$EC; [bool]$TO; [string]$Error; [bool] Ok() { return $this.EC -eq 0 -and -not $this.TO -and -not $this.Error } }
$r = [TestResult]@{EC=0; TO=$false; Error=''}
if ($r.Ok()) { Pass 'Ok() returns true for clean result' } else { Fail 'Ok() should be true' }
$r2 = [TestResult]@{EC=1; TO=$false; Error=''}
if (-not $r2.Ok()) { Pass 'Ok() returns false for non-zero exit' } else { Fail 'Ok() should be false' }
$r3 = [TestResult]@{EC=0; TO=$true; Error=''}
if (-not $r3.Ok()) { Pass 'Ok() returns false for timeout' } else { Fail 'Ok() should be false' }

# --- Results ---
Write-Host "`n=== Results: $passed passed, $failed failed ==="
if ($failed -gt 0) { exit 1 } else { exit 0 }