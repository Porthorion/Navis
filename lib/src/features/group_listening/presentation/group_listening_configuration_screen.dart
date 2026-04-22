import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class GroupListeningConfigurationScreen extends ConsumerStatefulWidget {
  const GroupListeningConfigurationScreen({super.key});

  @override
  ConsumerState<GroupListeningConfigurationScreen> createState() =>
      _GroupListeningConfigurationScreenState();
}

class _GroupListeningConfigurationScreenState
    extends ConsumerState<GroupListeningConfigurationScreen> {
  final _voyageServerUrlController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _deviceLabelController = TextEditingController();

  bool _enabled = false;
  bool _autoFollowHost = true;
  bool _initialized = false;
  String? _selectedServerUrl;

  @override
  void dispose() {
    _voyageServerUrlController.dispose();
    _displayNameController.dispose();
    _deviceLabelController.dispose();
    super.dispose();
  }

  void _initFromSettings(
    AppSettingsModel settings, {
    required String? resolvedVoyageServerUrl,
  }) {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _enabled = settings.groupListeningEnabled;
    _autoFollowHost = settings.voyageAutoFollowHost;
    final configuredUrl = settings.voyageServerUrl?.trim();
    final initialServerUrl = resolvedVoyageServerUrl ?? configuredUrl;
    _selectedServerUrl = initialServerUrl;
    _voyageServerUrlController.text = initialServerUrl ?? '';
    _displayNameController.text = settings.voyageDisplayName ?? '';
    _deviceLabelController.text = settings.voyageDeviceLabel ?? '';
  }

  Future<void> _save(
    List<GroupListeningVoyageServerOption> bundledServers,
  ) async {
    final repository = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    final bundledServerUrl = bundledServers.isEmpty ? null : bundledServers.first.url;
    final voyageServerUrl = bundledServers.isEmpty
        ? _voyageServerUrlController.text.trim()
        : (_selectedServerUrl ?? bundledServerUrl ?? '').trim();
    final displayName = _displayNameController.text.trim();
    final deviceLabel = _deviceLabelController.text.trim();

    await repository.saveSettings(
      current.copyWith(
        groupListeningEnabled: _enabled,
        voyageServerUrl: voyageServerUrl.isEmpty ? null : voyageServerUrl,
        voyageDisplayName: displayName.isEmpty ? null : displayName,
        voyageDeviceLabel: deviceLabel.isEmpty ? null : deviceLabel,
        voyageAutoFollowHost: _autoFollowHost,
        clearVoyageServerUrl: voyageServerUrl.isEmpty,
        clearVoyageDisplayName: displayName.isEmpty,
        clearVoyageDeviceLabel: deviceLabel.isEmpty,
      ),
    );
  }

  String _enableSubtitle(
    List<GroupListeningVoyageServerOption> bundledServers,
    GroupListeningVoyageConnectionStatus connectionStatus,
  ) {
    if (_enabled) {
      return connectionStatus.message;
    }
    if (bundledServers.isEmpty) {
      return 'Enable Listen Together and connect Navis to a Voyage server.';
    }
    if (bundledServers.length == 1) {
      return 'Enable Listen Together and verify the bundled Voyage server.';
    }
    return 'Enable Listen Together and choose which bundled Voyage server to use.';
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final bundledServers = ref.watch(groupListeningBundledVoyageServersProvider);
    final resolvedVoyageServerUrl = ref.watch(
      groupListeningResolvedVoyageServerUrlProvider,
    );
    final connectionStatus = ref.watch(
      groupListeningVoyageConnectionStatusProvider,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Listen Together Configuration')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (settings) {
          _initFromSettings(
            settings,
            resolvedVoyageServerUrl: resolvedVoyageServerUrl,
          );
          final selectedServerUrl =
              _selectedServerUrl ??
              (bundledServers.isEmpty ? null : bundledServers.first.url);
          if (bundledServers.isNotEmpty &&
              selectedServerUrl != null &&
              _voyageServerUrlController.text != selectedServerUrl) {
            _voyageServerUrlController.text = selectedServerUrl;
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: Column(
                  children: <Widget>[
                    SwitchListTile(
                      key: const ValueKey('groupListeningEnabledSwitch'),
                      secondary: const Icon(Icons.headset_mic_outlined),
                      title: const Text('Enable Listen Together'),
                      subtitle: Text(
                        _enableSubtitle(bundledServers, connectionStatus),
                      ),
                      value: _enabled,
                      onChanged: (value) {
                        setState(() {
                          _enabled = value;
                          if (value &&
                              bundledServers.isNotEmpty &&
                              (_selectedServerUrl == null ||
                                  _selectedServerUrl!.isEmpty)) {
                            _selectedServerUrl = bundledServers.first.url;
                            _voyageServerUrlController.text =
                                bundledServers.first.url;
                          }
                        });
                        _save(bundledServers);
                      },
                    ),
                    if (bundledServers.length == 1)
                      ListTile(
                        leading: const Icon(Icons.cloud_outlined),
                        title: const Text('Voyage server'),
                        subtitle: Text(bundledServers.single.label),
                      ),
                    if (bundledServers.length > 1)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: DropdownButtonFormField<String>(
                          key: const ValueKey('groupListeningVoyageServerDropdown'),
                          value: selectedServerUrl,
                          decoration: const InputDecoration(
                            labelText: 'Voyage server',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.cloud_outlined),
                          ),
                          items: bundledServers
                              .map(
                                (server) => DropdownMenuItem<String>(
                                  value: server.url,
                                  child: Text(server.label),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _selectedServerUrl = value;
                              _voyageServerUrlController.text = value;
                            });
                            _save(bundledServers);
                          },
                        ),
                      ),
                    if (bundledServers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: TextField(
                          key: const ValueKey('groupListeningVoyageServerUrlField'),
                          controller: _voyageServerUrlController,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'Voyage server URL',
                            hintText: 'https://voyage.example.com',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.link),
                          ),
                          onChanged: (_) => _save(bundledServers),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ConnectionStatusCard(status: connectionStatus),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Local profile',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('groupListeningDisplayNameField'),
                        controller: _displayNameController,
                        decoration: const InputDecoration(
                          labelText: 'Display name',
                          hintText: 'Shown to other listeners',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        onChanged: (_) => _save(bundledServers),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey('groupListeningDeviceLabelField'),
                        controller: _deviceLabelController,
                        decoration: const InputDecoration(
                          labelText: 'Device label',
                          hintText: 'Optional device nickname',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.devices_outlined),
                        ),
                        onChanged: (_) => _save(bundledServers),
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        key: const ValueKey('groupListeningAutoFollowHostSwitch'),
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(Icons.sync_alt_outlined),
                        title: const Text('Auto-follow host playback'),
                        subtitle: const Text(
                          'Prefer host-led play, pause, and seek updates when joining a room.',
                        ),
                        value: _autoFollowHost,
                        onChanged: (value) {
                          setState(() => _autoFollowHost = value);
                          _save(bundledServers);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text(
                    'Sensitive Voyage tokens are not stored here',
                  ),
                  subtitle: const Text(
                    'Only non-sensitive configuration is stored in app settings. Room tokens and secrets stay in secure storage.',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ConnectionStatusCard extends StatelessWidget {
  const _ConnectionStatusCard({required this.status});

  final GroupListeningVoyageConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    late final Color background;
    late final Color foreground;
    late final IconData icon;
    switch (status.state) {
      case GroupListeningVoyageConnectionState.connected:
        background = scheme.primaryContainer;
        foreground = scheme.onPrimaryContainer;
        icon = Icons.verified_outlined;
        break;
      case GroupListeningVoyageConnectionState.failed:
        background = scheme.errorContainer;
        foreground = scheme.onErrorContainer;
        icon = Icons.cloud_off_outlined;
        break;
      case GroupListeningVoyageConnectionState.checking:
        background = scheme.secondaryContainer;
        foreground = scheme.onSecondaryContainer;
        icon = Icons.sync_outlined;
        break;
      case GroupListeningVoyageConnectionState.disabled:
      case GroupListeningVoyageConnectionState.unconfigured:
        background = scheme.surfaceContainerHighest;
        foreground = scheme.onSurfaceVariant;
        icon = Icons.info_outline;
        break;
    }

    final subtitle = <String>[
      if (status.serverLabel != null) status.serverLabel!,
      if (status.serverUrl != null) status.serverUrl!,
    ].join(' • ');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  status.message,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
