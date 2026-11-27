import Flutter
import Intents
import UIKit

/// Pure mapping between SiriKit's `INPlayMediaIntent` and the `com.navis.app/siri`
/// channel contract in `lib/src/features/player/data/ios_siri_bridge.dart`.
enum SiriPlayMedia {
  /// What `status` means for Siri's resolve step.
  enum ResolutionKind: Equatable {
    case success, loginRequired, serviceUnavailable
  }

  /// The `playMedia` arguments; absent or blank fields are omitted.
  static func arguments(from search: INMediaSearch?) -> [String: String] {
    guard let search else { return [:] }
    var arguments = ["mediaType": mediaTypeName(search.mediaType)]
    let fields: [(String, String?)] = [
      ("mediaName", search.mediaName),
      ("artistName", search.artistName),
      ("albumName", search.albumName),
      ("genreName", search.genreNames?.first),
    ]
    for (key, value) in fields {
      if let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        arguments[key] = text
      }
    }
    return arguments
  }

  static func mediaTypeName(_ type: INMediaItemType) -> String {
    switch type {
    case .song: return "song"
    case .album: return "album"
    case .artist: return "artist"
    case .playlist: return "playlist"
    case .genre: return "genre"
    case .music: return "music"
    default: return "unknown"
    }
  }

  /// Dart's `playMedia` reply to Siri's response code; no reply (timeout) fails.
  static func responseCode(forPlayStatus status: String?) -> INPlayMediaIntentResponseCode {
    switch status {
    case "playing": return .success
    case "signedOut", "notReady": return .failureRequiringAppLaunch
    default: return .failure
    }
  }

  static func resolutionKind(forStatus status: String?) -> ResolutionKind {
    switch status {
    case "signedOut": return .loginRequired
    case "unavailable": return .serviceUnavailable
    default: return .success
    }
  }

  static func resolution(
    forStatus status: String?, item: INMediaItem
  ) -> INPlayMediaMediaItemResolutionResult {
    switch resolutionKind(forStatus: status) {
    case .loginRequired: return .unsupported(forReason: .loginRequired)
    case .serviceUnavailable: return .unsupported(forReason: .serviceUnavailable)
    case .success: return .success(with: item)
    }
  }
}

/// Answers `INPlayMediaIntent` in the app process. A background launch for an
/// intent connects no scene, so no Dart engine runs: that case answers
/// `.continueInApp` and the intent arrives again as a user activity, held in
/// `pendingSearch` until Dart reports `ready`.
final class SiriBridge: NSObject, INPlayMediaIntentHandling {
  static let shared = SiriBridge()

  private var channel: FlutterMethodChannel?
  private var dartReady = false
  private var pendingSearch: INMediaSearch?

  /// Main thread only.
  private var isInProcess: Bool {
    dartReady && channel != nil && !UIApplication.shared.connectedScenes.isEmpty
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.navis.app/siri", binaryMessenger: messenger)
    self.channel = channel
    dartReady = false
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "ready":
        self?.dartIsReady()
        result(nil)
      case "setVocabulary":
        let arguments = call.arguments as? [String: Any]
        self?.setVocabulary(
          artists: arguments?["artists"] as? [String] ?? [],
          playlists: arguments?["playlists"] as? [String] ?? [])
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: INPlayMediaIntentHandling

  func resolveMediaItems(
    for intent: INPlayMediaIntent,
    with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
  ) {
    DispatchQueue.main.async {
      let search = intent.mediaSearch
      let item = INMediaItem(
        identifier: "navis.siri.search",
        title: search?.mediaName ?? search?.artistName ?? search?.albumName,
        type: search?.mediaType ?? .music,
        artwork: nil)
      guard self.isInProcess else {
        NSLog("Navis Siri: resolve scenes=%d dartReady=%d path=cold", self.sceneCount, self.dartReady ? 1 : 0)
        completion([.success(with: item)])
        return
      }
      self.call("status", nil, timeout: 3) { status in
        NSLog("Navis Siri: resolve path=warm status=%@", status ?? "timeout")
        completion([SiriPlayMedia.resolution(forStatus: status, item: item)])
      }
    }
  }

  func handle(
    intent: INPlayMediaIntent,
    completion: @escaping (INPlayMediaIntentResponse) -> Void
  ) {
    DispatchQueue.main.async {
      let search = intent.mediaSearch
      let type = SiriPlayMedia.mediaTypeName(search?.mediaType ?? .unknown)
      guard self.isInProcess else {
        NSLog(
          "Navis Siri: handle scenes=%d dartReady=%d type=%@ name=%@ path=cold code=continueInApp",
          self.sceneCount, self.dartReady ? 1 : 0, type, search?.mediaName ?? "-")
        completion(INPlayMediaIntentResponse(code: .continueInApp, userActivity: nil))
        return
      }
      self.call("playMedia", SiriPlayMedia.arguments(from: search), timeout: 10) { status in
        let code = SiriPlayMedia.responseCode(forPlayStatus: status)
        NSLog(
          "Navis Siri: handle scenes=%d type=%@ name=%@ path=warm status=%@ code=%ld",
          self.sceneCount, type, search?.mediaName ?? "-", status ?? "timeout", code.rawValue)
        completion(INPlayMediaIntentResponse(code: code, userActivity: nil))
      }
    }
  }

  // MARK: Cold launch

  /// A user activity from a scene connecting or continuing; plays it when Dart
  /// is up (a scene exists by definition), else keeps it until `ready`.
  func takeUserActivity(_ activity: NSUserActivity) {
    guard let intent = activity.interaction?.intent as? INPlayMediaIntent else { return }
    DispatchQueue.main.async {
      let search = intent.mediaSearch
      if self.dartReady && self.channel != nil {
        NSLog("Navis Siri: activity played at once name=%@", search?.mediaName ?? "-")
        self.call("playMedia", SiriPlayMedia.arguments(from: search), timeout: 10) { _ in }
      } else {
        NSLog("Navis Siri: activity held until ready name=%@", search?.mediaName ?? "-")
        self.pendingSearch = search
      }
    }
  }

  private func dartIsReady() {
    DispatchQueue.main.async {
      self.dartReady = true
      guard let pending = self.pendingSearch else { return }
      self.pendingSearch = nil
      NSLog("Navis Siri: flushing held activity name=%@", pending.mediaName ?? "-")
      self.call("playMedia", SiriPlayMedia.arguments(from: pending), timeout: 10) { _ in }
    }
  }

  // MARK: Vocabulary

  private func setVocabulary(artists: [String], playlists: [String]) {
    func apply() {
      let vocabulary = INVocabulary.shared()
      vocabulary.setVocabularyStrings(NSOrderedSet(array: artists), of: .mediaMusicArtistName)
      vocabulary.setVocabularyStrings(NSOrderedSet(array: playlists), of: .mediaPlaylistTitle)
      NSLog("Navis Siri: vocabulary artists=%d playlists=%d", artists.count, playlists.count)
    }
    DispatchQueue.main.async {
      switch INPreferences.siriAuthorizationStatus() {
      case .authorized:
        DispatchQueue.global(qos: .utility).async(execute: apply)
      case .notDetermined where UIApplication.shared.applicationState == .active:
        INPreferences.requestSiriAuthorization { status in
          if status == .authorized { apply() }
        }
      default:
        break
      }
    }
  }

  // MARK: Channel

  private var sceneCount: Int { UIApplication.shared.connectedScenes.count }

  /// Invokes Dart and answers [completion] exactly once, on the main queue: with
  /// the string reply, or nil on timeout, error or no channel.
  private func call(
    _ method: String, _ arguments: Any?, timeout: TimeInterval,
    completion: @escaping (String?) -> Void
  ) {
    guard let channel else {
      completion(nil)
      return
    }
    var finished = false
    var timeoutItem: DispatchWorkItem?
    let finish: (String?) -> Void = { value in
      guard !finished else { return }
      finished = true
      timeoutItem?.cancel()
      completion(value)
    }
    let item = DispatchWorkItem { finish(nil) }
    timeoutItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    channel.invokeMethod(method, arguments: arguments) { reply in
      DispatchQueue.main.async { finish(reply as? String) }
    }
  }
}
