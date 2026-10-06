import 'package:media_kit/media_kit.dart';

import 'icy_metadata.dart';

IcyPropertySource createIcyPropertySource(Player player) =>
    NativeIcyPropertySource(player.platform is NativePlayer
        ? player.platform as NativePlayer
        : null);

class NativeIcyPropertySource implements IcyPropertySource {
  NativeIcyPropertySource(this.native);

  final NativePlayer? native;

  @override
  Future<String> read(String property) async =>
      await native?.getProperty(property, waitForInitialization: false) ?? '';

  @override
  Future<void> observe(
      String property, Future<void> Function(String) listener) async {
    await native?.observeProperty(property, listener);
  }

  @override
  Future<void> unobserve(String property) async {
    await native?.unobserveProperty(property);
  }
}
