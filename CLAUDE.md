# CLAUDE.md

Guidance for Claude Code working in this repo. Read `README.md` too — this file
covers the things that are easy to get wrong.

## What this repo is

Bash tooling to build/release Debian & Ubuntu `.deb` packages for Session
software. This dir is the canonical packaging working tree; each package repo is
cloned in as a **git-ignored subdirectory** (`liboxenmq/`, `session-router/`,
`oxen-core/`, …) — plain clones, not submodules. Tools are run from here with the
checkout dir as the first arg: `./deb-version-bump liboxenmq`.

The real packaging lives on `debian/<codename>` and `ubuntu/<codename>` branches
*inside each checkout*, managed with git-buildpackage (gbp). This repo never
contains that packaging; it orchestrates it.

## Architecture

* `build-distros.bash` — data (sourced everywhere): `version_suffix` (per-distro
  `~debN`/`~ubuntuNNNN`) and `distros` (branches the tools act on).
* `lib.bash` — all shared functions. Tools are thin front-ends that source it.
  Keep logic here (DRY); don't duplicate across tools.
* `deb-version-bump`, `deb-add-patch`, `deb-pkg-update`, `deb-rebuild`, `deb-push`,
  `deb-add-distro` — the single-repo tools. See README for each. `deb-rebuild` is a
  no-change rebuild bump (binNMU-style, e.g. relinking a new system-lib soname):
  no source change, just a version bump + changelog entry. `deb-add-patch` and
  `deb-rebuild` take `--only <glob>` (per-distro, uses `+M` not `-N`).
* `deb-add-distro-all` + `deb-cascade` — cross-repo tools driven by `build-order`
  (dependency-ordered build steps). `deb-cascade` pushes a branch across all
  repos in order, monitors CI (via the `drone` CLI), and pauses for the manual
  `/staging` publish between steps; it's reentrant (skips repos already in
  `/staging`).
* `build-order` — hand-maintained cross-repo dependency ordering (one line per
  parallelizable build step). Derived from `is_our_package` build-deps.
* `deb-migrate-hosts` — throwaway, not maintained. Left uncommitted (and
  deliberately *not* git-ignored, so it stays visible in `git status`).

Future RPM support should reuse `lib.bash` with thin `rpm-*` wrappers.

## Rules that must not be broken

* **Only `deb-push` pushes.** Every other tool commits locally and stops so the
  user can inspect. Pushing triggers CI builds; publishing to reprepro is a
  separate *manual* step (signing key). Never push or publish automatically.
* **Don't commit the checkouts.** They're ignored via `/*/` in `.gitignore`.
* **Changelog distribution field** = the branch codename, **except `debian/sid`
  = `unstable`** (`changelog_dist` in lib.bash).
* **Version suffix** comes from `build-distros.bash`; sid has none. `deb-add-distro`
  refuses if the suffix isn't defined there yet.
* **`-N` must stay uniform across distros.** The `~debN`/`~ubuntuNNNN` suffix makes
  a newer distro's package outrank an older one's *at the same `-N`*, so a distro
  upgrade is seen as an apt upgrade. Bumping `-N` on only some distros breaks that
  (e.g. `-3~deb11` outranks `-2~deb12`). So a patch/change for only some distros
  (`deb-add-patch --only …`) must NOT bump `-N` — it appends/increments a `+M`
  after the suffix (`bump_plus`), which sorts above the plain version but below the
  next distro's suffix. A full (all-distro) run bumps `-N` and resets any `+M`.
* **Domain names:** new/generated content uses `deb.session.foundation` (apt) and
  `builds.session.codes` (builds file server). Do NOT rewrite existing files'
  older names — `deb.loki.network`/`deb.oxen.io` still work and must stay. The
  docker registry `registry.oxen.rocks` and `registry.session.codes` are the same
  service: leave `registry.oxen.rocks` alone on its own (it's fine), but prefer
  `registry.session.codes` in new code, or when you're already editing that part of
  a file for another reason. The *only* mandatory rewrite is the
  dead `builds.lokinet.dev` → `builds.session.codes` (that's what `deb-migrate-hosts`
  is for).

## Gotchas

* **`.drone.jsonnet` conflicts are expected** on every upstream merge (the
  packaging branch fully replaces it). They're auto-resolved `--ours`; only
  *other* conflicts stop the run.
* **Two conflict points per branch** in `deb-version-bump`: the `git merge` and
  the `gbp pq rebase` (the rebase is the more common one). `deb-add-patch`/
  `deb-pkg-update` conflict at the `git cherry-pick`.
* **Resume state** lives in `<repo>/.git/session-pkg-state` (sourceable bash). On
  conflict the tool records progress and exits; the user resolves + completes the
  git op, then re-runs the *same command* to continue. `run_multibranch` skips
  completed branches. Running a *different* operation while a state file exists is
  refused.
* **Per-branch `gbp.conf`**: each branch sets its own `debian-branch`/`dist`, so
  `gbp dch` runs with `--ignore-branch`, `--spawn-editor=never` (the user hates
  the editor popup), and an explicit `--distribution`. It still auto-generates
  changelog content from commits.
* **`DEBEMAIL`** is set in the user's environment (`jason@session.foundation`) —
  do not override the maintainer identity from git config (which is a different
  address).
* **Version parsing** reads `project(... VERSION x.y.z ...)` from the top-level
  `CMakeLists.txt` (often multiline) via an inline `python3` snippet in
  `parse_cmake_version`.
* **The dep pre-check** (`deb-push`) can only vet a dependency whose source repo
  is checked out here; "ours" is decided by the `is_our_package` heuristic
  (`*session*|*oxen*|*loki*|*sogs*`). Extend that pattern for new families.

## Testing

The pure helpers and the dep-check are unit-testable (source `lib.bash` without
`set -e` and call functions; mock `repo_pkg_version` to avoid the network).
`deb-add-distro` is safely testable end-to-end against a throwaway sandbox clone
(stub the `docker manifest inspect` check). The gbp-pq flows
(`deb-version-bump`/`deb-add-patch`) mutate real branches and are best validated
during an actual release — offer to babysit the first run rather than
auto-testing against real repos.
