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
  var _emittedEos = false;
  int? _originalGranuleBase;
  var _originalSamples = 0;

  /// Granule of the last page handed out (the audio delivered so far).
  var _granule = 0;

  // Packet and continuation state, reset by [beginContinuation].
  var _offsetSeconds = 0;
  var _packetIndex = 0;
  var _contPreSkip = 0;
  int? _contGranule;
  var _continuationEos = false;
  final _partial = BytesBuilder(copy: false);

  /// Packets dropped by the current continuation because they were delivered.
  int droppedPackets = 0;

  /// Whether the stream so far is a clean Opus page sequence with audio.
  bool get canContinue =>
      !_passthrough && _opus && !_endsMidPacket && !_emittedEos && _granule > 0;

  /// Whole-second offset to request: one second of decoder pre-roll before the
  /// end of the delivered audio, so the join decodes like an uncut stream.
  int get resumeSeconds => max(0, (_granule - _preSkip) ~/ 48000 - 1);

  /// Whether the continuation ended with complete packets and an EOS page.
  bool get continuationComplete =>
      _packetIndex >= 2 &&
      _continuationEos &&
      _pending.isEmpty &&
      _partial.isEmpty;

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
      _opus = page.flags & 2 != 0 &&
          page.segments.length == 1 &&
          _isOpusHead(page.data, head, page.end);
      if (_opus) {
        final h = ByteData.sublistView(page.data);
        _channels = page.data[head + 9];
        _preSkip = h.getUint16(head + 10, Endian.little);
        _serial = page.serial;
      }
    }
    if (_opus && _originalGranuleBase == null) {
      try {
        var at = page.bodyStart;
        for (final segment in page.segments) {
          _partial.add(Uint8List.sublistView(page.data, at, at + segment));
          at += segment;
          if (segment < 255) {
            final packet = _partial.takeBytes();
            if (_packetIndex++ >= 2) _originalSamples += _packetSamples(packet);
          }
        }
        if (_originalSamples > 0 && page.granule >= 0) {
          _originalGranuleBase = page.granule - _originalSamples;
        }
      } on FormatException {
        // Invalid original packets keep the plain decoder failure path.
        _opus = false;
      }
    }
    _sequence = page.sequence;
    if (page.flags & 4 != 0) _emittedEos = true;
    if (page.granule >= 0) _granule = page.granule;
    if (page.segments.isNotEmpty) {
      _endsMidPacket = page.segments.last == 255;
    }
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
    _contGranule = _originalGranuleBase;
    _continuationEos = false;
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
    if (page.flags & 4 != 0) _continuationEos = true;
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
        _contPreSkip =
            ByteData.sublistView(packet).getUint16(10, Endian.little);
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
    if (audio.isEmpty) {
      return page.segments.isEmpty ? _emptyEosFor(page) : null;
    }
    if (page.granule < 0) throw const FormatException('audio without granule');
    // Map the page granule into the delivered stream's granule space, then
    // walk back through the packet durations to place every packet's end.
    final samples = audio.map(_packetSamples).toList();
    if (samples.any((n) => 48000 % n != 0)) {
      throw const FormatException('unplaceable Opus packet duration');
    }
    final duration = samples.fold<int>(0, (sum, n) => sum + n);
    final previousGranule = _contGranule;
    // End trimming changes the final granule, not the preceding packet ends.
    final untrimmed = previousGranule == null
        ? page.granule
        : max(page.granule, previousGranule + duration);
    _contGranule = page.granule;
    final mappedGranule =
        _offsetSeconds * 48000 + (page.granule - _contPreSkip) + _preSkip;
    final ends = List<int>.filled(audio.length, 0);
    var end = mappedGranule + untrimmed - page.granule;
    for (var i = audio.length - 1; i >= 0; i--) {
      ends[i] = end;
      end -= samples[i];
    }
    final kept = <Uint8List>[];
    for (var i = 0; i < audio.length; i++) {
      if (ends[i] > _granule && mappedGranule > _granule) {
        kept.add(audio[i]);
      } else {
        droppedPackets++;
      }
    }
    if (kept.isEmpty) return _emptyEosFor(page);
    if (page.flags & 4 != 0) _emittedEos = true;
    final out = BytesBuilder(copy: false);
    var first = 0;
    while (first < kept.length) {
      var last = first;
      var segments = 0;
      while (last < kept.length) {
        final count = kept[last].length ~/ 255 + 1;
        if (segments + count > 255) break;
        segments += count;
        last++;
      }
      if (last == first) throw const FormatException('oversized Opus packet');
      final endIndex = audio.length - kept.length + last - 1;
      out.add(_buildPage(
          _serial,
          ++_sequence,
          last == kept.length ? mappedGranule : ends[endIndex],
          last == kept.length ? page.flags & 4 : 0,
          kept.sublist(first, last)));
      first = last;
    }
    _granule = mappedGranule;
    return out.takeBytes();
  }

  /// A data-less EOS page at the delivered granule when [page] carries EOS
  /// but none of its audio is new (a wholly overlapped final page, or a bare
  /// EOS page) and the delivered stream has not ended yet; otherwise null.
  Uint8List? _emptyEosFor(_Page page) {
    if (_emittedEos ||
        page.flags & 4 == 0 ||
        _packetIndex < 2 ||
        _partial.isNotEmpty) {
      return null;
    }
    _emittedEos = true;
    return _buildPage(_serial, ++_sequence, _granule, 4, const []);
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
