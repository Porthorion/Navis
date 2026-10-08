import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/night_schedule.dart';

void main() {
  group('NightSchedule', () {
    const normal = NightSchedule(
      enabled: true,
      startMinutes: 480,
      endMinutes: 1020,
    );
    const overnight = NightSchedule(
      enabled: true,
      startMinutes: 1320,
      endMinutes: 420,
    );

    test('normal window includes its start and excludes its end', () {
      expect(normal.isActiveAt(DateTime(2026, 10, 8, 7, 59, 59)), isFalse);
      expect(normal.isActiveAt(DateTime(2026, 10, 8, 8)), isTrue);
      expect(normal.isActiveAt(DateTime(2026, 10, 8, 12)), isTrue);
      expect(normal.isActiveAt(DateTime(2026, 10, 8, 16, 59, 59)), isTrue);
      expect(normal.isActiveAt(DateTime(2026, 10, 8, 17)), isFalse);
    });

    test('wrap-around window includes midnight and respects boundaries', () {
      expect(overnight.isActiveAt(DateTime(2026, 10, 8, 21, 59, 59)), isFalse);
      expect(overnight.isActiveAt(DateTime(2026, 10, 8, 22)), isTrue);
      expect(overnight.isActiveAt(DateTime(2026, 10, 9)), isTrue);
      expect(overnight.isActiveAt(DateTime(2026, 10, 9, 6, 59, 59)), isTrue);
      expect(overnight.isActiveAt(DateTime(2026, 10, 9, 7)), isFalse);
      expect(overnight.isActiveAt(DateTime(2026, 10, 9, 12)), isFalse);
    });

    test('equal boundaries never activate', () {
      const schedule = NightSchedule(
        enabled: true,
        startMinutes: 420,
        endMinutes: 420,
      );
      for (final hour in [0, 6, 7, 12, 23]) {
        expect(schedule.isActiveAt(DateTime(2026, 10, 8, hour)), isFalse);
      }
    });

    test('disabled schedule never activates', () {
      const schedule = NightSchedule(
        enabled: false,
        startMinutes: 1320,
        endMinutes: 420,
      );
      expect(schedule.isActiveAt(DateTime(2026, 10, 8, 22)), isFalse);
      expect(schedule.isActiveAt(DateTime(2026, 10, 9, 3)), isFalse);
    });

    test('next normal boundary is strictly after the supplied time', () {
      expect(
        normal.nextBoundaryAfter(DateTime(2026, 10, 8, 7, 59, 59)),
        DateTime(2026, 10, 8, 8),
      );
      expect(
        normal.nextBoundaryAfter(DateTime(2026, 10, 8, 8)),
        DateTime(2026, 10, 8, 17),
      );
      expect(
        normal.nextBoundaryAfter(DateTime(2026, 10, 8, 17)),
        DateTime(2026, 10, 9, 8),
      );
    });

    test('next overnight boundary uses the next local calendar day', () {
      expect(
        overnight.nextBoundaryAfter(DateTime(2026, 10, 8, 7)),
        DateTime(2026, 10, 8, 22),
      );
      expect(
        overnight.nextBoundaryAfter(DateTime(2026, 10, 8, 22)),
        DateTime(2026, 10, 9, 7),
      );
      expect(
        overnight.nextBoundaryAfter(DateTime(2026, 12, 31, 23, 59, 59)),
        DateTime(2027, 1, 1, 7),
      );
    });

    test('equal boundaries advance to the next configured occurrence', () {
      const schedule = NightSchedule(
        enabled: true,
        startMinutes: 420,
        endMinutes: 420,
      );
      expect(
        schedule.nextBoundaryAfter(DateTime(2026, 10, 8, 7)),
        DateTime(2026, 10, 9, 7),
      );
    });
  });
}
