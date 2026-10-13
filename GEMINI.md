# Navis instructions for Gemini

Read [AGENTS.md](AGENTS.md) first. The canonical policy is
[docs/development/agentic-engineering.md](docs/development/agentic-engineering.md), and
[docs/README.md](docs/README.md) maps the project documentation.

Before editing, inspect the relevant implementation, callers, configuration,
and tests. Keep work focused, update related documentation in the same change,
and use the guide's Definition of Done. Implementation work needs
`./tool/check.sh`; runtime-affecting work needs the diagnostics-API and
app-owned screenshot validation loop.

Do not instantiate `NavisDatabase` outside Riverpod, mutate providers during
build, break the permanent-download → rolling-cache → stream resolver order,
expose secrets, or restore retired Listen Together/Voyage without an explicit
product decision.
