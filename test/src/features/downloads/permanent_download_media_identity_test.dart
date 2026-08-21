import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/permanent_download_media_identity.dart';

void main() {
  test('FLAC identity tags preserve ordinary Vorbis comments', () async {
    final directory = await Directory.systemTemp.createTemp('navis_flac_tag_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/track.flac')
      ..writeAsBytesSync(
        _flacWithComments(<String, String>{
          'TITLE': 'Test Track',
          'ARTIST': 'Test Artist',
        }),
      );
    final identity = PermanentDownloadMediaIdentity();

    await identity.write(
      file: file,
      songId: 'server-song-id',
      profileFingerprint: 'profile-fingerprint',
    );

    final tags = await identity.read(file);
    expect(tags['TITLE'], 'Test Track');
    expect(tags['ARTIST'], 'Test Artist');
    expect(tags[PermanentDownloadMediaIdentity.songIdKey], 'server-song-id');
    expect(
      tags[PermanentDownloadMediaIdentity.profileFingerprintKey],
      'profile-fingerprint',
    );
  });
}

Uint8List _flacWithComments(Map<String, String> comments) {
  final data = BytesBuilder(copy: false)
    ..add('fLaC'.codeUnits)
    ..add(<int>[0, 0, 0, 0]);
  final payload = BytesBuilder(copy: false);
  _writeLe(payload, 5);
  payload.add('navis'.codeUnits);
  _writeLe(payload, comments.length);
  for (final entry in comments.entries) {
    final value = '${entry.key}=${entry.value}'.codeUnits;
    _writeLe(payload, value.length);
    payload.add(value);
  }
  final bytes = payload.toBytes();
  data.add(<int>[0x84, 0, 0, bytes.length]);
  data.add(bytes);
  data.add(<int>[0xff, 0xf8, 0, 0]);
  return data.toBytes();
}

void _writeLe(BytesBuilder target, int value) {
  target.add(<int>[value & 0xff, (value >> 8) & 0xff, 0, 0]);
}
