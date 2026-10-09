import 'package:flutter/foundation.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';

/// Compile-time configuration for Navis services and distribution.
abstract final class AppConstants {
  /// Porthorion's public pages for Navis, linked from About and Privacy.
  static const String websiteUrl = 'https://navis.porthorion.com';
  static const String privacyPolicyUrl = '$websiteUrl/privacy/app';
  static const String eulaUrl = '$websiteUrl/eula';
  static const String supportEmail = 'support@porthorion.com';

  /// Shared HTTP identity derived from the current app changelog version.
  static final String userAgent =
      'Navis/${changelogs.first.version} '
      '(+https://navis.porthorion.com; support@porthorion.com)';

  /// Root of the signed update manifests and release artifacts.
  static const String updateBaseUrl = 'https://downloads.porthorion.com/navis/';

  /// Raw Ed25519 public key used to verify update manifests.
  static const String updateSigningPublicKey =
      'vSq61OOmfZS6CNYHeddKudoDAjZa179002wz/wnKtGk=';

  static const String updateManualDownloadUrl = '$websiteUrl/download';

  /// Update channel for release selection.
  ///
  /// Set via `--dart-define=NAVIS_UPDATE_CHANNEL=dev` for sidecar/dev builds.
  static const String updateChannel = String.fromEnvironment(
    'NAVIS_UPDATE_CHANNEL',
    defaultValue: 'stable',
  );

  /// Whether this build can self-update via APK install (sideload APKs).
  ///
  /// Set to `false` for Google Play App Bundle builds via
  /// `--dart-define=NAVIS_SELF_UPDATE=false`.
  static const bool selfUpdateEnabled = bool.fromEnvironment(
    'NAVIS_SELF_UPDATE',
    defaultValue: true,
  );

  /// Google Play listing for the stable Android package.
  static const String playStorePackageName = 'com.navis.app.navis';

  static const String playStoreListingUrl =
      'https://play.google.com/store/apps/details?id=$playStorePackageName';

  /// Last.fm API key bundled at build time. Empty in keyless builds.
  ///
  /// Release builds inject it as a masked pair (the key XOR a per-build random
  /// pad, both hex) through `NAVIS_LASTFM_API_KEY_MASKED` and
  /// `NAVIS_LASTFM_API_KEY_PAD`, so the plaintext key is not a string literal in
  /// the binary. A plain `NAVIS_LASTFM_API_KEY` define is still accepted when
  /// the masked pair is absent, which keeps local dev runs working.
  ///
  /// This deters casual extraction. It is not secrecy: the app has to hold the
  /// key to use it, and a Last.fm API key is a client identifier rather than a
  /// credential (no shared secret is bundled or used).
  static final String lastFmApiKey = resolveLastFmApiKey(
    masked: _lastFmApiKeyMasked,
    pad: _lastFmApiKeyPad,
    plain: _lastFmApiKeyPlain,
  );

  static const String _lastFmApiKeyMasked = String.fromEnvironment(
    'NAVIS_LASTFM_API_KEY_MASKED',
    defaultValue: '',
  );
  static const String _lastFmApiKeyPad = String.fromEnvironment(
    'NAVIS_LASTFM_API_KEY_PAD',
    defaultValue: '',
  );
  static const String _lastFmApiKeyPlain = String.fromEnvironment(
    'NAVIS_LASTFM_API_KEY',
    defaultValue: '',
  );

  /// Chooses the bundled Last.fm key from the build defines.
  ///
  /// The masked pair wins when either half is present; a half-present or
  /// malformed pair yields an empty key rather than a wrong one. The plain
  /// define is only the fallback when both halves are empty.
  @visibleForTesting
  static String resolveLastFmApiKey({
    required String masked,
    required String pad,
    required String plain,
  }) {
    if (masked.isNotEmpty || pad.isNotEmpty) {
      return unmaskLastFmApiKey(masked: masked, pad: pad);
    }
    return plain.trim();
  }

  /// XORs hex [masked] with hex [pad]. Returns an empty string unless both are
  /// well-formed hex, [pad] covers [masked], and the result is printable ASCII
  /// (a pair from different builds decodes to noise, which must not be sent to
  /// Last.fm as a key).
  @visibleForTesting
  static String unmaskLastFmApiKey({
    required String masked,
    required String pad,
  }) {
    final maskedBytes = _decodeHex(masked);
    final padBytes = _decodeHex(pad);
    if (maskedBytes == null ||
        padBytes == null ||
        maskedBytes.isEmpty ||
        padBytes.length < maskedBytes.length) {
      return '';
    }
    final decoded = <int>[
      for (var i = 0; i < maskedBytes.length; i++) maskedBytes[i] ^ padBytes[i],
    ];
    final printable = decoded.every((byte) => byte > 0x20 && byte < 0x7f);
    return printable ? String.fromCharCodes(decoded) : '';
  }

  static List<int>? _decodeHex(String hex) {
    if (hex.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex)) {
      return null;
    }
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte == null) return null;
      bytes.add(byte);
    }
    return bytes;
  }
}
