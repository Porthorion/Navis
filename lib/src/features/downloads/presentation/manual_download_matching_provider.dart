import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';

class ManualDownloadMatchingState {
  const new({
    this.preview,
    this.automaticallyImported = 0,
    this.pendingPaths = const <String>{},
  });

  final PermanentDownloadImportPreview? preview;
  final int automaticallyImported;
  final Set<String> pendingPaths;

  int get pendingCount => pendingPaths.length;
  bool get needsManualMatching => preview != null && pendingPaths.isNotEmpty;
}

/// Holds only the current process's latest scan. Source files remain untouched
/// and a later rescan deliberately creates a fresh review state.
class ManualDownloadMatchingController
    extends Notifier<ManualDownloadMatchingState> {
  @override
  ManualDownloadMatchingState build() => const ManualDownloadMatchingState();

  void recordScan(
    PermanentDownloadImportPreview preview, {
    required int automaticallyImported,
  }) {
    final pendingPaths = preview.items
        .where(
          (item) =>
              item.disposition ==
                  PermanentDownloadImportDisposition.ambiguous ||
              item.disposition == PermanentDownloadImportDisposition.unmatched,
        )
        .map((item) => item.relativePath)
        .toSet();
    state = ManualDownloadMatchingState(
      preview: preview,
      automaticallyImported: automaticallyImported,
      pendingPaths: pendingPaths,
    );
  }

  void markImported(Iterable<String> relativePaths) {
    final completed = relativePaths.toSet();
    state = ManualDownloadMatchingState(
      preview: state.preview,
      automaticallyImported: state.automaticallyImported,
      pendingPaths: state.pendingPaths.difference(completed),
    );
  }

  void clear() => state = const ManualDownloadMatchingState();
}

final manualDownloadMatchingProvider =
    NotifierProvider<
      ManualDownloadMatchingController,
      ManualDownloadMatchingState
    >(ManualDownloadMatchingController.new);
