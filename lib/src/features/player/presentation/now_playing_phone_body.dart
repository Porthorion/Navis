part of 'now_playing_screen.dart';

/// Portrait phone Now Playing body: the controls are pinned to the bottom and
/// the cover and title sit above them, sized by [NowPlayingPhoneLayout].
///
/// The upper part never scrolls (a scroll view there would take the
/// swipe-down-to-dismiss drag): when even the smallest cover does not fit, it
/// is scaled down to the room left above the controls. The controls never
/// scroll or clip.
class _PhoneNowPlayingColumn extends StatelessWidget {
  const new({
    required this.layout,
    required this.art,
    required this.titleBlock,
    required this.transport,
    this.info,
    this.seek,
    this.actions,
  });

  final NowPlayingPhoneLayout layout;
  final Widget art;
  final Widget titleBlock;
  final Widget? info;
  final Widget? seek;
  final Widget transport;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    const inset = EdgeInsets.symmetric(
      horizontal: NowPlayingPhoneLayout.contentMargin,
    );
    return Column(
      // Tight width, so the scaled upper part below gets an exact box.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (context, viewport) {
              final upper = Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(height: layout.aboveArt),
                  art,
                  SizedBox(height: layout.artToTitle),
                  Padding(
                    padding: inset,
                    // Clipped to the modelled height, so a wrapped radio
                    // artist list can never push the cover around.
                    child: SizedBox(
                      height: layout.titleBlock,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topCenter,
                          minHeight: 0,
                          maxHeight: double.infinity,
                          child: titleBlock,
                        ),
                      ),
                    ),
                  ),
                ],
              );
              if (layout.scalesUpper) {
                return FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(width: viewport.maxWidth, child: upper),
                );
              }
              // Anything the model leaves over collects above the cover; a
              // few dp of misjudged height are clipped, never an overflow.
              return ClipRect(
                child: OverflowBox(
                  alignment: Alignment.bottomCenter,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: upper,
                ),
              );
            },
          ),
        ),
        Padding(
          padding: inset,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(height: layout.afterTitle),
              ?info,
              SizedBox(height: layout.afterInfo),
              ?seek,
              SizedBox(height: layout.afterSeek),
              transport,
              SizedBox(height: layout.afterTransport),
              ?actions,
              SizedBox(height: layout.bottom),
            ],
          ),
        ),
      ],
    );
  }
}
