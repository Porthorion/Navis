# Architectural decision records

Navis does not reconstruct historical ADRs without reliable evidence. Create a
new record here only for a durable, cross-cutting decision whose rationale and
trade-offs future contributors need. Small local implementation choices belong
in code and the owning active document instead.

## Decision records

- [First-setup catalog readiness — 2026-09-20](2026-09-20-first-setup-readiness.md)
  — superseded by the partial-readiness decision below.
- [Full-screen sync partial readiness — 2026-09-20](2026-09-20-fullscreen-sync-partial-readiness.md)
  — accepted recovery boundary for isolated album-detail failures.
- [Shared design foundation — 2026-09-30](2026-09-30-design-foundation.md)
  — tokens, typography and component themes.
- [External integrations policy — 2026-10-04](2026-10-04-external-integrations-policy.md)
  — one user-controlled integration policy.
- [Colour styles — 2026-10-07](2026-10-07-colour-styles.md)
  — the second theme axis and subsequent appearance decisions.

## New records

Use `YYYY-MM-DD-short-title.md` and this structure:

```markdown
# Decision: <title>

- Date: YYYY-MM-DD
- Status: accepted | superseded | deprecated
- Supersedes: <record or none>
- Superseded by: <record or none>

## Context

## Decision

## Reasoning and alternatives

## Consequences
```

Link the record from the active architecture or workflow document when it
changes how contributors should work. Do not invent a date, rationale, or
alternative; mark unavailable historical details as unknown.
