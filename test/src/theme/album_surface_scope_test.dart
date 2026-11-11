import 'package:file/file.dart' show File;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/desktop/desktop_anchored_popover.dart';
import 'package:navis/src/common_widgets/navis_modal_sheet.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/domain/sheet_style.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/album_sheet_surface.dart';
import 'package:navis/src/theme/album_surface_scope.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_theme.dart';

const _selected = 0xFF123456;
const _seedA = 0xFFAA2200;
const _seedB = 0xFF0033BB;

class _Source extends Notifier<String?> {
  @override
  String? build() => 'id:a';
  void set(String? value) => state = value;
}

final _sourceProvider = NotifierProvider<_Source, String?>(_Source.new);

/// Resolves `id:a` and `id:b` instantly; counts extractions.
class _Cache extends DynamicAccentColorCache {
  final resolved = <String>[];

  @override
  Future<int?> resolve({
    required String source,
    required SubsonicApiClient? api,
    required BaseCacheManager cacheManager,
  }) async {
    resolved.add(source);
    return switch (source) {
      'id:a' => _seedA,
      'id:b' => _seedB,
      _ => null,
    };
  }
}

class _UnusedFileSystem implements FileSystem {
  @override
  Future<File> createFile(String name) => throw UnimplementedError();
}

List<Override> _overrides(
  SheetStyle style,
  _Cache cache, {
  String? source = 'id:a',
}) => [
  appSettingsProvider.overrideWithValue(
    AsyncData(const AppSettingsModel.defaults().copyWith(sheetStyle: style)),
  ),
  colorSchemeSeedProvider.overrideWith((_) => _selected),
  subsonicApiProvider.overrideWithValue(null),
  coverArtCacheManagerProvider.overrideWithValue(
    CacheManager(
      Config(
        'navis-album-surface-test',
        repo: NonStoringObjectProvider(),
        fileSystem: _UnusedFileSystem(),
      ),
    ),
  ),
  dynamicAccentColorCacheProvider.overrideWithValue(cache),
  playingArtworkSourceProvider.overrideWith(
    (ref) => source == null ? null : ref.watch(_sourceProvider),
  ),
];

ThemeData _theme(String mode) => switch (mode) {
  'light' => buildLightTheme(const Color(_selected)),
  'dark' => buildDarkTheme(const Color(_selected)),
  _ => buildOledTheme(const Color(_selected)),
};

Future<void> _pump(
  WidgetTester tester, {
  required String mode,
  required SheetStyle style,
  required Widget home,
  _Cache? cache,
}) async {
  final theme = _theme(mode);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(style, cache ?? _Cache()),
      child: MaterialApp(
        theme: theme,
        darkTheme: theme,
        themeMode: mode == 'light' ? ThemeMode.light : ThemeMode.dark,
        builder: (context, child) => AlbumSurfaceScope(child: child!),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Color? _tintFor(ThemeData theme, int seed) => albumSheetSurface(
  seed: seed,
  scheme: theme.colorScheme,
  style: theme.extension<NavisColorStyleData>()!,
);

Color _materialColor(WidgetTester tester, Finder within) => tester
    .widget<Material>(
      find.descendant(of: within, matching: find.byType(Material)).first,
    )
    .color!;

void main() {
  for (final mode in ['light', 'dark', 'oled']) {
    final theme = _theme(mode);
    final tint = _tintFor(theme, _seedA)!;
    final plain =
        theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;

    for (final style in SheetStyle.values) {
      testWidgets('sheet fill in $mode / ${style.name}', (tester) async {
        await _pump(
          tester,
          mode: mode,
          style: style,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNavisModalSheet<void>(
                context: context,
                builder: (_) => const SizedBox(height: 100),
              ),
              child: const Text('open'),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(
          _materialColor(tester, find.byType(BottomSheet)),
          style == SheetStyle.albumColor ? tint : plain,
        );
      });
    }

    testWidgets('popup and MenuAnchor fill in $mode / album colour', (
      tester,
    ) async {
      await _pump(
        tester,
        mode: mode,
        style: SheetStyle.albumColor,
        home: Scaffold(
          body: Column(
            children: [
              PopupMenuButton<int>(
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 1, child: Text('popup item')),
                ],
              ),
              MenuAnchor(
                menuChildren: const [
                  MenuItemButton(child: Text('anchor item')),
                ],
                builder: (context, controller, _) => TextButton(
                  onPressed: controller.open,
                  child: const Text('anchor'),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<int>));
      await tester.pumpAndSettle();
      final popup = tester.widgetList<Material>(
        find.ancestor(
          of: find.text('popup item'),
          matching: find.byType(Material),
        ),
      );
      expect(popup.map((m) => m.color), contains(tint));
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();

      await tester.tap(find.text('anchor'));
      await tester.pumpAndSettle();
      final anchor = tester.widgetList<Material>(
        find.ancestor(
          of: find.text('anchor item'),
          matching: find.byType(Material),
        ),
      );
      expect(anchor.map((m) => m.color), contains(tint));
    });
  }

  testWidgets('popup menus keep the theme colour outside Album Color', (
    tester,
  ) async {
    await _pump(
      tester,
      mode: 'dark',
      style: SheetStyle.matchNowPlaying,
      home: Scaffold(
        body: PopupMenuButton<int>(
          itemBuilder: (_) => const [
            PopupMenuItem(value: 1, child: Text('popup item')),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    final colors = tester
        .widgetList<Material>(
          find.ancestor(
            of: find.text('popup item'),
            matching: find.byType(Material),
          ),
        )
        .map((m) => m.color);
    expect(colors, isNot(contains(_tintFor(_theme('dark'), _seedA))));
  });

  testWidgets('no seed (radio art refused, no cover) falls back to the theme', (
    tester,
  ) async {
    final theme = _theme('dark');
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(SheetStyle.albumColor, _Cache(), source: null),
        child: MaterialApp(
          theme: theme,
          builder: (context, child) => AlbumSurfaceScope(child: child!),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showNavisModalSheet<void>(
                context: context,
                builder: (_) => const SizedBox(height: 100),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      _materialColor(tester, find.byType(BottomSheet)),
      theme.colorScheme.surfaceContainerLow,
    );
  });

  testWidgets('dialogs stay theme-coloured in Album Color', (tester) async {
    final theme = _theme('dark');
    await _pump(
      tester,
      mode: 'dark',
      style: SheetStyle.albumColor,
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
      _materialColor(tester, find.byType(Dialog)),
      theme.dialogTheme.backgroundColor ??
          theme.colorScheme.surfaceContainerHigh,
    );
  });

  for (final style in [SheetStyle.albumColor, SheetStyle.theme]) {
    testWidgets('popover card equals its tail (${style.name})', (tester) async {
      final theme = _theme('dark');
      await _pump(
        tester,
        mode: 'dark',
        style: style,
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
      final tail = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<CustomPainter>()
          .firstWhere((p) => p.runtimeType.toString() == '_TailPainter');
      final expected = style == SheetStyle.albumColor
          ? _tintFor(theme, _seedA)!
          : theme.colorScheme.surfaceContainerHigh;
      expect(card.color, expected);
      // ignore: avoid_dynamic_calls
      expect((tail as dynamic).fill, expected);
    });
  }

  group('colour source', () {
    ProviderContainer container(SheetStyle style, _Cache cache) {
      final c = ProviderContainer(
        overrides: [
          ..._overrides(style, cache),
          dynamicAccentEnabledProvider.overrideWith((_) => false),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('resolves only for Album Color (accent off)', () async {
      for (final style in [SheetStyle.matchNowPlaying, SheetStyle.theme]) {
        final cache = _Cache();
        expect(
          await container(style, cache).read(albumSurfaceSeedProvider.future),
          isNull,
        );
        expect(cache.resolved, isEmpty);
      }
      final cache = _Cache();
      final c = container(SheetStyle.albumColor, cache);
      expect(await c.read(albumSurfaceSeedProvider.future), _seedA);
    });

    test('a song change leaves the app theme seed alone', () async {
      final cache = _Cache();
      final c = container(SheetStyle.albumColor, cache);
      final log = <int?>[];
      c.listen(effectiveColorSchemeSeedProvider, (_, n) => log.add(n));
      final album = c.listen(albumSurfaceSeedProvider, (_, _) {});
      addTearDown(album.close);
      await c.read(albumSurfaceSeedProvider.future);
      expect(c.read(effectiveColorSchemeSeedProvider), _selected);

      c.read(_sourceProvider.notifier).set('id:b');
      expect(await c.read(albumSurfaceSeedProvider.future), _seedB);
      expect(c.read(effectiveColorSchemeSeedProvider), _selected);
      expect(log, isEmpty);
    });

    testWidgets('a song change does not rebuild a page-level Theme probe', (
      tester,
    ) async {
      var probeBuilds = 0;
      final cache = _Cache();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._overrides(SheetStyle.albumColor, cache),
            dynamicAccentEnabledProvider.overrideWith((_) => false),
          ],
          child: MaterialApp(
            theme: _theme('dark'),
            builder: (context, child) => AlbumSurfaceScope(child: child!),
            home: Builder(
              builder: (context) {
                Theme.of(context);
                probeBuilds++;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = probeBuilds;
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(SizedBox).first),
      );
      scope.read(_sourceProvider.notifier).set('id:b');
      await tester.pumpAndSettle();
      expect(cache.resolved, containsAll(['id:a', 'id:b']));
      expect(probeBuilds, before);
    });
  });
}
