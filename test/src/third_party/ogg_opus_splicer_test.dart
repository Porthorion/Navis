import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/src/ogg_opus_splicer.dart';

/// Independent page reader and CRC so the tests do not trust the splicer.
class P {
  new(
    this.flags,
    this.granule,
    this.serial,
    this.seq,
    this.crcOk,
    this.packets,
    this.end,
  );
  final int flags, granule, serial, seq, end;
  final bool crcOk;
  final List<Uint8List> packets;
}

int _crc(Uint8List b) {
  var c = 0;
  for (final x in b) {
    c ^= x << 24;
    for (var i = 0; i < 8; i++) {
      c = (c & 0x80000000) != 0 ? (c << 1) ^ 0x04C11DB7 : c << 1;
      c &= 0xFFFFFFFF;
    }
  }
  return c;
}

List<P> pagesOf(List<int> bytes) {
  final d = Uint8List.fromList(bytes);
  final h = ByteData.sublistView(d);
  final out = <P>[];
  var p = 0;
  var cur = <int>[];
  while (p < d.length) {
    expect(String.fromCharCodes(d.sublist(p, p + 4)), 'OggS');
    final n = d[p + 26];
    final segs = d.sublist(p + 27, p + 27 + n);
    var at = p + 27 + n;
    final packets = <Uint8List>[];
    for (final s in segs) {
      cur.addAll(d.sublist(at, at + s));
      at += s;
      if (s < 255) {
        packets.add(Uint8List.fromList(cur));
        cur = [];
      }
    }
    final raw = Uint8List.fromList(d.sublist(p, at));
    final stored = h.getUint32(p + 22, Endian.little);
    raw.setRange(22, 26, [0, 0, 0, 0]);
    out.add(
      P(
        d[p + 5],
        h.getInt64(p + 6, Endian.little),
        h.getUint32(p + 14, Endian.little),
        h.getUint32(p + 18, Endian.little),
        _crc(raw) == stored,
        packets,
        at,
      ),
    );
    p = at;
  }
  return out;
}

final full = File('test/fixtures/ogg/tone_full.opus').readAsBytesSync();
final from2 = File('test/fixtures/ogg/tone_from_2s.opus').readAsBytesSync();

/// The bytes of [full] up to and including the page with granule [g], plus a
/// ragged half of the next page (what a cut leaves behind).
List<int> cutAfter(int g) {
  var p = 0;
  while (true) {
    final n = full[p + 26];
    var len = 27 + n;
    for (var i = 0; i < n; i++) {
      len += full[p + 27 + i];
    }
    final gran = ByteData.sublistView(full).getInt64(p + 6, Endian.little);
    p += len;
    if (gran == g) return full.sublist(0, p + 40);
  }
}

List<int> run(OggOpusSplicer s, List<int> bytes, int chunk, bool cont) {
  final out = <int>[];
  for (var i = 0; i < bytes.length; i += chunk) {
    final c = bytes.sublist(
      i,
      i + chunk > bytes.length ? bytes.length : i + chunk,
    );
    out.addAll(cont ? s.splice(c) : s.forward(c));
  }
  return out;
}

// Synthetic packets isolate lacing and TOC placement from the real fixtures.
Uint8List _page(
  int granule,
  List<List<int>> packets, {
  int flags = 0,
  int seq = 2,
  int serial = 42,
  List<int>? lacing,
}) {
  final body = packets.expand((p) => p).toList();
  final segments =
      lacing ??
      [
        for (final p in packets) ...[
          for (var n = p.length; n >= 255; n -= 255) 255,
          p.length % 255,
        ],
      ];
  final out = Uint8List(27 + segments.length + body.length);
  out.setRange(0, 4, 'OggS'.codeUnits);
  out[5] = flags;
  final h = ByteData.sublistView(out)
    ..setInt64(6, granule, Endian.little)
    ..setUint32(14, serial, Endian.little)
    ..setUint32(18, seq, Endian.little);
  out[26] = segments.length;
  out.setRange(27, 27 + segments.length, segments);
  out.setRange(27 + segments.length, out.length, body);
  h.setUint32(22, _crc(out), Endian.little);
  return out;
}

List<int> _headers({int serial = 42}) => [
  ..._page(
    0,
    [
      <int>[...'OpusHead'.codeUnits, 1, 1, 0, 0, 128, 187, 0, 0, 0, 0, 0],
    ],
    flags: 2,
    seq: 0,
    serial: serial,
  ),
  ..._page(0, ['OpusTags'.codeUnits], seq: 1, serial: serial),
];

void main() {
  test('forward hands out only complete pages and is byte-identical', () {
    final s = OggOpusSplicer();
    final out = run(s, full, 777, false) + s.flush();
    expect(out, full);
    final cut = OggOpusSplicer();
    final got = run(cut, cutAfter(100800), 1000, false);
    expect(pagesOf(got).last.granule, 100800);
    expect(cut.canContinue, isTrue);
    expect(cut.resumeSeconds, 1); // floor(2.09 s) - 1 s of pre-roll
  });

  test('a stitched stream is one clean logical stream', () {
    final s = OggOpusSplicer();
    final head = run(s, cutAfter(100800), 1500, false);
    final offset = s.resumeSeconds;
    expect(offset, 1);
    // The continuation here starts at 2 s; pretend the server was asked for
    // second 2 so the mapped granules line up with the delivered audio.
    s.beginContinuation(2);
    final tail = run(s, from2, 1300, true);
    final pages = pagesOf([...head, ...tail]);
    expect(pages.every((p) => p.crcOk), isTrue);
    expect(pages.map((p) => p.serial).toSet(), hasLength(1));
    expect(
      [for (final p in pages) p.seq],
      [for (var i = 0; i < pages.length; i++) i],
    );
    expect(
      pages.where(
        (p) => String.fromCharCodes(p.packets.first.take(8)) == 'OpusHead',
      ),
      hasLength(1),
    );
    expect(
      pages.where(
        (p) => String.fromCharCodes(p.packets.first.take(8)) == 'OpusTags',
      ),
      hasLength(1),
    );
    // Granules grow by exactly one 20 ms packet per packet: no gap, no repeat.
    final audio = pages.skip(2).toList();
    for (var i = 1; i < audio.length - 1; i++) {
      expect(
        audio[i].granule - audio[i - 1].granule,
        audio[i].packets.length * 960,
      );
    }
    expect(pages.last.flags & 4, 4);
    // The tail covers 2 s onward, so the stitched stream is as long as 'full'.
    final fullPages = pagesOf(full);
    expect(
      pages.last.granule,
      greaterThanOrEqualTo(fullPages.last.granule - 960),
    );
    expect(s.droppedPackets, 5);
  });

  test('the continuation starts exactly after the delivered granule', () {
    final s = OggOpusSplicer();
    run(s, cutAfter(96000), 4000, false);
    expect(s.resumeSeconds, 0); // pre-skip keeps this just below two seconds.
    s.beginContinuation(1); // 1 s early: the tail repeats 1 s of audio
    final tail = pagesOf(run(s, from2, 4000, true));
    expect(s.droppedPackets, 50); // 1 s of overlap = 50 packets
    // First kept packet ends one packet after the delivered granule.
    final first = tail.first;
    expect(first.granule - first.packets.length * 960, 96000);
    expect(first.seq, greaterThan(0));
  });

  test('a mid-packet origin cannot continue and granule -1 preserves the last time', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(96000, [
        [152, 0],
      ]),
    ]);
    s.forward(_page(-1, [List.filled(255, 152)], lacing: [255], seq: 3));
    expect(s.canContinue, isFalse);
    expect(s.resumeSeconds, 1);
  });

  test('empty original pages remain byte-identical passthrough', () {
    final bytes = [..._headers(), ..._page(0, [], lacing: [])];
    final s = OggOpusSplicer();
    expect([...s.forward(bytes), ...s.flush()], bytes);
  });

  for (final spec in [
    (0, 480),
    (8, 960),
    (16, 1920),
    (96, 480),
    (104, 960),
    (128, 120),
    (136, 240),
    (144, 480),
    (152, 960),
    (153, 1920),
    (155, 1920),
  ]) {
    test('TOC ${spec.$1} places ${spec.$2} sample packets exactly', () {
      final packet = [spec.$1, 2, 0];
      final s = OggOpusSplicer();
      s.forward([
        ..._headers(),
        ..._page(spec.$2 * 2, [packet, packet]),
      ]);
      s.beginContinuation(0);
      final out = s.splice([
        ..._headers(),
        ..._page(spec.$2 * 3, [packet, packet, packet], flags: 4),
      ]);
      final pages = pagesOf(out);
      expect(s.droppedPackets, 2);
      expect(pages.single.packets, [packet]);
      expect(pages.single.granule, spec.$2 * 3);
      expect(pages.single.crcOk, isTrue);
    });
  }

  for (final packet in [
    [24, 0],
    [17, 0],
    [25, 0],
    [131, 48],
  ]) {
    test('unplaceable duration $packet refuses instead of overlapping', () {
      final s = OggOpusSplicer();
      final original = [
        ..._headers(),
        ..._page(96000, [packet]),
      ];
      expect(s.forward(original), original);
      s.beginContinuation(1);
      expect(
        () => s.splice([
          ..._headers(),
          ..._page(57600, [packet]),
        ]),
        throwsFormatException,
      );
    });
  }

  test('continued packets, 255/510 lacing and page limit preserve packets', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ]),
    ]);
    s.beginContinuation(0);
    final big = List<int>.filled(510, 7)..[0] = 152;
    final many = [
      big,
      for (var i = 0; i < 254; i++) [152, i],
    ];
    // Use at most 255 segments per input page: the continued packet makes the
    // rewritten result require one more segment and therefore another page.
    final input = [
      ..._headers(),
      ..._page(-1, [big.sublist(0, 255)], lacing: [255]),
      ..._page(
        254 * 960,
        [big.sublist(255), ...many.skip(1).take(253)],
        lacing: [255, 0, ...List.filled(253, 2)],
        flags: 1,
      ),
      ..._page(255 * 960, [many.last], flags: 4),
    ];
    final pages = pagesOf(run(s, input, 17, true));
    expect(pages.expand((p) => p.packets).toList(), many.skip(1).toList());
    expect(pages.every((p) => p.crcOk), isTrue);
    expect(pages.last.granule, 255 * 960);
    expect(pages.last.flags & 4, 4);

    // Keep the big packet too, so repacking must split the 256 laces.
    final fresh = OggOpusSplicer();
    fresh.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ]),
    ]);
    fresh.beginContinuation(1);
    final eosInput = [
      ..._headers(),
      ..._page(-1, [big.sublist(0, 255)], lacing: [255]),
      ..._page(
        254 * 960,
        [big.sublist(255), ...many.skip(1).take(253)],
        lacing: [255, 0, ...List.filled(253, 2)],
        flags: 5,
      ),
    ];
    final split = pagesOf(run(fresh, eosInput, 10000, true));
    expect(split.expand((p) => p.packets).toList(), many.take(254).toList());
    expect(split.length, 2);
    expect(split.map((p) => p.seq).toList(), [3, 4]);
    expect(split.every((p) => p.crcOk && p.serial == 42), isTrue);
    expect(split.first.flags & 4, 0);
    expect(split.last.flags & 4, 4);
    expect(split.first.granule, 48000 + 253 * 960);
  });

  test('a data-less EOS page remains the final rewritten page', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ]),
    ]);
    s.beginContinuation(2);
    final pages = pagesOf(
      s.splice([
        ..._headers(serial: 84),
        ..._page(1920, [
          [152, 0],
          [152, 1],
        ], serial: 84),
        ..._page(1920, [], flags: 4, serial: 84),
      ]),
    );
    expect(pages, hasLength(2));
    expect(pages.first.flags & 4, 0);
    expect(pages.last.flags & 4, 4);
    expect(pages.last.packets, isEmpty);
    expect(pages.last.granule, 96000 + 1920);
    expect(pages.map((p) => p.seq).toList(), [3, 4]);
    expect(pages.every((p) => p.crcOk && p.serial == 42), isTrue);
    expect(s.continuationComplete, isTrue);
  });

  for (final partial in [false, true]) {
    test(
      'empty EOS cannot be emitted with ${partial ? 'a partial packet' : 'missing headers'}',
      () {
        final s = OggOpusSplicer();
        s.forward([
          ..._headers(),
          ..._page(960, [
            [152, 0],
          ]),
        ]);
        s.beginContinuation(0);
        expect(
          s.splice([
            if (partial) ...[
              ..._headers(serial: 84),
              ..._page(-1, [List.filled(255, 152)], lacing: [255], serial: 84),
            ],
            ..._page(-1, [], flags: 4, serial: 84),
          ]),
          isEmpty,
        );
        expect(s.continuationComplete, isFalse);
      },
    );
  }

  for (final emptyEos in [false, true]) {
    test(
      'end trim preserves a short mixed-duration packet, empty EOS=$emptyEos',
      () {
        final s = OggOpusSplicer();
        s.forward([
          ..._headers(),
          ..._page(960, [
            [152, 0],
          ]),
        ]);
        s.beginContinuation(0);
        final packets = [
          [144, 1],
          [152, 2],
        ]; // 480 + 960 samples, with 700 trimmed at the end.
        final pages = pagesOf(
          s.splice([
            ..._headers(),
            ..._page(960, [
              [152, 0],
            ]),
            ..._page(1700, packets, flags: emptyEos ? 0 : 4),
            if (emptyEos) ..._page(1700, [], flags: 4),
          ]),
        );
        expect(pages.expand((p) => p.packets).toList(), packets);
        expect(pages.last.granule, 1700);
        expect(pages.last.flags & 4, 4);
        expect(pages.every((p) => p.crcOk), isTrue);
        expect(s.droppedPackets, 1);
      },
    );
  }

  test('first continuation audio page can carry mixed-duration end trim', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ]),
    ]);
    s.beginContinuation(0);
    final packets = [
      [144, 1],
      [152, 2],
    ];
    final pages = pagesOf(
      s.splice([
        ..._headers(),
        ..._page(1700, [
          [152, 0],
          ...packets,
        ], flags: 4),
      ]),
    );
    expect(pages.single.packets, packets);
    expect(pages.single.granule, 1700);
    expect(s.droppedPackets, 1);
  });

  test('a cut after EOS cannot continue or append a duplicate EOS', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ], flags: 4),
    ]);
    expect(s.canContinue, isFalse);
    s.beginContinuation(0);
    expect(
      s.splice([
        ..._headers(),
        ..._page(960, [
          [152, 0],
        ]),
        ..._page(960, [], flags: 4),
      ]),
      isEmpty,
    );
    expect(s.continuationComplete, isTrue);
  });

  test('beginContinuation clears a previously unfinished packet', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ]),
    ]);
    s.beginContinuation(0);
    s.splice([
      ..._headers(),
      ..._page(-1, [List.filled(255, 7)], lacing: [255]),
    ]);
    s.beginContinuation(0);
    final packet = List.filled(255, 7)..[0] = 152;
    final tail = pagesOf(
      s.splice([
        ..._headers(),
        ..._page(1920, [packet], flags: 4),
      ]),
    );
    expect(tail.single.packets.single, packet);
    expect(tail.single.crcOk, isTrue);
  });

  test('lost sync is refused and a wholly overlapped EOS emits nothing', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(96000, [
        [152, 0],
      ]),
    ]);
    s.beginContinuation(0);
    expect(
      s.splice([
        ..._headers(),
        ..._page(960, [
          [152, 0],
        ], flags: 4),
      ]),
      isEmpty,
    );
    expect(s.resumeSeconds, 1);
    expect(() => s.splice([0, 0, 0, 0]), throwsFormatException);
  });

  test('a channel mismatch is refused', () {
    final s = OggOpusSplicer();
    run(s, cutAfter(96000), 4000, false);
    s.beginContinuation(2);
    final bad = Uint8List.fromList(from2)..[28 + 9] = 2;
    expect(() => s.splice(bad), throwsFormatException);
  });

  test('invalid original packets pass through and disable splicing', () {
    final s = OggOpusSplicer();
    final original = [
      ..._headers(),
      ..._page(960, [
        [155],
      ]),
    ];
    expect(s.forward(original), original);
    expect(s.canContinue, isFalse);
  });

  test('a non-Opus or non-Ogg stream passes through and cannot continue', () {
    final mp3 = Uint8List.fromList(List.filled(5000, 7));
    final s = OggOpusSplicer();
    expect(s.forward(mp3.sublist(0, 2)), isEmpty);
    expect(s.forward(mp3.sublist(2)).length, 5000);
    expect(s.canContinue, isFalse);
    expect(s.forward(mp3), same(mp3));
  });

  test('nothing is continuable before the first audio page', () {
    final s = OggOpusSplicer();
    run(s, full.sublist(0, 120), 50, false); // headers only
    expect(s.canContinue, isFalse);
  });

  test('a cut after the final trimmed audio page appends no packet (EOS on a separate empty page)', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ]),
      ..._page(1700, [
        [152, 1],
      ], seq: 3),
    ]);
    expect(s.canContinue, isTrue);
    s.beginContinuation(0);
    final out = s.splice([
      ..._headers(serial: 84),
      ..._page(1700, [
        [152, 0],
        [152, 1],
      ], serial: 84),
      ..._page(1700, [], flags: 4, seq: 3, serial: 84),
    ]);
    final d = Uint8List.fromList(out);
    // Exactly one data-less EOS page: no segments, mapped granule, next sequence.
    expect(d.length, 27);
    expect(d[5], 4);
    expect(d[26], 0);
    expect(ByteData.sublistView(d).getInt64(6, Endian.little), 1700);
    expect(ByteData.sublistView(d).getUint32(18, Endian.little), 4);
    expect(s.droppedPackets, 2);
    expect(s.continuationComplete, isTrue);
  });

  test('a wholly overlapped audio EOS page still terminates an original that lost its empty EOS', () {
    final originalPages = pagesOf(full);
    final finalStart = originalPages[originalPages.length - 2].end;
    final last = Uint8List.fromList(full.sublist(finalStart));
    last[5] &= ~4;
    last.fillRange(22, 26, 0);
    ByteData.sublistView(last).setUint32(22, _crc(last), Endian.little);
    // The original delivered its final audio page; its separate empty EOS
    // page (never appended here) was lost to the cut.
    final origin = [...full.take(finalStart), ...last];

    final s = OggOpusSplicer();
    final head = s.forward(origin);
    expect(s.canContinue, isTrue);
    s.beginContinuation(1);
    final tail = s.splice(from2);
    expect(s.continuationComplete, isTrue);
    final stitched = pagesOf([...head, ...tail]);
    final audio = stitched.skip(2).expand((p) => p.packets).length;
    expect(audio, originalPages.skip(2).expand((p) => p.packets).length);
    expect(stitched.every((p) => p.crcOk), isTrue);
    expect(stitched.where((p) => p.flags & 4 != 0), hasLength(1));
    final eos = stitched.last;
    expect(eos.flags & 4, 4);
    expect(eos.packets, isEmpty);
    expect(eos.serial, stitched.first.serial);
    expect(eos.seq, stitched[stitched.length - 2].seq + 1);
    expect(eos.granule, stitched[stitched.length - 2].granule);
    expect(tail.length, 27);
  });

  test('a wholly overlapped EOS adds no second EOS once one was emitted', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(1700, [
        [152, 0],
        [152, 1],
      ]),
    ]);
    s.beginContinuation(0);
    final out = s.splice([
      ..._headers(serial: 84),
      ..._page(960, [
        [152, 0],
      ]),
      // Fresh audio plus EOS emits the EOS itself; the empty EOS that follows
      // (wholly overlapped by definition) must not be doubled.
      ..._page(
        3620,
        [
          [152, 0],
          [152, 1],
        ],
        flags: 4,
        serial: 84,
        seq: 3,
      ),
      ..._page(3620, [], flags: 4, serial: 84, seq: 4),
    ]);
    final pages = pagesOf(out);
    expect(pages.where((p) => p.flags & 4 != 0), hasLength(1));
    expect(pages.every((p) => p.crcOk), isTrue);
    expect(s.continuationComplete, isTrue);
  });

  test('a partially overlapped EOS page keeps only its new packets', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ]),
    ]);
    s.beginContinuation(0);
    final pages = pagesOf(
      s.splice([
        ..._headers(serial: 84),
        ..._page(
          1920,
          [
            [152, 0],
            [152, 1],
          ],
          flags: 4,
          serial: 84,
        ),
      ]),
    );
    expect(s.droppedPackets, 1);
    expect(pages, hasLength(1));
    expect(pages.single.packets, hasLength(1));
    expect(pages.single.flags & 4, 4);
    expect(pages.single.granule, 1920);
    expect(pages.single.crcOk, isTrue);
    expect(s.continuationComplete, isTrue);
  });

  test('a continuation EOS page with only new packets is unchanged', () {
    final s = OggOpusSplicer();
    s.forward([
      ..._headers(),
      ..._page(960, [
        [152, 0],
      ]),
    ]);
    s.beginContinuation(0);
    final pages = pagesOf(
      s.splice([
        ..._headers(serial: 84),
        ..._page(
          2880,
          [
            [152, 0],
            [152, 1],
          ],
          flags: 4,
          serial: 84,
        ),
      ]),
    );
    expect(s.droppedPackets, 0);
    expect(pages, hasLength(1));
    expect(pages.single.packets, hasLength(2));
    expect(pages.single.flags & 4, 4);
    expect(pages.single.granule, 2880);
    expect(s.continuationComplete, isTrue);
  });
}
