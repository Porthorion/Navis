import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/auth/presentation/server_url_validation.dart';

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
  final AppNoticeController _noticeController = AppNoticeController();

  bool _isConnecting = false;
  bool _showValidationErrors = false;
  bool _passwordVisible = false;

  bool get _isBusy => _isConnecting;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _urlController.addListener(_handleUrlChanged);
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _noticeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final heroSection = _LoginHeroSection(subtitle: l10n.loginSubtitle);

    final urlField = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextFormField(
          controller: _urlController,
          decoration: InputDecoration(
            labelText: l10n.loginServerUrlLabel,
            prefixIcon: const Icon(Icons.dns_outlined),
          ),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          enabled: !_isBusy,
          validator: (value) => validateServerUrl(value, l10n),
        ),
        if (isInsecureHttpUrl(_urlController.text.trim())) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.loginInsecureHttpWarning,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );

    final credentialsFields = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextFormField(
          controller: _usernameController,
          decoration: InputDecoration(
            labelText: l10n.loginUsernameLabel,
            prefixIcon: const Icon(Icons.person_outline),
          ),
          textInputAction: TextInputAction.next,
          enabled: !_isBusy,
          validator: (value) => _validateRequired(
            value,
            l10n.loginValidationUsernameRequired,
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _passwordController,
          decoration: InputDecoration(
            labelText: l10n.loginPasswordLabel,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(
                _passwordVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: _isBusy
                  ? null
                  : () =>
                        setState(() => _passwordVisible = !_passwordVisible),
            ),
          ),
          obscureText: !_passwordVisible,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _connect(),
          enabled: !_isBusy,
          validator: (value) => _validateRequired(
            value,
            l10n.loginValidationPasswordRequired,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _isBusy ? null : _connect,
          child: _isConnecting
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(l10n.loginConnecting),
                  ],
                )
              : Text(l10n.loginConnect),
        ),
      ],
    );

    Form buildForm(Widget child) => Form(
          key: _formKey,
          autovalidateMode: _showValidationErrors
              ? AutovalidateMode.onUserInteraction
              : AutovalidateMode.disabled,
          child: child,
        );

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(forceMaterialTransparency: true),
      body: Stack(
          children: <Widget>[
            Positioned.fill(
              child: SafeArea(
                bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 600;
                  final isShort = constraints.maxHeight < 600;

                  // Wide + short: side-by-side layout (landscape phones,
                  // short desktop windows). URL field moves to left column
                  // under the hero so only username/password/button are on
                  // the right — they fit without scrolling.
                  if (isWide && isShort) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 16,
                        ),
                        child: ConstrainedBox(
                          // No maxHeight — let the card be its natural size so
                          // Center can truly center it vertically.
                          constraints: const BoxConstraints(maxWidth: 800),
                          child: Card(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: buildForm(
                              IntrinsicHeight(
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: <Widget>[
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: <Widget>[
                                            // Compact hero: smaller icon,
                                            // no subtitle — saves ~70dp vs
                                            // the full hero section.
                                            const _LoginHeroSection(compact: true),
                                            const SizedBox(height: 16),
                                            urlField,
                                          ],
                                        ),
                                      ),
                                    ),
                                    VerticalDivider(
                                      width: 1,
                                      thickness: 1,
                                      indent: 12,
                                      endIndent: 12,
                                      color: theme.colorScheme.outlineVariant,
                                    ),
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: <Widget>[
                                            credentialsFields,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  // Wide + tall: centered Card with full vertical layout
                  if (isWide) {
                    return Center(
                      child: SingleChildScrollView(
                        // Top padding clears the transparent AppBar since
                        // extendBodyBehindAppBar=true extends the body under it.
                        padding: const EdgeInsets.fromLTRB(
                          24,
                          kToolbarHeight + 16,
                          24,
                          40,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: Card(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: buildForm(
                                Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    heroSection,
                                    const SizedBox(height: 32),
                                    urlField,
                                    const SizedBox(height: 16),
                                    credentialsFields,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  // Narrow (mobile portrait): full-page scrollable
                  return SingleChildScrollView(
                    // Top padding clears the transparent AppBar.
                    padding: const EdgeInsets.fromLTRB(
                      24,
                      kToolbarHeight + 8,
                      24,
                      40,
                    ),
                    child: buildForm(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          heroSection,
                          const SizedBox(height: 32),
                          urlField,
                          const SizedBox(height: 16),
                          credentialsFields,
                        ],
                      ),
                    ),
                  );
                },
              ),
              ),
            ),
            AppNoticeHost(controller: _noticeController),
          ],
        ),
      );
  }

  String? _validateRequired(String? value, String message) {
    if (value == null || value.trim().isEmpty) {
      return message;
    }
    return null;
  }

  Future<void> _connect() async {
    if (_isBusy) {
      return;
    }
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
      _noticeController.show(
        message: l10n.loginConnectSuccess,
        level: AppNoticeLevel.success,
      );
      context.go('/');
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _noticeController.show(
        message: _toUserMessage(error, l10n),
        level: AppNoticeLevel.error,
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
    return normalizeServerUrl(_urlController.text);
  }

  void _handleUrlChanged() {
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

class _LoginHeroSection extends StatelessWidget {
  const _LoginHeroSection({this.subtitle, this.compact = false});

  /// Full subtitle text shown in portrait/wide layouts.
  /// Omitted when [compact] is true.
  final String? subtitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        NavisIcon(size: compact ? 56 : 80, tintWithAccent: true),
        SizedBox(height: compact ? 8 : 12),
        Text(
          'Navis',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        if (!compact && subtitle != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
