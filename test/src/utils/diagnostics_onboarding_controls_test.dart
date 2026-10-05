import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';

/// The clone-only onboarding controls, against the real onboarding screen.
void main() {
  setUpAll(() async {
    final inter = FontLoader(navisFontFamily)
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    await inter.load();
  });

  late DiagnosticsPresentationController controller;
  final tokenField = find.byKey(
    const ValueKey<String>('onboarding-listenbrainz-token'),
  );
  final lastFmField = find.byKey(
    const ValueKey<String>('onboarding-lastfm-key'),
  );

  setUp(() {
    final root = Directory.systemTemp.createTempSync('navis_onboarding_ctl_');
    addTearDown(() => root.deleteSync(recursive: true));
    controller = DiagnosticsPresentationController(
      artifactRoot: root,
      frameWaiter: () => TestWidgetsFlutterBinding.instance.pump(
        const Duration(milliseconds: 50),
      ),
    );
  });

  Future<void> pumpOnboarding(
    WidgetTester tester, {
    bool bundledKey = true,
    Size size = const Size(390, 844),
  }) async {
    tester.view
      ..devicePixelRatio = 3
      ..physicalSize = size * 3;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      controller.wrap(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            customColorPresetsProvider.overrideWithValue(
              const AsyncData(<int>[]),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              CloneDiagnosticsExternalScrobbleCredentialStore(),
            ),
            lastFmBundledKeyProvider.overrideWithValue(bundledKey),
          ],
          child: const MaterialApp(
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: OnboardingScreen(reviewMode: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('moves to a step like Next and Back, within range', (
    tester,
  ) async {
    await pumpOnboarding(tester);
    expect(tokenField, findsNothing);

    expect(await controller.setOnboardingStep(3), 3);
    await tester.pumpAndSettle();
    expect(find.text('Step 4 of 4'), findsWidgets);
    expect(tokenField, findsOneWidget);

    expect(await controller.setOnboardingStep(1), 1);
    await tester.pumpAndSettle();
    expect(tokenField, findsNothing);
    // The screen's own Back button still works from the jumped step.
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 4'), findsWidgets);

    for (final step in [-1, 4]) {
      await expectLater(
        controller.setOnboardingStep(step),
        throwsA(
          isA<DiagnosticsPresentationOutOfRange>().having(
            (error) => error.count,
            'count',
            4,
          ),
        ),
      );
    }
    expect(find.text('Step 1 of 4'), findsWidgets);
  });

  testWidgets('focuses and unfocuses the token field through its node', (
    tester,
  ) async {
    await pumpOnboarding(tester);
    await controller.setOnboardingStep(3);
    await tester.pumpAndSettle();

    bool hasFocus() => tester
        .state<EditableTextState>(
          find.descendant(of: tokenField, matching: find.byType(EditableText)),
        )
        .widget
        .focusNode
        .hasFocus;
    expect(hasFocus(), isFalse);
    expect(await controller.focusOnboardingField('listenBrainzToken'), isTrue);
    await tester.pumpAndSettle();
    expect(hasFocus(), isTrue);
    expect(await controller.focusOnboardingField('none'), isFalse);
    await tester.pumpAndSettle();
    expect(hasFocus(), isFalse);

    await expectLater(
      controller.focusOnboardingField('email'),
      throwsFormatException,
    );
    // The Last.fm field is not shown when the build bundles a key.
    await expectLater(
      () => controller.focusOnboardingField('lastFmKey'),
      throwsA(isA<DiagnosticsPresentationUnavailable>()),
    );
  });

  testWidgets('focuses the Last.fm key field when it is shown', (tester) async {
    await pumpOnboarding(tester, bundledKey: false);
    await controller.setOnboardingStep(3);
    await tester.pumpAndSettle();
    expect(lastFmField, findsOneWidget);
    expect(await controller.focusOnboardingField('lastFmKey'), isTrue);
    await tester.pumpAndSettle();
    expect(
      tester
          .state<EditableTextState>(
            find.descendant(
              of: lastFmField,
              matching: find.byType(EditableText),
            ),
          )
          .widget
          .focusNode
          .hasFocus,
      isTrue,
    );
  });

  testWidgets('scrolls a lazily built field into the tree before focusing', (
    tester,
  ) async {
    await pumpOnboarding(tester, size: const Size(360, 400));
    await controller.setOnboardingStep(3);
    await tester.pumpAndSettle();
    expect(tokenField, findsNothing, reason: 'below the lazily built extent');
    expect(await controller.focusOnboardingField('listenBrainzToken'), isTrue);
    await tester.pumpAndSettle();
    expect(tokenField, findsOneWidget);
    expect(
      tester
          .state<EditableTextState>(
            find.descendant(
              of: tokenField,
              matching: find.byType(EditableText),
            ),
          )
          .widget
          .focusNode
          .hasFocus,
      isTrue,
    );
  });

  testWidgets('a field on another step is unavailable', (tester) async {
    await pumpOnboarding(tester);
    await expectLater(
      () => controller.focusOnboardingField('listenBrainzToken'),
      throwsA(isA<DiagnosticsPresentationUnavailable>()),
    );
  });

  testWidgets('without onboarding mounted every control is unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      controller.wrap(const MaterialApp(home: SizedBox.shrink())),
    );
    await expectLater(
      controller.setOnboardingStep(0),
      throwsA(isA<DiagnosticsPresentationUnavailable>()),
    );
    for (final field in ['listenBrainzToken', 'none']) {
      await expectLater(
        controller.focusOnboardingField(field),
        throwsA(isA<DiagnosticsPresentationUnavailable>()),
      );
    }
  });
}
