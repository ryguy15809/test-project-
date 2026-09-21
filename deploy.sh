#!/usr/bin/env bash
set -euo pipefail

# Deploy the Tug of War game from GitHub.
# Run ON the VPS (or via deploy.ps1 from your machine).
#
# One-time setup (already done on the VPS):
#   sudo git clone https://github.com/ryguy15809/test-project-.git /opt/tugofwar
#   sudo chown -R ubuntu:ubuntu /opt/tugofwar
#   (the game_server systemd service runs from /opt/tugofwar)

REPO=/opt/tugofwar
WEB=/var/www/tugofwar
AUTH=/opt/auth_service

echo ">>> Pulling latest from GitHub..."
git -C "$REPO" pull --ff-only origin main

echo ">>> Deploying web client -> $WEB"
sudo rsync -a --delete "$REPO/web/" "$WEB/"

echo ">>> Deploying auth code (auth.db + systemd unit untouched)"
sudo cp "$REPO"/auth_service/*.py "$AUTH"/
sudo cp "$REPO"/auth_service/requirements.txt "$AUTH"/

echo ">>> Restarting services..."
sudo systemctl restart game_server auth

echo ">>> Deploy complete."
