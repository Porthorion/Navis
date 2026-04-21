import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

@immutable
class GroupListeningSettings {
  const GroupListeningSettings({
    required this.enabled,
    this.voyageServerUrl,
    this.displayName,
    this.deviceLabel,
    required this.autoFollowHost,
  });

  const GroupListeningSettings.defaults()
    : enabled = false,
      voyageServerUrl = null,
      displayName = null,
      deviceLabel = null,
      autoFollowHost = true;

  final bool enabled;
  final String? voyageServerUrl;
  final String? displayName;
  final String? deviceLabel;
  final bool autoFollowHost;
}

final groupListeningSettingsProvider = Provider<GroupListeningSettings>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return GroupListeningSettings(
    enabled: settings.groupListeningEnabled,
    voyageServerUrl: settings.voyageServerUrl,
    displayName: settings.voyageDisplayName,
    deviceLabel: settings.voyageDeviceLabel,
    autoFollowHost: settings.voyageAutoFollowHost,
  );
});
