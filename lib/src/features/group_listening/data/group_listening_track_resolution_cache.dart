/// In-memory cache for portable track resolution results.
class GroupListeningTrackResolutionCache {
  GroupListeningTrackResolutionCache();

  final Map<String, GroupListeningTrackResolutionCacheEntry> _entries =
      <String, GroupListeningTrackResolutionCacheEntry>{};

  GroupListeningTrackResolutionCacheEntry? read(String cacheKey) =>
      _entries[cacheKey];

  void write(String cacheKey, GroupListeningTrackResolutionCacheEntry entry) {
    _entries[cacheKey] = entry;
  }

  void clear() => _entries.clear();
}

enum GroupListeningTrackResolutionStatus { resolved, unavailable }

class GroupListeningTrackResolutionCacheEntry {
  const GroupListeningTrackResolutionCacheEntry({
    required this.status,
    this.songId,
    this.confidence,
    this.reason,
  });

  final GroupListeningTrackResolutionStatus status;
  final String? songId;
  final double? confidence;
  final String? reason;
}
