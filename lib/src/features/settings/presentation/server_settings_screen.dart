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
  bool _lastFmKeyInitialized = false;
  bool _obscureApiKey = true;

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
    super.dispose();
  }

  void _initLastFmKey(AppSettingsModel settings) {
    if (_lastFmKeyInitialized) return;
    _lastFmKeyInitialized = true;
    _lastFmApiKeyController.text = settings.lastFmApiKey ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final configAsync = ref.watch(serverConfigStateProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final isBundled = ref.watch(lastFmBundledKeyProvider);
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

          settingsAsync.whenData(_initLastFmKey);

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
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.loginTestConnectionSuccess(result.apiVersion)),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_toUserMessage(error, l10n))),
      );
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
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wipeLocalData
                ? l10n.serverSettingsSignOutWipeSuccess
                : l10n.serverSettingsSignOutSuccess,
          ),
        ),
      );
      context.go('/login');
    } on Object {
      if (!mounted) return;
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.serverSettingsSignOutError)),
      );
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
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            key.isEmpty
                ? l10n.configurationLastFmApiKeyCleared
                : l10n.configurationLastFmApiKeySaved,
          ),
        ),
      );
    } on Object {
      if (!mounted) return;
      AppNoticeMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.serverSettingsSaveError)),
      );
    } finally {
      if (mounted) setState(() => _isSavingApiKey = false);
    }
  }

  Future<void> _clearLastFmKey() async {
    _lastFmApiKeyController.clear();
    await _saveLastFmKey();
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
