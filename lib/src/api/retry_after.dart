import 'dart:io';

/// Parses Retry-After delta seconds or an HTTP-date using the supplied clock.
DateTime? parseRetryAfter(String? value, {DateTime Function()? now}) {
  if (value == null) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null && seconds >= 0) {
    return (now ?? DateTime.now)().toUtc().add(Duration(seconds: seconds));
  }
  try {
    return HttpDate.parse(value.trim());
  } on HttpException {
    return null;
  } on FormatException {
    return null;
  }
}
