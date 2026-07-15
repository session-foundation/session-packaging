# session-packaging

Scripts for building and releasing Debian/Ubuntu (`.deb`) packages for
Session-related software (oxen-core, session-storage-server, session-router, and
libraries such as libsession-util, oxen-encoding, oxen-mq, oxen-logging, libquic,
…).

This directory is the canonical working tree for packaging. Each package's
repository is cloned in as a **git-ignored checkout** (a subdirectory, e.g.
`liboxenmq/`, `session-router/`, `oxen-core/`). They are plain clones, not
submodules; clone whichever ones you need to work on:

```sh
git clone git@github.com:session-foundation/oxen-mq liboxenmq
```

All tools are run **from this top-level directory** with the checkout directory
as the first argument, e.g. `./deb-version-bump liboxenmq`.

## How releases work

The actual debian packaging lives in `debian/<codename>` and `ubuntu/<codename>`
branches inside each package repo, managed with
[git-buildpackage](https://honk.sigxcpu.org/piki/projects/git-buildpackage/)
(gbp). `debian/sid` is the primary branch; the others carry the same packaging
with a per-distro version suffix.

* Package versions get a debian revision: `1.3.0-1`, `-2`, … (sid, no suffix).
* Other distros append a suffix from `build-distros.bash`: `1.3.0-1~deb13`
  (trixie), `1.3.0-1~ubuntu2404` (noble), etc.
* The changelog **distribution** field is the codename (`trixie`, `noble`, …),
  except `debian/sid` which uses `unstable`.
* Some libraries embed the soname version in the binary package name (e.g.
  `liboxenmq1.3.0`) via a `debian/control.in` template plus a
  `debian/update-lib-version.sh` (or `update-liboxen-ver.sh`) script that
  regenerates `debian/control` after the changelog is bumped. The tools run that
  script automatically when present.

Builds happen in CI: the `debian/*` / `ubuntu/*` branches carry a completely
replaced `.drone.jsonnet` that builds the package and uploads the artifacts (via
`debian/ci-upload.sh`) to the builds file server. Pushing a branch triggers its
build — so **none of these tools push automatically**; you inspect locally and
push with `deb-push` when ready.

The built packages are then copied into the reprepro repositories at
<https://deb.session.foundation> — this step is **manual and stays manual**
(it uses a signing key that is never stored unencrypted). There are three repos:
the root (public releases), `/beta` (semi-public testing), and `/staging`
(build-only, used to chain dependency builds). Which repo a branch's CI build
pulls its dependencies from is set by `local repo_suffix` in that branch's
`.drone.jsonnet`.

## Tools

All are run from this directory; the first argument is always the checkout dir.
None of them push (except `deb-push`); each prints the push command to run next.

Anywhere a branch or `--only`/glob is expected, a **bare codename** works as
shorthand for its full branch: `sid` → `debian/sid`, `noble` → `ubuntu/noble`,
etc. (the known codenames are the `version_suffix` keys in `build-distros.bash`;
they're unique across debian/ubuntu). So `--only sid,trixie,forky` and
`./deb-push oxen-mq sid,noble` both work.

### `./deb-version-bump <repo> [--force] [--create-missing] [<source-ref>]`
New upstream release across **all** active distro branches. Reads the new version
from `<source-ref>`'s top-level `CMakeLists.txt` (`project(... VERSION x.y.z)`);
the package version becomes `<version>-1<suffix>`. `<source-ref>` defaults to
`origin/stable`. For each branch: merge upstream → rebase & re-export the patch
queue → changelog → regenerate `control` → commit. Aborts (touching nothing)
unless the new upstream version is greater than every branch's current version
(`--force` overrides).

If an active distro branch doesn't exist yet, it's created **as part of this
release** rather than being a hard error. The existing branches are bumped first;
then the new branch is forked off its now-updated family base (`debian/*` from
`debian/sid`, `ubuntu/*` from the newest `ubuntu/*`) and given a debut changelog
entry at the new version — exactly what `deb-add-distro` does after a release, so
it debuts directly at the new version with no invented prior history. You're
prompted first (after a builder-image check); `--create-missing` skips the prompt
for non-interactive runs. A branch that can't be forked (no family base) is still
a hard error pointing at `deb-add-distro`.

### `./deb-add-patch <repo> <commit> [<commit>...] -m "<msg>" [--only <glob>…] [--no-bump]`
Cherry-pick one or more **source** commits into the gbp patch queue across the
active branches, with a `-N` revision bump. `--only <glob>[,…]` restricts to
matching branches for a fix only some distros need; a partial run appends/bumps a
`+M` (leaving `-N` alone, so distro-upgrade ordering is preserved) instead of
bumping `-N`. `--no-bump` applies the patch with **no** version bump or changelog
entry at all (takes no `-m`) — use it when the current version was never
built/published, so the fix needs no new version to distinguish it (e.g. fixing a
build error on the distros whose build failed); combine with `--only` to target them.

### `./deb-rebuild <repo> [-m "<msg>"] [--only <glob>…]`
No-change rebuild bump (Debian binNMU-style) — no source or packaging change,
just a version bump + changelog entry so CI rebuilds. Use it to relink against a
new system-library soname (e.g. libsodium moved on forky). `-m` defaults to
"Rebuild"; `--only` works as above (`+M` for a partial rebuild).

### `./deb-pkg-update <repo> [<commit>...] -m "<msg>" | <commit>... --no-bump`
Propagate a **packaging** change (to `debian/…`) with a `-N` revision bump. First
commit your change on `debian/sid` yourself, then run this: it bumps sid's
changelog and cherry-picks the packaging commit(s) onto every other branch. With
no commit refs it auto-detects the packaging commits on sid since the last
changelog entry (and asks for confirmation if there's more than one).

`--no-bump` cherry-picks the given commit(s) onto every active branch that lacks
them with **no version bump and no changelog entry** — for when a version bump is
coming separately and you don't want a throwaway `-N`. Explicit commit ref(s) are
required (they can live on any branch, e.g. a fix committed on one distro);
branches that already have the commit, or don't exist yet, are skipped; `-m` isn't
accepted.

### `./deb-push <repo> [--no-wait] [<branch-glob>...]`
Push branches to origin (triggering CI). Globs match the active distro list, e.g.
`debian/sid`, `'debian/*'`, `'ubuntu/*'` (quote them), or bare codenames. Give
several space- or comma-separated (`debian/sid forky` or `sid,forky`). No
argument = all. If any glob matches nothing, nothing is pushed. Before pushing it runs a **dependency
pre-check**: for each branch it verifies every Session-family build-dependency is
available at the required version in that branch's target reprepro repo (parsed
from its `.drone.jsonnet`); if any is missing, nothing is pushed (an unsatisfied
dep is a guaranteed CI failure — publish the dependency first).

After pushing it **watches the triggered CI builds** to completion — the same
live, refreshing per-branch status display `deb-cascade` uses, with links to each
build — and exits non-zero if any build fails. Pass `--no-wait` to skip the watch
(or if the `drone` CLI / `DRONE_SERVER`+`DRONE_TOKEN` aren't available it's skipped
automatically).

### `./deb-add-distro <repo> <debian|ubuntu>/<codename>`
Create packaging for a new distro release. New `debian/*` branches fork from
`debian/sid`; new `ubuntu/*` branches fork from the newest existing `ubuntu/*`
branch. The `~suffix` must already be defined in `build-distros.bash`. Makes the
three standard edits (`.drone.jsonnet` distro, `debian/gbp.conf`
`debian-branch`+`dist`, and a new changelog entry) and commits. It also checks
that the builder docker image for the new codename exists first. Remember to add
the new branch to the `distros` list in `build-distros.bash` when it should join
the regular build set.

## Rebuilding across all packages (cascades)

To build a whole set of packages — e.g. add a new distro like `ubuntu/resolute`
everywhere — order matters: a package can't build until the Session-family
packages it build-depends on have been built by CI **and** uploaded to
`/staging`. Two tools handle this, driven by the `build-order` file (one line per
build step; repos on a line have no interdependency and build in parallel; each
line must be published to `/staging` before the next):

### `./deb-add-distro-all <branch> [<repo>...]`
Create the branch in every repo in `build-order` (order-independent; skips repos
that already have it; does not push). Prep step before a cascade.

### `./deb-cascade <branch> [<repo>...]`
Push the branch across all repos **in dependency order**, one `build-order` line
at a time. For each line it: skips repos already in `/staging` at that version
(so it's safe to re-run after a failure), pushes the rest, **watches each CI
build to completion** (alerting on success, stopping on failure), then pauses for
you to upload the built packages to `/staging` (the manual signing step),
auto-rechecking until they appear before moving to the next line. Requires the
`drone` CLI with `DRONE_SERVER`/`DRONE_TOKEN` set.

So, to add resolute everywhere:
```sh
./deb-add-distro-all ubuntu/resolute     # create + review branches locally
./deb-cascade        ubuntu/resolute     # push in order, monitor CI, pause for /staging
```

## Resume after conflicts

`deb-version-bump`, `deb-add-patch`, and `deb-pkg-update` operate over ~10
branches and can hit merge / rebase / cherry-pick conflicts. `.drone.jsonnet`
conflicts are auto-resolved (keep the packaging branch's copy); anything else
stops with instructions. Progress is recorded in
`<repo>/.git/session-pkg-state`. To resume: resolve the conflict, complete the
git operation (`git merge/rebase/cherry-pick --continue`), and **re-run the exact
same command** — it skips completed branches and continues. To abandon, delete
that state file.

## `build-distros.bash`

Sourced by all tools. Defines:
* `version_suffix` — every known distro's version suffix (includes old/future
  entries as a handy reference).
* `distros` — the branches the tools currently act on.

## `build-order`

The cross-repo dependency ordering used by `deb-cascade` (see above). Hand-
maintained; the header comment records the build-dep graph it was derived from.
Keep every repo on a line strictly later than all of its dependencies.

## `deb-migrate-hosts` (throwaway)

A one-shot, **uncommitted** helper that rewrites the dead `builds.lokinet.dev`
(and file-server `oxen.rocks`) hostnames to `builds.session.codes` across a
repo's branches. Not part of the maintained toolset — it stays untracked (not
git-ignored, so `git status` keeps it in view).
