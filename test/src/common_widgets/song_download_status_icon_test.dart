import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';

import '../../helpers/test_theme.dart';

Future<void> _pump(WidgetTester tester, {VoidCallback? onDownload}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        songDownloadStateProvider('s').overrideWithValue(
          const SongDownloadState(status: SongDownloadStatus.cached),
        ),
      ],
      child: MaterialApp(
        theme: testTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SongDownloadStatusIcon(songId: 's', onDownload: onDownload),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('tapping the cached icon calls onDownload', (tester) async {
    var taps = 0;
    await _pump(tester, onDownload: () => taps++);
    await tester.tap(find.byIcon(Icons.schedule));
    expect(taps, 1);
  });

  testWidgets('cached icon is not interactive without onDownload', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
  });
}
