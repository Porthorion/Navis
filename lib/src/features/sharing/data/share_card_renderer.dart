import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Renders a 1200×630 PNG share card image using dart:ui Canvas.
///
/// No widget tree is required. The card contains:
/// - Dark gradient background
/// - Cover art (or a placeholder) on the left
/// - Text content (type label, title, subtitle, tertiary) on the right
/// - Navis logo in the bottom-right corner
class ShareCardRenderer {
  static const double _width = 1200.0;
  static const double _height = 630.0;

  static const double _coverMarginLeft = 65.0;
  static const double _coverSize = 500.0;
  static const double _coverRadius = 20.0;
  static const double _textLeft = _coverMarginLeft + _coverSize + 40.0;
  static const double _textRight = _width - 40.0;
  static const double _textWidth = _textRight - _textLeft;
  static const double _logoSize = 50.0;
  static const double _logoMargin = 24.0;

  // Background colours
  static const int _bgTopColor = 0xff1a1a2e;
  static const int _bgBottomColor = 0xff16213e;

  // Text colours
  static const int _typeLabelColor = 0xff8892b0;
  static const int _titleColor = 0xffffffff;
  static const int _subtitleColor = 0xccffffff;
  static const int _tertiaryColor = 0x99ffffff;

  /// Renders a share card and returns PNG bytes.
  ///
  /// - [coverArtBytes]: raw PNG/JPEG bytes of cover art (nullable).
  /// - [title]: primary text (song title, album name, etc.).
  /// - [subtitle]: secondary text (artist name), nullable.
  /// - [tertiaryText]: tertiary text (album name for songs), nullable.
  /// - [typeLabel]: content type badge ("SONG", "ALBUM", "ARTIST", "PLAYLIST").
  static Future<Uint8List> render({
    Uint8List? coverArtBytes,
    required String title,
    String? subtitle,
    String? tertiaryText,
    required String typeLabel,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    _drawBackground(canvas);

    if (coverArtBytes != null) {
      await _drawCoverArt(canvas, coverArtBytes);
    } else {
      _drawCoverArtPlaceholder(canvas);
    }

    _drawText(
      canvas,
      title: title,
      subtitle: subtitle,
      tertiaryText: tertiaryText,
      typeLabel: typeLabel,
    );

    await _drawNavisLogo(canvas);

    final picture = recorder.endRecording();
    final image = await picture.toImage(_width.toInt(), _height.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  // ---------------------------------------------------------------------------
  // Background
  // ---------------------------------------------------------------------------

  static void _drawBackground(ui.Canvas canvas) {
    final paint = ui.Paint()
      ..shader = ui.Gradient.linear(
        ui.Offset.zero,
        const ui.Offset(0, _height),
        [
          const ui.Color(_bgTopColor),
          const ui.Color(_bgBottomColor),
        ],
      );
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, _width, _height),
      paint,
    );
  }

  // ---------------------------------------------------------------------------
  // Cover art
  // ---------------------------------------------------------------------------

  static Future<void> _drawCoverArt(
    ui.Canvas canvas,
    Uint8List bytes,
  ) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    final image = await completer.future;

    final coverTop = (_height - _coverSize) / 2;
    final destRect = ui.Rect.fromLTWH(
      _coverMarginLeft,
      coverTop,
      _coverSize,
      _coverSize,
    );

    // Clip to rounded rectangle then draw image.
    canvas.save();
    final rrect = ui.RRect.fromRectAndRadius(
      destRect,
      const ui.Radius.circular(_coverRadius),
    );
    canvas.clipRRect(rrect);

    final srcRect = ui.Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.drawImageRect(image, srcRect, destRect, ui.Paint());
    canvas.restore();
  }

  static void _drawCoverArtPlaceholder(ui.Canvas canvas) {
    final coverTop = (_height - _coverSize) / 2;
    final rect = ui.Rect.fromLTWH(
      _coverMarginLeft,
      coverTop,
      _coverSize,
      _coverSize,
    );
    final rrect = ui.RRect.fromRectAndRadius(
      rect,
      const ui.Radius.circular(_coverRadius),
    );

    final bgPaint = ui.Paint()
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        [
          const ui.Color(0xff0f3460),
          const ui.Color(0xff533483),
        ],
      );
    canvas.drawRRect(rrect, bgPaint);

    // Draw a music note (♪) centred in the placeholder.
    _drawParagraph(
      canvas,
      text: '♪',
      color: const ui.Color(0x66ffffff),
      fontSize: 180,
      maxLines: 1,
      ellipsis: null,
      left: _coverMarginLeft,
      top: coverTop + (_coverSize - 200) / 2,
      width: _coverSize,
      bold: false,
      textAlign: ui.TextAlign.center,
    );
  }

  // ---------------------------------------------------------------------------
  // Text
  // ---------------------------------------------------------------------------

  static void _drawText(
    ui.Canvas canvas, {
    required String title,
    String? subtitle,
    String? tertiaryText,
    required String typeLabel,
  }) {
    double y =
        (_height -
            _estimateTextBlockHeight(
              subtitle: subtitle,
              tertiaryText: tertiaryText,
            )) /
        2;

    // Type label (e.g. "SONG")
    _drawParagraph(
      canvas,
      text: typeLabel.toUpperCase(),
      color: const ui.Color(_typeLabelColor),
      fontSize: 18,
      maxLines: 1,
      ellipsis: null,
      left: _textLeft,
      top: y,
      width: _textWidth,
      bold: false,
      letterSpacing: 3.0,
    );
    y += 30;

    // Title
    _drawParagraph(
      canvas,
      text: title,
      color: const ui.Color(_titleColor),
      fontSize: 52,
      maxLines: 2,
      ellipsis: '…',
      left: _textLeft,
      top: y,
      width: _textWidth,
      bold: true,
    );
    y += _estimateTitleHeight(title);

    if (subtitle != null) {
      y += 16;
      _drawParagraph(
        canvas,
        text: subtitle,
        color: const ui.Color(_subtitleColor),
        fontSize: 34,
        maxLines: 1,
        ellipsis: '…',
        left: _textLeft,
        top: y,
        width: _textWidth,
        bold: false,
      );
      y += 48;
    }

    if (tertiaryText != null) {
      y += 8;
      _drawParagraph(
        canvas,
        text: tertiaryText,
        color: const ui.Color(_tertiaryColor),
        fontSize: 26,
        maxLines: 1,
        ellipsis: '…',
        left: _textLeft,
        top: y,
        width: _textWidth,
        bold: false,
      );
    }
  }

  static double _estimateTitleHeight(String title) {
    // Two-line titles get roughly 2 × line height; single-line get 1 ×.
    // Line height at 52px ≈ 68px.
    if (title.length > 20) return 140;
    return 72;
  }

  static double _estimateTextBlockHeight({
    String? subtitle,
    String? tertiaryText,
  }) {
    // type label (30) + title (~110) + optional subtitle (48+16) + optional tertiary (34+8)
    double h = 30 + 110;
    if (subtitle != null) h += 16 + 48;
    if (tertiaryText != null) h += 8 + 34;
    return h;
  }

  // ---------------------------------------------------------------------------
  // Navis logo
  // ---------------------------------------------------------------------------

  static Future<void> _drawNavisLogo(ui.Canvas canvas) async {
    try {
      final data = await rootBundle.load('lib/src/icon/Navis_Icon_Dark.png');
      final bytes = data.buffer.asUint8List();

      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, completer.complete);
      final image = await completer.future;

      final destRect = ui.Rect.fromLTWH(
        _width - _logoSize - _logoMargin,
        _height - _logoSize - _logoMargin,
        _logoSize,
        _logoSize,
      );
      final srcRect = ui.Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );

      final paint = ui.Paint()..color = const ui.Color(0xaaffffff);
      canvas.drawImageRect(image, srcRect, destRect, paint);
    } catch (_) {
      // If the logo asset fails to load, skip it silently.
    }
  }

  // ---------------------------------------------------------------------------
  // Paragraph helper
  // ---------------------------------------------------------------------------

  static void _drawParagraph(
    ui.Canvas canvas, {
    required String text,
    required ui.Color color,
    required double fontSize,
    required int maxLines,
    required String? ellipsis,
    required double left,
    required double top,
    required double width,
    required bool bold,
    double letterSpacing = 0.0,
    ui.TextAlign textAlign = ui.TextAlign.left,
  }) {
    final paragraphStyle = ui.ParagraphStyle(
      textAlign: textAlign,
      maxLines: maxLines,
      ellipsis: ellipsis,
      fontFamily: 'sans-serif',
    );

    final textStyle = ui.TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: bold ? ui.FontWeight.bold : ui.FontWeight.normal,
      letterSpacing: letterSpacing,
    );

    final builder = ui.ParagraphBuilder(paragraphStyle)
      ..pushStyle(textStyle)
      ..addText(text);

    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: width));

    canvas.drawParagraph(paragraph, ui.Offset(left, top));
  }
}
