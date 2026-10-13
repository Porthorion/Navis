---
name: navis-subsonic-sync
description: Navis Subsonic/OpenSubsonic API integration and library synchronization — Dio error handling, the response envelope, authentication and credential redaction, server capabilities, pagination, scans, reconnect, and retry-safe mutations like scrobbles and playlist edits. Use for any API client, sync engine, or server-communication change or bug.
metadata:
  author: ChatGPT
  version: '1.1'
  project: Navis
  origin: custom-not-official
  prepared: '2026-09-22'
  adapted: trimmed duplicated policy boilerplate, anchored to repo paths
---

# Navis Subsonic API and Synchronization

Task-scoped workflow for API and sync work. AGENTS.md and
`docs/development/agentic-engineering.md` are always loaded and govern scope and
validation. The clients live under `lib/src/api/` (Subsonic, Last.fm,
LRCLIB); sync persistence flows through `lib/src/database/`.

## Ground rules

Inspect the actual client, adapters, authentication model, URL builders,
DTOs, database mapping, capability checks, and tests before editing. Do not
assume every server implements every OpenSubsonic extension, or that all
endpoints return the same kind of content. Preserve compatibility required by
the product rather than treating one tested server as the entire protocol.
Keep server/account-qualified identity across API results, cache keys,
database rows, and playback references.

## Parse transport and protocol failures separately

For endpoints returning a Subsonic response envelope, check its command
status and error payload **in addition to** HTTP status. Handle non-JSON
responses from proxies or auth failures without treating them as an empty
library. Stream, cover-art, and download endpoints need their own response
handling — do not route every response through the JSON parser.

Differentiate timeout, cancellation, transport loss, authorization failure,
unsupported capability, malformed payload, and valid empty data.
connectivity_plus reports connectivity types, not guaranteed server or
internet reachability; let actual requests decide whether the configured
server is reachable, and never add a public-internet probe as a prerequisite
for a private/LAN server.

Preserve optional-field compatibility and unknown-field tolerance consistent
with the protocol and existing models. Regenerate affected Freezed/JSON
artifacts with `make gen`; never solve parsing failures by weakening all
models or hand-editing generated files.

## Make retries, pagination, and sync safe

Use the existing Dio cancellation and request/session ownership model. Reject
late results after the user changes account, server, search, or sync
generation. Keep retry bounds task-appropriate across Dio, providers, and
reconnect logic; cancellation and auth errors must not become retry storms.

Decide retry safety by **endpoint semantics**, not HTTP method — in this
protocol a GET may still mutate state. Do not replay scrobbles, playlist
changes, or other side effects blindly after an uncertain network outcome;
preserve existing deduplication/conflict handling rather than inventing
server idempotency guarantees.

For scans and pagination, preserve server-defined order and offsets while
preventing duplicate records. A failed or partial scan is **not** an
authoritative deletion list; reconcile deletions only after the project's
complete-scan conditions hold. Sync executions hold leases (see the sync
sections of `docs/architecture.md`) — work that lost its lease must record
that and must not write. Coordinate schema or retained-media changes with
`offline-library-consistency`.

## Protect credentials without changing product scope

Keep secrets and credential-bearing URLs out of logs, diagnostics, test
fixtures, screenshots, and OS media metadata. Inspect Dio
logger/interceptor behavior, redirects, and retry paths — not only the
initial request. Preserve the secure-storage abstractions; never disable
certificate verification, enable insecure networking globally, change server
credentials, or upgrade auth schemes to make a test pass. Use locally
controlled fixtures or the explicitly authorized development server
(`docs/development/development-workflow.md`); no real server writes are needed for unit
tests.

## Regression coverage and verification

Candidate fixtures: valid empty results; `status="failed"` envelope; HTTP
error with an HTML body; missing optional metadata; unknown extra fields;
unsupported extensions; duplicate IDs across different servers; canceled
search; mid-scan disconnect; reconnect to a changed account; uncertain
outcome of a non-idempotent operation. Assert redaction and protection
against partial-sync data loss where relevant. Place tests mirroring the
source layout under `test/src/api/` or `test/src/features/...` (harness
patterns in the `dart-add-unit-test` skill).

Run focused tests, `flutter analyze --no-fatal-infos`, and `./tool/check.sh`.
Runtime-affecting sync work needs the authenticated diagnostics-API loop from
`docs/development/development-workflow.md` against the authorized dev server.

## Primary references

- OpenSubsonic overview: https://opensubsonic.netlify.app/docs/
- Subsonic response envelope:
  https://opensubsonic.netlify.app/docs/responses/subsonic-response/
- Dio: https://pub.dev/packages/dio
- connectivity_plus limitations: https://pub.dev/packages/connectivity_plus
