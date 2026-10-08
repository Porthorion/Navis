import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/settings/domain/night_schedule.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_color_style.dart';

/// Left inset that marks an option as depending on the control above it.
const double appearanceSubOptionInset = 32;

/// A switch title with an optional [adornment] (such as a "New" tag) beside
/// it. Without an adornment it is the plain title, so rows keep their height.
Widget _titleWithAdornment(String text, Widget? adornment) {
  if (adornment == null) return Text(text);
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Flexible(child: Text(text)),
      const SizedBox(width: 8),
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
          end: 16,
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
        16,
        8,
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
        4,
        16,
        8,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
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
