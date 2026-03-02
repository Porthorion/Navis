// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_queue_dao.dart';

// ignore_for_file: type=lint
mixin _$DownloadQueueDaoMixin on DatabaseAccessor<NavisDatabase> {
  $DownloadQueueTableTable get downloadQueueTable =>
      attachedDatabase.downloadQueueTable;
  DownloadQueueDaoManager get managers => DownloadQueueDaoManager(this);
}

class DownloadQueueDaoManager {
  final _$DownloadQueueDaoMixin _db;
  DownloadQueueDaoManager(this._db);
  $$DownloadQueueTableTableTableManager get downloadQueueTable =>
      $$DownloadQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.downloadQueueTable,
      );
}
