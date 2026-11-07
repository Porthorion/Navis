import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';

/// Gives a switch's `onChanged` its on/off haptic. A null stays null, so a
/// disabled switch stays disabled and silent.
ValueChanged<bool>? _withToggleHaptic(ValueChanged<bool>? onChanged) {
  if (onChanged == null) return null;
  return (value) {
    NavisHaptics.toggle(value);
    onChanged(value);
  };
}

/// A [SwitchListTile] that feels like a switch: every settings switch uses it,
/// so the haptic lives here once.
///
/// The [key] goes to the [SwitchListTile] it builds, not to this widget, so
/// anything that looks a tile up by key or type still gets the real tile.
class NavisSwitchListTile extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.contentPadding,
    this.secondary,
    this.adaptive = false,
    Key? key,
  }) : _tileKey = key;

  const NavisSwitchListTile.adaptive({
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.contentPadding,
    this.secondary,
    Key? key,
  }) : adaptive = true,
       _tileKey = key;

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final Widget? secondary;
  final bool adaptive;
  final Key? _tileKey;

  @override
  Widget build(BuildContext context) {
    final changed = _withToggleHaptic(onChanged);
    return adaptive
        ? SwitchListTile.adaptive(
            key: _tileKey,
            value: value,
            onChanged: changed,
            title: title,
            subtitle: subtitle,
            contentPadding: contentPadding,
            secondary: secondary,
          )
        : SwitchListTile(
            key: _tileKey,
            value: value,
            onChanged: changed,
            title: title,
            subtitle: subtitle,
            contentPadding: contentPadding,
            secondary: secondary,
          );
  }
}

/// A [Switch] that gives the on/off haptic, for switches outside a list tile.
/// Like [NavisSwitchListTile], its [key] goes to the [Switch] it builds.
class NavisSwitch extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.adaptive = false,
    Key? key,
  }) : _switchKey = key;

  const NavisSwitch.adaptive({
    required this.value,
    required this.onChanged,
    Key? key,
  }) : adaptive = true,
       _switchKey = key;

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool adaptive;
  final Key? _switchKey;

  @override
  Widget build(BuildContext context) {
    final changed = _withToggleHaptic(onChanged);
    return adaptive
        ? Switch.adaptive(key: _switchKey, value: value, onChanged: changed)
        : Switch(key: _switchKey, value: value, onChanged: changed);
  }
}
