#!/usr/bin/env bash
set -euo pipefail

# Playwright resolves the correct apt package list for the distro, so we
# don't hand-maintain one. Requires Node in the image (INSTALL_NODE=true),
# which is present by feature-build time. VERSION comes from the feature's
# "version" option (default "latest" — the one deliberately mutable input;
# pin it in devcontainer.json to freeze the dependency list).
export DEBIAN_FRONTEND=noninteractive
npx -y "playwright@${VERSION:-latest}" install-deps chromium
apt-get clean
rm -rf /var/lib/apt/lists/* /root/.npm
