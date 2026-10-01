import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/presentation/deferred_queue_restore_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class _Handler extends Mock implements NavisPlaybackHandler {}

class _Value<T> extends Notifier<T?> {
  @override
  T? build() => null;

  void set(T? value) => state = value;
}

final _handlerValue =
    NotifierProvider<_Value<NavisPlaybackHandler>, NavisPlaybackHandler?>(
      _Value<NavisPlaybackHandler>.new,
    );
final _apiValue =
    NotifierProvider<_Value<SubsonicApiClient>, SubsonicApiClient?>(
      _Value<SubsonicApiClient>.new,
    );

SubsonicApiClient _client() => SubsonicApiClient(
  baseUrl: 'https://example.com',
  authConfig: const SubsonicAuthConfig(
    username: 'alice',
    password: 'secret',
    apiVersion: '1.16.1',
  ),
  enableLogging: false,
);

void main() {
  test(
    'retries a deferred restore once both the handler and a client exist',
    () async {
      final handler = _Handler();
      when(handler.retryDeferredQueueRestore).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          audioHandlerProvider.overrideWith((ref) => ref.watch(_handlerValue)),
          subsonicApiProvider.overrideWith((ref) => ref.watch(_apiValue)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(deferredQueueRestoreControllerProvider, (_, _) {});

      container.read(_handlerValue.notifier).set(handler);
      await container.pump();
      verifyNever(handler.retryDeferredQueueRestore);

      // Signing in, or a rebuilt client after a network change, retries.
      container.read(_apiValue.notifier).set(_client());
      await container.pump();
      verify(handler.retryDeferredQueueRestore).called(1);
      container.read(_apiValue.notifier).set(_client());
      await container.pump();
      verify(handler.retryDeferredQueueRestore).called(1);

      // Losing the session does not.
      container.read(_apiValue.notifier).set(null);
      await container.pump();
      verifyNever(handler.retryDeferredQueueRestore);
    },
  );

  test('retries when the handler becomes ready after the session', () async {
    final handler = _Handler();
    when(handler.retryDeferredQueueRestore).thenAnswer((_) async {});
    final container = ProviderContainer(
      overrides: [
        audioHandlerProvider.overrideWith((ref) => ref.watch(_handlerValue)),
        subsonicApiProvider.overrideWith((ref) => ref.watch(_apiValue)),
      ],
    );
    addTearDown(container.dispose);
    container.read(_apiValue.notifier).set(_client());
    await container.pump();
    container.listen(deferredQueueRestoreControllerProvider, (_, _) {});

    container.read(_handlerValue.notifier).set(handler);
    await container.pump();

    verify(handler.retryDeferredQueueRestore).called(1);
  });
}
