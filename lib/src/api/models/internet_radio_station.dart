import 'package:freezed_annotation/freezed_annotation.dart';

part 'internet_radio_station.freezed.dart';
part 'internet_radio_station.g.dart';

@freezed
abstract class InternetRadioStation with _$InternetRadioStation {
  const factory InternetRadioStation({
    required String id,
    required String name,
    required String streamUrl,
    String? homePageUrl,
  }) = _InternetRadioStation;

  factory InternetRadioStation.fromJson(Map<String, dynamic> json) =>
      _$InternetRadioStationFromJson(json);
}
