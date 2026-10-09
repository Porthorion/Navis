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
}
