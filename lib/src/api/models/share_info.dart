import 'package:freezed_annotation/freezed_annotation.dart';

part 'share_info.freezed.dart';
part 'share_info.g.dart';

@freezed
abstract class ShareInfo with _$ShareInfo {
  const factory ShareInfo({
    required String id,
    String? url,
    String? description,
    DateTime? expires,
    DateTime? created,
  }) = _ShareInfo;

  factory ShareInfo.fromJson(Map<String, dynamic> json) =>
      _$ShareInfoFromJson(json);
}
