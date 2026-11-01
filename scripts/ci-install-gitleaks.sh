#!/usr/bin/env bash
# Installs the pinned gitleaks on a Linux x64 CI runner, after checking its checksum. On a Mac: brew install gitleaks.
set -euo pipefail
version=8.30.1
sha256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
tmp=$(mktemp -d)
curl -sSfL -o "$tmp/gitleaks.tar.gz" \
    "https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_linux_x64.tar.gz"
echo "$sha256  $tmp/gitleaks.tar.gz" | sha256sum --check --quiet
tar -xzf "$tmp/gitleaks.tar.gz" -C "$tmp" gitleaks
sudo install "$tmp/gitleaks" /usr/local/bin/gitleaks
rm -rf "$tmp"
echo "gitleaks $(gitleaks version)"
