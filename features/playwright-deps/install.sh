#!/usr/bin/env bash
set -euo pipefail

# Playwright resolves the correct apt package list for the distro, so we
# don't hand-maintain one. Requires Node in the image (INSTALL_NODE=true),
# which is present by feature-build time.
npx -y playwright install-deps chromium
apt-get clean
rm -rf /var/lib/apt/lists/*
