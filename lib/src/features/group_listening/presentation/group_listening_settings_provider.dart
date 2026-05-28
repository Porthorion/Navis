import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/constants.dart';

@immutable
class GroupListeningSettings {
  const GroupListeningSettings({
    required this.enabled,
    this.voyageServerUrl,
    required this.autoFollowHost,
  });

  const GroupListeningSettings.defaults()
    : enabled = false,
      voyageServerUrl = null,
      autoFollowHost = true;

  final bool enabled;
  final String? voyageServerUrl;
  final bool autoFollowHost;
}

@immutable
class GroupListeningVoyageServerOption {
  const GroupListeningVoyageServerOption({
    required this.label,
    required this.url,
    this.bundled = false,
  });

  final String label;
  final String url;
  final bool bundled;
}

final groupListeningSettingsProvider = Provider<GroupListeningSettings>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return GroupListeningSettings(
    enabled: settings.groupListeningEnabled,
    voyageServerUrl: settings.voyageServerUrl,
    autoFollowHost: settings.voyageAutoFollowHost,
  );
});

final groupListeningBundledVoyageServersProvider =
    Provider<List<GroupListeningVoyageServerOption>>((_) {
      return _parseBundledVoyageServers(AppConstants.voyageServers);
    });

final groupListeningVoyageServersProvider =
    Provider<List<GroupListeningVoyageServerOption>>((ref) {
      final bundledServers = ref.watch(
        groupListeningBundledVoyageServersProvider,
      );
      final settings =
          ref.watch(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults();
      final seenUrls = bundledServers.map((server) => server.url).toSet();
      final customServers = <GroupListeningVoyageServerOption>[];
      for (final server in settings.customVoyageServers) {
        final normalizedUrl = normalizeVoyageBaseUri(server.url)?.toString();
        if (normalizedUrl == null || !seenUrls.add(normalizedUrl)) {
          continue;
        }
        customServers.add(
          GroupListeningVoyageServerOption(
            label: server.label,
            url: normalizedUrl,
          ),
        );
      }
      return List<GroupListeningVoyageServerOption>.unmodifiable(
        <GroupListeningVoyageServerOption>[
          ...bundledServers,
          ...customServers,
        ],
      );
    });

final groupListeningResolvedVoyageServerUrlProvider = Provider<String?>((
  ref,
) {
  final settings = ref.watch(groupListeningSettingsProvider);
  final servers = ref.watch(groupListeningVoyageServersProvider);
  final configuredUrl = normalizeVoyageBaseUri(
    settings.voyageServerUrl,
  )?.toString();

  if (servers.isEmpty) {
    return configuredUrl;
  }
  if (configuredUrl != null &&
      servers.any((server) => server.url == configuredUrl)) {
    return configuredUrl;
  }
  return servers.first.url;
});

final groupListeningSelectedVoyageServerOptionProvider =
    Provider<GroupListeningVoyageServerOption?>((ref) {
      final resolvedUrl = ref.watch(
        groupListeningResolvedVoyageServerUrlProvider,
      );
      if (resolvedUrl == null) {
        return null;
      }
      final servers = ref.watch(groupListeningVoyageServersProvider);
      for (final server in servers) {
        if (server.url == resolvedUrl) {
          return server;
        }
      }
      final uri = Uri.tryParse(resolvedUrl);
      if (uri == null) {
        return null;
      }
      return GroupListeningVoyageServerOption(
        label: uri.host.isEmpty ? resolvedUrl : uri.host,
        url: resolvedUrl,
      );
    });

List<GroupListeningVoyageServerOption> _parseBundledVoyageServers(String raw) {
  final options = <GroupListeningVoyageServerOption>[];
  final seenUrls = <String>{};
  for (final entry in raw.split(RegExp(r'[\n,;]+'))) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    final separatorIndex = trimmed.indexOf('|');
    final hasLabel = separatorIndex > 0;
    final rawLabel = hasLabel
        ? trimmed.substring(0, separatorIndex).trim()
        : '';
    final rawUrl = hasLabel
        ? trimmed.substring(separatorIndex + 1).trim()
        : trimmed;
    final normalizedUrl = normalizeVoyageBaseUri(rawUrl)?.toString();
    if (normalizedUrl == null || !seenUrls.add(normalizedUrl)) {
      continue;
    }
    final uri = Uri.parse(normalizedUrl);
    options.add(
      GroupListeningVoyageServerOption(
        label: rawLabel.isEmpty ? uri.host : rawLabel,
        url: normalizedUrl,
        bundled: true,
      ),
    );
  }
  return List<GroupListeningVoyageServerOption>.unmodifiable(options);
}
