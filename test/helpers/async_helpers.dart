/// Lets queued microtasks and zero-delay timers settle, one event-loop turn at
/// a time.
Future<void> drainMicrotasks({int turns = 6}) async {
  for (var i = 0; i < turns; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}
