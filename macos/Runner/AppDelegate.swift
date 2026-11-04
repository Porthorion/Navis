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
    var playPauseLabel = ""
    var nextLabel = ""
    var previousLabel = ""
  }

  /// Nil until the first `update`: before that the Dock shows only its stock
  /// menu rather than transport items with made-up labels.
  private(set) var dockMenuState: DockMenuState?
  /// Set by `MainFlutterWindow`; carries the chosen menu action back to Dart.
  var dockMenuChannel: FlutterMethodChannel?

  // Must stay false: AppKit also applies it when the last window is only
  // hidden, and the close button hides (window_manager's preventClose plus a
  // Dart `hide()`) so playback keeps running. A real close quits through
  // `MainFlutterWindow.close()`. Cmd+Q and Dock > Quit always quit.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Dock icon clicked while the main window is hidden or minimized: bring it
  // back. Judged on the main window itself, so an open About or other panel
  // does not count as "a visible window".
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if let window = NSApp.windows.first(where: { $0 is MainFlutterWindow }), !window.isVisible {
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
    guard let playPauseLabel = arguments["playPauseLabel"] as? String,
          let nextLabel = arguments["nextLabel"] as? String,
          let previousLabel = arguments["previousLabel"] as? String else { return }
    var state = DockMenuState()
    state.hasItem = arguments["hasItem"] as? Bool ?? false
    state.title = arguments["title"] as? String ?? ""
    state.artist = arguments["artist"] as? String ?? ""
    state.playPauseLabel = playPauseLabel
    state.nextLabel = nextLabel
    state.previousLabel = previousLabel
    dockMenuState = state
  }

  // Right-click on the Dock icon: now playing (disabled), Play/Pause, Next,
  // Previous.
  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    guard let state = dockMenuState else { return nil }
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
