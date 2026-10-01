#!/bin/bash
#
# Maintains convenience symlinks in the builds.session.codes tree; run every minute from cron on the
# build storage host.  In each <org>/<project>/{debian,ubuntu}-<codename> directory:
#
#     latest          -> the newest deb-* build
#     <deb version>   -> the newest deb-* build of that version, e.g.
#                        1.10.2-2~deb14 -> deb-forky-20260930T232953Z-9ae57b450
#
# plus `latest` in rpm distro directories and assorted *-LATEST links for the oxen-core, lokinet and
# lokinet-gui binary builds.
#
# Usage: build-latest.sh [-n|--dry-run] [<builds root>]
#
# --dry-run prints the links that would be created, changed or removed, and changes nothing.

set -u
shopt -s nullglob
# Build directory names embed a UTC timestamp, so plain byte-order globbing lists them oldest first.
export LC_ALL=C

dry_run=
case "${1:-}" in -n|--dry-run) dry_run=1; shift ;; esac
root=${1:-/srv/builds.lokinet.dev}
# nginx's autoindex doesn't list dotfiles, so these stay out of the public listings.
lock=$root/.build-latest.lock
stamp=$root/.build-latest.stamp

if [ -z "$dry_run" ]; then
    exec 9>"$lock"
    flock -n 9 || exit 0  # the previous run is still going

    # Records when this run started: the next run only revisits directories modified since then,
    # which includes anything uploaded while this run was going.
    touch "$stamp.new"
fi

# Points symlink $2 at $1.  A link that is already correct is left alone; a wrong one is replaced
# atomically, so a download never finds it missing.
set_link() {
    local target=$1 link=$2 old=
    [ -L "$link" ] && old=$(readlink "$link")
    [ "$old" = "$target" ] && return
    if [ -n "$dry_run" ]; then
        echo "link   ${link#"$root"/} -> $target${old:+  (currently -> $old)}"
        return
    fi
    ln -sfn "$target" "$link.new.$$" && mv -Tf "$link.new.$$" "$link"
}

remove_link() {
    if [ -n "$dry_run" ]; then
        echo "remove ${1#"$root"/}  (dangling -> $(readlink "$1"))"
        return
    fi
    rm -f "$1"
}

# True if directory $1, or any directory directly inside it, may have changed since the previous
# run.  Uploads add files to a build directory, which bumps that directory's mtime but not its
# parent's, hence checking the children too.  Ties count as changed, since the stamp's timestamp
# resolution may be coarse.
changed() {
    local d
    [ -e "$stamp" ] || return 0
    for d in "$1" "$1"/*/; do
        [ "$stamp" -nt "$d" ] || return 0
    done
    return 1
}

# Sets DEB_VERSION to the version of the packages in build directory $1 (all packages of one build
# share it), or to empty if no .deb has been uploaded there yet.
deb_version() {
    local debs=("$1"/*.deb)
    DEB_VERSION=
    [ ${#debs[@]} -gt 0 ] || return
    DEB_VERSION=${debs[0]##*/}        # <package>_<version>_<arch>.deb
    DEB_VERSION=${DEB_VERSION#*_}
    DEB_VERSION=${DEB_VERSION%_*}
}

# Updates `latest` and the per-version links in deb distro directory $1.
update_deb_dir() {
    local dir=$1 build name link v latest=
    local -A by_version=()
    for build in "$dir"/deb-*/; do
        build=${build%/}
        [ -L "$build" ] && continue
        deb_version "$build"
        [ -n "$DEB_VERSION" ] || continue
        name=${build##*/}
        latest=$name
        # Builds are visited oldest first, so a re-pushed build of the same version wins.
        by_version[$DEB_VERSION]=$name
    done
    [ -n "$latest" ] || return
    set_link "$latest" "$dir/latest"
    for v in "${!by_version[@]}"; do
        set_link "${by_version[$v]}" "$dir/$v"
    done
    # A version link left dangling by a deleted build directory, with no other build of that version
    # to point at.  (Debian versions always start with a digit, which keeps this off any other links.)
    for link in "$dir"/[0-9]*; do
        name=${link##*/}
        [ -L "$link" ] && ! [ -e "$link" ] && [ -z "${by_version[$name]+set}" ] &&
            [[ $(readlink "$link") == deb-* ]] && remove_link "$link"
    done
}

# Updates `latest` in rpm distro directory $1.
update_rpm_dir() {
    local builds=("$1"/rpm-*/)
    [ ${#builds[@]} -gt 0 ] || return
    local newest=${builds[-1]%/}
    set_link "${newest##*/}" "$1/latest"
}

# Points symlink $1 at the most recently modified of the remaining arguments (via a path relative to
# the link's directory); does nothing if there are none.
link_newest() {
    local link=$1 newest= f
    shift
    for f; do
        if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
    done
    [ -n "$newest" ] || return
    set_link "${newest#"${link%/*}"/}" "$link"
}

for dir in "$root"/*/*/{debian,ubuntu}-*/ "$root"/oxen-io/oxen-backports/*/{debian,ubuntu}-*/; do
    dir=${dir%/}
    changed "$dir" && update_deb_dir "$dir"
done

for dir in "$root"/*/*/{fedora,opensuse,centos}-*/; do
    dir=${dir%/}
    changed "$dir" && update_rpm_dir "$dir"
done

for branch in dev stable; do
    path=$root/oxen-io/oxen-core/$branch
    [ -d "$path" ] || continue
    for os in linux macos win; do
        ext=.tar.xz
        [ "$os" = win ] && ext=.zip
        link_newest "$root/oxen-io/oxen-core/oxen-$branch-$os-LATEST$ext" "$path"/oxen-$os-*$ext
    done
    for os in ios android; do
        link_newest "$root/oxen-io/oxen-core/oxen-$branch-$os-deps-LATEST.tar.xz" "$path"/$os-deps-*.tar.xz
    done
done

# oxen-core's dev branch uploads its deb builds straight into dev/, for every distro at once.
path=$root/oxen-io/oxen-core/dev
if [ -d "$path" ] && changed "$path"; then
    declare -A newest_deb=()
    for build in "$path"/deb-*-*-*/; do
        build=${build%/}
        [ -L "$build" ] && continue
        deb_version "$build"
        [ -n "$DEB_VERSION" ] || continue
        name=${build##*/}
        distro=${name#deb-}
        newest_deb[${distro%%-*}]=$name
    done
    for distro in "${!newest_deb[@]}"; do
        set_link "${newest_deb[$distro]}" "$path/deb-$distro-latest"
    done
fi

for branch in dev stable; do
    path=$root/oxen-io/lokinet/$branch
    [ -d "$path" ] || continue
    for os in linux-amd64 windows-64bit darwin-amd64; do
        ext=.tar.xz
        [[ $os == windows-* ]] && ext=.zip
        link_newest "$root/oxen-io/lokinet/lokinet-$branch-$os-LATEST$ext" "$path"/lokinet-$os-*$ext
    done
done

for arch in amd64; do
    builds=("$root"/oxen-io/lokinet-gui/dev/lokinet-linux-$arch-v*/)
    [ ${#builds[@]} -gt 0 ] || continue
    newest=$(printf '%s\n' "${builds[@]%/}" | sort -V | tail -n 1)
    set_link "dev/${newest##*/}" "$root/oxen-io/lokinet-gui/latest-linux-$arch"
done

[ -n "$dry_run" ] || mv -f "$stamp.new" "$stamp"
