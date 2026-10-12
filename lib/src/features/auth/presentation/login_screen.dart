import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/auth/presentation/server_url_validation.dart';
import 'package:navis/src/routing/app_routes.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const new({super.key});

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
  ProviderSubscription<AsyncValue<ServerConfigModel?>>?
  _retainedServerSubscription;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController();
    _urlController.addListener(_handleUrlChanged);
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    // After a keep-data sign-out, or when the saved password can no longer
    // be read, the profile is still on the device: offer its address and
    // username so only the password needs typing.
    _retainedServerSubscription = ref.listenManual(retainedServerProvider, (
      _,
      next,
    ) {
      final retained = next.asData?.value;
      if (retained == null) return;
      _retainedServerSubscription?.close();
      _retainedServerSubscription = null;
      // Never overwrite what the user has started typing.
      if (_urlController.text.isNotEmpty ||
          _usernameController.text.isNotEmpty) {
        return;
      }
      _urlController.text = retained.url;
      _usernameController.text = retained.username;
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _retainedServerSubscription?.close();
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
    // Track keyboard height so scroll views can add bottom padding when the
    // keyboard is open. Must be read in build() (not inside LayoutBuilder) so
    // that the widget rebuilds when viewInsets change — LayoutBuilder alone
    // won't rebuild when resizeToAvoidBottomInset: false.
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

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
          // Keep the field above the keyboard when resizeToAvoidBottomInset is
          // false — tells EditableText.showOnScreen to scroll the field up by at
          // least bottomInset dp from the viewport bottom.
          scrollPadding: EdgeInsets.only(bottom: bottomInset + 20),
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
          scrollPadding: EdgeInsets.only(bottom: bottomInset + 20),
          enabled: !_isBusy,
          validator: (value) =>
              _validateRequired(value, l10n.loginValidationUsernameRequired),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _passwordController,
          decoration: InputDecoration(
            labelText: l10n.loginPasswordLabel,
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              tooltip: _passwordVisible
                  ? l10n.loginHidePassword
                  : l10n.loginShowPassword,
              icon: Icon(
                _passwordVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: _isBusy
                  ? null
                  : () => setState(() => _passwordVisible = !_passwordVisible),
            ),
          ),
          obscureText: !_passwordVisible,
          textInputAction: TextInputAction.done,
          scrollPadding: EdgeInsets.only(bottom: bottomInset + 20),
          onFieldSubmitted: (_) => _connect(),
          enabled: !_isBusy,
          validator: (value) =>
              _validateRequired(value, l10n.loginValidationPasswordRequired),
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
      // Prevent Scaffold from shrinking the body when the keyboard appears.
      // Without this, LayoutBuilder sees smaller constraints when the keyboard
      // opens — which can flip the isShort/isWide branch and dispose the
      // focused TextFormField, causing a show→focus→dismiss→show keyboard loop
      // (observed on Android Auto). Instead we manually add viewInsets.bottom
      // as bottom padding on each scroll view so fields still scroll into view.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= kAdaptiveMediumWidth;
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
                                            const _LoginHeroSection(
                                              compact: true,
                                            ),
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
                                          children: <Widget>[credentialsFields],
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

                  // Wide + tall: centered Card with full vertical layout.
                  // Use ScrollView → ConstrainedBox(minHeight) → Center, NOT
                  // Center → ScrollView. The minHeight ensures Center always has
                  // a bounded space at least as tall as the viewport so the card
                  // lands at the true visual midpoint. Symmetric vertical padding
                  // (40dp each side) guarantees no asymmetric offset.
                  if (isWide) {
                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              24,
                              40,
                              24,
                              // Grow bottom padding when keyboard is open so
                              // the focused field can scroll above the keyboard.
                              40 + bottomInset,
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
                        ),
                      ),
                    );
                  }

                  // Narrow (mobile portrait): scrollable with vertical centering.
                  // ScrollView → ConstrainedBox(minHeight) → Center ensures the
                  // form is centred when it fits and scrolls when it doesn't.
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            24,
                            24,
                            24,
                            40 + bottomInset,
                          ),
                          child: buildForm(
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
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
      final repository = ref.read(serverConfigRepositoryProvider);
      final retainedMatch = await repository.compareRetainedServer(config);
      if (retainedMatch == RetainedServerMatch.different) {
        if (!mounted || !await _confirmServerReplacement(l10n)) {
          return;
        }
        await ref.read(signOutServiceProvider).signOut(wipeLocalData: true);
        await ref.read(serverConfigProvider.notifier).refresh();
      }
      await ref.read(serverConfigProvider.notifier).save(config);

      if (!mounted) {
        return;
      }
      _noticeController.show(
        message: l10n.loginConnectSuccess,
        level: AppNoticeLevel.success,
      );
      // Initial catalog sync now runs from the normal shell so a successful
      // login always lands on Home immediately.
      context.go(AppRoutes.home);
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

  Future<bool> _confirmServerReplacement(AppLocalizations l10n) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.loginReplaceServerTitle),
            content: Text(l10n.loginReplaceServerMessage),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.cancelAction),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.loginReplaceServerAction),
              ),
            ],
          ),
        ) ??
        false;
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
      SubsonicInsecureLegacyAuthException() =>
        l10n.loginErrorInsecureLegacyAuth,
      SubsonicAuthException() => l10n.loginErrorAuthentication,
      SubsonicConnectionException() => l10n.loginErrorConnection,
      SubsonicApiException(:final message) => message,
      _ => l10n.loginErrorUnknown,
    };
  }
}

class _LoginHeroSection extends StatelessWidget {
  const new({this.subtitle, this.compact = false});

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
          style: theme.textTheme.headlineMedium,
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
