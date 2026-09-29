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

  test('radio cards use one narrow column and bounded wide columns', () {
    expect(ContentLayout.radio(599).columns, 1);
    expect(ContentLayout.radio(1040).columns, 3);
    expect(ContentLayout.radio(2000).columns, 6);
    expect(ContentLayout.radio(600).extent, 294);
    expect(ContentLayout.radio(1100).extent, 358.6666666666667);
  });
}
