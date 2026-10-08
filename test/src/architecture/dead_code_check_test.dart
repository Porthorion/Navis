import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/dead_code_check.dart';

void main() {
  test('declarations distinguish production and test references', () {
    final report = checkDeadCode({
      'lib/main.dart': '''
void main() { used(); }
void used() {}
void unused() {}
void testHelper() {}
void _private() {}
''',
      'test/example_test.dart': 'void main() { testHelper(); }',
    });
    expect(report.findings.map((f) => f.name), ['unused']);
    expect(report.testOnly.map((f) => f.name), ['testHelper']);
  });

  test('tooling counts as production use, excluding the checker itself', () {
    final report = checkDeadCode({
      'lib/main.dart': '''
void releaseTool() {}
void checkerOnly() {}
void checkerImplementationOnly() {}
void integrationOnly() {}
void unrelatedOnly() {}
''',
      'tool/release.dart': 'void main() { releaseTool(); }',
      'tool/dead_code_check.dart': 'void main() { checkerOnly(); }',
      'tool/src/dead_code.dart':
          'void check() { checkerImplementationOnly(); }',
      'integration_test/example.dart': 'void main() { integrationOnly(); }',
      'other/example.dart': 'void main() { unrelatedOnly(); }',
    });
    expect(report.findings.map((f) => f.name), [
      'checkerImplementationOnly',
      'checkerOnly',
      'unrelatedOnly',
    ]);
    expect(report.testOnly.map((f) => f.name), ['integrationOnly']);
  });

  test(
    'visibleForTesting excludes declarations with or without test callers',
    () {
      final report = checkDeadCode({
        'lib/main.dart': '''
@visibleForTesting
void seam() {}
@meta.visibleForTesting
final observation = 0;
@visibleForTesting
class TestHarness { void helper() {} }
class Production {
  @visibleForTesting
  Production.fixture();
  Production();
  @visibleForTesting
  void hook() {}
  @visibleForTesting
  int get status => 0;
  @visibleForTesting
  final marker = 0;
}
enum Status { active, @visibleForTesting reserved }
void main() { Production(); Status.active; }
''',
        'test/example.dart':
            'void main() { seam(); Production.fixture().hook(); }',
      });
      expect(report.findings, isEmpty);
      expect(report.testOnly, isEmpty);
    },
  );

  test('comments and strings are not references; interpolations are', () {
    final report = checkDeadCode({
      'lib/main.dart': r'''
void main() { print('$interpolated ${expression()}'); }
const interpolated = 1;
int expression() => 2;
void mentionedInComment() {} // mentionedInComment
void mentionedInString() {}
const text = 'mentionedInString';
''',
    });
    expect(report.findings.map((f) => f.name), [
      'mentionedInComment',
      'mentionedInString',
      'text',
    ]);
  });

  test('overrides, lifecycle hooks and native entry points are roots', () {
    final report = checkDeadCode({
      'lib/main.dart': '''
@pragma('vm:entry-point')
void nativeCallback() {}
class WidgetState {
  @override
  void overrideCallback() {}
  void initState() {}
  void build() {}
  void unusedMember() {}
}
void main() { WidgetState(); }
''',
    });
    expect(report.findings.map((f) => f.name), ['WidgetState.unusedMember']);
  });

  test('generated code is a reference source, never a declaration source', () {
    final report = checkDeadCode({
      'lib/models.dart': 'void fromJson() {} void nativeBridgeCallback() {}',
      'lib/models.g.dart': 'void generated() { fromJson(); }',
      'lib/models.freezed.dart': 'void generatedFreezed() {}',
      'third_party/bridge/frb_generated.dart':
          'void nativeCall() { nativeBridgeCallback(); }',
      'lib/l10n/app_localizations.dart': 'void generatedL10n() {}',
    });
    expect(report.findings, isEmpty);
  });

  test('providers used only as identifiers are alive', () {
    final report = checkDeadCode({
      'lib/main.dart': '''
final activeProvider = Provider();
void main() { ref.read(activeProvider); }
''',
    });
    expect(report.findings, isEmpty);
  });

  test('all public declaration and member forms are scanned', () {
    final report = checkDeadCode({
      'lib/example.dart': '''
class PublicClass {
  static void staticMethod() {}
  int get getter => 0;
  set setter(int value) {}
  int field = 0;
  PublicClass.named();
  PublicClass();
}
mixin PublicMixin { void mixinMethod() {} }
enum PublicEnum { constant; void enumMethod() {} }
extension PublicExtension on String { void extensionMethod() {} }
extension type PublicExtensionType(int value) { void typeMethod() {} }
typedef PublicTypedef = void Function();
final topLevel = 0;
''',
    });
    expect(
      report.findings.map((f) => f.name),
      containsAll([
        'PublicClass.staticMethod',
        'PublicClass.getter',
        'PublicClass.setter',
        'PublicClass.field',
        'PublicClass.named',
        'PublicMixin',
        'PublicMixin.mixinMethod',
        'PublicEnum',
        'PublicEnum.constant',
        'PublicEnum.enumMethod',
        'PublicExtension',
        'PublicExtension.extensionMethod',
        'PublicExtensionType',
        'PublicExtensionType.typeMethod',
        'PublicTypedef',
        'topLevel',
      ]),
    );
    expect(
      report.findings.map((f) => f.name),
      isNot(contains('PublicClass.PublicClass')),
    );
  });

  test('external bases do not exempt unannotated members', () {
    final report = checkDeadCode({
      'lib/main.dart': '''
class Child extends ExternalBase implements ExternalInterface {
  void unannotated() {}
  @override
  void annotated() {}
}
void main() { Child(); }
''',
    });
    expect(report.findings.map((f) => f.name), ['Child.unannotated']);
  });

  test('implicit extension access retains its public extension name', () {
    final report = checkDeadCode({
      'lib/main.dart': '''
extension UsedExtension on String { void activeMember() {} }
extension TestExtension on int { void testMember() {} }
void main() { ''.activeMember(); }
''',
      'test/example_test.dart': 'void main() { 1.testMember(); }',
    });
    expect(report.findings, isEmpty);
    expect(report.testOnly.map((f) => f.name), [
      'TestExtension',
      'TestExtension.testMember',
    ]);
  });

  test('extension type representation fields are declarations', () {
    final report = checkDeadCode({
      'lib/main.dart': 'extension type Wrapper(int representation) {}',
    });
    expect(report.findings.map((f) => f.name), [
      'Wrapper',
      'Wrapper.representation',
    ]);
  });

  test('l10n requires dot access outside generated localizations', () {
    final report = checkDeadCode(
      {
        'lib/main.dart': '''
void main() { print(l10n.used); print(AppLocalizations.of(context)!.message(1)); }
''',
        'lib/l10n/app_localizations.dart': 'void generated() { l10n.unused; }',
        'lib/models.g.dart': 'void generatedModel() { l10n.generatedUse; }',
      },
      arb: '{"used":"Used","message":"{count}","unused":"Unused","generatedUse":"Generated","@used":{}}',
    );
    expect(report.findings.map((f) => (f.kind, f.name)), [('l10n', 'unused')]);
  });

  test('assets and fonts require literals; directory loads must exist', () {
    final report = checkDeadCode(
      {
        'lib/main.dart': '''
void main() {
  load('assets/used.svg');
  load('assets/catalog/missing.json');
  load('assets/catalog/present.json');
  font('Inter');
}
''',
      },
      pubspec: '''
flutter:
  assets:
    - assets/used.svg
    - assets/unused.svg
    - assets/catalog/
  fonts:
    - family: Inter
    - family: Other
''',
      assetExists: (path) => path.endsWith('present.json'),
    );
    expect(report.findings.map((f) => (f.kind, f.name)), [
      ('asset', 'assets/unused.svg'),
      ('asset-missing', 'assets/catalog/missing.json'),
      ('font', 'Other'),
    ]);
  });

  test('dependencies include tests, tools and conditional imports', () {
    final report = checkDeadCode(
      {
        'lib/main.dart': "import 'package:app/app.dart' if (dart.library.io) 'package:conditional/io.dart'; void main() {}",
        'test/test.dart': "import 'package:test_support/test.dart';",
        'tool/tool.dart': "import 'package:tool_support/tool.dart';",
        'integration_test/test.dart':
            "import 'package:integration/integration.dart';",
      },
      pubspec: '''
dependencies:
  app: any
  conditional: any
  unused_package: any
dev_dependencies:
  test_support: any
  tool_support: any
  integration: any
  builder: any
''',
      dependencyUses: {'builder'},
    );
    expect(report.findings.map((f) => (f.kind, f.name)), [
      ('dependency', 'unused_package'),
    ]);
  });

  test('baseline ignores line numbers and reports stale entries', () {
    const finding = (
      kind: 'declaration',
      path: 'lib/a.dart',
      name: 'unused',
      line: 99,
    );
    const baseline = (
      kind: 'declaration',
      path: 'lib/a.dart',
      name: 'unused',
      reason: 'dead: candidate for removal',
    );
    final matched = compareBaseline([finding], [baseline]);
    expect(matched.added, isEmpty);
    expect(matched.stale, isEmpty);
    expect(compareBaseline([], [baseline]).stale, [baseline]);
    expect(compareBaseline([finding], []).added, [finding]);
  });

  test(
    'updates preserve reasons, prune stale entries and expose new blanks',
    () {
      const old = (
        kind: 'declaration',
        path: 'lib/a.dart',
        name: 'old',
        reason: 'deliberate: platform callback',
      );
      const stale = (
        kind: 'l10n',
        path: 'lib/l10n/app_en.arb',
        name: 'stale',
        reason: 'dead: candidate for removal',
      );
      const findings = [
        (kind: 'declaration', path: 'lib/a.dart', name: 'old', line: 3),
        (kind: 'declaration', path: 'lib/b.dart', name: 'new', line: 1),
      ];
      expect(updateBaseline(findings, [old, stale]).map((e) => e.reason), [
        old.reason,
        '',
      ]);
      expect(
        updateBaseline(findings, [
          old,
        ], reason: 'dead: candidate for removal').map((e) => e.reason),
        [old.reason, 'dead: candidate for removal'],
      );
      expect(
        compareBaseline([], [
          (kind: 'asset', path: 'pubspec.yaml', name: 'a', reason: ' '),
        ]).invalid,
        hasLength(1),
      );
    },
  );

  test('invalid Dart fails closed', () {
    expect(
      () => checkDeadCode({'lib/main.dart': 'void broken( {'}),
      throwsFormatException,
    );
  });

  ({
    Directory directory,
    File baseline,
    Future<({int exitCode, String stdout, String stderr})> Function(
      List<String>,
    )
    run,
  })
  cliFixture(String source) {
    final directory = Directory.systemTemp.createTempSync('navis-dead-code-');
    addTearDown(() => directory.deleteSync(recursive: true));
    for (final name in ['tool', 'lib/l10n', 'third_party']) {
      Directory(p.join(directory.path, name)).createSync(recursive: true);
    }
    File(p.join(directory.path, 'lib', 'main.dart')).writeAsStringSync(source);
    File(p.join(directory.path, 'lib', 'l10n', 'app_en.arb'))
        .writeAsStringSync('{}');
    File(p.join(directory.path, 'pubspec.yaml'))
        .writeAsStringSync('name: fixture');
    File(p.join(directory.path, 'analysis_options.yaml')).writeAsStringSync('');
    final baseline = File(
      p.join(directory.path, 'tool', 'dead_code_baseline.json'),
    );
    baseline.writeAsStringSync('{"entries":[]}\n');
    Future<({int exitCode, String stdout, String stderr})> run(
      List<String> arguments,
    ) async {
      final output = File(p.join(directory.path, 'stdout.txt'));
      final errors = File(p.join(directory.path, 'stderr.txt'));
      final out = output.openWrite();
      final err = errors.openWrite();
      late final int code;
      try {
        code = runDeadCodeCheck(arguments, root: directory, out: out, err: err);
      } finally {
        await out.close();
        await err.close();
      }
      return (
        exitCode: code,
        stdout: output.readAsStringSync(),
        stderr: errors.readAsStringSync(),
      );
    }

    return (directory: directory, baseline: baseline, run: run);
  }

  test(
    'CLI refuses unreasoned updates without modifying the baseline',
    () async {
      final (:directory, :baseline, :run) = cliFixture('void unused() {}');
      const original = '{"entries":[]}\n';
      final result = await run(['--update']);
      expect(result.exitCode, 2, reason: '${result.stdout}\n${result.stderr}');
      expect(baseline.readAsStringSync(), original);
      final pending = File(
        p.join(directory.path, 'tool', 'dead_code_baseline.pending.json'),
      );
      expect(
        (jsonDecode(pending.readAsStringSync())
            as Map<String, dynamic>)['entries'],
        [
          {
            'kind': 'declaration',
            'path': 'lib/main.dart',
            'name': 'unused',
            'reason': '',
          },
        ],
      );
      final accepted = await run([
        '--update',
        '--reason',
        'dead: candidate for removal',
      ]);
      expect(
        accepted.exitCode,
        0,
        reason: '${accepted.stdout}\n${accepted.stderr}',
      );
      final check = await run([]);
      expect(check.exitCode, 0, reason: '${check.stdout}\n${check.stderr}');
      final app = File(p.join(directory.path, 'lib', 'main.dart'));
      app.writeAsStringSync('void unused() {}\nvoid newlyUnused() {}');
      final added = await run([]);
      expect(added.exitCode, 1);
      expect(
        added.stderr,
        contains('NEW declaration  lib/main.dart:2  newlyUnused'),
      );
      app.writeAsStringSync('void main() {}');
      final stale = await run([]);
      expect(stale.exitCode, 1);
      expect(
        stale.stderr,
        contains('STALE declaration  lib/main.dart  unused'),
      );
      final pruned = await run(['--update']);
      expect(pruned.exitCode, 0);
      expect(
        (jsonDecode(baseline.readAsStringSync())
            as Map<String, dynamic>)['entries'],
        isEmpty,
      );
    },
  );

  test(
    'CLI test-only findings require annotation or a baseline reason',
    () async {
      final (:directory, :baseline, :run) = cliFixture('void onlyTests() {}');
      final app = File(p.join(directory.path, 'lib', 'main.dart'));
      final tests = Directory(p.join(directory.path, 'test'))..createSync();
      File(p.join(tests.path, 'example_test.dart'))
          .writeAsStringSync('void main() { onlyTests(); }');
      app.writeAsStringSync('void onlyTests() {}');
      final testOnly = await run([]);
      expect(testOnly.exitCode, 1);
      expect(
        testOnly.stderr,
        contains('NEW declaration  lib/main.dart:1  onlyTests'),
      );
      final unreasonedTestOnly = await run(['--update']);
      expect(unreasonedTestOnly.exitCode, 2);
      expect(
        (jsonDecode(baseline.readAsStringSync())
            as Map<String, dynamic>)['entries'],
        isEmpty,
      );
      final reasoned = await run([
        '--update',
        '--reason',
        'deliberate: test fixture observation',
      ]);
      expect(reasoned.exitCode, 0);
      final baselined = await run([]);
      expect(baselined.exitCode, 0);
      app.writeAsStringSync('@visibleForTesting\nvoid onlyTests() {}');
      final annotatedStale = await run([]);
      expect(annotatedStale.exitCode, 1);
      expect(
        annotatedStale.stderr,
        contains('STALE declaration  lib/main.dart  onlyTests'),
      );
      final annotatedPrune = await run(['--update']);
      expect(annotatedPrune.exitCode, 0);
      final annotated = await run([]);
      expect(annotated.exitCode, 0);
    },
  );
}
