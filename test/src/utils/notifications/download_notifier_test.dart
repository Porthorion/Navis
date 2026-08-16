import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/notifications/download_notifier.dart';

void main() {
  test('download failure notifications use safe generic copy', () {
    expect(DownloadNotifier.failureNotificationTitle, 'Download failed');
    expect(DownloadNotifier.failureNotificationTitle, isNot(contains(':')));
  });
}
