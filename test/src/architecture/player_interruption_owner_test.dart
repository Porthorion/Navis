import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('handler disables automatic interruptions on every native deck', () {
    final source = File('lib/src/features/player/data/navis_audio_handler.dart')
        .readAsStringSync();
    final builder = source.substring(
      source.indexOf('  AudioPlayer _buildBaseAudioPlayer('),
      source.indexOf('  Future<void> _initialize()'),
    );
    expect(builder, contains('handleInterruptions: false'));
    expect(RegExp(r'\bAudioPlayer\(').allMatches(source), hasLength(1));
  });
}
