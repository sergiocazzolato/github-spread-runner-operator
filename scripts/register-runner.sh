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
RUNNER_LABELS=${RUNNER_LABELS:-juju,lxd}

set -x

apt-get update
apt-get install -y --no-install-recommends curl jq ca-certificates tar git

# Download latest runner tarball (uses the GitHub releases redirect)
ARCHIVE="$(curl --silent "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.assets[] | select(.name | contains("linux-x64")) | .name')"
URL="$(curl --silent "https://api.github.com/repos/actions/runner/releases/latest" | jq -r '.assets[] | select(.name | contains("linux-x64")) | .browser_download_url')"
curl -fsSL -o "$ARCHIVE" "$URL"

# extract
tar xzf "$ARCHIVE"

# Register runner
# The config script will create a runner registration and write _diag files.
./config.sh --unattended --url \"$GITHUB_URL\" --token \"$GITHUB_TOKEN\" --name \"$RUNNER_NAME\" --labels \"$RUNNER_LABELS\" --replace
./svc.sh install
./svc.sh start

echo "Runner $RUNNER_NAME registered"
