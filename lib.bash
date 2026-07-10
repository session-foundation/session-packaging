# lib.bash — shared helpers for the session-packaging deb-* tools.
#
# Sourced by every deb-* tool. Callers must set `set -euo pipefail` themselves
# (each tool does). This file only defines functions + a few globals; sourcing it
# has no side effects beyond loading the distro data.

# Absolute path to this repo (where the tools + build-distros.bash live).
SP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Absolute path of the tool that sourced us, captured now — before any tool cd's
# into a checkout (resolve_repo) — so usage() can still read its own header.
SELF="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[1]:-$0}")"
# shellcheck source=build-distros.bash
source "$SP_ROOT/build-distros.bash"

# Canonical hostnames for anything we generate (old names still work but new
# uses standardise on these).
DEB_REPO_HOST="deb.session.foundation"
BUILDS_HOST="builds.session.codes"

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------
# Colours, but only on a terminal and unless NO_COLOR is set.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\e[0m'  C_ERR=$'\e[1;31m'  C_WARN=$'\e[33m'   C_OK=$'\e[1;32m'
    C_HDR=$'\e[1;36m' C_PKG=$'\e[1;35m'  C_VER=$'\e[1;36m'  C_DIM=$'\e[2m'  C_BOLD=$'\e[1m'
    # Distro brand colours (24-bit): Debian red #D70A53, Ubuntu orange #E95420.
    C_DEB=$'\e[1;38;2;215;10;83m' C_UBU=$'\e[1;38;2;233;84;32m'
else
    C_RESET='' C_ERR='' C_WARN='' C_OK='' C_HDR='' C_PKG='' C_VER='' C_DIM='' C_BOLD=''
    C_DEB='' C_UBU=''
fi

# Wrap text in a colour (helpers for call sites). cpkg colours each whitespace-
# separated name: for a distro branch the "debian/"/"ubuntu/" prefix takes the
# brand colour (Debian red / Ubuntu orange) and the codename is plain bold; other
# names (repo names, bare codenames) use the default package colour.
cpkg() {
    local -a words; local w out="" sep=""
    read -ra words <<< "$*"
    for w in "${words[@]}"; do
        case "$w" in
            debian/*) out+="$sep$C_DEB${w%%/*}/$C_RESET$C_BOLD${w#*/}$C_RESET" ;;
            ubuntu/*) out+="$sep$C_UBU${w%%/*}/$C_RESET$C_BOLD${w#*/}$C_RESET" ;;
            *)        out+="$sep$C_PKG$w$C_RESET" ;;
        esac
        sep=" "
    done
    printf '%s' "$out"
}
cver() { printf '%s%s%s' "$C_VER" "$*" "$C_RESET"; }   # versions
# Like cver but dims a trailing distro suffix (~debN / ~ubuntuNNNN, plus any +M
# rebuild counter) so the shared base version stands out. The required digit after
# deb/ubuntu keeps an upstream tag like ~debug or ~pre from matching.
cvers() {
    local v="$1"
    if [[ "$v" =~ ~(deb|ubuntu)[0-9].*$ ]]; then
        printf '%s%s%s%s%s%s' "$C_VER" "${v%"${BASH_REMATCH[0]}"}" "$C_RESET" \
                              "$C_DIM" "${BASH_REMATCH[0]}" "$C_RESET"
    else
        printf '%s%s%s' "$C_VER" "$v" "$C_RESET"
    fi
}

# Render TEXT as an OSC 8 terminal hyperlink to URL on a terminal; plain otherwise.
hyperlink() {
    if [ -t 2 ]; then printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"
    else printf '%s' "$2"; fi
}

# Informational output goes to stderr so stdout stays clean for capture.
msg()  { printf '%s\n' "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

# Print a script's leading header-comment block (its usage docs) to stderr,
# stripping the leading "# ": everything from just after the shebang up to the
# first non-comment line.
print_header() {
    awk 'NR==1 { next }
         /^#/  { sub(/^# ?/, ""); if (!seen && $0 == "") next; seen=1; print; next }
         { exit }' "$1" >&2
}

# Print the calling script's header-comment usage docs and exit (status default 1).
# Uses SELF (absolute) so it works even after a tool has cd'd into a checkout.
usage() { print_header "$SELF"; exit "${1:-1}"; }

# A single status line that updates in place. On a terminal it rewrites the
# current line (carriage-return + clear-to-end); when output is redirected it
# prints only when the text changes (so logs don't fill with duplicates).
_last_status=""
render_status() {
    local s="$*"
    if [ -t 2 ]; then printf '\r\033[K%s' "$s" >&2
    elif [ "$s" != "$_last_status" ]; then printf '%s\n' "$s" >&2; fi
    _last_status="$s"
}
render_status_end() { [ -t 2 ] && printf '\n' >&2; _last_status=""; return 0; }

# A multi-line status block (one line per argument) that updates in place on a
# terminal — it moves the cursor up over the previous block and rewrites each
# line. When output is redirected it prints the block only when it changes. The
# entry count must stay constant between calls within one block.
_block_lines=0
render_block() {
    if [ -t 2 ]; then
        [ "$_block_lines" -gt 0 ] && printf '\033[%dA' "$_block_lines" >&2
        local l
        for l in "$@"; do printf '\r\033[K%s\n' "$l" >&2; done
        _block_lines=$#
    else
        local joined; joined="$(printf '%s\n' "$@")"
        [ "$joined" = "$_last_status" ] || { printf '%s\n' "$@" >&2; _last_status="$joined"; }
    fi
}
render_block_end() { _block_lines=0; _last_status=""; return 0; }

# Extract the short arch label from a stage name like "Ubuntu resolute (amd64)".
stage_arch() { case "$1" in *\(*\)) local a="${1##*(}"; printf '%s' "${a%)}" ;; *) printf '%s' "$1" ;; esac; }

# Coloured "<repo>(<state>)" tag for a drone build status, for the CI line.
ci_tag() {
    local r="$1" s="$2" c label
    case "$s" in
        success)                       c="$C_OK";   label=done ;;
        running)                       c="$C_WARN"; label=building ;;
        pending|"")                    c="$C_DIM";  label=queued ;;
        none)                          c="$C_DIM";  label=no-build ;;
        failure|error|killed|declined) c="$C_ERR";  label="$s" ;;
        *)                             c="$C_DIM";  label="$s" ;;
    esac
    printf '%s%s(%s)%s' "$c" "$r" "$label" "$C_RESET"
}

# Yes/no prompt (default no). Returns 0 on yes.
confirm() {
    local reply
    printf '%s [y/N] ' "$*" >&2
    read -r reply || true
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------------------
# repo resolution + git state
# ---------------------------------------------------------------------------
# Validate <repo> is a managed checkout and cd into it. Sets REPO, GITDIR,
# STATE_FILE.
resolve_repo() {
    local r="${1%/}"
    [ -n "$r" ] || die "no repository given"
    local d="$SP_ROOT/$r"
    [ -e "$d/.git" ] || die "repo '$r' not found in $SP_ROOT — clone it there first"
    cd "$d"
    REPO="$r"
    GITDIR="$(cd "$(git rev-parse --git-dir)" && pwd)"
    STATE_FILE="$GITDIR/session-pkg-state"
}

# Does a git operation (merge/cherry-pick/rebase) still need resolving?
git_op_in_progress() {
    [ -e "$GITDIR/MERGE_HEAD" ]        || [ -e "$GITDIR/CHERRY_PICK_HEAD" ] || \
    [ -e "$GITDIR/rebase-merge" ]      || [ -e "$GITDIR/rebase-apply" ]
}

# Refuse to start if the working tree has uncommitted changes. Submodules are
# ignored: packaging never touches their contents (CI does `submodule update` at
# build time), and a submodule checked out at a different commit than the branch
# records is normal here and must not count as "dirty".
require_clean_tree() {
    git update-index -q --refresh --ignore-submodules=all 2>/dev/null || true
    if ! git diff --quiet --ignore-submodules=all ||
       ! git diff --cached --quiet --ignore-submodules=all; then
        die "working tree of $REPO is not clean; commit or stash first"
    fi
}

# Newest existing ubuntu/* branch (highest ~ubuntuNNNN), or empty + return 1.
newest_ubuntu() {
    local b best="" bestnum=-1 num
    for b in "${!version_suffix[@]}"; do
        case "$b" in ubuntu/*) ;; *) continue ;; esac
        branch_exists "$b" || continue
        num="$(printf '%s' "${version_suffix[$b]}" | sed -n 's/^~ubuntu\([0-9]\+\)$/\1/p')"
        [ -n "$num" ] || continue
        if [ "$num" -gt "$bestnum" ]; then bestnum="$num"; best="$b"; fi
    done
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}

# Does the current repo have a branch to fork <branch>'s family from? (debian
# forks from debian/sid; ubuntu from the newest ubuntu branch.) Used to skip
# repos that simply don't do a given distro family.
family_base_exists() {
    case "$1" in
        debian/*) branch_exists debian/sid ;;
        ubuntu/*) newest_ubuntu >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# The branch to fork <branch> from: debian/sid for debian/*, the newest existing
# ubuntu/* for ubuntu/*. Prints it, or empty + return 1 if there's no base.
base_for() {
    case "$1" in
        debian/*) branch_exists debian/sid && printf 'debian/sid\n' || return 1 ;;
        ubuntu/*) newest_ubuntu ;;
        *) return 1 ;;
    esac
}

branch_exists() {
    git show-ref --verify --quiet "refs/heads/$1" ||
    git show-ref --verify --quiet "refs/remotes/origin/$1"
}

# The most useful ref for reading a branch: local if present, else origin/.
branch_ref() {
    if git show-ref --verify --quiet "refs/heads/$1"; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "origin/$1"
    fi
}

# Assert every active distro branch exists; otherwise point at deb-add-distro.
require_branches() {
    local b; local -a missing=() branches
    if [ -n "${TARGET:-}" ]; then read -ra branches <<< "$TARGET"; else branches=("${distros[@]}"); fi
    for b in "${branches[@]}"; do
        branch_exists "$b" || missing+=("$b")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "missing branch(es): ${missing[*]}
create them first with:  ./deb-add-distro $REPO <branch>"
    fi
}

# Fast-forward the local branch to origin (creating it if absent). Fails loudly
# on divergence rather than making a merge commit.
checkout_uptodate() {
    local b="$1"
    git checkout -q "$b" 2>/dev/null || git checkout -q -b "$b" "origin/$b"
    if git show-ref --verify --quiet "refs/remotes/origin/$b"; then
        git merge --ff-only -q "origin/$b" ||
            die "$b has diverged from origin/$b; reconcile it manually"
    fi
}

# ---------------------------------------------------------------------------
# distro-branch creation (deb-add-distro, and deb-version-bump --create-missing)
# ---------------------------------------------------------------------------
# Refuse if the builder docker image for <codename> doesn't exist. The image name
# pattern comes from <baseref>'s .drone.jsonnet distro_docker line.
check_builder_image() {
    local baseref="$1" codename="$2" line prefix suffix image
    line="$(git show "$baseref:.drone.jsonnet" 2>/dev/null | grep -m1 'distro_docker *=')" ||
        { warn "no distro_docker line in .drone.jsonnet; skipping builder-image check"; return 0; }
    prefix="$(printf '%s' "$line" | sed -n "s/.*=[ \t]*'\([^']*\)'[ \t]*+[ \t]*distro.*/\1/p")"
    suffix="$(printf '%s' "$line" | sed -n "s/.*distro[ \t]*+[ \t]*'\([^']*\)'.*/\1/p")"
    [ -n "$prefix" ] || { warn "cannot parse distro_docker; skipping builder-image check"; return 0; }
    image="$prefix$codename$suffix"
    msg "Checking builder image: $image"
    if command -v docker >/dev/null 2>&1; then
        docker manifest inspect "$image" >/dev/null 2>&1 && return 0
        die "builder image '$image' not found — build it in ../session-docker-ci first"
    elif command -v skopeo >/dev/null 2>&1; then
        skopeo inspect "docker://$image" >/dev/null 2>&1 && return 0
        die "builder image '$image' not found — build it in ../session-docker-ci first"
    else
        warn "neither docker nor skopeo available; cannot verify builder image $image"
    fi
}

# Create a new distro branch <newbranch> by forking <base> (default: its family
# base via base_for) and applying the structural edits: .drone.jsonnet distro,
# debian/gbp.conf debian-branch + dist, and origin tracking (so a later bare `git
# push` targets origin/<newbranch>, which doesn't exist yet, rather than the base).
# Leaves the branch checked out with those two files STAGED but not committed, and
# touches neither the changelog nor debian/control — the caller sets the version
# and commits (deb-add-distro: a same-version entry; deb-version-bump: the
# new-version bump). Sets CREATED_BASE / CREATED_BASEREF. The caller is responsible
# for the builder-image check (via check_builder_image) beforehand.
create_distro_branch() {
    local newbranch="$1" base="${2:-}" family codename
    family="${newbranch%%/*}"; codename="${newbranch#*/}"
    case "$family" in debian|ubuntu) ;; *) die "cannot create '$newbranch': not a debian/ or ubuntu/ branch" ;; esac
    [ -n "${version_suffix[$newbranch]:-}" ] ||
        die "no version suffix defined for '$newbranch' in build-distros.bash"
    [ -n "$base" ] || base="$(base_for "$newbranch")" || die "$REPO has no base branch to fork $newbranch from"
    CREATED_BASE="$base"
    CREATED_BASEREF="$(branch_ref "$base")"
    msg "Forking $(cpkg "$newbranch") from $(cpkg "$base")"

    git checkout -q --no-track -b "$newbranch" "$CREATED_BASEREF"
    git config "branch.$newbranch.remote" origin
    git config "branch.$newbranch.merge" "refs/heads/$newbranch"

    sed -i "s/^local distro = '[^']*';/local distro = '$codename';/" .drone.jsonnet
    grep -q "^local distro = '$codename';" .drone.jsonnet ||
        die "failed to update 'local distro' in .drone.jsonnet"

    sed -i -e "s#^debian-branch = .*#debian-branch = $newbranch#" \
           -e "s#^dist = .*#dist = $codename#" debian/gbp.conf
    grep -q "^debian-branch = $newbranch\$" debian/gbp.conf ||
        die "failed to update debian-branch in debian/gbp.conf"
    grep -q "^dist = $codename\$" debian/gbp.conf ||
        die "failed to update dist in debian/gbp.conf"

    git add .drone.jsonnet debian/gbp.conf
}

# Strip branch <2>'s ~suffix off version <1>, e.g. (1.3.0-2~deb13, debian/trixie)
# -> 1.3.0-2. A branch with no suffix (debian/sid) returns the version unchanged.
strip_suffix() {
    local v="$1" s="${version_suffix[$2]:-}"
    [ -n "$s" ] && printf '%s\n' "${v%"$s"}" || printf '%s\n' "$v"
}

# Fork <newbranch> off <base> (default: its family base via base_for) and give it a
# debut changelog entry at the base's *current* version + <newbranch>'s ~suffix,
# distribution = codename. This is the whole of deb-add-distro, and is what
# deb-version-bump uses to fork a brand-new distro off a just-bumped base (so it
# debuts at the new release with no invented history). deb-version-bump passes an
# explicit <base> pinned to a pre-run branch, so forking several new distros at
# once never chains one off another. Commits; sets CREATED_VERSION. The caller must
# have run check_builder_image first.
create_distro_release() {
    local newbranch="$1" base="${2:-}" codename basever title
    codename="${newbranch#*/}"
    create_distro_branch "$newbranch" "$base"   # sets CREATED_BASE/CREATED_BASEREF; stages drone/gbp
    basever="$(strip_suffix "$(changelog_version "$CREATED_BASEREF")" "$CREATED_BASE")"
    CREATED_VERSION="$basever${version_suffix[$newbranch]}"
    title="${codename^} deb"
    msg "  changelog: $(cver "$CREATED_VERSION") ($codename)"
    filter_dch dch --newversion "$CREATED_VERSION" --distribution "$codename" \
        --force-distribution --force-bad-version "$title"
    regen_control
    git add .drone.jsonnet debian/gbp.conf debian/changelog debian/control
    git commit -q -m "$title"
}

# ---------------------------------------------------------------------------
# versions
# ---------------------------------------------------------------------------
# Extract the upstream version from a ref's top-level CMakeLists.txt project().
parse_cmake_version() {
    local ref="$1" v
    v="$(git show "$ref:CMakeLists.txt" 2>/dev/null | python3 -c '
import re, sys
t = sys.stdin.read()
m = re.search(r"\bproject\s*\(.*?\bVERSION\s+([0-9]+(?:\.[0-9]+)*)", t, re.S)
if not m:
    sys.exit(1)
print(m.group(1))
')" || die "could not parse project(... VERSION ...) from $ref:CMakeLists.txt"
    [ -n "$v" ] || die "empty version parsed from $ref:CMakeLists.txt"
    printf '%s\n' "$v"
}

# Top changelog version of a ref, e.g. 1.3.0-3~deb13.
changelog_version() {
    local top
    top="$(git show "$1:debian/changelog" 2>/dev/null)" || return 0
    top="${top%%$'\n'*}"          # first line: "pkg (VERSION) dist; urgency=..."
    top="${top#*(}"               # drop up to the first (
    printf '%s\n' "${top%%)*}"    # keep up to the first )
}

# Upstream portion of a debian version (strip the debian revision + suffix).
upstream_of() { printf '%s\n' "${1%-*}"; }

# Increment the debian revision of a version, dropping any ~suffix.
# 1.3.0-1 -> 1.3.0-2 ;  1.3.0-3~deb13 -> 1.3.0-4
bump_revision() {
    local v="$1" up rev
    up="${v%-*}"
    rev="${v##*-}"
    [[ "$rev" =~ ^([0-9]+) ]] || die "cannot parse debian revision from '$v'"
    printf '%s-%s\n' "$up" "$(( BASH_REMATCH[1] + 1 ))"
}

# Add or increment a +M counter at the end of a version. Used by --only patches:
# they leave -N unchanged (a per-distro -N bump would outrank newer distros'
# packages and break distro-upgrade ordering) and distinguish the rebuild with a
# +M that sorts above the plain version but below the next distro's suffix.
# 1.2.3-2~deb12 -> 1.2.3-2~deb12+1 ;  1.2.3-2~deb12+1 -> 1.2.3-2~deb12+2
bump_plus() {
    local v="$1"
    if [[ "$v" =~ \+([0-9]+)$ ]]; then
        printf '%s+%s\n' "${v%+*}" "$(( BASH_REMATCH[1] + 1 ))"
    else
        printf '%s+1\n' "$v"
    fi
}

# Suffix (~debN / ~ubuntuNNNN) for a branch, from build-distros.bash.
suffix_for() { printf '%s\n' "${version_suffix[$1]:-}"; }

# Expand a bare distro codename (e.g. 'sid', 'trixie', 'noble') to its full
# 'family/codename' branch. The known codenames are the codename halves of the
# version_suffix keys (build-distros.bash); they are unique across debian/ubuntu,
# so the mapping is unambiguous. A token that already contains '/' (a full branch,
# or a glob like 'debian/*') or a bare token matching no known codename is returned
# unchanged, so downstream glob-matching and error reporting are unaffected.
expand_distro() {
    local tok="$1" k
    case "$tok" in */*) printf '%s\n' "$tok"; return ;; esac
    for k in "${!version_suffix[@]}"; do
        [ "${k#*/}" = "$tok" ] && { printf '%s\n' "$k"; return; }
    done
    printf '%s\n' "$tok"
}

# Split comma-separated distro specs (any number of args) and expand each bare
# codename via expand_distro. Prints one expanded token per line.
expand_distro_spec() {
    local arg t
    for arg in "$@"; do
        IFS=, read -ra _toks <<< "$arg"
        for t in "${_toks[@]}"; do [ -n "$t" ] && expand_distro "$t"; done
    done
}

# Changelog distribution field for a branch: the codename, except sid -> unstable.
changelog_dist() {
    if [ "$1" = debian/sid ]; then printf 'unstable\n'; else printf '%s\n' "${1#*/}"; fi
}

# ---------------------------------------------------------------------------
# packaging steps (run inside a checked-out branch)
# ---------------------------------------------------------------------------
# Regenerate debian/control from control.in, if the repo uses that mechanism.
regen_control() {
    local s
    for s in update-lib-version.sh update-liboxen-ver.sh; do
        if [ -x "debian/$s" ]; then
            msg "  regenerating debian/control via debian/$s"
            "./debian/$s"
        fi
    done
}

# Run a dch / gbp-dch command, filtering warnings that don't matter because we
# force the outcome: the "Recognised distributions are: ..." block and the "new
# version ... is less than the current version" note (both from --force-*), and
# the "Distribution data outdated"/"Unable to determine the current … development
# release" pair from an out-of-date distro-info-data (harmless with
# --force-distribution). Preserves the command's exit status and other output.
filter_dch() {
    local err rc=0
    err="$(mktemp)"
    "$@" 2>"$err" || rc=$?
    awk '
        /dch warning: Recognised distributions are:/ { b=1; next }
        b { if (/Using your request anyway\./) b=0; next }
        /dch warning: new version .* is less than/ { n=1; next }
        n { n=0; next }
        /^Distribution data outdated/ { next }
        /Unable to determine the current .* development release/ { next }
        { print }
    ' "$err" >&2
    rm -f "$err"
    return "$rc"
}

# Merge <ref> into the current (debian) branch, auto-resolving the expected
# .drone.jsonnet conflict (keep ours). Returns non-zero if any *other* conflict
# remains for a human to resolve.
merge_upstream() {
    local ref="$1"
    if git merge --no-edit "$ref"; then
        return 0
    fi
    # Auto-resolve .drone.jsonnet if it is among the conflicts.
    if git diff --name-only --diff-filter=U | grep -qx '.drone.jsonnet'; then
        git checkout --ours -- .drone.jsonnet
        git add -- .drone.jsonnet
    fi
    # Any remaining conflicts need a human.
    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
        return 1
    fi
    # Only .drone.jsonnet was conflicted: finish the merge without an editor.
    GIT_EDITOR=true git merge --continue
}

# gbp dch (release, versioned, correct distribution, no editor) + control regen
# + commit. Used by version-bump / add-patch / packaging-update.
# Version for a branch under the current operation: +M under --only (PARTIAL),
# else the shared -N base plus the branch's suffix.
next_version() {
    if [ "${PARTIAL:-0}" = 1 ]; then
        bump_plus "$(changelog_version "$(branch_ref "$1")")"
    else
        printf '%s\n' "$VERSION_BASE$(suffix_for "$1")"
    fi
}

finalize_branch() {
    local b="$1" ver dist
    ver="$(next_version "$b")"
    dist="$(changelog_dist "$b")"
    msg "  changelog: $(cver "$ver") ($dist)"
    filter_dch gbp dch --release --new-version="$ver" \
            --distribution="$dist" --force-distribution \
            --spawn-editor=never --ignore-branch
    regen_control
    git add debian/changelog debian/control
    git commit -q -m "$COMMIT_MSG"
}

# ---------------------------------------------------------------------------
# resume state file (sourceable bash in .git/session-pkg-state)
# ---------------------------------------------------------------------------
# Single-quote a value safely for the sourceable state file.
_sq() { local s="${1//\'/\'\\\'\'}"; printf "'%s'" "$s"; }

# save_state <current-branch> <current-phase>  (both may be empty)
save_state() {
    {
        printf 'operation=%s\n'      "$(_sq "$OPERATION")"
        printf 'version_base=%s\n'   "$(_sq "${VERSION_BASE:-}")"
        printf 'source_ref=%s\n'     "$(_sq "${SOURCE_REF:-}")"
        printf 'commit_msg=%s\n'     "$(_sq "${COMMIT_MSG:-}")"
        printf 'commits=%s\n'        "$(_sq "${COMMITS[*]:-}")"
        printf 'completed=%s\n'      "$(_sq "${COMPLETED:-}")"
        printf 'current_branch=%s\n' "$(_sq "${1:-}")"
        printf 'current_phase=%s\n'  "$(_sq "${2:-}")"
        printf 'target=%s\n'         "$(_sq "${TARGET:-}")"
        printf 'partial=%s\n'        "$(_sq "${PARTIAL:-0}")"
        printf 'missing=%s\n'        "$(_sq "${MISSING[*]:-}")"
        printf 'ubuntu_base=%s\n'    "$(_sq "${UBUNTU_BASE:-}")"
        printf 'nobump=%s\n'         "$(_sq "${NOBUMP:-0}")"
    } > "$STATE_FILE"
}

clear_state() { rm -f "$STATE_FILE"; }

# If a state file exists it must match <op>; load it (sets RESUMING=1 and the
# operation globals). Otherwise RESUMING=0.
begin_or_resume() {
    local op="$1"
    OPERATION="$op"
    RESUMING=0
    COMPLETED=""
    RESUME_CURRENT=""
    CURRENT_PHASE=""
    COMMITS=()
    TARGET=""
    PARTIAL=0
    MISSING=()
    UBUNTU_BASE=""
    NOBUMP=0
    [ -f "$STATE_FILE" ] || return 0

    local operation='' version_base='' source_ref='' commit_msg='' \
          commits='' completed='' current_branch='' current_phase='' \
          target='' partial='' missing='' ubuntu_base='' nobump=''
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    [ "$operation" = "$op" ] || die \
"an unfinished '$operation' operation is in progress for $REPO.
Resume it by re-running its command, or abandon it with:
    rm $STATE_FILE"

    RESUMING=1
    VERSION_BASE="$version_base"
    SOURCE_REF="$source_ref"
    COMMIT_MSG="$commit_msg"
    COMPLETED="$completed"
    RESUME_CURRENT="$current_branch"
    CURRENT_PHASE="$current_phase"
    TARGET="$target"
    PARTIAL="${partial:-0}"
    UBUNTU_BASE="$ubuntu_base"
    NOBUMP="${nobump:-0}"
    read -ra COMMITS <<< "$commits"
    read -ra MISSING <<< "$missing"
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Drive a per-branch operation across all active distros, honouring skip/resume.
# Arg: name of a function taking <branch> and reading RESUME_PHASE (empty unless
# resuming that exact branch).
run_multibranch() {
    local process_fn="$1" b
    local -a branches
    if [ -n "${TARGET:-}" ]; then read -ra branches <<< "$TARGET"; else branches=("${distros[@]}"); fi
    for b in "${branches[@]}"; do
        if in_list "$b" "$COMPLETED"; then
            msg "$C_HDR== $(cpkg "$b")$C_HDR ==$C_RESET $C_DIM(already done, skipping)$C_RESET"
            continue
        fi
        if [ "$RESUMING" = 1 ] && [ "$b" = "$RESUME_CURRENT" ]; then
            RESUME_PHASE="$CURRENT_PHASE"
            msg "$C_HDR== $(cpkg "$b")$C_HDR ==$C_RESET (resuming at '$RESUME_PHASE')"
        else
            RESUME_PHASE=""
            msg "$C_HDR== $(cpkg "$b")$C_HDR ==$C_RESET"
        fi
        "$process_fn" "$b"
        COMPLETED="$COMPLETED $b"
        save_state "" ""
    done
    clear_state
}

# On resume, verify the human actually finished the conflicted git operation.
ensure_resolved() {
    local b="$1" phase="$2"
    if git_op_in_progress; then
        die "the '$phase' conflict on $b is not resolved yet:
a merge/rebase/cherry-pick is still in progress in $(pwd).
Finish it (git {merge,rebase,cherry-pick} --continue) then re-run to resume."
    fi
}

# Print resume instructions and stop. Uses INVOCATION (set by each tool).
conflict_halt() {
    local b="$1" phase="$2" what="$3"
    save_state "$b" "$phase"
    cat >&2 <<EOF

>>> CONFLICT while $what.
    Resolve it in: $(pwd)
      1. fix the conflicted files and 'git add' them
      2. complete the git operation:
           git merge --continue   /   git rebase --continue   /   git cherry-pick --continue
    Then resume with the same command:
      $INVOCATION
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# dependency pre-check (used by deb-push)
# ---------------------------------------------------------------------------
# Heuristic: a package we publish (must be present in our repo) vs a base-distro
# system package (ignored). Extend the pattern as new families appear.
is_our_package() {
    case "$1" in
        *session*|*oxen*|*loki*|*sogs*) return 0 ;;
        *)                              return 1 ;;
    esac
}

# Does the reprepro distribution exist at all (even empty)? Checks for its
# Release index. <suffix> is '', '/beta', '/staging'.
repo_dist_exists() {
    local suffix="$1" distro="$2"
    local base="https://$DEB_REPO_HOST$suffix/dists/$distro"
    curl -fsI "$base/InRelease" >/dev/null 2>&1 || curl -fsI "$base/Release" >/dev/null 2>&1
}

# Version of <pkg> published for <suffix>/<distro>/<arch>, or empty. <suffix> is
# the reprepro repo suffix ('', '/beta', '/staging').
repo_pkg_version() {
    local suffix="$1" distro="$2" arch="$3" pkg="$4"
    local base="https://$DEB_REPO_HOST$suffix/dists/$distro/main/binary-$arch"
    local dl tmp ext name got=1
    dl="$(mktemp)"; tmp="$(mktemp)"
    for ext in xz gz ''; do
        name="Packages"; [ -n "$ext" ] && name="Packages.$ext"
        if curl -fsSL -o "$dl" "$base/$name" 2>/dev/null; then
            case "$ext" in
                xz) xz   -dc "$dl" > "$tmp" 2>/dev/null && got=0 ;;
                gz) gzip -dc "$dl" > "$tmp" 2>/dev/null && got=0 ;;
                '') cp        "$dl"  "$tmp"              && got=0 ;;
            esac
            [ "$got" = 0 ] && break
        fi
    done
    rm -f "$dl"
    if [ "$got" != 0 ]; then rm -f "$tmp"; return 0; fi
    awk -v p="$pkg" '
        $1=="Package:" { cur=$2 }
        $1=="Version:" && cur==p { print $2; exit }
    ' "$tmp"
    rm -f "$tmp"
}

# Check that every "ours" build-dep of <branch> is available at the required
# version in the branch's own target repo (parsed from its .drone.jsonnet).
# Prints problems to stderr; returns non-zero if any dep is unsatisfied.
dep_check() {
    local b="$1" ref
    ref="$(branch_ref "$b")"
    local control distro suffix
    distro="$(drone_local "$ref" distro)"
    [ -n "$distro" ] || { warn "[$b] no/unparseable .drone.jsonnet; skipping dep check"; return 0; }
    suffix="$(drone_local "$ref" repo_suffix)"
    control="$(git show "$ref:debian/control" 2>/dev/null)" ||
        { warn "[$b] no debian/control; skipping"; return 0; }

    # Pull the (folded) Build-Depends field and flatten it to one line.
    local bd
    bd="$(printf '%s\n' "$control" | awk '
        /^Build-Depends:/ { f=1; sub(/^Build-Depends:/,""); print; next }
        f && /^[ \t]/     { print; next }
        f                 { exit }
    ' | tr '\n' ' ')"

    local rc=0 entry pkg ver avail IFS=,
    for entry in $bd; do
        pkg="$(printf '%s' "$entry" | sed -e 's/^[ \t]*//' -e 's/[ \t(|].*//')"
        [ -n "$pkg" ] || continue
        is_our_package "$pkg" || continue
        ver="$(printf '%s' "$entry" | sed -n 's/.*(>=[ \t]*\([^)]*\)).*/\1/p' | tr -d ' ')"
        [ -n "$ver" ] || continue    # no minimum version constraint -> nothing to verify
        avail="$(repo_pkg_version "$suffix" "$distro" amd64 "$pkg")"
        if [ -z "$avail" ]; then
            warn "[$b] $pkg (>= $ver) not found on https://$DEB_REPO_HOST$suffix ($distro)"
            rc=1
        elif ! dpkg --compare-versions "$avail" ge "$ver"; then
            warn "[$b] $pkg $avail is older than required (>= $ver) on https://$DEB_REPO_HOST$suffix ($distro)"
            rc=1
        fi
    done
    return "$rc"
}

# ---------------------------------------------------------------------------
# cross-repo helpers (used by deb-cascade / deb-add-distro-all)
# ---------------------------------------------------------------------------
# Read a `local <name> = '...'` string value from a ref's .drone.jsonnet.
drone_local() {
    git show "$1:.drone.jsonnet" 2>/dev/null |
        sed -n "s/^local $2 = '\([^']*\)'.*/\1/p" | head -1
}

# Binary package names produced by a ref (from its debian/control).
repo_binaries() {
    git show "$1:debian/control" 2>/dev/null | sed -n 's/^Package:[[:space:]]*//p'
}

# The git origin remote of the current repo as an "owner/repo" slug.
origin_slug() {
    git remote get-url origin 2>/dev/null |
        sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##'
}

# True if every binary package produced by the current repo's <branch> is already
# published in <suffix> (e.g. /staging) at >= that branch's changelog version.
published_in_repo() {
    local suffix="$1" branch="$2" ref distro ver pkg avail any=0
    ref="$(branch_ref "$branch")"
    distro="$(drone_local "$ref" distro)"
    ver="$(changelog_version "$ref")"
    [ -n "$distro" ] && [ -n "$ver" ] || return 1
    while read -r pkg; do
        [ -n "$pkg" ] || continue
        any=1
        avail="$(repo_pkg_version "$suffix" "$distro" amd64 "$pkg")"
        [ -n "$avail" ] && dpkg --compare-versions "$avail" ge "$ver" || return 1
    done < <(repo_binaries "$ref")
    [ "$any" = 1 ]      # unknown (no binaries parsed) counts as not-published
}

# ---------------------------------------------------------------------------
# drone CI (used by deb-cascade)
# ---------------------------------------------------------------------------
require_drone() {
    command -v drone >/dev/null 2>&1 ||
        die "the 'drone' CLI is required for CI monitoring but was not found"
    [ -n "${DRONE_SERVER:-}" ] && [ -n "${DRONE_TOKEN:-}" ] ||
        die "DRONE_SERVER and DRONE_TOKEN must be set for CI monitoring"
    export DRONE_SERVER DRONE_TOKEN
}

# Newest build number for <slug> targeting <branch> at commit <sha>, or empty.
# No event filter, so a `drone build restart` (newer, same commit, possibly a
# different event) is found too. `--branch` filters the target branch, which
# already excludes PRs *from* this branch (those target their base branch).
drone_build_for() {
    drone build ls "$1" --branch "$2" --limit 30 \
        --format $'{{.Number}}\t{{.After}}\n' 2>/dev/null |
        awk -v s="$3" '$2==s && !seen {print $1; seen=1}'
}

# Restart a build and return the resulting build number (may differ), or empty.
drone_restart() {
    drone build restart "$1" "$2" >/dev/null 2>&1 || return 1
}

drone_status() { drone build info "$1" "$2" --format $'{{.Status}}\n' 2>/dev/null; }

# One call returning a build's overall status and each stage, as a `STATUS=<s>`
# line followed by `STAGE=<name>=<s>` lines. Guarded so it is never fatal.
drone_build_detail() {
    drone build info "$1" "$2" \
        --format 'STATUS={{.Status}}{{"\n"}}{{range .Stages}}STAGE={{.Name}}={{.Status}}{{"\n"}}{{end}}' \
        2>/dev/null || true
}

drone_terminal() {
    case "$1" in
        success|failure|error|killed|skipped|declined) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# success footer
# ---------------------------------------------------------------------------
push_hint() {
    # Under --only (TARGET set) exactly those branches changed, so point the push
    # command straight at them; a full run leaves it open (all active branches).
    if [ -n "${TARGET:-}" ]; then
        cat >&2 <<EOF

${C_OK}Done.${C_RESET} Nothing has been pushed. When you're ready, push the changed branch(es) with:
    ${C_HDR}./deb-push $REPO $TARGET${C_RESET}
EOF
    else
        cat >&2 <<EOF

${C_OK}Done.${C_RESET} Nothing has been pushed. When you're ready, push with:
    ${C_HDR}./deb-push $REPO${C_RESET}
(or restrict, e.g.  ./deb-push $REPO 'debian/*'   or   ./deb-push $REPO debian/sid)
EOF
    fi
}
