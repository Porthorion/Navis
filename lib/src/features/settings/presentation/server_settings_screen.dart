import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/auth/presentation/server_url_validation.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';

class ServerSettingsScreen extends ConsumerStatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  ConsumerState<ServerSettingsScreen> createState() =>
      _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends ConsumerState<ServerSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

  bool _showValidationErrors = false;
  bool _isTestingConnection = false;
  bool _isSaving = false;
  bool _isSigningOut = false;
  String? _hydratedFingerprint;

  bool get _isBusy => _isTestingConnection || _isSaving || _isSigningOut;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _urlController.addListener(_onUrlChanged);
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final configAsync = ref.watch(serverConfigStateProvider);
    final syncState = ref.watch(librarySyncControllerProvider);
    final isSyncRunning = syncState.isRunning;

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

          _hydrateFieldsFromConfig(config);
          final theme = Theme.of(context);

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                autovalidateMode: _showValidationErrors
                    ? AutovalidateMode.onUserInteraction
                    : AutovalidateMode.disabled,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
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
                              label: l10n.serverSettingsNameLabel,
                              value:
                                  config.name ??
                                  l10n.serverSettingsUnknownValue,
                            ),
                            _ServerInfoRow(
                              label: l10n.serverSettingsUrlLabel,
                              value: config.url,
                            ),
                            _ServerInfoRow(
                              label: l10n.serverSettingsUsernameLabel,
                              value: config.username,
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
                            _ServerInfoRow(
                              label: l10n.serverSettingsCapabilitiesLabel,
                              value: _capabilitiesSummary(
                                config.capabilitiesJson,
                                l10n,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _urlController,
                      decoration: InputDecoration(
                        labelText: l10n.loginServerUrlLabel,
                      ),
                      enabled: !_isBusy,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      validator: (value) => validateServerUrl(value, l10n),
                    ),
                    if (isInsecureHttpUrl(
                      _urlController.text.trim(),
                    )) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        l10n.loginInsecureHttpWarning,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _usernameController,
                      decoration: InputDecoration(
                        labelText: l10n.loginUsernameLabel,
                      ),
                      enabled: !_isBusy,
                      textInputAction: TextInputAction.next,
                      validator: (value) => _validateRequired(
                        value,
                        l10n.loginValidationUsernameRequired,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      decoration: InputDecoration(
                        labelText: l10n.loginPasswordLabel,
                      ),
                      enabled: !_isBusy,
                      obscureText: true,
                      validator: (value) => _validateRequired(
                        value,
                        l10n.loginValidationPasswordRequired,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.tonal(
                      onPressed: _isBusy ? null : _testConnection,
                      child: Text(
                        _isTestingConnection
                            ? l10n.loginTestingConnection
                            : l10n.serverSettingsTestConnection,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _isBusy ? null : () => _save(config),
                      child: Text(
                        _isSaving
                            ? l10n.serverSettingsSaving
                            : l10n.serverSettingsSave,
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: (_isBusy || isSyncRunning)
                          ? null
                          : _runForceFullSync,
                      icon: const Icon(Icons.sync),
                      label: Text(
                        isSyncRunning
                            ? l10n.serverSettingsForceFullSyncRunning
                            : l10n.serverSettingsForceFullSync,
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _isBusy ? null : _showSignOutOptions,
                      icon: const Icon(Icons.logout),
                      label: Text(l10n.serverSettingsSignOut),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.serverSettingsLoadError),
          ),
        ),
      ),
    );
  }

  void _hydrateFieldsFromConfig(ServerConfigModel config) {
    final fingerprint =
        '${config.url}|${config.username}|${config.apiVersion}|${config.useLegacyAuth}';

    if (_hydratedFingerprint == fingerprint) {
      return;
    }

    _urlController.text = config.url;
    _usernameController.text = config.username;
    _passwordController.text = config.password;
    _hydratedFingerprint = fingerprint;
  }

  String _capabilitiesSummary(String? capabilitiesJson, AppLocalizations l10n) {
    if (capabilitiesJson == null || capabilitiesJson.trim().isEmpty) {
      return l10n.serverSettingsCapabilitiesEmpty;
    }

    try {
      final decoded = jsonDecode(capabilitiesJson);
      if (decoded is! Map<String, dynamic>) {
        return l10n.serverSettingsCapabilitiesEmpty;
      }
      final extensions = decoded['extensions'];
      if (extensions is! List) {
        return l10n.serverSettingsCapabilitiesEmpty;
      }
      return l10n.serverSettingsCapabilitiesCount(extensions.length);
    } on FormatException {
      return l10n.serverSettingsCapabilitiesEmpty;
    }
  }

  String? _validateRequired(String? value, String message) {
    if (value == null || value.trim().isEmpty) {
      return message;
    }
    return null;
  }

  bool _validateForm() {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid && !_showValidationErrors) {
      setState(() => _showValidationErrors = true);
    }
    return isValid;
  }

  Future<void> _testConnection() async {
    if (!_validateForm()) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    setState(() => _isTestingConnection = true);
    try {
      final result = await ref
          .read(serverConnectionServiceProvider)
          .probe(
            url: normalizeServerUrl(_urlController.text),
            username: _usernameController.text.trim(),
            password: _passwordController.text,
          );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.loginTestConnectionSuccess(result.apiVersion)),
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_toUserMessage(error, l10n))),
      );
    } finally {
      if (mounted) {
        setState(() => _isTestingConnection = false);
      }
    }
  }

  Future<void> _save(ServerConfigModel currentConfig) async {
    if (!_validateForm()) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final normalizedUrl = normalizeServerUrl(_urlController.text);
    final uri = parseServerUrl(normalizedUrl);
    if (uri == null) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final result = await ref
          .read(serverConnectionServiceProvider)
          .probe(
            url: normalizedUrl,
            username: _usernameController.text.trim(),
            password: _passwordController.text,
          );

      final updated = currentConfig.copyWith(
        name: uri.host.isEmpty ? currentConfig.name : uri.host,
        url: normalizedUrl,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        apiVersion: result.apiVersion,
        useLegacyAuth: result.useLegacyAuth,
        capabilitiesJson: jsonEncode(result.capabilities.toJson()),
      );

      await ref.read(serverConfigProvider.notifier).save(updated);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.serverSettingsSaveSuccess)),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_toUserMessage(error, l10n))),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _showSignOutOptions() async {
    final l10n = AppLocalizations.of(context)!;
    final wipeLocalData = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.logout_outlined),
                title: Text(l10n.serverSettingsSignOutKeepData),
                subtitle: Text(l10n.serverSettingsSignOutKeepDataSubtitle),
                onTap: () => Navigator.of(context).pop(false),
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: Text(l10n.serverSettingsSignOutWipeData),
                subtitle: Text(l10n.serverSettingsSignOutWipeDataSubtitle),
                onTap: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (wipeLocalData == null) {
      return;
    }

    await _signOut(wipeLocalData: wipeLocalData);
  }

  Future<void> _runForceFullSync() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await ref
        .read(librarySyncControllerProvider.notifier)
        .syncNow(forceFull: true);
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (result.status == LibrarySyncStatus.succeeded ||
        result.status == LibrarySyncStatus.skipped) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.serverSettingsForceFullSyncSuccess)),
      );
      return;
    }

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          l10n.serverSettingsForceFullSyncFailure(
            result.errorMessage ?? l10n.loginErrorUnknown,
          ),
        ),
      ),
    );
  }

  Future<void> _signOut({required bool wipeLocalData}) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isSigningOut = true);
    try {
      await ref
          .read(signOutServiceProvider)
          .signOut(wipeLocalData: wipeLocalData);
      await ref.read(serverConfigProvider.notifier).refresh();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
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
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.serverSettingsSignOutError)));
    } finally {
      if (mounted) {
        setState(() => _isSigningOut = false);
      }
    }
  }

  void _onUrlChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
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

class _ServerInfoRow extends StatelessWidget {
  const _ServerInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodyMedium,
          children: <InlineSpan>[
            TextSpan(
              text: '$label: ',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}
