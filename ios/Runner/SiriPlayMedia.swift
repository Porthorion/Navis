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

  /// The `playMedia` arguments; absent or blank fields are omitted. `deferred`
  /// marks a cold-launch intent replayed once Dart is up (Dart waits longer,
  /// as no Siri response is pending).
  static func arguments(from search: INMediaSearch?, deferred: Bool = false) -> [String: String] {
    var arguments: [String: String] = deferred ? ["deferred": "1"] : [:]
    guard let search else { return arguments }
    arguments["mediaType"] = mediaTypeName(search.mediaType)
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
  /// `slow` means the search is still loading and music will start: success.
  static func responseCode(forPlayStatus status: String?) -> INPlayMediaIntentResponseCode {
    switch status {
    case "playing", "slow": return .success
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
        self.call("playMedia", SiriPlayMedia.arguments(from: search, deferred: true), timeout: 10) { _ in }
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
      self.call("playMedia", SiriPlayMedia.arguments(from: pending, deferred: true), timeout: 10) { _ in }
    }
  }

  /// The scene (and its Flutter engine) went away: Dart is no longer there to
  /// answer, so a later activity waits for the next engine's `ready`.
  func sceneDidDisconnect() {
    DispatchQueue.main.async {
      NSLog("Navis Siri: scene disconnected, channel dropped")
      self.dartReady = false
      self.channel = nil
    }
  }

  // MARK: Vocabulary

  /// Latest lists waiting for the Siri authorization prompt; main thread only.
  private var pendingVocabulary: (artists: [String], playlists: [String])?
  private var authorizationInFlight = false
  private var activationObserver: NSObjectProtocol?

  /// Empty lists clear the vocabulary and never prompt (signed out). Otherwise
  /// the lists are applied once Siri is authorized; the prompt is requested
  /// while the app is active, or on the next activation if it is not.
  private func setVocabulary(artists: [String], playlists: [String]) {
    DispatchQueue.main.async {
      if artists.isEmpty && playlists.isEmpty {
        self.pendingVocabulary = nil
        DispatchQueue.global(qos: .utility).async {
          INVocabulary.shared().removeAllVocabularyStrings()
          NSLog("Navis Siri: vocabulary cleared")
        }
        return
      }
      self.applyVocabulary(artists, playlists)
    }
  }

  private func applyVocabulary(_ artists: [String], _ playlists: [String]) {
    switch INPreferences.siriAuthorizationStatus() {
    case .authorized:
      pendingVocabulary = nil
      writeVocabulary(artists, playlists)
    case .notDetermined:
      pendingVocabulary = (artists, playlists)
      if UIApplication.shared.applicationState == .active {
        requestAuthorization()
      } else if activationObserver == nil {
        activationObserver = NotificationCenter.default.addObserver(
          forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
          guard let self, let pending = self.pendingVocabulary else { return }
          self.applyVocabulary(pending.artists, pending.playlists)
        }
      }
    default:
      pendingVocabulary = nil
    }
  }

  private func requestAuthorization() {
    guard !authorizationInFlight else { return }
    authorizationInFlight = true
    INPreferences.requestSiriAuthorization { status in
      DispatchQueue.main.async {
        self.authorizationInFlight = false
        guard let pending = self.pendingVocabulary else { return }
        self.pendingVocabulary = nil
        if status == .authorized { self.writeVocabulary(pending.artists, pending.playlists) }
      }
    }
  }

  private func writeVocabulary(_ artists: [String], _ playlists: [String]) {
    DispatchQueue.global(qos: .utility).async {
      let vocabulary = INVocabulary.shared()
      vocabulary.setVocabularyStrings(NSOrderedSet(array: artists), of: .mediaMusicArtistName)
      vocabulary.setVocabularyStrings(NSOrderedSet(array: playlists), of: .mediaPlaylistTitle)
      NSLog("Navis Siri: vocabulary artists=%d playlists=%d", artists.count, playlists.count)
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
