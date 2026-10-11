import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// A circular disc carrying one icon: the leading mark of every notice
/// surface (notice tile, transient notice, offline banner, empty state).
///
/// Without [fill] and [ink] it takes the colour style's tonal control roles,
/// so it follows the accent and Controls (Accent | White) settings; callers
/// pass both only for a semantic kind such as success or a warning.
class NoticeIconDisc extends StatelessWidget {
  const new({
    required this.icon,
    required this.size,
    required this.iconSize,
    this.fill,
    this.ink,
    super.key,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final Color? fill;
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = NavisColorStyleData.of(context);
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill ?? style.tonalControlFill(scheme),
          shape: BoxShape.circle,
        ),
        child: SizedBox.square(
          dimension: size,
          child: Icon(
            icon,
            size: iconSize,
            color: ink ?? style.onTonalControlFill(scheme),
          ),
        ),
      ),
    );
  }
}
