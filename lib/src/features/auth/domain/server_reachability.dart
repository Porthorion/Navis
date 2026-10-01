enum ServerReachabilityStatus { checking, online, offline }

class ServerReachabilityState {
  const new({
    required this.status,
    this.lastCheckedAt,
    this.lastOnlineAt,
    this.lastErrorMessage,
    this.consecutiveFailureCount = 0,
    this.showRetryBanner = true,
  });

  final ServerReachabilityStatus status;
  final DateTime? lastCheckedAt;
  final DateTime? lastOnlineAt;
  final String? lastErrorMessage;
  final int consecutiveFailureCount;
  final bool showRetryBanner;

  ServerReachabilityState copyWith({
    ServerReachabilityStatus? status,
    DateTime? lastCheckedAt,
    DateTime? lastOnlineAt,
    String? lastErrorMessage,
    int? consecutiveFailureCount,
    bool? showRetryBanner,
    bool clearErrorMessage = false,
  }) {
    return ServerReachabilityState(
      status: status ?? this.status,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      lastOnlineAt: lastOnlineAt ?? this.lastOnlineAt,
      lastErrorMessage: clearErrorMessage
          ? null
          : lastErrorMessage ?? this.lastErrorMessage,
      consecutiveFailureCount:
          consecutiveFailureCount ?? this.consecutiveFailureCount,
      showRetryBanner: showRetryBanner ?? this.showRetryBanner,
    );
  }
}
