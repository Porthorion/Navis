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
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart'
    show
        buildGroupListeningClientConfiguration,
        isVoyageTransportAllowed,
        normalizeVoyageBaseUri;
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
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

class _ServerSettingsScreenState extends ConsumerState<ServerSettingsScreen>
    with WidgetsBindingObserver {
  static const _lastFmAuthTimeout = Duration(minutes: 10);
  static const _lastFmFastPollWindow = Duration(seconds: 30);
  static const _lastFmFastPollInterval = Duration(seconds: 2);
  static const _lastFmSlowPollInterval = Duration(seconds: 5);

  bool _isTestingConnection = false;
  bool _isSigningOut = false;
  bool _isSavingApiKey = false;
  bool _isLastFmAuthBusy = false;
  bool _isLastFmAuthPolling = false;
  bool _isListenBrainzBusy = false;
  bool _isVoyageChecking = false;

  final _lastFmApiKeyController = TextEditingController();
  final _lastFmSecretController = TextEditingController();
  final _listenBrainzTokenController = TextEditingController();
  final _voyageServerUrlController = TextEditingController();
  final _customVoyageLabelController = TextEditingController();
  final _customVoyageUrlController = TextEditingController();
  bool _lastFmKeyInitialized = false;
  bool _externalCredentialsHydrated = false;
  bool _groupListeningInitialized = false;
  bool _obscureApiKey = true;
  bool _obscureLastFmSecret = true;
  bool _obscureListenBrainzToken = true;
  bool _groupListeningEnabled = false;
  String? _selectedVoyageServerUrl;
  String? _lastFmAuthToken;
  String? _lastFmAuthApiKey;
  String? _lastFmAuthSharedSecret;
  DateTime? _lastFmAuthStartedAt;
  DateTime? _lastFmAuthExpiresAt;
  Timer? _lastFmAuthPollTimer;
  Timer? _lastFmAuthTimeoutTimer;
  String? _lastFmApiKeyError;
  String? _lastFmApiKeySuccess;
  String? _lastFmScrobbleError;
  String? _lastFmScrobbleSuccess;
  String? _listenBrainzError;
  String? _listenBrainzSuccess;
  GroupListeningVoyageConnectionStatus _voyageStatus =
      const GroupListeningVoyageConnectionStatus(
        state: GroupListeningVoyageConnectionState.disabled,
        message: 'Listen Together is off.',
      );

  bool get _isBusy => _isTestingConnection || _isSigningOut;
  bool get _isLastFmAuthPending =>
      _lastFmAuthToken != null && _lastFmAuthExpiresAt != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastFmApiKeyController.addListener(_onApiKeyTextChanged);
    _listenBrainzTokenController.addListener(_onApiKeyTextChanged);
  }

  void _onApiKeyTextChanged() {
    // Triggers rebuild so the clear icon in _LastFmCard stays in sync.
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lastFmAuthPollTimer?.cancel();
    _lastFmAuthTimeoutTimer?.cancel();
    _lastFmApiKeyController.removeListener(_onApiKeyTextChanged);
    _listenBrainzTokenController.removeListener(_onApiKeyTextChanged);
    _lastFmApiKeyController.dispose();
    _lastFmSecretController.dispose();
    _listenBrainzTokenController.dispose();
    _voyageServerUrlController.dispose();
    _customVoyageLabelController.dispose();
    _customVoyageUrlController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isLastFmAuthPending) {
      unawaited(_pollLastFmAuth());
    }
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
    final lastFmSharedSecret = await store.readLastFmSharedSecret() ?? '';
    final listenBrainzToken = await store.readListenBrainzToken() ?? '';
    if (!mounted) return;
    _lastFmSecretController.text = lastFmSharedSecret;
    _listenBrainzTokenController.text = listenBrainzToken;
    setState(() {
      if (settings.lastFmSessionConnected) {
        _lastFmScrobbleSuccess = 'Last.fm scrobbling connected.';
      }
      if (settings.listenBrainzTokenValid) {
        _listenBrainzSuccess = 'ListenBrainz token validated.';
      }
    });
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
    _voyageStatus = _statusForVoyageUrl(
      enabled: _groupListeningEnabled,
      voyageServerUrl: initialServerUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final configAsync = ref.watch(serverConfigStateProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final isBundled = ref.watch(lastFmBundledKeyProvider);
    final voyageServers = ref.watch(
      groupListeningVoyageServersProvider,
    );
    final resolvedVoyageServerUrl = ref.watch(
      groupListeningResolvedVoyageServerUrlProvider,
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
            unawaited(_hydrateExternalCredentials(settings));
            _initGroupListeningSettings(
              settings,
              resolvedVoyageServerUrl: resolvedVoyageServerUrl,
            );
          });
          final currentSettings =
              settingsAsync.asData?.value ?? const AppSettingsModel.defaults();
          final selectedVoyageServerUrl =
              _selectedVoyageServerUrl ??
              (voyageServers.isEmpty ? null : voyageServers.first.url);
          if (voyageServers.isNotEmpty &&
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
                    settings: currentSettings,
                    isBundled: isBundled,
                    isSaving: _isSavingApiKey,
                    isAuthBusy: _isLastFmAuthBusy,
                    isAuthPending: _isLastFmAuthPending,
                    obscureApiKey: _obscureApiKey,
                    obscureSharedSecret: _obscureLastFmSecret,
                    controller: _lastFmApiKeyController,
                    sharedSecretController: _lastFmSecretController,
                    apiKeyError: _lastFmApiKeyError,
                    apiKeySuccess: _lastFmApiKeySuccess,
                    scrobbleError: _lastFmScrobbleError,
                    scrobbleSuccess: _lastFmScrobbleSuccess,
                    onToggleObscure: () =>
                        setState(() => _obscureApiKey = !_obscureApiKey),
                    onToggleSharedSecretObscure: () => setState(
                      () => _obscureLastFmSecret = !_obscureLastFmSecret,
                    ),
                    onSave: _saveLastFmKey,
                    onClear: _clearLastFmKey,
                    onGetApiKey: _openLastFmApiPage,
                    onStartAuth: _startLastFmAuth,
                    onCancelAuth: _cancelLastFmAuth,
                    onDisconnectScrobbling: () =>
                        _disconnectLastFm(currentSettings),
                  ),
                  const SizedBox(height: 12),
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
                    onValidate: () => _validateListenBrainz(currentSettings),
                    onClear: () => _clearListenBrainz(currentSettings),
                    onOpenTokenSettings: _openListenBrainzTokenPage,
                    onEnabledChanged: (value) =>
                        _setListenBrainzEnabled(currentSettings, value),
                  ),
                  const SizedBox(height: 32),

                  // ── Listen Together section ─────────────────────────
                  const _SectionHeader(title: 'Listen Together'),
                  const SizedBox(height: 8),
                  _ListenTogetherCard(
                    enabled: _groupListeningEnabled,
                    bundledServers: voyageServers,
                    customServers:
                        settingsAsync.asData?.value.customVoyageServers ??
                        const <CustomVoyageServer>[],
                    selectedServerUrl: selectedVoyageServerUrl,
                    voyageServerUrlController: _voyageServerUrlController,
                    customVoyageLabelController: _customVoyageLabelController,
                    customVoyageUrlController: _customVoyageUrlController,
                    connectionStatus: _voyageStatus,
                    isChecking: _isVoyageChecking,
                    onEnabledChanged: (value) {
                      setState(() {
                        _groupListeningEnabled = value;
                        if (value &&
                            voyageServers.isNotEmpty &&
                            (_selectedVoyageServerUrl == null ||
                                _selectedVoyageServerUrl!.isEmpty)) {
                          _selectedVoyageServerUrl = voyageServers.first.url;
                          _voyageServerUrlController.text =
                              voyageServers.first.url;
                        }
                      });
                      unawaited(
                        _checkAndSaveGroupListeningSettings(
                          config: config,
                          voyageServers: voyageServers,
                        ),
                      );
                    },
                    onServerSelected: (value) {
                      if (value == null) return;
                      setState(() {
                        _selectedVoyageServerUrl = value;
                        _voyageServerUrlController.text = value;
                      });
                      unawaited(
                        _checkAndSaveGroupListeningSettings(
                          config: config,
                          voyageServers: voyageServers,
                        ),
                      );
                    },
                    onManualServerChanged: (_) => setState(() {
                      _voyageStatus = _statusForVoyageUrl(
                        enabled: _groupListeningEnabled,
                        voyageServerUrl: _voyageServerUrlController.text,
                      );
                    }),
                    onManualServerSubmitted: (_) =>
                        _checkAndSaveGroupListeningSettings(
                          config: config,
                          voyageServers: voyageServers,
                        ),
                    onTestServer: () => _checkAndSaveGroupListeningSettings(
                      config: config,
                      voyageServers: voyageServers,
                    ),
                    onAddCustomServer: () => _addCustomVoyageServer(config),
                    onDeleteCustomServer: _deleteCustomVoyageServer,
                  ),
                  const SizedBox(height: 12),
                  _VoyageConnectionStatusCard(status: _voyageStatus),
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
        final store = ref.read(externalScrobbleCredentialStoreProvider);
        await store.clearLastFmSharedSecret();
        await store.clearLastFmSessionKey();
        _lastFmSecretController.clear();
        _clearLastFmAuthState();
      }
      await repo.saveSettings(
        current.copyWith(
          lastFmApiKey: key.isEmpty ? null : key,
          clearLastFmApiKey: key.isEmpty,
          lastFmScrobblingEnabled:
              key.isNotEmpty && current.lastFmScrobblingEnabled,
          lastFmSessionConnected:
              key.isNotEmpty && current.lastFmSessionConnected,
        ),
      );
      if (!mounted) return;
      setState(() {
        _lastFmApiKeyError = null;
        _lastFmApiKeySuccess = key.isEmpty
            ? null
            : l10n.configurationLastFmApiKeySaved;
        if (key.isEmpty) {
          _lastFmScrobbleError = null;
          _lastFmScrobbleSuccess = null;
        }
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

  Future<void> _startLastFmAuth() async {
    final apiKey = _effectiveLastFmApiKey();
    final secret = _lastFmSecretController.text.trim();
    if (apiKey.isEmpty) {
      setState(() {
        _lastFmApiKeyError = 'Enter a Last.fm API key.';
        _lastFmApiKeySuccess = null;
        _lastFmScrobbleError = null;
        _lastFmScrobbleSuccess = null;
      });
      return;
    }
    if (secret.isEmpty) {
      setState(() {
        _lastFmScrobbleError = 'Enter your Last.fm shared secret.';
        _lastFmScrobbleSuccess = null;
      });
      return;
    }
    setState(() {
      _isLastFmAuthBusy = true;
      _lastFmApiKeyError = null;
      _lastFmScrobbleError = null;
      _lastFmScrobbleSuccess = null;
    });
    try {
      final client = ref.read(lastFmApiClientFactoryProvider)(apiKey);
      if (!ref.read(lastFmBundledKeyProvider)) {
        final validation = await client.validateApiKey();
        if (!validation.valid) {
          if (!mounted) return;
          setState(() {
            _lastFmApiKeyError = _lastFmApiKeyFailureMessage(validation);
            _lastFmApiKeySuccess = null;
          });
          return;
        }
      }
      final token = await client.getAuthToken(sharedSecret: secret);
      if (token.trim().isEmpty) {
        throw const LastFmApiException(null, 'Last.fm auth token missing');
      }
      await ref
          .read(externalScrobbleCredentialStoreProvider)
          .saveLastFmSharedSecret(secret);
      final launched = await launchUrl(
        client.authorizationUrl(token),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw const LastFmApiException(
          null,
          'Could not open Last.fm authorization.',
        );
      }
      if (!mounted) return;
      _beginLastFmPendingAuth(
        token: token,
        apiKey: apiKey,
        sharedSecret: secret,
      );
      unawaited(_pollLastFmAuth());
    } on LastFmApiException catch (error) {
      if (!mounted) return;
      setState(() {
        if (error.code == 10) {
          _lastFmApiKeyError = 'Invalid Last.fm API key.';
          _lastFmApiKeySuccess = null;
          _lastFmScrobbleError = null;
        } else if (error.code == 13) {
          _lastFmScrobbleError = 'Invalid Last.fm shared secret.';
        } else {
          _lastFmScrobbleError = _lastFmAuthErrorMessage(error);
        }
        _lastFmScrobbleSuccess = null;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _lastFmScrobbleError =
            'Could not start Last.fm authorization. Check your connection.';
        _lastFmScrobbleSuccess = null;
      });
    } finally {
      if (mounted) setState(() => _isLastFmAuthBusy = false);
    }
  }

  void _beginLastFmPendingAuth({
    required String token,
    required String apiKey,
    required String sharedSecret,
  }) {
    _lastFmAuthPollTimer?.cancel();
    _lastFmAuthTimeoutTimer?.cancel();
    final now = DateTime.now();
    setState(() {
      _lastFmAuthToken = token;
      _lastFmAuthApiKey = apiKey;
      _lastFmAuthSharedSecret = sharedSecret;
      _lastFmAuthStartedAt = now;
      _lastFmAuthExpiresAt = now.add(_lastFmAuthTimeout);
      _lastFmScrobbleError = null;
      _lastFmScrobbleSuccess = null;
    });
    _lastFmAuthTimeoutTimer = Timer(_lastFmAuthTimeout, _timeoutLastFmAuth);
  }

  Future<void> _pollLastFmAuth() async {
    final token = _lastFmAuthToken;
    final apiKey = _lastFmAuthApiKey;
    final secret = _lastFmAuthSharedSecret;
    if (token == null ||
        apiKey == null ||
        secret == null ||
        apiKey.isEmpty ||
        secret.isEmpty) {
      setState(() {
        _lastFmScrobbleError = 'Last.fm authorization is incomplete.';
        _lastFmScrobbleSuccess = null;
      });
      return;
    }
    if (_isLastFmAuthPolling) return;
    _lastFmAuthPollTimer?.cancel();
    setState(() {
      _isLastFmAuthPolling = true;
      if (!_hasRetryableLastFmAuthMessage(_lastFmScrobbleError)) {
        _lastFmScrobbleError = null;
      }
    });
    try {
      final session = await ref
          .read(lastFmApiClientFactoryProvider)(apiKey)
          .getSession(token: token, sharedSecret: secret);
      await ref
          .read(externalScrobbleCredentialStoreProvider)
          .saveLastFmSessionKey(session.key);
      final current =
          ref.read(appSettingsProvider).asData?.value ??
          const AppSettingsModel.defaults();
      await ref
          .read(settingsRepositoryProvider)
          .saveSettings(
            current.copyWith(
              lastFmApiKey: ref.read(lastFmBundledKeyProvider)
                  ? current.lastFmApiKey
                  : apiKey,
              lastFmSessionConnected: true,
              lastFmScrobblingEnabled: true,
            ),
          );
      if (!mounted) return;
      _lastFmAuthPollTimer?.cancel();
      _lastFmAuthTimeoutTimer?.cancel();
      setState(() {
        _clearLastFmAuthState(cancelTimers: false);
        _isLastFmAuthPolling = false;
        _lastFmScrobbleError = null;
        _lastFmScrobbleSuccess = 'Last.fm scrobbling connected.';
      });
    } on LastFmApiException catch (error) {
      if (!mounted) return;
      if (_isLastFmAuthorizationPendingError(error)) {
        setState(() {
          _isLastFmAuthPolling = false;
          _lastFmScrobbleError = null;
          _lastFmScrobbleSuccess = null;
        });
        _scheduleNextLastFmPoll();
        return;
      }
      _lastFmAuthPollTimer?.cancel();
      _lastFmAuthTimeoutTimer?.cancel();
      setState(() {
        _clearLastFmAuthState(cancelTimers: false);
        _isLastFmAuthPolling = false;
        if (error.code == 10) {
          _lastFmApiKeyError = 'Invalid Last.fm API key.';
          _lastFmApiKeySuccess = null;
          _lastFmScrobbleError = null;
        } else if (error.code == 13) {
          _lastFmScrobbleError = 'Invalid Last.fm shared secret.';
        } else {
          _lastFmScrobbleError = _lastFmAuthErrorMessage(error);
        }
        _lastFmScrobbleSuccess = null;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _isLastFmAuthPolling = false;
        _lastFmScrobbleError =
            'Last.fm is unavailable. Still waiting for approval...';
        _lastFmScrobbleSuccess = null;
      });
      _scheduleNextLastFmPoll();
    }
  }

  void _scheduleNextLastFmPoll() {
    if (!_isLastFmAuthPending) return;
    final startedAt = _lastFmAuthStartedAt;
    final elapsed = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
    final interval = elapsed < _lastFmFastPollWindow
        ? _lastFmFastPollInterval
        : _lastFmSlowPollInterval;
    _lastFmAuthPollTimer?.cancel();
    _lastFmAuthPollTimer = Timer(interval, () => unawaited(_pollLastFmAuth()));
  }

  void _timeoutLastFmAuth() {
    if (!_isLastFmAuthPending || !mounted) return;
    _lastFmAuthPollTimer?.cancel();
    setState(() {
      _clearLastFmAuthState(cancelTimers: false);
      _isLastFmAuthBusy = false;
      _isLastFmAuthPolling = false;
      _lastFmScrobbleError = 'Last.fm authorization timed out. Try again.';
      _lastFmScrobbleSuccess = null;
    });
  }

  void _cancelLastFmAuth() {
    setState(() {
      _clearLastFmAuthState();
      _isLastFmAuthBusy = false;
      _isLastFmAuthPolling = false;
      _lastFmScrobbleError = null;
      _lastFmScrobbleSuccess = null;
    });
  }

  void _clearLastFmAuthState({bool cancelTimers = true}) {
    if (cancelTimers) {
      _lastFmAuthPollTimer?.cancel();
      _lastFmAuthTimeoutTimer?.cancel();
    }
    _lastFmAuthToken = null;
    _lastFmAuthApiKey = null;
    _lastFmAuthSharedSecret = null;
    _lastFmAuthStartedAt = null;
    _lastFmAuthExpiresAt = null;
  }

  Future<void> _disconnectLastFm(AppSettingsModel settings) async {
    final store = ref.read(externalScrobbleCredentialStoreProvider);
    await store.clearLastFmSessionKey();
    await ref
        .read(settingsRepositoryProvider)
        .saveSettings(
          settings.copyWith(
            lastFmScrobblingEnabled: false,
            lastFmSessionConnected: false,
          ),
        );
    if (!mounted) return;
    setState(() {
      _clearLastFmAuthState();
      _lastFmScrobbleError = null;
      _lastFmScrobbleSuccess = null;
    });
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
      final valid = await ref
          .read(listenBrainzApiClientProvider)
          .validateToken(token);
      if (!valid) {
        await ref
            .read(externalScrobbleCredentialStoreProvider)
            .clearListenBrainzToken();
        await ref
            .read(settingsRepositoryProvider)
            .saveSettings(
              settings.copyWith(
                listenBrainzTokenValid: false,
                listenBrainzScrobblingEnabled: false,
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
            ),
          );
      if (!mounted) return;
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
          ),
        );
    if (!mounted) return;
    setState(() {
      _listenBrainzError = null;
      _listenBrainzSuccess = null;
    });
  }

  Future<void> _checkAndSaveGroupListeningSettings({
    required ServerConfigModel config,
    required List<GroupListeningVoyageServerOption> voyageServers,
  }) async {
    final voyageServerUrl = _selectedVoyageUrl(voyageServers);
    final initialStatus = _statusForVoyageUrl(
      enabled: _groupListeningEnabled,
      voyageServerUrl: voyageServerUrl,
    );
    setState(() => _voyageStatus = initialStatus);
    if (!_groupListeningEnabled) {
      await _saveGroupListeningSettings(
        voyageServers,
        voyageServerUrl: voyageServerUrl,
      );
      return;
    }
    if (voyageServerUrl == null ||
        initialStatus.state == GroupListeningVoyageConnectionState.failed) {
      return;
    }
    setState(() {
      _isVoyageChecking = true;
      _voyageStatus = GroupListeningVoyageConnectionStatus(
        state: GroupListeningVoyageConnectionState.checking,
        message: 'Checking Voyage connection...',
        userActionMessage: voyageServerUrl,
      );
    });
    try {
      final configuration = buildGroupListeningClientConfiguration(
        enabled: true,
        voyageServerUrl: voyageServerUrl,
        activeServer: config,
      );
      if (configuration == null) {
        throw const FormatException('Invalid Voyage configuration.');
      }
      final discovery = await ref
          .read(groupListeningRepositoryProvider)
          .discover(configuration);
      if (!discovery.supportsCurrentProtocol) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.unsupportedProtocolVersion,
            message: 'Voyage protocol is not compatible.',
          ),
        );
      }
      await _saveGroupListeningSettings(
        voyageServers,
        voyageServerUrl: voyageServerUrl,
      );
      if (!mounted) return;
      setState(() {
        _voyageStatus = const GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.connected,
          message: 'Successfully connected to Voyage.',
        );
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _voyageStatus = GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.failed,
          message: 'Not connected to Voyage.',
          userActionMessage: _voyageFailureMessage(error),
        );
      });
    } finally {
      if (mounted) setState(() => _isVoyageChecking = false);
    }
  }

  Future<void> _saveGroupListeningSettings(
    List<GroupListeningVoyageServerOption> voyageServers, {
    required String? voyageServerUrl,
  }) async {
    final repository = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    final normalizedUrl = voyageServerUrl?.trim() ?? '';

    await repository.saveSettings(
      current.copyWith(
        groupListeningEnabled: _groupListeningEnabled,
        voyageServerUrl: normalizedUrl.isEmpty ? null : normalizedUrl,
        voyageDisplayName: null,
        voyageDeviceLabel: null,
        voyageAutoFollowHost: true,
        clearVoyageServerUrl: normalizedUrl.isEmpty,
        clearVoyageDisplayName: true,
        clearVoyageDeviceLabel: true,
      ),
    );
  }

  Future<void> _addCustomVoyageServer(ServerConfigModel config) async {
    final label = _customVoyageLabelController.text.trim();
    final url = _customVoyageUrlController.text.trim();
    if (url.isEmpty) {
      return;
    }
    final normalizedUri = normalizeVoyageBaseUri(url);
    if (normalizedUri == null || !isVoyageTransportAllowed(normalizedUri)) {
      if (!mounted) {
        return;
      }
      showAppNotice(
        context,
        message: 'Enter a valid http or https Voyage server URL.',
        level: AppNoticeLevel.error,
      );
      return;
    }
    final normalizedUrl = normalizedUri.toString();
    setState(() {
      _isVoyageChecking = true;
      _voyageStatus = GroupListeningVoyageConnectionStatus(
        state: GroupListeningVoyageConnectionState.checking,
        message: 'Checking Voyage connection...',
        userActionMessage: normalizedUrl,
      );
    });
    try {
      final configuration = buildGroupListeningClientConfiguration(
        enabled: true,
        voyageServerUrl: normalizedUrl,
        activeServer: config,
      );
      if (configuration == null) {
        throw const FormatException('Invalid Voyage configuration.');
      }
      final discovery = await ref
          .read(groupListeningRepositoryProvider)
          .discover(configuration);
      if (!discovery.supportsCurrentProtocol) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.unsupportedProtocolVersion,
            message: 'Voyage protocol is not compatible.',
          ),
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _voyageStatus = GroupListeningVoyageConnectionStatus(
          state: GroupListeningVoyageConnectionState.failed,
          message: 'Not connected to Voyage.',
          userActionMessage: _voyageFailureMessage(error),
        );
      });
      return;
    } finally {
      if (mounted) setState(() => _isVoyageChecking = false);
    }
    final repository = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    final existing = current.customVoyageServers
        .where((server) => server.url != normalizedUrl)
        .toList();
    existing.add(
      CustomVoyageServer(
        label: label.isEmpty ? normalizedUrl : label,
        url: normalizedUrl,
      ),
    );
    await repository.saveSettings(
      current.copyWith(customVoyageServers: existing),
    );
    _customVoyageLabelController.clear();
    _customVoyageUrlController.clear();
    setState(() {
      _selectedVoyageServerUrl = normalizedUrl;
      _voyageServerUrlController.text = normalizedUrl;
      _voyageStatus = const GroupListeningVoyageConnectionStatus(
        state: GroupListeningVoyageConnectionState.connected,
        message: 'Successfully connected to Voyage.',
      );
    });
  }

  Future<void> _deleteCustomVoyageServer(CustomVoyageServer server) async {
    final repository = ref.read(settingsRepositoryProvider);
    final current =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    await repository.saveSettings(
      current.copyWith(
        customVoyageServers: current.customVoyageServers
            .where((entry) => entry.url != server.url)
            .toList(),
        clearVoyageServerUrl: current.voyageServerUrl == server.url,
      ),
    );
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

  String _effectiveLastFmApiKey() {
    if (ref.read(lastFmBundledKeyProvider)) {
      return ref.read(lastFmApiKeyProvider).trim();
    }
    return _lastFmApiKeyController.text.trim();
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

  bool _isLastFmAuthorizationPendingError(LastFmApiException error) {
    final message = error.message.toLowerCase();
    return error.code == 14 ||
        message.contains('not authorized') ||
        message.contains('unauthorized token');
  }

  bool _hasRetryableLastFmAuthMessage(String? message) {
    return message?.contains('Still waiting for approval') ?? false;
  }

  String _lastFmAuthErrorMessage(LastFmApiException error) {
    if (error.code == 29) {
      return 'Last.fm is rate limiting authorization. Try again later.';
    }
    if (error.code == 16 || error.code == 11) {
      return 'Last.fm is unavailable. Try again later.';
    }
    return error.message.isEmpty
        ? 'Could not authorize Last.fm scrobbling. Try again later.'
        : error.message;
  }

  String? _selectedVoyageUrl(List<GroupListeningVoyageServerOption> servers) {
    final raw = servers.isEmpty
        ? _voyageServerUrlController.text.trim()
        : (_selectedVoyageServerUrl ??
                  (servers.isEmpty ? null : servers.first.url) ??
                  '')
              .trim();
    return normalizeVoyageBaseUri(raw)?.toString();
  }

  GroupListeningVoyageConnectionStatus _statusForVoyageUrl({
    required bool enabled,
    required String? voyageServerUrl,
  }) {
    if (!enabled) {
      return const GroupListeningVoyageConnectionStatus(
        state: GroupListeningVoyageConnectionState.disabled,
        message: 'Listen Together is off.',
      );
    }
    final uri = normalizeVoyageBaseUri(voyageServerUrl);
    if (uri == null) {
      return const GroupListeningVoyageConnectionStatus(
        state: GroupListeningVoyageConnectionState.unconfigured,
        message: 'Not connected to Voyage.',
        userActionMessage: 'Enter a valid Voyage server URL.',
      );
    }
    if (!isVoyageTransportAllowed(uri)) {
      return const GroupListeningVoyageConnectionStatus(
        state: GroupListeningVoyageConnectionState.failed,
        message: 'Not connected to Voyage.',
        userActionMessage:
            'Use HTTPS for Voyage, or a local HTTP server in debug builds.',
      );
    }
    return GroupListeningVoyageConnectionStatus(
      state: GroupListeningVoyageConnectionState.unconfigured,
      message: 'Voyage server ready to test.',
      userActionMessage: uri.toString(),
    );
  }

  String? _voyageFailureMessage(Object error) {
    final failure = error is GroupListeningRepositoryException
        ? error.failure
        : null;
    if (failure == null) {
      return 'Voyage is unavailable. Check the URL and try again.';
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
      _ =>
        failure.message.isNotEmpty
            ? failure.message
            : 'Voyage is unavailable. Check the URL and try again.',
    };
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
    required this.customServers,
    required this.selectedServerUrl,
    required this.voyageServerUrlController,
    required this.customVoyageLabelController,
    required this.customVoyageUrlController,
    required this.connectionStatus,
    required this.isChecking,
    required this.onEnabledChanged,
    required this.onServerSelected,
    required this.onManualServerChanged,
    required this.onManualServerSubmitted,
    required this.onTestServer,
    required this.onAddCustomServer,
    required this.onDeleteCustomServer,
  });

  final bool enabled;
  final List<GroupListeningVoyageServerOption> bundledServers;
  final List<CustomVoyageServer> customServers;
  final String? selectedServerUrl;
  final TextEditingController voyageServerUrlController;
  final TextEditingController customVoyageLabelController;
  final TextEditingController customVoyageUrlController;
  final GroupListeningVoyageConnectionStatus connectionStatus;
  final bool isChecking;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<String?> onServerSelected;
  final ValueChanged<String> onManualServerChanged;
  final ValueChanged<String> onManualServerSubmitted;
  final VoidCallback onTestServer;
  final VoidCallback onAddCustomServer;
  final ValueChanged<CustomVoyageServer> onDeleteCustomServer;

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
            secondary: enabled ? const Icon(Icons.headset_mic_outlined) : null,
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: <Widget>[
                if (bundledServers.isEmpty) ...<Widget>[
                  TextField(
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
                    onSubmitted: onManualServerSubmitted,
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: customVoyageLabelController,
                  decoration: const InputDecoration(
                    labelText: 'Custom server label',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey(
                    'groupListeningCustomVoyageServerUrlField',
                  ),
                  controller: customVoyageUrlController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Custom server URL',
                    hintText: 'https://voyage.example.com',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.add_link_outlined),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: isChecking ? null : onTestServer,
                        icon: isChecking
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.wifi_tethering),
                        label: const Text('Test server'),
                      ),
                      FilledButton.icon(
                        onPressed: isChecking ? null : onAddCustomServer,
                        icon: const Icon(Icons.add),
                        label: const Text('Add custom server'),
                      ),
                    ],
                  ),
                ),
                for (final server in customServers)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud_queue_outlined),
                    title: Text(server.label),
                    subtitle: Text(server.url),
                    trailing: IconButton(
                      tooltip: 'Delete custom server',
                      onPressed: () => onDeleteCustomServer(server),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
              ],
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
    required this.settings,
    required this.isBundled,
    required this.isSaving,
    required this.isAuthBusy,
    required this.isAuthPending,
    required this.obscureApiKey,
    required this.obscureSharedSecret,
    required this.controller,
    required this.sharedSecretController,
    required this.apiKeyError,
    required this.apiKeySuccess,
    required this.scrobbleError,
    required this.scrobbleSuccess,
    required this.onToggleObscure,
    required this.onToggleSharedSecretObscure,
    required this.onSave,
    required this.onClear,
    required this.onGetApiKey,
    required this.onStartAuth,
    required this.onCancelAuth,
    required this.onDisconnectScrobbling,
  });

  final AppSettingsModel settings;
  final bool isBundled;
  final bool isSaving;
  final bool isAuthBusy;
  final bool isAuthPending;
  final bool obscureApiKey;
  final bool obscureSharedSecret;
  final TextEditingController controller;
  final TextEditingController sharedSecretController;
  final String? apiKeyError;
  final String? apiKeySuccess;
  final String? scrobbleError;
  final String? scrobbleSuccess;
  final VoidCallback onToggleObscure;
  final VoidCallback onToggleSharedSecretObscure;
  final VoidCallback onSave;
  final VoidCallback onClear;
  final VoidCallback onGetApiKey;
  final VoidCallback onStartAuth;
  final VoidCallback onCancelAuth;
  final VoidCallback onDisconnectScrobbling;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final apiKeyValid =
        isBundled || (settings.lastFmApiKey?.trim().isNotEmpty ?? false);
    final scrobblingConnected =
        settings.lastFmScrobblingEnabled && settings.lastFmSessionConnected;

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
            const Divider(height: 28),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Last.fm scrobbling',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (scrobblingConnected)
                  Icon(Icons.check_circle, color: Colors.green.shade700),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: sharedSecretController,
              obscureText: obscureSharedSecret,
              decoration: InputDecoration(
                labelText: 'Shared secret',
                border: const OutlineInputBorder(),
                errorText: scrobbleError,
                helperText: scrobbleError == null ? scrobbleSuccess : null,
                helperStyle: TextStyle(color: Colors.green.shade700),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(
                    obscureSharedSecret
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip: obscureSharedSecret ? 'Show' : 'Hide',
                  onPressed: onToggleSharedSecretObscure,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (isAuthPending) ...<Widget>[
              Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: <Widget>[
                    const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text('Waiting for Last.fm approval...'),
                    ),
                    TextButton(
                      onPressed: onCancelAuth,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: isAuthBusy || isAuthPending || !apiKeyValid
                      ? null
                      : onStartAuth,
                  icon: isAuthBusy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_browser_outlined),
                  label: const Text('Authorize with Last.fm'),
                ),
                TextButton.icon(
                  onPressed:
                      isAuthBusy ||
                          isAuthPending ||
                          !settings.lastFmSessionConnected
                      ? null
                      : onDisconnectScrobbling,
                  icon: const Icon(Icons.link_off_outlined),
                  label: const Text('Clear scrobbling'),
                ),
              ],
            ),
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
                  label: const Text('Token settings'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
