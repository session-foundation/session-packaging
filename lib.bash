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
    C_REPO=$'\e[1;34m' C_PROJ=$'\e[1;92m'
    # Distro brand colours (24-bit): Debian red #D70A53, Ubuntu orange #E95420.
    C_DEB=$'\e[1;38;2;215;10;83m' C_UBU=$'\e[1;38;2;233;84;32m'
else
    C_RESET='' C_ERR='' C_WARN='' C_OK='' C_HDR='' C_PKG='' C_VER='' C_DIM='' C_BOLD=''
    C_REPO='' C_PROJ='' C_DEB='' C_UBU=''
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
# Like cver but dims a trailing distro suffix (~debN / ~ubuntuNNNN) so the shared
# base version stands out. A +M rebuild counter keeps the base colour (not dimmed):
# it marks a real per-distro difference, so it should stand out from the suffix.
# The required digit after deb/ubuntu keeps an upstream tag like ~debug or ~pre
# from matching.
cvers() {
    local v="$1" plus="" suf=""
    if [[ "$v" =~ ([+][0-9]+)$ ]]; then plus="${BASH_REMATCH[1]}"; v="${v%"$plus"}"; fi
    if [[ "$v" =~ ~(deb|ubuntu)[0-9].*$ ]]; then suf="${BASH_REMATCH[0]}"; v="${v%"$suf"}"; fi
    printf '%s%s%s' "$C_VER" "$v" "$C_RESET"
    [ -n "$suf" ]  && printf '%s%s%s' "$C_DIM" "$suf" "$C_RESET"
    [ -n "$plus" ] && printf '%s%s%s' "$C_VER" "$plus" "$C_RESET"
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

# Coloured "<repo>(<state>)" tag for a CI pipeline/workflow status, for the CI line.
ci_tag() {
    local r="$1" s="$2" c label
    case "$s" in
        success)                                c="$C_OK";   label=done ;;
        running)                                c="$C_WARN"; label=building ;;
        pending|created|"")                     c="$C_DIM";  label=queued ;;
        blocked)                                c="$C_WARN"; label=needs-approval ;;
        none)                                   c="$C_DIM";  label=no-build ;;
        failure|error|killed|canceled|declined) c="$C_ERR";  label="$s" ;;
        *)                                      c="$C_DIM";  label="$s" ;;
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
    # Drop this repo's opted-out distro branches (skip_distros in build-distros.bash)
    # from the active set, so every single-repo tool ignores them.
    local b; local -A drop=(); local -a kept=()
    for b in ${skip_distros[$REPO]:-}; do drop[$b]=1; done
    if [ "${#drop[@]}" -gt 0 ]; then
        for b in "${distros[@]}"; do [ -n "${drop[$b]:-}" ] || kept+=("$b"); done
        distros=("${kept[@]}")
    fi
}

# True if <repo> opts out of building <branch> (skip_distros in build-distros.bash).
# For the cross-repo tools, which iterate repos for one branch and so don't go
# through resolve_repo's filtering of `distros`.
repo_skips_branch() {
    local b
    for b in ${skip_distros[$1]:-}; do [ "$b" = "$2" ] && return 0; done
    return 1
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
# packaging CI config
# ---------------------------------------------------------------------------
# A packaging branch's CI config is .woodpecker/override-deb.star: any
# .woodpecker/override* config files replace everything else in .woodpecker/ (a
# session-woodpecker-config feature), so upstream's own .woodpecker/ configs merge
# in unchanged. Branches not yet migrated to it still use a fully replaced
# .drone.jsonnet. Both write their settings as simple assignments that the helpers
# below read: distro, repo_suffix, the builder image (`builder_image`, or
# `distro_docker` in jsonnet) and the arches built.
CI_OVERRIDE=".woodpecker/override-deb.star"

# <ref>'s .woodpecker/override* config files, one per line.
ci_overrides() {
    git ls-tree --name-only "$1" .woodpecker/ 2>/dev/null |
        grep -E '^\.woodpecker/override[^/]*\.(ya?ml|jsonnet|star)$'
}

# <ref>'s packaging CI config files, one per line: its overrides, or .drone.jsonnet.
ci_files() {
    ci_overrides "$1" || printf '%s\n' .drone.jsonnet
}

# The contents of all of <ref>'s packaging CI config files.
ci_source() {
    local f
    while read -r f; do git show "$1:$f" 2>/dev/null; done < <(ci_files "$1")
}

# Read a string setting (`<name> = "..."`, or jsonnet `local <name> = '...';`)
# from <ref>'s packaging CI config.
ci_setting() {
    ci_source "$1" | sed -nE "s/^(local )?$2 = ['\"]([^'\"]*)['\"].*/\2/p" | head -1
}

# The Debian architectures <ref>'s CI builds, one per line: the Starlark `arches`
# list, or the jsonnet deb_pipeline(...) invocations (each `debarch='...'`,
# defaulting to amd64; the deb_pipeline definition line, `... ) = {`, is skipped).
ci_debarches() {
    ci_source "$1" | awk '
        /^arches = \[/ {
            s = $0; sub(/^arches = \[/, "", s); sub(/\].*/, "", s)
            while (match(s, /[a-z0-9]+/)) { print substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
        }
        /deb_pipeline\(/ && $0 !~ /deb_pipeline\([^)]*\)[ \t]*=/ {
            if (match($0, /debarch=.[a-z0-9]+/)) {
                a = substr($0, RSTART, RLENGTH); sub(/debarch=./, "", a); print a
            } else print "amd64"
        }
    ' | awk 'NF && !seen[$0]++'
}

# The config Woodpecker would use for <ref>, one file per line: the first of the
# server's WOODPECKER_DEFAULT_PIPELINE_CONFIGS that exists (.woodpecker/ if it has
# any config files, then .woodpecker.{jsonnet,star,yaml,yml}, then .drone.jsonnet),
# with any override files standing in for all of .woodpecker/. Prints
# `.woodpecker/` for the directory's (non-override) files, or nothing if there is
# no config. Must be kept in step with the server's search order.
ci_config_used() {
    local ref="$1" f
    if git ls-tree --name-only "$ref" .woodpecker/ 2>/dev/null | grep -qE '\.(ya?ml|jsonnet|star)$'; then
        ci_overrides "$ref" || printf '%s\n' .woodpecker/
        return
    fi
    for f in .woodpecker.jsonnet .woodpecker.star .woodpecker.yaml .woodpecker.yml .drone.jsonnet; do
        git cat-file -e "$ref:$f" 2>/dev/null && { printf '%s\n' "$f"; return; }
    done
}

# Check that pushing <branch> would run its packaging build: an upstream that
# switches to .woodpecker/ configs shadows a packaging .drone.jsonnet, and CI then
# runs upstream's builds instead. Warns and returns non-zero if not.
ci_config_check() {
    local b="$1" ref f
    local -a used
    ref="$(branch_ref "$b")"
    mapfile -t used < <(ci_config_used "$ref")
    if [ "${#used[@]}" -eq 0 ]; then
        warn "[$(cpkg "$b")] has no CI config at all"
        return 1
    fi
    case "${used[0]}" in
        .woodpecker/override*|.drone.jsonnet) ;;
        *)  warn "[$(cpkg "$b")] CI would run upstream's ${used[0]} instead of the packaging build: add $CI_OVERRIDE"
            return 1 ;;
    esac
    for f in "${used[@]}"; do
        git show "$ref:$f" | grep -q 'debian/ci-upload\.sh' && return 0
    done
    warn "[$(cpkg "$b")] CI would run ${used[*]}, which isn't a packaging build (it never runs debian/ci-upload.sh)"
    return 1
}

# ---------------------------------------------------------------------------
# distro-branch creation (deb-add-distro, and deb-version-bump --create-missing)
# ---------------------------------------------------------------------------
# Refuse if the builder docker image for <codename> doesn't exist. The image name
# pattern comes from <baseref>'s CI config builder image line.
check_builder_image() {
    local baseref="$1" codename="$2" line prefix suffix image
    line="$(ci_source "$baseref" | grep -m1 -E '^(local )?(builder_image|distro_docker) =')" ||
        { warn "no builder image in the CI config; skipping builder-image check"; return 0; }
    prefix="$(printf '%s' "$line" | sed -nE "s/.*= *['\"]([^'\"]*)['\"] *\+ *distro.*/\1/p")"
    suffix="$(printf '%s' "$line" | sed -nE "s/.*distro *\+ *['\"]([^'\"]*)['\"].*/\1/p")"
    [ -n "$prefix" ] || { warn "cannot parse the CI config's builder image; skipping builder-image check"; return 0; }
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
# base via base_for) and applying the structural edits: the CI config's distro,
# debian/gbp.conf debian-branch + dist, and origin tracking (so a later bare `git
# push` targets origin/<newbranch>, which doesn't exist yet, rather than the base).
# Leaves the branch checked out with those files STAGED but not committed, and
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

    local -a cifiles
    mapfile -t cifiles < <(ci_files HEAD)
    sed -i -E "s/^(local )?distro = (['\"])[^'\"]*(['\"])/\1distro = \2$codename\3/" "${cifiles[@]}"
    grep -qE "^(local )?distro = ['\"]$codename['\"]" "${cifiles[@]}" ||
        die "failed to update distro in ${cifiles[*]}"

    sed -i -e "s#^debian-branch = .*#debian-branch = $newbranch#" \
           -e "s#^dist = .*#dist = $codename#" debian/gbp.conf
    grep -q "^debian-branch = $newbranch\$" debian/gbp.conf ||
        die "failed to update debian-branch in debian/gbp.conf"
    grep -q "^dist = $codename\$" debian/gbp.conf ||
        die "failed to update dist in debian/gbp.conf"

    git add "${cifiles[@]}" debian/gbp.conf
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
    create_distro_branch "$newbranch" "$base"   # sets CREATED_BASE/CREATED_BASEREF; stages CI config/gbp
    basever="$(strip_suffix "$(changelog_version "$CREATED_BASEREF")" "$CREATED_BASE")"
    CREATED_VERSION="$basever${version_suffix[$newbranch]}"
    title="${codename^} deb"
    msg "  changelog: $(cver "$CREATED_VERSION") ($codename)"
    filter_dch dch --newversion "$CREATED_VERSION" --distribution "$codename" \
        --force-distribution --force-bad-version "$title"
    regen_control
    git add debian/changelog debian/control
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

# Numeric debian revision of a version, ignoring any ~suffix/+M.
# 1.3.0-3~deb13+1 -> 3
revision_num() {
    [[ "${1##*-}" =~ ^([0-9]+) ]] || die "cannot parse debian revision from '$1'"
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# Increment the debian revision of a version, dropping any ~suffix.
# 1.3.0-1 -> 1.3.0-2 ;  1.3.0-3~deb13 -> 1.3.0-4
bump_revision() {
    printf '%s-%s\n' "$(upstream_of "$1")" "$(( $(revision_num "$1") + 1 ))"
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

# Resolve branch-selection args (globs and bare codenames, space- or
# comma-separated; none = 'debian/*' 'ubuntu/*') against the active distro list
# into SELECTED, de-duplicated in order. Dies if any glob matches no active branch.
SELECTED=()
select_branches() {
    local g b
    local -a globs hits
    mapfile -t globs < <(expand_distro_spec "$@")
    [ "${#globs[@]}" -gt 0 ] || globs=('debian/*' 'ubuntu/*')
    SELECTED=()
    for g in "${globs[@]}"; do
        hits=()
        for b in "${distros[@]}"; do
            # shellcheck disable=SC2254
            case "$b" in $g) hits+=("$b") ;; esac
        done
        [ "${#hits[@]}" -gt 0 ] || die "no active branch matches '$g'"
        SELECTED+=("${hits[@]}")
    done
    mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | awk '!seen[$0]++')
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
        printf 'only=%s\n'           "$(_sq "${ONLY:-0}")"
        printf 'missing=%s\n'        "$(_sq "${MISSING[*]:-}")"
        printf 'ubuntu_base=%s\n'    "$(_sq "${UBUNTU_BASE:-}")"
        printf 'nobump=%s\n'         "$(_sq "${NOBUMP:-0}")"
        printf 'phase_ref=%s\n'      "$(_sq "${PHASE_REF:-}")"
        printf 'phase_head=%s\n'     "$(_sq "${PHASE_HEAD:-}")"
    } > "$STATE_FILE"
}

clear_state() { rm -f "$STATE_FILE"; }

# begin_phase <branch> <phase>
#
# save_state for a phase whose git operation a resume must be able to tell apart
# from an abandoned one: it also records the checked-out branch and its commit, which
# `git cherry-pick --abort` puts back (see phase_abandoned). Only for a branch's last
# conflict point, since an abandoned phase means starting the whole branch over.
begin_phase() {
    PHASE_REF="$(git symbolic-ref -q HEAD)" || die "begin_phase: HEAD is detached"
    PHASE_HEAD="$(git rev-parse HEAD)"
    save_state "$1" "$2"
}

# On resume: was the interrupted begin_phase operation abandoned, leaving its branch
# where it started with no git operation in progress?
phase_abandoned() {
    [ -n "${PHASE_HEAD:-}" ] && ! git_op_in_progress &&
        [ "$(git rev-parse -q --verify "$PHASE_REF" 2>/dev/null)" = "$PHASE_HEAD" ]
}

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
    ONLY=0
    MISSING=()
    UBUNTU_BASE=""
    NOBUMP=0
    PHASE_REF=""
    PHASE_HEAD=""
    [ -f "$STATE_FILE" ] || return 0

    local operation='' version_base='' source_ref='' commit_msg='' \
          commits='' completed='' current_branch='' current_phase='' \
          target='' partial='' only='' missing='' ubuntu_base='' nobump='' \
          phase_ref='' phase_head=''
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
    ONLY="${only:-0}"
    UBUNTU_BASE="$ubuntu_base"
    NOBUMP="${nobump:-0}"
    PHASE_REF="$phase_ref"
    PHASE_HEAD="$phase_head"
    read -ra COMMITS <<< "$commits"
    read -ra MISSING <<< "$missing"
}

# resume_option <option> <saved value> <given value>
#
# On resume, an option given again must match the interrupted operation's (one left
# out keeps it): the branches already done were made with the saved value.
resume_option() {
    [ "$2" = "$3" ] || die \
"$1 doesn't match the unfinished $OPERATION for $REPO, which uses: ${2:-(none)}
Leave it out to resume with that, or abandon the operation with:
    rm $STATE_FILE"
}

# resume_commits <commit>...
#
# On resume with commits given again: use them instead of the saved ones for the
# branches not done yet. Only allowed if the interrupted branch's cherry-pick was
# abandoned, so that no branch ends up with both.
resume_commits() {
    [ "$*" != "${COMMITS[*]}" ] || return 0
    if [ -n "$RESUME_CURRENT" ] && ! phase_abandoned; then
        if git_op_in_progress; then
            die "the $CURRENT_PHASE on $RESUME_CURRENT is still in progress with the original commits.
To use different commits, abort it first (git cherry-pick --abort), then re-run."
        fi
        die "the $CURRENT_PHASE on $RESUME_CURRENT was completed with the original commits, so it
can't switch to different ones now. Resume without giving commits to carry on with:
    ${COMMITS[*]}"
    fi
    msg "Using $* in place of ${COMMITS[*]} for the branches not done yet"
    [ -z "${COMPLETED// /}" ] || msg "  (already done with the original commits:$COMPLETED)"
    COMMITS=("$@")
    save_state "$RESUME_CURRENT" "$CURRENT_PHASE"
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
        if [ "$RESUMING" = 1 ] && [ "$b" = "$RESUME_CURRENT" ] && phase_abandoned; then
            RESUME_PHASE=""
            msg "$C_HDR== $(cpkg "$b")$C_HDR ==$C_RESET (its '$CURRENT_PHASE' was abandoned; starting it over)"
        elif [ "$RESUMING" = 1 ] && [ "$b" = "$RESUME_CURRENT" ]; then
            RESUME_PHASE="$CURRENT_PHASE"
            msg "$C_HDR== $(cpkg "$b")$C_HDR ==$C_RESET (resuming at '$RESUME_PHASE')"
        else
            RESUME_PHASE=""
            msg "$C_HDR== $(cpkg "$b")$C_HDR ==$C_RESET"
        fi
        "$process_fn" "$b"
        COMPLETED="$COMPLETED $b"
        PHASE_REF="" PHASE_HEAD=""
        save_state "" ""
    done
    clear_state
    # A run across every branch ends back on debian/sid, where new packaging work
    # usually starts; an --only run stays on the last branch it worked on.
    if [ "${ONLY:-0}" != 1 ] && in_list debian/sid "${distros[*]}" && branch_exists debian/sid; then
        git checkout -q debian/sid
    fi
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

# The arguments as a command line to paste back into a shell, quoting only the
# words that need it.
shell_quote() {
    local a out=""
    for a; do
        case "$a" in
            ''|*[!A-Za-z0-9_./:=@%+,-]*) a="${a@Q}" ;;
        esac
        out+="${out:+ }$a"
    done
    printf '%s\n' "$out"
}

# Print resume instructions and stop. Uses INVOCATION (each tool's own command
# line, from shell_quote).
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

# On-disk cache of apt Packages indices. Not under /tmp: a distro's archive indices
# run to hundreds of MB.
INDEX_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/session-packaging/indices"

# Fetch the Packages index at <url> (without a compression extension) into
# INDEX_CACHE and print the cached file's path: the .gz when the server has one
# (dose3 reads it directly; read it with `zcat -f`), else the uncompressed index.
# Downloads only when the server's copy is newer than the cached one, so repeated
# checks of a repo that changes mid-run (/staging during a cascade) stay cheap.
# Prints nothing if there's no index at <url>.
cached_index() {
    local url="$1" base ext dst tmp code
    base="$INDEX_CACHE/$(printf '%s' "${url#*://}" | tr '/' '_')"
    mkdir -p "$INDEX_CACHE"
    for ext in .gz ''; do
        dst="$base$ext"
        # Download beside the cached copy and rename into place, so a concurrent
        # reader never sees a partial file.
        tmp="$(mktemp "$base.XXXXXX")"
        if [ -e "$dst" ]; then
            code="$(curl -sSL -R -z "$dst" -o "$tmp" -w '%{http_code}' "$url$ext" 2>/dev/null)" || code=000
        else
            code="$(curl -sSL -R -o "$tmp" -w '%{http_code}' "$url$ext" 2>/dev/null)" || code=000
        fi
        case "$code" in
            200) mv "$tmp" "$dst"; printf '%s\n' "$dst"; return 0 ;;
            304) rm -f "$tmp";     printf '%s\n' "$dst"; return 0 ;;
        esac
        rm -f "$tmp"
    done
}

# cached_index for each <url>, up to INDEX_FETCH_JOBS at once, printing one line per
# <url> in the order given: its cached path, or an empty line if it isn't published.
INDEX_FETCH_JOBS=8
cached_indices() {
    local dir u i=0 running=0
    dir="$(mktemp -d)"
    for u; do
        if [ "$running" -ge "$INDEX_FETCH_JOBS" ]; then
            wait -n || true
            running=$((running - 1))
        fi
        cached_index "$u" > "$dir/$i" &
        running=$((running + 1)) i=$((i + 1))
    done
    wait
    for ((i = 0; i < $#; i++)); do printf '%s\n' "$(cat "$dir/$i")"; done
    rm -rf "$dir"
}

# URL of the <suffix>/<distro>/<arch> Packages index of our repo, without
# compression extension. <suffix> is the reprepro repo suffix ('', '/beta',
# '/staging').
repo_index_url() {
    printf '%s\n' "https://$DEB_REPO_HOST$1/dists/$2/main/binary-$3/Packages"
}

# Path of the cached <suffix>/<distro>/<arch> Packages index of our repo (see
# cached_index), or nothing if it isn't published.
repo_index() {
    cached_index "$(repo_index_url "$1" "$2" "$3")"
}

# Version of <pkg> in Packages index <file> (plain or gzipped), or empty.
pkg_version_in() {
    # Reads to the end rather than exiting at the first match: an early exit would
    # kill zcat with SIGPIPE, which pipefail turns into a failure.
    zcat -f "$1" | awk -v p="$2" '
        $1=="Package:" { cur=$2 }
        $1=="Version:" && cur==p && !found { print $2; found=1 }
    '
}

# Version of <pkg> published for <suffix>/<distro>/<arch>, or empty.
repo_pkg_version() {
    local f; f="$(repo_index "$1" "$2" "$3")"
    [ -n "$f" ] || return 0
    pkg_version_in "$f" "$4"
}

# Check that every versioned build-dep of <branch> that comes from our repo — one
# of "ours" (is_our_package), or anything else the repo carries for that distro,
# like the ngtcp2 backports — is available at the required version in the
# branch's own target repo (from its CI config), for EVERY architecture that
# branch's CI builds — not just amd64. A dep that exists
# for amd64 but is missing for arm64/armhf/i386 still fails those builds, so the
# pre-check must cover them. Prints problems to stderr; returns non-zero if any dep
# is unsatisfied on any built arch.
dep_check() {
    local b="$1" ref
    ref="$(branch_ref "$b")"
    local control distro suffix
    distro="$(ci_setting "$ref" distro)"
    [ -n "$distro" ] || { warn "[$(cpkg "$b")] no distro in the CI config; skipping dep check"; return 0; }
    suffix="$(ci_setting "$ref" repo_suffix)"
    control="$(git show "$ref:debian/control" 2>/dev/null)" ||
        { warn "[$(cpkg "$b")] no debian/control; skipping"; return 0; }

    local -a arches
    mapfile -t arches < <(ci_debarches "$ref")
    [ "${#arches[@]}" -gt 0 ] || arches=(amd64)

    # Pull the (folded) Build-Depends field and flatten it to one line.
    local bd
    bd="$(printf '%s\n' "$control" | awk '
        /^Build-Depends:/ { f=1; sub(/^Build-Depends:/,""); print; next }
        f && /^[ \t]/     { print; next }
        f                 { exit }
    ' | tr '\n' ' ')"

    local rc=0 entry pkg ver avail arch v list
    local -A pkgidx=() pkgidx_set=()   # per-arch Packages index, fetched once, lazily
    # Outdated arches are grouped by the version they have, so each distinct stale
    # version is reported once with its arches; old_vers keeps first-seen order.
    local -a entries miss old_vers
    local -A old_arches
    IFS=, read -ra entries <<< "$bd"
    for entry in "${entries[@]}"; do
        pkg="$(printf '%s' "$entry" | sed -e 's/^[ \t]*//' -e 's/[ \t(|].*//')"
        [ -n "$pkg" ] || continue
        ver="$(printf '%s' "$entry" | sed -n 's/.*(>=[ \t]*\([^)]*\)).*/\1/p' | tr -d ' ')"
        [ -n "$ver" ] || continue    # no minimum version constraint -> nothing to verify
        miss=(); old_vers=(); old_arches=()
        for arch in "${arches[@]}"; do
            if [ -z "${pkgidx_set[$arch]:-}" ]; then
                pkgidx[$arch]="$(repo_index "$suffix" "$distro" "$arch")"
                pkgidx_set[$arch]=1
            fi
            if [ -z "${pkgidx[$arch]}" ]; then miss+=("$arch"); continue; fi  # no index for arch
            avail="$(pkg_version_in "${pkgidx[$arch]}" "$pkg")"
            if [ -z "$avail" ]; then miss+=("$arch")
            elif ! dpkg --compare-versions "$avail" ge "$ver"; then
                [ -n "${old_arches[$avail]:-}" ] || old_vers+=("$avail")
                old_arches[$avail]+="${old_arches[$avail]:+, }$arch"
            fi
        done
        # Other packages are vetted only if our repo carries them (backports such as
        # ngtcp2); one it has for no arch at all comes from the distro's own archive,
        # which this doesn't check.
        is_our_package "$pkg" || [ "${#miss[@]}" -lt "${#arches[@]}" ] || continue
        if [ "${#miss[@]}" -gt 0 ]; then
            printf -v list '%s, ' "${miss[@]}"
            warn "[$(cpkg "$b")] $(cpkg "$pkg") (>= $(cver "$ver")) not published for: ${list%, } — https://$DEB_REPO_HOST$suffix ($distro)"
            rc=1
        fi
        if [ "${#old_vers[@]}" -gt 0 ]; then
            list=""
            for v in "${old_vers[@]}"; do
                list+="${list:+, }$C_BOLD$C_WARN$v$C_RESET (${old_arches[$v]})"
            done
            warn "[$(cpkg "$b")] $(cpkg "$pkg") (>= $(cver "$ver")) unsatisfied: $list — https://$DEB_REPO_HOST$suffix ($distro)"
            rc=1
        fi
    done
    return "$rc"
}

# ---------------------------------------------------------------------------
# installability against the distro archive (dose3; used by deb-rebuild-broken)
# ---------------------------------------------------------------------------
require_dose() {
    command -v dose-debcheck >/dev/null 2>&1 && command -v dose-builddebcheck >/dev/null 2>&1 ||
        die "dose3 is required: apt install dose-distcheck dose-builddebcheck"
}

# The distro archive Packages index URLs (without compression extension) that
# <branch>'s builder image installs from on <arch>, one per line. They mirror the
# builder images' apt sources: Debian main from the release, -updates and -security
# (sid only has the release), and Ubuntu main/universe/restricted/multiverse from the
# release, -updates, -backports and -security (non-x86 arches live on
# ports.ubuntu.com). A pocket a release doesn't have is just absent when fetched.
distro_archive_urls() {
    local b="$1" arch="$2" c="${1#*/}" mirror s comp
    case "$b" in
        debian/sid)
            printf '%s\n' "https://deb.debian.org/debian/dists/sid/main/binary-$arch/Packages" ;;
        debian/*)
            printf '%s\n' \
                "https://deb.debian.org/debian/dists/$c/main/binary-$arch/Packages" \
                "https://deb.debian.org/debian/dists/$c-updates/main/binary-$arch/Packages" \
                "https://deb.debian.org/debian-security/dists/$c-security/main/binary-$arch/Packages" ;;
        ubuntu/*)
            case "$arch" in
                amd64|i386) mirror="http://archive.ubuntu.com/ubuntu" ;;
                *)          mirror="http://ports.ubuntu.com/ubuntu-ports" ;;
            esac
            for s in "$c" "$c-updates" "$c-backports" "$c-security"; do
                for comp in main universe restricted multiverse; do
                    printf '%s\n' "$mirror/dists/$s/$comp/binary-$arch/Packages"
                done
            done ;;
        *) die "no distro archive known for '$b'" ;;
    esac
}

# fetch_distro_indices <branch> <arch>...
#
# Fetch <branch>'s distro archive indices (see distro_archive_urls) for each <arch>
# not fetched yet this run, all in parallel, for distro_indices to return. Call this
# directly, not in a subshell, or the memo of what was fetched is lost.
declare -gA _distro_indices=()
fetch_distro_indices() {
    local branch="$1" arch u i; shift
    local -a want=() urls=() url_arch=() paths=()
    for arch; do
        [ -z "${_distro_indices[$branch|$arch]+set}" ] || continue
        want+=("$arch")
        while read -r u; do
            urls+=("$u"); url_arch+=("$arch")
        done < <(distro_archive_urls "$branch" "$arch")
    done
    [ "${#want[@]}" -gt 0 ] || return 0
    msg "${C_DIM}fetching the $branch archive indices for ${want[*]}...$C_RESET"
    mapfile -t paths < <(cached_indices "${urls[@]}")
    for arch in "${want[@]}"; do _distro_indices[$branch|$arch]=""; done
    for i in "${!urls[@]}"; do
        [ -z "${paths[i]:-}" ] || _distro_indices[$branch|${url_arch[i]}]+="${paths[i]}"$'\n'
    done
    for arch in "${want[@]}"; do
        [ -n "${_distro_indices[$branch|$arch]}" ] || die "no $branch archive indices found for $arch"
    done
}

# Set DISTRO_INDICES to the cached paths of <branch>'s distro archive indices for
# <arch>, fetching them first if fetch_distro_indices hasn't. Same subshell caveat.
DISTRO_INDICES=()
distro_indices() {
    fetch_distro_indices "$1" "$2"
    mapfile -t DISTRO_INDICES < <(printf '%s' "${_distro_indices[$1|$2]}")
}

# Source package name in <ref>'s debian/control (often not the checkout's name:
# libquic's is oxen-libquic).
control_source() {
    git show "$1:debian/control" 2>/dev/null | sed -n 's/^Source:[[:space:]]*//p' | head -1
}

# The binaries of source <src> in Packages index <file>, leaving out debug symbols:
# with <ver>, the stanzas of that version's binaries (blank-line separated); without,
# each distinct version present. A binary's source is its Source: field (minus any
# "(version)"), or its own name when it has none.
_index_source() {
    zcat -f "$1" | awk -v s="$2" -v v="${3:-}" '
        BEGIN { RS = ""; FS = "\n" }
        {
            pkg = src = ver = sec = ""
            for (i = 1; i <= NF; i++) {
                if      ($i ~ /^Package:/) { pkg = $i; sub(/^Package:[ \t]*/, "", pkg) }
                else if ($i ~ /^Source:/)  { src = $i; sub(/^Source:[ \t]*/, "", src); sub(/[ \t].*/, "", src) }
                else if ($i ~ /^Version:/) { ver = $i; sub(/^Version:[ \t]*/, "", ver) }
                else if ($i ~ /^Section:/) { sec = $i; sub(/^Section:[ \t]*/, "", sec) }
            }
            if (src == "") src = pkg
            if (src != s || sec == "debug" || pkg ~ /-dbgsym$/) next
            if (v == "") { if (!seen[ver]++) print ver }
            else if (ver == v) printf "%s\n\n", $0
        }'
}
index_source_versions() { _index_source "$1" "$2"; }
index_source_stanzas()  { _index_source "$1" "$2" "$3"; }

# The highest of the Debian versions on stdin (one per line), or nothing.
newest_version() {
    local v best=""
    while read -r v; do
        [ -n "$v" ] || continue
        if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best"; then best="$v"; fi
    done
    [ -z "$best" ] || printf '%s\n' "$best"
}

# A Sources-format stanza for <ref>'s source package at its changelog version, with
# its build relationships, for dose-builddebcheck. Each field is flattened onto one
# line: dose3's parser rejects a field whose first line is empty, which is how our
# control files write Build-Depends.
source_stanza() {
    git show "$1:debian/control" | awk -v ver="$(changelog_version "$1")" '
        function flush() {
            if (f != "") {
                gsub(/[ \t]+/, " ", val); sub(/^[ ,]+/, "", val); sub(/[ ,]+$/, "", val)
                print f ": " val
            }
            f = ""
        }
        /^#/       { next }
        /^[ \t]*$/ { if (started) exit; next }
        /^[ \t]/   { if (f != "") val = val " " $0; next }
                   { flush(); started = 1 }
        /^Source:/ {
            s = $0; sub(/^Source:[ \t]*/, "", s)
            print "Package: " s; print "Version: " ver; print "Architecture: any"
        }
        /^Build-(Depends|Conflicts)(-Arch|-Indep)?:/ {
            f = $0; sub(/:.*/, "", f); val = $0; sub(/^[^:]*:/, "", val)
        }
        END { flush(); print "" }'
}

# Run a dose3 checker (dose-debcheck or dose-builddebcheck, given --failures
# --explain) and print "<package>\t<reason>" for each reason a package is broken,
# where a reason is "<pkg> needs <dep>" or "<pkg> conflicts with <pkg2>" and <pkg>
# is the package in the dependency chain that has the problem. Dies on anything but
# dose's 0 (all fine) or 1 (some broken) exit.
dose_run() {
    local out err rc=0
    err="$(mktemp)"
    out="$("$@" 2>"$err")" || rc=$?
    if [ "$rc" -gt 1 ]; then
        cat "$err" >&2; rm -f "$err"
        die "$1 failed (exit $rc)"
    fi
    rm -f "$err"
    # The report's indentation is fixed: a checked package at 2 spaces, the package
    # a reason is about at 6, and the dependency chains leading to it deeper.
    printf '%s\n' "$out" | awk '
        function clean(s) { gsub(/"/, "", s); gsub(/:[a-z][a-z0-9-]*/, "", s); return s }
        /^  package: /              { pkg = $2 }
        /^     pkg[12]?:/           { rp = "" }
        /^      package: /          { if (rp == "") rp = $2 }
        /^      unsat-dependency: / { sub(/^      unsat-dependency: /, ""); print pkg "\t" rp " needs " clean($0) }
        /^      unsat-conflict: /   { sub(/^      unsat-conflict: /, "");   print pkg "\t" rp " conflicts with " clean($0) }'
}

# ---------------------------------------------------------------------------
# cross-repo helpers (used by deb-cascade / deb-add-distro-all / deb-rebuild-broken)
# ---------------------------------------------------------------------------
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
    distro="$(ci_setting "$ref" distro)"
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

# Run a command inside checkout <repo> (in a subshell, so the caller's cwd is kept).
in_repo() { ( cd "$SP_ROOT/$1"; shift; "$@" ); }

# The build-order file's steps, one entry per line with comments and blanks
# stripped, in BUILD_STEPS. Repos within an entry are space-separated.
BUILD_STEPS=()
read_build_order() {
    local line
    BUILD_STEPS=()
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | xargs || true)"
        [ -n "$line" ] && BUILD_STEPS+=("$line")
    done < "$SP_ROOT/build-order"
    [ "${#BUILD_STEPS[@]}" -gt 0 ] || die "no steps found in $SP_ROOT/build-order"
}

# Die unless <suffix>'s reprepro distribution for <branch> exists. reprepro doesn't
# create one until it's exported once (even empty), and CI builds that pull from a
# missing one fail at apt-get update, so a cascade should fail before it starts.
require_repo_dist() {
    local suffix="$1" dist="${2#*/}"
    repo_dist_exists "$suffix" "$dist" || die \
"the $suffix repo for '$dist' doesn't exist yet:
    https://$DEB_REPO_HOST$suffix/dists/$dist/
Export that distribution in reprepro first (an empty one is fine), then re-run."
}

# push_and_watch [--fresh] <branch> <repo>...
#
# Push <branch> in each <repo> (deb-push --no-wait, so its pre-checks run) and watch
# all the CI builds to completion with monitor_ci, which sets MON_FAILED. A repo
# whose branch was already on the remote at this commit lets monitor_ci restart a
# stale failed build once, which is what makes re-running a cascade after a failure
# work; a newly pushed commit never restarts anything. With --fresh, a stale build
# that succeeded is restarted too, for a rebuild with nothing new to push: a build
# from before a distro library transition produced packages the transition broke.
# Polls every DEB_CASCADE_POLL seconds (default 4).
push_and_watch() {
    local stale=failed
    if [ "${1:-}" = --fresh ]; then stale=any; shift; fi
    local branch="$1" r rem; shift
    local -A sha=() restart=()
    for r; do
        sha[$r]="$(in_repo "$r" git rev-parse "$branch")"
        rem="$(in_repo "$r" git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')"
        [ "$rem" = "${sha[$r]}" ] && restart[$r]="$stale" || restart[$r]=none
        msg "[$(cpkg "$r")] pushing $branch ..."
        # --no-wait: everything is watched together below, and deb-push's own watch
        # would die on a stale failure before monitor_ci could restart it.
        "$SP_ROOT/deb-push" "$r" --no-wait "$branch"
    done
    MON_ITEMS=()
    for r; do
        MON_ITEMS+=("$r|$(in_repo "$r" origin_slug)|$branch|${sha[$r]}|${restart[$r]}")
    done
    MON_POLL="${DEB_CASCADE_POLL:-4}"
    monitor_ci
}

# The barrier between cascade steps: tell the user to upload <branch>'s packages
# from each <repo> to <suffix> (the manual signing step), then re-check until they
# are all published there. <what> names the set in the messages (e.g. "step 2").
# Re-checks every DEB_CASCADE_STAGE_POLL seconds (default 15); on a terminal, Enter
# re-checks at once and "skip" carries on without the stragglers.
wait_published() {
    local suffix="$1" branch="$2" what="$3" r ans
    local poll="${DEB_CASCADE_STAGE_POLL:-15}"
    local -a pend
    shift 3
    msg "Upload these to the $suffix repo now (manual signing step)."
    msg "On the main reprepro server run: ${C_BOLD}DEBS_TO_REPO_SUFFIX=$suffix DISTRO=$branch ./publish-debs.sh${C_RESET}"
    while :; do
        pend=()
        for r; do
            in_repo "$r" published_in_repo "$suffix" "$branch" || pend+=("$r")
        done
        if [ "${#pend[@]}" -eq 0 ]; then
            [ -t 0 ] && printf '\n' >&2
            msg "${C_OK}All of $what are in $suffix.${C_RESET}"
            return 0
        fi
        if [ -t 0 ]; then
            printf '\r\033[K  waiting for %s in %s  [Enter = recheck, "skip" = force] ' \
                "${pend[*]}" "$suffix" >&2
            ans=""
            read -t "$poll" -r ans || true
            [ "$ans" = skip ] && { printf '\n' >&2; warn "forced past $suffix for: ${pend[*]}"; return 0; }
        else
            sleep "$poll"
        fi
    done
}

# ---------------------------------------------------------------------------
# Woodpecker CI (via woodpecker-cli, using its configured context or
# WOODPECKER_SERVER/WOODPECKER_TOKEN)
# ---------------------------------------------------------------------------
CI_SERVER=""

# 0 if woodpecker-cli is installed and can authenticate, setting CI_SERVER (the
# web UI base, for build links); else 1 (caller decides whether that's fatal).
have_ci() {
    command -v woodpecker-cli >/dev/null 2>&1 || return 1
    woodpecker-cli info >/dev/null 2>&1 || return 1
    CI_SERVER="${WOODPECKER_SERVER:-$(woodpecker-cli context ls 2>/dev/null | awk '$2=="*" {print $3; exit}')}"
    CI_SERVER="${CI_SERVER%/}"
}

require_ci() {
    command -v woodpecker-cli >/dev/null 2>&1 ||
        die "the 'woodpecker-cli' CLI is required for CI monitoring but was not found"
    have_ci || die "woodpecker-cli can't authenticate; run 'woodpecker-cli setup' (or set WOODPECKER_SERVER/WOODPECKER_TOKEN)"
}

# Woodpecker's numeric repo id for an "owner/repo" slug, or empty if the repo
# isn't activated there. Build links need the id, not the slug.
ci_repo_id() {
    woodpecker-cli repo show "$1" --output 'go-template={{range .}}{{.ID}}{{end}}' 2>/dev/null || true
}

# Newest pipeline number for <repo> targeting <branch> at commit <sha>, or empty.
# No event filter, so a restarted pipeline (newer, same commit, possibly a
# different event) is found too. `--branch` filters the target branch, which
# already excludes PRs *from* this branch (those target their base branch).
ci_build_for() {
    woodpecker-cli pipeline ls "$1" --branch "$2" --limit 30 \
        --output $'go-template={{range .}}{{.Number}}\t{{.Commit}}\n{{end}}' 2>/dev/null |
        awk -v s="$3" '$2==s && !seen {print $1; seen=1}'
}

# Restart a pipeline. Woodpecker creates a new pipeline number for it, which
# ci_build_for then finds as the newest at that commit.
ci_restart() {
    woodpecker-cli pipeline start "$1" "$2" >/dev/null 2>&1 || return 1
}

ci_stop() {
    woodpecker-cli pipeline stop "$1" "$2" >/dev/null 2>&1 || return 1
}

ci_status() {
    woodpecker-cli pipeline show "$1" "$2" --output 'go-template={{range .}}{{.Status}}{{end}}' 2>/dev/null || true
}

# One call returning a pipeline's overall status and each workflow, as a
# `STATUS=<s>` line followed by `STAGE=<name>=<s>` lines. Guarded so it is never
# fatal. The "DEPRECATED" workflow is the server's Drone-config notice, not a build.
ci_build_detail() {
    woodpecker-cli pipeline show "$1" "$2" \
        --output 'go-template={{range .}}STATUS={{.Status}}{{"\n"}}{{range .Workflows}}{{if ne .Name "DEPRECATED"}}STAGE={{.Name}}={{.State}}{{"\n"}}{{end}}{{end}}{{end}}' \
        2>/dev/null || true
}

ci_terminal() {
    case "$1" in
        success|failure|error|killed|canceled|skipped|declined) return 0 ;;
        *) return 1 ;;
    esac
}

# Live-watch a set of CI builds to completion, rendering a refreshing block (one
# line per item: dim while locating/queued, per-stage tags once building, a
# terminal tag when done, with an OSC-8 link to the build). Shared by deb-cascade
# (one item per repo) and deb-push (one item per pushed branch).
#
# Input:  MON_ITEMS — each entry "label|slug|branch|sha|restart[|old]". <restart>
#                     says which stale build (one *already* finished when first
#                     seen) is restarted, once: "failed" restarts one that didn't
#                     succeed (cascade reentrancy), "any" one that succeeded too
#                     (a rebuild with nothing new to push), "none" never restarts.
#                     Optional <old> is a build number to ignore (one the caller
#                     just restarted), so the watch waits for its replacement.
#         MON_POLL  — seconds between polls (default 4).
# Output: MON_FAILED — labels whose build didn't finish "success" (empty = all ok).
# Requires have_ci/require_ci to have succeeded (for CI_SERVER).
# Every CI call is guarded so a transient CLI hiccup can't abort under `set -e`.
MON_ITEMS=(); MON_FAILED=()
monitor_ci() {
    local poll="${MON_POLL:-4}" n=0 i rec
    local -a lbl slug br sha restart old
    for rec in "${MON_ITEMS[@]}"; do
        IFS='|' read -r "lbl[$n]" "slug[$n]" "br[$n]" "sha[$n]" "restart[$n]" "old[$n]" <<< "$rec"
        n=$((n + 1))
    done
    MON_FAILED=()
    [ "$n" -gt 0 ] || return 0
    local wid=1
    for ((i = 0; i < n; i++)); do [ "${#lbl[i]}" -gt "$wid" ] && wid="${#lbl[i]}"; done

    local -A bnum=() cst=() restarted=() ignore=() gaveup=() tries=() rid=() ridof=() seen=()
    for ((i = 0; i < n; i++)); do
        [ -n "${ridof[${slug[i]}]:-}" ] || ridof[${slug[i]}]="$(ci_repo_id "${slug[i]}")"
        rid[$i]="${ridof[${slug[i]}]}"
        [ -z "${old[i]:-}" ] || ignore[$i]="${old[i]}"
        if [ -z "${rid[$i]}" ]; then
            warn "${slug[i]} isn't an active repo on $CI_SERVER"
            gaveup[$i]=1; cst[$i]=nobuild
        fi
    done
    local all_done detail ov tags sline bpad blink cand lf
    local -a lines
    msg "Watching CI (every ${poll}s)..."
    while :; do
        all_done=1; lines=()
        for ((i = 0; i < n; i++)); do
            # colour the label per family, padded to the column by its *plain* width
            # (cpkg adds escape codes, so %-*s can't do the padding).
            lf="$(cpkg "${lbl[i]}")$(printf '%*s' "$(( wid - ${#lbl[i]} ))" '')"
            if [ -n "${gaveup[$i]:-}" ]; then
                lines+=("$(printf '  %s %sno build found%s' "$lf" "$C_ERR" "$C_RESET")"); continue
            fi
            if [ -z "${bnum[$i]:-}" ]; then
                cand="$(ci_build_for "${rid[$i]}" "${br[i]}" "${sha[i]}" 2>/dev/null || true)"
                if [ -n "$cand" ] && [ "$cand" != "${ignore[$i]:-}" ]; then
                    bnum[$i]="$cand"; tries[$i]=0
                else
                    tries[$i]=$(( ${tries[$i]:-0} + 1 ))
                    if [ "${tries[$i]}" -ge 15 ]; then
                        gaveup[$i]=1; cst[$i]=nobuild
                        lines+=("$(printf '  %s %sno build found%s' "$lf" "$C_ERR" "$C_RESET")")
                    else
                        all_done=0
                        lines+=("$(printf '  %s %slocating…%s' "$lf" "$C_DIM" "$C_RESET")")
                    fi
                    continue
                fi
            fi
            detail="$(ci_build_detail "${rid[$i]}" "${bnum[$i]}")"
            ov="$(printf '%s\n' "$detail" | sed -n 's/^STATUS=//p' | head -1)"; [ -n "$ov" ] || ov=pending
            # Only on first sight: a build that fails while being watched is a real
            # failure to report, not a stale one to retry.
            if [ -z "${seen[$i]:-}" ] && [ "${restarted[$i]:-0}" = 0 ] && ci_terminal "$ov" \
               && { [ "${restart[i]:-none}" = any ] ||
                    { [ "${restart[i]:-none}" = failed ] && [ "$ov" != success ]; }; }; then
                if ci_restart "${rid[$i]}" "${bnum[$i]}"; then
                    restarted[$i]=1; ignore[$i]="${bnum[$i]}"; bnum[$i]=""; all_done=0
                    lines+=("$(printf '  %s %srestarting #%s…%s' "$lf" "$C_WARN" "${ignore[$i]}" "$C_RESET")"); continue
                fi
            fi
            if [ -n "$detail" ]; then seen[$i]=1; fi
            cst[$i]="$ov"; ci_terminal "$ov" || all_done=0
            tags=""
            while IFS= read -r sline; do
                [ -n "$sline" ] || continue
                tags+=" $(ci_tag "$(stage_arch "${sline%=*}")" "${sline##*=}")"
            done < <(printf '%s\n' "$detail" | sed -n 's/^STAGE=//p')
            [ -n "$tags" ] || tags=" $(ci_tag build "$ov")"
            bpad=$(( 5 - ${#bnum[$i]} )); [ "$bpad" -lt 1 ] && bpad=1
            blink="$(hyperlink "$CI_SERVER/repos/${rid[$i]}/pipeline/${bnum[$i]}" "#${bnum[$i]}")"
            lines+=("$(printf '  %s %s%*s%s' "$lf" "$blink" "$bpad" "" "$tags")")
        done
        render_block "${lines[@]}"
        [ "$all_done" = 1 ] && break
        sleep "$poll"
    done
    render_block_end
    for ((i = 0; i < n; i++)); do [ "${cst[$i]:-}" = success ] || MON_FAILED+=("${lbl[i]}"); done
}

# ---------------------------------------------------------------------------
# success footer
# ---------------------------------------------------------------------------
push_hint() {
    # A tool running this one as a step of its own (deb-rebuild-broken) pushes
    # straight afterwards, so the hint would be wrong there.
    [ -z "${SP_NO_PUSH_HINT:-}" ] || return 0
    # Only a genuinely restricted run (--only, PARTIAL=1) names its branches; a full
    # run — even one that set TARGET just to reorder/filter (version-bump creating a
    # distro, pkg-update --no-bump) — points at the bare "all branches" form, since
    # deb-push with no args already defaults to every active branch.
    if [ "${PARTIAL:-0}" = 1 ] && [ -n "${TARGET:-}" ]; then
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
