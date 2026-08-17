import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_provider.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_sheet.dart';

class _FakeRecoveryService implements PlaybackRecoveryService {
  int retryCalls = 0;

  @override
  void retryPlayback() => retryCalls += 1;

  @override
  Future<void> resetLibraryCacheAndRetry() async {}

  @override
  Future<void> signOut({required bool wipeLocalData}) async {}
}

void main() {
  testWidgets(
    'offers playback recovery actions and retries without replaying',
    (
      tester,
    ) async {
      final recovery = _FakeRecoveryService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackRecoveryServiceProvider.overrideWithValue(recovery),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () => showPlaybackRecoverySheet(context),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Playback unavailable'), findsOneWidget);
      expect(find.text('Reset library cache and retry'), findsOneWidget);
      expect(find.text('Sign out (keep local data)'), findsOneWidget);

      await tester.tap(find.text('Retry playback'));
      await tester.pumpAndSettle();
      expect(recovery.retryCalls, 1);
      expect(find.text('Playback unavailable'), findsNothing);
    },
  );
}
