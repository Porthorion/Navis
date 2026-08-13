import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/app_notice.dart';

void main() {
  test(
    'raw ScaffoldMessenger calls are blocked outside app_notice.dart',
    () async {
      final offenders = <String>[];
      await for (final entity in Directory('lib/src').list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        if (entity.path.endsWith('lib/src/common_widgets/app_notice.dart')) {
          continue;
        }
        final content = await entity.readAsString();
        if (content.contains('ScaffoldMessenger.of(')) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Use AppNoticeMessenger/showAppNotice instead: $offenders',
      );
    },
  );

  testWidgets('shows a single top notice and replaces previous notice', (
    tester,
  ) async {
    final controller = AppNoticeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppNoticeScope(
            notifier: controller,
            child: Stack(
              children: <Widget>[
                const SizedBox.expand(),
                AppNoticeHost(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );

    controller.show(
      message: 'First',
      duration: const Duration(milliseconds: 60),
    );
    await tester.pump();
    expect(find.text('First'), findsOneWidget);

    controller.show(
      message: 'Second',
      duration: const Duration(milliseconds: 60),
    );
    await tester.pump();
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 80));
  });

  testWidgets('auto-dismiss hides notice after duration', (tester) async {
    final controller = AppNoticeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppNoticeScope(
            notifier: controller,
            child: Stack(
              children: <Widget>[
                const SizedBox.expand(),
                AppNoticeHost(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );

    controller.show(
      message: 'Auto dismiss',
      duration: const Duration(milliseconds: 120),
    );
    await tester.pump();
    expect(find.text('Auto dismiss'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Auto dismiss'), findsNothing);
  });

  testWidgets('notice is configured for swipe-up dismiss', (tester) async {
    final controller = AppNoticeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppNoticeScope(
            notifier: controller,
            child: Stack(
              children: <Widget>[
                const SizedBox.expand(),
                AppNoticeHost(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );

    controller.show(message: 'Dismiss me');
    await tester.pump();
    expect(find.text('Dismiss me'), findsOneWidget);

    final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
    expect(dismissible.direction, DismissDirection.up);
    controller.dismiss();
    await tester.pumpAndSettle();
  });

  testWidgets('notice is announced as a dismissible live region', (
    tester,
  ) async {
    final controller = AppNoticeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppNoticeScope(
            notifier: controller,
            child: Stack(
              children: <Widget>[
                const SizedBox.expand(),
                AppNoticeHost(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );

    controller.show(message: 'Download complete');
    await tester.pump();

    final announcement = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.liveRegion == true,
    );
    expect(announcement, findsOneWidget);
    final semantics = tester.widget<Semantics>(announcement);
    expect(semantics.properties.label, 'Download complete');
    expect(semantics.properties.onTap, isNotNull);

    controller.dismiss();
    await tester.pumpAndSettle();
  });

  testWidgets('notice switches immediately when reduced motion is requested', (
    tester,
  ) async {
    final controller = AppNoticeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Scaffold(
            body: AppNoticeScope(
              notifier: controller,
              child: Stack(
                children: <Widget>[
                  const SizedBox.expand(),
                  AppNoticeHost(controller: controller),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    controller.show(message: 'Saved');
    await tester.pump();

    expect(
      tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
      Duration.zero,
    );
    expect(find.text('Saved'), findsOneWidget);

    controller.dismiss();
    await tester.pumpAndSettle();
  });

  testWidgets('notice text is clamped to two lines', (tester) async {
    final controller = AppNoticeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppNoticeScope(
            notifier: controller,
            child: Stack(
              children: <Widget>[
                const SizedBox.expand(),
                AppNoticeHost(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );

    controller.show(
      message:
          'This is a long notice intended to verify text clamping and overflow behavior for the compact top notification pill.',
      duration: const Duration(milliseconds: 60),
    );
    await tester.pump();

    final text = tester.widget<Text>(find.textContaining('This is a long'));
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
    await tester.pump(const Duration(milliseconds: 80));
  });
}
