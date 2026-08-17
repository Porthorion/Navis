import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auto/data/android_auto_browse_notifier.dart';
import 'package:navis/src/features/auto/data/auto_media_id.dart';

void main() {
  group('AndroidAutoBrowseNotifier', () {
    late AndroidAutoBrowseNotifier notifier;

    setUp(() {
      notifier = AndroidAutoBrowseNotifier();
    });

    tearDown(() => notifier.dispose());

    test('seeds all refreshed parents with non-null options', () {
      for (final parentMediaId in <String>[
        AutoMediaRoot.root,
        AutoMediaRoot.recent,
        AudioService.recentRootId,
      ]) {
        final stream = notifier.streamFor(parentMediaId);

        expect(stream, isNotNull);
        expect(stream!.value, const <String, dynamic>{});
      }
    });

    test('emits refreshes for every subscribed browse parent', () async {
      final rootRefresh = notifier.streamFor(AutoMediaRoot.root)!.skip(1).first;
      final recentRefresh = notifier
          .streamFor(AutoMediaRoot.recent)!
          .skip(1)
          .first;
      final systemRecentRefresh = notifier
          .streamFor(AudioService.recentRootId)!
          .skip(1)
          .first;

      notifier.notifyParentsChanged();

      await expectLater(rootRefresh, completion(const <String, dynamic>{}));
      await expectLater(recentRefresh, completion(const <String, dynamic>{}));
      await expectLater(
        systemRecentRefresh,
        completion(const <String, dynamic>{}),
      );
    });

    test('does not create refresh streams for unrelated parents', () {
      expect(notifier.streamFor('root/albums'), isNull);
    });
  });
}
