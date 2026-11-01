import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';

class _Controller extends LibrarySyncController {
  new(this.result);

  final LibrarySyncState result;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> requestTarget(
    LibrarySyncTarget target, {
    bool requireFresh = false,
  }) async => result;
}

LibrarySyncState _failed(String category) => LibrarySyncState(
  status: LibrarySyncStatus.failed,
  stage: LibrarySyncStage.completed,
  failureCategory: category,
  errorMessage: category == 'databaseBusy' ? '' : 'Metadata sync failed.',
);

void main() {
  for (final (category, throws) in [('databaseBusy', false), ('sync', true)]) {
    test(
      'a $category playlist refresh ${throws ? 'throws' : 'keeps the data'}',
      () async {
        final container = ProviderContainer(
          overrides: [
            librarySyncControllerProvider.overrideWith(
              () => _Controller(_failed(category)),
            ),
          ],
        );
        addTearDown(container.dispose);

        final refresh = container.read(playlistSyncProvider.future);

        if (throws) {
          await expectLater(refresh, throwsStateError);
        } else {
          await refresh;
        }
      },
    );
  }
}
