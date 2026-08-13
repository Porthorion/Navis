import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/routing/app_router.dart';

void main() {
  Future<void> pumpTransition(
    WidgetTester tester, {
    required bool disableAnimations,
  }) async {
    final destination = const _DetailRoutePreview();
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              final page = buildSlideFadePage<void>(
                context: context,
                key: const ValueKey<String>('detail-preview'),
                child: destination,
              );
              return ColoredBox(
                color: const Color(0xFF101010),
                child: page.transitionsBuilder(
                  context,
                  const AlwaysStoppedAnimation<double>(0.35),
                  const AlwaysStoppedAnimation<double>(0),
                  destination,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  testWidgets('standard motion previews the route fade and travel', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTransition(tester, disableAnimations: false);

    await expectLater(
      find.byType(_DetailRoutePreview),
      matchesGoldenFile('goldens/detail_route_standard_motion.png'),
    );
  });

  testWidgets('reduced motion presents the route immediately', (tester) async {
    await tester.binding.setSurfaceSize(const Size(720, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpTransition(tester, disableAnimations: true);

    await expectLater(
      find.byType(_DetailRoutePreview),
      matchesGoldenFile('goldens/detail_route_reduced_motion.png'),
    );
  });
}

class _DetailRoutePreview extends StatelessWidget {
  const _DetailRoutePreview();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xFF282828),
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Row(
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFFE16734),
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
                child: SizedBox(width: 180, height: 180),
              ),
              SizedBox(width: 28),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Album detail',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Artwork, metadata, and actions are ready.',
                      style: TextStyle(color: Color(0xFFC7C7C7), fontSize: 16),
                    ),
                    SizedBox(height: 24),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(0xFFE16734),
                        borderRadius: BorderRadius.all(Radius.circular(20)),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        child: Text(
                          'Play album',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
