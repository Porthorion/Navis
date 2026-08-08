import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('captures a protected deterministic PNG inside artifact root', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 240)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory.systemTemp.createTempSync(
      'navis_presentation_test_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    var waitedForFrame = false;
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () async {
        waitedForFrame = true;
      },
    );

    await tester.pumpWidget(
      controller.wrap(
        const MaterialApp(
          home: ColoredBox(color: Colors.blue),
        ),
      ),
    );

    expect(controller.status.screenshotReady, isTrue);
    expect(controller.appReady, isFalse);
    expect(controller.status.logicalWidth, 320);
    expect(controller.status.logicalHeight, 240);
    controller.markAppReady();
    expect(controller.appReady, isTrue);
    final capture = (await tester.runAsync<DiagnosticsScreenshot>(
      () => controller.capture(label: 'blue-screen'),
    ))!;
    final file = File(p.join(root.path, capture.artifact));
    final bytes = file.readAsBytesSync();

    expect(capture.artifact, startsWith('screenshots/'));
    expect(waitedForFrame, isTrue);
    expect(p.isWithin(root.path, file.path), isTrue);
    expect(capture.pixelRatio, 1);
    expect(capture.pixelWidth, 320);
    expect(capture.pixelHeight, 240);
    expect(capture.byteCount, bytes.length);
    expect(capture.sha256Digest, hasLength(64));
    expect(
      bytes.take(8),
      orderedEquals(<int>[137, 80, 78, 71, 13, 10, 26, 10]),
    );
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1ff, 0x180);
      expect(
        Directory(p.join(root.path, 'screenshots')).statSync().mode & 0x1ff,
        0x1c0,
      );
    }
  });

  testWidgets('rejects unsafe labels and unavailable render surfaces', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync(
      'navis_presentation_test_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () async {},
    );

    await expectLater(
      controller.capture(label: '../escape'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      controller.capture(label: 'unavailable'),
      throwsA(isA<DiagnosticsPresentationUnavailable>()),
    );
  });
}
