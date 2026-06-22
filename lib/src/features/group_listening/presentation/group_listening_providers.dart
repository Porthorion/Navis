import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';
import 'package:navis/src/features/group_listening/data/group_listening_device_name_service.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

final groupListeningAvailabilityProvider = Provider<GroupListeningAvailability>(
  (ref) {
    final settings = ref.watch(groupListeningSettingsProvider);
    final resolvedVoyageServerUrl = ref.watch(
      groupListeningResolvedVoyageServerUrlProvider,
    );
    final activeServer = ref.watch(serverConfigStateProvider).asData?.value;
    return resolveGroupListeningAvailability(
      enabled: settings.enabled,
      voyageServerUrl: resolvedVoyageServerUrl,
      activeServer: activeServer,
    );
  },
);

final groupListeningClientConfigurationProvider =
    Provider<GroupListeningClientConfiguration?>((ref) {
      final settings = ref.watch(groupListeningSettingsProvider);
      final deviceLabel = ref
          .watch(groupListeningDeviceLabelProvider)
          .asData
          ?.value;
      final resolvedVoyageServerUrl = ref.watch(
        groupListeningResolvedVoyageServerUrlProvider,
      );
      final activeServer = ref.watch(serverConfigStateProvider).asData?.value;
      return buildGroupListeningClientConfiguration(
        enabled: settings.enabled,
        voyageServerUrl: resolvedVoyageServerUrl,
        activeServer: activeServer,
        autoFollowHost: settings.autoFollowHost,
        deviceLabel: deviceLabel,
      );
    });

final groupListeningDeviceLabelProvider = FutureProvider<String>((ref) {
  return const GroupListeningDeviceNameService().resolveDeviceLabel();
});

final groupListeningSessionCredentialStoreProvider =
    Provider<GroupListeningSessionCredentialStore>((_) {
      return const FlutterSecureGroupListeningSessionCredentialStore();
    });

final groupListeningHttpClientProvider = Provider<GroupListeningHttpClient>((
  _,
) {
  return VoyageGroupListeningHttpClient();
});

final groupListeningRealtimeTransportProvider =
    Provider<GroupListeningRealtimeTransportClient>((_) {
      return const IOWebSocketGroupListeningRealtimeTransportClient();
    });

final groupListeningRepositoryProvider = Provider<GroupListeningRepository>((
  ref,
) {
  return DefaultGroupListeningRepository(
    httpClient: ref.watch(groupListeningHttpClientProvider),
    realtimeTransport: ref.watch(groupListeningRealtimeTransportProvider),
  );
});

final groupListeningCapabilityDiscoveryProvider =
    FutureProvider.autoDispose<GroupListeningCapabilityDiscovery?>((ref) async {
      final availability = ref.watch(groupListeningAvailabilityProvider);
      if (availability != GroupListeningAvailability.ready) {
        return null;
      }
      final configuration = ref.watch(
        groupListeningClientConfigurationProvider,
      );
      if (configuration == null) {
        return null;
      }
      final resolved = await resolveBestBundledVoyageServer(
        ref,
        configuration,
      );
      return resolved?.discovery ??
          ref.read(groupListeningRepositoryProvider).discover(configuration);
    });

final groupListeningAvailableRoomsProvider =
    FutureProvider.autoDispose<List<GroupListeningAvailableRoomSummary>>((
      ref,
    ) async {
      final availability = ref.watch(groupListeningAvailabilityProvider);
      if (availability != GroupListeningAvailability.ready) {
        return const <GroupListeningAvailableRoomSummary>[];
      }
      final configuration = ref.watch(
        groupListeningClientConfigurationProvider,
      );
      if (configuration == null) {
        return const <GroupListeningAvailableRoomSummary>[];
      }
      final resolved = await resolveBestBundledVoyageServer(
        ref,
        configuration,
      );
      final effectiveConfiguration = resolved == null
          ? configuration
          : configurationWithVoyageBaseUrl(
              configuration,
              Uri.parse(resolved.option.url),
            );
      return ref
          .read(groupListeningRepositoryProvider)
          .listAvailableRooms(effectiveConfiguration);
    });

Future<GroupListeningResolvedVoyageServer?> resolveBestBundledVoyageServer(
  Ref ref,
  GroupListeningClientConfiguration configuration, {
  String? preferredUrl,
}) async {
  final voyageServers = ref.read(groupListeningVoyageServersProvider);
  if (voyageServers.isEmpty) {
    return null;
  }
  final settings = ref.read(groupListeningSettingsProvider);
  if (!settings.enabled) {
    return null;
  }
  final selectedUrl = normalizeVoyageBaseUri(
    preferredUrl ?? settings.voyageServerUrl,
  )?.toString();
  final repository = ref.read(groupListeningRepositoryProvider);
  final probes = await Future.wait(
    voyageServers.map((server) async {
      final uri = normalizeVoyageBaseUri(server.url);
      if (uri == null || !isVoyageTransportAllowed(uri)) {
        return null;
      }
      try {
        final discovery = await repository.discover(
          configurationWithVoyageBaseUrl(configuration, uri),
        );
        if (!discovery.supportsCurrentProtocol) {
          return null;
        }
        return GroupListeningResolvedVoyageServer(
          option: server,
          discovery: discovery,
        );
      } on Object {
        return null;
      }
    }),
  );
  final candidates = probes.nonNulls.toList(growable: false);
  if (candidates.isEmpty) {
    return null;
  }
  candidates.sort((a, b) {
    final versionCompare = compareSemanticVersions(
      b.discovery.serverVersion,
      a.discovery.serverVersion,
    );
    if (versionCompare != 0) {
      return versionCompare;
    }
    final aSelected = selectedUrl != null && a.option.url == selectedUrl;
    final bSelected = selectedUrl != null && b.option.url == selectedUrl;
    if (aSelected != bSelected) {
      return aSelected ? -1 : 1;
    }
    return voyageServers
        .indexOf(a.option)
        .compareTo(
          voyageServers.indexOf(b.option),
        );
  });
  return candidates.first;
}

GroupListeningClientConfiguration configurationWithVoyageBaseUrl(
  GroupListeningClientConfiguration configuration,
  Uri voyageBaseUrl, {
  String? protocolVersion,
}) {
  return GroupListeningClientConfiguration(
    voyageBaseUrl: voyageBaseUrl,
    sourceServerOrigin: configuration.sourceServerOrigin,
    sourceServerFingerprint: configuration.sourceServerFingerprint,
    displayName: configuration.displayName,
    deviceLabel: configuration.deviceLabel,
    autoFollowHost: configuration.autoFollowHost,
    allowInsecureTransport: voyageBaseUrl.scheme == 'http',
    protocolVersion: protocolVersion ?? configuration.protocolVersion,
  );
}

enum GroupListeningVoyageConnectionState {
  disabled,
  unconfigured,
  checking,
  connected,
  failed,
}

@immutable
class GroupListeningVoyageConnectionStatus {
  const GroupListeningVoyageConnectionStatus({
    required this.state,
    required this.message,
    this.userActionMessage,
  });

  final GroupListeningVoyageConnectionState state;
  final String message;
  final String? userActionMessage;

  bool get isHealthy => state == GroupListeningVoyageConnectionState.connected;
}

final groupListeningVoyageConnectionStatusProvider =
    Provider<GroupListeningVoyageConnectionStatus>((ref) {
      final settings = ref.watch(groupListeningSettingsProvider);
      final availability = ref.watch(groupListeningAvailabilityProvider);
      final discoveryAsync = ref.watch(
        groupListeningCapabilityDiscoveryProvider,
      );

      if (!settings.enabled) {
        return GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.disabled,
          message: 'Listen Together is off.',
        );
      }
      if (availability != GroupListeningAvailability.ready) {
        final resolvedVoyageServerUrl = ref.watch(
          groupListeningResolvedVoyageServerUrlProvider,
        );
        return GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.unconfigured,
          message: 'Not connected to Voyage.',
          userActionMessage: _voyageUserActionMessage(
            voyageServerUrl: resolvedVoyageServerUrl,
            availability: availability,
          ),
        );
      }

      return discoveryAsync.when(
        data: (_) => GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.connected,
          message: 'Successfully connected to Voyage.',
        ),
        loading: () => GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.checking,
          message: 'Checking Voyage connection...',
        ),
        error: (error, _) => GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.failed,
          message: 'Not connected to Voyage.',
          userActionMessage: _voyageDiscoveryUserActionMessage(error),
        ),
      );
    });

String? _voyageUserActionMessage({
  required String? voyageServerUrl,
  required GroupListeningAvailability availability,
}) {
  if (availability != GroupListeningAvailability.unconfigured) {
    return null;
  }
  final uri = normalizeVoyageBaseUri(voyageServerUrl);
  if (uri == null) {
    return 'Enter a valid Voyage server URL.';
  }
  if (!isVoyageTransportAllowed(uri)) {
    return 'Use HTTPS for Voyage, or a local HTTP server in debug builds.';
  }
  return 'Sign in to your Subsonic server before using Listen Together.';
}

String? _voyageDiscoveryUserActionMessage(Object error) {
  final failure = error is GroupListeningRepositoryException
      ? error.failure
      : null;
  if (failure == null) {
    return null;
  }
  return switch (failure.code) {
    GroupListeningErrorCode.unsupportedProtocolVersion =>
      'Update Navis or choose a Voyage server with a compatible protocol.',
    GroupListeningErrorCode.validationFailed =>
      'Check the Voyage server configuration and try again.',
    GroupListeningErrorCode.insecureTransport =>
      'Use HTTPS for Voyage, or a local HTTP server in debug builds.',
    GroupListeningErrorCode.transportUnavailable
        when failure.message.isNotEmpty =>
      failure.message,
    _ => null,
  };
}

@immutable
class GroupListeningResolvedVoyageServer {
  const GroupListeningResolvedVoyageServer({
    required this.option,
    required this.discovery,
  });

  final GroupListeningVoyageServerOption option;
  final GroupListeningCapabilityDiscovery discovery;
}

final groupListeningClientDescriptorProvider =
    Provider<GroupListeningClientDescriptor>((ref) {
      final configuration = ref.watch(
        groupListeningClientConfigurationProvider,
      );
      final resolvedDeviceLabel = ref
          .watch(groupListeningDeviceLabelProvider)
          .asData
          ?.value;
      final packageInfo = ref.watch(packageInfoProvider).asData?.value;
      final fallbackDeviceLabel =
          resolvedDeviceLabel ?? defaultGroupListeningDeviceLabel();
      final fingerprint = configuration?.sourceServerFingerprint ?? 'local';
      final fingerprintPrefix = fingerprint.length <= 12
          ? fingerprint
          : fingerprint.substring(0, 12);
      final rawDeviceId = <String>[
        packageInfo?.packageName ?? 'navis',
        defaultTargetPlatform.name,
        configuration?.deviceLabel ??
            configuration?.displayName ??
            fallbackDeviceLabel,
        fingerprintPrefix,
      ].join('-');
      return GroupListeningClientDescriptor(
        appVersion: packageInfo?.version ?? 'dev',
        platform: defaultTargetPlatform.name,
        deviceId: _normalizeGroupListeningDeviceId(rawDeviceId),
        deviceLabel: configuration?.deviceLabel ?? fallbackDeviceLabel,
        capabilities: const <String>{
          'playback_anchor',
          'queue_add',
          voyageQueueEntryMetadataCapability,
          voyagePortableTrackRefsCapability,
          'queue_remove',
          'queue_replace',
        },
      );
    });

String _normalizeGroupListeningDeviceId(String rawValue) {
  var normalized = rawValue
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-');
  normalized = normalized.replaceFirst(RegExp(r'^-+'), '');
  normalized = normalized.replaceFirst(RegExp(r'-+$'), '');
  if (normalized.isEmpty) {
    return 'navis-${defaultTargetPlatform.name}';
  }
  return normalized.length <= 64 ? normalized : normalized.substring(0, 64);
}

int compareSemanticVersions(String left, String right) {
  final leftParts = _semanticVersionParts(left);
  final rightParts = _semanticVersionParts(right);
  for (var index = 0; index < leftParts.length; index++) {
    final compare = leftParts[index].compareTo(rightParts[index]);
    if (compare != 0) {
      return compare;
    }
  }
  return left.compareTo(right);
}

List<int> _semanticVersionParts(String version) {
  final match = RegExp(r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(
    version.trim(),
  );
  if (match == null) {
    return const <int>[0, 0, 0];
  }
  return <int>[
    int.tryParse(match.group(1) ?? '') ?? 0,
    int.tryParse(match.group(2) ?? '') ?? 0,
    int.tryParse(match.group(3) ?? '') ?? 0,
  ];
}
