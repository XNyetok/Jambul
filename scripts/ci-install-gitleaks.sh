#!/usr/bin/env bash
# Installs the pinned gitleaks on a Linux x64 CI runner, after checking its checksum. On a Mac: brew install gitleaks.
set -euo pipefail
version=8.30.1
sha256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
file=gitleaks_${version}_linux_x64.tar.gz
url=https://github.com/gitleaks/gitleaks/releases/download/v$version/$file
tmp=$(mktemp -d)
# github.com's release downloads can fail with a 504 for a while when GitHub's API still serves the file, and gh
# downloads through the API. The checksum below checks either download.
if ! curl -sSfL --max-time 60 -o "$tmp/$file" "$url"; then
    echo "::warning::Downloading gitleaks from github.com failed; trying GitHub's API."
    gh release download "v$version" --repo gitleaks/gitleaks --pattern "$file" --dir "$tmp" --clobber
fi
echo "$sha256  $tmp/$file" | sha256sum --check --quiet
tar -xzf "$tmp/$file" -C "$tmp" gitleaks
sudo install "$tmp/gitleaks" /usr/local/bin/gitleaks
rm -rf "$tmp"
echo "gitleaks $(gitleaks version)"
