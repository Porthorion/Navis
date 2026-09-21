import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Typed artwork failure categories (plan F5).
///
/// A missing or stale cover reference is a surface condition; network,
/// authentication, rate-limit, and decoding failures never prove that media
/// was deleted. Only validated catalog evidence advances availability.
enum CoverArtFailureCategory {
  /// The server answered that this cover-art reference does not exist.
  missingCoverReference,

  /// The server or an intermediary rejected the request (401/403).
  authRejection,

  /// Connection, response, or body read timed out.
  networkTimeout,

  /// HTTP success whose payload is not an image, or a cached error payload.
  invalidPayload,

  /// Bytes were fetched but the image codec could not decode them.
  decodeFailure,

  /// Other connection-level failures.
  transport,
}

/// Typed artwork fetch failure carrying its [CoverArtFailureCategory].
class CoverArtFetchException implements Exception {
  const CoverArtFetchException(
    this.category, {
    this.statusCode,
    this.cause,
  });

  final CoverArtFailureCategory category;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'Cover art fetch failed (${category.name}'
      '${statusCode == null ? '' : ', status $statusCode'})'
      '${cause == null ? '' : ': $cause'}';
}

/// Maps a lower-level error to the artwork failure taxonomy.
CoverArtFailureCategory classifyCoverArtFailure(
  Object? error, {
  int? statusCode,
}) {
  if (error is CoverArtFetchException) {
    return error.category;
  }
  if (error is CoverArtInvalidResponseException) {
    return CoverArtFailureCategory.invalidPayload;
  }
  if (error is TimeoutException) {
    return CoverArtFailureCategory.networkTimeout;
  }
  if (statusCode != null) {
    switch (statusCode) {
      case HttpStatus.notFound:
      case HttpStatus.gone:
        return CoverArtFailureCategory.missingCoverReference;
      case HttpStatus.unauthorized:
      case HttpStatus.forbidden:
        return CoverArtFailureCategory.authRejection;
    }
  }
  return CoverArtFailureCategory.transport;
}

/// Recovery orchestration for cover art (plan F6/F7).
///
/// F6: a cached file that fails to decode (or a cached error payload) is
/// evicted from the disk cache and the decoded-image cache exactly once per
/// key; the next build refetches from the network. Repeated builds never
/// loop: the second failure renders the placeholder without another refetch.
///
/// F7: a missing cover reference triggers one coalesced entity-metadata
/// refresh. Concurrent builds share the same in-flight refresh, and a
/// per-cover cooldown prevents retry loops. The refresh may change the
/// cover ID or bump the targeted revision, after which widgets naturally
/// retry the resulting cover identity.
class CoverArtRecoveryCoordinator {
  CoverArtRecoveryCoordinator({
    Future<void> Function(String coverArtId)? refreshEntityForCover,
  }) : _refreshEntityForCover = refreshEntityForCover;

  final Future<void> Function(String coverArtId)? _refreshEntityForCover;

  final Set<String> _recoveredEntries = <String>{};
  final Map<String, Future<void>> _pendingRefreshes = <String, Future<void>>{};
  final Set<String> _refreshedCovers = <String>{};

  /// Evicts a corrupt or invalid cache entry exactly once and reports
  /// whether the caller should rebuild to trigger the single refetch.
  Future<bool> handleInvalidCacheEntry({
    required String cacheKey,
    required CacheManager cacheManager,
    File? cachedFile,
  }) async {
    if (!_recoveredEntries.add(cacheKey)) {
      return false;
    }
    try {
      await cacheManager.removeFile(cacheKey);
    } on Object catch (error) {
      AppLogger.warning(
        'Cover art eviction failed for $cacheKey: $error',
      );
    }
    if (cachedFile != null) {
      try {
        // Best-effort decoded-image eviction for the plain file key; the
        // resize-wrapped variants share the same underlying file identity.
        PaintingBinding.instance.imageCache.evict(FileImage(cachedFile));
      } on Object {
        // Decoded-cache eviction is best effort; the disk eviction above is
        // the authoritative targeted invalidation.
      }
    }
    AppLogger.info(
      'Cover art cache entry evicted for one bounded refetch: $cacheKey',
    );
    return true;
  }

  /// Requests one coalesced entity-metadata refresh for a missing cover
  /// reference. Returns the in-flight refresh when one is already running.
  Future<void> handleMissingCover(String coverArtId) {
    final id = coverArtId.trim();
    if (id.isEmpty) {
      return Future<void>.value();
    }
    final pending = _pendingRefreshes[id];
    if (pending != null) {
      return pending;
    }
    // Cooldown: one refresh per cover identity per session so repeated
    // builds cannot create a refresh loop.
    if (!_refreshedCovers.add(id)) {
      return Future<void>.value();
    }
    final refresh = _refresh(id);
    _pendingRefreshes[id] = refresh;
    return refresh;
  }

  Future<void> _refresh(String coverArtId) async {
    final refresh = _refreshEntityForCover;
    if (refresh == null) {
      return;
    }
    try {
      await refresh(coverArtId);
    } on Object catch (error, stackTrace) {
      AppLogger.info(
        'Cover art metadata refresh failed for $coverArtId: '
        '$error\n$stackTrace',
      );
    } finally {
      _pendingRefreshes.remove(coverArtId);
    }
  }
}
