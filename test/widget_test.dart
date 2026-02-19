import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';

void main() {
  testWidgets('shows login screen while unauthenticated', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        ],
        child: const NavisApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text('Connect to your Subsonic or Navidrome server.'),
      findsOneWidget,
    );
  });
}
