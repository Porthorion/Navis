# Riverpod startup assertion: static root-cause pass (2026-11-07, Opus)

Unproven (stack truncated). Summary of the static analysis:

- Fires only in iOS debug diagnostics builds (`tool/lib/diagnostics.sh:33`: iOS debug, others profile; the check is debug-only, riverpod `element.dart:871`).
- "Unhandled Exception" form implies a synchronous `state =` inside a `ref.listen` callback (or before the first await of an unawaited async), reached when a widget's `ref.watch` flushes a stale provider mid-build.
- Router hypothesis rejected: `app_router.dart:124-141` listeners only set ValueNotifiers; the prewarm cannot help (`app.dart:385` watches `serverConfigStateProvider` directly).
- Fixture runs differ because they start on a fresh profile and go through `/initial-sync` (`forceFullSync`, `initial_server_sync_provider.dart:50`).
- Prime suspect (medium-low): `RequiredLibraryRebuildController` listeners call `start()` synchronously (`required_library_rebuild_provider.dart:98,105,110`); `_run` sets state before its first await (`:174,180,193`). Fix: `unawaited(Future<void>.microtask(start))` as at `:113`.
- Alternatives: `ServerReachabilityController._onServerConfigChanged` (`server_reachability_provider.dart:105,120`) and `LibrarySyncController._onServerConfigChanged` (`library_sync_provider.dart:882,903`), sync `state =` in `ref.listen(serverConfigStateProvider)`; the throw also skips `_checkReachability()`/`_scheduleStartupSync()` in debug.
- Next: first make `reportUncaughtErrorRedacted` (`credential_redaction.dart:88`) print the stack one line per call in debug (iOS truncates print at ~1 KB), rerun a fixture diagnostics run on the simulator (after I9's runtime proof frees it), then fix at the source with a failing widget test (`UncontrolledProviderScope` + stale `syncNetworkPolicyProvider`), then delete the prewarm (`lib/main.dart:150-158`, import `:24`).

## Proven at runtime (2026-11-07, after #337)

`tool/download_preferences_diagnostics.sh` on the iOS simulator (dev `027d8a91`) reproduced it with full stacks
(`~/.cache/claude-navis-logs/riverpod-repro/stack.txt`): `_NavisAppState.build` (`app.dart:93`, `ref.watch(appRouterProvider)`)
flushes stale dependencies, rebuilding `serverConfigStateProvider`, whose listeners write state synchronously:
`ServerReachabilityController._onServerConfigChanged` (`:105`) and `LibrarySyncController._onServerConfigChanged` (`:882`) —
the "alternatives" above, not the initial-sync suspect. Fix (Sonnet, branch `fix/riverpod-startup-listener-assertion`):
debug-only deferral of those listener bodies while `buildOwner.debugBuilding`, release unchanged; prewarm removed.
