import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:url_launcher/url_launcher.dart';

class ServerSettingsScreen extends ConsumerStatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  ConsumerState<ServerSettingsScreen> createState() =>
      _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends ConsumerState<ServerSettingsScreen> {
  bool _isTestingConnection = false;
  bool _isSigningOut = false;
  bool _isSavingApiKey = false;

  final _lastFmApiKeyController = TextEditingController();
  final _voyageServerUrlController = TextEditingController();
  bool _lastFmKeyInitialized = false;
  bool _groupListeningInitialized = false;
  bool _obscureApiKey = true;
  bool _groupListeningEnabled = false;
  String? _selectedVoyageServerUrl;

  bool get _isBusy => _isTestingConnection || _isSigningOut;

  @override
  void initState() {
    super.initState();
    _lastFmApiKeyController.addListener(_onApiKeyTextChanged);
  }

  void _onApiKeyTextChanged() {
    // Triggers rebuild so the clear icon in _LastFmCard stays in sync.
    setState(() {});
  }

  @override
  void dispose() {
    _lastFmApiKeyController.removeListener(_onApiKeyTextChanged);
    _lastFmApiKeyController.dispose();
    _voyageServerUrlController.dispose();
    super.dispose();
  }

  void _initLastFmKey(AppSettingsModel settings) {
    if (_lastFmKeyInitialized) return;
    _lastFmKeyInitialized = true;
    _lastFmApiKeyController.text = settings.lastFmApiKey ?? '';
  }

  void _initGroupListeningSettings(
    AppSettingsModel settings, {
    required String? resolvedVoyageServerUrl,
  }) {
    if (_groupListeningInitialized) return;
    _groupListeningInitialized = true;
    _groupListeningEnabled = settings.groupListeningEnabled;
    final configuredUrl = settings.voyageServerUrl?.trim();
    final initialServerUrl = resolvedVoyageServerUrl ?? configuredUrl;
    _selectedVoyageServerUrl = initialServerUrl;
    _voyageServerUrlController.text = initialServerUrl ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final configAsync = ref.watch(serverConfigStateProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final isBundled = ref.watch(lastFmBundledKeyProvider);
    final bundledVoyageServers = ref.watch(
      groupListeningBundledVoyageServersProvider,
    );
    final resolvedVoyageServerUrl = ref.watch(
      groupListeningResolvedVoyageServerUrlProvider,
    );
    final voyageConnectionStatus = ref.watch(
      groupListeningVoyageConnectionStatusProvider,
    );
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.serverSettingsTitle)),
      body: configAsync.when(
        data: (config) {
          if (config == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.serverSettingsNotAuthenticated,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          settingsAsync.whenData((settings) {
            _initLastFmKey(settings);
            _initGroupListeningSettings(
              settings,
              resolvedVoyageServerUrl: resolvedVoyageServerUrl,
            );
          });
          final selectedVoyageServerUrl =
              _selectedVoyageServerUrl ??
              (bundledVoyageServers.isEmpty
                  ? null
                  : bundledVoyageServers.first.url);
          if (bundledVoyageServers.isNotEmpty &&
              selectedVoyageServerUrl != null &&
              _voyageServerUrlController.text != selectedVoyageServerUrl) {
            _voyageServerUrlController.text = selectedVoyageServerUrl;
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // ── Server section ──────────────────────────────────────
                  _SectionHeader(title: l10n.configurationServerSection),
                  const SizedBox(height: 8),

                  // Connection info card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.serverSettingsCurrentConnection,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          _ServerInfoRow(
                            label: l10n.serverSettingsUrlLabel,
                            value: config.url,
                          ),
                          _ServerInfoRow(
                            label: l10n.serverSettingsUsernameLabel,
                            value: config.username,
                          ),
                          if (config.name != null)
                            _ServerInfoRow(
                              label: l10n.serverSettingsNameLabel,
                              value: config.name!,
                            ),
                          _ServerInfoRow(
                            label: l10n.serverSettingsApiVersionLabel,
                            value: config.apiVersion,
                          ),
                          _ServerInfoRow(
                            label: l10n.serverSettingsAuthModeLabel,
                            value: config.useLegacyAuth
                                ? l10n.serverSettingsAuthModeLegacy
                                : l10n.serverSettingsAuthModeToken,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Test Connection
                  FilledButton.tonal(
                    onPressed: _isBusy ? null : () => _testConnection(config),
                    child: _isTestingConnection
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.serverSettingsTestConnection),
                  ),
                  const SizedBox(height: 12),

                  // Sign Out (red)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                    ),
                    onPressed: _isBusy
                        ? null
                        : () => _showSignOutConfirmation(context),
                    child: _isSigningOut
                        ? SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cs.onError,
                            ),
                          )
                        : Text(l10n.serverSettingsSignOut),
                  ),
                  const SizedBox(height: 32),

                  // ── External Services section ──────────────────────────
                  _SectionHeader(
                    title: l10n.configurationExternalServicesSection,
                  ),
                  const SizedBox(height: 8),

                  // Last.fm card
                  _LastFmCard(
                    isBundled: isBundled,
                    isSaving: _isSavingApiKey,
                    obscureApiKey: _obscureApiKey,
                    controller: _lastFmApiKeyController,
                    onToggleObscure: () =>
                        setState(() => _obscureApiKey = !_obscureApiKey),
                    onSave: _saveLastFmKey,
                    onClear: _clearLastFmKey,
                    onGetApiKey: _openLastFmApiPage,
                  ),
                  const SizedBox(height: 32),

                  // ── Listen Together section ─────────────────────────
                  const _SectionHeader(title: 'Listen Together'),
                  const SizedBox(height: 8),
                  _ListenTogetherCard(
                    enabled: _groupListeningEnabled,
                    bundledServers: bundledVoyageServers,
                    selectedServerUrl: selectedVoyageServerUrl,
                    voyageServerUrlController: _voyageServerUrlController,
                    connectionStatus: voyageConnectionStatus,
                    onEnabledChanged: (value) {
                      setState(() {
                        _groupListeningEnabled = value;
                        if (value &&
                            bundledVoyageServers.isNotEmpty &&
                            (_selectedVoyageServerUrl == null ||
                                _selectedVoyageServerUrl!.isEmpty)) {
                          _selectedVoyageServerUrl =
                              bundledVoyageServers.first.url;
                          _voyageServerUrlController.text =
                              bundledVoyageServers.first.url;
                        }
                      });
                      _saveGroupListeningSettings(bundledVoyageServers);
                    },
                    onServerSelected: (value) {
                      if (value == null) return;
                      setState(() {
                        _selectedVoyageServerUrl = value;
                        _voyageServerUrlController.text = value;
                      });
                      _saveGroupListeningSettings(bundledVoyageServers);
                    },
                    onManualServerChanged: (_) =>
                        _saveGroupListeningSettings(bundledVoyageServers),
                  ),
                  const SizedBox(height: 12),
                  _VoyageConnectionStatusCard(status: voyageConnectionStatus),
                ],
              ),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.serverSettingsLoadError,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _testConnection(ServerConfigModel config) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isTestingConnection = true);
    try {
      final result = await ref
          .read(serverConnectionServiceProvider)
          .probe(
            url: config.url,
            username: config.username,
            password: config.password,
          );
      if (!mounted) return;
      showAppNotice(context, message: l10n.loginTestConnectionSuccess(result.apiVersion), level: AppNoticeLevel.success);
    } on Object catch (error) {
      if (!mounted) return;
      showAppNotice(context, message: _toUserMessage(error, l10n), level: AppNoticeLevel.error);
    } finally {
      if (mounted) setState(() => _isTestingConnection = false);
    }
  }

  Future<void> _showSignOutConfirmation(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showDialog<_SignOutAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.serverSettingsSignOutConfirmTitle),
        content: Text(l10n.serverSettingsSignOutConfirmMessage),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_SignOutAction.keepData),
            child: Text(l10n.serverSettingsSignOutKeepData),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_SignOutAction.wipeData),
            child: Text(l10n.serverSettingsSignOutWipeData),
          ),
        ],
      ),
    );

    if (action == null) return;
    await _signOut(wipeLocalData: action == _SignOutAction.wipeData);
  }

  Future<void> _signOut({required bool wipeLocalData}) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isSigningOut = true);
    try {
      await ref
          .read(signOutServiceProvider)
          .signOut(wipeLocalData: wipeLocalData);
      await ref.read(serverConfigProvider.notifier).refresh();
      if (!mounted) return;
      showAppNotice(
        context,
        message: wipeLocalData
            ? l10n.serverSettingsSignOutWipeSuccess
            : l10n.serverSettingsSignOutSuccess,
        level: AppNoticeLevel.info,
      );
      context.go('/login');
    } on Object {
      if (!mounted) return;
      showAppNotice(context, message: l10n.serverSettingsSignOutError, level: AppNoticeLevel.error);
    } finally {
      if (mounted) setState(() => _isSigningOut = false);
    }
  }

  Future<void> _saveLastFmKey() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isSavingApiKey = true);
    try {
      final repo = ref.read(settingsRepositoryProvider);
      final current =
          ref.read(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults();
      final key = _lastFmApiKeyController.text.trim();
      await repo.saveSettings(
        current.copyWith(
          lastFmApiKey: key.isEmpty ? null : key,
          clearLastFmApiKey: key.isEmpty,
        ),
      );
      if (!mounted) return;
      showAppNotice(
        context,
        message: key.isEmpty
            ? l10n.configurationLastFmApiKeyCleared
            : l10n.configurationLastFmApiKeySaved,
        level: AppNoticeLevel.success,
      );
    } on Object {
      if (!mounted) return;
      showAppNotice(context, message: l10n.serverSettingsSaveError, level: AppNoticeLevel.error);
    } finally {
      if (mounted) setState(() => _isSavingApiKey = false);
    }
  }

  Future<void> _clearLastFmKey() async {
    _lastFmApiKeyController.clear();
    await _saveLastFmKey();
  }

  Future<void> _saveGroupListeningSettings(
    List<GroupListeningVoyageServerOption> bundledServers,
  ) async {
    final repository = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    final bundledServerUrl = bundledServers.isEmpty
        ? null
        : bundledServers.first.url;
    final voyageServerUrl = bundledServers.isEmpty
        ? _voyageServerUrlController.text.trim()
        : (_selectedVoyageServerUrl ?? bundledServerUrl ?? '').trim();

    await repository.saveSettings(
      current.copyWith(
        groupListeningEnabled: _groupListeningEnabled,
        voyageServerUrl: voyageServerUrl.isEmpty ? null : voyageServerUrl,
        voyageDisplayName: null,
        voyageDeviceLabel: null,
        voyageAutoFollowHost: true,
        clearVoyageServerUrl: voyageServerUrl.isEmpty,
        clearVoyageDisplayName: true,
        clearVoyageDeviceLabel: true,
      ),
    );
  }

  Future<void> _openLastFmApiPage() async {
    final uri = Uri.parse('https://www.last.fm/api/accounts');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _toUserMessage(Object error, AppLocalizations l10n) {
    return switch (error) {
      SubsonicAuthException() => l10n.loginErrorAuthentication,
      SubsonicConnectionException() => l10n.loginErrorConnection,
      SubsonicApiException(:final message) => message,
      _ => l10n.loginErrorUnknown,
    };
  }
}

enum _SignOutAction { keepData, wipeData }

// ─────────────────────────────────────────────────────────────────────────────
// Shared internal widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ServerInfoRow extends StatelessWidget {
  const _ServerInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$label: ',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _ListenTogetherCard extends StatelessWidget {
  const _ListenTogetherCard({
    required this.enabled,
    required this.bundledServers,
    required this.selectedServerUrl,
    required this.voyageServerUrlController,
    required this.connectionStatus,
    required this.onEnabledChanged,
    required this.onServerSelected,
    required this.onManualServerChanged,
  });

  final bool enabled;
  final List<GroupListeningVoyageServerOption> bundledServers;
  final String? selectedServerUrl;
  final TextEditingController voyageServerUrlController;
  final GroupListeningVoyageConnectionStatus connectionStatus;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<String?> onServerSelected;
  final ValueChanged<String> onManualServerChanged;

  String get _enableSubtitle {
    if (enabled) {
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
    return Card(
      child: Column(
        children: <Widget>[
          SwitchListTile(
            key: const ValueKey('groupListeningEnabledSwitch'),
            secondary: const Icon(Icons.headset_mic_outlined),
            title: const Text('Enable Listen Together'),
            subtitle: Text(_enableSubtitle),
            value: enabled,
            onChanged: onEnabledChanged,
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
                onChanged: onServerSelected,
              ),
            ),
          if (bundledServers.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: TextField(
                key: const ValueKey('groupListeningVoyageServerUrlField'),
                controller: voyageServerUrlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Voyage server URL',
                  hintText: 'https://voyage.example.com',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.link),
                ),
                onChanged: onManualServerChanged,
              ),
            ),
        ],
      ),
    );
  }
}

class _VoyageConnectionStatusCard extends StatelessWidget {
  const _VoyageConnectionStatusCard({required this.status});

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

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
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
                if (status.userActionMessage != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    status.userActionMessage!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: foreground),
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

// ─────────────────────────────────────────────────────────────────────────────
// Last.fm card
// ─────────────────────────────────────────────────────────────────────────────

class _LastFmCard extends StatelessWidget {
  const _LastFmCard({
    required this.isBundled,
    required this.isSaving,
    required this.obscureApiKey,
    required this.controller,
    required this.onToggleObscure,
    required this.onSave,
    required this.onClear,
    required this.onGetApiKey,
  });

  final bool isBundled;
  final bool isSaving;
  final bool obscureApiKey;
  final TextEditingController controller;
  final VoidCallback onToggleObscure;
  final VoidCallback onSave;
  final VoidCallback onClear;
  final VoidCallback onGetApiKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.music_note_outlined, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  l10n.configurationLastFmSection,
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (isBundled) ...<Widget>[
              // ── Bundled key notice ──────────────────────────────────
              Container(
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.verified_outlined,
                      size: 20,
                      color: cs.onSecondaryContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            l10n.configurationLastFmBundledNotice,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: cs.onSecondaryContainer,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.configurationLastFmBundledSubtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSecondaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...<Widget>[
              // ── User-provided key field ─────────────────────────────
              TextField(
                controller: controller,
                obscureText: obscureApiKey,
                decoration: InputDecoration(
                  labelText: l10n.configurationLastFmApiKeyLabel,
                  hintText: l10n.configurationLastFmApiKeyHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        icon: Icon(
                          obscureApiKey
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        tooltip: obscureApiKey ? 'Show' : 'Hide',
                        onPressed: onToggleObscure,
                      ),
                      if (controller.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Clear',
                          onPressed: onClear,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  // Get API Key link
                  TextButton.icon(
                    onPressed: onGetApiKey,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(l10n.configurationLastFmGetApiKey),
                  ),
                  const Spacer(),
                  // Save button
                  FilledButton.tonal(
                    onPressed: isSaving ? null : onSave,
                    child: isSaving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.serverSettingsSave),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
