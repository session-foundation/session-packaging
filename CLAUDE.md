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
  `deb-ci-restart`, `deb-add-distro` — the single-repo tools. See README for each.
  `deb-ci-restart` stops and restarts branches' CI pipelines (no push) and watches
  them; don't confuse it with `deb-rebuild`, which is a
  packaging bump. `deb-rebuild` is a
  no-change rebuild bump (binNMU-style, e.g. relinking a new system-lib soname):
  no source change, just a version bump + changelog entry. `deb-add-patch` and
  `deb-rebuild` take `--only <glob>` (per-distro, uses `+M` not `-N`).
* `deb-add-distro-all` + `deb-cascade` — cross-repo tools driven by `build-order`
  (dependency-ordered build steps). `deb-cascade` pushes a branch across all
  repos in order, monitors CI (Woodpecker at `ci.session.codes`, via
  `woodpecker-cli`), and pauses for the manual
  `/staging` publish between steps; it's reentrant (skips repos already in
  `/staging`).
* `build-order` — hand-maintained cross-repo dependency ordering (one line per
  parallelizable build step). Derived from `is_our_package` build-deps.
* `publish-debs.sh` — the manual reprepro publish step, run on the repo host (not
  a `deb-*` tool: it reads the builds tree, not checkouts). Host paths come from
  `~/.publish-debs.conf`; keep host names and paths out of the script itself. The
  target repo is chosen by the `DEBS_TO_REPO_SUFFIX` variable, which the user's
  own (uncommitted) wrappers set before sourcing the script, so it must keep
  working when sourced.
* `build-latest.sh` — cron job on the builds file server maintaining its
  `latest`/per-version symlinks.
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

* **CI is Woodpecker; packaging CI configs are mid-migration.** Migrated branches
  use `.woodpecker/override-deb.star`: the server's config extension
  (`~/src/session-woodpecker-config`) runs only `.woodpecker/override*` files when
  any exist, so upstream's `.woodpecker/` merges in untouched. Unmigrated branches
  still carry a replaced `.drone.jsonnet`, which the server still accepts (it adds
  a "DEPRECATED" notice workflow to each pipeline, which `ci_build_detail` hides).
  Read CI settings via the `ci_*` helpers in lib.bash, never by hard-coding either
  file. Build links need Woodpecker's numeric repo id (`ci_repo_id`), not the slug.
* **Upstream moving to `.woodpecker/` silently shadows a packaging
  `.drone.jsonnet`** (Woodpecker's search order puts `.woodpecker/` first), and
  CI then runs upstream's full CI instead of the package build. `ci_config_check`
  catches it: `deb-push` refuses, `deb-version-bump` warns. `ci_config_used`
  mirrors the server's `WOODPECKER_DEFAULT_PIPELINE_CONFIGS` order and must be
  kept in step with it.
* **`.drone.jsonnet` conflicts are expected** on every upstream merge into an
  unmigrated branch (the packaging branch fully replaces it). They're
  auto-resolved `--ours`; only *other* conflicts stop the run.
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

## Migrating a repo's packaging CI to `override-deb.star`

General Drone → Woodpecker conversion (labels, `when`, secrets, `CI_*`
variables, cloning, host renames) is documented in
`~/src/session-woodpecker-config/README.md` ("Migrating from `.drone.jsonnet`");
follow that. The deb-specific parts:

* **Template:** copy `.woodpecker/override-deb.star` from an already-migrated
  repo (libquic was the first) rather than converting the old `.drone.jsonnet`
  line by line. Per branch, take the values from that branch's old
  `.drone.jsonnet`: `distro`, the `Debian`/`Ubuntu` family in `distro_name` and
  `builder_image`, `repo_suffix`, `arches` (one per `deb_pipeline(...)` call, from
  its `debarch=`). Don't carry over a reduced `jobs=` (libquic's `ubuntu/jammy`
  used `jobs=2` on arm64 for memory): give the platform the `mem8: yes` agent
  label instead, via `agent_labels = {"arm64": {"mem8": "yes"}}`. That routes the
  build to the 8GB Pi5 agents; without it, a build can land on a 4GB Pi4.
* **Keep the tool-read settings parseable:** `distro`, `builder_image` (as
  `"<prefix>" + distro + "<suffix>"`), `repo_suffix` and `arches` must stay
  single-line top-level assignments in that form. `ci_setting`, `ci_debarches`,
  `check_builder_image` and `create_distro_branch` (which rewrites `distro`
  when forking a new distro) all depend on it.
* **`debian/ci-upload.sh`** reads Drone's variables, which nothing sets any more:
  `DRONE_BUILD_CREATED` → `CI_PIPELINE_CREATED`, `DRONE_COMMIT` →
  `CI_COMMIT_SHA`, `DRONE_BRANCH` → `CI_COMMIT_BRANCH`, `DRONE_REPO` → `CI_REPO`.
* **Upload is a separate step**, the only one with the `SSH_KEY` secret, so the
  upstream build never sees the key. It works because gbp writes the debs to
  `..` of the workspace, which is still inside the `/woodpecker` volume that
  steps share. The step installs `openssh-client` itself because each step starts
  from a fresh container. Workflows run on `push` and `manual` only, since the
  secret isn't available to pull requests.
* **Clone:** Woodpecker's default clone (shallow, with submodules) replaces the
  old `submodules` step. gbp builds with `--git-upstream-tag=HEAD`, so no tags
  are needed.
* **`.drone.jsonnet` on the branch:** make it match upstream so merges stop
  conflicting. If upstream deleted it, delete it; otherwise restore upstream's
  copy (`git checkout <upstream-ref> -- .drone.jsonnet`). Either way the override
  shadows it, because Woodpecker searches `.woodpecker/` first.
* **Applying it across branches:** commit on `debian/sid`, then for each other
  branch cherry-pick the previous branch's commit. Resolve the expected
  `.drone.jsonnet` modify/delete conflict with `git rm`, and edit the distro
  lines before `cherry-pick --continue`. Picking from the previous branch of the
  same family keeps ubuntu branches starting from ubuntu values.
* **Versioning:** no bump is needed when the current version was never built (as
  with libquic, whose push had run upstream's CI instead). If the current
  version is already published, push the migration only together with the next
  version bump, because pushing it alone rebuilds a published version.
* `ci_config_check` (run by `deb-push`) passing on every branch confirms that
  Woodpecker will pick the override.

## Testing

The pure helpers and the dep-check are unit-testable (source `lib.bash` without
`set -e` and call functions; mock `repo_pkg_version` to avoid the network).
`deb-add-distro` is safely testable end-to-end against a throwaway sandbox clone
(stub the `docker manifest inspect` check). The gbp-pq flows
(`deb-version-bump`/`deb-add-patch`) mutate real branches and are best validated
during an actual release — offer to babysit the first run rather than
auto-testing against real repos.
