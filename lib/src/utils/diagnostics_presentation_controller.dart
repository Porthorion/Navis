import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

class DiagnosticsPresentationUnavailable implements Exception {
  const DiagnosticsPresentationUnavailable();
}

class DiagnosticsPresentationStatus {
  const DiagnosticsPresentationStatus({
    required this.logicalWidth,
    required this.logicalHeight,
    required this.devicePixelRatio,
    required this.screenshotReady,
  });

  final double logicalWidth;
  final double logicalHeight;
  final double devicePixelRatio;
  final bool screenshotReady;

  Map<String, Object?> toJson() => <String, Object?>{
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'devicePixelRatio': devicePixelRatio,
    'screenshotReady': screenshotReady,
  };
}

class DiagnosticsScreenshot {
  const DiagnosticsScreenshot({
    required this.artifact,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.pixelRatio,
    required this.byteCount,
    required this.sha256Digest,
  });

  final String artifact;
  final double logicalWidth;
  final double logicalHeight;
  final int pixelWidth;
  final int pixelHeight;
  final double pixelRatio;
  final int byteCount;
  final String sha256Digest;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': 'captured',
    'artifact': artifact,
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'pixelWidth': pixelWidth,
    'pixelHeight': pixelHeight,
    'pixelRatio': pixelRatio,
    'byteCount': byteCount,
    'sha256': sha256Digest,
  };
}

class DiagnosticsPresentationController {
  DiagnosticsPresentationController({
    required Directory artifactRoot,
    this.frameWaiter,
  }) : _artifactRoot = Directory(p.normalize(p.absolute(artifactRoot.path)));

  static final RegExp _validLabel = RegExp(r'^[a-z0-9][a-z0-9_-]{0,47}$');
  static const double _capturePixelRatio = 1;

  static bool isValidLabel(String label) => _validLabel.hasMatch(label);

  final Directory _artifactRoot;
  final Future<void> Function()? frameWaiter;
  final GlobalKey _boundaryKey = GlobalKey(
    debugLabel: 'diagnosticsPresentationBoundary',
  );
  bool _appReady = false;

  bool get appReady => _appReady;

  void markAppReady() {
    _appReady = true;
  }

  Widget wrap(Widget child) {
    return RepaintBoundary(key: _boundaryKey, child: child);
  }

  DiagnosticsPresentationStatus get status {
    final context = _boundaryKey.currentContext;
    final boundary = _boundary;
    final size = (boundary?.hasSize ?? false) ? boundary!.size : Size.zero;
    final pixelRatio = context == null
        ? 0.0
        : View.of(context).devicePixelRatio;
    return DiagnosticsPresentationStatus(
      logicalWidth: size.width,
      logicalHeight: size.height,
      devicePixelRatio: pixelRatio,
      screenshotReady:
          boundary != null && boundary.attached && boundary.hasSize,
    );
  }

  Future<void> waitForFrame() async {
    final waitOverride = frameWaiter;
    if (waitOverride != null) {
      await waitOverride();
      return;
    }
    final binding = WidgetsBinding.instance;
    var consecutiveQuietFrames = 0;
    for (var frame = 0; frame < 120; frame++) {
      binding.ensureVisualUpdate();
      await binding.endOfFrame;
      if (binding.transientCallbackCount == 0) {
        consecutiveQuietFrames++;
        if (consecutiveQuietFrames >= 2) {
          return;
        }
      } else {
        consecutiveQuietFrames = 0;
      }
    }
  }

  Future<DiagnosticsScreenshot> capture({required String label}) async {
    if (!isValidLabel(label)) {
      throw const FormatException(
        'label must match [a-z0-9][a-z0-9_-]{0,47}',
      );
    }

    await waitForFrame();
    final boundary = _boundary;
    if (boundary == null || !boundary.attached || !boundary.hasSize) {
      throw const DiagnosticsPresentationUnavailable();
    }

    final image = await boundary.toImage(pixelRatio: _capturePixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw const DiagnosticsPresentationUnavailable();
      }
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final screenshots = Directory(
        p.join(_artifactRoot.path, 'screenshots'),
      );
      await screenshots.create(recursive: true);
      _setPosixMode(screenshots.path, '700');

      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp('[^0-9]'),
        '',
      );
      final file = File(p.join(screenshots.path, '$timestamp-$label.png'));
      final normalizedFile = p.normalize(p.absolute(file.path));
      if (!p.isWithin(_artifactRoot.path, normalizedFile)) {
        throw StateError('Screenshot path escaped the diagnostics root.');
      }
      await file.writeAsBytes(bytes, flush: true);
      _setPosixMode(file.path, '600');

      return DiagnosticsScreenshot(
        artifact: p.relative(file.path, from: _artifactRoot.path),
        logicalWidth: boundary.size.width,
        logicalHeight: boundary.size.height,
        pixelWidth: image.width,
        pixelHeight: image.height,
        pixelRatio: _capturePixelRatio,
        byteCount: bytes.length,
        sha256Digest: sha256.convert(bytes).toString(),
      );
    } finally {
      image.dispose();
    }
  }

  RenderRepaintBoundary? get _boundary {
    final renderObject = _boundaryKey.currentContext?.findRenderObject();
    return renderObject is RenderRepaintBoundary ? renderObject : null;
  }

  void _setPosixMode(String path, String mode) {
    if (Platform.isWindows) return;
    final result = Process.runSync('chmod', <String>[mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not protect diagnostics artifact.',
        path,
      );
    }
  }
}
