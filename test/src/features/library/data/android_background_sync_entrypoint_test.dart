import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/data/android_background_sync_entrypoint.dart';

void main() {
  test(
    'background policy tracker refreshes metering during a worker pass',
    () async {
      final changes = StreamController<List<ConnectivityResult>>();
      addTearDown(changes.close);
      var connectivity = <ConnectivityResult>[ConnectivityResult.wifi];
      var metered = false;
      final tracker = await BackgroundNetworkPolicyTracker.create(
        readConnectivity: () async => connectivity,
        connectivityChanges: changes.stream,
        readNativeMetered: () async => metered,
        backgroundSyncUnmeteredOnly: true,
        refreshInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);

      expect(tracker.current.allowsBackgroundSync, isTrue);

      connectivity = <ConnectivityResult>[ConnectivityResult.mobile];
      metered = true;
      await tracker.refresh();

      expect(tracker.current.networkType.name, 'cellular');
      expect(tracker.current.allowsBackgroundSync, isFalse);
    },
  );

  test('background policy tracker reacts to connectivity changes', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    addTearDown(changes.close);
    var connectivity = <ConnectivityResult>[ConnectivityResult.wifi];
    final tracker = await BackgroundNetworkPolicyTracker.create(
      readConnectivity: () async => connectivity,
      connectivityChanges: changes.stream,
      readNativeMetered: () async => false,
      backgroundSyncUnmeteredOnly: true,
      refreshInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);

    connectivity = <ConnectivityResult>[ConnectivityResult.none];
    changes.add(connectivity);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(tracker.current.networkType.name, 'offline');
    expect(tracker.current.allowsBackgroundSync, isFalse);
  });
}
