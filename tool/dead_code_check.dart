import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'src/dead_code.dart';

export 'src/dead_code.dart';

Map<String, String> _sources() => {
  for (final root in ['lib', 'test', 'tool', 'integration_test', 'third_party'])
    if (Directory(root).existsSync())
      for (final file in Directory(
        root,
      ).listSync(recursive: true, followLinks: false).whereType<File>())
        if (p.extension(file.path) == '.dart' &&
            (root != 'third_party' ||
                p.basename(file.path).startsWith('frb_generated')))
          p.posix.joinAll(p.split(file.path)): file.readAsStringSync(),
};

Set<String> _dependencyUses(Map<String, dynamic> baseline) {
  final uses = <String>{};
  // Lint includes may also belong to tracked path dependencies.
  for (final root in ['.', 'third_party']) {
    final files = root == '.'
        ? [File('analysis_options.yaml')]
        : Directory(root)
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((f) => p.basename(f.path) == 'analysis_options.yaml');
    for (final file in files) {
      final config = loadYaml(file.readAsStringSync()) as YamlMap?;
      final include = config?['include'];
      if (include is String && include.startsWith('package:')) {
        uses.add(include.substring(8).split('/').first);
      }
    }
  }
  // Only explicitly documented tooling exceptions are accepted. Their evidence
  // is checked, so removing a CLI/configuration also removes its exemption.
  for (final raw in baseline['dependencyUses'] as List<dynamic>? ?? []) {
    final entry = raw as Map<String, dynamic>;
    final name = entry['name'] as String;
    final reason = entry['reason'] as String;
    if (reason.trim().isEmpty) {
      throw FormatException('Empty tooling reason: $name');
    }
    final source = File(entry['path'] as String);
    if (source.existsSync() &&
        source.readAsStringSync().contains(entry['evidence'] as String)) {
      uses.add(name);
    }
  }
  return uses;
}

void main(List<String> args) {
  final timer = Stopwatch()..start();
  try {
    var update = false;
    String? reason;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--update') {
        update = true;
      } else if (args[i] == '--reason' && i + 1 < args.length) {
        reason = args[++i];
        if (reason.trim().isEmpty) {
          throw const FormatException('Reason must not be empty');
        }
      } else {
        throw const FormatException(
          'Usage: dart run tool/dead_code_check.dart [--update [--reason "text"]]',
        );
      }
    }
    if (reason != null && !update) {
      throw const FormatException('--reason requires --update');
    }
    final file = File(p.join('tool', 'dead_code_baseline.json'));
    final baseline = file.existsSync()
        ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{'entries': <dynamic>[]};
    final entries = [
      for (final raw in baseline['entries'] as List<dynamic>)
        (
          kind: (raw as Map<String, dynamic>)['kind'] as String,
          path: raw['path'] as String,
          name: raw['name'] as String,
          reason: raw['reason'] as String,
        ),
    ];
    final keys = entries.map((e) => findingKey(e.kind, e.path, e.name)).toSet();
    if (keys.length != entries.length) {
      throw const FormatException('Duplicate baseline entry');
    }
    final report = checkDeadCode(
      _sources(),
      pubspec: File('pubspec.yaml').readAsStringSync(),
      arb: File(p.join('lib', 'l10n', 'app_en.arb')).readAsStringSync(),
      dependencyUses: _dependencyUses(baseline),
      assetExists: (path) => File(p.joinAll(p.posix.split(path))).existsSync(),
    );
    for (final finding in report.findings) {
      stdout.writeln(
        '${finding.kind}  ${finding.path}:${finding.line}  ${finding.name}',
      );
    }
    stdout.writeln('test-only (non-blocking):');
    for (final finding in report.testOnly) {
      stdout.writeln(
        'test-only  ${finding.path}:${finding.line}  ${finding.name}',
      );
    }
    final counts = {
      for (final kind in [
        'declaration',
        'l10n',
        'asset',
        'asset-missing',
        'font',
        'dependency',
      ])
        kind: 0,
    };
    for (final finding in report.findings) {
      counts.update(finding.kind, (n) => n + 1, ifAbsent: () => 1);
    }
    stdout.writeln(
      'Summary: ${counts.entries.map((e) => '${e.key}=${e.value}').join(', ')}; test-only=${report.testOnly.length}; ${timer.elapsedMilliseconds}ms',
    );
    if (update) {
      final updated = updateBaseline(report.findings, entries, reason: reason);
      final pending = updated.any((e) => e.reason.trim().isEmpty);
      baseline['entries'] = [
        for (final e in updated)
          {'kind': e.kind, 'path': e.path, 'name': e.name, 'reason': e.reason},
      ];
      final output = pending
          ? File(p.join('tool', 'dead_code_baseline.pending.json'))
          : file;
      output.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(baseline)}\n',
      );
      if (pending) {
        stderr.writeln(
          'Refusing update: fill empty reasons in ${output.path} and fold them into ${file.path}.',
        );
        exitCode = 2;
      }
    } else {
      final difference = compareBaseline(report.findings, entries);
      for (final f in difference.added) {
        stderr.writeln('NEW ${f.kind}  ${f.path}:${f.line}  ${f.name}');
      }
      for (final e in difference.stale) {
        stderr.writeln('STALE ${e.kind}  ${e.path}  ${e.name}');
      }
      for (final e in difference.invalid) {
        stderr.writeln('EMPTY REASON ${e.kind}  ${e.path}  ${e.name}');
      }
      if (difference.added.isNotEmpty ||
          difference.stale.isNotEmpty ||
          difference.invalid.isNotEmpty) {
        exitCode = 1;
      }
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 2;
  }
}
