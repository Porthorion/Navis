# AI-assisted contributions

AI-assisted work is welcome in Navis, and most of the project is written with AI help. What matters is that a person stands behind each contribution: whoever submits an issue or pull request is responsible for understanding it, testing it and explaining it. This page applies to contributors, to the maintainer, and to agents working in the repository.

## Disclosure

Every issue and pull request states:

| Field | Meaning |
|---|---|
| Harness | The tool that drove the model, for example Claude Code, Codex CLI, Cursor, or `none` |
| Tool(s) | Other AI-based tools used, or `none` |
| Model(s) | The exact identifier the tool reports, or `n/a` |
| Involvement | One of: `Fully AI-generated, human verified`, `AI-assisted`, `Human-written, AI-reviewed`, `No AI used` |
| Adversarial review | Scope, method, findings and what changed because of them; `n/a` for trivial changes |

The issue forms and the pull request template contain these fields.

## Before you submit

- Read the full diff and be able to explain every part of it.
- Check that every API, file path and command you reference exists in the repository.
- Run focused tests for what you changed, then `./tool/check.sh`.
- Look at effects beyond the edited files: callers, configuration, generated code, documentation.
- For non-trivial changes, have the work reviewed independently (a different model, session or person) with the explicit aim of finding faults, and resolve what it finds.

## Evidence must be real

Logs, reproduction steps, test results, screenshots and version numbers must be things you actually observed. Do not let a model fill in plausible-looking output. If something was not run or could not be reproduced, say so.

## Enforcement

- Fabricated evidence (invented logs, reproduction steps, test results, APIs or vulnerabilities) gets the contributor blocked, even on a first offence.
- Undisclosed AI use gets the contribution closed. Repeated non-disclosure gets the contributor blocked.

## Agents and the maintainer

The same rules bind agents working on the repository and the maintainer. Agents follow the writing and pull request rules in [AGENTS.md](../../AGENTS.md) and never open a pull request unless the maintainer explicitly asks.

An agent that wrote a substantial part of a commit is credited with a trailer, using the convention already in the history:

```
Co-Authored-By: <agent name> <the agent vendor's noreply address>
```

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for the wider contribution process and [agentic-engineering.md](agentic-engineering.md) for the engineering workflow and Definition of Done.
