import 'package:just_audio/just_audio.dart';

/// A repeat occurrence of a song whose cache file has a registered
/// `LockCachingAudioSource` writer. It is its own player source (just_audio
/// derives the native id from the instance), but every request goes through
/// the [leader]: the completed cache file is read first, a running download is
/// joined, and the origin is fetched once. Disposing an occurrence never
/// touches the leader, which other occurrences and the next-song warm share.
// ignore: experimental_member_use, reason: StreamAudioSource is the proxy contract the lock-cache source implements.
class LockCacheFollowerSource extends StreamAudioSource {
  new(this.leader, {super.tag});

  // ignore: experimental_member_use, reason: the shared writer.
  final LockCachingAudioSource leader;

  @override
  // ignore: experimental_member_use, reason: the proxy response contract.
  Future<StreamAudioResponse> request([int? start, int? end]) =>
      leader.request(start, end);
}

/// Whether the origin behind [source] answers byte ranges: null until a
/// lock-cache download's response arrives, and true for any source that is not
/// a lock-cache download (it carries no such limit). A repeat occurrence
/// reports its leader's answer. Both seek planners read it from here.
bool? lockCacheOriginRanges(IndexedAudioSource? source) => switch (source) {
  // ignore: experimental_member_use, reason: as above.
  LockCachingAudioSource() => source.originSupportsRangeRequests,
  LockCacheFollowerSource(:final leader) => leader.originSupportsRangeRequests,
  _ => true,
};
