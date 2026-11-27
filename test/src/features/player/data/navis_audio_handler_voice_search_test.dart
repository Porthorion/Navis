import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    show AudioServicePlatform;
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';

import 'navis_audio_handler_navigation_harness.dart';

/// `playFromVoiceSearch` (Siri, #530) and Android Auto's `playFromSearch`
/// share one local search; only the Android Auto entry broadcasts an error.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AudioServicePlatform.instance = NoOpAudioService());

  Future<NavisAudioHandler> make() async {
    final directory = await Directory.systemTemp.createTemp('navis-voice-');
    final (handler, _, database) = await createHandler(
      directory,
      6,
      readRadioPlaybackAllowed: (_) => true,
    );
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    return handler;
  }

  const songTwo = {
    AndroidAutoConstants.mediaFocusKey: AndroidAutoConstants.mediaFocusSong,
    AndroidAutoConstants.mediaTitleKey: 'Song 2',
  };
  const nothing = {
    AndroidAutoConstants.mediaFocusKey: AndroidAutoConstants.mediaFocusSong,
    AndroidAutoConstants.mediaTitleKey: 'Zzzxqj nomatch',
  };

  test('a match loads and returns true without an error state', () async {
    final handler = await make();
    expect(await handler.playFromVoiceSearch('Song 2', songTwo), isTrue);
    expect(handler.snapshot.queueSongIds, contains('song-2'));
    expect(
      handler.playbackState.value.processingState,
      isNot(AudioProcessingState.error),
    );
  });

  test('a miss returns false and leaves playback state alone', () async {
    final handler = await make();
    final before = handler.playbackState.value;
    expect(await handler.playFromVoiceSearch('Zzzxqj nomatch', nothing), false);
    expect(handler.playbackState.value, before);
  });

  test('playFromSearch still broadcasts the Android Auto error', () async {
    final handler = await make();
    await handler.playFromSearch('Zzzxqj nomatch', nothing);
    final state = handler.playbackState.value;
    expect(state.processingState, AudioProcessingState.error);
    expect(state.errorMessage, 'No matching music was found.');
  });

  test('playFromSearch on a match does not error', () async {
    final handler = await make();
    await handler.playFromSearch('Song 2', songTwo);
    expect(handler.snapshot.queueSongIds, contains('song-2'));
    expect(
      handler.playbackState.value.processingState,
      isNot(AudioProcessingState.error),
    );
  });
}
