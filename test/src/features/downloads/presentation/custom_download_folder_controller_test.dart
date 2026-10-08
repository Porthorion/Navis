import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/features/downloads/presentation/custom_download_folder_controller.dart';
import 'package:navis/src/features/downloads/presentation/manual_download_matching_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

const _preview = PermanentDownloadImportPreview(
  rootPath: '/music/navis',
  items: <PermanentDownloadImportItem>[
    PermanentDownloadImportItem(
      relativePath: 'known.flac',
      fileSize: 1,
      format: 'flac',
      disposition: PermanentDownloadImportDisposition.recognized,
    ),
    PermanentDownloadImportItem(
      relativePath: 'unknown.flac',
      fileSize: 1,
      format: 'flac',
      disposition: PermanentDownloadImportDisposition.unmatched,
    ),
  ],
);

class _FakeFolderService extends Fake implements DownloadService {
  final List<String> calls = <String>[];
  final List<Completer<void>> previewGates = <Completer<void>>[];

  @override
  Future<PermanentDownloadImportPreview> previewCustomDownloadFolder(
    String path,
  ) async {
    calls.add('preview $path');
    final gate = Completer<void>();
    previewGates.add(gate);
    await gate.future;
    return _preview;
  }

  @override
  Future<void> configureCustomDownloadFolder({
    required bool enabled,
    String? path,
  }) async {
    calls.add('configure $enabled $path');
  }

  @override
  Future<PermanentDownloadImportResult> importCustomDownloadFolder(
    PermanentDownloadImportPreview preview, {
    Map<String, String> manualSongIds = const <String, String>{},
    bool includeRecognized = true,
  }) async {
    calls.add('import ${preview.rootPath}');
    return const PermanentDownloadImportResult(
      importedCount: 1,
      skippedCount: 0,
    );
  }
}

ProviderContainer _container(_FakeFolderService service) {
  final container = ProviderContainer(
    overrides: [
      downloadServiceProvider.overrideWithValue(service),
      customDownloadFolderPathProvider.overrideWithValue('/music/navis'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _openNextGate(_FakeFolderService service, int count) async {
  while (service.previewGates.length < count) {
    await pumpEventQueue();
  }
  service.previewGates[count - 1].complete();
}

void main() {
  test('choosing a folder configures it and records the scan', () async {
    final service = _FakeFolderService();
    final container = _container(service);
    final controller = container.read(
      customDownloadFolderControllerProvider.notifier,
    );

    final chosen = controller.choose('/music/navis');
    await pumpEventQueue();
    expect(container.read(customDownloadFolderControllerProvider).busy, isTrue);

    await _openNextGate(service, 1);
    final result = await chosen;

    expect(result.importedCount, 1);
    expect(service.calls, <String>[
      'preview /music/navis',
      'configure true /music/navis',
      'import /music/navis',
    ]);
    // No screen is involved: the scan is recorded by the app-wide owner.
    final matching = container.read(manualDownloadMatchingProvider);
    expect(matching.needsManualMatching, isTrue);
    expect(matching.pendingCount, 1);
    expect(
      container.read(customDownloadFolderControllerProvider).busy,
      isFalse,
    );
  });

  test('folder operations run one at a time', () async {
    final service = _FakeFolderService();
    final container = _container(service);
    final controller = container.read(
      customDownloadFolderControllerProvider.notifier,
    );

    final chosen = controller.choose('/music/navis');
    final rescanned = controller.rescan();
    await pumpEventQueue();
    expect(service.calls, <String>['preview /music/navis']);

    await _openNextGate(service, 1);
    await chosen;
    expect(container.read(customDownloadFolderControllerProvider).busy, isTrue);
    await _openNextGate(service, 2);
    await rescanned;

    expect(service.calls, <String>[
      'preview /music/navis',
      'configure true /music/navis',
      'import /music/navis',
      'preview /music/navis',
      'import /music/navis',
    ]);
    expect(
      container.read(customDownloadFolderControllerProvider).busy,
      isFalse,
    );
  });

  test(
    'a failed operation releases the next one and reports busy off',
    () async {
      final service = _FakeFolderService();
      final container = _container(service);
      final controller = container.read(
        customDownloadFolderControllerProvider.notifier,
      );

      final chosen = controller.choose('/music/navis');
      await pumpEventQueue();
      final failure = Exception('unreadable');
      service.previewGates.single.completeError(failure);
      await expectLater(chosen, throwsA(same(failure)));
      expect(
        container.read(customDownloadFolderControllerProvider).busy,
        isFalse,
      );

      final again = controller.choose('/music/navis');
      await _openNextGate(service, 2);
      expect((await again).importedCount, 1);
    },
  );

  test('disabling the folder clears the last scan', () async {
    final service = _FakeFolderService();
    final container = _container(service);
    container
        .read(manualDownloadMatchingProvider.notifier)
        .recordScan(_preview, automaticallyImported: 1);

    await container
        .read(customDownloadFolderControllerProvider.notifier)
        .disable();

    expect(service.calls, <String>['configure false null']);
    expect(
      container.read(manualDownloadMatchingProvider).needsManualMatching,
      isFalse,
    );
  });
}
