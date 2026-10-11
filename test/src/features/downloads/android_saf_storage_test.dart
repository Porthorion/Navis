import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.navis.app/permanent_download_storage');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'inspectTree':
            case 'validateWritableTree':
              return <String, Object?>{
                'uri': call.arguments['treeUri'],
                'displayName': 'Downloads',
                'canRead': true,
                'canWrite': true,
                'canReplace': call.method == 'validateWritableTree',
              };
            case 'listRecursively':
              return <Map<String, Object?>>[
                <String, Object?>{
                  'uri': 'content://test/document/root%3Aartist%2Fsong.flac',
                  'relativePath': 'Artist/song.flac',
                  'displayName': 'song.flac',
                  'size': 42,
                  'mimeType': 'audio/flac',
                },
              ];
            case 'isDescendant':
              return call.arguments['documentUri'].toString().contains('root');
            case 'diagnosticsFixtureTree':
              return 'content://test.diagnostics.documents/tree/root';
            case 'diagnosticsFixtureStageUnindexedCopy':
              return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('decodes a writable SAF tree and recursive documents', () async {
    const storage = AndroidSafStorage();
    final tree = await storage.inspectTree('content://test/tree/root');
    final writableTree = await storage.validateWritableTree(tree.uri);
    final documents = await storage.listRecursively(tree.uri);

    expect(tree.displayName, 'Downloads');
    expect(tree.canRead && tree.canWrite, isTrue);
    expect(tree.canReplace, isFalse);
    expect(writableTree.canReplace, isTrue);
    expect(documents.single.relativePath, 'Artist/song.flac');
    expect(documents.single.size, 42);
    expect(
      await storage.isDescendant(
        treeUri: tree.uri,
        documentUri: documents.single.uri,
      ),
      isTrue,
    );
    expect(
      await storage.diagnosticsFixtureTree(),
      'content://test.diagnostics.documents/tree/root',
    );
    await storage.diagnosticsFixtureStageUnindexedCopy();
  });

  test(
    'checks saved documents through the engine-owned playback channel',
    () async {
      const playback = MethodChannel(
        'com.navis.app/permanent_download_playback',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(playback, (call) async {
        expect(call.method, 'exists');
        expect(call.arguments['uri'], 'content://test/document/track');
        calls++;
        return true;
      });
      try {
        expect(
          await const AndroidSafStorage().exists(
            'content://test/document/track',
          ),
          isTrue,
        );
        expect(calls, 1);
        messenger.setMockMethodCallHandler(playback, (_) async => null);
        expect(
          await const AndroidSafStorage().exists(
            'content://test/document/track',
          ),
          isFalse,
        );
        messenger.setMockMethodCallHandler(playback, (_) async {
          throw PlatformException(
            code: 'SAF_STORAGE_ERROR',
            message: 'Read grant revoked',
          );
        });
        await expectLater(
          const AndroidSafStorage().exists('content://test/document/track'),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              'Read grant revoked',
            ),
          ),
        );
      } finally {
        messenger.setMockMethodCallHandler(playback, null);
      }
    },
  );

  for (final (code, errno) in [('NO_SPACE', 28), ('PERMISSION_DENIED', 13)]) {
    test('preserves $code for the download hold policy', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: code),
          );
      await expectLater(
        const AndroidSafStorage().materialize('content://fixture/audio'),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.osError?.errorCode,
            'errno',
            errno,
          ),
        ),
      );
    });
  }

  test(
    'normalizes Android provider failures to recoverable filesystem errors',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'materialize') {
              throw PlatformException(
                code: 'access-denied',
                message: 'Fixture read access is revoked',
              );
            }
            return null;
          });

      await expectLater(
        const AndroidSafStorage().materialize(
          'content://test/document/root%3Atrack.flac',
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'Fixture read access is revoked',
          ),
        ),
      );
    },
  );
}
