// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'navis_database.dart';

// ignore_for_file: type=lint
class $ServerConfigTableTable extends ServerConfigTable
    with TableInfo<$ServerConfigTableTable, ServerConfigTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerConfigTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _apiVersionMeta = const VerificationMeta(
    'apiVersion',
  );
  @override
  late final GeneratedColumn<String> apiVersion = GeneratedColumn<String>(
    'api_version',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _capabilitiesMeta = const VerificationMeta(
    'capabilities',
  );
  @override
  late final GeneratedColumn<String> capabilities = GeneratedColumn<String>(
    'capabilities',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastSyncedMeta = const VerificationMeta(
    'lastSynced',
  );
  @override
  late final GeneratedColumn<DateTime> lastSynced = GeneratedColumn<DateTime>(
    'last_synced',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastFullSyncedMeta = const VerificationMeta(
    'lastFullSynced',
  );
  @override
  late final GeneratedColumn<DateTime> lastFullSynced =
      GeneratedColumn<DateTime>(
        'last_full_synced',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    url,
    username,
    apiVersion,
    capabilities,
    lastSynced,
    lastFullSynced,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'server_config';
  @override
  VerificationContext validateIntegrity(
    Insertable<ServerConfigTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    } else if (isInserting) {
      context.missing(_urlMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('api_version')) {
      context.handle(
        _apiVersionMeta,
        apiVersion.isAcceptableOrUnknown(data['api_version']!, _apiVersionMeta),
      );
    } else if (isInserting) {
      context.missing(_apiVersionMeta);
    }
    if (data.containsKey('capabilities')) {
      context.handle(
        _capabilitiesMeta,
        capabilities.isAcceptableOrUnknown(
          data['capabilities']!,
          _capabilitiesMeta,
        ),
      );
    }
    if (data.containsKey('last_synced')) {
      context.handle(
        _lastSyncedMeta,
        lastSynced.isAcceptableOrUnknown(data['last_synced']!, _lastSyncedMeta),
      );
    }
    if (data.containsKey('last_full_synced')) {
      context.handle(
        _lastFullSyncedMeta,
        lastFullSynced.isAcceptableOrUnknown(
          data['last_full_synced']!,
          _lastFullSyncedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ServerConfigTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ServerConfigTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      ),
      url: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      apiVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}api_version'],
      )!,
      capabilities: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}capabilities'],
      ),
      lastSynced: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_synced'],
      ),
      lastFullSynced: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_full_synced'],
      ),
    );
  }

  @override
  $ServerConfigTableTable createAlias(String alias) {
    return $ServerConfigTableTable(attachedDatabase, alias);
  }
}

class ServerConfigTableData extends DataClass
    implements Insertable<ServerConfigTableData> {
  final int id;
  final String? name;
  final String url;
  final String username;
  final String apiVersion;
  final String? capabilities;
  final DateTime? lastSynced;
  final DateTime? lastFullSynced;
  const ServerConfigTableData({
    required this.id,
    this.name,
    required this.url,
    required this.username,
    required this.apiVersion,
    this.capabilities,
    this.lastSynced,
    this.lastFullSynced,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    map['url'] = Variable<String>(url);
    map['username'] = Variable<String>(username);
    map['api_version'] = Variable<String>(apiVersion);
    if (!nullToAbsent || capabilities != null) {
      map['capabilities'] = Variable<String>(capabilities);
    }
    if (!nullToAbsent || lastSynced != null) {
      map['last_synced'] = Variable<DateTime>(lastSynced);
    }
    if (!nullToAbsent || lastFullSynced != null) {
      map['last_full_synced'] = Variable<DateTime>(lastFullSynced);
    }
    return map;
  }

  ServerConfigTableCompanion toCompanion(bool nullToAbsent) {
    return ServerConfigTableCompanion(
      id: Value(id),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
      url: Value(url),
      username: Value(username),
      apiVersion: Value(apiVersion),
      capabilities: capabilities == null && nullToAbsent
          ? const Value.absent()
          : Value(capabilities),
      lastSynced: lastSynced == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSynced),
      lastFullSynced: lastFullSynced == null && nullToAbsent
          ? const Value.absent()
          : Value(lastFullSynced),
    );
  }

  factory ServerConfigTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ServerConfigTableData(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String?>(json['name']),
      url: serializer.fromJson<String>(json['url']),
      username: serializer.fromJson<String>(json['username']),
      apiVersion: serializer.fromJson<String>(json['apiVersion']),
      capabilities: serializer.fromJson<String?>(json['capabilities']),
      lastSynced: serializer.fromJson<DateTime?>(json['lastSynced']),
      lastFullSynced: serializer.fromJson<DateTime?>(json['lastFullSynced']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String?>(name),
      'url': serializer.toJson<String>(url),
      'username': serializer.toJson<String>(username),
      'apiVersion': serializer.toJson<String>(apiVersion),
      'capabilities': serializer.toJson<String?>(capabilities),
      'lastSynced': serializer.toJson<DateTime?>(lastSynced),
      'lastFullSynced': serializer.toJson<DateTime?>(lastFullSynced),
    };
  }

  ServerConfigTableData copyWith({
    int? id,
    Value<String?> name = const Value.absent(),
    String? url,
    String? username,
    String? apiVersion,
    Value<String?> capabilities = const Value.absent(),
    Value<DateTime?> lastSynced = const Value.absent(),
    Value<DateTime?> lastFullSynced = const Value.absent(),
  }) => ServerConfigTableData(
    id: id ?? this.id,
    name: name.present ? name.value : this.name,
    url: url ?? this.url,
    username: username ?? this.username,
    apiVersion: apiVersion ?? this.apiVersion,
    capabilities: capabilities.present ? capabilities.value : this.capabilities,
    lastSynced: lastSynced.present ? lastSynced.value : this.lastSynced,
    lastFullSynced: lastFullSynced.present
        ? lastFullSynced.value
        : this.lastFullSynced,
  );
  ServerConfigTableData copyWithCompanion(ServerConfigTableCompanion data) {
    return ServerConfigTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      url: data.url.present ? data.url.value : this.url,
      username: data.username.present ? data.username.value : this.username,
      apiVersion: data.apiVersion.present
          ? data.apiVersion.value
          : this.apiVersion,
      capabilities: data.capabilities.present
          ? data.capabilities.value
          : this.capabilities,
      lastSynced: data.lastSynced.present
          ? data.lastSynced.value
          : this.lastSynced,
      lastFullSynced: data.lastFullSynced.present
          ? data.lastFullSynced.value
          : this.lastFullSynced,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ServerConfigTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('url: $url, ')
          ..write('username: $username, ')
          ..write('apiVersion: $apiVersion, ')
          ..write('capabilities: $capabilities, ')
          ..write('lastSynced: $lastSynced, ')
          ..write('lastFullSynced: $lastFullSynced')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    url,
    username,
    apiVersion,
    capabilities,
    lastSynced,
    lastFullSynced,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ServerConfigTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.url == this.url &&
          other.username == this.username &&
          other.apiVersion == this.apiVersion &&
          other.capabilities == this.capabilities &&
          other.lastSynced == this.lastSynced &&
          other.lastFullSynced == this.lastFullSynced);
}

class ServerConfigTableCompanion
    extends UpdateCompanion<ServerConfigTableData> {
  final Value<int> id;
  final Value<String?> name;
  final Value<String> url;
  final Value<String> username;
  final Value<String> apiVersion;
  final Value<String?> capabilities;
  final Value<DateTime?> lastSynced;
  final Value<DateTime?> lastFullSynced;
  const ServerConfigTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.url = const Value.absent(),
    this.username = const Value.absent(),
    this.apiVersion = const Value.absent(),
    this.capabilities = const Value.absent(),
    this.lastSynced = const Value.absent(),
    this.lastFullSynced = const Value.absent(),
  });
  ServerConfigTableCompanion.insert({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    required String url,
    required String username,
    required String apiVersion,
    this.capabilities = const Value.absent(),
    this.lastSynced = const Value.absent(),
    this.lastFullSynced = const Value.absent(),
  }) : url = Value(url),
       username = Value(username),
       apiVersion = Value(apiVersion);
  static Insertable<ServerConfigTableData> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? url,
    Expression<String>? username,
    Expression<String>? apiVersion,
    Expression<String>? capabilities,
    Expression<DateTime>? lastSynced,
    Expression<DateTime>? lastFullSynced,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (url != null) 'url': url,
      if (username != null) 'username': username,
      if (apiVersion != null) 'api_version': apiVersion,
      if (capabilities != null) 'capabilities': capabilities,
      if (lastSynced != null) 'last_synced': lastSynced,
      if (lastFullSynced != null) 'last_full_synced': lastFullSynced,
    });
  }

  ServerConfigTableCompanion copyWith({
    Value<int>? id,
    Value<String?>? name,
    Value<String>? url,
    Value<String>? username,
    Value<String>? apiVersion,
    Value<String?>? capabilities,
    Value<DateTime?>? lastSynced,
    Value<DateTime?>? lastFullSynced,
  }) {
    return ServerConfigTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      url: url ?? this.url,
      username: username ?? this.username,
      apiVersion: apiVersion ?? this.apiVersion,
      capabilities: capabilities ?? this.capabilities,
      lastSynced: lastSynced ?? this.lastSynced,
      lastFullSynced: lastFullSynced ?? this.lastFullSynced,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (apiVersion.present) {
      map['api_version'] = Variable<String>(apiVersion.value);
    }
    if (capabilities.present) {
      map['capabilities'] = Variable<String>(capabilities.value);
    }
    if (lastSynced.present) {
      map['last_synced'] = Variable<DateTime>(lastSynced.value);
    }
    if (lastFullSynced.present) {
      map['last_full_synced'] = Variable<DateTime>(lastFullSynced.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ServerConfigTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('url: $url, ')
          ..write('username: $username, ')
          ..write('apiVersion: $apiVersion, ')
          ..write('capabilities: $capabilities, ')
          ..write('lastSynced: $lastSynced, ')
          ..write('lastFullSynced: $lastFullSynced')
          ..write(')'))
        .toString();
  }
}

class $AppSettingsTableTable extends AppSettingsTable
    with TableInfo<$AppSettingsTableTable, AppSettingsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _wifiMaxBitRateMeta = const VerificationMeta(
    'wifiMaxBitRate',
  );
  @override
  late final GeneratedColumn<int> wifiMaxBitRate = GeneratedColumn<int>(
    'wifi_max_bit_rate',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _wifiFormatMeta = const VerificationMeta(
    'wifiFormat',
  );
  @override
  late final GeneratedColumn<String> wifiFormat = GeneratedColumn<String>(
    'wifi_format',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cellularMaxBitRateMeta =
      const VerificationMeta('cellularMaxBitRate');
  @override
  late final GeneratedColumn<int> cellularMaxBitRate = GeneratedColumn<int>(
    'cellular_max_bit_rate',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _cellularFormatMeta = const VerificationMeta(
    'cellularFormat',
  );
  @override
  late final GeneratedColumn<String> cellularFormat = GeneratedColumn<String>(
    'cellular_format',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _scrobbleEnabledMeta = const VerificationMeta(
    'scrobbleEnabled',
  );
  @override
  late final GeneratedColumn<bool> scrobbleEnabled = GeneratedColumn<bool>(
    'scrobble_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("scrobble_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _gaplessEnabledMeta = const VerificationMeta(
    'gaplessEnabled',
  );
  @override
  late final GeneratedColumn<bool> gaplessEnabled = GeneratedColumn<bool>(
    'gapless_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("gapless_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _skipSilenceEnabledMeta =
      const VerificationMeta('skipSilenceEnabled');
  @override
  late final GeneratedColumn<bool> skipSilenceEnabled = GeneratedColumn<bool>(
    'skip_silence_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("skip_silence_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    wifiMaxBitRate,
    wifiFormat,
    cellularMaxBitRate,
    cellularFormat,
    scrobbleEnabled,
    gaplessEnabled,
    skipSilenceEnabled,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSettingsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('wifi_max_bit_rate')) {
      context.handle(
        _wifiMaxBitRateMeta,
        wifiMaxBitRate.isAcceptableOrUnknown(
          data['wifi_max_bit_rate']!,
          _wifiMaxBitRateMeta,
        ),
      );
    }
    if (data.containsKey('wifi_format')) {
      context.handle(
        _wifiFormatMeta,
        wifiFormat.isAcceptableOrUnknown(data['wifi_format']!, _wifiFormatMeta),
      );
    }
    if (data.containsKey('cellular_max_bit_rate')) {
      context.handle(
        _cellularMaxBitRateMeta,
        cellularMaxBitRate.isAcceptableOrUnknown(
          data['cellular_max_bit_rate']!,
          _cellularMaxBitRateMeta,
        ),
      );
    }
    if (data.containsKey('cellular_format')) {
      context.handle(
        _cellularFormatMeta,
        cellularFormat.isAcceptableOrUnknown(
          data['cellular_format']!,
          _cellularFormatMeta,
        ),
      );
    }
    if (data.containsKey('scrobble_enabled')) {
      context.handle(
        _scrobbleEnabledMeta,
        scrobbleEnabled.isAcceptableOrUnknown(
          data['scrobble_enabled']!,
          _scrobbleEnabledMeta,
        ),
      );
    }
    if (data.containsKey('gapless_enabled')) {
      context.handle(
        _gaplessEnabledMeta,
        gaplessEnabled.isAcceptableOrUnknown(
          data['gapless_enabled']!,
          _gaplessEnabledMeta,
        ),
      );
    }
    if (data.containsKey('skip_silence_enabled')) {
      context.handle(
        _skipSilenceEnabledMeta,
        skipSilenceEnabled.isAcceptableOrUnknown(
          data['skip_silence_enabled']!,
          _skipSilenceEnabledMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AppSettingsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSettingsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      wifiMaxBitRate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}wifi_max_bit_rate'],
      ),
      wifiFormat: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}wifi_format'],
      ),
      cellularMaxBitRate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cellular_max_bit_rate'],
      ),
      cellularFormat: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cellular_format'],
      ),
      scrobbleEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}scrobble_enabled'],
      )!,
      gaplessEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}gapless_enabled'],
      )!,
      skipSilenceEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}skip_silence_enabled'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $AppSettingsTableTable createAlias(String alias) {
    return $AppSettingsTableTable(attachedDatabase, alias);
  }
}

class AppSettingsTableData extends DataClass
    implements Insertable<AppSettingsTableData> {
  final int id;
  final int? wifiMaxBitRate;
  final String? wifiFormat;
  final int? cellularMaxBitRate;
  final String? cellularFormat;
  final bool scrobbleEnabled;
  final bool gaplessEnabled;
  final bool skipSilenceEnabled;
  final DateTime updatedAt;
  const AppSettingsTableData({
    required this.id,
    this.wifiMaxBitRate,
    this.wifiFormat,
    this.cellularMaxBitRate,
    this.cellularFormat,
    required this.scrobbleEnabled,
    required this.gaplessEnabled,
    required this.skipSilenceEnabled,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || wifiMaxBitRate != null) {
      map['wifi_max_bit_rate'] = Variable<int>(wifiMaxBitRate);
    }
    if (!nullToAbsent || wifiFormat != null) {
      map['wifi_format'] = Variable<String>(wifiFormat);
    }
    if (!nullToAbsent || cellularMaxBitRate != null) {
      map['cellular_max_bit_rate'] = Variable<int>(cellularMaxBitRate);
    }
    if (!nullToAbsent || cellularFormat != null) {
      map['cellular_format'] = Variable<String>(cellularFormat);
    }
    map['scrobble_enabled'] = Variable<bool>(scrobbleEnabled);
    map['gapless_enabled'] = Variable<bool>(gaplessEnabled);
    map['skip_silence_enabled'] = Variable<bool>(skipSilenceEnabled);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  AppSettingsTableCompanion toCompanion(bool nullToAbsent) {
    return AppSettingsTableCompanion(
      id: Value(id),
      wifiMaxBitRate: wifiMaxBitRate == null && nullToAbsent
          ? const Value.absent()
          : Value(wifiMaxBitRate),
      wifiFormat: wifiFormat == null && nullToAbsent
          ? const Value.absent()
          : Value(wifiFormat),
      cellularMaxBitRate: cellularMaxBitRate == null && nullToAbsent
          ? const Value.absent()
          : Value(cellularMaxBitRate),
      cellularFormat: cellularFormat == null && nullToAbsent
          ? const Value.absent()
          : Value(cellularFormat),
      scrobbleEnabled: Value(scrobbleEnabled),
      gaplessEnabled: Value(gaplessEnabled),
      skipSilenceEnabled: Value(skipSilenceEnabled),
      updatedAt: Value(updatedAt),
    );
  }

  factory AppSettingsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSettingsTableData(
      id: serializer.fromJson<int>(json['id']),
      wifiMaxBitRate: serializer.fromJson<int?>(json['wifiMaxBitRate']),
      wifiFormat: serializer.fromJson<String?>(json['wifiFormat']),
      cellularMaxBitRate: serializer.fromJson<int?>(json['cellularMaxBitRate']),
      cellularFormat: serializer.fromJson<String?>(json['cellularFormat']),
      scrobbleEnabled: serializer.fromJson<bool>(json['scrobbleEnabled']),
      gaplessEnabled: serializer.fromJson<bool>(json['gaplessEnabled']),
      skipSilenceEnabled: serializer.fromJson<bool>(json['skipSilenceEnabled']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'wifiMaxBitRate': serializer.toJson<int?>(wifiMaxBitRate),
      'wifiFormat': serializer.toJson<String?>(wifiFormat),
      'cellularMaxBitRate': serializer.toJson<int?>(cellularMaxBitRate),
      'cellularFormat': serializer.toJson<String?>(cellularFormat),
      'scrobbleEnabled': serializer.toJson<bool>(scrobbleEnabled),
      'gaplessEnabled': serializer.toJson<bool>(gaplessEnabled),
      'skipSilenceEnabled': serializer.toJson<bool>(skipSilenceEnabled),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  AppSettingsTableData copyWith({
    int? id,
    Value<int?> wifiMaxBitRate = const Value.absent(),
    Value<String?> wifiFormat = const Value.absent(),
    Value<int?> cellularMaxBitRate = const Value.absent(),
    Value<String?> cellularFormat = const Value.absent(),
    bool? scrobbleEnabled,
    bool? gaplessEnabled,
    bool? skipSilenceEnabled,
    DateTime? updatedAt,
  }) => AppSettingsTableData(
    id: id ?? this.id,
    wifiMaxBitRate: wifiMaxBitRate.present
        ? wifiMaxBitRate.value
        : this.wifiMaxBitRate,
    wifiFormat: wifiFormat.present ? wifiFormat.value : this.wifiFormat,
    cellularMaxBitRate: cellularMaxBitRate.present
        ? cellularMaxBitRate.value
        : this.cellularMaxBitRate,
    cellularFormat: cellularFormat.present
        ? cellularFormat.value
        : this.cellularFormat,
    scrobbleEnabled: scrobbleEnabled ?? this.scrobbleEnabled,
    gaplessEnabled: gaplessEnabled ?? this.gaplessEnabled,
    skipSilenceEnabled: skipSilenceEnabled ?? this.skipSilenceEnabled,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  AppSettingsTableData copyWithCompanion(AppSettingsTableCompanion data) {
    return AppSettingsTableData(
      id: data.id.present ? data.id.value : this.id,
      wifiMaxBitRate: data.wifiMaxBitRate.present
          ? data.wifiMaxBitRate.value
          : this.wifiMaxBitRate,
      wifiFormat: data.wifiFormat.present
          ? data.wifiFormat.value
          : this.wifiFormat,
      cellularMaxBitRate: data.cellularMaxBitRate.present
          ? data.cellularMaxBitRate.value
          : this.cellularMaxBitRate,
      cellularFormat: data.cellularFormat.present
          ? data.cellularFormat.value
          : this.cellularFormat,
      scrobbleEnabled: data.scrobbleEnabled.present
          ? data.scrobbleEnabled.value
          : this.scrobbleEnabled,
      gaplessEnabled: data.gaplessEnabled.present
          ? data.gaplessEnabled.value
          : this.gaplessEnabled,
      skipSilenceEnabled: data.skipSilenceEnabled.present
          ? data.skipSilenceEnabled.value
          : this.skipSilenceEnabled,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingsTableData(')
          ..write('id: $id, ')
          ..write('wifiMaxBitRate: $wifiMaxBitRate, ')
          ..write('wifiFormat: $wifiFormat, ')
          ..write('cellularMaxBitRate: $cellularMaxBitRate, ')
          ..write('cellularFormat: $cellularFormat, ')
          ..write('scrobbleEnabled: $scrobbleEnabled, ')
          ..write('gaplessEnabled: $gaplessEnabled, ')
          ..write('skipSilenceEnabled: $skipSilenceEnabled, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    wifiMaxBitRate,
    wifiFormat,
    cellularMaxBitRate,
    cellularFormat,
    scrobbleEnabled,
    gaplessEnabled,
    skipSilenceEnabled,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppSettingsTableData &&
          other.id == this.id &&
          other.wifiMaxBitRate == this.wifiMaxBitRate &&
          other.wifiFormat == this.wifiFormat &&
          other.cellularMaxBitRate == this.cellularMaxBitRate &&
          other.cellularFormat == this.cellularFormat &&
          other.scrobbleEnabled == this.scrobbleEnabled &&
          other.gaplessEnabled == this.gaplessEnabled &&
          other.skipSilenceEnabled == this.skipSilenceEnabled &&
          other.updatedAt == this.updatedAt);
}

class AppSettingsTableCompanion extends UpdateCompanion<AppSettingsTableData> {
  final Value<int> id;
  final Value<int?> wifiMaxBitRate;
  final Value<String?> wifiFormat;
  final Value<int?> cellularMaxBitRate;
  final Value<String?> cellularFormat;
  final Value<bool> scrobbleEnabled;
  final Value<bool> gaplessEnabled;
  final Value<bool> skipSilenceEnabled;
  final Value<DateTime> updatedAt;
  const AppSettingsTableCompanion({
    this.id = const Value.absent(),
    this.wifiMaxBitRate = const Value.absent(),
    this.wifiFormat = const Value.absent(),
    this.cellularMaxBitRate = const Value.absent(),
    this.cellularFormat = const Value.absent(),
    this.scrobbleEnabled = const Value.absent(),
    this.gaplessEnabled = const Value.absent(),
    this.skipSilenceEnabled = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  AppSettingsTableCompanion.insert({
    this.id = const Value.absent(),
    this.wifiMaxBitRate = const Value.absent(),
    this.wifiFormat = const Value.absent(),
    this.cellularMaxBitRate = const Value.absent(),
    this.cellularFormat = const Value.absent(),
    this.scrobbleEnabled = const Value.absent(),
    this.gaplessEnabled = const Value.absent(),
    this.skipSilenceEnabled = const Value.absent(),
    required DateTime updatedAt,
  }) : updatedAt = Value(updatedAt);
  static Insertable<AppSettingsTableData> custom({
    Expression<int>? id,
    Expression<int>? wifiMaxBitRate,
    Expression<String>? wifiFormat,
    Expression<int>? cellularMaxBitRate,
    Expression<String>? cellularFormat,
    Expression<bool>? scrobbleEnabled,
    Expression<bool>? gaplessEnabled,
    Expression<bool>? skipSilenceEnabled,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (wifiMaxBitRate != null) 'wifi_max_bit_rate': wifiMaxBitRate,
      if (wifiFormat != null) 'wifi_format': wifiFormat,
      if (cellularMaxBitRate != null)
        'cellular_max_bit_rate': cellularMaxBitRate,
      if (cellularFormat != null) 'cellular_format': cellularFormat,
      if (scrobbleEnabled != null) 'scrobble_enabled': scrobbleEnabled,
      if (gaplessEnabled != null) 'gapless_enabled': gaplessEnabled,
      if (skipSilenceEnabled != null)
        'skip_silence_enabled': skipSilenceEnabled,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  AppSettingsTableCompanion copyWith({
    Value<int>? id,
    Value<int?>? wifiMaxBitRate,
    Value<String?>? wifiFormat,
    Value<int?>? cellularMaxBitRate,
    Value<String?>? cellularFormat,
    Value<bool>? scrobbleEnabled,
    Value<bool>? gaplessEnabled,
    Value<bool>? skipSilenceEnabled,
    Value<DateTime>? updatedAt,
  }) {
    return AppSettingsTableCompanion(
      id: id ?? this.id,
      wifiMaxBitRate: wifiMaxBitRate ?? this.wifiMaxBitRate,
      wifiFormat: wifiFormat ?? this.wifiFormat,
      cellularMaxBitRate: cellularMaxBitRate ?? this.cellularMaxBitRate,
      cellularFormat: cellularFormat ?? this.cellularFormat,
      scrobbleEnabled: scrobbleEnabled ?? this.scrobbleEnabled,
      gaplessEnabled: gaplessEnabled ?? this.gaplessEnabled,
      skipSilenceEnabled: skipSilenceEnabled ?? this.skipSilenceEnabled,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (wifiMaxBitRate.present) {
      map['wifi_max_bit_rate'] = Variable<int>(wifiMaxBitRate.value);
    }
    if (wifiFormat.present) {
      map['wifi_format'] = Variable<String>(wifiFormat.value);
    }
    if (cellularMaxBitRate.present) {
      map['cellular_max_bit_rate'] = Variable<int>(cellularMaxBitRate.value);
    }
    if (cellularFormat.present) {
      map['cellular_format'] = Variable<String>(cellularFormat.value);
    }
    if (scrobbleEnabled.present) {
      map['scrobble_enabled'] = Variable<bool>(scrobbleEnabled.value);
    }
    if (gaplessEnabled.present) {
      map['gapless_enabled'] = Variable<bool>(gaplessEnabled.value);
    }
    if (skipSilenceEnabled.present) {
      map['skip_silence_enabled'] = Variable<bool>(skipSilenceEnabled.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingsTableCompanion(')
          ..write('id: $id, ')
          ..write('wifiMaxBitRate: $wifiMaxBitRate, ')
          ..write('wifiFormat: $wifiFormat, ')
          ..write('cellularMaxBitRate: $cellularMaxBitRate, ')
          ..write('cellularFormat: $cellularFormat, ')
          ..write('scrobbleEnabled: $scrobbleEnabled, ')
          ..write('gaplessEnabled: $gaplessEnabled, ')
          ..write('skipSilenceEnabled: $skipSilenceEnabled, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $ArtistsTableTable extends ArtistsTable
    with TableInfo<$ArtistsTableTable, ArtistsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ArtistsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _albumCountMeta = const VerificationMeta(
    'albumCount',
  );
  @override
  late final GeneratedColumn<int> albumCount = GeneratedColumn<int>(
    'album_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _coverArtMeta = const VerificationMeta(
    'coverArt',
  );
  @override
  late final GeneratedColumn<String> coverArt = GeneratedColumn<String>(
    'cover_art',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _starredMeta = const VerificationMeta(
    'starred',
  );
  @override
  late final GeneratedColumn<DateTime> starred = GeneratedColumn<DateTime>(
    'starred',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    albumCount,
    coverArt,
    starred,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'artists';
  @override
  VerificationContext validateIntegrity(
    Insertable<ArtistsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('album_count')) {
      context.handle(
        _albumCountMeta,
        albumCount.isAcceptableOrUnknown(data['album_count']!, _albumCountMeta),
      );
    }
    if (data.containsKey('cover_art')) {
      context.handle(
        _coverArtMeta,
        coverArt.isAcceptableOrUnknown(data['cover_art']!, _coverArtMeta),
      );
    }
    if (data.containsKey('starred')) {
      context.handle(
        _starredMeta,
        starred.isAcceptableOrUnknown(data['starred']!, _starredMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ArtistsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ArtistsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      albumCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}album_count'],
      ),
      coverArt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_art'],
      ),
      starred: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}starred'],
      ),
    );
  }

  @override
  $ArtistsTableTable createAlias(String alias) {
    return $ArtistsTableTable(attachedDatabase, alias);
  }
}

class ArtistsTableData extends DataClass
    implements Insertable<ArtistsTableData> {
  final String id;
  final String name;
  final int? albumCount;
  final String? coverArt;
  final DateTime? starred;
  const ArtistsTableData({
    required this.id,
    required this.name,
    this.albumCount,
    this.coverArt,
    this.starred,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || albumCount != null) {
      map['album_count'] = Variable<int>(albumCount);
    }
    if (!nullToAbsent || coverArt != null) {
      map['cover_art'] = Variable<String>(coverArt);
    }
    if (!nullToAbsent || starred != null) {
      map['starred'] = Variable<DateTime>(starred);
    }
    return map;
  }

  ArtistsTableCompanion toCompanion(bool nullToAbsent) {
    return ArtistsTableCompanion(
      id: Value(id),
      name: Value(name),
      albumCount: albumCount == null && nullToAbsent
          ? const Value.absent()
          : Value(albumCount),
      coverArt: coverArt == null && nullToAbsent
          ? const Value.absent()
          : Value(coverArt),
      starred: starred == null && nullToAbsent
          ? const Value.absent()
          : Value(starred),
    );
  }

  factory ArtistsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ArtistsTableData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      albumCount: serializer.fromJson<int?>(json['albumCount']),
      coverArt: serializer.fromJson<String?>(json['coverArt']),
      starred: serializer.fromJson<DateTime?>(json['starred']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'albumCount': serializer.toJson<int?>(albumCount),
      'coverArt': serializer.toJson<String?>(coverArt),
      'starred': serializer.toJson<DateTime?>(starred),
    };
  }

  ArtistsTableData copyWith({
    String? id,
    String? name,
    Value<int?> albumCount = const Value.absent(),
    Value<String?> coverArt = const Value.absent(),
    Value<DateTime?> starred = const Value.absent(),
  }) => ArtistsTableData(
    id: id ?? this.id,
    name: name ?? this.name,
    albumCount: albumCount.present ? albumCount.value : this.albumCount,
    coverArt: coverArt.present ? coverArt.value : this.coverArt,
    starred: starred.present ? starred.value : this.starred,
  );
  ArtistsTableData copyWithCompanion(ArtistsTableCompanion data) {
    return ArtistsTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      albumCount: data.albumCount.present
          ? data.albumCount.value
          : this.albumCount,
      coverArt: data.coverArt.present ? data.coverArt.value : this.coverArt,
      starred: data.starred.present ? data.starred.value : this.starred,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ArtistsTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('albumCount: $albumCount, ')
          ..write('coverArt: $coverArt, ')
          ..write('starred: $starred')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, albumCount, coverArt, starred);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ArtistsTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.albumCount == this.albumCount &&
          other.coverArt == this.coverArt &&
          other.starred == this.starred);
}

class ArtistsTableCompanion extends UpdateCompanion<ArtistsTableData> {
  final Value<String> id;
  final Value<String> name;
  final Value<int?> albumCount;
  final Value<String?> coverArt;
  final Value<DateTime?> starred;
  final Value<int> rowid;
  const ArtistsTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.albumCount = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.starred = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ArtistsTableCompanion.insert({
    required String id,
    required String name,
    this.albumCount = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.starred = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<ArtistsTableData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? albumCount,
    Expression<String>? coverArt,
    Expression<DateTime>? starred,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (albumCount != null) 'album_count': albumCount,
      if (coverArt != null) 'cover_art': coverArt,
      if (starred != null) 'starred': starred,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ArtistsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int?>? albumCount,
    Value<String?>? coverArt,
    Value<DateTime?>? starred,
    Value<int>? rowid,
  }) {
    return ArtistsTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      albumCount: albumCount ?? this.albumCount,
      coverArt: coverArt ?? this.coverArt,
      starred: starred ?? this.starred,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (albumCount.present) {
      map['album_count'] = Variable<int>(albumCount.value);
    }
    if (coverArt.present) {
      map['cover_art'] = Variable<String>(coverArt.value);
    }
    if (starred.present) {
      map['starred'] = Variable<DateTime>(starred.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ArtistsTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('albumCount: $albumCount, ')
          ..write('coverArt: $coverArt, ')
          ..write('starred: $starred, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AlbumsTableTable extends AlbumsTable
    with TableInfo<$AlbumsTableTable, AlbumsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AlbumsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _artistIdMeta = const VerificationMeta(
    'artistId',
  );
  @override
  late final GeneratedColumn<String> artistId = GeneratedColumn<String>(
    'artist_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES artists (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _artistNameMeta = const VerificationMeta(
    'artistName',
  );
  @override
  late final GeneratedColumn<String> artistName = GeneratedColumn<String>(
    'artist_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _songCountMeta = const VerificationMeta(
    'songCount',
  );
  @override
  late final GeneratedColumn<int> songCount = GeneratedColumn<int>(
    'song_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMeta = const VerificationMeta(
    'duration',
  );
  @override
  late final GeneratedColumn<int> duration = GeneratedColumn<int>(
    'duration',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _genreMeta = const VerificationMeta('genre');
  @override
  late final GeneratedColumn<String> genre = GeneratedColumn<String>(
    'genre',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _coverArtMeta = const VerificationMeta(
    'coverArt',
  );
  @override
  late final GeneratedColumn<String> coverArt = GeneratedColumn<String>(
    'cover_art',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _songsHydratedMeta = const VerificationMeta(
    'songsHydrated',
  );
  @override
  late final GeneratedColumn<bool> songsHydrated = GeneratedColumn<bool>(
    'songs_hydrated',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("songs_hydrated" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _starredMeta = const VerificationMeta(
    'starred',
  );
  @override
  late final GeneratedColumn<DateTime> starred = GeneratedColumn<DateTime>(
    'starred',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _playCountMeta = const VerificationMeta(
    'playCount',
  );
  @override
  late final GeneratedColumn<int> playCount = GeneratedColumn<int>(
    'play_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    artistId,
    artistName,
    songCount,
    duration,
    year,
    genre,
    coverArt,
    songsHydrated,
    starred,
    playCount,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'albums';
  @override
  VerificationContext validateIntegrity(
    Insertable<AlbumsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('artist_id')) {
      context.handle(
        _artistIdMeta,
        artistId.isAcceptableOrUnknown(data['artist_id']!, _artistIdMeta),
      );
    }
    if (data.containsKey('artist_name')) {
      context.handle(
        _artistNameMeta,
        artistName.isAcceptableOrUnknown(data['artist_name']!, _artistNameMeta),
      );
    }
    if (data.containsKey('song_count')) {
      context.handle(
        _songCountMeta,
        songCount.isAcceptableOrUnknown(data['song_count']!, _songCountMeta),
      );
    }
    if (data.containsKey('duration')) {
      context.handle(
        _durationMeta,
        duration.isAcceptableOrUnknown(data['duration']!, _durationMeta),
      );
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    }
    if (data.containsKey('genre')) {
      context.handle(
        _genreMeta,
        genre.isAcceptableOrUnknown(data['genre']!, _genreMeta),
      );
    }
    if (data.containsKey('cover_art')) {
      context.handle(
        _coverArtMeta,
        coverArt.isAcceptableOrUnknown(data['cover_art']!, _coverArtMeta),
      );
    }
    if (data.containsKey('songs_hydrated')) {
      context.handle(
        _songsHydratedMeta,
        songsHydrated.isAcceptableOrUnknown(
          data['songs_hydrated']!,
          _songsHydratedMeta,
        ),
      );
    }
    if (data.containsKey('starred')) {
      context.handle(
        _starredMeta,
        starred.isAcceptableOrUnknown(data['starred']!, _starredMeta),
      );
    }
    if (data.containsKey('play_count')) {
      context.handle(
        _playCountMeta,
        playCount.isAcceptableOrUnknown(data['play_count']!, _playCountMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AlbumsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AlbumsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      artistId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artist_id'],
      ),
      artistName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artist_name'],
      ),
      songCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}song_count'],
      ),
      duration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration'],
      ),
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      ),
      genre: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}genre'],
      ),
      coverArt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_art'],
      ),
      songsHydrated: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}songs_hydrated'],
      )!,
      starred: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}starred'],
      ),
      playCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}play_count'],
      ),
    );
  }

  @override
  $AlbumsTableTable createAlias(String alias) {
    return $AlbumsTableTable(attachedDatabase, alias);
  }
}

class AlbumsTableData extends DataClass implements Insertable<AlbumsTableData> {
  final String id;
  final String name;
  final String? artistId;
  final String? artistName;
  final int? songCount;
  final int? duration;
  final int? year;
  final String? genre;
  final String? coverArt;
  final bool songsHydrated;
  final DateTime? starred;
  final int? playCount;
  const AlbumsTableData({
    required this.id,
    required this.name,
    this.artistId,
    this.artistName,
    this.songCount,
    this.duration,
    this.year,
    this.genre,
    this.coverArt,
    required this.songsHydrated,
    this.starred,
    this.playCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || artistId != null) {
      map['artist_id'] = Variable<String>(artistId);
    }
    if (!nullToAbsent || artistName != null) {
      map['artist_name'] = Variable<String>(artistName);
    }
    if (!nullToAbsent || songCount != null) {
      map['song_count'] = Variable<int>(songCount);
    }
    if (!nullToAbsent || duration != null) {
      map['duration'] = Variable<int>(duration);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || genre != null) {
      map['genre'] = Variable<String>(genre);
    }
    if (!nullToAbsent || coverArt != null) {
      map['cover_art'] = Variable<String>(coverArt);
    }
    map['songs_hydrated'] = Variable<bool>(songsHydrated);
    if (!nullToAbsent || starred != null) {
      map['starred'] = Variable<DateTime>(starred);
    }
    if (!nullToAbsent || playCount != null) {
      map['play_count'] = Variable<int>(playCount);
    }
    return map;
  }

  AlbumsTableCompanion toCompanion(bool nullToAbsent) {
    return AlbumsTableCompanion(
      id: Value(id),
      name: Value(name),
      artistId: artistId == null && nullToAbsent
          ? const Value.absent()
          : Value(artistId),
      artistName: artistName == null && nullToAbsent
          ? const Value.absent()
          : Value(artistName),
      songCount: songCount == null && nullToAbsent
          ? const Value.absent()
          : Value(songCount),
      duration: duration == null && nullToAbsent
          ? const Value.absent()
          : Value(duration),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      genre: genre == null && nullToAbsent
          ? const Value.absent()
          : Value(genre),
      coverArt: coverArt == null && nullToAbsent
          ? const Value.absent()
          : Value(coverArt),
      songsHydrated: Value(songsHydrated),
      starred: starred == null && nullToAbsent
          ? const Value.absent()
          : Value(starred),
      playCount: playCount == null && nullToAbsent
          ? const Value.absent()
          : Value(playCount),
    );
  }

  factory AlbumsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AlbumsTableData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      artistId: serializer.fromJson<String?>(json['artistId']),
      artistName: serializer.fromJson<String?>(json['artistName']),
      songCount: serializer.fromJson<int?>(json['songCount']),
      duration: serializer.fromJson<int?>(json['duration']),
      year: serializer.fromJson<int?>(json['year']),
      genre: serializer.fromJson<String?>(json['genre']),
      coverArt: serializer.fromJson<String?>(json['coverArt']),
      songsHydrated: serializer.fromJson<bool>(json['songsHydrated']),
      starred: serializer.fromJson<DateTime?>(json['starred']),
      playCount: serializer.fromJson<int?>(json['playCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'artistId': serializer.toJson<String?>(artistId),
      'artistName': serializer.toJson<String?>(artistName),
      'songCount': serializer.toJson<int?>(songCount),
      'duration': serializer.toJson<int?>(duration),
      'year': serializer.toJson<int?>(year),
      'genre': serializer.toJson<String?>(genre),
      'coverArt': serializer.toJson<String?>(coverArt),
      'songsHydrated': serializer.toJson<bool>(songsHydrated),
      'starred': serializer.toJson<DateTime?>(starred),
      'playCount': serializer.toJson<int?>(playCount),
    };
  }

  AlbumsTableData copyWith({
    String? id,
    String? name,
    Value<String?> artistId = const Value.absent(),
    Value<String?> artistName = const Value.absent(),
    Value<int?> songCount = const Value.absent(),
    Value<int?> duration = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<String?> genre = const Value.absent(),
    Value<String?> coverArt = const Value.absent(),
    bool? songsHydrated,
    Value<DateTime?> starred = const Value.absent(),
    Value<int?> playCount = const Value.absent(),
  }) => AlbumsTableData(
    id: id ?? this.id,
    name: name ?? this.name,
    artistId: artistId.present ? artistId.value : this.artistId,
    artistName: artistName.present ? artistName.value : this.artistName,
    songCount: songCount.present ? songCount.value : this.songCount,
    duration: duration.present ? duration.value : this.duration,
    year: year.present ? year.value : this.year,
    genre: genre.present ? genre.value : this.genre,
    coverArt: coverArt.present ? coverArt.value : this.coverArt,
    songsHydrated: songsHydrated ?? this.songsHydrated,
    starred: starred.present ? starred.value : this.starred,
    playCount: playCount.present ? playCount.value : this.playCount,
  );
  AlbumsTableData copyWithCompanion(AlbumsTableCompanion data) {
    return AlbumsTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      artistId: data.artistId.present ? data.artistId.value : this.artistId,
      artistName: data.artistName.present
          ? data.artistName.value
          : this.artistName,
      songCount: data.songCount.present ? data.songCount.value : this.songCount,
      duration: data.duration.present ? data.duration.value : this.duration,
      year: data.year.present ? data.year.value : this.year,
      genre: data.genre.present ? data.genre.value : this.genre,
      coverArt: data.coverArt.present ? data.coverArt.value : this.coverArt,
      songsHydrated: data.songsHydrated.present
          ? data.songsHydrated.value
          : this.songsHydrated,
      starred: data.starred.present ? data.starred.value : this.starred,
      playCount: data.playCount.present ? data.playCount.value : this.playCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AlbumsTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('artistId: $artistId, ')
          ..write('artistName: $artistName, ')
          ..write('songCount: $songCount, ')
          ..write('duration: $duration, ')
          ..write('year: $year, ')
          ..write('genre: $genre, ')
          ..write('coverArt: $coverArt, ')
          ..write('songsHydrated: $songsHydrated, ')
          ..write('starred: $starred, ')
          ..write('playCount: $playCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    artistId,
    artistName,
    songCount,
    duration,
    year,
    genre,
    coverArt,
    songsHydrated,
    starred,
    playCount,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AlbumsTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.artistId == this.artistId &&
          other.artistName == this.artistName &&
          other.songCount == this.songCount &&
          other.duration == this.duration &&
          other.year == this.year &&
          other.genre == this.genre &&
          other.coverArt == this.coverArt &&
          other.songsHydrated == this.songsHydrated &&
          other.starred == this.starred &&
          other.playCount == this.playCount);
}

class AlbumsTableCompanion extends UpdateCompanion<AlbumsTableData> {
  final Value<String> id;
  final Value<String> name;
  final Value<String?> artistId;
  final Value<String?> artistName;
  final Value<int?> songCount;
  final Value<int?> duration;
  final Value<int?> year;
  final Value<String?> genre;
  final Value<String?> coverArt;
  final Value<bool> songsHydrated;
  final Value<DateTime?> starred;
  final Value<int?> playCount;
  final Value<int> rowid;
  const AlbumsTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.artistId = const Value.absent(),
    this.artistName = const Value.absent(),
    this.songCount = const Value.absent(),
    this.duration = const Value.absent(),
    this.year = const Value.absent(),
    this.genre = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.songsHydrated = const Value.absent(),
    this.starred = const Value.absent(),
    this.playCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AlbumsTableCompanion.insert({
    required String id,
    required String name,
    this.artistId = const Value.absent(),
    this.artistName = const Value.absent(),
    this.songCount = const Value.absent(),
    this.duration = const Value.absent(),
    this.year = const Value.absent(),
    this.genre = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.songsHydrated = const Value.absent(),
    this.starred = const Value.absent(),
    this.playCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<AlbumsTableData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? artistId,
    Expression<String>? artistName,
    Expression<int>? songCount,
    Expression<int>? duration,
    Expression<int>? year,
    Expression<String>? genre,
    Expression<String>? coverArt,
    Expression<bool>? songsHydrated,
    Expression<DateTime>? starred,
    Expression<int>? playCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (artistId != null) 'artist_id': artistId,
      if (artistName != null) 'artist_name': artistName,
      if (songCount != null) 'song_count': songCount,
      if (duration != null) 'duration': duration,
      if (year != null) 'year': year,
      if (genre != null) 'genre': genre,
      if (coverArt != null) 'cover_art': coverArt,
      if (songsHydrated != null) 'songs_hydrated': songsHydrated,
      if (starred != null) 'starred': starred,
      if (playCount != null) 'play_count': playCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AlbumsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String?>? artistId,
    Value<String?>? artistName,
    Value<int?>? songCount,
    Value<int?>? duration,
    Value<int?>? year,
    Value<String?>? genre,
    Value<String?>? coverArt,
    Value<bool>? songsHydrated,
    Value<DateTime?>? starred,
    Value<int?>? playCount,
    Value<int>? rowid,
  }) {
    return AlbumsTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      artistId: artistId ?? this.artistId,
      artistName: artistName ?? this.artistName,
      songCount: songCount ?? this.songCount,
      duration: duration ?? this.duration,
      year: year ?? this.year,
      genre: genre ?? this.genre,
      coverArt: coverArt ?? this.coverArt,
      songsHydrated: songsHydrated ?? this.songsHydrated,
      starred: starred ?? this.starred,
      playCount: playCount ?? this.playCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (artistId.present) {
      map['artist_id'] = Variable<String>(artistId.value);
    }
    if (artistName.present) {
      map['artist_name'] = Variable<String>(artistName.value);
    }
    if (songCount.present) {
      map['song_count'] = Variable<int>(songCount.value);
    }
    if (duration.present) {
      map['duration'] = Variable<int>(duration.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (genre.present) {
      map['genre'] = Variable<String>(genre.value);
    }
    if (coverArt.present) {
      map['cover_art'] = Variable<String>(coverArt.value);
    }
    if (songsHydrated.present) {
      map['songs_hydrated'] = Variable<bool>(songsHydrated.value);
    }
    if (starred.present) {
      map['starred'] = Variable<DateTime>(starred.value);
    }
    if (playCount.present) {
      map['play_count'] = Variable<int>(playCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AlbumsTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('artistId: $artistId, ')
          ..write('artistName: $artistName, ')
          ..write('songCount: $songCount, ')
          ..write('duration: $duration, ')
          ..write('year: $year, ')
          ..write('genre: $genre, ')
          ..write('coverArt: $coverArt, ')
          ..write('songsHydrated: $songsHydrated, ')
          ..write('starred: $starred, ')
          ..write('playCount: $playCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SongsTableTable extends SongsTable
    with TableInfo<$SongsTableTable, SongsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SongsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _albumIdMeta = const VerificationMeta(
    'albumId',
  );
  @override
  late final GeneratedColumn<String> albumId = GeneratedColumn<String>(
    'album_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES albums (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _artistIdMeta = const VerificationMeta(
    'artistId',
  );
  @override
  late final GeneratedColumn<String> artistId = GeneratedColumn<String>(
    'artist_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES artists (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _artistNameMeta = const VerificationMeta(
    'artistName',
  );
  @override
  late final GeneratedColumn<String> artistName = GeneratedColumn<String>(
    'artist_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _albumNameMeta = const VerificationMeta(
    'albumName',
  );
  @override
  late final GeneratedColumn<String> albumName = GeneratedColumn<String>(
    'album_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _trackMeta = const VerificationMeta('track');
  @override
  late final GeneratedColumn<int> track = GeneratedColumn<int>(
    'track',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _discNumberMeta = const VerificationMeta(
    'discNumber',
  );
  @override
  late final GeneratedColumn<int> discNumber = GeneratedColumn<int>(
    'disc_number',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMeta = const VerificationMeta(
    'duration',
  );
  @override
  late final GeneratedColumn<int> duration = GeneratedColumn<int>(
    'duration',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bitRateMeta = const VerificationMeta(
    'bitRate',
  );
  @override
  late final GeneratedColumn<int> bitRate = GeneratedColumn<int>(
    'bit_rate',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentTypeMeta = const VerificationMeta(
    'contentType',
  );
  @override
  late final GeneratedColumn<String> contentType = GeneratedColumn<String>(
    'content_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _suffixMeta = const VerificationMeta('suffix');
  @override
  late final GeneratedColumn<String> suffix = GeneratedColumn<String>(
    'suffix',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _coverArtMeta = const VerificationMeta(
    'coverArt',
  );
  @override
  late final GeneratedColumn<String> coverArt = GeneratedColumn<String>(
    'cover_art',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _starredMeta = const VerificationMeta(
    'starred',
  );
  @override
  late final GeneratedColumn<DateTime> starred = GeneratedColumn<DateTime>(
    'starred',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _playCountMeta = const VerificationMeta(
    'playCount',
  );
  @override
  late final GeneratedColumn<int> playCount = GeneratedColumn<int>(
    'play_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    albumId,
    artistId,
    artistName,
    albumName,
    track,
    discNumber,
    duration,
    bitRate,
    contentType,
    suffix,
    size,
    coverArt,
    starred,
    playCount,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'songs';
  @override
  VerificationContext validateIntegrity(
    Insertable<SongsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('album_id')) {
      context.handle(
        _albumIdMeta,
        albumId.isAcceptableOrUnknown(data['album_id']!, _albumIdMeta),
      );
    }
    if (data.containsKey('artist_id')) {
      context.handle(
        _artistIdMeta,
        artistId.isAcceptableOrUnknown(data['artist_id']!, _artistIdMeta),
      );
    }
    if (data.containsKey('artist_name')) {
      context.handle(
        _artistNameMeta,
        artistName.isAcceptableOrUnknown(data['artist_name']!, _artistNameMeta),
      );
    }
    if (data.containsKey('album_name')) {
      context.handle(
        _albumNameMeta,
        albumName.isAcceptableOrUnknown(data['album_name']!, _albumNameMeta),
      );
    }
    if (data.containsKey('track')) {
      context.handle(
        _trackMeta,
        track.isAcceptableOrUnknown(data['track']!, _trackMeta),
      );
    }
    if (data.containsKey('disc_number')) {
      context.handle(
        _discNumberMeta,
        discNumber.isAcceptableOrUnknown(data['disc_number']!, _discNumberMeta),
      );
    }
    if (data.containsKey('duration')) {
      context.handle(
        _durationMeta,
        duration.isAcceptableOrUnknown(data['duration']!, _durationMeta),
      );
    }
    if (data.containsKey('bit_rate')) {
      context.handle(
        _bitRateMeta,
        bitRate.isAcceptableOrUnknown(data['bit_rate']!, _bitRateMeta),
      );
    }
    if (data.containsKey('content_type')) {
      context.handle(
        _contentTypeMeta,
        contentType.isAcceptableOrUnknown(
          data['content_type']!,
          _contentTypeMeta,
        ),
      );
    }
    if (data.containsKey('suffix')) {
      context.handle(
        _suffixMeta,
        suffix.isAcceptableOrUnknown(data['suffix']!, _suffixMeta),
      );
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    }
    if (data.containsKey('cover_art')) {
      context.handle(
        _coverArtMeta,
        coverArt.isAcceptableOrUnknown(data['cover_art']!, _coverArtMeta),
      );
    }
    if (data.containsKey('starred')) {
      context.handle(
        _starredMeta,
        starred.isAcceptableOrUnknown(data['starred']!, _starredMeta),
      );
    }
    if (data.containsKey('play_count')) {
      context.handle(
        _playCountMeta,
        playCount.isAcceptableOrUnknown(data['play_count']!, _playCountMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SongsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SongsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      albumId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}album_id'],
      ),
      artistId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artist_id'],
      ),
      artistName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artist_name'],
      ),
      albumName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}album_name'],
      ),
      track: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}track'],
      ),
      discNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}disc_number'],
      ),
      duration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration'],
      ),
      bitRate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bit_rate'],
      ),
      contentType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_type'],
      ),
      suffix: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}suffix'],
      ),
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      ),
      coverArt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_art'],
      ),
      starred: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}starred'],
      ),
      playCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}play_count'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      ),
    );
  }

  @override
  $SongsTableTable createAlias(String alias) {
    return $SongsTableTable(attachedDatabase, alias);
  }
}

class SongsTableData extends DataClass implements Insertable<SongsTableData> {
  final String id;
  final String title;
  final String? albumId;
  final String? artistId;
  final String? artistName;
  final String? albumName;
  final int? track;
  final int? discNumber;
  final int? duration;
  final int? bitRate;
  final String? contentType;
  final String? suffix;
  final int? size;
  final String? coverArt;
  final DateTime? starred;
  final int? playCount;
  final DateTime? createdAt;
  const SongsTableData({
    required this.id,
    required this.title,
    this.albumId,
    this.artistId,
    this.artistName,
    this.albumName,
    this.track,
    this.discNumber,
    this.duration,
    this.bitRate,
    this.contentType,
    this.suffix,
    this.size,
    this.coverArt,
    this.starred,
    this.playCount,
    this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || albumId != null) {
      map['album_id'] = Variable<String>(albumId);
    }
    if (!nullToAbsent || artistId != null) {
      map['artist_id'] = Variable<String>(artistId);
    }
    if (!nullToAbsent || artistName != null) {
      map['artist_name'] = Variable<String>(artistName);
    }
    if (!nullToAbsent || albumName != null) {
      map['album_name'] = Variable<String>(albumName);
    }
    if (!nullToAbsent || track != null) {
      map['track'] = Variable<int>(track);
    }
    if (!nullToAbsent || discNumber != null) {
      map['disc_number'] = Variable<int>(discNumber);
    }
    if (!nullToAbsent || duration != null) {
      map['duration'] = Variable<int>(duration);
    }
    if (!nullToAbsent || bitRate != null) {
      map['bit_rate'] = Variable<int>(bitRate);
    }
    if (!nullToAbsent || contentType != null) {
      map['content_type'] = Variable<String>(contentType);
    }
    if (!nullToAbsent || suffix != null) {
      map['suffix'] = Variable<String>(suffix);
    }
    if (!nullToAbsent || size != null) {
      map['size'] = Variable<int>(size);
    }
    if (!nullToAbsent || coverArt != null) {
      map['cover_art'] = Variable<String>(coverArt);
    }
    if (!nullToAbsent || starred != null) {
      map['starred'] = Variable<DateTime>(starred);
    }
    if (!nullToAbsent || playCount != null) {
      map['play_count'] = Variable<int>(playCount);
    }
    if (!nullToAbsent || createdAt != null) {
      map['created_at'] = Variable<DateTime>(createdAt);
    }
    return map;
  }

  SongsTableCompanion toCompanion(bool nullToAbsent) {
    return SongsTableCompanion(
      id: Value(id),
      title: Value(title),
      albumId: albumId == null && nullToAbsent
          ? const Value.absent()
          : Value(albumId),
      artistId: artistId == null && nullToAbsent
          ? const Value.absent()
          : Value(artistId),
      artistName: artistName == null && nullToAbsent
          ? const Value.absent()
          : Value(artistName),
      albumName: albumName == null && nullToAbsent
          ? const Value.absent()
          : Value(albumName),
      track: track == null && nullToAbsent
          ? const Value.absent()
          : Value(track),
      discNumber: discNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(discNumber),
      duration: duration == null && nullToAbsent
          ? const Value.absent()
          : Value(duration),
      bitRate: bitRate == null && nullToAbsent
          ? const Value.absent()
          : Value(bitRate),
      contentType: contentType == null && nullToAbsent
          ? const Value.absent()
          : Value(contentType),
      suffix: suffix == null && nullToAbsent
          ? const Value.absent()
          : Value(suffix),
      size: size == null && nullToAbsent ? const Value.absent() : Value(size),
      coverArt: coverArt == null && nullToAbsent
          ? const Value.absent()
          : Value(coverArt),
      starred: starred == null && nullToAbsent
          ? const Value.absent()
          : Value(starred),
      playCount: playCount == null && nullToAbsent
          ? const Value.absent()
          : Value(playCount),
      createdAt: createdAt == null && nullToAbsent
          ? const Value.absent()
          : Value(createdAt),
    );
  }

  factory SongsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SongsTableData(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      albumId: serializer.fromJson<String?>(json['albumId']),
      artistId: serializer.fromJson<String?>(json['artistId']),
      artistName: serializer.fromJson<String?>(json['artistName']),
      albumName: serializer.fromJson<String?>(json['albumName']),
      track: serializer.fromJson<int?>(json['track']),
      discNumber: serializer.fromJson<int?>(json['discNumber']),
      duration: serializer.fromJson<int?>(json['duration']),
      bitRate: serializer.fromJson<int?>(json['bitRate']),
      contentType: serializer.fromJson<String?>(json['contentType']),
      suffix: serializer.fromJson<String?>(json['suffix']),
      size: serializer.fromJson<int?>(json['size']),
      coverArt: serializer.fromJson<String?>(json['coverArt']),
      starred: serializer.fromJson<DateTime?>(json['starred']),
      playCount: serializer.fromJson<int?>(json['playCount']),
      createdAt: serializer.fromJson<DateTime?>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'albumId': serializer.toJson<String?>(albumId),
      'artistId': serializer.toJson<String?>(artistId),
      'artistName': serializer.toJson<String?>(artistName),
      'albumName': serializer.toJson<String?>(albumName),
      'track': serializer.toJson<int?>(track),
      'discNumber': serializer.toJson<int?>(discNumber),
      'duration': serializer.toJson<int?>(duration),
      'bitRate': serializer.toJson<int?>(bitRate),
      'contentType': serializer.toJson<String?>(contentType),
      'suffix': serializer.toJson<String?>(suffix),
      'size': serializer.toJson<int?>(size),
      'coverArt': serializer.toJson<String?>(coverArt),
      'starred': serializer.toJson<DateTime?>(starred),
      'playCount': serializer.toJson<int?>(playCount),
      'createdAt': serializer.toJson<DateTime?>(createdAt),
    };
  }

  SongsTableData copyWith({
    String? id,
    String? title,
    Value<String?> albumId = const Value.absent(),
    Value<String?> artistId = const Value.absent(),
    Value<String?> artistName = const Value.absent(),
    Value<String?> albumName = const Value.absent(),
    Value<int?> track = const Value.absent(),
    Value<int?> discNumber = const Value.absent(),
    Value<int?> duration = const Value.absent(),
    Value<int?> bitRate = const Value.absent(),
    Value<String?> contentType = const Value.absent(),
    Value<String?> suffix = const Value.absent(),
    Value<int?> size = const Value.absent(),
    Value<String?> coverArt = const Value.absent(),
    Value<DateTime?> starred = const Value.absent(),
    Value<int?> playCount = const Value.absent(),
    Value<DateTime?> createdAt = const Value.absent(),
  }) => SongsTableData(
    id: id ?? this.id,
    title: title ?? this.title,
    albumId: albumId.present ? albumId.value : this.albumId,
    artistId: artistId.present ? artistId.value : this.artistId,
    artistName: artistName.present ? artistName.value : this.artistName,
    albumName: albumName.present ? albumName.value : this.albumName,
    track: track.present ? track.value : this.track,
    discNumber: discNumber.present ? discNumber.value : this.discNumber,
    duration: duration.present ? duration.value : this.duration,
    bitRate: bitRate.present ? bitRate.value : this.bitRate,
    contentType: contentType.present ? contentType.value : this.contentType,
    suffix: suffix.present ? suffix.value : this.suffix,
    size: size.present ? size.value : this.size,
    coverArt: coverArt.present ? coverArt.value : this.coverArt,
    starred: starred.present ? starred.value : this.starred,
    playCount: playCount.present ? playCount.value : this.playCount,
    createdAt: createdAt.present ? createdAt.value : this.createdAt,
  );
  SongsTableData copyWithCompanion(SongsTableCompanion data) {
    return SongsTableData(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      albumId: data.albumId.present ? data.albumId.value : this.albumId,
      artistId: data.artistId.present ? data.artistId.value : this.artistId,
      artistName: data.artistName.present
          ? data.artistName.value
          : this.artistName,
      albumName: data.albumName.present ? data.albumName.value : this.albumName,
      track: data.track.present ? data.track.value : this.track,
      discNumber: data.discNumber.present
          ? data.discNumber.value
          : this.discNumber,
      duration: data.duration.present ? data.duration.value : this.duration,
      bitRate: data.bitRate.present ? data.bitRate.value : this.bitRate,
      contentType: data.contentType.present
          ? data.contentType.value
          : this.contentType,
      suffix: data.suffix.present ? data.suffix.value : this.suffix,
      size: data.size.present ? data.size.value : this.size,
      coverArt: data.coverArt.present ? data.coverArt.value : this.coverArt,
      starred: data.starred.present ? data.starred.value : this.starred,
      playCount: data.playCount.present ? data.playCount.value : this.playCount,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SongsTableData(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('albumId: $albumId, ')
          ..write('artistId: $artistId, ')
          ..write('artistName: $artistName, ')
          ..write('albumName: $albumName, ')
          ..write('track: $track, ')
          ..write('discNumber: $discNumber, ')
          ..write('duration: $duration, ')
          ..write('bitRate: $bitRate, ')
          ..write('contentType: $contentType, ')
          ..write('suffix: $suffix, ')
          ..write('size: $size, ')
          ..write('coverArt: $coverArt, ')
          ..write('starred: $starred, ')
          ..write('playCount: $playCount, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    albumId,
    artistId,
    artistName,
    albumName,
    track,
    discNumber,
    duration,
    bitRate,
    contentType,
    suffix,
    size,
    coverArt,
    starred,
    playCount,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SongsTableData &&
          other.id == this.id &&
          other.title == this.title &&
          other.albumId == this.albumId &&
          other.artistId == this.artistId &&
          other.artistName == this.artistName &&
          other.albumName == this.albumName &&
          other.track == this.track &&
          other.discNumber == this.discNumber &&
          other.duration == this.duration &&
          other.bitRate == this.bitRate &&
          other.contentType == this.contentType &&
          other.suffix == this.suffix &&
          other.size == this.size &&
          other.coverArt == this.coverArt &&
          other.starred == this.starred &&
          other.playCount == this.playCount &&
          other.createdAt == this.createdAt);
}

class SongsTableCompanion extends UpdateCompanion<SongsTableData> {
  final Value<String> id;
  final Value<String> title;
  final Value<String?> albumId;
  final Value<String?> artistId;
  final Value<String?> artistName;
  final Value<String?> albumName;
  final Value<int?> track;
  final Value<int?> discNumber;
  final Value<int?> duration;
  final Value<int?> bitRate;
  final Value<String?> contentType;
  final Value<String?> suffix;
  final Value<int?> size;
  final Value<String?> coverArt;
  final Value<DateTime?> starred;
  final Value<int?> playCount;
  final Value<DateTime?> createdAt;
  final Value<int> rowid;
  const SongsTableCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.albumId = const Value.absent(),
    this.artistId = const Value.absent(),
    this.artistName = const Value.absent(),
    this.albumName = const Value.absent(),
    this.track = const Value.absent(),
    this.discNumber = const Value.absent(),
    this.duration = const Value.absent(),
    this.bitRate = const Value.absent(),
    this.contentType = const Value.absent(),
    this.suffix = const Value.absent(),
    this.size = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.starred = const Value.absent(),
    this.playCount = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SongsTableCompanion.insert({
    required String id,
    required String title,
    this.albumId = const Value.absent(),
    this.artistId = const Value.absent(),
    this.artistName = const Value.absent(),
    this.albumName = const Value.absent(),
    this.track = const Value.absent(),
    this.discNumber = const Value.absent(),
    this.duration = const Value.absent(),
    this.bitRate = const Value.absent(),
    this.contentType = const Value.absent(),
    this.suffix = const Value.absent(),
    this.size = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.starred = const Value.absent(),
    this.playCount = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title);
  static Insertable<SongsTableData> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? albumId,
    Expression<String>? artistId,
    Expression<String>? artistName,
    Expression<String>? albumName,
    Expression<int>? track,
    Expression<int>? discNumber,
    Expression<int>? duration,
    Expression<int>? bitRate,
    Expression<String>? contentType,
    Expression<String>? suffix,
    Expression<int>? size,
    Expression<String>? coverArt,
    Expression<DateTime>? starred,
    Expression<int>? playCount,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (albumId != null) 'album_id': albumId,
      if (artistId != null) 'artist_id': artistId,
      if (artistName != null) 'artist_name': artistName,
      if (albumName != null) 'album_name': albumName,
      if (track != null) 'track': track,
      if (discNumber != null) 'disc_number': discNumber,
      if (duration != null) 'duration': duration,
      if (bitRate != null) 'bit_rate': bitRate,
      if (contentType != null) 'content_type': contentType,
      if (suffix != null) 'suffix': suffix,
      if (size != null) 'size': size,
      if (coverArt != null) 'cover_art': coverArt,
      if (starred != null) 'starred': starred,
      if (playCount != null) 'play_count': playCount,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SongsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String?>? albumId,
    Value<String?>? artistId,
    Value<String?>? artistName,
    Value<String?>? albumName,
    Value<int?>? track,
    Value<int?>? discNumber,
    Value<int?>? duration,
    Value<int?>? bitRate,
    Value<String?>? contentType,
    Value<String?>? suffix,
    Value<int?>? size,
    Value<String?>? coverArt,
    Value<DateTime?>? starred,
    Value<int?>? playCount,
    Value<DateTime?>? createdAt,
    Value<int>? rowid,
  }) {
    return SongsTableCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      albumId: albumId ?? this.albumId,
      artistId: artistId ?? this.artistId,
      artistName: artistName ?? this.artistName,
      albumName: albumName ?? this.albumName,
      track: track ?? this.track,
      discNumber: discNumber ?? this.discNumber,
      duration: duration ?? this.duration,
      bitRate: bitRate ?? this.bitRate,
      contentType: contentType ?? this.contentType,
      suffix: suffix ?? this.suffix,
      size: size ?? this.size,
      coverArt: coverArt ?? this.coverArt,
      starred: starred ?? this.starred,
      playCount: playCount ?? this.playCount,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (albumId.present) {
      map['album_id'] = Variable<String>(albumId.value);
    }
    if (artistId.present) {
      map['artist_id'] = Variable<String>(artistId.value);
    }
    if (artistName.present) {
      map['artist_name'] = Variable<String>(artistName.value);
    }
    if (albumName.present) {
      map['album_name'] = Variable<String>(albumName.value);
    }
    if (track.present) {
      map['track'] = Variable<int>(track.value);
    }
    if (discNumber.present) {
      map['disc_number'] = Variable<int>(discNumber.value);
    }
    if (duration.present) {
      map['duration'] = Variable<int>(duration.value);
    }
    if (bitRate.present) {
      map['bit_rate'] = Variable<int>(bitRate.value);
    }
    if (contentType.present) {
      map['content_type'] = Variable<String>(contentType.value);
    }
    if (suffix.present) {
      map['suffix'] = Variable<String>(suffix.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (coverArt.present) {
      map['cover_art'] = Variable<String>(coverArt.value);
    }
    if (starred.present) {
      map['starred'] = Variable<DateTime>(starred.value);
    }
    if (playCount.present) {
      map['play_count'] = Variable<int>(playCount.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SongsTableCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('albumId: $albumId, ')
          ..write('artistId: $artistId, ')
          ..write('artistName: $artistName, ')
          ..write('albumName: $albumName, ')
          ..write('track: $track, ')
          ..write('discNumber: $discNumber, ')
          ..write('duration: $duration, ')
          ..write('bitRate: $bitRate, ')
          ..write('contentType: $contentType, ')
          ..write('suffix: $suffix, ')
          ..write('size: $size, ')
          ..write('coverArt: $coverArt, ')
          ..write('starred: $starred, ')
          ..write('playCount: $playCount, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GenresTableTable extends GenresTable
    with TableInfo<$GenresTableTable, GenresTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GenresTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _songCountMeta = const VerificationMeta(
    'songCount',
  );
  @override
  late final GeneratedColumn<int> songCount = GeneratedColumn<int>(
    'song_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _albumCountMeta = const VerificationMeta(
    'albumCount',
  );
  @override
  late final GeneratedColumn<int> albumCount = GeneratedColumn<int>(
    'album_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [name, songCount, albumCount];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'genres';
  @override
  VerificationContext validateIntegrity(
    Insertable<GenresTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('song_count')) {
      context.handle(
        _songCountMeta,
        songCount.isAcceptableOrUnknown(data['song_count']!, _songCountMeta),
      );
    }
    if (data.containsKey('album_count')) {
      context.handle(
        _albumCountMeta,
        albumCount.isAcceptableOrUnknown(data['album_count']!, _albumCountMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {name};
  @override
  GenresTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GenresTableData(
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      songCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}song_count'],
      ),
      albumCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}album_count'],
      ),
    );
  }

  @override
  $GenresTableTable createAlias(String alias) {
    return $GenresTableTable(attachedDatabase, alias);
  }
}

class GenresTableData extends DataClass implements Insertable<GenresTableData> {
  final String name;
  final int? songCount;
  final int? albumCount;
  const GenresTableData({required this.name, this.songCount, this.albumCount});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || songCount != null) {
      map['song_count'] = Variable<int>(songCount);
    }
    if (!nullToAbsent || albumCount != null) {
      map['album_count'] = Variable<int>(albumCount);
    }
    return map;
  }

  GenresTableCompanion toCompanion(bool nullToAbsent) {
    return GenresTableCompanion(
      name: Value(name),
      songCount: songCount == null && nullToAbsent
          ? const Value.absent()
          : Value(songCount),
      albumCount: albumCount == null && nullToAbsent
          ? const Value.absent()
          : Value(albumCount),
    );
  }

  factory GenresTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GenresTableData(
      name: serializer.fromJson<String>(json['name']),
      songCount: serializer.fromJson<int?>(json['songCount']),
      albumCount: serializer.fromJson<int?>(json['albumCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'name': serializer.toJson<String>(name),
      'songCount': serializer.toJson<int?>(songCount),
      'albumCount': serializer.toJson<int?>(albumCount),
    };
  }

  GenresTableData copyWith({
    String? name,
    Value<int?> songCount = const Value.absent(),
    Value<int?> albumCount = const Value.absent(),
  }) => GenresTableData(
    name: name ?? this.name,
    songCount: songCount.present ? songCount.value : this.songCount,
    albumCount: albumCount.present ? albumCount.value : this.albumCount,
  );
  GenresTableData copyWithCompanion(GenresTableCompanion data) {
    return GenresTableData(
      name: data.name.present ? data.name.value : this.name,
      songCount: data.songCount.present ? data.songCount.value : this.songCount,
      albumCount: data.albumCount.present
          ? data.albumCount.value
          : this.albumCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GenresTableData(')
          ..write('name: $name, ')
          ..write('songCount: $songCount, ')
          ..write('albumCount: $albumCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(name, songCount, albumCount);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GenresTableData &&
          other.name == this.name &&
          other.songCount == this.songCount &&
          other.albumCount == this.albumCount);
}

class GenresTableCompanion extends UpdateCompanion<GenresTableData> {
  final Value<String> name;
  final Value<int?> songCount;
  final Value<int?> albumCount;
  final Value<int> rowid;
  const GenresTableCompanion({
    this.name = const Value.absent(),
    this.songCount = const Value.absent(),
    this.albumCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GenresTableCompanion.insert({
    required String name,
    this.songCount = const Value.absent(),
    this.albumCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : name = Value(name);
  static Insertable<GenresTableData> custom({
    Expression<String>? name,
    Expression<int>? songCount,
    Expression<int>? albumCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (name != null) 'name': name,
      if (songCount != null) 'song_count': songCount,
      if (albumCount != null) 'album_count': albumCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GenresTableCompanion copyWith({
    Value<String>? name,
    Value<int?>? songCount,
    Value<int?>? albumCount,
    Value<int>? rowid,
  }) {
    return GenresTableCompanion(
      name: name ?? this.name,
      songCount: songCount ?? this.songCount,
      albumCount: albumCount ?? this.albumCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (songCount.present) {
      map['song_count'] = Variable<int>(songCount.value);
    }
    if (albumCount.present) {
      map['album_count'] = Variable<int>(albumCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GenresTableCompanion(')
          ..write('name: $name, ')
          ..write('songCount: $songCount, ')
          ..write('albumCount: $albumCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlaylistsTableTable extends PlaylistsTable
    with TableInfo<$PlaylistsTableTable, PlaylistsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaylistsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _songCountMeta = const VerificationMeta(
    'songCount',
  );
  @override
  late final GeneratedColumn<int> songCount = GeneratedColumn<int>(
    'song_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMeta = const VerificationMeta(
    'duration',
  );
  @override
  late final GeneratedColumn<int> duration = GeneratedColumn<int>(
    'duration',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ownerMeta = const VerificationMeta('owner');
  @override
  late final GeneratedColumn<String> owner = GeneratedColumn<String>(
    'owner',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isPublicMeta = const VerificationMeta(
    'isPublic',
  );
  @override
  late final GeneratedColumn<bool> isPublic = GeneratedColumn<bool>(
    'is_public',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_public" IN (0, 1))',
    ),
  );
  static const VerificationMeta _coverArtMeta = const VerificationMeta(
    'coverArt',
  );
  @override
  late final GeneratedColumn<String> coverArt = GeneratedColumn<String>(
    'cover_art',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _commentMeta = const VerificationMeta(
    'comment',
  );
  @override
  late final GeneratedColumn<String> comment = GeneratedColumn<String>(
    'comment',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    songCount,
    duration,
    owner,
    isPublic,
    coverArt,
    comment,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playlists';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlaylistsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('song_count')) {
      context.handle(
        _songCountMeta,
        songCount.isAcceptableOrUnknown(data['song_count']!, _songCountMeta),
      );
    }
    if (data.containsKey('duration')) {
      context.handle(
        _durationMeta,
        duration.isAcceptableOrUnknown(data['duration']!, _durationMeta),
      );
    }
    if (data.containsKey('owner')) {
      context.handle(
        _ownerMeta,
        owner.isAcceptableOrUnknown(data['owner']!, _ownerMeta),
      );
    }
    if (data.containsKey('is_public')) {
      context.handle(
        _isPublicMeta,
        isPublic.isAcceptableOrUnknown(data['is_public']!, _isPublicMeta),
      );
    }
    if (data.containsKey('cover_art')) {
      context.handle(
        _coverArtMeta,
        coverArt.isAcceptableOrUnknown(data['cover_art']!, _coverArtMeta),
      );
    }
    if (data.containsKey('comment')) {
      context.handle(
        _commentMeta,
        comment.isAcceptableOrUnknown(data['comment']!, _commentMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlaylistsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaylistsTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      songCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}song_count'],
      ),
      duration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration'],
      ),
      owner: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner'],
      ),
      isPublic: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_public'],
      ),
      coverArt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_art'],
      ),
      comment: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}comment'],
      ),
    );
  }

  @override
  $PlaylistsTableTable createAlias(String alias) {
    return $PlaylistsTableTable(attachedDatabase, alias);
  }
}

class PlaylistsTableData extends DataClass
    implements Insertable<PlaylistsTableData> {
  final String id;
  final String name;
  final int? songCount;
  final int? duration;
  final String? owner;
  final bool? isPublic;
  final String? coverArt;
  final String? comment;
  const PlaylistsTableData({
    required this.id,
    required this.name,
    this.songCount,
    this.duration,
    this.owner,
    this.isPublic,
    this.coverArt,
    this.comment,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || songCount != null) {
      map['song_count'] = Variable<int>(songCount);
    }
    if (!nullToAbsent || duration != null) {
      map['duration'] = Variable<int>(duration);
    }
    if (!nullToAbsent || owner != null) {
      map['owner'] = Variable<String>(owner);
    }
    if (!nullToAbsent || isPublic != null) {
      map['is_public'] = Variable<bool>(isPublic);
    }
    if (!nullToAbsent || coverArt != null) {
      map['cover_art'] = Variable<String>(coverArt);
    }
    if (!nullToAbsent || comment != null) {
      map['comment'] = Variable<String>(comment);
    }
    return map;
  }

  PlaylistsTableCompanion toCompanion(bool nullToAbsent) {
    return PlaylistsTableCompanion(
      id: Value(id),
      name: Value(name),
      songCount: songCount == null && nullToAbsent
          ? const Value.absent()
          : Value(songCount),
      duration: duration == null && nullToAbsent
          ? const Value.absent()
          : Value(duration),
      owner: owner == null && nullToAbsent
          ? const Value.absent()
          : Value(owner),
      isPublic: isPublic == null && nullToAbsent
          ? const Value.absent()
          : Value(isPublic),
      coverArt: coverArt == null && nullToAbsent
          ? const Value.absent()
          : Value(coverArt),
      comment: comment == null && nullToAbsent
          ? const Value.absent()
          : Value(comment),
    );
  }

  factory PlaylistsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlaylistsTableData(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      songCount: serializer.fromJson<int?>(json['songCount']),
      duration: serializer.fromJson<int?>(json['duration']),
      owner: serializer.fromJson<String?>(json['owner']),
      isPublic: serializer.fromJson<bool?>(json['isPublic']),
      coverArt: serializer.fromJson<String?>(json['coverArt']),
      comment: serializer.fromJson<String?>(json['comment']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'songCount': serializer.toJson<int?>(songCount),
      'duration': serializer.toJson<int?>(duration),
      'owner': serializer.toJson<String?>(owner),
      'isPublic': serializer.toJson<bool?>(isPublic),
      'coverArt': serializer.toJson<String?>(coverArt),
      'comment': serializer.toJson<String?>(comment),
    };
  }

  PlaylistsTableData copyWith({
    String? id,
    String? name,
    Value<int?> songCount = const Value.absent(),
    Value<int?> duration = const Value.absent(),
    Value<String?> owner = const Value.absent(),
    Value<bool?> isPublic = const Value.absent(),
    Value<String?> coverArt = const Value.absent(),
    Value<String?> comment = const Value.absent(),
  }) => PlaylistsTableData(
    id: id ?? this.id,
    name: name ?? this.name,
    songCount: songCount.present ? songCount.value : this.songCount,
    duration: duration.present ? duration.value : this.duration,
    owner: owner.present ? owner.value : this.owner,
    isPublic: isPublic.present ? isPublic.value : this.isPublic,
    coverArt: coverArt.present ? coverArt.value : this.coverArt,
    comment: comment.present ? comment.value : this.comment,
  );
  PlaylistsTableData copyWithCompanion(PlaylistsTableCompanion data) {
    return PlaylistsTableData(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      songCount: data.songCount.present ? data.songCount.value : this.songCount,
      duration: data.duration.present ? data.duration.value : this.duration,
      owner: data.owner.present ? data.owner.value : this.owner,
      isPublic: data.isPublic.present ? data.isPublic.value : this.isPublic,
      coverArt: data.coverArt.present ? data.coverArt.value : this.coverArt,
      comment: data.comment.present ? data.comment.value : this.comment,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistsTableData(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('songCount: $songCount, ')
          ..write('duration: $duration, ')
          ..write('owner: $owner, ')
          ..write('isPublic: $isPublic, ')
          ..write('coverArt: $coverArt, ')
          ..write('comment: $comment')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    songCount,
    duration,
    owner,
    isPublic,
    coverArt,
    comment,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaylistsTableData &&
          other.id == this.id &&
          other.name == this.name &&
          other.songCount == this.songCount &&
          other.duration == this.duration &&
          other.owner == this.owner &&
          other.isPublic == this.isPublic &&
          other.coverArt == this.coverArt &&
          other.comment == this.comment);
}

class PlaylistsTableCompanion extends UpdateCompanion<PlaylistsTableData> {
  final Value<String> id;
  final Value<String> name;
  final Value<int?> songCount;
  final Value<int?> duration;
  final Value<String?> owner;
  final Value<bool?> isPublic;
  final Value<String?> coverArt;
  final Value<String?> comment;
  final Value<int> rowid;
  const PlaylistsTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.songCount = const Value.absent(),
    this.duration = const Value.absent(),
    this.owner = const Value.absent(),
    this.isPublic = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.comment = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlaylistsTableCompanion.insert({
    required String id,
    required String name,
    this.songCount = const Value.absent(),
    this.duration = const Value.absent(),
    this.owner = const Value.absent(),
    this.isPublic = const Value.absent(),
    this.coverArt = const Value.absent(),
    this.comment = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<PlaylistsTableData> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<int>? songCount,
    Expression<int>? duration,
    Expression<String>? owner,
    Expression<bool>? isPublic,
    Expression<String>? coverArt,
    Expression<String>? comment,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (songCount != null) 'song_count': songCount,
      if (duration != null) 'duration': duration,
      if (owner != null) 'owner': owner,
      if (isPublic != null) 'is_public': isPublic,
      if (coverArt != null) 'cover_art': coverArt,
      if (comment != null) 'comment': comment,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlaylistsTableCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<int?>? songCount,
    Value<int?>? duration,
    Value<String?>? owner,
    Value<bool?>? isPublic,
    Value<String?>? coverArt,
    Value<String?>? comment,
    Value<int>? rowid,
  }) {
    return PlaylistsTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      songCount: songCount ?? this.songCount,
      duration: duration ?? this.duration,
      owner: owner ?? this.owner,
      isPublic: isPublic ?? this.isPublic,
      coverArt: coverArt ?? this.coverArt,
      comment: comment ?? this.comment,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (songCount.present) {
      map['song_count'] = Variable<int>(songCount.value);
    }
    if (duration.present) {
      map['duration'] = Variable<int>(duration.value);
    }
    if (owner.present) {
      map['owner'] = Variable<String>(owner.value);
    }
    if (isPublic.present) {
      map['is_public'] = Variable<bool>(isPublic.value);
    }
    if (coverArt.present) {
      map['cover_art'] = Variable<String>(coverArt.value);
    }
    if (comment.present) {
      map['comment'] = Variable<String>(comment.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistsTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('songCount: $songCount, ')
          ..write('duration: $duration, ')
          ..write('owner: $owner, ')
          ..write('isPublic: $isPublic, ')
          ..write('coverArt: $coverArt, ')
          ..write('comment: $comment, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlaylistSongsTableTable extends PlaylistSongsTable
    with TableInfo<$PlaylistSongsTableTable, PlaylistSongsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlaylistSongsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _playlistIdMeta = const VerificationMeta(
    'playlistId',
  );
  @override
  late final GeneratedColumn<String> playlistId = GeneratedColumn<String>(
    'playlist_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES playlists (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
    'song_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES songs (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [playlistId, songId, sortOrder];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'playlist_songs';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlaylistSongsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('playlist_id')) {
      context.handle(
        _playlistIdMeta,
        playlistId.isAcceptableOrUnknown(data['playlist_id']!, _playlistIdMeta),
      );
    } else if (isInserting) {
      context.missing(_playlistIdMeta);
    }
    if (data.containsKey('song_id')) {
      context.handle(
        _songIdMeta,
        songId.isAcceptableOrUnknown(data['song_id']!, _songIdMeta),
      );
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {playlistId, songId};
  @override
  PlaylistSongsTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlaylistSongsTableData(
      playlistId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}playlist_id'],
      )!,
      songId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}song_id'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $PlaylistSongsTableTable createAlias(String alias) {
    return $PlaylistSongsTableTable(attachedDatabase, alias);
  }
}

class PlaylistSongsTableData extends DataClass
    implements Insertable<PlaylistSongsTableData> {
  final String playlistId;
  final String songId;
  final int sortOrder;
  const PlaylistSongsTableData({
    required this.playlistId,
    required this.songId,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['playlist_id'] = Variable<String>(playlistId);
    map['song_id'] = Variable<String>(songId);
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  PlaylistSongsTableCompanion toCompanion(bool nullToAbsent) {
    return PlaylistSongsTableCompanion(
      playlistId: Value(playlistId),
      songId: Value(songId),
      sortOrder: Value(sortOrder),
    );
  }

  factory PlaylistSongsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlaylistSongsTableData(
      playlistId: serializer.fromJson<String>(json['playlistId']),
      songId: serializer.fromJson<String>(json['songId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'playlistId': serializer.toJson<String>(playlistId),
      'songId': serializer.toJson<String>(songId),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  PlaylistSongsTableData copyWith({
    String? playlistId,
    String? songId,
    int? sortOrder,
  }) => PlaylistSongsTableData(
    playlistId: playlistId ?? this.playlistId,
    songId: songId ?? this.songId,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  PlaylistSongsTableData copyWithCompanion(PlaylistSongsTableCompanion data) {
    return PlaylistSongsTableData(
      playlistId: data.playlistId.present
          ? data.playlistId.value
          : this.playlistId,
      songId: data.songId.present ? data.songId.value : this.songId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistSongsTableData(')
          ..write('playlistId: $playlistId, ')
          ..write('songId: $songId, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(playlistId, songId, sortOrder);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaylistSongsTableData &&
          other.playlistId == this.playlistId &&
          other.songId == this.songId &&
          other.sortOrder == this.sortOrder);
}

class PlaylistSongsTableCompanion
    extends UpdateCompanion<PlaylistSongsTableData> {
  final Value<String> playlistId;
  final Value<String> songId;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const PlaylistSongsTableCompanion({
    this.playlistId = const Value.absent(),
    this.songId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlaylistSongsTableCompanion.insert({
    required String playlistId,
    required String songId,
    required int sortOrder,
    this.rowid = const Value.absent(),
  }) : playlistId = Value(playlistId),
       songId = Value(songId),
       sortOrder = Value(sortOrder);
  static Insertable<PlaylistSongsTableData> custom({
    Expression<String>? playlistId,
    Expression<String>? songId,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (playlistId != null) 'playlist_id': playlistId,
      if (songId != null) 'song_id': songId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlaylistSongsTableCompanion copyWith({
    Value<String>? playlistId,
    Value<String>? songId,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return PlaylistSongsTableCompanion(
      playlistId: playlistId ?? this.playlistId,
      songId: songId ?? this.songId,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (playlistId.present) {
      map['playlist_id'] = Variable<String>(playlistId.value);
    }
    if (songId.present) {
      map['song_id'] = Variable<String>(songId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlaylistSongsTableCompanion(')
          ..write('playlistId: $playlistId, ')
          ..write('songId: $songId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedTracksTableTable extends CachedTracksTable
    with TableInfo<$CachedTracksTableTable, CachedTracksTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedTracksTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
    'song_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES songs (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _filePathMeta = const VerificationMeta(
    'filePath',
  );
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
    'file_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileSizeMeta = const VerificationMeta(
    'fileSize',
  );
  @override
  late final GeneratedColumn<int> fileSize = GeneratedColumn<int>(
    'file_size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bitRateMeta = const VerificationMeta(
    'bitRate',
  );
  @override
  late final GeneratedColumn<int> bitRate = GeneratedColumn<int>(
    'bit_rate',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastAccessedAtMeta = const VerificationMeta(
    'lastAccessedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastAccessedAt =
      GeneratedColumn<DateTime>(
        'last_accessed_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  @override
  late final GeneratedColumnWithTypeConverter<CacheType, String> cacheType =
      GeneratedColumn<String>(
        'cache_type',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<CacheType>($CachedTracksTableTable.$convertercacheType);
  @override
  late final GeneratedColumnWithTypeConverter<DownloadStatus, String>
  downloadStatus =
      GeneratedColumn<String>(
        'download_status',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<DownloadStatus>(
        $CachedTracksTableTable.$converterdownloadStatus,
      );
  @override
  List<GeneratedColumn> get $columns => [
    songId,
    filePath,
    fileSize,
    format,
    bitRate,
    lastAccessedAt,
    cacheType,
    downloadStatus,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_tracks';
  @override
  VerificationContext validateIntegrity(
    Insertable<CachedTracksTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('song_id')) {
      context.handle(
        _songIdMeta,
        songId.isAcceptableOrUnknown(data['song_id']!, _songIdMeta),
      );
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('file_path')) {
      context.handle(
        _filePathMeta,
        filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta),
      );
    } else if (isInserting) {
      context.missing(_filePathMeta);
    }
    if (data.containsKey('file_size')) {
      context.handle(
        _fileSizeMeta,
        fileSize.isAcceptableOrUnknown(data['file_size']!, _fileSizeMeta),
      );
    } else if (isInserting) {
      context.missing(_fileSizeMeta);
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    } else if (isInserting) {
      context.missing(_formatMeta);
    }
    if (data.containsKey('bit_rate')) {
      context.handle(
        _bitRateMeta,
        bitRate.isAcceptableOrUnknown(data['bit_rate']!, _bitRateMeta),
      );
    }
    if (data.containsKey('last_accessed_at')) {
      context.handle(
        _lastAccessedAtMeta,
        lastAccessedAt.isAcceptableOrUnknown(
          data['last_accessed_at']!,
          _lastAccessedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastAccessedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {songId};
  @override
  CachedTracksTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedTracksTableData(
      songId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}song_id'],
      )!,
      filePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_path'],
      )!,
      fileSize: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}file_size'],
      )!,
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      )!,
      bitRate: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}bit_rate'],
      ),
      lastAccessedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_accessed_at'],
      )!,
      cacheType: $CachedTracksTableTable.$convertercacheType.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}cache_type'],
        )!,
      ),
      downloadStatus: $CachedTracksTableTable.$converterdownloadStatus.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}download_status'],
        )!,
      ),
    );
  }

  @override
  $CachedTracksTableTable createAlias(String alias) {
    return $CachedTracksTableTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<CacheType, String, String> $convertercacheType =
      const EnumNameConverter<CacheType>(CacheType.values);
  static JsonTypeConverter2<DownloadStatus, String, String>
  $converterdownloadStatus = const EnumNameConverter<DownloadStatus>(
    DownloadStatus.values,
  );
}

class CachedTracksTableData extends DataClass
    implements Insertable<CachedTracksTableData> {
  final String songId;
  final String filePath;
  final int fileSize;
  final String format;
  final int? bitRate;
  final DateTime lastAccessedAt;
  final CacheType cacheType;
  final DownloadStatus downloadStatus;
  const CachedTracksTableData({
    required this.songId,
    required this.filePath,
    required this.fileSize,
    required this.format,
    this.bitRate,
    required this.lastAccessedAt,
    required this.cacheType,
    required this.downloadStatus,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['song_id'] = Variable<String>(songId);
    map['file_path'] = Variable<String>(filePath);
    map['file_size'] = Variable<int>(fileSize);
    map['format'] = Variable<String>(format);
    if (!nullToAbsent || bitRate != null) {
      map['bit_rate'] = Variable<int>(bitRate);
    }
    map['last_accessed_at'] = Variable<DateTime>(lastAccessedAt);
    {
      map['cache_type'] = Variable<String>(
        $CachedTracksTableTable.$convertercacheType.toSql(cacheType),
      );
    }
    {
      map['download_status'] = Variable<String>(
        $CachedTracksTableTable.$converterdownloadStatus.toSql(downloadStatus),
      );
    }
    return map;
  }

  CachedTracksTableCompanion toCompanion(bool nullToAbsent) {
    return CachedTracksTableCompanion(
      songId: Value(songId),
      filePath: Value(filePath),
      fileSize: Value(fileSize),
      format: Value(format),
      bitRate: bitRate == null && nullToAbsent
          ? const Value.absent()
          : Value(bitRate),
      lastAccessedAt: Value(lastAccessedAt),
      cacheType: Value(cacheType),
      downloadStatus: Value(downloadStatus),
    );
  }

  factory CachedTracksTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedTracksTableData(
      songId: serializer.fromJson<String>(json['songId']),
      filePath: serializer.fromJson<String>(json['filePath']),
      fileSize: serializer.fromJson<int>(json['fileSize']),
      format: serializer.fromJson<String>(json['format']),
      bitRate: serializer.fromJson<int?>(json['bitRate']),
      lastAccessedAt: serializer.fromJson<DateTime>(json['lastAccessedAt']),
      cacheType: $CachedTracksTableTable.$convertercacheType.fromJson(
        serializer.fromJson<String>(json['cacheType']),
      ),
      downloadStatus: $CachedTracksTableTable.$converterdownloadStatus.fromJson(
        serializer.fromJson<String>(json['downloadStatus']),
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'songId': serializer.toJson<String>(songId),
      'filePath': serializer.toJson<String>(filePath),
      'fileSize': serializer.toJson<int>(fileSize),
      'format': serializer.toJson<String>(format),
      'bitRate': serializer.toJson<int?>(bitRate),
      'lastAccessedAt': serializer.toJson<DateTime>(lastAccessedAt),
      'cacheType': serializer.toJson<String>(
        $CachedTracksTableTable.$convertercacheType.toJson(cacheType),
      ),
      'downloadStatus': serializer.toJson<String>(
        $CachedTracksTableTable.$converterdownloadStatus.toJson(downloadStatus),
      ),
    };
  }

  CachedTracksTableData copyWith({
    String? songId,
    String? filePath,
    int? fileSize,
    String? format,
    Value<int?> bitRate = const Value.absent(),
    DateTime? lastAccessedAt,
    CacheType? cacheType,
    DownloadStatus? downloadStatus,
  }) => CachedTracksTableData(
    songId: songId ?? this.songId,
    filePath: filePath ?? this.filePath,
    fileSize: fileSize ?? this.fileSize,
    format: format ?? this.format,
    bitRate: bitRate.present ? bitRate.value : this.bitRate,
    lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    cacheType: cacheType ?? this.cacheType,
    downloadStatus: downloadStatus ?? this.downloadStatus,
  );
  CachedTracksTableData copyWithCompanion(CachedTracksTableCompanion data) {
    return CachedTracksTableData(
      songId: data.songId.present ? data.songId.value : this.songId,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      fileSize: data.fileSize.present ? data.fileSize.value : this.fileSize,
      format: data.format.present ? data.format.value : this.format,
      bitRate: data.bitRate.present ? data.bitRate.value : this.bitRate,
      lastAccessedAt: data.lastAccessedAt.present
          ? data.lastAccessedAt.value
          : this.lastAccessedAt,
      cacheType: data.cacheType.present ? data.cacheType.value : this.cacheType,
      downloadStatus: data.downloadStatus.present
          ? data.downloadStatus.value
          : this.downloadStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedTracksTableData(')
          ..write('songId: $songId, ')
          ..write('filePath: $filePath, ')
          ..write('fileSize: $fileSize, ')
          ..write('format: $format, ')
          ..write('bitRate: $bitRate, ')
          ..write('lastAccessedAt: $lastAccessedAt, ')
          ..write('cacheType: $cacheType, ')
          ..write('downloadStatus: $downloadStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    songId,
    filePath,
    fileSize,
    format,
    bitRate,
    lastAccessedAt,
    cacheType,
    downloadStatus,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedTracksTableData &&
          other.songId == this.songId &&
          other.filePath == this.filePath &&
          other.fileSize == this.fileSize &&
          other.format == this.format &&
          other.bitRate == this.bitRate &&
          other.lastAccessedAt == this.lastAccessedAt &&
          other.cacheType == this.cacheType &&
          other.downloadStatus == this.downloadStatus);
}

class CachedTracksTableCompanion
    extends UpdateCompanion<CachedTracksTableData> {
  final Value<String> songId;
  final Value<String> filePath;
  final Value<int> fileSize;
  final Value<String> format;
  final Value<int?> bitRate;
  final Value<DateTime> lastAccessedAt;
  final Value<CacheType> cacheType;
  final Value<DownloadStatus> downloadStatus;
  final Value<int> rowid;
  const CachedTracksTableCompanion({
    this.songId = const Value.absent(),
    this.filePath = const Value.absent(),
    this.fileSize = const Value.absent(),
    this.format = const Value.absent(),
    this.bitRate = const Value.absent(),
    this.lastAccessedAt = const Value.absent(),
    this.cacheType = const Value.absent(),
    this.downloadStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedTracksTableCompanion.insert({
    required String songId,
    required String filePath,
    required int fileSize,
    required String format,
    this.bitRate = const Value.absent(),
    required DateTime lastAccessedAt,
    required CacheType cacheType,
    required DownloadStatus downloadStatus,
    this.rowid = const Value.absent(),
  }) : songId = Value(songId),
       filePath = Value(filePath),
       fileSize = Value(fileSize),
       format = Value(format),
       lastAccessedAt = Value(lastAccessedAt),
       cacheType = Value(cacheType),
       downloadStatus = Value(downloadStatus);
  static Insertable<CachedTracksTableData> custom({
    Expression<String>? songId,
    Expression<String>? filePath,
    Expression<int>? fileSize,
    Expression<String>? format,
    Expression<int>? bitRate,
    Expression<DateTime>? lastAccessedAt,
    Expression<String>? cacheType,
    Expression<String>? downloadStatus,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (songId != null) 'song_id': songId,
      if (filePath != null) 'file_path': filePath,
      if (fileSize != null) 'file_size': fileSize,
      if (format != null) 'format': format,
      if (bitRate != null) 'bit_rate': bitRate,
      if (lastAccessedAt != null) 'last_accessed_at': lastAccessedAt,
      if (cacheType != null) 'cache_type': cacheType,
      if (downloadStatus != null) 'download_status': downloadStatus,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedTracksTableCompanion copyWith({
    Value<String>? songId,
    Value<String>? filePath,
    Value<int>? fileSize,
    Value<String>? format,
    Value<int?>? bitRate,
    Value<DateTime>? lastAccessedAt,
    Value<CacheType>? cacheType,
    Value<DownloadStatus>? downloadStatus,
    Value<int>? rowid,
  }) {
    return CachedTracksTableCompanion(
      songId: songId ?? this.songId,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      format: format ?? this.format,
      bitRate: bitRate ?? this.bitRate,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      cacheType: cacheType ?? this.cacheType,
      downloadStatus: downloadStatus ?? this.downloadStatus,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (songId.present) {
      map['song_id'] = Variable<String>(songId.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (fileSize.present) {
      map['file_size'] = Variable<int>(fileSize.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (bitRate.present) {
      map['bit_rate'] = Variable<int>(bitRate.value);
    }
    if (lastAccessedAt.present) {
      map['last_accessed_at'] = Variable<DateTime>(lastAccessedAt.value);
    }
    if (cacheType.present) {
      map['cache_type'] = Variable<String>(
        $CachedTracksTableTable.$convertercacheType.toSql(cacheType.value),
      );
    }
    if (downloadStatus.present) {
      map['download_status'] = Variable<String>(
        $CachedTracksTableTable.$converterdownloadStatus.toSql(
          downloadStatus.value,
        ),
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedTracksTableCompanion(')
          ..write('songId: $songId, ')
          ..write('filePath: $filePath, ')
          ..write('fileSize: $fileSize, ')
          ..write('format: $format, ')
          ..write('bitRate: $bitRate, ')
          ..write('lastAccessedAt: $lastAccessedAt, ')
          ..write('cacheType: $cacheType, ')
          ..write('downloadStatus: $downloadStatus, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DownloadQueueTableTable extends DownloadQueueTable
    with TableInfo<$DownloadQueueTableTable, DownloadQueueTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadQueueTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
    'song_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES songs (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _albumIdMeta = const VerificationMeta(
    'albumId',
  );
  @override
  late final GeneratedColumn<String> albumId = GeneratedColumn<String>(
    'album_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES albums (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _playlistIdMeta = const VerificationMeta(
    'playlistId',
  );
  @override
  late final GeneratedColumn<String> playlistId = GeneratedColumn<String>(
    'playlist_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES playlists (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _qualityMeta = const VerificationMeta(
    'quality',
  );
  @override
  late final GeneratedColumn<String> quality = GeneratedColumn<String>(
    'quality',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<DownloadStatus, String> status =
      GeneratedColumn<String>(
        'status',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<DownloadStatus>(
        $DownloadQueueTableTable.$converterstatus,
      );
  static const VerificationMeta _progressMeta = const VerificationMeta(
    'progress',
  );
  @override
  late final GeneratedColumn<double> progress = GeneratedColumn<double>(
    'progress',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _priorityMeta = const VerificationMeta(
    'priority',
  );
  @override
  late final GeneratedColumn<int> priority = GeneratedColumn<int>(
    'priority',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    songId,
    albumId,
    playlistId,
    quality,
    format,
    status,
    progress,
    addedAt,
    priority,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_queue';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadQueueTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('song_id')) {
      context.handle(
        _songIdMeta,
        songId.isAcceptableOrUnknown(data['song_id']!, _songIdMeta),
      );
    }
    if (data.containsKey('album_id')) {
      context.handle(
        _albumIdMeta,
        albumId.isAcceptableOrUnknown(data['album_id']!, _albumIdMeta),
      );
    }
    if (data.containsKey('playlist_id')) {
      context.handle(
        _playlistIdMeta,
        playlistId.isAcceptableOrUnknown(data['playlist_id']!, _playlistIdMeta),
      );
    }
    if (data.containsKey('quality')) {
      context.handle(
        _qualityMeta,
        quality.isAcceptableOrUnknown(data['quality']!, _qualityMeta),
      );
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    }
    if (data.containsKey('progress')) {
      context.handle(
        _progressMeta,
        progress.isAcceptableOrUnknown(data['progress']!, _progressMeta),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('priority')) {
      context.handle(
        _priorityMeta,
        priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DownloadQueueTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadQueueTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      songId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}song_id'],
      ),
      albumId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}album_id'],
      ),
      playlistId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}playlist_id'],
      ),
      quality: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}quality'],
      ),
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      ),
      status: $DownloadQueueTableTable.$converterstatus.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}status'],
        )!,
      ),
      progress: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}progress'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}added_at'],
      )!,
      priority: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}priority'],
      )!,
    );
  }

  @override
  $DownloadQueueTableTable createAlias(String alias) {
    return $DownloadQueueTableTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<DownloadStatus, String, String> $converterstatus =
      const EnumNameConverter<DownloadStatus>(DownloadStatus.values);
}

class DownloadQueueTableData extends DataClass
    implements Insertable<DownloadQueueTableData> {
  final int id;
  final String? songId;
  final String? albumId;
  final String? playlistId;
  final String? quality;
  final String? format;
  final DownloadStatus status;
  final double progress;
  final DateTime addedAt;
  final int priority;
  const DownloadQueueTableData({
    required this.id,
    this.songId,
    this.albumId,
    this.playlistId,
    this.quality,
    this.format,
    required this.status,
    required this.progress,
    required this.addedAt,
    required this.priority,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || songId != null) {
      map['song_id'] = Variable<String>(songId);
    }
    if (!nullToAbsent || albumId != null) {
      map['album_id'] = Variable<String>(albumId);
    }
    if (!nullToAbsent || playlistId != null) {
      map['playlist_id'] = Variable<String>(playlistId);
    }
    if (!nullToAbsent || quality != null) {
      map['quality'] = Variable<String>(quality);
    }
    if (!nullToAbsent || format != null) {
      map['format'] = Variable<String>(format);
    }
    {
      map['status'] = Variable<String>(
        $DownloadQueueTableTable.$converterstatus.toSql(status),
      );
    }
    map['progress'] = Variable<double>(progress);
    map['added_at'] = Variable<DateTime>(addedAt);
    map['priority'] = Variable<int>(priority);
    return map;
  }

  DownloadQueueTableCompanion toCompanion(bool nullToAbsent) {
    return DownloadQueueTableCompanion(
      id: Value(id),
      songId: songId == null && nullToAbsent
          ? const Value.absent()
          : Value(songId),
      albumId: albumId == null && nullToAbsent
          ? const Value.absent()
          : Value(albumId),
      playlistId: playlistId == null && nullToAbsent
          ? const Value.absent()
          : Value(playlistId),
      quality: quality == null && nullToAbsent
          ? const Value.absent()
          : Value(quality),
      format: format == null && nullToAbsent
          ? const Value.absent()
          : Value(format),
      status: Value(status),
      progress: Value(progress),
      addedAt: Value(addedAt),
      priority: Value(priority),
    );
  }

  factory DownloadQueueTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadQueueTableData(
      id: serializer.fromJson<int>(json['id']),
      songId: serializer.fromJson<String?>(json['songId']),
      albumId: serializer.fromJson<String?>(json['albumId']),
      playlistId: serializer.fromJson<String?>(json['playlistId']),
      quality: serializer.fromJson<String?>(json['quality']),
      format: serializer.fromJson<String?>(json['format']),
      status: $DownloadQueueTableTable.$converterstatus.fromJson(
        serializer.fromJson<String>(json['status']),
      ),
      progress: serializer.fromJson<double>(json['progress']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
      priority: serializer.fromJson<int>(json['priority']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'songId': serializer.toJson<String?>(songId),
      'albumId': serializer.toJson<String?>(albumId),
      'playlistId': serializer.toJson<String?>(playlistId),
      'quality': serializer.toJson<String?>(quality),
      'format': serializer.toJson<String?>(format),
      'status': serializer.toJson<String>(
        $DownloadQueueTableTable.$converterstatus.toJson(status),
      ),
      'progress': serializer.toJson<double>(progress),
      'addedAt': serializer.toJson<DateTime>(addedAt),
      'priority': serializer.toJson<int>(priority),
    };
  }

  DownloadQueueTableData copyWith({
    int? id,
    Value<String?> songId = const Value.absent(),
    Value<String?> albumId = const Value.absent(),
    Value<String?> playlistId = const Value.absent(),
    Value<String?> quality = const Value.absent(),
    Value<String?> format = const Value.absent(),
    DownloadStatus? status,
    double? progress,
    DateTime? addedAt,
    int? priority,
  }) => DownloadQueueTableData(
    id: id ?? this.id,
    songId: songId.present ? songId.value : this.songId,
    albumId: albumId.present ? albumId.value : this.albumId,
    playlistId: playlistId.present ? playlistId.value : this.playlistId,
    quality: quality.present ? quality.value : this.quality,
    format: format.present ? format.value : this.format,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    addedAt: addedAt ?? this.addedAt,
    priority: priority ?? this.priority,
  );
  DownloadQueueTableData copyWithCompanion(DownloadQueueTableCompanion data) {
    return DownloadQueueTableData(
      id: data.id.present ? data.id.value : this.id,
      songId: data.songId.present ? data.songId.value : this.songId,
      albumId: data.albumId.present ? data.albumId.value : this.albumId,
      playlistId: data.playlistId.present
          ? data.playlistId.value
          : this.playlistId,
      quality: data.quality.present ? data.quality.value : this.quality,
      format: data.format.present ? data.format.value : this.format,
      status: data.status.present ? data.status.value : this.status,
      progress: data.progress.present ? data.progress.value : this.progress,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      priority: data.priority.present ? data.priority.value : this.priority,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadQueueTableData(')
          ..write('id: $id, ')
          ..write('songId: $songId, ')
          ..write('albumId: $albumId, ')
          ..write('playlistId: $playlistId, ')
          ..write('quality: $quality, ')
          ..write('format: $format, ')
          ..write('status: $status, ')
          ..write('progress: $progress, ')
          ..write('addedAt: $addedAt, ')
          ..write('priority: $priority')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    songId,
    albumId,
    playlistId,
    quality,
    format,
    status,
    progress,
    addedAt,
    priority,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadQueueTableData &&
          other.id == this.id &&
          other.songId == this.songId &&
          other.albumId == this.albumId &&
          other.playlistId == this.playlistId &&
          other.quality == this.quality &&
          other.format == this.format &&
          other.status == this.status &&
          other.progress == this.progress &&
          other.addedAt == this.addedAt &&
          other.priority == this.priority);
}

class DownloadQueueTableCompanion
    extends UpdateCompanion<DownloadQueueTableData> {
  final Value<int> id;
  final Value<String?> songId;
  final Value<String?> albumId;
  final Value<String?> playlistId;
  final Value<String?> quality;
  final Value<String?> format;
  final Value<DownloadStatus> status;
  final Value<double> progress;
  final Value<DateTime> addedAt;
  final Value<int> priority;
  const DownloadQueueTableCompanion({
    this.id = const Value.absent(),
    this.songId = const Value.absent(),
    this.albumId = const Value.absent(),
    this.playlistId = const Value.absent(),
    this.quality = const Value.absent(),
    this.format = const Value.absent(),
    this.status = const Value.absent(),
    this.progress = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.priority = const Value.absent(),
  });
  DownloadQueueTableCompanion.insert({
    this.id = const Value.absent(),
    this.songId = const Value.absent(),
    this.albumId = const Value.absent(),
    this.playlistId = const Value.absent(),
    this.quality = const Value.absent(),
    this.format = const Value.absent(),
    required DownloadStatus status,
    this.progress = const Value.absent(),
    required DateTime addedAt,
    this.priority = const Value.absent(),
  }) : status = Value(status),
       addedAt = Value(addedAt);
  static Insertable<DownloadQueueTableData> custom({
    Expression<int>? id,
    Expression<String>? songId,
    Expression<String>? albumId,
    Expression<String>? playlistId,
    Expression<String>? quality,
    Expression<String>? format,
    Expression<String>? status,
    Expression<double>? progress,
    Expression<DateTime>? addedAt,
    Expression<int>? priority,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (songId != null) 'song_id': songId,
      if (albumId != null) 'album_id': albumId,
      if (playlistId != null) 'playlist_id': playlistId,
      if (quality != null) 'quality': quality,
      if (format != null) 'format': format,
      if (status != null) 'status': status,
      if (progress != null) 'progress': progress,
      if (addedAt != null) 'added_at': addedAt,
      if (priority != null) 'priority': priority,
    });
  }

  DownloadQueueTableCompanion copyWith({
    Value<int>? id,
    Value<String?>? songId,
    Value<String?>? albumId,
    Value<String?>? playlistId,
    Value<String?>? quality,
    Value<String?>? format,
    Value<DownloadStatus>? status,
    Value<double>? progress,
    Value<DateTime>? addedAt,
    Value<int>? priority,
  }) {
    return DownloadQueueTableCompanion(
      id: id ?? this.id,
      songId: songId ?? this.songId,
      albumId: albumId ?? this.albumId,
      playlistId: playlistId ?? this.playlistId,
      quality: quality ?? this.quality,
      format: format ?? this.format,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      addedAt: addedAt ?? this.addedAt,
      priority: priority ?? this.priority,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (songId.present) {
      map['song_id'] = Variable<String>(songId.value);
    }
    if (albumId.present) {
      map['album_id'] = Variable<String>(albumId.value);
    }
    if (playlistId.present) {
      map['playlist_id'] = Variable<String>(playlistId.value);
    }
    if (quality.present) {
      map['quality'] = Variable<String>(quality.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(
        $DownloadQueueTableTable.$converterstatus.toSql(status.value),
      );
    }
    if (progress.present) {
      map['progress'] = Variable<double>(progress.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    if (priority.present) {
      map['priority'] = Variable<int>(priority.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadQueueTableCompanion(')
          ..write('id: $id, ')
          ..write('songId: $songId, ')
          ..write('albumId: $albumId, ')
          ..write('playlistId: $playlistId, ')
          ..write('quality: $quality, ')
          ..write('format: $format, ')
          ..write('status: $status, ')
          ..write('progress: $progress, ')
          ..write('addedAt: $addedAt, ')
          ..write('priority: $priority')
          ..write(')'))
        .toString();
  }
}

class $PlayHistoryTableTable extends PlayHistoryTable
    with TableInfo<$PlayHistoryTableTable, PlayHistoryTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlayHistoryTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
    'song_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES songs (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _playedAtMeta = const VerificationMeta(
    'playedAt',
  );
  @override
  late final GeneratedColumn<DateTime> playedAt = GeneratedColumn<DateTime>(
    'played_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [songId, playedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'play_history';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlayHistoryTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('song_id')) {
      context.handle(
        _songIdMeta,
        songId.isAcceptableOrUnknown(data['song_id']!, _songIdMeta),
      );
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('played_at')) {
      context.handle(
        _playedAtMeta,
        playedAt.isAcceptableOrUnknown(data['played_at']!, _playedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_playedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {songId, playedAt};
  @override
  PlayHistoryTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlayHistoryTableData(
      songId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}song_id'],
      )!,
      playedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}played_at'],
      )!,
    );
  }

  @override
  $PlayHistoryTableTable createAlias(String alias) {
    return $PlayHistoryTableTable(attachedDatabase, alias);
  }
}

class PlayHistoryTableData extends DataClass
    implements Insertable<PlayHistoryTableData> {
  final String songId;
  final DateTime playedAt;
  const PlayHistoryTableData({required this.songId, required this.playedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['song_id'] = Variable<String>(songId);
    map['played_at'] = Variable<DateTime>(playedAt);
    return map;
  }

  PlayHistoryTableCompanion toCompanion(bool nullToAbsent) {
    return PlayHistoryTableCompanion(
      songId: Value(songId),
      playedAt: Value(playedAt),
    );
  }

  factory PlayHistoryTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlayHistoryTableData(
      songId: serializer.fromJson<String>(json['songId']),
      playedAt: serializer.fromJson<DateTime>(json['playedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'songId': serializer.toJson<String>(songId),
      'playedAt': serializer.toJson<DateTime>(playedAt),
    };
  }

  PlayHistoryTableData copyWith({String? songId, DateTime? playedAt}) =>
      PlayHistoryTableData(
        songId: songId ?? this.songId,
        playedAt: playedAt ?? this.playedAt,
      );
  PlayHistoryTableData copyWithCompanion(PlayHistoryTableCompanion data) {
    return PlayHistoryTableData(
      songId: data.songId.present ? data.songId.value : this.songId,
      playedAt: data.playedAt.present ? data.playedAt.value : this.playedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlayHistoryTableData(')
          ..write('songId: $songId, ')
          ..write('playedAt: $playedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(songId, playedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlayHistoryTableData &&
          other.songId == this.songId &&
          other.playedAt == this.playedAt);
}

class PlayHistoryTableCompanion extends UpdateCompanion<PlayHistoryTableData> {
  final Value<String> songId;
  final Value<DateTime> playedAt;
  final Value<int> rowid;
  const PlayHistoryTableCompanion({
    this.songId = const Value.absent(),
    this.playedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlayHistoryTableCompanion.insert({
    required String songId,
    required DateTime playedAt,
    this.rowid = const Value.absent(),
  }) : songId = Value(songId),
       playedAt = Value(playedAt);
  static Insertable<PlayHistoryTableData> custom({
    Expression<String>? songId,
    Expression<DateTime>? playedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (songId != null) 'song_id': songId,
      if (playedAt != null) 'played_at': playedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlayHistoryTableCompanion copyWith({
    Value<String>? songId,
    Value<DateTime>? playedAt,
    Value<int>? rowid,
  }) {
    return PlayHistoryTableCompanion(
      songId: songId ?? this.songId,
      playedAt: playedAt ?? this.playedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (songId.present) {
      map['song_id'] = Variable<String>(songId.value);
    }
    if (playedAt.present) {
      map['played_at'] = Variable<DateTime>(playedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlayHistoryTableCompanion(')
          ..write('songId: $songId, ')
          ..write('playedAt: $playedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RecentSearchesTableTable extends RecentSearchesTable
    with TableInfo<$RecentSearchesTableTable, RecentSearchesTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecentSearchesTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _queryMeta = const VerificationMeta('query');
  @override
  late final GeneratedColumn<String> query = GeneratedColumn<String>(
    'query',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _searchedAtMeta = const VerificationMeta(
    'searchedAt',
  );
  @override
  late final GeneratedColumn<DateTime> searchedAt = GeneratedColumn<DateTime>(
    'searched_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [query, searchedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recent_searches';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecentSearchesTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('query')) {
      context.handle(
        _queryMeta,
        query.isAcceptableOrUnknown(data['query']!, _queryMeta),
      );
    } else if (isInserting) {
      context.missing(_queryMeta);
    }
    if (data.containsKey('searched_at')) {
      context.handle(
        _searchedAtMeta,
        searchedAt.isAcceptableOrUnknown(data['searched_at']!, _searchedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_searchedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {query};
  @override
  RecentSearchesTableData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecentSearchesTableData(
      query: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}query'],
      )!,
      searchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}searched_at'],
      )!,
    );
  }

  @override
  $RecentSearchesTableTable createAlias(String alias) {
    return $RecentSearchesTableTable(attachedDatabase, alias);
  }
}

class RecentSearchesTableData extends DataClass
    implements Insertable<RecentSearchesTableData> {
  final String query;
  final DateTime searchedAt;
  const RecentSearchesTableData({
    required this.query,
    required this.searchedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['query'] = Variable<String>(query);
    map['searched_at'] = Variable<DateTime>(searchedAt);
    return map;
  }

  RecentSearchesTableCompanion toCompanion(bool nullToAbsent) {
    return RecentSearchesTableCompanion(
      query: Value(query),
      searchedAt: Value(searchedAt),
    );
  }

  factory RecentSearchesTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecentSearchesTableData(
      query: serializer.fromJson<String>(json['query']),
      searchedAt: serializer.fromJson<DateTime>(json['searchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'query': serializer.toJson<String>(query),
      'searchedAt': serializer.toJson<DateTime>(searchedAt),
    };
  }

  RecentSearchesTableData copyWith({String? query, DateTime? searchedAt}) =>
      RecentSearchesTableData(
        query: query ?? this.query,
        searchedAt: searchedAt ?? this.searchedAt,
      );
  RecentSearchesTableData copyWithCompanion(RecentSearchesTableCompanion data) {
    return RecentSearchesTableData(
      query: data.query.present ? data.query.value : this.query,
      searchedAt: data.searchedAt.present
          ? data.searchedAt.value
          : this.searchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecentSearchesTableData(')
          ..write('query: $query, ')
          ..write('searchedAt: $searchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(query, searchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecentSearchesTableData &&
          other.query == this.query &&
          other.searchedAt == this.searchedAt);
}

class RecentSearchesTableCompanion
    extends UpdateCompanion<RecentSearchesTableData> {
  final Value<String> query;
  final Value<DateTime> searchedAt;
  final Value<int> rowid;
  const RecentSearchesTableCompanion({
    this.query = const Value.absent(),
    this.searchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  RecentSearchesTableCompanion.insert({
    required String query,
    required DateTime searchedAt,
    this.rowid = const Value.absent(),
  }) : query = Value(query),
       searchedAt = Value(searchedAt);
  static Insertable<RecentSearchesTableData> custom({
    Expression<String>? query,
    Expression<DateTime>? searchedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (query != null) 'query': query,
      if (searchedAt != null) 'searched_at': searchedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  RecentSearchesTableCompanion copyWith({
    Value<String>? query,
    Value<DateTime>? searchedAt,
    Value<int>? rowid,
  }) {
    return RecentSearchesTableCompanion(
      query: query ?? this.query,
      searchedAt: searchedAt ?? this.searchedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (query.present) {
      map['query'] = Variable<String>(query.value);
    }
    if (searchedAt.present) {
      map['searched_at'] = Variable<DateTime>(searchedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecentSearchesTableCompanion(')
          ..write('query: $query, ')
          ..write('searchedAt: $searchedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PlayQueueTableTable extends PlayQueueTable
    with TableInfo<$PlayQueueTableTable, PlayQueueTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlayQueueTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _currentIndexMeta = const VerificationMeta(
    'currentIndex',
  );
  @override
  late final GeneratedColumn<int> currentIndex = GeneratedColumn<int>(
    'current_index',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<ShuffleMode, String> shuffleMode =
      GeneratedColumn<String>(
        'shuffle_mode',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('off'),
      ).withConverter<ShuffleMode>($PlayQueueTableTable.$convertershuffleMode);
  @override
  late final GeneratedColumnWithTypeConverter<RepeatMode, String> repeatMode =
      GeneratedColumn<String>(
        'repeat_mode',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('off'),
      ).withConverter<RepeatMode>($PlayQueueTableTable.$converterrepeatMode);
  static const VerificationMeta _positionMsMeta = const VerificationMeta(
    'positionMs',
  );
  @override
  late final GeneratedColumn<int> positionMs = GeneratedColumn<int>(
    'position_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    currentIndex,
    shuffleMode,
    repeatMode,
    positionMs,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'play_queue';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlayQueueTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('current_index')) {
      context.handle(
        _currentIndexMeta,
        currentIndex.isAcceptableOrUnknown(
          data['current_index']!,
          _currentIndexMeta,
        ),
      );
    }
    if (data.containsKey('position_ms')) {
      context.handle(
        _positionMsMeta,
        positionMs.isAcceptableOrUnknown(data['position_ms']!, _positionMsMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PlayQueueTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlayQueueTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      currentIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}current_index'],
      ),
      shuffleMode: $PlayQueueTableTable.$convertershuffleMode.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}shuffle_mode'],
        )!,
      ),
      repeatMode: $PlayQueueTableTable.$converterrepeatMode.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}repeat_mode'],
        )!,
      ),
      positionMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position_ms'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $PlayQueueTableTable createAlias(String alias) {
    return $PlayQueueTableTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<ShuffleMode, String, String> $convertershuffleMode =
      const EnumNameConverter<ShuffleMode>(ShuffleMode.values);
  static JsonTypeConverter2<RepeatMode, String, String> $converterrepeatMode =
      const EnumNameConverter<RepeatMode>(RepeatMode.values);
}

class PlayQueueTableData extends DataClass
    implements Insertable<PlayQueueTableData> {
  final int id;
  final int? currentIndex;
  final ShuffleMode shuffleMode;
  final RepeatMode repeatMode;
  final int positionMs;
  final DateTime updatedAt;
  const PlayQueueTableData({
    required this.id,
    this.currentIndex,
    required this.shuffleMode,
    required this.repeatMode,
    required this.positionMs,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || currentIndex != null) {
      map['current_index'] = Variable<int>(currentIndex);
    }
    {
      map['shuffle_mode'] = Variable<String>(
        $PlayQueueTableTable.$convertershuffleMode.toSql(shuffleMode),
      );
    }
    {
      map['repeat_mode'] = Variable<String>(
        $PlayQueueTableTable.$converterrepeatMode.toSql(repeatMode),
      );
    }
    map['position_ms'] = Variable<int>(positionMs);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  PlayQueueTableCompanion toCompanion(bool nullToAbsent) {
    return PlayQueueTableCompanion(
      id: Value(id),
      currentIndex: currentIndex == null && nullToAbsent
          ? const Value.absent()
          : Value(currentIndex),
      shuffleMode: Value(shuffleMode),
      repeatMode: Value(repeatMode),
      positionMs: Value(positionMs),
      updatedAt: Value(updatedAt),
    );
  }

  factory PlayQueueTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlayQueueTableData(
      id: serializer.fromJson<int>(json['id']),
      currentIndex: serializer.fromJson<int?>(json['currentIndex']),
      shuffleMode: $PlayQueueTableTable.$convertershuffleMode.fromJson(
        serializer.fromJson<String>(json['shuffleMode']),
      ),
      repeatMode: $PlayQueueTableTable.$converterrepeatMode.fromJson(
        serializer.fromJson<String>(json['repeatMode']),
      ),
      positionMs: serializer.fromJson<int>(json['positionMs']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'currentIndex': serializer.toJson<int?>(currentIndex),
      'shuffleMode': serializer.toJson<String>(
        $PlayQueueTableTable.$convertershuffleMode.toJson(shuffleMode),
      ),
      'repeatMode': serializer.toJson<String>(
        $PlayQueueTableTable.$converterrepeatMode.toJson(repeatMode),
      ),
      'positionMs': serializer.toJson<int>(positionMs),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  PlayQueueTableData copyWith({
    int? id,
    Value<int?> currentIndex = const Value.absent(),
    ShuffleMode? shuffleMode,
    RepeatMode? repeatMode,
    int? positionMs,
    DateTime? updatedAt,
  }) => PlayQueueTableData(
    id: id ?? this.id,
    currentIndex: currentIndex.present ? currentIndex.value : this.currentIndex,
    shuffleMode: shuffleMode ?? this.shuffleMode,
    repeatMode: repeatMode ?? this.repeatMode,
    positionMs: positionMs ?? this.positionMs,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  PlayQueueTableData copyWithCompanion(PlayQueueTableCompanion data) {
    return PlayQueueTableData(
      id: data.id.present ? data.id.value : this.id,
      currentIndex: data.currentIndex.present
          ? data.currentIndex.value
          : this.currentIndex,
      shuffleMode: data.shuffleMode.present
          ? data.shuffleMode.value
          : this.shuffleMode,
      repeatMode: data.repeatMode.present
          ? data.repeatMode.value
          : this.repeatMode,
      positionMs: data.positionMs.present
          ? data.positionMs.value
          : this.positionMs,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlayQueueTableData(')
          ..write('id: $id, ')
          ..write('currentIndex: $currentIndex, ')
          ..write('shuffleMode: $shuffleMode, ')
          ..write('repeatMode: $repeatMode, ')
          ..write('positionMs: $positionMs, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    currentIndex,
    shuffleMode,
    repeatMode,
    positionMs,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlayQueueTableData &&
          other.id == this.id &&
          other.currentIndex == this.currentIndex &&
          other.shuffleMode == this.shuffleMode &&
          other.repeatMode == this.repeatMode &&
          other.positionMs == this.positionMs &&
          other.updatedAt == this.updatedAt);
}

class PlayQueueTableCompanion extends UpdateCompanion<PlayQueueTableData> {
  final Value<int> id;
  final Value<int?> currentIndex;
  final Value<ShuffleMode> shuffleMode;
  final Value<RepeatMode> repeatMode;
  final Value<int> positionMs;
  final Value<DateTime> updatedAt;
  const PlayQueueTableCompanion({
    this.id = const Value.absent(),
    this.currentIndex = const Value.absent(),
    this.shuffleMode = const Value.absent(),
    this.repeatMode = const Value.absent(),
    this.positionMs = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  PlayQueueTableCompanion.insert({
    this.id = const Value.absent(),
    this.currentIndex = const Value.absent(),
    this.shuffleMode = const Value.absent(),
    this.repeatMode = const Value.absent(),
    this.positionMs = const Value.absent(),
    required DateTime updatedAt,
  }) : updatedAt = Value(updatedAt);
  static Insertable<PlayQueueTableData> custom({
    Expression<int>? id,
    Expression<int>? currentIndex,
    Expression<String>? shuffleMode,
    Expression<String>? repeatMode,
    Expression<int>? positionMs,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (currentIndex != null) 'current_index': currentIndex,
      if (shuffleMode != null) 'shuffle_mode': shuffleMode,
      if (repeatMode != null) 'repeat_mode': repeatMode,
      if (positionMs != null) 'position_ms': positionMs,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  PlayQueueTableCompanion copyWith({
    Value<int>? id,
    Value<int?>? currentIndex,
    Value<ShuffleMode>? shuffleMode,
    Value<RepeatMode>? repeatMode,
    Value<int>? positionMs,
    Value<DateTime>? updatedAt,
  }) {
    return PlayQueueTableCompanion(
      id: id ?? this.id,
      currentIndex: currentIndex ?? this.currentIndex,
      shuffleMode: shuffleMode ?? this.shuffleMode,
      repeatMode: repeatMode ?? this.repeatMode,
      positionMs: positionMs ?? this.positionMs,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (currentIndex.present) {
      map['current_index'] = Variable<int>(currentIndex.value);
    }
    if (shuffleMode.present) {
      map['shuffle_mode'] = Variable<String>(
        $PlayQueueTableTable.$convertershuffleMode.toSql(shuffleMode.value),
      );
    }
    if (repeatMode.present) {
      map['repeat_mode'] = Variable<String>(
        $PlayQueueTableTable.$converterrepeatMode.toSql(repeatMode.value),
      );
    }
    if (positionMs.present) {
      map['position_ms'] = Variable<int>(positionMs.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlayQueueTableCompanion(')
          ..write('id: $id, ')
          ..write('currentIndex: $currentIndex, ')
          ..write('shuffleMode: $shuffleMode, ')
          ..write('repeatMode: $repeatMode, ')
          ..write('positionMs: $positionMs, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $PlayQueueItemsTableTable extends PlayQueueItemsTable
    with TableInfo<$PlayQueueItemsTableTable, PlayQueueItemsTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PlayQueueItemsTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _queueIdMeta = const VerificationMeta(
    'queueId',
  );
  @override
  late final GeneratedColumn<int> queueId = GeneratedColumn<int>(
    'queue_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES play_queue (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
    'song_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES songs (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [queueId, songId, sortOrder];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'play_queue_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<PlayQueueItemsTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('queue_id')) {
      context.handle(
        _queueIdMeta,
        queueId.isAcceptableOrUnknown(data['queue_id']!, _queueIdMeta),
      );
    } else if (isInserting) {
      context.missing(_queueIdMeta);
    }
    if (data.containsKey('song_id')) {
      context.handle(
        _songIdMeta,
        songId.isAcceptableOrUnknown(data['song_id']!, _songIdMeta),
      );
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    } else if (isInserting) {
      context.missing(_sortOrderMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {queueId, sortOrder};
  @override
  PlayQueueItemsTableData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PlayQueueItemsTableData(
      queueId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}queue_id'],
      )!,
      songId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}song_id'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $PlayQueueItemsTableTable createAlias(String alias) {
    return $PlayQueueItemsTableTable(attachedDatabase, alias);
  }
}

class PlayQueueItemsTableData extends DataClass
    implements Insertable<PlayQueueItemsTableData> {
  final int queueId;
  final String songId;
  final int sortOrder;
  const PlayQueueItemsTableData({
    required this.queueId,
    required this.songId,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['queue_id'] = Variable<int>(queueId);
    map['song_id'] = Variable<String>(songId);
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  PlayQueueItemsTableCompanion toCompanion(bool nullToAbsent) {
    return PlayQueueItemsTableCompanion(
      queueId: Value(queueId),
      songId: Value(songId),
      sortOrder: Value(sortOrder),
    );
  }

  factory PlayQueueItemsTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PlayQueueItemsTableData(
      queueId: serializer.fromJson<int>(json['queueId']),
      songId: serializer.fromJson<String>(json['songId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'queueId': serializer.toJson<int>(queueId),
      'songId': serializer.toJson<String>(songId),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  PlayQueueItemsTableData copyWith({
    int? queueId,
    String? songId,
    int? sortOrder,
  }) => PlayQueueItemsTableData(
    queueId: queueId ?? this.queueId,
    songId: songId ?? this.songId,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  PlayQueueItemsTableData copyWithCompanion(PlayQueueItemsTableCompanion data) {
    return PlayQueueItemsTableData(
      queueId: data.queueId.present ? data.queueId.value : this.queueId,
      songId: data.songId.present ? data.songId.value : this.songId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PlayQueueItemsTableData(')
          ..write('queueId: $queueId, ')
          ..write('songId: $songId, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(queueId, songId, sortOrder);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlayQueueItemsTableData &&
          other.queueId == this.queueId &&
          other.songId == this.songId &&
          other.sortOrder == this.sortOrder);
}

class PlayQueueItemsTableCompanion
    extends UpdateCompanion<PlayQueueItemsTableData> {
  final Value<int> queueId;
  final Value<String> songId;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const PlayQueueItemsTableCompanion({
    this.queueId = const Value.absent(),
    this.songId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PlayQueueItemsTableCompanion.insert({
    required int queueId,
    required String songId,
    required int sortOrder,
    this.rowid = const Value.absent(),
  }) : queueId = Value(queueId),
       songId = Value(songId),
       sortOrder = Value(sortOrder);
  static Insertable<PlayQueueItemsTableData> custom({
    Expression<int>? queueId,
    Expression<String>? songId,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (queueId != null) 'queue_id': queueId,
      if (songId != null) 'song_id': songId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PlayQueueItemsTableCompanion copyWith({
    Value<int>? queueId,
    Value<String>? songId,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return PlayQueueItemsTableCompanion(
      queueId: queueId ?? this.queueId,
      songId: songId ?? this.songId,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (queueId.present) {
      map['queue_id'] = Variable<int>(queueId.value);
    }
    if (songId.present) {
      map['song_id'] = Variable<String>(songId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PlayQueueItemsTableCompanion(')
          ..write('queueId: $queueId, ')
          ..write('songId: $songId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ScrobbleQueueTableTable extends ScrobbleQueueTable
    with TableInfo<$ScrobbleQueueTableTable, ScrobbleQueueTableData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ScrobbleQueueTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
    'song_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES songs (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _submissionMeta = const VerificationMeta(
    'submission',
  );
  @override
  late final GeneratedColumn<bool> submission = GeneratedColumn<bool>(
    'submission',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("submission" IN (0, 1))',
    ),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<DateTime> nextAttemptAt =
      GeneratedColumn<DateTime>(
        'next_attempt_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<DateTime> expiresAt = GeneratedColumn<DateTime>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sessionKeyMeta = const VerificationMeta(
    'sessionKey',
  );
  @override
  late final GeneratedColumn<String> sessionKey = GeneratedColumn<String>(
    'session_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    songId,
    submission,
    createdAt,
    nextAttemptAt,
    attempts,
    expiresAt,
    sessionKey,
    lastError,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'scrobble_queue';
  @override
  VerificationContext validateIntegrity(
    Insertable<ScrobbleQueueTableData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('song_id')) {
      context.handle(
        _songIdMeta,
        songId.isAcceptableOrUnknown(data['song_id']!, _songIdMeta),
      );
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('submission')) {
      context.handle(
        _submissionMeta,
        submission.isAcceptableOrUnknown(data['submission']!, _submissionMeta),
      );
    } else if (isInserting) {
      context.missing(_submissionMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_nextAttemptAtMeta);
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    if (data.containsKey('session_key')) {
      context.handle(
        _sessionKeyMeta,
        sessionKey.isAcceptableOrUnknown(data['session_key']!, _sessionKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionKeyMeta);
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {songId, submission, sessionKey},
  ];
  @override
  ScrobbleQueueTableData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ScrobbleQueueTableData(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      songId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}song_id'],
      )!,
      submission: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}submission'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}next_attempt_at'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}expires_at'],
      )!,
      sessionKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_key'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
    );
  }

  @override
  $ScrobbleQueueTableTable createAlias(String alias) {
    return $ScrobbleQueueTableTable(attachedDatabase, alias);
  }
}

class ScrobbleQueueTableData extends DataClass
    implements Insertable<ScrobbleQueueTableData> {
  final int id;
  final String songId;
  final bool submission;
  final DateTime createdAt;
  final DateTime nextAttemptAt;
  final int attempts;
  final DateTime expiresAt;
  final String sessionKey;
  final String? lastError;
  const ScrobbleQueueTableData({
    required this.id,
    required this.songId,
    required this.submission,
    required this.createdAt,
    required this.nextAttemptAt,
    required this.attempts,
    required this.expiresAt,
    required this.sessionKey,
    this.lastError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['song_id'] = Variable<String>(songId);
    map['submission'] = Variable<bool>(submission);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt);
    map['attempts'] = Variable<int>(attempts);
    map['expires_at'] = Variable<DateTime>(expiresAt);
    map['session_key'] = Variable<String>(sessionKey);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    return map;
  }

  ScrobbleQueueTableCompanion toCompanion(bool nullToAbsent) {
    return ScrobbleQueueTableCompanion(
      id: Value(id),
      songId: Value(songId),
      submission: Value(submission),
      createdAt: Value(createdAt),
      nextAttemptAt: Value(nextAttemptAt),
      attempts: Value(attempts),
      expiresAt: Value(expiresAt),
      sessionKey: Value(sessionKey),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
    );
  }

  factory ScrobbleQueueTableData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ScrobbleQueueTableData(
      id: serializer.fromJson<int>(json['id']),
      songId: serializer.fromJson<String>(json['songId']),
      submission: serializer.fromJson<bool>(json['submission']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      nextAttemptAt: serializer.fromJson<DateTime>(json['nextAttemptAt']),
      attempts: serializer.fromJson<int>(json['attempts']),
      expiresAt: serializer.fromJson<DateTime>(json['expiresAt']),
      sessionKey: serializer.fromJson<String>(json['sessionKey']),
      lastError: serializer.fromJson<String?>(json['lastError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'songId': serializer.toJson<String>(songId),
      'submission': serializer.toJson<bool>(submission),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'nextAttemptAt': serializer.toJson<DateTime>(nextAttemptAt),
      'attempts': serializer.toJson<int>(attempts),
      'expiresAt': serializer.toJson<DateTime>(expiresAt),
      'sessionKey': serializer.toJson<String>(sessionKey),
      'lastError': serializer.toJson<String?>(lastError),
    };
  }

  ScrobbleQueueTableData copyWith({
    int? id,
    String? songId,
    bool? submission,
    DateTime? createdAt,
    DateTime? nextAttemptAt,
    int? attempts,
    DateTime? expiresAt,
    String? sessionKey,
    Value<String?> lastError = const Value.absent(),
  }) => ScrobbleQueueTableData(
    id: id ?? this.id,
    songId: songId ?? this.songId,
    submission: submission ?? this.submission,
    createdAt: createdAt ?? this.createdAt,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    attempts: attempts ?? this.attempts,
    expiresAt: expiresAt ?? this.expiresAt,
    sessionKey: sessionKey ?? this.sessionKey,
    lastError: lastError.present ? lastError.value : this.lastError,
  );
  ScrobbleQueueTableData copyWithCompanion(ScrobbleQueueTableCompanion data) {
    return ScrobbleQueueTableData(
      id: data.id.present ? data.id.value : this.id,
      songId: data.songId.present ? data.songId.value : this.songId,
      submission: data.submission.present
          ? data.submission.value
          : this.submission,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      sessionKey: data.sessionKey.present
          ? data.sessionKey.value
          : this.sessionKey,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ScrobbleQueueTableData(')
          ..write('id: $id, ')
          ..write('songId: $songId, ')
          ..write('submission: $submission, ')
          ..write('createdAt: $createdAt, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('attempts: $attempts, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('sessionKey: $sessionKey, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    songId,
    submission,
    createdAt,
    nextAttemptAt,
    attempts,
    expiresAt,
    sessionKey,
    lastError,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ScrobbleQueueTableData &&
          other.id == this.id &&
          other.songId == this.songId &&
          other.submission == this.submission &&
          other.createdAt == this.createdAt &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.attempts == this.attempts &&
          other.expiresAt == this.expiresAt &&
          other.sessionKey == this.sessionKey &&
          other.lastError == this.lastError);
}

class ScrobbleQueueTableCompanion
    extends UpdateCompanion<ScrobbleQueueTableData> {
  final Value<int> id;
  final Value<String> songId;
  final Value<bool> submission;
  final Value<DateTime> createdAt;
  final Value<DateTime> nextAttemptAt;
  final Value<int> attempts;
  final Value<DateTime> expiresAt;
  final Value<String> sessionKey;
  final Value<String?> lastError;
  const ScrobbleQueueTableCompanion({
    this.id = const Value.absent(),
    this.songId = const Value.absent(),
    this.submission = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.attempts = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.sessionKey = const Value.absent(),
    this.lastError = const Value.absent(),
  });
  ScrobbleQueueTableCompanion.insert({
    this.id = const Value.absent(),
    required String songId,
    required bool submission,
    required DateTime createdAt,
    required DateTime nextAttemptAt,
    this.attempts = const Value.absent(),
    required DateTime expiresAt,
    required String sessionKey,
    this.lastError = const Value.absent(),
  }) : songId = Value(songId),
       submission = Value(submission),
       createdAt = Value(createdAt),
       nextAttemptAt = Value(nextAttemptAt),
       expiresAt = Value(expiresAt),
       sessionKey = Value(sessionKey);
  static Insertable<ScrobbleQueueTableData> custom({
    Expression<int>? id,
    Expression<String>? songId,
    Expression<bool>? submission,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? nextAttemptAt,
    Expression<int>? attempts,
    Expression<DateTime>? expiresAt,
    Expression<String>? sessionKey,
    Expression<String>? lastError,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (songId != null) 'song_id': songId,
      if (submission != null) 'submission': submission,
      if (createdAt != null) 'created_at': createdAt,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (attempts != null) 'attempts': attempts,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (sessionKey != null) 'session_key': sessionKey,
      if (lastError != null) 'last_error': lastError,
    });
  }

  ScrobbleQueueTableCompanion copyWith({
    Value<int>? id,
    Value<String>? songId,
    Value<bool>? submission,
    Value<DateTime>? createdAt,
    Value<DateTime>? nextAttemptAt,
    Value<int>? attempts,
    Value<DateTime>? expiresAt,
    Value<String>? sessionKey,
    Value<String?>? lastError,
  }) {
    return ScrobbleQueueTableCompanion(
      id: id ?? this.id,
      songId: songId ?? this.songId,
      submission: submission ?? this.submission,
      createdAt: createdAt ?? this.createdAt,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      attempts: attempts ?? this.attempts,
      expiresAt: expiresAt ?? this.expiresAt,
      sessionKey: sessionKey ?? this.sessionKey,
      lastError: lastError ?? this.lastError,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (songId.present) {
      map['song_id'] = Variable<String>(songId.value);
    }
    if (submission.present) {
      map['submission'] = Variable<bool>(submission.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<DateTime>(expiresAt.value);
    }
    if (sessionKey.present) {
      map['session_key'] = Variable<String>(sessionKey.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ScrobbleQueueTableCompanion(')
          ..write('id: $id, ')
          ..write('songId: $songId, ')
          ..write('submission: $submission, ')
          ..write('createdAt: $createdAt, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('attempts: $attempts, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('sessionKey: $sessionKey, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }
}

abstract class _$NavisDatabase extends GeneratedDatabase {
  _$NavisDatabase(QueryExecutor e) : super(e);
  $NavisDatabaseManager get managers => $NavisDatabaseManager(this);
  late final $ServerConfigTableTable serverConfigTable =
      $ServerConfigTableTable(this);
  late final $AppSettingsTableTable appSettingsTable = $AppSettingsTableTable(
    this,
  );
  late final $ArtistsTableTable artistsTable = $ArtistsTableTable(this);
  late final $AlbumsTableTable albumsTable = $AlbumsTableTable(this);
  late final $SongsTableTable songsTable = $SongsTableTable(this);
  late final $GenresTableTable genresTable = $GenresTableTable(this);
  late final $PlaylistsTableTable playlistsTable = $PlaylistsTableTable(this);
  late final $PlaylistSongsTableTable playlistSongsTable =
      $PlaylistSongsTableTable(this);
  late final $CachedTracksTableTable cachedTracksTable =
      $CachedTracksTableTable(this);
  late final $DownloadQueueTableTable downloadQueueTable =
      $DownloadQueueTableTable(this);
  late final $PlayHistoryTableTable playHistoryTable = $PlayHistoryTableTable(
    this,
  );
  late final $RecentSearchesTableTable recentSearchesTable =
      $RecentSearchesTableTable(this);
  late final $PlayQueueTableTable playQueueTable = $PlayQueueTableTable(this);
  late final $PlayQueueItemsTableTable playQueueItemsTable =
      $PlayQueueItemsTableTable(this);
  late final $ScrobbleQueueTableTable scrobbleQueueTable =
      $ScrobbleQueueTableTable(this);
  late final AppSettingsDao appSettingsDao = AppSettingsDao(
    this as NavisDatabase,
  );
  late final ServerDao serverDao = ServerDao(this as NavisDatabase);
  late final LibraryDao libraryDao = LibraryDao(this as NavisDatabase);
  late final PlaylistDao playlistDao = PlaylistDao(this as NavisDatabase);
  late final CacheDao cacheDao = CacheDao(this as NavisDatabase);
  late final DownloadQueueDao downloadQueueDao = DownloadQueueDao(
    this as NavisDatabase,
  );
  late final HistoryDao historyDao = HistoryDao(this as NavisDatabase);
  late final PlayQueueDao playQueueDao = PlayQueueDao(this as NavisDatabase);
  late final ScrobbleDao scrobbleDao = ScrobbleDao(this as NavisDatabase);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    serverConfigTable,
    appSettingsTable,
    artistsTable,
    albumsTable,
    songsTable,
    genresTable,
    playlistsTable,
    playlistSongsTable,
    cachedTracksTable,
    downloadQueueTable,
    playHistoryTable,
    recentSearchesTable,
    playQueueTable,
    playQueueItemsTable,
    scrobbleQueueTable,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'artists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('albums', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'albums',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('songs', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'artists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('songs', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'playlists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('playlist_songs', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'songs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('playlist_songs', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'songs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('cached_tracks', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'songs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('download_queue', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'albums',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('download_queue', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'playlists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('download_queue', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'songs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('play_history', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'play_queue',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('play_queue_items', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'songs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('play_queue_items', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'songs',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('scrobble_queue', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$ServerConfigTableTableCreateCompanionBuilder =
    ServerConfigTableCompanion Function({
      Value<int> id,
      Value<String?> name,
      required String url,
      required String username,
      required String apiVersion,
      Value<String?> capabilities,
      Value<DateTime?> lastSynced,
      Value<DateTime?> lastFullSynced,
    });
typedef $$ServerConfigTableTableUpdateCompanionBuilder =
    ServerConfigTableCompanion Function({
      Value<int> id,
      Value<String?> name,
      Value<String> url,
      Value<String> username,
      Value<String> apiVersion,
      Value<String?> capabilities,
      Value<DateTime?> lastSynced,
      Value<DateTime?> lastFullSynced,
    });

class $$ServerConfigTableTableFilterComposer
    extends Composer<_$NavisDatabase, $ServerConfigTableTable> {
  $$ServerConfigTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get apiVersion => $composableBuilder(
    column: $table.apiVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get capabilities => $composableBuilder(
    column: $table.capabilities,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastSynced => $composableBuilder(
    column: $table.lastSynced,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastFullSynced => $composableBuilder(
    column: $table.lastFullSynced,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ServerConfigTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $ServerConfigTableTable> {
  $$ServerConfigTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get apiVersion => $composableBuilder(
    column: $table.apiVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get capabilities => $composableBuilder(
    column: $table.capabilities,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastSynced => $composableBuilder(
    column: $table.lastSynced,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastFullSynced => $composableBuilder(
    column: $table.lastFullSynced,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ServerConfigTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $ServerConfigTableTable> {
  $$ServerConfigTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get apiVersion => $composableBuilder(
    column: $table.apiVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get capabilities => $composableBuilder(
    column: $table.capabilities,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastSynced => $composableBuilder(
    column: $table.lastSynced,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastFullSynced => $composableBuilder(
    column: $table.lastFullSynced,
    builder: (column) => column,
  );
}

class $$ServerConfigTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $ServerConfigTableTable,
          ServerConfigTableData,
          $$ServerConfigTableTableFilterComposer,
          $$ServerConfigTableTableOrderingComposer,
          $$ServerConfigTableTableAnnotationComposer,
          $$ServerConfigTableTableCreateCompanionBuilder,
          $$ServerConfigTableTableUpdateCompanionBuilder,
          (
            ServerConfigTableData,
            BaseReferences<
              _$NavisDatabase,
              $ServerConfigTableTable,
              ServerConfigTableData
            >,
          ),
          ServerConfigTableData,
          PrefetchHooks Function()
        > {
  $$ServerConfigTableTableTableManager(
    _$NavisDatabase db,
    $ServerConfigTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerConfigTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerConfigTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerConfigTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> name = const Value.absent(),
                Value<String> url = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> apiVersion = const Value.absent(),
                Value<String?> capabilities = const Value.absent(),
                Value<DateTime?> lastSynced = const Value.absent(),
                Value<DateTime?> lastFullSynced = const Value.absent(),
              }) => ServerConfigTableCompanion(
                id: id,
                name: name,
                url: url,
                username: username,
                apiVersion: apiVersion,
                capabilities: capabilities,
                lastSynced: lastSynced,
                lastFullSynced: lastFullSynced,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> name = const Value.absent(),
                required String url,
                required String username,
                required String apiVersion,
                Value<String?> capabilities = const Value.absent(),
                Value<DateTime?> lastSynced = const Value.absent(),
                Value<DateTime?> lastFullSynced = const Value.absent(),
              }) => ServerConfigTableCompanion.insert(
                id: id,
                name: name,
                url: url,
                username: username,
                apiVersion: apiVersion,
                capabilities: capabilities,
                lastSynced: lastSynced,
                lastFullSynced: lastFullSynced,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ServerConfigTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $ServerConfigTableTable,
      ServerConfigTableData,
      $$ServerConfigTableTableFilterComposer,
      $$ServerConfigTableTableOrderingComposer,
      $$ServerConfigTableTableAnnotationComposer,
      $$ServerConfigTableTableCreateCompanionBuilder,
      $$ServerConfigTableTableUpdateCompanionBuilder,
      (
        ServerConfigTableData,
        BaseReferences<
          _$NavisDatabase,
          $ServerConfigTableTable,
          ServerConfigTableData
        >,
      ),
      ServerConfigTableData,
      PrefetchHooks Function()
    >;
typedef $$AppSettingsTableTableCreateCompanionBuilder =
    AppSettingsTableCompanion Function({
      Value<int> id,
      Value<int?> wifiMaxBitRate,
      Value<String?> wifiFormat,
      Value<int?> cellularMaxBitRate,
      Value<String?> cellularFormat,
      Value<bool> scrobbleEnabled,
      Value<bool> gaplessEnabled,
      Value<bool> skipSilenceEnabled,
      required DateTime updatedAt,
    });
typedef $$AppSettingsTableTableUpdateCompanionBuilder =
    AppSettingsTableCompanion Function({
      Value<int> id,
      Value<int?> wifiMaxBitRate,
      Value<String?> wifiFormat,
      Value<int?> cellularMaxBitRate,
      Value<String?> cellularFormat,
      Value<bool> scrobbleEnabled,
      Value<bool> gaplessEnabled,
      Value<bool> skipSilenceEnabled,
      Value<DateTime> updatedAt,
    });

class $$AppSettingsTableTableFilterComposer
    extends Composer<_$NavisDatabase, $AppSettingsTableTable> {
  $$AppSettingsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get wifiMaxBitRate => $composableBuilder(
    column: $table.wifiMaxBitRate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get wifiFormat => $composableBuilder(
    column: $table.wifiFormat,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cellularMaxBitRate => $composableBuilder(
    column: $table.cellularMaxBitRate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cellularFormat => $composableBuilder(
    column: $table.cellularFormat,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get scrobbleEnabled => $composableBuilder(
    column: $table.scrobbleEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get gaplessEnabled => $composableBuilder(
    column: $table.gaplessEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get skipSilenceEnabled => $composableBuilder(
    column: $table.skipSilenceEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppSettingsTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $AppSettingsTableTable> {
  $$AppSettingsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get wifiMaxBitRate => $composableBuilder(
    column: $table.wifiMaxBitRate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get wifiFormat => $composableBuilder(
    column: $table.wifiFormat,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cellularMaxBitRate => $composableBuilder(
    column: $table.cellularMaxBitRate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cellularFormat => $composableBuilder(
    column: $table.cellularFormat,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get scrobbleEnabled => $composableBuilder(
    column: $table.scrobbleEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get gaplessEnabled => $composableBuilder(
    column: $table.gaplessEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get skipSilenceEnabled => $composableBuilder(
    column: $table.skipSilenceEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppSettingsTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $AppSettingsTableTable> {
  $$AppSettingsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get wifiMaxBitRate => $composableBuilder(
    column: $table.wifiMaxBitRate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get wifiFormat => $composableBuilder(
    column: $table.wifiFormat,
    builder: (column) => column,
  );

  GeneratedColumn<int> get cellularMaxBitRate => $composableBuilder(
    column: $table.cellularMaxBitRate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cellularFormat => $composableBuilder(
    column: $table.cellularFormat,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get scrobbleEnabled => $composableBuilder(
    column: $table.scrobbleEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get gaplessEnabled => $composableBuilder(
    column: $table.gaplessEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get skipSilenceEnabled => $composableBuilder(
    column: $table.skipSilenceEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$AppSettingsTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $AppSettingsTableTable,
          AppSettingsTableData,
          $$AppSettingsTableTableFilterComposer,
          $$AppSettingsTableTableOrderingComposer,
          $$AppSettingsTableTableAnnotationComposer,
          $$AppSettingsTableTableCreateCompanionBuilder,
          $$AppSettingsTableTableUpdateCompanionBuilder,
          (
            AppSettingsTableData,
            BaseReferences<
              _$NavisDatabase,
              $AppSettingsTableTable,
              AppSettingsTableData
            >,
          ),
          AppSettingsTableData,
          PrefetchHooks Function()
        > {
  $$AppSettingsTableTableTableManager(
    _$NavisDatabase db,
    $AppSettingsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int?> wifiMaxBitRate = const Value.absent(),
                Value<String?> wifiFormat = const Value.absent(),
                Value<int?> cellularMaxBitRate = const Value.absent(),
                Value<String?> cellularFormat = const Value.absent(),
                Value<bool> scrobbleEnabled = const Value.absent(),
                Value<bool> gaplessEnabled = const Value.absent(),
                Value<bool> skipSilenceEnabled = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => AppSettingsTableCompanion(
                id: id,
                wifiMaxBitRate: wifiMaxBitRate,
                wifiFormat: wifiFormat,
                cellularMaxBitRate: cellularMaxBitRate,
                cellularFormat: cellularFormat,
                scrobbleEnabled: scrobbleEnabled,
                gaplessEnabled: gaplessEnabled,
                skipSilenceEnabled: skipSilenceEnabled,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int?> wifiMaxBitRate = const Value.absent(),
                Value<String?> wifiFormat = const Value.absent(),
                Value<int?> cellularMaxBitRate = const Value.absent(),
                Value<String?> cellularFormat = const Value.absent(),
                Value<bool> scrobbleEnabled = const Value.absent(),
                Value<bool> gaplessEnabled = const Value.absent(),
                Value<bool> skipSilenceEnabled = const Value.absent(),
                required DateTime updatedAt,
              }) => AppSettingsTableCompanion.insert(
                id: id,
                wifiMaxBitRate: wifiMaxBitRate,
                wifiFormat: wifiFormat,
                cellularMaxBitRate: cellularMaxBitRate,
                cellularFormat: cellularFormat,
                scrobbleEnabled: scrobbleEnabled,
                gaplessEnabled: gaplessEnabled,
                skipSilenceEnabled: skipSilenceEnabled,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $AppSettingsTableTable,
      AppSettingsTableData,
      $$AppSettingsTableTableFilterComposer,
      $$AppSettingsTableTableOrderingComposer,
      $$AppSettingsTableTableAnnotationComposer,
      $$AppSettingsTableTableCreateCompanionBuilder,
      $$AppSettingsTableTableUpdateCompanionBuilder,
      (
        AppSettingsTableData,
        BaseReferences<
          _$NavisDatabase,
          $AppSettingsTableTable,
          AppSettingsTableData
        >,
      ),
      AppSettingsTableData,
      PrefetchHooks Function()
    >;
typedef $$ArtistsTableTableCreateCompanionBuilder =
    ArtistsTableCompanion Function({
      required String id,
      required String name,
      Value<int?> albumCount,
      Value<String?> coverArt,
      Value<DateTime?> starred,
      Value<int> rowid,
    });
typedef $$ArtistsTableTableUpdateCompanionBuilder =
    ArtistsTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<int?> albumCount,
      Value<String?> coverArt,
      Value<DateTime?> starred,
      Value<int> rowid,
    });

final class $$ArtistsTableTableReferences
    extends
        BaseReferences<_$NavisDatabase, $ArtistsTableTable, ArtistsTableData> {
  $$ArtistsTableTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$AlbumsTableTable, List<AlbumsTableData>>
  _albumsTableRefsTable(_$NavisDatabase db) => MultiTypedResultKey.fromTable(
    db.albumsTable,
    aliasName: $_aliasNameGenerator(
      db.artistsTable.id,
      db.albumsTable.artistId,
    ),
  );

  $$AlbumsTableTableProcessedTableManager get albumsTableRefs {
    final manager = $$AlbumsTableTableTableManager(
      $_db,
      $_db.albumsTable,
    ).filter((f) => f.artistId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_albumsTableRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SongsTableTable, List<SongsTableData>>
  _songsTableRefsTable(_$NavisDatabase db) => MultiTypedResultKey.fromTable(
    db.songsTable,
    aliasName: $_aliasNameGenerator(db.artistsTable.id, db.songsTable.artistId),
  );

  $$SongsTableTableProcessedTableManager get songsTableRefs {
    final manager = $$SongsTableTableTableManager(
      $_db,
      $_db.songsTable,
    ).filter((f) => f.artistId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_songsTableRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ArtistsTableTableFilterComposer
    extends Composer<_$NavisDatabase, $ArtistsTableTable> {
  $$ArtistsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get albumCount => $composableBuilder(
    column: $table.albumCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverArt => $composableBuilder(
    column: $table.coverArt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> albumsTableRefs(
    Expression<bool> Function($$AlbumsTableTableFilterComposer f) f,
  ) {
    final $$AlbumsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.albumsTable,
      getReferencedColumn: (t) => t.artistId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AlbumsTableTableFilterComposer(
            $db: $db,
            $table: $db.albumsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> songsTableRefs(
    Expression<bool> Function($$SongsTableTableFilterComposer f) f,
  ) {
    final $$SongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.artistId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableFilterComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ArtistsTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $ArtistsTableTable> {
  $$ArtistsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get albumCount => $composableBuilder(
    column: $table.albumCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverArt => $composableBuilder(
    column: $table.coverArt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ArtistsTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $ArtistsTableTable> {
  $$ArtistsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get albumCount => $composableBuilder(
    column: $table.albumCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get coverArt =>
      $composableBuilder(column: $table.coverArt, builder: (column) => column);

  GeneratedColumn<DateTime> get starred =>
      $composableBuilder(column: $table.starred, builder: (column) => column);

  Expression<T> albumsTableRefs<T extends Object>(
    Expression<T> Function($$AlbumsTableTableAnnotationComposer a) f,
  ) {
    final $$AlbumsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.albumsTable,
      getReferencedColumn: (t) => t.artistId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AlbumsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.albumsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> songsTableRefs<T extends Object>(
    Expression<T> Function($$SongsTableTableAnnotationComposer a) f,
  ) {
    final $$SongsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.artistId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ArtistsTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $ArtistsTableTable,
          ArtistsTableData,
          $$ArtistsTableTableFilterComposer,
          $$ArtistsTableTableOrderingComposer,
          $$ArtistsTableTableAnnotationComposer,
          $$ArtistsTableTableCreateCompanionBuilder,
          $$ArtistsTableTableUpdateCompanionBuilder,
          (ArtistsTableData, $$ArtistsTableTableReferences),
          ArtistsTableData,
          PrefetchHooks Function({bool albumsTableRefs, bool songsTableRefs})
        > {
  $$ArtistsTableTableTableManager(_$NavisDatabase db, $ArtistsTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ArtistsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ArtistsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ArtistsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int?> albumCount = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<DateTime?> starred = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ArtistsTableCompanion(
                id: id,
                name: name,
                albumCount: albumCount,
                coverArt: coverArt,
                starred: starred,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<int?> albumCount = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<DateTime?> starred = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ArtistsTableCompanion.insert(
                id: id,
                name: name,
                albumCount: albumCount,
                coverArt: coverArt,
                starred: starred,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ArtistsTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({albumsTableRefs = false, songsTableRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (albumsTableRefs) db.albumsTable,
                    if (songsTableRefs) db.songsTable,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (albumsTableRefs)
                        await $_getPrefetchedData<
                          ArtistsTableData,
                          $ArtistsTableTable,
                          AlbumsTableData
                        >(
                          currentTable: table,
                          referencedTable: $$ArtistsTableTableReferences
                              ._albumsTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ArtistsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).albumsTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.artistId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (songsTableRefs)
                        await $_getPrefetchedData<
                          ArtistsTableData,
                          $ArtistsTableTable,
                          SongsTableData
                        >(
                          currentTable: table,
                          referencedTable: $$ArtistsTableTableReferences
                              ._songsTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$ArtistsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).songsTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.artistId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$ArtistsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $ArtistsTableTable,
      ArtistsTableData,
      $$ArtistsTableTableFilterComposer,
      $$ArtistsTableTableOrderingComposer,
      $$ArtistsTableTableAnnotationComposer,
      $$ArtistsTableTableCreateCompanionBuilder,
      $$ArtistsTableTableUpdateCompanionBuilder,
      (ArtistsTableData, $$ArtistsTableTableReferences),
      ArtistsTableData,
      PrefetchHooks Function({bool albumsTableRefs, bool songsTableRefs})
    >;
typedef $$AlbumsTableTableCreateCompanionBuilder =
    AlbumsTableCompanion Function({
      required String id,
      required String name,
      Value<String?> artistId,
      Value<String?> artistName,
      Value<int?> songCount,
      Value<int?> duration,
      Value<int?> year,
      Value<String?> genre,
      Value<String?> coverArt,
      Value<bool> songsHydrated,
      Value<DateTime?> starred,
      Value<int?> playCount,
      Value<int> rowid,
    });
typedef $$AlbumsTableTableUpdateCompanionBuilder =
    AlbumsTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String?> artistId,
      Value<String?> artistName,
      Value<int?> songCount,
      Value<int?> duration,
      Value<int?> year,
      Value<String?> genre,
      Value<String?> coverArt,
      Value<bool> songsHydrated,
      Value<DateTime?> starred,
      Value<int?> playCount,
      Value<int> rowid,
    });

final class $$AlbumsTableTableReferences
    extends
        BaseReferences<_$NavisDatabase, $AlbumsTableTable, AlbumsTableData> {
  $$AlbumsTableTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ArtistsTableTable _artistIdTable(_$NavisDatabase db) =>
      db.artistsTable.createAlias(
        $_aliasNameGenerator(db.albumsTable.artistId, db.artistsTable.id),
      );

  $$ArtistsTableTableProcessedTableManager? get artistId {
    final $_column = $_itemColumn<String>('artist_id');
    if ($_column == null) return null;
    final manager = $$ArtistsTableTableTableManager(
      $_db,
      $_db.artistsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_artistIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$SongsTableTable, List<SongsTableData>>
  _songsTableRefsTable(_$NavisDatabase db) => MultiTypedResultKey.fromTable(
    db.songsTable,
    aliasName: $_aliasNameGenerator(db.albumsTable.id, db.songsTable.albumId),
  );

  $$SongsTableTableProcessedTableManager get songsTableRefs {
    final manager = $$SongsTableTableTableManager(
      $_db,
      $_db.songsTable,
    ).filter((f) => f.albumId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_songsTableRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $DownloadQueueTableTable,
    List<DownloadQueueTableData>
  >
  _downloadQueueTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.downloadQueueTable,
        aliasName: $_aliasNameGenerator(
          db.albumsTable.id,
          db.downloadQueueTable.albumId,
        ),
      );

  $$DownloadQueueTableTableProcessedTableManager get downloadQueueTableRefs {
    final manager = $$DownloadQueueTableTableTableManager(
      $_db,
      $_db.downloadQueueTable,
    ).filter((f) => f.albumId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _downloadQueueTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$AlbumsTableTableFilterComposer
    extends Composer<_$NavisDatabase, $AlbumsTableTable> {
  $$AlbumsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get artistName => $composableBuilder(
    column: $table.artistName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get songCount => $composableBuilder(
    column: $table.songCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get genre => $composableBuilder(
    column: $table.genre,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverArt => $composableBuilder(
    column: $table.coverArt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get songsHydrated => $composableBuilder(
    column: $table.songsHydrated,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get playCount => $composableBuilder(
    column: $table.playCount,
    builder: (column) => ColumnFilters(column),
  );

  $$ArtistsTableTableFilterComposer get artistId {
    final $$ArtistsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.artistId,
      referencedTable: $db.artistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ArtistsTableTableFilterComposer(
            $db: $db,
            $table: $db.artistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> songsTableRefs(
    Expression<bool> Function($$SongsTableTableFilterComposer f) f,
  ) {
    final $$SongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.albumId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableFilterComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> downloadQueueTableRefs(
    Expression<bool> Function($$DownloadQueueTableTableFilterComposer f) f,
  ) {
    final $$DownloadQueueTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.downloadQueueTable,
      getReferencedColumn: (t) => t.albumId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$DownloadQueueTableTableFilterComposer(
            $db: $db,
            $table: $db.downloadQueueTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$AlbumsTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $AlbumsTableTable> {
  $$AlbumsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get artistName => $composableBuilder(
    column: $table.artistName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get songCount => $composableBuilder(
    column: $table.songCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get genre => $composableBuilder(
    column: $table.genre,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverArt => $composableBuilder(
    column: $table.coverArt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get songsHydrated => $composableBuilder(
    column: $table.songsHydrated,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get playCount => $composableBuilder(
    column: $table.playCount,
    builder: (column) => ColumnOrderings(column),
  );

  $$ArtistsTableTableOrderingComposer get artistId {
    final $$ArtistsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.artistId,
      referencedTable: $db.artistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ArtistsTableTableOrderingComposer(
            $db: $db,
            $table: $db.artistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$AlbumsTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $AlbumsTableTable> {
  $$AlbumsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get artistName => $composableBuilder(
    column: $table.artistName,
    builder: (column) => column,
  );

  GeneratedColumn<int> get songCount =>
      $composableBuilder(column: $table.songCount, builder: (column) => column);

  GeneratedColumn<int> get duration =>
      $composableBuilder(column: $table.duration, builder: (column) => column);

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<String> get genre =>
      $composableBuilder(column: $table.genre, builder: (column) => column);

  GeneratedColumn<String> get coverArt =>
      $composableBuilder(column: $table.coverArt, builder: (column) => column);

  GeneratedColumn<bool> get songsHydrated => $composableBuilder(
    column: $table.songsHydrated,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get starred =>
      $composableBuilder(column: $table.starred, builder: (column) => column);

  GeneratedColumn<int> get playCount =>
      $composableBuilder(column: $table.playCount, builder: (column) => column);

  $$ArtistsTableTableAnnotationComposer get artistId {
    final $$ArtistsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.artistId,
      referencedTable: $db.artistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ArtistsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.artistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> songsTableRefs<T extends Object>(
    Expression<T> Function($$SongsTableTableAnnotationComposer a) f,
  ) {
    final $$SongsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.albumId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> downloadQueueTableRefs<T extends Object>(
    Expression<T> Function($$DownloadQueueTableTableAnnotationComposer a) f,
  ) {
    final $$DownloadQueueTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.downloadQueueTable,
          getReferencedColumn: (t) => t.albumId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$DownloadQueueTableTableAnnotationComposer(
                $db: $db,
                $table: $db.downloadQueueTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$AlbumsTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $AlbumsTableTable,
          AlbumsTableData,
          $$AlbumsTableTableFilterComposer,
          $$AlbumsTableTableOrderingComposer,
          $$AlbumsTableTableAnnotationComposer,
          $$AlbumsTableTableCreateCompanionBuilder,
          $$AlbumsTableTableUpdateCompanionBuilder,
          (AlbumsTableData, $$AlbumsTableTableReferences),
          AlbumsTableData,
          PrefetchHooks Function({
            bool artistId,
            bool songsTableRefs,
            bool downloadQueueTableRefs,
          })
        > {
  $$AlbumsTableTableTableManager(_$NavisDatabase db, $AlbumsTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AlbumsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AlbumsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AlbumsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> artistId = const Value.absent(),
                Value<String?> artistName = const Value.absent(),
                Value<int?> songCount = const Value.absent(),
                Value<int?> duration = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> genre = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<bool> songsHydrated = const Value.absent(),
                Value<DateTime?> starred = const Value.absent(),
                Value<int?> playCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AlbumsTableCompanion(
                id: id,
                name: name,
                artistId: artistId,
                artistName: artistName,
                songCount: songCount,
                duration: duration,
                year: year,
                genre: genre,
                coverArt: coverArt,
                songsHydrated: songsHydrated,
                starred: starred,
                playCount: playCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String?> artistId = const Value.absent(),
                Value<String?> artistName = const Value.absent(),
                Value<int?> songCount = const Value.absent(),
                Value<int?> duration = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> genre = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<bool> songsHydrated = const Value.absent(),
                Value<DateTime?> starred = const Value.absent(),
                Value<int?> playCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AlbumsTableCompanion.insert(
                id: id,
                name: name,
                artistId: artistId,
                artistName: artistName,
                songCount: songCount,
                duration: duration,
                year: year,
                genre: genre,
                coverArt: coverArt,
                songsHydrated: songsHydrated,
                starred: starred,
                playCount: playCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$AlbumsTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                artistId = false,
                songsTableRefs = false,
                downloadQueueTableRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (songsTableRefs) db.songsTable,
                    if (downloadQueueTableRefs) db.downloadQueueTable,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (artistId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.artistId,
                                    referencedTable:
                                        $$AlbumsTableTableReferences
                                            ._artistIdTable(db),
                                    referencedColumn:
                                        $$AlbumsTableTableReferences
                                            ._artistIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (songsTableRefs)
                        await $_getPrefetchedData<
                          AlbumsTableData,
                          $AlbumsTableTable,
                          SongsTableData
                        >(
                          currentTable: table,
                          referencedTable: $$AlbumsTableTableReferences
                              ._songsTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AlbumsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).songsTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.albumId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (downloadQueueTableRefs)
                        await $_getPrefetchedData<
                          AlbumsTableData,
                          $AlbumsTableTable,
                          DownloadQueueTableData
                        >(
                          currentTable: table,
                          referencedTable: $$AlbumsTableTableReferences
                              ._downloadQueueTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$AlbumsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).downloadQueueTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.albumId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$AlbumsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $AlbumsTableTable,
      AlbumsTableData,
      $$AlbumsTableTableFilterComposer,
      $$AlbumsTableTableOrderingComposer,
      $$AlbumsTableTableAnnotationComposer,
      $$AlbumsTableTableCreateCompanionBuilder,
      $$AlbumsTableTableUpdateCompanionBuilder,
      (AlbumsTableData, $$AlbumsTableTableReferences),
      AlbumsTableData,
      PrefetchHooks Function({
        bool artistId,
        bool songsTableRefs,
        bool downloadQueueTableRefs,
      })
    >;
typedef $$SongsTableTableCreateCompanionBuilder =
    SongsTableCompanion Function({
      required String id,
      required String title,
      Value<String?> albumId,
      Value<String?> artistId,
      Value<String?> artistName,
      Value<String?> albumName,
      Value<int?> track,
      Value<int?> discNumber,
      Value<int?> duration,
      Value<int?> bitRate,
      Value<String?> contentType,
      Value<String?> suffix,
      Value<int?> size,
      Value<String?> coverArt,
      Value<DateTime?> starred,
      Value<int?> playCount,
      Value<DateTime?> createdAt,
      Value<int> rowid,
    });
typedef $$SongsTableTableUpdateCompanionBuilder =
    SongsTableCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String?> albumId,
      Value<String?> artistId,
      Value<String?> artistName,
      Value<String?> albumName,
      Value<int?> track,
      Value<int?> discNumber,
      Value<int?> duration,
      Value<int?> bitRate,
      Value<String?> contentType,
      Value<String?> suffix,
      Value<int?> size,
      Value<String?> coverArt,
      Value<DateTime?> starred,
      Value<int?> playCount,
      Value<DateTime?> createdAt,
      Value<int> rowid,
    });

final class $$SongsTableTableReferences
    extends BaseReferences<_$NavisDatabase, $SongsTableTable, SongsTableData> {
  $$SongsTableTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $AlbumsTableTable _albumIdTable(_$NavisDatabase db) =>
      db.albumsTable.createAlias(
        $_aliasNameGenerator(db.songsTable.albumId, db.albumsTable.id),
      );

  $$AlbumsTableTableProcessedTableManager? get albumId {
    final $_column = $_itemColumn<String>('album_id');
    if ($_column == null) return null;
    final manager = $$AlbumsTableTableTableManager(
      $_db,
      $_db.albumsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_albumIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $ArtistsTableTable _artistIdTable(_$NavisDatabase db) =>
      db.artistsTable.createAlias(
        $_aliasNameGenerator(db.songsTable.artistId, db.artistsTable.id),
      );

  $$ArtistsTableTableProcessedTableManager? get artistId {
    final $_column = $_itemColumn<String>('artist_id');
    if ($_column == null) return null;
    final manager = $$ArtistsTableTableTableManager(
      $_db,
      $_db.artistsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_artistIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<
    $PlaylistSongsTableTable,
    List<PlaylistSongsTableData>
  >
  _playlistSongsTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.playlistSongsTable,
        aliasName: $_aliasNameGenerator(
          db.songsTable.id,
          db.playlistSongsTable.songId,
        ),
      );

  $$PlaylistSongsTableTableProcessedTableManager get playlistSongsTableRefs {
    final manager = $$PlaylistSongsTableTableTableManager(
      $_db,
      $_db.playlistSongsTable,
    ).filter((f) => f.songId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _playlistSongsTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $CachedTracksTableTable,
    List<CachedTracksTableData>
  >
  _cachedTracksTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.cachedTracksTable,
        aliasName: $_aliasNameGenerator(
          db.songsTable.id,
          db.cachedTracksTable.songId,
        ),
      );

  $$CachedTracksTableTableProcessedTableManager get cachedTracksTableRefs {
    final manager = $$CachedTracksTableTableTableManager(
      $_db,
      $_db.cachedTracksTable,
    ).filter((f) => f.songId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _cachedTracksTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $DownloadQueueTableTable,
    List<DownloadQueueTableData>
  >
  _downloadQueueTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.downloadQueueTable,
        aliasName: $_aliasNameGenerator(
          db.songsTable.id,
          db.downloadQueueTable.songId,
        ),
      );

  $$DownloadQueueTableTableProcessedTableManager get downloadQueueTableRefs {
    final manager = $$DownloadQueueTableTableTableManager(
      $_db,
      $_db.downloadQueueTable,
    ).filter((f) => f.songId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _downloadQueueTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$PlayHistoryTableTable, List<PlayHistoryTableData>>
  _playHistoryTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.playHistoryTable,
        aliasName: $_aliasNameGenerator(
          db.songsTable.id,
          db.playHistoryTable.songId,
        ),
      );

  $$PlayHistoryTableTableProcessedTableManager get playHistoryTableRefs {
    final manager = $$PlayHistoryTableTableTableManager(
      $_db,
      $_db.playHistoryTable,
    ).filter((f) => f.songId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _playHistoryTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $PlayQueueItemsTableTable,
    List<PlayQueueItemsTableData>
  >
  _playQueueItemsTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.playQueueItemsTable,
        aliasName: $_aliasNameGenerator(
          db.songsTable.id,
          db.playQueueItemsTable.songId,
        ),
      );

  $$PlayQueueItemsTableTableProcessedTableManager get playQueueItemsTableRefs {
    final manager = $$PlayQueueItemsTableTableTableManager(
      $_db,
      $_db.playQueueItemsTable,
    ).filter((f) => f.songId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _playQueueItemsTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $ScrobbleQueueTableTable,
    List<ScrobbleQueueTableData>
  >
  _scrobbleQueueTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.scrobbleQueueTable,
        aliasName: $_aliasNameGenerator(
          db.songsTable.id,
          db.scrobbleQueueTable.songId,
        ),
      );

  $$ScrobbleQueueTableTableProcessedTableManager get scrobbleQueueTableRefs {
    final manager = $$ScrobbleQueueTableTableTableManager(
      $_db,
      $_db.scrobbleQueueTable,
    ).filter((f) => f.songId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _scrobbleQueueTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SongsTableTableFilterComposer
    extends Composer<_$NavisDatabase, $SongsTableTable> {
  $$SongsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get artistName => $composableBuilder(
    column: $table.artistName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get albumName => $composableBuilder(
    column: $table.albumName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get track => $composableBuilder(
    column: $table.track,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get discNumber => $composableBuilder(
    column: $table.discNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bitRate => $composableBuilder(
    column: $table.bitRate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get suffix => $composableBuilder(
    column: $table.suffix,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverArt => $composableBuilder(
    column: $table.coverArt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get playCount => $composableBuilder(
    column: $table.playCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$AlbumsTableTableFilterComposer get albumId {
    final $$AlbumsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.albumId,
      referencedTable: $db.albumsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AlbumsTableTableFilterComposer(
            $db: $db,
            $table: $db.albumsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ArtistsTableTableFilterComposer get artistId {
    final $$ArtistsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.artistId,
      referencedTable: $db.artistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ArtistsTableTableFilterComposer(
            $db: $db,
            $table: $db.artistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> playlistSongsTableRefs(
    Expression<bool> Function($$PlaylistSongsTableTableFilterComposer f) f,
  ) {
    final $$PlaylistSongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playlistSongsTable,
      getReferencedColumn: (t) => t.songId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistSongsTableTableFilterComposer(
            $db: $db,
            $table: $db.playlistSongsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> cachedTracksTableRefs(
    Expression<bool> Function($$CachedTracksTableTableFilterComposer f) f,
  ) {
    final $$CachedTracksTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.cachedTracksTable,
      getReferencedColumn: (t) => t.songId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$CachedTracksTableTableFilterComposer(
            $db: $db,
            $table: $db.cachedTracksTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> downloadQueueTableRefs(
    Expression<bool> Function($$DownloadQueueTableTableFilterComposer f) f,
  ) {
    final $$DownloadQueueTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.downloadQueueTable,
      getReferencedColumn: (t) => t.songId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$DownloadQueueTableTableFilterComposer(
            $db: $db,
            $table: $db.downloadQueueTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> playHistoryTableRefs(
    Expression<bool> Function($$PlayHistoryTableTableFilterComposer f) f,
  ) {
    final $$PlayHistoryTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playHistoryTable,
      getReferencedColumn: (t) => t.songId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlayHistoryTableTableFilterComposer(
            $db: $db,
            $table: $db.playHistoryTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> playQueueItemsTableRefs(
    Expression<bool> Function($$PlayQueueItemsTableTableFilterComposer f) f,
  ) {
    final $$PlayQueueItemsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playQueueItemsTable,
      getReferencedColumn: (t) => t.songId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlayQueueItemsTableTableFilterComposer(
            $db: $db,
            $table: $db.playQueueItemsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> scrobbleQueueTableRefs(
    Expression<bool> Function($$ScrobbleQueueTableTableFilterComposer f) f,
  ) {
    final $$ScrobbleQueueTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.scrobbleQueueTable,
      getReferencedColumn: (t) => t.songId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ScrobbleQueueTableTableFilterComposer(
            $db: $db,
            $table: $db.scrobbleQueueTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SongsTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $SongsTableTable> {
  $$SongsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get artistName => $composableBuilder(
    column: $table.artistName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get albumName => $composableBuilder(
    column: $table.albumName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get track => $composableBuilder(
    column: $table.track,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get discNumber => $composableBuilder(
    column: $table.discNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bitRate => $composableBuilder(
    column: $table.bitRate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get suffix => $composableBuilder(
    column: $table.suffix,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverArt => $composableBuilder(
    column: $table.coverArt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get playCount => $composableBuilder(
    column: $table.playCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$AlbumsTableTableOrderingComposer get albumId {
    final $$AlbumsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.albumId,
      referencedTable: $db.albumsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AlbumsTableTableOrderingComposer(
            $db: $db,
            $table: $db.albumsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ArtistsTableTableOrderingComposer get artistId {
    final $$ArtistsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.artistId,
      referencedTable: $db.artistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ArtistsTableTableOrderingComposer(
            $db: $db,
            $table: $db.artistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SongsTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $SongsTableTable> {
  $$SongsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artistName => $composableBuilder(
    column: $table.artistName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get albumName =>
      $composableBuilder(column: $table.albumName, builder: (column) => column);

  GeneratedColumn<int> get track =>
      $composableBuilder(column: $table.track, builder: (column) => column);

  GeneratedColumn<int> get discNumber => $composableBuilder(
    column: $table.discNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get duration =>
      $composableBuilder(column: $table.duration, builder: (column) => column);

  GeneratedColumn<int> get bitRate =>
      $composableBuilder(column: $table.bitRate, builder: (column) => column);

  GeneratedColumn<String> get contentType => $composableBuilder(
    column: $table.contentType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get suffix =>
      $composableBuilder(column: $table.suffix, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<String> get coverArt =>
      $composableBuilder(column: $table.coverArt, builder: (column) => column);

  GeneratedColumn<DateTime> get starred =>
      $composableBuilder(column: $table.starred, builder: (column) => column);

  GeneratedColumn<int> get playCount =>
      $composableBuilder(column: $table.playCount, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$AlbumsTableTableAnnotationComposer get albumId {
    final $$AlbumsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.albumId,
      referencedTable: $db.albumsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AlbumsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.albumsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$ArtistsTableTableAnnotationComposer get artistId {
    final $$ArtistsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.artistId,
      referencedTable: $db.artistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ArtistsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.artistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> playlistSongsTableRefs<T extends Object>(
    Expression<T> Function($$PlaylistSongsTableTableAnnotationComposer a) f,
  ) {
    final $$PlaylistSongsTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.playlistSongsTable,
          getReferencedColumn: (t) => t.songId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$PlaylistSongsTableTableAnnotationComposer(
                $db: $db,
                $table: $db.playlistSongsTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> cachedTracksTableRefs<T extends Object>(
    Expression<T> Function($$CachedTracksTableTableAnnotationComposer a) f,
  ) {
    final $$CachedTracksTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.cachedTracksTable,
          getReferencedColumn: (t) => t.songId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$CachedTracksTableTableAnnotationComposer(
                $db: $db,
                $table: $db.cachedTracksTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> downloadQueueTableRefs<T extends Object>(
    Expression<T> Function($$DownloadQueueTableTableAnnotationComposer a) f,
  ) {
    final $$DownloadQueueTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.downloadQueueTable,
          getReferencedColumn: (t) => t.songId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$DownloadQueueTableTableAnnotationComposer(
                $db: $db,
                $table: $db.downloadQueueTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> playHistoryTableRefs<T extends Object>(
    Expression<T> Function($$PlayHistoryTableTableAnnotationComposer a) f,
  ) {
    final $$PlayHistoryTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playHistoryTable,
      getReferencedColumn: (t) => t.songId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlayHistoryTableTableAnnotationComposer(
            $db: $db,
            $table: $db.playHistoryTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> playQueueItemsTableRefs<T extends Object>(
    Expression<T> Function($$PlayQueueItemsTableTableAnnotationComposer a) f,
  ) {
    final $$PlayQueueItemsTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.playQueueItemsTable,
          getReferencedColumn: (t) => t.songId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$PlayQueueItemsTableTableAnnotationComposer(
                $db: $db,
                $table: $db.playQueueItemsTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> scrobbleQueueTableRefs<T extends Object>(
    Expression<T> Function($$ScrobbleQueueTableTableAnnotationComposer a) f,
  ) {
    final $$ScrobbleQueueTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.scrobbleQueueTable,
          getReferencedColumn: (t) => t.songId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ScrobbleQueueTableTableAnnotationComposer(
                $db: $db,
                $table: $db.scrobbleQueueTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$SongsTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $SongsTableTable,
          SongsTableData,
          $$SongsTableTableFilterComposer,
          $$SongsTableTableOrderingComposer,
          $$SongsTableTableAnnotationComposer,
          $$SongsTableTableCreateCompanionBuilder,
          $$SongsTableTableUpdateCompanionBuilder,
          (SongsTableData, $$SongsTableTableReferences),
          SongsTableData,
          PrefetchHooks Function({
            bool albumId,
            bool artistId,
            bool playlistSongsTableRefs,
            bool cachedTracksTableRefs,
            bool downloadQueueTableRefs,
            bool playHistoryTableRefs,
            bool playQueueItemsTableRefs,
            bool scrobbleQueueTableRefs,
          })
        > {
  $$SongsTableTableTableManager(_$NavisDatabase db, $SongsTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SongsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SongsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SongsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> albumId = const Value.absent(),
                Value<String?> artistId = const Value.absent(),
                Value<String?> artistName = const Value.absent(),
                Value<String?> albumName = const Value.absent(),
                Value<int?> track = const Value.absent(),
                Value<int?> discNumber = const Value.absent(),
                Value<int?> duration = const Value.absent(),
                Value<int?> bitRate = const Value.absent(),
                Value<String?> contentType = const Value.absent(),
                Value<String?> suffix = const Value.absent(),
                Value<int?> size = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<DateTime?> starred = const Value.absent(),
                Value<int?> playCount = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SongsTableCompanion(
                id: id,
                title: title,
                albumId: albumId,
                artistId: artistId,
                artistName: artistName,
                albumName: albumName,
                track: track,
                discNumber: discNumber,
                duration: duration,
                bitRate: bitRate,
                contentType: contentType,
                suffix: suffix,
                size: size,
                coverArt: coverArt,
                starred: starred,
                playCount: playCount,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                Value<String?> albumId = const Value.absent(),
                Value<String?> artistId = const Value.absent(),
                Value<String?> artistName = const Value.absent(),
                Value<String?> albumName = const Value.absent(),
                Value<int?> track = const Value.absent(),
                Value<int?> discNumber = const Value.absent(),
                Value<int?> duration = const Value.absent(),
                Value<int?> bitRate = const Value.absent(),
                Value<String?> contentType = const Value.absent(),
                Value<String?> suffix = const Value.absent(),
                Value<int?> size = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<DateTime?> starred = const Value.absent(),
                Value<int?> playCount = const Value.absent(),
                Value<DateTime?> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SongsTableCompanion.insert(
                id: id,
                title: title,
                albumId: albumId,
                artistId: artistId,
                artistName: artistName,
                albumName: albumName,
                track: track,
                discNumber: discNumber,
                duration: duration,
                bitRate: bitRate,
                contentType: contentType,
                suffix: suffix,
                size: size,
                coverArt: coverArt,
                starred: starred,
                playCount: playCount,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SongsTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                albumId = false,
                artistId = false,
                playlistSongsTableRefs = false,
                cachedTracksTableRefs = false,
                downloadQueueTableRefs = false,
                playHistoryTableRefs = false,
                playQueueItemsTableRefs = false,
                scrobbleQueueTableRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (playlistSongsTableRefs) db.playlistSongsTable,
                    if (cachedTracksTableRefs) db.cachedTracksTable,
                    if (downloadQueueTableRefs) db.downloadQueueTable,
                    if (playHistoryTableRefs) db.playHistoryTable,
                    if (playQueueItemsTableRefs) db.playQueueItemsTable,
                    if (scrobbleQueueTableRefs) db.scrobbleQueueTable,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (albumId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.albumId,
                                    referencedTable: $$SongsTableTableReferences
                                        ._albumIdTable(db),
                                    referencedColumn:
                                        $$SongsTableTableReferences
                                            ._albumIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (artistId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.artistId,
                                    referencedTable: $$SongsTableTableReferences
                                        ._artistIdTable(db),
                                    referencedColumn:
                                        $$SongsTableTableReferences
                                            ._artistIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (playlistSongsTableRefs)
                        await $_getPrefetchedData<
                          SongsTableData,
                          $SongsTableTable,
                          PlaylistSongsTableData
                        >(
                          currentTable: table,
                          referencedTable: $$SongsTableTableReferences
                              ._playlistSongsTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SongsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).playlistSongsTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.songId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (cachedTracksTableRefs)
                        await $_getPrefetchedData<
                          SongsTableData,
                          $SongsTableTable,
                          CachedTracksTableData
                        >(
                          currentTable: table,
                          referencedTable: $$SongsTableTableReferences
                              ._cachedTracksTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SongsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).cachedTracksTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.songId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (downloadQueueTableRefs)
                        await $_getPrefetchedData<
                          SongsTableData,
                          $SongsTableTable,
                          DownloadQueueTableData
                        >(
                          currentTable: table,
                          referencedTable: $$SongsTableTableReferences
                              ._downloadQueueTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SongsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).downloadQueueTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.songId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (playHistoryTableRefs)
                        await $_getPrefetchedData<
                          SongsTableData,
                          $SongsTableTable,
                          PlayHistoryTableData
                        >(
                          currentTable: table,
                          referencedTable: $$SongsTableTableReferences
                              ._playHistoryTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SongsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).playHistoryTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.songId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (playQueueItemsTableRefs)
                        await $_getPrefetchedData<
                          SongsTableData,
                          $SongsTableTable,
                          PlayQueueItemsTableData
                        >(
                          currentTable: table,
                          referencedTable: $$SongsTableTableReferences
                              ._playQueueItemsTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SongsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).playQueueItemsTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.songId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (scrobbleQueueTableRefs)
                        await $_getPrefetchedData<
                          SongsTableData,
                          $SongsTableTable,
                          ScrobbleQueueTableData
                        >(
                          currentTable: table,
                          referencedTable: $$SongsTableTableReferences
                              ._scrobbleQueueTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SongsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).scrobbleQueueTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.songId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$SongsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $SongsTableTable,
      SongsTableData,
      $$SongsTableTableFilterComposer,
      $$SongsTableTableOrderingComposer,
      $$SongsTableTableAnnotationComposer,
      $$SongsTableTableCreateCompanionBuilder,
      $$SongsTableTableUpdateCompanionBuilder,
      (SongsTableData, $$SongsTableTableReferences),
      SongsTableData,
      PrefetchHooks Function({
        bool albumId,
        bool artistId,
        bool playlistSongsTableRefs,
        bool cachedTracksTableRefs,
        bool downloadQueueTableRefs,
        bool playHistoryTableRefs,
        bool playQueueItemsTableRefs,
        bool scrobbleQueueTableRefs,
      })
    >;
typedef $$GenresTableTableCreateCompanionBuilder =
    GenresTableCompanion Function({
      required String name,
      Value<int?> songCount,
      Value<int?> albumCount,
      Value<int> rowid,
    });
typedef $$GenresTableTableUpdateCompanionBuilder =
    GenresTableCompanion Function({
      Value<String> name,
      Value<int?> songCount,
      Value<int?> albumCount,
      Value<int> rowid,
    });

class $$GenresTableTableFilterComposer
    extends Composer<_$NavisDatabase, $GenresTableTable> {
  $$GenresTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get songCount => $composableBuilder(
    column: $table.songCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get albumCount => $composableBuilder(
    column: $table.albumCount,
    builder: (column) => ColumnFilters(column),
  );
}

class $$GenresTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $GenresTableTable> {
  $$GenresTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get songCount => $composableBuilder(
    column: $table.songCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get albumCount => $composableBuilder(
    column: $table.albumCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$GenresTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $GenresTableTable> {
  $$GenresTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get songCount =>
      $composableBuilder(column: $table.songCount, builder: (column) => column);

  GeneratedColumn<int> get albumCount => $composableBuilder(
    column: $table.albumCount,
    builder: (column) => column,
  );
}

class $$GenresTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $GenresTableTable,
          GenresTableData,
          $$GenresTableTableFilterComposer,
          $$GenresTableTableOrderingComposer,
          $$GenresTableTableAnnotationComposer,
          $$GenresTableTableCreateCompanionBuilder,
          $$GenresTableTableUpdateCompanionBuilder,
          (
            GenresTableData,
            BaseReferences<_$NavisDatabase, $GenresTableTable, GenresTableData>,
          ),
          GenresTableData,
          PrefetchHooks Function()
        > {
  $$GenresTableTableTableManager(_$NavisDatabase db, $GenresTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GenresTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GenresTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GenresTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> name = const Value.absent(),
                Value<int?> songCount = const Value.absent(),
                Value<int?> albumCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GenresTableCompanion(
                name: name,
                songCount: songCount,
                albumCount: albumCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String name,
                Value<int?> songCount = const Value.absent(),
                Value<int?> albumCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GenresTableCompanion.insert(
                name: name,
                songCount: songCount,
                albumCount: albumCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$GenresTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $GenresTableTable,
      GenresTableData,
      $$GenresTableTableFilterComposer,
      $$GenresTableTableOrderingComposer,
      $$GenresTableTableAnnotationComposer,
      $$GenresTableTableCreateCompanionBuilder,
      $$GenresTableTableUpdateCompanionBuilder,
      (
        GenresTableData,
        BaseReferences<_$NavisDatabase, $GenresTableTable, GenresTableData>,
      ),
      GenresTableData,
      PrefetchHooks Function()
    >;
typedef $$PlaylistsTableTableCreateCompanionBuilder =
    PlaylistsTableCompanion Function({
      required String id,
      required String name,
      Value<int?> songCount,
      Value<int?> duration,
      Value<String?> owner,
      Value<bool?> isPublic,
      Value<String?> coverArt,
      Value<String?> comment,
      Value<int> rowid,
    });
typedef $$PlaylistsTableTableUpdateCompanionBuilder =
    PlaylistsTableCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<int?> songCount,
      Value<int?> duration,
      Value<String?> owner,
      Value<bool?> isPublic,
      Value<String?> coverArt,
      Value<String?> comment,
      Value<int> rowid,
    });

final class $$PlaylistsTableTableReferences
    extends
        BaseReferences<
          _$NavisDatabase,
          $PlaylistsTableTable,
          PlaylistsTableData
        > {
  $$PlaylistsTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<
    $PlaylistSongsTableTable,
    List<PlaylistSongsTableData>
  >
  _playlistSongsTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.playlistSongsTable,
        aliasName: $_aliasNameGenerator(
          db.playlistsTable.id,
          db.playlistSongsTable.playlistId,
        ),
      );

  $$PlaylistSongsTableTableProcessedTableManager get playlistSongsTableRefs {
    final manager = $$PlaylistSongsTableTableTableManager(
      $_db,
      $_db.playlistSongsTable,
    ).filter((f) => f.playlistId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _playlistSongsTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $DownloadQueueTableTable,
    List<DownloadQueueTableData>
  >
  _downloadQueueTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.downloadQueueTable,
        aliasName: $_aliasNameGenerator(
          db.playlistsTable.id,
          db.downloadQueueTable.playlistId,
        ),
      );

  $$DownloadQueueTableTableProcessedTableManager get downloadQueueTableRefs {
    final manager = $$DownloadQueueTableTableTableManager(
      $_db,
      $_db.downloadQueueTable,
    ).filter((f) => f.playlistId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _downloadQueueTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PlaylistsTableTableFilterComposer
    extends Composer<_$NavisDatabase, $PlaylistsTableTable> {
  $$PlaylistsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get songCount => $composableBuilder(
    column: $table.songCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get owner => $composableBuilder(
    column: $table.owner,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isPublic => $composableBuilder(
    column: $table.isPublic,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverArt => $composableBuilder(
    column: $table.coverArt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get comment => $composableBuilder(
    column: $table.comment,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> playlistSongsTableRefs(
    Expression<bool> Function($$PlaylistSongsTableTableFilterComposer f) f,
  ) {
    final $$PlaylistSongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playlistSongsTable,
      getReferencedColumn: (t) => t.playlistId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistSongsTableTableFilterComposer(
            $db: $db,
            $table: $db.playlistSongsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> downloadQueueTableRefs(
    Expression<bool> Function($$DownloadQueueTableTableFilterComposer f) f,
  ) {
    final $$DownloadQueueTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.downloadQueueTable,
      getReferencedColumn: (t) => t.playlistId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$DownloadQueueTableTableFilterComposer(
            $db: $db,
            $table: $db.downloadQueueTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlaylistsTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $PlaylistsTableTable> {
  $$PlaylistsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get songCount => $composableBuilder(
    column: $table.songCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get owner => $composableBuilder(
    column: $table.owner,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isPublic => $composableBuilder(
    column: $table.isPublic,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverArt => $composableBuilder(
    column: $table.coverArt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get comment => $composableBuilder(
    column: $table.comment,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PlaylistsTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $PlaylistsTableTable> {
  $$PlaylistsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get songCount =>
      $composableBuilder(column: $table.songCount, builder: (column) => column);

  GeneratedColumn<int> get duration =>
      $composableBuilder(column: $table.duration, builder: (column) => column);

  GeneratedColumn<String> get owner =>
      $composableBuilder(column: $table.owner, builder: (column) => column);

  GeneratedColumn<bool> get isPublic =>
      $composableBuilder(column: $table.isPublic, builder: (column) => column);

  GeneratedColumn<String> get coverArt =>
      $composableBuilder(column: $table.coverArt, builder: (column) => column);

  GeneratedColumn<String> get comment =>
      $composableBuilder(column: $table.comment, builder: (column) => column);

  Expression<T> playlistSongsTableRefs<T extends Object>(
    Expression<T> Function($$PlaylistSongsTableTableAnnotationComposer a) f,
  ) {
    final $$PlaylistSongsTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.playlistSongsTable,
          getReferencedColumn: (t) => t.playlistId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$PlaylistSongsTableTableAnnotationComposer(
                $db: $db,
                $table: $db.playlistSongsTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> downloadQueueTableRefs<T extends Object>(
    Expression<T> Function($$DownloadQueueTableTableAnnotationComposer a) f,
  ) {
    final $$DownloadQueueTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.downloadQueueTable,
          getReferencedColumn: (t) => t.playlistId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$DownloadQueueTableTableAnnotationComposer(
                $db: $db,
                $table: $db.downloadQueueTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$PlaylistsTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $PlaylistsTableTable,
          PlaylistsTableData,
          $$PlaylistsTableTableFilterComposer,
          $$PlaylistsTableTableOrderingComposer,
          $$PlaylistsTableTableAnnotationComposer,
          $$PlaylistsTableTableCreateCompanionBuilder,
          $$PlaylistsTableTableUpdateCompanionBuilder,
          (PlaylistsTableData, $$PlaylistsTableTableReferences),
          PlaylistsTableData,
          PrefetchHooks Function({
            bool playlistSongsTableRefs,
            bool downloadQueueTableRefs,
          })
        > {
  $$PlaylistsTableTableTableManager(
    _$NavisDatabase db,
    $PlaylistsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaylistsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaylistsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaylistsTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int?> songCount = const Value.absent(),
                Value<int?> duration = const Value.absent(),
                Value<String?> owner = const Value.absent(),
                Value<bool?> isPublic = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<String?> comment = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaylistsTableCompanion(
                id: id,
                name: name,
                songCount: songCount,
                duration: duration,
                owner: owner,
                isPublic: isPublic,
                coverArt: coverArt,
                comment: comment,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<int?> songCount = const Value.absent(),
                Value<int?> duration = const Value.absent(),
                Value<String?> owner = const Value.absent(),
                Value<bool?> isPublic = const Value.absent(),
                Value<String?> coverArt = const Value.absent(),
                Value<String?> comment = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaylistsTableCompanion.insert(
                id: id,
                name: name,
                songCount: songCount,
                duration: duration,
                owner: owner,
                isPublic: isPublic,
                coverArt: coverArt,
                comment: comment,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlaylistsTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                playlistSongsTableRefs = false,
                downloadQueueTableRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (playlistSongsTableRefs) db.playlistSongsTable,
                    if (downloadQueueTableRefs) db.downloadQueueTable,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (playlistSongsTableRefs)
                        await $_getPrefetchedData<
                          PlaylistsTableData,
                          $PlaylistsTableTable,
                          PlaylistSongsTableData
                        >(
                          currentTable: table,
                          referencedTable: $$PlaylistsTableTableReferences
                              ._playlistSongsTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PlaylistsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).playlistSongsTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.playlistId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (downloadQueueTableRefs)
                        await $_getPrefetchedData<
                          PlaylistsTableData,
                          $PlaylistsTableTable,
                          DownloadQueueTableData
                        >(
                          currentTable: table,
                          referencedTable: $$PlaylistsTableTableReferences
                              ._downloadQueueTableRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$PlaylistsTableTableReferences(
                                db,
                                table,
                                p0,
                              ).downloadQueueTableRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.playlistId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$PlaylistsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $PlaylistsTableTable,
      PlaylistsTableData,
      $$PlaylistsTableTableFilterComposer,
      $$PlaylistsTableTableOrderingComposer,
      $$PlaylistsTableTableAnnotationComposer,
      $$PlaylistsTableTableCreateCompanionBuilder,
      $$PlaylistsTableTableUpdateCompanionBuilder,
      (PlaylistsTableData, $$PlaylistsTableTableReferences),
      PlaylistsTableData,
      PrefetchHooks Function({
        bool playlistSongsTableRefs,
        bool downloadQueueTableRefs,
      })
    >;
typedef $$PlaylistSongsTableTableCreateCompanionBuilder =
    PlaylistSongsTableCompanion Function({
      required String playlistId,
      required String songId,
      required int sortOrder,
      Value<int> rowid,
    });
typedef $$PlaylistSongsTableTableUpdateCompanionBuilder =
    PlaylistSongsTableCompanion Function({
      Value<String> playlistId,
      Value<String> songId,
      Value<int> sortOrder,
      Value<int> rowid,
    });

final class $$PlaylistSongsTableTableReferences
    extends
        BaseReferences<
          _$NavisDatabase,
          $PlaylistSongsTableTable,
          PlaylistSongsTableData
        > {
  $$PlaylistSongsTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $PlaylistsTableTable _playlistIdTable(_$NavisDatabase db) =>
      db.playlistsTable.createAlias(
        $_aliasNameGenerator(
          db.playlistSongsTable.playlistId,
          db.playlistsTable.id,
        ),
      );

  $$PlaylistsTableTableProcessedTableManager get playlistId {
    final $_column = $_itemColumn<String>('playlist_id')!;

    final manager = $$PlaylistsTableTableTableManager(
      $_db,
      $_db.playlistsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_playlistIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $SongsTableTable _songIdTable(_$NavisDatabase db) =>
      db.songsTable.createAlias(
        $_aliasNameGenerator(db.playlistSongsTable.songId, db.songsTable.id),
      );

  $$SongsTableTableProcessedTableManager get songId {
    final $_column = $_itemColumn<String>('song_id')!;

    final manager = $$SongsTableTableTableManager(
      $_db,
      $_db.songsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_songIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PlaylistSongsTableTableFilterComposer
    extends Composer<_$NavisDatabase, $PlaylistSongsTableTable> {
  $$PlaylistSongsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  $$PlaylistsTableTableFilterComposer get playlistId {
    final $$PlaylistsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableTableFilterComposer(
            $db: $db,
            $table: $db.playlistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SongsTableTableFilterComposer get songId {
    final $$SongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableFilterComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaylistSongsTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $PlaylistSongsTableTable> {
  $$PlaylistSongsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  $$PlaylistsTableTableOrderingComposer get playlistId {
    final $$PlaylistsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableTableOrderingComposer(
            $db: $db,
            $table: $db.playlistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SongsTableTableOrderingComposer get songId {
    final $$SongsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableOrderingComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaylistSongsTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $PlaylistSongsTableTable> {
  $$PlaylistSongsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  $$PlaylistsTableTableAnnotationComposer get playlistId {
    final $$PlaylistsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.playlistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SongsTableTableAnnotationComposer get songId {
    final $$SongsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlaylistSongsTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $PlaylistSongsTableTable,
          PlaylistSongsTableData,
          $$PlaylistSongsTableTableFilterComposer,
          $$PlaylistSongsTableTableOrderingComposer,
          $$PlaylistSongsTableTableAnnotationComposer,
          $$PlaylistSongsTableTableCreateCompanionBuilder,
          $$PlaylistSongsTableTableUpdateCompanionBuilder,
          (PlaylistSongsTableData, $$PlaylistSongsTableTableReferences),
          PlaylistSongsTableData,
          PrefetchHooks Function({bool playlistId, bool songId})
        > {
  $$PlaylistSongsTableTableTableManager(
    _$NavisDatabase db,
    $PlaylistSongsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlaylistSongsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlaylistSongsTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlaylistSongsTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> playlistId = const Value.absent(),
                Value<String> songId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlaylistSongsTableCompanion(
                playlistId: playlistId,
                songId: songId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String playlistId,
                required String songId,
                required int sortOrder,
                Value<int> rowid = const Value.absent(),
              }) => PlaylistSongsTableCompanion.insert(
                playlistId: playlistId,
                songId: songId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlaylistSongsTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({playlistId = false, songId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (playlistId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.playlistId,
                                referencedTable:
                                    $$PlaylistSongsTableTableReferences
                                        ._playlistIdTable(db),
                                referencedColumn:
                                    $$PlaylistSongsTableTableReferences
                                        ._playlistIdTable(db)
                                        .id,
                              )
                              as T;
                    }
                    if (songId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.songId,
                                referencedTable:
                                    $$PlaylistSongsTableTableReferences
                                        ._songIdTable(db),
                                referencedColumn:
                                    $$PlaylistSongsTableTableReferences
                                        ._songIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PlaylistSongsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $PlaylistSongsTableTable,
      PlaylistSongsTableData,
      $$PlaylistSongsTableTableFilterComposer,
      $$PlaylistSongsTableTableOrderingComposer,
      $$PlaylistSongsTableTableAnnotationComposer,
      $$PlaylistSongsTableTableCreateCompanionBuilder,
      $$PlaylistSongsTableTableUpdateCompanionBuilder,
      (PlaylistSongsTableData, $$PlaylistSongsTableTableReferences),
      PlaylistSongsTableData,
      PrefetchHooks Function({bool playlistId, bool songId})
    >;
typedef $$CachedTracksTableTableCreateCompanionBuilder =
    CachedTracksTableCompanion Function({
      required String songId,
      required String filePath,
      required int fileSize,
      required String format,
      Value<int?> bitRate,
      required DateTime lastAccessedAt,
      required CacheType cacheType,
      required DownloadStatus downloadStatus,
      Value<int> rowid,
    });
typedef $$CachedTracksTableTableUpdateCompanionBuilder =
    CachedTracksTableCompanion Function({
      Value<String> songId,
      Value<String> filePath,
      Value<int> fileSize,
      Value<String> format,
      Value<int?> bitRate,
      Value<DateTime> lastAccessedAt,
      Value<CacheType> cacheType,
      Value<DownloadStatus> downloadStatus,
      Value<int> rowid,
    });

final class $$CachedTracksTableTableReferences
    extends
        BaseReferences<
          _$NavisDatabase,
          $CachedTracksTableTable,
          CachedTracksTableData
        > {
  $$CachedTracksTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SongsTableTable _songIdTable(_$NavisDatabase db) =>
      db.songsTable.createAlias(
        $_aliasNameGenerator(db.cachedTracksTable.songId, db.songsTable.id),
      );

  $$SongsTableTableProcessedTableManager get songId {
    final $_column = $_itemColumn<String>('song_id')!;

    final manager = $$SongsTableTableTableManager(
      $_db,
      $_db.songsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_songIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$CachedTracksTableTableFilterComposer
    extends Composer<_$NavisDatabase, $CachedTracksTableTable> {
  $$CachedTracksTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get bitRate => $composableBuilder(
    column: $table.bitRate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<CacheType, CacheType, String> get cacheType =>
      $composableBuilder(
        column: $table.cacheType,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnWithTypeConverterFilters<DownloadStatus, DownloadStatus, String>
  get downloadStatus => $composableBuilder(
    column: $table.downloadStatus,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  $$SongsTableTableFilterComposer get songId {
    final $$SongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableFilterComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedTracksTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $CachedTracksTableTable> {
  $$CachedTracksTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fileSize => $composableBuilder(
    column: $table.fileSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get bitRate => $composableBuilder(
    column: $table.bitRate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cacheType => $composableBuilder(
    column: $table.cacheType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get downloadStatus => $composableBuilder(
    column: $table.downloadStatus,
    builder: (column) => ColumnOrderings(column),
  );

  $$SongsTableTableOrderingComposer get songId {
    final $$SongsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableOrderingComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedTracksTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $CachedTracksTableTable> {
  $$CachedTracksTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<int> get fileSize =>
      $composableBuilder(column: $table.fileSize, builder: (column) => column);

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<int> get bitRate =>
      $composableBuilder(column: $table.bitRate, builder: (column) => column);

  GeneratedColumn<DateTime> get lastAccessedAt => $composableBuilder(
    column: $table.lastAccessedAt,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<CacheType, String> get cacheType =>
      $composableBuilder(column: $table.cacheType, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DownloadStatus, String> get downloadStatus =>
      $composableBuilder(
        column: $table.downloadStatus,
        builder: (column) => column,
      );

  $$SongsTableTableAnnotationComposer get songId {
    final $$SongsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$CachedTracksTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $CachedTracksTableTable,
          CachedTracksTableData,
          $$CachedTracksTableTableFilterComposer,
          $$CachedTracksTableTableOrderingComposer,
          $$CachedTracksTableTableAnnotationComposer,
          $$CachedTracksTableTableCreateCompanionBuilder,
          $$CachedTracksTableTableUpdateCompanionBuilder,
          (CachedTracksTableData, $$CachedTracksTableTableReferences),
          CachedTracksTableData,
          PrefetchHooks Function({bool songId})
        > {
  $$CachedTracksTableTableTableManager(
    _$NavisDatabase db,
    $CachedTracksTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedTracksTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedTracksTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedTracksTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> songId = const Value.absent(),
                Value<String> filePath = const Value.absent(),
                Value<int> fileSize = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<int?> bitRate = const Value.absent(),
                Value<DateTime> lastAccessedAt = const Value.absent(),
                Value<CacheType> cacheType = const Value.absent(),
                Value<DownloadStatus> downloadStatus = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CachedTracksTableCompanion(
                songId: songId,
                filePath: filePath,
                fileSize: fileSize,
                format: format,
                bitRate: bitRate,
                lastAccessedAt: lastAccessedAt,
                cacheType: cacheType,
                downloadStatus: downloadStatus,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String songId,
                required String filePath,
                required int fileSize,
                required String format,
                Value<int?> bitRate = const Value.absent(),
                required DateTime lastAccessedAt,
                required CacheType cacheType,
                required DownloadStatus downloadStatus,
                Value<int> rowid = const Value.absent(),
              }) => CachedTracksTableCompanion.insert(
                songId: songId,
                filePath: filePath,
                fileSize: fileSize,
                format: format,
                bitRate: bitRate,
                lastAccessedAt: lastAccessedAt,
                cacheType: cacheType,
                downloadStatus: downloadStatus,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$CachedTracksTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({songId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (songId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.songId,
                                referencedTable:
                                    $$CachedTracksTableTableReferences
                                        ._songIdTable(db),
                                referencedColumn:
                                    $$CachedTracksTableTableReferences
                                        ._songIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$CachedTracksTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $CachedTracksTableTable,
      CachedTracksTableData,
      $$CachedTracksTableTableFilterComposer,
      $$CachedTracksTableTableOrderingComposer,
      $$CachedTracksTableTableAnnotationComposer,
      $$CachedTracksTableTableCreateCompanionBuilder,
      $$CachedTracksTableTableUpdateCompanionBuilder,
      (CachedTracksTableData, $$CachedTracksTableTableReferences),
      CachedTracksTableData,
      PrefetchHooks Function({bool songId})
    >;
typedef $$DownloadQueueTableTableCreateCompanionBuilder =
    DownloadQueueTableCompanion Function({
      Value<int> id,
      Value<String?> songId,
      Value<String?> albumId,
      Value<String?> playlistId,
      Value<String?> quality,
      Value<String?> format,
      required DownloadStatus status,
      Value<double> progress,
      required DateTime addedAt,
      Value<int> priority,
    });
typedef $$DownloadQueueTableTableUpdateCompanionBuilder =
    DownloadQueueTableCompanion Function({
      Value<int> id,
      Value<String?> songId,
      Value<String?> albumId,
      Value<String?> playlistId,
      Value<String?> quality,
      Value<String?> format,
      Value<DownloadStatus> status,
      Value<double> progress,
      Value<DateTime> addedAt,
      Value<int> priority,
    });

final class $$DownloadQueueTableTableReferences
    extends
        BaseReferences<
          _$NavisDatabase,
          $DownloadQueueTableTable,
          DownloadQueueTableData
        > {
  $$DownloadQueueTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SongsTableTable _songIdTable(_$NavisDatabase db) =>
      db.songsTable.createAlias(
        $_aliasNameGenerator(db.downloadQueueTable.songId, db.songsTable.id),
      );

  $$SongsTableTableProcessedTableManager? get songId {
    final $_column = $_itemColumn<String>('song_id');
    if ($_column == null) return null;
    final manager = $$SongsTableTableTableManager(
      $_db,
      $_db.songsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_songIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $AlbumsTableTable _albumIdTable(_$NavisDatabase db) =>
      db.albumsTable.createAlias(
        $_aliasNameGenerator(db.downloadQueueTable.albumId, db.albumsTable.id),
      );

  $$AlbumsTableTableProcessedTableManager? get albumId {
    final $_column = $_itemColumn<String>('album_id');
    if ($_column == null) return null;
    final manager = $$AlbumsTableTableTableManager(
      $_db,
      $_db.albumsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_albumIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $PlaylistsTableTable _playlistIdTable(_$NavisDatabase db) =>
      db.playlistsTable.createAlias(
        $_aliasNameGenerator(
          db.downloadQueueTable.playlistId,
          db.playlistsTable.id,
        ),
      );

  $$PlaylistsTableTableProcessedTableManager? get playlistId {
    final $_column = $_itemColumn<String>('playlist_id');
    if ($_column == null) return null;
    final manager = $$PlaylistsTableTableTableManager(
      $_db,
      $_db.playlistsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_playlistIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$DownloadQueueTableTableFilterComposer
    extends Composer<_$NavisDatabase, $DownloadQueueTableTable> {
  $$DownloadQueueTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get quality => $composableBuilder(
    column: $table.quality,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<DownloadStatus, DownloadStatus, String>
  get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnFilters(column),
  );

  $$SongsTableTableFilterComposer get songId {
    final $$SongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableFilterComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AlbumsTableTableFilterComposer get albumId {
    final $$AlbumsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.albumId,
      referencedTable: $db.albumsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AlbumsTableTableFilterComposer(
            $db: $db,
            $table: $db.albumsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlaylistsTableTableFilterComposer get playlistId {
    final $$PlaylistsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableTableFilterComposer(
            $db: $db,
            $table: $db.playlistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$DownloadQueueTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $DownloadQueueTableTable> {
  $$DownloadQueueTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get quality => $composableBuilder(
    column: $table.quality,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnOrderings(column),
  );

  $$SongsTableTableOrderingComposer get songId {
    final $$SongsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableOrderingComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AlbumsTableTableOrderingComposer get albumId {
    final $$AlbumsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.albumId,
      referencedTable: $db.albumsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AlbumsTableTableOrderingComposer(
            $db: $db,
            $table: $db.albumsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlaylistsTableTableOrderingComposer get playlistId {
    final $$PlaylistsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableTableOrderingComposer(
            $db: $db,
            $table: $db.playlistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$DownloadQueueTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $DownloadQueueTableTable> {
  $$DownloadQueueTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get quality =>
      $composableBuilder(column: $table.quality, builder: (column) => column);

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DownloadStatus, String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<double> get progress =>
      $composableBuilder(column: $table.progress, builder: (column) => column);

  GeneratedColumn<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<int> get priority =>
      $composableBuilder(column: $table.priority, builder: (column) => column);

  $$SongsTableTableAnnotationComposer get songId {
    final $$SongsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$AlbumsTableTableAnnotationComposer get albumId {
    final $$AlbumsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.albumId,
      referencedTable: $db.albumsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$AlbumsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.albumsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$PlaylistsTableTableAnnotationComposer get playlistId {
    final $$PlaylistsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.playlistId,
      referencedTable: $db.playlistsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlaylistsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.playlistsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$DownloadQueueTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $DownloadQueueTableTable,
          DownloadQueueTableData,
          $$DownloadQueueTableTableFilterComposer,
          $$DownloadQueueTableTableOrderingComposer,
          $$DownloadQueueTableTableAnnotationComposer,
          $$DownloadQueueTableTableCreateCompanionBuilder,
          $$DownloadQueueTableTableUpdateCompanionBuilder,
          (DownloadQueueTableData, $$DownloadQueueTableTableReferences),
          DownloadQueueTableData,
          PrefetchHooks Function({bool songId, bool albumId, bool playlistId})
        > {
  $$DownloadQueueTableTableTableManager(
    _$NavisDatabase db,
    $DownloadQueueTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadQueueTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadQueueTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadQueueTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> songId = const Value.absent(),
                Value<String?> albumId = const Value.absent(),
                Value<String?> playlistId = const Value.absent(),
                Value<String?> quality = const Value.absent(),
                Value<String?> format = const Value.absent(),
                Value<DownloadStatus> status = const Value.absent(),
                Value<double> progress = const Value.absent(),
                Value<DateTime> addedAt = const Value.absent(),
                Value<int> priority = const Value.absent(),
              }) => DownloadQueueTableCompanion(
                id: id,
                songId: songId,
                albumId: albumId,
                playlistId: playlistId,
                quality: quality,
                format: format,
                status: status,
                progress: progress,
                addedAt: addedAt,
                priority: priority,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> songId = const Value.absent(),
                Value<String?> albumId = const Value.absent(),
                Value<String?> playlistId = const Value.absent(),
                Value<String?> quality = const Value.absent(),
                Value<String?> format = const Value.absent(),
                required DownloadStatus status,
                Value<double> progress = const Value.absent(),
                required DateTime addedAt,
                Value<int> priority = const Value.absent(),
              }) => DownloadQueueTableCompanion.insert(
                id: id,
                songId: songId,
                albumId: albumId,
                playlistId: playlistId,
                quality: quality,
                format: format,
                status: status,
                progress: progress,
                addedAt: addedAt,
                priority: priority,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$DownloadQueueTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({songId = false, albumId = false, playlistId = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (songId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.songId,
                                    referencedTable:
                                        $$DownloadQueueTableTableReferences
                                            ._songIdTable(db),
                                    referencedColumn:
                                        $$DownloadQueueTableTableReferences
                                            ._songIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (albumId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.albumId,
                                    referencedTable:
                                        $$DownloadQueueTableTableReferences
                                            ._albumIdTable(db),
                                    referencedColumn:
                                        $$DownloadQueueTableTableReferences
                                            ._albumIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (playlistId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.playlistId,
                                    referencedTable:
                                        $$DownloadQueueTableTableReferences
                                            ._playlistIdTable(db),
                                    referencedColumn:
                                        $$DownloadQueueTableTableReferences
                                            ._playlistIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [];
                  },
                );
              },
        ),
      );
}

typedef $$DownloadQueueTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $DownloadQueueTableTable,
      DownloadQueueTableData,
      $$DownloadQueueTableTableFilterComposer,
      $$DownloadQueueTableTableOrderingComposer,
      $$DownloadQueueTableTableAnnotationComposer,
      $$DownloadQueueTableTableCreateCompanionBuilder,
      $$DownloadQueueTableTableUpdateCompanionBuilder,
      (DownloadQueueTableData, $$DownloadQueueTableTableReferences),
      DownloadQueueTableData,
      PrefetchHooks Function({bool songId, bool albumId, bool playlistId})
    >;
typedef $$PlayHistoryTableTableCreateCompanionBuilder =
    PlayHistoryTableCompanion Function({
      required String songId,
      required DateTime playedAt,
      Value<int> rowid,
    });
typedef $$PlayHistoryTableTableUpdateCompanionBuilder =
    PlayHistoryTableCompanion Function({
      Value<String> songId,
      Value<DateTime> playedAt,
      Value<int> rowid,
    });

final class $$PlayHistoryTableTableReferences
    extends
        BaseReferences<
          _$NavisDatabase,
          $PlayHistoryTableTable,
          PlayHistoryTableData
        > {
  $$PlayHistoryTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SongsTableTable _songIdTable(_$NavisDatabase db) =>
      db.songsTable.createAlias(
        $_aliasNameGenerator(db.playHistoryTable.songId, db.songsTable.id),
      );

  $$SongsTableTableProcessedTableManager get songId {
    final $_column = $_itemColumn<String>('song_id')!;

    final manager = $$SongsTableTableTableManager(
      $_db,
      $_db.songsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_songIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PlayHistoryTableTableFilterComposer
    extends Composer<_$NavisDatabase, $PlayHistoryTableTable> {
  $$PlayHistoryTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<DateTime> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$SongsTableTableFilterComposer get songId {
    final $$SongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableFilterComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlayHistoryTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $PlayHistoryTableTable> {
  $$PlayHistoryTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<DateTime> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$SongsTableTableOrderingComposer get songId {
    final $$SongsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableOrderingComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlayHistoryTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $PlayHistoryTableTable> {
  $$PlayHistoryTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<DateTime> get playedAt =>
      $composableBuilder(column: $table.playedAt, builder: (column) => column);

  $$SongsTableTableAnnotationComposer get songId {
    final $$SongsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlayHistoryTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $PlayHistoryTableTable,
          PlayHistoryTableData,
          $$PlayHistoryTableTableFilterComposer,
          $$PlayHistoryTableTableOrderingComposer,
          $$PlayHistoryTableTableAnnotationComposer,
          $$PlayHistoryTableTableCreateCompanionBuilder,
          $$PlayHistoryTableTableUpdateCompanionBuilder,
          (PlayHistoryTableData, $$PlayHistoryTableTableReferences),
          PlayHistoryTableData,
          PrefetchHooks Function({bool songId})
        > {
  $$PlayHistoryTableTableTableManager(
    _$NavisDatabase db,
    $PlayHistoryTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlayHistoryTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlayHistoryTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlayHistoryTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> songId = const Value.absent(),
                Value<DateTime> playedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlayHistoryTableCompanion(
                songId: songId,
                playedAt: playedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String songId,
                required DateTime playedAt,
                Value<int> rowid = const Value.absent(),
              }) => PlayHistoryTableCompanion.insert(
                songId: songId,
                playedAt: playedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlayHistoryTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({songId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (songId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.songId,
                                referencedTable:
                                    $$PlayHistoryTableTableReferences
                                        ._songIdTable(db),
                                referencedColumn:
                                    $$PlayHistoryTableTableReferences
                                        ._songIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PlayHistoryTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $PlayHistoryTableTable,
      PlayHistoryTableData,
      $$PlayHistoryTableTableFilterComposer,
      $$PlayHistoryTableTableOrderingComposer,
      $$PlayHistoryTableTableAnnotationComposer,
      $$PlayHistoryTableTableCreateCompanionBuilder,
      $$PlayHistoryTableTableUpdateCompanionBuilder,
      (PlayHistoryTableData, $$PlayHistoryTableTableReferences),
      PlayHistoryTableData,
      PrefetchHooks Function({bool songId})
    >;
typedef $$RecentSearchesTableTableCreateCompanionBuilder =
    RecentSearchesTableCompanion Function({
      required String query,
      required DateTime searchedAt,
      Value<int> rowid,
    });
typedef $$RecentSearchesTableTableUpdateCompanionBuilder =
    RecentSearchesTableCompanion Function({
      Value<String> query,
      Value<DateTime> searchedAt,
      Value<int> rowid,
    });

class $$RecentSearchesTableTableFilterComposer
    extends Composer<_$NavisDatabase, $RecentSearchesTableTable> {
  $$RecentSearchesTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get query => $composableBuilder(
    column: $table.query,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get searchedAt => $composableBuilder(
    column: $table.searchedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecentSearchesTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $RecentSearchesTableTable> {
  $$RecentSearchesTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get query => $composableBuilder(
    column: $table.query,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get searchedAt => $composableBuilder(
    column: $table.searchedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecentSearchesTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $RecentSearchesTableTable> {
  $$RecentSearchesTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get query =>
      $composableBuilder(column: $table.query, builder: (column) => column);

  GeneratedColumn<DateTime> get searchedAt => $composableBuilder(
    column: $table.searchedAt,
    builder: (column) => column,
  );
}

class $$RecentSearchesTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $RecentSearchesTableTable,
          RecentSearchesTableData,
          $$RecentSearchesTableTableFilterComposer,
          $$RecentSearchesTableTableOrderingComposer,
          $$RecentSearchesTableTableAnnotationComposer,
          $$RecentSearchesTableTableCreateCompanionBuilder,
          $$RecentSearchesTableTableUpdateCompanionBuilder,
          (
            RecentSearchesTableData,
            BaseReferences<
              _$NavisDatabase,
              $RecentSearchesTableTable,
              RecentSearchesTableData
            >,
          ),
          RecentSearchesTableData,
          PrefetchHooks Function()
        > {
  $$RecentSearchesTableTableTableManager(
    _$NavisDatabase db,
    $RecentSearchesTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecentSearchesTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecentSearchesTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$RecentSearchesTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> query = const Value.absent(),
                Value<DateTime> searchedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => RecentSearchesTableCompanion(
                query: query,
                searchedAt: searchedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String query,
                required DateTime searchedAt,
                Value<int> rowid = const Value.absent(),
              }) => RecentSearchesTableCompanion.insert(
                query: query,
                searchedAt: searchedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecentSearchesTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $RecentSearchesTableTable,
      RecentSearchesTableData,
      $$RecentSearchesTableTableFilterComposer,
      $$RecentSearchesTableTableOrderingComposer,
      $$RecentSearchesTableTableAnnotationComposer,
      $$RecentSearchesTableTableCreateCompanionBuilder,
      $$RecentSearchesTableTableUpdateCompanionBuilder,
      (
        RecentSearchesTableData,
        BaseReferences<
          _$NavisDatabase,
          $RecentSearchesTableTable,
          RecentSearchesTableData
        >,
      ),
      RecentSearchesTableData,
      PrefetchHooks Function()
    >;
typedef $$PlayQueueTableTableCreateCompanionBuilder =
    PlayQueueTableCompanion Function({
      Value<int> id,
      Value<int?> currentIndex,
      Value<ShuffleMode> shuffleMode,
      Value<RepeatMode> repeatMode,
      Value<int> positionMs,
      required DateTime updatedAt,
    });
typedef $$PlayQueueTableTableUpdateCompanionBuilder =
    PlayQueueTableCompanion Function({
      Value<int> id,
      Value<int?> currentIndex,
      Value<ShuffleMode> shuffleMode,
      Value<RepeatMode> repeatMode,
      Value<int> positionMs,
      Value<DateTime> updatedAt,
    });

final class $$PlayQueueTableTableReferences
    extends
        BaseReferences<
          _$NavisDatabase,
          $PlayQueueTableTable,
          PlayQueueTableData
        > {
  $$PlayQueueTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<
    $PlayQueueItemsTableTable,
    List<PlayQueueItemsTableData>
  >
  _playQueueItemsTableRefsTable(_$NavisDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.playQueueItemsTable,
        aliasName: $_aliasNameGenerator(
          db.playQueueTable.id,
          db.playQueueItemsTable.queueId,
        ),
      );

  $$PlayQueueItemsTableTableProcessedTableManager get playQueueItemsTableRefs {
    final manager = $$PlayQueueItemsTableTableTableManager(
      $_db,
      $_db.playQueueItemsTable,
    ).filter((f) => f.queueId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _playQueueItemsTableRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$PlayQueueTableTableFilterComposer
    extends Composer<_$NavisDatabase, $PlayQueueTableTable> {
  $$PlayQueueTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get currentIndex => $composableBuilder(
    column: $table.currentIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<ShuffleMode, ShuffleMode, String>
  get shuffleMode => $composableBuilder(
    column: $table.shuffleMode,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnWithTypeConverterFilters<RepeatMode, RepeatMode, String>
  get repeatMode => $composableBuilder(
    column: $table.repeatMode,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> playQueueItemsTableRefs(
    Expression<bool> Function($$PlayQueueItemsTableTableFilterComposer f) f,
  ) {
    final $$PlayQueueItemsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.playQueueItemsTable,
      getReferencedColumn: (t) => t.queueId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlayQueueItemsTableTableFilterComposer(
            $db: $db,
            $table: $db.playQueueItemsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$PlayQueueTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $PlayQueueTableTable> {
  $$PlayQueueTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get currentIndex => $composableBuilder(
    column: $table.currentIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get shuffleMode => $composableBuilder(
    column: $table.shuffleMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get repeatMode => $composableBuilder(
    column: $table.repeatMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PlayQueueTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $PlayQueueTableTable> {
  $$PlayQueueTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get currentIndex => $composableBuilder(
    column: $table.currentIndex,
    builder: (column) => column,
  );

  GeneratedColumnWithTypeConverter<ShuffleMode, String> get shuffleMode =>
      $composableBuilder(
        column: $table.shuffleMode,
        builder: (column) => column,
      );

  GeneratedColumnWithTypeConverter<RepeatMode, String> get repeatMode =>
      $composableBuilder(
        column: $table.repeatMode,
        builder: (column) => column,
      );

  GeneratedColumn<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> playQueueItemsTableRefs<T extends Object>(
    Expression<T> Function($$PlayQueueItemsTableTableAnnotationComposer a) f,
  ) {
    final $$PlayQueueItemsTableTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.playQueueItemsTable,
          getReferencedColumn: (t) => t.queueId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$PlayQueueItemsTableTableAnnotationComposer(
                $db: $db,
                $table: $db.playQueueItemsTable,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$PlayQueueTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $PlayQueueTableTable,
          PlayQueueTableData,
          $$PlayQueueTableTableFilterComposer,
          $$PlayQueueTableTableOrderingComposer,
          $$PlayQueueTableTableAnnotationComposer,
          $$PlayQueueTableTableCreateCompanionBuilder,
          $$PlayQueueTableTableUpdateCompanionBuilder,
          (PlayQueueTableData, $$PlayQueueTableTableReferences),
          PlayQueueTableData,
          PrefetchHooks Function({bool playQueueItemsTableRefs})
        > {
  $$PlayQueueTableTableTableManager(
    _$NavisDatabase db,
    $PlayQueueTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlayQueueTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlayQueueTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PlayQueueTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int?> currentIndex = const Value.absent(),
                Value<ShuffleMode> shuffleMode = const Value.absent(),
                Value<RepeatMode> repeatMode = const Value.absent(),
                Value<int> positionMs = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
              }) => PlayQueueTableCompanion(
                id: id,
                currentIndex: currentIndex,
                shuffleMode: shuffleMode,
                repeatMode: repeatMode,
                positionMs: positionMs,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int?> currentIndex = const Value.absent(),
                Value<ShuffleMode> shuffleMode = const Value.absent(),
                Value<RepeatMode> repeatMode = const Value.absent(),
                Value<int> positionMs = const Value.absent(),
                required DateTime updatedAt,
              }) => PlayQueueTableCompanion.insert(
                id: id,
                currentIndex: currentIndex,
                shuffleMode: shuffleMode,
                repeatMode: repeatMode,
                positionMs: positionMs,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlayQueueTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({playQueueItemsTableRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (playQueueItemsTableRefs) db.playQueueItemsTable,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (playQueueItemsTableRefs)
                    await $_getPrefetchedData<
                      PlayQueueTableData,
                      $PlayQueueTableTable,
                      PlayQueueItemsTableData
                    >(
                      currentTable: table,
                      referencedTable: $$PlayQueueTableTableReferences
                          ._playQueueItemsTableRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$PlayQueueTableTableReferences(
                            db,
                            table,
                            p0,
                          ).playQueueItemsTableRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.queueId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$PlayQueueTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $PlayQueueTableTable,
      PlayQueueTableData,
      $$PlayQueueTableTableFilterComposer,
      $$PlayQueueTableTableOrderingComposer,
      $$PlayQueueTableTableAnnotationComposer,
      $$PlayQueueTableTableCreateCompanionBuilder,
      $$PlayQueueTableTableUpdateCompanionBuilder,
      (PlayQueueTableData, $$PlayQueueTableTableReferences),
      PlayQueueTableData,
      PrefetchHooks Function({bool playQueueItemsTableRefs})
    >;
typedef $$PlayQueueItemsTableTableCreateCompanionBuilder =
    PlayQueueItemsTableCompanion Function({
      required int queueId,
      required String songId,
      required int sortOrder,
      Value<int> rowid,
    });
typedef $$PlayQueueItemsTableTableUpdateCompanionBuilder =
    PlayQueueItemsTableCompanion Function({
      Value<int> queueId,
      Value<String> songId,
      Value<int> sortOrder,
      Value<int> rowid,
    });

final class $$PlayQueueItemsTableTableReferences
    extends
        BaseReferences<
          _$NavisDatabase,
          $PlayQueueItemsTableTable,
          PlayQueueItemsTableData
        > {
  $$PlayQueueItemsTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $PlayQueueTableTable _queueIdTable(_$NavisDatabase db) =>
      db.playQueueTable.createAlias(
        $_aliasNameGenerator(
          db.playQueueItemsTable.queueId,
          db.playQueueTable.id,
        ),
      );

  $$PlayQueueTableTableProcessedTableManager get queueId {
    final $_column = $_itemColumn<int>('queue_id')!;

    final manager = $$PlayQueueTableTableTableManager(
      $_db,
      $_db.playQueueTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_queueIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $SongsTableTable _songIdTable(_$NavisDatabase db) =>
      db.songsTable.createAlias(
        $_aliasNameGenerator(db.playQueueItemsTable.songId, db.songsTable.id),
      );

  $$SongsTableTableProcessedTableManager get songId {
    final $_column = $_itemColumn<String>('song_id')!;

    final manager = $$SongsTableTableTableManager(
      $_db,
      $_db.songsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_songIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PlayQueueItemsTableTableFilterComposer
    extends Composer<_$NavisDatabase, $PlayQueueItemsTableTable> {
  $$PlayQueueItemsTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  $$PlayQueueTableTableFilterComposer get queueId {
    final $$PlayQueueTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.queueId,
      referencedTable: $db.playQueueTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlayQueueTableTableFilterComposer(
            $db: $db,
            $table: $db.playQueueTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SongsTableTableFilterComposer get songId {
    final $$SongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableFilterComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlayQueueItemsTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $PlayQueueItemsTableTable> {
  $$PlayQueueItemsTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  $$PlayQueueTableTableOrderingComposer get queueId {
    final $$PlayQueueTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.queueId,
      referencedTable: $db.playQueueTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlayQueueTableTableOrderingComposer(
            $db: $db,
            $table: $db.playQueueTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SongsTableTableOrderingComposer get songId {
    final $$SongsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableOrderingComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlayQueueItemsTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $PlayQueueItemsTableTable> {
  $$PlayQueueItemsTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  $$PlayQueueTableTableAnnotationComposer get queueId {
    final $$PlayQueueTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.queueId,
      referencedTable: $db.playQueueTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PlayQueueTableTableAnnotationComposer(
            $db: $db,
            $table: $db.playQueueTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SongsTableTableAnnotationComposer get songId {
    final $$SongsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PlayQueueItemsTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $PlayQueueItemsTableTable,
          PlayQueueItemsTableData,
          $$PlayQueueItemsTableTableFilterComposer,
          $$PlayQueueItemsTableTableOrderingComposer,
          $$PlayQueueItemsTableTableAnnotationComposer,
          $$PlayQueueItemsTableTableCreateCompanionBuilder,
          $$PlayQueueItemsTableTableUpdateCompanionBuilder,
          (PlayQueueItemsTableData, $$PlayQueueItemsTableTableReferences),
          PlayQueueItemsTableData,
          PrefetchHooks Function({bool queueId, bool songId})
        > {
  $$PlayQueueItemsTableTableTableManager(
    _$NavisDatabase db,
    $PlayQueueItemsTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PlayQueueItemsTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PlayQueueItemsTableTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$PlayQueueItemsTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> queueId = const Value.absent(),
                Value<String> songId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PlayQueueItemsTableCompanion(
                queueId: queueId,
                songId: songId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int queueId,
                required String songId,
                required int sortOrder,
                Value<int> rowid = const Value.absent(),
              }) => PlayQueueItemsTableCompanion.insert(
                queueId: queueId,
                songId: songId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PlayQueueItemsTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({queueId = false, songId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (queueId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.queueId,
                                referencedTable:
                                    $$PlayQueueItemsTableTableReferences
                                        ._queueIdTable(db),
                                referencedColumn:
                                    $$PlayQueueItemsTableTableReferences
                                        ._queueIdTable(db)
                                        .id,
                              )
                              as T;
                    }
                    if (songId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.songId,
                                referencedTable:
                                    $$PlayQueueItemsTableTableReferences
                                        ._songIdTable(db),
                                referencedColumn:
                                    $$PlayQueueItemsTableTableReferences
                                        ._songIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PlayQueueItemsTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $PlayQueueItemsTableTable,
      PlayQueueItemsTableData,
      $$PlayQueueItemsTableTableFilterComposer,
      $$PlayQueueItemsTableTableOrderingComposer,
      $$PlayQueueItemsTableTableAnnotationComposer,
      $$PlayQueueItemsTableTableCreateCompanionBuilder,
      $$PlayQueueItemsTableTableUpdateCompanionBuilder,
      (PlayQueueItemsTableData, $$PlayQueueItemsTableTableReferences),
      PlayQueueItemsTableData,
      PrefetchHooks Function({bool queueId, bool songId})
    >;
typedef $$ScrobbleQueueTableTableCreateCompanionBuilder =
    ScrobbleQueueTableCompanion Function({
      Value<int> id,
      required String songId,
      required bool submission,
      required DateTime createdAt,
      required DateTime nextAttemptAt,
      Value<int> attempts,
      required DateTime expiresAt,
      required String sessionKey,
      Value<String?> lastError,
    });
typedef $$ScrobbleQueueTableTableUpdateCompanionBuilder =
    ScrobbleQueueTableCompanion Function({
      Value<int> id,
      Value<String> songId,
      Value<bool> submission,
      Value<DateTime> createdAt,
      Value<DateTime> nextAttemptAt,
      Value<int> attempts,
      Value<DateTime> expiresAt,
      Value<String> sessionKey,
      Value<String?> lastError,
    });

final class $$ScrobbleQueueTableTableReferences
    extends
        BaseReferences<
          _$NavisDatabase,
          $ScrobbleQueueTableTable,
          ScrobbleQueueTableData
        > {
  $$ScrobbleQueueTableTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SongsTableTable _songIdTable(_$NavisDatabase db) =>
      db.songsTable.createAlias(
        $_aliasNameGenerator(db.scrobbleQueueTable.songId, db.songsTable.id),
      );

  $$SongsTableTableProcessedTableManager get songId {
    final $_column = $_itemColumn<String>('song_id')!;

    final manager = $$SongsTableTableTableManager(
      $_db,
      $_db.songsTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_songIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ScrobbleQueueTableTableFilterComposer
    extends Composer<_$NavisDatabase, $ScrobbleQueueTableTable> {
  $$ScrobbleQueueTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get submission => $composableBuilder(
    column: $table.submission,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sessionKey => $composableBuilder(
    column: $table.sessionKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  $$SongsTableTableFilterComposer get songId {
    final $$SongsTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableFilterComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScrobbleQueueTableTableOrderingComposer
    extends Composer<_$NavisDatabase, $ScrobbleQueueTableTable> {
  $$ScrobbleQueueTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get submission => $composableBuilder(
    column: $table.submission,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sessionKey => $composableBuilder(
    column: $table.sessionKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  $$SongsTableTableOrderingComposer get songId {
    final $$SongsTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableOrderingComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScrobbleQueueTableTableAnnotationComposer
    extends Composer<_$NavisDatabase, $ScrobbleQueueTableTable> {
  $$ScrobbleQueueTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<bool> get submission => $composableBuilder(
    column: $table.submission,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<DateTime> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<String> get sessionKey => $composableBuilder(
    column: $table.sessionKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  $$SongsTableTableAnnotationComposer get songId {
    final $$SongsTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.songId,
      referencedTable: $db.songsTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SongsTableTableAnnotationComposer(
            $db: $db,
            $table: $db.songsTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ScrobbleQueueTableTableTableManager
    extends
        RootTableManager<
          _$NavisDatabase,
          $ScrobbleQueueTableTable,
          ScrobbleQueueTableData,
          $$ScrobbleQueueTableTableFilterComposer,
          $$ScrobbleQueueTableTableOrderingComposer,
          $$ScrobbleQueueTableTableAnnotationComposer,
          $$ScrobbleQueueTableTableCreateCompanionBuilder,
          $$ScrobbleQueueTableTableUpdateCompanionBuilder,
          (ScrobbleQueueTableData, $$ScrobbleQueueTableTableReferences),
          ScrobbleQueueTableData,
          PrefetchHooks Function({bool songId})
        > {
  $$ScrobbleQueueTableTableTableManager(
    _$NavisDatabase db,
    $ScrobbleQueueTableTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ScrobbleQueueTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ScrobbleQueueTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ScrobbleQueueTableTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> songId = const Value.absent(),
                Value<bool> submission = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> nextAttemptAt = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<DateTime> expiresAt = const Value.absent(),
                Value<String> sessionKey = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
              }) => ScrobbleQueueTableCompanion(
                id: id,
                songId: songId,
                submission: submission,
                createdAt: createdAt,
                nextAttemptAt: nextAttemptAt,
                attempts: attempts,
                expiresAt: expiresAt,
                sessionKey: sessionKey,
                lastError: lastError,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String songId,
                required bool submission,
                required DateTime createdAt,
                required DateTime nextAttemptAt,
                Value<int> attempts = const Value.absent(),
                required DateTime expiresAt,
                required String sessionKey,
                Value<String?> lastError = const Value.absent(),
              }) => ScrobbleQueueTableCompanion.insert(
                id: id,
                songId: songId,
                submission: submission,
                createdAt: createdAt,
                nextAttemptAt: nextAttemptAt,
                attempts: attempts,
                expiresAt: expiresAt,
                sessionKey: sessionKey,
                lastError: lastError,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ScrobbleQueueTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({songId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (songId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.songId,
                                referencedTable:
                                    $$ScrobbleQueueTableTableReferences
                                        ._songIdTable(db),
                                referencedColumn:
                                    $$ScrobbleQueueTableTableReferences
                                        ._songIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ScrobbleQueueTableTableProcessedTableManager =
    ProcessedTableManager<
      _$NavisDatabase,
      $ScrobbleQueueTableTable,
      ScrobbleQueueTableData,
      $$ScrobbleQueueTableTableFilterComposer,
      $$ScrobbleQueueTableTableOrderingComposer,
      $$ScrobbleQueueTableTableAnnotationComposer,
      $$ScrobbleQueueTableTableCreateCompanionBuilder,
      $$ScrobbleQueueTableTableUpdateCompanionBuilder,
      (ScrobbleQueueTableData, $$ScrobbleQueueTableTableReferences),
      ScrobbleQueueTableData,
      PrefetchHooks Function({bool songId})
    >;

class $NavisDatabaseManager {
  final _$NavisDatabase _db;
  $NavisDatabaseManager(this._db);
  $$ServerConfigTableTableTableManager get serverConfigTable =>
      $$ServerConfigTableTableTableManager(_db, _db.serverConfigTable);
  $$AppSettingsTableTableTableManager get appSettingsTable =>
      $$AppSettingsTableTableTableManager(_db, _db.appSettingsTable);
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db, _db.songsTable);
  $$GenresTableTableTableManager get genresTable =>
      $$GenresTableTableTableManager(_db, _db.genresTable);
  $$PlaylistsTableTableTableManager get playlistsTable =>
      $$PlaylistsTableTableTableManager(_db, _db.playlistsTable);
  $$PlaylistSongsTableTableTableManager get playlistSongsTable =>
      $$PlaylistSongsTableTableTableManager(_db, _db.playlistSongsTable);
  $$CachedTracksTableTableTableManager get cachedTracksTable =>
      $$CachedTracksTableTableTableManager(_db, _db.cachedTracksTable);
  $$DownloadQueueTableTableTableManager get downloadQueueTable =>
      $$DownloadQueueTableTableTableManager(_db, _db.downloadQueueTable);
  $$PlayHistoryTableTableTableManager get playHistoryTable =>
      $$PlayHistoryTableTableTableManager(_db, _db.playHistoryTable);
  $$RecentSearchesTableTableTableManager get recentSearchesTable =>
      $$RecentSearchesTableTableTableManager(_db, _db.recentSearchesTable);
  $$PlayQueueTableTableTableManager get playQueueTable =>
      $$PlayQueueTableTableTableManager(_db, _db.playQueueTable);
  $$PlayQueueItemsTableTableTableManager get playQueueItemsTable =>
      $$PlayQueueItemsTableTableTableManager(_db, _db.playQueueItemsTable);
  $$ScrobbleQueueTableTableTableManager get scrobbleQueueTable =>
      $$ScrobbleQueueTableTableTableManager(_db, _db.scrobbleQueueTable);
}
