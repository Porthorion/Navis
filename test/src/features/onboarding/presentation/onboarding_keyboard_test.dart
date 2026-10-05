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

/// Typing the ListenBrainz token on a phone: the keyboard covers the bottom
/// 300 dp. The field must keep focus and the same state while the keyboard
/// opens, stay where a finger can reach it above the keyboard, and take text.
void main() {
  const keyboard = 300.0;
  const devicePixelRatio = 3.0;
  const statusBar = 24.0;

  setUpAll(() async {
    final inter = FontLoader(navisFontFamily)
      ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'));
    await inter.load();
  });

  Future<void> openIntegrationsStep(WidgetTester tester, Size size) async {
    tester.view
      ..devicePixelRatio = devicePixelRatio
      ..physicalSize = size * devicePixelRatio
      ..padding = const FakeViewPadding(top: statusBar * devicePixelRatio)
      ..viewPadding = const FakeViewPadding(top: statusBar * devicePixelRatio);
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio()
        ..resetPadding()
        ..resetViewPadding()
        ..resetViewInsets();
    });
    await tester.pumpWidget(
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
          // Release builds carry a Last.fm key, so the ListenBrainz token is
          // the only field on the step.
          lastFmBundledKeyProvider.overrideWithValue(true),
        ],
        child: const MaterialApp(
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OnboardingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var step = 0; step < 3; step++) {
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> typeTokenWithKeyboardOpen(WidgetTester tester, Size size) async {
    await openIntegrationsStep(tester, size);
    final field = find.byType(TextField);
    await tester.scrollUntilVisible(
      field,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.pump();

    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.widget.focusNode.hasFocus, isTrue);

    // The keyboard slides in over a few frames, then stays.
    for (final height in const [100.0, 200.0, keyboard]) {
      tester.view.viewInsets = FakeViewPadding(
        bottom: height * devicePixelRatio,
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final current = tester.state<EditableTextState>(find.byType(EditableText));
    expect(
      identical(current, editable),
      isTrue,
      reason: 'the field was rebuilt and lost its state',
    );
    expect(current.widget.focusNode.hasFocus, isTrue);
    expect(field.hitTestable(), findsOneWidget);
    // The line being typed into sits between the status bar and the
    // keyboard. (On a phone on its side the field's label may scroll under
    // the status bar to make room for the caret.)
    final line = tester.getRect(find.byType(EditableText));
    expect(line.top, greaterThanOrEqualTo(statusBar));
    expect(line.bottom, lessThanOrEqualTo(size.height - keyboard));

    tester.testTextInput.enterText('typed-token');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'typed-token');
    expect(
      tester
          .state<EditableTextState>(find.byType(EditableText))
          .widget
          .focusNode
          .hasFocus,
      isTrue,
    );
  }

  testWidgets('token field keeps focus and takes text at 360x780', (
    tester,
  ) async {
    await typeTokenWithKeyboardOpen(tester, const Size(360, 780));
  });

  testWidgets('token field keeps focus and takes text at 390x844', (
    tester,
  ) async {
    await typeTokenWithKeyboardOpen(tester, const Size(390, 844));
  });

  testWidgets('token field keeps focus and takes text at 412x915', (
    tester,
  ) async {
    await typeTokenWithKeyboardOpen(tester, const Size(412, 915));
  });

  // The step fits until the keyboard opens, so "scroll for more" appears
  // only then: the case that used to rebuild the field and close the
  // keyboard again.
  testWidgets('token field survives the step becoming scrollable', (
    tester,
  ) async {
    await typeTokenWithKeyboardOpen(tester, const Size(412, 1100));
  });

  testWidgets('token field keeps focus and takes text in landscape', (
    tester,
  ) async {
    await typeTokenWithKeyboardOpen(tester, const Size(844, 390));
  });
}
