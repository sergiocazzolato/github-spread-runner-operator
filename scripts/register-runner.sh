#!/usr/bin/env bash
set -euo pipefail


# This script runs *inside* the target LXD container. It's pushed there by the charm
# and executed with the following environment variables set by the charm:
# - GITHUB_URL (e.g. https://github.com/owner/repo or https://github.com/org)
# - GITHUB_TOKEN (registration token)
# - RUNNER_NAME (the name to register)
# - RUNNER_LABELS (comma separated labels)


GITHUB_URL=${GITHUB_URL:?}
GITHUB_TOKEN=${GITHUB_TOKEN:?}
RUNNER_NAME=${RUNNER_NAME:?}
RUNNER_LABELS=${RUNNER_LABELS:-spread-enabled}
HTTP_PROXY=${HTTP_PROXY:-}
HTTPS_PROXY=${HTTPS_PROXY:-}
NO_PROXY="${NO_PROXY:-"localhost,127.0.0.1"}"

RUNNER_USER=ubuntu
RUNNER_HOME="/home/$RUNNER_USER/actions-runner"

set -x

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

sudo apt update
sudo apt install -y --no-install-recommends curl jq ca-certificates tar git

mkdir -p "$RUNNER_HOME"
chown "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_HOME"
cd "$RUNNER_HOME"


# Download latest runner tarball (uses the GitHub releases redirect)
ARCHIVE="$(curl --silent "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.assets[] | select(.name | contains("linux-x64")) | .name')"
URL="$(curl --silent "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.assets[] | select(.name | contains("linux-x64")) | .browser_download_url')"
curl -fsSL -o "$ARCHIVE" "$URL"

# extract
tar xzf "$ARCHIVE"
chown -R "${RUNNER_USER}:${RUNNER_USER}" .

# Register runner
# The config script will create a runner registration and write _diag files.
su - "$RUNNER_USER" -c "$RUNNER_HOME/config.sh --unattended --url \"$GITHUB_URL\" --token \"$GITHUB_TOKEN\" --name \"$RUNNER_NAME\" --labels \"$RUNNER_LABELS\" --replace"
sudo ./svc.sh install
sudo ./svc.sh start

echo "Runner $RUNNER_NAME registered"

# Update proxy for the runner service

# Detect the GitHub runner service
SERVICE=$(systemctl list-units --type=service --all | grep -o "actions.runner.*\.service" || true)

if [[ -z "$SERVICE" ]]; then
    echo "Could not find GitHub runner systemd service"
    exit 1
fi

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
