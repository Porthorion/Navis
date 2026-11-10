import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/routing/content_layout.dart';
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
    this.alignWithContent = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool dense;

  /// Insets by `ContentLayout.padding` (the Library grids' inset) instead of a
  /// fixed 12, so the field lines up with the chips and cards below it.
  final bool alignWithContent;

  @override
  Widget build(BuildContext context) {
    if (!alignWithContent || dense) return _field(context, 12);
    return LayoutBuilder(
      builder: (context, constraints) =>
          _field(context, ContentLayout.padding(constraints.maxWidth)),
    );
  }

  Widget _field(BuildContext context, double inset) {
    return Padding(
      padding: dense
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(inset, 8, inset, 4),
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

/// The typed search of a list, applied after a short pause like the other
/// searches that query the database (each keystroke would re-read the list).
/// Pair with a [ListFilterField] using [search], [onSearchChanged] and
/// [clearSearch]; the list follows [query].
mixin DebouncedSearch<T extends StatefulWidget> on State<T> {
  final TextEditingController search = TextEditingController();
  Timer? _debounce;

  /// The search text the list currently follows.
  String query = '';

  void onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => query = search.text.trim());
    });
    // Shows the clear button at once.
    setState(() {});
  }

  void clearSearch() {
    _debounce?.cancel();
    search.clear();
    setState(() => query = '');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    search.dispose();
    super.dispose();
  }
}
