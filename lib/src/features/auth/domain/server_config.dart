import 'package:freezed_annotation/freezed_annotation.dart';

part 'server_config.freezed.dart';
part 'server_config.g.dart';

@freezed
abstract class ServerConfigModel with _$ServerConfigModel {
  const factory ServerConfigModel({
    int? id,
    String? name,
    required String url,
    required String username,
    required String password,
    required String apiVersion,
    @Default(false) bool useLegacyAuth,
    String? capabilitiesJson,
    DateTime? lastSynced,
  }) = _ServerConfigModel;

  factory ServerConfigModel.fromJson(Map<String, dynamic> json) =>
      _$ServerConfigModelFromJson(json);
}
