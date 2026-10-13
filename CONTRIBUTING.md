# Contributing to Navis

Thanks for helping. Navis is licensed GPL-3.0-or-later; by submitting a contribution you agree to license it under the same terms.

## Before you start

- Search [existing issues](https://github.com/Porthorion/Navis/issues) first. For bugs, use the bug report template; for ideas, the feature request template.
- Read [AGENTS.md](AGENTS.md) and [docs/agentic-engineering.md](docs/agentic-engineering.md). They are the canonical project rules, including the Definition of Done. Use [docs/README.md](docs/README.md) to find the subsystem docs.

## Setup and checks

```bash
./tool/bootstrap.sh   # once
./tool/check.sh       # format, codegen, analyze, tests; run before every PR
```

Setup details are in [docs/development-workflow.md](docs/development-workflow.md).

## Pull requests

- Target the `dev` branch. `main` holds releases only.
- Keep PRs small and focused on one change.
- Update the relevant documentation in the same PR.
- Fill in the PR template.

## How merges work

Development happens in a private repository. On GitHub, `dev` is the integration branch and `main` holds releases. Maintainers merge accepted PRs through the private repository, so the merge commit on GitHub may differ from your branch. Your authorship is kept.

## Name and logo

The Navis name and logo are reserved. See [TRADEMARK.md](TRADEMARK.md) before using them, for example in a fork.
