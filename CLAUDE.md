# Navis instructions for Claude

Read [AGENTS.md](AGENTS.md) first, then
[docs/agentic-engineering.md](docs/agentic-engineering.md) and the relevant
subsystem documentation from [docs/README.md](docs/README.md). They are the
canonical project guidance; this file intentionally does not duplicate them.

Before implementation, inspect relevant source, callers, configuration, and
tests. Keep changes focused, update documentation in the same change, and
follow the Definition of Done in the canonical guide. For runtime-affecting
work, use the authenticated diagnostics API and the mandatory runtime loop in
`docs/development-workflow.md`; inspect app-owned screenshots for visible UI.

Never instantiate `NavisDatabase` outside Riverpod, mutate a provider during
widget build, break the permanent-download → rolling-cache → stream playback
order, expose credentials, or reintroduce retired Listen Together/Voyage
without an explicit product decision. Run `./tool/check.sh` for implementation
work and report only validation actually run.
