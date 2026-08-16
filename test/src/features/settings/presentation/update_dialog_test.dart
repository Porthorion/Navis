import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';

class _FailingUpdateService extends UpdateService {
  @override
  Future<String> downloadArtifact(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) {
    return Future<String>.error(
      DioException(
        requestOptions: RequestOptions(path: 'https://example.invalid/navis'),
        type: DioExceptionType.connectionError,
        error: const SocketException('Connection refused'),
      ),
    );
  }
}

void main() {
  testWidgets('update download failures keep technical details out of the UI', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showUpdateDialog(
                  context,
                  const UpdateInfo(
                    tagName: 'v1.2.6',
                    htmlUrl: 'https://example.invalid/navis',
                    delivery: UpdateDelivery.forgejoSelfUpdate,
                    downloadUrl: 'https://example.invalid/navis.apk',
                    assetFileName: 'navis-test.apk',
                  ),
                  updateService: _FailingUpdateService(),
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
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(find.text('Download failed. Please try again.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Download Manually'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsNothing);
  });
}
