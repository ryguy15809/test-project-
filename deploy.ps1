# Deploy Tug of War to the VPS by pulling the latest code from GitHub.
# Usage:  ./deploy.ps1
$ErrorActionPreference = "Stop"

$key    = "C:/Users/catea/Downloads/oracle2-ssh-key-2026-08-05.key"
$target = "ubuntu@141.148.32.59"

Write-Host "Deploying to $target ..." -ForegroundColor Cyan
ssh -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new $target "bash /opt/tugofwar/deploy.sh"
exit $LASTEXITCODE
