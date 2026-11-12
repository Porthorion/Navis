import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/desktop/desktop_anchored_popover.dart';
import 'package:navis/src/common_widgets/navis_modal_sheet.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_backdrop.dart';
import 'package:navis/src/features/player/presentation/now_playing_menu_scope.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _seed = Color(0xFF3F7F6F);
const _tint = Color(0xFFD32F2F);
const _average = Color(0xFF204060);

class _Flag<T> extends Notifier<T> {
  _Flag(this.initial);
  final T initial;
  @override
  T build() => initial;
  // ignore: use_setters_to_change_properties
  void set(T value) => state = value;
}

NotifierProvider<_Flag<T>, T> _flag<T>(T initial) =>
    NotifierProvider<_Flag<T>, T>(() => _Flag<T>(initial));

final _expanded = _flag(true);
final _customize = _flag(false);
final _npBackground = _flag(NowPlayingBackground.tinted);
final _menuPick = _flag(NowPlayingBackground.tinted);

ThemeData _theme(String mode) => switch (mode) {
  'light' => buildLightTheme(_seed, style: NavisColorStyle.pastel),
  'dark' => buildDarkTheme(_seed, style: NavisColorStyle.pastel),
  _ => buildOledTheme(_seed, style: NavisColorStyle.pastel),
};

NowPlayingPublishedBackdrop _published({bool image = true}) =>
    NowPlayingPublishedBackdrop(
      owner: Object(),
      imageKey: image ? 'k' : null,
      image: image ? MemoryImage(Uint8List(0)) : null,
      coverAverage: image ? _average : null,
      useCoverAverage: image,
      tintColor: _tint,
    );

Color? _expected(
  ThemeData theme,
  NowPlayingBackground pick,
  NowPlayingPublishedBackdrop b,
) {
  final style = theme.extension<NavisColorStyleData>()!;
  return nowPlayingMenuFill(
    layer: resolveNowPlayingLayer(pick, b, flat: style.flatNowPlaying),
    backdrop: b,
    scheme: theme.colorScheme,
    style: style,
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required String mode,
  required Widget home,
  NowPlayingPublishedBackdrop? backdrop,
}) async {
  final theme = _theme(mode);
  final container = ProviderContainer(
    overrides: [
      playerSheetExpandedProvider.overrideWith((r) => r.watch(_expanded)),
      customizeQueueAndMenusProvider.overrideWith((r) => r.watch(_customize)),
      nowPlayingBackgroundProvider.overrideWith((r) => r.watch(_npBackground)),
      menuBackgroundPickProvider.overrideWith((r) => r.watch(_menuPick)),
    ],
  );
  addTearDown(container.dispose);
  if (backdrop != null) {
    container
        .read(nowPlayingPublishedBackdropProvider.notifier)
        .publish(backdrop);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        darkTheme: theme,
        themeMode: mode == 'light' ? ThemeMode.light : ThemeMode.dark,
        builder: (context, child) => NowPlayingMenuScope(child: child!),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Widget _sheetButton() => Builder(
  builder: (context) => TextButton(
    onPressed: () => showNavisModalSheet<void>(
      context: context,
      builder: (_) => const SizedBox(height: 100),
    ),
    child: const Text('open'),
  ),
);

Color? _sheetColor(WidgetTester tester) => tester
    .widget<Material>(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Material),
          )
          .first,
    )
    .color;

Iterable<Color?> _popupColors(WidgetTester tester, String label) => tester
    .widgetList<Material>(
      find.ancestor(of: find.text(label), matching: find.byType(Material)),
    )
    .map((m) => m.color);

Widget _menus() => Scaffold(
  body: Column(
    children: [
      PopupMenuButton<int>(
        itemBuilder: (_) => const [
          PopupMenuItem(value: 1, child: Text('popup item')),
        ],
      ),
      MenuAnchor(
        menuChildren: const [MenuItemButton(child: Text('anchor item'))],
        builder: (context, controller, _) =>
            TextButton(onPressed: controller.open, child: const Text('anchor')),
      ),
    ],
  ),
);

void main() {
  setUp(() {
    // Provider defaults are per container; nothing global to reset.
  });

  for (final mode in ['light', 'dark', 'oled']) {
    final theme = _theme(mode);
    final tinted = _expected(theme, NowPlayingBackground.tinted, _published());

    testWidgets('popup and MenuAnchor take the fill in $mode', (tester) async {
      await _pump(tester, mode: mode, home: _menus(), backdrop: _published());
      expect(tinted, isNotNull);
      await tester.tap(find.byType(PopupMenuButton<int>));
      await tester.pumpAndSettle();
      expect(_popupColors(tester, 'popup item'), contains(tinted));
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('anchor'));
      await tester.pumpAndSettle();
      expect(_popupColors(tester, 'anchor item'), contains(tinted));
    });

    testWidgets('sheet fill in $mode follows the expanded backdrop', (
      tester,
    ) async {
      await _pump(
        tester,
        mode: mode,
        home: _sheetButton(),
        backdrop: _published(),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(_sheetColor(tester), tinted);
    });
  }

  testWidgets('collapsed Now Playing leaves the theme fill', (tester) async {
    final container = await _pump(
      tester,
      mode: 'dark',
      home: _sheetButton(),
      backdrop: _published(),
    );
    container.read(_expanded.notifier).set(false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      _sheetColor(tester),
      _theme('dark').bottomSheetTheme.backgroundColor ??
          _theme('dark').colorScheme.surfaceContainerLow,
    );
  });

  testWidgets('a Plain menu pick keeps the theme over Now Playing', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      mode: 'dark',
      home: _menus(),
      backdrop: _published(),
    );
    container.read(_customize.notifier).set(true);
    container.read(_menuPick.notifier).set(NowPlayingBackground.plain);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    expect(
      _popupColors(tester, 'popup item'),
      isNot(
        contains(
          _expected(_theme('dark'), NowPlayingBackground.tinted, _published()),
        ),
      ),
    );
  });

  testWidgets('toggle off follows the Now Playing background, on the pick', (
    tester,
  ) async {
    final theme = _theme('dark');
    final b = _published();
    final container = await _pump(
      tester,
      mode: 'dark',
      home: _sheetButton(),
      backdrop: b,
    );
    Future<Color?> open() async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final color = _sheetColor(tester);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      return color;
    }

    container.read(_npBackground.notifier).set(NowPlayingBackground.artwork);
    await tester.pumpAndSettle();
    expect(await open(), _expected(theme, NowPlayingBackground.artwork, b));
    container.read(_customize.notifier).set(true);
    await tester.pumpAndSettle();
    // Pick is Tinted while Now Playing is Artwork.
    expect(await open(), _expected(theme, NowPlayingBackground.tinted, b));
  });

  testWidgets('a sheet keeps its fill across a track change and collapse', (
    tester,
  ) async {
    final theme = _theme('dark');
    final first = _published();
    final container = await _pump(
      tester,
      mode: 'dark',
      home: _sheetButton(),
      backdrop: first,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final opened = _sheetColor(tester);
    expect(opened, _expected(theme, NowPlayingBackground.tinted, first));
    container
        .read(nowPlayingPublishedBackdropProvider.notifier)
        .publish(
          NowPlayingPublishedBackdrop(
            owner: Object(),
            imageKey: null,
            image: null,
            coverAverage: null,
            useCoverAverage: false,
            tintColor: const Color(0xFF1565C0),
          ),
        );
    container.read(_expanded.notifier).set(false);
    await tester.pumpAndSettle();
    expect(_sheetColor(tester), opened);
  });

  testWidgets('the desktop popover card takes the fill', (tester) async {
    final theme = _theme('dark');
    final b = _published();
    await _pump(
      tester,
      mode: 'dark',
      backdrop: b,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDesktopAnchoredPopover<void>(
            anchorContext: context,
            builder: (_) => const SizedBox(height: 60, child: Text('body')),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final card = tester.widget<Material>(
      find.byKey(const ValueKey<String>('desktopAnchoredPopover')),
    );
    expect(card.color, _expected(theme, NowPlayingBackground.tinted, b));
  });

  testWidgets('dialogs stay theme-coloured over Now Playing', (tester) async {
    final theme = _theme('dark');
    await _pump(
      tester,
      mode: 'dark',
      backdrop: _published(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(title: Text('dialog')),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Material>(
            find
                .descendant(
                  of: find.byType(Dialog),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color,
      theme.dialogTheme.backgroundColor ??
          theme.colorScheme.surfaceContainerHigh,
    );
  });
}
