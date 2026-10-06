import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/home_notice_card.dart';
import 'package:navis/src/theme/navis_tokens.dart';

Widget _card({
  String subtitle = '',
  Widget? leading,
  String? semanticLabel,
  VoidCallback? onOpen,
  VoidCallback? onDismiss,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Column(
        children: <Widget>[
          HomeNoticeCard(
            openKey: const ValueKey<String>('open'),
            dismissKey: const ValueKey<String>('dismiss'),
            title: 'Title',
            subtitle: subtitle,
            dismissTooltip: 'Dismiss it',
            leading: leading,
            semanticLabel: semanticLabel,
            onOpen: onOpen ?? () {},
            onDismiss: onDismiss ?? () {},
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('shows the title and subtitle on the raised surface', (
    tester,
  ) async {
    await tester.pumpWidget(_card(subtitle: 'Body'));

    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Body'), findsOneWidget);
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(HomeNoticeCard),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      material.color,
      Theme.of(tester.element(find.byType(HomeNoticeCard)))
          .colorScheme
          .surfaceContainerHigh,
    );
    final openRect = tester.getRect(find.byKey(const ValueKey<String>('open')));
    final titleRect = tester.getRect(find.text('Title'));
    expect(titleRect.left - openRect.left, NavisSpace.md);
    final padding = tester.widget<Padding>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('open')),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(
      padding.padding,
      const EdgeInsets.fromLTRB(
        NavisSpace.md,
        NavisSpace.sm,
        NavisSpace.xxs,
        NavisSpace.sm,
      ),
    );
    expect(material.borderRadius, NavisRadius.lgAll);
  });

  testWidgets('leaves out an empty subtitle and the leading widget', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_card());

    expect(find.text('Title'), findsOneWidget);
    expect(find.text(''), findsNothing);
    expect(
      find.descendant(
        of: find.byType(HomeNoticeCard),
        matching: find.byType(Text),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('leading')), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Row label')), findsNothing);
    semantics.dispose();
  });

  testWidgets('opens on tap and dismisses from its own close button', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var opened = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      _card(
        subtitle: 'Body',
        leading: const SizedBox(key: ValueKey<String>('leading'), width: 48),
        semanticLabel: 'Row label',
        onOpen: () => opened++,
        onDismiss: () => dismissed++,
      ),
    );

    expect(find.byKey(const ValueKey<String>('leading')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Row label')), findsOneWidget);
    final leadingRect = tester.getRect(
      find.byKey(const ValueKey<String>('leading')),
    );
    final openRect = tester.getRect(find.byKey(const ValueKey<String>('open')));
    final titleRect = tester.getRect(find.text('Title'));
    expect(leadingRect.left - openRect.left, NavisSpace.md);
    expect(titleRect.left - leadingRect.right, NavisSpace.sm);
    expect(leadingRect.center.dy, openRect.center.dy);
    expect(find.byTooltip('Dismiss it'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('open')));
    expect((opened, dismissed), (1, 0));
    await tester.tap(find.byKey(const ValueKey<String>('dismiss')));
    expect((opened, dismissed), (1, 1));
    semantics.dispose();
  });
}
