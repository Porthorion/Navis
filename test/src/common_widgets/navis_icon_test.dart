import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  testWidgets('uses the canonical mark with theme and accent colours', (
    tester,
  ) async {
    Future<SvgPicture> pumpIcon({
      required ThemeData theme,
      bool tintWithAccent = false,
      Color? tintColor,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: NavisIcon(
              tintWithAccent: tintWithAccent,
              tintColor: tintColor,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.widget<SvgPicture>(find.byType(SvgPicture));
    }

    final light = buildLightTheme(Colors.blue);
    final dark = buildDarkTheme(Colors.blue);
    var picture = await pumpIcon(theme: light);
    expect(
      (picture.bytesLoader as SvgAssetLoader).assetName,
      NavisIcon.assetPath,
    );
    expect(
      picture.colorFilter,
      ColorFilter.mode(light.colorScheme.onSurface, BlendMode.srcIn),
    );

    picture = await pumpIcon(theme: dark);
    expect(
      picture.colorFilter,
      ColorFilter.mode(dark.colorScheme.onSurface, BlendMode.srcIn),
    );

    picture = await pumpIcon(
      theme: buildLightTheme(Colors.blue),
      tintWithAccent: true,
      tintColor: const Color(0xFF005BBB),
    );
    expect(
      picture.colorFilter,
      const ColorFilter.mode(Color(0xFF005BBB), BlendMode.srcIn),
    );
  });

  testWidgets('renders the mark concentrically in every colour state', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(540, 180);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(Colors.blue),
        home: const Scaffold(
          backgroundColor: Color(0xFFF4F4F4),
          body: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _LogoRegistrationSample(background: Color(0xFFF4F4F4)),
              _LogoRegistrationSample(
                background: Color(0xFF111111),
                darkTheme: true,
              ),
              _LogoRegistrationSample(
                background: Color(0xFFF4F4F4),
                tintColor: Color(0xFF005BBB),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Row),
      matchesGoldenFile('goldens/navis_icon_centered_states.png'),
    );
  });
}

class _LogoRegistrationSample extends StatelessWidget {
  const new({required this.background, this.darkTheme = false, this.tintColor});

  final Color background;
  final bool darkTheme;
  final Color? tintColor;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: darkTheme
          ? buildDarkTheme(Colors.blue)
          : buildLightTheme(Colors.blue),
      child: ColoredBox(
        color: background,
        child: SizedBox.square(
          dimension: 160,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Container(
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: darkTheme
                        ? const Color(0xFF626262)
                        : const Color(0xFFB0B0B0),
                  ),
                ),
              ),
              NavisIcon(
                size: 128,
                tintWithAccent: tintColor != null,
                tintColor: tintColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
