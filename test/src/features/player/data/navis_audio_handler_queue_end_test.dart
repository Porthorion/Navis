import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    show AudioServicePlatform;
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart' as schema;
import 'package:navis/src/features/player/data/navis_audio_handler.dart';

import 'navis_audio_handler_navigation_harness.dart';

/// "When the queue ends" (#832): a NEW queue starts with Repeat All (Start
/// again from the top) or Repeat Off (Stop); restores keep the saved mode.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AudioServicePlatform.instance = NoOpAudioService());

  List<String> ids(int n) => [for (var i = 0; i < n; i++) 'song-$i'];

  Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)> make({
    bool startAgain = true,
    bool Function()? readStartAgain,
    Future<void> Function(NavisDatabase)? seed,
  }) async {
    final directory = await Directory.systemTemp.createTemp('navis-qend-');
    final (handler, player, database) = await createHandler(
      directory,
      6,
      queueEndStartAgain: startAgain,
      readQueueEndStartAgain: readStartAgain,
      readRadioPlaybackAllowed: (_) => true,
      seed: seed,
    );
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    return (handler, player, database);
  }

  Future<schema.RepeatMode?> savedMode(
    NavisAudioHandler handler,
    NavisDatabase database,
  ) async {
    await handler.debugFlushQueuePersistence();
    return (await database.playQueueDao.getQueueState())?.repeatMode;
  }

  test('the default starts a new queue on Repeat All everywhere', () async {
    final (handler, player, database) = await make();
    await handler.replaceQueue(ids(3), expandMatchFlows: false);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
    expect(player.appliedLoopMode, LoopMode.all);
    expect(await savedMode(handler, database), schema.RepeatMode.all);
  });

  test('Stop starts a new queue on Repeat Off even after Repeat All', () async {
    final (handler, player, database) = await make(startAgain: false);
    await handler.replaceQueue(ids(3), expandMatchFlows: false);
    await handler.setRepeatMode(AudioServiceRepeatMode.all);
    await handler.replaceQueue(ids(2), expandMatchFlows: false);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.none);
    expect(player.appliedLoopMode, LoopMode.off);
    expect(await savedMode(handler, database), schema.RepeatMode.off);
  });

  test('Repeat One on one queue does not carry to the next', () async {
    final (handler, player, _) = await make();
    await handler.replaceQueue(ids(3), expandMatchFlows: false);
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    expect(player.appliedLoopMode, LoopMode.one);
    await handler.replaceQueue(ids(4), expandMatchFlows: false);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
    expect(player.appliedLoopMode, LoopMode.all);
  });

  test('the user can still turn repeat off for the current queue', () async {
    final (handler, player, database) = await make();
    await handler.replaceQueue(ids(3), expandMatchFlows: false);
    await handler.setRepeatMode(AudioServiceRepeatMode.none);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.none);
    expect(player.appliedLoopMode, LoopMode.off);
    expect(await savedMode(handler, database), schema.RepeatMode.off);
  });

  test('clearing the queue keeps the mode', () async {
    final (handler, _, _) = await make();
    await handler.replaceQueue(ids(3), expandMatchFlows: false);
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    await handler.clearQueue();
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.one);
  });

  for (final (saved, expected) in [
    (schema.RepeatMode.off, AudioServiceRepeatMode.none),
    (schema.RepeatMode.one, AudioServiceRepeatMode.one),
  ]) {
    test('a restored queue keeps its saved ${saved.name} mode', () async {
      final (handler, _, _) = await make(
        seed: (database) => database.playQueueDao.saveQueue(
          currentIndex: 1,
          songIds: ids(3),
          repeatMode: saved,
        ),
      );
      await handler.debugWaitForStartupQueueRestore();
      expect(handler.snapshot.queueSongIds, ids(3));
      expect(handler.snapshot.repeatMode, expected);
    });
  }

  test(
    'an in-place mix start applies the setting and syncs the player',
    () async {
      final (handler, player, database) = await make();
      await handler.replaceQueue(ids(4), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.none);
      expect(player.appliedLoopMode, LoopMode.off);
      await handler.retainCurrentSongAsQueue('song-0');
      expect(handler.snapshot.queueSongIds, ['song-0']);
      expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
      expect(player.appliedLoopMode, LoopMode.all);
      expect(await savedMode(handler, database), schema.RepeatMode.all);
    },
  );

  test('radio stays on Repeat Off', () async {
    final (handler, player, _) = await make();
    await handler.replaceQueue(ids(3), expandMatchFlows: false);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
    await handler.playRadioStream(
      stationId: 'fixture',
      stationName: 'Fixture',
      streamUrl: 'https://radio.example/live',
    );
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.none);
    expect(player.appliedLoopMode, LoopMode.off);
    // The next queue gets the default again.
    await handler.replaceQueue(ids(2), expandMatchFlows: false);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
  });

  test('changing the setting mid-queue waits for the next queue', () async {
    var startAgain = true;
    final (handler, _, _) = await make(readStartAgain: () => startAgain);
    await handler.replaceQueue(ids(3), expandMatchFlows: false);
    startAgain = false;
    await handler.applyRuntimeSettings();
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
    await handler.replaceQueue(ids(3), expandMatchFlows: false);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.none);
  });
}
