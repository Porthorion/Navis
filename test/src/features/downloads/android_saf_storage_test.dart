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
  });
}
