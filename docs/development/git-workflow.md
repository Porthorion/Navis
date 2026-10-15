# Git Workflow

How branches, commits, pull requests and releases fit together. This is the
single canonical place; [AGENTS.md](../../AGENTS.md) and
[CONTRIBUTING.md](../../CONTRIBUTING.md) summarize it and link here.

The public GitHub repository `Porthorion/Navis` is the primary place for work.
Every change goes through a branch and a GitHub pull request, so activity is
public and CI runs before anything merges.

```text
topic ──PR──► dev ───────────────────────────────► (1.6 work)
                 \
                  └─ release/1.5 ──fix PRs──► ... ──► main ── tag v1.5.0
                        ▲   │                    (fast-forward on release day)
                        │   └── back-merge into dev after each fix PR
                        └────── later patches (1.5.1, ...) from the same branch
```

## Remotes and roles

| Remote | Where | Role |
| --- | --- | --- |
| GitHub `Porthorion/Navis` | public | Primary: branches, pull requests, CI, issues, tags. |
| `origin` (Forgejo `Navis-dev`) | private | Owner's backup of everything. |
| `public` (Forgejo `khalifa/Navis`) | public | Only a README and the 1.5.0 bridge release for 1.4.x updaters. Do not push work there. |

The maintainer clone gives `origin` two push URLs, so `git push origin <branch>`
updates Forgejo and GitHub. Recommended: fetch from GitHub, so a pull request
merged on GitHub shows up on `git pull` and the next `git push origin dev`
brings Forgejo up to date.

```bash
# Existing maintainer clone (both push URLs already set): change only fetch.
git remote set-url origin https://github.com/Porthorion/Navis.git
# Fresh clone: also add both push URLs. The first --push replaces the
# implicit one, so add both.
git remote set-url --add --push origin https://github.com/Porthorion/Navis.git
git remote set-url --add --push origin <forgejo-navis-dev-url>
git remote -v   # fetch: GitHub; push: GitHub and Forgejo
```

Keep the separate `github` remote: `tool/release.sh --github` pushes to it.

## Branches

- `main`: exactly what has been released. Changes only on release day.
- `dev`: work for the next version.
- `release/X.Y` (for example `release/1.5`): cut from `dev` at feature freeze.
  It lives on as the X.Y.x maintenance line: fixes only, never features. It is
  deleted once the next minor ships and X.Y is no longer patched.
- Topic branches: short-lived, named `<type>/<short-kebab>` with a
  Conventional Commit type (`feat`, `fix`, `refactor`, `perf`, `docs`, `test`,
  `ci`, `chore`, `build`), for example `fix/queue-after-reconnect`. One topic
  per branch. Branch from `dev`, or from `release/X.Y` for a fix to a shipped
  line. Delete after merge.
- Per-release scratch branches such as `release/v1.5.0` (the
  `tool/release.sh` worktree) are temporary. Delete them after the release.

## Commits

- Conventional Commits: `type(scope)?: summary`. Imperative summary, at most
  72 characters. The body explains why, not what.
- One logical change per commit.
- Generated files (`make gen`) go in the commit that needs them.
- Never commit secrets.
- Agents add a `Co-Authored-By: <Agent/Model> <noreply@...>` trailer
  ([CONTRIBUTING.md](../../CONTRIBUTING.md#who-gets-credit)).
- Run `./tool/check.sh` before pushing, or at least before marking a pull
  request ready.

## Pushing

- Push topic branches freely. They are public, so keep them clean: no private
  hostnames, IPs, local paths or credentials
  ([AGENTS.md](../../AGENTS.md) writing rules).
- Open a draft pull request early when it helps.
- `--force-with-lease` only on your own topic branch. Never force-push `main`,
  `dev` or `release/*`.
- Never push directly to `main`, `dev` or `release/*`. The exceptions are the
  release-day push by `tool/release.sh`, and back-merges of `release/X.Y`
  into `dev`.

## Pull requests

- Target `dev` for features and fixes, `release/X.Y` for fixes to a shipped
  line.
- Title is a Conventional Commit. Fill in
  [the template](../../.github/pull_request_template.md).
- CI (the `ci` job, see [ci-cd.md](ci-cd.md)) must be green.
- Merge method: "Create a merge commit". It keeps each author's commits, which
  matches the credit policy. Squash only for a maintainer's own messy branch.
- Delete the branch on merge.
- Agents open a pull request only when the maintainer asks, and never merge.
- Docs-only pull requests skip CI (`paths-ignore`), so the maintainer merges
  them as admin.

## Versions and releases

The version in `pubspec.yaml` follows
[the versioning rules](agentic-engineering.md#versioning): `dev` starts the
next version before new work, and `release/X.Y` carries the patch versions of
that line. Dev builds come from `tool/dev_release.sh`, run from `dev` or
`release/X.Y`.

Stable release, at the git level:

1. Freeze: cut `release/X.Y` from `dev`.
2. Fixes land as pull requests into `release/X.Y`. After each, merge
   `release/X.Y` into `dev` ("Merge release/1.5 into dev").
3. Release day: run `tool/release.sh` on `release/X.Y`. It fast-forwards
   `main` to the branch, tags `vX.Y.Z`, pushes `main`, the branch and the tag,
   then builds and publishes. Do not merge or tag by hand; see
   [development-workflow.md](development-workflow.md#publishing-a-release)
   and the guides under [docs/release/](../release/release-from-linux.md).
4. Back-merge into `dev`.
5. Later patch releases (X.Y.1, ...) repeat steps 2 to 4 on the same branch.

## Hotfix and cherry-pick

A fix to a shipped line is a pull request into `release/X.Y`, then back-merged
into `dev`. If the fix was already made on `dev`, cherry-pick it:

```bash
git switch -c fix/short-name origin/release/1.5
git cherry-pick -x <sha>
```

Push and open a pull request into `release/1.5`; `-x` records the original
commit in the message.

## Quick reference

| I want to... | Do this |
| --- | --- |
| Start a feature or fix | Branch `<type>/<name>` from `dev`, open a PR into `dev`. |
| Fix a shipped version | Branch from `release/X.Y`, PR into `release/X.Y`, back-merge into `dev`. |
| Bring a `dev` fix to a shipped line | `git cherry-pick -x` onto a branch from `release/X.Y`, own PR. |
| Update my PR branch | Add commits; `--force-with-lease` only if you rebased. |
| Start a release line | Cut `release/X.Y` from `dev` at feature freeze. |
| Ship | Run `tool/release.sh` on `release/X.Y` (fast-forwards `main`, tags, pushes), then back-merge into `dev`. |
| Clean up | Delete merged topic branches; delete `release/X.Y` when no longer patched. |

## GitHub settings

Configured by the maintainer, not by the repository:

- A branch protection rule or ruleset for `main`, `dev` and `release/**`:
  require a pull request and the `ci` status check (the final job of
  `.github/workflows/ci.yml`, which fails unless `static` and every test shard
  passed), block force-pushes and deletion. The release-day push by
  `tool/release.sh` and back-merges are done by the maintainer as admin.
- "Automatically delete head branches" on.
- Allowed merge methods: merge commit (default); squash allowed for
  maintainer use; rebase off.
