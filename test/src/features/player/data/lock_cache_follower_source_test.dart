import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/features/player/data/lock_cache_follower_source.dart';

// ignore: experimental_member_use, reason: a writer stand-in that records what reaches it.
class _Leader extends LockCachingAudioSource {
  new(File file, {this.ranges})
    : super(Uri.parse('https://fixture.invalid/song?id=a'), cacheFile: file);
  final requested = <(int?, int?)>[];
  var cancels = 0;
  bool? ranges;
  @override
  bool? get originSupportsRangeRequests => ranges;
  @override
  // ignore: experimental_member_use, reason: the proxy response contract.
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    requested.add((start, end));
    return StreamAudioResponse(
      sourceLength: 4,
      contentLength: 4,
      offset: start,
      stream: Stream.value([1, 2, 3, 4]),
      contentType: 'audio/mpeg',
    );
  }

  @override
  Future<void> cancelDownload() async => cancels++;
}

void main() {
  late Directory directory;
  late _Leader leader;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('navis-follower-');
    leader = _Leader(File('${directory.path}/a.mp3'));
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('requests go to the leader unchanged', () async {
    final follower = LockCacheFollowerSource(leader);
    final response = await follower.request(2, 4);
    expect(leader.requested, [(2, 4)]);
    expect(response.offset, 2);
    expect(await response.stream.expand((chunk) => chunk).toList(), [
      1,
      2,
      3,
      4,
    ]);
  });

  test('disposing an occurrence leaves the leader alone', () {
    LockCacheFollowerSource(leader).dispose();
    expect(leader.cancels, 0);
  });

  test('the range answer is the leader\'s, null until it knows', () {
    final follower = LockCacheFollowerSource(leader);
    expect(lockCacheOriginRanges(follower), isNull);
    leader.ranges = false;
    expect(lockCacheOriginRanges(follower), isFalse);
    leader.ranges = true;
    expect(lockCacheOriginRanges(follower), isTrue);
    expect(lockCacheOriginRanges(leader), isTrue);
  });

  test('a source that is not a lock-cache download has no range limit', () {
    expect(lockCacheOriginRanges(null), isTrue);
    expect(
      lockCacheOriginRanges(
        AudioSource.uri(Uri.parse('file:///a.mp3')) as IndexedAudioSource,
      ),
      isTrue,
    );
  });

  test(
    'a repeat requests a fresh download after the finished file is deleted',
    () async {
      final body = List<int>.generate(1024, (i) => i % 251);
      var downloads = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        downloads++;
        request.response
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..contentLength = body.length
          ..add(body);
        await request.response.close();
      });
      final file = File('${directory.path}/b.mp3');
      // ignore: experimental_member_use, reason: the real writer behind the follower.
      final writer = LockCachingAudioSource(
        Uri.parse('http://127.0.0.1:${server.port}/b'),
        cacheFile: file,
      );
      final follower = LockCacheFollowerSource(writer);
      final first = await writer.request();
      await first.stream.drain<void>();
      for (var i = 0; i < 200 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(downloads, 1);
      file.deleteSync();
      for (final source in [follower, writer]) {
        final response = await source.request().timeout(
          const Duration(seconds: 3),
        );
        expect(await response.stream.expand((c) => c).toList(), body);
        for (var i = 0; i < 200 && !file.existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        // The first request refills the file; a repeat then reads it.
        if (source == follower) expect(downloads, 2);
      }
      expect(downloads, 2);
    },
  );
}
