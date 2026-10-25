# check-cluster.ps1 - Quick Ray cluster health check
param([switch]$Json)
& "$PSScriptRoot\deploy.ps1" -Action verify