# Navis instructions for GitHub Copilot

Start with [AGENTS.md](../AGENTS.md), then read the canonical
[agentic engineering guide](../docs/agentic-engineering.md) and the relevant
documentation from [docs/README.md](../docs/README.md). Those documents are
the source of truth; this is a concise compatibility entry point.

Inspect implementation, callers, configuration, and tests before changing
behavior. Make a focused change, update documentation in the same change, and
complete the project Definition of Done. Use `./tool/check.sh` for
implementation work. Runtime-affecting work also requires the diagnostics-API
and screenshot validation loop in `docs/development-workflow.md`.

Do not create `NavisDatabase` outside Riverpod, mutate providers during build,
change playback resolution order (permanent download → rolling cache → stream),
expose secrets, or restore retired Listen Together/Voyage without an explicit
decision. Report validation accurately.
