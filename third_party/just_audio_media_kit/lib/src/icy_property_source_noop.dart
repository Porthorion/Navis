import 'package:media_kit/media_kit.dart';

import 'icy_metadata.dart';

IcyPropertySource createIcyPropertySource(Player player) => _NoIcyProperties();

class _NoIcyProperties implements IcyPropertySource {
  @override
  Future<String> read(String property) async => '';

  @override
  Future<void> observe(
      String property, Future<void> Function(String) listener) async {}

  @override
  Future<void> unobserve(String property) async {}
}
