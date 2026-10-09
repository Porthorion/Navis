import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';

/// A reachability controller that always reports [_state].
class StaticReachabilityController extends ServerReachabilityController {
  new(this._state);

  final ServerReachabilityState _state;

  @override
  ServerReachabilityState build() => _state;
}

/// A reachability controller that always reports an online server.
class OnlineReachability extends ServerReachabilityController {
  @override
  ServerReachabilityState build() =>
      const ServerReachabilityState(status: ServerReachabilityStatus.online);
}
