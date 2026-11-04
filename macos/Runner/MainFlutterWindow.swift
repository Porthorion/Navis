import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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

    let dockMenuChannel = FlutterMethodChannel(
      name: "com.navis.app/dock_menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    dockMenuChannel.setMethodCallHandler { call, result in
      guard call.method == "update",
            let arguments = call.arguments as? [String: Any],
            let delegate = NSApp.delegate as? AppDelegate else {
        result(FlutterMethodNotImplemented)
        return
      }
      delegate.dockMenuChannel = dockMenuChannel
      delegate.applyDockMenuUpdate(arguments)
      result(nil)
    }

    super.awakeFromNib()
  }
}
