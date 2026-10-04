import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/app_routes.dart';

class ServerSettingsScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<ServerSettingsScreen> createState() =>
      _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends ConsumerState<ServerSettingsScreen> {
  bool _isTestingConnection = false;
  bool _isSigningOut = false;

  bool get _isBusy => _isTestingConnection || _isSigningOut;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final configAsync = ref.watch(serverConfigStateProvider);
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
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back),
                onPressed: () =>
                    NavService.back(context, fallback: AppRoutes.settings),
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

                        // Last.fm, ListenBrainz and the other online
                        // services live on their own page.
                        _SectionHeader(title: l10n.integrationsMasterTitle),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.hub_outlined),
                          title: Text(l10n.integrationsTitle),
                          subtitle: Text(l10n.integrationsSubtitle),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => NavService.openSettingsPage(
                            context,
                            ref,
                            SettingsPage.integrations,
                          ),
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
      context.go(AppRoutes.login);
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
  const new({required this.title});

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
  const new({required this.label, required this.value});

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
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
