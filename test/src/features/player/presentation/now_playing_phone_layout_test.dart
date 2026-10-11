import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/presentation/now_playing_phone_layout.dart';

/// Phone sizes (dp) with the body the Now Playing screen is given: the view
/// height minus a 24 dp status bar, the 18 dp drag handle and the bottom inset
/// (24 dp gesture navigation or 48 dp three-button navigation).
const _phones = <(String, double, double)>[
  ('360x640', 360, 640),
  ('390x844', 390, 844),
  ('412x915', 412, 915),
  ('411x960', 411, 960),
  ('448x998', 448, 998),
];
const _insets = <(String, double)>[('gesture', 24), ('three-button', 48)];
const _scales = <double>[1, 1.3, 2];
const _eps = 0.01;

double _bodyHeight(double viewHeight, double inset) =>
    viewHeight - 24 - 18 - inset;

void _expectRange(double value, (double, double) range, String name) {
  expect(value, greaterThanOrEqualTo(range.$1 - _eps), reason: '$name min');
  expect(value, lessThanOrEqualTo(range.$2 + _eps), reason: '$name max');
}

void main() {
  for (final (phoneName, w, h) in _phones) {
    for (final (insetName, inset) in _insets) {
      for (final scale in _scales) {
        for (final radio in [false, true]) {
          final name =
              '$phoneName $insetName ${scale}x${radio ? ' radio' : ''}';
          test('$name stays within the model', () {
            final body = _bodyHeight(h, inset);
            final l = NowPlayingPhoneLayout.compute(
              width: w,
              height: body,
              textScaler: TextScaler.linear(scale),
              isRadio: radio,
            );

            // The pinned controls end at the bottom gap, the part above them
            // fills the rest exactly unless the upper part is scaled down.
            final total = l.upperHeight + l.lowerHeight;
            if (l.scalesUpper) {
              expect(total, greaterThan(body));
              expect(
                l.artSize,
                closeTo((0.45 * w).clamp(120, 200).toDouble(), _eps),
              );
            } else {
              expect(total, closeTo(body, _eps));
            }

            // The cover is square, inside its width limits and never wider
            // than the screen minus its margins.
            expect(l.artSize, lessThanOrEqualTo(w - 2 * l.artMargin + _eps));
            if (!l.scalesUpper) {
              expect(
                l.artSize,
                greaterThanOrEqualTo((0.45 * w).clamp(120, 200) - _eps),
              );
            }
            expect(l.artMargin, inInclusiveRange(16, 24));

            // Gaps follow the 4/8/12/16/20/24 rhythm: every gap stays in its
            // range, the two around the cover also carry the leftover height.
            expect(l.aboveArt, greaterThanOrEqualTo(4 - _eps));
            final aboveShare = radio ? 0.4 : 0.6;
            final titleShare = radio ? 0.3 : 0.4;
            expect(
              l.aboveArt,
              lessThanOrEqualTo(16 + aboveShare * l.slack + _eps),
            );
            expect(l.artToTitle, greaterThanOrEqualTo(12 - _eps));
            expect(
              l.artToTitle,
              lessThanOrEqualTo(28 + titleShare * l.slack + _eps),
            );
            _expectRange(l.bottom, (8, 16), 'bottom');
            if (radio) {
              expect(l.afterTitle, greaterThanOrEqualTo(16 - _eps));
              expect(
                l.afterTitle,
                lessThanOrEqualTo(32 + 0.3 * l.slack + _eps),
              );
              expect(l.seekBlock + l.actionBlock + l.infoBlock, 0);
            } else {
              _expectRange(
                l.afterTitle,
                l.showInfo ? (8, 16) : (8, 20),
                'afterTitle',
              );
              if (l.showInfo) {
                _expectRange(l.afterInfo, (8, 20), 'afterInfo');
              }
              _expectRange(l.afterSeek, (8, 24), 'afterSeek');
              _expectRange(l.afterTransport, (8, 16), 'afterTransport');
            }

            // Only short phones may drop the info pager.
            if (!l.showInfo && !radio) {
              expect(l.tier, NowPlayingPhoneTier.short);
            }
            // Tall phones step the title up; short phones fold the album.
            expect(l.titleSize, l.tier == NowPlayingPhoneTier.tall ? 24 : 20);
            expect(l.foldAlbum, l.tier == NowPlayingPhoneTier.short && !radio);
            // Large Play button only where the transport row has the width.
            expect(
              l.largeTransport,
              l.tier == NowPlayingPhoneTier.tall && w >= 380,
            );
          });
        }
      }
    }
  }

  test('classes follow the body height', () {
    expect(NowPlayingPhoneLayout.tierFor(574), NowPlayingPhoneTier.short);
    expect(NowPlayingPhoneLayout.tierFor(619.9), NowPlayingPhoneTier.short);
    expect(NowPlayingPhoneLayout.tierFor(620), NowPlayingPhoneTier.normal);
    expect(NowPlayingPhoneLayout.tierFor(778), NowPlayingPhoneTier.normal);
    expect(NowPlayingPhoneLayout.tierFor(830), NowPlayingPhoneTier.tall);
    expect(NowPlayingPhoneLayout.tierFor(894), NowPlayingPhoneTier.tall);
  });

  test('artwork margin eases from 24 to 16 dp on tall bodies', () {
    expect(NowPlayingPhoneLayout.artMarginFor(700), 24);
    expect(NowPlayingPhoneLayout.artMarginFor(820), closeTo(20, _eps));
    expect(NowPlayingPhoneLayout.artMarginFor(860), 16);
    expect(NowPlayingPhoneLayout.artMarginFor(950), 16);
  });

  test('a 360x640 phone keeps every control and a large cover', () {
    final l = NowPlayingPhoneLayout.compute(
      width: 360,
      height: _bodyHeight(640, 48),
      textScaler: TextScaler.noScaling,
    );
    expect(l.tier, NowPlayingPhoneTier.short);
    expect(l.scalesUpper, isFalse);
    expect(l.showInfo, isTrue);
    expect(l.actionBlock, 48);
    expect(l.artSize, greaterThan(0.62 * 360));
  });

  test('a 390x844 phone fills the width, then spreads the gaps', () {
    final l = NowPlayingPhoneLayout.compute(
      width: 390,
      height: _bodyHeight(844, 24),
      textScaler: TextScaler.noScaling,
    );
    expect(l.tier, NowPlayingPhoneTier.normal);
    expect(l.artSize, 390 - 48);
    expect(l.t, 1);
    expect(l.slack, greaterThan(0));
    // Leftover height splits 60/40 around the cover.
    expect(l.aboveArt - 16, closeTo(l.slack * 0.6, _eps));
    expect(l.artToTitle - 28, closeTo(l.slack * 0.4, _eps));
  });

  test('tall phones grow the cover to 16 dp margins', () {
    final l = NowPlayingPhoneLayout.compute(
      width: 411,
      height: _bodyHeight(960, 24),
      textScaler: TextScaler.noScaling,
    );
    expect(l.tier, NowPlayingPhoneTier.tall);
    expect(l.artSize, 411 - 32);
    expect(l.titleSize, 24);
    expect(l.artistSize, 17);
    expect(l.largeTransport, isTrue);
  });

  test('big text shrinks the cover before the upper part is scaled', () {
    final fits = NowPlayingPhoneLayout.compute(
      width: 360,
      height: 620,
      textScaler: const TextScaler.linear(2),
    );
    // Below the preferred 62% of the width, still above the floor.
    expect(fits.scalesUpper, isFalse);
    expect(fits.artSize, lessThan(0.62 * 360));
    expect(fits.artSize, greaterThanOrEqualTo(0.45 * 360));

    final scales = NowPlayingPhoneLayout.compute(
      width: 360,
      height: 440,
      textScaler: const TextScaler.linear(2),
    );
    expect(scales.scalesUpper, isTrue);
    expect(scales.artSize, closeTo(0.45 * 360, _eps));
    // The controls still fit; only the cover and title are scaled down.
    expect(scales.lowerHeight, lessThan(440));
  });

  test('the info pager is dropped only when a short phone cannot fit it', () {
    NowPlayingPhoneLayout at(double height, double scale) =>
        NowPlayingPhoneLayout.compute(
          width: 360,
          height: height,
          textScaler: TextScaler.linear(scale),
        );
    expect(at(574, 1).showInfo, isTrue);
    expect(at(520, 1.3).showInfo, isFalse);
    // Normal and tall phones always keep it.
    expect(at(700, 2).showInfo, isTrue);
  });
}
