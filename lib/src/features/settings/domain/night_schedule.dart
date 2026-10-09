import 'package:flutter/foundation.dart';

@immutable
class NightSchedule {
  const new({
    required this.enabled,
    required this.startMinutes,
    required this.endMinutes,
  });

  static const int defaultStartMinutes = 22 * 60;
  static const int defaultEndMinutes = 7 * 60;

  final bool enabled;
  final int startMinutes;
  final int endMinutes;

  bool isActiveAt(DateTime localTime) {
    if (!enabled || startMinutes == endMinutes) return false;
    final minute = localTime.hour * 60 + localTime.minute;
    if (startMinutes > endMinutes) {
      return minute >= startMinutes || minute < endMinutes;
    }
    return minute >= startMinutes && minute < endMinutes;
  }

  /// Returns the next configured boundary, strictly after [localTime].
  DateTime nextBoundaryAfter(DateTime localTime) {
    DateTime nextOccurrence(int minutes) {
      DateTime onDay(int day) => localTime.isUtc
          ? DateTime.utc(
              localTime.year,
              localTime.month,
              day,
              minutes ~/ 60,
              minutes % 60,
            )
          : DateTime(
              localTime.year,
              localTime.month,
              day,
              minutes ~/ 60,
              minutes % 60,
            );
      final today = onDay(localTime.day);
      return today.isAfter(localTime) ? today : onDay(localTime.day + 1);
    }

    final start = nextOccurrence(startMinutes);
    final end = nextOccurrence(endMinutes);
    return start.isBefore(end) ? start : end;
  }

  @override
  bool operator ==(Object other) =>
      other is NightSchedule &&
      other.enabled == enabled &&
      other.startMinutes == startMinutes &&
      other.endMinutes == endMinutes;

  @override
  int get hashCode => Object.hash(enabled, startMinutes, endMinutes);
}
