import 'dart:io';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';

import '../../../../helpers/test_theme.dart';

class _FailingUpdateService extends UpdateService {
  new({this.integrityError = false});
  final bool integrityError;

  @override
  bool canApplyUpdate(UpdateInstallMode mode) => true;

  @override
  Future<String> downloadArtifact(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) {
    return Future<String>.error(
      integrityError
          ? const UpdateIntegrityException()
          : DioException(
              requestOptions: RequestOptions(
                path: 'https://example.invalid/navis',
              ),
              type: DioExceptionType.connectionError,
              error: const SocketException('Connection refused'),
            ),
    );
  }
}

const _packageInfo = UpdateInfo(
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  size: 123,
  tagName: 'v1.5.2',
  htmlUrl: 'https://example.invalid/navis',
  delivery: UpdateDelivery.desktopSelfUpdate,
  downloadUrl: 'https://example.invalid/navis.deb',
  assetFileName: 'navis-test.deb',
);
const _packageManagerMessage =
    "Navis was installed by your system's package manager. Update it from there, "
    'for example with your software updater or AUR helper.';

class _PackageUpdateService extends UpdateService {
  new({this.applyError, this.canApply = true});
  final Exception? applyError;
  final bool canApply;
  int downloads = 0;
  int applies = 0;

  @override
  bool canApplyUpdate(UpdateInstallMode mode) => canApply;

  @override
  Future<String> downloadArtifact(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    downloads++;
    return '/tmp/verified-package.deb';
  }

  @override
  Future<void> applyDesktopUpdate(
    String path,
    UpdateInstallMode mode, {
    String? expectedSha256,
  }) async {
    applies++;
    expect(path, '/tmp/verified-package.deb');
    expect(expectedSha256, _packageInfo.sha256);
    if (applyError != null) throw applyError!;
  }
}

Future<void> _openPackageDialog(
  WidgetTester tester,
  _PackageUpdateService service,
  UpdateInstallMode mode,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: testTheme(),
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => showUpdateDialog(
              context,
              _packageInfo,
              updateService: service,
              installModeDetector: () => mode,
            ),
            child: const Text('Open update'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open update'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Install'));
  await tester.pumpAndSettle();
}

void main() {
  for (final integrityError in [false, true]) {
    testWidgets(
      'integrity=$integrityError update download failures keep technical details out of the UI',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showUpdateDialog(
                      context,
                      const UpdateInfo(
                        sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                        size: 123,
                        tagName: 'v1.2.6',
                        releaseNotes:
                            '**Stability fixes** for artwork and storage.',
                        htmlUrl: 'https://example.invalid/navis',
                        delivery: UpdateDelivery.selfUpdate,
                        downloadUrl: 'https://example.invalid/navis.apk',
                        assetFileName: 'navis-test.apk',
                      ),
                      updateService: _FailingUpdateService(
                        integrityError: integrityError,
                      ),
                    ),
                    child: const Text('Open update'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open update'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Stability fixes'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Install'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            integrityError
                ? 'The update download was damaged. Try again.'
                : 'Download failed. Please try again.',
          ),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Download Manually'), findsOneWidget);
        expect(find.textContaining('Connection refused'), findsNothing);
      },
    );
  }

  testWidgets(
    'unknown package owner shows package manager actions without download',
    (tester) async {
      final service = _PackageUpdateService();
      await _openPackageDialog(
        tester,
        service,
        UpdateInstallMode.linuxPackageManaged,
      );
      expect(find.text(_packageManagerMessage), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
      expect(find.text('Download Manually'), findsOneWidget);
      expect(service.downloads, 0);
      expect(service.applies, 0);
    },
  );

  for (final mode in [UpdateInstallMode.linuxDeb, UpdateInstallMode.linuxRpm]) {
    testWidgets('$mode without elevation uses package-manager screen', (
      tester,
    ) async {
      final service = _PackageUpdateService(canApply: false);
      await _openPackageDialog(tester, service, mode);
      expect(find.text(_packageManagerMessage), findsOneWidget);
      expect(find.text('Download Manually'), findsOneWidget);
      expect(find.textContaining('cannot update itself'), findsNothing);
      expect(service.downloads, 0);
    });

    testWidgets(
      '$mode successful apply stays applying without no-write error',
      (tester) async {
        final service = _PackageUpdateService();
        await _openPackageDialog(tester, service, mode);
        await tester.tap(find.text('Restart & Update'));
        await tester.pump();
        expect(service.downloads, 1);
        expect(service.applies, 1);
        expect(find.text('Applying update…'), findsOneWidget);
        expect(find.textContaining('cannot update itself'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('cancelled elevation silently returns to confirm and can retry', (
    tester,
  ) async {
    final service = _PackageUpdateService(
      applyError: const UpdateCancelledException(),
    );
    await _openPackageDialog(tester, service, UpdateInstallMode.linuxDeb);
    await tester.tap(find.text('Restart & Update'));
    await tester.pumpAndSettle();
    expect(find.text('Install'), findsOneWidget);
    expect(
      find.text('Could not apply the update automatically.'),
      findsNothing,
    );
    expect(find.text(_packageManagerMessage), findsNothing);
    expect(find.text('Applying update…'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(service.applies, 1);
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text('Restart & Update'), findsOneWidget);
  });

  testWidgets('unavailable elevation uses the package-manager phase', (
    tester,
  ) async {
    final service = _PackageUpdateService(
      applyError: const UpdateElevationUnavailableException(),
    );
    await _openPackageDialog(tester, service, UpdateInstallMode.linuxDeb);
    await tester.tap(find.text('Restart & Update'));
    await tester.pumpAndSettle();
    expect(find.text(_packageManagerMessage), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
    expect(find.text('Download Manually'), findsOneWidget);
    expect(
      find.text('Could not apply the update automatically.'),
      findsNothing,
    );
  });

  testWidgets('root-side integrity failure shows the integrity message', (
    tester,
  ) async {
    final service = _PackageUpdateService(
      applyError: const UpdateIntegrityException(),
    );
    await _openPackageDialog(tester, service, UpdateInstallMode.linuxDeb);
    await tester.tap(find.text('Restart & Update'));
    await tester.pumpAndSettle();
    expect(
      find.text('The update download was damaged. Try again.'),
      findsOneWidget,
    );
    expect(
      find.text('Could not apply the update automatically.'),
      findsNothing,
    );
  });

  testWidgets('installer failure keeps the apply-error path', (tester) async {
    final service = _PackageUpdateService(
      applyError: ProcessException('pkexec', [], 'apt lock held', 100),
    );
    await _openPackageDialog(tester, service, UpdateInstallMode.linuxDeb);
    await tester.tap(find.text('Restart & Update'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not apply the update automatically.'),
      findsOneWidget,
    );
    expect(find.textContaining('apt lock held'), findsNothing);
    expect(find.text('Download Manually'), findsOneWidget);
  });
}
