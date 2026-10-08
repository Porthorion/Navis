# Decision: Leave full-screen sync after a safe catalog with isolated album detail failures

- Date: 2026-09-20
- Status: accepted
- Supersedes: [Require a complete catalog before leaving first setup](2026-09-20-first-setup-readiness.md)
- Superseded by: none

## Context

The live server repeatedly advertised more songs than four `getAlbum`
responses supplied. A complete first catalog had already been validated and
promoted, but requiring every album detail to succeed left setup on the
full-screen retry view indefinitely. Users cannot correct a server response.
The same full-screen controller handles first setup, cache upgrade, manual
cache reset, and playback recovery. Ordinary Repair Library runs in the
background from Sync Settings and does not use it.

## Decision

Keep the full-screen view while the authoritative catalog is collected,
validated, and committed. A run may leave that view automatically when its only
remaining work is canonical album hydration whose current responses are
provably incomplete. Every pending album must have been attempted in that run;
timeouts, 404s, authentication errors, other required catalog failures, unverified
artists, and uncommitted candidates do not qualify. The current run must have
published its full catalog for every full-screen entry point. Preserve existing songs and
pending album flags. Subsequent eligible automatic incremental checks retry the
albums; the normal manual-only and metered-data policies still apply.

First setup records a separate durable usable-catalog timestamp after this
decision, rather than setting the full-sync timestamp or advancing the server
cursor. All four full-screen reasons use the same
partial-result predicate, and
the existing app notice explains that some items continue in the background.
Complete results continue to use their existing completion evidence.

## Reasoning and alternatives

The user wants the intended full-screen setup while Navis does the initial
work, without asking them to decide what to do about a server-owned defect.
Strictly requiring every album detail can block a usable library forever;
accepting every partial result could expose an unsafe or incomplete catalog.
The response classification and durable readiness marker separate these cases.

## Consequences

Affected albums may lack some tracks until the server returns complete detail.
Sync Settings continues to show their pending state, while later
incremental sync adds missing tracks without replacing known membership from a
truncated response. A broad scan, deletion confirmation, cache reset, or
unrelated verification that has not safely completed still keeps the required
screen. A server that never fixes those albums cannot be made complete by the
client; Navis continues bounded retries under the configured sync policy.
