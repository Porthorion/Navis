import 'package:audio_service/audio_service.dart';
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:rxdart/rxdart.dart';

/// Owns Android Auto browse invalidations for the parents Navis exposes.
///
/// `audio_service` forwards [ValueStream] emissions through
/// `MediaBrowserServiceCompat.notifyChildrenChanged` with non-null options.
/// This avoids the deprecated static bridge, which sends null options and is
/// rejected by current AndroidX media services.
class AndroidAutoBrowseNotifier {
  AndroidAutoBrowseNotifier()
    : _parents = <String, BehaviorSubject<Map<String, dynamic>>>{
        for (final parentMediaId in _notifiedParentMediaIds)
          parentMediaId: BehaviorSubject<Map<String, dynamic>>.seeded(
            const <String, dynamic>{},
          ),
      };

  static const List<String> _notifiedParentMediaIds = <String>[
    AutoMediaRoot.root,
    AutoMediaRoot.recent,
    AudioService.recentRootId,
  ];

  final Map<String, BehaviorSubject<Map<String, dynamic>>> _parents;

  /// Returns a non-null-options stream for a parent Navis actively refreshes.
  ValueStream<Map<String, dynamic>>? streamFor(String parentMediaId) =>
      _parents[parentMediaId];

  /// Invalidates all Android Auto parents whose contents can change.
  void notifyParentsChanged() {
    for (final stream in _parents.values) {
      if (!stream.isClosed) {
        stream.add(const <String, dynamic>{});
      }
    }
  }

  Future<void> dispose() => Future.wait<void>(
    _parents.values.map((stream) => stream.close()),
  );
}
