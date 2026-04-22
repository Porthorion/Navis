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
  });

  const GroupListeningSettings.defaults()
    : enabled = false,
      voyageServerUrl = null;

  final bool enabled;
  final String? voyageServerUrl;
}

@immutable
class GroupListeningVoyageServerOption {
  const GroupListeningVoyageServerOption({
    required this.label,
    required this.url,
  });

  final String label;
  final String url;
}

final groupListeningSettingsProvider = Provider<GroupListeningSettings>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return GroupListeningSettings(
    enabled: settings.groupListeningEnabled,
    voyageServerUrl: settings.voyageServerUrl,
  );
});

final groupListeningBundledVoyageServersProvider =
    Provider<List<GroupListeningVoyageServerOption>>((_) {
      return _parseBundledVoyageServers(AppConstants.voyageServers);
    });

final groupListeningResolvedVoyageServerUrlProvider = Provider<String?>((
  ref,
) {
  final settings = ref.watch(groupListeningSettingsProvider);
  final bundledServers = ref.watch(groupListeningBundledVoyageServersProvider);
  final configuredUrl = normalizeVoyageBaseUri(
    settings.voyageServerUrl,
  )?.toString();

  if (bundledServers.isEmpty) {
    return configuredUrl;
  }
  if (configuredUrl != null &&
      bundledServers.any((server) => server.url == configuredUrl)) {
    return configuredUrl;
  }
  return bundledServers.first.url;
});

final groupListeningSelectedVoyageServerOptionProvider =
    Provider<GroupListeningVoyageServerOption?>((ref) {
      final resolvedUrl = ref.watch(
        groupListeningResolvedVoyageServerUrlProvider,
      );
      if (resolvedUrl == null) {
        return null;
      }
      final bundledServers = ref.watch(
        groupListeningBundledVoyageServersProvider,
      );
      for (final server in bundledServers) {
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
      ),
    );
  }
  return List<GroupListeningVoyageServerOption>.unmodifiable(options);
}
