# Architectural decision records

Navis does not reconstruct historical ADRs without reliable evidence. Create a
new record here only for a durable, cross-cutting decision whose rationale and
trade-offs future contributors need. Small local implementation choices belong
in code and the owning active document instead.

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
