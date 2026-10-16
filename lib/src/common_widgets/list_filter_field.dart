import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// Search field above a filterable list (Queue, Downloaded and Playlists).
class ListFilterField extends StatelessWidget {
  const new({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
    this.dense = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: dense
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                  onPressed: onClear,
                )
              : null,
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: OutlineInputBorder(
            borderRadius: NavisShapeData.of(context).mdAll,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: NavisShapeData.of(context).mdAll,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: NavisShapeData.of(context).mdAll,
            borderSide: BorderSide.none,
          ),
          contentPadding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: dense ? 10 : 14,
          ),
        ),
      ),
    );
  }
}
