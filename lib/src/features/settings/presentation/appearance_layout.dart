import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Extra left inset that marks an option as depending on the control above it.
const double appearanceSubOptionIndent = NavisSpace.md;

/// Layout contract shared by every Appearance control, so Settings and the
/// setup step lay the same widgets out against their own left edge.
///
/// Settings uses the defaults. Setup, whose headings sit flush with its
/// panel, supplies a zero [gutter] and a larger [optionTitleStyle].
class AppearanceLayout extends InheritedWidget {
  const new({
    required super.child,
    this.gutter = NavisSpace.md,
    this.optionTitleStyle,
    super.key,
  });

  /// Horizontal inset of every shared control from the surrounding edge.
  final double gutter;

  /// Style of option labels; null keeps the Settings look (primary small).
  final TextStyle? optionTitleStyle;

  static AppearanceLayout? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceLayout>();

  /// The gutter in effect for [context].
  static double gutterOf(BuildContext context) =>
      maybeOf(context)?.gutter ?? NavisSpace.md;

  /// Start inset of a sub-option revealed under its parent control.
  static double subOptionInsetOf(BuildContext context) =>
      gutterOf(context) + appearanceSubOptionIndent;

  @override
  bool updateShouldNotify(AppearanceLayout oldWidget) =>
      gutter != oldWidget.gutter ||
      optionTitleStyle != oldWidget.optionTitleStyle;
}

/// Which kind of heading an [AppearanceHeading] is.
enum AppearanceHeadingLevel {
  /// A group of related options such as "Theme" or "Shape & Layout".
  section,

  /// The label of a single option such as "Color Style".
  option,
}

/// The one heading used across Appearance settings and setup, with an
/// optional [adornment] such as a "New" tag.
class AppearanceHeading extends StatelessWidget {
  const new({
    required this.title,
    this.level = AppearanceHeadingLevel.option,
    this.adornment,
    this.topPadding,
    this.bottomPadding = NavisSpace.xxs,
    super.key,
  });

  final String title;
  final AppearanceHeadingLevel level;
  final Widget? adornment;

  /// Space above; defaults to a larger gap for sections than for options.
  final double? topPadding;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final layout = AppearanceLayout.maybeOf(context);
    final isSection = level == AppearanceHeadingLevel.section;
    final style = isSection
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)
        : layout?.optionTitleStyle ??
              theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              );
    final gutter = AppearanceLayout.gutterOf(context);
    return Semantics(
      header: isSection,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          gutter,
          topPadding ?? (isSection ? NavisSpace.lg : NavisSpace.xs),
          gutter,
          bottomPadding,
        ),
        child: Row(
          children: <Widget>[
            Flexible(child: Text(title, style: style)),
            if (adornment != null) ...<Widget>[
              const SizedBox(width: NavisSpace.xs),
              adornment!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Content padding for full-width switch rows, aligned to the layout gutter.
EdgeInsetsDirectional appearanceSwitchPadding(BuildContext context) =>
    EdgeInsetsDirectional.symmetric(
      horizontal: AppearanceLayout.gutterOf(context),
    );
