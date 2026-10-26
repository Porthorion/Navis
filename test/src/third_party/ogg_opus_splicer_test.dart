import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/src/ogg_opus_splicer.dart';

/// Independent page reader and CRC so the tests do not trust the splicer.
class P {
  P(
    this.flags,
    this.granule,
    this.serial,
    this.seq,
    this.crcOk,
    this.packets,
    this.raw,
  );
  final int flags, granule, serial, seq;
  final bool crcOk;
  final List<Uint8List> packets;
  final Uint8List raw;
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
  while (p < d.length) {
    expect(String.fromCharCodes(d.sublist(p, p + 4)), 'OggS');
    final n = d[p + 26];
    final segs = d.sublist(p + 27, p + 27 + n);
    var at = p + 27 + n;
    final packets = <Uint8List>[];
    var cur = <int>[];
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
        d.sublist(p, at),
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
    s.beginContinuation(1); // 1 s early: the tail repeats 1 s of audio
    final tail = pagesOf(run(s, from2, 4000, true));
    expect(s.droppedPackets, 50); // 1 s of overlap = 50 packets
    // First kept packet ends one packet after the delivered granule.
    final first = tail.first;
    expect(first.granule - first.packets.length * 960, 96000);
    expect(first.seq, greaterThan(0));
  });

  test('a channel mismatch is refused', () {
    final s = OggOpusSplicer();
    run(s, cutAfter(96000), 4000, false);
    s.beginContinuation(2);
    final bad = Uint8List.fromList(from2)..[28 + 9] = 2;
    expect(() => s.splice(bad), throwsFormatException);
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
}
