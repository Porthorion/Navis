import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

typedef _AccessorClass = ({
  String name,
  String path,
  List<String> parameters,
  String parent,
  bool routesTransactions,
});

Map<String, _AccessorClass> _classes(Map<String, String> sources) {
  final classes = <String, _AccessorClass>{};
  for (final entry in sources.entries) {
    final unit = parseString(content: entry.value, path: entry.key).unit;
    for (final declaration in unit.declarations) {
      final String name;
      final TypeParameterList? parameters;
      final NamedType? parent;
      final WithClause? mixins;
      if (declaration is ClassDeclaration) {
        name = declaration.namePart.typeName.lexeme;
        parameters = declaration.namePart.typeParameters;
        parent = declaration.extendsClause?.superclass;
        mixins = declaration.withClause;
      } else if (declaration is ClassTypeAlias) {
        name = declaration.name.lexeme;
        parameters = declaration.typeParameters;
        parent = declaration.superclass;
        mixins = declaration.withClause;
      } else {
        continue;
      }
      if (parent == null) continue;
      classes[name] = (
        name: name,
        path: entry.key,
        parameters: [
          for (final parameter
              in parameters?.typeParameters ?? <TypeParameter>[])
            parameter.name.lexeme,
        ],
        parent: '${parent.name.lexeme}${parent.typeArguments?.toSource() ?? ''}'
            .replaceAll(RegExp(r'\s+'), ''),
        routesTransactions:
            mixins?.mixinTypes.any(
              (type) => type.name.lexeme == 'NavisDaoTransactions',
            ) ??
            false,
      );
    }
  }
  return classes;
}

Iterable<({String location, bool routed})> _navisAccessors(
  Map<String, _AccessorClass> classes,
) sync* {
  for (final declaration in classes.values) {
    var type = declaration.name;
    var routed = false;
    final visited = <String>{};
    while (visited.add(type)) {
      if (type == 'DatabaseAccessor<NavisDatabase>') {
        yield (
          location: '${declaration.path}: ${declaration.name}',
          routed: routed,
        );
        break;
      }
      final name = type.split('<').first;
      final current = classes[name];
      if (current == null) break;
      routed |= current.routesTransactions;
      final arguments = type.contains('<')
          ? type.substring(type.indexOf('<') + 1, type.length - 1).split(',')
          : <String>[];
      var parent = current.parent;
      for (
        var i = 0;
        i < current.parameters.length && i < arguments.length;
        i++
      ) {
        parent = parent.replaceAll(
          RegExp('\\b${current.parameters[i]}\\b'),
          arguments[i],
        );
      }
      type = parent;
    }
  }
}

Iterable<String> _unroutedAccessors(Map<String, _AccessorClass> classes) =>
    _navisAccessors(classes)
        .where((accessor) => !accessor.routed)
        .map((accessor) => accessor.location);

void main() {
  test('every Navis DAO routes transactions through the database', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              p.extension(file.path) == '.dart' &&
              !file.path.endsWith('.g.dart'),
        );
    final classes = _classes({
      for (final file in files) file.path: file.readAsStringSync(),
    });
    expect(_navisAccessors(classes), isNotEmpty);
    expect(_unroutedAccessors(classes), isEmpty);
  });

  test('guard detects feature accessors and intermediate base classes', () {
    final classes = _classes({
      'lib/src/database/base.dart': '''
class Base<T> extends DatabaseAccessor<T> {}
class Intermediate<T> extends Base<T> {}
class PlainBase extends DatabaseAccessor<NavisDatabase> {}
''',
      'lib/src/features/example/data/dao.dart': '''
class FeatureDao extends drift.DatabaseAccessor<NavisDatabase> {}
class DerivedDao extends Intermediate<NavisDatabase> {}
class PlainDerivedDao extends PlainBase {}
class OtherDatabaseDao extends Base<OtherDatabase> {}
''',
    });
    expect(_unroutedAccessors(classes), [
      'lib/src/database/base.dart: PlainBase',
      'lib/src/features/example/data/dao.dart: FeatureDao',
      'lib/src/features/example/data/dao.dart: DerivedDao',
      'lib/src/features/example/data/dao.dart: PlainDerivedDao',
    ]);
  });

  test('guard accepts inherited routing and mixin application bases', () {
    final classes = _classes({
      'lib/src/features/example/data/dao.dart': '''
class RoutedBase = DatabaseAccessor<NavisDatabase> with NavisDaoTransactions;
class DerivedDao extends RoutedBase {}
class GenericBase<T> extends DatabaseAccessor<T> {}
class RoutedDao extends GenericBase<NavisDatabase> with NavisDaoTransactions {}
class LeafDao extends RoutedDao {}
''',
    });
    expect(_unroutedAccessors(classes), isEmpty);
  });
}
