import 'dart:math';
import 'dart:typed_data';

/// Navis: joins an Ogg/Opus transcode that was cut mid-body with a second
/// transcode that starts a few seconds earlier, into ONE logical stream.
///
/// Media3 reads the Ogg headers once and never checks serial or sequence, so a
/// true chained stream would decode its second header packets as audio. The
/// splicer therefore drops the continuation's header pages, rewrites serial,
/// page sequence, granule and CRC, and drops packets that overlap audio
/// already delivered.
///
/// Usage: pass every origin chunk through [forward] (it returns only complete
/// pages). After a cut, if [canContinue], call [beginContinuation] with the
/// whole-second offset of the second request ([resumeSeconds]) and pass its
/// chunks through [splice]. Throws [FormatException] when the continuation
/// cannot be placed exactly; the caller then falls back to failing the fetch.
class OggOpusSplicer {
  var _pending = Uint8List(0);
  var _checked = false;
  var _passthrough = false;
  var _pages = 0;
  var _opus = false;
  var _endsMidPacket = false;
  var _serial = 0;
  var _preSkip = 0;
  var _channels = 0;
  var _sequence = 0;

  /// Granule of the last page handed out (the audio delivered so far).
  var _granule = 0;

  // Continuation state, reset by [beginContinuation].
  var _offsetSeconds = 0;
  var _packetIndex = 0;
  var _contPreSkip = 0;
  final _partial = BytesBuilder(copy: false);

  /// Packets dropped by the current continuation because they were delivered.
  int droppedPackets = 0;

  /// Whether the stream so far is a clean Opus page sequence with audio.
  bool get canContinue =>
      !_passthrough && _opus && !_endsMidPacket && _granule > 0;

  /// Whole-second offset to request: one second of decoder pre-roll before the
  /// end of the delivered audio, so the join decodes like an uncut stream.
  int get resumeSeconds => max(0, (_granule - _preSkip) ~/ 48000 - 1);

  /// Original-phase: returns the complete pages of the data so far. Non-Ogg
  /// and non-Opus data passes through byte-identical.
  List<int> forward(List<int> chunk) {
    if (_passthrough) return chunk;
    _append(chunk);
    if (!_checked) {
      if (_pending.length < 4) return const <int>[];
      _checked = true;
      if (!_isOggS(_pending, 0)) return _takePassthrough();
    }
    var pos = 0;
    while (true) {
      if (_pending.length - pos >= 4 && !_isOggS(_pending, pos)) {
        // Lost sync: stop tracking and hand the rest over untouched.
        final out = _pending.sublist(0, pos);
        _passthrough = true;
        final rest = _pending.sublist(pos);
        _pending = Uint8List(0);
        return [...out, ...rest];
      }
      final page = _Page.parse(_pending, pos);
      if (page == null) break;
      _track(page);
      pos = page.end;
    }
    final out = _pending.sublist(0, pos);
    _pending = _pending.sublist(pos);
    return out;
  }

  /// Original-phase end of stream: any trailing partial page, untouched.
  List<int> flush() {
    final out = _pending;
    _pending = Uint8List(0);
    return out;
  }

  void _track(_Page page) {
    if (_pages++ == 0) {
      final head = page.bodyStart;
      _opus =
          page.flags & 2 != 0 &&
          page.segments.length == 1 &&
          _isOpusHead(page.data, head, page.end);
      if (_opus) {
        final h = ByteData.sublistView(page.data);
        _channels = page.data[head + 9];
        _preSkip = h.getUint16(head + 10, Endian.little);
        _serial = page.serial;
      }
    }
    _sequence = page.sequence;
    if (page.granule >= 0) _granule = page.granule;
    _endsMidPacket = page.segments.last == 255;
  }

  List<int> _takePassthrough() {
    _passthrough = true;
    final out = _pending;
    _pending = Uint8List(0);
    return out;
  }

  /// Starts parsing a continuation response that begins at [offsetSeconds].
  void beginContinuation(int offsetSeconds) {
    _offsetSeconds = offsetSeconds;
    _packetIndex = 0;
    _pending = Uint8List(0);
    _partial.clear();
    droppedPackets = 0;
  }

  /// Continuation-phase: returns the rewritten pages of the new data.
  List<int> splice(List<int> chunk) {
    _append(chunk);
    final out = BytesBuilder(copy: false);
    var pos = 0;
    while (true) {
      if (_pending.length - pos >= 4 && !_isOggS(_pending, pos)) {
        throw const FormatException('continuation lost Ogg sync');
      }
      final page = _Page.parse(_pending, pos);
      if (page == null) break;
      pos = page.end;
      final rewritten = _rewrite(page);
      if (rewritten != null) out.add(rewritten);
    }
    _pending = _pending.sublist(pos);
    return out.takeBytes();
  }

  Uint8List? _rewrite(_Page page) {
    final packets = <Uint8List>[];
    var at = page.bodyStart;
    for (final s in page.segments) {
      _partial.add(Uint8List.sublistView(page.data, at, at + s));
      at += s;
      if (s < 255) packets.add(_partial.takeBytes());
    }
    final audio = <Uint8List>[];
    for (final packet in packets) {
      if (_packetIndex == 0) {
        if (!_isOpusHead(packet, 0, packet.length) || packet[9] != _channels) {
          throw const FormatException('continuation header mismatch');
        }
        _contPreSkip = ByteData.sublistView(packet)
            .getUint16(10, Endian.little);
        _packetIndex++;
      } else if (_packetIndex == 1) {
        if (!_startsWith(packet, 0, 'OpusTags'.codeUnits)) {
          throw const FormatException('continuation tags missing');
        }
        _packetIndex++;
      } else {
        audio.add(packet);
      }
    }
    if (audio.isEmpty) return null;
    if (page.granule < 0) throw const FormatException('audio without granule');
    // Map the page granule into the delivered stream's granule space, then
    // walk back through the packet durations to place every packet's end.
    final ends = List<int>.filled(audio.length, 0);
    var end = _offsetSeconds * 48000 + (page.granule - _contPreSkip) + _preSkip;
    for (var i = audio.length - 1; i >= 0; i--) {
      ends[i] = end;
      end -= _packetSamples(audio[i]);
    }
    final kept = <Uint8List>[];
    for (var i = 0; i < audio.length; i++) {
      if (ends[i] > _granule) {
        kept.add(audio[i]);
      } else {
        droppedPackets++;
      }
    }
    if (kept.isEmpty) return null;
    _granule = ends.last;
    return _buildPage(_serial, ++_sequence, _granule, page.flags & 4, kept);
  }

  void _append(List<int> chunk) {
    if (_pending.isEmpty) {
      _pending = Uint8List.fromList(chunk);
    } else {
      final joined = Uint8List(_pending.length + chunk.length)
        ..setRange(0, _pending.length, _pending)
        ..setRange(_pending.length, _pending.length + chunk.length, chunk);
      _pending = joined;
    }
  }
}

class _Page {
  _Page(this.data, this.start, this.segments, this.bodyStart, this.end);

  final Uint8List data;
  final int start;
  final Uint8List segments;
  final int bodyStart;
  final int end;

  int get flags => data[start + 5];
  int get granule =>
      ByteData.sublistView(data).getInt64(start + 6, Endian.little);
  int get serial =>
      ByteData.sublistView(data).getUint32(start + 14, Endian.little);
  int get sequence =>
      ByteData.sublistView(data).getUint32(start + 18, Endian.little);

  /// The page at [pos], or null while it is still incomplete.
  static _Page? parse(Uint8List data, int pos) {
    if (data.length - pos < 27) return null;
    final count = data[pos + 26];
    final bodyStart = pos + 27 + count;
    if (data.length < bodyStart) return null;
    final segments = Uint8List.sublistView(data, pos + 27, bodyStart);
    if (segments.isEmpty) {
      // A page without segments carries nothing and cannot be placed.
      throw const FormatException('empty Ogg page');
    }
    var body = 0;
    for (final s in segments) {
      body += s;
    }
    final end = bodyStart + body;
    if (data.length < end) return null;
    return _Page(data, pos, segments, bodyStart, end);
  }
}

bool _isOggS(Uint8List b, int at) => _startsWith(b, at, 'OggS'.codeUnits);

bool _isOpusHead(Uint8List b, int at, int end) =>
    end - at >= 19 && _startsWith(b, at, 'OpusHead'.codeUnits);

bool _startsWith(Uint8List b, int at, List<int> prefix) {
  if (at < 0 || at + prefix.length > b.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (b[at + i] != prefix[i]) return false;
  }
  return true;
}

/// Duration of an Opus packet in 48 kHz samples (RFC 6716 section 3.1).
int _packetSamples(Uint8List packet) {
  if (packet.isEmpty) throw const FormatException('empty Opus packet');
  final toc = packet[0];
  final config = toc >> 3;
  final frame = config < 12
      ? const [480, 960, 1920, 2880][config & 3]
      : config < 16
      ? const [480, 960][config & 1]
      : const [120, 240, 480, 960][config & 3];
  final code = toc & 3;
  final int frames;
  if (code == 0) {
    frames = 1;
  } else if (code < 3) {
    frames = 2;
  } else {
    if (packet.length < 2) throw const FormatException('short Opus packet');
    frames = packet[1] & 0x3F;
  }
  final samples = frame * frames;
  if (samples <= 0 || samples > 5760) {
    throw const FormatException('unplaceable Opus packet duration');
  }
  return samples;
}

Uint8List _buildPage(
  int serial,
  int sequence,
  int granule,
  int flags,
  List<Uint8List> packets,
) {
  final lacing = <int>[];
  var bodyLength = 0;
  for (final p in packets) {
    for (var n = p.length; n >= 255; n -= 255) {
      lacing.add(255);
    }
    lacing.add(p.length % 255);
    bodyLength += p.length;
  }
  if (lacing.length > 255) {
    throw const FormatException('rewritten page exceeds 255 segments');
  }
  final out = Uint8List(27 + lacing.length + bodyLength);
  final h = ByteData.sublistView(out);
  out.setRange(0, 4, 'OggS'.codeUnits);
  out[5] = flags;
  h.setInt64(6, granule, Endian.little);
  h.setUint32(14, serial, Endian.little);
  h.setUint32(18, sequence, Endian.little);
  out[26] = lacing.length;
  out.setRange(27, 27 + lacing.length, lacing);
  var at = 27 + lacing.length;
  for (final p in packets) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  h.setUint32(22, _crc(out), Endian.little);
  return out;
}

final _crcTable = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var r = i << 24;
    for (var k = 0; k < 8; k++) {
      r = (r & 0x80000000) != 0 ? ((r << 1) ^ 0x04C11DB7) : (r << 1);
    }
    table[i] = r & 0xFFFFFFFF;
  }
  return table;
}();

int _crc(Uint8List bytes) {
  var crc = 0;
  for (final b in bytes) {
    crc = ((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) & 0xFF) ^ b];
  }
  return crc;
}
