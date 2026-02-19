enum ServerReachabilityStatus {
  checking,
  online,
  offline,
}

class ServerReachabilityState {
  const ServerReachabilityState({
    required this.status,
    this.lastCheckedAt,
    this.lastOnlineAt,
    this.lastErrorMessage,
  });

  final ServerReachabilityStatus status;
  final DateTime? lastCheckedAt;
  final DateTime? lastOnlineAt;
  final String? lastErrorMessage;

  ServerReachabilityState copyWith({
    ServerReachabilityStatus? status,
    DateTime? lastCheckedAt,
    DateTime? lastOnlineAt,
    String? lastErrorMessage,
    bool clearErrorMessage = false,
  }) {
    return ServerReachabilityState(
      status: status ?? this.status,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      lastOnlineAt: lastOnlineAt ?? this.lastOnlineAt,
      lastErrorMessage: clearErrorMessage
          ? null
          : lastErrorMessage ?? this.lastErrorMessage,
    );
  }
}
