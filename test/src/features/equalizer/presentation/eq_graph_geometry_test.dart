import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_workspace.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_geometry.dart';
import 'package:navis/src/features/equalizer/presentation/eq_graph_painter.dart';

void main() {
  const geometry = EqGraphGeometry(Rect.fromLTWH(40, 20, 600, 300));
  test('logarithmic frequency and linear gain map back without rounding', () {
    for (final hz in [20.0, 31.25, 1234.56789, 20000.0]) {
      expect(geometry.frequency(geometry.x(hz)), closeTo(hz, 1e-8));
    }
    expect(geometry.x(math.sqrt(20 * 20000)), geometry.plot.center.dx);
    expect(geometry.gain(geometry.y(3.12735)), closeTo(3.12735, 1e-10));
    expect(geometry.frequency(-100), 20);
    expect(geometry.frequency(1000), 20000);
  });
  test(
    'vertical drag retains exact frequency and Q; fixed modes lock frequency',
    () {
      const filter = EqFilter(
        frequencyHz: 1234.56789,
        gainDb: 3.12735,
        q: 1.4142135623730951,
      );
      final start = geometry.handle(filter);
      for (final mode in EqMode.values) {
        final moved = geometry.drag(filter, start, const Offset(0, -30), mode);
        expect(moved.frequencyHz, filter.frequencyHz);
        expect(moved.q, filter.q);
        expect(moved.gainDb, closeTo(filter.gainDb + 4.8, 1e-10));
      }
      final fixed = geometry.drag(
        filter,
        start,
        const Offset(100, 0),
        EqMode.importedFixed,
      );
      expect(fixed, filter);
    },
  );
  test(
    'all gain-free filter types ignore vertical drag and remain disabled',
    () {
      for (final type in EqFilterType.values.where(
        (t) => !EqFilter(type: t, frequencyHz: 1000).usesGain,
      )) {
        final filter = EqFilter(
          type: type,
          frequencyHz: 1000,
          gainDb: 3.12735,
          enabled: false,
        );
        final moved = geometry.drag(
          filter,
          geometry.handle(filter),
          const Offset(60, -100),
          EqMode.advanced,
        );
        expect(moved.frequencyHz, closeTo(1000 * math.pow(1000, .1), 1e-8));
        expect(moved.gainDb, filter.gainDb);
        expect(moved.enabled, isFalse);
      }
    },
  );
  test(
    'overlapping touch targets return every candidate in authored order',
    () {
      const filters = [
        EqFilter(frequencyHz: 1000),
        EqFilter(frequencyHz: 1001),
        EqFilter(frequencyHz: 20),
      ];
      expect(geometry.hits(filters, geometry.handle(filters.first)), [0, 1]);
      expect(geometry.hits(filters, const Offset(10000, 10000)), isEmpty);
    },
  );
  test('Q uses a logarithmic scale across the full supported range', () {
    expect(EqGraphGeometry.qAt(0), .1);
    expect(EqGraphGeometry.qAt(1), 20);
    for (final q in [.1, .67, 1.4142135623730951, 20.0]) {
      expect(
        EqGraphGeometry.qAt(EqGraphGeometry.qPosition(q)),
        closeTo(q, 1e-12),
      );
    }
  });
  test('a plot inside a canvas leaves room for axis labels', () {
    final inside = EqGraphGeometry.inside(const Size(400, 300));
    expect(inside.plot.left, EqGraphGeometry.plotInsets.left);
    expect(inside.plot.top, EqGraphGeometry.plotInsets.top);
    expect(inside.plot.right, 400 - EqGraphGeometry.plotInsets.right);
    expect(inside.plot.bottom, 300 - EqGraphGeometry.plotInsets.bottom);
    expect(EqGraphGeometry.inside(Size.zero).plot.width, 1);
  });
  group('pointer targets', () {
    const stacked = [
      EqFilter(frequencyHz: 1000),
      EqFilter(frequencyHz: 1001),
      EqFilter(frequencyHz: 1080),
    ];
    final point = geometry.handle(stacked.first);
    test('an ambiguous stack asks for an explicit choice', () {
      expect(geometry.target(stacked.take(2).toList(), point), [0, 1]);
    });
    test('a drag keeps the band selected elsewhere, even when buried', () {
      expect(geometry.target(stacked, point, selected: 1), [1]);
      expect(geometry.target(stacked, point, selected: 2), [2]);
    });
    test('a clearly nearest handle wins without a chooser', () {
      const apart = [EqFilter(frequencyHz: 1000), EqFilter(frequencyHz: 1150)];
      expect(geometry.target(apart, geometry.handle(apart[1])), [1]);
    });
    test('a selection outside the touch radius never steals the touch', () {
      expect(
        geometry.target(stacked, point, selected: 5),
        geometry.target(stacked, point),
      );
      expect(geometry.target(stacked, const Offset(-500, -500)), isEmpty);
    });
  });
  test('readouts trim fractional zeros but never integer digits', () {
    expect(eqNumber(440, decimals: 0), '440');
    expect(eqNumber(10000, decimals: 0), '10000');
    expect(eqNumber(1234.56789), '1234.57');
    expect(eqNumber(1.4142135623730951, decimals: 3), '1.414');
    expect(eqNumber(250), '250');
    expect(eqNumber(0.5), '0.5');
    expect(eqShortFrequency(31.25), '31');
    expect(eqShortFrequency(440), '440');
    expect(eqShortFrequency(1234.56789), '1.2k');
    expect(eqShortFrequency(10000), '10k');
    expect(eqShortFrequency(16000), '16k');
    expect(eqSignedGain(3.12735), '+3.13');
    expect(eqSignedGain(0), '0');
    expect(eqSignedGain(0.001), '0');
    expect(eqSignedGain(-2.5), '-2.5');
    expect(eqNumber(-0.001), '0');
    expect(eqNumber(-0.0), '0');
  });
}
