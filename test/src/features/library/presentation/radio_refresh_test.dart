import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/radio_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_theme.dart';

class _MockApi extends Mock implements SubsonicApiClient;

class _SyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  void emit(LibrarySyncStatus status) =>
      state = LibrarySyncState(status: status, stage: LibrarySyncStage.idle);
}

const _old = InternetRadioStation(
  id: 'r1',
  name: 'Old Name',
  streamUrl: 'https://radio.example/stream',
);
const _renamed = InternetRadioStation(
  id: 'r1',
  name: 'New Name',
  streamUrl: 'https://radio.example/stream',
);

ProviderContainer _container(List<Override> overrides) {
  final container = ProviderContainer(
    overrides: [
      localRadioStationsProvider.overrideWith(
        (ref) => Stream.value(const <InternetRadioStation>[]),
      ),
      serverUserIsAdminProvider.overrideWith((ref) async => false),
      currentRadioStationIdProvider.overrideWithValue(null),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: RadioTabContent()),
      ),
    ),
  );
}

void main() {
  test('server stations refetch when a sync run completes', () async {
    final api = _MockApi();
    var reads = 0;
    when(
      () => api.getInternetRadioStations(),
    ).thenAnswer((_) async => ++reads == 1 ? const [_old] : const [_renamed]);
    final container = ProviderContainer(
      overrides: [
        subsonicApiProvider.overrideWithValue(api),
        librarySyncControllerProvider.overrideWith(_SyncController.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(radioStationsProvider, (_, _) {});
    expect(await container.read(radioStationsProvider.future), [_old]);

    final sync = container.read(
      librarySyncControllerProvider.notifier,
    ) as _SyncController;
    sync.emit(LibrarySyncStatus.running);
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1, reason: 'a starting sync is not a completion');
    sync.emit(LibrarySyncStatus.failed);
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1, reason: 'a failed sync is not a success');

    sync.emit(LibrarySyncStatus.running);
    sync.emit(LibrarySyncStatus.succeeded);
    expect(await container.read(radioStationsProvider.future), [_renamed]);
    expect(reads, 2);
  });

  testWidgets('opening the Radio tab refetches server stations', (
    tester,
  ) async {
    var reads = 0;
    final container = _container([
      radioStationsProvider.overrideWith(
        (ref) async => ++reads == 1 ? const [_old] : const [_renamed],
      ),
    ]);
    await _pump(tester, container);
    await tester.pumpAndSettle();
    expect(reads, 1, reason: 'a cold open fetches once, not twice');
    expect(find.text('Old Name'), findsOneWidget);

    // Leave and reopen the tab: the provider already holds a value.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, container);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('New Name'), findsOneWidget);
  });

  testWidgets('previous stations stay visible while refetching and on error', (
    tester,
  ) async {
    var reads = 0;
    final second = Completer<List<InternetRadioStation>>();
    final container = _container([
      radioStationsProvider.overrideWith((ref) async {
        return ++reads == 1 ? const [_old] : await second.future;
      }),
    ]);
    await _pump(tester, container);
    await tester.pumpAndSettle();
    expect(find.text('Old Name'), findsOneWidget);

    container.invalidate(radioStationsProvider);
    await tester.pump();
    expect(container.read(radioStationsProvider).isLoading, isTrue);
    expect(find.text('Old Name'), findsOneWidget);
    expect(find.byType(ShimmerListPage), findsNothing);

    second.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(container.read(radioStationsProvider).hasError, isTrue);
    expect(find.text('Old Name'), findsOneWidget);
    expect(find.byType(ErrorState), findsNothing);
  });
}
