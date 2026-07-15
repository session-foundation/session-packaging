
declare -A version_suffix=(
    [debian/sid]=''
    [debian/buster]='~deb10'
    [debian/bullseye]='~deb11'
    [debian/bookworm]='~deb12'
    [debian/trixie]='~deb13'
    [debian/forky]='~deb14'
    [debian/duke]='~deb15'
    [ubuntu/xenial]='~ubuntu1604'
    [ubuntu/bionic]='~ubuntu1804'
    [ubuntu/focal]='~ubuntu2004'
    [ubuntu/jammy]='~ubuntu2204'
    [ubuntu/lunar]='~ubuntu2304'
    [ubuntu/mantic]='~ubuntu2310'
    [ubuntu/noble]='~ubuntu2404'
    [ubuntu/oracular]='~ubuntu2410'
    [ubuntu/plucky]='~ubuntu2504'
    [ubuntu/questing]='~ubuntu2510'
    [ubuntu/resolute]='~ubuntu2604'
    [ubuntu/stonking]='~ubuntu2610'
)

distros=(debian/{sid,forky,trixie,bookworm,bullseye} ubuntu/{resolute,noble,jammy})

# Per-repo opt-outs: distro branches a given repo does NOT build (e.g. it never
# built there, or we've given up fixing an old distro for it). Keyed by checkout
# dir; values are space-separated full branch names. The tools drop these from the
# active `distros` set for that repo, so version-bump won't build or recreate them
# and deb-push won't push them (existing branches just go stale; delete them by
# hand if you want them gone).
declare -A skip_distros=(
#    [libsession-python]='debian/bullseye ubuntu/jammy'
)
