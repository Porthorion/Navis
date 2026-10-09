import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/home/presentation/home_onboarding_warmup.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/integrations/presentation/integration_copy.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/domain/night_schedule.dart';
import 'package:navis/src/features/settings/presentation/appearance_options.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/external_service_messages.dart';
import 'package:navis/src/features/settings/presentation/listenbrainz_connection_status.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/features/settings/presentation/color_style_selector.dart';
import 'package:navis/src/theme/navis_color_style.dart';

/// A deliberately shell-free, one-time customization experience.
class OnboardingScreen extends ConsumerStatefulWidget {
  const new({
    super.key,
    this.reviewMode = false,
    this.homeWarmupAfterRebuild = false,
  });

  final bool reviewMode;

  /// True only for the one-time handoff from a successful required rebuild.
  /// It is intentionally route-scoped rather than persisted or user-visible.
  final bool homeWarmupAfterRebuild;

  @override
  ConsumerState<OnboardingScreen> createState() => OnboardingScreenState();
}

class OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _steps = 4;

  /// How many steps the flow has (diagnostics reads it to bound a step jump).
  static const stepCount = _steps;

  /// Zero-based step where external-service credential fields are shown.
  static const integrationsStep = 3;
  int _step = 0;
  bool _hydrated = false;
  bool _onboardingRequiredAtEntry = false;
  bool _saving = false;
  bool _lastFmBusy = false;
  bool _listenBrainzBusy = false;
  bool _obscureLastFmKey = true;
  bool _obscureListenBrainzToken = true;
  String? _lastFmError;
  String? _listenBrainzError;
  String? _saveError;
  AppSettingsModel? _draft;
  List<int>? _draftCustomPresets;
  late final TextEditingController _lastFmKey;
  late final TextEditingController _listenBrainzToken;
  // Own focus nodes, so a field keeps focus (and the keyboard stays up) when
  // the layout around it changes as the keyboard opens.
  final FocusNode _lastFmKeyFocus = FocusNode(debugLabel: 'onboarding-lastfm');
  final FocusNode _listenBrainzTokenFocus = FocusNode(
    debugLabel: 'onboarding-listenbrainz',
  );
  late final List<ScrollController> _stepScrollControllers;
  // Whether a step has more content below the visible part: it scrolls and is
  // not yet at (or within [_scrollHintEndSlack] of) its end.
  late final List<bool> _stepHasMoreBelow;
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
      (_) => ScrollController()..addListener(_updateStepScrollability),
    );
    _stepHasMoreBelow = List<bool>.filled(_steps, false);
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
    _lastFmKeyFocus.dispose();
    _listenBrainzTokenFocus.dispose();
    for (final controller in _stepScrollControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The shown step, 0-based. Read by the diagnostics presentation controller.
  int get step => _step;

  /// Shows [target] exactly as Next and Back do: the step changes and nothing
  /// is saved. Used by the clone-only diagnostics step control, which has
  /// already checked the range.
  void showStep(int target) {
    assert(target >= 0 && target < _steps, 'step out of range');
    setState(() => _step = target);
  }

  void _stopHomeWarmup() {
    _homeWarmupAllowed = false;
    _homeWarmup?.stop();
  }

  void _hydrate(AppSettingsModel settings, {required bool onboardingRequired}) {
    if (_hydrated) return;
    _hydrated = true;
    _onboardingRequiredAtEntry = onboardingRequired;
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
    setState(() {
      _saving = true;
      _saveError = null;
    });
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
        await _saveIntegrationChoices(draft);
        final handler = ref.read(audioHandlerProvider);
        if (handler != null) await handler.applyRuntimeSettings();
      }
      if (!discardDraft || (!widget.reviewMode && _onboardingRequiredAtEntry)) {
        await ref.read(setupHighlightsServiceProvider).markSeen();
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
        setState(() => _saveError = l10n.onboardingSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Writes the Integrations step's switches through the targeted writers,
  /// which the full-row settings save leaves alone, and marks the 1.4.3
  /// Integrations note as seen: setup has just shown the same choices.
  Future<void> _saveIntegrationChoices(AppSettingsModel draft) async {
    final repository = ref.read(settingsRepositoryProvider);
    final policy = _draftIntegrationPolicy(draft);
    await repository.updateLastFmApiKey(draft.lastFmApiKey);
    await repository.updateListenBrainzConnection(
      tokenValid: draft.listenBrainzTokenValid,
      userName: draft.listenBrainzUserName,
      scrobblingEnabled: draft.listenBrainzScrobblingEnabled,
    );
    await repository.setExternalIntegrationsEnabled(
      enabled: draft.externalIntegrationsEnabled,
    );
    for (final service in _integrationStepServices) {
      await repository.setIntegrationEnabled(
        service.key,
        enabled: policy.isServiceSwitchOn(service),
      );
    }
    await repository.updateIntegrationsNoticeDismissed(dismissed: true);
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

  Future<void> _validateLastFmKey() async {
    final current = _draft;
    final key = _lastFmKey.text.trim();
    if (current == null || _lastFmBusy || _storedOnlineServicesOff) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _lastFmBusy = true;
      _lastFmError = null;
    });
    try {
      if (key.isNotEmpty) {
        final result = await ref
            .read(lastFmApiClientFactoryProvider)(key)
            .validateApiKey();
        if (!mounted) return;
        if (!result.valid) {
          setState(
            () => _lastFmError = lastFmApiKeyFailureMessage(result, l10n),
          );
          return;
        }
      }
      if (!mounted) return;
      // The latest draft: switches may have changed while validating.
      setState(
        () => _draft = (_draft ?? current).copyWith(
          lastFmApiKey: key.isEmpty ? null : key,
          clearLastFmApiKey: key.isEmpty,
        ),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Last.fm key validation failed. $error\n$stackTrace');
      if (mounted) {
        setState(
          () => _lastFmError = l10n.configurationLastFmApiKeyValidationFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _lastFmBusy = false);
    }
  }

  Future<void> _validateListenBrainz() async {
    final current = _draft;
    final token = _listenBrainzToken.text.trim();
    if (current == null || _listenBrainzBusy || _storedOnlineServicesOff) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
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
      if (!mounted) return;
      if (!details.valid) {
        setState(
          () => _listenBrainzError = l10n.configurationListenBrainzTokenInvalid,
        );
        return;
      }
      await ref
          .read(externalScrobbleCredentialStoreProvider)
          .saveListenBrainzToken(token);
      if (!mounted) return;
      setState(
        () => _draft = (_draft ?? current).copyWith(
          listenBrainzTokenValid: true,
          listenBrainzScrobblingEnabled: true,
          listenBrainzUserName: details.userName,
        ),
      );
    } on Object catch (error, stackTrace) {
      // The guard refuses the check while stored settings keep online
      // services off; say so rather than blaming the network.
      final blocked =
          error is DioException && error.error is IntegrationBlockedException;
      if (!blocked) {
        AppLogger.warning(
          'ListenBrainz token validation failed. $error\n$stackTrace',
        );
      }
      if (mounted) {
        setState(
          () => _listenBrainzError = blocked
              ? l10n.onboardingIntegrationsStoredOff
              : l10n.configurationListenBrainzUnavailable,
        );
      }
    } finally {
      if (mounted) setState(() => _listenBrainzBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final onboardingRequired = ref.watch(onboardingRequiredProvider);
    if (onboardingRequired != null) {
      settings.whenData(
        (value) => _hydrate(value, onboardingRequired: onboardingRequired),
      );
    }
    final draft = _draft;
    if (draft == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final motion = MotionPolicy.of(context);
    final previewTheme = _previewTheme(context, draft);
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 600 || viewport.height < 700;
    // Read here so the page follows the keyboard as it opens and closes.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final keyboardOpen = keyboardInset > 0;
    // On a phone the keyboard leaves little room, so the header and the
    // actions step aside while it is up; the actions would sit behind it
    // anyway.
    final typing = compact && keyboardOpen;
    final stepPanel = _stepPanel(
      draft,
      previewTheme,
      motion,
      framed: false,
      typing: typing,
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
          // The body keeps its size when the keyboard opens and pads itself
          // by the keyboard height below. Resizing the body squeezed the step
          // list to nothing on phones.
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: compact ? 760 : 900),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        typing ? 0 : 20,
                        24,
                        keyboardOpen
                            ? keyboardInset + (typing ? 0 : NavisSpace.md)
                            : 24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!typing) ...[
                            KeyedSubtree(
                              key: const ValueKey<String>('onboarding-header'),
                              // A phone on its side gets the one-row header,
                              // which leaves the step room to show.
                              child: _header(
                                stacked: viewport.width < 600,
                                previewTheme,
                              ),
                            ),
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                              value: (_step + 1) / _steps,
                            ),
                            const SizedBox(height: 28),
                          ],
                          // Keyed so the step, and a focused field in it,
                          // survive the header and actions coming and going.
                          Expanded(
                            key: const ValueKey<String>('onboarding-step'),
                            child: stepPanel,
                          ),
                          if (!typing) ...[
                            if (_saveError != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  _saveError!,
                                  style: TextStyle(
                                    color: previewTheme.colorScheme.error,
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

  Widget _header(ThemeData previewTheme, {required bool stacked}) {
    final l10n = AppLocalizations.of(context)!;
    final title = widget.reviewMode
        ? l10n.onboardingReviewTitle
        : l10n.onboardingTitle;
    final progress = l10n.onboardingStepProgress(_step + 1, _steps);
    final progressSemantics = l10n.onboardingStepProgressSemantics(
      _step + 1,
      _steps,
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(child: NavisIcon(size: 74, tintWithAccent: true)),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: previewTheme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            progress,
            textAlign: TextAlign.center,
            semanticsLabel: progressSemantics,
          ),
        ],
      );
    }
    return Row(
      children: [
        const NavisIcon(size: 56, tintWithAccent: true),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: previewTheme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(progress, semanticsLabel: progressSemantics),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stepPanel(
    AppSettingsModel draft,
    ThemeData previewTheme,
    MotionPolicy motion, {
    required bool framed,
    required bool typing,
  }) {
    final content = Padding(
      padding: EdgeInsets.fromLTRB(
        framed ? 20 : 0,
        typing ? 0 : 18,
        framed ? 20 : 0,
        typing ? 0 : 8,
      ),
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
        borderRadius: NavisShapeData.of(context).scaledAll(28),
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
          ?back,
          const SizedBox(width: 8),
          next,
        ],
      );
    }
    return Row(
      children: [skip, const Spacer(), ?back, const SizedBox(width: 8), next],
    );
  }

  ThemeData _previewTheme(BuildContext context, AppSettingsModel draft) {
    final resolvedMode = resolveThemeMode(draft.themeMode);
    final dark =
        resolvedMode == ThemeMode.dark ||
        (resolvedMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);
    final seed = resolveColorSchemeSeedColor(draft.colorSchemeSeed);
    final style = NavisColorStyle.parse(draft.colorStyle);
    final flat = draft.flatSurfaces;
    if (!dark) return buildLightTheme(seed, style: style, flat: flat);
    return _previewOled(context, draft)
        ? buildOledTheme(seed, style: style, flat: flat)
        : buildDarkTheme(seed, style: style, flat: flat);
  }

  /// Mirrors app.dart: OLED mode, or Auto with "OLED when dark" while the
  /// platform is dark. The night schedule never switches the preview by time.
  bool _previewOled(BuildContext context, AppSettingsModel draft) =>
      draft.themeMode == 'oled' ||
      (draft.themeMode == 'system' &&
          draft.oledForAuto &&
          MediaQuery.platformBrightnessOf(context) == Brightness.dark);

  /// The current step, built under the preview theme: the [Builder]'s
  /// context sits below `Theme(data: previewTheme)`, unlike the state's own
  /// context, so every step's text follows the look chosen in the first step.
  Widget _buildStep(AppSettingsModel draft) => Builder(
    builder: (context) => switch (_step) {
      0 => _appearanceStep(context, draft),
      1 => _listeningStep(context, draft),
      2 => _queueStep(context, draft),
      _ => _integrationsStep(context, draft),
    },
  );

  Widget _appearanceStep(BuildContext context, AppSettingsModel draft) {
    final l10n = AppLocalizations.of(context)!;
    final customPresets = _draftCustomPresets ?? const <int>[];
    final pending = ref.watch(pendingSetupHighlightsProvider);
    Widget? tagFor(SetupHighlight highlight) =>
        pending.contains(highlight) ? const NewFeatureTag() : null;
    final colorStyleTag = tagFor(SetupHighlight.colorStyle);
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
        OledForAutoOption(
          visible: draft.themeMode == 'system',
          value: draft.oledForAuto,
          adornment: tagFor(SetupHighlight.oledForAuto),
          onChanged: (value) =>
              setState(() => _draft = draft.copyWith(oledForAuto: value)),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Flexible(
              child: Text(
                l10n.appearanceColorStyleLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (colorStyleTag != null) ...[
              const SizedBox(width: 8),
              colorStyleTag,
            ],
          ],
        ),
        ColorStyleSelector(
          currentStyle: NavisColorStyle.parse(draft.colorStyle),
          seed: resolveColorSchemeSeedColor(draft.colorSchemeSeed),
          brightness: Theme.of(context).brightness,
          oled: _previewOled(context, draft),
          onChanged: (style) => setState(
            () => _draft = draft.copyWith(colorStyle: style.storageKey),
          ),
        ),
        NightScheduleSection(
          schedule: NightSchedule(
            enabled: draft.nightScheduleEnabled,
            startMinutes: draft.nightScheduleStartMinutes,
            endMinutes: draft.nightScheduleEndMinutes,
          ),
          userStyle: NavisColorStyle.parse(draft.colorStyle),
          now: ref.watch(nowProvider)(),
          adornment: tagFor(SetupHighlight.nightSchedule),
          onChanged: (schedule) => setState(
            () => _draft = draft.copyWith(
              nightScheduleEnabled: schedule.enabled,
              nightScheduleStartMinutes: schedule.startMinutes,
              nightScheduleEndMinutes: schedule.endMinutes,
            ),
          ),
        ),
        FlatSurfacesOption(
          value: draft.flatSurfaces,
          adornment: tagFor(SetupHighlight.flatSurfaces),
          onChanged: (value) =>
              setState(() => _draft = draft.copyWith(flatSurfaces: value)),
        ),
        NowPlayingBackgroundOption(
          value: draft.nowPlayingBackground,
          adornment: tagFor(SetupHighlight.nowPlayingBackground),
          titleStyle: Theme.of(context).textTheme.titleMedium,
          onChanged: (value) => setState(
            () => _draft = draft.copyWith(nowPlayingBackground: value),
          ),
        ),
        DensityOption(
          value: draft.density,
          adornment: tagFor(SetupHighlight.density),
          titleStyle: Theme.of(context).textTheme.titleMedium,
          onChanged: (value) =>
              setState(() => _draft = draft.copyWith(density: value)),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.onboardingAccentColor,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        ColorSchemeGrid(
          currentSeed: draft.colorSchemeSeed,
          style: NavisColorStyle.parse(draft.colorStyle),
          dynamicAlbumColorEnabled: false,
          customPresets: customPresets,
          onSelected: (seed) => setState(
            () => _draft = draft.copyWith(
              colorSchemeSeed: seed,
              clearColorSchemeSeed: seed == null,
            ),
          ),
          onCustomColorPicked: (value) =>
              setState(() => _draft = draft.copyWith(colorSchemeSeed: value)),
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
      final position = controller.position;
      final hasMoreBelow =
          position.maxScrollExtent - position.pixels > _scrollHintEndSlack;
      if (_stepHasMoreBelow[step] == hasMoreBelow) return;
      setState(() => _stepHasMoreBelow[step] = hasMoreBelow);
    });
  }

  /// A step's scrolling content. The "scroll for more" hint sits above the
  /// list rather than in it: inserted into the list it shifted every row and
  /// rebuilt a focused field, which closed the keyboard. It is left out while
  /// the keyboard is up, when the step has too little room for it, and once
  /// the list is scrolled to (or near) its end; it returns when scrolled back
  /// up.
  Widget _scrollStep({required List<Widget> children}) => LayoutBuilder(
    builder: (context, constraints) => _scrollStepContent(
      // Under the preview theme, unlike the state's own context.
      context,
      children: children,
      showHint:
          (_step == 1 || _step == integrationsStep) &&
          _stepHasMoreBelow[_step] &&
          MediaQuery.viewInsetsOf(context).bottom == 0 &&
          constraints.maxHeight >= _minStepHeightForScrollHint,
    ),
  );

  static const _minStepHeightForScrollHint = 120.0;

  /// Remaining scroll distance at which a step counts as scrolled to its end.
  static const _scrollHintEndSlack = 24.0;

  Widget _scrollStepContent(
    BuildContext context, {
    required List<Widget> children,
    required bool showHint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHint)
          Padding(
            key: const ValueKey<String>('onboarding-scroll-hint'),
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
        Expanded(
          key: const ValueKey<String>('onboarding-step-list'),
          child: NotificationListener<ScrollMetricsNotification>(
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
                children: children,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _listeningStep(BuildContext context, AppSettingsModel draft) {
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

  Widget _qualityField(String label, int? value, ValueChanged<int?> onChanged) {
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

  Widget _queueStep(BuildContext context, AppSettingsModel draft) {
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

  /// The services the Integrations step offers; the rest of the switches
  /// live in Settings › Integrations. Update checks are left out where Navis
  /// cannot update itself, as in About.
  List<IntegrationService> get _integrationStepServices => [
    IntegrationService.deezer,
    IntegrationService.lastFm,
    IntegrationService.listenBrainz,
    IntegrationService.lrclib,
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.iOS)
      IntegrationService.updates,
  ];

  /// The draft's integration choices. A Last.fm key counts as verified when
  /// the build carries one or the key in the draft passed validation.
  IntegrationPolicy _draftIntegrationPolicy(AppSettingsModel draft) {
    final draftKey = draft.lastFmApiKey?.trim() ?? '';
    return integrationPolicyFromSettings(
      draft,
      lastFmVerified: ref.read(lastFmBundledKeyProvider) || draftKey.isNotEmpty,
    );
  }

  AppSettingsModel _withServiceSwitch(
    AppSettingsModel draft,
    IntegrationService service, {
    required bool enabled,
  }) {
    final disabled = {
      ...parseDisabledIntegrationKeys(draft.disabledIntegrations),
    };
    if (enabled) {
      disabled.remove(service.key);
    } else {
      disabled.add(service.key);
    }
    return draft.copyWith(
      disabledIntegrations: encodeDisabledIntegrationKeys(disabled),
    );
  }

  /// Whether the stored "Online services" switch is off, as when setup is
  /// run again after turning it off. The guard reads stored settings, not
  /// the draft, so no key or token can be checked until setup is finished.
  bool get _storedOnlineServicesOff =>
      ref.read(appSettingsProvider).asData?.value.externalIntegrationsEnabled ==
      false;

  /// Room kept around a focused field when it scrolls into view. The step's
  /// list already ends at the keyboard, so the keyboard height is not added.
  static const _fieldScrollPadding = EdgeInsets.all(NavisSpace.lg);

  Widget _integrationsStep(BuildContext context, AppSettingsModel draft) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final bundled = ref.watch(lastFmBundledKeyProvider);
    final policy = _draftIntegrationPolicy(draft);
    final storedOff = ref.watch(
      appSettingsProvider.select(
        (settings) =>
            settings.asData?.value.externalIntegrationsEnabled == false,
      ),
    );
    return _scrollStep(
      children: [
        Text(
          l10n.onboardingIntegrationsTitle,
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: NavisSpace.xs),
        Text(l10n.onboardingIntegrationsDescription),
        const SizedBox(height: NavisSpace.xs),
        SwitchListTile(
          key: const ValueKey<String>('onboarding-integrations-master'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.integrationsMasterTitle),
          subtitle: Text(l10n.integrationsMasterSubtitle),
          value: draft.externalIntegrationsEnabled,
          onChanged: (value) => setState(
            () => _draft = draft.copyWith(externalIntegrationsEnabled: value),
          ),
        ),
        const Divider(height: NavisSpace.lg),
        for (final service in _integrationStepServices)
          KeyedSubtree(
            key: ValueKey<String>('onboarding-integration-${service.key}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _integrationServiceTile(draft, policy, service),
                if (service == IntegrationService.lastFm &&
                    !bundled &&
                    policy.isServiceEnabled(service))
                  _credential(_lastFmKeyField(l10n, blocked: storedOff)),
                if (service == IntegrationService.listenBrainz &&
                    policy.isServiceEnabled(service))
                  _credential(
                    _listenBrainzTokenField(draft, l10n, blocked: storedOff),
                  ),
              ],
            ),
          ),
        const SizedBox(height: NavisSpace.sm),
        Text(
          l10n.onboardingIntegrationsFineTune,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _integrationServiceTile(
    AppSettingsModel draft,
    IntegrationPolicy policy,
    IntegrationService service,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final name = integrationServiceName(service, l10n);
    // ListenBrainz's switch says whether to set it up: switching it on shows
    // the token field, so it does not wait for a verified token. Last.fm
    // stays locked until a key is verified, as in Settings › Integrations.
    final listenBrainz = service == IntegrationService.listenBrainz;
    final lock = listenBrainz
        ? (policy.masterEnabled ? null : IntegrationLockReason.masterOff)
        : policy.serviceLockReason(service);
    final on = policy.isServiceSwitchOn(service);
    return SwitchListTile(
      key: ValueKey<String>('onboarding-integrations-service-${service.key}'),
      contentPadding: EdgeInsets.zero,
      title: Text(name),
      subtitle: Text(
        lock == null
            ? integrationServiceDescription(service, l10n)
            : integrationLockReasonText(
                lock,
                service: service,
                serviceName: name,
                l10n: l10n,
              ),
      ),
      value: listenBrainz ? on : policy.isVerified(service) && on,
      onChanged: lock == null
          ? (value) => setState(
              () => _draft = _withServiceSwitch(draft, service, enabled: value),
            )
          : null,
    );
  }

  /// Key and token setup under a service, at a readable width.
  Widget _credential(Widget child) => Padding(
    padding: const EdgeInsets.only(top: NavisSpace.xxs, bottom: NavisSpace.md),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: child,
      ),
    ),
  );

  Widget _visibilityToggle({
    required bool obscured,
    required VoidCallback onPressed,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return IconButton(
      icon: Icon(
        obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      ),
      tooltip: obscured
          ? l10n.configurationShowSecret
          : l10n.configurationHideSecret,
      onPressed: onPressed,
    );
  }

  Widget _listenBrainzTokenField(
    AppSettingsModel draft,
    AppLocalizations l10n, {
    required bool blocked,
  }) {
    final valid = draft.listenBrainzTokenValid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey<String>('onboarding-listenbrainz-token'),
          controller: _listenBrainzToken,
          focusNode: _listenBrainzTokenFocus,
          // Locked while the token is checked.
          enabled: !_listenBrainzBusy,
          obscureText: _obscureListenBrainzToken,
          textInputAction: TextInputAction.done,
          scrollPadding: _fieldScrollPadding,
          onSubmitted: blocked ? null : (_) => _validateListenBrainz(),
          decoration: InputDecoration(
            labelText: l10n.configurationListenBrainzTokenLabel,
            errorText: _listenBrainzError,
            helperText: blocked ? l10n.onboardingIntegrationsStoredOff : null,
            helperMaxLines: 3,
            prefixIcon: const Icon(Icons.token_outlined),
            suffixIcon: _visibilityToggle(
              obscured: _obscureListenBrainzToken,
              onPressed: () => setState(
                () => _obscureListenBrainzToken = !_obscureListenBrainzToken,
              ),
            ),
          ),
        ),
        if (valid)
          ListenBrainzConnectionStatus(
            settings: draft,
            enabled: !_listenBrainzBusy && !blocked,
            onUpdate: _validateListenBrainz,
          )
        else
          const SizedBox(height: NavisSpace.sm),
        Wrap(
          spacing: NavisSpace.xs,
          runSpacing: NavisSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (!valid)
              FilledButton.tonal(
                onPressed: _listenBrainzBusy || blocked
                    ? null
                    : _validateListenBrainz,
                child: Text(
                  _listenBrainzBusy
                      ? l10n.onboardingValidating
                      : l10n.onboardingListenBrainzValidate,
                ),
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

  Widget _lastFmKeyField(AppLocalizations l10n, {required bool blocked}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey<String>('onboarding-lastfm-key'),
          controller: _lastFmKey,
          focusNode: _lastFmKeyFocus,
          // Locked while the key is checked.
          enabled: !_lastFmBusy,
          obscureText: _obscureLastFmKey,
          textInputAction: TextInputAction.done,
          scrollPadding: _fieldScrollPadding,
          onSubmitted: blocked ? null : (_) => _validateLastFmKey(),
          decoration: InputDecoration(
            labelText: l10n.configurationLastFmApiKeyLabel,
            hintText: l10n.configurationLastFmApiKeyHint,
            errorText: _lastFmError,
            helperText: blocked ? l10n.onboardingIntegrationsStoredOff : null,
            helperMaxLines: 3,
            prefixIcon: const Icon(Icons.key_outlined),
            suffixIcon: _visibilityToggle(
              obscured: _obscureLastFmKey,
              onPressed: () =>
                  setState(() => _obscureLastFmKey = !_obscureLastFmKey),
            ),
          ),
        ),
        const SizedBox(height: NavisSpace.sm),
        Wrap(
          spacing: NavisSpace.xs,
          runSpacing: NavisSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonal(
              onPressed: _lastFmBusy || blocked ? null : _validateLastFmKey,
              child: Text(
                _lastFmBusy
                    ? l10n.onboardingValidating
                    : l10n.onboardingLastFmValidateKey,
              ),
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

  Future<void> _openExternal(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}
