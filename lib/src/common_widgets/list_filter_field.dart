import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/desktop_layout.dart';
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

/// A Library tab's [ListFilterField]. On a short window
/// ([AdaptiveContext.useShortHeightChrome], a landscape phone) it becomes the
/// tab's one pinned control row instead: a dense field, then [shortControls]
/// (the tab's chips and sort) in a strip that scrolls sideways, so the
/// controls never stack and never cost a second row of height.
class LibraryFilterField extends StatelessWidget {
  const new({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
    this.alignWithContent = false,
    this.shortControls = const <Widget>[],
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool alignWithContent;

  /// The tab's other controls; shown only in the short row.
  final List<Widget> shortControls;

  @override
  Widget build(BuildContext context) {
    if (!resolveAdaptiveContextFor(context).useShortHeightChrome) {
      return ListFilterField(
        controller: controller,
        hint: hint,
        onChanged: onChanged,
        onClear: onClear,
        alignWithContent: alignWithContent,
      );
    }
    final field = ListFilterField(
      controller: controller,
      hint: hint,
      onChanged: onChanged,
      onClear: onClear,
      dense: true,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = ContentLayout.padding(constraints.maxWidth);
        final width = constraints.maxWidth - inset * 2;
        return Padding(
          padding: EdgeInsets.fromLTRB(inset, 6, inset, 6),
          // 40 dp, not the 48 dp a field or a chip takes by default: with the
          // 6 dp above and below, the row is 52 dp.
          child: SizedBox(
            height: 40,
            child: shortControls.isEmpty
                ? field
                : Row(
                    children: <Widget>[
                      SizedBox(
                        width: math.min(
                          width,
                          (constraints.maxWidth * 0.4).clamp(200.0, 360.0),
                        ),
                        child: field,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(spacing: 8, children: shortControls),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// The empty state of a filtered list: no match for [query], with a way back.
class FilterNoResults extends StatelessWidget {
  const new({super.key, required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return EmptyState(
      title: l10n.libraryFilterNoResults(query),
      subtitle: l10n.libraryFilterNoResultsSubtitle,
      icon: Icons.search_off,
      action: FilledButton.tonalIcon(
        style: NavisColorStyleData.tonalStyleOf(context),
        key: const ValueKey<String>('filterClearAction'),
        onPressed: onClear,
        icon: const Icon(Icons.filter_alt_off_outlined),
        label: Text(l10n.libraryClearFiltersAction),
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
