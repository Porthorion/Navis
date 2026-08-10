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
| 2026-08-10 | Live cache self-repair | Playback source resolution deletes a missing cache record before falling back to the stream, so stale cached/downloaded state cannot persist until the next startup sweep. |
| 2026-08-10 | Linux authenticated run | A clean isolated profile connected through the app API, began the normal `fetchingArtists` path after a passive connect response, and showed Home plus the visible sync banner in an opened screenshot. A rolling-cache fault reported one missing entry and production maintenance reduced it to zero. The final playback retry encountered a remote-media timeout, so it is not used as cache-repair evidence. |
| 2026-08-10 | Linux clone certification | `tool/sync_diagnostics.sh clone` completed its API-driven interruption/restart, metered-policy, mutation-precedence, normal-sync, and repeated full-repair matrix. Its final report recorded active playback without load failures, no sync error, and a successful repeated full repair after an earlier partial repair awaited deletion confirmation. |
| 2026-08-10 | Windows build attempt | The VM cannot resolve GitHub, so its generated MPV archive was zero bytes. A Linux-downloaded archive was copied to the isolated build path and its expected MD5 verified. The next failure is Rust toolchain error 448 (`untrusted mount point`) while Cargokit invokes `rustc`; it persists after moving the disposable checkout from Documents to a fresh `C:` path. |
| 2026-08-10 | Windows toolchain refresh | The VM desktop is active, GitHub DNS is restored, and Rust was updated to 1.97.1. The former Rust error-448 no longer occurs. A separate official Flutter 3.44.6 SDK was installed to match Linux without changing the existing local SDK. A clean isolated profile build completed with zero native warnings/errors. |
| 2026-08-10 | Windows diagnostics startup repair | The server had written its handshake before awaiting Unix `chmod`; Windows then bound the port but never began serving requests. Skipping the POSIX permission command on Windows restores the authenticated health response. A waking keyboard event also restored the VM framebuffer from black to the visible desktop. |
| 2026-08-11 | Broad-sync control coalescing | Windows validation found that diagnostics broad actions could call the raw engine while the app's startup controller was already synchronizing, producing competing progress snapshots. Broad API actions now join the production controller, matching user-triggered sync behavior. |
| 2026-08-11 | Windows live certification | An isolated profile connected to the real server through the authenticated app API. First login remained on Home while sync ran; its opened app-owned screenshot showed the sync banner. The full-repair candidate collected and atomically promoted 1,697 artists, 5,436 albums, and 54,109 songs while direct-stream playback had zero load failures. A simulated missing rolling-cache file was visible as one missing entry and production maintenance reduced cache entries/missing files to zero. After shutdown and rebuild, the same isolated profile restarted with the promoted catalog, restored rolling-cache entry and player state, and a deferred low-data compatibility audit with no error. The opened restart screenshot showed populated Home content. |
| 2026-08-11 | Final automated validation | The focused diagnostics-server suite passed 20 tests and the full Flutter suite passed 1,060 tests with 1 skip. Formatting and code generation passed. `tool/check.sh` reached analysis but stopped on 496 pre-existing informational diagnostics despite `--no-fatal-infos`; its inspected output contained no errors or warnings from this work. |

## Completion status

The runtime acceptance matrix is complete on Linux and Windows. The test VM was
shut down through the authenticated app API after the final restart check.

The repository's aggregate `tool/check.sh` gate is not clean because its
analysis step treats 496 existing informational diagnostics as a non-zero
failure. Formatting, code generation, focused tests, and the complete Flutter
suite passed; no error or warning was reported for this work. This is a
repository-wide quality-gate follow-up, not an unresolved sync or cache
behavioral failure.

## Evidence rules for completion

Completion requires focused tests, a clean Linux isolated-profile rerun, an
opened Home progress/failure screenshot, a clean restart, and an interactive
Windows isolated-profile run that exercises normal sync, Repair Library, cache
fault/maintenance, and restart. All runtime scenarios are recorded above.
Record each command/artifact location in `PROGRESS.md`.
