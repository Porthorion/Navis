import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/async_body.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/integrations/presentation/integration_copy.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/settings/presentation/external_service_messages.dart';
import 'package:navis/src/features/settings/presentation/listenbrainz_connection_status.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/external_url.dart';

/// Settings › Integrations: which online services Navis may contact besides
/// the user's server, per service and per feature.
///
/// Every switch writes at once through the targeted integration writers, so a
/// choice made here can never be overwritten by another screen's full-row
/// save. The page also owns the Last.fm key and ListenBrainz token setup,
/// because their features stay locked until the credential is verified.
class IntegrationsSettingsScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<IntegrationsSettingsScreen> createState() =>
      _IntegrationsSettingsScreenState();
}

class _IntegrationsSettingsScreenState
    extends ConsumerState<IntegrationsSettingsScreen> {
  final _lastFmKeyController = TextEditingController();
  final _listenBrainzTokenController = TextEditingController();
  bool _hydrated = false;
  bool _obscureLastFmKey = true;
  bool _obscureListenBrainzToken = true;
  bool _savingLastFmKey = false;
  bool _listenBrainzBusy = false;
  bool _lastFmKeySaved = false;
  String? _lastFmKeyError;
  String? _listenBrainzError;

  @override
  void initState() {
    super.initState();
    // Fill the credential fields once, outside build, from the first settings
    // that arrive.
    ref.listenManual<AsyncValue<AppSettingsModel>>(appSettingsProvider, (
      _,
      next,
    ) {
      final settings = next.asData?.value;
      if (settings != null) unawaited(_hydrate(settings));
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _lastFmKeyController.dispose();
    _listenBrainzTokenController.dispose();
    super.dispose();
  }

  Future<void> _hydrate(AppSettingsModel settings) async {
    if (_hydrated) return;
    _hydrated = true;
    _lastFmKeyController.text = settings.lastFmApiKey ?? '';
    _lastFmKeySaved = (settings.lastFmApiKey ?? '').trim().isNotEmpty;
    String? token;
    try {
      token = await ref
          .read(externalScrobbleCredentialStoreProvider)
          .readListenBrainzToken();
    } on CredentialReadException {
      // Brief unavailability must not present the stored token as removed.
      token = null;
    }
    if (!mounted) return;
    setState(() => _listenBrainzTokenController.text = token ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settingsAsync = ref.watch(appSettingsProvider);
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

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
        title: Text(l10n.integrationsTitle),
      ),
      body: AsyncBody(
        value: settingsAsync,
        data: (settings) => _buildContent(context, settings, desktopMode),
        errorTitle: l10n.integrationsLoadError,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    AppSettingsModel settings,
    bool desktopMode,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final policy = ref.watch(integrationPolicyProvider);
    final horizontal = desktopMode ? NavisSpace.xl : NavisSpace.md;
    // Matches About, which hides update controls where Navis cannot update
    // itself.
    final updatesAvailable =
        !kIsWeb && defaultTargetPlatform != TargetPlatform.iOS;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            horizontal,
            NavisSpace.xs,
            horizontal,
            NavisSpace.xxl,
          ),
          children: <Widget>[
            SwitchListTile(
              key: const ValueKey<String>('integrations-master'),
              contentPadding: EdgeInsets.zero,
              value: settings.externalIntegrationsEnabled,
              onChanged: (value) => _write(
                (repository) =>
                    repository.setExternalIntegrationsEnabled(enabled: value),
              ),
              title: Text(l10n.integrationsMasterTitle),
              subtitle: Text(l10n.integrationsMasterSubtitle),
            ),
            const Divider(height: NavisSpace.lg),
            for (final group in _groups)
              ..._buildGroup(
                context,
                settings,
                policy,
                group,
                updatesAvailable: updatesAvailable,
              ),
          ],
        ),
      ),
    );
  }

  /// One group heading followed by its services, or nothing when none of its
  /// services apply on this platform.
  List<Widget> _buildGroup(
    BuildContext context,
    AppSettingsModel settings,
    IntegrationPolicy policy,
    _ServiceGroup group, {
    required bool updatesAvailable,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final services = <IntegrationService>[
      for (final service in group.services)
        if (service != IntegrationService.updates || updatesAvailable) service,
    ];
    if (services.isEmpty) return const <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: NavisSpace.xl),
        child: Semantics(
          header: true,
          child: Text(
            group.title(l10n),
            key: ValueKey<String>('integrations-group-${group.id}'),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      for (final service in services)
        _ServiceSection(
          // The first service sits close under its group heading.
          topPadding: service == services.first ? NavisSpace.xs : NavisSpace.lg,
          service: service,
          policy: policy,
          onServiceChanged: (value) => _write(
            (repository) =>
                repository.setIntegrationEnabled(service.key, enabled: value),
          ),
          onFeatureChanged: (feature, {required enabled}) => _write(
            (repository) =>
                repository.setIntegrationEnabled(feature.key, enabled: enabled),
          ),
          credential: switch (service) {
            IntegrationService.lastFm => _buildLastFmCredential(
              context,
              masterOn: policy.masterEnabled,
            ),
            IntegrationService.listenBrainz => _buildListenBrainzCredential(
              context,
              settings,
              masterOn: policy.masterEnabled,
            ),
            _ => null,
          },
        ),
    ];
  }

  Widget _buildLastFmCredential(
    BuildContext context, {
    required bool masterOn,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    if (ref.watch(lastFmBundledKeyProvider)) {
      return Text(
        l10n.integrationsLastFmKeyIncluded,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final success = NavisTokens.of(context).success;
    final savedText = _lastFmKeySaved
        ? l10n.configurationLastFmApiKeySaved
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: _lastFmKeyController,
          obscureText: _obscureLastFmKey,
          decoration: InputDecoration(
            labelText: l10n.configurationLastFmApiKeyLabel,
            hintText: l10n.configurationLastFmApiKeyHint,
            errorText: _lastFmKeyError,
            helperText: _lastFmKeyError == null ? savedText : null,
            helperStyle: TextStyle(color: success),
            prefixIcon: const Icon(Icons.key_outlined),
            suffixIcon: _SecretFieldActions(
              controller: _lastFmKeyController,
              obscured: _obscureLastFmKey,
              onToggleObscured: () =>
                  setState(() => _obscureLastFmKey = !_obscureLastFmKey),
              onClear: _clearLastFmKey,
            ),
          ),
        ),
        const SizedBox(height: NavisSpace.sm),
        Wrap(
          spacing: NavisSpace.xs,
          runSpacing: NavisSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.tonal(
              style: NavisColorStyleData.tonalStyleOf(context),
              onPressed: _savingLastFmKey || !masterOn ? null : _saveLastFmKey,
              child: _savingLastFmKey
                  ? const _ButtonProgress()
                  : Text(l10n.serverSettingsSave),
            ),
            TextButton.icon(
              onPressed: () =>
                  _openExternal('https://www.last.fm/api/accounts'),
              icon: const Icon(Icons.open_in_new),
              label: Text(l10n.configurationLastFmGetApiKey),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildListenBrainzCredential(
    BuildContext context,
    AppSettingsModel settings, {
    required bool masterOn,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final valid = settings.listenBrainzTokenValid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: _listenBrainzTokenController,
          obscureText: _obscureListenBrainzToken,
          decoration: InputDecoration(
            labelText: l10n.configurationListenBrainzTokenLabel,
            // A working token is shown by the connection row below.
            errorText: _listenBrainzError,
            prefixIcon: const Icon(Icons.token_outlined),
            suffixIcon: _SecretFieldActions(
              controller: _listenBrainzTokenController,
              obscured: _obscureListenBrainzToken,
              onToggleObscured: () => setState(
                () => _obscureListenBrainzToken = !_obscureListenBrainzToken,
              ),
              onClear: _clearListenBrainz,
            ),
          ),
        ),
        if (valid)
          ListenBrainzConnectionStatus(
            settings: settings,
            enabled: !_listenBrainzBusy && masterOn,
            onUpdate: _validateListenBrainz,
          )
        else
          const SizedBox(height: NavisSpace.sm),
        Wrap(
          spacing: NavisSpace.xs,
          runSpacing: NavisSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (!valid)
              FilledButton.tonal(
                style: NavisColorStyleData.tonalStyleOf(context),
                onPressed: _listenBrainzBusy || !masterOn
                    ? null
                    : _validateListenBrainz,
                child: _listenBrainzBusy
                    ? const _ButtonProgress()
                    : Text(l10n.configurationListenBrainzValidateAndSave),
              ),
            TextButton.icon(
              onPressed: () =>
                  _openExternal('https://listenbrainz.org/settings/'),
              icon: const Icon(Icons.open_in_new),
              label: Text(l10n.configurationListenBrainzGetToken),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _write(
    Future<void> Function(SettingsRepository repository) write,
  ) async {
    try {
      await write(ref.read(settingsRepositoryProvider));
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Integration switch could not be saved',
        error,
        stackTrace,
      );
      if (!mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.integrationsSaveError,
        level: AppNoticeLevel.error,
      );
    }
  }

  Future<void> _saveLastFmKey() async {
    final l10n = AppLocalizations.of(context)!;
    final key = _lastFmKeyController.text.trim();
    setState(() => _savingLastFmKey = true);
    try {
      if (key.isNotEmpty) {
        final result = await ref
            .read(lastFmApiClientFactoryProvider)(key)
            .validateApiKey();
        if (!result.valid) {
          if (!mounted) return;
          setState(
            () => _lastFmKeyError = lastFmApiKeyFailureMessage(result, l10n),
          );
          return;
        }
      }
      await ref
          .read(settingsRepositoryProvider)
          .updateLastFmApiKey(key.isEmpty ? null : key);
      if (!mounted) return;
      setState(() {
        _lastFmKeyError = null;
        _lastFmKeySaved = key.isNotEmpty;
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
      if (mounted) setState(() => _savingLastFmKey = false);
    }
  }

  Future<void> _clearLastFmKey() async {
    _lastFmKeyController.clear();
    await _saveLastFmKey();
  }

  Future<void> _validateListenBrainz() async {
    final l10n = AppLocalizations.of(context)!;
    final token = _listenBrainzTokenController.text.trim();
    if (token.isEmpty) {
      setState(
        () => _listenBrainzError = l10n.configurationListenBrainzTokenRequired,
      );
      return;
    }
    setState(() {
      _listenBrainzBusy = true;
      _listenBrainzError = null;
    });
    try {
      final details = await ref
          .read(listenBrainzApiClientProvider)
          .validateTokenDetails(token, userInitiated: true);
      final store = ref.read(externalScrobbleCredentialStoreProvider);
      final repository = ref.read(settingsRepositoryProvider);
      if (!details.valid) {
        await store.clearListenBrainzToken();
        await repository.updateListenBrainzConnection(
          tokenValid: false,
          scrobblingEnabled: false,
        );
        if (!mounted) return;
        setState(
          () => _listenBrainzError = l10n.configurationListenBrainzTokenInvalid,
        );
        return;
      }
      final wasConnected =
          (await repository.getSettings()).listenBrainzTokenValid;
      await store.saveListenBrainzToken(token);
      await repository.updateListenBrainzConnection(
        tokenValid: true,
        // A new connection starts with scrobbling on, like every other
        // feature; checking an existing token again keeps the user's choice.
        scrobblingEnabled: wasConnected ? null : true,
        userName: details.userName,
      );
      if (!mounted) return;
      ref.read(refreshWeeklyPlaylistsAfterTokenValidationProvider)();
    } on Object catch (error) {
      if (!mounted) return;
      setState(
        () => _listenBrainzError = listenBrainzConnectionError(l10n, error),
      );
    } finally {
      if (mounted) setState(() => _listenBrainzBusy = false);
    }
  }

  Future<void> _clearListenBrainz() async {
    _listenBrainzTokenController.clear();
    setState(() => _listenBrainzError = null);
    try {
      await ref
          .read(externalScrobbleCredentialStoreProvider)
          .clearListenBrainzToken();
      await ref
          .read(settingsRepositoryProvider)
          .updateListenBrainzConnection(
            tokenValid: false,
            scrobblingEnabled: false,
          );
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'ListenBrainz token could not be cleared',
        error,
        stackTrace,
      );
      if (!mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!
            .integrationsListenBrainzDisconnectFailed,
        level: AppNoticeLevel.error,
      );
    }
  }

  Future<void> _openExternal(String url) async {
    await launchExternalHttpUrl(url);
  }
}

/// A named group of services on the page. Every [IntegrationService] appears
/// in exactly one group.
class _ServiceGroup {
  const new(this.id, this.title, this.services);

  /// Stable key suffix for the heading.
  final String id;
  final String Function(AppLocalizations l10n) title;
  final List<IntegrationService> services;
}

final List<_ServiceGroup> _groups = <_ServiceGroup>[
  _ServiceGroup(
    'discovery',
    (l10n) => l10n.integrationsGroupDiscovery,
    const <IntegrationService>[
      IntegrationService.deezer,
      IntegrationService.lastFm,
    ],
  ),
  _ServiceGroup(
    'history',
    (l10n) => l10n.integrationsGroupListeningHistory,
    const <IntegrationService>[IntegrationService.listenBrainz],
  ),
  _ServiceGroup(
    'now-playing',
    (l10n) => l10n.integrationsGroupNowPlaying,
    const <IntegrationService>[
      IntegrationService.lrclib,
      IntegrationService.radioMetadata,
      IntegrationService.serverLinkedArtwork,
    ],
  ),
  _ServiceGroup(
    'app',
    (l10n) => l10n.integrationsGroupApp,
    const <IntegrationService>[
      IntegrationService.updates,
      IntegrationService.autoEq,
    ],
  ),
];

/// One service: its heading with the service switch, what it sends and
/// where, an optional credential, then one switch per feature.
class _ServiceSection extends StatelessWidget {
  const new({
    required this.service,
    required this.policy,
    required this.onServiceChanged,
    required this.onFeatureChanged,
    required this.topPadding,
    this.credential,
  });

  final IntegrationService service;

  /// Space above the section heading.
  final double topPadding;
  final IntegrationPolicy policy;
  final ValueChanged<bool> onServiceChanged;
  final void Function(IntegrationFeature feature, {required bool enabled})
  onFeatureChanged;

  /// The key or token setup shown between the description and the features.
  final Widget? credential;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final name = integrationServiceName(service, l10n);
    final verified = policy.isVerified(service);
    final lock = policy.serviceLockReason(service);
    final serviceLocked = lock != null;
    final credential = this.credential;
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          NavisSectionHeader(
            title: name,
            compact: true,
            trailing: <Widget>[
              Semantics(
                label: [
                  l10n.integrationsServiceSwitchLabel(name),
                  if (lock != null)
                    integrationLockReasonText(
                      lock,
                      service: service,
                      serviceName: name,
                      l10n: l10n,
                    ),
                ].join(' • '),
                child: Switch(
                  key: ValueKey<String>('integrations-service-${service.key}'),
                  // An unverified service cannot run, so it reads as off
                  // until its credential is verified.
                  value: verified && policy.isServiceSwitchOn(service),
                  onChanged: serviceLocked ? null : onServiceChanged,
                ),
              ),
            ],
          ),
          Text(
            integrationServiceDescription(service, l10n),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (credential != null) ...<Widget>[
            const SizedBox(height: NavisSpace.md),
            // Keeps key and token fields at a readable width on desktop.
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: credential,
              ),
            ),
          ],
          const SizedBox(height: NavisSpace.xxs),
          for (final feature in IntegrationFeature.forService(service))
            _FeatureTile(
              feature: feature,
              policy: policy,
              serviceName: name,
              onChanged: (value) => onFeatureChanged(feature, enabled: value),
            ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const new({
    required this.feature,
    required this.policy,
    required this.serviceName,
    required this.onChanged,
  });

  final IntegrationFeature feature;
  final IntegrationPolicy policy;
  final String serviceName;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final lock = policy.lockReason(feature);
    final copy = integrationFeatureCopy(feature, l10n);
    return SwitchListTile(
      key: ValueKey<String>('integrations-feature-${feature.key}'),
      contentPadding: EdgeInsets.zero,
      // Locked by the master or service switch, a feature shows the choice
      // that returns when they are switched back on. Without a verified
      // credential it cannot run at all, so it reads as off whatever lock
      // is shown, like its service switch.
      value:
          policy.isVerified(feature.service) &&
          policy.isFeatureSwitchOn(feature),
      onChanged: lock == null ? onChanged : null,
      title: Text(copy.title),
      subtitle: Text(
        lock == null
            ? copy.subtitle
            : integrationLockReasonText(
                lock,
                service: feature.service,
                serviceName: serviceName,
                l10n: l10n,
              ),
      ),
    );
  }
}

/// Show/hide and clear actions inside a credential field.
class _SecretFieldActions extends StatelessWidget {
  const new({
    required this.controller,
    required this.obscured,
    required this.onToggleObscured,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool obscured;
  final VoidCallback onToggleObscured;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            icon: Icon(
              obscured
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
            tooltip: obscured
                ? l10n.configurationShowSecret
                : l10n.configurationHideSecret,
            onPressed: onToggleObscured,
          ),
          if (value.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: l10n.configurationClearSecret,
              onPressed: onClear,
            ),
        ],
      ),
    );
  }
}

class _ButtonProgress extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(
      dimension: NavisSpace.md,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
