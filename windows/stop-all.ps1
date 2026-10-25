# stop-all.ps1 - Stop visualization stack
& "$PSScriptRoot\deploy.ps1" -Action stop -Component visualization
Write-Host "Done." -ForegroundColor Green