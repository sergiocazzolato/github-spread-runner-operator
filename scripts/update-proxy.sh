#!/usr/bin/env bash
set -euo pipefail

HTTP_PROXY="${1:-}"
HTTPS_PROXY="${2:-}"
NO_PROXY="${3:-"localhost,127.0.0.1"}"

# Detect the GitHub runner service
SERVICE=$(systemctl list-units --type=service --all | grep -o "actions.runner.*\.service" || true)

if [[ -z "$SERVICE" ]]; then
    echo "Could not find GitHub runner systemd service"
    exit 1
fi

echo "Using runner service: $SERVICE"

# Create systemd override
sudo mkdir -p /etc/systemd/system/"$SERVICE".d

cat <<EOF | sudo tee /etc/systemd/system/"$SERVICE".d/proxy.conf >/dev/null
[Service]
Environment="http_proxy=$HTTP_PROXY"
Environment="https_proxy=$HTTPS_PROXY"
Environment="HTTP_PROXY=$HTTP_PROXY"
Environment="HTTPS_PROXY=$HTTPS_PROXY"
Environment="no_proxy=$NO_PROXY"
Environment="NO_PROXY=$NO_PROXY"
EOF

echo "Proxy configuration written to systemd override"

# Apply changes
sudo systemctl daemon-reload
sudo systemctl restart "$SERVICE"

echo "Runner service restarted"
echo
echo "Current proxy environment in service:"
systemctl show "$SERVICE" | grep -i proxy


echo "Setting machine-wide proxy"

# Delete existing entries
sudo sed -i '/http_proxy/d' /etc/environment || true
sudo sed -i '/https_proxy/d' /etc/environment || true
sudo sed -i '/no_proxy/d' /etc/environment || true
sudo sed -i '/HTTP_PROXY/d' /etc/environment || true
sudo sed -i '/HTTPS_PROXY/d' /etc/environment || true
sudo sed -i '/NO_PROXY/d' /etc/environment || true

# Append new entries
cat <<EOF | sudo tee -a /etc/environment > /dev/null
http_proxy="$HTTP_PROXY"
https_proxy="$HTTPS_PROXY"
HTTP_PROXY="$HTTP_PROXY"
HTTPS_PROXY="$HTTPS_PROXY"
no_proxy="$NO_PROXY"
NO_PROXY="$NO_PROXY"
EOF

echo "Updated /etc/environment"
