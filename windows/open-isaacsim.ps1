# open-isaacsim.ps1 - Open Isaac Sim in browser (tunnel + URL)
param([switch]$NoTunnel)

if (-not $NoTunnel) {
    $existing = netstat -ano 2>$null | Select-String "16006.*LISTEN"
    if (-not $existing) {
        Write-Host "Starting SSH tunnel..." -ForegroundColor Yellow
        Start-Process -FilePath "ssh" -ArgumentList "-NT", "-p", "46602", "-L", "127.0.0.1:16006:127.0.0.1:6006", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "zjf@180.97.68.228" -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }
}
Start-Process "http://127.0.0.1:16006/vnc.html?autoconnect=1&resize=remote"