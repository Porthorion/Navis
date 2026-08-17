import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/bootstrap/android_ui_bootstrap_gate.dart';

void main() {
  group('AndroidUiBootstrapGate', () {
    test(
      'does not start UI while the media-service engine is detached',
      () async {
        var starts = 0;
        final gate = AndroidUiBootstrapGate(
          startUi: () async {
            starts += 1;
          },
          onError: (_, _) {},
        );

        await gate.handleLifecycleState(AppLifecycleState.detached);

        expect(starts, 0);
        expect(gate.hasStartedUi, isFalse);
      },
    );

    test('starts UI once when an activity resumes', () async {
      var starts = 0;
      final gate = AndroidUiBootstrapGate(
        startUi: () async {
          starts += 1;
        },
        onError: (_, _) {},
      );

      await gate.handleLifecycleState(AppLifecycleState.resumed);
      await gate.handleLifecycleState(AppLifecycleState.paused);
      await gate.handleLifecycleState(AppLifecycleState.resumed);

      expect(starts, 1);
      expect(gate.hasStartedUi, isTrue);
    });

    test(
      'contains UI bootstrap failures and does not retry automatically',
      () async {
        var starts = 0;
        Object? capturedError;
        final gate = AndroidUiBootstrapGate(
          startUi: () async {
            starts += 1;
            throw StateError('no activity channel');
          },
          onError: (error, _) {
            capturedError = error;
          },
        );

        await gate.handleLifecycleState(AppLifecycleState.resumed);
        await gate.handleLifecycleState(AppLifecycleState.resumed);

        expect(starts, 1);
        expect(capturedError, isA<StateError>());
        expect(gate.hasStartedUi, isTrue);
      },
    );
  });
}
