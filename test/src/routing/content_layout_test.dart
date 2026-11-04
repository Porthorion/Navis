import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/routing/content_layout.dart';

void main() {
  test('Auto reveals more covers while keeping their useful size', () {
    for (final sample in <(double, int, double)>[
      (328, 2, 160),
      (1040, 5, 198.4),
      (2000, 10, 189.2),
      (3400, 17, 188.7058823529412),
    ]) {
      final grid = ContentLayout.albums(sample.$1, GridArtworkSize.auto);
      expect(grid.columns, sample.$2);
      expect(grid.extent, closeTo(sample.$3, 0.001));
      expect(grid.occupiedWidth, lessThanOrEqualTo(sample.$1));
    }
  });

  test('all presets fit narrow panes and bound artwork on ultrawide panes', () {
    for (final size in GridArtworkSize.values) {
      for (final width in <double>[0, 80, 320, 599, 600, 960, 3440, 10000]) {
        for (final grid in [
          ContentLayout.albums(width, size),
          ContentLayout.artists(width, size),
        ]) {
          expect(grid.columns, greaterThanOrEqualTo(1));
          expect(grid.extent, inInclusiveRange(0, 268));
          expect(grid.occupiedWidth, lessThanOrEqualTo(width + 0.001));
        }
      }
    }
    expect(ContentLayout.albums(80, GridArtworkSize.large).extent, 80);
    expect(ContentLayout.albums(400, GridArtworkSize.large).extent, 196);
  });

  test('artwork cap leaves room without stretching a sparse collection', () {
    final grid = ContentLayout.albums(220, GridArtworkSize.small);
    expect(grid.extent, 152);
    expect(grid.occupiedWidth, 152);
    expect(ContentLayout.albums(2000, GridArtworkSize.small).columns, 12);
    expect(ContentLayout.albums(2000, GridArtworkSize.large).columns, 8);
  });

  test('track modes use the local pane and accessibility text scale', () {
    expect(
      ContentLayout.trackMode(719, TextScaler.noScaling),
      TrackRowMode.compact,
    );
    expect(
      ContentLayout.trackMode(720, TextScaler.noScaling),
      TrackRowMode.medium,
    );
    expect(
      ContentLayout.trackMode(960, TextScaler.noScaling),
      TrackRowMode.wide,
    );
    expect(
      ContentLayout.trackMode(1200, const TextScaler.linear(2)),
      TrackRowMode.compact,
    );
    expect(
      ContentLayout.trackMode(1920, const TextScaler.linear(2)),
      TrackRowMode.wide,
    );
  });

  test('previews include two pages, including a partially visible card', () {
    expect(ContentLayout.shelfLimit(328, 128), 6);
    expect(ContentLayout.shelfLimit(2000, 148), 26);
    expect(ContentLayout.shelfLimit(80, 128), 2);
  });

  test('genre cards are bounded and single column only when very narrow', () {
    expect(ContentLayout.genres(0).columns, 1);
    expect(ContentLayout.genres(599).columns, 2);
    expect(ContentLayout.genres(1352).extent, closeTo(260.8, 0.001));
    expect(ContentLayout.genres(1352).columns, 5);
  });

  test('radio cards use one narrow column and bounded wide columns', () {
    expect(ContentLayout.radio(599).columns, 1);
    expect(ContentLayout.radio(1040).columns, 3);
    expect(ContentLayout.radio(2000).columns, 6);
    expect(ContentLayout.radio(600).extent, 294);
    expect(ContentLayout.radio(1100).extent, 358.6666666666667);
  });

  test('genre cards always fill the pane between the page insets', () {
    for (var window = 600.0; window <= 1920; window += 20) {
      for (final rail in <double>[0, 28]) {
        final width = window - ContentLayout.padding(window) * 2 - rail;
        final grid = ContentLayout.genres(width);
        expect(grid.occupiedWidth, closeTo(width, 0.001), reason: '$window');
        expect(grid.extent, inInclusiveRange(220, 340), reason: '$window');
      }
    }
  });

  test('artist cells fill the pane on every size, with the letter rail', () {
    for (final size in GridArtworkSize.values) {
      for (var window = 600.0; window <= 1920; window += 20) {
        final width = window - ContentLayout.padding(window) * 2 - 28;
        final grid = ContentLayout.artists(width, size);
        expect(
          grid.occupiedWidth,
          closeTo(width, 0.001),
          reason: '$size at $window',
        );
      }
    }
  });

  test('phones get three artists per row at the default size', () {
    for (final phone in <double>[360, 375, 390, 412]) {
      final width = phone - ContentLayout.padding(phone) * 2 - 28;
      final grid = ContentLayout.artists(width, GridArtworkSize.auto);
      expect(grid.columns, 3, reason: '$phone');
      expect(grid.occupiedWidth, closeTo(width, 0.001), reason: '$phone');
    }
  });

  test('genre cards reach their widest just below three columns', () {
    final grid = ContentLayout.genres(683);
    expect(grid.columns, 2);
    expect(grid.extent, closeTo(335.5, 0.001));
  });
}
