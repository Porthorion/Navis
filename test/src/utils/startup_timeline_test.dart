import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_provider.dart';
import 'package:navis/src/utils/app_logger.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/startup_timeline.dart';
import 'package:path/path.dart' as p;

class _TimelinePaths extends PathProviderPlatform {
  new(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Copy details puts sanitized startup events on the clipboard', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-startup-copy-',
    );
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TimelinePaths(directory.path);
    final container = ProviderContainer();
    addTearDown(() async {
      container.dispose();
      PathProviderPlatform.instance = previous;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      await directory.delete(recursive: true);
    });
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        });
    AppLogger.startup(
      StartupEvent.bootstrapFailure,
      failureType: StartupFailure.timeout,
    );
    await container.read(playbackRecoveryServiceProvider).copyDetails();
    expect(copied, contains('bootstrapFailure'));
    expect(copied, contains('"failureType":"timeout"'));
    expect(copied, isNot(contains('https://')));
  });

  test('private timeline retains bounded events across restart and merges worker evidence', () async {
    final directory = await Directory.systemTemp.createTemp('navis-startup-');
    addTearDown(() => directory.delete(recursive: true));
    final timeline = StartupTimeline(readDirectory: () async => directory);
    await Future.wait(
      List.generate(
        340,
        (i) => timeline.record(
          StartupEvent.bootstrapReady,
          attempt: i,
          elapsedMs: i,
        ),
      ),
    );
    final file = File(p.join(directory.path, 'startup-timeline.jsonl'));
    expect(await file.readAsLines(), hasLength(200));
    expect(await file.length(), lessThan(32768));
    await File(p.join(directory.path, 'startup-worker.jsonl')).writeAsString(
      '${jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'event': 'workerExit', 'outcome': 'success', 'title': 'PRIVATE', 'url': 'https://private.invalid', 'token': 'SECRET'})}\n{interrupted',
    );
    final reopened = StartupTimeline(readDirectory: () async => directory);
    final details = await reopened.copyDetails();
    expect(details.split('\n'), hasLength(201));
    expect(details, contains('workerExit'));
    expect(details, isNot(contains('PRIVATE')));
    expect(details, isNot(contains('SECRET')));
    expect(details, isNot(contains('private.invalid')));
    expect(utf8.encode(details).length, lessThan(65536));
  });

  test('unavailable storage does not poison the next write', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-startup-retry-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var unavailable = true;
    final timeline = StartupTimeline(
      readDirectory: () async {
        if (unavailable) throw const FileSystemException('unavailable');
        return directory;
      },
    );
    await expectLater(
      timeline.record(StartupEvent.processStart),
      throwsA(isA<FileSystemException>()),
    );
    unavailable = false;
    await timeline.record(StartupEvent.restart);
    expect(await timeline.copyDetails(), contains('restart'));
  });
}
