# Sync Stability Validation

This document is the current source of truth for the post-1.2.0 sync and
cache-stability investigation. It records only safe, reproducible evidence;
credentials, bearer tokens, server URLs, user libraries, and screenshots are
intentionally excluded.

## Objective

Make ordinary sync resilient across desktop and mobile: failures must remain
visible and actionable, an initial sign-in must remain on Home while sync runs,
and missing or inconsistent local cache/library state must be detected and
repaired automatically. Repair Library remains an explicit recovery control.

## Acceptance matrix

| Scenario | Required production path | Expected result |
| --- | --- | --- |
| Initial sign-in | `session/connect` then normal startup sync | Home remains visible; durable progress/failure state is visible; no forced repair solely because diagnostics observed the session. |
| Normal sync | `LibrarySyncController.syncIfStale()` | Bounded low-data reconciliation; an existing failure is not replaced by a transient skipped/deferred state. |
| Full sync / Repair Library | production repair action | Candidate catalog validates and promotes atomically; interrupted work resumes safely. |
| Missing rolling/permanent cache file | startup/maintenance production cache manager | Missing DB entries/files are reconciled without user intervention; playback falls back safely if needed. |
| Corrupt isolated cache | clone-only diagnostics fault action | Maintenance removes stale metadata; an explicit repair remains usable afterward. |
| Windows | Windows profile build, authenticated app API, app-owned screenshots | Same endpoint contract and acceptance matrix as Linux, plus Windows-native build/startup evidence. |

## Controls and safety boundaries

- All runtime assertions use Navis's bearer-authenticated app API; diagnostics
  profiles are isolated. The primary profile never permits destructive fault
  injection.
- `GET /v1/cache/status` reports only counts. Clone-only cache corruption and
  maintenance actions never return filesystem paths.
- Screenshots are captured through `POST /v1/presentation/screenshot` and must
  be opened for review when Flutter-visible behavior changes.
- Never place account credentials, access tokens, remote URLs, or user-library
  data in this document or logs.

## Findings and implemented checkpoints

| Date | Checkpoint | Evidence / result |
| --- | --- | --- |
| 2026-08-10 | Windows diagnostics enabled | Profile builds on Linux and Windows can host the same authenticated control plane. Windows SSH reachability and toolchain were verified; an isolated remote build checkout was created without touching the existing user profile. |
| 2026-08-10 | Initial Home flow | A first sync now starts from the normal shell and routing no longer forces `/initial-sync`. Home exposes progress and a retry action for failure. |
| 2026-08-10 | Failure durability | A no-op/deferred automatic pass preserves a previously failed sync state instead of making the failure disappear. |
| 2026-08-10 | Cache fault controls | Isolated diagnostics can inspect cache counts, simulate a missing cache file, and invoke the production cache-maintenance path. |

## Active investigation

1. Ensure diagnostics observation does not instantiate the legacy initial-sync
   controller and upgrade a normal initial sync into a user-requested repair.
2. Add or prove an automatic cache-maintenance trigger that is safe under
   Riverpod test/container lifecycles, then cover it through the app API.
3. Run the full matrix on a live interactive Windows desktop session. The VM is
   reachable by SSH, but the current remote console has no logged-in desktop
   session, so GUI launch/handshake cannot yet be observed there.
4. Repeat Linux normal/repair/cache-fault scenarios after each behavior change,
   then run the full quality gate. The current analyzer gate reports existing
   informational findings as a non-zero result; no error or warning was found
   in the inspected output.

## Evidence rules for completion

Completion requires focused tests, a clean Linux isolated-profile rerun, an
opened Home progress/failure screenshot, a clean restart, and an interactive
Windows isolated-profile run that exercises normal sync, Repair Library, cache
fault/maintenance, and restart. Record each command/artifact location in
`PROGRESS.md`; do not claim Windows completion from an SSH-only build.
