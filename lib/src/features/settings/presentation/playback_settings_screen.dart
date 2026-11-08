import 'package:navis/src/common_widgets/navis_slider.dart';
import 'package:navis/src/common_widgets/navis_switch.dart';
import 'package:navis/src/features/equalizer/data/eq_platform_support.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/presentation/adjustment_ruler.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_panel.dart';
import 'package:navis/src/features/player/presentation/replay_gain_untagged_provider.dart';
import 'package:navis/src/common_widgets/async_body.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/confirm_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/motion_policy.dart';

class PlaybackSettingsScreen extends ConsumerStatefulWidget {
  const new({this.focusReplayGain = false, super.key});

  /// Scrolls to the ReplayGain section once the settings have loaded (the
  /// link from holding the ReplayGain line on Now Playing).
  final bool focusReplayGain;

  @override
  ConsumerState<PlaybackSettingsScreen> createState() =>
      _PlaybackSettingsScreenState();
}

class _PlaybackSettingsScreenState
    extends ConsumerState<PlaybackSettingsScreen> {
  static const double _minReplayGainPreamp = -6;
  static const double _maxReplayGainPreamp = 6;
  static const List<int?> _qualityOptions = <int?>[
    null,
    320,
    256,
    192,
    128,
    96,
  ];
  static const List<String?> _formatOptions = <String?>[
    null,
    'mp3',
    'aac',
    'opus',
    'vorbis',
  ];

  final _formKey = GlobalKey<FormState>();
  final _replayGainKey = GlobalKey();
  bool _didFocus = false;

  int? _wifiBitRate;
  String? _wifiFormat;
  int? _cellularBitRate;
  String? _cellularFormat;
  bool _cachedPlaybackFirst = false;
  bool _scrobbleEnabled = true;
  bool _gaplessEnabled = true;
  bool _fastSeekingEnabled = true;
  bool _prefetchNextOnMobileData = true;
  bool _fullscreenModeLyrics = false;
  bool _albumQueueEnabled = false;
  bool _likedQueueEnabled = false;
  bool _matchFlowEnabled = false;

  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 5;
  String _crossfadeType = 'normal';
  String _replayGainMode = 'off';
  double _replayGainPreamp = 0;
  double? _replayGainUntaggedDb;

  /// The level under the ruler or stepper while it moves; it joins the form
  /// (and so the autosave) only when the input ends.
  double? _untaggedPreview;
  bool _didHydrateForm = false;
  bool _isSaving = false;
  bool _isAutoSaving = false;
  bool _pendingAutosave = false;
  bool _experimentalExpanded = false;
  String _lastSavedSignature = '';
  Timer? _autosaveDebounce;
  Completer<void>? _autosaveDone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settingsAsync = ref.watch(appSettingsProvider);
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    settingsAsync.whenData((settings) {
      if (_didHydrateForm) {
        return;
      }
      _didHydrateForm = true;
      _hydrate(settings);
    });

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
        title: Text(l10n.settingsPlaybackTitle),
      ),
      body: AsyncBody(
        value: settingsAsync,
        data: (_) => _buildForm(context, l10n),
        errorTitle: l10n.playbackSettingsLoadError,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
    );
  }

  Widget _buildForm(BuildContext context, AppLocalizations l10n) {
    final boost =
        ref.watch(audioHandlerProvider)?.replayGainBoostSupported ?? false;
    _scheduleAutosave();
    // The form only exists once the settings have loaded, so scroll after its
    // first build rather than in initState.
    if (widget.focusReplayGain && !_didFocus) {
      _didFocus = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _replayGainKey.currentContext;
        if (!mounted || target == null) return;
        Scrollable.ensureVisible(
          target,
          alignment: 0.02,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      });
    }
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            desktopMode ? 24 : 16,
            desktopMode ? 24 : 16,
            desktopMode ? 24 : 16,
            16,
          ),
          children: <Widget>[
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.playbackSettingsWifiSectionTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    isExpanded: true,
                    initialValue: _wifiBitRate,
                    decoration: InputDecoration(
                      labelText: l10n.playbackSettingsWifiQualityLabel,
                    ),
                    items: _qualityOptions
                        .map(
                          (value) => DropdownMenuItem<int?>(
                            value: value,
                            child: Text(_qualityLabel(l10n, value)),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _isSaving
                        ? null
                        : (value) => setState(() => _wifiBitRate = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    isExpanded: true,
                    initialValue: _wifiFormat,
                    decoration: InputDecoration(
                      labelText: l10n.playbackSettingsWifiFormatLabel,
                    ),
                    items: _formatOptions
                        .map(
                          (value) => DropdownMenuItem<String?>(
                            value: value,
                            child: Text(_formatLabel(l10n, value)),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _isSaving
                        ? null
                        : (value) => setState(() => _wifiFormat = value),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.playbackSettingsCellularSectionTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    isExpanded: true,
                    initialValue: _cellularBitRate,
                    decoration: InputDecoration(
                      labelText: l10n.playbackSettingsCellularQualityLabel,
                    ),
                    items: _qualityOptions
                        .map(
                          (value) => DropdownMenuItem<int?>(
                            value: value,
                            child: Text(_qualityLabel(l10n, value)),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _isSaving
                        ? null
                        : (value) => setState(() => _cellularBitRate = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    isExpanded: true,
                    initialValue: _cellularFormat,
                    decoration: InputDecoration(
                      labelText: l10n.playbackSettingsCellularFormatLabel,
                    ),
                    items: _formatOptions
                        .map(
                          (value) => DropdownMenuItem<String?>(
                            value: value,
                            child: Text(_formatLabel(l10n, value)),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _isSaving
                        ? null
                        : (value) => setState(() => _cellularFormat = value),
                  ),
                  const SizedBox(height: 12),
                  NavisSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _cachedPlaybackFirst,
                    onChanged: _isSaving
                        ? null
                        : (value) =>
                              setState(() => _cachedPlaybackFirst = value),
                    title: Text(l10n.playbackSettingsCachedFirstTitle),
                    subtitle: Text(l10n.playbackSettingsCachedFirstSubtitle),
                  ),
                  const SizedBox(height: 24),
                  NavisSwitchListTile(
                    key: const ValueKey('playbackSettingsScrobbleToggle'),
                    contentPadding: EdgeInsets.zero,
                    value: _scrobbleEnabled,
                    onChanged: _isSaving
                        ? null
                        : (value) => setState(() => _scrobbleEnabled = value),
                    title: Text(l10n.playbackSettingsScrobbleTitle),
                    subtitle: Text(l10n.playbackSettingsScrobbleSubtitle),
                  ),
                  NavisSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _albumQueueEnabled,
                    onChanged: _isSaving
                        ? null
                        : (value) => setState(() => _albumQueueEnabled = value),
                    title: Text(l10n.playbackSettingsAlbumQueueTitle),
                    subtitle: Text(l10n.playbackSettingsAlbumQueueSubtitle),
                  ),
                  if (_albumQueueEnabled)
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: NavisSwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _likedQueueEnabled,
                        onChanged: _isSaving
                            ? null
                            : (value) =>
                                  setState(() => _likedQueueEnabled = value),
                        title: Text(l10n.playbackSettingsLikedQueueTitle),
                        subtitle: Text(l10n.playbackSettingsLikedQueueSubtitle),
                      ),
                    ),
                  if (navisFastSeekSupported())
                    NavisSwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _fastSeekingEnabled,
                      onChanged: _isSaving
                          ? null
                          : (value) =>
                                setState(() => _fastSeekingEnabled = value),
                      title: Text(l10n.playbackSettingsFastSeekingTitle),
                      subtitle: Text(l10n.playbackSettingsFastSeekingSubtitle),
                    ),
                  NavisSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _prefetchNextOnMobileData,
                    onChanged: _isSaving ? null : _setPrefetchNextOnMobileData,
                    title: Text(l10n.playbackSettingsPrefetchNextTitle),
                    subtitle: Text(l10n.playbackSettingsPrefetchNextSubtitle),
                  ),
                  NavisSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _gaplessEnabled,
                    onChanged: _isSaving ? null : _setGaplessEnabled,
                    title: Text(l10n.playbackSettingsGaplessTitle),
                    subtitle: Text(l10n.playbackSettingsGaplessSubtitle),
                  ),
                  if (_gaplessEnabled) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          NavisSwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _crossfadeEnabled,
                            onChanged: _isSaving ? null : _setCrossfadeEnabled,
                            title: Text(
                              l10n.playbackSettingsCrossfadeEnableTitle,
                            ),
                            subtitle: Text(
                              l10n.playbackSettingsCrossfadeEnableSubtitle,
                            ),
                          ),
                          if (_crossfadeEnabled) ...[
                            Text(
                              l10n.playbackSettingsCrossfadeDurationLabel(
                                _crossfadeDurationSeconds,
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            NavisSlider(
                              value: _crossfadeDurationSeconds.toDouble(),
                              min: 1,
                              max: 12,
                              divisions: 11,
                              label: '${_crossfadeDurationSeconds}s',
                              onChanged: _isSaving
                                  ? null
                                  : (value) => setState(
                                      () => _crossfadeDurationSeconds = value
                                          .round(),
                                    ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: _crossfadeType,
                              decoration: InputDecoration(
                                labelText:
                                    l10n.playbackSettingsCrossfadeTypeLabel,
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'normal',
                                  child: Text(
                                    l10n.playbackSettingsCrossfadeTypeNormal,
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'smart',
                                  child: Text(
                                    l10n.playbackSettingsCrossfadeTypeSmart,
                                  ),
                                ),
                              ],
                              onChanged: _isSaving
                                  ? null
                                  : (value) {
                                      if (value != null) {
                                        setState(() => _crossfadeType = value);
                                      }
                                    },
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _crossfadeType == 'smart'
                                  ? l10n.playbackSettingsCrossfadeTypeSmartDescription
                                  : l10n.playbackSettingsCrossfadeTypeNormalDescription,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline,
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  NavisSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _fullscreenModeLyrics,
                    onChanged: _isSaving
                        ? null
                        : (value) =>
                              setState(() => _fullscreenModeLyrics = value),
                    title: Text(l10n.playbackSettingsFullscreenLyricsTitle),
                    subtitle: Text(
                      l10n.playbackSettingsFullscreenLyricsSubtitle,
                    ),
                  ),
                  // ── ReplayGain section ─────────────────────────────────────
                  const SizedBox(height: 24),
                  Text(
                    key: _replayGainKey,
                    l10n.playbackSettingsReplayGainSectionTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    boost
                        ? l10n.playbackSettingsReplayGainIntroBoost
                        : l10n.playbackSettingsReplayGainIntro,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _replayGainMode,
                    decoration: InputDecoration(
                      labelText: l10n.playbackSettingsReplayGainModeLabel,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'off',
                        child: Text(l10n.playbackSettingsReplayGainModeOff),
                      ),
                      DropdownMenuItem(
                        value: 'smart',
                        child: Text(l10n.playbackSettingsReplayGainModeSmart),
                      ),
                      DropdownMenuItem(
                        value: 'track',
                        child: Text(l10n.playbackSettingsReplayGainModeTrack),
                      ),
                      DropdownMenuItem(
                        value: 'album',
                        child: Text(l10n.playbackSettingsReplayGainModeAlbum),
                      ),
                    ],
                    onChanged: _isSaving
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() {
                                _replayGainMode = value;
                                _untaggedPreview = null;
                              });
                            }
                          },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    switch (_replayGainMode) {
                      'off' =>
                        l10n.playbackSettingsReplayGainModeOffDescription,
                      'smart' =>
                        l10n.playbackSettingsReplayGainModeSmartDescription,
                      'track' =>
                        l10n.playbackSettingsReplayGainModeTrackDescription,
                      _ => l10n.playbackSettingsReplayGainModeAlbumDescription,
                    },
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  ..._buildReplayGainCoverage(context, l10n),
                  if (_replayGainMode != 'off') ...[
                    const SizedBox(height: 12),
                    Text(
                      '${l10n.playbackSettingsReplayGainPreampLabel}: '
                      '${_replayGainPreamp.toStringAsFixed(1)} dB',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    NavisSlider(
                      value: _replayGainPreamp.clamp(
                        _minReplayGainPreamp,
                        _maxReplayGainPreamp,
                      ),
                      min: _minReplayGainPreamp,
                      max: _maxReplayGainPreamp,
                      divisions: 24,
                      label: '${_replayGainPreamp.toStringAsFixed(1)} dB',
                      onChanged: _isSaving
                          ? null
                          : (value) => setState(
                              () => _replayGainPreamp =
                                  _normalizeReplayGainPreamp(value),
                            ),
                    ),
                    Text(
                      switch (_replayGainPreamp) {
                        < 0 when boost =>
                          l10n.playbackSettingsReplayGainPreampSubtitleDownBoost,
                        0 when boost =>
                          l10n.playbackSettingsReplayGainPreampSubtitleZeroBoost,
                        _ when boost =>
                          l10n.playbackSettingsReplayGainPreampSubtitleUpBoost,
                        < 0 =>
                          l10n.playbackSettingsReplayGainPreampSubtitleDown,
                        0 => l10n.playbackSettingsReplayGainPreampSubtitleZero,
                        _ => l10n.playbackSettingsReplayGainPreampSubtitleUp,
                      },
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildUntaggedLevel(context, l10n),
                    const SizedBox(height: 4),
                    Text(
                      l10n.playbackSettingsReplayGainUntaggedSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const PlaybackAdjustmentPanel(),
                  const SizedBox(height: 24),
                  _buildExperimentalSection(context, l10n),
                  const SizedBox(height: 20),
                  Row(
                    children: <Widget>[
                      if (_isAutoSaving)
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      if (_isAutoSaving) const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _isAutoSaving
                              ? 'Saving changes...'
                              : 'Changes save automatically',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _isSaving ? null : _resetDefaults,
                    child: Text(l10n.playbackSettingsResetAction),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _qualityLabel(AppLocalizations l10n, int? value) {
    return value == null
        ? l10n.playbackSettingsQualityOriginal
        : l10n.playbackSettingsQualityKbps(value);
  }

  String _formatLabel(AppLocalizations l10n, String? value) {
    return value == null
        ? l10n.playbackSettingsFormatOriginal
        : value.toUpperCase();
  }

  Widget _buildExperimentalSection(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: NavisShapeData.of(context).mdAll,
      child: Column(
        children: <Widget>[
          InkWell(
            borderRadius: NavisShapeData.of(context).mdAll,
            onTap: () {
              setState(() {
                _experimentalExpanded = !_experimentalExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.science_outlined,
                    size: 22,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.playbackSettingsExperimentalTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  AnimatedRotation(
                    turns: _experimentalExpanded ? 0.5 : 0,
                    duration: MotionPolicy.of(context).surface,
                    curve: Curves.easeOutCubic,
                    child: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
            ),
          ),
          ClipRect(
            child: AnimatedAlign(
              alignment: Alignment.topCenter,
              heightFactor: _experimentalExpanded ? 1 : 0,
              duration: MotionPolicy.of(context).surface,
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: _experimentalExpanded ? 1 : 0,
                duration: MotionPolicy.of(context).surface,
                curve: Curves.easeOutCubic,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                  child: Column(
                    children: _buildExperimentalControls(context, l10n),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildExperimentalControls(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    return <Widget>[
      NavisSwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _matchFlowEnabled,
        onChanged: _isSaving
            ? null
            : (value) => setState(() => _matchFlowEnabled = value),
        title: Text(l10n.matchFlowTitle),
        subtitle: Text(l10n.matchFlowPlaybackSettingsSubtitle),
      ),
      if (_matchFlowEnabled)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.account_tree_outlined),
          title: Text(l10n.matchFlowManageTitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => NavService.openMatchFlow(context, ref),
        ),
    ];
  }

  /// How much of the library has ReplayGain data, what the rest plays at, and
  /// where the real fix is. Nothing while loading or for an empty library.
  List<Widget> _buildReplayGainCoverage(
    BuildContext context,
    AppLocalizations l10n,
  ) {
    final stats = ref.watch(replayGainLibraryGainsProvider).asData?.value;
    if (stats == null || stats.total == 0) return const <Widget>[];
    final level = effectiveReplayGainUntaggedDb(
      fixed: _replayGainUntaggedDb,
      auto: ref.watch(replayGainAutoUntaggedDbProvider),
    );
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.outline);
    return <Widget>[
      const SizedBox(height: 8),
      Text(
        l10n.playbackSettingsReplayGainCoverage(
          stats.withData * 100 ~/ stats.total,
          stats.total,
          stats.withData,
        ),
        style: style,
      ),
      Text(
        _replayGainMode == 'off'
            ? l10n.playbackSettingsReplayGainCoverageOff
            : l10n.playbackSettingsReplayGainCoverageRest(
                _replayGainUntaggedDb == null ? 'automatic' : 'fixed',
                _dbText(level),
              ),
        style: style,
      ),
      if (stats.withData < stats.total)
        Text(l10n.playbackSettingsReplayGainCoverageTip, style: style),
    ];
  }

  Widget _buildUntaggedLevel(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final autoAsync = ref.watch(replayGainAutoUntaggedDbProvider);
    final auto = effectiveReplayGainUntaggedDb(fixed: null, auto: autoAsync);
    final automatic = _replayGainUntaggedDb == null;
    // A preview only exists while a fixed level is being dragged.
    final level = automatic
        ? auto
        : (_untaggedPreview ?? _replayGainUntaggedDb ?? auto);
    String text(double db) =>
        l10n.playbackSettingsReplayGainUntaggedFixed(_dbText(db));

    void commit() {
      // Nothing to commit also keeps this safe when a stepper reports the end
      // of a hold from didUpdateWidget, during build.
      if (_untaggedPreview == null) return;
      setState(() {
        _replayGainUntaggedDb = _untaggedPreview;
        _untaggedPreview = null;
      });
    }

    Widget stepper({required bool up}) {
      return RulerStepButton(
        key: ValueKey<String>('replayGainUntagged-${up ? 'plus' : 'minus'}'),
        icon: up ? Icons.add : Icons.remove,
        tooltip: up
            ? l10n.playbackAdjustmentIncreaseBy(text(1))
            : l10n.playbackAdjustmentDecreaseBy(text(1)),
        // Stays enabled at the limits: onStep returns false there, which ends a
        // hold through the button's normal path (disabling it mid-hold would
        // end the hold during build).
        enabled: !automatic,
        onStep: () {
          if (_isSaving) return false;
          // A whole dB from wherever the ruler sits, like the pitch stepper's
          // semitone; the ruler itself does the fine moves.
          final current = _untaggedPreview ?? level;
          final target = _normalizeUntaggedDb(current + (up ? 1 : -1))!;
          if (target == current) return false;
          setState(() => _untaggedPreview = target);
          return true;
        },
        onEnd: commit,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        NavisSwitchListTile(
          key: const ValueKey<String>('replayGainUntagged-automatic'),
          contentPadding: EdgeInsets.zero,
          value: automatic,
          // Turning it off copies the automatic level, so wait until the
          // library level is known rather than store the fallback.
          onChanged: _isSaving || (automatic && !autoAsync.hasValue)
              ? null
              : (value) => setState(() {
                  _untaggedPreview = null;
                  _replayGainUntaggedDb = value
                      ? null
                      : _normalizeUntaggedDb(auto);
                }),
          title: Text(
            l10n.playbackSettingsReplayGainUntaggedAutomatic(_dbText(auto)),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Expanded(
              child: Text(
                l10n.playbackSettingsReplayGainUntaggedLabel,
                style: theme.textTheme.titleSmall,
              ),
            ),
            Flexible(
              child: Text(
                text(level),
                textAlign: TextAlign.end,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        // The painter puts lower values on the left in every locale, so the
        // row stays LTR like the other rulers.
        Row(
          textDirection: TextDirection.ltr,
          children: <Widget>[
            stepper(up: false),
            Expanded(
              child: AdjustmentRuler(
                key: const ValueKey<String>('replayGainUntagged-ruler'),
                // The pitch and speed ruler, counting in tens of dB: its
                // hundredth lines are 0.1 dB with a click each and its
                // labelled tenths are whole dB with a stronger tick. The value
                // is rounded to hundredths so it equals what the ruler asked
                // for: a mismatch would read as an outside change mid-drag.
                value: roundAdjustment(_normalizeUntaggedDb(level)! / 10),
                label: l10n.playbackSettingsReplayGainUntaggedLabel,
                valueLabel: text(level),
                onChanged: (value) =>
                    setState(() => _untaggedPreview = _tenthsDb(value)),
                onChangeEnd: commit,
                range: const AdjustmentRange(
                  minimum: replayGainMinUntaggedDb / 10,
                  maximum: 0,
                ),
                labelBuilder: (value) => text(_tenthsDb(value)),
                enabled: !automatic && !_isSaving,
                readOnly: automatic,
              ),
            ),
            stepper(up: true),
          ],
        ),
      ],
    );
  }

  void _hydrate(AppSettingsModel settings) {
    _wifiBitRate = settings.wifiMaxBitRate;
    _wifiFormat = settings.wifiFormat;
    _cellularBitRate = settings.cellularMaxBitRate;
    _cellularFormat = settings.cellularFormat;
    _cachedPlaybackFirst = settings.cachedPlaybackFirst;
    _scrobbleEnabled = settings.scrobbleEnabled;
    _gaplessEnabled = settings.gaplessEnabled || settings.crossfadeEnabled;
    _fastSeekingEnabled = settings.fastSeekingEnabled;
    _prefetchNextOnMobileData = settings.prefetchNextOnMobileData;
    _fullscreenModeLyrics = settings.skipSilenceEnabled;
    _albumQueueEnabled = settings.albumQueueEnabled;
    _likedQueueEnabled = settings.likedQueueEnabled;
    _matchFlowEnabled = settings.matchFlowEnabled;

    _crossfadeEnabled = settings.crossfadeEnabled;
    _crossfadeDurationSeconds = settings.crossfadeDurationSeconds;
    _crossfadeType = settings.crossfadeType;
    _replayGainMode = settings.replayGainMode;
    _replayGainPreamp = _normalizeReplayGainPreamp(settings.replayGainPreamp);
    _replayGainUntaggedDb = _normalizeUntaggedDb(settings.replayGainUntaggedDb);
    _untaggedPreview = null;
    _lastSavedSignature = _formSignature();
  }

  void _scheduleAutosave() {
    if (!_didHydrateForm || _isSaving) {
      return;
    }
    final signature = _formSignature();
    if (signature == _lastSavedSignature) {
      return;
    }
    _autosaveDebounce?.cancel();
    _autosaveDebounce = Timer(
      const Duration(milliseconds: 420),
      () => unawaited(_persistAutosave(signature)),
    );
  }

  String _formSignature() {
    return <Object?>[
      _wifiBitRate,
      _wifiFormat,
      _cellularBitRate,
      _cellularFormat,
      _cachedPlaybackFirst,
      _scrobbleEnabled,
      _gaplessEnabled,
      _fastSeekingEnabled,
      _prefetchNextOnMobileData,
      _fullscreenModeLyrics,

      _crossfadeEnabled,
      _crossfadeDurationSeconds,
      _crossfadeType,
      _replayGainMode,
      _replayGainPreamp,
      _replayGainUntaggedDb,
      _albumQueueEnabled,
      _likedQueueEnabled,
      _matchFlowEnabled,
    ].join('|');
  }

  Future<void> _persistAutosave(String signature) async {
    // A reset owns the settings row until it has re-hydrated the form.
    if (_isSaving) {
      return;
    }
    if (_isAutoSaving) {
      _pendingAutosave = true;
      return;
    }
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final done = _autosaveDone = Completer<void>();
    if (mounted) {
      setState(() => _isAutoSaving = true);
    }
    try {
      // Build on the stored row, never on defaults: the settings stream has
      // no value while it reloads, and this write replaces the whole row.
      final currentSettings =
          ref.read(appSettingsProvider).asData?.value ??
          await ref.read(settingsRepositoryProvider).getSettings();
      final wifiFormat = _normalizeFormat(_wifiFormat);
      final cellularFormat = _normalizeFormat(_cellularFormat);
      // Copy the stored row so fields owned by other screens (integrations,
      // ListenBrainz, sync and desktop volume) survive this general save.
      // Appearance and Home sections are protected by targeted-only writers.
      final settings = currentSettings.copyWith(
        wifiMaxBitRate: _wifiBitRate,
        clearWifiBitRate: _wifiBitRate == null,
        wifiFormat: wifiFormat,
        clearWifiFormat: wifiFormat == null,
        cellularMaxBitRate: _cellularBitRate,
        clearCellularBitRate: _cellularBitRate == null,
        cellularFormat: cellularFormat,
        clearCellularFormat: cellularFormat == null,
        cachedPlaybackFirst: _cachedPlaybackFirst,
        scrobbleEnabled: _scrobbleEnabled,
        gaplessEnabled: _gaplessEnabled || _crossfadeEnabled,
        fastSeekingEnabled: _fastSeekingEnabled,
        prefetchNextOnMobileData: _prefetchNextOnMobileData,
        skipSilenceEnabled: _fullscreenModeLyrics,
        crossfadeEnabled: _crossfadeEnabled,
        crossfadeDurationSeconds: _crossfadeDurationSeconds,
        crossfadeType: _crossfadeType,
        replayGainMode: _replayGainMode,
        replayGainPreamp: _normalizeReplayGainPreamp(_replayGainPreamp),
        replayGainUntaggedDb: _replayGainUntaggedDb,
        clearReplayGainUntaggedDb: _replayGainUntaggedDb == null,
        albumQueueEnabled: _albumQueueEnabled,
        matchFlowEnabled: _matchFlowEnabled,
        likedQueueEnabled: _likedQueueEnabled,
      );
      await ref.read(settingsRepositoryProvider).saveSettings(settings);
      final handler = ref.read(audioHandlerProvider);
      if (handler != null) {
        await handler.applyRuntimeSettings();
      }
      _lastSavedSignature = signature;
    } on Object {
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context)!;
      showAppNotice(
        context,
        message: l10n.playbackSettingsSaveFailure,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isAutoSaving = false);
      }
      done.complete();
      if (_pendingAutosave) {
        _pendingAutosave = false;
        _scheduleAutosave();
      }
    }
  }

  Future<void> _setPrefetchNextOnMobileData(bool value) async {
    if (!value) {
      final l10n = AppLocalizations.of(context)!;
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.playbackSettingsPrefetchNextOffTitle,
        message: l10n.playbackSettingsPrefetchNextOffMessage,
        confirmLabel: l10n.playbackSettingsPrefetchNextOffConfirm,
      );
      if (!confirmed || !mounted) return;
    }
    setState(() => _prefetchNextOnMobileData = value);
  }

  void _setGaplessEnabled(bool value) {
    setState(() {
      _gaplessEnabled = value;
      if (!value && _crossfadeEnabled) {
        _crossfadeEnabled = false;
      }
    });
  }

  void _setCrossfadeEnabled(bool value) {
    setState(() {
      _crossfadeEnabled = value;
      if (value) {
        _gaplessEnabled = true;
      }
    });
  }

  Future<void> _resetDefaults() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isSaving = true);
    // Drop the queued autosave and let a running one finish first, so neither
    // can write the old form values back over the defaults.
    _autosaveDebounce?.cancel();
    _pendingAutosave = false;
    // Read everything before the first await: leaving the page while a save
    // drains must not cancel the reset, and ref is unusable once disposed.
    final repository = ref.read(settingsRepositoryProvider);
    final adjustments = ref.read(playbackAdjustmentsProvider.notifier);
    final equalizer = ref.read(equalizerProvider.notifier);
    final handler = ref.read(audioHandlerProvider);
    try {
      await _autosaveDone?.future;
      await repository.resetPlaybackDefaults();
      await adjustments.selectPreset(PlaybackPreset.noneId);
      await equalizer.reset();
      final persisted = await repository.getSettings();
      if (handler != null) {
        await handler.applyRuntimeSettings();
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _hydrate(persisted);
      });
      showAppNotice(
        context,
        message: l10n.playbackSettingsResetSuccess,
        level: AppNoticeLevel.success,
      );
    } on Object {
      if (!mounted) {
        return;
      }
      showAppNotice(
        context,
        message: l10n.playbackSettingsResetFailure,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  String? _normalizeFormat(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.toLowerCase();
  }

  /// A stored level outside the ruler (or finer than 0.1 dB) snaps to the
  /// nearest tenth of a dB on it; null stays Automatic.
  double? _normalizeUntaggedDb(double? value) => value == null
      ? null
      : (value.clamp(replayGainMinUntaggedDb, 0.0) * 10).round() / 10;

  /// dB for a ruler value in tens of dB, rounded so float noise never shows
  /// or reaches storage.
  double _tenthsDb(double tens) => (tens * 100).round() / 10;

  /// Rounds to the ruler's tenth first, so an Automatic level such as -0.04
  /// reads "0", never "-0.0".
  String _dbText(double db) {
    final tenths = (db * 10).round() / 10;
    return tenths.toStringAsFixed(tenths == tenths.roundToDouble() ? 0 : 1);
  }

  double _normalizeReplayGainPreamp(double value) {
    return value.clamp(_minReplayGainPreamp, _maxReplayGainPreamp);
  }

  @override
  void dispose() {
    _autosaveDebounce?.cancel();
    if (_didHydrateForm) {
      final signature = _formSignature();
      if (signature != _lastSavedSignature) {
        unawaited(_persistAutosave(signature));
      }
    }
    super.dispose();
  }
}
