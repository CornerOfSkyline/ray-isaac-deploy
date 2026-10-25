# start-all.ps1 - One-click: verify Ray cluster, start visualization, open browser
param([switch]$SkipVerify)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Isaac Sim Remote Deployment        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan

# 1. Quick health check
if (-not $SkipVerify) {
    Write-Host "`n[1/3] Checking system health..." -ForegroundColor Yellow
    & "$ScriptDir\deploy.ps1" -Action status
}

# 2. Ensure visualization is running
Write-Host "`n[2/3] Starting visualization stack..." -ForegroundColor Yellow
& "$ScriptDir\deploy.ps1" -Action start -Component visualization

# 3. Open browser
Write-Host "`n[3/3] Opening viewer..." -ForegroundColor Yellow
& "$ScriptDir\deploy.ps1" -Action open-viewer

Write-Host "`nDone. Isaac Sim should appear in your browser." -ForegroundColor Green