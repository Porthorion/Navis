import 'dart:convert';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

typedef DeadCodeFinding = ({String kind, String path, String name, int line});
typedef DeadCodeReport = ({
  List<DeadCodeFinding> findings,
  List<DeadCodeFinding> testOnly,
});
typedef BaselineEntry = ({
  String kind,
  String path,
  String name,
  String reason,
});

DeadCodeFinding _finding(String kind, String path, String name, int line) =>
    (kind: kind, path: path, name: name, line: line);

String findingKey(String kind, String path, String name) =>
    '$kind\t$path\t$name';

bool _localizations(String path) =>
    p.posix.isWithin('lib/l10n', path) &&
    p.posix.basename(path).startsWith('app_localizations');

bool _generated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    _localizations(path) ||
    (p.posix.isWithin('third_party', path) &&
        p.posix.basename(path).startsWith('frb_generated'));

// Framework lifecycle hooks can be invoked without a Dart identifier reference.
const _callbacks = {
  'build',
  'createState',
  'createElement',
  'dispose',
  'initState',
  'didChangeDependencies',
  'didUpdateWidget',
  'debugFillProperties',
  'toString',
  'hashCode',
  '==',
  'noSuchMethod',
};

bool _entryPoint(AnnotatedNode node) => node.metadata.any(
  (annotation) =>
      annotation.name.name == 'pragma' &&
      annotation.arguments?.arguments.firstOrNull is SimpleStringLiteral &&
      (annotation.arguments!.arguments.first as SimpleStringLiteral).value ==
          'vm:entry-point',
);

bool _visibleForTesting(AnnotatedNode node) => node.metadata.any(
  (annotation) => annotation.name.name.split('.').last == 'visibleForTesting',
);

Iterable<({Token token, AnnotatedNode node, String? owner})> _declarations(
  CompilationUnit unit,
) sync* {
  for (final node in unit.declarations) {
    if (_visibleForTesting(node)) continue;
    final (name, members) = switch (node) {
      ClassDeclaration() => (node.namePart.typeName, node.body.members),
      EnumDeclaration() => (node.namePart.typeName, node.body.members),
      MixinDeclaration() => (node.name, node.body.members),
      ExtensionDeclaration() => (node.name, node.body.members),
      ExtensionTypeDeclaration() => (node.namePart.typeName, node.body.members),
      ClassTypeAlias() => (node.name, const <ClassMember>[]),
      TypeAlias() => (node.name, const <ClassMember>[]),
      FunctionDeclaration() => (node.name, const <ClassMember>[]),
      _ => (null, const <ClassMember>[]),
    };
    if (name != null &&
        !(node is FunctionDeclaration && name.lexeme == 'main')) {
      yield (token: name, node: node, owner: null);
    }
    if (node is TopLevelVariableDeclaration) {
      for (final variable in node.variables.variables) {
        yield (token: variable.name, node: node, owner: null);
      }
    }
    if (node is EnumDeclaration) {
      for (final constant in node.body.constants) {
        yield (token: constant.name, node: constant, owner: name?.lexeme);
      }
    }
    final primary = switch (node) {
      ClassDeclaration() => node.namePart,
      EnumDeclaration() => node.namePart,
      ExtensionTypeDeclaration() => node.namePart,
      _ => null,
    };
    if (primary is PrimaryConstructorDeclaration) {
      final constructor = primary.constructorName?.name;
      if (constructor != null && constructor.lexeme != 'new') {
        yield (token: constructor, node: node, owner: name?.lexeme);
      }
      for (final parameter in primary.formalParameters.parameters) {
        if (parameter.name != null &&
            (node is ExtensionTypeDeclaration ||
                parameter.constFinalOrVarKeyword != null)) {
          yield (token: parameter.name!, node: node, owner: name?.lexeme);
        }
      }
    }
    for (final member in members) {
      if (member.metadata.any(
        (annotation) => annotation.name.name == 'override',
      )) {
        continue;
      }
      final tokens = switch (member) {
        MethodDeclaration() => [member.name],
        ConstructorDeclaration(name: final name?) when name.lexeme != 'new' => [
          name,
        ],
        FieldDeclaration() => [
          for (final variable in member.fields.variables) variable.name,
        ],
        _ => <Token>[],
      };
      for (final token in tokens) {
        if (_callbacks.contains(token.lexeme) ||
            (node is EnumDeclaration &&
                const {'values', 'index', 'name'}.contains(token.lexeme))) {
          continue;
        }
        yield (token: token, node: member, owner: name?.lexeme);
      }
    }
  }
}

class _Strings extends RecursiveAstVisitor<void> {
  final literals = <String, int>{};

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    literals.putIfAbsent(node.value, () => node.offset);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    final value = node.stringValue;
    if (value != null) literals.putIfAbsent(value, () => node.offset);
    super.visitAdjacentStrings(node);
  }
}

int _line(String source, String name) {
  final offset = source.indexOf(name);
  return offset < 0
      ? 1
      : '\n'.allMatches(source.substring(0, offset)).length + 1;
}

/// Checks unresolved sources; generated Dart contributes references only.
/// Identifier collisions are intentionally accepted, so this is not reachability.
DeadCodeReport checkDeadCode(
  Map<String, String> sources, {
  String pubspec = '',
  String arb = '{}',
  Set<String> dependencyUses = const {},
  bool Function(String)? assetExists,
}) {
  final references = <String, int>{};
  final testReferences = <String>{};
  final properties = <String>{};
  final literals = <String, ({String path, int line})>{};
  final imports = <String>{};
  final extensions = <String, List<String>>{};
  final declarations = <({DeadCodeFinding finding, String identifier})>[];
  for (final path in sources.keys.toList()..sort()) {
    final entry = MapEntry(path, sources[path]!);
    final inLib = p.posix.isWithin('lib', entry.key);
    final generated = _generated(entry.key);
    final testReference =
        p.posix.isWithin('test', entry.key) ||
        p.posix.isWithin('integration_test', entry.key);
    final productionReference =
        inLib ||
        (p.posix.isWithin('tool', entry.key) &&
            entry.key != 'tool/dead_code_check.dart' &&
            entry.key != 'tool/src/dead_code.dart') ||
        (p.posix.isWithin('third_party', entry.key) &&
            p.posix.basename(entry.key).startsWith('frb_generated'));
    final parsed = parseString(
      content: entry.value,
      path: entry.key,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.any(
      (error) => error.diagnosticCode.type.name == 'SYNTACTIC_ERROR',
    )) {
      throw FormatException('Cannot scan invalid Dart: ${entry.key}');
    }
    var token = parsed.unit.beginToken;
    while (!token.isEof) {
      if (token.isIdentifier) {
        if (productionReference) {
          references.update(
            token.lexeme,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
          if (inLib &&
              !_localizations(entry.key) &&
              const {'.', '?.', '..', '?..'}.contains(token.previous?.lexeme)) {
            properties.add(token.lexeme);
          }
        } else if (testReference) {
          testReferences.add(token.lexeme);
        }
      }
      token = token.next!;
    }
    final strings = _Strings();
    parsed.unit.accept(strings);
    if (inLib) {
      for (final literal in strings.literals.entries) {
        literals.putIfAbsent(
          literal.key,
          () => (
            path: entry.key,
            line: parsed.lineInfo.getLocation(literal.value).lineNumber,
          ),
        );
      }
    }
    for (final directive in parsed.unit.directives) {
      final uris = switch (directive) {
        ImportDirective() => [
          directive.uri,
          ...directive.configurations.map((c) => c.uri),
        ],
        ExportDirective() => [
          directive.uri,
          ...directive.configurations.map((c) => c.uri),
        ],
        _ => <StringLiteral>[],
      };
      for (final uri in uris) {
        final value = uri.stringValue;
        if (value != null && value.startsWith('package:')) {
          imports.add(value.substring(8).split('/').first);
        }
      }
    }
    if (!inLib || generated) continue;
    for (final declaration in _declarations(parsed.unit)) {
      final name = declaration.token.lexeme;
      if (name.startsWith('_') ||
          _entryPoint(declaration.node) ||
          _visibleForTesting(declaration.node)) {
        continue;
      }
      if (declaration.node case ExtensionDeclaration(:final body)) {
        extensions[name] = [
          for (final member in body.members.whereType<MethodDeclaration>())
            member.name.lexeme,
        ];
      }
      declarations.add((
        identifier: name,
        finding: (
          kind: 'declaration',
          path: entry.key,
          name: declaration.owner == null ? name : '${declaration.owner}.$name',
          line: parsed.lineInfo
              .getLocation(declaration.token.offset)
              .lineNumber,
        ),
      ));
    }
  }
  final findings = <DeadCodeFinding>[];
  final testOnly = <DeadCodeFinding>[];
  for (final declaration in declarations) {
    if ((references[declaration.identifier] ?? 0) > 1) continue;
    // Extensions are selected implicitly through their members.
    final members = extensions[declaration.identifier] ?? <String>[];
    if (members.any((name) => (references[name] ?? 0) > 1)) continue;
    (testReferences.contains(declaration.identifier) ||
                members.any(testReferences.contains)
            ? testOnly
            : findings)
        .add(declaration.finding);
  }
  for (final key in (jsonDecode(arb) as Map<String, dynamic>).keys) {
    if (!key.startsWith('@') && !properties.contains(key)) {
      findings.add(
        _finding('l10n', 'lib/l10n/app_en.arb', key, _line(arb, '"$key"')),
      );
    }
  }
  final config = loadYaml(pubspec) as YamlMap? ?? YamlMap();
  final flutter = config['flutter'] as YamlMap? ?? YamlMap();
  for (final asset in flutter['assets'] as YamlList? ?? YamlList()) {
    final path = asset as String;
    if (path.endsWith('/')) {
      for (final literal in literals.entries) {
        if (p.posix.isWithin(path, literal.key) &&
            assetExists != null &&
            !assetExists(literal.key)) {
          findings.add(
            _finding(
              'asset-missing',
              literal.value.path,
              literal.key,
              literal.value.line,
            ),
          );
        }
      }
    } else if (!literals.containsKey(path)) {
      findings.add(
        _finding('asset', 'pubspec.yaml', path, _line(pubspec, path)),
      );
    }
  }
  for (final font in flutter['fonts'] as YamlList? ?? YamlList()) {
    final family = (font as YamlMap)['family'] as String;
    if (!literals.containsKey(family)) {
      findings.add(
        _finding('font', 'pubspec.yaml', family, _line(pubspec, family)),
      );
    }
  }
  for (final section in ['dependencies', 'dev_dependencies']) {
    for (final name
        in (config[section] as YamlMap? ?? YamlMap()).keys.cast<String>()) {
      if (!imports.contains(name) && !dependencyUses.contains(name)) {
        findings.add(
          _finding(
            'dependency',
            'pubspec.yaml',
            name,
            _line(pubspec, '$name:'),
          ),
        );
      }
    }
  }
  int compare(DeadCodeFinding a, DeadCodeFinding b) => findingKey(
    a.kind,
    a.path,
    a.name,
  ).compareTo(findingKey(b.kind, b.path, b.name));
  findings.sort(compare);
  testOnly.sort(compare);
  return (findings: findings, testOnly: testOnly);
}

({
  List<DeadCodeFinding> added,
  List<BaselineEntry> stale,
  List<BaselineEntry> invalid,
})
compareBaseline(List<DeadCodeFinding> findings, List<BaselineEntry> baseline) {
  final current = {
    for (final f in findings) findingKey(f.kind, f.path, f.name),
  };
  final known = {for (final e in baseline) findingKey(e.kind, e.path, e.name)};
  return (
    added: findings
        .where((f) => !known.contains(findingKey(f.kind, f.path, f.name)))
        .toList(),
    stale: baseline
        .where((e) => !current.contains(findingKey(e.kind, e.path, e.name)))
        .toList(),
    invalid: baseline.where((e) => e.reason.trim().isEmpty).toList(),
  );
}

/// Produces a sorted ratchet update; new findings require an explicit reason.
List<BaselineEntry> updateBaseline(
  List<DeadCodeFinding> findings,
  List<BaselineEntry> baseline, {
  String? reason,
}) {
  final reasons = {
    for (final e in baseline) findingKey(e.kind, e.path, e.name): e.reason,
  };
  return [
    for (final f in findings)
      (
        kind: f.kind,
        path: f.path,
        name: f.name,
        reason: reasons[findingKey(f.kind, f.path, f.name)] ?? reason ?? '',
      ),
  ]..sort(
    (a, b) => findingKey(
      a.kind,
      a.path,
      a.name,
    ).compareTo(findingKey(b.kind, b.path, b.name)),
  );
}
