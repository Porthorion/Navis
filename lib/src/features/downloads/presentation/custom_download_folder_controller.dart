import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/features/downloads/presentation/manual_download_matching_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Whether a custom download folder operation is running.
class CustomDownloadFolderState {
  const new({this.busy = false});

  final bool busy;
}

/// Chooses, disables and rescans the custom download folder for the app.
///
/// A scan of a large folder takes a while, and the Downloads settings tab is
/// a page that is disposed as soon as another tab is shown. When the tab ran
/// these steps itself, leaving it during the scan stopped setup before the
/// folder was saved, or after the import but before Manual Matching was
/// filled in (issue #45). The operations live here instead and always run to
/// completion; they run one at a time, since `DownloadService` refuses
/// overlapping folder maintenance.
class CustomDownloadFolderController
    extends Notifier<CustomDownloadFolderState> {
  Future<void> _tail = Future<void>.value();
  int _queued = 0;

  @override
  CustomDownloadFolderState build() => const CustomDownloadFolderState();

  /// Uses the folder at [path]: adopts the files already in it, moves
  /// existing downloads into it and records the scan for Manual Matching.
  Future<PermanentDownloadImportResult> choose(String path) =>
      _serialized(() async {
        final service = ref.read(downloadServiceProvider);
        final preview = await service.previewCustomDownloadFolder(path);
        await service.configureCustomDownloadFolder(enabled: true, path: path);
        final result = await service.importCustomDownloadFolder(preview);
        ref
            .read(manualDownloadMatchingProvider.notifier)
            .recordScan(preview, automaticallyImported: result.importedCount);
        return result;
      });

  /// Stops using a custom folder and forgets its last scan.
  Future<void> disable() => _serialized(() async {
    await ref
        .read(downloadServiceProvider)
        .configureCustomDownloadFolder(enabled: false);
    ref.read(manualDownloadMatchingProvider.notifier).clear();
  });

  /// Imports files added to the current folder since the last scan, or
  /// returns `null` when no folder is set.
  Future<PermanentDownloadImportResult?> rescan() => _serialized(() async {
    final path = ref.read(customDownloadFolderPathProvider);
    if (path == null || path.trim().isEmpty) return null;
    final service = ref.read(downloadServiceProvider);
    final preview = await service.previewCustomDownloadFolder(path);
    final result = await service.importCustomDownloadFolder(preview);
    ref
        .read(manualDownloadMatchingProvider.notifier)
        .recordScan(preview, automaticallyImported: result.importedCount);
    return result;
  });

  Future<T> _serialized<T>(Future<T> Function() operation) {
    _queued++;
    state = const CustomDownloadFolderState(busy: true);
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result.whenComplete(() {
      if (--_queued == 0) state = const CustomDownloadFolderState();
    });
  }
}

final customDownloadFolderControllerProvider =
    NotifierProvider<CustomDownloadFolderController, CustomDownloadFolderState>(
      CustomDownloadFolderController.new,
    );
