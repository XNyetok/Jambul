#!/usr/bin/env bash
# Keeps secrets and personal data out of Jambul's public repository. The git hooks that
# scripts/setup.sh installs run it on every commit, commit message, merge and push, and CI runs it again on GitHub.
#
#   scripts/scan.sh staged             the files staged for the next commit, and who is committing them
#   scripts/scan.sh message <file>     a commit message
#   scripts/scan.sh text <file>        any other text that ends up in history, such as a pull request's title and
#                                      description, which become the squash commit's message
#   scripts/scan.sh pre-push <remote> <url>
#                                      what git is about to push, given as git gives it to a pre-push hook on stdin
#   scripts/scan.sh range <revs>...    commits, as `git rev-list` takes them (main..topic): their files, messages,
#                                      authors and committers
#   scripts/scan.sh tree               every file in the index
#   scripts/scan.sh history            every commit, tag and ref name
#
# Every file is read straight from git by its object ID, never by its path, and scanned whole:
# - Jambul's own rules, applied by this script so nothing escapes them: home-folder paths, email addresses other than
#   the project's public ones, CI skip markers in messages, files that must never be committed
#   (signing material, logs, private phase plans), and archives, PDFs and executables, which can't be
#   read for any of this.
# - gitleaks' default rules for hundreds of token and key formats. Each file is handed to it under a plain number and
#   after a blank first line, so it can't skip a file by its name or by its first bytes.
# - Private patterns: strings that must never appear but can't be listed in the repository without publishing them,
#   such as a maintainer's private email addresses or their Mac's name. They come from .git/info/private-patterns
#   (one per line, # starts a comment) and, in CI, from the JAMBUL_PRIVATE_PATTERNS secret. They match as written,
#   and also with case, punctuation, whitespace and line breaks ignored, in paths, contents, messages and names.
#
# Findings are reported by rule and place only, never by content, so the report can't leak what it found. Anything that
# goes wrong fails the scan rather than skipping part of it. Runs under the bash 3.2 that ships with macOS as well as
# on Linux.
set -uo pipefail
# Byte by byte: in a UTF-8 locale, BSD tools give up on binary content and would report nothing.
export LC_ALL=C
# A replacement object would show the scan one commit while the push sends another.
export GIT_NO_REPLACE_OBJECTS=1

root=$(git rev-parse --show-toplevel) || exit 2
cd "$root" || exit 2

if [[ -t 2 ]]; then red=$'\033[31m' green=$'\033[32m' reset=$'\033[0m'; else red='' green='' reset=''; fi
found=0
fail() {
    printf '%s✘ %s%s\n' "$red" "$1" "$reset" >&2
    found=1
}

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/no-ignore"

if ! command -v gitleaks > /dev/null; then
    fail "gitleaks isn't installed. Install it with 'brew install gitleaks' (see CONTRIBUTING.md)."
    exit 1
fi

# Jambul's rules. Each is an extended regular expression, matched without regard to case where noted.
home_path='/Users/[A-Za-z0-9._-]+'
home_path_allowed='^/Users/(Shared|you|username|USER|name)$'
email='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}'
email_allowed='^(debi@elysiumx[.]org|[^@]+@users[.]noreply[.]github[.]com|(noreply|support|git)@github[.]com|[^@]+@example[.](com|org|net))$'
# Case-insensitive: a commit message that would keep CI from running on it.
skip_marker='[[](skip ci|ci skip|no ci|skip actions|actions skip)[]]|^[[:space:]]*skip-checks[[:space:]]*:[[:space:]]*true'
# Case-insensitive: paths that must never be committed.
forbidden_path='[.](p12|pfx|cer|crt|der|pem|key|p8|mobileprovision|provisionprofile|keychain|keychain-db|log|ips|crash|spindump|shutdownstall|diag|tracev3|logarchive|zip|tar|tgz|gz|bz2|xz|7z|rar|dmg|pkg|xip|ipa|pdf|rtf|rtfd)$|(^|/)[.]env([.][^/]*)?$|(^|/)diagnosticreports/|(^|/)docs/phase-[^/]*$'
# Case-insensitive: images, which gitleaks reads as binary anyway. Jambul's own rules still read them.
image_path='[.](png|jpe?g|gif|icns|heic|webp|tiff?|bmp|ico)$'

# The private patterns, as written and normalized: lowercase letters and digits only, at least four of them.
patterns=$scratch/patterns
normalized=$scratch/patterns-normalized
{
    [[ -n ${JAMBUL_PRIVATE_PATTERNS:-} ]] && printf '%s\n' "$JAMBUL_PRIVATE_PATTERNS"
    private_file=$(git rev-parse --git-path info/private-patterns)
    [[ -f $private_file ]] && cat "$private_file"
} | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' > "$patterns"
tr -cd '[:alnum:]\n' < "$patterns" | tr '[:upper:]' '[:lower:]' | awk 'length >= 4' > "$normalized"
if [[ ! -s $patterns ]]; then
    if [[ ${JAMBUL_REQUIRE_PRIVATE_PATTERNS:-} == true ]]; then
        fail "no private patterns were loaded, though this run requires them: is the JAMBUL_PRIVATE_PATTERNS secret set?"
        exit 1
    fi
    echo "(No private patterns are set up for this clone; see \"Keeping secrets out\" in CONTRIBUTING.md.)" >&2
fi

# Whether a file holds a private pattern, as written or normalized.
has_private_file() {
    [[ -s $patterns ]] || return 1
    grep -a -q -i -F -f "$patterns" "$1" && return 0
    [[ -s $normalized ]] && tr -cd '[:alnum:]' < "$1" | tr '[:upper:]' '[:lower:]' | grep -a -q -F -f "$normalized"
}

# Whether a string, such as a path or a ref's name, holds a private pattern.
has_private() {
    printf '%s\n' "$1" > "$scratch/probe"
    has_private_file "$scratch/probe"
}

# How to name a path or ref in the report: quoted so odd characters can't garble it, or not at all if it's private.
name_of() {
    if has_private "$1"; then echo "<a name holding a private pattern>"; else printf '%q' "$1"; fi
}

# The numbers of the lines of a file that match an extended regular expression (case-insensitive with -i first),
# leaving out matches of a second expression, comma-separated.
lines_matching() {
    local flags='' file regex allowed=''
    [[ $1 == -i ]] && { flags=-i; shift; }
    file=$1 regex=$2
    [[ $# -gt 2 ]] && allowed=$3
    if [[ -n $allowed ]]; then
        grep -a -n -o $flags -E -- "$regex" "$file" | grep -v -E -- "^[0-9]+:${allowed#^}" | cut -d: -f1 | sort -un \
            | paste -sd, -
    else
        grep -a -n $flags -E -- "$regex" "$file" | cut -d: -f1 | sort -un | paste -sd, -
    fi
}

# Fails if a file holds a private pattern, saying on which lines when it's written as is.
check_private() {
    local what=$1 file=$2 lines
    [[ -s $patterns ]] || return 0
    lines=$(grep -a -n -i -F -f "$patterns" "$file" | cut -d: -f1 | sort -un | paste -sd, -)
    if [[ -n $lines ]]; then
        fail "$what: a private pattern on line $lines"
    elif has_private_file "$file"; then
        fail "$what: a private pattern, written with other case, punctuation or line breaks"
    fi
}

# Applies Jambul's content rules to a file. Messages may name contributors in trailers, may not skip CI, and are
# otherwise held to the same rules as files.
check_rules() {
    local what=$1 file=$2 kind=$3 subject=$2 lines
    if [[ $kind == message ]]; then
        # Addresses in Co-authored-by and Signed-off-by trailers are contributors' own, as GitHub and Dependabot write
        # them. The lines stay in place so line numbers hold.
        awk '{ l = tolower($0); if (l ~ /^[[:space:]]*(co-authored-by|signed-off-by)[[:space:]]*:/) print ""; else print }' \
            "$file" > "$scratch/without-trailers"
        subject=$scratch/without-trailers
        lines=$(lines_matching -i "$file" "$skip_marker")
        [[ -n $lines ]] && fail "$what: a marker that would keep CI from running, on line $lines"
    fi
    lines=$(lines_matching "$file" "$home_path" "$home_path_allowed")
    [[ -n $lines ]] && fail "$what: a home-folder path on line $lines"
    lines=$(lines_matching "$subject" "$email" "$email_allowed")
    [[ -n $lines ]] && fail "$what: an email address that isn't one of the project's public ones, on line $lines"
}

# Fails if a file of "Name <email>" lines holds a private identity.
check_identity() {
    local what=$1 file=$2
    has_private_file "$file" && fail "$what is a private identity"
}

# Runs gitleaks with its default rules on the given target, leaving findings as rule, file and line.
gitleaks_run() {
    rm -f "$scratch/leaks" "$scratch/leaks-errors"
    gitleaks "$@" --config "$root/.gitleaks.toml" --gitleaks-ignore-path "$scratch/no-ignore" --ignore-gitleaks-allow \
        --no-banner --log-level error --redact --report-format template \
        --report-template "$root/scripts/gitleaks-report.tmpl" --report-path "$scratch/leaks" \
        > /dev/null 2> "$scratch/leaks-errors"
}

# Reports gitleaks' findings from its last run, naming files through a map of "number<TAB>label" lines if given. The
# line numbers allow for the blank line each file and text was given first.
report_leaks() {
    local what=$1 status=$2 map=${3:-} rule file line label
    [[ $status -eq 0 ]] && return
    if [[ -s $scratch/leaks ]]; then
        while IFS='|' read -r rule file line; do
            [[ -z $rule ]] && continue
            label=$what
            if [[ -n $map ]]; then
                label=$(awk -F'\t' -v n="${file#./}" '$1 == n { print $2; exit }' "$map")
                [[ -z $label ]] && label="$what: a file"
            fi
            fail "$label: $rule, on line $((line - 1))"
        done < "$scratch/leaks"
    elif has_private_file "$scratch/leaks-errors"; then
        fail "$what: gitleaks couldn't scan"
    else
        # Failing without a finding is gitleaks itself failing, which mustn't let anything through either.
        fail "$what: gitleaks couldn't scan: $(head -c 300 "$scratch/leaks-errors")"
    fi
}

# Scans text that becomes part of history: a commit or tag message, or a pull request's title and description.
check_text() {
    local what=$1 file=$2
    { echo; cat "$file"; } > "$scratch/text"
    gitleaks_run stdin < "$scratch/text"
    report_leaks "$what" $?
    check_rules "$what" "$file" message
    check_private "$what" "$file"
}

# Fails if a file starts like an archive, a PDF, an RTF document or an executable, none of which can be read for any
# of this.
check_readable() {
    local what=$1 file=$2 magic
    magic=$(head -c 5 "$file" | od -An -tx1 | tr -d ' \n')
    case $magic in
    504b0304* | 25504446* | 7b5c727466* | cffaedfe* | cefaedfe* | feedface* | feedfacf* | cafebabe* | 7f454c46* \
        | 1f8b* | 377abcaf* | 52617221* | 78617221*)
        fail "$what: an archive, PDF, RTF document or executable, which can't be scanned"
        ;;
    esac
}

# Scans the blobs listed in a file of NUL-terminated "mode sha path" records: each path, then each blob's contents.
scan_blobs() {
    local what=$1 list=$2 record mode rest sha path label n=0 out
    out=$(mktemp -d "$scratch/blobs.XXXXXX")
    mkdir "$out/gitleaks"
    : > "$out/map"
    while IFS= read -r -d '' record; do
        mode=${record%% *}
        rest=${record#* }
        sha=${rest%% *}
        path=${rest#* }
        n=$((n + 1))
        label="$what: $(name_of "$path")"
        has_private "$path" && fail "$what: a path holding a private pattern"
        printf '%s\n' "$path" | grep -q -i -E -- "$forbidden_path" && fail "$label: a kind of file that must never be committed"
        if [[ $mode == 160000 ]]; then
            fail "$label: a submodule, which the scan can't look into"
            continue
        fi
        if ! git cat-file blob "$sha" > "$out/$n" 2> /dev/null; then
            fail "$label: couldn't be read"
            continue
        fi
        check_readable "$label" "$out/$n"
        check_rules "$label" "$out/$n" file
        check_private "$label" "$out/$n"
        if ! printf '%s\n' "$path" | grep -q -i -E -- "$image_path"; then
            { echo; cat "$out/$n"; } > "$out/gitleaks/$n"
            printf '%s\t%s\n' "$n" "$label" >> "$out/map"
        fi
    done < "$list"
    if [[ -n $(ls "$out/gitleaks") ]]; then
        (cd "$out/gitleaks" && gitleaks_run dir .)
        report_leaks "$what" $? "$out/map"
    fi
    rm -rf "$out"
}

# Turns `git diff --raw -z` output on stdin into "mode sha path" records, keeping the new side.
records_from_raw() {
    local header path
    while IFS= read -r -d '' header && IFS= read -r -d '' path; do
        set -- $header
        printf '%s %s %s\0' "$2" "$4" "$path"
    done
}

# Scans commits: who made them, their messages, and every file they add or change, merges included.
scan_range() {
    local commit short
    if ! git rev-list --reverse "$@" > "$scratch/commits" 2> "$scratch/errors"; then
        if has_private_file "$scratch/errors"; then
            fail "couldn't list the commits to scan"
        else
            fail "couldn't list the commits to scan: $(head -c 300 "$scratch/errors")"
        fi
        return
    fi
    while IFS= read -r commit; do
        short=$(git rev-parse --short "$commit")
        git show -s --format='%an <%ae>%n%cn <%ce>' "$commit" > "$scratch/who"
        check_identity "commit $short: its author or committer" "$scratch/who"
        git show -s --format='%B' "$commit" > "$scratch/message"
        check_text "commit $short's message" "$scratch/message"
        if ! git diff-tree -r -m --root --raw -z --no-commit-id --no-renames --diff-filter=ACMT "$commit" \
            > "$scratch/raw"; then
            fail "commit $short: its changes couldn't be listed"
            continue
        fi
        records_from_raw < "$scratch/raw" | LC_ALL=C sort -z -u > "$scratch/records"
        scan_blobs "commit $short" "$scratch/records"
    done < "$scratch/commits"
}

# Scans an annotated tag: its name as pushed and as written inside it, its tagger and its message, and the same for
# any tag it points at in turn.
check_tag() {
    local tag=$1 label depth=0 inner type
    label="tag $(name_of "$2")"
    has_private "$2" && fail "a tag's name holds a private pattern"
    while :; do
        if ! git cat-file tag "$tag" > "$scratch/tag" 2> /dev/null; then
            fail "$label: couldn't be read"
            return
        fi
        inner=$(sed -n 's/^tag //p' "$scratch/tag" | head -1)
        has_private "$inner" && fail "$label: the name written inside it holds a private pattern"
        sed -n 's/^tagger //p' "$scratch/tag" | sed 's/ [0-9]* [-+][0-9]*$//' > "$scratch/who"
        check_identity "$label: its tagger" "$scratch/who"
        sed '1,/^$/d' "$scratch/tag" > "$scratch/tag-message"
        check_text "$label's message" "$scratch/tag-message"
        type=$(sed -n 's/^type //p' "$scratch/tag" | head -1)
        [[ $type == tag ]] || return
        tag=$(sed -n 's/^object //p' "$scratch/tag" | head -1)
        label="$label, in the tag it points at"
        depth=$((depth + 1))
        [[ $depth -lt 10 ]] || { fail "$label: tags nested too deep to follow"; return; }
    done
}

mode=${1:-}
[[ $# -gt 0 ]] && shift
case $mode in
staged)
    # Author and committer travel with the commit, so a private address there would be published too.
    { git var GIT_AUTHOR_IDENT; git var GIT_COMMITTER_IDENT; } 2> /dev/null | sed 's/ [0-9]* [-+][0-9]*$//' > "$scratch/who"
    check_identity "the commit's author or committer" "$scratch/who"
    if ! git diff --cached --raw -z --no-renames --diff-filter=ACMT > "$scratch/raw"; then
        fail "the staged changes couldn't be listed"
    fi
    records_from_raw < "$scratch/raw" > "$scratch/records"
    scan_blobs "staged" "$scratch/records"
    ;;
message | text)
    [[ $# -eq 1 ]] || { echo "usage: scripts/scan.sh $mode <file>" >&2; exit 2; }
    if [[ $mode == message ]]; then check_text "the commit message" "$1"; else check_text "the text" "$1"; fi
    ;;
pre-push)
    url=${2:-${1:-}}
    zero=$(git hash-object --stdin < /dev/null | tr '0-9a-f' '0')
    cat > "$scratch/push"
    # Commits the remote already has, as the remote itself tells: this clone's tracking refs can be stale, or belong to
    # another repository behind the same name.
    have=()
    if git ls-remote "$url" > "$scratch/remote-refs" 2> /dev/null; then
        while read -r sha ref; do
            git cat-file -e "$sha^{commit}" 2> /dev/null && have+=("^$sha")
        done < "$scratch/remote-refs"
    else
        fail "couldn't ask the remote which commits it already has, so the new ones can't be told apart"
    fi
    while read -r local_ref local_sha remote_ref remote_sha; do
        # A ref being deleted carries nothing.
        [[ $local_sha == "$zero" ]] && continue
        has_private "$local_ref $remote_ref" && fail "a ref's name holds a private pattern"
        [[ $(git cat-file -t "$local_sha" 2> /dev/null) == tag ]] && check_tag "$local_sha" "${remote_ref#refs/tags/}"
        if ! target=$(git rev-parse --verify --quiet "$local_sha^{commit}"); then
            fail "a pushed ref points at something other than a commit, which this scan doesn't cover"
            continue
        fi
        scan_range "$target" ${have[@]+"${have[@]}"}
    done < "$scratch/push"
    ;;
range)
    [[ $# -gt 0 ]] || { echo "usage: scripts/scan.sh range <revs>..." >&2; exit 2; }
    scan_range "$@"
    ;;
tree)
    if ! git ls-files -s -z > "$scratch/index"; then
        fail "the index couldn't be listed"
    fi
    while IFS= read -r -d '' entry; do
        meta=${entry%%$'\t'*}
        set -- $meta
        printf '%s %s %s\0' "$1" "$2" "${entry#*$'\t'}"
    done < "$scratch/index" > "$scratch/records"
    scan_blobs "the index" "$scratch/records"
    ;;
history)
    scan_range --all
    git for-each-ref --format='%(objecttype) %(objectname) %(refname)' > "$scratch/refs"
    while read -r type object ref; do
        has_private "$ref" && fail "a ref's name holds a private pattern"
        [[ $type == tag ]] && check_tag "$object" "${ref#refs/tags/}"
    done < "$scratch/refs"
    ;;
*)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
    exit 2
    ;;
esac

if [[ $found -ne 0 ]]; then
    cat >&2 <<'EOF'

Nothing was let through. Remove what was found; for a false positive, see "Keeping secrets out" in CONTRIBUTING.md.
Skipping the hooks only moves the problem: CI runs the same scan on every push and pull request.
EOF
    exit 1
fi
printf '%s✔ no secrets or personal data found (%s)%s\n' "$green" "$mode" "$reset" >&2
