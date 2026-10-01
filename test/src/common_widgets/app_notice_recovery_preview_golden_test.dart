import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<AppNoticeController> pump(
    WidgetTester tester, {
    required String message,
  }) async {
    final controller = AppNoticeController()
      ..show(
        message: message,
        level: AppNoticeLevel.error,
        duration: const Duration(days: 1),
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        home: Scaffold(body: AppNoticeHost(controller: controller)),
      ),
    );
    return controller;
  }

  testWidgets('raw refresh failure before exposes implementation detail', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await pump(
      tester,
      message: 'StateError: Album refresh failed. Server returned 503.',
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/app_notice_recovery_before.png'),
    );
    controller.dispose();
  });

  testWidgets('safe refresh failure after gives a clear recovery step', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = await pump(
      tester,
      message:
          'Could not refresh this album. Check your connection and try again.',
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/app_notice_recovery_after.png'),
    );
    controller.dispose();
  });
}
