---
name: navis-riverpod-state
description: Navis Riverpod 3 provider design — state ownership, AsyncValue handling, provider lifetime and disposal, retries, stream subscriptions, account switching, rebuild scoping, and stale async UI updates. Use for any provider, notifier, invalidation, or state-lifecycle defect, including "UI shows stale data" or "provider rebuilds too much".
metadata:
  author: ChatGPT
  version: '1.1'
  project: Navis
  origin: custom-not-official
  prepared: '2026-09-22'
  adapted: trimmed duplicated policy boilerplate, anchored to repo paths
---

# Navis Riverpod State and Lifecycle

Task-scoped workflow for provider work. AGENTS.md and
`docs/development/agentic-engineering.md` are always loaded and govern scope and
validation; this skill adds the Riverpod-specific constraints. The Provider
Organization section of `docs/architecture.md` is the map of the real graph.

## Ground rules

The repo uses flutter_riverpod/riverpod ^3.4.2 with **manual providers** —
riverpod_generator/riverpod_annotation are not dependencies; do not add them
or migrate providers merely to follow an example. `lib/src/providers/
app_providers.dart` is the composition root: it may import features for DI,
but features must not import each other circularly. Never mutate provider
state during widget build (check.sh hard-fails on it) and never instantiate
`NavisDatabase` outside provider DI. Preserve the router's narrow
auth-refresh contract — do not rebuild it from broad or timestamped
configuration state.

Map the relevant provider graph before editing: family keys, scopes,
subscriptions, consumers, Notifiers, and external services. Record which
layer is authoritative for playback, account identity, persistent library
state, and view-only state; preserve that authority instead of building a
second queue or library cache in widget state.

## Check Riverpod 3 lifecycle behavior deliberately

Check the installed version's behavior for: automatic provider retry policy,
listener pausing when out of view, disposal/recomputation, and equality-based
notification filtering. A paused widget listener does not pause the audio
engine — trace the real service owner and subscription path. `keepAlive` is
not a universal fix for visibility pausing, stale requests, or equality
mistakes.

For async work, use cancellation and operation/source identity so a
completion cannot update a disposed owner or a newer account/query. Check
`ref.mounted` where supported; being mounted alone does not prove the result
still belongs to the current operation. Register cleanup at the correct
lifetime boundary and never dispose shared resources from a short-lived
provider that does not own them.

Treat provider recomputation, automatic retries, Dio retries, and
reconnection retries as **separate mechanisms**. Check whether combined
policies repeat side effects or multiply requests; do not put non-idempotent
operations in a retried computation without an explicit task-supported
design, and do not globally disable retries or retain every provider just to
hide one defect.

## Keep state transitions and rendering coherent

Use the existing immutable model conventions (Freezed where already in use —
note the repo's known Drift AOT caveat before modeling new persisted types as
Freezed). Check collection mutation, Freezed equality/copy semantics, and
notification filtering when an update is mysteriously not observed. Preserve
the intended data/loading/error representation, including stale-content-
while-refreshing where that is current behavior. Never expose old-account
data while a new session initializes.

Make search, sorting, pagination, cache repair, and playback updates
invalidate only their affected state. Do not make the library or poster grid
depend on a high-frequency playback-position stream; use `select` or split
dependencies where the installed APIs support it, and measure the affected
rebuild behavior instead of declaring an optimization from style alone.

## Regression coverage and verification

Build isolated `ProviderContainer`s with explicit overrides and dispose them
in `addTearDown` — the `dart-add-unit-test` skill has the repo's harness
patterns (`withTestDatabase`, fakes). Do not share containers across tests
or rely on production accounts and devices.

Candidate cases: disposal during a request; two searches completing out of
order; account/source switch with in-flight work; retry after transient
failure without duplicate writes; equal-state filtering; navigating away
while shared playback continues; a targeted update that does not rebuild
unrelated library views. When the defect shows in the UI, assert at the
consumer boundary (widget test — see `flutter-add-widget-test`), and cover
all `AsyncValue` states including error.

Run the focused test, `flutter analyze --no-fatal-infos`, and
`./tool/check.sh`. Runtime-affecting state work additionally needs the
runtime loop from `docs/development/development-workflow.md`.

## Primary references

- Riverpod 3 migration semantics: https://riverpod.dev/docs/3.0_migration
- Provider disposal: https://riverpod.dev/docs/concepts2/auto_dispose
- Automatic retry: https://riverpod.dev/docs/concepts2/retry
- Provider testing: https://riverpod.dev/docs/how_to/testing
