import 'dart:convert';

import 'package:navis/src/utils/constants.dart';

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AutoEqEntry {
  const new({
    required this.name,
    required this.path,
    required this.measurementSource,
    required this.recommended,
  });

  factory fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String;
    final name = json['name'] as String;
    if (name.isEmpty ||
        name.length > 500 ||
        path.isEmpty ||
        path.length > 2000 ||
        path.startsWith('/') ||
        Uri.decodeComponent(path).split('/').any((s) => s == '..') ||
        path.contains(r'\') ||
        path.contains('?') ||
        path.contains('#')) {
      throw const FormatException('Invalid AutoEQ catalogue entry');
    }
    return AutoEqEntry(
      name: name,
      path: path,
      measurementSource: json['source'] as String,
      recommended: json['recommended'] as bool,
    );
  }
  final String name;
  final String path;
  final String measurementSource;
  final bool recommended;

  Map<String, Object> toJson() => {
    'name': name,
    'path': path,
    'source': measurementSource,
    'recommended': recommended,
  };
}

class AutoEqIndex {
  new({required this.revision, required List<AutoEqEntry> entries})
    : entries = List.unmodifiable(entries);

  factory decode(String source) {
    if (utf8.encode(source).length > 5 * 1024 * 1024) {
      throw const FormatException('AutoEQ catalogue is too large');
    }
    final json = jsonDecode(source) as Map<String, dynamic>;
    final revision = json['revision'] as String;
    final entries = json['entries'] as List<dynamic>;
    if (json['version'] != 1 ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(revision) ||
        entries.isEmpty ||
        entries.length > 30000) {
      throw const FormatException('Invalid AutoEQ catalogue');
    }
    return AutoEqIndex(
      revision: revision,
      entries: entries
          .map(
            (dynamic raw) => AutoEqEntry.fromJson(raw as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  factory fromMarkdown({
    required String revision,
    required String recommended,
    required String full,
  }) {
    final paths = _links
        .allMatches(recommended)
        .map((m) => m.group(2)!)
        .toSet();
    final entries = _links
        .allMatches(full)
        .map(
          (m) => AutoEqEntry.fromJson({
            'name': m.group(1),
            'path': m.group(2),
            'source': m.group(3) ?? '',
            'recommended': paths.contains(m.group(2)),
          }),
        )
        .toList();
    return AutoEqIndex.decode(
      jsonEncode({
        'version': 1,
        'revision': revision,
        'entries': entries.map((e) => e.toJson()).toList(),
      }),
    );
  }
  final String revision;
  final List<AutoEqEntry> entries;

  String encode() => jsonEncode({
    'version': 1,
    'revision': revision,
    'entries': entries.map((e) => e.toJson()).toList(),
  });

  List<AutoEqEntry> search(String query, {bool recommendedOnly = true}) {
    final terms = query.toLowerCase().trim().split(RegExp(r'\s+'));
    return entries
        .where(
          (entry) =>
              (!recommendedOnly || entry.recommended) &&
              terms.every(
                '${entry.name} ${entry.measurementSource}'
                    .toLowerCase()
                    .contains,
              ),
        )
        .take(100)
        .toList();
  }

  static final _links = RegExp(
    r'^- \[(.+)\]\(\./(.+)\)(?: by (.*))?$',
    multiLine: true,
  );
}

/// Network is used only for an explicit refresh or profile download.
class AutoEqCatalogue {
  /// Production code passes a [client] from `externalDioFactoryProvider`,
  /// built with [baseOptions], so the integration guard applies.
  new({Dio? client}) : _client = client ?? Dio(baseOptions);

  static final baseOptions = BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    followRedirects: false,
    headers: {'User-Agent': AppConstants.userAgent},
  );
  final Dio _client;
  Future<File> _cache() async => File(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'equalizer',
      'autoeq-index.json',
    ),
  );

  Future<AutoEqIndex> load() async {
    try {
      final cache = await _cache();
      if (cache.existsSync() && cache.lengthSync() <= 5 * 1024 * 1024) {
        return AutoEqIndex.decode(cache.readAsStringSync());
      }
    } on Object {
      // A damaged/unsupported refresh cache never prevents bundled discovery.
    }
    return AutoEqIndex.decode(
      await rootBundle.loadString('assets/autoeq/index.json'),
    );
  }

  Future<String> _text(String url, {int limit = 5 * 1024 * 1024}) async {
    var bytes = 0;
    final response = await _client.get<ResponseBody>(
      url,
      // Refresh and download only run when the user asks for them.
      options: userInitiatedOptions(Options(responseType: ResponseType.stream)),
    );
    final chunks = <int>[];
    await for (final chunk in response.data!.stream) {
      bytes += chunk.length;
      if (bytes > limit) {
        throw const FormatException('AutoEQ response is too large');
      }
      chunks.addAll(chunk);
    }
    return utf8.decode(chunks);
  }

  Future<AutoEqIndex> refresh() async {
    final commit = jsonDecode(
      await _text(
        'https://api.github.com/repos/jaakkopasanen/AutoEq/commits/master',
        limit: 1024 * 1024,
      ),
    ) as Map<String, dynamic>;
    final revision = commit['sha'] as String;
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(revision)) {
      throw const FormatException('Invalid AutoEQ revision');
    }
    final base =
        'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/$revision/results';
    final recommended = await _text('$base/README.md');
    final full = await _text('$base/INDEX.md');
    final index = AutoEqIndex.fromMarkdown(
      revision: revision,
      recommended: recommended,
      full: full,
    );
    final cache = await _cache();
    cache.parent.createSync(recursive: true);
    final temporary = File('${cache.path}.tmp');
    temporary.writeAsStringSync(index.encode(), flush: true);
    temporary.renameSync(cache.path);
    return index;
  }

  Future<EqPreset> download(
    AutoEqIndex index,
    AutoEqEntry entry, {
    bool fixedBand = false,
  }) async {
    // Only validated catalogue entries from this exact revision are allowed.
    if (!index.entries.contains(entry)) {
      throw ArgumentError('Unknown AutoEQ entry');
    }
    final leaf = Uri.decodeComponent(entry.path.split('/').last);
    final filename = Uri.encodeComponent(
      '$leaf ${fixedBand ? 'FixedBandEQ' : 'ParametricEQ'}.txt',
    );
    final url =
        'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/'
        '${index.revision}/results/${entry.path}/$filename';
    final text = await _text(url, limit: EqImportParser.maximumBytes);
    return EqImportParser().parse(
      text,
      id: 'preview',
      name: entry.name,
      fixedBand: fixedBand,
      sourceUrl: url,
      revision: index.revision,
      measurementSource: entry.measurementSource,
    );
  }
}
