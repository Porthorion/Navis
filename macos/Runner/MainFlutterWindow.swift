import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // A real close (not the hide that window_manager's preventClose turns the
  // close button into, which is orderOut and never reaches close()) must not
  // leave a windowless process, e.g. before Dart sets preventClose or after a
  // failed desktop bootstrap. `applicationShouldTerminateAfterLastWindowClosed`
  // cannot do this: AppKit also applies it when the window is merely hidden.
  /// What a real close does; replaceable so a test need not quit the app.
  var terminate: () -> Void = { NSApp.terminate(nil) }

  override func close() {
    super.close()
    DispatchQueue.main.async { [terminate] in terminate() }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    FlutterMethodChannel(
      name: "com.navis.app/storage_capacity",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { call, result in
      guard call.method == "freeBytes",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.global(qos: .utility).async {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
        let bytes = attributes?[.systemFreeSize] as? NSNumber
        DispatchQueue.main.async { result(bytes ?? NSNull()) }
      }
    }

    // file_picker's folder panel cannot create folders; this one can.
    FlutterMethodChannel(
      name: "com.navis.app/directory_picker",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { [weak self] call, result in
      guard call.method == "pick", let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.allowsMultipleSelection = false
      if let title = (call.arguments as? [String: Any])?["title"] as? String {
        panel.message = title
      }
      panel.beginSheetModal(for: self) { response in
        result(response == .OK ? panel.url?.path : nil)
      }
    }

    let dockMenuChannel = FlutterMethodChannel(
      name: "com.navis.app/dock_menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    (NSApp.delegate as? AppDelegate)?.dockMenuChannel = dockMenuChannel
    dockMenuChannel.setMethodCallHandler { call, result in
      guard call.method == "update",
            let arguments = call.arguments as? [String: Any],
            let delegate = NSApp.delegate as? AppDelegate else {
        result(FlutterMethodNotImplemented)
        return
      }
      delegate.applyDockMenuUpdate(arguments)
      result(nil)
    }

    // The main menu is only guaranteed to exist once the nib has loaded.
    DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.installControlsMenu() }

    super.awakeFromNib()
  }
}
