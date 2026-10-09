import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  testWidgets('the Flat panel Play icon contrasts with its filled button', (
    tester,
  ) async {
    final base = buildDarkTheme(const Color(0xFFAA3355));
    const tint = CaptionTint(
      fill: Color(0xFF553344),
      text: Color(0xFFFFFFFF),
      subtext: Color(0xFFDDDDDD),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: base,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Material(
          child: Theme(
            data: flatPanelThemeForTest(base, tint),
            child: EntityActionBar(
              compact: true,
              onPlay: () {},
              onShuffle: () {},
            ),
          ),
        ),
      ),
    );
    final playIcon = tester.widget<RichText>(
      find.descendant(
        of: find.byType(IconButton).first,
        matching: find.byType(RichText),
      ),
    );
    // The filled button is drawn in the panel's text colour, so its glyph
    // must use the panel fill, never the text colour.
    expect(playIcon.text.style?.color, tint.fill);
  });
}
