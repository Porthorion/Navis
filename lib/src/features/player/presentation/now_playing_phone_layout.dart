import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Height class of the phone Now Playing body; picks type and control sizes.
enum NowPlayingPhoneTier { short, normal, tall }

/// Sizes and gaps for the portrait phone Now Playing body.
///
/// The controls get their real height first and stay at the bottom, where the
/// thumb is. The artwork is the flexible element: it shrinks on short screens
/// and grows up to the screen width minus its margins. Only once it has
/// stopped growing does leftover height become space, shared by every gap
/// through one factor (`t`, minimum to maximum) and then placed around the
/// artwork. This is the order used by Gramophone, Auxio, Metrolist and
/// Symfonium ("the cover has last priority for space").
///
/// [compute] is pure: block heights are modelled from the Material 3 line
/// heights the widgets use (`ceil`ed like the rendered text), so the layout is
/// unit-tested without pumping the screen. A widget test pins the model to the
/// rendered heights.
class NowPlayingPhoneLayout {
  const new({
    required this.tier,
    required this.artSize,
    required this.artMargin,
    required this.t,
    required this.slack,
    required this.scrollsUpper,
    required this.showInfo,
    required this.foldAlbum,
    required this.largeTransport,
    required this.titleSize,
    required this.artistSize,
    required this.albumSize,
    required this.titleGap,
    required this.albumGap,
    required this.titleBlock,
    required this.infoBlock,
    required this.seekBlock,
    required this.transportBlock,
    required this.actionBlock,
    required this.aboveArt,
    required this.artToTitle,
    required this.afterTitle,
    required this.afterInfo,
    required this.afterSeek,
    required this.afterTransport,
    required this.bottom,
  });

  /// Body heights (dp) that start the tall and end the short class.
  static const double shortBelow = 620;
  static const double tallFrom = 830;

  /// Horizontal inset of the text and controls.
  static const double contentMargin = NavisSpace.xl;

  /// Artwork side margin: [contentMargin] on normal phones, easing to
  /// [tallArtMargin] between [artMarginGrowFrom] and [artMarginGrowTo] so tall
  /// phones get a larger cover without a jump.
  static const double tallArtMargin = NavisSpace.md;
  static const double artMarginGrowFrom = 780;
  static const double artMarginGrowTo = 860;

  /// The artwork prefers at least this share of the width (and never more than
  /// [artMinCap]), may shrink to [artFloorShare] before the upper part scrolls.
  static const double artMinShare = 0.62;
  static const double artMinCap = 320;
  static const double artFloorShare = 0.45;
  static const double artFloorMin = 120;
  static const double artFloorCap = 200;

  /// Share of leftover height placed above the artwork; the rest goes between
  /// the artwork and the title. Above-art space lowers the composition toward
  /// the thumb.
  static const double slackAboveArtShare = 0.6;

  /// Radio has far less below the title, so its leftover height is shared
  /// more evenly: above the artwork, between artwork and title, and between
  /// title and transport.
  static const (double, double, double) radioSlackShares = (0.4, 0.3, 0.3);

  /// Gap ranges (dp, minimum to maximum) on the 4/8/12/16/20/24 rhythm.
  static const (double, double) aboveArtRange = (NavisSpace.xxs, NavisSpace.md);
  // 28 is between the xl and xxl steps: the cover to title gap carries the
  // composition, so it is the widest.
  static const (double, double) artToTitleRange = (NavisSpace.sm, 28);
  static const (double, double) afterTitleRange = (
    NavisSpace.xs,
    NavisSpace.md,
  );
  static const (double, double) afterInfoRange = (NavisSpace.xs, NavisSpace.lg);
  static const (double, double) afterSeekRange = (NavisSpace.xs, NavisSpace.xl);
  static const (double, double) afterTransportRange = (
    NavisSpace.xs,
    NavisSpace.md,
  );
  static const (double, double) bottomRange = (NavisSpace.xs, NavisSpace.md);
  // Radio has no info line, seek bar or action row: title to transport.
  static const (double, double) radioAfterTitleRange = (
    NavisSpace.md,
    NavisSpace.xxl,
  );

  /// Narrowest width that fits the larger Play button in the transport row.
  static const double largeTransportMinWidth = 380;

  final NowPlayingPhoneTier tier;

  /// Side of the square artwork, lyrics slot and placeholder.
  final double artSize;
  final double artMargin;

  /// Shared 0..1 factor interpolating every gap from minimum to maximum.
  final double t;

  /// Height left after the artwork and all gaps reached their maximum.
  final double slack;

  /// True when even the smallest artwork does not fit: the artwork and title
  /// scroll while the controls stay pinned.
  final bool scrollsUpper;
  final bool showInfo;
  final bool foldAlbum;
  final bool largeTransport;

  final double titleSize;
  final double artistSize;
  final double albumSize;
  final double titleGap;
  final double albumGap;

  final double titleBlock;
  final double infoBlock;
  final double seekBlock;
  final double transportBlock;
  final double actionBlock;

  /// Gaps in layout order, each following the block it is named after.
  final double aboveArt;
  final double artToTitle;
  final double afterTitle;
  final double afterInfo;
  final double afterSeek;
  final double afterTransport;
  final double bottom;

  /// Height of the pinned controls: everything from the title to the bottom.
  @visibleForTesting
  double get lowerHeight =>
      afterTitle +
      infoBlock +
      afterInfo +
      seekBlock +
      afterSeek +
      transportBlock +
      afterTransport +
      actionBlock +
      bottom;

  /// Natural height of the artwork part: gap, cover, gap and title.
  @visibleForTesting
  double get upperHeight => aboveArt + artSize + artToTitle + titleBlock;

  static NowPlayingPhoneTier tierFor(double height) {
    if (height < shortBelow) {
      return NowPlayingPhoneTier.short;
    }
    return height >= tallFrom
        ? NowPlayingPhoneTier.tall
        : NowPlayingPhoneTier.normal;
  }

  static double artMarginFor(double height) {
    final grow =
        ((height - artMarginGrowFrom) / (artMarginGrowTo - artMarginGrowFrom))
            .clamp(0.0, 1.0);
    return contentMargin + (tallArtMargin - contentMargin) * grow;
  }

  // Material 3 line-height ratios of the styles the widgets use.
  static const double _titleLine = 28 / 22; // titleLarge
  static const double _bodyLargeLine = 1.5;
  static const double _bodyMediumLine = 20 / 14;
  static const double _bodySmallLine = 16 / 12;
  static const double _labelSmallLine = 16 / 11;

  static double _line(TextScaler scaler, double fontSize, double ratio) =>
      (scaler.scale(fontSize) * ratio).ceilToDouble();

  /// Computes the layout for a body of [width] x [height] dp.
  // ignore: prefer_constructors_over_static_methods
  static NowPlayingPhoneLayout compute({
    required double width,
    required double height,
    required TextScaler textScaler,
    bool isRadio = false,
    bool isExternalSource = false,
  }) {
    final tier = tierFor(height);
    // Radio keeps the artist/album pair on two lines (its artist can be
    // several links), so its short class reuses the normal sizes.
    final foldAlbum = tier == NowPlayingPhoneTier.short && !isRadio;
    final (titleSize, artistSize, albumSize) = switch (tier) {
      NowPlayingPhoneTier.tall => (24.0, 17.0, 14.0),
      _ => (20.0, 15.0, 13.0),
    };
    final tall = tier == NowPlayingPhoneTier.tall;
    final titleGap = tall ? 4.0 : 2.0;
    final albumGap = tall ? 2.0 : 1.0;

    var titleBlock =
        _line(textScaler, titleSize, _titleLine) +
        titleGap +
        _line(textScaler, artistSize, _bodyLargeLine);
    if (!foldAlbum) {
      titleBlock += albumGap + _line(textScaler, albumSize, _bodyMediumLine);
    }
    if (isExternalSource) {
      titleBlock += _line(textScaler, 11, _labelSmallLine) + titleGap;
    }
    // Info line (Material insets 4 + 4) and its page dots (6 + 4).
    final infoBlock = 8 + _line(textScaler, 12, _bodySmallLine) + 10;
    // Slider track area plus the position and duration labels.
    final seekBlock = 28 + _line(textScaler, 12, _bodySmallLine);
    final largeTransport = tall && width >= largeTransportMinWidth;
    final transportBlock = largeTransport ? 62.0 : 54.0;
    const actionBlock = 48.0;

    final margin = artMarginFor(height);
    final artMax = math.max<double>(width - 2 * margin, 0);
    final artMin = math.min(artMinShare * width, artMinCap);
    final artFloor = math.min(
      math.max(artFloorShare * width, artFloorMin),
      artFloorCap,
    );

    // Gap ranges in layout order: aboveArt, artToTitle, afterTitle,
    // afterInfo, afterSeek, afterTransport, bottom. A block that is absent
    // takes its trailing gap with it.
    const none = (0.0, 0.0);
    List<(double, double)> rangesFor({required bool withInfo}) =>
        <(double, double)>[
          aboveArtRange,
          artToTitleRange,
          if (isRadio)
            radioAfterTitleRange
          else if (withInfo)
            afterTitleRange
          else
            afterInfoRange,
          if (!isRadio && withInfo) afterInfoRange else none,
          if (isRadio) none else afterSeekRange,
          if (isRadio) none else afterTransportRange,
          bottomRange,
        ];

    var showInfo = !isRadio;
    var gaps = rangesFor(withInfo: showInfo);
    double fixedHeight() =>
        titleBlock +
        (showInfo ? infoBlock : 0) +
        (isRadio ? 0 : seekBlock + actionBlock) +
        transportBlock;
    double minGaps() => gaps.fold(0, (sum, g) => sum + g.$1);
    var available = height - fixedHeight() - minGaps();
    if (tier == NowPlayingPhoneTier.short && showInfo && available < artMin) {
      // The info pager is the only optional block, and only on short phones.
      showInfo = false;
      gaps = rangesFor(withInfo: false);
      available = height - fixedHeight() - minGaps();
    }

    final gapSpan = gaps.fold<double>(0, (sum, g) => sum + g.$2 - g.$1);
    var art = artMax;
    var t = 0.0;
    var slack = 0.0;
    var scrolls = false;
    if (available >= artMax) {
      // 1) artwork at its maximum with minimum gaps, 2) raise t until the
      // gaps reach their maximum, 3) whatever is left is slack.
      final spare = available - artMax;
      t = gapSpan == 0 ? 1 : math.min<double>(1, spare / gapSpan);
      slack = math.max<double>(0, spare - gapSpan);
    } else if (available >= artFloor) {
      art = available;
    } else {
      art = math.min(artMin, artMax);
      scrolls = true;
    }

    final shares = isRadio
        ? radioSlackShares
        : (slackAboveArtShare, 1 - slackAboveArtShare, 0.0);
    double gap(int i) => gaps[i].$1 + (gaps[i].$2 - gaps[i].$1) * t;
    return NowPlayingPhoneLayout(
      tier: tier,
      artSize: art,
      artMargin: margin,
      t: t,
      slack: slack,
      scrollsUpper: scrolls,
      showInfo: showInfo,
      foldAlbum: foldAlbum,
      largeTransport: largeTransport,
      titleSize: titleSize,
      artistSize: artistSize,
      albumSize: albumSize,
      titleGap: titleGap,
      albumGap: albumGap,
      titleBlock: titleBlock,
      infoBlock: showInfo ? infoBlock : 0,
      seekBlock: isRadio ? 0 : seekBlock,
      transportBlock: transportBlock,
      actionBlock: isRadio ? 0 : actionBlock,
      aboveArt: gap(0) + slack * shares.$1,
      artToTitle: gap(1) + slack * shares.$2,
      afterTitle: gap(2) + slack * shares.$3,
      afterInfo: gap(3),
      afterSeek: gap(4),
      afterTransport: gap(5),
      bottom: gap(6),
    );
  }
}
