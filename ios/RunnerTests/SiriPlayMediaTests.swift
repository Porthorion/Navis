import Intents
import XCTest

@testable import Runner

/// The `INPlayMediaIntent` <-> `com.navis.app/siri` mapping.
class SiriPlayMediaTests: XCTestCase {
  private func search(
    _ type: INMediaItemType, name: String? = nil, artist: String? = nil,
    album: String? = nil, genres: [String]? = nil
  ) -> INMediaSearch {
    INMediaSearch(
      mediaType: type, sortOrder: .unknown, mediaName: name, artistName: artist,
      albumName: album, genreNames: genres, moodNames: nil, releaseDate: nil,
      reference: .unknown, mediaIdentifier: nil)
  }

  func testMediaTypeNames() {
    let expected: [(INMediaItemType, String)] = [
      (.song, "song"), (.album, "album"), (.artist, "artist"), (.playlist, "playlist"),
      (.genre, "genre"), (.music, "music"), (.unknown, "unknown"), (.podcastShow, "unknown"),
      (.movie, "unknown"),
    ]
    for (type, name) in expected {
      XCTAssertEqual(SiriPlayMedia.mediaTypeName(type), name)
    }
  }

  func testArgumentsCarryEveryField() {
    let arguments = SiriPlayMedia.arguments(
      from: search(.song, name: "Alive", artist: "Pearl Jam", album: "Ten", genres: ["Rock", "Grunge"]))
    XCTAssertEqual(
      arguments,
      [
        "mediaType": "song", "mediaName": "Alive", "artistName": "Pearl Jam",
        "albumName": "Ten", "genreName": "Rock",
      ])
  }

  func testArgumentsForEachMediaType() {
    XCTAssertEqual(
      SiriPlayMedia.arguments(from: search(.album, name: "Ten")),
      ["mediaType": "album", "mediaName": "Ten"])
    XCTAssertEqual(
      SiriPlayMedia.arguments(from: search(.artist, name: "Pearl Jam")),
      ["mediaType": "artist", "mediaName": "Pearl Jam"])
    XCTAssertEqual(
      SiriPlayMedia.arguments(from: search(.playlist, name: "Road trip")),
      ["mediaType": "playlist", "mediaName": "Road trip"])
    XCTAssertEqual(
      SiriPlayMedia.arguments(from: search(.genre, genres: ["Jazz"])),
      ["mediaType": "genre", "genreName": "Jazz"])
    XCTAssertEqual(SiriPlayMedia.arguments(from: search(.music)), ["mediaType": "music"])
  }

  func testBlankFieldsAndNilSearchAreOmitted() {
    XCTAssertEqual(
      SiriPlayMedia.arguments(from: search(.unknown, name: "  ", artist: "", genres: [" "])),
      ["mediaType": "unknown"])
    XCTAssertEqual(
      SiriPlayMedia.arguments(from: search(.song, name: "  Alive \n")),
      ["mediaType": "song", "mediaName": "Alive"])
    XCTAssertEqual(SiriPlayMedia.arguments(from: nil), [:])
  }

  func testDeferredFlagIsAddedOnlyWhenAsked() {
    XCTAssertEqual(
      SiriPlayMedia.arguments(from: search(.artist, name: "Radiohead"), deferred: true),
      ["mediaType": "artist", "mediaName": "Radiohead", "deferred": "1"])
    XCTAssertEqual(SiriPlayMedia.arguments(from: nil, deferred: true), ["deferred": "1"])
    XCTAssertNil(SiriPlayMedia.arguments(from: search(.music))["deferred"])
  }

  func testResponseCodes() {
    XCTAssertEqual(SiriPlayMedia.responseCode(forPlayStatus: "playing"), .success)
    XCTAssertEqual(SiriPlayMedia.responseCode(forPlayStatus: "slow"), .success)
    XCTAssertEqual(SiriPlayMedia.responseCode(forPlayStatus: "signedOut"), .failureRequiringAppLaunch)
    XCTAssertEqual(SiriPlayMedia.responseCode(forPlayStatus: "notReady"), .failureRequiringAppLaunch)
    for status in ["notFound", "offline", "surprise", nil] as [String?] {
      XCTAssertEqual(SiriPlayMedia.responseCode(forPlayStatus: status), .failure, status ?? "nil")
    }
  }

  func testResolutionKinds() {
    XCTAssertEqual(SiriPlayMedia.resolutionKind(forStatus: "signedOut"), .loginRequired)
    XCTAssertEqual(SiriPlayMedia.resolutionKind(forStatus: "unavailable"), .serviceUnavailable)
    for status in ["ready", "surprise", nil] as [String?] {
      XCTAssertEqual(SiriPlayMedia.resolutionKind(forStatus: status), .success, status ?? "nil")
    }
  }

  func testResolutionResultsAreBuilt() {
    let item = INMediaItem(identifier: "x", title: "Alive", type: .song, artwork: nil)
    for status in ["ready", "signedOut", "unavailable", nil] as [String?] {
      XCTAssertNotNil(SiriPlayMedia.resolution(forStatus: status, item: item), status ?? "nil")
    }
  }
}
