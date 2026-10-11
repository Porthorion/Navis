import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/notice_icon_disc.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

void main() {
  testWidgets('renders an optional user-controlled action', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyState(
            title: 'Unavailable',
            action: OutlinedButton(
              key: ValueKey<String>('return-to-library'),
              onPressed: null,
              child: Text('Back to Library'),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('return-to-library')),
      findsOneWidget,
    );
  });

  testWidgets('shows a 64 px tonal disc with the title and quiet subtitle', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyState(
            title: 'Nothing here',
            subtitle: 'Add something to see it.',
            icon: Icons.search,
          ),
        ),
      ),
    );

    final context = tester.element(find.byType(EmptyState));
    final scheme = Theme.of(context).colorScheme;
    final style = NavisColorStyleData.of(context);
    final disc = tester.widget<NoticeIconDisc>(find.byType(NoticeIconDisc));
    expect(disc.size, 64);
    expect(disc.iconSize, 28);
    expect(tester.getSize(find.byType(NoticeIconDisc)), const Size(64, 64));
    final fill =
        (tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: find.byType(NoticeIconDisc),
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(fill, style.tonalControlFill(scheme));
    expect(
      tester.widget<Icon>(find.byIcon(Icons.search)).color,
      style.onTonalControlFill(scheme),
    );
    final title = tester.widget<Text>(find.text('Nothing here'));
    expect(
      title.style?.fontSize,
      Theme.of(context).textTheme.titleMedium?.fontSize,
    );
    final subtitle = tester.widget<Text>(find.text('Add something to see it.'));
    expect(subtitle.style?.color, scheme.onSurfaceVariant);
    expect(
      tester.getSize(find.text('Add something to see it.')).width,
      lessThanOrEqualTo(320),
    );
  });
}
