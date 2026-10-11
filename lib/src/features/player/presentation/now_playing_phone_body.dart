part of 'now_playing_screen.dart';

/// Portrait phone Now Playing body: the controls are pinned to the bottom and
/// the cover and title sit above them, sized by [NowPlayingPhoneLayout].
///
/// The upper part only scrolls when even the smallest cover does not fit
/// (very large text); the controls never scroll or clip.
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
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (context, viewport) => SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: viewport.maxHeight),
                // Anything the model leaves over collects above the cover.
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    SizedBox(height: layout.aboveArt),
                    art,
                    SizedBox(height: layout.artToTitle),
                    Padding(padding: inset, child: titleBlock),
                  ],
                ),
              ),
            ),
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
