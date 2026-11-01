#!/usr/bin/env bash
# Gets a clone ready for working on Jambul: installs the git hooks that keep secrets, personal data and AI
# attribution out of commits, merges and pushes. Safe to run again, and needed again after .githooks/ changes.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v gitleaks > /dev/null; then
    echo "✘ gitleaks is missing, and the hooks refuse every commit without it: brew install gitleaks" >&2
    exit 1
fi
echo "✔ gitleaks $(gitleaks version) is installed."

# The hooks go into .git/hooks, which stays put across checkouts. A hooks path inside the working tree would vanish,
# and with it every check, on a branch that doesn't have the folder.
git config --unset core.hooksPath || true
# A hooks path set anywhere else, such as globally by another tool, makes git skip .git/hooks, and the scan with them.
if other=$(git config --get core.hooksPath); then
    echo "✘ core.hooksPath is set to $other ($(git config --show-origin --get core.hooksPath | cut -f1))." >&2
    echo "  Git would skip .git/hooks, and every check with them. Unset it, then run this again." >&2
    exit 1
fi
hooks=$(git rev-parse --git-path hooks)
mkdir -p "$hooks"
for hook in .githooks/*; do
    name=$(basename "$hook")
    if [[ -f $hooks/$name ]] && ! grep -q "installed into .git/hooks by scripts/setup.sh" "$hooks/$name"; then
        mv "$hooks/$name" "$hooks/$name.before-jambul"
        echo "  Moved your existing $name hook to $hooks/$name.before-jambul."
    fi
    cp "$hook" "$hooks/$name"
    chmod +x "$hooks/$name"
done
echo "✔ Git hooks installed: every commit, merge and push is scanned by scripts/scan.sh."

patterns=$(git rev-parse --git-path info/private-patterns)
if [[ ! -f $patterns ]]; then
    mkdir -p "$(dirname "$patterns")"
    cat > "$patterns" <<'PATTERNS'
# Strings that must never reach the public repository, one per line, such as your private email addresses or your
# Mac's name. This file stays in .git/ and is never committed. Lines starting with # are ignored.
PATTERNS
    echo "✔ Created $patterns for anything private of yours the scan should also refuse."
fi

# Whatever address commits carry becomes public with them.
if [[ -z $(git config --local user.email || true) ]]; then
    echo "! This clone has no address of its own, so commits would use your global one: $(git config user.email || echo none)."
    echo "  It becomes public with every commit. To use a public address here: git config user.email <address>"
else
    echo "  Commits from this clone are signed $(git config user.name || echo '<no name>') <$(git config user.email)>, which becomes public."
fi
