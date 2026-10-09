import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/night_schedule.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Left inset that marks an option as depending on the control above it.
const double appearanceSubOptionInset = NavisSpace.xxl;

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
        contentPadding: const EdgeInsetsDirectional.only(
          start: appearanceSubOptionInset,
          end: NavisSpace.md,
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
      title: _titleWithAdornment(l10n.appearanceFlatSurfacesLabel, adornment),
      subtitle: Text(l10n.appearanceFlatSurfacesSub),
      value: value,
      onChanged: onChanged,
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
    final showActiveNote =
        schedule.isActiveAt(now) && userStyle != NavisColorStyle.night;

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
      padding: const EdgeInsetsDirectional.fromSTEB(
        appearanceSubOptionInset,
        0,
        NavisSpace.md,
        NavisSpace.xs,
      ),
      child: Text(text, style: theme.textTheme.bodySmall),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SwitchListTile(
          title: _titleWithAdornment(
            l10n.appearanceNightScheduleLabel,
            adornment,
          ),
          subtitle: Text(
            l10n.appearanceNightScheduleSub(
              format(schedule.startMinutes),
              format(schedule.endMinutes),
            ),
          ),
          value: schedule.enabled,
          onChanged: (enabled) => onChanged(
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
      padding: const EdgeInsetsDirectional.fromSTEB(
        appearanceSubOptionInset,
        NavisSpace.xxs,
        NavisSpace.md,
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
/// setup, which differ only in [titleStyle].
class _AppearanceChoiceSection extends StatelessWidget {
  const new({
    required this.title,
    required this.description,
    required this.selector,
    required this.adornment,
    required this.titleStyle,
    this.topPadding = NavisSpace.xs,
    this.note,
  });

  final String title;
  final String description;
  final Widget selector;
  final Widget? adornment;
  final TextStyle? titleStyle;

  /// Space above the title; Corner Style sits below a switch and needs more.
  final double topPadding;

  /// Optional line under the selector.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            NavisSpace.md,
            topPadding,
            NavisSpace.md,
            NavisSpace.xxs,
          ),
          child: Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  title,
                  style:
                      titleStyle ??
                      theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                ),
              ),
              if (adornment != null) ...<Widget>[
                const SizedBox(width: NavisSpace.xs),
                adornment!,
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NavisSpace.md,
            vertical: NavisSpace.xxs,
          ),
          child: AnimatedSize(
            duration: MotionPolicy.of(context).surface,
            alignment: Alignment.topLeft,
            child: Text(description, style: theme.textTheme.bodySmall),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: NavisSpace.md,
            vertical: NavisSpace.xs,
          ),
          child: SizedBox(width: double.infinity, child: selector),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NavisSpace.md,
              0,
              NavisSpace.md,
              NavisSpace.xs,
            ),
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
    this.titleStyle,
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
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _AppearanceChoiceSection(
      title: l10n.appearanceNowPlayingBackgroundLabel,
      adornment: adornment,
      titleStyle: titleStyle,
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
    this.titleStyle,
    super.key,
  });

  final NavisDensity value;
  final ValueChanged<NavisDensity> onChanged;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _AppearanceChoiceSection(
      title: l10n.appearanceDensityLabel,
      adornment: adornment,
      titleStyle: titleStyle,
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

/// Corner Style: Rounded, Soft or Square corners for cards, buttons and
/// panels, with a small corner glyph on each choice. Shared by Appearance
/// settings and setup.
class CornerStyleOption extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.adornment,
    this.titleStyle,
    super.key,
  });

  final NavisCornerStyle value;
  final ValueChanged<NavisCornerStyle> onChanged;

  /// Shown beside the title, for example a "New" tag.
  final Widget? adornment;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    String name(NavisCornerStyle style) => switch (style) {
      NavisCornerStyle.rounded => l10n.appearanceCornerStyleRounded,
      NavisCornerStyle.soft => l10n.appearanceCornerStyleSoft,
      NavisCornerStyle.square => l10n.appearanceCornerStyleSquare,
    };
    // The glyph is a 22 px tile, so the style's md radius is scaled to it.
    Widget glyph(NavisCornerStyle style) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(
          NavisShapeData.forStyle(style).md / 2.5,
        ),
        border: Border.all(color: scheme.onSurface, width: 2),
      ),
      child: const SizedBox(width: 22, height: 22),
    );
    return _AppearanceChoiceSection(
      title: l10n.appearanceCornerStyleLabel,
      adornment: adornment,
      titleStyle: titleStyle,
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
