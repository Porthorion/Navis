import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/home/presentation/home_screen.dart';

void main() {
  // One row is 56 px with a 4 px gap, so n rows are n * 60 - 4.
  test('shows only whole rows when the list overflows', () {
    // 250 px fits four whole rows (236) but not a fifth (296).
    expect(snapDesktopSongListHeight(250, 20), 236);
    expect(snapDesktopSongListHeight(296, 20), 296);
    expect(snapDesktopSongListHeight(295, 20), 236);
  });

  test('a list that fits keeps its natural height', () {
    expect(snapDesktopSongListHeight(400, 3), 3 * 60 - 4);
    expect(snapDesktopSongListHeight(400, 0), 0);
  });

  test('a panel shorter than one row is not collapsed', () {
    expect(snapDesktopSongListHeight(30, 5), 30);
  });
}
