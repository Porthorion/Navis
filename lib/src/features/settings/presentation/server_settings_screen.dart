import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
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
  bool _isListenBrainzBusy = false;

  final _lastFmApiKeyController = TextEditingController();
  final _listenBrainzTokenController = TextEditingController();
  bool _lastFmKeyInitialized = false;
  bool _externalCredentialsHydrated = false;
  bool _obscureApiKey = true;
  bool _obscureListenBrainzToken = true;
  String? _lastFmApiKeyError;
  String? _lastFmApiKeySuccess;
  String? _listenBrainzError;
  String? _listenBrainzSuccess;

  bool get _isBusy => _isTestingConnection || _isSigningOut;

  @override
  void initState() {
    super.initState();
    _lastFmApiKeyController.addListener(_onApiKeyTextChanged);
    _listenBrainzTokenController.addListener(_onApiKeyTextChanged);
  }

  void _onApiKeyTextChanged() {
    // Triggers rebuild so the clear icon in _LastFmCard stays in sync.
    setState(() {});
  }

  @override
  void dispose() {
    _lastFmApiKeyController.removeListener(_onApiKeyTextChanged);
    _listenBrainzTokenController.removeListener(_onApiKeyTextChanged);
    _lastFmApiKeyController.dispose();
    _listenBrainzTokenController.dispose();
    super.dispose();
  }

  void _initLastFmKey(AppSettingsModel settings) {
    if (_lastFmKeyInitialized) return;
    _lastFmKeyInitialized = true;
    _lastFmApiKeyController.text = settings.lastFmApiKey ?? '';
    if ((settings.lastFmApiKey ?? '').trim().isNotEmpty) {
      _lastFmApiKeySuccess = 'Last.fm API key saved.';
    }
  }

  Future<void> _hydrateExternalCredentials(AppSettingsModel settings) async {
    if (_externalCredentialsHydrated) return;
    _externalCredentialsHydrated = true;
    final store = ref.read(externalScrobbleCredentialStoreProvider);
    final listenBrainzToken = await store.readListenBrainzToken() ?? '';
    if (!mounted) return;
    _listenBrainzTokenController.text = listenBrainzToken;
    setState(() {
      if (settings.listenBrainzTokenValid) {
        _listenBrainzSuccess = 'ListenBrainz token validated.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final configAsync = ref.watch(serverConfigStateProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final isBundled = ref.watch(lastFmBundledKeyProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final sectionGap = desktopMode
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(),
          )
        : const SizedBox(height: 12);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !desktopMode,
        leading: desktopMode
            ? IconButton(
                tooltip: l10n.syncSettingsBackToSettings,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => NavService.returnToSettings(context, ref),
              )
            : null,
        title: Text(l10n.serverSettingsTitle),
      ),
      body: Theme(
        data: desktopMode
            ? theme.copyWith(
                cardTheme: const CardThemeData(
                  color: Colors.transparent,
                  elevation: 0,
                  margin: EdgeInsets.zero,
                  shadowColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(),
                ),
              )
            : theme,
        child: configAsync.when(
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
              unawaited(_hydrateExternalCredentials(settings));
            });
            final currentSettings =
                settingsAsync.asData?.value ??
                const AppSettingsModel.defaults();
            final testConnectionAction = FilledButton.tonal(
              onPressed: _isBusy ? null : () => _testConnection(config),
              child: _isTestingConnection
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.serverSettingsTestConnection),
            );
            final signOutAction = FilledButton(
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
            );

            return SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      desktopMode ? 24 : 16,
                      desktopMode ? 24 : 16,
                      desktopMode ? 24 : 16,
                      16,
                    ),
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
                        sectionGap,

                        if (desktopMode) ...<Widget>[
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: <Widget>[
                              testConnectionAction,
                              signOutAction,
                            ],
                          ),
                          const SizedBox(height: 20),
                        ] else ...<Widget>[
                          testConnectionAction,
                          sectionGap,
                          signOutAction,
                          const SizedBox(height: 32),
                        ],

                        // ── External Services section ──────────────────────────
                        _SectionHeader(
                          title: l10n.configurationExternalServicesSection,
                        ),
                        const SizedBox(height: 8),

                        // Last.fm card
                        _LastFmCard(
                          settings: currentSettings,
                          isBundled: isBundled,
                          isSaving: _isSavingApiKey,
                          obscureApiKey: _obscureApiKey,
                          controller: _lastFmApiKeyController,
                          apiKeyError: _lastFmApiKeyError,
                          apiKeySuccess: _lastFmApiKeySuccess,
                          onToggleObscure: () =>
                              setState(() => _obscureApiKey = !_obscureApiKey),
                          onSave: _saveLastFmKey,
                          onClear: _clearLastFmKey,
                          onGetApiKey: _openLastFmApiPage,
                        ),
                        sectionGap,
                        _ListenBrainzCard(
                          settings: currentSettings,
                          isBusy: _isListenBrainzBusy,
                          obscureToken: _obscureListenBrainzToken,
                          controller: _listenBrainzTokenController,
                          errorText: _listenBrainzError,
                          successText: _listenBrainzSuccess,
                          onToggleObscure: () => setState(
                            () => _obscureListenBrainzToken =
                                !_obscureListenBrainzToken,
                          ),
                          onValidate: () =>
                              _validateListenBrainz(currentSettings),
                          onClear: () => _clearListenBrainz(currentSettings),
                          onOpenTokenSettings: _openListenBrainzTokenPage,
                          onEnabledChanged: (value) =>
                              _setListenBrainzEnabled(currentSettings, value),
                        ),
                      ],
                    ),
                  ),
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
      showAppNotice(
        context,
        message: l10n.loginTestConnectionSuccess(result.apiVersion),
        level: AppNoticeLevel.success,
      );
    } on Object catch (error) {
      if (!mounted) return;
      showAppNotice(
        context,
        message: _toUserMessage(error, l10n),
        level: AppNoticeLevel.error,
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
      showAppNotice(
        context,
        message: l10n.serverSettingsSignOutError,
        level: AppNoticeLevel.error,
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
      if (key.isNotEmpty) {
        final result = await ref
            .read(lastFmApiClientFactoryProvider)(key)
            .validateApiKey();
        if (!result.valid) {
          if (!mounted) return;
          setState(() {
            _lastFmApiKeyError = _lastFmApiKeyFailureMessage(result);
            _lastFmApiKeySuccess = null;
          });
          return;
        }
      }
      if (key.isEmpty) {
        _lastFmApiKeySuccess = null;
      }
      await repo.saveSettings(
        current.copyWith(
          lastFmApiKey: key.isEmpty ? null : key,
          clearLastFmApiKey: key.isEmpty,
          lastFmScrobblingEnabled: false,
          lastFmSessionConnected: false,
        ),
      );
      if (!mounted) return;
      setState(() {
        _lastFmApiKeyError = null;
        _lastFmApiKeySuccess = key.isEmpty
            ? null
            : l10n.configurationLastFmApiKeySaved;
      });
      showAppNotice(
        context,
        message: key.isEmpty
            ? l10n.configurationLastFmApiKeyCleared
            : l10n.configurationLastFmApiKeySaved,
        level: AppNoticeLevel.success,
      );
    } on Object {
      if (!mounted) return;
      showAppNotice(
        context,
        message: l10n.serverSettingsSaveError,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) setState(() => _isSavingApiKey = false);
    }
  }

  Future<void> _clearLastFmKey() async {
    _lastFmApiKeyController.clear();
    await _saveLastFmKey();
  }

  Future<void> _validateListenBrainz(AppSettingsModel settings) async {
    final token = _listenBrainzTokenController.text.trim();
    if (token.isEmpty) {
      setState(() {
        _listenBrainzError = 'Enter a ListenBrainz user token.';
        _listenBrainzSuccess = null;
      });
      return;
    }
    setState(() {
      _isListenBrainzBusy = true;
      _listenBrainzError = null;
      _listenBrainzSuccess = null;
    });
    try {
      final details = await ref
          .read(listenBrainzApiClientProvider)
          .validateTokenDetails(token);
      if (!details.valid) {
        await ref
            .read(externalScrobbleCredentialStoreProvider)
            .clearListenBrainzToken();
        await ref
            .read(settingsRepositoryProvider)
            .saveSettings(
              settings.copyWith(
                listenBrainzTokenValid: false,
                listenBrainzScrobblingEnabled: false,
                clearListenBrainzUserName: true,
              ),
            );
        if (!mounted) return;
        setState(() {
          _listenBrainzError = 'Invalid ListenBrainz token.';
          _listenBrainzSuccess = null;
        });
        return;
      }
      await ref
          .read(externalScrobbleCredentialStoreProvider)
          .saveListenBrainzToken(token);
      await ref
          .read(settingsRepositoryProvider)
          .saveSettings(
            settings.copyWith(
              listenBrainzTokenValid: true,
              listenBrainzScrobblingEnabled: true,
              listenBrainzUserName: details.userName,
            ),
          );
      if (!mounted) return;
      ref
          .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
          .refreshAfterTokenValidation();
      setState(() {
        _listenBrainzError = null;
        _listenBrainzSuccess = 'ListenBrainz token validated.';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _listenBrainzError =
            'ListenBrainz is unavailable. Check your connection and try again.';
        _listenBrainzSuccess = null;
      });
    } finally {
      if (mounted) setState(() => _isListenBrainzBusy = false);
    }
  }

  Future<void> _setListenBrainzEnabled(
    AppSettingsModel settings,
    bool enabled,
  ) async {
    if (!settings.listenBrainzTokenValid) return;
    await ref
        .read(settingsRepositoryProvider)
        .saveSettings(
          settings.copyWith(listenBrainzScrobblingEnabled: enabled),
        );
  }

  Future<void> _clearListenBrainz(AppSettingsModel settings) async {
    _listenBrainzTokenController.clear();
    await ref
        .read(externalScrobbleCredentialStoreProvider)
        .clearListenBrainzToken();
    await ref
        .read(settingsRepositoryProvider)
        .saveSettings(
          settings.copyWith(
            listenBrainzTokenValid: false,
            listenBrainzScrobblingEnabled: false,
            clearListenBrainzUserName: true,
          ),
        );
    if (!mounted) return;
    setState(() {
      _listenBrainzError = null;
      _listenBrainzSuccess = null;
    });
  }

  Future<void> _openLastFmApiPage() async {
    final uri = Uri.parse('https://www.last.fm/api/accounts');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openListenBrainzTokenPage() async {
    final uri = Uri.parse('https://listenbrainz.org/settings/');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _lastFmApiKeyFailureMessage(LastFmApiKeyValidationResult result) {
    if (result.apiErrorCode == 10 || result.statusCode == 403) {
      return 'Invalid Last.fm API key.';
    }
    if (result.statusCode == 429) {
      return 'Last.fm is rate limiting validation. Try again later.';
    }
    return result.message ?? 'Could not validate this Last.fm API key.';
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
    required this.settings,
    required this.isBundled,
    required this.isSaving,
    required this.obscureApiKey,
    required this.controller,
    required this.apiKeyError,
    required this.apiKeySuccess,
    required this.onToggleObscure,
    required this.onSave,
    required this.onClear,
    required this.onGetApiKey,
  });

  final AppSettingsModel settings;
  final bool isBundled;
  final bool isSaving;
  final bool obscureApiKey;
  final TextEditingController controller;
  final String? apiKeyError;
  final String? apiKeySuccess;
  final VoidCallback onToggleObscure;
  final VoidCallback onSave;
  final VoidCallback onClear;
  final VoidCallback onGetApiKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final apiKeyValid =
        isBundled || (settings.lastFmApiKey?.trim().isNotEmpty ?? false);

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
                Expanded(
                  child: Text(
                    l10n.configurationLastFmSection,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (apiKeyValid)
                  Icon(Icons.check_circle, color: Colors.green.shade700),
              ],
            ),
            const SizedBox(height: 12),

            if (isBundled) ...<Widget>[
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
              TextField(
                controller: controller,
                obscureText: obscureApiKey,
                decoration: InputDecoration(
                  labelText: l10n.configurationLastFmApiKeyLabel,
                  hintText: l10n.configurationLastFmApiKeyHint,
                  border: const OutlineInputBorder(),
                  enabledBorder: apiKeySuccess != null && apiKeyError == null
                      ? OutlineInputBorder(
                          borderSide: BorderSide(
                            color: Colors.green.shade700,
                          ),
                        )
                      : null,
                  errorText: apiKeyError,
                  helperText: apiKeyError == null ? apiKeySuccess : null,
                  helperStyle: TextStyle(color: Colors.green.shade700),
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
                  TextButton.icon(
                    onPressed: onGetApiKey,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(l10n.configurationLastFmGetApiKey),
                  ),
                  const Spacer(),
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

class _ListenBrainzCard extends StatelessWidget {
  const _ListenBrainzCard({
    required this.settings,
    required this.isBusy,
    required this.obscureToken,
    required this.controller,
    required this.errorText,
    required this.successText,
    required this.onToggleObscure,
    required this.onValidate,
    required this.onClear,
    required this.onOpenTokenSettings,
    required this.onEnabledChanged,
  });

  final AppSettingsModel settings;
  final bool isBusy;
  final bool obscureToken;
  final TextEditingController controller;
  final String? errorText;
  final String? successText;
  final VoidCallback onToggleObscure;
  final VoidCallback onValidate;
  final VoidCallback onClear;
  final VoidCallback onOpenTokenSettings;
  final ValueChanged<bool> onEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valid = settings.listenBrainzTokenValid;
    final enabled = settings.listenBrainzScrobblingEnabled && valid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.hearing_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ListenBrainz',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (valid)
                  Icon(Icons.check_circle, color: Colors.green.shade700),
                Switch(
                  value: enabled,
                  onChanged: valid && !isBusy ? onEnabledChanged : null,
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: obscureToken,
              decoration: InputDecoration(
                labelText: 'User token',
                border: const OutlineInputBorder(),
                enabledBorder: successText != null && errorText == null
                    ? OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.green.shade700),
                      )
                    : null,
                errorText: errorText,
                helperText: errorText == null ? successText : null,
                helperStyle: TextStyle(color: Colors.green.shade700),
                prefixIcon: const Icon(Icons.token_outlined),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      icon: Icon(
                        obscureToken
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      tooltip: obscureToken ? 'Show' : 'Hide',
                      onPressed: onToggleObscure,
                    ),
                    if (controller.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear',
                        onPressed: onClear,
                        icon: const Icon(Icons.clear),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: isBusy ? null : onValidate,
                  icon: isBusy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified_outlined),
                  label: const Text('Validate and save'),
                ),
                TextButton.icon(
                  onPressed: onOpenTokenSettings,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Get Token'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
