#!/usr/bin/env bash
# Ships the branch you're on: opens its pull request, waits for CI, squash-merges it with the commit's own message,
# and deletes the branch here and on GitHub. The branch holds one commit on top of main. If CI fails, amend that
# commit and run this again. Runs under the bash 3.2 that ships with macOS.
set -euo pipefail
export GH_PROMPT_DISABLED=1

fail() {
    printf '✘ %s\n' "$1" >&2
    exit 1
}

# Waits until GitHub shows the commit being shipped, every check main's rules require has passed on it, and GitHub
# calls the pull request clean. A check that hasn't started yet isn't listed at all, and GitHub counts a skipped run
# as passed, so neither the list nor GitHub's verdict is enough alone.
wait_for_ci() {
    local required view state oid merge=UNKNOWN checks failed pending passed name seen='' i
    required=$(gh api "repos/{owner}/{repo}/rules/branches/main" \
        --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context')
    [[ -n $required ]] || fail "main's rules require no checks, so there's nothing to wait for."
    echo "Waiting for CI on #$pr..."
    for ((i = 0; i < 120; i++)); do
        ((i == 0)) || sleep 10
        view=$(gh pr view "$pr" --json state,headRefOid,mergeStateStatus \
            --jq '"\(.state) \(.headRefOid) \(.mergeStateStatus)"' 2> /dev/null) || continue
        read -r state oid merge <<< "$view"
        [[ $state == OPEN ]] || fail "#$pr is no longer open on GitHub ($state)."
        # Right after a push, GitHub can still show the commit before it, with that commit's checks.
        if [[ $oid != "$head" ]]; then
            [[ -z $seen && $i -lt 12 ]] || fail "#$pr's branch on GitHub isn't at the commit being shipped."
            continue
        fi
        seen=yes
        checks=$(gh pr checks "$pr" --required --json bucket,name --jq '.[] | "\(.bucket) \(.name)"' 2> /dev/null || true)
        failed=$(printf '%s\n' "$checks" | sed -n -E 's/^(fail|cancel) //p' | sort -u)
        if [[ -n $failed ]]; then
            printf '✘ CI failed on #%s. Fix it, amend the commit and run this again.\n' "$pr" >&2
            printf '%s\n' "$failed" | sed 's/^/  /' >&2
            exit 1
        fi
        pending=$(printf '%s\n' "$checks" | grep -c '^pending ' || true)
        passed=yes
        while IFS= read -r name; do
            printf '%s\n' "$checks" | grep -xF "pass $name" > /dev/null || passed=
        done <<< "$required"
        case $merge in
        DIRTY) fail "#$pr conflicts with main. Rebase it on main and run this again." ;;
        BEHIND) fail "#$pr is behind main. Rebase it on main and run this again." ;;
        DRAFT) fail "#$pr is a draft." ;;
        CLEAN | UNSTABLE)
            if [[ $pending -eq 0 && -n $passed ]]; then return; fi
            ;;
        esac
    done
    fail "#$pr still isn't ready after $((SECONDS / 60)) minutes (GitHub says $merge). Run this again later."
}

# The commit's own message lands on main, scanned once more right before it does.
merge() {
    local out
    [[ $(git rev-parse --verify --quiet "refs/heads/$branch" || true) == "$head" ]] ||
        fail "$branch moved while CI ran. Run this again to ship it as it is now."
    [[ -z $(git status --porcelain) ]] || fail "Commit or stash your changes, then run this again."
    message=$(mktemp)
    printf '%s (#%s)\n\n%s\n' "$subject" "$pr" "$body" > "$message"
    if ! out=$(scripts/scan.sh message "$message" 2>&1); then
        printf '%s\n' "$out" >&2
        fail "The merge's commit message didn't pass the scan."
    fi
    # gh can fail on its way back after GitHub has merged.
    if ! out=$(gh pr merge "$pr" --squash --match-head-commit "$head" --subject "$subject (#$pr)" --body "$body" 2>&1) &&
        [[ $(gh pr view "$pr" --json state --jq .state 2> /dev/null || true) != MERGED ]]; then
        printf '%s\n' "$out" >&2
        fail "Couldn't merge #$pr."
    fi
}

message=
trap '[[ -z $message ]] || rm -f "$message"' EXIT
command -v gh > /dev/null || fail "gh isn't installed: brew install gh"
cd "$(git rev-parse --show-toplevel)"

branch=$(git symbolic-ref --quiet --short HEAD) || fail "Not on a branch."
[[ $branch != main ]] || fail "You're on main. Ship from a branch."
[[ -z $(git status --porcelain) ]] || fail "Commit or stash your changes first."
# Only main: fetching the branch too would turn the lease on the push below into a plain --force.
git fetch --quiet origin main
count=$(git rev-list --count origin/main..HEAD)
[[ $count -eq 1 ]] ||
    fail "$branch has $count commits on top of main. Squash them first: git reset --soft \"\$(git merge-base origin/main HEAD)\" && git commit"
head=$(git rev-parse HEAD)
subject=$(git log -1 --format=%s)
body=$(git log -1 --format=%b)

# GitHub writes the squash commit under the account's primary email, and that address goes public with it.
email=$(git config user.email) || fail "Set git's user.email first."
primary=$(gh api user/emails --jq '.[] | select(.primary) | .email')
[[ $primary == "$email" ]] ||
    fail "Your primary email on GitHub isn't $email, and the merge would go out under it. Change it at https://github.com/settings/emails."

# Pull requests from forks can have a branch of the same name.
own='map(select(.isCrossRepository | not))'
# A run after a merge whose cleanup didn't finish goes straight to the cleanup.
pr=$(gh pr list --head "$branch" --base main --state merged --json number,headRefOid,isCrossRepository \
    --jq "$own | map(select(.headRefOid == \"$head\"))[0].number // empty")
if [[ -z $pr ]]; then
    pr=$(gh pr list --head "$branch" --base main --state open --json number,isCrossRepository \
        --jq "${own}[0].number // empty")
    # The new text goes up before the commit, so CI checks the new commit with it.
    if [[ -n $pr ]]; then
        if [[ $(gh pr view "$pr" --json title --jq .title) != "$subject" ||
            $(gh pr view "$pr" --json body --jq .body) != "$body" ]]; then
            gh pr edit "$pr" --title "$subject" --body "$body" > /dev/null
        fi
    fi
    git push --quiet --force-with-lease --set-upstream origin "$branch" ||
        fail "Couldn't push $branch. If GitHub has a branch of that name from elsewhere, rename yours."
    if [[ -z $pr ]]; then
        url=$(gh pr create --base main --head "$branch" --title "$subject" --body "$body")
        pr=${url##*/}
    fi
    wait_for_ci
    merge
fi

# Ends on an up-to-date main, and deletes the branch, here and on GitHub, only where it's still the shipped commit.
[[ $(git symbolic-ref --quiet --short HEAD || true) == main ]] || git switch --quiet main
git pull --quiet --ff-only origin main
if [[ $(git rev-parse --verify --quiet "refs/heads/$branch" || true) == "$head" ]]; then
    git branch --quiet -D "$branch"
fi
if [[ $(git ls-remote origin "refs/heads/$branch" | cut -f1) == "$head" ]]; then
    # GitHub deletes it too after a merge, and may get there first.
    git push --quiet --force-with-lease="refs/heads/$branch:$head" origin ":refs/heads/$branch" 2> /dev/null || true
fi
git fetch --quiet --prune origin

remote=$(git ls-remote --heads origin) || fail "Couldn't list the branches on GitHub."
left=$({
    git for-each-ref --format='%(refname:short) (here)' refs/heads
    printf '%s\n' "$remote" | sed -n 's|.*refs/heads/\(.*\)|\1 (on GitHub)|p'
} | grep -v '^main (' || true)
if [[ -z $left ]]; then
    echo "✔ #$pr is on main, and only main is left."
else
    echo "✔ #$pr is on main. Other branches are left:"
    printf '%s\n' "$left" | sed 's/^/  /'
fi
