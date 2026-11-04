import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// What the Dock menu shows: the last state Dart pushed over
  /// `com.navis.app/dock_menu`. Labels are localized by Dart.
  struct DockMenuState {
    var hasItem = false
    var title = ""
    var artist = ""
    var playPauseLabel = "Play"
    var nextLabel = "Next"
    var previousLabel = "Previous"
  }

  private(set) var dockMenuState = DockMenuState()
  /// Set by `MainFlutterWindow`; carries the chosen menu action back to Dart.
  var dockMenuChannel: FlutterMethodChannel?

  // Closing the window hides it (window_manager's preventClose plus a Dart
  // hide), so playback keeps running; Cmd+Q and Dock > Quit still quit.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Dock icon clicked while the window is hidden or minimized: bring it back.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag, let window = NSApp.windows.first(where: { $0 is MainFlutterWindow }) {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Handles Dart's `update` call.
  func applyDockMenuUpdate(_ arguments: [String: Any]) {
    var state = DockMenuState()
    state.hasItem = arguments["hasItem"] as? Bool ?? false
    state.title = arguments["title"] as? String ?? ""
    state.artist = arguments["artist"] as? String ?? ""
    state.playPauseLabel = arguments["playPauseLabel"] as? String ?? state.playPauseLabel
    state.nextLabel = arguments["nextLabel"] as? String ?? state.nextLabel
    state.previousLabel = arguments["previousLabel"] as? String ?? state.previousLabel
    dockMenuState = state
  }

  // Right-click on the Dock icon: now playing (disabled), Play/Pause, Next,
  // Previous.
  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let state = dockMenuState
    let menu = NSMenu()
    menu.autoenablesItems = false
    if state.hasItem {
      let label = state.artist.isEmpty ? state.title : "\(state.title) — \(state.artist)"
      let nowPlaying = NSMenuItem(title: label, action: nil, keyEquivalent: "")
      nowPlaying.isEnabled = false
      menu.addItem(nowPlaying)
    }
    for (title, action) in [
      (state.playPauseLabel, "playPause"),
      (state.nextLabel, "next"),
      (state.previousLabel, "previous"),
    ] {
      let item = NSMenuItem(
        title: title, action: #selector(dockMenuItemSelected(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = action
      menu.addItem(item)
    }
    return menu
  }

  @objc func dockMenuItemSelected(_ item: NSMenuItem) {
    guard let action = item.representedObject as? String else { return }
    dockMenuChannel?.invokeMethod("command", arguments: ["action": action])
  }
}
