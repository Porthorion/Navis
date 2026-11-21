import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/utils/search_text.dart';

/// Desktop type-to-filter: typing on a page that has no focused text field
/// builds a query with no visible input. The page shows [typeFilterBadge] and
/// a dimmed [typeFilterOverlay] of the typed text; Backspace edits the query
/// and Escape clears it. Touch layouts pair the page's filter with a
/// `ListFilterField` instead.
///
/// The Library root and the detail pages share this one handler. It only
/// takes keys while the page is visible and current ([typeFilterPageActive]),
/// the quick-search overlay is closed, no Ctrl/Meta/Alt is held and no text
/// field has focus. The page reads [typeFilterQuery] and filters its own
/// in-memory lists; wrap its body with [typeFilterFrame] (or place
/// [typeFilterBadge] and [typeFilterOverlay] itself).
mixin TypeToFilter<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  String _typedFilter = '';

  /// What was typed, or '' when it holds nothing searchable (only
  /// punctuation): such a query is no filter, so no badge and no matching.
  String get typeFilterQuery => effectiveFilterQuery(_typedFilter);

  /// The page's active filter: the typed query, else the touch field's
  /// [touchQuery].
  String activeFilterQuery(String touchQuery) => typeFilterQuery.isNotEmpty
      ? typeFilterQuery
      : effectiveFilterQuery(touchQuery);

  bool typeFilterOverlayVisible = false;
  Timer? _typeFilterFadeTimer;
  late final LibraryTypeFilterOwners _typeFilterOwners;

  /// Whether this page may take keystrokes now. Detail pages: they are the
  /// current route. The Library root overrides it (it stays mounted under
  /// detail pages).
  bool get typeFilterPageActive => ModalRoute.of(context)?.isCurrent ?? true;

  /// Called inside the `setState` that changes the query, so the page can
  /// drop caches derived from it.
  void onTypeFilterChanged({required bool cleared}) {}

  @override
  void initState() {
    super.initState();
    _typeFilterOwners = ref.read(libraryTypeFilterOwnersProvider.notifier);
    HardwareKeyboard.instance.addHandler(_onTypeFilterKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onTypeFilterKey);
    _typeFilterFadeTimer?.cancel();
    // Deferred: provider listeners must not be notified mid-unmount.
    final owners = _typeFilterOwners;
    scheduleMicrotask(() => owners.remove(this));
    super.dispose();
  }

  bool _onTypeFilterKey(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // The shell keeps branches mounted behind other tabs; only the visible
    // page may take keystrokes.
    if (!TickerMode.valuesOf(context).enabled) return false;
    // Don't intercept when the quick-search overlay is visible.
    if (ref.read(quickSearchOverlayVisibleProvider)) return false;
    if (!typeFilterPageActive) return false;
    // Don't intercept modifier combos (shortcuts).
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return false;
    }
    // Don't intercept when a text field is being edited.
    final focusWidget = FocusManager.instance.primaryFocus?.context?.widget;
    if (focusWidget is EditableText) return false;
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null) {
      return false;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      if (_typedFilter.isEmpty) return false;
      updateTypeFilter(_typedFilter.substring(0, _typedFilter.length - 1));
      return true;
    }
    if (key == LogicalKeyboardKey.escape && _typedFilter.isNotEmpty) {
      clearTypeFilter();
      return true;
    }
    final char = event.character;
    if (char != null && char.isNotEmpty && !_isControlChar(char)) {
      // Don't start a new filter with a space; only add spaces to an
      // existing query so play/pause isn't swallowed before typing begins.
      if (char == ' ' && _typedFilter.isEmpty) return false;
      updateTypeFilter(_typedFilter + char);
      return true;
    }
    return false;
  }

  bool _isControlChar(String s) {
    final code = s.codeUnitAt(0);
    return code < 32 || code == 127;
  }

  void updateTypeFilter(String query) {
    if (query.isEmpty) {
      clearTypeFilter();
      return;
    }
    _typeFilterFadeTimer?.cancel();
    setState(() {
      _typedFilter = query;
      typeFilterOverlayVisible = true;
      onTypeFilterChanged(cleared: false);
    });
    _typeFilterOwners.add(this);
    _typeFilterFadeTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => typeFilterOverlayVisible = false);
        _typeFilterOwners.remove(this);
      }
    });
  }

  void clearTypeFilter() {
    _typeFilterFadeTimer?.cancel();
    setState(() {
      _typedFilter = '';
      typeFilterOverlayVisible = false;
      onTypeFilterChanged(cleared: true);
    });
    _typeFilterOwners.remove(this);
  }

  /// The `Filtering: "<query>"` strip, or null with no query.
  Widget? typeFilterBadge() => typeFilterQuery.isEmpty
      ? null
      : TypeFilterBadge(query: typeFilterQuery, onClear: clearTypeFilter);

  /// The dimmed full-screen echo of the typed text, shown while typing and
  /// briefly after; null otherwise. Place it last in a [Stack].
  Widget? typeFilterOverlay() =>
      typeFilterOverlayVisible && _typedFilter.isNotEmpty
      ? Positioned.fill(child: _TypeFilterOverlay(query: _typedFilter))
      : null;

  /// [child] under the badge with the overlay on top.
  Widget typeFilterFrame(Widget child) => Stack(
    children: <Widget>[
      Column(
        children: <Widget>[
          ?typeFilterBadge(),
          Expanded(child: child),
        ],
      ),
      ?typeFilterOverlay(),
    ],
  );
}

class TypeFilterBadge extends StatelessWidget {
  const new({super.key, required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.filter_list_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.libraryFilteringLabel(query),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Tooltip(
            message: l10n.libraryClearFiltersAction,
            child: GestureDetector(
              onTap: onClear,
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypeFilterOverlay extends StatelessWidget {
  const new({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.35),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              query,
              style: Theme.of(context).textTheme.displayLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: Colors.white.withValues(alpha: 0.85),
                letterSpacing: 2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
