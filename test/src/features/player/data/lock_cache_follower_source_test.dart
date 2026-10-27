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
}
