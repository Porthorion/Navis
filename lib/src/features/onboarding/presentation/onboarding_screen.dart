import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/home/presentation/home_onboarding_warmup.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/listenbrainz_connection_status.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/navigation_service.dart';

/// A deliberately shell-free, one-time customization experience.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({
    super.key,
    this.reviewMode = false,
    this.homeWarmupAfterRebuild = false,
  });

  final bool reviewMode;

  /// True only for the one-time handoff from a successful required rebuild.
  /// It is intentionally route-scoped rather than persisted or user-visible.
  final bool homeWarmupAfterRebuild;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _steps = 4;
  int _step = 0;
  bool _hydrated = false;
  bool _saving = false;
  bool _lastFmBusy = false;
  bool _listenBrainzBusy = false;
  String? _serviceError;
  AppSettingsModel? _draft;
  List<int>? _draftCustomPresets;
  late final TextEditingController _lastFmKey;
  late final TextEditingController _listenBrainzToken;
  late final List<ScrollController> _stepScrollControllers;
  late final List<bool> _stepCanScroll;
  final Set<int> _scrollabilityMeasurementPending = <int>{};
  HomeOnboardingWarmupSession? _homeWarmup;
  AppLifecycleListener? _homeWarmupLifecycleListener;
  var _homeWarmupAllowed = true;

  @override
  void initState() {
    super.initState();
    _lastFmKey = TextEditingController();
    _listenBrainzToken = TextEditingController();
    _stepScrollControllers = List<ScrollController>.generate(
      _steps,
      (_) => ScrollController(),
    );
    _stepCanScroll = List<bool>.filled(_steps, false);
    if (widget.homeWarmupAfterRebuild) {
      _homeWarmupLifecycleListener = AppLifecycleListener(
        onInactive: _stopHomeWarmup,
        onPause: _stopHomeWarmup,
        onHide: _stopHomeWarmup,
        onDetach: _stopHomeWarmup,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_homeWarmupAllowed) {
          return;
        }
        _homeWarmup = startHomeOnboardingWarmup(ref, context);
      });
    }
  }

  @override
  void dispose() {
    _stopHomeWarmup();
    _homeWarmupLifecycleListener?.dispose();
    _lastFmKey.dispose();
    _listenBrainzToken.dispose();
    for (final controller in _stepScrollControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _stopHomeWarmup() {
    _homeWarmupAllowed = false;
    _homeWarmup?.stop();
  }

  void _hydrate(AppSettingsModel settings) {
    if (_hydrated) return;
    _hydrated = true;
    _draft = settings;
    _draftCustomPresets = List<int>.from(
      ref.read(customColorPresetsProvider).asData?.value ?? const <int>[],
    );
    _lastFmKey.text = settings.lastFmApiKey ?? '';
    unawaited(_readListenBrainzToken());
  }

  Future<void> _readListenBrainzToken() async {
    final token = await ref
        .read(externalScrobbleCredentialStoreProvider)
        .readListenBrainzToken();
    if (mounted && token != null) _listenBrainzToken.text = token;
  }

  Future<void> _finish({required bool discardDraft}) async {
    final draft = _draft;
    if (draft == null || _saving) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _saving = true);
    try {
      if (!discardDraft) {
        final customPresets = _draftCustomPresets;
        if (customPresets != null) {
          await ref
              .read(navisDatabaseProvider)
              .appSettingsDao
              .updateCustomColorPresets(
                customPresets.isEmpty ? null : jsonEncode(customPresets),
              );
        }
        await ref.read(settingsRepositoryProvider).saveSettings(draft);
        final handler = ref.read(audioHandlerProvider);
        if (handler != null) await handler.applyRuntimeSettings();
      }
      await ref.read(onboardingCompletionServiceProvider).complete();
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 260));
      if (!mounted) return;
      if (widget.reviewMode) {
        NavService.back(context, fallback: AppRoutes.settings);
      } else {
        context.go(AppRoutes.home);
      }
    } on Object {
      if (mounted) {
        setState(() => _serviceError = l10n.onboardingSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _skip() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return AlertDialog(
          title: Text(l10n.onboardingSkipDialogTitle),
          content: Text(l10n.onboardingSkipDialogMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.onboardingKeepCustomizing),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.onboardingSkipSetup),
            ),
          ],
        );
      },
    );
    if (discard == true) {
      await _finish(discardDraft: true);
    }
  }

  Future<void> _saveLastFm() async {
    final current = _draft;
    final key = _lastFmKey.text.trim();
    if (current == null || _lastFmBusy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _lastFmBusy = true;
      _serviceError = null;
    });
    try {
      if (key.isNotEmpty) {
        final result = await ref
            .read(lastFmApiClientFactoryProvider)(key)
            .validateApiKey();
        if (!result.valid) {
          throw StateError(
            result.message ?? l10n.configurationLastFmApiKeyInvalid,
          );
        }
      }
      setState(
        () => _draft = current.copyWith(
          lastFmApiKey: key.isEmpty ? null : key,
          clearLastFmApiKey: key.isEmpty,
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _serviceError = '$error');
      }
    } finally {
      if (mounted) setState(() => _lastFmBusy = false);
    }
  }

  Future<void> _validateListenBrainz() async {
    final current = _draft;
    final token = _listenBrainzToken.text.trim();
    if (current == null || _listenBrainzBusy) return;
    final l10n = AppLocalizations.of(context)!;
    if (token.isEmpty) {
      setState(
        () => _serviceError = l10n.configurationListenBrainzTokenRequired,
      );
      return;
    }
    setState(() {
      _listenBrainzBusy = true;
      _serviceError = null;
    });
    try {
      final details = await ref
          .read(listenBrainzApiClientProvider)
          .validateTokenDetails(token);
      if (!details.valid) {
        throw StateError(l10n.configurationListenBrainzTokenInvalid);
      }
      await ref
          .read(externalScrobbleCredentialStoreProvider)
          .saveListenBrainzToken(token);
      setState(
        () => _draft = current.copyWith(
          listenBrainzTokenValid: true,
          listenBrainzScrobblingEnabled: true,
          listenBrainzUserName: details.userName,
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _serviceError = '$error');
      }
    } finally {
      if (mounted) setState(() => _listenBrainzBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    settings.whenData(_hydrate);
    final draft = _draft;
    if (draft == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final l10n = AppLocalizations.of(context)!;
    final motion = MotionPolicy.of(context);
    final previewTheme = _previewTheme(context, draft);
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 600 || viewport.height < 700;
    final stepPanel = _stepPanel(
      draft,
      previewTheme,
      motion,
      framed: false,
    );
    return Theme(
      data: previewTheme,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (_, _) {
          if (_step == 0) {
            unawaited(_skip());
          } else {
            setState(() => _step--);
          }
        },
        child: Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? 760 : 900),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (compact) ...[
                            const Align(
                              child: NavisIcon(size: 74, tintWithAccent: true),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              widget.reviewMode
                                  ? l10n.onboardingReviewTitle
                                  : l10n.onboardingTitle,
                              textAlign: TextAlign.center,
                              style: previewTheme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              l10n.onboardingStepProgress(_step + 1, _steps),
                              textAlign: TextAlign.center,
                              semanticsLabel: l10n
                                  .onboardingStepProgressSemantics(
                                    _step + 1,
                                    _steps,
                                  ),
                            ),
                          ] else ...[
                            Row(
                              children: [
                                const NavisIcon(size: 56, tintWithAccent: true),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        widget.reviewMode
                                            ? l10n.onboardingReviewTitle
                                            : l10n.onboardingTitle,
                                        style: previewTheme
                                            .textTheme
                                            .headlineSmall,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.onboardingStepProgress(
                                          _step + 1,
                                          _steps,
                                        ),
                                        semanticsLabel: l10n
                                            .onboardingStepProgressSemantics(
                                              _step + 1,
                                              _steps,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 12),
                          LinearProgressIndicator(value: (_step + 1) / _steps),
                          const SizedBox(height: 28),
                          Expanded(child: stepPanel),
                          if (_serviceError != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                _serviceError!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          const SizedBox(height: 24),
                          Divider(
                            color: previewTheme.colorScheme.outlineVariant,
                          ),
                          const SizedBox(height: 16),
                          _actions(compact),
                        ],
                      ),
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

  Widget _stepPanel(
    AppSettingsModel draft,
    ThemeData previewTheme,
    MotionPolicy motion, {
    required bool framed,
  }) {
    final content = Padding(
      padding: EdgeInsets.fromLTRB(framed ? 20 : 0, 18, framed ? 20 : 0, 8),
      child: AnimatedSwitcher(
        duration: motion.reduceMotion ? Duration.zero : motion.surface,
        layoutBuilder: (currentChild, _) => currentChild ?? const SizedBox(),
        child: KeyedSubtree(key: ValueKey(_step), child: _buildStep(draft)),
      ),
    );
    if (!framed) return content;
    return Material(
      color: previewTheme.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: previewTheme.colorScheme.outlineVariant),
      ),
      child: content,
    );
  }

  Widget _actions(bool compact) {
    final l10n = AppLocalizations.of(context)!;
    final skip = TextButton(
      onPressed: _saving ? null : _skip,
      child: Text(l10n.onboardingSkipSetup),
    );
    final back = _step > 0
        ? TextButton(
            onPressed: _saving ? null : () => setState(() => _step--),
            child: Text(l10n.onboardingBack),
          )
        : null;
    final next = FilledButton(
      onPressed: _saving
          ? null
          : () => _step == _steps - 1
                ? _finish(discardDraft: false)
                : setState(() => _step++),
      child: _saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              _step == _steps - 1
                  ? l10n.onboardingFinish
                  : l10n.onboardingContinue,
            ),
    );
    if (compact) {
      return Wrap(
        alignment: WrapAlignment.spaceBetween,
        runSpacing: 8,
        children: [
          skip,
          const SizedBox(width: 12),
          if (back != null) back,
          const SizedBox(width: 8),
          next,
        ],
      );
    }
    return Row(
      children: [
        skip,
        const Spacer(),
        if (back != null) back,
        const SizedBox(width: 8),
        next,
      ],
    );
  }

  ThemeData _previewTheme(BuildContext context, AppSettingsModel draft) {
    final resolvedMode = resolveThemeMode(draft.themeMode);
    final dark =
        resolvedMode == ThemeMode.dark ||
        (resolvedMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    final seed = resolveColorSchemeSeedColor(draft.colorSchemeSeed);
    if (!dark) return buildLightTheme(seed);
    return draft.themeMode == 'oled'
        ? buildOledTheme(seed)
        : buildDarkTheme(seed);
  }

  Widget _buildStep(AppSettingsModel draft) => switch (_step) {
    0 => _appearanceStep(draft),
    1 => _listeningStep(draft),
    2 => _queueStep(draft),
    _ => _servicesStep(draft),
  };

  Widget _appearanceStep(AppSettingsModel draft) {
    final l10n = AppLocalizations.of(context)!;
    final customPresets = _draftCustomPresets ?? const <int>[];
    return _scrollStep(
      children: [
        Text(
          l10n.onboardingAppearanceTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(l10n.onboardingAppearanceDescription),
        const SizedBox(height: 16),
        ThemeModeSelector(
          currentMode: draft.themeMode,
          onChanged: (value) =>
              setState(() => _draft = draft.copyWith(themeMode: value)),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.onboardingAccentColor,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        ColorSchemeGrid(
          currentSeed: draft.colorSchemeSeed,
          dynamicAlbumColorEnabled: false,
          customPresets: customPresets,
          onSelected: (seed) => setState(
            () => _draft = draft.copyWith(
              colorSchemeSeed: seed,
              clearColorSchemeSeed: seed == null,
            ),
          ),
          onCustomColorPicked: (value) => setState(
            () => _draft = draft.copyWith(colorSchemeSeed: value),
          ),
          onSavePreset: (value) => setState(() {
            if (!_draftCustomPresets!.contains(value)) {
              _draftCustomPresets = [..._draftCustomPresets!, value];
            }
          }),
          onDeletePreset: (value) => setState(() {
            _draftCustomPresets = _draftCustomPresets!
                .where((preset) => preset != value)
                .toList(growable: false);
            if (draft.colorSchemeSeed == value) {
              _draft = draft.copyWith(
                clearColorSchemeSeed: true,
                colorSchemeSeed: null,
              );
            }
          }),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.onboardingAppearanceColorPickerHint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  void _updateStepScrollability() {
    final step = _step;
    if (_scrollabilityMeasurementPending.contains(step)) return;
    _scrollabilityMeasurementPending.add(step);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollabilityMeasurementPending.remove(step);
      final controller = _stepScrollControllers[step];
      if (!mounted || !controller.hasClients) return;
      final canScroll = controller.position.maxScrollExtent > 0;
      if (_stepCanScroll[step] == canScroll) return;
      setState(() => _stepCanScroll[step] = canScroll);
    });
  }

  Widget _scrollStep({required List<Widget> children}) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          _updateStepScrollability();
          return false;
        },
        child: Scrollbar(
          controller: _stepScrollControllers[_step],
          thumbVisibility: true,
          child: ListView(
            controller: _stepScrollControllers[_step],
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              if ((_step == 1 || _step == 3) && _stepCanScroll[_step])
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.swipe_up_alt_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.onboardingScrollForMore,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ...children,
            ],
          ),
        ),
      );

  Widget _listeningStep(AppSettingsModel draft) {
    final l10n = AppLocalizations.of(context)!;
    return _scrollStep(
      children: [
        Text(
          l10n.onboardingListeningTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(l10n.onboardingListeningDescription),
        const SizedBox(height: 16),
        _qualityField(
          l10n.onboardingWifiQuality,
          draft.wifiMaxBitRate,
          (value) => setState(
            () => _draft = draft.copyWith(
              wifiMaxBitRate: value,
              clearWifiBitRate: value == null,
            ),
          ),
        ),
        _formatField(
          l10n.onboardingWifiFormat,
          draft.wifiFormat,
          (value) => setState(
            () => _draft = draft.copyWith(
              wifiFormat: value,
              clearWifiFormat: value == null,
            ),
          ),
        ),
        _qualityField(
          l10n.onboardingMobileQuality,
          draft.cellularMaxBitRate,
          (value) => setState(
            () => _draft = draft.copyWith(
              cellularMaxBitRate: value,
              clearCellularBitRate: value == null,
            ),
          ),
        ),
        _formatField(
          l10n.onboardingMobileFormat,
          draft.cellularFormat,
          (value) => setState(
            () => _draft = draft.copyWith(
              cellularFormat: value,
              clearCellularFormat: value == null,
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.onboardingPreferLocalTitle),
          subtitle: Text(l10n.onboardingPreferLocalSubtitle),
          value: draft.cachedPlaybackFirst,
          onChanged: (value) => setState(
            () => _draft = draft.copyWith(cachedPlaybackFirst: value),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.onboardingScrobbleTitle),
          subtitle: Text(l10n.onboardingScrobbleSubtitle),
          value: draft.scrobbleEnabled,
          onChanged: (value) =>
              setState(() => _draft = draft.copyWith(scrobbleEnabled: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.onboardingGaplessTitle),
          subtitle: Text(l10n.onboardingGaplessSubtitle),
          value: draft.gaplessEnabled,
          onChanged: (value) => setState(
            () => _draft = draft.copyWith(
              gaplessEnabled: value,
              crossfadeEnabled: value && draft.crossfadeEnabled,
            ),
          ),
        ),
        if (draft.gaplessEnabled) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.onboardingCrossfadeTitle),
            subtitle: Text(l10n.onboardingCrossfadeSubtitle),
            value: draft.crossfadeEnabled,
            onChanged: (value) => setState(
              () => _draft = draft.copyWith(
                crossfadeEnabled: value,
                gaplessEnabled: value || draft.gaplessEnabled,
              ),
            ),
          ),
          if (draft.crossfadeEnabled) ...[
            const SizedBox(height: 8),
            Text(
              l10n.onboardingCrossfadeDuration(draft.crossfadeDurationSeconds),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Slider(
              value: draft.crossfadeDurationSeconds.toDouble(),
              min: 1,
              max: 12,
              divisions: 11,
              label: l10n.onboardingCrossfadeSecondsShort(
                draft.crossfadeDurationSeconds,
              ),
              onChanged: (value) => setState(
                () => _draft = draft.copyWith(
                  crossfadeDurationSeconds: value.round(),
                ),
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: draft.crossfadeType,
              decoration: InputDecoration(
                labelText: l10n.onboardingCrossfadeType,
              ),
              items: [
                DropdownMenuItem(
                  value: 'normal',
                  child: Text(l10n.playbackSettingsCrossfadeTypeNormal),
                ),
                DropdownMenuItem(
                  value: 'smart',
                  child: Text(l10n.onboardingCrossfadeTypeSmart),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _draft = draft.copyWith(crossfadeType: value));
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
              draft.crossfadeType == 'smart'
                  ? l10n.onboardingCrossfadeSmartDescription
                  : l10n.onboardingCrossfadeNormalDescription,
            ),
          ],
        ],
      ],
    );
  }

  Widget _qualityField(
    String label,
    int? value,
    ValueChanged<int?> onChanged,
  ) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<int?>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          DropdownMenuItem(
            value: null,
            child: Text(l10n.playbackSettingsFormatOriginal),
          ),
          for (final kbps in const [320, 256, 192, 128, 96])
            DropdownMenuItem(
              value: kbps,
              child: Text(l10n.playbackSettingsQualityKbps(kbps)),
            ),
        ],
        onChanged: (v) => onChanged(v),
      ),
    );
  }

  Widget _formatField(
    String label,
    String? value,
    ValueChanged<String?> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String?>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(
          value: null,
          child: Text(
            AppLocalizations.of(context)!.playbackSettingsFormatOriginal,
          ),
        ),
        const DropdownMenuItem(value: 'mp3', child: Text('MP3')),
        const DropdownMenuItem(value: 'aac', child: Text('AAC')),
        const DropdownMenuItem(value: 'opus', child: Text('Opus')),
      ],
      onChanged: onChanged,
    ),
  );

  Widget _queueStep(AppSettingsModel draft) {
    final l10n = AppLocalizations.of(context)!;
    return _scrollStep(
      children: [
        Text(
          l10n.onboardingQueueTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(l10n.onboardingQueueDescription),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.onboardingAlbumQueueTitle),
          subtitle: Text(l10n.onboardingAlbumQueueSubtitle),
          value: draft.albumQueueEnabled,
          onChanged: (v) => setState(
            () => _draft = draft.copyWith(
              albumQueueEnabled: v,
              likedQueueEnabled: v && draft.likedQueueEnabled,
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.onboardingLikedQueueTitle),
          subtitle: Text(
            draft.albumQueueEnabled
                ? l10n.onboardingLikedQueueSubtitle
                : l10n.onboardingLikedQueueDisabledSubtitle,
          ),
          value: draft.likedQueueEnabled,
          onChanged: draft.albumQueueEnabled
              ? (v) => setState(
                  () => _draft = draft.copyWith(likedQueueEnabled: v),
                )
              : null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.onboardingWifiOnlyDownloadsTitle),
          subtitle: Text(l10n.onboardingWifiOnlyDownloadsSubtitle),
          value: draft.wifiOnlyDownloads,
          onChanged: (v) =>
              setState(() => _draft = draft.copyWith(wifiOnlyDownloads: v)),
        ),
      ],
    );
  }

  Widget _servicesStep(AppSettingsModel draft) {
    final l10n = AppLocalizations.of(context)!;
    final bundled = ref.watch(lastFmBundledKeyProvider);
    return _scrollStep(
      children: [
        Text(
          l10n.onboardingServicesTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(l10n.onboardingServicesDescription),
        const SizedBox(height: 16),
        Text('ListenBrainz', style: Theme.of(context).textTheme.titleMedium),
        Text(l10n.onboardingListenBrainzDisclosure),
        TextField(
          controller: _listenBrainzToken,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10n.onboardingListenBrainzTokenLabel,
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => launchUrl(
            Uri.parse('https://listenbrainz.org/profile/'),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(l10n.onboardingListenBrainzGetToken),
        ),
        if (draft.listenBrainzTokenValid)
          ListenBrainzConnectionStatus(
            settings: draft,
            enabled: !_listenBrainzBusy,
            onUpdate: _validateListenBrainz,
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: _listenBrainzBusy ? null : _validateListenBrainz,
              child: Text(
                _listenBrainzBusy
                    ? l10n.onboardingValidating
                    : l10n.onboardingListenBrainzValidate,
              ),
            ),
          ),
        const Divider(height: 40),
        Text('Last.fm', style: Theme.of(context).textTheme.titleMedium),
        Text(
          bundled
              ? l10n.onboardingLastFmBundledDescription
              : l10n.onboardingLastFmDescription,
        ),
        if (!bundled) ...[
          TextField(
            controller: _lastFmKey,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.onboardingLastFmApiKeyLabel,
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: _lastFmBusy ? null : _saveLastFm,
                child: Text(
                  _lastFmBusy
                      ? l10n.onboardingValidating
                      : l10n.onboardingLastFmValidateKey,
                ),
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://www.last.fm/api/accounts'),
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(l10n.onboardingLastFmGetApiKey),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
