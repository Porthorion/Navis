import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/home_notice_card.dart';
import 'package:navis/src/common_widgets/notice_icon_disc.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';

Widget _card({
  String subtitle = '',
  Widget? leading,
  String? semanticLabel,
  VoidCallback? onOpen,
  VoidCallback? onDismiss,
  IconData? icon,
  NoticeAction? primaryAction,
  NoticeAction? secondaryAction,
  NavisColorStyleData? style,
}) {
  return MaterialApp(
    theme: style == null
        ? null
        : ThemeData(extensions: <ThemeExtension<dynamic>>[style]),
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
            icon: icon,
            primaryAction: primaryAction,
            secondaryAction: secondaryAction,
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
        NavisSpace.md,
        NavisSpace.xs,
        NavisSpace.md,
      ),
    );
    expect(
      (material.shape! as RoundedRectangleBorder).borderRadius,
      NavisRadius.lgAll,
    );
  });

  testWidgets('shows a tonal icon disc and bold title, body in two lines', (
    tester,
  ) async {
    await tester.pumpWidget(_card(subtitle: 'Body', icon: Icons.hub_outlined));

    final context = tester.element(find.byType(HomeNoticeCard));
    final scheme = Theme.of(context).colorScheme;
    final style = NavisColorStyleData.of(context);
    final disc = tester.widget<NoticeIconDisc>(find.byType(NoticeIconDisc));
    expect(disc.size, 40);
    expect(disc.iconSize, 20);
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byType(NoticeIconDisc),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.color, style.tonalControlFill(scheme));
    expect(
      tester.widget<Icon>(find.byIcon(Icons.hub_outlined)).color,
      style.onTonalControlFill(scheme),
    );
    final title = tester.widget<Text>(find.text('Title'));
    expect(title.style?.fontWeight, FontWeight.w600);
    final body = tester.widget<Text>(find.text('Body'));
    expect(body.maxLines, 2);
    expect(body.overflow, TextOverflow.ellipsis);
    expect(body.style?.color, scheme.onSurfaceVariant);
  });

  testWidgets('flat surfaces draw an outline instead of a fill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _card(
        subtitle: 'Body',
        style: const NavisColorStyleData(
          style: NavisColorStyle.neutral,
          dark: false,
          flat: true,
        ),
      ),
    );

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(HomeNoticeCard),
            matching: find.byType(Material),
          )
          .first,
    );
    final scheme = Theme.of(tester.element(find.byType(HomeNoticeCard)))
        .colorScheme;
    expect(material.color, Colors.transparent);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.side.color, scheme.outlineVariant);
    expect(shape.side.width, 1);
  });

  testWidgets('renders a tonal primary and a text secondary action', (
    tester,
  ) async {
    var primary = 0;
    var secondary = 0;
    var opened = 0;
    await tester.pumpWidget(
      _card(
        subtitle: 'Body',
        onOpen: () => opened++,
        primaryAction: NoticeAction(
          key: const ValueKey<String>('primary'),
          label: 'Install',
          onPressed: () => primary++,
        ),
        secondaryAction: NoticeAction(
          key: const ValueKey<String>('secondary'),
          label: 'Notes',
          onPressed: () => secondary++,
        ),
      ),
    );

    final context = tester.element(find.byType(HomeNoticeCard));
    final tonal = NavisColorStyleData.tonalStyleOf(context);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('primary')),
    );
    final scheme = Theme.of(context).colorScheme;
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      tonal.backgroundColor?.resolve(<WidgetState>{}),
    );
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      NavisColorStyleData.of(context).tonalControlFill(scheme),
    );
    expect(find.byKey(const ValueKey<String>('secondary')), findsOneWidget);
    // Actions sit under the text, end-aligned.
    final primaryRect = tester.getRect(
      find.byKey(const ValueKey<String>('primary')),
    );
    final titleRect = tester.getRect(find.text('Title'));
    final openRect = tester.getRect(find.byKey(const ValueKey<String>('open')));
    expect(primaryRect.top, greaterThan(titleRect.bottom));
    expect(openRect.right - primaryRect.right, NavisSpace.md);

    await tester.tap(find.byKey(const ValueKey<String>('primary')));
    await tester.tap(find.byKey(const ValueKey<String>('secondary')));
    expect((primary, secondary, opened), (1, 1, 0));
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
