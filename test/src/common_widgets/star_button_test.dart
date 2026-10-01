import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/star_button.dart';

class _StarHarness extends StatefulWidget {
  const new({required this.reduceMotion});

  final bool reduceMotion;

  @override
  State<_StarHarness> createState() => _StarHarnessState();
}

class _StarHarnessState extends State<_StarHarness> {
  bool _starred = false;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reduceMotion),
      child: MaterialApp(
        home: Scaffold(
          body: StarButton(
            isStarred: _starred,
            label: 'Like',
            starredLabel: 'Liked',
            onPressed: () => setState(() => _starred = !_starred),
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('uses the normal like feedback scale by default', (tester) async {
    await tester.pumpWidget(const _StarHarness(reduceMotion: false));

    expect(
      find.byKey(const ValueKey<String>('starButtonFeedbackScale')),
      findsOneWidget,
    );
    await tester.tap(find.text('Like'));
    await tester.pump();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
  });

  testWidgets('changes like state without scale feedback for reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(const _StarHarness(reduceMotion: true));

    expect(
      find.byKey(const ValueKey<String>('starButtonFeedbackScale')),
      findsNothing,
    );
    await tester.tap(find.text('Like'));
    await tester.pump();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('starButtonFeedbackScale')),
      findsNothing,
    );
  });
}
