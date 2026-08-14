import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget preview({required bool reduceMotion}) =>
      MaterialApp(home: _TrackSwapPreview(reduceMotion: reduceMotion));

  testWidgets('standard Now Playing metadata transitions between tracks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(preview(reduceMotion: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 98));

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/now_playing_motion_before.png'),
    );
  });

  testWidgets(
    'reduced motion presents the next Now Playing track immediately',
    (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 220));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(preview(reduceMotion: true));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/now_playing_motion_after.png'),
      );
    },
  );
}

class _TrackCard extends StatelessWidget {
  const _TrackCard({
    required super.key,
    required this.title,
    required this.artColor,
  });

  final String title;
  final Color artColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 330,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: artColor,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackSwapPreview extends StatefulWidget {
  const _TrackSwapPreview({required this.reduceMotion});

  final bool reduceMotion;

  @override
  State<_TrackSwapPreview> createState() => _TrackSwapPreviewState();
}

class _TrackSwapPreviewState extends State<_TrackSwapPreview> {
  var _showNext = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _showNext = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 280);
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: AnimatedSwitcher(
          duration: duration,
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: widget.reduceMotion
              ? (child, animation) => child
              : (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.985, end: 1).animate(
                      animation,
                    ),
                    child: child,
                  ),
                ),
          child: _TrackCard(
            key: ValueKey<String>(_showNext ? 'track-two' : 'track-one'),
            title: _showNext ? 'Next track' : 'Current track',
            artColor: _showNext
                ? const Color(0xFF6F62B8)
                : const Color(0xFFE16734),
          ),
        ),
      ),
    );
  }
}
