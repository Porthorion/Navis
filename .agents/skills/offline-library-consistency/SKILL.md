---
name: offline-library-consistency
description: Navis offline storage and Drift consistency — schema migrations, downloads, cache ownership and eviction, missing-file repair, source reconnect, SAF/document permissions, local media identity, and database-to-UI coherence. Use for any database schema change, download/cache feature, file-repair flow, or "downloaded songs disappeared" class of bug.
metadata:
  author: ChatGPT
  version: '2.1'
  project: Navis
  origin: custom-not-official
  prepared: '2026-09-22'
  adapted: trimmed duplicated policy boilerplate, anchored to repo paths
---

# Navis Drift and Offline Library Consistency

Task-scoped workflow for persistence and offline-storage work. AGENTS.md and
`docs/agentic-engineering.md` are always loaded and govern scope and
validation. The database lives in `lib/src/database/` (tables, DAOs,
migrations); storage flows through the downloads and cache features.

## Ground rules

Read the actual storage abstractions and generator configuration instead of
inventing class or table names. Trace the affected schema and DAO through
scan/download services, playback source selection, providers, and UI
indicators. Custom download folders are **user-owned** (see
`docs/architecture.md`) — treat that as a hard ownership boundary.

Determine how account/server/source identity qualifies remote item IDs and
local references. Do not merge records merely because filenames, titles, or
unqualified server IDs match — real libraries contain distinct tracks with
identical titles and trailing-space variants.

## Map data, bytes, and ownership

Classify every byte store as one of: app-owned disposable cache, retained
offline download, user-owned local media, or provider-managed document.
Unknown ownership is not permission to delete. Classify every reference as
native path, file URI, content/document URI, or network URL, and use the
actual abstraction for that kind — a content URI is not an ordinary path and
a display name is not a filesystem identity. Keep artwork caching separate
from audio caching and retained downloads unless the implementation
explicitly shares them.

## Separate missing from inaccessible

Distinguish confirmed absence from: disconnected mount, temporarily
unavailable provider, revoked permission, partial download, corrupt data,
transient I/O failure. Preserve the information needed to recover when a
source returns. Check persisted grants and actual provider capabilities in
Android storage work — do not assume a permission API exists in the selected
picker package.

Cache eviction must preserve user-owned music, retained downloads, and bytes
in active use. Verify the managed boundary and ownership before deletion:
lexical normalization or string-prefix matching alone does not prove physical
containment (symlinks, races) — use filesystem primitives such as
canonicalization. If safety cannot be established, do not delete. Run
deletion tests only against isolated fixtures.

## Keep storage transitions recoverable

A database transaction does not atomically commit filesystem or
document-provider work. Use the existing staged writes, completion markers,
reconciliation, or compensating cleanup so interruption leaves a recoverable
state; check provider capabilities before assuming atomic rename.

Make repeat repair/reconnect safe: prevent old scans and downloads from
writing after source changes or cancellation. Use targeted database updates
and provider invalidation — never rescan the whole library per widget build
or playback tick. A partial server scan or permission error must not become
an instruction to purge unseen items.

## Handle Drift changes as upgrades, not fresh installs

Inspect `schemaVersion`, historical schema snapshots, migrations, type
converters, constraints, indexes, and build.yaml. A schema change requires:
a stepwise migration, regenerated Drift output via `make gen`, and updates
to `test/src/database/migrations/navis_migration_test.dart` (repo rule).
Never rewrite historical snapshots to hide an incompatibility, reset real
databases, or hand-edit generated output.

Test upgrades from the affected prior schema versions with representative
data — not only empty-database creation — verifying preserved user intent
and relationships, not just schema shape. Also test the affected DAO
query/watch behavior so committed repair/download changes reach providers
and UI. Use the configured Drift executor; a mock DAO alone is not a
migration test. Use `withTestDatabase` from `test/helpers/` for provider-DI
database access in tests.

## Regression coverage and verification

Candidate fixtures: missing app cache; interrupted download; retained
offline track; inaccessible user-owned file; disconnected volume returning;
revoked document permission; repeat repair; identical item IDs on two
servers; source switch during a download; populated-database upgrade.
Include negative tests proving protected media is not deleted.

Run the migration test and focused suites, `flutter analyze
--no-fatal-infos`, and `./tool/check.sh`. Runtime-affecting storage work
needs the runtime loop (persistence + clean restart) from
`docs/development-workflow.md`.

## Primary references

- Drift migrations: https://drift.simonbinder.eu/migrations/
- Drift migration tests: https://drift.simonbinder.eu/migrations/tests/
- Drift transactions: https://drift.simonbinder.eu/dart_api/transactions/
- Android document access / SAF:
  https://developer.android.com/training/data-storage/shared/documents-files
- `p.canonicalize` does not resolve symlinks:
  https://pub.dev/documentation/path/latest/path/canonicalize.html
