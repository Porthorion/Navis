import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';

class _UnavailableServerConfigNotifier extends ServerConfigNotifier {
  @override
  Future<ServerConfigModel?> build() async {
    throw const CredentialReadException();
  }
}

void main() {
  test('an unavailable config stays loading instead of signing out', () async {
    final container = ProviderContainer(
      overrides: [
        serverConfigProvider.overrideWith(_UnavailableServerConfigNotifier.new),
      ],
      retry: (retryCount, error) => null,
    );
    addTearDown(container.dispose);
    container.listen(serverConfigProvider, (_, _) {}, fireImmediately: true);
    await container.pump();
    await container.pump();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      container.read(sessionRoutePhaseProvider),
      SessionRoutePhase.loading,
    );
  });
}
