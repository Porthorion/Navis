import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/routing/desktop_commands.dart';

void main() {
  testWidgets('desktop command guard blocks when text input is focused', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(focusNode: focusNode),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final context = tester.element(find.byType(TextField));
    expect(desktopCommandBlockedByTextInput(context), isTrue);
  });

  testWidgets('desktop command guard allows non-text focused widgets', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: focusNode,
            child: const SizedBox(height: 20, width: 20),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final context = tester.element(find.byType(SizedBox));
    expect(desktopCommandBlockedByTextInput(context), isFalse);
  });
}
