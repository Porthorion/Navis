import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/features/downloads/presentation/manual_download_matching_provider.dart';

void main() {
  test('keeps only unresolved items available for manual matching', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const preview = PermanentDownloadImportPreview(
      rootPath: '/downloads',
      items: <PermanentDownloadImportItem>[
        PermanentDownloadImportItem(
          relativePath: 'clear.flac',
          fileSize: 1,
          format: 'flac',
          disposition: PermanentDownloadImportDisposition.recognized,
        ),
        PermanentDownloadImportItem(
          relativePath: 'ambiguous.flac',
          fileSize: 1,
          format: 'flac',
          disposition: PermanentDownloadImportDisposition.ambiguous,
        ),
        PermanentDownloadImportItem(
          relativePath: 'unknown.flac',
          fileSize: 1,
          format: 'flac',
          disposition: PermanentDownloadImportDisposition.unmatched,
        ),
      ],
    );

    container
        .read(manualDownloadMatchingProvider.notifier)
        .recordScan(preview, automaticallyImported: 1);

    expect(container.read(manualDownloadMatchingProvider).pendingCount, 2);
    expect(
      container.read(manualDownloadMatchingProvider).needsManualMatching,
      isTrue,
    );

    container.read(manualDownloadMatchingProvider.notifier).markImported(
      <String>['ambiguous.flac'],
    );

    expect(
      container.read(manualDownloadMatchingProvider).pendingPaths,
      <String>{'unknown.flac'},
    );
  });
}
