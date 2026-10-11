import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/home/presentation/cover_colour_worker.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Caption tints already derived this session, so a card that rebuilds or
/// scrolls back paints its tint immediately.
final Map<String, CaptionTint> _tintMemo = <String, CaptionTint>{};
const int _kTintMemoCapacity = 1024;

String _memoKey(Color sampled, NavisColorStyleData style) =>
    '${sampled.toARGB32()}|${style.style.index}|${style.dark}|'
    '${style.adjustment.vividness}|${style.adjustment.depth}';

/// The memoised tint of [sampled] in [style], or null if not derived yet.
CaptionTint? peekCaptionTint(Color sampled, NavisColorStyleData style) =>
    _tintMemo[_memoKey(sampled, style)];

/// Clears the memo; for tests.
@visibleForTesting
void clearCaptionTintMemo() => _tintMemo.clear();

/// Derives [captionTintFor] in the [worker] isolate (the HCT conversions and
/// tone search are CPU work that does not belong on the UI isolate) and
/// memoises it.
Future<CaptionTint> resolveCaptionTint(
  CoverColourWorker worker,
  Color sampled,
  NavisColorStyleData style,
) async {
  final key = _memoKey(sampled, style);
  final known = _tintMemo[key];
  if (known != null) return known;
  final v = await worker.captionTint(sampled, style);
  Color at(int i) =>
      Color.from(alpha: v[i], red: v[i + 1], green: v[i + 2], blue: v[i + 3]);
  final tint = CaptionTint(fill: at(0), text: at(4), subtext: at(8));
  if (_tintMemo.length >= _kTintMemoCapacity) {
    _tintMemo.remove(_tintMemo.keys.first);
  }
  return _tintMemo[key] = tint;
}
