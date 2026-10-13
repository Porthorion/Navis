---
name: dart-add-unit-test
description: Write and run unit tests for Navis Dart logic (providers, services, DAOs, API clients, utils) with flutter_test and mocktail. Use when creating new logic, fixing bugs, or asked to add coverage — even if the user just says "add a test" or "is this covered?".
---

# Writing Unit Tests in Navis

## File placement

Test files mirror `lib/src/` under `test/src/` (repo convention enforced by
review, not tooling): `lib/src/features/player/data/foo_service.dart` is tested
in `test/src/features/player/data/foo_service_test.dart`. Navis is a Flutter
package, so always import `package:flutter_test/flutter_test.dart` and run with
`flutter test` (never `dart test`).

Run the focused suite first:

```bash
flutter test test/src/features/player/data/foo_service_test.dart
```

## Structure

- Group related cases with `group()`; individual cases with `test()`.
- Prefer `expect()` matchers (`equals`, `throwsA`, `isA<T>()`) over manual
  conditionals; async tests use plain `async`/`await`.
- Share fixtures via `setUp()`/`tearDown()`; release streams and containers in
  `tearDown` so the suite stays hermetic.

## Navis test infrastructure

Use the sanctioned helpers in `test/helpers/` — `./tool/check.sh` hard-fails on
ad-hoc database construction, and AGENTS.md forbids instantiating
`NavisDatabase` outside provider DI:

- `withTestDatabase(...)` / `createTestDatabase()` — database access in tests
  plus Riverpod `Override`s to inject it through provider DI.
- `testTheme()` / `testNavisApp` — deterministic theming for widget harnesses.
- `test/helpers/library_sync_fakes.dart` — fakes for library sync collaborators.
- Guard database-dependent cases with the `sqliteAvailable` getter from
  `test/helpers/test_database.dart` when the native sqlite3 library may be
  absent (some CI runners).

## Mocking with mocktail

Navis uses `package:mocktail` (already a dev dependency). It needs no
build_runner codegen — do not introduce mockito or `@GenerateNiceMocks`:

```dart
class _MockSubsonicClient extends Mock implements SubsonicClient {}

void main() {
  group('FooService', () {
    late _MockSubsonicClient client;
    late FooService service;

    setUp(() {
      client = _MockSubsonicClient();
      service = FooService(client);
      registerFallbackValue(FooRequest.placeholder());
    });

    test('parses a successful response', () async {
      when(() => client.fetch(any()))
          .thenAnswer((_) async => const FooResult(ok: true));

      final result = await service.load();

      expect(result.ok, isTrue);
      verify(() => client.fetch(any())).called(1);
    });
  });
}
```

`registerFallbackValue` is required for `any()` used as a non-nullable
argument type.

## Providers under test

For Riverpod logic, build a `ProviderContainer` with explicit overrides per
test, and read through it — do not reach into provider internals:

```dart
final container = ProviderContainer(overrides: withTestDatabase());
addTearDown(container.dispose);
```

Widget-level provider testing belongs to widget tests (see
`flutter-add-widget-test`). Adding a regression test alongside each bug fix is
the repo norm per `docs/development/agentic-engineering.md`.
