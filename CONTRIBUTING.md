# Contributing to Navis

Thanks for helping. Navis is licensed GPL-3.0-or-later; by submitting a contribution you agree to license it under the same terms.

## The most useful contribution is a good issue

Navis has one maintainer, so review time is the scarce resource. A clear, accurate issue helps more than an unsolicited patch, because it lets the maintainer (or an invited contributor) fix the right thing.

**Pull requests are taken from two groups:**

- people who already have a pull request merged in Navis, and
- anyone a maintainer has invited to send one, usually in a comment on an issue.

Any other pull request is closed politely, without review, with a pointer to open an issue first. The code can still serve as a reference for the fix. This is about review capacity, not the quality of anyone's work, and it applies the same way whether or not AI was used.

## Writing a useful issue

Use the bug report, enhancement or server compatibility template, and search [existing issues](https://github.com/Porthorion/Navis/issues) first.

- One problem per issue.
- Report what you observed before what you think caused it.
- Give exact steps, the expected result and the actual result.
- Include the Navis version, platform, and server software and version.
- Paste raw logs, not summaries. Mark every redaction (credentials, tokens, private server addresses, personal data) so readers know something was removed.
- For a feature request, describe the problem and who it affects, and check [what is not planned for now](docs/project/non-goals.md) first.
- A suspected cause or fix is welcome, but put it under "Technical notes", separate from the observations.
- Disclose any AI use (see [AI-assisted contributions](docs/development/ai-contributions.md)). Fabricated reports lead to a block.
- Security problems go privately through the Security tab, as described in [SECURITY.md](SECURITY.md). Never open a public issue for them.

## Pull requests (invited or eligible)

- One concern per pull request, with no unrelated cleanup.
- Follow the existing patterns in the surrounding code.
- Add tests that fail before the change and pass after it.
- Exercise user-facing behaviour in the running app when you can.
- Read the whole diff yourself for stray edits, local paths and credentials.
- For non-trivial changes, get an independent or adversarial review and resolve its findings.
- Update the relevant documentation in the same pull request.
- Target `dev`, or `release/X.Y` for a fix to a shipped version (see [Branches](#branches)).
- Fill in the [pull request template](.github/pull_request_template.md). Everything on GitHub is public, so leave out private hostnames, IPs, local paths and credentials, and leave out working-session history.

Read [AGENTS.md](AGENTS.md) and [docs/development/agentic-engineering.md](docs/development/agentic-engineering.md); they are the canonical project rules, including the Definition of Done. [docs/README.md](docs/README.md) indexes the subsystem docs.

### Setup and checks

```bash
./tool/bootstrap.sh   # once
./tool/check.sh       # format, codegen, analyze, tests; run before every PR
```

CI mirrors part of `check.sh`, not all of it. Setup details are in [docs/development/development-workflow.md](docs/development/development-workflow.md). Report only checks you actually ran, and never say a check passed if it did not.

## AI-assisted contributions

AI-assisted work is welcome; most of Navis is written with AI help. The person who submits it is responsible for understanding, testing and explaining it. Every issue and pull request must disclose the harness, tools, models and level of AI involvement. The rules, including what gets a contribution closed or a contributor blocked, are in [docs/development/ai-contributions.md](docs/development/ai-contributions.md).

## Who gets credit

Pull requests are merged on GitHub with a merge commit. To keep credit clear:

- Maintainers keep your original commits and authorship by merging without rewriting them. You appear in the history and the contributor graph.
- If a squash or rewrite is unavoidable, the resulting commit carries a `Co-authored-by: Name <email>` trailer for every contributor, and the pull request is closed with a comment linking that commit.
- AI agents that wrote a substantial part of a commit are credited with a trailer in the form `Co-Authored-By: <Agent/Model> <noreply@...>`.
- Release notes may thank contributors by GitHub handle.

## Name and logo

The Navis name and logo are reserved. See [TRADEMARK.md](TRADEMARK.md) before using them, for example in a fork.

## Questions and ideas

Use [GitHub Discussions](https://github.com/Porthorion/Navis/discussions) for how-to questions (Q&A) and early ideas (Ideas). Keep Issues for confirmed bugs and concrete enhancement requests.

## Branches

- `dev`: new features and general fixes. Target pull requests here.
- `release/X.Y` (for example `release/1.5`): the maintenance line of a
  release. Fixes to that version target this branch; maintainers merge them
  back into `dev`. If unsure, target `dev` and mention it in the pull request.
- `main`: released code only, tagged `vX.Y.Z` on release day.

Use a topic branch named `<type>/<short-kebab>`. The full workflow is in
[docs/development/git-workflow.md](docs/development/git-workflow.md).
