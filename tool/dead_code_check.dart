import 'dart:io';

import 'src/dead_code.dart';

export 'src/dead_code.dart';

void main(List<String> args) {
  exitCode = runDeadCodeCheck(args, root: Directory.current);
}
