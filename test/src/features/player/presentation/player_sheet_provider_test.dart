import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';

void main() {
  test('player overlay controller preserves LIFO dismissal order', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final controller = container.read(playerOverlayStackProvider.notifier);

    expect(container.read(playerOverlayStackProvider), isEmpty);
    expect(container.read(playerSheetExpandedProvider), isFalse);
    expect(container.read(queueOverlayVisibleProvider), isFalse);

    controller.showQueue();

    expect(
      container.read(playerOverlayStackProvider),
      orderedEquals(<PlayerOverlayRoute>[
        PlayerOverlayRoute.nowPlaying,
        PlayerOverlayRoute.queue,
      ]),
    );
    expect(container.read(playerSheetExpandedProvider), isTrue);
    expect(container.read(queueOverlayVisibleProvider), isTrue);

    expect(controller.dismissTop(), isTrue);
    expect(
      container.read(playerOverlayStackProvider),
      orderedEquals(<PlayerOverlayRoute>[PlayerOverlayRoute.nowPlaying]),
    );
    expect(container.read(playerSheetExpandedProvider), isTrue);
    expect(container.read(queueOverlayVisibleProvider), isFalse);

    controller.showQueue();
    controller.collapse();

    expect(container.read(playerOverlayStackProvider), isEmpty);
    expect(container.read(playerSheetExpandedProvider), isFalse);
    expect(container.read(queueOverlayVisibleProvider), isFalse);
  });
}
