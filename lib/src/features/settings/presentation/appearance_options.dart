import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/new_feature_tag.dart';
import 'package:navis/src/features/onboarding/domain/setup_highlights.dart';
import 'package:navis/src/features/onboarding/presentation/setup_highlights_provider.dart';
import 'package:navis/src/features/settings/presentation/appearance_layout.dart';
import 'package:navis/src/features/settings/presentation/color_style_selector.dart';
import 'package:navis/src/features/settings/domain/flat_areas.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/night_schedule.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// The setup highlights that were pending when the user entered an
/// Appearance screen (Settings or the setup step).
///
/// Tags render from this snapshot for the whole visit, so a tag stays visible
/// while the user is looking at it even though `markOptionSeen` clears it from
/// `pendingSetupHighlightsProvider` immediately; the next visit starts from the
/// cleared set. Highlights that become pending later in the same visit (the
/// provider loading) join the snapshot; nothing ever leaves it.
class AppearanceVisitScope extends ConsumerStatefulWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppearanceVisitScope> createState() =>
      _AppearanceVisitScopeState();

  /// The visit's tagged highlights, or null outside a scope.
  static Set<SetupHighlight>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_AppearanceVisitData>()
      ?.snapshot;

  /// Whether [highlight] is tagged for the current visit. Outside a scope it
  /// follows the live provider.
  static bool isTagged(
    BuildContext context,
    WidgetRef ref,
    SetupHighlight highlight,
  ) {
    final visit = maybeOf(context);
    if (visit != null) return visit.contains(highlight);
    return ref.watch(pendingSetupHighlightsProvider).contains(highlight);
  }
}

class _AppearanceVisitScopeState extends ConsumerState<AppearanceVisitScope> {
  Set<SetupHighlight> _snapshot = const <SetupHighlight>{};

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingSetupHighlightsProvider);
    if (!_snapshot.containsAll(pending)) {
      _snapshot = Set<SetupHighlight>.unmodifiable(<SetupHighlight>{
        ..._snapshot,
        ...pending,
      });
    }
    return _AppearanceVisitData(snapshot: _snapshot, child: widget.child);
  }
}

class _AppearanceVisitData extends InheritedWidget {
  const new({required this.snapshot, required super.child});

  final Set<SetupHighlight> snapshot;

  @override
  bool updateShouldNotify(_AppearanceVisitData oldWidget) =>
      !identical(snapshot, oldWidget.snapshot);
}

/// Wraps one setup-highlighted option: supplies its "New" tag for the visit
/// ([AppearanceVisitScope]) and records it with `markOptionSeen` once the
/// option has actually been on screen (at least half visible, once per visit).
///
/// Untagged options render [builder]'s result untouched, so only options that
/// can still clear carry a visibility detector.
class HighlightedAppearanceOption extends ConsumerStatefulWidget {
  const new({required this.highlight, required this.builder, super.key});

  final SetupHighlight highlight;
  final Widget Function(BuildContext context, Widget? adornment) builder;

  @override
  ConsumerState<HighlightedAppearanceOption> createState() =>
      _HighlightedAppearanceOptionState();
}

class _HighlightedAppearanceOptionState
    extends ConsumerState<HighlightedAppearanceOption> {
  var _marked = false;

  void _onVisibility(VisibilityInfo info) {
    if (_marked || !mounted || info.visibleFraction < 0.5) return;
    if (!ref.read(pendingSetupHighlightsProvider).contains(widget.highlight)) {
      return;
    }
    _marked = true;
    unawaited(
      ref
          .read(setupHighlightsServiceProvider)
          .markOptionSeen(widget.highlight)
          .catchError((Object error) {
            AppLogger.warning(
              'Could not clear the ${widget.highlight.name} tag: $error',
            );
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tagged = AppearanceVisitScope.isTagged(
      context,
      ref,
      widget.highlight,
    );
    final child = widget.builder(
      context,
      tagged ? const NewFeatureTag() : null,
    );
    if (!tagged) return child;
    return VisibilityDetector(
      key: ValueKey<String>('setupHighlight-${widget.highlight.storageKey}'),
      onVisibilityChanged: _onVisibility,
      child: child,
    );
  }
}

/// A switch title with an optional [adornment] (such as a "New" tag) beside
/// it. Without an adornment it is the plain title, so rows keep their height.
Widget _titleWithAdornment(String text, Widget? adornment) {
  if (adornment == null) return Text(text);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Flexible(child: Text(text)),
      const SizedBox(width: NavisSpace.xs),
      adornment,
    ],
  );
}

/// Shows [child] under its parent control, animating the height change
/// unless the platform asks for reduced motion.
class AppearanceSubOptionReveal extends StatelessWidget {
  const new({required this.visible, required this.child, super.key});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: MotionPolicy.of(context).surface,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: visible ? child : const SizedBox(width: double.infinity),
    );
  }
}

/// "Use OLED when dark" for Auto mode, revealed under the theme mode picker
/// while [visible]. Shared by Appearance settings and setup.
class OledForAutoOption extends StatelessWidget {
  const new({
    required this.visible,
    required this.value,
    required this.onChanged,
    this.adornment,
    super.key,
  });

  final bool visible;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppearanceSubOptionReveal(
      visible: visible,
      child: SwitchListTile(
        contentPadding: EdgeInsetsDirectional.only(
          start: AppearanceLayout.subOptionInsetOf(context),
          end: AppearanceLayout.gutterOf(context),
        ),
        title: _titleWithAdornment(l10n.appearanceOledForAutoLabel, adornment),
        subtitle: Text(l10n.appearanceOledForAutoSub),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

/// Flat Surfaces switch. Shared by Appearance settings and setup.
class FlatSurfacesOption extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.adornment,
    super.key,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SwitchListTile(
      contentPadding: appearanceSwitchPadding(context),
      title: _titleWithAdornment(l10n.appearanceFlatSurfacesLabel, adornment),
      subtitle: Text(l10n.appearanceFlatSurfacesSub),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// The areas Flat Surfaces applies to, revealed under the Flat Surfaces
/// switch while [visible]. The tag, if any, sits on the first switch. Shared
/// by Appearance settings and setup.
class FlatAreasOption extends StatelessWidget {
  const new({
    required this.visible,
    required this.value,
    required this.onChanged,
    this.adornment,
    super.key,
  });

  final bool visible;
  final FlatAreas value;
  final ValueChanged<FlatAreas> onChanged;

  /// Shown beside the first title, for example a "New" tag.
  final Widget? adornment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget area({
      required Key key,
      required String title,
      required String subtitle,
      required bool selected,
      required ValueChanged<bool> onChanged,
      Widget? adornment,
    }) => SwitchListTile(
      key: key,
      contentPadding: EdgeInsetsDirectional.only(
        start: AppearanceLayout.subOptionInsetOf(context),
        end: AppearanceLayout.gutterOf(context),
      ),
      title: _titleWithAdornment(title, adornment),
      subtitle: Text(subtitle),
      value: selected,
      onChanged: onChanged,
    );
    return AppearanceSubOptionReveal(
      visible: visible,
      child: Column(
        children: <Widget>[
          area(
            key: const ValueKey<String>('flatAreaSurfaces'),
            title: l10n.appearanceFlatAreaSurfacesLabel,
            subtitle: l10n.appearanceFlatAreaSurfacesSub,
            selected: value.surfaces,
            adornment: adornment,
            onChanged: (selected) =>
                onChanged(value.copyWith(surfaces: selected)),
          ),
          area(
            key: const ValueKey<String>('flatAreaNowPlaying'),
            title: l10n.appearanceFlatAreaNowPlayingLabel,
            subtitle: l10n.appearanceFlatAreaNowPlayingSub,
            selected: value.nowPlaying,
            onChanged: (selected) =>
                onChanged(value.copyWith(nowPlaying: selected)),
          ),
          area(
            key: const ValueKey<String>('flatAreaArtworkText'),
            title: l10n.appearanceFlatAreaArtworkTextLabel,
            subtitle: l10n.appearanceFlatAreaArtworkTextSub,
            selected: value.artworkText,
            onChanged: (selected) =>
                onChanged(value.copyWith(artworkText: selected)),
          ),
        ],
      ),
    );
  }
}

/// Album Art Colored Shade switch. Disabled with a note while Flat text over
/// artwork puts album titles below the art. Shared by Appearance settings and
/// setup.
class AlbumArtColoredShadeOption extends StatelessWidget {
  const new({
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.adornment,
    super.key,
  });

  final bool value;

  /// False while the titles sit below the art, where there is nothing to tint.
  final bool enabled;
  final ValueChanged<bool> onChanged;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SwitchListTile(
      contentPadding: appearanceSwitchPadding(context),
      title: _titleWithAdornment(
        l10n.appearanceAlbumArtColoredShadeLabel,
        adornment,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.appearanceAlbumArtColoredShadeSub),
          if (!enabled) Text(l10n.appearanceAlbumArtColoredShadeFlatNote),
        ],
      ),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}

/// Night schedule switch with its start and end rows.
///
/// Callback-driven: the caller persists or drafts each change. [now] decides
/// whether the "Night is on until" note shows.
class NightScheduleSection extends StatelessWidget {
  const new({
    required this.schedule,
    required this.userStyle,
    required this.now,
    required this.onChanged,
    this.adornment,
    super.key,
  });

  final NightSchedule schedule;

  /// The style the user chose, not the scheduled override.
  final NavisColorStyle userStyle;
  final DateTime now;
  final ValueChanged<NightSchedule> onChanged;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final use24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    String format(int minutes) => localizations.formatTimeOfDay(
      TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
      alwaysUse24HourFormat: use24Hour,
    );
    final sameTimes = schedule.startMinutes == schedule.endMinutes;
    final alreadyNight = userStyle == NavisColorStyle.night;
    final showActiveNote = schedule.isActiveAt(now) && !alreadyNight;
    final sub = alreadyNight
        ? l10n.appearanceNightScheduleAlreadyNight
        : l10n.appearanceNightScheduleSub(
            format(schedule.startMinutes),
            format(schedule.endMinutes),
          );

    Future<void> pick({required bool isStart}) async {
      final current = isStart ? schedule.startMinutes : schedule.endMinutes;
      final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      );
      if (picked == null) return;
      final minutes = picked.hour * 60 + picked.minute;
      onChanged(
        NightSchedule(
          enabled: schedule.enabled,
          startMinutes: isStart ? minutes : schedule.startMinutes,
          endMinutes: isStart ? schedule.endMinutes : minutes,
        ),
      );
    }

    Widget note(String text) => Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        AppearanceLayout.subOptionInsetOf(context),
        0,
        AppearanceLayout.gutterOf(context),
        NavisSpace.xs,
      ),
      child: Text(text, style: theme.textTheme.bodySmall),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SwitchListTile(
          contentPadding: appearanceSwitchPadding(context),
          title: _titleWithAdornment(
            l10n.appearanceNightScheduleLabel,
            adornment,
          ),
          // The time pills below already show the window once it is on. The
          // switch is only locked while off: with Night as the style it has
          // nothing to schedule, but an enabled schedule must stay removable.
          subtitle: schedule.enabled && !alreadyNight ? null : Text(sub),
          value: schedule.enabled,
          onChanged: alreadyNight && !schedule.enabled
              ? null
              : (enabled) => onChanged(
                  NightSchedule(
                    enabled: enabled,
                    startMinutes: schedule.startMinutes,
                    endMinutes: schedule.endMinutes,
                  ),
                ),
        ),
        AppearanceSubOptionReveal(
          visible: schedule.enabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _ScheduleWindowRow(
                startLabel: format(schedule.startMinutes),
                endLabel: format(schedule.endMinutes),
                startSemantics: l10n.appearanceNightScheduleStartsAt(
                  format(schedule.startMinutes),
                ),
                endSemantics: l10n.appearanceNightScheduleEndsAt(
                  format(schedule.endMinutes),
                ),
                onPickStart: () => pick(isStart: true),
                onPickEnd: () => pick(isStart: false),
              ),
              if (sameTimes) note(l10n.appearanceNightScheduleSameTimes),
              if (showActiveNote)
                note(
                  l10n.appearanceNightScheduleActiveNote(
                    format(schedule.endMinutes),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One row holding the night window: moon, start pill, arrow, end pill.
class _ScheduleWindowRow extends StatelessWidget {
  const new({
    required this.startLabel,
    required this.endLabel,
    required this.startSemantics,
    required this.endSemantics,
    required this.onPickStart,
    required this.onPickEnd,
  });

  final String startLabel;
  final String endLabel;
  final String startSemantics;
  final String endSemantics;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(String label, String semantics, VoidCallback onTap) {
      return Semantics(
        label: semantics,
        button: true,
        excludeSemantics: true,
        onTap: onTap,
        child: ActionChip(
          key: ValueKey<String>(semantics),
          label: Text(label),
          onPressed: onTap,
        ),
      );
    }

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        AppearanceLayout.subOptionInsetOf(context),
        NavisSpace.xxs,
        AppearanceLayout.gutterOf(context),
        NavisSpace.xs,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: NavisSpace.xs,
        runSpacing: NavisSpace.xxs,
        children: <Widget>[
          Icon(
            Icons.bedtime_outlined,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          pill(startLabel, startSemantics, onPickStart),
          Icon(Icons.arrow_forward, size: 16, color: scheme.onSurfaceVariant),
          pill(endLabel, endSemantics, onPickEnd),
        ],
      ),
    );
  }
}

/// A titled option with an optional [adornment] (a "New" tag), a one-line
/// [description] and a [selector] below. Shared by Appearance settings and
/// setup, which differ only in their [AppearanceLayout].
class AppearanceChoiceSection extends StatelessWidget {
  const new({
    required this.title,
    required this.selector,
    this.description,
    this.adornment,
    this.topPadding = NavisSpace.xs,
    this.note,
    super.key,
  });

  final String title;
  final String? description;
  final Widget selector;
  final Widget? adornment;

  /// Space above the title; Corner Style sits below a switch and needs more.
  final double topPadding;

  /// Optional line under the selector.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = AppearanceLayout.gutterOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppearanceHeading(
          title: title,
          adornment: adornment,
          topPadding: topPadding,
        ),
        if (description != null)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: gutter,
              vertical: NavisSpace.xxs,
            ),
            child: AnimatedSize(
              duration: MotionPolicy.of(context).surface,
              alignment: Alignment.topLeft,
              child: Text(description!, style: theme.textTheme.bodySmall),
            ),
          ),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: gutter,
            vertical: NavisSpace.xs,
          ),
          child: SizedBox(width: double.infinity, child: selector),
        ),
        if (note != null)
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, NavisSpace.xs),
            child: Text(note!, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

/// Now Playing Background: Art-Tinted, Artwork or Plain, with a description
/// of the selected look. Shared by Appearance settings and setup.
class NowPlayingBackgroundOption extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.adornment,
    this.oled = false,
    this.flat = false,
    super.key,
  });

  final NowPlayingBackground value;
  final ValueChanged<NowPlayingBackground> onChanged;

  /// Whether OLED is the active dark theme. With [flat] it shows a note that
  /// Now Playing stays black for every background.
  final bool oled;
  final bool flat;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppearanceChoiceSection(
      title: l10n.appearanceNowPlayingBackgroundLabel,
      adornment: adornment,
      note: oled && flat
          ? l10n.appearanceNowPlayingBackgroundOledFlatNote
          : null,
      description: switch (value) {
        NowPlayingBackground.tinted =>
          l10n.appearanceNowPlayingBackgroundTintedSub,
        NowPlayingBackground.artwork =>
          l10n.appearanceNowPlayingBackgroundArtworkSub,
        NowPlayingBackground.plain =>
          l10n.appearanceNowPlayingBackgroundPlainSub,
      },
      selector: SegmentedButton<NowPlayingBackground>(
        key: const ValueKey<String>('nowPlayingBackgroundSelector'),
        showSelectedIcon: false,
        expandedInsets: EdgeInsets.zero,
        segments: <ButtonSegment<NowPlayingBackground>>[
          ButtonSegment<NowPlayingBackground>(
            value: NowPlayingBackground.tinted,
            label: Text(
              l10n.appearanceNowPlayingBackgroundTinted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ButtonSegment<NowPlayingBackground>(
            value: NowPlayingBackground.artwork,
            label: Text(
              l10n.appearanceNowPlayingBackgroundArtwork,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ButtonSegment<NowPlayingBackground>(
            value: NowPlayingBackground.plain,
            label: Text(
              l10n.appearanceNowPlayingBackgroundPlain,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        selected: <NowPlayingBackground>{value},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// Density: Comfortable or Compact spacing for Home, track lists and library
/// rows. Shared by Appearance settings and setup.
class DensityOption extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.adornment,
    super.key,
  });

  final NavisDensity value;
  final ValueChanged<NavisDensity> onChanged;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppearanceChoiceSection(
      title: l10n.appearanceDensityLabel,
      adornment: adornment,
      description: l10n.appearanceDensitySub,
      selector: SegmentedButton<NavisDensity>(
        key: const ValueKey<String>('densitySelector'),
        showSelectedIcon: false,
        expandedInsets: EdgeInsets.zero,
        segments: <ButtonSegment<NavisDensity>>[
          ButtonSegment<NavisDensity>(
            value: NavisDensity.comfortable,
            icon: const Icon(Icons.view_agenda_outlined),
            label: Text(
              l10n.appearanceDensityComfortable,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ButtonSegment<NavisDensity>(
            value: NavisDensity.compact,
            icon: const Icon(Icons.view_compact_alt_outlined),
            label: Text(
              l10n.appearanceDensityCompact,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        selected: <NavisDensity>{value},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// Corner Style: Pill, Soft or Square corners for cards, buttons and
/// panels, with a small corner glyph on each choice. Shared by Appearance
/// settings and setup.
class CornerStyleOption extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.adornment,
    super.key,
  });

  final NavisCornerStyle value;
  final ValueChanged<NavisCornerStyle> onChanged;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    String name(NavisCornerStyle style) => switch (style) {
      NavisCornerStyle.rounded => l10n.appearanceCornerStyleRounded,
      NavisCornerStyle.soft => l10n.appearanceCornerStyleSoft,
      NavisCornerStyle.square => l10n.appearanceCornerStyleSquare,
    };
    // The glyph is a small button-shaped tile drawn from the style's control
    // corner (scaled down, capped at half its height) so Pill reads as a
    // stadium, Soft as a rounded rectangle and Square as nearly sharp.
    Widget glyph(NavisCornerStyle style) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(
          math.min(NavisShapeData.forStyle(style).control / 2.5, 9),
        ),
        border: Border.all(color: scheme.onSurface, width: 2),
      ),
      child: const SizedBox(width: 30, height: 18),
    );
    return AppearanceChoiceSection(
      title: l10n.appearanceCornerStyleLabel,
      adornment: adornment,
      topPadding: NavisSpace.md,
      description:
          '${switch (value) {
            NavisCornerStyle.rounded => l10n.appearanceCornerStyleRoundedSub,
            NavisCornerStyle.soft => l10n.appearanceCornerStyleSoftSub,
            NavisCornerStyle.square => l10n.appearanceCornerStyleSquareSub,
          }}\n${l10n.appearanceCornerStyleArtworkNote}',
      selector: SegmentedButton<NavisCornerStyle>(
        key: const ValueKey<String>('cornerStyleSelector'),
        showSelectedIcon: false,
        expandedInsets: EdgeInsets.zero,
        segments: <ButtonSegment<NavisCornerStyle>>[
          for (final style in NavisCornerStyle.values)
            ButtonSegment<NavisCornerStyle>(
              value: style,
              icon: glyph(style),
              label: Text(
                name(style),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        selected: <NavisCornerStyle>{value},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// The options that Settings and setup both show, in the order they share.
///
/// Setup lists them under "More appearance options" except Night Schedule,
/// which sits beside Color Style; Settings spreads them over its Theme, Color,
/// Shape & Layout and Now Playing sections. Both keep this relative order,
/// which a test pins.
enum AppearanceOptionKind {
  oledForAuto(SetupHighlight.oledForAuto),
  nightSchedule(SetupHighlight.nightSchedule),
  flatSurfaces(SetupHighlight.flatSurfaces),
  cornerStyle(SetupHighlight.cornerStyle),
  density(null),
  nowPlayingBackground(SetupHighlight.nowPlayingBackground);

  new(this.highlight);

  /// The setup highlight that tags this option, or null for a renamed one.
  final SetupHighlight? highlight;
}

/// Values and callbacks for the options in [AppearanceOptionKind], built by
/// Settings from providers and by setup from its draft, so both render the
/// same widgets with the same tags.
class AppearanceOptionSet {
  const new({
    required this.oledForAutoVisible,
    required this.oledForAuto,
    required this.onOledForAutoChanged,
    required this.nightSchedule,
    required this.userStyle,
    required this.now,
    required this.onNightScheduleChanged,
    required this.flatSurfaces,
    required this.onFlatSurfacesChanged,
    required this.flatAreas,
    required this.onFlatAreasChanged,
    required this.albumArtColoredShade,
    required this.onAlbumArtColoredShadeChanged,
    required this.cornerStyle,
    required this.onCornerStyleChanged,
    required this.density,
    required this.onDensityChanged,
    required this.nowPlayingBackground,
    required this.onNowPlayingBackgroundChanged,
    required this.previewOled,
  });

  /// Whether the OLED switch applies (Auto theme mode).
  final bool oledForAutoVisible;
  final bool oledForAuto;
  final ValueChanged<bool> onOledForAutoChanged;
  final NightSchedule nightSchedule;
  final NavisColorStyle userStyle;
  final DateTime now;
  final ValueChanged<NightSchedule> onNightScheduleChanged;
  final bool flatSurfaces;
  final ValueChanged<bool> onFlatSurfacesChanged;
  final FlatAreas flatAreas;
  final ValueChanged<FlatAreas> onFlatAreasChanged;
  final bool albumArtColoredShade;
  final ValueChanged<bool> onAlbumArtColoredShadeChanged;
  final NavisCornerStyle cornerStyle;
  final ValueChanged<NavisCornerStyle> onCornerStyleChanged;
  final NavisDensity density;
  final ValueChanged<NavisDensity> onDensityChanged;
  final NowPlayingBackground nowPlayingBackground;
  final ValueChanged<NowPlayingBackground> onNowPlayingBackgroundChanged;

  /// Whether the previewed dark theme is OLED (for the Now Playing note).
  final bool previewOled;

  static Widget _tagged(
    SetupHighlight highlight,
    Widget Function(Widget? adornment) builder,
  ) => HighlightedAppearanceOption(
    highlight: highlight,
    builder: (context, adornment) => builder(adornment),
  );

  Widget build(AppearanceOptionKind kind) {
    return switch (kind) {
      AppearanceOptionKind.oledForAuto => _tagged(
        SetupHighlight.oledForAuto,
        (adornment) => OledForAutoOption(
          visible: oledForAutoVisible,
          value: oledForAuto,
          adornment: adornment,
          onChanged: onOledForAutoChanged,
        ),
      ),
      AppearanceOptionKind.nightSchedule => _tagged(
        SetupHighlight.nightSchedule,
        (adornment) => NightScheduleSection(
          schedule: nightSchedule,
          userStyle: userStyle,
          now: now,
          adornment: adornment,
          onChanged: onNightScheduleChanged,
        ),
      ),
      AppearanceOptionKind.flatSurfaces => Column(
        children: <Widget>[
          _tagged(
            SetupHighlight.flatSurfaces,
            (adornment) => FlatSurfacesOption(
              value: flatSurfaces,
              adornment: adornment,
              onChanged: onFlatSurfacesChanged,
            ),
          ),
          _tagged(
            SetupHighlight.flatAreas,
            (adornment) => FlatAreasOption(
              visible: flatSurfaces,
              value: flatAreas,
              adornment: adornment,
              onChanged: onFlatAreasChanged,
            ),
          ),
        ],
      ),
      AppearanceOptionKind.cornerStyle => _tagged(
        SetupHighlight.cornerStyle,
        (adornment) => CornerStyleOption(
          value: cornerStyle,
          adornment: adornment,
          onChanged: onCornerStyleChanged,
        ),
      ),
      AppearanceOptionKind.density => DensityOption(
        value: density,
        onChanged: onDensityChanged,
      ),
      AppearanceOptionKind.nowPlayingBackground => _tagged(
        SetupHighlight.nowPlayingBackground,
        (adornment) => NowPlayingBackgroundOption(
          value: nowPlayingBackground,
          oled: previewOled,
          flat: flatSurfaces && flatAreas.nowPlaying,
          adornment: adornment,
          onChanged: onNowPlayingBackgroundChanged,
        ),
      ),
    };
  }

  /// Album Art Colored Shade, which both screens place in their Color group
  /// rather than in [AppearanceOptionKind]'s order.
  Widget buildAlbumArtColoredShade() => _tagged(
    SetupHighlight.albumArtShade,
    (adornment) => AlbumArtColoredShadeOption(
      value: albumArtColoredShade,
      enabled: !(flatSurfaces && flatAreas.artworkText),
      adornment: adornment,
      onChanged: onAlbumArtColoredShadeChanged,
    ),
  );

  /// The option widgets for [kinds], keyed by kind so reorders keep state.
  List<Widget> buildAll(Iterable<AppearanceOptionKind> kinds) => <Widget>[
    for (final kind in kinds)
      KeyedSubtree(
        key: ValueKey<AppearanceOptionKind>(kind),
        child: build(kind),
      ),
  ];
}

/// Color Style heading (with its "New" tag) and the style tiles. Shared by
/// Appearance settings and setup.
class ColorStyleOption extends StatelessWidget {
  const new({
    required this.currentStyle,
    required this.seed,
    required this.brightness,
    required this.oled,
    required this.onChanged,
    super.key,
  });

  final NavisColorStyle currentStyle;
  final Color seed;
  final Brightness brightness;
  final bool oled;
  final ValueChanged<NavisColorStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return HighlightedAppearanceOption(
      highlight: SetupHighlight.colorStyle,
      builder: (context, adornment) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppearanceHeading(
            title: l10n.appearanceColorStyleLabel,
            adornment: adornment,
          ),
          ColorStyleSelector(
            currentStyle: currentStyle,
            seed: seed,
            brightness: brightness,
            oled: oled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
