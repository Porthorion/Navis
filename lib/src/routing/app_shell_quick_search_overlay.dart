part of 'app_shell.dart';

class _DesktopQuickSearchOverlay extends StatefulWidget {
  const _DesktopQuickSearchOverlay({
    required this.controller,
    required this.focusNode,
    required this.onDismiss,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onDismiss;
  final void Function(
    String, {
    SearchResultType? filter,
    required bool explicitFilter,
  })
  onSubmitted;

  @override
  State<_DesktopQuickSearchOverlay> createState() =>
      _DesktopQuickSearchOverlayState();
}

class _DesktopQuickSearchOverlayState
    extends State<_DesktopQuickSearchOverlay> {
  static const List<SearchResultType?> _filterValues = [
    null,
    SearchResultType.artists,
    SearchResultType.albums,
    SearchResultType.songs,
  ];

  int _selectedIndex = 0;
  bool _explicitFilter = false;

  void _cycleNext() {
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % _filterValues.length;
      _explicitFilter = true;
    });
  }

  void _cyclePrev() {
    setState(() {
      _selectedIndex =
          (_selectedIndex - 1 + _filterValues.length) % _filterValues.length;
      _explicitFilter = true;
    });
  }

  void _submit() {
    widget.onSubmitted(
      widget.controller.text,
      filter: _filterValues[_selectedIndex],
      explicitFilter: _explicitFilter,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final filterLabels = <String>[
      l10n.quickSearchEverything,
      l10n.searchArtistsSection,
      l10n.searchAlbumsSection,
      l10n.searchSongsSection,
    ];
    return FocusScope(
      autofocus: true,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (intent) {
                widget.onDismiss();
                return null;
              },
            ),
          },
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) {
              return ColoredBox(
                color: Colors.black.withValues(alpha: 0.44 * value),
                child: child,
              );
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onDismiss,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GestureDetector(
                      onTap: () {},
                      child: Material(
                        elevation: 12,
                        color: colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(18),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  const Icon(Icons.search),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Focus(
                                      onKeyEvent: (node, event) {
                                        if (event is KeyDownEvent) {
                                          final key = event.logicalKey;
                                          if (key == LogicalKeyboardKey.tab) {
                                            if (HardwareKeyboard
                                                .instance
                                                .isShiftPressed) {
                                              _cyclePrev();
                                            } else {
                                              _cycleNext();
                                            }
                                            return KeyEventResult.handled;
                                          } else if (key ==
                                              LogicalKeyboardKey.arrowRight) {
                                            _cycleNext();
                                            return KeyEventResult.handled;
                                          } else if (key ==
                                              LogicalKeyboardKey.arrowLeft) {
                                            _cyclePrev();
                                            return KeyEventResult.handled;
                                          }
                                        }
                                        return KeyEventResult.ignored;
                                      },
                                      child: TextField(
                                        key: const ValueKey(
                                          'desktopQuickSearchField',
                                        ),
                                        controller: widget.controller,
                                        focusNode: widget.focusNode,
                                        autofocus: true,
                                        textInputAction: TextInputAction.search,
                                        decoration: InputDecoration(
                                          hintText: l10n.quickSearchHint,
                                          border: InputBorder.none,
                                          isDense: true,
                                        ),
                                        onSubmitted: (_) => _submit(),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: l10n.quickSearchSubmitTooltip,
                                    onPressed: _submit,
                                    icon: const Icon(
                                      Icons.arrow_forward_rounded,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: <Widget>[
                                  for (int i = 0; i < filterLabels.length; i++)
                                    FilterChip(
                                      label: Text(filterLabels[i]),
                                      selected: _selectedIndex == i,
                                      onSelected: (_) => setState(() {
                                        _selectedIndex = i;
                                        _explicitFilter = true;
                                      }),
                                      visualDensity: VisualDensity.compact,
                                      showCheckmark: false,
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
