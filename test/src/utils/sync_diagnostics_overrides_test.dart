import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';

void main() {
  test('all override fields survive the JSON round trip', () {
    const overrides = SyncDiagnosticsOverrides(
      networkType: NetworkType.cellular,
      nativeMetered: true,
      backgroundSyncUnmeteredOnly: false,
      automaticSyncAllowed: false,
      interactiveHydrationAllowed: true,
      meteredBudgetBytes: 1024,
      requestReporting: true,
      cachedListenBrainzPresentation: true,
      forceSearchRemoteFailure: true,
      radioPresentationFixture: true,
      artistTopTracksPresentationFixture: true,
    );
    expect(
      SyncDiagnosticsOverrides.fromJson(overrides.toJson()).toJson(),
      overrides.toJson(),
    );
  });

  test('patch keeps omitted fields and clears explicit nulls', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      syncDiagnosticsOverridesProvider.notifier,
    );
    final values = <String, Object?>{
      'networkType': 'cellular',
      'nativeMetered': true,
      'backgroundSyncUnmeteredOnly': false,
      'automaticSyncAllowed': false,
      'interactiveHydrationAllowed': true,
      'meteredBudgetBytes': 1024,
      'requestReporting': true,
      'cachedListenBrainzPresentation': true,
      'forceSearchRemoteFailure': true,
      'radioPresentationFixture': true,
      'artistTopTracksPresentationFixture': true,
    };
    controller.patch(values);
    controller.patch({'meteredBudgetBytes': 2048});
    expect(container.read(syncDiagnosticsOverridesProvider).toJson(), {
      ...values,
      'meteredBudgetBytes': 2048,
    });
    controller.patch({for (final key in values.keys) key: null});
    expect(
      container.read(syncDiagnosticsOverridesProvider).toJson(),
      const SyncDiagnosticsOverrides().toJson(),
    );
  });
}
