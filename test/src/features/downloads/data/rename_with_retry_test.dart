import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/downloads/data/rename_with_retry.dart';

class _MockFile extends Mock implements File;

void main() {
  test('retries filesystem failures and rethrows the third failure', () async {
    final file = _MockFile();
    const path = 'track.flac';
    var attempts = 0;
    final errors = List.generate(
      3,
      (index) => FileSystemException('held open on attempt ${index + 1}', path),
    );
    when(() => file.rename(path)).thenAnswer((_) async {
      throw errors[attempts++];
    });

    await expectLater(renameWithRetry(file, path), throwsA(same(errors.last)));

    expect(attempts, 3);
    verify(() => file.rename(path)).called(3);
  });
}
