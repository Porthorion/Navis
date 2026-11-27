import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_switch.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// Sidebar style selector, plus the auto-hide switch where [showAutohide].
/// Shared by Desktop settings and the tablet Sidebar group in Home & Library.
class DesktopNavbarSettings extends StatelessWidget {
  const new({
    required this.currentStyle,
    required this.onStyleChanged,
    this.autohideEnabled = false,
    this.onAutohideChanged,
  });

  final String currentStyle;
  final ValueChanged<String> onStyleChanged;

  /// The auto-hide switch shows only when [onAutohideChanged] is given.
  final bool autohideEnabled;
  final ValueChanged<bool>? onAutohideChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = (currentStyle == 'comfortable' || currentStyle == 'icons')
        ? currentStyle
        : 'compact';

    final colorStyle = NavisColorStyleData.of(context);
    Widget styleOption({
      required String value,
      required String label,
      required IconData icon,
    }) {
      final isSelected = selected == value;
      return Expanded(
        child: SizedBox(
          height: 48,
          child: FilledButton.icon(
            onPressed: () => onStyleChanged(value),
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              backgroundColor: isSelected
                  ? colorStyle.tonalControlFill(colorScheme)
                  : colorScheme.surfaceContainerLow,
              foregroundColor: isSelected
                  ? colorStyle.onTonalControlFill(colorScheme)
                  : colorScheme.onSurfaceVariant,
              shape: NavisShapeData.of(context).mdShape,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            l10n.desktopNavbarStyleLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              color: colorScheme.primary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              styleOption(
                value: 'compact',
                label: l10n.desktopNavbarStyleDefault,
                icon: Icons.view_compact_alt_outlined,
              ),
              const SizedBox(width: 8),
              styleOption(
                value: 'comfortable',
                label: l10n.desktopNavbarStyleLarge,
                icon: Icons.view_sidebar_outlined,
              ),
              const SizedBox(width: 8),
              styleOption(
                value: 'icons',
                label: l10n.desktopNavbarStyleIcons,
                icon: Icons.more_vert_rounded,
              ),
            ],
          ),
        ),
        if (onAutohideChanged != null)
          NavisSwitchListTile(
            title: Text(l10n.desktopNavbarAutohideLabel),
            subtitle: Text(l10n.desktopNavbarAutohideSub),
            value: autohideEnabled,
            onChanged: onAutohideChanged,
          ),
      ],
    );
  }
}
