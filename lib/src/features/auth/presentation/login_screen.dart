import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/data/server_connection_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';

final serverConnectionServiceProvider = Provider<ServerConnectionService>((
  ref,
) {
  return const SubsonicServerConnectionService();
});

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

  bool _isTestingConnection = false;
  bool _isConnecting = false;
  bool _showValidationErrors = false;

  bool get _isBusy => _isTestingConnection || _isConnecting;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.loginTitle)),
      body: SafeArea(
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
                Text(
                  l10n.loginSubtitle,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    labelText: l10n.loginServerUrlLabel,
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  enabled: !_isBusy,
                  validator: (value) => _validateUrl(value, l10n),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: l10n.loginUsernameLabel,
                  ),
                  textInputAction: TextInputAction.next,
                  enabled: !_isBusy,
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
                  obscureText: true,
                  enabled: !_isBusy,
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
                        : l10n.loginTestConnection,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _isBusy ? null : _connect,
                  child: Text(
                    _isConnecting ? l10n.loginConnecting : l10n.loginConnect,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _validateRequired(String? value, String message) {
    if (value == null || value.trim().isEmpty) {
      return message;
    }
    return null;
  }

  String? _validateUrl(String? value, AppLocalizations l10n) {
    if (value == null || value.trim().isEmpty) {
      return l10n.loginValidationServerUrlRequired;
    }

    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
      return l10n.loginValidationServerUrlInvalid;
    }

    if (uri.scheme != 'https') {
      return l10n.loginValidationServerUrlHttpsOnly;
    }

    return null;
  }

  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_validateForm()) {
      return;
    }

    setState(() => _isTestingConnection = true);
    try {
      final result = await ref
          .read(serverConnectionServiceProvider)
          .probe(
            url: _normalizedUrl,
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

  Future<void> _connect() async {
    final l10n = AppLocalizations.of(context)!;
    if (!_validateForm()) {
      return;
    }

    setState(() => _isConnecting = true);
    try {
      final result = await ref
          .read(serverConnectionServiceProvider)
          .probe(
            url: _normalizedUrl,
            username: _usernameController.text.trim(),
            password: _passwordController.text,
          );
      final url = _normalizedUrl;
      final username = _usernameController.text.trim();
      final password = _passwordController.text;

      final uri = Uri.parse(url);
      final host = uri.host;
      final name = host.isEmpty ? null : host;

      final config = ServerConfigModel(
        name: name,
        url: url,
        username: username,
        password: password,
        apiVersion: result.apiVersion,
        useLegacyAuth: result.useLegacyAuth,
        capabilitiesJson: jsonEncode(result.capabilities.toJson()),
      );
      await ref.read(serverConfigProvider.notifier).save(config);

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.loginConnectSuccess)),
      );
      context.go('/');
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_toUserMessage(error, l10n))),
      );
    } finally {
      if (mounted) {
        setState(() => _isConnecting = false);
      }
    }
  }

  bool _validateForm() {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid && !_showValidationErrors) {
      setState(() => _showValidationErrors = true);
    }
    return isValid;
  }

  String get _normalizedUrl {
    final raw = _urlController.text.trim();
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
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
