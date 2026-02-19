import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/data/server_connection_service.dart';

final serverConnectionServiceProvider = Provider<ServerConnectionService>((
  ref,
) {
  return const SubsonicServerConnectionService();
});
