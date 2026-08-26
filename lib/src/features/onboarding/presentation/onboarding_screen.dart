import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/settings/presentation/appearance_settings_screen.dart';
import 'package:navis/src/features/settings/presentation/listenbrainz_connection_status.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// A deliberately shell-free, one-time customization experience.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.reviewMode = false});

  final bool reviewMode;

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
  }

  @override
  void dispose() {
    _lastFmKey.dispose();
    _listenBrainzToken.dispose();
    for (final controller in _stepScrollControllers) {
      controller.dispose();
    }
    super.dispose();
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
      await ref
          .read(navisDatabaseProvider)
          .appSettingsDao
          .completeOnboarding(currentOnboardingVersion);
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 260));
      if (!mounted) return;
      context.go(widget.reviewMode ? '/settings' : '/');
    } on Object {
      if (mounted) {
        setState(() => _serviceError = 'Could not save setup. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _skip() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Skip customization?'),
        content: const Text(
          'Your current settings will be kept. You can reopen this from Settings at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep customizing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Skip setup'),
          ),
        ],
      ),
    );
    if (discard == true) {
      await _finish(discardDraft: true);
    }
  }

  Future<void> _saveLastFm() async {
    final current = _draft;
    final key = _lastFmKey.text.trim();
    if (current == null || _lastFmBusy) return;
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
          throw StateError(result.message ?? 'Invalid Last.fm API key.');
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
    if (token.isEmpty) {
      setState(() => _serviceError = 'Enter a ListenBrainz user token.');
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
      if (!details.valid) throw StateError('Invalid ListenBrainz token.');
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
                                  ? 'Customize Navis'
                                  : 'Make Navis yours',
                              textAlign: TextAlign.center,
                              style: previewTheme.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Step ${_step + 1} of $_steps',
                              textAlign: TextAlign.center,
                              semanticsLabel:
                                  'Customization step ${_step + 1} of $_steps',
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
                                            ? 'Customize Navis'
                                            : 'Make Navis yours',
                                        style: previewTheme
                                            .textTheme
                                            .headlineSmall,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Step ${_step + 1} of $_steps',
                                        semanticsLabel:
                                            'Customization step ${_step + 1} of $_steps',
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
    final skip = TextButton(
      onPressed: _saving ? null : _skip,
      child: const Text('Skip setup'),
    );
    final back = _step > 0
        ? TextButton(
            onPressed: _saving ? null : () => setState(() => _step--),
            child: const Text('Back'),
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
          : Text(_step == _steps - 1 ? 'Finish' : 'Continue'),
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
    final customPresets = _draftCustomPresets ?? const <int>[];
    return _scrollStep(
      children: [
        Text('Choose your look', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Pick a theme and accent. You can change both later in Appearance settings.',
        ),
        const SizedBox(height: 16),
        ThemeModeSelector(
          currentMode: draft.themeMode,
          onChanged: (value) =>
              setState(() => _draft = draft.copyWith(themeMode: value)),
        ),
        const SizedBox(height: 24),
        Text('Accent color', style: Theme.of(context).textTheme.titleMedium),
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
          'This is the full color picker from Appearance settings. You can revisit it there at any time.',
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
                          'Scroll for more options',
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

  Widget _listeningStep(AppSettingsModel draft) => _scrollStep(
    children: [
      Text(
        'Tune your listening',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      const Text(
        'Choose stream quality, formats, local playback priority, and track transitions.',
      ),
      const SizedBox(height: 16),
      _qualityField(
        'Wi-Fi quality',
        draft.wifiMaxBitRate,
        (value) => setState(
          () => _draft = draft.copyWith(
            wifiMaxBitRate: value,
            clearWifiBitRate: value == null,
          ),
        ),
      ),
      _formatField(
        'Wi-Fi format',
        draft.wifiFormat,
        (value) => setState(
          () => _draft = draft.copyWith(
            wifiFormat: value,
            clearWifiFormat: value == null,
          ),
        ),
      ),
      _qualityField(
        'Mobile quality',
        draft.cellularMaxBitRate,
        (value) => setState(
          () => _draft = draft.copyWith(
            cellularMaxBitRate: value,
            clearCellularBitRate: value == null,
          ),
        ),
      ),
      _formatField(
        'Mobile format',
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
        title: const Text('Prefer downloaded or cached audio'),
        subtitle: const Text(
          'Use a complete local copy before streaming when one is available.',
        ),
        value: draft.cachedPlaybackFirst,
        onChanged: (value) =>
            setState(() => _draft = draft.copyWith(cachedPlaybackFirst: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Scrobble to your music server'),
        subtitle: const Text(
          'Report now-playing and completed plays to your Subsonic server.',
        ),
        value: draft.scrobbleEnabled,
        onChanged: (value) =>
            setState(() => _draft = draft.copyWith(scrobbleEnabled: value)),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Gapless playback'),
        subtitle: const Text('Move between tracks without an added pause.'),
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
          title: const Text('Crossfade'),
          subtitle: const Text('Blend the end of a track into the next one.'),
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
            'Crossfade duration: ${draft.crossfadeDurationSeconds} seconds',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Slider(
            value: draft.crossfadeDurationSeconds.toDouble(),
            min: 1,
            max: 12,
            divisions: 11,
            label: '${draft.crossfadeDurationSeconds}s',
            onChanged: (value) => setState(
              () => _draft = draft.copyWith(
                crossfadeDurationSeconds: value.round(),
              ),
            ),
          ),
          DropdownButtonFormField<String>(
            initialValue: draft.crossfadeType,
            decoration: const InputDecoration(labelText: 'Crossfade type'),
            items: const [
              DropdownMenuItem(value: 'normal', child: Text('Normal')),
              DropdownMenuItem(
                value: 'smart',
                child: Text('Smart — only between different albums'),
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
                ? 'Smart avoids blending tracks from the same album.'
                : 'Normal blends every eligible track transition.',
          ),
        ],
      ],
    ],
  );

  Widget _qualityField(
    String label,
    int? value,
    ValueChanged<int?> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<int?>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: const [
        DropdownMenuItem(value: null, child: Text('Server default')),
        DropdownMenuItem(value: 320, child: Text('320 kbps')),
        DropdownMenuItem(value: 256, child: Text('256 kbps')),
        DropdownMenuItem(value: 192, child: Text('192 kbps')),
        DropdownMenuItem(value: 128, child: Text('128 kbps')),
        DropdownMenuItem(value: 96, child: Text('96 kbps')),
      ],
      onChanged: (v) => onChanged(v),
    ),
  );

  Widget _formatField(
    String label,
    String? value,
    ValueChanged<String?> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String?>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: const [
        DropdownMenuItem(value: null, child: Text('Server default')),
        DropdownMenuItem(value: 'mp3', child: Text('MP3')),
        DropdownMenuItem(value: 'aac', child: Text('AAC')),
        DropdownMenuItem(value: 'opus', child: Text('Opus')),
      ],
      onChanged: onChanged,
    ),
  );

  Widget _queueStep(AppSettingsModel draft) => _scrollStep(
    children: [
      Text(
        'Queue and downloads',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      const Text(
        'Control what happens when you play a track and when downloads can run.',
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Queue whole albums'),
        subtitle: const Text(
          'Playing a track from an album queues the album from that track.',
        ),
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
        title: const Text('Queue all liked songs'),
        subtitle: Text(
          draft.albumQueueEnabled
              ? 'On the Liked page, start from the selected song.'
              : 'Enable album queueing to use this option.',
        ),
        value: draft.likedQueueEnabled,
        onChanged: draft.albumQueueEnabled
            ? (v) =>
                  setState(() => _draft = draft.copyWith(likedQueueEnabled: v))
            : null,
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Download only on Wi-Fi'),
        subtitle: const Text(
          'Avoid downloading music over a metered connection.',
        ),
        value: draft.wifiOnlyDownloads,
        onChanged: (v) =>
            setState(() => _draft = draft.copyWith(wifiOnlyDownloads: v)),
      ),
    ],
  );

  Widget _servicesStep(AppSettingsModel draft) {
    final bundled = ref.watch(lastFmBundledKeyProvider);
    return _scrollStep(
      children: [
        Text(
          'Optional music services',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'These services are optional. You can configure or remove them later in Settings.',
        ),
        const SizedBox(height: 16),
        Text('ListenBrainz', style: Theme.of(context).textTheme.titleMedium),
        const Text(
          'When enabled, Navis sends track, artist, album, duration, play time, and now-playing activity to ListenBrainz. Your token stays in secure device storage.',
        ),
        TextField(
          controller: _listenBrainzToken,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'ListenBrainz user token',
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => launchUrl(
            Uri.parse('https://listenbrainz.org/profile/'),
            mode: LaunchMode.externalApplication,
          ),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Get a ListenBrainz user token'),
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
                _listenBrainzBusy ? 'Validating…' : 'Validate and connect',
              ),
            ),
          ),
        const Divider(height: 40),
        Text('Last.fm', style: Theme.of(context).textTheme.titleMedium),
        Text(
          bundled
              ? 'This build already includes a Last.fm API key. Same Vibes similar-song queues and artist top tracks are available; Last.fm scrobbling is not enabled.'
              : 'A Last.fm API key enables Same Vibes similar-song queues and artist top tracks. It does not enable Last.fm scrobbling.',
        ),
        if (!bundled) ...[
          TextField(
            controller: _lastFmKey,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Last.fm API key'),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: _lastFmBusy ? null : _saveLastFm,
                child: Text(_lastFmBusy ? 'Validating…' : 'Validate key'),
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://www.last.fm/api/accounts'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('Get API key'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
