#!/usr/bin/env bash
#
# publish-debs.sh — publishes the latest CI deb builds into a reprepro repository, then
# optionally mirrors the repository tree to the serving host.
#
# Usage: [DISTRO=<family>/<codename>] [DEBS_TO_REPO_SUFFIX=<suffix>] ./publish-debs.sh [<project>...]
#
#   <project>            builds-tree project to publish, e.g. session-foundation/liboxenmq; the
#                        session-foundation/ can be left off (liboxenmq, session-backports/ngtcp2)
#                        (default: all of them; see `projects` below)
#   DISTRO               publish only this distro, e.g. debian/forky (or debian-forky)
#                        (default: every distro in build-distros.bash)
#   DEBS_TO_REPO_SUFFIX  publish to the repo at this path below the main one, e.g. /staging
#                        (default: the main repo)
#
# Settings are read from ~/.publish-debs.conf (sourced as bash), which must set all of:
#
#   BUILDS_DIR=...    local copy of the builds file tree (<org>/<project>/<distro>/latest/)
#   REPREPRO_DIR=...  reprepro base directory of the main repo; other repos are below it
#   SYNC_DEST=...     rsync destination the whole repository tree is mirrored to afterwards;
#                     set it empty to skip the sync when publishing on the serving host itself
#
# Lists everything and waits for confirmation first.  Ubuntu's .ddeb debug-symbol packages are
# published alongside the .debs, as Debian's -dbgsym .debs are.  Any failure (including a
# cancelled signing prompt) or Ctrl-C stops the run; re-running is safe, as packages already in
# the repo are skipped.

set -euo pipefail
# Resolved because the server's wrappers reach this script through a symlink.
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.bash"

case "${1:-}" in -h|--help) usage 0 ;; esac

conf=~/.publish-debs.conf
[ -f "$conf" ] || die "$conf not found; see the top of $SELF for what it must set"
source "$conf"
for v in BUILDS_DIR REPREPRO_DIR SYNC_DEST; do
    [ -n "${!v+set}" ] || die "$conf does not set $v"
    [ "$v" = SYNC_DEST ] || [ -n "${!v}" ] || die "$v in $conf is empty"
done

suffix=${DEBS_TO_REPO_SUFFIX:-}
repo_dir=$REPREPRO_DIR$suffix
[ -d "$repo_dir/conf" ] || die "$repo_dir is not a reprepro repository"

if [ -n "${DISTRO:-}" ]; then
    [[ $DISTRO == */* ]] || DISTRO=${DISTRO/-//}
    dists=("$DISTRO")
else
    dists=("${distros[@]}")
fi

if [ -z "$suffix${DISTRO:-}" ]; then
    # Only push these to main, not /beta or /staging
    #dists+=(mint/{wilma,xia,zara,venessa,vera,victoria,virginia,ulyana,ulyssa,uma,una} kali/kali-rolling)
    #dists+=(mint/{ulyana,ulyssa,uma,una} kali/kali-rolling)
    dists+=(kali/kali-rolling)
fi

# If a distro is in here, we load files from the other distro in here rather than the name directly
declare -A distro_map
for m in mint/{wilma,xia,zara}; do
    distro_map["$m"]="ubuntu/noble"
done
for m in mint/{venessa,vera,victoria,virginia}; do
    distro_map["$m"]="ubuntu/jammy"
done
for m in mint/{ulyana,ulyssa,uma,una}; do
    distro_map["$m"]="ubuntu/focal"
done
for m in kali/kali-rolling; do
    distro_map["$m"]="debian/forky"
done

# These packages are universal enough (mostly pure-Python modules) that they will work on
# everything, and so we only build one for debian/sid and then use that one for everything.
declare -A sid_only=(
    [oxen-io/better_profanity]=1
    [oxen-io/session-pysogs]=1
)

projects=()
for p; do
    if [ ! -d "$BUILDS_DIR/$p" ] && [ -d "$BUILDS_DIR/session-foundation/$p" ]; then
        p=session-foundation/$p
    fi
    [ -d "$BUILDS_DIR/$p" ] || die "$p not found in $BUILDS_DIR (or under session-foundation/)"
    projects+=("$p")
done
if [ "${#projects[@]}" -eq 0 ]; then
    projects=(oxen-io/oxen-core
        session-foundation/{oxen-encoding,liboxenmq,pyoxenmq,liblogging,libquic,libsession-util,libsession-python,session-router,session-storage-server,pyoxenc}
        oxen-io/{lokinet,session-pysogs,better_profanity}
        jagerman/{libonionrequests,ethyl}
    )
    # session-backports uploads each package it builds to a directory of its own.
    for p in "$BUILDS_DIR"/session-foundation/session-backports/*/; do
        [ -d "$p" ] || continue
        p=${p%/}
        projects+=("session-foundation/session-backports/${p##*/}")
    done
fi
# C collation here and for the package names in the listing, because other locales ignore
# punctuation (and so wouldn't group projects by org).
mapfile -t projects < <(printf '%s\n' "${projects[@]}" | LC_ALL=C sort)

shopt -s nullglob

# Sets debs to the packages of project $2 to publish into distro $1.  (The build directories also
# hold .buildinfo files, which aren't published.)
project_debs() {
    local dir=${distro_map[$1]:-$1}
    if [ "$dir" != debian/sid ] && [ -n "${sid_only[$2]:-}" ]; then dir=debian/sid; fi
    dir=$BUILDS_DIR/$2/${dir/\//-}/latest
    debs=("$dir"/*.deb "$dir"/*.ddeb)
}

# Sets distro_debs to all the packages to publish into distro $1.
find_distro_debs() {
    local p
    distro_debs=()
    for p in "${projects[@]}"; do
        project_debs "$1" "$p"
        distro_debs+=("${debs[@]}")
    done
}

# Prints words $@ as one brace expression, with any ending they all share moved after the braces:
# amd64 arm64 -> {amd,arm}64.  Only endings, as a shared start gives the unreadable a{md,rm}64.
brace_join() {
    local w suffix=$1 list=
    for w; do
        while [[ $w != *"$suffix" ]]; do suffix=${suffix:1}; done
    done
    for w; do
        # Each alternative must keep at least one character.
        while [ ${#w} -le ${#suffix} ]; do suffix=${suffix:1}; done
    done
    for w; do list+=,${w%"$suffix"}; done
    printf '{%s}%s' "${list#,}" "$suffix"
}

# Prints the basenames of package files $@ (<name>_<version>_<arch>.<ext>), merging each package's
# per-architecture files into one <name>_<version>_{amd64,i386,...}.<ext> line.
compact_names() {
    local f stem key a
    local -a list
    local -A arches=()
    for f; do
        f=${f##*/}
        stem=${f%.*}
        key=${stem%_*}$'\t'${f##*.}
        arches[$key]+=,${stem##*_}
    done
    for key in "${!arches[@]}"; do
        IFS=, read -ra list <<< "${arches[$key]#,}"
        a=${list[0]}
        [ "${#list[@]}" -eq 1 ] || a=$(brace_join "${list[@]}")
        printf '%s_%s.%s\n' "${key%$'\t'*}" "$a" "${key#*$'\t'}"
    done
}

# reprepro reports routine conditions on stderr alongside real errors; the routine ones are passed
# through plain and everything else is shown in red.
highlight_errors() {
    local line routine="Skipping inclusion|component guessed|not ending with '\.deb'|Ignoring as --ignore=extension|^Created directory"
    while IFS= read -r line; do
        if [[ $line =~ $routine ]]; then
            printf '%s\n' "$line"
        else
            printf '%s%s%s\n' "$C_ERR" "$line" "$C_RESET"
        fi
    done >&2
}

# A pipeline rather than a process substitution, so that the filter has printed everything and
# reprepro's exit status is known before the next step starts.
run_reprepro() {
    { reprepro -V -b "$repo_dir" "$@" 2>&1 >&3 3>&- | highlight_errors; } 3>&1
}

# reprepro catches Ctrl-C itself and exits with an ordinary error status, so without this the run
# would carry on to the next distro (and its signing prompt).
trap 'printf "\n" >&2; die "interrupted"' INT

# column can't see the terminal's width through the indenting pipe below.
width=$(stty size <&2 2>/dev/null) || width=
width=${width#* }
[ "${width:-0}" -gt 4 ] || width=80

total=0
for x in "${dists[@]}"; do
    find_distro_debs "$x"
    total=$((total + ${#distro_debs[@]}))
    msg ""
    if [ "${#distro_debs[@]}" -eq 0 ]; then
        msg "${C_WARN}Nothing to upload to $(cpkg "$x")${C_RESET}"
        continue
    fi
    msg "${C_WARN}About to upload ${#distro_debs[@]} files to $(cpkg "$x") ${C_REPO}${suffix:-(MAIN REPOSITORY)}${C_RESET}${C_WARN}:${C_RESET}"
    for p in "${projects[@]}"; do
        project_debs "$x" "$p"
        [ "${#debs[@]}" -gt 0 ] || continue
        msg "  $C_PKG${p%%/*}/$C_RESET$C_PROJ${p#*/}$C_RESET ${C_DIM}(${#debs[@]} files)${C_RESET}"
        compact_names "${debs[@]}" | LC_ALL=C sort | column -c $((width - 4)) | expand | sed 's/^/    /' >&2
    done
done
msg ""
[ "$total" -gt 0 ] || die "no packages found to upload"
read -rp "Press enter to continue..."

for x in "${dists[@]}"; do
    find_distro_debs "$x"
    [ "${#distro_debs[@]}" -gt 0 ] || continue
    codename=${x#*/}
    # The .ddebs differ from .debs only in name, hence --ignore=extension.  Exporting separately
    # afterwards means each distribution is signed once; old pool files are kept until then
    # because the still-published indices refer to them.
    run_reprepro --ignore=extension --export=silent-never --keepunreferencedfiles \
        includedeb "$codename" "${distro_debs[@]}" || die "including packages into $x failed"
    run_reprepro export "$codename" || die "exporting $x failed"
done
run_reprepro deleteunreferenced || die "removing unreferenced pool files failed"

if [ -n "$SYNC_DEST" ]; then
    read -rp "Press enter to sync to $SYNC_DEST..."
    rsync -aP --delete "$REPREPRO_DIR/." "$SYNC_DEST/." || die "sync failed"
fi
